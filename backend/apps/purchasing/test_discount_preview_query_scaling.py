"""Regression test: the purchase discount preview must not re-query per line.

Field telemetry from the first client measured purchaseorder-discount-preview at
61 queries/call — against ~14 for the equivalent sales path — because every line
resolved its variant bare and then read ``variant.product``, that product's
categories (discount eligibility) and ``variant.display_name`` one line at a
time. The PO editor re-previews on every line edit, so the slope was paid on
every keystroke. The lines are now bulk-loaded once
(``catalog.services.preload_line_variants``); this test bounds the remaining
slope so a future change that reintroduces a per-line read fails loudly.
"""

from decimal import Decimal

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group
from django.db import connection
from django.test import TestCase, override_settings
from django.test.utils import CaptureQueriesContext
from django.urls import reverse
from rest_framework.test import APIClient

from apps.catalog.models import ProductCategory
from apps.catalog.services import MIN_LINES_TO_PRELOAD
from apps.catalog.testing import create_product_with_default_variant
from apps.core.roles import MANAGER_GROUP, ensure_role_groups
from apps.discounts.models import DiscountRule

from .models import Supplier

# The line ``variant`` field reads from a map the parent serializer primes in
# one query (it used to be DRF's own .get(pk=...) per line — 21 of the 28
# queries on a 20-line preview in the field). Nothing per line is left; the
# bound is zero so a single per-line read fails loudly.
MAX_QUERIES_PER_LINE = 0


@override_settings(
    CACHES={"default": {"BACKEND": "django.core.cache.backends.locmem.LocMemCache"}}
)
class PurchaseDiscountPreviewQueryScalingTests(TestCase):
    def setUp(self):
        ensure_role_groups()
        self.client = APIClient()
        self.user = get_user_model().objects.create_user(
            username="purchase-manager",
            password="pass",
        )
        self.user.groups.add(Group.objects.get(name=MANAGER_GROUP))
        self.client.force_authenticate(user=self.user)
        self.supplier = Supplier.objects.create(name="Scaling supplier")
        category = ProductCategory.objects.create(name="Scaling category")
        self.variants = []
        for index in range(11):
            product = create_product_with_default_variant(
                sku=f"PUR-SCALE-{index}",
                barcode="",
                name=f"Scaling product {index}",
                unit_price=Decimal("1.00"),
            )
            product.categories.add(category)
            self.variants.append(product.default_variant)

    def _measure(self, line_count):
        payload = {
            "supplier": self.supplier.pk,
            "lines": [
                {"variant": variant.pk, "quantity": 2, "unit_cost": "5.00"}
                for variant in self.variants[:line_count]
            ],
        }
        url = reverse("purchaseorder-discount-preview")
        # Warm the permission/content-type caches so the measurement reflects
        # steady state rather than first-request warmup.
        self.client.post(url, payload, format="json")
        with CaptureQueriesContext(connection) as ctx:
            response = self.client.post(url, payload, format="json")
        self.assertEqual(response.status_code, 200, response.data)
        self.assertEqual(len(response.data["lines"]), line_count)
        return len(ctx.captured_queries)

    def _assert_slope_is_bounded(self):
        # Below MIN_LINES_TO_PRELOAD the preload deliberately stays cold (a
        # lone line is cheaper unbatched), so measure from where the batch
        # shape applies — the slope is what is bounded, not that constant.
        small_count = max(2, MIN_LINES_TO_PRELOAD)
        small = self._measure(small_count)
        large = self._measure(11)
        slope = (large - small) / (11 - small_count)
        self.assertLessEqual(
            slope,
            MAX_QUERIES_PER_LINE,
            f"purchase discount preview scaled with lines: {small} -> {large} "
            f"queries ({slope} per line) — a per-line read is back",
        )

    def test_preview_query_count_barely_grows_with_lines(self):
        self._assert_slope_is_bounded()

    def test_preview_query_count_barely_grows_with_lines_under_active_rules(self):
        # The engine pass is a constant cost, but it reads the line categories
        # the preload provides — so measure the discounted path too.
        DiscountRule.objects.create(
            name="Supplier automatic",
            channel=DiscountRule.Channel.PURCHASING,
            value_type=DiscountRule.ValueType.PERCENTAGE,
            value=Decimal("10.00"),
            priority=1,
            exclusive=False,
        )
        self._assert_slope_is_bounded()
