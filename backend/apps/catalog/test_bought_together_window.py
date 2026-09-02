"""The "bought together" panel ranks recent baskets, and a bounded number.

Field data: ``products/<id>/bought-together`` reached 18 s (p95 9.9 s, 83%
database time) because it first collected up to 50,000 order ids for the
product across the shop's whole history. It now looks at paid orders inside a
window and at most the newest N of them.
"""

from datetime import timedelta
from decimal import Decimal
from unittest import mock

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group
from django.test import TestCase
from django.urls import reverse
from django.utils import timezone
from rest_framework.test import APIClient

from apps.catalog.testing import create_product_with_default_variant
from apps.core.roles import MANAGER_GROUP, ensure_role_groups
from apps.sales.models import Order, OrderLine


class BoughtTogetherWindowTests(TestCase):
    def setUp(self):
        ensure_role_groups()
        self.client = APIClient()
        user = get_user_model().objects.create_user(username="m", password="p")
        user.groups.add(Group.objects.get(name=MANAGER_GROUP))
        self.client.force_authenticate(user)
        self.tea = create_product_with_default_variant(name="Tea", sku="TEA", unit_price=Decimal("5"))
        self.sugar = create_product_with_default_variant(name="Sugar", sku="SUG", unit_price=Decimal("2"))
        self.milk = create_product_with_default_variant(name="Milk", sku="MLK", unit_price=Decimal("3"))

    def _basket(self, products, *, days_ago=0):
        order = Order.objects.create(status=Order.Status.PAID, subtotal=5, total=5)
        for product in products:
            OrderLine.objects.create(
                order=order,
                variant=product.default_variant,
                quantity=Decimal("1"),
                unit_price=Decimal("1.00"),
            )
        if days_ago:
            Order.objects.filter(pk=order.pk).update(
                created_at=timezone.now() - timedelta(days=days_ago)
            )
        return order

    def _ranked(self):
        response = self.client.get(reverse("product-bought-together", args=[self.tea.pk]))
        self.assertEqual(response.status_code, 200, response.data)
        return [(row["id"], row["orders_together"]) for row in response.data["results"]]

    def test_baskets_outside_the_window_are_ignored(self):
        self._basket([self.tea, self.sugar])
        self._basket([self.tea, self.milk], days_ago=400)
        self._basket([self.tea, self.milk], days_ago=401)
        self.assertEqual(self._ranked(), [(self.sugar.pk, 1)])

    def test_only_the_newest_baskets_are_ranked(self):
        self._basket([self.tea, self.milk], days_ago=3)
        self._basket([self.tea, self.milk], days_ago=2)
        self._basket([self.tea, self.sugar], days_ago=1)
        with mock.patch("apps.catalog.views.BOUGHT_TOGETHER_MAX_ORDERS", 1):
            self.assertEqual(self._ranked(), [(self.sugar.pk, 1)])
