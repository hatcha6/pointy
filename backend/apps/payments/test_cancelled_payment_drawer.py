"""A cancelled payment, and the drawer it goes back out of.

Cancelling a payment writes its opposite: a negative payment in the drawer that
is open now (``apps.payments.documents.reverse``). For cash that is money handed
back over the counter, so the drawer handing it over has to expect that much
less. It did not. The drawer's cash total counted positive rows only — a filter
that exists to keep a *refund's* negative rows out, since a refund reaches the
drawer once already, through ``OrderAdjustment.cash_amount`` — and the
cancellation's row went out with them. The cashier gave the money back and the
close came up short by exactly that amount.
"""

from decimal import Decimal

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group
from django.db import connection
from django.db.migrations.loader import MigrationLoader
from django.test import TestCase
from django.urls import reverse
from rest_framework.test import APIClient

from apps.catalog.testing import create_product_with_default_variant
from apps.core.roles import MANAGER_GROUP, ensure_role_groups
from apps.customers.models import Customer
from apps.documents.guards import system_write
from apps.inventory.models import StockItem
from apps.notifications.models import BusinessNotification
from apps.notifications.services import sync_business_notifications
from apps.sales.models import Order, RegisterSession, prime_register_session_cash_totals
from apps.sales.register_summary import build_register_session_summary
from apps.sales.services import checkout_order, return_order_items

from .models import Payment
from .reconciliation import link_counter_payments, reconcile_payment_reversals
from .services import cancel_payment


class DrawerTestCase(TestCase):
    def setUp(self):
        ensure_role_groups()
        self.user = get_user_model().objects.create_user(
            username="drawer-manager", password="pass"
        )
        self.user.groups.add(Group.objects.get(name=MANAGER_GROUP))
        product = create_product_with_default_variant(
            name="Drawer widget", sku="DW1", barcode="", unit_price=Decimal("5.00")
        )
        self.variant = product.default_variant
        StockItem.objects.create(variant=self.variant, quantity_on_hand=Decimal("50"))
        # Yesterday's shift took the money; today's hands it back.
        self.taking = self._session("taking", opening="20.00")
        self.giving = self._session("giving", opening="100.00")
        self.customer = Customer.objects.create(full_name="زبون الدرج")

    def _session(self, suffix, *, opening):
        return RegisterSession.objects.create(
            owner=self.user,
            owner_key=f"user:{self.user.pk}:{suffix}",
            opening_cash=Decimal(opening),
        )

    def _sale(self, session, *, quantity=2, method="cash"):
        # An آجل invoice paid in full at issue: a cash sale's payment cannot be
        # cancelled out from under it (``test_cancel_and_replace``), and the
        # drawer arithmetic is the same whichever kind of sale the money was for.
        return checkout_order(
            register_session=session,
            lines_data=[{"variant": self.variant, "quantity": Decimal(quantity)}],
            payments_data=[
                {"method": method, "amount": Decimal("5.00") * Decimal(quantity)}
            ],
            sale_type=Order.SaleType.CREDIT,
            customer=self.customer,
        )

    def _cancel(self, order, *, session):
        payment = order.payments.order_by("id").first()
        cancel_payment(payment, reason="حُصِّلت بالخطأ", register_session=session)

    def _fresh(self, session):
        """A new instance: nothing primed, every total asked of the database."""
        return RegisterSession.objects.get(pk=session.pk)

    @staticmethod
    def _method_row(summary, method):
        return next(row for row in summary["payment_methods"] if row["method"] == method)


