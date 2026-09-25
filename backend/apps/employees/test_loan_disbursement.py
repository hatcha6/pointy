"""Approving a loan is handing its money over — and the books now see it leave.

Before, an approved loan was on the balance sheet as owed to the shop while the
cash that paid it was still counted in the box: approving a 600 loan read as a
600 gain, and repaying it through payroll read as 200 less labour cost a
month. Now the money leaves the drawer, the cash box or a bank on the day the
loan is approved, and an instalment is part of the wage it came out of.
"""

from datetime import date
from decimal import Decimal

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group
from django.test import TestCase
from django.urls import reverse
from django.utils import timezone
from rest_framework import status
from rest_framework.test import APIClient

from apps.core.models import ShopSettings
from apps.core.roles import ACCOUNTANT_GROUP, MANAGER_GROUP, ensure_role_groups
from apps.expenses.services import build_expense_ledger
from apps.reports.models import ReportRun
from apps.reports.services import generate_report_payload
from apps.sales.models import RegisterCashMovement, RegisterSession
from apps.treasury.models import MoneyAccount
from apps.treasury.movements import account_movements
from apps.treasury.position import treasury_position

from .models import CompensationPlan, Employee, EmployeeLoan, PayrollAdjustment
from .reporting import payroll_cost
from .services import draft_monthly_payroll_run

JUNE = (date(2026, 6, 1), date(2026, 6, 30))


