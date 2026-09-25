"""Balances on employees' accounts: settled by payroll, reaching every book.

A cashier on 1,000 a month. What they owe the shop comes off the next wage,
oldest first and never more than the pay (or the entry's own limit) can carry;
what the shop owes them is paid with it. Paying the run is the settlement and
voiding it gives the balance back. The books follow one rule: an opening
balance is a position, an adjustment is labour cost on its day, and settling
either — through a run or in cash — is neither.
"""

from datetime import date, timedelta
from decimal import Decimal
from unittest import mock

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group, Permission
from django.test import TestCase
from django.urls import reverse
from django.utils import timezone
from rest_framework import status
from rest_framework.test import APIClient

from apps.core.models import ShopSettings
from apps.core.roles import ACCOUNTANT_GROUP, MANAGER_GROUP, ensure_role_groups
from apps.documents import services as document_services
from apps.documents.errors import DocumentBlocked
from apps.documents.statuses import DocumentStatus
from apps.employees.models import (
    CompensationPlan,
    Employee,
    PayrollAdjustment,
    PayrollRun,
)
from apps.employees.reporting import payroll_cost, wages_payable
from apps.employees.services import (
    approve_payroll_run,
    draft_monthly_payroll_run,
    mark_payroll_run_paid,
    void_payroll_run,
)
from apps.employees.staff_purchases import ensure_staff_customer
from apps.expenses.services import build_expense_ledger
from apps.reports.models import ReportRun
from apps.reports.services import generate_report_payload
from apps.sales.models import Order, RegisterCashMovement, RegisterSession

from .employees import (
    account_position,
    create_employee_entry,
    settle_employee_balance,
)
from .models import BalanceEntry, EmployeeBalanceAllocation, EmployeeBalanceEntry

Kind = BalanceEntry.Kind
Direction = BalanceEntry.Direction
Type = ReportRun.ReportType

MAY_20 = date(2026, 5, 20)
JUNE = (date(2026, 6, 1), date(2026, 6, 30))
JULY = (date(2026, 7, 1), date(2026, 7, 31))
MAY = (date(2026, 5, 1), date(2026, 5, 31))


def _balance_rows(run):
    return PayrollAdjustment.objects.filter(
        payroll_line__payroll_run=run,
        adjustment_type=PayrollAdjustment.AdjustmentType.ACCOUNT_BALANCE,
    ).order_by("id")


class _EmployeeCase(TestCase):
    def setUp(self):
        ensure_role_groups()
        ShopSettings.load()
        self.manager = get_user_model().objects.create_user(
            username="owner", password="p"
        )
        self.manager.groups.add(Group.objects.get(name=MANAGER_GROUP))
        self.client = APIClient()
        self.client.force_authenticate(user=self.manager)
        self.employee = Employee.objects.create(full_name="سالم")
        CompensationPlan.objects.create(
            employee=self.employee,
            pay_type=CompensationPlan.PayType.MONTHLY_SALARY,
            salary_type=CompensationPlan.SalaryType.MONTHLY_FIXED,
            amount=Decimal("1000.00"),
            effective_from=date(2026, 1, 1),
        )

    def _entry(
        self,
        direction,
        amount,
        *,
        kind=Kind.ADJUSTMENT,
        limit=None,
        effective_date=MAY_20,
        note="سبب",
    ):
        return create_employee_entry(
            employee=self.employee,
            kind=kind,
            direction=direction,
            amount=Decimal(amount),
            effective_date=effective_date,
            note=note,
            payroll_deduction_limit=limit,
            actor=self.manager,
        )

    def _draft(self, period=JUNE):
        run, _created = draft_monthly_payroll_run(
            period_start=period[0], period_end=period[1]
        )
        return run

    def _pay(self, run, *, on=None):
        return mark_payroll_run_paid(
            approve_payroll_run(run), payment_date=on or run.period_end
        )

    def _open_drawer(self):
        response = self.client.post(
            reverse("register-session-start"), {"opening_cash": "500.00"}, format="json"
        )
        self.assertIn(response.status_code, (200, 201), response.data)
        return RegisterSession.objects.get(pk=response.data["id"])

    def _remaining(self, entry):
        response = self.client.get(
            reverse("employee-balance-entry-detail", args=[entry.pk])
        )
        self.assertEqual(response.status_code, status.HTTP_200_OK, response.data)
        return Decimal(response.data["remaining_amount"])


