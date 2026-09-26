"""An order's balance is net of what came back, not only of what was paid.

A return hands its money back as a negative payment while the order's total
stays where it was, so ``total − amount_paid`` read every part-returned sale as
owing exactly its refund. The invoice screen offered to collect it, the
collection service accepted it, the aging report listed it and
``payment_status`` said "partial" for ever. What a customer owes is the total
less what they settled, and a return settles its share — the rule the paid/open
status already followed (``apps.sales.documents.settled_amount``).
"""

from datetime import timedelta
from decimal import Decimal

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group
from django.db import connection
from django.test import TestCase, override_settings
from django.test.utils import CaptureQueriesContext
from django.urls import reverse
from django.utils import timezone
from rest_framework import serializers, status
from rest_framework.test import APIClient

from apps.catalog.testing import create_product_with_default_variant
from apps.core.roles import MANAGER_GROUP, ensure_role_groups
from apps.customers.models import Customer
from apps.customers.receivables import outstanding_balance
from apps.documents.guards import system_write
from apps.inventory.models import StockItem
from apps.payments.models import Payment
from apps.payments.services import cancel_payment
from apps.reports.models import ReportRun
from apps.reports.services import generate_report_payload
from apps.sales.models import Order, OrderAdjustment, RegisterSession
from apps.sales.services import (
    checkout_order,
    record_customer_account_payment,
    record_customer_payment,
    return_order_items,
    void_order,
)

ZERO = Decimal("0.00")


