"""The purchasing history endpoints must not query once per row.

``product-cost-history``, ``variant-cost-history`` and ``adjustment-history``
each render ``variant.display_name``, which falls back to
``option_values_label`` — a query per row — for any variant without an explicit
name. Both actions build their own queryset (they do not go through
``PurchaseOrderViewSet.queryset``, which does prefetch the option values), so
the prefetch has to be repeated there. These tests pin the cost flat AND assert
the label is unchanged.
"""

from decimal import Decimal

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group
from django.db import connection
from django.test import TestCase
from django.test.utils import CaptureQueriesContext
from django.urls import reverse
from rest_framework.test import APIClient

from apps.catalog.models import (
    ProductVariant,
    VariantOption,
    VariantOptionValue,
)
from apps.catalog.testing import create_product_with_default_variant
from apps.core.roles import MANAGER_GROUP, ensure_role_groups

from .models import (
    PurchaseLine,
    PurchaseOrder,
    PurchaseOrderAdjustment,
    PurchaseOrderAdjustmentLine,
    Supplier,
)


class PurchaseHistoryQueryScalingTests(TestCase):
    def setUp(self):
        ensure_role_groups()
        self.client = APIClient()
        self.user = get_user_model().objects.create_user(
            username="purchasing-manager",
            password="pass",
        )
        self.user.groups.add(Group.objects.get(name=MANAGER_GROUP))
        self.client.force_authenticate(user=self.user)

        self.supplier = Supplier.objects.create(name="مورد")
        self.product = create_product_with_default_variant(
            sku="HIST-1",
            name="قميص",
            unit_price=Decimal("20.00"),
        )
        self.color = VariantOption.objects.create(code="hist-color", name="اللون")
        self.product.variant_options.add(self.color)

    def _variant(self, index):
        # No explicit ``name``: display_name falls through to the option label,
        # which is the branch that queries. Each variant needs its own option
        # value — the combination is unique per product.
        value = VariantOptionValue.objects.create(
            option=self.color,
            code=f"shade-{index}",
            name=f"لون {index}",
        )
        variant = ProductVariant.objects.create(
            product=self.product,
            sku=f"HIST-1-{index}",
            unit_price=Decimal("22.00"),
        )
        variant.option_values.set([value])
        return variant

    def _seed_purchase_line(self, index):
        order = PurchaseOrder.objects.create(
            supplier=self.supplier,
            status=PurchaseOrder.Status.RECEIVED,
            subtotal=Decimal("10.00"),
            total=Decimal("10.00"),
        )
        return PurchaseLine.objects.create(
            purchase_order=order,
            variant=self._variant(index),
            quantity=Decimal("1"),
            unit_cost=Decimal("10.00"),
        )

    def _seed_adjustment_line(self, index):
        line = self._seed_purchase_line(index)
        adjustment = PurchaseOrderAdjustment.objects.create(
            purchase_order=line.purchase_order,
            adjustment_type=PurchaseOrderAdjustment.AdjustmentType.RETURN,
            amount=Decimal("10.00"),
            settlement_method=PurchaseOrderAdjustment.SettlementMethod.SUPPLIER_CREDIT,
            reason="مرتجع",
        )
        return PurchaseOrderAdjustmentLine.objects.create(
            adjustment=adjustment,
            purchase_line=line,
            variant=line.variant,
            quantity=Decimal("1"),
            unit_cost=Decimal("10.00"),
            line_amount=Decimal("10.00"),
        )

    def _query_count(self, url):
        # Warm the permission / content-type caches first: their queries land on
        # whichever request runs first and would otherwise inflate the smaller
        # measurement and hide the per-row slope.
        self.assertEqual(self.client.get(url).status_code, 200)
        with CaptureQueriesContext(connection) as queries:
            response = self.client.get(url)
        self.assertEqual(response.status_code, 200)
        return len(queries), response.data

    def test_cost_history_does_not_scale_with_line_count(self):
        url = (
            reverse("purchaseorder-product-cost-history")
            + f"?product={self.product.pk}"
        )
        for index in range(3):
            self._seed_purchase_line(index)
        small_count, small_body = self._query_count(url)
        for index in range(3, 9):
            self._seed_purchase_line(index)
        large_count, large_body = self._query_count(url)

        self.assertEqual(len(small_body["results"]), 3)
        self.assertEqual(len(large_body["results"]), 9)
        self.assertEqual(
            small_count,
            large_count,
            f"cost history scales with rows: {small_count} at 3, {large_count} at 9",
        )
        self.assertEqual(
            sorted(row["variant_name"] for row in large_body["results"]),
            sorted(f"اللون: لون {index}" for index in range(9)),
        )

    def test_adjustment_history_does_not_scale_with_line_count(self):
        url = reverse("purchaseorder-adjustment-history")
        for index in range(3):
            self._seed_adjustment_line(index)
        small_count, small_body = self._query_count(url)
        for index in range(3, 9):
            self._seed_adjustment_line(index)
        large_count, large_body = self._query_count(url)

        self.assertEqual(len(small_body["results"]), 3)
        self.assertEqual(len(large_body["results"]), 9)
        self.assertEqual(
            small_count,
            large_count,
            f"adjustment history scales with rows: {small_count} at 3, {large_count} at 9",
        )
        self.assertEqual(
            sorted(row["variant_name"] for row in large_body["results"]),
            sorted(f"اللون: لون {index}" for index in range(9)),
        )
