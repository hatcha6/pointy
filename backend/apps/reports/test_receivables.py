"""Who owes the shop, how old it is, and what one account says.

Credit selling is universal in this market and unrecoverable credit is the
owner's largest single risk — and it was the one subject the report catalogue
did not cover at all. These tests pin the two decisions that decide the numbers:
what counts as a receivable, and that a balance is rebuilt *as at a date* rather
than read off today.
"""

from datetime import timedelta
from decimal import Decimal

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group
from django.test import TestCase
from django.utils import timezone

from apps.core.roles import MANAGER_GROUP, ensure_role_groups
from apps.customers.models import Customer
from apps.documents.statuses import DocumentStatus
from apps.payments.models import Payment
from apps.purchasing.models import PurchaseOrder, Supplier, SupplierPayment
from apps.sales.models import Order, RegisterSession

from .models import ReportRun
from .sections import decimal_from
from .services import generate_report_payload


class ReceivablesAgingTests(TestCase):
    def setUp(self):
        ensure_role_groups()
        User = get_user_model()
        self.manager = User.objects.create_user(username="ar-mgr", password="p")
        self.manager.groups.add(Group.objects.get(name=MANAGER_GROUP))
        self.today = timezone.localdate()
        self.session = RegisterSession.objects.create(
            owner=self.manager,
            owner_key=f"user:{self.manager.pk}",
            opening_cash=Decimal("0.00"),
        )
        self.customer = Customer.objects.create(full_name="زبون آجل")
        self.other = Customer.objects.create(full_name="زبون آخر")

    def _invoice(
        self, customer, *, days_ago, total, paid=None, status=None, due_in_days=None
    ):
        order = Order.objects.create(
            register_session=self.session,
            customer=customer,
            sale_type=Order.SaleType.CREDIT,
            status=status or Order.Status.OPEN,
            subtotal=Decimal(total),
            total=Decimal(total),
            due_date=(
                None
                if due_in_days is None
                else self.today + timedelta(days=due_in_days)
            ),
        )
        when = timezone.now() - timedelta(days=days_ago)
        Order.objects.filter(pk=order.pk).update(created_at=when)
        if paid:
            Payment.objects.create(
                order=order,
                method=Payment.Method.CASH,
                amount=Decimal(paid),
                paid_at=when,
            )
        return order

    def _report(self, *, end=None):
        end = end or self.today
        return generate_report_payload(
            report_type=ReportRun.ReportType.RECEIVABLES_AGING,
            params={"start_date": end.isoformat(), "end_date": end.isoformat()},
            user=self.manager,
        )

    def _section(self, payload):
        return next(s for s in payload["sections"] if s["key"] == "receivables_aging")

    def test_an_unpaid_credit_invoice_is_a_receivable(self):
        self._invoice(self.customer, days_ago=5, total="100.00")
        self.assertEqual(self._report()["summary"]["receivable_total"], "100.00")

    def test_part_payment_reduces_the_balance(self):
        self._invoice(self.customer, days_ago=5, total="100.00", paid="30.00")
        self.assertEqual(self._report()["summary"]["receivable_total"], "70.00")

    def test_a_settled_invoice_leaves_nothing_behind(self):
        self._invoice(
            self.customer,
            days_ago=5,
            total="100.00",
            paid="100.00",
            status=Order.Status.PAID,
        )
        self.assertEqual(self._report()["summary"]["receivable_total"], "0.00")

    def test_a_voided_credit_invoice_is_not_a_debt(self):
        """The definition this test defends.

        "Any order whose payments are less than its total" reads every voided
        sale as a receivable: a void keeps its total and carries a reversing
        negative payment.
        """
        self._invoice(
            self.customer, days_ago=5, total="100.00", status=Order.Status.VOID
        )
        self.assertEqual(self._report()["summary"]["receivable_total"], "0.00")

    def test_a_cash_sale_is_not_a_receivable(self):
        Order.objects.create(
            register_session=self.session,
            customer=self.customer,
            sale_type=Order.SaleType.STANDARD,
            status=Order.Status.PAID,
            subtotal=Decimal("50.00"),
            total=Decimal("50.00"),
        )
        self.assertEqual(self._report()["summary"]["receivable_total"], "0.00")

    def test_debts_land_in_the_bucket_their_age_earns(self):
        self._invoice(self.customer, days_ago=5, total="10.00")
        self._invoice(self.customer, days_ago=45, total="20.00")
        self._invoice(self.customer, days_ago=75, total="40.00")
        self._invoice(self.customer, days_ago=200, total="80.00")

        summary = self._report()["summary"]
        self.assertEqual(summary["d0_30"], "10.00")
        self.assertEqual(summary["d31_60"], "20.00")
        self.assertEqual(summary["d61_90"], "40.00")
        self.assertEqual(summary["d90_plus"], "80.00")
        self.assertEqual(summary["receivable_total"], "150.00")
        self.assertEqual(summary["overdue_total"], "140.00")
        self.assertEqual(summary["oldest_days"], 200)

    def test_the_schedule_foots_to_the_stated_total(self):
        self._invoice(self.customer, days_ago=5, total="10.00")
        self._invoice(self.other, days_ago=75, total="40.00")
        payload = self._report()
        section = self._section(payload)
        rows_total = sum(
            (decimal_from(row["total"]) for row in section["rows"]), Decimal("0.00")
        )
        self.assertEqual(rows_total, Decimal(payload["summary"]["receivable_total"]))
        self.assertEqual(len(section["rows"]), 2)

    def test_a_debt_since_collected_is_still_owed_at_the_earlier_date(self):
        """The point of an as-of report.

        Run in November for 30 September, the figure must be what was owed on
        30 September — including debts that have since been paid.
        """
        order = self._invoice(self.customer, days_ago=40, total="100.00")
        Payment.objects.create(
            order=order,
            method=Payment.Method.CASH,
            amount=Decimal("100.00"),
            paid_at=timezone.now() - timedelta(days=5),
        )
        Order.objects.filter(pk=order.pk).update(status=Order.Status.PAID)

        self.assertEqual(self._report()["summary"]["receivable_total"], "0.00")
        earlier = self._report(end=self.today - timedelta(days=20))
        self.assertEqual(earlier["summary"]["receivable_total"], "100.00")

    def test_an_invoice_raised_after_the_date_is_not_yet_owed(self):
        self._invoice(self.customer, days_ago=2, total="100.00")
        earlier = self._report(end=self.today - timedelta(days=10))
        self.assertEqual(earlier["summary"]["receivable_total"], "0.00")


