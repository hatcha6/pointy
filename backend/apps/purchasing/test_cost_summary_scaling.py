"""``product-cost-summary`` must cost the same whatever a product's shape.

The endpoint behind the "Lowest / Highest / Last cost" metrics aggregated its
min/max/average in one grouped query but then asked for each variant's most
recent purchase line one variant at a time. The 2026-09-16 field export caught
it at 81 queries for a single product, against a median of 5.

Two things are pinned here, because they fail in different ways: the query
count must not grow with the number of variants, and the batched lookup must
still pick the same line the one-at-a-time helper picked — newest
``created_at``, ``-id`` breaking ties, never a cancelled order.
"""

from decimal import Decimal

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group
from django.db import connection
from django.test import TestCase
from django.test.utils import CaptureQueriesContext
from django.urls import reverse
from rest_framework.test import APIClient

from apps.catalog.models import Product, ProductVariant
from apps.core.roles import MANAGER_GROUP, ensure_role_groups
from apps.inventory.models import Warehouse

from .models import PurchaseLine, PurchaseOrder, Supplier
from .services import (
    latest_purchase_line_for_variant,
    latest_purchase_lines_for_variants,
)


class ProductCostSummaryScalingTests(TestCase):
    def setUp(self):
        ensure_role_groups()
        self.client = APIClient()
        user = get_user_model().objects.create_user(username="m", password="p")
        user.groups.add(Group.objects.get(name=MANAGER_GROUP))
        self.client.force_authenticate(user=user)
        self.warehouse = Warehouse.objects.first() or Warehouse.objects.create(
            name="main"
        )
        self.supplier = Supplier.objects.create(name="مورد", phone="0910000000")
        self.product = Product.objects.create(name="منتج", is_active=True)
        self._order_seq = 0

    def _variant(self, index):
        return ProductVariant.objects.create(
            product=self.product,
            name=f"v{index}",
            sku=f"CS-{index}",
            unit_price=Decimal("10"),
            is_active=True,
            is_default=(index == 0),
        )

    def _buy(self, variant, cost, *, status=None):
        self._order_seq += 1
        order = PurchaseOrder.objects.create(
            warehouse=self.warehouse,
            supplier=self.supplier,
            order_number=f"CS-PO-{self._order_seq:04d}",
            status=status or PurchaseOrder.Status.RECEIVED,
        )
        return PurchaseLine.objects.create(
            purchase_order=order,
            variant=variant,
            quantity=Decimal("1"),
            unit_cost=Decimal(cost),
        )

    def _measure(self, expected_variants):
        url = reverse("purchaseorder-product-cost-summary")
        params = {"product": self.product.pk}
        self.client.get(url, params)  # warm the per-request caches
        with CaptureQueriesContext(connection) as ctx:
            response = self.client.get(url, params)
        self.assertEqual(response.status_code, 200, response.content[:300])
        self.assertEqual(len(response.data), expected_variants)
        return len(ctx.captured_queries)

    def test_query_count_does_not_grow_with_variants(self):
        for index in range(3):
            self._buy(self._variant(index), "4.00")
        few = self._measure(expected_variants=3)
        for index in range(3, 12):
            self._buy(self._variant(index), "4.00")
        many = self._measure(expected_variants=12)
        self.assertEqual(
            few,
            many,
            "product-cost-summary scaled with variants: "
            f"{few} -> {many} queries for 3 -> 12 variants",
        )

    def test_last_cost_is_the_newest_non_cancelled_line_per_variant(self):
        first = self._variant(0)
        second = self._variant(1)
        self._buy(first, "4.00")
        newest_first = self._buy(first, "6.00")
        self._buy(first, "99.00", status=PurchaseOrder.Status.CANCELLED)
        self._buy(second, "7.00")
        newest_second = self._buy(second, "8.00")

        batched = latest_purchase_lines_for_variants([first.pk, second.pk])
        self.assertEqual(batched[first.pk].pk, newest_first.pk)
        self.assertEqual(batched[second.pk].pk, newest_second.pk)
        # And the batch agrees with the single-variant helper it replaced.
        for variant in (first, second):
            self.assertEqual(
                batched[variant.pk].pk,
                latest_purchase_line_for_variant(variant.pk).pk,
            )

        rows = {
            row["variant"]: row
            for row in self.client.get(
                reverse("purchaseorder-product-cost-summary"),
                {"product": self.product.pk},
            ).data
        }
        self.assertEqual(Decimal(rows[first.pk]["last_cost"]), Decimal("6.00"))
        self.assertEqual(Decimal(rows[second.pk]["last_cost"]), Decimal("8.00"))

    def test_a_variant_never_bought_reports_no_costs(self):
        bought = self._variant(0)
        never = self._variant(1)
        self._buy(bought, "4.00")
        self.assertEqual(latest_purchase_lines_for_variants([never.pk]), {})
        rows = {
            row["variant"]: row
            for row in self.client.get(
                reverse("purchaseorder-product-cost-summary"),
                {"product": self.product.pk},
            ).data
        }
        self.assertIsNone(rows[never.pk]["last_cost"])
        self.assertEqual(rows[never.pk]["purchases_count"], 0)
        self.assertEqual(Decimal(rows[bought.pk]["last_cost"]), Decimal("4.00"))

    def test_batched_lookup_handles_an_empty_request(self):
        self.assertEqual(latest_purchase_lines_for_variants([]), {})
        self.assertEqual(latest_purchase_lines_for_variants([None]), {})