@override_settings(
    CACHES={"default": {"BACKEND": "django.core.cache.backends.locmem.LocMemCache"}}
)
class BalanceNetOfReturnsTests(TestCase):
    def setUp(self):
        ensure_role_groups()
        self.user = get_user_model().objects.create_user(
            username="balance-manager", password="p"
        )
        self.user.groups.add(Group.objects.get(name=MANAGER_GROUP))
        self.client = APIClient()
        self.client.force_authenticate(user=self.user)
        product = create_product_with_default_variant(
            name="Widget", sku="BAL-W", barcode="", unit_price=Decimal("5.00")
        )
        self.variant = product.default_variant
        StockItem.objects.create(variant=self.variant, quantity_on_hand=Decimal("100"))
        self.customer = Customer.objects.create(full_name="زبون آجل")
        self.session = RegisterSession.objects.create(
            owner=self.user,
            owner_key=f"user:{self.user.pk}",
            opening_cash=ZERO,
        )

    # -- helpers ---------------------------------------------------------

    def _sale(self, *payments, sale_type=Order.SaleType.CREDIT, quantity="2"):
        """Two widgets at 5.00, paid with ``payments`` at the counter."""
        return checkout_order(
            register_session=self.session,
            lines_data=[{"variant": self.variant, "quantity": Decimal(quantity)}],
            payments_data=[
                {"method": "cash", "amount": Decimal(amount)} for amount in payments
            ],
            customer=self.customer,
            sale_type=sale_type,
        )

    def _return_one(self, order):
        return_order_items(
            order=order,
            lines=[(order.lines.get(), Decimal("1"))],
            reason="customer changed their mind",
            register_session=self.session,
        )
        return Order.objects.get(pk=order.pk)

    def _collect(self, order, amount):
        return record_customer_payment(
            order,
            method="cash",
            amount=Decimal(amount),
            register_session=self.session,
        )

    def _report(self, report_type, day, **params):
        return generate_report_payload(
            report_type=report_type,
            params={
                "start_date": day.isoformat(),
                "end_date": day.isoformat(),
                **params,
            },
            user=self.user,
        )

    def _aging(self, day=None):
        return self._report(
            ReportRun.ReportType.RECEIVABLES_AGING, day or timezone.localdate()
        )["summary"]

    def _statement(self, day=None):
        return self._report(
            ReportRun.ReportType.CUSTOMER_STATEMENT,
            day or timezone.localdate(),
            customer_id=self.customer.pk,
        )

    # -- the returned-then-collected case ---------------------------------

    def test_a_settled_sale_that_was_part_returned_owes_nothing(self):
        order = self._return_one(self._sale("10.00"))

        self.assertEqual(order.status, Order.Status.PAID)
        # The drawer really did give 5.00 back ...
        self.assertEqual(order.amount_paid, Decimal("5.00"))
        # ... for goods it took back, so nothing is left to pay.
        self.assertEqual(order.raw_balance_due, ZERO)
        self.assertEqual(order.balance_due, ZERO)
        self.assertEqual(order.payment_status, "paid")

    def test_collecting_the_refund_again_is_refused(self):
        order = self._return_one(self._sale("10.00"))
        payments_before = Payment.objects.count()

        with self.assertRaises(serializers.ValidationError):
            self._collect(order, "5.00")
        with self.assertRaises(serializers.ValidationError):
            record_customer_account_payment(
                self.customer,
                method="cash",
                amount=Decimal("5.00"),
                register_session=self.session,
            )
        # The payments endpoint takes the same decision on its own, for a
        # caller that never goes through the collection service.
        response = self.client.post(
            reverse("payment-list"),
            {"order": order.pk, "method": "cash", "amount": "5.00"},
            format="json",
        )
        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertIn("amount", response.data)
        self.assertEqual(Payment.objects.count(), payments_before)

    def test_the_invoice_offers_nothing_to_collect(self):
        """The invoice screen shows its آجل balance callout and collect button
        whenever a credit invoice's ``balance_due`` is above zero."""
        order = self._return_one(self._sale("10.00"))

        response = self.client.get(reverse("order-detail", args=[order.pk]))

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(response.data["balance_due"], "0.00")
        self.assertEqual(response.data["payment_status"], "paid")
        self.assertFalse(response.data["is_overdue"])

    # -- payment_status ----------------------------------------------------

    def test_payment_status_follows_the_balance(self):
        unpaid = self._sale()
        partial = self._sale("3.00")
        returned_cash_sale = self._return_one(
            self._sale("10.00", sale_type=Order.SaleType.STANDARD)
        )

        self.assertEqual(unpaid.payment_status, "unpaid")
        self.assertEqual(partial.payment_status, "partial")
        self.assertEqual(partial.balance_due, Decimal("7.00"))
        # Was "partial": 5.00 short of a total that no longer describes the sale.
        self.assertEqual(returned_cash_sale.payment_status, "paid")
        self.assertEqual(returned_cash_sale.balance_due, ZERO)

    def test_a_sale_given_back_whole_owes_nothing_and_says_void(self):
        """``total − amount_paid`` read a voided sale as owing its whole total.
        It owes nothing — and so the balance alone would call it "paid", which
        a reprint would print as a sale that stood."""
        voided = self._sale("10.00")
        void_order(order=voided, reason="wrong customer", register_session=self.session)
        returned = self._sale("10.00", sale_type=Order.SaleType.STANDARD)
        self._return_one(returned)
        returned = self._return_one(returned)

        for order in (Order.objects.get(pk=voided.pk), returned):
            with self.subTest(order=order.receipt_number):
                self.assertEqual(order.status, Order.Status.VOID)
                self.assertEqual(order.balance_due, ZERO)
                self.assertEqual(order.payment_status, "void")

    # -- the reports -------------------------------------------------------

    def test_aging_and_statement_agree_the_returned_invoice_is_settled(self):
        self._return_one(self._sale("10.00"))
        # A real debt beside it, so the reports are seen to count one.
        self._sale("3.00")

        aging = self._aging()
        self.assertEqual(aging["receivable_total"], "7.00")
        self.assertEqual(aging["invoice_count"], 1)
        self.assertEqual(outstanding_balance(self.customer), Decimal("7.00"))

        statement = self._statement()
        self.assertEqual(statement["summary"]["closing_balance"], "7.00")
        rows = next(
            section
            for section in statement["sections"]
            if section["key"] == "statement_entries"
        )["rows"]
        self.assertEqual(rows[-1]["balance"], "7.00")
        # The return is its own line — the credit note that explains the
        # refund — and comes right before the refund it pays out, the order in
        # which the two were written.
        kinds = [row["kind"] for row in rows]
        self.assertEqual(kinds.index("refund"), kinds.index("return") + 1)
        self.assertEqual(rows[kinds.index("return")]["credit"], "5.00")
        self.assertEqual(rows[kinds.index("refund")]["debit"], "5.00")

    def test_the_statement_figures_each_count_one_kind_of_line(self):
        """«المحصَّل» is money in and «إجمالي الفواتير» is invoices. They were
        the credit and debit columns, which also carry the returns and the
        refunds that pay them out."""
        self._return_one(self._sale("10.00"))
        self._sale("3.00")

        statement = self._statement()

        summary = statement["summary"]
        self.assertEqual(summary["invoiced_total"], "20.00")
        self.assertEqual(summary["returned_total"], "5.00")
        self.assertEqual(summary["received_total"], "13.00")
        self.assertEqual(summary["refunded_total"], "5.00")
        # opening + invoiced − returned − received + refunded
        self.assertEqual(summary["closing_balance"], "7.00")
        # The columns still foot to their own lines.
        section = next(
            section
            for section in statement["sections"]
            if section["key"] == "statement_entries"
        )
        self.assertEqual(section["totals"]["full"], {"debit": "25.00", "credit": "18.00"})
        self.assertEqual(section["totals"]["full"], section["totals"]["shown"])

    def test_a_returned_invoice_is_not_a_debt_as_of_an_earlier_date(self):
        """The as-of arithmetic nets the return too — and the statement's
        opening balance is the same arithmetic run to the day before."""
        order = self._return_one(self._sale("10.00"))
        earlier = timezone.now() - timedelta(days=3)
        # A fixture standing in for a sale made three days ago: a submitted
        # payment's date is frozen, so moving it back says so.
        with system_write():
            Order.objects.filter(pk=order.pk).update(created_at=earlier)
            Payment.objects.filter(order=order).update(paid_at=earlier)
            OrderAdjustment.objects.filter(order=order).update(created_at=earlier)
        yesterday = timezone.localdate() - timedelta(days=1)

        self.assertEqual(self._aging(yesterday)["receivable_total"], "0.00")
        statement = self._statement()
        self.assertEqual(statement["summary"]["opening_balance"], "0.00")
        self.assertEqual(statement["summary"]["closing_balance"], "0.00")

    # -- an invoice a cancelled payment reopened ---------------------------

    def test_a_reopened_invoice_owes_what_it_holds_net_of_its_return(self):
        """Bought 10.00, paid 4.00 then 6.00, returned one (5.00 back), then the
        4.00 was cancelled (4.00 back): the customer holds goods worth 5.00 and
        has 1.00 of their money in the till, so they owe 4.00 — not the 9.00
        that ``total − amount_paid`` says."""
        order = self._sale("4.00")
        first = order.payments.get()
        self._collect(order, "6.00")
        order = self._return_one(order)
        cancel_payment(first, reason="entered twice", register_session=self.session)
        order = Order.objects.get(pk=order.pk)

        self.assertEqual(order.status, Order.Status.OPEN)
        self.assertEqual(order.amount_paid, Decimal("1.00"))
        self.assertEqual(order.balance_due, Decimal("4.00"))
        self.assertEqual(order.payment_status, "partial")
        self.assertEqual(outstanding_balance(self.customer), Decimal("4.00"))
        self.assertEqual(self._aging()["receivable_total"], "4.00")
        self.assertEqual(self._statement()["summary"]["closing_balance"], "4.00")

        with self.assertRaises(serializers.ValidationError):
            self._collect(order, "4.01")
        # Paying what it owes settles it: the flip to paid counts the return.
        self._collect(order, "4.00")
        order = Order.objects.get(pk=order.pk)
        self.assertEqual(order.status, Order.Status.PAID)
        self.assertEqual(order.balance_due, ZERO)
        self.assertEqual(order.payment_status, "paid")

    def test_partial_is_read_off_the_settled_figure_too(self):
        """Paid 5.00 and 5.00, one of the two returned (5.00 back), then a
        5.00 payment cancelled (5.00 back). None of the customer's money is
        left in the till, but half the sale was settled by the goods that came
        back, and the balance says 5.00 of 10.00 — so the status says partial.
        "Unpaid" would claim the whole total is owed."""
        order = self._sale("5.00")
        first = order.payments.get()
        self._collect(order, "5.00")
        order = self._return_one(order)
        cancel_payment(first, reason="entered twice", register_session=self.session)
        order = Order.objects.get(pk=order.pk)

        self.assertEqual(order.amount_paid, ZERO)
        self.assertEqual(order.balance_due, Decimal("5.00"))
        self.assertEqual(order.payment_status, "partial")

    # -- cost ----------------------------------------------------------------

    def _list_queries(self, url):
        self.client.get(url)  # warm permissions and settings singletons
        with CaptureQueriesContext(connection) as ctx:
            response = self.client.get(url)
        self.assertEqual(response.status_code, status.HTTP_200_OK)
        return len(ctx)

    def test_the_invoice_lists_do_not_read_returns_per_row(self):
        """``balance_due`` now reads ``adjustments``. Comparing live sales with
        returned ones cannot see that read — every row makes it — so this
        compares a page of returned sales with one twice its size."""
        for _ in range(3):
            self._return_one(self._sale("10.00"))
        invoices = reverse("order-list")
        strip = reverse("register-session-orders", args=[self.session.pk])
        customer_tab = reverse("customer-orders", args=[self.customer.pk])
        small = [self._list_queries(url) for url in (invoices, strip, customer_tab)]

        for _ in range(3):
            self._return_one(self._sale("10.00"))
        large = [self._list_queries(url) for url in (invoices, strip, customer_tab)]

        self.assertEqual(small, large, "an invoice list reads returns once per row")
