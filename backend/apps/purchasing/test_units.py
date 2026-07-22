from decimal import Decimal

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group
from django.test import TestCase
from django.urls import reverse
from rest_framework import status
from rest_framework.test import APIClient

from apps.catalog.models import ProductUnit, UnitOfMeasure
from apps.catalog.testing import create_product_with_default_variant
from apps.core.roles import MANAGER_GROUP, ensure_role_groups
from apps.inventory.models import StockItem
from apps.purchasing.models import PurchaseOrder
from apps.purchasing.services import (
    latest_product_unit_cost,
    latest_variant_unit_cost,
)


class PurchaseUnitTestCase(TestCase):
    """Shared fixture: a manager client and a Soda product purchasable by the
    carton of 24."""

    def setUp(self):
        ensure_role_groups()
        self.client = APIClient()
        self.user = get_user_model().objects.create_user(
            username="unit-purchaser", password="pass"
        )
        self.user.groups.add(Group.objects.get(name=MANAGER_GROUP))
        self.client.force_authenticate(user=self.user)

        self.product = create_product_with_default_variant(
            name="Soda", sku="SODA", unit_price="1.00"
        )
        self.variant = self.product.default_variant
        ProductUnit.objects.create(
            product=self.product,
            unit=UnitOfMeasure.objects.get(code="carton"),
            factor_to_base=Decimal("24"),
        )
        from apps.purchasing.models import Supplier

        self.supplier = Supplier.objects.create(name="Beverages Inc")


class PurchaseUnitTests(PurchaseUnitTestCase):

    def _create_order(self):
        return self.client.post(
            reverse("purchaseorder-list"),
            {
                "supplier": self.supplier.pk,
                "lines": [
                    {
                        "variant": self.variant.pk,
                        "quantity": 3,
                        "unit": "carton",
                        "unit_cost": "48.00",
                    }
                ],
            },
            format="json",
        )

    def test_pack_purchase_converts_to_base_units_through_lifecycle(self):
        StockItem.objects.create(variant=self.variant, quantity_on_hand=Decimal("0"))
        create_response = self._create_order()
        self.assertEqual(
            create_response.status_code, status.HTTP_201_CREATED, create_response.data
        )
        line = create_response.data["lines"][0]
        self.assertEqual(line["unit"], "carton")
        self.assertEqual(Decimal(line["unit_factor"]), Decimal("24"))
        self.assertEqual(Decimal(line["base_quantity"]), Decimal("72.000"))
        # 48 per carton ÷ 24 = 2.00 per base unit.
        self.assertEqual(Decimal(line["base_unit_cost"]), Decimal("2.00"))

        order_id = create_response.data["id"]
        submit_response = self.client.post(
            reverse("purchaseorder-submit", args=[order_id]), format="json"
        )
        self.assertEqual(submit_response.status_code, status.HTTP_200_OK)
        stock_item = StockItem.objects.get(variant=self.variant)
        # 3 cartons × 24 = 72 base units expected.
        self.assertEqual(stock_item.quantity_expected, Decimal("72.000"))

        receive_response = self.client.post(
            reverse("purchaseorder-receive", args=[order_id]), format="json"
        )
        self.assertEqual(receive_response.status_code, status.HTTP_200_OK)
        self.assertEqual(
            receive_response.data["status"], PurchaseOrder.Status.RECEIVED
        )
        stock_item = StockItem.objects.get(variant=self.variant)
        self.assertEqual(stock_item.quantity_on_hand, Decimal("72.000"))
        self.assertEqual(stock_item.quantity_expected, Decimal("0.000"))

    def test_cost_lookup_normalises_to_base_unit(self):
        StockItem.objects.create(variant=self.variant, quantity_on_hand=Decimal("0"))
        order_id = self._create_order().data["id"]
        self.client.post(reverse("purchaseorder-submit", args=[order_id]), format="json")
        self.client.post(reverse("purchaseorder-receive", args=[order_id]), format="json")
        self.assertEqual(latest_variant_unit_cost(self.variant.pk), Decimal("2.00"))

    def test_unpurchasable_unit_rejected(self):
        self.product.units.update(is_purchasable=False)
        response = self._create_order()
        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)


