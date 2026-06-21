"""Register session cash reconciliation over realistic / long operations.

Focuses on the ``RegisterSession`` cash properties (expected_cash, cash_sales_total,
cash_refund_total, cash_variance, denomination math) and the close / pay-in /
pay-out guards in ``RegisterSessionViewSet``. These exercise the drawer accounting
end-to-end through real sales, refunds (cash / card / split), pay-ins/outs, and
long multi-day sessions — the scenarios that silently corrupt a shift's cash count
if a regression slips in.

Coverage here is deliberately disjoint from ``RegisterSessionApiTests`` in
``apps/sales/tests.py`` (which covers idempotent start, isolation, single close,
and the basic expected-cash readout). We add: cash/card/split refund drawer
attribution, variance sign across over/exact/short, double-close & closed-session
movement guards, multi-day aggregation, and cross-session refund booking.
"""

from decimal import Decimal

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group
from django.test import TestCase
from django.urls import reverse
from rest_framework import status
from rest_framework.test import APIClient

from apps.catalog.testing import create_product_with_default_variant
from apps.core.roles import CASHIER_GROUP, MANAGER_GROUP, ensure_role_groups
from apps.inventory.models import StockItem
from apps.payments.models import Payment

from .models import Order, RegisterCashMovement, RegisterSession
from .services import checkout_order, return_order_items


def _open_session(owner):
    return RegisterSession.objects.create(
        owner=owner,
        owner_key=f"user:{owner.pk}",
        opening_cash=Decimal("0.00"),
    )