class LoanDisbursementTests(TestCase):
    def setUp(self):
        ensure_role_groups()
        ShopSettings.load()
        self.manager = get_user_model().objects.create_user(
            username="owner", password="p"
        )
        self.manager.groups.add(Group.objects.get(name=MANAGER_GROUP))
        self.client = APIClient()
        self.client.force_authenticate(user=self.manager)
        self.today = timezone.localdate()
        self.cash_box = self._account(MoneyAccount.Kind.CASH, "الخزينة")
        self.bank = self._account(MoneyAccount.Kind.BANK, "المصرف")
        self.employee = Employee.objects.create(full_name="سالم")
        CompensationPlan.objects.create(
            employee=self.employee,
            pay_type=CompensationPlan.PayType.MONTHLY_SALARY,
            salary_type=CompensationPlan.SalaryType.MONTHLY_FIXED,
            amount=Decimal("1000.00"),
            effective_from=date(2026, 1, 1),
        )
        self.loan = EmployeeLoan.objects.create(
            employee=self.employee,
            requested_by=self.manager,
            amount=Decimal("600.00"),
            monthly_deduction=Decimal("200.00"),
        )

    @staticmethod
    def _account(kind, name):
        """The shop's default account of a kind — seeded for cash — counted
        from the start of the year, from nothing."""
        account = MoneyAccount.objects.filter(kind=kind, is_default=True).first()
        if account is None:
            account = MoneyAccount.objects.create(name=name, kind=kind, is_default=True)
        MoneyAccount.objects.filter(pk=account.pk).update(
            name=name, opening_balance=Decimal("0.00"), opening_at=date(2026, 1, 1)
        )
        account.refresh_from_db()
        return account

    def _approve(self, client=None, **payload):
        return (client or self.client).post(
            reverse("employee-loan-approve", args=[self.loan.pk]),
            payload,
            format="json",
        )

    def _components(self, account):
        position = next(
            row
            for row in treasury_position(as_of=self.today)["accounts"]
            if row["account"].pk == account.pk
        )
        return {part["code"]: part["amount"] for part in position["components"]}

    def _open_drawer(self):
        response = self.client.post(
            reverse("register-session-start"), {"opening_cash": "1000.00"}, format="json"
        )
        self.assertIn(response.status_code, (200, 201), response.data)
        return RegisterSession.objects.get(pk=response.data["id"])

    def test_a_client_that_says_nothing_pays_it_from_the_cash_box(self):
        response = self._approve()

        self.assertEqual(response.status_code, status.HTTP_200_OK, response.data)
        self.loan.refresh_from_db()
        self.assertEqual(self.loan.status, EmployeeLoan.Status.APPROVED)
        self.assertEqual(self.loan.disbursement_method, "cash")
        self.assertIsNotNone(self.loan.disbursed_at)
        self.assertEqual(response.data["disbursement_method"], "cash")
        self.assertFalse(response.data["paid_from_register"])
        self.assertEqual(self._components(self.cash_box)["staff_loans"], Decimal("-600.00"))

    def test_from_the_approvers_own_drawer(self):
        session = self._open_drawer()

        response = self._approve(pay_from_register=True)

        self.assertEqual(response.status_code, status.HTTP_200_OK, response.data)
        movement = RegisterCashMovement.objects.get(register_session=session)
        self.assertEqual(movement.movement_type, RegisterCashMovement.MovementType.PAY_OUT)
        self.assertEqual(movement.amount, Decimal("600.00"))
        session.refresh_from_db()
        self.assertEqual(session.expected_cash, Decimal("400.00"))
        # Counted once, as the loan — not a second time as a drawer pay-out.
        components = self._components(self.cash_box)
        self.assertEqual(components["staff_loans"], Decimal("-600.00"))
        self.assertNotIn("drawer_out", components)
        rows = account_movements(self.cash_box, start=self.today, end=self.today)["rows"]
        self.assertEqual(
            [(row["source"], row["amount"]) for row in rows],
            [("staff_loans", Decimal("-600.00"))],
        )
        # Lent, not spent.
        ledger = build_expense_ledger(user=self.manager, start=self.today, end=self.today)
        self.assertEqual(ledger["rows"], [])

    def test_the_drawer_has_to_be_open(self):
        response = self._approve(pay_from_register=True)

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertEqual(response.data["code"], "register_session_required")
        self.loan.refresh_from_db()
        self.assertEqual(self.loan.status, EmployeeLoan.Status.REQUESTED)

    def test_paying_from_a_drawer_is_the_drawers_own_right(self):
        accountant = get_user_model().objects.create_user(username="acc", password="p")
        accountant.groups.add(Group.objects.get(name=ACCOUNTANT_GROUP))
        client = APIClient()
        client.force_authenticate(user=accountant)

        refused = self._approve(client, pay_from_register=True)
        allowed = self._approve(client)

        self.assertEqual(refused.status_code, status.HTTP_403_FORBIDDEN)
        self.assertEqual(allowed.status_code, status.HTTP_200_OK, allowed.data)

    def test_by_transfer_from_a_bank(self):
        response = self._approve(disbursement_method="transfer", money_account=self.bank.pk)

        self.assertEqual(response.status_code, status.HTTP_200_OK, response.data)
        self.assertEqual(response.data["money_account_name"], "المصرف")
        self.assertEqual(self._components(self.bank)["staff_loans"], Decimal("-600.00"))
        self.assertNotIn("staff_loans", self._components(self.cash_box))

    def test_cash_names_no_account(self):
        response = self._approve(money_account=self.bank.pk)

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertIn("money_account", response.data)

    def test_a_loan_paid_out_cannot_change_or_disappear(self):
        self._approve()

        edited = self.client.patch(
            reverse("employee-loan-detail", args=[self.loan.pk]),
            {"amount": "900.00"},
            format="json",
        )
        deleted = self.client.delete(
            reverse("employee-loan-detail", args=[self.loan.pk])
        )
        rescheduled = self.client.patch(
            reverse("employee-loan-detail", args=[self.loan.pk]),
            {"monthly_deduction": "150.00"},
            format="json",
        )

        self.assertEqual(edited.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertEqual(deleted.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertEqual(rescheduled.status_code, status.HTTP_200_OK, rescheduled.data)
        self.loan.refresh_from_db()
        self.assertEqual(self.loan.amount, Decimal("600.00"))

    def test_a_loan_is_not_a_gain_on_the_balance_sheet(self):
        self._approve()

        payload = generate_report_payload(
            report_type=ReportRun.ReportType.BALANCE_SHEET,
            params={
                "start_date": self.today.replace(day=1).isoformat(),
                "end_date": self.today.isoformat(),
            },
            user=self.manager,
        )

        assets = {
            row["line"]: row
            for row in next(
                s for s in payload["sections"] if s["key"] == "balance_assets"
            )["rows"]
        }
        self.assertEqual(assets["employee_loans"]["change"], "600.00")
        self.assertEqual(assets["cash_and_bank"]["change"], "-600.00")
        self.assertEqual(payload["summary"]["period_result"], "0.00")

    def test_an_instalment_is_still_part_of_the_wage(self):
        self._approve()

        run, _created = draft_monthly_payroll_run(
            period_start=JUNE[0], period_end=JUNE[1]
        )
        from .services import approve_payroll_run

        run = approve_payroll_run(run)

        instalment = PayrollAdjustment.objects.get(
            payroll_line__payroll_run=run, loan=self.loan
        )
        self.assertEqual(instalment.amount, Decimal("200.00"))
        self.assertEqual(run.net_total, Decimal("800.00"))
        self.assertEqual(payroll_cost(*JUNE), Decimal("1000.00"))