class CustomerStatementTests(TestCase):
    def setUp(self):
        ensure_role_groups()
        User = get_user_model()
        self.manager = User.objects.create_user(username="stmt-mgr", password="p")
        self.manager.groups.add(Group.objects.get(name=MANAGER_GROUP))
        self.today = timezone.localdate()
        self.session = RegisterSession.objects.create(
            owner=self.manager,
            owner_key=f"user:{self.manager.pk}",
            opening_cash=Decimal("0.00"),
        )
        self.customer = Customer.objects.create(full_name="زبون الكشف")

    def _invoice(self, days_ago, total):
        order = Order.objects.create(
            register_session=self.session,
            customer=self.customer,
            sale_type=Order.SaleType.CREDIT,
            status=Order.Status.OPEN,
            subtotal=Decimal(total),
            total=Decimal(total),
        )
        Order.objects.filter(pk=order.pk).update(
            created_at=timezone.now() - timedelta(days=days_ago)
        )
        return order

    def _pay(self, order, days_ago, amount):
        Payment.objects.create(
            order=order,
            method=Payment.Method.CASH,
            amount=Decimal(amount),
            paid_at=timezone.now() - timedelta(days=days_ago),
        )

    def _statement(self, start, end):
        return generate_report_payload(
            report_type=ReportRun.ReportType.CUSTOMER_STATEMENT,
            params={
                "customer_id": self.customer.pk,
                "start_date": start.isoformat(),
                "end_date": end.isoformat(),
            },
            user=self.manager,
        )

    def test_opening_plus_movements_equals_closing(self):
        """The property that makes a statement a statement."""
        self._invoice(days_ago=40, total="100.00")
        inside = self._invoice(days_ago=10, total="50.00")
        self._pay(inside, days_ago=5, amount="30.00")

        payload = self._statement(self.today - timedelta(days=20), self.today)
        summary = payload["summary"]
        self.assertEqual(summary["opening_balance"], "100.00")
        self.assertEqual(summary["invoiced_total"], "50.00")
        self.assertEqual(summary["received_total"], "30.00")
        self.assertEqual(summary["closing_balance"], "120.00")

    def test_the_running_balance_reaches_the_closing_figure(self):
        self._invoice(days_ago=40, total="100.00")
        inside = self._invoice(days_ago=10, total="50.00")
        self._pay(inside, days_ago=5, amount="30.00")

        payload = self._statement(self.today - timedelta(days=20), self.today)
        rows = next(
            s for s in payload["sections"] if s["key"] == "statement_entries"
        )["rows"]
        self.assertEqual(rows[-1]["balance"], payload["summary"]["closing_balance"])

    def test_a_statement_needs_a_customer(self):
        from .registry import ReportValidationError

        with self.assertRaises(ReportValidationError):
            generate_report_payload(
                report_type=ReportRun.ReportType.CUSTOMER_STATEMENT,
                params={"preset": "month"},
                user=self.manager,
            )


