"""Regression tests: purchase-order create and edit must not re-query per line.

Field telemetry (v0.4.2, one shop, one week) measured ``purchaseorder-detail``
PATCH at a mean of 903 queries and up to 2,151 (8 s), ``purchaseorder-list``
POST up to 1,090 and ``purchaseorder-receive`` up to 1,286. Reproduced on a
20-line order (Postgres, warm caches) and read query by query:

* the RESPONSE was the bulk of it — the service hands back the row it locked,
  bare, so serializing it re-ran the receipt/adjustment aggregates behind
  ``accepted_quantity`` & co. and re-read variant, product and option values
  for every line (~20 queries per line); the viewset now re-reads the order
  through its detail queryset before serializing, exactly as ``receive`` does;
* the edit-while-submitted / edit-while-received paths locked, updated and
  journalled stock one line at a time (a savepoint per line from
  ``get_or_create``); they now lock the whole order's rows in one statement
  and write the movements in one batch, like the receive path;
* the lines were inserted one by one, then ``recalculate`` saved each line
  twice (net figures, then landed costs); now one ``bulk_create`` and one
  ``bulk_update``;
* validation fetched every line's product and base unit-of-measure separately.

* validation fetched every line's product and base unit-of-measure separately,
  and the cost guard looked up each line's previous purchase on its own;
* receiving asked each line's receipt totals three aggregates at a time — the
  locked rows now double as the lines' prefetched relations, refreshed once
  after the receipt is written.

Measured after (20 lines, Postgres): create 583 -> 41, PATCH draft 601 -> 57,
PATCH submitted 819 -> 80, PATCH received 1342 -> 143 (the re-receive's only
per-line statement left is the receipt line INSERT). The bounds below leave
headroom for a query or two a line, not for the N+1 coming back.
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
from apps.catalog.testing import create_product_with_default_variant
from apps.core.roles import MANAGER_GROUP, ensure_role_groups
from apps.inventory.models import StockItem

from .models import Supplier

MAX_CREATE_QUERIES_PER_LINE = 2
MAX_DRAFT_EDIT_QUERIES_PER_LINE = 2
MAX_SUBMITTED_EDIT_QUERIES_PER_LINE = 3
# Unwind + re-receive: the receive half is inherently per line (see
# test_receive_query_scaling); this bounds everything around it.
MAX_RECEIVED_EDIT_QUERIES_PER_LINE = 10


@override_settings(
    CACHES={"default": {"BACKEND": "django.core.cache.backends.locmem.LocMemCache"}}
)
class PurchaseOrderEditQueryScalingTests(TestCase):
    def setUp(self):
        ensure_role_groups()
        self.client = APIClient()
        self.user = get_user_model().objects.create_user(username="buyer", password="p")
        self.user.groups.add(Group.objects.get(name=MANAGER_GROUP))
        self.client.force_authenticate(user=self.user)
        self.supplier = Supplier.objects.create(name="Edit-scaling supplier")
        # A category on every product: the discount engine reads each line's
        # categories, which was a query per line until they were prefetched.
        category = ProductCategory.objects.create(name="Edit scaling")
        self.variants = []
        for index in range(21):
            product = create_product_with_default_variant(
                sku=f"EDIT-SCALE-{index}",
                barcode="",
                name=f"Edit product {index}",
                unit_price=Decimal("2.00"),
            )
            product.categories.add(category)
            StockItem.objects.create(variant=product.default_variant, quantity_on_hand=0)
            self.variants.append(product.default_variant)

    def _lines(self, count, *, quantity=2, unit_cost="1.25"):
        return [
            {"variant": variant.pk, "quantity": quantity, "unit_cost": unit_cost}
            for variant in self.variants[:count]
        ]

    def _create(self, count):
        response = self.client.post(
            reverse("purchaseorder-list"),
            {"supplier": self.supplier.pk, "lines": self._lines(count)},
            format="json",
        )
        self.assertEqual(response.status_code, 201, response.data)
        return response.data["id"]

    def _patch(self, order_id, count, **line_kwargs):
        response = self.client.patch(
            reverse("purchaseorder-detail", args=[order_id]),
            {"lines": self._lines(count, **line_kwargs)},
            format="json",
        )
        self.assertEqual(response.status_code, 200, response.data)
        return response

    def _submit(self, order_id):
        response = self.client.post(reverse("purchaseorder-submit", args=[order_id]), format="json")
        self.assertEqual(response.status_code, 200, response.data)

    def _receive(self, order_id):
        response = self.client.post(reverse("purchaseorder-receive", args=[order_id]), format="json")
        self.assertEqual(response.status_code, 200, response.data)

    def _count(self, action):
        with CaptureQueriesContext(connection) as context:
            action()
        return len(context.captured_queries)

    def _slope(self, run):
        """Queries per extra line between a 1-line and a 20-line order, so the
        fixed cost of a request never masks (or fakes) a per-line one."""
        # Warm permission/content-type caches so the first measured request
        # does not pay for them.
        run(1)
        small = self._count(lambda: run(1))
        large = self._count(lambda: run(20))
        return (large - small) / 19

    def test_create_does_not_scale_per_line(self):
        self.assertLessEqual(self._slope(self._create), MAX_CREATE_QUERIES_PER_LINE)

    def test_draft_edit_does_not_scale_per_line(self):
        def run(count):
            self._patch(self._create(count), count, quantity=3)

        order_id = self._create(20)
        with CaptureQueriesContext(connection) as context:
            self._patch(order_id, 20, quantity=3)
        # The absolute number too: the response alone used to be ~20 a line.
        self.assertLess(len(context.captured_queries), 20 * 5)
        self.assertLessEqual(self._slope(run), MAX_DRAFT_EDIT_QUERIES_PER_LINE + MAX_CREATE_QUERIES_PER_LINE)

    def test_submitted_edit_rebuilds_expected_stock_in_batches(self):
        def run(count):
            order_id = self._create(count)
            self._submit(order_id)
            self._patch(order_id, count, quantity=4)

        expected_before = StockItem.objects.get(variant=self.variants[0]).quantity_expected
        # create + submit + edit; submit is out of scope but is itself batched.
        self.assertLessEqual(self._slope(run), MAX_SUBMITTED_EDIT_QUERIES_PER_LINE + MAX_CREATE_QUERIES_PER_LINE + 3)
        # Three orders were created and edited to quantity 4 along the way; the
        # batched rebuild must have registered each of them, not fewer.
        stock = StockItem.objects.get(variant=self.variants[0])
        self.assertEqual(stock.quantity_expected - expected_before, 3 * 4)

    def test_received_edit_re_records_the_delivery_in_batches(self):
        order_id = self._create(20)
        self._submit(order_id)
        self._receive(order_id)
        with CaptureQueriesContext(connection) as context:
            self._patch(order_id, 20, quantity=5, unit_cost="1.50")
        self.assertLessEqual(len(context.captured_queries) / 20, MAX_RECEIVED_EDIT_QUERIES_PER_LINE)
        stock = StockItem.objects.get(variant=self.variants[0])
        self.assertEqual(stock.quantity_on_hand, 5)
        self.assertEqual(stock.quantity_expected, 0)
