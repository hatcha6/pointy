from datetime import timedelta
from decimal import Decimal

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group
from django.core.exceptions import FieldError
from django.db import connection
from django.test import SimpleTestCase, TestCase
from django.test.utils import CaptureQueriesContext
from django.urls import reverse
from django.utils import timezone
from rest_framework import serializers, status
from rest_framework.test import APIClient

from apps.catalog.models import (
    ModifierGroup,
    ModifierOption,
    ProductModifierGroup,
    ProductVariant,
)
from apps.catalog.testing import create_product_with_default_variant
from apps.core.models import IdempotencyRecord, RelayInstallation, ShopSettings
from apps.core.roles import CASHIER_GROUP, MANAGER_GROUP, ensure_role_groups
from apps.customers.models import Customer, PaymentCard
from apps.discounts.models import AppliedDiscount, DiscountRedemption, DiscountRule
from apps.inventory.models import StockItem, StockMovement
from apps.payments.models import Payment
from apps.payments.tests import _moamalat_receipt_url
from apps.purchasing.models import PurchaseOrder, Supplier
from .load_testing import build_ramp_stages, capacity_summary, collapse_reasons
from .models import (
    Order,
    OrderAdjustment,
    OrderExchange,
    OrderLine,
    OrderLineModifier,
    RegisterCashMovement,
    RegisterSession,
    StockReservation,
)
from . import tasks as sales_tasks
from .services import (
    prepare_sale_stock_adjustments,
    release_quote_reservations,
    reserve_stock_for_quote,
    return_order_items,
)