class PayablesAgingTests(TestCase):
    def setUp(self):
        ensure_role_groups()
        User = get_user_model()
        self.manager = User.objects.create_user(username="ap-mgr", password="p")
        self.manager.groups.add(Group.objects.get(name=MANAGER_GROUP))
        self.today = timezone.localdate()
        self.supplier = Supplier.objects.create(name="مورد")

    def _order(self, *, days_ago, total, paid=None, due_days_ago=None):
        order = PurchaseOrder.objects.create(
            supplier=self.supplier,
            status=PurchaseOrder.Status.RECEIVED,
            subtotal=Decimal(total),
            total=Decimal(total),
            due_date=(
                self.today - timedelta(days=due_days_ago)
                if due_days_ago is not None
                else None
            ),
        )
        when = timezone.now() - timedelta(days=days_ago)
        PurchaseOrder.objects.filter(pk=order.pk).update(created_at=when)
        if paid:
            SupplierPayment.objects.create(
                purchase_order=order,
                supplier=self.supplier,
                method=SupplierPayment.Method.CASH,
                amount=Decimal(paid),
                paid_at=when,
            )
        return order

    def _report(self):
        return generate_report_payload(
            report_type=ReportRun.ReportType.PAYABLES_AGING,
            params={
                "start_date": self.today.isoformat(),
                "end_date": self.today.isoformat(),
            },
            user=self.manager,
        )

    def test_an_unpaid_order_is_a_payable(self):
        self._order(days_ago=5, total="200.00")
        self.assertEqual(self._report()["summary"]["payable_total"], "200.00")

    def test_a_settled_order_is_not(self):
        self._order(days_ago=5, total="200.00", paid="200.00")
        self.assertEqual(self._report()["summary"]["payable_total"], "0.00")

    def test_a_cancelled_order_is_not(self):
        order = self._order(days_ago=5, total="200.00")
        PurchaseOrder.objects.filter(pk=order.pk).update(
            status=PurchaseOrder.Status.CANCELLED
        )
        self.assertEqual(self._report()["summary"]["payable_total"], "0.00")

    def test_the_due_date_decides_the_bucket_when_there_is_one(self):
        """A supplier chases on the terms agreed, not on when you ordered."""
        self._order(days_ago=5, total="100.00", due_days_ago=100)
        summary = self._report()["summary"]
        self.assertEqual(summary["d90_plus"], "100.00")
        self.assertEqual(summary["d0_30"], "0.00")

    def test_without_a_due_date_it_ages_from_the_order(self):
        self._order(days_ago=100, total="100.00")
        self.assertEqual(self._report()["summary"]["d90_plus"], "100.00")

    def test_a_cancelled_payment_does_not_settle_the_order(self):
        """A cancelled payment keeps its row and its amount. Counting it
        cleared a debt the shop still owed — while the supplier's own screen,
        which never counted it, showed the debt."""
        order = self._order(days_ago=5, total="200.00", paid="200.00")
        SupplierPayment.objects.filter(purchase_order=order).update(
            doc_status=DocumentStatus.CANCELLED
        )
        self.assertEqual(self._report()["summary"]["payable_total"], "200.00")

    def test_a_payment_on_account_settles_the_oldest_order_first(self):
        """Paid to the supplier rather than to one order. Left out, the report
        stated a debt the shop had already settled."""
        self._order(days_ago=50, total="100.00")
        self._order(days_ago=5, total="100.00")
        SupplierPayment.objects.create(
            supplier=self.supplier,
            method=SupplierPayment.Method.CASH,
            amount=Decimal("120.00"),
            paid_at=timezone.now() - timedelta(days=1),
        )
        summary = self._report()["summary"]
        self.assertEqual(summary["payable_total"], "80.00")
        self.assertEqual(summary["d31_60"], "0.00")
        self.assertEqual(summary["d0_30"], "80.00")
        # And it is the debt the supplier's own screen states.
        self.assertEqual(summary["payable_total"], str(self.supplier.payable_balance))


