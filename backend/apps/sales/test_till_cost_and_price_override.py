"""Two rights a shop grants separately: seeing cost, and changing a price.

A shop asked for both at the till — the cost of what they are selling, and the
ability to reprice a cart line without walking to the products screen. They are
implemented as two permissions rather than one because they are different
kinds of trust: knowing what a thing cost is knowledge, and changing what it
sells for is revenue.

What these pin is that neither can be had by accident, and that repricing does
not become a hole in the guards that already stand around a sale.
"""

from decimal import Decimal

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group, Permission
from django.test import TestCase
from django.urls import reverse
from rest_framework import status
from rest_framework.test import APIClient

from apps.catalog.testing import create_product_with_default_variant
from apps.core.models import ShopSettings
from apps.core.roles import CASHIER_GROUP, MANAGER_GROUP, ensure_role_groups

from .models import Order, RegisterSession


class TillCostAndPriceOverrideTests(TestCase):
    def setUp(self):
        ensure_role_groups()
        User = get_user_model()
        self.cashier = User.objects.create_user(username="till", password="x")
        self.cashier.groups.add(Group.objects.get(name=CASHIER_GROUP))
        self.client = APIClient()
        self.client.force_authenticate(self.cashier)

        self.product = create_product_with_default_variant(
            name="أرز", sku="RICE-1", unit_price=Decimal("10.00")
        )
        self.variant = self.product.default_variant
        self.session = RegisterSession.objects.create(
            owner_key=f"user:{self.cashier.pk}",
            opening_cash=Decimal("0.00"),
        )
        self._stock_at_cost(Decimal("6.00"))

    def _grant(self, codename):
        self.cashier.user_permissions.add(
            Permission.objects.get(
                codename=codename, content_type__app_label="sales"
            )
        )
        self.cashier = get_user_model().objects.get(pk=self.cashier.pk)
        self.client.force_authenticate(self.cashier)

    def _checkout(self, *, unit_price=None, amount="10.00"):
        line = {"variant": self.variant.pk, "quantity": "1"}
        if unit_price is not None:
            line["unit_price"] = unit_price
        return self.client.post(
            reverse("order-checkout"),
            {
                "lines": [line],
                "payments": [{"method": "cash", "amount": amount}],
            },
            format="json",
        )

    # ---------------------------------------------------------------- cost

    def test_a_cashier_cannot_read_cost_without_the_permission(self):
        # The most sensitive number a shop has is not something a till gets by
        # virtue of being able to sell.
        response = self.client.post(
            reverse("order-line-costs"),
            {"variants": [self.variant.pk]},
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_403_FORBIDDEN)

    def test_the_permission_reads_cost_for_the_cart(self):
        self._grant("view_till_cost")

        response = self.client.post(
            reverse("order-line-costs"),
            {"variants": [self.variant.pk]},
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertIn(str(self.variant.pk), response.data["costs"])

    def test_seeing_cost_does_not_let_you_change_a_price(self):
        # The whole reason these are two permissions. A shop may well want a
        # senior cashier to know the floor without being able to discount to it.
        self._grant("view_till_cost")

        response = self._checkout(unit_price="6.00", amount="6.00")

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertFalse(Order.objects.exists())

    # ------------------------------------------------------------- pricing

    def test_a_price_sent_without_the_permission_is_refused_not_ignored(self):
        # Refused rather than quietly dropped: the cashier typed 6.00 and told
        # the customer 6.00, so silently charging 10.00 would be worse than
        # failing — the disagreement would be discovered at the counter.
        response = self._checkout(unit_price="6.00", amount="6.00")

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertIn("unit_price", str(response.data))
        self.assertFalse(Order.objects.exists())

    def test_the_permission_sells_at_the_typed_price(self):
        self._grant("override_line_price")

        response = self._checkout(unit_price="6.00", amount="6.00")

        self.assertEqual(response.status_code, status.HTTP_201_CREATED)
        line = Order.objects.get().lines.get()
        self.assertEqual(line.unit_price, Decimal("6.00"))

    def test_an_overridden_line_remembers_what_it_would_have_sold_for(self):
        # A repriced line is the money decision a manager most wants to find
        # afterwards, and today's price sheet cannot answer it — prices move.
        self._grant("override_line_price")

        self._checkout(unit_price="6.00", amount="6.00")

        line = Order.objects.get().lines.get()
        self.assertEqual(line.original_unit_price, Decimal("10.00"))

    def test_an_ordinary_line_carries_no_override_marker(self):
        response = self._checkout()

        self.assertEqual(
            response.status_code, status.HTTP_201_CREATED, response.data
        )
        line = Order.objects.get().lines.get()
        self.assertIsNone(line.original_unit_price)
        self.assertEqual(line.unit_price, Decimal("10.00"))

    def test_repricing_to_the_same_number_is_not_an_override(self):
        self._grant("override_line_price")

        self._checkout(unit_price="10.00")

        line = Order.objects.get().lines.get()
        self.assertIsNone(line.original_unit_price)

    def test_a_negative_price_is_refused(self):
        self._grant("override_line_price")

        response = self._checkout(unit_price="-1.00", amount="0.00")

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)

    def test_repricing_below_cost_still_meets_the_shop_loss_guard(self):
        # The point: repricing is not a way around the guard that already
        # stands in front of a discount to the same number. The guard reads
        # effective_unit_price, which is what the override sets.
        settings = ShopSettings.load()
        settings.prevent_selling_at_loss = True
        settings.save(update_fields=["prevent_selling_at_loss"])
        self._grant("override_line_price")

        response = self._checkout(unit_price="4.00", amount="4.00")

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertEqual(response.data.get("code"), "sale_at_loss_blocked")
        self.assertFalse(Order.objects.exists())

    def _stock_at_cost(self, unit_cost):
        """Ten on the shelf, valued at a known rate.

        Written straight to the valuation bin rather than through a purchase
        order: the bin IS what `valuation_unit_costs` reads, so this seeds
        exactly the number the endpoint reports and the loss guard compares
        against, with none of a PO's ceremony in between.
        """
        from apps.inventory.models import (
            StockItem,
            StockValuationBin,
            Warehouse,
        )

        warehouse_id = Warehouse.default_id()
        StockItem.objects.create(
            variant=self.variant,
            quantity_on_hand=Decimal("10"),
        )
        StockValuationBin.objects.update_or_create(
            variant=self.variant,
            warehouse_id=warehouse_id,
            defaults={
                "quantity": Decimal("10"),
                "stock_value": unit_cost * Decimal("10"),
                "valuation_rate": unit_cost,
            },
        )


class RoleDefaultsTests(TestCase):
    """Who holds these out of the box.

    A manager gets both, because MANAGER_PERMISSION_DOMAINS grants every
    `sales` permission and a manager already sees cost on the products screen,
    in the reports and all through purchasing — refusing it at the till would
    be an inconsistency, not a safeguard.

    A cashier gets neither, and that is the control a shop actually asked
    for: it decides, per person, who at the counter may see what the owner
    pays a supplier and who may change what a thing sells for.
    """

    def setUp(self):
        ensure_role_groups()

    def _sales_codenames(self, role):
        return set(
            Group.objects.get(name=role)
            .permissions.filter(content_type__app_label="sales")
            .values_list("codename", flat=True)
        )

    def test_a_cashier_gets_neither_by_default(self):
        codenames = self._sales_codenames(CASHIER_GROUP)

        self.assertNotIn("view_till_cost", codenames)
        self.assertNotIn("override_line_price", codenames)

    def test_a_manager_gets_both(self):
        codenames = self._sales_codenames(MANAGER_GROUP)

        self.assertIn("view_till_cost", codenames)
        self.assertIn("override_line_price", codenames)
