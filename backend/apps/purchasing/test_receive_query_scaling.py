"""Regression test: the purchase-order detail payload must not re-query per line.

Field telemetry from the first client measured ``purchaseorder-receive`` at 266
queries/call. Roughly half of that was the *response*: the lifecycle actions
handed the detail serializer an order loaded bare (the service locks it with
``select_for_update().get(...)``, and ``refresh_from_db()`` drops any prefetch
cache), so every nested line, receipt line, adjustment and variant re-queried one
row at a time. The same shape was on plain ``retrieve`` — ``lines__adjustment_lines``
and the variants' ``option_values`` were simply missing from the prefetch tree,
costing ~4 queries per line on the PO details screen.

The last per-line read was ``PurchaseLineSerializer._previous_base_unit_cost``
(the "cost changed" flag), resolved two ways: ``previous_purchase_lines_for``
batches it into two queries for any caller handing the serializer bare rows (see
``test_previous_unit_cost_primer``), and ``previous_purchase_line_annotations``
carries it on rows read through the detail queryset for free (see
``test_previous_cost_annotation``). The primer fills from the annotation when it
is there, so the paths compose rather than both charging.

Measured on a 20-line order (sqlite, warm caches):

    receive endpoint   920 -> 467 -> 449 -> 447 -> 83 queries  (43.0 -> 21.0 -> 20.1 -> 20.0 -> 3.2/line)
    retrieve           123 ->  43 ->  25 ->  23 queries  ( 5.0 ->  1.0 -> 0.05 ->  0.0/line)

The remaining receive slope is the write path itself (stock movement + receipt
line per line, plus the receipt-quantity aggregates the service must re-read
after each write); retrieve is now flat in the line count and pays nothing for
the previous-cost fields. These bounds guard the serialization side so a dropped
prefetch, annotation or primer fails loudly rather than quietly restoring the
N+1.
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
from apps.core.roles import MANAGER_GROUP, ensure_role_groups
from apps.inventory.models import StockItem

from .models import Supplier

# The receive write path keeps one statement per line: the receipt line INSERT.
# The receipt-quantity reads answer from the rows the lock already fetched
# (refreshed once after the receipt is written), and the stock rows are locked
# and written back as one batch. Measured 20.0 -> 3.2 per line.
MAX_RECEIVE_QUERIES_PER_LINE = 5
# Nothing per-line is left on a detail read, and with the previous-cost columns
# annotated onto the prefetch the primer's second query is gone too. Measured
# exactly 0.0 — a bound of zero is the point: at 1 the N+1 this file exists to
# guard could come back unnoticed.
MAX_RETRIEVE_QUERIES_PER_LINE = 0


@override_settings(
    CACHES={"default": {"BACKEND": "django.core.cache.backends.locmem.LocMemCache"}}
)
class PurchaseOrderDetailQueryScalingTests(TestCase):
    def setUp(self):
        ensure_role_groups()
        self.client = APIClient()
        self.user = get_user_model().objects.create_user(
            username="receiving-manager",
            password="pass",
        )
        self.user.groups.add(Group.objects.get(name=MANAGER_GROUP))
        self.client.force_authenticate(user=self.user)
        self.supplier = Supplier.objects.create(name="Scaling supplier")
        self.variants = []
        for index in range(21):
            product = create_product_with_default_variant(
                sku=f"RECV-SCALE-{index}",
                barcode="",
                name=f"Receiving product {index}",
                unit_price=Decimal("2.00"),
            )
            StockItem.objects.create(
                variant=product.default_variant,
                quantity_on_hand=0,
            )
            self.variants.append(product.default_variant)

    def _submitted_order(self, line_count):
        response = self.client.post(
            reverse("purchaseorder-list"),
            {
                "supplier": self.supplier.pk,
                "lines": [
                    {"variant": variant.pk, "quantity": 2, "unit_cost": "1.25"}
                    for variant in self.variants[:line_count]
                ],
            },
            format="json",
        )
        self.assertEqual(response.status_code, 201, response.data)
        order_id = response.data["id"]
        submit = self.client.post(
            reverse("purchaseorder-submit", args=[order_id]),
            format="json",
        )
        self.assertEqual(submit.status_code, 200, submit.data)
        return order_id

    def _receive(self, order_id):
        response = self.client.post(
            reverse("purchaseorder-receive", args=[order_id]),
            format="json",
        )
        self.assertEqual(response.status_code, 200, response.data)
        return response

    def test_receiving_does_not_scale_the_response_payload_per_line(self):
        # Warm the permission/content-type caches first, or the first request
        # pays for them and the slope reads low.
        self._receive(self._submitted_order(1))

        small_order = self._submitted_order(1)
        with CaptureQueriesContext(connection) as small:
            small_response = self._receive(small_order)
        large_order = self._submitted_order(20)
        with CaptureQueriesContext(connection) as large:
            large_response = self._receive(large_order)

        # The payload itself is unchanged — re-reading through the prefetch-rich
        # queryset is a serialization detail, not a contract change.
        self.assertEqual(len(small_response.data["lines"]), 1)
        self.assertEqual(len(large_response.data["lines"]), 20)
        self.assertEqual(large_response.data["status"], "received")

        slope = (len(large) - len(small)) / 19
        self.assertLessEqual(
            slope,
            MAX_RECEIVE_QUERIES_PER_LINE,
            f"receive costs {slope:.1f} queries per line "
            f"({len(small)} for 1 line, {len(large)} for 20)",
        )

    def test_retrieving_a_received_order_does_not_scale_per_line(self):
        small_order = self._submitted_order(1)
        self._receive(small_order)
        large_order = self._submitted_order(20)
        self._receive(large_order)
        small_url = reverse("purchaseorder-detail", args=[small_order])
        large_url = reverse("purchaseorder-detail", args=[large_order])
        self.client.get(small_url)  # warm caches

        with CaptureQueriesContext(connection) as small:
            small_response = self.client.get(small_url)
        with CaptureQueriesContext(connection) as large:
            large_response = self.client.get(large_url)

        self.assertEqual(small_response.status_code, 200)
        self.assertEqual(len(large_response.data["lines"]), 20)

        slope = (len(large) - len(small)) / 19
        self.assertLessEqual(
            slope,
            MAX_RETRIEVE_QUERIES_PER_LINE,
            f"retrieve costs {slope:.1f} queries per line "
            f"({len(small)} for 1 line, {len(large)} for 20)",
        )
