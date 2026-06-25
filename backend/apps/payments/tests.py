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

from apps.analytics.models import AnalyticsEvent
from apps.catalog.testing import create_product_with_default_variant
from apps.core.models import ShopSettings
from apps.core.roles import CASHIER_GROUP, MANAGER_GROUP, ensure_role_groups
from apps.customers.models import Customer, PaymentCard
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


class PaymentLedgerListTests(TestCase):
    """The Payments hub lists customer payments through the read projection:
    commission + customer name are exposed and ``paid_at`` is filterable."""

    def setUp(self):
        from django.utils import timezone

        ensure_role_groups()
        User = get_user_model()
        self.manager = User.objects.create_user(username="ledger-mgr", password="pass")
        self.manager.groups.add(Group.objects.get(name=MANAGER_GROUP))

        self.customer = Customer.objects.create(full_name="Ledger Customer")
        self.session = RegisterSession.objects.create(owner_key="user:ledger")
        self.order = Order.objects.create(
            register_session=self.session,
            customer=self.customer,
            subtotal=Decimal("20.00"),
            total=Decimal("20.00"),
        )
        self.now = timezone.now()
        self.old_payment = Payment.objects.create(
            order=self.order,
            method=Payment.Method.CARD,
            amount=Decimal("5.00"),
            commission_percent=Decimal("2.00"),
            commission_amount=Decimal("0.10"),
            external_reference="OLD-REF",
            created_by=self.manager,
            paid_at=self.now - timezone.timedelta(days=10),
        )
        self.recent_payment = Payment.objects.create(
            order=self.order,
            method=Payment.Method.CASH,
            amount=Decimal("7.00"),
            created_by=self.manager,
            paid_at=self.now,
        )

    def test_ledger_exposes_commission_and_customer_name(self):
        client = APIClient()
        client.force_authenticate(user=self.manager)

        response = client.get(reverse("payment-list"), {"ordering": "paid_at"})

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        rows = {row["id"]: row for row in response.data["results"]}
        row = rows[self.old_payment.pk]
        self.assertEqual(row["customer"], self.customer.pk)
        self.assertEqual(row["customer_name"], "Ledger Customer")
        self.assertEqual(row["order"], self.order.pk)
        self.assertEqual(row["order_receipt_number"], self.order.receipt_number)
        self.assertEqual(Decimal(row["commission_amount"]), Decimal("0.10"))
        self.assertEqual(Decimal(row["commission_percent"]), Decimal("2.00"))
        self.assertEqual(row["external_reference"], "OLD-REF")
        self.assertEqual(row["created_by_username"], "ledger-mgr")
        self.assertIn("paid_at", row)

    def test_paid_at_range_filter_narrows_results(self):
        from django.utils import timezone

        client = APIClient()
        client.force_authenticate(user=self.manager)
        cutoff = (self.now - timezone.timedelta(days=1)).isoformat()

        response = client.get(reverse("payment-list"), {"paid_at__gte": cutoff})

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        ids = [row["id"] for row in response.data["results"]]
        self.assertEqual(ids, [self.recent_payment.pk])

    def test_method_filter_narrows_results(self):
        client = APIClient()
        client.force_authenticate(user=self.manager)

        response = client.get(reverse("payment-list"), {"method": Payment.Method.CARD})

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        ids = [row["id"] for row in response.data["results"]]
        self.assertEqual(ids, [self.old_payment.pk])


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

    def _pay_card(self, order, amount, pan="639974*********8809"):
        serializer = PaymentSerializer(
            data={
                "order": order.pk,
                "method": Payment.Method.CARD,
                "amount": amount,
                "card_receipt_url": _moamalat_receipt_url(f"{amount}0", pan=pan),
            }
        )
        serializer.is_valid(raise_exception=True)
        return serializer.save()

    def _new_order(self, customer=None):
        return Order.objects.create(
            register_session=self.session,
            subtotal=Decimal("10.00"),
            total=Decimal("10.00"),
            customer=customer,
        )

    def test_card_payment_mints_card_and_placeholder_customer(self):
        payment = self._pay_card(self.order, "6.00")

        card = PaymentCard.objects.get()
        self.assertEqual(payment.card, card)
        self.assertEqual(card.masked_pan, "639974*********8809")
        self.assertEqual(card.card_scheme, "NUMO BANK1")
        self.assertEqual(card.last_receipt_data["rrn"], "615316000050")

        placeholder = card.customer
        self.assertTrue(placeholder.is_auto_created)
        self.assertEqual(placeholder.full_name, "Card •••• 8809")
        self.order.refresh_from_db()
        self.assertEqual(self.order.customer_id, placeholder.pk)

    def test_same_card_dedupes_across_orders_without_new_placeholder(self):
        first = self._pay_card(self.order, "6.00")
        second_order = self._new_order()
        second = self._pay_card(second_order, "6.00")

        self.assertEqual(first.card_id, second.card_id)
        self.assertEqual(PaymentCard.objects.count(), 1)
        # Only one placeholder customer for the shared card.
        self.assertEqual(Customer.objects.filter(is_auto_created=True).count(), 1)
        second_order.refresh_from_db()
        self.assertEqual(second_order.customer_id, first.card.customer_id)

    def test_card_on_order_with_customer_skips_placeholder(self):
        real = Customer.objects.create(full_name="Real Customer")
        order = self._new_order(customer=real)

        payment = self._pay_card(order, "6.00")

        self.assertEqual(payment.card.customer_id, real.pk)
        self.assertFalse(Customer.objects.filter(is_auto_created=True).exists())
        order.refresh_from_db()
        self.assertEqual(order.customer_id, real.pk)

    def test_naming_customer_on_later_sale_folds_placeholder_history(self):
        # First sale is anonymous: the card mints a hidden placeholder and the
        # walk-in order lands under it.
        first = self._pay_card(self.order, "6.00")
        placeholder = first.card.customer
        self.assertTrue(placeholder.is_auto_created)
        placeholder_id = placeholder.pk

        # Next time the same card is used the cashier remembers to pick the
        # customer. We should attach the card to that named customer with no
        # manual reassign...
        real = Customer.objects.create(full_name="Layla Ahmed")
        second_order = self._new_order(customer=real)
        with self.captureOnCommitCallbacks(execute=True):
            second = self._pay_card(second_order, "6.00")

        self.assertEqual(PaymentCard.objects.count(), 1)
        second.card.refresh_from_db()
        self.assertEqual(second.card.customer_id, real.pk)
        # ...and the placeholder is retired, its earlier anonymous sale
        # back-filled onto the now-known customer (the whole point: no orphaned,
        # half-filled data left behind).
        self.assertFalse(Customer.objects.filter(pk=placeholder_id).exists())
        self.order.refresh_from_db()
        self.assertEqual(self.order.customer_id, real.pk)
        # The silent move leaves an audit trail naming both ends.
        event = AnalyticsEvent.objects.get(name="customers.payment_card.auto_linked")
        self.assertEqual(event.attributes["from_customer_id"], placeholder_id)
        self.assertEqual(event.attributes["to_customer_id"], real.pk)
        self.assertTrue(event.attributes["placeholder_merged"])

    def test_card_already_owned_by_named_customer_is_not_stolen(self):
        # A card tied to one named customer must not silently jump to another on
        # the next sale (a shared card or a mis-picked customer) -- that stays a
        # manual reassign decision.
        owner = Customer.objects.create(full_name="First Owner")
        first = self._pay_card(self._new_order(customer=owner), "6.00")
        self.assertEqual(first.card.customer_id, owner.pk)

        other = Customer.objects.create(full_name="Second Person")
        second = self._pay_card(self._new_order(customer=other), "6.00")

        second.card.refresh_from_db()
        self.assertEqual(second.card.customer_id, owner.pk)

    def test_split_tender_placeholder_moves_only_the_named_card(self):
        # One anonymous order paid by two different cards parks both under a
        # single placeholder. Naming one card's customer later must move only
        # that card -- the co-payer's card stays put.
        order = self._new_order()  # total 10.00, left partly paid below
        paid_a = self._pay_card(order, "6.00")
        paid_b = self._pay_card(order, "1.00", pan="510321*********1234")
        placeholder = paid_a.card.customer
        self.assertEqual(placeholder.cards.count(), 2)

        real = Customer.objects.create(full_name="Card A Owner")
        self._pay_card(self._new_order(customer=real), "6.00")

        paid_a.card.refresh_from_db()
        paid_b.card.refresh_from_db()
        self.assertEqual(paid_a.card.customer_id, real.pk)
        # Co-payer's card and the placeholder both survive untouched.
        self.assertEqual(paid_b.card.customer_id, placeholder.pk)
        self.assertTrue(Customer.objects.filter(pk=placeholder.pk).exists())