class CancelledPaymentDrawerTests(DrawerTestCase):
    # --- the drawer ----------------------------------------------------

    def test_the_drawer_that_hands_the_cash_back_expects_that_much_less(self):
        self._cancel(self._sale(self.taking), session=self.giving)

        giving = self._fresh(self.giving)
        self.assertEqual(giving.cash_sales_total, Decimal("-10.00"))
        self.assertEqual(giving.expected_cash, Decimal("90.00"))

    def test_the_drawer_that_took_it_is_left_as_it_was_counted(self):
        self._cancel(self._sale(self.taking), session=self.giving)

        # It did take the money, and was counted and signed off holding it.
        taking = self._fresh(self.taking)
        self.assertEqual(taking.cash_sales_total, Decimal("10.00"))
        self.assertEqual(taking.expected_cash, Decimal("30.00"))

    def test_taken_and_given_back_in_one_shift_nets_to_nothing(self):
        self._cancel(self._sale(self.giving), session=self.giving)

        giving = self._fresh(self.giving)
        self.assertEqual(giving.cash_sales_total, Decimal("0.00"))
        self.assertEqual(giving.expected_cash, Decimal("100.00"))

    def test_a_card_payment_given_back_leaves_the_drawer_alone(self):
        self._cancel(self._sale(self.taking, method="card"), session=self.giving)

        self.assertEqual(self._fresh(self.giving).expected_cash, Decimal("100.00"))

    # --- the primed path the session list reads ------------------------

    def test_primed_totals_agree_with_cold_ones(self):
        self._cancel(self._sale(self.taking), session=self.giving)

        primed = prime_register_session_cash_totals(
            RegisterSession.objects.filter(pk__in=[self.taking.pk, self.giving.pk])
        )

        for session in primed:
            cold = self._fresh(session)
            with self.subTest(session=session.pk):
                self.assertEqual(session.cash_sales_total, cold.cash_sales_total)
                self.assertEqual(session.cash_refund_total, cold.cash_refund_total)
                self.assertEqual(session.expected_cash, cold.expected_cash)
        by_id = {session.pk: session for session in primed}
        self.assertEqual(by_id[self.giving.pk].expected_cash, Decimal("90.00"))
        self.assertEqual(by_id[self.taking.pk].expected_cash, Decimal("30.00"))

    def test_the_session_list_shows_the_cash_going_back(self):
        self._cancel(self._sale(self.taking), session=self.giving)
        client = APIClient()
        client.force_authenticate(user=self.user)

        response = client.get(reverse("register-session-list"))

        self.assertEqual(response.status_code, 200, response.data)
        rows = {row["id"]: row for row in response.data["results"]}
        self.assertEqual(rows[self.giving.pk]["cash_sales_total"], "-10.00")
        self.assertEqual(rows[self.giving.pk]["expected_cash"], "90.00")
        self.assertEqual(rows[self.taking.pk]["expected_cash"], "30.00")

    # --- what the drawer must still leave out --------------------------

    def test_a_refund_still_leaves_the_drawer_once(self):
        """Why the drawer skips negative rows at all: a return's refund rows
        reach it through ``cash_refund_total``. Counting cancellations must not
        start counting those as well."""
        order = self._sale(self.giving)
        return_order_items(
            order=order,
            lines=[(order.lines.get(), 1)],
            reason="مرتجع",
            register_session=self.giving,
        )

        giving = self._fresh(self.giving)
        self.assertEqual(giving.cash_sales_total, Decimal("10.00"))
        self.assertEqual(giving.cash_refund_total, Decimal("5.00"))
        self.assertEqual(giving.expected_cash, Decimal("105.00"))

    def test_an_old_refund_row_that_sits_in_a_drawer_is_still_counted_once(self):
        """Migration ``payments.0007`` gave every historical payment its order's
        session — refund rows included — so a drawer can hold refund rows of its
        own, and they must stay out of its takings."""
        order = self._sale(self.giving)
        adjustment = return_order_items(
            order=order,
            lines=[(order.lines.get(), 1)],
            reason="مرتجع",
            register_session=self.giving,
        )
        with system_write():
            Payment.objects.filter(
                external_reference=f"return:{adjustment.pk}"
            ).update(register_session=self.giving)

        self.assertEqual(self._fresh(self.giving).expected_cash, Decimal("105.00"))

    def test_a_row_that_only_claims_to_be_a_cancellation_moves_nothing(self):
        """The reference is free text anyone taking a payment can write, and
        stays editable after submit — so it cannot be what marks a counter
        row. A drawer that believed it could be emptied by typing."""
        order = self._sale(self.giving)
        Payment.objects.create(
            order=order,
            method=Payment.Method.CASH,
            amount=Decimal("-10.00"),
            external_reference=f"cancel:{order.payments.get().pk}",
            register_session=self.giving,
        )

        self.assertEqual(self._fresh(self.giving).expected_cash, Decimal("110.00"))

    # --- the Z-report ----------------------------------------------------

    def test_the_z_report_of_the_shift_that_gave_it_back_foots(self):
        self._cancel(self._sale(self.taking), session=self.giving)

        summary = build_register_session_summary(self._fresh(self.giving))

        cash = self._method_row(summary, Payment.Method.CASH)
        self.assertEqual(cash["gross"], "-10.00")
        self.assertEqual(cash["net"], "-10.00")
        self.assertEqual(cash["count"], 1)
        self.assertEqual(summary["cash"]["cash_sales_total"], "-10.00")
        self.assertEqual(summary["cash"]["expected_cash"], "90.00")

    def test_the_z_report_of_the_shift_that_took_it_is_unchanged(self):
        self._cancel(self._sale(self.taking), session=self.giving)

        summary = build_register_session_summary(self._fresh(self.taking))

        cash = self._method_row(summary, Payment.Method.CASH)
        self.assertEqual(cash["gross"], "10.00")
        self.assertEqual(cash["count"], 1)
        self.assertEqual(summary["cash"]["expected_cash"], "30.00")

    def test_a_card_payment_given_back_comes_off_the_card_row(self):
        self._cancel(self._sale(self.taking, method="card"), session=self.giving)

        summary = build_register_session_summary(self._fresh(self.giving))

        card = self._method_row(summary, Payment.Method.CARD)
        self.assertEqual(card["gross"], "-10.00")
        self.assertEqual(card["net"], "-10.00")
        self.assertEqual(summary["cash"]["expected_cash"], "100.00")

    # --- the variance alert ----------------------------------------------

    def test_a_shift_that_counted_right_raises_no_variance_alert(self):
        """The alert batches its own copy of the drawer sum, in SQL. It must
        agree with ``cash_variance`` — a shift that handed 10.00 back and
        counted 90.00 is exact, not 10.00 short."""
        self._cancel(self._sale(self.taking), session=self.giving)
        for session, counted in ((self.taking, "30.00"), (self.giving, "90.00")):
            session.status = RegisterSession.Status.CLOSED
            session.closing_cash = Decimal(counted)
            session.save(update_fields=["status", "closing_cash"])
        self.assertEqual(self._fresh(self.giving).cash_variance, Decimal("0.00"))

        sync_business_notifications()

        self.assertFalse(
            BusinessNotification.objects.filter(
                code="sales.register_variance",
                status=BusinessNotification.Status.ACTIVE,
            ).exists()
        )


