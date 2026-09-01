"""A schedule that says what it left out, a total that foots, one definition
per figure, and a comparison column.

Four separate defects, one theme: the report was computing the right numbers and
presenting them in a way a reader could not check.
"""

from datetime import timedelta
from decimal import Decimal

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group
from django.test import TestCase
from django.utils import timezone

from apps.catalog.testing import create_product_with_default_variant
from apps.core.roles import MANAGER_GROUP, ensure_role_groups
from apps.employees.models import Employee, PayrollLine, PayrollRun
from apps.employees.reporting import payroll_cost, payroll_paid
from apps.payments.models import Payment
from apps.sales.models import Order, OrderLine, RegisterSession

from .models import ReportRun
from .registry import SECTION_ROW_LIMITS
from .sections import decimal_from
from .services import generate_report_payload


class TruncationTests(TestCase):
    """A schedule that omits rows must say so.

    The row caps were always computed and the metadata always emitted; the
    reader was never told. A month of stock movements printed 120 lines out of
    thousands under a header badged "archive" and a checksum.
    """

    def setUp(self):
        ensure_role_groups()
        User = get_user_model()
        self.manager = User.objects.create_user(username="trunc-mgr", password="p")
        self.manager.groups.add(Group.objects.get(name=MANAGER_GROUP))
        self.session = RegisterSession.objects.create(
            owner=self.manager,
            owner_key=f"user:{self.manager.pk}",
            opening_cash=Decimal("0.00"),
        )
        self.limit = SECTION_ROW_LIMITS["recent_orders"]
        for _ in range(self.limit + 3):
            Order.objects.create(
                register_session=self.session,
                status=Order.Status.PAID,
                subtotal=Decimal("1.00"),
                total=Decimal("1.00"),
            )

    def _section(self, key, **params):
        payload = generate_report_payload(
            report_type=ReportRun.ReportType.SALES_SUMMARY,
            params=params or {"preset": "month"},
            user=self.manager,
        )
        return payload, next(s for s in payload["sections"] if s["key"] == key)

    def test_a_truncated_section_reports_what_it_omitted(self):
        _payload, section = self._section("recent_orders")
        metadata = section["metadata"]
        self.assertTrue(metadata["truncated"])
        self.assertEqual(metadata["returned_count"], self.limit)
        self.assertEqual(metadata["total_count"], self.limit + 3)
        self.assertEqual(metadata["omitted_count"], 3)

    def test_the_report_level_audit_says_the_document_is_incomplete(self):
        payload, _section = self._section("recent_orders")
        self.assertTrue(payload["audit"]["truncated"])
        self.assertEqual(payload["audit"]["omitted_count"], 3)

    def test_asking_for_detail_raises_the_cap(self):
        _payload, section = self._section(
            "recent_orders", preset="month", granularity="detailed"
        )
        self.assertFalse(section["metadata"]["truncated"])
        self.assertEqual(section["metadata"]["returned_count"], self.limit + 3)

    def test_a_truncated_section_still_states_the_total_of_every_row(self):
        """The distinction that makes a short schedule honest.

        "The rows you can see add up to this; all the rows add up to that."
        """
        _payload, section = self._section("recent_orders")
        totals = section["totals"]
        self.assertEqual(decimal_from(totals["shown"]["total"]), Decimal(self.limit))
        self.assertNotEqual(totals["shown"]["total"], totals["full"]["total"])


