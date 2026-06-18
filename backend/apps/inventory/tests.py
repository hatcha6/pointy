from decimal import Decimal

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group
from django.core.exceptions import FieldError
from django.test import TestCase
from django.urls import reverse
from rest_framework import status
from rest_framework.exceptions import ValidationError
from rest_framework.test import APIClient

from apps.catalog.models import ProductVariant
from apps.catalog.testing import create_product_with_default_variant
from apps.core.roles import CASHIER_GROUP, MANAGER_GROUP, ensure_role_groups
from .models import StockItem, StockMovement
from .services import (
    create_stock_movement,
    lock_stock_item,
    stock_count_needs_review,
    stock_snapshot,
)


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

    def test_stock_models_reject_product_aliases(self):
        with self.assertRaises(TypeError):
            StockItem.objects.create(
                product=self.product,
                quantity_on_hand=1,
            )

        with self.assertRaises(TypeError):
            StockMovement.objects.create(
                product=self.product,
                stock_item=self.stock_item,
                movement_type=StockMovement.Type.INCREASE,
                quantity=1,
                on_hand_before=5,
                on_hand_after=6,
                committed_before=1,
                committed_after=1,
                expected_before=3,
                expected_after=3,
            )

        with self.assertRaises(FieldError):
            list(StockItem.objects.filter(product=self.product))

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


class StockServiceTests(TestCase):
    def setUp(self):
        self.product = create_product_with_default_variant(
            sku="SVC-STOCK",
            name="خدمة المخزون",
            unit_price=Decimal("2.00"),
        )
        self.variant = self.product.default_variant

    def test_stock_count_needs_review_ignores_zero_gap(self):
        self.assertFalse(
            stock_count_needs_review(
                expected=Decimal("10"),
                counted=Decimal("10"),
                min_units=Decimal("1"),
                percent=Decimal("10"),
            )
        )

    def test_stock_count_needs_review_ignores_gap_below_min_units(self):
        # gap 0.5 is below the one-unit absolute floor.
        self.assertFalse(
            stock_count_needs_review(
                expected=Decimal("100"),
                counted=Decimal("100.5"),
                min_units=Decimal("1"),
                percent=Decimal("1"),
            )
        )

    def test_stock_count_needs_review_flags_material_gap(self):
        # gap 20 clears the floor and 20% clears the 10% threshold.
        self.assertTrue(
            stock_count_needs_review(
                expected=Decimal("100"),
                counted=Decimal("80"),
                min_units=Decimal("1"),
                percent=Decimal("10"),
            )
        )

    def test_stock_count_needs_review_ignores_small_fraction(self):
        # gap 3 clears the floor but 3% is below the 10% threshold.
        self.assertFalse(
            stock_count_needs_review(
                expected=Decimal("100"),
                counted=Decimal("97"),
                min_units=Decimal("1"),
                percent=Decimal("10"),
            )
        )

    def test_stock_count_needs_review_uses_absolute_floor_when_expected_zero(self):
        # With nothing expected the percent rule can't apply, so the floor decides.
        self.assertTrue(
            stock_count_needs_review(
                expected=Decimal("0"),
                counted=Decimal("3"),
                min_units=Decimal("2"),
                percent=Decimal("10"),
            )
        )
        self.assertFalse(
            stock_count_needs_review(
                expected=Decimal("0"),
                counted=Decimal("1"),
                min_units=Decimal("2"),
                percent=Decimal("10"),
            )
        )

    def test_lock_stock_item_creates_when_missing(self):
        self.assertFalse(StockItem.objects.filter(variant=self.variant).exists())
        stock_item = lock_stock_item(variant=self.variant)
        self.assertIsNotNone(stock_item.pk)
        self.assertEqual(stock_item.quantity_on_hand, 0)

    def test_lock_stock_item_requires_variant(self):
        with self.assertRaises(ValidationError):
            lock_stock_item(variant=None)

    def test_create_stock_movement_ignores_non_positive_quantity(self):
        stock_item = StockItem.objects.create(
            variant=self.variant,
            quantity_on_hand=5,
        )
        before = stock_snapshot(stock_item)
        result = create_stock_movement(
            stock_item=stock_item,
            movement_type=StockMovement.Type.INCREASE,
            quantity=0,
            note="",
            created_by=None,
            before=before,
        )
        self.assertIsNone(result)
        self.assertEqual(StockMovement.objects.count(), 0)

    def test_create_stock_movement_records_before_and_after(self):
        stock_item = StockItem.objects.create(
            variant=self.variant,
            quantity_on_hand=5,
        )
        before = stock_snapshot(stock_item)
        stock_item.quantity_on_hand = 8
        movement = create_stock_movement(
            stock_item=stock_item,
            movement_type=StockMovement.Type.INCREASE,
            quantity=3,
            note="restock",
            created_by=None,
            before=before,
        )
        self.assertIsNotNone(movement)
        self.assertEqual(movement.on_hand_before, 5)
        self.assertEqual(movement.on_hand_after, 8)
        self.assertEqual(movement.quantity, 3)

    def test_create_stock_movement_rejects_variant_mismatch(self):
        stock_item = StockItem.objects.create(
            variant=self.variant,
            quantity_on_hand=5,
        )
        other_variant = create_product_with_default_variant(
            sku="SVC-OTHER",
            name="صنف آخر",
            unit_price=Decimal("1.00"),
        ).default_variant
        before = stock_snapshot(stock_item)
        with self.assertRaises(ValidationError):
            create_stock_movement(
                stock_item=stock_item,
                movement_type=StockMovement.Type.INCREASE,
                quantity=3,
                note="",
                created_by=None,
                before=before,
                variant=other_variant,
            )