class PackCostNormalisationTests(PurchaseUnitTestCase):
    """A pack purchase (48 a carton of 24) must never surface as a per-piece
    cost anywhere costs meet the per-base-unit sale price — the bug class that
    turned a carton of eggs bought at 162 into a phantom 161-dinar-per-egg loss.
    """

    def _received_line(self, *, unit="", unit_factor="1", unit_cost, quantity="1"):
        """A received PO with one line, created directly (no API round-trip) —
        read-path tests only need the snapshots, not the stock bookkeeping."""
        order = PurchaseOrder.objects.create(
            supplier=self.supplier,
            status=PurchaseOrder.Status.RECEIVED,
        )
        return order.lines.create(
            variant=self.variant,
            quantity=Decimal(quantity),
            unit=unit,
            unit_factor=Decimal(unit_factor),
            unit_cost=Decimal(unit_cost),
        )

    def test_cost_summary_reports_pack_purchases_per_base_unit(self):
        self._received_line(unit="carton", unit_factor="24", unit_cost="48.00")
        self._received_line(unit_cost="2.10")

        response = self.client.get(
            reverse("purchaseorder-product-cost-summary"),
            {"product": self.product.pk},
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        summary = next(
            row for row in response.data if row["variant"] == self.variant.pk
        )
        # Carton line participates at 48/24 = 2.00, never at 48.
        self.assertEqual(Decimal(summary["lowest_cost"]), Decimal("2.00"))
        self.assertEqual(Decimal(summary["highest_cost"]), Decimal("2.10"))
        self.assertEqual(Decimal(summary["average_cost"]), Decimal("2.05"))
        self.assertEqual(Decimal(summary["last_cost"]), Decimal("2.10"))
        self.assertEqual(summary["purchases_count"], 2)

    def test_cost_summary_last_cost_normalises_a_latest_pack_line(self):
        self._received_line(unit_cost="2.10")
        self._received_line(unit="carton", unit_factor="24", unit_cost="48.00")

        response = self.client.get(
            reverse("purchaseorder-product-cost-summary"),
            {"product": self.product.pk},
        )

        summary = next(
            row for row in response.data if row["variant"] == self.variant.pk
        )
        self.assertEqual(Decimal(summary["last_cost"]), Decimal("2.00"))

    def test_margin_impact_normalises_mixed_pack_history(self):
        self.variant.unit_price = Decimal("2.50")
        self.variant.save(update_fields=["unit_price"])
        self._received_line(unit_cost="1.90")
        self._received_line(unit="carton", unit_factor="24", unit_cost="48.00")

        response = self.client.get(
            reverse("purchaseorder-variant-margin-impact"),
            {"variant": self.variant.pk},
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        data = response.data
        # 48-per-carton is 2.00 per piece → a healthy 0.50 margin, not −45.50.
        self.assertEqual(data["latest_unit_cost"], "2.00")
        self.assertEqual(data["latest_effective_unit_cost"], "2.00")
        self.assertEqual(data["latest_margin_amount"], "0.50")
        self.assertEqual(data["latest_margin_percent"], "20.00")
        self.assertEqual(data["previous_unit_cost"], "1.90")
        self.assertEqual(data["previous_margin_amount"], "0.60")
        self.assertEqual(data["unit_cost_delta"], "0.10")
        self.assertEqual(data["effective_unit_cost_delta"], "0.10")
        self.assertEqual(data["margin_amount_delta"], "-0.10")

    def test_line_previous_cost_is_expressed_in_the_lines_own_unit(self):
        self._received_line(unit_cost="2.00")
        carton_line = self._received_line(
            unit="carton", unit_factor="24", unit_cost="48.00"
        )

        response = self.client.get(
            reverse(
                "purchaseorder-detail", args=[carton_line.purchase_order_id]
            ),
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        line = response.data["lines"][0]
        # Last buy was loose pieces at 2.00 → 48.00 per carton of 24: same
        # price, so no change — not a fake +2300% spike.
        self.assertEqual(line["previous_unit_cost"], "48.00")
        self.assertEqual(line["unit_cost_change"], "0.00")
        self.assertFalse(line["unit_cost_changed"])

    def test_line_previous_cost_scales_a_pack_history_down_to_pieces(self):
        self._received_line(unit="carton", unit_factor="24", unit_cost="48.00")
        piece_line = self._received_line(unit_cost="2.10")

        response = self.client.get(
            reverse("purchaseorder-detail", args=[piece_line.purchase_order_id]),
        )

        line = response.data["lines"][0]
        self.assertEqual(line["previous_unit_cost"], "2.00")
        self.assertEqual(line["unit_cost_change"], "0.10")
        self.assertEqual(line["unit_cost_change_percent"], "5.00")
        self.assertTrue(line["unit_cost_changed"])

    def test_latest_product_unit_cost_normalises_packs(self):
        self._received_line(unit="carton", unit_factor="24", unit_cost="48.00")
        self.assertEqual(
            latest_product_unit_cost(self.product.pk), Decimal("2.00")
        )
        self.assertEqual(
            latest_variant_unit_cost(self.variant.pk), Decimal("2.00")
        )

    def test_cost_history_exposes_base_cost_and_pack_context(self):
        self._received_line(unit="carton", unit_factor="24", unit_cost="48.00")

        response = self.client.get(
            reverse("purchaseorder-variant-cost-history"),
            {"variant": self.variant.pk},
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        rows = response.data.get("results", response.data)
        row = rows[0]
        self.assertEqual(row["unit"], "carton")
        self.assertEqual(Decimal(row["unit_factor"]), Decimal("24"))
        self.assertEqual(row["base_unit_cost"], "2.00")
        self.assertEqual(row["effective_base_unit_cost"], "2.00")
        self.assertNotEqual(row["unit_label"], "")