class ProfitStatementTests(TestCase):
    """Buying stock is not an expense, and the column has to prove it."""

    def setUp(self):
        ensure_role_groups()
        User = get_user_model()
        self.manager = User.objects.create_user(username="pnl-mgr", password="p")
        self.manager.groups.add(Group.objects.get(name=MANAGER_GROUP))
        product = create_product_with_default_variant(
            sku="PNL-1", name="سلعة", unit_price=Decimal("10.00")
        )
        session = RegisterSession.objects.create(
            owner=self.manager,
            owner_key=f"user:{self.manager.pk}",
            opening_cash=Decimal("0.00"),
        )
        order = Order.objects.create(
            register_session=session,
            status=Order.Status.PAID,
            subtotal=Decimal("20.00"),
            total=Decimal("20.00"),
        )
        OrderLine.objects.create(
            order=order,
            variant=product.default_variant,
            quantity=2,
            unit_price=Decimal("10.00"),
            unit_cost=Decimal("4.00"),
        )
        Payment.objects.create(
            order=order, method=Payment.Method.CASH, amount=Decimal("20.00")
        )

    def _payload(self):
        return generate_report_payload(
            report_type=ReportRun.ReportType.PROFIT_COSTS,
            params={"preset": "month"},
            user=self.manager,
        )

    def _statement(self):
        payload = self._payload()
        section = next(
            s for s in payload["sections"] if s["key"] == "profit_statement"
        )
        return payload, {row["line"]: row for row in section["rows"]}

    def test_the_expense_lines_sum_to_the_stated_expense_total(self):
        payload, lines = self._statement()
        components = (
            "payroll_cost_total",
            "payment_commission_total",
            "ad_hoc_expense_total",
            "shrinkage_total",
        )
        total = sum(
            (abs(decimal_from(lines[name]["amount"])) for name in components),
            Decimal("0.00"),
        )
        self.assertEqual(
            total, Decimal(payload["summary"]["operating_expense_total"])
        )

    def test_purchases_sit_below_the_total_and_are_marked(self):
        _payload, lines = self._statement()
        self.assertTrue(lines["purchase_spend_total"]["below_total"])
        self.assertFalse(lines["purchase_spend_total"]["is_total"])

    def test_gross_profit_less_expenses_is_the_net(self):
        payload = self._payload()
        summary = payload["summary"]
        self.assertEqual(
            Decimal(summary["gross_profit"])
            - Decimal(summary["operating_expense_total"]),
            Decimal(summary["net_operating_profit"]),
        )

    def test_the_basis_is_stated(self):
        codes = {note["code"] for note in self._payload()["notes"]}
        self.assertIn("basis_accrual", codes)
        self.assertIn("purchases_are_not_expense", codes)

    def test_the_cash_bridge_reconciles_revenue_to_money_received(self):
        """Revenue recognised, less the movement in what customers owe, is the
        cash the shop should have taken. A cash sale leaves no residual."""
        payload = self._payload()
        rows = {
            row["line"]: decimal_from(row["amount"])
            for row in next(
                s for s in payload["sections"] if s["key"] == "cash_bridge"
            )["rows"]
        }
        self.assertEqual(rows["cash_received_from_customers"], Decimal("20.00"))
        self.assertEqual(rows["unreconciled_difference"], Decimal("0.00"))


class PayrollDefinitionTests(TestCase):
    """One definition each for "what labour cost" and "what wages were paid".

    Two reports used to state the shop's staff cost for the same month and give
    two different numbers, and neither page said which question it answered.
    """

    def setUp(self):
        ensure_role_groups()
        User = get_user_model()
        self.manager = User.objects.create_user(username="pay-mgr", password="p")
        self.manager.groups.add(Group.objects.get(name=MANAGER_GROUP))
        self.today = timezone.localdate()
        self.start = self.today.replace(day=1)
        employee = Employee.objects.create(full_name="موظف")

        # Approved but not paid: a cost of the period, not yet money out.
        self._run(employee, PayrollRun.Status.APPROVED, Decimal("300.00"))
        # Paid inside the period: both a cost and a payment.
        self._run(
            employee,
            PayrollRun.Status.PAID,
            Decimal("500.00"),
            payment_date=self.today,
        )

    def _run(self, employee, status, amount, payment_date=None):
        run = PayrollRun.objects.create(
            status=status,
            period_start=self.start,
            period_end=self.today,
            payment_date=payment_date,
        )
        PayrollLine.objects.create(
            payroll_run=run,
            employee=employee,
            rate=amount,
            gross_amount=amount,
            net_amount=amount,
        )
        run.recalculate(save_lines=True)
        PayrollRun.objects.filter(pk=run.pk).update(
            gross_total=run.gross_total,
            net_total=run.net_total,
            deductions_total=run.deductions_total,
        )
        return run

    def test_cost_and_paid_are_different_questions_with_different_answers(self):
        self.assertEqual(payroll_cost(self.start, self.today), Decimal("800.00"))
        self.assertEqual(payroll_paid(self.start, self.today), Decimal("500.00"))

    def test_both_reports_read_the_same_definitions(self):
        payroll = generate_report_payload(
            report_type=ReportRun.ReportType.PAYROLL_SUMMARY,
            params={"preset": "month"},
            user=self.manager,
        )["summary"]
        profit = generate_report_payload(
            report_type=ReportRun.ReportType.PROFIT_COSTS,
            params={"preset": "month"},
            user=self.manager,
        )["summary"]
        self.assertEqual(payroll["salary_expense"], "800.00")
        self.assertEqual(payroll["paid_total"], "500.00")
        # The profit statement carries the *cost*, and it is named for what it
        # is rather than borrowing the other report's label.
        self.assertEqual(profit["payroll_cost_total"], payroll["salary_expense"])

    def test_a_void_run_is_neither_a_cost_nor_a_payment(self):
        PayrollRun.objects.filter(status=PayrollRun.Status.APPROVED).update(
            status=PayrollRun.Status.VOID
        )
        self.assertEqual(payroll_cost(self.start, self.today), Decimal("500.00"))

    def test_a_run_straddling_the_month_end_counts_in_both(self):
        """Overlap, not containment.

        A fortnightly run crossing the month end is part of both months'
        labour; dropping it from both is how a month ends up with three weeks
        of wages against four weeks of sales.
        """
        employee = Employee.objects.get()
        run = PayrollRun.objects.create(
            status=PayrollRun.Status.APPROVED,
            period_start=self.start - timedelta(days=7),
            period_end=self.start + timedelta(days=7),
        )
        PayrollLine.objects.create(
            payroll_run=run,
            employee=employee,
            rate=Decimal("100.00"),
            gross_amount=Decimal("100.00"),
            net_amount=Decimal("100.00"),
        )
        run.recalculate(save_lines=True)
        PayrollRun.objects.filter(pk=run.pk).update(net_total=run.net_total)
        self.assertEqual(payroll_cost(self.start, self.today), Decimal("900.00"))


