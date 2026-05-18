from datetime import timedelta
from decimal import Decimal

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group
from django.test import TestCase
from django.urls import reverse
from django.utils import timezone
from rest_framework import status
from rest_framework.test import APIClient

from apps.catalog.models import Product
from apps.core.models import ShopSettings
from apps.core.roles import CASHIER_GROUP, MANAGER_GROUP, ensure_role_groups
from apps.inventory.models import StockItem, StockMovement
from apps.payments.models import Payment
from .models import Order, OrderAdjustment, RegisterCashMovement, RegisterSession


class RegisterSessionApiTests(TestCase):
    def setUp(self):
        ensure_role_groups()
        self.client = APIClient()
        self.user = get_user_model().objects.create_user(
            username="register-user",
            password="pass",
        )
        self.user.groups.add(Group.objects.get(name=CASHIER_GROUP))
        self.client.force_authenticate(user=self.user)

    def test_current_returns_no_content_without_open_session(self):
        response = self.client.get(reverse("register-session-current"))

        self.assertEqual(response.status_code, status.HTTP_204_NO_CONTENT)
        self.assertEqual(RegisterSession.objects.count(), 0)

    def test_start_requires_opening_cash_when_setting_is_enabled(self):
        response = self.client.post(reverse("register-session-start"), format="json")

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertIn("opening_cash", response.data)
        self.assertEqual(RegisterSession.objects.count(), 0)

    def test_start_allows_missing_opening_cash_when_setting_is_disabled(self):
        ShopSettings.load()
        ShopSettings.objects.filter(pk=1).update(require_opening_cash=False)

        response = self.client.post(reverse("register-session-start"), format="json")

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(response.data["opening_cash"], "0.00")

    def test_start_is_idempotent_for_authenticated_owner(self):
        first_response = self.client.post(
            reverse("register-session-start"),
            {"opening_cash": "15.25"},
            format="json",
        )
        second_response = self.client.post(
            reverse("register-session-start"),
            {"opening_cash": "99.00"},
            format="json",
        )

        self.assertEqual(first_response.status_code, status.HTTP_200_OK)
        self.assertEqual(second_response.status_code, status.HTTP_200_OK)
        self.assertEqual(first_response.data["id"], second_response.data["id"])
        self.assertEqual(
            first_response.data["session_number"],
            f"RS-{first_response.data['id']}",
        )
        self.assertEqual(second_response.data["opening_cash"], "15.25")
        self.assertEqual(RegisterSession.objects.count(), 1)

        session = RegisterSession.objects.get()
        self.assertEqual(session.owner_key, f"user:{self.user.pk}")
        self.assertEqual(session.owner, self.user)

    def test_authenticated_users_have_isolated_current_sessions(self):
        User = get_user_model()
        first_user = User.objects.create_user(username="first", password="pass")
        second_user = User.objects.create_user(username="second", password="pass")
        first_user.groups.add(Group.objects.get(name=CASHIER_GROUP))
        second_user.groups.add(Group.objects.get(name=CASHIER_GROUP))

        first_client = APIClient()
        first_client.force_authenticate(user=first_user)
        first_response = first_client.post(
            reverse("register-session-start"),
            {"opening_cash": "0.00"},
            format="json",
        )
        repeat_response = first_client.post(
            reverse("register-session-start"),
            {"opening_cash": "1.00"},
            format="json",
        )

        second_client = APIClient()
        second_client.force_authenticate(user=second_user)
        empty_current_response = second_client.get(reverse("register-session-current"))
        second_response = second_client.post(
            reverse("register-session-start"),
            {"opening_cash": "0.00"},
            format="json",
        )

        self.assertEqual(first_response.status_code, status.HTTP_200_OK)
        self.assertEqual(repeat_response.status_code, status.HTTP_200_OK)
        self.assertEqual(first_response.data["id"], repeat_response.data["id"])
        self.assertEqual(empty_current_response.status_code, status.HTTP_204_NO_CONTENT)
        self.assertEqual(second_response.status_code, status.HTTP_200_OK)
        self.assertNotEqual(first_response.data["id"], second_response.data["id"])
        self.assertEqual(
            RegisterSession.objects.filter(status=RegisterSession.Status.OPEN).count(),
            2,
        )

    def test_close_persists_closing_cash_and_denominations(self):
        start_response = self.client.post(
            reverse("register-session-start"),
            {"opening_cash": "10.00"},
            format="json",
        )
        session_id = start_response.data["id"]

        close_response = self.client.post(
            reverse("register-session-close", args=[session_id]),
            {
                "closing_cash": "18.75",
                "count_025": 3,
                "count_050": 4,
                "count_075": 5,
                "count_100": 6,
            },
            format="json",
        )

        self.assertEqual(close_response.status_code, status.HTTP_200_OK)
        session = RegisterSession.objects.get(pk=session_id)
        self.assertEqual(session.status, RegisterSession.Status.CLOSED)
        self.assertEqual(session.closing_cash, Decimal("18.75"))
        self.assertEqual(session.count_025, 3)
        self.assertEqual(session.count_050, 4)
        self.assertEqual(session.count_075, 5)
        self.assertEqual(session.count_100, 6)
        self.assertIsNotNone(session.closed_at)

        current_response = self.client.get(reverse("register-session-current"))
        self.assertEqual(current_response.status_code, status.HTTP_204_NO_CONTENT)

    def test_closed_session_reports_expected_cash_and_variance(self):
        product = Product.objects.create(
            sku="CASH-REC",
            barcode="",
            name="Cash reconciliation coffee",
            unit_price=Decimal("3.00"),
        )
        StockItem.objects.create(product=product, quantity_on_hand=5)
        start_response = self.client.post(
            reverse("register-session-start"),
            {"opening_cash": "10.00"},
            format="json",
        )
        session_id = start_response.data["id"]

        checkout_response = self.client.post(
            reverse("order-checkout"),
            {"lines": [{"product": product.pk, "quantity": 2}]},
            format="json",
        )
        pay_in_response = self.client.post(
            reverse("register-session-pay-in", args=[session_id]),
            {"amount": "5.00", "reason": "Float top-up"},
            format="json",
        )
        pay_out_response = self.client.post(
            reverse("register-session-pay-out", args=[session_id]),
            {"amount": "2.00", "reason": "Supplies"},
            format="json",
        )
        close_response = self.client.post(
            reverse("register-session-close", args=[session_id]),
            {
                "closing_cash": "18.75",
                "count_025": 3,
                "count_050": 4,
                "count_075": 5,
                "count_100": 6,
            },
            format="json",
        )
        manager = get_user_model().objects.create_user(
            username="reconciliation-manager",
            password="pass",
        )
        manager.groups.add(Group.objects.get(name=MANAGER_GROUP))
        manager_client = APIClient()
        manager_client.force_authenticate(user=manager)
        detail_response = manager_client.get(
            reverse("register-session-detail", args=[session_id]),
        )

        self.assertEqual(checkout_response.status_code, status.HTTP_201_CREATED)
        self.assertEqual(pay_in_response.status_code, status.HTTP_201_CREATED)
        self.assertEqual(pay_out_response.status_code, status.HTTP_201_CREATED)
        self.assertEqual(close_response.status_code, status.HTTP_200_OK)
        self.assertNotIn("expected_cash", close_response.data)
        self.assertEqual(detail_response.status_code, status.HTTP_200_OK)
        self.assertEqual(detail_response.data["cash_sales_total"], "6.00")
        self.assertEqual(detail_response.data["pay_in_total"], "5.00")
        self.assertEqual(detail_response.data["pay_out_total"], "2.00")
        self.assertEqual(detail_response.data["cash_refund_total"], "0.00")
        self.assertEqual(detail_response.data["expected_cash"], "19.00")
        self.assertEqual(detail_response.data["denomination_total"], "12.50")
        self.assertEqual(detail_response.data["cash_variance"], "-0.25")
        self.assertTrue(detail_response.data["has_cash_variance"])

    def test_list_returns_request_owner_register_session_history(self):
        User = get_user_model()
        first_user = User.objects.create_user(username="history-one", password="pass")
        second_user = User.objects.create_user(username="history-two", password="pass")
        first_user.groups.add(Group.objects.get(name=CASHIER_GROUP))
        second_user.groups.add(Group.objects.get(name=CASHIER_GROUP))

        first_client = APIClient()
        first_client.force_authenticate(user=first_user)
        first_session = first_client.post(
            reverse("register-session-start"),
            {"opening_cash": "0.00"},
            format="json",
        ).data
        first_client.post(
            reverse("register-session-close", args=[first_session["id"]]),
            {
                "closing_cash": "10.00",
                "count_025": 0,
                "count_050": 0,
                "count_075": 0,
                "count_100": 10,
            },
            format="json",
        )

        second_client = APIClient()
        second_client.force_authenticate(user=second_user)
        second_client.post(
            reverse("register-session-start"),
            {"opening_cash": "0.00"},
            format="json",
        )

        response = first_client.get(reverse("register-session-list"))

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(len(response.data["results"]), 1)
        self.assertEqual(response.data["results"][0]["id"], first_session["id"])

    def test_manager_can_view_all_register_session_history(self):
        User = get_user_model()
        first_user = User.objects.create_user(username="history-one", password="pass")
        second_user = User.objects.create_user(username="history-two", password="pass")
        manager = User.objects.create_user(username="history-manager", password="pass")
        first_user.groups.add(Group.objects.get(name=CASHIER_GROUP))
        second_user.groups.add(Group.objects.get(name=CASHIER_GROUP))
        manager.groups.add(Group.objects.get(name=MANAGER_GROUP))

        first_client = APIClient()
        first_client.force_authenticate(user=first_user)
        first_session = first_client.post(
            reverse("register-session-start"),
            {"opening_cash": "0.00"},
            format="json",
        ).data

        second_client = APIClient()
        second_client.force_authenticate(user=second_user)
        second_session = second_client.post(
            reverse("register-session-start"),
            {"opening_cash": "0.00"},
            format="json",
        ).data

        manager_client = APIClient()
        manager_client.force_authenticate(user=manager)
        response = manager_client.get(reverse("register-session-list"))

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        session_ids = {session["id"] for session in response.data["results"]}
        self.assertSetEqual(session_ids, {first_session["id"], second_session["id"]})

    def test_manager_current_session_still_uses_manager_owner(self):
        User = get_user_model()
        cashier = User.objects.create_user(username="cashier-current", password="pass")
        manager = User.objects.create_user(username="manager-current", password="pass")
        cashier.groups.add(Group.objects.get(name=CASHIER_GROUP))
        manager.groups.add(Group.objects.get(name=MANAGER_GROUP))

        cashier_client = APIClient()
        cashier_client.force_authenticate(user=cashier)
        cashier_client.post(
            reverse("register-session-start"),
            {"opening_cash": "0.00"},
            format="json",
        )

        manager_client = APIClient()
        manager_client.force_authenticate(user=manager)
        response = manager_client.get(reverse("register-session-current"))

        self.assertEqual(response.status_code, status.HTTP_204_NO_CONTENT)

    def test_orders_action_returns_sales_for_owned_session(self):
        product = Product.objects.create(
            sku="TEA",
            barcode="",
            name="Tea",
            unit_price=Decimal("2.00"),
        )
        StockItem.objects.create(product=product, quantity_on_hand=5)
        session = self.client.post(
            reverse("register-session-start"),
            {"opening_cash": "0.00"},
            format="json",
        ).data
        checkout_response = self.client.post(
            reverse("order-checkout"),
            {"lines": [{"product": Product.objects.get(sku="TEA").pk, "quantity": 3}]},
            format="json",
        )

        response = self.client.get(reverse("register-session-orders", args=[session["id"]]))

        self.assertEqual(checkout_response.status_code, status.HTTP_201_CREATED)
        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(len(response.data["results"]), 1)
        self.assertEqual(response.data["results"][0]["id"], checkout_response.data["id"])
        self.assertEqual(response.data["results"][0]["total"], "6.00")

    def test_orders_action_does_not_expose_another_owner_session(self):
        User = get_user_model()
        first_user = User.objects.create_user(username="session-owner", password="pass")
        second_user = User.objects.create_user(username="session-outsider", password="pass")
        first_user.groups.add(Group.objects.get(name=CASHIER_GROUP))
        second_user.groups.add(Group.objects.get(name=CASHIER_GROUP))

        first_client = APIClient()
        first_client.force_authenticate(user=first_user)
        session = first_client.post(
            reverse("register-session-start"),
            {"opening_cash": "0.00"},
            format="json",
        ).data

        second_client = APIClient()
        second_client.force_authenticate(user=second_user)
        response = second_client.get(reverse("register-session-orders", args=[session["id"]]))

        self.assertEqual(response.status_code, status.HTTP_404_NOT_FOUND)

    def test_manager_can_view_orders_for_any_register_session(self):
        User = get_user_model()
        cashier = User.objects.create_user(username="session-owner", password="pass")
        manager = User.objects.create_user(username="session-manager", password="pass")
        cashier.groups.add(Group.objects.get(name=CASHIER_GROUP))
        manager.groups.add(Group.objects.get(name=MANAGER_GROUP))

        product = Product.objects.create(
            sku="MGR-TEA",
            barcode="",
            name="Manager Tea",
            unit_price=Decimal("2.00"),
        )
        StockItem.objects.create(product=product, quantity_on_hand=5)
        cashier_client = APIClient()
        cashier_client.force_authenticate(user=cashier)
        session = cashier_client.post(
            reverse("register-session-start"),
            {"opening_cash": "0.00"},
            format="json",
        ).data
        checkout_response = cashier_client.post(
            reverse("order-checkout"),
            {"lines": [{"product": product.pk, "quantity": 2}]},
            format="json",
        )

        manager_client = APIClient()
        manager_client.force_authenticate(user=manager)
        response = manager_client.get(reverse("register-session-orders", args=[session["id"]]))

        self.assertEqual(checkout_response.status_code, status.HTTP_201_CREATED)
        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(response.data["results"][0]["id"], checkout_response.data["id"])

    def test_pay_in_creates_cash_movement_with_required_reason(self):
        session = self.client.post(
            reverse("register-session-start"),
            {"opening_cash": "0.00"},
            format="json",
        ).data

        response = self.client.post(
            reverse("register-session-pay-in", args=[session["id"]]),
            {"amount": "25.50", "reason": "Float top-up"},
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_201_CREATED)
        self.assertEqual(
            response.data["movement_type"],
            RegisterCashMovement.MovementType.PAY_IN,
        )
        self.assertEqual(response.data["amount"], "25.50")
        self.assertEqual(response.data["reason"], "Float top-up")

        movement = RegisterCashMovement.objects.get()
        self.assertEqual(movement.register_session_id, session["id"])
        self.assertEqual(movement.created_by, self.user)

    def test_pay_out_requires_reason(self):
        session = self.client.post(
            reverse("register-session-start"),
            {"opening_cash": "0.00"},
            format="json",
        ).data

        response = self.client.post(
            reverse("register-session-pay-out", args=[session["id"]]),
            {"amount": "4.00", "reason": "   "},
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertIn("reason", response.data)
        self.assertEqual(RegisterCashMovement.objects.count(), 0)

    def test_pay_out_rejects_closed_session(self):
        session = self.client.post(
            reverse("register-session-start"),
            {"opening_cash": "0.00"},
            format="json",
        ).data
        self.client.post(
            reverse("register-session-close", args=[session["id"]]),
            {
                "closing_cash": "0.00",
                "count_025": 0,
                "count_050": 0,
                "count_075": 0,
                "count_100": 0,
            },
            format="json",
        )

        response = self.client.post(
            reverse("register-session-pay-out", args=[session["id"]]),
            {"amount": "4.00", "reason": "Petty cash"},
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertEqual(RegisterCashMovement.objects.count(), 0)

    def test_cash_movements_action_returns_owned_session_movements(self):
        User = get_user_model()
        first_user = User.objects.create_user(username="movement-owner", password="pass")
        second_user = User.objects.create_user(
            username="movement-outsider",
            password="pass",
        )
        first_user.groups.add(Group.objects.get(name=CASHIER_GROUP))
        second_user.groups.add(Group.objects.get(name=CASHIER_GROUP))

        first_client = APIClient()
        first_client.force_authenticate(user=first_user)
        session = first_client.post(
            reverse("register-session-start"),
            {"opening_cash": "0.00"},
            format="json",
        ).data
        pay_in_response = first_client.post(
            reverse("register-session-pay-in", args=[session["id"]]),
            {"amount": "12.00", "reason": "Extra change"},
            format="json",
        )

        response = first_client.get(
            reverse("register-session-cash-movements", args=[session["id"]])
        )

        second_client = APIClient()
        second_client.force_authenticate(user=second_user)
        blocked_response = second_client.get(
            reverse("register-session-cash-movements", args=[session["id"]])
        )

        self.assertEqual(pay_in_response.status_code, status.HTTP_201_CREATED)
        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(len(response.data["results"]), 1)
        self.assertEqual(response.data["results"][0]["amount"], "12.00")
        self.assertEqual(blocked_response.status_code, status.HTTP_404_NOT_FOUND)

    def test_manager_can_view_cash_movements_for_any_register_session(self):
        User = get_user_model()
        cashier = User.objects.create_user(username="movement-cashier", password="pass")
        manager = User.objects.create_user(username="movement-manager", password="pass")
        cashier.groups.add(Group.objects.get(name=CASHIER_GROUP))
        manager.groups.add(Group.objects.get(name=MANAGER_GROUP))

        cashier_client = APIClient()
        cashier_client.force_authenticate(user=cashier)
        session = cashier_client.post(
            reverse("register-session-start"),
            {"opening_cash": "0.00"},
            format="json",
        ).data
        cashier_client.post(
            reverse("register-session-pay-out", args=[session["id"]]),
            {"amount": "3.00", "reason": "Supplies"},
            format="json",
        )

        manager_client = APIClient()
        manager_client.force_authenticate(user=manager)
        response = manager_client.get(
            reverse("register-session-cash-movements", args=[session["id"]])
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(response.data["results"][0]["movement_type"], "pay_out")


class OrderCheckoutApiTests(TestCase):
    def setUp(self):
        ensure_role_groups()
        self.client = APIClient()
        self.user = get_user_model().objects.create_user(
            username="checkout-user",
            password="pass",
        )
        self.user.groups.add(Group.objects.get(name=CASHIER_GROUP))
        self.client.force_authenticate(user=self.user)
        self.product = Product.objects.create(
            sku="COFFEE",
            barcode="",
            name="Coffee",
            unit_price=Decimal("3.50"),
        )
        self.stock_item = StockItem.objects.create(
            product=self.product,
            quantity_on_hand=10,
        )

    def checkout_payload(self, **overrides):
        payload = {
            "lines": [{"product": self.product.pk, "quantity": 2}],
            "payment_method": "cash",
            "amount_received": "7.00",
        }
        payload.update(overrides)
        return payload

    def start_session(self, client=None):
        client = client or self.client
        return client.post(
            reverse("register-session-start"),
            {"opening_cash": "0.00"},
            format="json",
        ).data

    def test_checkout_requires_open_session(self):
        response = self.client.post(
            reverse("order-checkout"),
            self.checkout_payload(),
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertEqual(
            response.data["detail"],
            "No open register session for this request owner.",
        )
        self.assertEqual(Order.objects.count(), 0)

    def test_checkout_links_order_to_active_session_and_captures_prices(self):
        session = self.start_session()

        response = self.client.post(
            reverse("order-checkout"),
            self.checkout_payload(),
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_201_CREATED)
        self.assertEqual(response.data["register_session"], session["id"])
        self.assertEqual(response.data["register_session_number"], session["session_number"])
        self.assertEqual(response.data["subtotal"], "7.00")
        self.assertEqual(response.data["total"], "7.00")

        order = Order.objects.get(pk=response.data["id"])
        self.assertEqual(order.register_session_id, session["id"])
        self.assertEqual(order.lines.get().unit_price, Decimal("3.50"))

    def test_checkout_creates_paid_order_and_payment(self):
        self.start_session()

        response = self.client.post(
            reverse("order-checkout"),
            {
                "lines": [{"product": self.product.pk, "quantity": 2}],
            },
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_201_CREATED)
        self.assertEqual(response.data["status"], Order.Status.PAID)

        order = Order.objects.get(pk=response.data["id"])
        payment = Payment.objects.get(order=order)
        self.assertEqual(order.status, Order.Status.PAID)
        self.assertEqual(payment.method, Payment.Method.CASH)
        self.assertEqual(payment.amount, Decimal("7.00"))
        self.assertEqual(payment.commission_percent, Decimal("0.00"))
        self.assertEqual(payment.commission_amount, Decimal("0.00"))
        self.assertEqual(response.data["payments"][0]["method"], Payment.Method.CASH)

    def test_checkout_records_card_payment_with_configured_commission(self):
        ShopSettings.load()
        ShopSettings.objects.filter(pk=1).update(card_commission_percent=Decimal("1.25"))
        self.start_session()

        response = self.client.post(
            reverse("order-checkout"),
            self.checkout_payload(payment_method=Payment.Method.CARD),
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_201_CREATED)
        payment = Payment.objects.get(order_id=response.data["id"])
        self.assertEqual(payment.method, Payment.Method.CARD)
        self.assertEqual(payment.commission_percent, Decimal("1.25"))
        self.assertEqual(payment.commission_amount, Decimal("0.09"))
        self.assertEqual(response.data["payments"][0]["commission_percent"], "1.25")
        self.assertEqual(response.data["payments"][0]["commission_amount"], "0.09")

    def test_checkout_records_split_payments_with_per_tender_commission(self):
        ShopSettings.load()
        ShopSettings.objects.filter(pk=1).update(
            card_commission_percent=Decimal("1.00"),
            transfer_commission_percent=Decimal("0.50"),
        )
        self.start_session()

        response = self.client.post(
            reverse("order-checkout"),
            self.checkout_payload(
                payments=[
                    {"method": Payment.Method.CASH, "amount": "2.00"},
                    {"method": Payment.Method.CARD, "amount": "3.00"},
                    {"method": Payment.Method.TRANSFER, "amount": "2.00"},
                ],
            ),
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_201_CREATED)
        payments = list(Payment.objects.filter(order_id=response.data["id"]).order_by("id"))
        self.assertEqual([payment.method for payment in payments], [
            Payment.Method.CASH,
            Payment.Method.CARD,
            Payment.Method.TRANSFER,
        ])
        self.assertEqual(payments[0].commission_amount, Decimal("0.00"))
        self.assertEqual(payments[1].commission_amount, Decimal("0.03"))
        self.assertEqual(payments[2].commission_amount, Decimal("0.01"))

    def test_checkout_rejects_disabled_payment_method(self):
        ShopSettings.load()
        ShopSettings.objects.filter(pk=1).update(enable_card_payments=False)
        self.start_session()

        response = self.client.post(
            reverse("order-checkout"),
            self.checkout_payload(payment_method=Payment.Method.CARD),
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertIn("payment_method", response.data)
        self.assertEqual(Order.objects.count(), 0)

    def test_checkout_decrements_stock_and_records_stock_movement(self):
        self.start_session()

        response = self.client.post(
            reverse("order-checkout"),
            self.checkout_payload(),
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_201_CREATED)
        self.stock_item.refresh_from_db()
        self.assertEqual(self.stock_item.quantity_on_hand, 8)

        movement = StockMovement.objects.get()
        self.assertEqual(movement.product, self.product)
        self.assertEqual(movement.movement_type, StockMovement.Type.DECREASE)
        self.assertEqual(movement.quantity, 2)
        self.assertEqual(movement.on_hand_before, 10)
        self.assertEqual(movement.on_hand_after, 8)
        self.assertEqual(movement.created_by, self.user)

    def test_checkout_rejects_oversell_when_setting_is_disabled(self):
        self.start_session()
        self.stock_item.quantity_on_hand = 1
        self.stock_item.save(update_fields=["quantity_on_hand", "updated_at"])

        response = self.client.post(
            reverse("order-checkout"),
            self.checkout_payload(),
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertIn("stock", response.data)
        self.stock_item.refresh_from_db()
        self.assertEqual(self.stock_item.quantity_on_hand, 1)
        self.assertEqual(Order.objects.count(), 0)
        self.assertEqual(StockMovement.objects.count(), 0)

    def test_checkout_allows_oversell_when_setting_is_enabled(self):
        ShopSettings.load()
        ShopSettings.objects.filter(pk=1).update(allow_overselling=True)
        self.start_session()
        self.stock_item.quantity_on_hand = 1
        self.stock_item.save(update_fields=["quantity_on_hand", "updated_at"])

        response = self.client.post(
            reverse("order-checkout"),
            self.checkout_payload(),
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_201_CREATED)
        self.stock_item.refresh_from_db()
        self.assertEqual(self.stock_item.quantity_on_hand, -1)
        self.assertEqual(StockMovement.objects.get().on_hand_after, -1)

    def test_partial_return_refunds_selected_quantity_and_restocks(self):
        self.start_session()
        checkout_response = self.client.post(
            reverse("order-checkout"),
            self.checkout_payload(),
            format="json",
        )
        line_id = checkout_response.data["lines"][0]["id"]

        response = self.client.post(
            reverse("order-return-items", args=[checkout_response.data["id"]]),
            {
                "reason": "Customer changed item",
                "lines": [{"line": line_id, "quantity": 1}],
            },
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(response.data["status"], Order.Status.PAID)
        self.assertEqual(response.data["lines"][0]["returned_quantity"], 1)
        self.assertEqual(response.data["lines"][0]["returnable_quantity"], 1)

        adjustment = OrderAdjustment.objects.get()
        self.assertEqual(adjustment.adjustment_type, OrderAdjustment.AdjustmentType.RETURN)
        self.assertEqual(adjustment.amount, Decimal("3.50"))
        self.assertEqual(adjustment.refund_method, Payment.Method.CASH)
        self.assertEqual(adjustment.reason, "Customer changed item")

        payments = Payment.objects.order_by("amount")
        self.assertEqual(payments.first().amount, Decimal("-3.50"))
        self.stock_item.refresh_from_db()
        self.assertEqual(self.stock_item.quantity_on_hand, 9)
        self.assertEqual(
            list(StockMovement.objects.order_by("created_at").values_list("movement_type", flat=True)),
            [StockMovement.Type.DECREASE, StockMovement.Type.INCREASE],
        )

    def test_void_order_refunds_remaining_quantities_and_marks_void(self):
        self.start_session()
        checkout_response = self.client.post(
            reverse("order-checkout"),
            self.checkout_payload(),
            format="json",
        )

        response = self.client.post(
            reverse("order-void", args=[checkout_response.data["id"]]),
            {"reason": "Wrong invoice"},
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(response.data["status"], Order.Status.VOID)
        self.assertEqual(response.data["lines"][0]["returned_quantity"], 2)
        self.assertEqual(response.data["lines"][0]["returnable_quantity"], 0)

        adjustment = OrderAdjustment.objects.get()
        self.assertEqual(adjustment.adjustment_type, OrderAdjustment.AdjustmentType.VOID)
        self.assertEqual(adjustment.amount, Decimal("7.00"))

        self.stock_item.refresh_from_db()
        self.assertEqual(self.stock_item.quantity_on_hand, 10)
        self.assertEqual(
            Payment.objects.order_by("amount").first().amount,
            Decimal("-7.00"),
        )

    def test_return_allows_closed_register_session_inside_cashier_window(self):
        session = self.start_session()
        checkout_response = self.client.post(
            reverse("order-checkout"),
            self.checkout_payload(),
            format="json",
        )
        line_id = checkout_response.data["lines"][0]["id"]
        self.client.post(
            reverse("register-session-close", args=[session["id"]]),
            {
                "closing_cash": "7.00",
                "count_025": 0,
                "count_050": 0,
                "count_075": 0,
                "count_100": 7,
            },
            format="json",
        )

        response = self.client.post(
            reverse("order-return-items", args=[checkout_response.data["id"]]),
            {"lines": [{"line": line_id, "quantity": 1}]},
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(response.data["lines"][0]["returned_quantity"], 1)
        self.assertEqual(OrderAdjustment.objects.get().register_session_id, session["id"])

    def test_return_rejects_cashier_after_return_window(self):
        ShopSettings.load()
        ShopSettings.objects.filter(pk=1).update(cashier_return_window_hours=42)
        self.start_session()
        checkout_response = self.client.post(
            reverse("order-checkout"),
            self.checkout_payload(),
            format="json",
        )
        order = Order.objects.get(pk=checkout_response.data["id"])
        Order.objects.filter(pk=order.pk).update(
            created_at=timezone.now() - timedelta(hours=43),
        )
        line_id = checkout_response.data["lines"][0]["id"]

        response = self.client.post(
            reverse("order-return-items", args=[checkout_response.data["id"]]),
            {"lines": [{"line": line_id, "quantity": 1}]},
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertEqual(OrderAdjustment.objects.count(), 0)

    def test_manager_can_void_after_cashier_return_window(self):
        ShopSettings.load()
        ShopSettings.objects.filter(pk=1).update(cashier_return_window_hours=42)
        self.start_session()
        checkout_response = self.client.post(
            reverse("order-checkout"),
            self.checkout_payload(),
            format="json",
        )
        Order.objects.filter(pk=checkout_response.data["id"]).update(
            created_at=timezone.now() - timedelta(hours=43),
        )

        manager = get_user_model().objects.create_user(
            username="returns-manager",
            password="pass",
        )
        manager.groups.add(Group.objects.get(name=MANAGER_GROUP))
        manager_client = APIClient()
        manager_client.force_authenticate(user=manager)
        response = manager_client.post(
            reverse("order-void", args=[checkout_response.data["id"]]),
            {"reason": "Manager approved late void"},
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(response.data["status"], Order.Status.VOID)
        self.assertFalse(response.data["can_void"])

    def test_checkout_is_isolated_by_authenticated_owner(self):
        User = get_user_model()
        first_user = User.objects.create_user(username="cashier-one", password="pass")
        second_user = User.objects.create_user(username="cashier-two", password="pass")
        first_user.groups.add(Group.objects.get(name=CASHIER_GROUP))
        second_user.groups.add(Group.objects.get(name=CASHIER_GROUP))

        first_client = APIClient()
        first_client.force_authenticate(user=first_user)
        first_session = self.start_session(first_client)

        second_client = APIClient()
        second_client.force_authenticate(user=second_user)
        blocked_response = second_client.post(
            reverse("order-checkout"),
            self.checkout_payload(),
            format="json",
        )

        self.assertEqual(blocked_response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertEqual(Order.objects.count(), 0)

        second_session = self.start_session(second_client)
        checkout_response = second_client.post(
            reverse("order-checkout"),
            self.checkout_payload(),
            format="json",
        )

        self.assertEqual(checkout_response.status_code, status.HTTP_201_CREATED)
        self.assertNotEqual(first_session["id"], second_session["id"])
        self.assertEqual(checkout_response.data["register_session"], second_session["id"])

    def test_checkout_cannot_use_closed_session(self):
        session = self.start_session()
        self.client.post(
            reverse("register-session-close", args=[session["id"]]),
            {
                "closing_cash": "7.00",
                "count_025": 0,
                "count_050": 0,
                "count_075": 0,
                "count_100": 7,
            },
            format="json",
        )

        response = self.client.post(
            reverse("order-checkout"),
            self.checkout_payload(),
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertEqual(Order.objects.count(), 0)

    def test_checkout_validates_non_empty_lines_and_positive_quantities(self):
        self.start_session()

        empty_response = self.client.post(
            reverse("order-checkout"),
            self.checkout_payload(lines=[]),
            format="json",
        )
        quantity_response = self.client.post(
            reverse("order-checkout"),
            self.checkout_payload(lines=[{"product": self.product.pk, "quantity": 0}]),
            format="json",
        )

        self.assertEqual(empty_response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertEqual(quantity_response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertIn("lines", empty_response.data)
        self.assertIn("lines", quantity_response.data)