class CheckoutLoadRampTests(SimpleTestCase):
    def test_build_ramp_stages_caps_workers_and_fills_total_duration(self):
        stages = build_ramp_stages(
            total_duration=600,
            step_duration=180,
            start_workers=4,
            max_workers=12,
            step_workers=4,
        )

        self.assertEqual(
            stages,
            [
                {"stage": 1, "workers": 4, "duration": 180},
                {"stage": 2, "workers": 8, "duration": 180},
                {"stage": 3, "workers": 12, "duration": 180},
                {"stage": 4, "workers": 12, "duration": 60},
            ],
        )

    def test_collapse_reasons_detect_failure_rate_and_p95_latency(self):
        summary = {
            "total_requests": 100,
            "successes": 98,
            "failures": 2,
            "failure_rate": 0.02,
            "latency_ms": {"p95": 2500},
        }

        reasons = collapse_reasons(
            summary,
            failure_rate_threshold=0.01,
            p95_ms_threshold=2000,
            min_requests=20,
        )

        self.assertEqual(len(reasons), 2)
        self.assertIn("failure rate", reasons[0])
        self.assertIn("p95 latency", reasons[1])

    def test_capacity_summary_returns_highest_non_collapsed_stage(self):
        stages = [
            self._stage(stage=1, clients=4, success_rps=20, collapsed=False),
            self._stage(stage=2, clients=8, success_rps=38, collapsed=False),
            self._stage(stage=3, clients=12, success_rps=22, collapsed=True),
        ]

        capacity = capacity_summary(stages)

        self.assertEqual(capacity["stage"], 2)
        self.assertEqual(capacity["concurrent_clients"], 8)
        self.assertEqual(capacity["success_rps"], 38)

    def _stage(self, *, stage, clients, success_rps, collapsed):
        return {
            "stage": stage,
            "concurrent_clients": clients,
            "total_requests": 100,
            "success_rps": success_rps,
            "failure_rate": 0,
            "latency_ms": {"p95": 120, "p99": 180},
            "collapsed": collapsed,
        }


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
        # Submitted cash (18.75) plus the counted denominations (12.50).
        self.assertEqual(session.closing_cash, Decimal("31.25"))
        self.assertEqual(session.count_025, 3)
        self.assertEqual(session.count_050, 4)
        self.assertEqual(session.count_075, 5)
        self.assertEqual(session.count_100, 6)
        self.assertIsNotNone(session.closed_at)

        current_response = self.client.get(reverse("register-session-current"))
        self.assertEqual(current_response.status_code, status.HTTP_204_NO_CONTENT)

    def test_closed_session_reports_expected_cash_and_variance(self):
        product = create_product_with_default_variant(
            sku="CASH-REC",
            barcode="",
            name="Cash reconciliation coffee",
            unit_price=Decimal("3.00"),
        )
        variant = product.default_variant
        StockItem.objects.create(variant=variant, quantity_on_hand=5)
        start_response = self.client.post(
            reverse("register-session-start"),
            {"opening_cash": "10.00"},
            format="json",
        )
        session_id = start_response.data["id"]

        checkout_response = self.client.post(
            reverse("order-checkout"),
            {"lines": [{"variant": variant.pk, "quantity": 2}]},
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
                "closing_cash": "6.25",
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
        # 6.25 entered + 12.50 in counted denominations.
        self.assertEqual(detail_response.data["closing_cash"], "18.75")
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
        product = create_product_with_default_variant(
            sku="TEA",
            barcode="",
            name="Tea",
            unit_price=Decimal("2.00"),
        )
        variant = product.default_variant
        StockItem.objects.create(variant=variant, quantity_on_hand=5)
        session = self.client.post(
            reverse("register-session-start"),
            {"opening_cash": "0.00"},
            format="json",
        ).data
        checkout_response = self.client.post(
            reverse("order-checkout"),
            {"lines": [{"variant": variant.pk, "quantity": 3}]},
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

        product = create_product_with_default_variant(
            sku="MGR-TEA",
            barcode="",
            name="Manager Tea",
            unit_price=Decimal("2.00"),
        )
        variant = product.default_variant
        StockItem.objects.create(variant=variant, quantity_on_hand=5)
        cashier_client = APIClient()
        cashier_client.force_authenticate(user=cashier)
        session = cashier_client.post(
            reverse("register-session-start"),
            {"opening_cash": "0.00"},
            format="json",
        ).data
        checkout_response = cashier_client.post(
            reverse("order-checkout"),
            {"lines": [{"variant": variant.pk, "quantity": 2}]},
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
        self.product = create_product_with_default_variant(
            sku="COFFEE",
            barcode="",
            name="Coffee",
            unit_price=Decimal("3.50"),
        )
        self.variant = self.product.default_variant
        self.stock_item = StockItem.objects.create(
            variant=self.variant,
            quantity_on_hand=10,
        )

    def checkout_payload(self, **overrides):
        payload = {
            "lines": [{"variant": self.variant.pk, "quantity": 2}],
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

    def test_card_checkout_captures_card_and_mints_placeholder_customer(self):
        self.start_session()

        response = self.client.post(
            reverse("order-checkout"),
            self.checkout_payload(
                payments=[
                    {
                        "method": "card",
                        "amount": "7.00",
                        "card_receipt_url": _moamalat_receipt_url("7.000"),
                    }
                ],
            ),
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_201_CREATED, response.data)
        order = Order.objects.get(pk=response.data["id"])
        self.assertEqual(order.status, Order.Status.PAID)
        card = PaymentCard.objects.get()
        self.assertEqual(card.masked_pan, "639974*********8809")
        self.assertEqual(order.payments.get().card_id, card.pk)
        # A walk-in card sale adopts a hidden placeholder customer.
        self.assertEqual(order.customer_id, card.customer_id)
        self.assertTrue(order.customer.is_auto_created)

    def test_card_checkout_with_chosen_customer_skips_placeholder(self):
        self.start_session()
        customer = Customer.objects.create(full_name="Layla Ahmed")

        response = self.client.post(
            reverse("order-checkout"),
            self.checkout_payload(
                customer=customer.pk,
                payments=[
                    {
                        "method": "card",
                        "amount": "7.00",
                        "card_receipt_url": _moamalat_receipt_url("7.000"),
                    }
                ],
            ),
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_201_CREATED, response.data)
        order = Order.objects.get(pk=response.data["id"])
        card = PaymentCard.objects.get()
        self.assertEqual(card.customer_id, customer.pk)
        self.assertEqual(order.customer_id, customer.pk)
        self.assertFalse(Customer.objects.filter(is_auto_created=True).exists())

    def test_orders_cannot_be_deleted_or_edited_via_api_even_by_manager(self):
        # Create a paid order through checkout.
        self.start_session()
        checkout = self.client.post(
            reverse("order-checkout"),
            self.checkout_payload(),
            format="json",
        )
        self.assertEqual(checkout.status_code, status.HTTP_201_CREATED)
        order_id = checkout.data["id"]

        manager = get_user_model().objects.create_user(
            username="order-manager",
            password="pass",
        )
        manager.groups.add(Group.objects.get(name=MANAGER_GROUP))
        manager_client = APIClient()
        manager_client.force_authenticate(user=manager)

        original_total = Order.objects.get(pk=order_id).total
        delete_response = manager_client.delete(
            reverse("order-detail", args=[order_id])
        )
        patch_response = manager_client.patch(
            reverse("order-detail", args=[order_id]),
            {"total": "0.00"},
            format="json",
        )
        put_response = manager_client.put(
            reverse("order-detail", args=[order_id]),
            {"status": Order.Status.VOID},
            format="json",
        )

        # The write methods are not exposed; either the action is unmapped
        # (405) or the permission layer rejects it (403). Both deny the write.
        denied = {status.HTTP_403_FORBIDDEN, status.HTTP_405_METHOD_NOT_ALLOWED}
        self.assertIn(delete_response.status_code, denied)
        self.assertIn(patch_response.status_code, denied)
        self.assertIn(put_response.status_code, denied)
        # The order and its audit trail are untouched.
        order = Order.objects.get(pk=order_id)
        self.assertEqual(order.total, original_total)
        self.assertNotEqual(order.status, Order.Status.VOID)

    def test_order_lines_reject_product_aliases(self):
        order = Order.objects.create()

        with self.assertRaises(TypeError):
            OrderLine.objects.create(
                order=order,
                product=self.product,
                quantity=1,
                unit_price=Decimal("3.50"),
                unit_cost=Decimal("0.00"),
            )

        with self.assertRaises(FieldError):
            list(OrderLine.objects.filter(product=self.product))

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
        customer = Customer.objects.create(
            full_name="Layla Ahmed",
            phone="+218911234567",
            email="layla@example.com",
        )

        response = self.client.post(
            reverse("order-checkout"),
            self.checkout_payload(customer=customer.pk),
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_201_CREATED)
        self.assertEqual(response.data["register_session"], session["id"])
        self.assertEqual(response.data["register_session_number"], session["session_number"])
        self.assertEqual(response.data["customer"], customer.pk)
        self.assertEqual(response.data["customer_number"], customer.customer_number)
        self.assertEqual(response.data["customer_name"], "Layla Ahmed")
        self.assertEqual(response.data["customer_phone"], "+218911234567")
        self.assertEqual(response.data["customer_email"], "layla@example.com")
        self.assertEqual(response.data["subtotal"], "7.00")
        self.assertEqual(response.data["discount_total"], "0.00")
        self.assertEqual(response.data["total"], "7.00")
        self.assertEqual(response.data["applied_discounts"], [])
        self.assertNotIn("tax_total", response.data)
        self.assertNotIn("tax_rate", response.data["lines"][0])

        order = Order.objects.get(pk=response.data["id"])
        self.assertEqual(order.register_session_id, session["id"])
        self.assertEqual(order.customer_id, customer.pk)
        self.assertEqual(order.lines.get().unit_price, Decimal("3.50"))
        self.assertEqual(order.lines.get().discount_total, Decimal("0.00"))

    def test_checkout_exposes_public_invoice_url_when_enabled(self):
        self.start_session()
        ShopSettings.load()
        ShopSettings.objects.filter(pk=1).update(enable_online_invoices=True)
        RelayInstallation.objects.create(
            installation_id="installation-1",
            shop_name="متجر نقطة البيع",
            relay_public_api_url="https://relay.example",
            relay_connector_address="relay.example:443",
            connector_token="connector-token",
            access_token="access-token",
            relay_enabled=True,
            subscription_active=True,
        )

        response = self.client.post(
            reverse("order-checkout"),
            self.checkout_payload(),
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_201_CREATED)
        order = Order.objects.get(pk=response.data["id"])
        self.assertTrue(order.public_token)
        self.assertEqual(
            response.data["public_invoice_url"],
            f"https://relay.example/invoices/installation-1/{order.public_token}",
        )

    def test_checkout_hides_public_invoice_url_when_setting_disabled(self):
        self.start_session()
        RelayInstallation.objects.create(
            installation_id="installation-1",
            shop_name="متجر نقطة البيع",
            relay_public_api_url="https://relay.example",
            relay_connector_address="relay.example:443",
            connector_token="connector-token",
            access_token="access-token",
            relay_enabled=True,
            subscription_active=True,
        )

        response = self.client.post(
            reverse("order-checkout"),
            self.checkout_payload(),
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_201_CREATED)
        self.assertEqual(response.data["public_invoice_url"], "")

    def test_public_invoice_requires_relayed_request_and_enabled_setting(self):
        self.start_session()
        ShopSettings.load()
        ShopSettings.objects.filter(pk=1).update(
            enable_online_invoices=True,
            shop_name="متجر الاختبار",
            receipt_header="أهلا بكم",
            receipt_footer="شكرا لكم",
        )
        checkout_response = self.client.post(
            reverse("order-checkout"),
            self.checkout_payload(),
            format="json",
        )
        order = Order.objects.get(pk=checkout_response.data["id"])
        url = reverse("public-invoice-detail", args=[order.public_token])

        direct_response = APIClient().get(url)
        relayed_response = APIClient().get(url, HTTP_X_POINTY_RELAYED_REQUEST="1")

        self.assertEqual(direct_response.status_code, status.HTTP_404_NOT_FOUND)
        self.assertEqual(relayed_response.status_code, status.HTTP_200_OK)
        self.assertEqual(relayed_response.data["shop_name"], "متجر الاختبار")
        self.assertEqual(relayed_response.data["receipt_header"], "أهلا بكم")
        self.assertEqual(relayed_response.data["receipt_footer"], "شكرا لكم")
        self.assertEqual(relayed_response.data["receipt_number"], order.receipt_number)
        self.assertEqual(relayed_response.data["status"], Order.Status.PAID)
        self.assertEqual(relayed_response.data["subtotal"], "7.00")
        self.assertEqual(relayed_response.data["discount_total"], "0.00")
        self.assertEqual(relayed_response.data["total"], "7.00")
        self.assertEqual(float(relayed_response.data["lines"][0]["quantity"]), 2.0)
        # No logo configured: the field is present but empty.
        self.assertEqual(relayed_response.data["shop_logo_data_uri"], "")
        self.assertNotIn("total_profit", relayed_response.data)
        self.assertNotIn("payments", relayed_response.data)

        ShopSettings.objects.filter(pk=1).update(enable_online_invoices=False)
        disabled_response = APIClient().get(
            url,
            HTTP_X_POINTY_RELAYED_REQUEST="1",
        )
        self.assertEqual(disabled_response.status_code, status.HTTP_404_NOT_FOUND)

    def test_public_invoice_embeds_shop_logo_as_data_uri(self):
        import base64
        import tempfile
        from pathlib import Path

        from django.contrib.contenttypes.models import ContentType

        from apps.attachments.models import Attachment, StorageVolume

        self.start_session()
        settings = ShopSettings.load()
        ShopSettings.objects.filter(pk=1).update(enable_online_invoices=True)
        logo_content = b"\x89PNG-public-logo"
        temp_dir = tempfile.mkdtemp()
        Path(temp_dir, "logos").mkdir()
        Path(temp_dir, "logos", "logo.png").write_bytes(logo_content)
        volume = StorageVolume.objects.create(
            name="public-invoice-logo-volume",
            path=temp_dir,
        )
        Attachment.objects.create(
            owner_content_type=ContentType.objects.get_for_model(
                settings,
                for_concrete_model=False,
            ),
            owner_object_id=settings.pk,
            role=Attachment.Role.SHOP_LOGO,
            storage_volume=volume,
            relative_path="logos/logo.png",
            original_filename="logo.png",
            content_type="image/png",
            original_size=len(logo_content),
            stored_size=len(logo_content),
            checksum_sha256="c" * 64,
            is_primary=True,
        )
        checkout_response = self.client.post(
            reverse("order-checkout"),
            self.checkout_payload(),
            format="json",
        )
        order = Order.objects.get(pk=checkout_response.data["id"])

        response = APIClient().get(
            reverse("public-invoice-detail", args=[order.public_token]),
            HTTP_X_POINTY_RELAYED_REQUEST="1",
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        expected = (
            "data:image/png;base64,"
            + base64.b64encode(logo_content).decode("ascii")
        )
        self.assertEqual(response.data["shop_logo_data_uri"], expected)

    def test_checkout_exposes_cost_and_profit_snapshot(self):
        self.start_session()
        supplier = Supplier.objects.create(name="Profit supplier")
        first_purchase = PurchaseOrder.objects.create(
            supplier=supplier,
            status=PurchaseOrder.Status.RECEIVED,
        )
        first_purchase.lines.create(
            variant=self.variant,
            quantity=10,
            unit_cost=Decimal("2.00"),
        )

        response = self.client.post(
            reverse("order-checkout"),
            self.checkout_payload(),
            format="json",
        )

        later_purchase = PurchaseOrder.objects.create(
            supplier=supplier,
            status=PurchaseOrder.Status.RECEIVED,
        )
        later_purchase.lines.create(
            variant=self.variant,
            quantity=10,
            unit_cost=Decimal("2.75"),
        )
        detail_response = self.client.get(
            reverse("order-detail", args=[response.data["id"]]),
        )
        list_response = self.client.get(reverse("order-list"))

        self.assertEqual(response.status_code, status.HTTP_201_CREATED)
        self.assertEqual(response.data["lines"][0]["unit_cost"], "2.00")
        self.assertEqual(response.data["lines"][0]["line_cost"], "4.00")
        self.assertEqual(response.data["lines"][0]["line_profit"], "3.00")
        self.assertEqual(response.data["total_cost"], "4.00")
        self.assertEqual(response.data["total_profit"], "3.00")
        self.assertEqual(detail_response.data["lines"][0]["unit_cost"], "2.00")
        self.assertEqual(detail_response.data["total_profit"], "3.00")
        self.assertEqual(list_response.data["results"][0]["total_profit"], "3.00")

        order_line = Order.objects.get(pk=response.data["id"]).lines.get()
        self.assertEqual(order_line.unit_cost, Decimal("2.00"))

    def test_checkout_rejects_loss_sale_when_setting_is_enabled_by_default(self):
        self.start_session()
        supplier = Supplier.objects.create(name="Loss prevention supplier")
        purchase = PurchaseOrder.objects.create(
            supplier=supplier,
            status=PurchaseOrder.Status.RECEIVED,
        )
        purchase.lines.create(
            variant=self.variant,
            quantity=10,
            unit_cost=Decimal("4.00"),
        )

        response = self.client.post(
            reverse("order-checkout"),
            self.checkout_payload(),
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertEqual(response.data["code"], "sale_at_loss_blocked")
        self.assertEqual(len(response.data["loss"]), 1)
        loss_line = response.data["loss"][0]
        self.assertEqual(int(loss_line["variant_id"]), self.variant.pk)
        self.assertEqual(str(loss_line["line_total"]), "7.00")
        self.assertEqual(str(loss_line["line_cost"]), "8.00")
        self.assertEqual(str(loss_line["loss_amount"]), "1.00")
        self.assertEqual(Order.objects.count(), 0)
        self.assertEqual(Payment.objects.count(), 0)
        self.assertEqual(StockMovement.objects.count(), 0)
        self.stock_item.refresh_from_db()
        self.assertEqual(self.stock_item.quantity_on_hand, 10)

    def test_checkout_allows_loss_sale_when_setting_is_disabled(self):
        ShopSettings.load()
        ShopSettings.objects.filter(pk=1).update(prevent_selling_at_loss=False)
        self.start_session()
        supplier = Supplier.objects.create(name="Loss allowed supplier")
        purchase = PurchaseOrder.objects.create(
            supplier=supplier,
            status=PurchaseOrder.Status.RECEIVED,
        )
        purchase.lines.create(
            variant=self.variant,
            quantity=10,
            unit_cost=Decimal("4.00"),
        )

        response = self.client.post(
            reverse("order-checkout"),
            self.checkout_payload(),
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_201_CREATED)
        self.assertEqual(response.data["lines"][0]["line_profit"], "-1.00")
        self.assertEqual(response.data["total_profit"], "-1.00")
        self.stock_item.refresh_from_db()
        self.assertEqual(self.stock_item.quantity_on_hand, 8)

    def test_discount_preview_reports_loss_lines_from_current_costs(self):
        supplier = Supplier.objects.create(name="Preview loss supplier")
        purchase = PurchaseOrder.objects.create(
            supplier=supplier,
            status=PurchaseOrder.Status.RECEIVED,
        )
        purchase.lines.create(
            variant=self.variant,
            quantity=10,
            unit_cost=Decimal("3.00"),
        )
        DiscountRule.objects.create(
            name="Preview loss discount",
            channel=DiscountRule.Channel.SALES,
            value_type=DiscountRule.ValueType.FIXED_AMOUNT,
            value=Decimal("2.00"),
        )

        response = self.client.post(
            reverse("order-discount-preview"),
            {"lines": [{"variant": self.variant.pk, "quantity": 2}]},
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(response.data["subtotal"], "7.00")
        self.assertEqual(response.data["discount_total"], "2.00")
        self.assertEqual(len(response.data["loss_lines"]), 1)
        loss_line = response.data["loss_lines"][0]
        self.assertEqual(loss_line["variant_id"], self.variant.pk)
        self.assertEqual(loss_line["line_total"], "5.00")
        self.assertEqual(loss_line["line_cost"], "6.00")
        self.assertEqual(loss_line["loss_amount"], "1.00")

    def test_checkout_prices_costs_and_stocks_the_exact_variant(self):
        variant = ProductVariant.objects.create(
            product=self.product,
            name="Large",
            sku="COFFEE-L",
            unit_price=Decimal("5.75"),
        )
        variant_stock = StockItem.objects.create(
            variant=variant,
            quantity_on_hand=6,
        )
        supplier = Supplier.objects.create(name="Variant cost supplier")
        default_purchase = PurchaseOrder.objects.create(
            supplier=supplier,
            status=PurchaseOrder.Status.RECEIVED,
        )
        default_purchase.lines.create(
            variant=self.variant,
            quantity=10,
            unit_cost=Decimal("2.00"),
        )
        variant_purchase = PurchaseOrder.objects.create(
            supplier=supplier,
            status=PurchaseOrder.Status.RECEIVED,
        )
        variant_purchase.lines.create(
            variant=variant,
            quantity=10,
            unit_cost=Decimal("4.25"),
        )
        self.start_session()

        response = self.client.post(
            reverse("order-checkout"),
            {
                "lines": [{"variant": variant.pk, "quantity": 2}],
                "payment_method": "cash",
                "amount_received": "11.50",
            },
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_201_CREATED)
        line = response.data["lines"][0]
        self.assertEqual(line["product"], self.product.pk)
        self.assertEqual(line["variant"], variant.pk)
        self.assertEqual(line["unit_price"], "5.75")
        self.assertEqual(line["unit_cost"], "4.25")
        self.assertEqual(line["line_cost"], "8.50")
        self.assertEqual(line["line_profit"], "3.00")
        self.stock_item.refresh_from_db()
        variant_stock.refresh_from_db()
        self.assertEqual(self.stock_item.quantity_on_hand, 10)
        self.assertEqual(variant_stock.quantity_on_hand, 4)

        order_line = Order.objects.get(pk=response.data["id"]).lines.get()
        self.assertEqual(order_line.variant_id, variant.pk)
        self.assertEqual(order_line.unit_cost, Decimal("4.25"))

    def test_checkout_shortages_are_grouped_by_variant(self):
        variant = ProductVariant.objects.create(
            product=self.product,
            name="Small",
            sku="COFFEE-S",
            unit_price=Decimal("3.50"),
        )
        StockItem.objects.create(variant=variant, quantity_on_hand=4)
        self.start_session()

        response = self.client.post(
            reverse("order-checkout"),
            {
                "lines": [
                    {"variant": variant.pk, "quantity": 2},
                    {"variant": variant.pk, "quantity": 3},
                ],
                "payment_method": "cash",
                "amount_received": "17.50",
            },
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertEqual(len(response.data["stock"]), 1)
        shortage = response.data["stock"][0]
        self.assertEqual(int(shortage["product_id"]), self.product.pk)
        self.assertEqual(int(shortage["variant_id"]), variant.pk)
        self.assertEqual(shortage["variant_name"], "Coffee - Small")
        self.assertEqual(float(shortage["requested"]), 5.0)
        self.assertEqual(float(shortage["available"]), 4.0)

    def test_checkout_creates_paid_order_and_payment(self):
        self.start_session()

        response = self.client.post(
            reverse("order-checkout"),
            {
                "lines": [{"variant": self.variant.pk, "quantity": 2}],
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

    def test_checkout_replay_with_idempotency_key_returns_same_order(self):
        self.start_session()
        payload = self.checkout_payload()

        first_response = self.client.post(
            reverse("order-checkout"),
            payload,
            format="json",
            HTTP_IDEMPOTENCY_KEY="checkout-retry-1",
        )
        second_response = self.client.post(
            reverse("order-checkout"),
            payload,
            format="json",
            HTTP_IDEMPOTENCY_KEY="checkout-retry-1",
        )

        self.assertEqual(first_response.status_code, status.HTTP_201_CREATED)
        self.assertEqual(second_response.status_code, status.HTTP_201_CREATED)
        self.assertEqual(first_response["Idempotency-Replayed"], "false")
        self.assertEqual(second_response["Idempotency-Replayed"], "true")
        self.assertEqual(first_response.data["id"], second_response.data["id"])
        self.assertEqual(Order.objects.count(), 1)
        self.assertEqual(Payment.objects.count(), 1)
        self.assertEqual(StockMovement.objects.count(), 1)
        self.stock_item.refresh_from_db()
        self.assertEqual(self.stock_item.quantity_on_hand, 8)

        record = IdempotencyRecord.objects.get()
        self.assertEqual(record.replay_count, 1)

    def test_checkout_rejects_idempotency_key_reused_with_different_body(self):
        self.start_session()

        first_response = self.client.post(
            reverse("order-checkout"),
            self.checkout_payload(),
            format="json",
            HTTP_IDEMPOTENCY_KEY="checkout-conflict",
        )
        conflict_response = self.client.post(
            reverse("order-checkout"),
            self.checkout_payload(
                lines=[{"variant": self.variant.pk, "quantity": 1}],
                amount_received="3.50",
            ),
            format="json",
            HTTP_IDEMPOTENCY_KEY="checkout-conflict",
        )

        self.assertEqual(first_response.status_code, status.HTTP_201_CREATED)
        self.assertEqual(conflict_response.status_code, status.HTTP_409_CONFLICT)
        self.assertEqual(Order.objects.count(), 1)
        self.assertEqual(Payment.objects.count(), 1)

    def test_checkout_applies_automatic_document_percentage_discount(self):
        DiscountRule.objects.create(
            name="Ten percent sale",
            channel=DiscountRule.Channel.SALES,
            value_type=DiscountRule.ValueType.PERCENTAGE,
            value=Decimal("10.00"),
        )
        self.start_session()

        response = self.client.post(
            reverse("order-checkout"),
            self.checkout_payload(amount_received="6.30"),
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_201_CREATED)
        self.assertEqual(response.data["subtotal"], "7.00")
        self.assertEqual(response.data["discount_total"], "0.70")
        self.assertEqual(response.data["total"], "6.30")
        self.assertEqual(response.data["lines"][0]["line_subtotal"], "7.00")
        self.assertEqual(response.data["lines"][0]["discount_total"], "0.70")
        self.assertEqual(response.data["lines"][0]["line_total"], "6.30")
        self.assertEqual(response.data["total_profit"], "6.30")

        order = Order.objects.get(pk=response.data["id"])
        self.assertEqual(order.discount_total, Decimal("0.70"))
        self.assertEqual(order.lines.get().discount_total, Decimal("0.70"))
        self.assertEqual(Payment.objects.get(order=order).amount, Decimal("6.30"))
        snapshot = AppliedDiscount.objects.get()
        redemption = DiscountRedemption.objects.get()
        self.assertEqual(snapshot.document, order)
        self.assertEqual(snapshot.discount_amount, Decimal("0.70"))
        self.assertEqual(snapshot.allocations[0]["line_object_id"], order.lines.get().pk)
        self.assertEqual(redemption.applied_discount, snapshot)

    def test_checkout_applies_coupon_discount(self):
        DiscountRule.objects.create(
            name="Coupon one dinar",
            channel=DiscountRule.Channel.SALES,
            application_type=DiscountRule.ApplicationType.COUPON_CODE,
            coupon_code="save1",
            value_type=DiscountRule.ValueType.FIXED_AMOUNT,
            value=Decimal("1.00"),
        )
        self.start_session()

        response = self.client.post(
            reverse("order-checkout"),
            self.checkout_payload(coupon_code=" SAVE1 ", amount_received="6.00"),
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_201_CREATED)
        self.assertEqual(response.data["discount_total"], "1.00")
        self.assertEqual(response.data["total"], "6.00")
        self.assertEqual(response.data["applied_discounts"][0]["coupon_code"], "SAVE1")
        self.assertEqual(AppliedDiscount.objects.get().coupon_code, "SAVE1")

    def test_checkout_rejects_invalid_disabled_and_expired_coupon_codes(self):
        DiscountRule.objects.create(
            name="Disabled coupon",
            channel=DiscountRule.Channel.SALES,
            application_type=DiscountRule.ApplicationType.COUPON_CODE,
            coupon_code="OFF",
            value_type=DiscountRule.ValueType.FIXED_AMOUNT,
            value=Decimal("1.00"),
            is_active=False,
        )
        DiscountRule.objects.create(
            name="Expired coupon",
            channel=DiscountRule.Channel.SALES,
            application_type=DiscountRule.ApplicationType.COUPON_CODE,
            coupon_code="OLD",
            value_type=DiscountRule.ValueType.FIXED_AMOUNT,
            value=Decimal("1.00"),
            ends_at=timezone.now() - timedelta(days=1),
        )
        self.start_session()

        for coupon_code in ("MISSING", "OFF", "OLD"):
            with self.subTest(coupon_code=coupon_code):
                response = self.client.post(
                    reverse("order-checkout"),
                    self.checkout_payload(coupon_code=coupon_code),
                    format="json",
                )

                self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
                self.assertIn("coupon_codes", response.data)

        self.assertEqual(Order.objects.count(), 0)
        self.assertEqual(AppliedDiscount.objects.count(), 0)

    def test_checkout_applies_line_and_document_discounts_when_stackable(self):
        line_rule = DiscountRule.objects.create(
            name="Line unit off",
            channel=DiscountRule.Channel.SALES,
            scope=DiscountRule.Scope.LINE,
            value_type=DiscountRule.ValueType.FIXED_UNIT_AMOUNT,
            value=Decimal("1.00"),
            priority=1,
            exclusive=False,
        )
        line_rule.products.add(self.product)
        DiscountRule.objects.create(
            name="Document half off",
            channel=DiscountRule.Channel.SALES,
            value_type=DiscountRule.ValueType.FIXED_AMOUNT,
            value=Decimal("0.50"),
            priority=2,
            exclusive=False,
        )
        self.start_session()

        response = self.client.post(
            reverse("order-checkout"),
            self.checkout_payload(amount_received="4.50"),
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_201_CREATED)
        self.assertEqual(response.data["subtotal"], "7.00")
        self.assertEqual(response.data["discount_total"], "2.50")
        self.assertEqual(response.data["total"], "4.50")
        self.assertEqual(response.data["lines"][0]["discount_total"], "2.50")
        self.assertEqual(
            [discount["rule_name"] for discount in response.data["applied_discounts"]],
            ["Line unit off", "Document half off"],
        )

    def test_checkout_respects_non_stacking_priority(self):
        DiscountRule.objects.create(
            name="First exclusive",
            channel=DiscountRule.Channel.SALES,
            value_type=DiscountRule.ValueType.FIXED_AMOUNT,
            value=Decimal("1.00"),
            priority=1,
        )
        DiscountRule.objects.create(
            name="Skipped later",
            channel=DiscountRule.Channel.SALES,
            value_type=DiscountRule.ValueType.FIXED_AMOUNT,
            value=Decimal("5.00"),
            priority=2,
        )
        self.start_session()

        response = self.client.post(
            reverse("order-checkout"),
            self.checkout_payload(amount_received="6.00"),
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_201_CREATED)
        self.assertEqual(response.data["discount_total"], "1.00")
        self.assertEqual(response.data["total"], "6.00")
        self.assertEqual(
            [discount["rule_name"] for discount in response.data["applied_discounts"]],
            ["First exclusive"],
        )

    def test_checkout_respects_coupon_usage_limit_after_redemption(self):
        DiscountRule.objects.create(
            name="Single use coupon",
            channel=DiscountRule.Channel.SALES,
            application_type=DiscountRule.ApplicationType.COUPON_CODE,
            coupon_code="ONCE",
            value_type=DiscountRule.ValueType.FIXED_AMOUNT,
            value=Decimal("1.00"),
            usage_limit=1,
        )
        self.start_session()

        first_response = self.client.post(
            reverse("order-checkout"),
            self.checkout_payload(coupon_code="once", amount_received="6.00"),
            format="json",
        )
        second_response = self.client.post(
            reverse("order-checkout"),
            self.checkout_payload(coupon_code="once", amount_received="6.00"),
            format="json",
        )

        self.assertEqual(first_response.status_code, status.HTTP_201_CREATED)
        self.assertEqual(first_response.data["discount_total"], "1.00")
        self.assertEqual(second_response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertIn("coupon_codes", second_response.data)
        self.assertEqual(Order.objects.count(), 1)
        self.assertEqual(DiscountRedemption.objects.count(), 1)

    def test_checkout_applies_customer_product_and_minimum_subtotal_restrictions(self):
        customer = Customer.objects.create(full_name="Eligible buyer")
        other_customer = Customer.objects.create(full_name="Other buyer")
        other_product = create_product_with_default_variant(
            sku="MUFFIN",
            barcode="",
            name="Muffin",
            unit_price=Decimal("5.00"),
        )
        other_variant = other_product.default_variant
        StockItem.objects.create(variant=other_variant, quantity_on_hand=5)
        rule = DiscountRule.objects.create(
            name="Coffee buyer coupon",
            channel=DiscountRule.Channel.SALES,
            application_type=DiscountRule.ApplicationType.COUPON_CODE,
            coupon_code="BUYER",
            scope=DiscountRule.Scope.LINE,
            value_type=DiscountRule.ValueType.PERCENTAGE,
            value=Decimal("10.00"),
            min_order_subtotal=Decimal("10.00"),
        )
        rule.products.add(self.product)
        rule.customers.add(customer)
        self.start_session()

        wrong_customer_response = self.client.post(
            reverse("order-checkout"),
            self.checkout_payload(
                customer=other_customer.pk,
                coupon_code="BUYER",
                amount_received="7.00",
            ),
            format="json",
        )
        below_minimum_response = self.client.post(
            reverse("order-checkout"),
            {
                "lines": [{"variant": self.variant.pk, "quantity": 2}],
                "customer": customer.pk,
                "coupon_code": "BUYER",
                "payment_method": "cash",
                "amount_received": "7.00",
            },
            format="json",
        )
        eligible_response = self.client.post(
            reverse("order-checkout"),
            {
                "lines": [
                    {"variant": self.variant.pk, "quantity": 2},
                    {"variant": other_variant.pk, "quantity": 1},
                ],
                "customer": customer.pk,
                "coupon_code": "BUYER",
                "payment_method": "cash",
                "amount_received": "11.30",
            },
            format="json",
        )

        self.assertEqual(wrong_customer_response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertIn("coupon_codes", wrong_customer_response.data)
        self.assertEqual(below_minimum_response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertIn("coupon_codes", below_minimum_response.data)
        self.assertEqual(eligible_response.status_code, status.HTTP_201_CREATED)
        self.assertEqual(eligible_response.data["subtotal"], "12.00")
        self.assertEqual(eligible_response.data["discount_total"], "0.70")
        self.assertEqual(eligible_response.data["total"], "11.30")
        lines = sorted(eligible_response.data["lines"], key=lambda line: line["product"])
        self.assertEqual(lines[0]["discount_total"], "0.70")
        self.assertEqual(lines[1]["discount_total"], "0.00")

    def test_order_list_filters_by_customer(self):
        self.start_session()
        first_customer = Customer.objects.create(full_name="First customer")
        second_customer = Customer.objects.create(full_name="Second customer")
        first_response = self.client.post(
            reverse("order-checkout"),
            self.checkout_payload(customer=first_customer.pk),
            format="json",
        )
        second_response = self.client.post(
            reverse("order-checkout"),
            self.checkout_payload(customer=second_customer.pk),
            format="json",
        )

        response = self.client.get(
            reverse("order-list"),
            {"customer": first_customer.pk},
        )

        self.assertEqual(first_response.status_code, status.HTTP_201_CREATED)
        self.assertEqual(second_response.status_code, status.HTTP_201_CREATED)
        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(len(response.data["results"]), 1)
        self.assertEqual(response.data["results"][0]["id"], first_response.data["id"])
        self.assertEqual(response.data["results"][0]["customer"], first_customer.pk)

    def test_order_list_filters_by_product_and_variant_without_duplicates(self):
        self.start_session()
        large_variant = ProductVariant.objects.create(
            product=self.product,
            name="Large",
            sku="COFFEE-L",
            unit_price=Decimal("5.00"),
        )
        StockItem.objects.create(variant=large_variant, quantity_on_hand=10)
        other_product = create_product_with_default_variant(
            sku="TEA",
            barcode="",
            name="Tea",
            unit_price=Decimal("2.00"),
        )
        StockItem.objects.create(
            variant=other_product.default_variant,
            quantity_on_hand=10,
        )
        coffee_response = self.client.post(
            reverse("order-checkout"),
            {
                "lines": [
                    {"variant": self.variant.pk, "quantity": 1},
                    {"variant": large_variant.pk, "quantity": 1},
                ],
                "payment_method": "cash",
                "amount_received": "8.50",
            },
            format="json",
        )
        tea_response = self.client.post(
            reverse("order-checkout"),
            {
                "lines": [{"variant": other_product.default_variant.pk, "quantity": 1}],
                "payment_method": "cash",
                "amount_received": "2.00",
            },
            format="json",
        )

        product_response = self.client.get(
            reverse("order-list"),
            {"product": self.product.pk},
        )
        variant_response = self.client.get(
            reverse("order-list"),
            {"product": self.product.pk, "variant": large_variant.pk},
        )

        self.assertEqual(coffee_response.status_code, status.HTTP_201_CREATED)
        self.assertEqual(tea_response.status_code, status.HTTP_201_CREATED)
        self.assertEqual(product_response.status_code, status.HTTP_200_OK)
        self.assertEqual(
            [order["id"] for order in product_response.data["results"]],
            [coffee_response.data["id"]],
        )
        self.assertEqual(variant_response.status_code, status.HTTP_200_OK)
        self.assertEqual(
            [order["id"] for order in variant_response.data["results"]],
            [coffee_response.data["id"]],
        )

    def test_session_orders_filters_by_customer(self):
        session = self.start_session()
        first_customer = Customer.objects.create(full_name="Session first customer")
        second_customer = Customer.objects.create(full_name="Session second customer")
        first_response = self.client.post(
            reverse("order-checkout"),
            self.checkout_payload(customer=first_customer.pk),
            format="json",
        )
        second_response = self.client.post(
            reverse("order-checkout"),
            self.checkout_payload(customer=second_customer.pk),
            format="json",
        )

        response = self.client.get(
            reverse("register-session-orders", args=[session["id"]]),
            {"customer": first_customer.pk},
        )

        self.assertEqual(first_response.status_code, status.HTTP_201_CREATED)
        self.assertEqual(second_response.status_code, status.HTTP_201_CREATED)
        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(len(response.data["results"]), 1)
        self.assertEqual(response.data["results"][0]["id"], first_response.data["id"])
        self.assertEqual(response.data["results"][0]["customer"], first_customer.pk)

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

    def test_checkout_rejects_split_payment_over_total(self):
        self.start_session()

        response = self.client.post(
            reverse("order-checkout"),
            self.checkout_payload(
                payments=[
                    {"method": Payment.Method.CASH, "amount": "2.00"},
                    {"method": Payment.Method.CARD, "amount": "6.00"},
                ],
            ),
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertIn("payments", response.data)
        self.assertEqual(Order.objects.count(), 0)
        self.assertEqual(Payment.objects.count(), 0)
        self.assertEqual(StockMovement.objects.count(), 0)

    def test_checkout_rejects_single_payment_over_total(self):
        self.start_session()

        response = self.client.post(
            reverse("order-checkout"),
            self.checkout_payload(amount_received="8.00"),
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertIn("payments", response.data)
        self.assertEqual(Order.objects.count(), 0)
        self.assertEqual(Payment.objects.count(), 0)
        self.assertEqual(StockMovement.objects.count(), 0)

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
        self.assertEqual(movement.variant.product, self.product)
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

    def test_return_revalidates_stale_line_quantity_before_restocking(self):
        self.start_session()
        checkout_response = self.client.post(
            reverse("order-checkout"),
            self.checkout_payload(),
            format="json",
        )
        order = Order.objects.get(pk=checkout_response.data["id"])
        stale_line = order.lines.get()

        return_order_items(
            order=order,
            lines=[(stale_line, 1)],
            reason="First return",
        )

        with self.assertRaises(serializers.ValidationError):
            return_order_items(
                order=order,
                lines=[(stale_line, 2)],
                reason="Stale return",
            )

        self.stock_item.refresh_from_db()
        self.assertEqual(self.stock_item.quantity_on_hand, 9)
        self.assertEqual(OrderAdjustment.objects.count(), 1)

    def test_partial_return_refunds_discounted_net_amount(self):
        DiscountRule.objects.create(
            name="Ten percent return",
            channel=DiscountRule.Channel.SALES,
            value_type=DiscountRule.ValueType.PERCENTAGE,
            value=Decimal("10.00"),
        )
        self.start_session()
        checkout_response = self.client.post(
            reverse("order-checkout"),
            self.checkout_payload(amount_received="6.30"),
            format="json",
        )
        line_id = checkout_response.data["lines"][0]["id"]

        response = self.client.post(
            reverse("order-return-items", args=[checkout_response.data["id"]]),
            {"lines": [{"line": line_id, "quantity": 1}]},
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        adjustment = OrderAdjustment.objects.get()
        self.assertEqual(adjustment.amount, Decimal("3.15"))
        adjustment_line = adjustment.lines.get()
        self.assertEqual(adjustment_line.unit_price, Decimal("3.50"))
        self.assertEqual(adjustment_line.discount_total, Decimal("0.35"))
        self.assertEqual(adjustment_line.line_total, Decimal("3.15"))
        self.assertEqual(
            Payment.objects.order_by("amount").first().amount,
            Decimal("-3.15"),
        )

    def test_void_refunds_discounted_remaining_amount_after_partial_return(self):
        DiscountRule.objects.create(
            name="Ten percent void",
            channel=DiscountRule.Channel.SALES,
            value_type=DiscountRule.ValueType.PERCENTAGE,
            value=Decimal("10.00"),
        )
        self.start_session()
        checkout_response = self.client.post(
            reverse("order-checkout"),
            self.checkout_payload(amount_received="6.30"),
            format="json",
        )
        line_id = checkout_response.data["lines"][0]["id"]
        self.client.post(
            reverse("order-return-items", args=[checkout_response.data["id"]]),
            {"lines": [{"line": line_id, "quantity": 1}]},
            format="json",
        )

        response = self.client.post(
            reverse("order-void", args=[checkout_response.data["id"]]),
            {"reason": "Void remainder"},
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(response.data["status"], Order.Status.VOID)
        adjustments = list(OrderAdjustment.objects.order_by("created_at"))
        self.assertEqual(adjustments[0].amount, Decimal("3.15"))
        self.assertEqual(adjustments[1].amount, Decimal("3.15"))
        self.assertEqual(
            list(Payment.objects.filter(amount__lt=0).order_by("created_at").values_list("amount", flat=True)),
            [Decimal("-3.15"), Decimal("-3.15")],
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
            self.checkout_payload(lines=[{"variant": self.variant.pk, "quantity": 0}]),
            format="json",
        )

        self.assertEqual(empty_response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertEqual(quantity_response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertIn("lines", empty_response.data)
        self.assertIn("lines", quantity_response.data)


class ModifierCheckoutApiTests(TestCase):
    def setUp(self):
        ensure_role_groups()
        self.client = APIClient()
        self.user = get_user_model().objects.create_user(
            username="mod-cashier", password="pass"
        )
        self.user.groups.add(Group.objects.get(name=CASHIER_GROUP))
        self.client.force_authenticate(user=self.user)

        self.product = create_product_with_default_variant(
            sku="COFFEE-M", name="Coffee", unit_price=Decimal("3.50")
        )
        self.variant = self.product.default_variant
        StockItem.objects.create(variant=self.variant, quantity_on_hand=20)

        # Optional multi-select group with a quantifiable, priced option.
        self.extras = ModifierGroup.objects.create(
            name="Extras", min_select=0, max_select=None
        )
        self.extra_shot = ModifierOption.objects.create(
            group=self.extras,
            name="Extra shot",
            price_delta=Decimal("0.50"),
            max_quantity=3,
        )
        # Required single-select group with a default.
        self.milk = ModifierGroup.objects.create(
            name="Milk", min_select=1, max_select=1
        )
        self.whole = ModifierOption.objects.create(
            group=self.milk, name="Whole", is_default=True
        )
        self.oat = ModifierOption.objects.create(
            group=self.milk, name="Oat", price_delta=Decimal("0.30")
        )
        for order, group in enumerate((self.milk, self.extras)):
            ProductModifierGroup.objects.create(
                product=self.product, group=group, display_order=order
            )

        self.client.post(
            reverse("register-session-start"),
            {"opening_cash": "0.00"},
            format="json",
        )

    def _checkout(self, modifiers, amount):
        return self.client.post(
            reverse("order-checkout"),
            {
                "lines": [
                    {
                        "variant": self.variant.pk,
                        "quantity": 2,
                        "modifiers": modifiers,
                    }
                ],
                "payment_method": "cash",
                "amount_received": amount,
            },
            format="json",
        )

    def test_modifier_deltas_price_into_the_line_and_total(self):
        response = self._checkout(
            [
                {"option": self.whole.pk},
                {"option": self.extra_shot.pk, "quantity": 2},
            ],
            # (3.50 base + 0.50×2 extra shot + 0.00 whole) × 2 = 9.00
            amount="9.00",
        )

        self.assertEqual(response.status_code, status.HTTP_201_CREATED, response.data)
        order = Order.objects.get(pk=response.data["id"])
        line = order.lines.get()
        self.assertEqual(line.unit_price, Decimal("4.50"))
        self.assertEqual(order.total, Decimal("9.00"))
        shot = line.modifiers.get(option_name="Extra shot")
        self.assertEqual(shot.quantity, 2)
        self.assertEqual(shot.unit_price_delta, Decimal("0.50"))
        self.assertEqual(shot.group_name, "Extras")

    def test_required_group_must_be_satisfied(self):
        # No Milk choice → the required single-select group is unsatisfied.
        response = self._checkout([], amount="7.00")
        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)

    def test_option_must_belong_to_the_products_groups(self):
        foreign = ModifierGroup.objects.create(name="Syrups")
        foreign_option = ModifierOption.objects.create(
            group=foreign, name="Vanilla", price_delta=Decimal("1.00")
        )
        response = self._checkout(
            [{"option": self.whole.pk}, {"option": foreign_option.pk}],
            amount="7.00",
        )
        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)

    def test_quantity_capped_at_option_max_quantity(self):
        response = self._checkout(
            [{"option": self.whole.pk}, {"option": self.extra_shot.pk, "quantity": 5}],
            amount="100.00",
        )
        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)

    def test_single_select_group_rejects_two_choices(self):
        response = self._checkout(
            [{"option": self.whole.pk}, {"option": self.oat.pk}],
            amount="100.00",
        )
        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)


class ModifierGroupApiTests(TestCase):
    def setUp(self):
        ensure_role_groups()
        self.manager = get_user_model().objects.create_user(
            username="mod-manager", password="pass"
        )
        self.manager.groups.add(Group.objects.get(name=MANAGER_GROUP))
        self.manager_client = APIClient()
        self.manager_client.force_authenticate(user=self.manager)
        self.cashier = get_user_model().objects.create_user(
            username="mod-cashier2", password="pass"
        )
        self.cashier.groups.add(Group.objects.get(name=CASHIER_GROUP))
        self.cashier_client = APIClient()
        self.cashier_client.force_authenticate(user=self.cashier)

    def test_manager_creates_group_with_nested_options(self):
        response = self.manager_client.post(
            reverse("modifiergroup-list"),
            {
                "name": "Milk",
                "min_select": 1,
                "max_select": 1,
                "options": [
                    {"name": "Whole", "is_default": True},
                    {"name": "Oat", "price_delta": "0.30"},
                ],
            },
            format="json",
        )
        self.assertEqual(response.status_code, status.HTTP_201_CREATED, response.data)
        group = ModifierGroup.objects.get(pk=response.data["id"])
        self.assertEqual(group.options.count(), 2)

    def test_cashier_cannot_manage_modifier_groups(self):
        response = self.cashier_client.post(
            reverse("modifiergroup-list"),
            {"name": "Milk", "options": []},
            format="json",
        )
        self.assertEqual(response.status_code, status.HTTP_403_FORBIDDEN)


class OrderListQueryCountTests(TestCase):
    """Guards the orders-list against re-introducing an N+1: the query count
    must stay constant as the number of orders on the page grows."""

    def setUp(self):
        ensure_role_groups()
        User = get_user_model()
        self.cashier = User.objects.create_user(username="nplus1-cashier", password="pass")
        self.cashier.groups.add(Group.objects.get(name=CASHIER_GROUP))
        self.manager = User.objects.create_user(username="nplus1-manager", password="pass")
        self.manager.groups.add(Group.objects.get(name=MANAGER_GROUP))
        product = create_product_with_default_variant(
            sku="NPLUS1",
            barcode="",
            name="N+1 guard coffee",
            unit_price=Decimal("4.00"),
        )
        self.variant = product.default_variant
        StockItem.objects.create(variant=self.variant, quantity_on_hand=1000)
        self.cashier_client = APIClient()
        self.cashier_client.force_authenticate(user=self.cashier)
        self.cashier_client.post(
            reverse("register-session-start"),
            {"opening_cash": "0.00"},
            format="json",
        )

    def _checkout_order(self):
        response = self.cashier_client.post(
            reverse("order-checkout"),
            {"lines": [{"variant": self.variant.pk, "quantity": 1}]},
            format="json",
        )
        self.assertEqual(response.status_code, status.HTTP_201_CREATED)

    def test_order_list_query_count_does_not_grow_with_orders(self):
        manager_client = APIClient()
        manager_client.force_authenticate(user=self.manager)

        for _ in range(2):
            self._checkout_order()
        with CaptureQueriesContext(connection) as few_orders:
            few_response = manager_client.get(reverse("order-list"))

        for _ in range(3):
            self._checkout_order()
        with CaptureQueriesContext(connection) as more_orders:
            more_response = manager_client.get(reverse("order-list"))

        self.assertEqual(few_response.status_code, status.HTTP_200_OK)
        self.assertEqual(more_response.status_code, status.HTTP_200_OK)
        self.assertEqual(len(few_response.data["results"]), 2)
        self.assertEqual(len(more_response.data["results"]), 5)
        # Prefetching + context-cached settings/role keep the orders list at a
        # constant number of queries; an N+1 over lines, payments, applied
        # discounts, returned quantities, variant option labels, the shop
        # settings, or the manager check would make the five-order page issue
        # strictly more queries than the two-order page.
        self.assertEqual(len(few_orders), len(more_orders))


class StockReservationTests(TestCase):
    """A quotation hold blocks others from the reserved units (availability =
    on-hand − committed) without moving on-hand, and releasing restores it."""

    def setUp(self):
        ShopSettings.objects.update_or_create(
            pk=1, defaults={"allow_overselling": False}
        )
        self.product = create_product_with_default_variant(
            sku="RESV", name="سلعة محجوزة", unit_price=Decimal("5.00")
        )
        self.variant = self.product.default_variant
        self.stock, _ = StockItem.objects.update_or_create(
            variant=self.variant,
            defaults={"quantity_on_hand": Decimal("10.000")},
        )

    def _quote(self, qty):
        order = Order.objects.create(
            sale_type=Order.SaleType.QUOTATION,
            subtotal=Decimal("5.00") * qty,
            total=Decimal("5.00") * qty,
        )
        OrderLine.objects.create(
            order=order,
            variant=self.variant,
            quantity=Decimal(qty),
            unit_price=Decimal("5.00"),
        )
        return order

    def test_reserve_holds_committed_without_moving_on_hand(self):
        order = self._quote(3)
        reserve_stock_for_quote(order)
        self.stock.refresh_from_db()
        self.assertEqual(self.stock.quantity_on_hand, Decimal("10.000"))
        self.assertEqual(self.stock.quantity_committed, Decimal("3.000"))
        self.assertEqual(
            order.stock_reservations.filter(
                status=StockReservation.Status.ACTIVE
            ).count(),
            1,
        )

    def test_reservation_blocks_others_from_held_units(self):
        reserve_stock_for_quote(self._quote(8))
        # Only 2 of 10 remain sellable once 8 are committed.
        with self.assertRaises(serializers.ValidationError):
            prepare_sale_stock_adjustments(
                [{"variant": self.variant, "quantity": Decimal("3")}]
            )
        adjustments = prepare_sale_stock_adjustments(
            [{"variant": self.variant, "quantity": Decimal("2")}]
        )
        self.assertEqual(len(adjustments), 1)

    def test_release_restores_availability(self):
        order = self._quote(4)
        reserve_stock_for_quote(order)
        release_quote_reservations(order)
        self.stock.refresh_from_db()
        self.assertEqual(self.stock.quantity_committed, Decimal("0.000"))
        self.assertEqual(
            order.stock_reservations.filter(
                status=StockReservation.Status.RELEASED
            ).count(),
            1,
        )

    def _reserving_quote(self, qty, *, valid_until):
        order = self._quote(qty)
        order.reserves_stock = True
        order.valid_until = valid_until
        order.save(update_fields=["reserves_stock", "valid_until"])
        reserve_stock_for_quote(order)
        return order

    def test_scheduled_task_releases_only_lapsed_quotation_reservations(self):
        today = timezone.localdate()
        # Lapsed yesterday → its hold must be freed automatically.
        expired = self._reserving_quote(4, valid_until=today - timedelta(days=1))
        # Valid through today → kept until tomorrow (boundary: valid_until == today).
        still_valid = self._reserving_quote(2, valid_until=today)

        self.stock.refresh_from_db()
        self.assertEqual(self.stock.quantity_committed, Decimal("6.000"))

        # Drive the actual Celery beat entrypoint, not just the service.
        released = sales_tasks.release_expired_quote_reservations()

        self.assertEqual(released, 1)
        self.stock.refresh_from_db()
        # Only the lapsed quotation's 4 units return to availability.
        self.assertEqual(self.stock.quantity_committed, Decimal("2.000"))
        self.assertEqual(
            expired.stock_reservations.filter(
                status=StockReservation.Status.RELEASED
            ).count(),
            1,
        )
        self.assertEqual(
            still_valid.stock_reservations.filter(
                status=StockReservation.Status.ACTIVE
            ).count(),
            1,
        )


class CreditAndQuotationCheckoutTests(TestCase):
    """End-to-end checkout for debt (آجل) and quotation (عرض سعر) sale types:
    accrual recognition, partial down-payments, stock isolation, the
    customer-required gate, and per-type payment rules."""

    def setUp(self):
        ensure_role_groups()
        self.client = APIClient()
        self.user = get_user_model().objects.create_user(
            username="credit-cashier", password="pass"
        )
        self.user.groups.add(Group.objects.get(name=CASHIER_GROUP))
        self.client.force_authenticate(user=self.user)
        self.product = create_product_with_default_variant(
            sku="WIDGET", barcode="", name="Widget", unit_price=Decimal("3.50")
        )
        self.variant = self.product.default_variant
        self.stock_item = StockItem.objects.create(
            variant=self.variant, quantity_on_hand=10
        )
        self.customer = Customer.objects.create(full_name="Debt Customer")
        session_id = self.client.post(
            reverse("register-session-start"),
            {"opening_cash": "0.00"},
            format="json",
        ).data["id"]
        self.session = RegisterSession.objects.get(pk=session_id)

    def _checkout(self, **overrides):
        payload = {"lines": [{"variant": self.variant.pk, "quantity": 2}]}
        payload.update(overrides)
        return self.client.post(reverse("order-checkout"), payload, format="json")

    def test_credit_invoice_fully_on_credit_accepts_empty_payments(self):
        # The POS sends `payments: []` for a fully-on-credit sale (no
        # down-payment). The field must accept the empty list (regression: it was
        # rejected field-level with "This list may not be empty." before
        # validate() — which allows zero payment for credit — ever ran).
        response = self._checkout(
            sale_type="credit",
            customer=self.customer.pk,
            payments=[],
        )
        self.assertEqual(response.status_code, status.HTTP_201_CREATED, response.data)
        order = Order.objects.get(pk=response.data["id"])
        self.assertEqual(order.status, Order.Status.OPEN)
        self.assertEqual(order.balance_due, Decimal("7.00"))
        self.assertEqual(order.amount_paid, Decimal("0.00"))
        self.assertEqual(response.data["payment_status"], "unpaid")

    def test_standard_sale_still_rejects_empty_payments(self):
        # allow_empty=True must not let a STANDARD sale skip payment.
        response = self._checkout(payments=[])
        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)

    def test_credit_invoice_with_down_payment_is_open_with_balance(self):
        response = self._checkout(
            sale_type="credit",
            customer=self.customer.pk,
            payment_method="cash",
            amount_received="3.00",
        )
        self.assertEqual(response.status_code, status.HTTP_201_CREATED, response.data)
        order = Order.objects.get(pk=response.data["id"])
        self.assertEqual(order.sale_type, Order.SaleType.CREDIT)
        self.assertEqual(order.status, Order.Status.OPEN)
        self.assertEqual(order.balance_due, Decimal("4.00"))
        self.assertEqual(order.amount_paid, Decimal("3.00"))
        self.assertEqual(response.data["payment_status"], "partial")
        # Accrual: stock leaves at issue and the sale is recognized immediately.
        self.stock_item.refresh_from_db()
        self.assertEqual(self.stock_item.quantity_on_hand, 8)
        self.assertIn(order, Order.objects.committed_sales())
        # The drawer reflects only the cash down-payment, not the full total.
        self.assertEqual(self.session.cash_sales_total, Decimal("3.00"))

    def test_credit_invoice_paid_in_full_marks_paid(self):
        response = self._checkout(
            sale_type="credit",
            customer=self.customer.pk,
            payment_method="cash",
            amount_received="7.00",
        )
        order = Order.objects.get(pk=response.data["id"])
        self.assertEqual(order.status, Order.Status.PAID)
        self.assertEqual(order.balance_due, Decimal("0.00"))

    def test_credit_invoice_rejects_overpayment(self):
        response = self._checkout(
            sale_type="credit",
            customer=self.customer.pk,
            payments=[{"method": "cash", "amount": "8.00"}],
        )
        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)

    def test_credit_requires_customer_when_setting_enabled(self):
        # require_customer_for_credit defaults True.
        response = self._checkout(
            sale_type="credit", payment_method="cash", amount_received="0.00"
        )
        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertIn("customer", response.data)

    def test_quotation_makes_no_sale_and_no_stock_movement(self):
        response = self._checkout(sale_type="quotation", customer=self.customer.pk)
        self.assertEqual(response.status_code, status.HTTP_201_CREATED, response.data)
        order = Order.objects.get(pk=response.data["id"])
        self.assertEqual(order.sale_type, Order.SaleType.QUOTATION)
        self.assertEqual(order.payments.count(), 0)
        self.assertEqual(response.data["payment_status"], "quotation")
        self.stock_item.refresh_from_db()
        self.assertEqual(self.stock_item.quantity_on_hand, 10)
        self.assertEqual(self.stock_item.quantity_committed, 0)
        self.assertNotIn(order, Order.objects.committed_sales())
        self.assertEqual(self.session.cash_sales_total, Decimal("0.00"))

    def test_quotation_cannot_take_payment(self):
        response = self._checkout(
            sale_type="quotation",
            customer=self.customer.pk,
            payments=[{"method": "cash", "amount": "1.00"}],
        )
        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)

    def test_quotation_with_reservation_holds_stock(self):
        response = self._checkout(
            sale_type="quotation",
            customer=self.customer.pk,
            reserve_stock=True,
            valid_until="2099-12-31",
        )
        self.assertEqual(response.status_code, status.HTTP_201_CREATED, response.data)
        order = Order.objects.get(pk=response.data["id"])
        self.stock_item.refresh_from_db()
        self.assertEqual(self.stock_item.quantity_on_hand, 10)
        self.assertEqual(self.stock_item.quantity_committed, 2)
        self.assertEqual(order.stock_reservations.count(), 1)


class CustomerPaymentAndConversionTests(TestCase):
    """Recording payments against an invoice and against a customer's account,
    plus converting a quotation in place (consuming any reservation exactly
    once)."""

    def setUp(self):
        ensure_role_groups()
        self.client = APIClient()
        # Account-level collection is a manager/accountant action (it needs
        # customers.view_customer); per-invoice payment is cashier-accessible.
        self.user = get_user_model().objects.create_user(
            username="collect-manager", password="pass"
        )
        self.user.groups.add(Group.objects.get(name=MANAGER_GROUP))
        self.client.force_authenticate(user=self.user)
        self.product = create_product_with_default_variant(
            sku="GADGET", barcode="", name="Gadget", unit_price=Decimal("3.50")
        )
        self.variant = self.product.default_variant
        self.stock_item = StockItem.objects.create(
            variant=self.variant, quantity_on_hand=10
        )
        self.customer = Customer.objects.create(full_name="Collections Customer")
        session_id = self.client.post(
            reverse("register-session-start"),
            {"opening_cash": "0.00"},
            format="json",
        ).data["id"]
        self.session = RegisterSession.objects.get(pk=session_id)

    def _checkout(self, **overrides):
        payload = {
            "lines": [{"variant": self.variant.pk, "quantity": 2}],
            "customer": self.customer.pk,
        }
        payload.update(overrides)
        return self.client.post(reverse("order-checkout"), payload, format="json")

    def _credit_invoice(self):
        # No down-payment -> fully on credit, balance 7.00.
        return Order.objects.get(pk=self._checkout(sale_type="credit").data["id"])

    def test_record_payment_settles_invoice(self):
        invoice = self._credit_invoice()
        response = self.client.post(
            reverse("order-record-payment", args=[invoice.pk]),
            {"method": "cash", "amount": "7.00"},
            format="json",
        )
        self.assertEqual(response.status_code, status.HTTP_201_CREATED, response.data)
        invoice.refresh_from_db()
        self.assertEqual(invoice.status, Order.Status.PAID)
        self.assertEqual(invoice.balance_due, Decimal("0.00"))
        self.assertEqual(self.session.cash_sales_total, Decimal("7.00"))

    def test_record_payment_rejects_overpayment(self):
        invoice = self._credit_invoice()
        response = self.client.post(
            reverse("order-record-payment", args=[invoice.pk]),
            {"method": "cash", "amount": "8.00"},
            format="json",
        )
        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)

    def test_account_payment_allocates_oldest_first(self):
        first = self._credit_invoice()
        second = self._credit_invoice()
        response = self.client.post(
            reverse("customer-record-payment", args=[self.customer.pk]),
            {"method": "cash", "amount": "10.00"},
            format="json",
        )
        self.assertEqual(response.status_code, status.HTTP_200_OK, response.data)
        first.refresh_from_db()
        second.refresh_from_db()
        self.assertEqual(first.status, Order.Status.PAID)
        self.assertEqual(first.balance_due, Decimal("0.00"))
        self.assertEqual(second.balance_due, Decimal("4.00"))
        self.assertEqual(response.data["outstanding_balance"], "4.00")

    def test_account_payment_card_splits_one_receipt_across_invoices(self):
        # One terminal swipe for the whole outstanding (7 + 7 = 14): the receipt
        # is validated once against the total, then split — both rows link to the
        # SAME card.
        first = self._credit_invoice()
        second = self._credit_invoice()
        response = self.client.post(
            reverse("customer-record-payment", args=[self.customer.pk]),
            {
                "method": "card",
                "amount": "14.00",
                "card_receipt_url": _moamalat_receipt_url("14.000"),
            },
            format="json",
        )
        self.assertEqual(response.status_code, status.HTTP_200_OK, response.data)
        first.refresh_from_db()
        second.refresh_from_db()
        self.assertEqual(first.status, Order.Status.PAID)
        self.assertEqual(second.status, Order.Status.PAID)
        card_payments = Payment.objects.filter(
            order__customer=self.customer, method=Payment.Method.CARD
        )
        self.assertEqual(card_payments.count(), 2)
        card_ids = {payment.card_id for payment in card_payments}
        self.assertEqual(len(card_ids), 1)
        self.assertIsNotNone(card_payments.first().card_id)

    def test_account_payment_card_rejects_receipt_amount_mismatch(self):
        self._credit_invoice()
        response = self.client.post(
            reverse("customer-record-payment", args=[self.customer.pk]),
            {
                "method": "card",
                "amount": "7.00",
                "card_receipt_url": _moamalat_receipt_url("5.000"),
            },
            format="json",
        )
        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)

    def test_account_payment_rejects_overpayment(self):
        self._credit_invoice()
        response = self.client.post(
            reverse("customer-record-payment", args=[self.customer.pk]),
            {"method": "cash", "amount": "20.00"},
            format="json",
        )
        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)

    def test_convert_reserved_quotation_to_credit_moves_stock_once(self):
        quote = Order.objects.get(
            pk=self._checkout(
                sale_type="quotation", reserve_stock=True, valid_until="2099-12-31"
            ).data["id"]
        )
        self.stock_item.refresh_from_db()
        self.assertEqual(self.stock_item.quantity_committed, 2)
        response = self.client.post(
            reverse("order-convert", args=[quote.pk]),
            {"sale_type": "credit", "amount_received": "3.00"},
            format="json",
        )
        self.assertEqual(response.status_code, status.HTTP_201_CREATED, response.data)
        new_order = Order.objects.get(pk=response.data["id"])
        self.assertEqual(new_order.sale_type, Order.SaleType.CREDIT)
        self.assertEqual(new_order.status, Order.Status.OPEN)
        self.assertEqual(new_order.balance_due, Decimal("4.00"))
        quote.refresh_from_db()
        self.assertEqual(quote.status, Order.Status.VOID)
        self.assertEqual(quote.converted_to_id, new_order.pk)
        # Reservation consumed and on-hand decremented exactly once.
        self.stock_item.refresh_from_db()
        self.assertEqual(self.stock_item.quantity_committed, 0)
        self.assertEqual(self.stock_item.quantity_on_hand, 8)

    def test_convert_to_standard_requires_full_payment_and_rolls_back(self):
        quote = Order.objects.get(
            pk=self._checkout(sale_type="quotation").data["id"]
        )
        response = self.client.post(
            reverse("order-convert", args=[quote.pk]),
            {"sale_type": "standard", "amount_received": "3.00"},
            format="json",
        )
        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        quote.refresh_from_db()
        self.assertEqual(quote.sale_type, Order.SaleType.QUOTATION)
        self.assertEqual(quote.status, Order.Status.OPEN)
        self.stock_item.refresh_from_db()
        self.assertEqual(self.stock_item.quantity_on_hand, 10)


class CashierCustomerAccessTests(TestCase):
    """``allow_cashier_customer_access`` lets a cashier look up customers and
    collect a customer's debt — even one another user issued — without exposing
    invoice lists or customer editing."""

    def setUp(self):
        ensure_role_groups()
        self.customer = Customer.objects.create(full_name="Debtor")
        product = create_product_with_default_variant(
            sku="WIDGET", barcode="", name="Widget", unit_price=Decimal("5.00")
        )
        self.variant = product.default_variant
        StockItem.objects.create(variant=self.variant, quantity_on_hand=20)

        # A manager issues the credit invoice the cashier will later collect.
        manager = get_user_model().objects.create_user(
            username="access-manager", password="pass"
        )
        manager.groups.add(Group.objects.get(name=MANAGER_GROUP))
        manager_client = APIClient()
        manager_client.force_authenticate(user=manager)
        manager_client.post(
            reverse("register-session-start"),
            {"opening_cash": "0.00"},
            format="json",
        )
        self.invoice = Order.objects.get(
            pk=manager_client.post(
                reverse("order-checkout"),
                {
                    "lines": [{"variant": self.variant.pk, "quantity": 2}],
                    "customer": self.customer.pk,
                    "sale_type": "credit",
                },
                format="json",
            ).data["id"]
        )

        # The collecting cashier, with their OWN open register session.
        cashier = get_user_model().objects.create_user(
            username="access-cashier", password="pass"
        )
        cashier.groups.add(Group.objects.get(name=CASHIER_GROUP))
        self.client = APIClient()
        self.client.force_authenticate(user=cashier)
        self.client.post(
            reverse("register-session-start"),
            {"opening_cash": "0.00"},
            format="json",
        )

    def _set_access(self, *, enabled):
        ShopSettings.objects.filter(pk=1).update(
            allow_cashier_customer_access=enabled
        )

    def test_cashier_collects_another_users_debt_when_enabled(self):
        self._set_access(enabled=True)
        response = self.client.post(
            reverse("customer-record-payment", args=[self.customer.pk]),
            {"method": "cash", "amount": "10.00"},
            format="json",
        )
        self.assertEqual(response.status_code, status.HTTP_200_OK, response.data)
        self.invoice.refresh_from_db()
        self.assertEqual(self.invoice.status, Order.Status.PAID)
        self.assertEqual(self.invoice.balance_due, Decimal("0.00"))

    def test_cashier_collection_blocked_when_disabled(self):
        self._set_access(enabled=False)
        response = self.client.post(
            reverse("customer-record-payment", args=[self.customer.pk]),
            {"method": "cash", "amount": "10.00"},
            format="json",
        )
        self.assertEqual(response.status_code, status.HTTP_403_FORBIDDEN)

    def test_cashier_sees_lookup_and_outstanding_when_enabled(self):
        self._set_access(enabled=True)
        self.assertEqual(
            self.client.get(reverse("customer-list")).status_code,
            status.HTTP_200_OK,
        )
        summary = self.client.get(
            reverse("customer-sales-summary", args=[self.customer.pk])
        )
        self.assertEqual(summary.status_code, status.HTTP_200_OK)
        self.assertEqual(summary.data["outstanding_balance"], "10.00")

    def test_cashier_cannot_browse_invoices_or_edit_even_when_enabled(self):
        self._set_access(enabled=True)
        # Invoice lists stay manager/accountant only — cashiers never browse
        # another cashier's sales.
        self.assertEqual(
            self.client.get(
                reverse("customer-orders", args=[self.customer.pk])
            ).status_code,
            status.HTTP_403_FORBIDDEN,
        )
        # Editing customer records stays restricted too.
        self.assertEqual(
            self.client.patch(
                reverse("customer-detail", args=[self.customer.pk]),
                {"notes": "x"},
                format="json",
            ).status_code,
            status.HTTP_403_FORBIDDEN,
        )


class OrderExchangeAndLookupApiTests(TestCase):
    """HTTP coverage for the sales exchange endpoint and the returns-desk invoice
    lookup: the new scoped permission, cross-session visibility, and the
    cashier-window override."""

    def setUp(self):
        ensure_role_groups()
        self.product = create_product_with_default_variant(
            sku="COFFEE", barcode="", name="Coffee", unit_price=Decimal("3.50"),
        )
        self.variant = self.product.default_variant
        self.stock = StockItem.objects.create(variant=self.variant, quantity_on_hand=10)
        self.replacement = create_product_with_default_variant(
            sku="TEA", barcode="", name="Tea", unit_price=Decimal("5.00"),
        )
        self.replacement_variant = self.replacement.default_variant
        StockItem.objects.create(variant=self.replacement_variant, quantity_on_hand=10)

    def _cashier(self, username, *, lookup_perm=False):
        from django.contrib.auth.models import Permission

        User = get_user_model()
        user = User.objects.create_user(username=username, password="pass")
        user.groups.add(Group.objects.get(name=CASHIER_GROUP))
        if lookup_perm:
            user.user_permissions.add(
                Permission.objects.get(
                    codename="process_return_lookup",
                    content_type__app_label="sales",
                )
            )
        # Re-fetch so has_perm() doesn't read a stale per-instance perm cache.
        return User.objects.get(pk=user.pk)

    def _client_for(self, user):
        client = APIClient()
        client.force_authenticate(user=user)
        return client

    def _start_session(self, client):
        return client.post(
            reverse("register-session-start"), {"opening_cash": "0.00"}, format="json"
        ).data

    def _checkout_coffee(self, client):
        return client.post(
            reverse("order-checkout"),
            {
                "lines": [{"variant": self.variant.pk, "quantity": 1}],
                "payment_method": "cash",
                "amount_received": "3.50",
            },
            format="json",
        ).data

    def _exchange_payload(self, line_id):
        return {
            "reason": "Swap for tea",
            "lines": [{"line": line_id, "quantity": 1}],
            "replacement_lines": [
                {"variant": self.replacement_variant.pk, "quantity": 1}
            ],
            "settlement_method": "cash",
        }

    def test_exchange_collects_net_difference_and_links_orders(self):
        client = self._client_for(self._cashier("ex-1"))
        self._start_session(client)
        order = self._checkout_coffee(client)
        line_id = order["lines"][0]["id"]

        response = client.post(
            reverse("order-exchange-items", args=[order["id"]]),
            self._exchange_payload(line_id),
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK, response.data)
        exchange = OrderExchange.objects.get()
        self.assertEqual(exchange.net_amount, Decimal("1.50"))
        self.assertEqual(exchange.replacement_order.status, Order.Status.PAID)
        self.stock.refresh_from_db()
        self.assertEqual(self.stock.quantity_on_hand, 10)  # coffee restocked

    def test_lookup_requires_the_scoped_permission(self):
        owner_client = self._client_for(self._cashier("owner-1"))
        self._start_session(owner_client)
        order = self._checkout_coffee(owner_client)

        other_client = self._client_for(self._cashier("other-1"))
        self._start_session(other_client)
        denied = other_client.get(
            reverse("order-lookup"), {"receipt": order["receipt_number"]}
        )
        self.assertEqual(denied.status_code, status.HTTP_403_FORBIDDEN)

    def test_lookup_finds_another_cashiers_invoice_with_permission(self):
        owner_client = self._client_for(self._cashier("owner-2"))
        self._start_session(owner_client)
        order = self._checkout_coffee(owner_client)

        agent_client = self._client_for(self._cashier("agent-2", lookup_perm=True))
        self._start_session(agent_client)
        found = agent_client.get(
            reverse("order-lookup"), {"receipt": order["receipt_number"]}
        )
        self.assertEqual(found.status_code, status.HTTP_200_OK, found.data)
        self.assertEqual(found.data["id"], order["id"])

        unknown = agent_client.get(reverse("order-lookup"), {"receipt": "R-nope"})
        self.assertEqual(unknown.status_code, status.HTTP_404_NOT_FOUND)

    def test_cannot_exchange_another_session_invoice_without_permission(self):
        owner_client = self._client_for(self._cashier("owner-3"))
        self._start_session(owner_client)
        order = self._checkout_coffee(owner_client)
        line_id = order["lines"][0]["id"]

        other_client = self._client_for(self._cashier("other-3"))
        self._start_session(other_client)
        blocked = other_client.post(
            reverse("order-exchange-items", args=[order["id"]]),
            self._exchange_payload(line_id),
            format="json",
        )
        self.assertEqual(blocked.status_code, status.HTTP_404_NOT_FOUND)
        self.assertEqual(OrderExchange.objects.count(), 0)

    def test_window_override_lets_permitted_cashier_exchange_old_invoice(self):
        owner_client = self._client_for(self._cashier("owner-4"))
        self._start_session(owner_client)
        order = self._checkout_coffee(owner_client)
        line_id = order["lines"][0]["id"]
        # Push the invoice past the cashier return window.
        Order.objects.filter(pk=order["id"]).update(
            created_at=timezone.now() - timedelta(days=30)
        )

        blocked = owner_client.post(
            reverse("order-exchange-items", args=[order["id"]]),
            self._exchange_payload(line_id),
            format="json",
        )
        self.assertEqual(blocked.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertEqual(OrderExchange.objects.count(), 0)

        agent_client = self._client_for(self._cashier("agent-4", lookup_perm=True))
        self._start_session(agent_client)
        allowed = agent_client.post(
            reverse("order-exchange-items", args=[order["id"]]),
            self._exchange_payload(line_id),
            format="json",
        )
        self.assertEqual(allowed.status_code, status.HTTP_200_OK, allowed.data)
        self.assertEqual(OrderExchange.objects.count(), 1)