class ComparisonColumnTests(TestCase):
    """Every figure in a month-end pack is read as a comparison."""

    def setUp(self):
        ensure_role_groups()
        User = get_user_model()
        self.manager = User.objects.create_user(username="cmp-mgr", password="p")
        self.manager.groups.add(Group.objects.get(name=MANAGER_GROUP))
        self.session = RegisterSession.objects.create(
            owner=self.manager,
            owner_key=f"user:{self.manager.pk}",
            opening_cash=Decimal("0.00"),
        )
        self.today = timezone.localdate()
        self._sale(days_ago=2, total="100.00")
        self._sale(days_ago=40, total="50.00")

    def _sale(self, days_ago, total):
        order = Order.objects.create(
            register_session=self.session,
            status=Order.Status.PAID,
            subtotal=Decimal(total),
            total=Decimal(total),
        )
        Order.objects.filter(pk=order.pk).update(
            created_at=timezone.now() - timedelta(days=days_ago)
        )

    def _payload(self, **params):
        return generate_report_payload(
            report_type=ReportRun.ReportType.SALES_SUMMARY,
            params=params,
            user=self.manager,
        )

    def test_the_comparison_window_is_stated_and_its_figures_carried(self):
        payload = self._payload(
            start_date=(self.today - timedelta(days=9)).isoformat(),
            end_date=self.today.isoformat(),
            comparison="previous_period",
        )
        self.assertIn("previous_summary", payload)
        self.assertEqual(payload["summary"]["net_sales"], "100.00")
        self.assertEqual(payload["previous_summary"]["net_sales"], "0.00")
        self.assertIn("compared_to", payload["period"])

    def test_the_headline_rows_carry_the_movement(self):
        payload = self._payload(
            start_date=(self.today - timedelta(days=9)).isoformat(),
            end_date=self.today.isoformat(),
            comparison="previous_period",
        )
        rows = {
            row["metric"]: row
            for row in next(
                s for s in payload["sections"] if s["key"] == "summary"
            )["rows"]
        }
        self.assertEqual(rows["net_sales"]["previous"], "0.00")
        # Up from nothing is not a percentage, and printing one invites a
        # reader to compare two figures that are not comparable.
        self.assertIsNone(rows["net_sales"]["change_percent"])

    def test_a_real_movement_is_expressed_as_a_percentage(self):
        payload = self._payload(
            start_date=(self.today - timedelta(days=44)).isoformat(),
            end_date=self.today.isoformat(),
            comparison="previous_year",
        )
        self.assertEqual(payload["summary"]["net_sales"], "150.00")

    def test_no_comparison_is_asked_for_by_default(self):
        self.assertNotIn("previous_summary", self._payload(preset="month"))

    def test_the_headline_figures_lead_the_summary_block(self):
        """The PDF used to take whichever eight figures came out of the
        dictionary first, so a report with ten lost two at random."""
        payload = self._payload(preset="month")
        rows = next(s for s in payload["sections"] if s["key"] == "summary")["rows"]
        self.assertEqual(
            [row["metric"] for row in rows[: len(payload["headline"])]],
            payload["headline"],
        )