class RegisterReconciliationServiceTests(TestCase):
    """Model-level drawer math driven through the real checkout/return services."""

    def setUp(self):
        ensure_role_groups()
        self.user = get_user_model().objects.create_user(
            username="recon-cashier",
            password="pass",
        )
        self.user.groups.add(Group.objects.get(name=CASHIER_GROUP))
        # Default flags are fine; make refunds always allowed for managers and keep
        # the loss guard from blocking checkouts (products created below have 0 cost).

    def _product(self, *, sku, price, qty="100"):
        product = create_product_with_default_variant(
            name=f"Item {sku}",
            sku=sku,
            barcode="",
            unit_price=Decimal(price),
        )
        StockItem.objects.create(
            variant=product.default_variant,
            quantity_on_hand=Decimal(qty),
        )
        return product.default_variant

    def _cash_sale(self, session, variant, quantity, unit_price):
        amount = (Decimal(unit_price) * Decimal(quantity)).quantize(Decimal("0.01"))
        return checkout_order(
            register_session=session,
            lines_data=[{"variant": variant, "quantity": Decimal(quantity)}],
            payments_data=[{"method": "cash", "amount": amount}],
        )

    # 1. expected_cash math over several cash sales + a pay-in + a pay-out.
    def test_expected_cash_aggregates_sales_payins_and_payouts(self):
        session = _open_session(self.user)
        session.opening_cash = Decimal("50.00")
        session.save(update_fields=["opening_cash"])
        variant = self._product(sku="REC-1", price="3.00")

        # Three separate cash sales: 2x3, 5x3, 1x3 = 6 + 15 + 3 = 24.00
        self._cash_sale(session, variant, "2", "3.00")
        self._cash_sale(session, variant, "5", "3.00")
        self._cash_sale(session, variant, "1", "3.00")

        RegisterCashMovement.objects.create(
            register_session=session,
            movement_type=RegisterCashMovement.MovementType.PAY_IN,
            amount=Decimal("10.00"),
            reason="Float top-up",
            created_by=self.user,
        )
        RegisterCashMovement.objects.create(
            register_session=session,
            movement_type=RegisterCashMovement.MovementType.PAY_OUT,
            amount=Decimal("4.00"),
            reason="Supplier change",
            created_by=self.user,
        )

        self.assertEqual(session.cash_sales_total, Decimal("24.00"))
        self.assertEqual(session.pay_in_total, Decimal("10.00"))
        self.assertEqual(session.pay_out_total, Decimal("4.00"))
        self.assertEqual(session.cash_refund_total, Decimal("0.00"))
        # 50 opening + 24 sales + 10 in - 4 out - 0 refund = 80.00
        self.assertEqual(session.expected_cash, Decimal("80.00"))

    # 2. REGRESSION: a cash refund in the same session reduces expected cash.
    def test_cash_refund_reduces_expected_cash(self):
        session = _open_session(self.user)
        session.opening_cash = Decimal("20.00")
        session.save(update_fields=["opening_cash"])
        variant = self._product(sku="REC-2", price="4.00")

        order = self._cash_sale(session, variant, "3", "4.00")  # 12.00 cash in
        self.assertEqual(session.cash_sales_total, Decimal("12.00"))
        self.assertEqual(session.expected_cash, Decimal("32.00"))

        line = order.lines.get()
        return_order_items(
            order=order,
            lines=[(line, 1)],  # refund one unit = 4.00
            reason="Damaged",
            register_session=session,
        )

        # Positive cash payments still total 12.00; the refund is tracked separately.
        self.assertEqual(session.cash_sales_total, Decimal("12.00"))
        self.assertEqual(session.cash_refund_total, Decimal("4.00"))
        # 20 + 12 - 4 = 28.00 — the drawer dropped by exactly the refund.
        self.assertEqual(session.expected_cash, Decimal("28.00"))

    # 3. REGRESSION: a card-paid sale's refund must NOT reduce the drawer.
    def test_card_refund_does_not_touch_drawer(self):
        session = _open_session(self.user)
        session.opening_cash = Decimal("15.00")
        session.save(update_fields=["opening_cash"])
        variant = self._product(sku="REC-3", price="5.00")

        order = checkout_order(
            register_session=session,
            lines_data=[{"variant": variant, "quantity": Decimal("2")}],
            payments_data=[{"method": "card", "amount": Decimal("10.00")}],
        )

        # No cash ever entered the drawer for a card sale.
        self.assertEqual(session.cash_sales_total, Decimal("0.00"))
        expected_before = session.expected_cash
        self.assertEqual(expected_before, Decimal("15.00"))

        line = order.lines.get()
        adjustment = return_order_items(
            order=order,
            lines=[(line, 2)],
            reason="Customer changed mind",
            register_session=session,
        )

        # The refund went back to card; cash_amount is 0 and the drawer is untouched.
        self.assertEqual(adjustment.amount, Decimal("10.00"))
        self.assertEqual(adjustment.cash_amount, Decimal("0.00"))
        self.assertEqual(adjustment.refund_method, Payment.Method.CARD)
        self.assertEqual(session.cash_refund_total, Decimal("0.00"))
        self.assertEqual(session.expected_cash, expected_before)

    # 4. REGRESSION: a split cash+card sale refund only reduces the drawer by the cash share.
    def test_split_refund_reduces_drawer_only_by_cash_share(self):
        session = _open_session(self.user)
        session.opening_cash = Decimal("30.00")
        session.save(update_fields=["opening_cash"])
        # Sale total = 10.00, paid 4 cash + 6 card.
        variant = self._product(sku="REC-4", price="10.00")

        order = checkout_order(
            register_session=session,
            lines_data=[{"variant": variant, "quantity": Decimal("1")}],
            payments_data=[
                {"method": "cash", "amount": Decimal("4.00")},
                {"method": "card", "amount": Decimal("6.00")},
            ],
        )

        # Only the cash tender shows in cash_sales_total.
        self.assertEqual(session.cash_sales_total, Decimal("4.00"))
        self.assertEqual(session.expected_cash, Decimal("34.00"))

        line = order.lines.get()
        adjustment = return_order_items(
            order=order,
            lines=[(line, 1)],  # full refund of 10.00, split 4 cash / 6 card
            reason="Full return",
            register_session=session,
        )

        self.assertEqual(adjustment.amount, Decimal("10.00"))
        # Refund split proportionally: 4.00 from cash, 6.00 from card.
        self.assertEqual(adjustment.cash_amount, Decimal("4.00"))
        self.assertEqual(session.cash_refund_total, Decimal("4.00"))
        # 30 + 4 cash sale - 4 cash refund = 30.00; the 6.00 card share never touches cash.
        self.assertEqual(session.expected_cash, Decimal("30.00"))

    # cash_sales_total counts VOID orders too (full return voids the order).
    def test_cash_sales_total_survives_order_becoming_void(self):
        session = _open_session(self.user)
        variant = self._product(sku="REC-5", price="7.00")
        order = self._cash_sale(session, variant, "1", "7.00")

        line = order.lines.get()
        return_order_items(
            order=order,
            lines=[(line, 1)],  # full single-line return -> order VOID
            reason="All back",
            register_session=session,
        )
        order.refresh_from_db()

        self.assertEqual(order.status, Order.Status.VOID)
        # Positive cash payment is still counted (PAID/VOID), refund tracked separately.
        self.assertEqual(session.cash_sales_total, Decimal("7.00"))
        self.assertEqual(session.cash_refund_total, Decimal("7.00"))
        self.assertEqual(session.expected_cash, Decimal("0.00"))