def _moamalat_receipt_url(amount, pan="639974*********8809"):
    fields = {
        "MerchantName": "SANAD ALBUNYAN ALTAWZIE A",
        "TerminalCity": "MISURATA LY",
        "TerminalId": "0JA8Y13W",
        "CardType": "NUMO BANK1",
        "AID": "A0000009021010",
        "PAN": pan,
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


class PaymentDrawerAttributionTests(TestCase):
    """Cash is attributed to the session that COLLECTED a payment, not the
    session that issued the order — so a debt invoice issued in one shift can be
    settled (and counted) in a later shift."""

    def setUp(self):
        User = get_user_model()
        self.cashier = User.objects.create_user(
            username="drawer-cashier", password="pass"
        )

    def test_cash_attributed_to_collecting_session(self):
        issuing = RegisterSession.objects.create(
            owner=self.cashier, owner_key=f"user:{self.cashier.pk}"
        )
        order = Order.objects.create(
            register_session=issuing,
            subtotal=Decimal("10.00"),
            total=Decimal("10.00"),
        )
        collecting = RegisterSession.objects.create(
            owner=self.cashier, owner_key="user:other-shift"
        )
        Payment.objects.create(
            order=order,
            register_session=collecting,
            method=Payment.Method.CASH,
            amount=Decimal("10.00"),
        )
        self.assertEqual(collecting.cash_sales_total, Decimal("10.00"))
        self.assertEqual(issuing.cash_sales_total, Decimal("0.00"))

    def test_serializer_defaults_session_to_order_session(self):
        session = RegisterSession.objects.create(
            owner=self.cashier, owner_key=f"user:{self.cashier.pk}"
        )
        order = Order.objects.create(
            register_session=session,
            subtotal=Decimal("5.00"),
            total=Decimal("5.00"),
        )
        serializer = PaymentSerializer(
            data={
                "order": order.pk,
                "method": Payment.Method.CASH,
                "amount": "2.00",
            },
            context={},
        )
        serializer.is_valid(raise_exception=True)
        payment = serializer.save()
        self.assertEqual(payment.register_session_id, session.pk)
        self.assertEqual(session.cash_sales_total, Decimal("2.00"))
