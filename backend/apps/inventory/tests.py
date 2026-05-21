from decimal import Decimal

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group
from django.test import TestCase
from django.urls import reverse
from rest_framework import status
from rest_framework.test import APIClient

from apps.catalog.models import ProductVariant
from apps.catalog.testing import create_product_with_default_variant
from apps.core.roles import CASHIER_GROUP, MANAGER_GROUP, ensure_role_groups
from .models import StockItem, StockMovement


class StockItemAuthorizationTests(TestCase):
    def setUp(self):
        ensure_role_groups()
        self.product = create_product_with_default_variant(
            sku="AUTH-STOCK",
            name="مخزون",
            unit_price=Decimal("1.00"),
        )
        self.variant = self.product.default_variant
        self.stock_item = StockItem.objects.create(
            variant=self.variant,
            quantity_on_hand=5,
            quantity_committed=1,
            quantity_expected=3,
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

    def test_manager_can_create_stock_movement_and_update_summary(self):
        manager = get_user_model().objects.create_user(
            username="movement-manager",
            password="pass",
        )
        manager.groups.add(Group.objects.get(name=MANAGER_GROUP))
        client = APIClient()
        client.force_authenticate(user=manager)

        response = client.post(
            reverse("stockmovement-list"),
            {
                "variant": self.variant.pk,
                "movement_type": StockMovement.Type.INCREASE,
                "quantity": 4,
                "note": "وردت من المورد",
            },
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_201_CREATED)
        self.stock_item.refresh_from_db()
        self.assertEqual(self.stock_item.quantity_on_hand, 9)
        self.assertEqual(response.data["on_hand_before"], 5)
        self.assertEqual(response.data["on_hand_after"], 9)
        self.assertEqual(response.data["created_by"], manager.pk)

    def test_stock_movement_records_and_displays_exact_variant(self):
        variant = ProductVariant.objects.create(
            product=self.product,
            name="Large",
            sku="AUTH-STOCK-L",
            unit_price=Decimal("1.50"),
        )
        stock_item = StockItem.objects.create(variant=variant, quantity_on_hand=2)
        manager = get_user_model().objects.create_user(
            username="variant-movement-manager",
            password="pass",
        )
        manager.groups.add(Group.objects.get(name=MANAGER_GROUP))
        client = APIClient()
        client.force_authenticate(user=manager)

        response = client.post(
            reverse("stockmovement-list"),
            {
                "variant": variant.pk,
                "movement_type": StockMovement.Type.INCREASE,
                "quantity": 3,
            },
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_201_CREATED)
        stock_item.refresh_from_db()
        self.assertEqual(stock_item.quantity_on_hand, 5)
        self.assertEqual(self.stock_item.quantity_on_hand, 5)
        self.assertEqual(response.data["variant"], variant.pk)
        self.assertEqual(response.data["variant_sku"], "AUTH-STOCK-L")
        self.assertEqual(response.data["variant_name"], "Large")
        self.assertEqual(response.data["variant_full_name"], "مخزون - Large")

    def test_stock_movement_cannot_make_stock_negative(self):
        manager = get_user_model().objects.create_user(
            username="negative-manager",
            password="pass",
        )
        manager.groups.add(Group.objects.get(name=MANAGER_GROUP))
        client = APIClient()
        client.force_authenticate(user=manager)

        response = client.post(
            reverse("stockmovement-list"),
            {
                "variant": self.variant.pk,
                "movement_type": StockMovement.Type.DECREASE,
                "quantity": 6,
            },
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.stock_item.refresh_from_db()
        self.assertEqual(self.stock_item.quantity_on_hand, 5)

    def test_cashier_cannot_create_stock_movement(self):
        cashier = get_user_model().objects.create_user(
            username="movement-cashier",
            password="pass",
        )
        cashier.groups.add(Group.objects.get(name=CASHIER_GROUP))
        client = APIClient()
        client.force_authenticate(user=cashier)

        response = client.post(
            reverse("stockmovement-list"),
            {
                "variant": self.variant.pk,
                "movement_type": StockMovement.Type.INCREASE,
                "quantity": 1,
            },
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_403_FORBIDDEN)