class RegisterVarianceTests(TestCase):
    """Variance sign/value and denomination semantics through the close endpoint."""

    def setUp(self):
        ensure_role_groups()
        self.user = get_user_model().objects.create_user(
            username="variance-cashier",
            password="pass",
        )
        self.user.groups.add(Group.objects.get(name=CASHIER_GROUP))
        self.client = APIClient()
        self.client.force_authenticate(user=self.user)

    def _start(self, opening_cash="0.00"):
        response = self.client.post(
            reverse("register-session-start"),
            {"opening_cash": opening_cash},
            format="json",
        )
        self.assertEqual(response.status_code, status.HTTP_200_OK)
        return response.data["id"]

    def _close(self, session_id, **body):
        return self.client.post(
            reverse("register-session-close", args=[session_id]),
            body,
            format="json",
        )

    def test_positive_variance_when_drawer_is_over(self):
        session_id = self._start(opening_cash="100.00")
        # No sales: expected_cash == opening 100.00. Count 120.00 in the drawer.
        response = self._close(
            session_id,
            closing_cash="0.00",
            count_025=0,
            count_050=0,
            count_075=0,
            count_100=120,
        )
        self.assertEqual(response.status_code, status.HTTP_200_OK)
        session = RegisterSession.objects.get(pk=session_id)
        # closing_cash = entered 0 + denominations 120.00.
        self.assertEqual(session.closing_cash, Decimal("120.00"))
        self.assertEqual(session.expected_cash, Decimal("100.00"))
        self.assertEqual(session.cash_variance, Decimal("20.00"))
        self.assertTrue(session.has_cash_variance)

    def test_exact_zero_variance_reports_no_variance(self):
        session_id = self._start(opening_cash="40.00")
        # Drawer counted to exactly 40.00 (160 quarters), entered 0.
        response = self._close(
            session_id,
            closing_cash="0.00",
            count_025=160,
            count_050=0,
            count_075=0,
            count_100=0,
        )
        self.assertEqual(response.status_code, status.HTTP_200_OK)
        session = RegisterSession.objects.get(pk=session_id)
        self.assertEqual(session.closing_cash, Decimal("40.00"))
        self.assertEqual(session.expected_cash, Decimal("40.00"))
        self.assertEqual(session.cash_variance, Decimal("0.00"))
        self.assertFalse(session.has_cash_variance)

    def test_negative_variance_when_drawer_is_short(self):
        session_id = self._start(opening_cash="100.00")
        # Entered 90.00, no denominations -> closing 90.00 vs expected 100.00.
        response = self._close(
            session_id,
            closing_cash="90.00",
            count_025=0,
            count_050=0,
            count_075=0,
            count_100=0,
        )
        self.assertEqual(response.status_code, status.HTTP_200_OK)
        session = RegisterSession.objects.get(pk=session_id)
        self.assertEqual(session.closing_cash, Decimal("90.00"))
        self.assertEqual(session.expected_cash, Decimal("100.00"))
        self.assertEqual(session.cash_variance, Decimal("-10.00"))
        self.assertTrue(session.has_cash_variance)

    def test_closing_cash_is_entered_plus_all_denominations(self):
        session_id = self._start(opening_cash="0.00")
        # 1*0.25 + 2*0.50 + 3*0.75 + 4*1.00 = 0.25 + 1.00 + 2.25 + 4.00 = 7.50
        response = self._close(
            session_id,
            closing_cash="2.50",
            count_025=1,
            count_050=2,
            count_075=3,
            count_100=4,
        )
        self.assertEqual(response.status_code, status.HTTP_200_OK)
        session = RegisterSession.objects.get(pk=session_id)
        self.assertEqual(session.denomination_total, Decimal("7.50"))
        # entered 2.50 + 7.50 denominations.
        self.assertEqual(session.closing_cash, Decimal("10.00"))

    def test_open_session_has_no_variance(self):
        session_id = self._start(opening_cash="25.00")
        session = RegisterSession.objects.get(pk=session_id)
        # An open (not-yet-closed) session has no closing_cash, hence no variance.
        self.assertIsNone(session.closing_cash)
        self.assertIsNone(session.cash_variance)
        self.assertFalse(session.has_cash_variance)