class CounterPaymentLinkTests(DrawerTestCase):
    """How a drawer knows a negative row is a cancellation: ``reverses``.

    Every cancellation made before the link existed was written with its
    reference alone, and so is any an older backend makes during a live
    update. The catch-up links those — and only those.
    """

    def _cancelled(self):
        order = self._sale(self.taking)
        payment = order.payments.get()
        cancel_payment(payment, reason="خطأ", register_session=self.giving)
        return payment, order.payments.get(amount__lt=0)

    def _unlink(self, counter):
        """What a counter row looks like when an older backend wrote it."""
        with system_write():
            Payment.objects.filter(pk=counter.pk).update(reverses=None)

    def test_the_counter_payment_names_the_payment_it_gives_back(self):
        payment, counter = self._cancelled()
        self.assertEqual(counter.reverses_id, payment.pk)

    def test_an_unlinked_counter_row_is_linked_and_then_counted(self):
        payment, counter = self._cancelled()
        self._unlink(counter)
        self.assertEqual(self._fresh(self.giving).expected_cash, Decimal("100.00"))

        self.assertEqual(reconcile_payment_reversals(), 1)

        counter.refresh_from_db()
        self.assertEqual(counter.reverses_id, payment.pk)
        self.assertEqual(self._fresh(self.giving).expected_cash, Decimal("90.00"))

    def test_catching_up_twice_links_nothing_twice(self):
        _payment, counter = self._cancelled()
        self._unlink(counter)
        reconcile_payment_reversals()

        self.assertEqual(reconcile_payment_reversals(), 0)

    def test_a_reference_to_a_payment_that_was_never_cancelled_is_not_linked(self):
        order = self._sale(self.giving)
        forged = Payment.objects.create(
            order=order,
            method=Payment.Method.CASH,
            amount=Decimal("-10.00"),
            external_reference=f"cancel:{order.payments.get().pk}",
            register_session=self.giving,
        )

        self.assertEqual(reconcile_payment_reversals(), 0)
        forged.refresh_from_db()
        self.assertIsNone(forged.reverses_id)
        self.assertEqual(self._fresh(self.giving).expected_cash, Decimal("110.00"))

    def test_money_given_back_once_is_not_given_back_again(self):
        payment, _counter = self._cancelled()
        second = Payment.objects.create(
            order=payment.order,
            method=Payment.Method.CASH,
            amount=Decimal("-10.00"),
            external_reference=f"cancel:{payment.pk}",
            register_session=self.giving,
        )

        self.assertEqual(reconcile_payment_reversals(), 0)
        second.refresh_from_db()
        self.assertIsNone(second.reverses_id)
        self.assertEqual(self._fresh(self.giving).expected_cash, Decimal("90.00"))

    def test_a_reference_whose_amount_does_not_match_is_not_linked(self):
        payment, counter = self._cancelled()
        self._unlink(counter)
        with system_write():
            Payment.objects.filter(pk=counter.pk).update(amount=Decimal("-3.00"))

        self.assertEqual(reconcile_payment_reversals(), 0)

    def test_the_migration_links_with_its_historical_model(self):
        """Migration ``0015`` hands the helper the historical ``Payment``, which
        has none of the live model's managers."""
        payment, counter = self._cancelled()
        self._unlink(counter)
        state = MigrationLoader(connection).project_state(
            ("payments", "0015_link_counter_payments")
        )

        linked = link_counter_payments(state.apps.get_model("payments", "Payment"))

        self.assertEqual(linked, 1)
        counter.refresh_from_db()
        self.assertEqual(counter.reverses_id, payment.pk)
