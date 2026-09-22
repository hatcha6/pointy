"""Opening stock: a product typed in with what the shop already has of it.

The feature exists because a cost that only arrives with a purchase order is
no cost at all for a shop entering shelves it has been trading off for years.
Every test here is about the second half of that sentence — the shelf moving
is easy, and it is the *valuation* that everything downstream reads.
"""

from decimal import Decimal

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group, Permission
from django.test import TestCase
from django.urls import reverse
from rest_framework import status
from rest_framework.test import APIClient

from apps.core.roles import CASHIER_GROUP, MANAGER_GROUP, ensure_role_groups
from apps.inventory.models import (
    StockItem,
    StockLedgerEntry,
    StockMovement,
    StockUnit,
    StockValuationBin,
)
from apps.inventory.valuation_service import valuation_unit_costs

from .models import Product, ProductVariant, VariantOption, VariantOptionValue


class OpeningStockApiTests(TestCase):
    def setUp(self):
        ensure_role_groups()
        self.client = APIClient()
        self.user = get_user_model().objects.create_user(
            username="opening-manager",
            password="pass",
        )
        self.user.groups.add(Group.objects.get(name=MANAGER_GROUP))
        self.client.force_authenticate(user=self.user)

    def _create(self, **overrides):
        payload = {
            "name": "زيت زيتون",
            "is_active": True,
            "default_variant": {
                "sku": "OIL-1",
                "unit_price": "12.00",
                "opening_quantity": "40",
                "opening_unit_cost": "7.500000",
            },
        }
        payload.update(overrides)
        return self.client.post(reverse("product-list"), payload, format="json")

    def test_opening_quantity_lands_on_the_shelf(self):
        response = self._create()

        self.assertEqual(response.status_code, status.HTTP_201_CREATED)
        variant = ProductVariant.objects.get(sku="OIL-1")
        self.assertEqual(
            StockItem.objects.get(variant=variant).quantity_on_hand,
            Decimal("40.000"),
        )

    def test_opening_cost_opens_the_valuation(self):
        """The half that matters. Without it the first sale books the whole
        selling price as profit, because the engine finds no bin and no
        purchase to fall back on."""
        self._create()
        variant = ProductVariant.objects.get(sku="OIL-1")

        bin_row = StockValuationBin.objects.get(variant=variant)
        self.assertEqual(bin_row.quantity, Decimal("40.000"))
        self.assertEqual(bin_row.valuation_rate, Decimal("7.500000"))
        self.assertEqual(bin_row.stock_value, Decimal("300.000000"))
        # And the till reads it through the ordinary door, not a special case.
        self.assertEqual(
            valuation_unit_costs([variant.pk])[variant.pk],
            Decimal("7.500000"),
        )

    def test_it_is_an_opening_voucher_not_an_adjustment(self):
        """A manual adjustment corrects a shelf the system already had an
        opinion about. This is the first opinion, and the cost screens read the
        voucher type to tell them apart."""
        self._create()
        variant = ProductVariant.objects.get(sku="OIL-1")

        entry = StockLedgerEntry.objects.get(variant=variant)
        self.assertEqual(
            entry.voucher_type, StockLedgerEntry.VoucherType.OPENING
        )
        self.assertEqual(entry.quantity_change, Decimal("40.000"))
        self.assertEqual(entry.valuation_rate, Decimal("7.500000"))

    def test_the_stock_history_shows_who_opened_it(self):
        self._create()
        variant = ProductVariant.objects.get(sku="OIL-1")

        movement = StockMovement.objects.get(variant=variant)
        self.assertEqual(movement.movement_type, StockMovement.Type.INCREASE)
        self.assertEqual(movement.quantity, Decimal("40.000"))
        self.assertEqual(movement.on_hand_before, Decimal("0.000"))
        self.assertEqual(movement.on_hand_after, Decimal("40.000"))
        self.assertEqual(movement.created_by, self.user)

    def test_no_opening_means_no_stock_event_at_all(self):
        """Every product created before this feature, and almost every one
        created after it, sends nothing — and must cost nothing."""
        response = self._create(
            default_variant={"sku": "OIL-2", "unit_price": "12.00"}
        )

        self.assertEqual(response.status_code, status.HTTP_201_CREATED)
        variant = ProductVariant.objects.get(sku="OIL-2")
        self.assertFalse(StockMovement.objects.filter(variant=variant).exists())
        self.assertFalse(
            StockLedgerEntry.objects.filter(variant=variant).exists()
        )

    def test_zero_quantity_is_not_an_opening(self):
        response = self._create(
            default_variant={
                "sku": "OIL-3",
                "unit_price": "12.00",
                "opening_quantity": "0",
            }
        )

        self.assertEqual(response.status_code, status.HTTP_201_CREATED)
        variant = ProductVariant.objects.get(sku="OIL-3")
        self.assertFalse(StockMovement.objects.filter(variant=variant).exists())

    def test_a_cost_with_no_quantity_is_refused(self):
        """Nothing would be written and the number would vanish, so it is a
        typo rather than half an answer."""
        response = self._create(
            default_variant={
                "sku": "OIL-4",
                "unit_price": "12.00",
                "opening_unit_cost": "7.50",
            }
        )

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertIn("opening_quantity", response.data)
        self.assertFalse(Product.objects.filter(name="زيت زيتون").exists())

    def test_opening_a_quantity_with_no_cost_is_allowed(self):
        """A shop that knows how many it has but not what it paid is telling
        the truth. The shelf moves; the ledger opens at zero rather than at an
        invented number."""
        response = self._create(
            default_variant={
                "sku": "OIL-5",
                "unit_price": "12.00",
                "opening_quantity": "6",
            }
        )

        self.assertEqual(response.status_code, status.HTTP_201_CREATED)
        variant = ProductVariant.objects.get(sku="OIL-5")
        self.assertEqual(
            StockItem.objects.get(variant=variant).quantity_on_hand,
            Decimal("6.000"),
        )
        self.assertEqual(
            StockValuationBin.objects.get(variant=variant).valuation_rate,
            Decimal("0.000000"),
        )

    def test_a_service_has_no_shelf_to_open(self):
        response = self._create(
            is_service=True,
            default_variant={
                "sku": "SRV-1",
                "unit_price": "12.00",
                "opening_quantity": "5",
                "opening_unit_cost": "1.00",
            },
        )

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertIn("opening_quantity", response.data)

    def test_a_made_to_order_product_has_no_shelf_to_open(self):
        response = self._create(
            is_prepared=True,
            default_variant={
                "sku": "PRP-1",
                "unit_price": "12.00",
                "opening_quantity": "5",
                "opening_unit_cost": "1.00",
            },
        )

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)

    def test_a_failed_opening_takes_the_product_with_it(self):
        """The two are one transaction. A product created with a shelf nobody
        asked for is worse than a refused save."""
        self._create(
            is_service=True,
            default_variant={
                "sku": "SRV-2",
                "unit_price": "12.00",
                "opening_quantity": "5",
            },
        )

        self.assertFalse(ProductVariant.objects.filter(sku="SRV-2").exists())

    def test_opening_stock_is_refused_on_an_edit(self):
        """A second opening on a shelf that already has a history is not a
        correction of the first one; a stock count or an adjustment is."""
        create = self._create(
            default_variant={"sku": "OIL-6", "unit_price": "12.00"}
        )
        product_id = create.data["id"]

        response = self.client.patch(
            reverse("product-detail", args=[product_id]),
            {
                "default_variant": {
                    "sku": "OIL-6",
                    "unit_price": "12.00",
                    "opening_quantity": "10",
                    "opening_unit_cost": "3.00",
                }
            },
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        variant = ProductVariant.objects.get(sku="OIL-6")
        self.assertFalse(StockMovement.objects.filter(variant=variant).exists())

    def test_creating_a_product_without_the_stock_permission_still_works(self):
        """The product create is allowed either way — it is only the two extra
        numbers that answer to the stock permission."""
        clerk = get_user_model().objects.create_user(
            username="clerk", password="pass"
        )
        clerk.groups.add(Group.objects.get(name=CASHIER_GROUP))
        clerk.user_permissions.add(
            Permission.objects.get(
                content_type__app_label="catalog", codename="add_product"
            )
        )
        client = APIClient()
        client.force_authenticate(user=clerk)

        allowed = client.post(
            reverse("product-list"),
            {
                "name": "شاي",
                "default_variant": {"sku": "TEA-1", "unit_price": "3.00"},
            },
            format="json",
        )
        refused = client.post(
            reverse("product-list"),
            {
                "name": "شاي أخضر",
                "default_variant": {
                    "sku": "TEA-2",
                    "unit_price": "3.00",
                    "opening_quantity": "9",
                    "opening_unit_cost": "1.00",
                },
            },
            format="json",
        )

        self.assertEqual(allowed.status_code, status.HTTP_201_CREATED)
        self.assertEqual(refused.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertFalse(ProductVariant.objects.filter(sku="TEA-2").exists())


class GeneratedVariantOpeningStockTests(TestCase):
    """A shop with six sizes on the shelf holds a different number of each."""

    def setUp(self):
        ensure_role_groups()
        self.client = APIClient()
        self.user = get_user_model().objects.create_user(
            username="opening-variants", password="pass"
        )
        self.user.groups.add(Group.objects.get(name=MANAGER_GROUP))
        self.client.force_authenticate(user=self.user)
        self.option = VariantOption.objects.create(name="المقاس")
        self.small = VariantOptionValue.objects.create(
            option=self.option, code="S", name="صغير"
        )
        self.large = VariantOptionValue.objects.create(
            option=self.option, code="L", name="كبير"
        )

    def test_each_generated_variant_opens_at_its_own_quantity_and_cost(self):
        response = self.client.post(
            reverse("product-list"),
            {
                "name": "قميص",
                "variants": [
                    {
                        "sku": "SH-S",
                        "unit_price": "30.00",
                        "is_default": True,
                        "option_values": [self.small.pk],
                        "opening_quantity": "12",
                        "opening_unit_cost": "18.00",
                    },
                    {
                        "sku": "SH-L",
                        "unit_price": "35.00",
                        "option_values": [self.large.pk],
                        "opening_quantity": "5",
                        "opening_unit_cost": "21.00",
                    },
                ],
            },
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_201_CREATED)
        small = ProductVariant.objects.get(sku="SH-S")
        large = ProductVariant.objects.get(sku="SH-L")
        self.assertEqual(
            StockItem.objects.get(variant=small).quantity_on_hand,
            Decimal("12.000"),
        )
        self.assertEqual(
            StockItem.objects.get(variant=large).quantity_on_hand,
            Decimal("5.000"),
        )
        costs = valuation_unit_costs([small.pk, large.pk])
        self.assertEqual(costs[small.pk], Decimal("18.000000"))
        self.assertEqual(costs[large.pk], Decimal("21.000000"))

    def test_one_row_may_open_while_another_does_not(self):
        response = self.client.post(
            reverse("product-list"),
            {
                "name": "بنطال",
                "variants": [
                    {
                        "sku": "PA-S",
                        "unit_price": "30.00",
                        "is_default": True,
                        "option_values": [self.small.pk],
                        "opening_quantity": "3",
                        "opening_unit_cost": "10.00",
                    },
                    {
                        "sku": "PA-L",
                        "unit_price": "35.00",
                        "option_values": [self.large.pk],
                    },
                ],
            },
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_201_CREATED)
        self.assertTrue(
            StockMovement.objects.filter(variant__sku="PA-S").exists()
        )
        self.assertFalse(
            StockMovement.objects.filter(variant__sku="PA-L").exists()
        )


class TrackedOpeningStockTests(TestCase):
    """A serialized product opened by hand is §6.1's shape: counted, on the
    missing-identifier worklist, and refused by the till until somebody scans
    it. Refusing the opening outright would leave the shelf holding goods the
    system says are not there."""

    def setUp(self):
        ensure_role_groups()
        self.client = APIClient()
        self.user = get_user_model().objects.create_user(
            username="opening-tracked", password="pass"
        )
        self.user.groups.add(Group.objects.get(name=MANAGER_GROUP))
        self.client.force_authenticate(user=self.user)

    def test_a_serialized_product_opens_into_unidentified_units(self):
        response = self.client.post(
            reverse("product-list"),
            {
                "name": "هاتف",
                "tracking_mode": Product.TrackingMode.SERIAL,
                "default_variant": {
                    "sku": "PH-1",
                    "unit_price": "900.00",
                    "opening_quantity": "3",
                    "opening_unit_cost": "700.00",
                },
            },
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_201_CREATED)
        variant = ProductVariant.objects.get(sku="PH-1")
        units = StockUnit.objects.filter(variant=variant)
        self.assertEqual(units.count(), 3)
        self.assertFalse(units.filter(is_identified=True).exists())
        # And each one carries the cost that was typed, not an invented one.
        self.assertEqual(
            {unit.incoming_rate for unit in units}, {Decimal("700.000000")}
        )