class RegisterCloseGuardTests(TestCase):
    """Double-close prevention and closed-session movement rejection."""

    def setUp(self):
        ensure_role_groups()
        self.user = get_user_model().objects.create_user(
            username="guard-cashier",
            password="pass",
        )
        self.user.groups.add(Group.objects.get(name=CASHIER_GROUP))
        self.client = APIClient()
        self.client.force_authenticate(user=self.user)

    def _start(self):
        response = self.client.post(
            reverse("register-session-start"),
            {"opening_cash": "10.00"},
            format="json",
        )
        return response.data["id"]

    def _close_body(self):
        return {
            "closing_cash": "10.00",
            "count_025": 0,
            "count_050": 0,
            "count_075": 0,
            "count_100": 0,
        }

    def test_second_close_is_rejected_and_does_not_overwrite(self):
        session_id = self._start()
        first = self.client.post(
            reverse("register-session-close", args=[session_id]),
            self._close_body(),
            format="json",
        )
        self.assertEqual(first.status_code, status.HTTP_200_OK)
        closed = RegisterSession.objects.get(pk=session_id)
        first_closed_at = closed.closed_at
        self.assertEqual(closed.closing_cash, Decimal("10.00"))

        # A second close with a different total must be rejected, not applied.
        second = self.client.post(
            reverse("register-session-close", args=[session_id]),
            {
                "closing_cash": "999.00",
                "count_025": 0,
                "count_050": 0,
                "count_075": 0,
                "count_100": 0,
            },
            format="json",
        )
        self.assertEqual(second.status_code, status.HTTP_400_BAD_REQUEST)
        closed.refresh_from_db()
        self.assertEqual(closed.closing_cash, Decimal("10.00"))
        self.assertEqual(closed.closed_at, first_closed_at)

    def test_pay_in_rejected_on_closed_session(self):
        session_id = self._start()
        self.client.post(
            reverse("register-session-close", args=[session_id]),
            self._close_body(),
            format="json",
        )
        response = self.client.post(
            reverse("register-session-pay-in", args=[session_id]),
            {"amount": "5.00", "reason": "Late float"},
            format="json",
        )
        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertFalse(
            RegisterCashMovement.objects.filter(register_session_id=session_id).exists()
        )

    def test_pay_out_rejected_on_closed_session(self):
        session_id = self._start()
        self.client.post(
            reverse("register-session-close", args=[session_id]),
            self._close_body(),
            format="json",
        )
        response = self.client.post(
            reverse("register-session-pay-out", args=[session_id]),
            {"amount": "5.00", "reason": "Late expense"},
            format="json",
        )
        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertFalse(
            RegisterCashMovement.objects.filter(register_session_id=session_id).exists()
        )


