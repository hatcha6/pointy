from decimal import Decimal

from django.contrib.auth import get_user_model
from django.test import TestCase
from django.urls import reverse
from rest_framework import status
from rest_framework.test import APIClient

from apps.catalog.models import Product
from apps.payments.models import Payment
from .models import Order, RegisterSession


class RegisterSessionApiTests(TestCase):
    def setUp(self):
        self.client = APIClient()
        self.user = get_user_model().objects.create_user(
            username="register-user",
            password="pass",
        )
        self.client.force_authenticate(user=self.user)

    def test_current_returns_no_content_without_open_session(self):
        response = self.client.get(reverse("register-session-current"))

        self.assertEqual(response.status_code, status.HTTP_204_NO_CONTENT)
        self.assertEqual(RegisterSession.objects.count(), 0)

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

        first_client = APIClient()
        first_client.force_authenticate(user=first_user)
        first_response = first_client.post(reverse("register-session-start"), format="json")
        repeat_response = first_client.post(reverse("register-session-start"), format="json")

        second_client = APIClient()
        second_client.force_authenticate(user=second_user)
        empty_current_response = second_client.get(reverse("register-session-current"))
        second_response = second_client.post(reverse("register-session-start"), format="json")

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

    def test_list_returns_request_owner_register_session_history(self):
        User = get_user_model()
        first_user = User.objects.create_user(username="history-one", password="pass")
        second_user = User.objects.create_user(username="history-two", password="pass")

        first_client = APIClient()
        first_client.force_authenticate(user=first_user)
        first_session = first_client.post(reverse("register-session-start"), format="json").data
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
        second_client.post(reverse("register-session-start"), format="json")

        response = first_client.get(reverse("register-session-list"))

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(len(response.data["results"]), 1)
        self.assertEqual(response.data["results"][0]["id"], first_session["id"])

    def test_orders_action_returns_sales_for_owned_session(self):
        Product.objects.create(
            sku="TEA",
            barcode="",
            name="Tea",
            unit_price=Decimal("2.00"),
        )
        session = self.client.post(reverse("register-session-start"), format="json").data
        checkout_response = self.client.post(
            reverse("order-checkout"),
            {"lines": [{"product": Product.objects.get(sku="TEA").pk, "quantity": 3}]},
            format="json",
        )

        response = self.client.get(reverse("register-session-orders", args=[session["id"]]))

        self.assertEqual(checkout_response.status_code, status.HTTP_201_CREATED)
        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(len(response.data), 1)
        self.assertEqual(response.data[0]["id"], checkout_response.data["id"])
        self.assertEqual(response.data[0]["total"], "6.00")

    def test_orders_action_does_not_expose_another_owner_session(self):
        User = get_user_model()
        first_user = User.objects.create_user(username="session-owner", password="pass")
        second_user = User.objects.create_user(username="session-outsider", password="pass")

        first_client = APIClient()
        first_client.force_authenticate(user=first_user)
        session = first_client.post(reverse("register-session-start"), format="json").data

        second_client = APIClient()
        second_client.force_authenticate(user=second_user)
        response = second_client.get(reverse("register-session-orders", args=[session["id"]]))

        self.assertEqual(response.status_code, status.HTTP_404_NOT_FOUND)


class OrderCheckoutApiTests(TestCase):
    def setUp(self):
        self.client = APIClient()
        self.user = get_user_model().objects.create_user(
            username="checkout-user",
            password="pass",
        )
        self.client.force_authenticate(user=self.user)
        self.product = Product.objects.create(
            sku="COFFEE",
            barcode="",
            name="Coffee",
            unit_price=Decimal("3.50"),
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
        return client.post(reverse("register-session-start"), format="json").data

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

    def test_checkout_is_isolated_by_authenticated_owner(self):
        User = get_user_model()
        first_user = User.objects.create_user(username="cashier-one", password="pass")
        second_user = User.objects.create_user(username="cashier-two", password="pass")

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