class ReceivablesDueDateAgingTests(ReceivablesAgingTests):
    """Aging once a credit invoice can record when it was actually due.

    Inherits the fixture, because the point of every case here is what changes
    — and what pointedly does not — relative to the invoice-date basis above.
    """

    def test_an_invoice_inside_its_terms_is_not_aged(self):
        # 40 days old, sold on 60-day terms. On the invoice-date basis this read
        # as more than a month overdue; it is not late at all.
        self._invoice(self.customer, days_ago=40, total="100.00", due_in_days=20)
        summary = self._report()["summary"]
        self.assertEqual(summary["not_yet_due"], "100.00")
        self.assertEqual(summary["d31_60"], "0.00")
        self.assertEqual(summary["receivable_total"], "100.00")
        self.assertEqual(summary["oldest_days"], 0)

    def test_a_passed_due_date_ages_from_the_due_date_not_the_invoice(self):
        # 90 days old, was due 10 days ago: 10 days of age, not 90.
        self._invoice(self.customer, days_ago=90, total="100.00", due_in_days=-10)
        summary = self._report()["summary"]
        self.assertEqual(summary["d0_30"], "100.00")
        self.assertEqual(summary["d90_plus"], "0.00")
        self.assertEqual(summary["oldest_days"], 10)

    def test_an_undated_invoice_still_ages_from_its_invoice_date(self):
        # The guarantee that matters for an upgrade: history with no recorded
        # due date lands exactly where it always did.
        self._invoice(self.customer, days_ago=45, total="100.00")
        summary = self._report()["summary"]
        self.assertEqual(summary["d31_60"], "100.00")
        self.assertEqual(summary["not_yet_due"], "0.00")
        self.assertEqual(summary["oldest_days"], 45)

    def test_not_yet_due_is_outstanding_but_never_overdue(self):
        self._invoice(self.customer, days_ago=1, total="250.00", due_in_days=30)
        summary = self._report()["summary"]
        self.assertEqual(summary["receivable_total"], "250.00")
        self.assertEqual(summary["overdue_total"], "0.00")

    def test_due_today_is_aged_at_zero_days_not_held_back(self):
        self._invoice(self.customer, days_ago=10, total="100.00", due_in_days=0)
        summary = self._report()["summary"]
        self.assertEqual(summary["not_yet_due"], "0.00")
        self.assertEqual(summary["d0_30"], "100.00")

    def test_the_customer_row_carries_the_not_yet_due_column(self):
        self._invoice(self.customer, days_ago=5, total="100.00", due_in_days=20)
        self._invoice(self.customer, days_ago=80, total="40.00", due_in_days=-70)
        row = self._section(self._report())["rows"][0]
        self.assertEqual(row["not_yet_due"], "100.00")
        self.assertEqual(row["d61_90"], "40.00")
        self.assertEqual(row["total"], "140.00")

    def test_the_report_says_which_basis_it_used(self):
        self._invoice(self.customer, days_ago=5, total="100.00", due_in_days=20)
        codes = {note["code"] for note in self._report()["notes"]}
        self.assertIn("aged_from_due_or_invoice_date", codes)
        self.assertIn("not_yet_due_excluded_from_ages", codes)