class RegisterOwnershipTests(TestCase):
    """Unique-open-session-per-owner and per-owner independence."""

    def setUp(self):
        ensure_role_groups()
        self.User = get_user_model()

    def _cashier_client(self, username):
        user = self.User.objects.create_user(username=username, password="pass")
        user.groups.add(Group.objects.get(name=CASHIER_GROUP))
        client = APIClient()
        client.force_authenticate(user=user)
        return user, client

    def test_second_start_reuses_existing_open_session(self):
        _, client = self._cashier_client("owner-a")
        first = client.post(
            reverse("register-session-start"),
            {"opening_cash": "10.00"},
            format="json",
        )
        # Re-starting with a different opening cash must reuse, not create a new one.
        second = client.post(
            reverse("register-session-start"),
            {"opening_cash": "999.00"},
            format="json",
        )
        self.assertEqual(first.status_code, status.HTTP_200_OK)
        self.assertEqual(second.status_code, status.HTTP_200_OK)
        self.assertEqual(first.data["id"], second.data["id"])
        self.assertEqual(
            RegisterSession.objects.filter(status=RegisterSession.Status.OPEN).count(),
            1,
        )
        reused = RegisterSession.objects.get(pk=first.data["id"])
        # The original opening_cash is preserved (the second value is ignored).
        self.assertEqual(reused.opening_cash, Decimal("10.00"))

    def test_each_owner_has_independent_open_session(self):
        user_a, client_a = self._cashier_client("indep-a")
        user_b, client_b = self._cashier_client("indep-b")
        a = client_a.post(
            reverse("register-session-start"),
            {"opening_cash": "10.00"},
            format="json",
        )
        b = client_b.post(
            reverse("register-session-start"),
            {"opening_cash": "20.00"},
            format="json",
        )
        self.assertNotEqual(a.data["id"], b.data["id"])
        self.assertEqual(
            RegisterSession.objects.filter(status=RegisterSession.Status.OPEN).count(),
            2,
        )
        # Each owner's "current" returns only their own session.
        current_a = client_a.get(reverse("register-session-current"))
        current_b = client_b.get(reverse("register-session-current"))
        self.assertEqual(current_a.data["id"], a.data["id"])
        self.assertEqual(current_b.data["id"], b.data["id"])

    def test_owner_can_reopen_after_closing(self):
        _, client = self._cashier_client("reopen-owner")
        first = client.post(
            reverse("register-session-start"),
            {"opening_cash": "10.00"},
            format="json",
        ).data
        client.post(
            reverse("register-session-close", args=[first["id"]]),
            {
                "closing_cash": "10.00",
                "count_025": 0,
                "count_050": 0,
                "count_075": 0,
                "count_100": 0,
            },
            format="json",
        )
        # A fresh start after closing creates a brand new open session.
        second = client.post(
            reverse("register-session-start"),
            {"opening_cash": "30.00"},
            format="json",
        )
        self.assertEqual(second.status_code, status.HTTP_200_OK)
        self.assertNotEqual(second.data["id"], first["id"])
        self.assertEqual(
            RegisterSession.objects.filter(status=RegisterSession.Status.OPEN).count(),
            1,
        )


class RegisterLongRunningTests(TestCase):
    """A session left open across a long, multi-day span of many sales."""

    def setUp(self):
        ensure_role_groups()
        self.user = get_user_model().objects.create_user(
            username="long-cashier",
            password="pass",
        )
        self.user.groups.add(Group.objects.get(name=CASHIER_GROUP))

    def test_long_session_aggregates_all_cash_sales_without_autoclose(self):
        session = _open_session(self.user)
        session.opening_cash = Decimal("100.00")
        session.save(update_fields=["opening_cash"])

        product = create_product_with_default_variant(
            name="Long-run coffee",
            sku="LONG-1",
            barcode="",
            unit_price=Decimal("2.50"),
        )
        variant = product.default_variant
        StockItem.objects.create(
            variant=variant,
            quantity_on_hand=Decimal("1000"),
        )

        # Simulate two days' worth of sales: 45 cash sales of 1 unit @ 2.50.
        sale_count = 45
        for _ in range(sale_count):
            checkout_order(
                register_session=session,
                lines_data=[{"variant": variant, "quantity": Decimal("1")}],
                payments_data=[{"method": "cash", "amount": Decimal("2.50")}],
            )

        # The session was never auto-closed across the span.
        session.refresh_from_db()
        self.assertEqual(session.status, RegisterSession.Status.OPEN)
        self.assertEqual(session.orders.count(), sale_count)

        expected_sales = (Decimal("2.50") * sale_count).quantize(Decimal("0.01"))
        self.assertEqual(session.cash_sales_total, expected_sales)  # 112.50
        # opening 100 + 112.50 sales = 212.50
        self.assertEqual(session.expected_cash, Decimal("212.50"))
        self.assertEqual(Payment.objects.filter(amount__gt=0).count(), sale_count)


