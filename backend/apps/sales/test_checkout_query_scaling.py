"""Regression test: the checkout endpoint's query count must grow only with the
per-line writes it genuinely needs (order line insert, stock lock/update, stock
movement), NOT with the batchable per-line reads that used to dominate it.

Field telemetry from the first client showed order-checkout — the busiest write
path in the shop — averaging ~113 DB queries per sale because the per-line unit
cost, the discount category lookup and the response serialization all fired once
per cart line. Those were batched (see apps.sales.services.checkout_order and the
OrderViewSet.checkout response prefetch). This test bounds the marginal query
cost per extra line so a reintroduced read N+1 fails loudly.
"""

from decimal import Decimal

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group
from django.db import connection
from django.test import TestCase, override_settings
from django.test.utils import CaptureQueriesContext
from django.urls import reverse
from rest_framework.test import APIClient

from apps.catalog.testing import create_product_with_default_variant
from apps.core.roles import CASHIER_GROUP, ensure_role_groups
from apps.inventory.models import StockItem


# Per extra cart line the checkout still does a bounded, known set of writes and
# locks (insert the order line, lock + update the stock row, insert the stock
# movement) plus a little serializer validation. A reintroduced read N+1 (cost,
# discount categories, response lines) would push the marginal cost above this.
MAX_QUERIES_PER_EXTRA_LINE = 10


@override_settings(
    CACHES={"default": {"BACKEND": "django.core.cache.backends.locmem.LocMemCache"}}
)
class CheckoutQueryScalingTests(TestCase):
    _seq = 0

    def setUp(self):
        ensure_role_groups()
        self.client = APIClient()
        self.user = get_user_model().objects.create_user(username="c", password="p")
        self.user.groups.add(Group.objects.get(name=CASHIER_GROUP))
        self.client.force_authenticate(user=self.user)
        self.client.post(
            reverse("register-session-start"), {"opening_cash": "0.00"}, format="json"
        )

    def _variants(self, count):
        variants = []
        for _ in range(count):
            CheckoutQueryScalingTests._seq += 1
            i = CheckoutQueryScalingTests._seq
            product = create_product_with_default_variant(
                name=f"p{i}", sku=f"S{i}", unit_price="3.00", barcode=""
            )
            StockItem.objects.create(
                variant=product.default_variant, quantity_on_hand=Decimal("100")
            )
            variants.append(product.default_variant)
        return variants

    def _checkout_query_count(self, line_count):
        variants = self._variants(line_count)
        # Warm per-request caches so the measured request is steady-state.
        self.client.get(reverse("order-list"))
        payload = {
            "lines": [{"variant": v.pk, "quantity": 1} for v in variants],
            "payment_method": "cash",
            "amount_received": f"{3 * line_count}.00",
        }
        with CaptureQueriesContext(connection) as ctx:
            response = self.client.post(
                reverse("order-checkout"), payload, format="json"
            )
        self.assertEqual(response.status_code, 201, response.data)
        return len(ctx.captured_queries)

    def test_checkout_marginal_query_cost_per_line_is_bounded(self):
        small_lines, large_lines = 2, 8
        small = self._checkout_query_count(small_lines)
        large = self._checkout_query_count(large_lines)
        per_line = (large - small) / (large_lines - small_lines)
        self.assertLessEqual(
            per_line,
            MAX_QUERIES_PER_EXTRA_LINE,
            f"checkout does {per_line:.1f} queries per extra line "
            f"({small} at {small_lines} lines, {large} at {large_lines}); "
            "a per-line read N+1 was likely reintroduced.",
        )
