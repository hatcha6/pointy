"""A sale below cost is refused for everyone and priced only for those who may
see cost.

The loss guard answers in two places: the discount preview the till runs on
every cart edit, and the ``sale_at_loss_blocked`` refusal from every sale path.
Both used to hand any cashier ``unit_cost``, ``line_cost`` and ``loss_amount``,
and with no manual-discount ceiling one item discounted to nothing read back
exactly what the owner paid for it. What these pin: the figures go to the
reporting roles and to holders of ``sales.view_till_cost``, a cashier is still
told which line is below cost, and the sale is still refused for everyone.
"""

from decimal import Decimal
from types import SimpleNamespace

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group, Permission
from django.test import TestCase
from django.urls import reverse
from rest_framework import status
from rest_framework.test import APIClient

from apps.catalog.testing import create_product_with_default_variant
from apps.core.models import ShopSettings
from apps.core.roles import (
    CASHIER_GROUP,
    MANAGER_GROUP,
    SUPERVISOR_GROUP,
    ensure_role_groups,
)
from apps.customers.models import Customer

from .models import Order

#: What the rice cost the shop, and what a 5.00 checkout of it loses. Chosen so
#: neither can turn up in a response by coincidence: a cashier's payload must
#: not carry them anywhere, under any key.
COST = "6.40"
CHECKOUT_LOSS = "1.40"
COST_FIELDS = ("unit_cost", "line_cost", "loss_amount")


