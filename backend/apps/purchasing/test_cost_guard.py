"""A purchase cost that is a typo must not become the cost of record.

The case these are written from, taken from a first client's database: on
2026-07-23 a cashier bought bread for cash at the till, paid 130 LYD for a stack
of loaves, and entered it as ``quantity 1 × unit_cost 130``. Bread sells for
1.00. Every one of the next 75 loaves sold booked a 129 LYD loss, and across all
products 348 such lines erased 54,537 LYD of gross margin — roughly eleven points
of the shop's revenue — from every report built on it. Nothing caught it: the
only loss guard in the product gates the *sale*, not the purchase.
"""

from decimal import Decimal

from django.test import override_settings
from django.urls import reverse
from rest_framework import status

from apps.catalog.models import ProductUnit, UnitOfMeasure

from .models import PurchaseOrder
from .test_pos_cash_purchase import PosCashPurchaseTestCase


class PosCashPurchaseCostGuardTests(PosCashPurchaseTestCase):
    """The POS path refuses, with no way to confirm past it.

    A cashier cannot judge whether 130.00 per loaf is plausible and has no
    permission to override, so an acknowledgement path here would just be a
    dialog people learn to dismiss.
    """

    def test_the_bread_typo_is_refused(self):
        self.open_session(self.cashier)

        response = self.post_purchase(
            lines=[
                {
                    "variant": self.variant.pk,
                    "quantity": "1",
                    "unit_cost": "130.00",  # the amount paid, typed as a unit cost
                }
            ]
        )

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        warnings = response.data["cost_warnings"]
        self.assertEqual(len(warnings), 1)
        self.assertEqual(warnings[0]["kind"], "above_sale_price")
        self.assertEqual(warnings[0]["base_unit_cost"], "130.00")
        self.assertEqual(warnings[0]["reference"], "0.50")
        self.assertEqual(warnings[0]["blocking"], "true")
        self.assertFalse(
            PurchaseOrder.objects.exists(),
            "the whole purchase must roll back, drawer pay-out included",
        )

    def test_acknowledging_does_not_get_past_the_pos_guard(self):
        """The escape hatch on the purchasing screen must not exist here."""
        self.open_session(self.cashier)

        response = self.post_purchase(
            acknowledge_cost_warnings=True,
            lines=[
                {
                    "variant": self.variant.pk,
                    "quantity": "1",
                    "unit_cost": "130.00",
                }
            ],
        )

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertFalse(PurchaseOrder.objects.exists())

    def test_the_same_purchase_entered_correctly_goes_through(self):
        """290 loaves at 1.00 is the same 290 LYD and must not be obstructed."""
        self.open_session(self.cashier, opening_cash=Decimal("400.00"))

        response = self.post_purchase(
            lines=[
                {
                    "variant": self.variant.pk,
                    "quantity": "290",
                    "unit_cost": "0.40",
                }
            ]
        )

        self.assertEqual(response.status_code, status.HTTP_201_CREATED, response.data)

    def test_a_thin_margin_cash_purchase_still_goes_through(self):
        """The blocking threshold is looser than the warning one on purpose: a
        cashier must not be stopped from a real purchase they cannot override."""
        self.open_session(self.cashier)

        response = self.post_purchase(
            lines=[
                {
                    "variant": self.variant.pk,
                    "quantity": "10",
                    # Above the 0.50 sale price, but nothing like a typo.
                    "unit_cost": "0.60",
                }
            ]
        )

        self.assertEqual(response.status_code, status.HTTP_201_CREATED, response.data)

    def test_a_pack_cost_is_judged_per_base_unit(self):
        """The comparison only means anything on the base-unit scale — a
        162-per-carton egg line is 0.45 an egg, not a 161-dinar loss."""
        self.open_session(self.cashier, opening_cash=Decimal("500.00"))
        carton = UnitOfMeasure.objects.create(
            code="pos-carton", name="Carton", abbreviation="ctn"
        )
        ProductUnit.objects.create(
            product=self.product,
            unit=carton,
            factor_to_base=Decimal("100"),
            is_purchasable=True,
        )

        response = self.post_purchase(
            lines=[
                {
                    "variant": self.variant.pk,
                    "quantity": "1",
                    "unit": "pos-carton",
                    "unit_cost": "40.00",  # = 0.40 a loaf against a 0.50 price
                }
            ]
        )

        self.assertEqual(response.status_code, status.HTTP_201_CREATED, response.data)


class PurchasingScreenCostGuardTests(PosCashPurchaseTestCase):
    """The purchasing screen warns and lets the buyer confirm.

    Clearance stock, a supplier price rise before the shelf price catches up, a
    deliberate loss leader — all real. A manager entering one should be asked,
    not blocked.
    """

    def create_order(self, unit_cost, **extra):
        payload = {
            "supplier": self.supplier.pk,
            "lines": [
                {
                    "variant": self.variant.pk,
                    "quantity": "10",
                    "unit_cost": unit_cost,
                }
            ],
        }
        payload.update(extra)
        return self.manager_client.post(
            reverse("purchaseorder-list"), payload, format="json"
        )

    def test_an_extreme_cost_is_held_for_confirmation(self):
        response = self.create_order("130.00")

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertEqual(response.data["cost_warnings"][0]["blocking"], "false")
        self.assertIn("cost_warnings", response.data)
        # Per-line shape too, so a plain DRF client still renders something.
        self.assertIn("unit_cost", response.data["lines"][0])
        self.assertFalse(PurchaseOrder.objects.exists())

    def test_confirming_lets_it_through(self):
        response = self.create_order("130.00", acknowledge_cost_warnings=True)

        self.assertEqual(response.status_code, status.HTTP_201_CREATED, response.data)
        self.assertEqual(PurchaseOrder.objects.count(), 1)

    def test_an_ordinary_cost_is_never_questioned(self):
        response = self.create_order("0.30")

        self.assertEqual(response.status_code, status.HTTP_201_CREATED, response.data)

    def test_a_cost_spike_is_caught_even_when_the_price_is_unset(self):
        """The price comparison misses an unpriced product entirely; the cost
        history is what catches a typo there."""
        self.variant.unit_price = Decimal("0.00")
        self.variant.save(update_fields=["unit_price"])
        first = self.create_order("1.00")
        self.assertEqual(first.status_code, status.HTTP_201_CREATED, first.data)

        response = self.create_order("130.00")

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertEqual(response.data["cost_warnings"][0]["kind"], "cost_spike")
        self.assertEqual(response.data["cost_warnings"][0]["reference"], "1.00")

    def test_a_first_purchase_of_an_unpriced_product_is_not_questioned(self):
        """Nothing to compare against is not the same as something wrong."""
        self.variant.unit_price = Decimal("0.00")
        self.variant.save(update_fields=["unit_price"])

        response = self.create_order("42.00")

        self.assertEqual(response.status_code, status.HTTP_201_CREATED, response.data)

    def test_a_thin_margin_is_not_worth_warning_about(self):
        """Calibrated against the field data: every real typo was 5x or worse,
        while the items genuinely sold below cost sat at 1.1-1.8x. Warning about
        those would only teach buyers to click through."""
        response = self.create_order("0.80")  # 1.6x the 0.50 price

        self.assertEqual(response.status_code, status.HTTP_201_CREATED, response.data)

    @override_settings(POINTY_PURCHASE_COST_WARN_PRICE_RATIO=100.0)
    def test_the_threshold_is_tunable(self):
        response = self.create_order("5.00")

        self.assertEqual(response.status_code, status.HTTP_201_CREATED, response.data)
