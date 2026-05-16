from decimal import Decimal

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group
from django.test import TestCase
from django.urls import reverse
from rest_framework import status
from rest_framework.test import APIClient

from apps.catalog.models import Product
from apps.core.roles import CASHIER_GROUP, MANAGER_GROUP, ensure_role_groups
from .models import StockItem


class StockItemAuthorizationTests(TestCase):
    def setUp(self):
        ensure_role_groups()
        self.product = Product.objects.create(
            sku="AUTH-STOCK",
            name="مخزون",
            unit_price=Decimal("1.00"),
        )
        self.stock_item = StockItem.objects.create(
            product=self.product,
            quantity_on_hand=5,
            reorder_level=2,
        )

    def test_cashier_cannot_access_inventory_endpoints(self):
        cashier = get_user_model().objects.create_user(
            username="cashier",
            password="pass",
        )
        cashier.groups.add(Group.objects.get(name=CASHIER_GROUP))
        client = APIClient()
        client.force_authenticate(user=cashier)

        response = client.get(reverse("stockitem-list"))

        self.assertEqual(response.status_code, status.HTTP_403_FORBIDDEN)

    def test_manager_can_update_inventory(self):
        manager = get_user_model().objects.create_user(
            username="manager",
            password="pass",
        )
        manager.groups.add(Group.objects.get(name=MANAGER_GROUP))
        client = APIClient()
        client.force_authenticate(user=manager)

        response = client.patch(
            reverse("stockitem-detail", args=[self.stock_item.pk]),
            {"quantity_on_hand": 9},
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.stock_item.refresh_from_db()
        self.assertEqual(self.stock_item.quantity_on_hand, 9)
