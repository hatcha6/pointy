"""``orders/?product=`` (the product page's recent sales) is a semi-join.

Field data: this list had p95 8.2 s and max 17.5 s (73% database time) — the
filter joined every line of the product and de-duplicated the whole result with
DISTINCT, and the page header COUNTed it the same way. ``id IN (lines of this
product)`` returns each order once by construction and lets the planner stop at
the page.
"""

from decimal import Decimal

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group
from django.db import connection
from django.test import TestCase
from django.test.utils import CaptureQueriesContext
from django.urls import reverse
from rest_framework.test import APIClient

from apps.catalog.testing import create_product_with_default_variant
from apps.core.roles import MANAGER_GROUP, ensure_role_groups

from .models import Order, OrderLine


class OrderProductFilterTests(TestCase):
    def setUp(self):
        ensure_role_groups()
        self.client = APIClient()
        user = get_user_model().objects.create_user(username="m", password="p")
        user.groups.add(Group.objects.get(name=MANAGER_GROUP))
        self.client.force_authenticate(user)
        self.product = create_product_with_default_variant(
            name="Tea", sku="TEA", unit_price=Decimal("5.00")
        )
        self.other = create_product_with_default_variant(
            name="Sugar", sku="SUG", unit_price=Decimal("2.00")
        )
        self.two_lines = self._paid_order([self.product, self.product])
        self.one_line = self._paid_order([self.product, self.other])
        self.unrelated = self._paid_order([self.other])

    def _paid_order(self, products):
        order = Order.objects.create(status=Order.Status.PAID, subtotal=5, total=5)
        for product in products:
            OrderLine.objects.create(
                order=order,
                variant=product.default_variant,
                quantity=Decimal("1"),
                unit_price=Decimal("5.00"),
            )
        return order

    def test_each_order_appears_once_without_distinct(self):
        with CaptureQueriesContext(connection) as context:
            response = self.client.get(
                reverse("order-list"), {"product": self.product.pk, "ordering": "-created_at"}
            )
        self.assertEqual(response.status_code, 200, response.data)
        self.assertEqual(
            sorted(row["id"] for row in response.data["results"]),
            sorted([self.two_lines.pk, self.one_line.pk]),
        )
        self.assertEqual(response.data["count"], 2)
        for query in context.captured_queries:
            self.assertNotIn("DISTINCT", query["sql"].upper().replace("COUNT(DISTINCT", "COUNT("))

    def test_variant_filter_uses_the_same_shape(self):
        response = self.client.get(
            reverse("order-list"), {"variant": self.other.default_variant.pk}
        )
        self.assertEqual(response.status_code, 200, response.data)
        self.assertEqual(
            sorted(row["id"] for row in response.data["results"]),
            sorted([self.one_line.pk, self.unrelated.pk]),
        )
