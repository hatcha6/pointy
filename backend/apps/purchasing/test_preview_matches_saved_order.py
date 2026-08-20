"""The purchase-order preview owes the same per-line costs as the save.

The buyer approves a purchase order from the preview screen, so a preview that
quotes a different cost basis than the order it is about to write is a wrong
number in front of the person making the decision — even when the document-level
total agrees, which in every case here it does.

Each test states the expected figures as literals worked out from the payload's
own inputs, and only then checks the saved order against the same literals. The
preview is never asserted against the purchase order directly: two backend
surfaces agreeing proves nothing about either being right.
"""

from decimal import Decimal

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group
from django.test import TestCase
from django.urls import reverse
from rest_framework import status
from rest_framework.test import APIClient

from apps.catalog.testing import create_product_with_default_variant
from apps.core.roles import MANAGER_GROUP, ensure_role_groups

from .models import PurchaseOrder, Supplier


class PurchasePreviewMatchesSavedOrderTests(TestCase):
    def setUp(self):
        ensure_role_groups()
        self.client = APIClient()
        user = get_user_model().objects.create_user(
            username="preview-buyer",
            password="pass",
        )
        user.groups.add(Group.objects.get(name=MANAGER_GROUP))
        self.client.force_authenticate(user=user)
        self.supplier = Supplier.objects.create(name="Preview supplier")

    def _variants(self, count, unit_price):
        return [
            create_product_with_default_variant(
                sku=f"PRV-{index}",
                barcode="",
                name=f"Preview product {index}",
                unit_price=unit_price,
            ).default_variant
            for index in range(count)
        ]

    def _preview(self, payload):
        response = self.client.post(
            reverse("purchaseorder-discount-preview"), payload, format="json"
        )
        self.assertEqual(response.status_code, status.HTTP_200_OK, response.data)
        return response.data

    def _save(self, payload):
        response = self.client.post(
            reverse("purchaseorder-list"), payload, format="json"
        )
        self.assertEqual(response.status_code, status.HTTP_201_CREATED, response.data)
        order = PurchaseOrder.objects.get(pk=response.data["id"])
        return list(order.lines.order_by("pk"))

    def assert_both(self, payload, field, expected):
        """``expected`` is one value per line, in payload order."""
        preview_lines = self._preview(payload)["lines"]
        self.assertEqual(
            [line[field] for line in preview_lines],
            expected,
            f"preview {field}",
        )
        saved_lines = self._save(payload)
        self.assertEqual(
            [f"{getattr(line, field):.2f}" for line in saved_lines],
            expected,
            f"saved {field}",
        )

    def test_retail_value_allocation_with_every_variant_unpriced(self):
        """Landed costs still reach the lines when retail value weighs nothing.

        Three lines of ten units, all variants priced 0.00 — samples, or stock
        whose selling price is not set yet. Retail-value weights are therefore
        all zero, so the allocation falls back to quantity: 500.00 over 3 × 10
        units is 166.666... a line, floored to 166.66 (499.98), and the two
        leftover cents go to the first two lines on an all-equal remainder.
        Per unit that is 16.67, on top of a 1.00 net unit cost.
        """
        variants = self._variants(3, Decimal("0.00"))
        payload = {
            "supplier": self.supplier.pk,
            "landed_cost_allocation_method": "retail_value",
            "landed_cost_entries": [{"name": "جمارك", "amount": "500.00"}],
            "lines": [
                {"variant": variant.pk, "quantity": 10, "unit_cost": "1.00"}
                for variant in variants
            ],
        }
        self.assert_both(
            payload, "allocated_landed_cost", ["166.67", "166.67", "166.66"]
        )
        self.assert_both(
            payload, "effective_unit_cost", ["17.67", "17.67", "17.67"]
        )

    def test_equal_allocation_leftover_cents_settle_on_the_same_lines(self):
        """With twelve lines the tie-break decides, and it must decide alike.

        Equal weighting spreads 100.00 over 12 lines: 8.3333... each, floored to
        8.33 (99.96), leaving four cents. Every remainder is identical, so the
        cents go to the four lowest lines — indices 0..3. Keying the allocator on
        unpadded stringified indices sorted "10" and "11" ahead of "2" and "3",
        which put those cents on the last two lines of the preview and the third
        and fourth of the save.
        """
        variants = self._variants(12, Decimal("5.00"))
        payload = {
            "supplier": self.supplier.pk,
            "landed_cost_allocation_method": "equal",
            "landed_cost_entries": [{"name": "شحن", "amount": "100.00"}],
            "lines": [
                {"variant": variant.pk, "quantity": 1, "unit_cost": "1.00"}
                for variant in variants
            ],
        }
        self.assert_both(
            payload,
            "allocated_landed_cost",
            ["8.34"] * 4 + ["8.33"] * 8,
        )

    def test_net_unit_cost_on_a_half_cent_rounds_half_up(self):
        """4.00 less a 0.91 manual discount is 3.09 over two units — 1.545.

        PurchaseOrder.recalculate() rounds this one figure ROUND_HALF_UP, giving
        1.55. A bare quantize() in the preview rounds half-even to 1.54, so the
        buyer approved a unit cost a cent below the one that was written.
        """
        variant = self._variants(1, Decimal("9.00"))[0]
        payload = {
            "supplier": self.supplier.pk,
            "extra_discount_amount": "0.91",
            "lines": [{"variant": variant.pk, "quantity": 2, "unit_cost": "2.00"}],
        }
        self.assert_both(payload, "net_line_total", ["3.09"])
        self.assert_both(payload, "net_unit_cost", ["1.55"])
