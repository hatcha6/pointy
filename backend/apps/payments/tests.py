from decimal import Decimal

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group
from django.test import TestCase
from django.urls import reverse
from rest_framework import status
from rest_framework.test import APIClient

from apps.catalog.testing import create_product_with_default_variant
from apps.core.roles import CASHIER_GROUP, MANAGER_GROUP, ensure_role_groups
from apps.inventory.models import StockItem, StockMovement
from apps.sales.models import Order, RegisterSession
from apps.sales.services import create_order_with_lines
from .models import Payment
from .serializers import PaymentSerializer


class PaymentAuthorizationTests(TestCase):
    def setUp(self):
        ensure_role_groups()
        User = get_user_model()
        self.cashier = User.objects.create_user(username="cashier", password="pass")
        self.other_cashier = User.objects.create_user(
            username="other-cashier",
            password="pass",
        )
        self.manager = User.objects.create_user(username="manager", password="pass")
        self.cashier.groups.add(Group.objects.get(name=CASHIER_GROUP))
        self.other_cashier.groups.add(Group.objects.get(name=CASHIER_GROUP))
        self.manager.groups.add(Group.objects.get(name=MANAGER_GROUP))

        self.cashier_order = self._create_order_for(self.cashier)
        self.other_order = self._create_order_for(self.other_cashier)
        Payment.objects.create(
            order=self.cashier_order,
            method=Payment.Method.CASH,
            amount=Decimal("4.00"),
        )
        Payment.objects.create(
            order=self.other_order,
            method=Payment.Method.CARD,
            amount=Decimal("6.00"),
        )

    def _create_order_for(self, user):
        owner_key = f"user:{user.pk}"
        session = RegisterSession.objects.create(owner=user, owner_key=owner_key)
        order = Order.objects.create(
            register_session=session,
            subtotal=Decimal("10.00"),
            total=Decimal("10.00"),
        )
        return order

    def test_cashier_only_lists_payments_for_owned_orders(self):
        client = APIClient()
        client.force_authenticate(user=self.cashier)

        response = client.get(reverse("payment-list"))

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(len(response.data["results"]), 1)
        self.assertEqual(response.data["results"][0]["order"], self.cashier_order.pk)

    def test_cashier_cannot_pay_another_cashiers_order(self):
        client = APIClient()
        client.force_authenticate(user=self.cashier)

        response = client.post(
            reverse("payment-list"),
            {
                "order": self.other_order.pk,
                "method": Payment.Method.CASH,
                "amount": "6.00",
            },
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertEqual(Payment.objects.filter(order=self.other_order).count(), 1)

    def test_payment_create_cannot_overpay_order(self):
        client = APIClient()
        client.force_authenticate(user=self.cashier)

        response = client.post(
            reverse("payment-list"),
            {
                "order": self.cashier_order.pk,
                "method": Payment.Method.CASH,
                "amount": "7.00",
            },
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertIn("amount", response.data)
        self.assertEqual(Payment.objects.filter(order=self.cashier_order).count(), 1)

    def test_manager_can_list_all_payments(self):
        client = APIClient()
        client.force_authenticate(user=self.manager)

        response = client.get(reverse("payment-list"))

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(len(response.data["results"]), 2)


class PaymentStockMovementTests(TestCase):
    def test_fully_paid_open_order_decrements_persisted_line_stock(self):
        product = create_product_with_default_variant(
            sku="PAY-STOCK",
            barcode="",
            name="Payment stock item",
            unit_price=Decimal("3.50"),
        )
        variant = product.default_variant
        stock_item = StockItem.objects.create(variant=variant, quantity_on_hand=5)
        session = RegisterSession.objects.create(owner_key="user:payment-stock")
        order = create_order_with_lines(
            register_session=session,
            lines_data=[{"variant": variant, "quantity": 2}],
        )

        serializer = PaymentSerializer(
            data={
                "order": order.pk,
                "method": Payment.Method.CASH,
                "amount": "7.00",
            }
        )
        serializer.is_valid(raise_exception=True)
        serializer.save()

        order.refresh_from_db()
        stock_item.refresh_from_db()
        self.assertEqual(order.status, Order.Status.PAID)
        self.assertEqual(stock_item.quantity_on_hand, 3)
        movement = StockMovement.objects.get()
        self.assertEqual(movement.movement_type, StockMovement.Type.DECREASE)
        self.assertEqual(movement.quantity, 2)
