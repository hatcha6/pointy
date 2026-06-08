import base64
import json
import zlib
from decimal import Decimal
from urllib.parse import quote

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group
from django.test import TestCase
from django.urls import reverse
from rest_framework import status
from rest_framework.test import APIClient

from apps.catalog.testing import create_product_with_default_variant
from apps.core.models import ShopSettings
from apps.core.roles import CASHIER_GROUP, MANAGER_GROUP, ensure_role_groups
from apps.inventory.models import StockItem, StockMovement
from apps.sales.models import Order, RegisterSession
from apps.sales.services import create_order_with_lines
from .models import Payment
from .moamalat import parse_moamalat_receipt_url
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

    def test_payment_create_replay_with_idempotency_key_returns_same_payment(self):
        client = APIClient()
        client.force_authenticate(user=self.cashier)
        payload = {
            "order": self.cashier_order.pk,
            "method": Payment.Method.CASH,
            "amount": "2.00",
        }

        first_response = client.post(
            reverse("payment-list"),
            payload,
            format="json",
            HTTP_IDEMPOTENCY_KEY="payment-retry-1",
        )
        second_response = client.post(
            reverse("payment-list"),
            payload,
            format="json",
            HTTP_IDEMPOTENCY_KEY="payment-retry-1",
        )

        self.assertEqual(first_response.status_code, status.HTTP_201_CREATED)
        self.assertEqual(second_response.status_code, status.HTTP_201_CREATED)
        self.assertEqual(first_response["Idempotency-Replayed"], "false")
        self.assertEqual(second_response["Idempotency-Replayed"], "true")
        self.assertEqual(first_response.data["id"], second_response.data["id"])
        self.assertEqual(Payment.objects.filter(order=self.cashier_order).count(), 2)

    def test_payment_create_rejects_key_reused_with_different_body(self):
        client = APIClient()
        client.force_authenticate(user=self.cashier)

        first_response = client.post(
            reverse("payment-list"),
            {
                "order": self.cashier_order.pk,
                "method": Payment.Method.CASH,
                "amount": "2.00",
            },
            format="json",
            HTTP_IDEMPOTENCY_KEY="payment-conflict",
        )
        conflict_response = client.post(
            reverse("payment-list"),
            {
                "order": self.cashier_order.pk,
                "method": Payment.Method.CASH,
                "amount": "1.00",
            },
            format="json",
            HTTP_IDEMPOTENCY_KEY="payment-conflict",
        )

        self.assertEqual(first_response.status_code, status.HTTP_201_CREATED)
        self.assertEqual(conflict_response.status_code, status.HTTP_409_CONFLICT)
        self.assertEqual(Payment.objects.filter(order=self.cashier_order).count(), 2)

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


class MoamalatCardReceiptTests(TestCase):
    def setUp(self):
        self.session = RegisterSession.objects.create(owner_key="user:receipt")
        self.order = Order.objects.create(
            register_session=self.session,
            subtotal=Decimal("10.00"),
            total=Decimal("10.00"),
        )

    def test_parser_reads_moamalat_receipt_payload(self):
        receipt = parse_moamalat_receipt_url(_moamalat_receipt_url("1.000"))

        self.assertEqual(receipt.amount, Decimal("1.00"))
        self.assertEqual(receipt.fields["PAN"], "639974*********8809")
        self.assertEqual(receipt.reference, "615316000050")

    def test_card_receipt_required_when_shop_setting_is_enabled(self):
        settings = ShopSettings.load()
        settings.require_card_payment_receipt = True
        settings.save(update_fields=["require_card_payment_receipt"])

        serializer = PaymentSerializer(
            data={
                "order": self.order.pk,
                "method": Payment.Method.CARD,
                "amount": "6.00",
            }
        )

        self.assertFalse(serializer.is_valid())
        self.assertIn("card_receipt_url", serializer.errors)

    def test_card_receipt_is_stored_as_redacted_payment_evidence(self):
        settings = ShopSettings.load()
        settings.require_card_payment_receipt = True
        settings.save(update_fields=["require_card_payment_receipt"])

        serializer = PaymentSerializer(
            data={
                "order": self.order.pk,
                "method": Payment.Method.CARD,
                "amount": "6.00",
                "card_receipt_url": _moamalat_receipt_url("6.000"),
            }
        )

        serializer.is_valid(raise_exception=True)
        payment = serializer.save()

        self.assertEqual(payment.external_reference, "615316000050")
        self.assertEqual(payment.card_receipt_data["provider"], "moamalat")
        self.assertEqual(
            payment.card_receipt_data["validation_method"],
            "decoded_receipt_payload",
        )
        self.assertFalse(payment.card_receipt_data["server_validated"])
        self.assertEqual(payment.card_receipt_data["amount"], "6.00")
        self.assertEqual(
            payment.card_receipt_data["masked_pan"],
            "639974*********8809",
        )
        self.assertNotIn("CardHolder", payment.card_receipt_data)

    def test_card_receipt_amount_must_match_payment_amount(self):
        serializer = PaymentSerializer(
            data={
                "order": self.order.pk,
                "method": Payment.Method.CARD,
                "amount": "6.00",
                "card_receipt_url": _moamalat_receipt_url("5.000"),
            }
        )

        self.assertFalse(serializer.is_valid())
        self.assertIn("card_receipt_url", serializer.errors)

    def test_card_receipt_terminal_must_be_trusted_when_configured(self):
        settings = ShopSettings.load()
        settings.trusted_card_terminal_ids = ["OTHERTERM"]
        settings.save(update_fields=["trusted_card_terminal_ids"])

        serializer = PaymentSerializer(
            data={
                "order": self.order.pk,
                "method": Payment.Method.CARD,
                "amount": "6.00",
                "card_receipt_url": _moamalat_receipt_url("6.000"),
            }
        )

        self.assertFalse(serializer.is_valid())
        self.assertIn("card_receipt_url", serializer.errors)

        settings.trusted_card_terminal_ids = ["0JA8Y13W"]
        settings.save(update_fields=["trusted_card_terminal_ids"])
        serializer = PaymentSerializer(
            data={
                "order": self.order.pk,
                "method": Payment.Method.CARD,
                "amount": "6.00",
                "card_receipt_url": _moamalat_receipt_url("6.000"),
            }
        )

        self.assertTrue(serializer.is_valid(), serializer.errors)


def _moamalat_receipt_url(amount):
    fields = {
        "MerchantName": "SANAD ALBUNYAN ALTAWZIE A",
        "TerminalCity": "MISURATA LY",
        "TerminalId": "0JA8Y13W",
        "CardType": "NUMO BANK1",
        "AID": "A0000009021010",
        "PAN": "639974*********8809",
        "CardHolder": "QARQOOM SALEH",
        "TransactionType": "شراء",
        "InvoiceNumber": "5",
        "DateTime": "02-06-26 18:33:41",
        "AuthorizationCode": "000055",
        "Amount": f"{amount} د.ل",
        "TransactionStatus": "تمت العملية بنجاح ",
        "RRN": "615316000050",
        "STAN": "000050",
        "BATCH": "4",
    }
    payload = f"V9E081919220260602183342;شراء;AR;{json.dumps(fields, ensure_ascii=False)}"
    query = base64.b64encode(zlib.compress(payload.encode("utf-8"))).decode("ascii")
    return (
        "https://receipt.moamalat.net:9443/frontTicketDigital/"
        f"#/digital/ticket?query={quote(query)}"
    )