class EmployeePayrollTests(_EmployeeCase):
    def test_the_next_run_deducts_what_the_employee_owes(self):
        entry = self._entry(Direction.THEY_OWE_US, "300.00", kind=Kind.OPENING)

        run = self._draft()

        row = _balance_rows(run).get()
        self.assertEqual(row.direction, PayrollAdjustment.Direction.DEDUCTION)
        self.assertEqual(row.balance_entry, entry)
        self.assertEqual(row.amount, Decimal("300.00"))
        self.assertEqual(run.lines.get().net_amount, Decimal("700.00"))
        self.assertEqual(run.net_total, Decimal("700.00"))
        # Not settled until the run is paid; on the run meanwhile.
        detail = self.client.get(
            reverse("employee-balance-entry-detail", args=[entry.pk])
        ).data
        self.assertEqual(detail["remaining_amount"], "300.00")
        self.assertEqual(detail["scheduled_amount"], "300.00")
        payload = self.client.get(reverse("payroll-run-detail", args=[run.pk])).data
        (adjustment,) = payload["lines"][0]["adjustments"]
        self.assertEqual(adjustment["balance_entry_number"], entry.number)
        self.assertEqual(adjustment["balance_entry_kind"], "opening")

    def test_paying_the_run_settles_the_balance(self):
        entry = self._entry(Direction.THEY_OWE_US, "300.00")

        self._pay(self._draft())

        self.assertEqual(self._remaining(entry), Decimal("0.00"))
        position = account_position(self.employee)
        self.assertEqual(position.owed_by_employee, Decimal("0.00"))
        # And the next run has nothing to take.
        self.assertFalse(_balance_rows(self._draft(JULY)).exists())

    def test_a_debt_the_pay_cannot_carry_waits_for_the_next_run(self):
        entry = self._entry(Direction.THEY_OWE_US, "1500.00")

        june = self._pay(self._draft())

        self.assertEqual(_balance_rows(june).get().amount, Decimal("1000.00"))
        self.assertEqual(june.net_total, Decimal("0.00"))
        self.assertEqual(self._remaining(entry), Decimal("500.00"))
        self.assertEqual(_balance_rows(self._draft(JULY)).get().amount, Decimal("500.00"))

    def test_a_limit_spreads_a_debt_over_runs(self):
        entry = self._entry(Direction.THEY_OWE_US, "900.00", limit=Decimal("300.00"))

        june = self._pay(self._draft())

        self.assertEqual(_balance_rows(june).get().amount, Decimal("300.00"))
        self.assertEqual(june.net_total, Decimal("700.00"))
        self.assertEqual(self._remaining(entry), Decimal("600.00"))
        self.assertEqual(_balance_rows(self._draft(JULY)).get().amount, Decimal("300.00"))

    def test_what_the_shop_owes_is_paid_with_the_wage(self):
        entry = self._entry(Direction.WE_OWE_THEM, "250.00", note="مكافأة")

        run = self._pay(self._draft())

        row = _balance_rows(run).get()
        self.assertEqual(row.direction, PayrollAdjustment.Direction.ADDITION)
        self.assertEqual(run.net_total, Decimal("1250.00"))
        self.assertEqual(self._remaining(entry), Decimal("0.00"))

    def test_both_sides_on_one_line(self):
        self._entry(Direction.THEY_OWE_US, "200.00")
        self._entry(Direction.WE_OWE_THEM, "100.00")

        run = self._draft()

        self.assertEqual(run.net_total, Decimal("900.00"))

    def test_staff_purchases_give_way_before_a_balance(self):
        self._entry(Direction.THEY_OWE_US, "800.00")
        account = ensure_staff_customer(self.employee)
        session = RegisterSession.objects.create(
            owner=self.manager,
            owner_key=f"user:{self.manager.pk}",
            opening_cash=Decimal("0.00"),
        )
        invoice = Order.objects.create(
            register_session=session,
            customer=account,
            sale_type=Order.SaleType.CREDIT,
            status=Order.Status.OPEN,
            subtotal=Decimal("500.00"),
            total=Decimal("500.00"),
        )
        from apps.sales.testing import issue

        issue(invoice, status=Order.Status.OPEN)

        run = self._draft()

        # The balance comes first; the purchases take what is left.
        balance = _balance_rows(run).get()
        purchase = PayrollAdjustment.objects.get(
            payroll_line__payroll_run=run,
            adjustment_type=PayrollAdjustment.AdjustmentType.STAFF_PURCHASE,
        )
        self.assertEqual(balance.amount, Decimal("800.00"))
        self.assertEqual(purchase.amount, Decimal("200.00"))

        # A deduction typed afterwards takes the purchases first.
        line = run.lines.get()
        line.manual_deduction_amount = Decimal("300.00")
        line.save(update_fields=["manual_deduction_amount"])
        run = PayrollRun.objects.get(pk=run.pk)
        run.recalculate(save_lines=True)

        self.assertFalse(
            PayrollAdjustment.objects.filter(pk=purchase.pk).exists()
        )
        balance.refresh_from_db()
        self.assertEqual(balance.amount, Decimal("700.00"))
        self.assertEqual(run.lines.get().net_amount, Decimal("0.00"))

    def test_two_unpaid_runs_do_not_take_it_twice(self):
        self._entry(Direction.THEY_OWE_US, "300.00")

        june = self._draft()
        july = self._draft(JULY)

        self.assertEqual(_balance_rows(june).get().amount, Decimal("300.00"))
        self.assertFalse(_balance_rows(july).exists())

    def test_cash_settled_after_approval_is_not_deducted_again(self):
        entry = self._entry(Direction.THEY_OWE_US, "300.00")
        run = approve_payroll_run(self._draft())
        self._open_drawer()
        settle_employee_balance(
            employee=self.employee,
            settles=Direction.THEY_OWE_US,
            amount=Decimal("300.00"),
            actor=self.manager,
        )

        run = mark_payroll_run_paid(run, payment_date=JUNE[1])

        self.assertFalse(_balance_rows(run).exists())
        self.assertEqual(run.net_total, Decimal("1000.00"))
        self.assertEqual(self._remaining(entry), Decimal("0.00"))

    def test_voiding_the_run_gives_the_balance_back(self):
        entry = self._entry(Direction.THEY_OWE_US, "300.00")
        run = self._pay(self._draft())

        void_payroll_run(run, reason="صُرف بالخطأ")

        self.assertEqual(self._remaining(entry), Decimal("300.00"))
        self.assertEqual(_balance_rows(self._draft(JULY)).get().amount, Decimal("300.00"))

    def test_a_client_cannot_type_a_balance_row(self):
        self._entry(Direction.THEY_OWE_US, "300.00")
        run = self._draft()

        response = self.client.post(
            reverse("payroll-run-bulk-adjustments", args=[run.pk]),
            {
                "line_ids": [run.lines.get().pk],
                "direction": "deduction",
                "adjustment_type": "account_balance",
                "amount": "50.00",
            },
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertEqual(_balance_rows(run).get().amount, Decimal("300.00"))

    def test_withdrawing_an_entry_lifts_it_off_an_unpaid_run(self):
        entry = self._entry(Direction.THEY_OWE_US, "300.00")
        run = approve_payroll_run(self._draft())

        document_services.cancel(entry, reason="سُجّل بالخطأ", actor=self.manager)

        run = PayrollRun.objects.get(pk=run.pk)
        self.assertFalse(_balance_rows(run).exists())
        self.assertEqual(run.net_total, Decimal("1000.00"))

    def test_an_entry_a_paid_run_settled_cannot_be_withdrawn(self):
        entry = self._entry(Direction.THEY_OWE_US, "300.00")
        self._pay(self._draft())

        with self.assertRaises(DocumentBlocked):
            document_services.cancel(entry, reason="لا", actor=self.manager)
        entry.refresh_from_db()
        self.assertEqual(entry.doc_status, DocumentStatus.SUBMITTED)


class EmployeeEntryRulesTests(_EmployeeCase):
    def test_one_opening_balance_per_employee(self):
        self._entry(Direction.THEY_OWE_US, "100.00", kind=Kind.OPENING)

        response = self.client.post(
            reverse("employee-balance-entry-list"),
            {
                "employee": self.employee.pk,
                "kind": "opening",
                "direction": "we_owe_them",
                "amount": "50.00",
            },
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertEqual(response.data["code"], "opening_balance_exists")

    def test_only_a_debt_takes_a_deduction_limit(self):
        response = self.client.post(
            reverse("employee-balance-entry-list"),
            {
                "employee": self.employee.pk,
                "kind": "adjustment",
                "direction": "we_owe_them",
                "amount": "50.00",
                "note": "مكافأة",
                "payroll_deduction_limit": "10.00",
            },
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertIn("payroll_deduction_limit", response.data)

    def test_an_undated_entry_is_dated_on_the_reports_clock(self):
        # Half past midnight in Tripoli: the shop's day is already tomorrow on
        # the reports' clock.
        tomorrow = timezone.localdate() + timedelta(days=1)
        with mock.patch("apps.balances.common.business_local_date", return_value=tomorrow):
            entry = create_employee_entry(
                employee=self.employee,
                kind=Kind.ADJUSTMENT,
                direction=Direction.THEY_OWE_US,
                amount=Decimal("10.00"),
                note="عجز",
                actor=self.manager,
            )
        self.assertEqual(entry.effective_date, timezone.localdate())

    def test_the_employee_arrives_with_an_opening_balance(self):
        response = self.client.post(
            reverse("employee-list"),
            {
                "full_name": "موظف جديد",
                "opening_balance": {
                    "direction": "they_owe_us",
                    "amount": "400.00",
                    "payroll_deduction_limit": "100.00",
                },
            },
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_201_CREATED, response.data)
        entry = EmployeeBalanceEntry.objects.get(employee_id=response.data["id"])
        self.assertEqual(entry.kind, Kind.OPENING)
        self.assertEqual(entry.payroll_deduction_limit, Decimal("100.00"))
        detail = self.client.get(reverse("employee-detail", args=[response.data["id"]]))
        self.assertEqual(detail.data["account_balance"]["owed_by_employee"], "400.00")
        self.assertTrue(detail.data["account_balance"]["has_opening_balance"])

    def test_an_opening_balance_needs_its_own_permission(self):
        clerk = get_user_model().objects.create_user(username="hr", password="p")
        clerk.user_permissions.add(
            *Permission.objects.filter(
                codename__in=("add_employee", "view_employee"),
                content_type__app_label="employees",
            )
        )
        client = APIClient()
        client.force_authenticate(user=clerk)

        response = client.post(
            reverse("employee-list"),
            {
                "full_name": "موظف",
                "opening_balance": {"direction": "they_owe_us", "amount": "400.00"},
            },
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_403_FORBIDDEN)
        self.assertFalse(Employee.objects.filter(full_name="موظف").exists())

    def test_the_accountant_keeps_the_employee_accounts(self):
        accountant = get_user_model().objects.create_user(username="acc", password="p")
        accountant.groups.add(Group.objects.get(name=ACCOUNTANT_GROUP))
        client = APIClient()
        client.force_authenticate(user=accountant)

        response = client.post(
            reverse("employee-balance-entry-list"),
            {
                "employee": self.employee.pk,
                "kind": "adjustment",
                "direction": "they_owe_us",
                "amount": "75.00",
                "note": "عجز في الدرج",
            },
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_201_CREATED, response.data)


class EmployeeCashSettlementTests(_EmployeeCase):
    def _settle(self, settles, amount):
        return self.client.post(
            reverse("employee-balance-entry-refund"),
            {"employee": self.employee.pk, "amount": amount, "settles": settles},
            format="json",
        )

    def test_the_shop_pays_what_it_owes_from_the_drawer(self):
        older = self._entry(Direction.WE_OWE_THEM, "100.00", effective_date=date(2026, 4, 1))
        newer = self._entry(Direction.WE_OWE_THEM, "150.00")
        session = self._open_drawer()

        response = self._settle("we_owe_them", "180.00")

        self.assertEqual(response.status_code, status.HTTP_201_CREATED, response.data)
        movement = RegisterCashMovement.objects.get(register_session=session)
        self.assertEqual(movement.movement_type, RegisterCashMovement.MovementType.PAY_OUT)
        self.assertEqual(movement.amount, Decimal("180.00"))
        session.refresh_from_db()
        self.assertEqual(session.expected_cash, Decimal("320.00"))
        # Oldest first.
        self.assertEqual(
            list(
                EmployeeBalanceAllocation.objects.order_by("id").values_list(
                    "entry_id", "amount"
                )
            ),
            [(older.pk, Decimal("100.00")), (newer.pk, Decimal("80.00"))],
        )
        self.assertEqual(account_position(self.employee).owed_to_employee, Decimal("70.00"))
        # A debt settled, not money spent.
        today = timezone.localdate()
        ledger = build_expense_ledger(user=self.manager, start=today, end=today)
        self.assertFalse(
            [row for row in ledger["rows"] if row["related_id"] == movement.pk]
        )

    def test_the_employee_pays_back_into_the_drawer(self):
        entry = self._entry(Direction.THEY_OWE_US, "300.00")
        session = self._open_drawer()

        response = self._settle("they_owe_us", "120.00")

        self.assertEqual(response.status_code, status.HTTP_201_CREATED, response.data)
        movement = RegisterCashMovement.objects.get(register_session=session)
        self.assertEqual(movement.movement_type, RegisterCashMovement.MovementType.PAY_IN)
        self.assertEqual(self._remaining(entry), Decimal("180.00"))

    def test_no_more_than_is_owed(self):
        self._entry(Direction.THEY_OWE_US, "100.00")
        self._open_drawer()

        response = self._settle("they_owe_us", "150.00")

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertEqual(response.data["code"], "refund_exceeds_credit")

    def test_cash_needs_an_open_drawer(self):
        self._entry(Direction.THEY_OWE_US, "100.00")

        response = self._settle("they_owe_us", "50.00")

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertEqual(response.data["code"], "register_session_required")

    def test_a_settlement_is_final_and_so_is_what_it_settled(self):
        entry = self._entry(Direction.THEY_OWE_US, "100.00")
        self._open_drawer()
        refund = EmployeeBalanceEntry.objects.get(
            pk=self._settle("they_owe_us", "40.00").data["id"]
        )

        response = self.client.post(
            reverse("employee-balance-entry-cancel", args=[refund.pk]),
            {"reason": "خطأ"},
            format="json",
        )
        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertEqual(response.data["code"], "refund_is_final")
        with self.assertRaises(DocumentBlocked):
            document_services.cancel(entry, reason="لا", actor=self.manager)


class EmployeeBooksTests(_EmployeeCase):
    def test_an_adjustment_is_labour_cost_on_its_day_and_not_again_when_paid(self):
        self._entry(Direction.WE_OWE_THEM, "200.00", effective_date=date(2026, 5, 15))

        self.assertEqual(payroll_cost(*MAY), Decimal("200.00"))
        run = self._pay(self._draft())
        self.assertEqual(run.net_total, Decimal("1200.00"))
        self.assertEqual(payroll_cost(*JUNE), Decimal("1000.00"))

    def test_an_opening_balance_is_never_labour_cost(self):
        # Wages the old books still owed: paid with June's wage, not June's cost.
        self._entry(Direction.WE_OWE_THEM, "500.00", kind=Kind.OPENING)

        self.assertEqual(payroll_cost(*MAY), Decimal("0.00"))
        run = self._pay(self._draft())
        self.assertEqual(run.net_total, Decimal("1500.00"))
        self.assertEqual(payroll_cost(*JUNE), Decimal("1000.00"))

    def test_a_recovery_reduces_labour_cost_once(self):
        self._entry(Direction.THEY_OWE_US, "150.00", effective_date=date(2026, 5, 15))

        self.assertEqual(payroll_cost(*MAY), Decimal("-150.00"))
        run = self._pay(self._draft())
        self.assertEqual(run.net_total, Decimal("850.00"))
        # The wage was the whole 1,000; 150 of it settled the debt.
        self.assertEqual(payroll_cost(*JUNE), Decimal("1000.00"))

    def test_wages_owed_by_an_approved_run_are_gross_of_the_balances(self):
        self._entry(Direction.THEY_OWE_US, "300.00", kind=Kind.OPENING)
        self._entry(Direction.WE_OWE_THEM, "100.00")
        approve_payroll_run(self._draft())

        self.assertEqual(wages_payable(timezone.localdate()), Decimal("1000.00"))

    def _report(self, report_type, *, start, end):
        return generate_report_payload(
            report_type=report_type,
            params={"start_date": start.isoformat(), "end_date": end.isoformat()},
            user=self.manager,
        )

    def _lines(self, payload, key):
        section = next(s for s in payload["sections"] if s["key"] == key)
        return {row["line"]: row for row in section["rows"]}

    def test_the_balance_sheet_carries_both_sides_and_bridges_the_opening(self):
        self._entry(Direction.THEY_OWE_US, "300.00", kind=Kind.OPENING, effective_date=date(2026, 5, 1))
        self._entry(Direction.WE_OWE_THEM, "100.00", effective_date=date(2026, 5, 10))

        payload = self._report(Type.BALANCE_SHEET, start=MAY[0], end=MAY[1])

        assets = self._lines(payload, "balance_assets")
        liabilities = self._lines(payload, "balance_liabilities")
        self.assertEqual(
            assets["employee_account_receivables"]["closing_balance"], "300.00"
        )
        self.assertEqual(
            liabilities["employee_account_payables"]["closing_balance"], "100.00"
        )
        movement = self._lines(payload, "net_position_movement")
        self.assertEqual(movement["opening_balances_recorded"]["amount"], "300.00")
        # What is left is the adjustment — the same figure the labour cost has.
        self.assertEqual(payload["summary"]["period_result"], "-100.00")
        self.assertEqual(payroll_cost(*MAY), Decimal("100.00"))

    def test_a_paid_run_takes_the_balance_off_the_sheet(self):
        self._entry(Direction.THEY_OWE_US, "300.00", kind=Kind.OPENING, effective_date=date(2026, 5, 1))
        self._pay(self._draft(), on=JUNE[1])

        payload = self._report(Type.BALANCE_SHEET, start=JUNE[0], end=JUNE[1])

        assets = self._lines(payload, "balance_assets")
        self.assertEqual(
            assets["employee_account_receivables"]["opening_balance"], "300.00"
        )
        self.assertEqual(
            assets["employee_account_receivables"]["closing_balance"], "0.00"
        )

    def test_the_payroll_summary_states_what_is_on_the_staff_accounts(self):
        self._entry(Direction.THEY_OWE_US, "300.00", kind=Kind.OPENING, effective_date=date(2026, 5, 1))
        self._entry(Direction.WE_OWE_THEM, "40.00", effective_date=date(2026, 5, 2))

        payload = self._report(Type.PAYROLL_SUMMARY, start=MAY[0], end=MAY[1])

        self.assertEqual(payload["summary"]["staff_owe_total"], "300.00")
        self.assertEqual(payload["summary"]["owed_to_staff_total"], "40.00")
        section = next(
            s for s in payload["sections"] if s["key"] == "employee_account_balances"
        )
        self.assertEqual(
            section["rows"],
            [
                {
                    "employee_name": "سالم",
                    "owed_by_employee": "300.00",
                    "owed_to_employee": "40.00",
                }
            ],
        )