class RegisterCrossSessionRefundTests(TestCase):
    """A refund books to the currently-open session, not the original sale's."""

    def setUp(self):
        ensure_role_groups()
        self.user = get_user_model().objects.create_user(
            username="cross-cashier",
            password="pass",
        )
        self.user.groups.add(Group.objects.get(name=CASHIER_GROUP))
        # Refund must be allowed even though the sale is from a prior shift; a
        # manager bypasses the cashier return window.
        self.manager = get_user_model().objects.create_user(
            username="cross-manager",
            password="pass",
        )
        self.manager.groups.add(Group.objects.get(name=MANAGER_GROUP))

    def test_refund_books_to_open_session_not_original_sale_session(self):
        product = create_product_with_default_variant(
            name="Cross coffee",
            sku="CROSS-1",
            barcode="",
            unit_price=Decimal("6.00"),
        )
        variant = product.default_variant
        StockItem.objects.create(variant=variant, quantity_on_hand=Decimal("50"))

        # Session 1: a cash sale, then close it.
        session1 = _open_session(self.user)
        order = checkout_order(
            register_session=session1,
            lines_data=[{"variant": variant, "quantity": Decimal("2")}],
            payments_data=[{"method": "cash", "amount": Decimal("12.00")}],
        )
        session1.status = RegisterSession.Status.CLOSED
        session1.closing_cash = Decimal("12.00")
        session1.save(update_fields=["status", "closing_cash"])

        self.assertEqual(session1.cash_sales_total, Decimal("12.00"))
        self.assertEqual(session1.cash_refund_total, Decimal("0.00"))

        # Session 2 opens; refund the session-1 order while session 2 is current.
        session2 = _open_session(self.user)
        line = order.lines.get()
        adjustment = return_order_items(
            order=order,
            lines=[(line, 1)],  # refund 6.00
            reason="Returned next shift",
            register_session=session2,
        )

        # The adjustment is booked against session 2 (the refunding drawer).
        self.assertEqual(adjustment.register_session_id, session2.pk)
        self.assertEqual(adjustment.cash_amount, Decimal("6.00"))

        # Session 1 is untouched: its sales stand, its refund total is still 0.
        self.assertEqual(session1.cash_sales_total, Decimal("12.00"))
        self.assertEqual(session1.cash_refund_total, Decimal("0.00"))

        # Session 2 carries the refund: no sales of its own, just the -6.00 drawer hit.
        self.assertEqual(session2.cash_sales_total, Decimal("0.00"))
        self.assertEqual(session2.cash_refund_total, Decimal("6.00"))
        self.assertEqual(session2.expected_cash, Decimal("-6.00"))

    def test_default_adjustment_session_falls_back_to_orders_session(self):
        # When no refunding session is supplied, the adjustment defaults to the
        # order's own register session (documents the service-layer fallback).
        product = create_product_with_default_variant(
            name="Fallback coffee",
            sku="FALLBACK-1",
            barcode="",
            unit_price=Decimal("5.00"),
        )
        variant = product.default_variant
        StockItem.objects.create(variant=variant, quantity_on_hand=Decimal("50"))

        session = _open_session(self.user)
        order = checkout_order(
            register_session=session,
            lines_data=[{"variant": variant, "quantity": Decimal("1")}],
            payments_data=[{"method": "cash", "amount": Decimal("5.00")}],
        )
        line = order.lines.get()
        adjustment = return_order_items(
            order=order,
            lines=[(line, 1)],
            reason="Same shift, no session passed",
            # register_session omitted -> falls back to order.register_session
        )
        self.assertEqual(adjustment.register_session_id, session.pk)
        self.assertEqual(session.cash_refund_total, Decimal("5.00"))
