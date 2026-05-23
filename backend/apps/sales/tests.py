from datetime import timedelta
from decimal import Decimal

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group
from django.core.exceptions import FieldError
from django.test import SimpleTestCase, TestCase
from django.urls import reverse
from django.utils import timezone
from rest_framework import serializers, status
from rest_framework.test import APIClient

from apps.catalog.models import ProductVariant
from apps.catalog.testing import create_product_with_default_variant
from apps.core.models import ShopSettings
from apps.core.roles import CASHIER_GROUP, MANAGER_GROUP, ensure_role_groups
from apps.customers.models import Customer
from apps.discounts.models import AppliedDiscount, DiscountRedemption, DiscountRule
from apps.inventory.models import StockItem, StockMovement
from apps.payments.models import Payment
from apps.purchasing.models import PurchaseOrder, Supplier
from .load_testing import build_ramp_stages, capacity_summary, collapse_reasons
from .models import (
    Order,
    OrderAdjustment,
    OrderLine,
    RegisterCashMovement,
    RegisterSession,
)
from .services import return_order_items


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
        self.assertEqual(session.closing_cash, Decimal("18.75"))
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
        self.assertEqual(response.data["customer_name"], "Layla Ahmed")
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
        self.assertEqual(int(shortage["requested"]), 5)
        self.assertEqual(int(shortage["available"]), 4)

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