class LossLineVisibilityTests(TestCase):
    def setUp(self):
        ensure_role_groups()
        self.product = create_product_with_default_variant(
            name="أرز", sku="RICE-LOSS", unit_price=Decimal("10.00")
        )
        self.variant = self.product.default_variant
        self._stock_at_cost(Decimal(COST))

    # -------------------------------------------------------------- readers

    def _user(self, username, group, *, till_cost=False):
        User = get_user_model()
        user = User.objects.create_user(username=username, password="x")
        user.groups.add(Group.objects.get(name=group))
        if till_cost:
            user.user_permissions.add(
                Permission.objects.get(
                    content_type__app_label="sales", codename="view_till_cost"
                )
            )
        # Fresh from the database, so no permission cache predates the grant.
        return User.objects.get(pk=user.pk)

    def _client(self, username, group, *, till_cost=False):
        client = APIClient()
        client.force_authenticate(
            self._user(username, group, till_cost=till_cost)
        )
        return client

    def cashier(self):
        return self._client("till", CASHIER_GROUP)

    def readers_who_see_cost(self):
        """Everyone the figures are for: a manager, a reporting role that was
        never granted the till permission, and a cashier who was."""
        return {
            "manager": self._client("owner", MANAGER_GROUP),
            "supervisor": self._client("floor", SUPERVISOR_GROUP),
            "cashier with till cost": self._client(
                "senior-till", CASHIER_GROUP, till_cost=True
            ),
        }

    # -------------------------------------------------------------- preview

    def _preview(self, client, *, discount):
        return client.post(
            reverse("order-discount-preview"),
            {
                "lines": [{"variant": self.variant.pk, "quantity": "1"}],
                "extra_discount_amount": discount,
            },
            format="json",
        )

    def test_a_cashier_is_told_which_line_is_below_cost_but_not_its_cost(self):
        # The leak itself: one item, its whole price taken off by hand, and
        # the "loss" that came back was the cost.
        response = self._preview(self.cashier(), discount="10.00")

        self.assertEqual(response.status_code, status.HTTP_200_OK, response.data)
        [line] = response.data["loss_lines"]
        self.assertEqual(line["variant_id"], self.variant.pk)
        self.assertEqual(line["product_name"], "أرز")
        self.assertEqual(line["line_total"], "0.00")
        for field in COST_FIELDS:
            self.assertNotIn(field, line)
        self.assertNotIn(COST, str(response.data))

    def test_the_preview_prices_the_loss_for_readers_who_see_cost(self):
        for audience, client in self.readers_who_see_cost().items():
            with self.subTest(audience):
                response = self._preview(client, discount="10.00")

                self.assertEqual(
                    response.status_code, status.HTTP_200_OK, response.data
                )
                [line] = response.data["loss_lines"]
                self.assertEqual(line["unit_cost"], COST)
                self.assertEqual(line["line_cost"], COST)
                self.assertEqual(line["loss_amount"], COST)

    # ------------------------------------------------------------- checkout

    def _open_session(self, client):
        client.post(
            reverse("register-session-start"),
            {"opening_cash": "0.00"},
            format="json",
        )

    def _checkout(self, client):
        self._open_session(client)
        return client.post(
            reverse("order-checkout"),
            {
                "lines": [{"variant": self.variant.pk, "quantity": "1"}],
                "extra_discount_amount": "5.00",
                "payments": [{"method": "cash", "amount": "5.00"}],
            },
            format="json",
        )

    def test_checkout_refuses_a_cashier_below_cost_without_pricing_it(self):
        response = self._checkout(self.cashier())

        self.assertEqual(
            response.status_code, status.HTTP_400_BAD_REQUEST, response.data
        )
        self.assertEqual(response.data["code"], "sale_at_loss_blocked")
        [line] = response.data["loss"]
        self.assertEqual(int(line["variant_id"]), self.variant.pk)
        self.assertEqual(str(line["line_total"]), "5.00")
        for field in COST_FIELDS:
            self.assertNotIn(field, line)
        self.assertNotIn(COST, str(response.data))
        self.assertNotIn(CHECKOUT_LOSS, str(response.data))
        # Hiding the figure did not soften the guard.
        self.assertFalse(Order.objects.exists())

    def test_checkout_prices_the_refusal_for_readers_who_see_cost(self):
        for audience, client in self.readers_who_see_cost().items():
            with self.subTest(audience):
                response = self._checkout(client)

                self.assertEqual(
                    response.status_code,
                    status.HTTP_400_BAD_REQUEST,
                    response.data,
                )
                self.assertEqual(response.data["code"], "sale_at_loss_blocked")
                [line] = response.data["loss"]
                self.assertEqual(str(line["unit_cost"]), COST)
                self.assertEqual(str(line["line_cost"]), COST)
                self.assertEqual(str(line["loss_amount"]), CHECKOUT_LOSS)
        self.assertFalse(Order.objects.exists())

    # ------------------------------------------------------ settling a debt

    def test_settling_a_debt_below_cost_is_priced_only_for_who_may_see_it(self):
        # Another sale path and another builder: the refusal is raised by the
        # payment that settles an invoice, from the order's stored lines rather
        # than a cart. An آجل invoice issued while the shop allowed losses is
        # refused when it is settled after the shop stopped allowing them.
        customer = Customer.objects.create(full_name="زبون آجل")
        cashier = self.cashier()
        self._open_session(cashier)
        self._set_loss_guard(False)
        issued = cashier.post(
            reverse("order-checkout"),
            {
                "lines": [{"variant": self.variant.pk, "quantity": "1"}],
                "extra_discount_amount": "5.00",
                "sale_type": "credit",
                "customer": customer.pk,
            },
            format="json",
        )
        self.assertEqual(issued.status_code, status.HTTP_201_CREATED, issued.data)
        self._set_loss_guard(True)
        manager = self._client("owner", MANAGER_GROUP)
        self._open_session(manager)

        def settle(client):
            return client.post(
                reverse("order-record-payment", args=[issued.data["id"]]),
                {"method": "cash", "amount": "5.00"},
                format="json",
            )

        refused = settle(cashier)
        self.assertEqual(
            refused.status_code, status.HTTP_400_BAD_REQUEST, refused.data
        )
        self.assertEqual(refused.data["code"], "sale_at_loss_blocked")
        [line] = refused.data["loss"]
        self.assertEqual(int(line["variant_id"]), self.variant.pk)
        for field in COST_FIELDS:
            self.assertNotIn(field, line)
        self.assertNotIn(COST, str(refused.data))
        self.assertNotIn(CHECKOUT_LOSS, str(refused.data))

        priced = settle(manager)
        self.assertEqual(
            priced.status_code, status.HTTP_400_BAD_REQUEST, priced.data
        )
        [line] = priced.data["loss"]
        self.assertEqual(str(line["line_cost"]), COST)
        self.assertEqual(str(line["loss_amount"]), CHECKOUT_LOSS)
        self.assertNotEqual(
            Order.objects.get(pk=issued.data["id"]).status, Order.Status.PAID
        )

    # ------------------------------------------------------------- handler

    def test_a_refusal_raised_during_validation_is_redacted_too(self):
        # Raised inside a serializer's validate(), DRF wraps every value of the
        # error in a list, ``code`` included. A redaction keyed on the bare
        # string would wave that shape through with the cost still in it.
        from rest_framework.exceptions import ValidationError
        from rest_framework.serializers import as_serializer_error

        from .loss_visibility import exception_handler
        from .services import sale_loss_blocked_payload, sale_loss_line_payload

        line = sale_loss_line_payload(
            line_key="0",
            variant=self.variant,
            quantity=Decimal("1"),
            unit_price=Decimal("10.00"),
            unit_cost=Decimal(COST),
            discount_total=Decimal("5.00"),
            line_total=Decimal("5.00"),
            line_cost=Decimal(COST),
        )
        refusal = ValidationError(
            as_serializer_error(ValidationError(sale_loss_blocked_payload([line])))
        )
        cashier = self._user("till", CASHIER_GROUP)

        response = exception_handler(
            refusal, {"request": SimpleNamespace(user=cashier)}
        )

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        [redacted] = response.data["loss"]
        self.assertEqual(redacted["line_total"], "5.00")
        for field in COST_FIELDS:
            self.assertNotIn(field, redacted)

    # ---------------------------------------------------------------- setup

    def _set_loss_guard(self, enabled):
        settings = ShopSettings.load()
        settings.prevent_selling_at_loss = enabled
        settings.save(update_fields=["prevent_selling_at_loss"])

    def _stock_at_cost(self, unit_cost):
        """Ten on the shelf, valued at a known rate — written to the valuation
        bin the loss guard reads, as ``test_till_cost_and_price_override``
        does."""
        from apps.inventory.models import StockItem, StockValuationBin, Warehouse

        StockItem.objects.create(variant=self.variant, quantity_on_hand=Decimal("10"))
        StockValuationBin.objects.update_or_create(
            variant=self.variant,
            warehouse_id=Warehouse.default_id(),
            defaults={
                "quantity": Decimal("10"),
                "stock_value": unit_cost * Decimal("10"),
                "valuation_rate": unit_cost,
            },
        )
