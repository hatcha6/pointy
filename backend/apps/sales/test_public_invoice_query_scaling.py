"""The public (relayed) invoice page must not query once per line.

``PublicInvoiceLineSerializer`` renders ``variant.display_name``, which falls
back to ``option_values_label`` — a query per line — for a variant with no
explicit name. ``PublicInvoiceView`` builds its own queryset rather than
reusing ``OrderViewSet``'s, so it needs its own option-value prefetch. This
test pins the cost flat and asserts the rendered labels are unchanged.
"""

from decimal import Decimal

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
from apps.core.models import ShopSettings

from .models import Order, OrderLine


class PublicInvoiceQueryScalingTests(TestCase):
    def setUp(self):
        self.client = APIClient()
        ShopSettings.load()
        ShopSettings.objects.filter(pk=1).update(enable_online_invoices=True)
        self.product = create_product_with_default_variant(
            sku="PUB-1",
            name="قميص",
            unit_price=Decimal("20.00"),
        )
        self.color = VariantOption.objects.create(code="pub-color", name="اللون")
        self.product.variant_options.add(self.color)
        self.order = Order.objects.create(
            status=Order.Status.PAID,
            subtotal=Decimal("0.00"),
            total=Decimal("0.00"),
        )

    def _add_line(self, index):
        # No explicit variant ``name``: display_name falls through to the option
        # label, which is the branch that queries. The option-value combination
        # is unique per product, so each variant gets its own value.
        value = VariantOptionValue.objects.create(
            option=self.color,
            code=f"shade-{index}",
            name=f"لون {index}",
        )
        variant = ProductVariant.objects.create(
            product=self.product,
            sku=f"PUB-1-{index}",
            unit_price=Decimal("22.00"),
        )
        variant.option_values.set([value])
        OrderLine.objects.create(
            order=self.order,
            variant=variant,
            quantity=Decimal("1"),
            unit_price=Decimal("22.00"),
        )

    def _query_count(self):
        url = reverse("public-invoice-detail", args=[self.order.public_token])
        # Warm the shop-settings / content-type caches first: their queries land
        # on whichever request runs first and would otherwise inflate the smaller
        # measurement and hide the per-line slope.
        self.assertEqual(
            self.client.get(url, HTTP_X_POINTY_RELAYED_REQUEST="1").status_code,
            200,
        )
        with CaptureQueriesContext(connection) as queries:
            response = self.client.get(url, HTTP_X_POINTY_RELAYED_REQUEST="1")
        self.assertEqual(response.status_code, 200)
        return len(queries), response.data

    def test_public_invoice_does_not_scale_with_line_count(self):
        for index in range(3):
            self._add_line(index)
        small_count, small_body = self._query_count()
        for index in range(3, 9):
            self._add_line(index)
        large_count, large_body = self._query_count()

        self.assertEqual(len(small_body["lines"]), 3)
        self.assertEqual(len(large_body["lines"]), 9)
        self.assertEqual(
            small_count,
            large_count,
            f"public invoice scales with lines: {small_count} at 3, {large_count} at 9",
        )
        self.assertEqual(
            sorted(line["variant_name"] for line in large_body["lines"]),
            sorted(f"اللون: لون {index}" for index in range(9)),
        )
