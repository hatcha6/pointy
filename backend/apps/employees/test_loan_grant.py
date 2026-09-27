"""A loan the owner gives, not only one an employee asks for.

Until this, the only way a loan came into being was an employee requesting it
from their own login. Staff without one — most of a small shop's — could not
be lent to at all, and an owner handing over an advance had no way to write it
down. Now whoever may record a loan records it for any employee on payroll,
and whoever may also approve one hands it over in the same step.
"""

from datetime import date
from decimal import Decimal

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group, Permission
from django.test import TestCase
from django.urls import reverse
from rest_framework import status
from rest_framework.test import APIClient

from apps.core.models import ShopSettings
from apps.core.roles import ACCOUNTANT_GROUP, MANAGER_GROUP, ensure_role_groups
from apps.sales.models import RegisterCashMovement, RegisterSession
from apps.treasury.models import MoneyAccount

from .models import CompensationPlan, Employee, EmployeeLoan, PayrollAdjustment
from .services import draft_monthly_payroll_run


class LoanGrantTests(TestCase):
    def setUp(self):
        ensure_role_groups()
        ShopSettings.load()
        self.manager = self._user("owner", MANAGER_GROUP)
        self.client = self._client(self.manager)
        self.cash_box = self._account(MoneyAccount.Kind.CASH, "الخزينة")
        self.bank = self._account(MoneyAccount.Kind.BANK, "المصرف")
        # No login: the employee this was built for.
        self.employee = Employee.objects.create(full_name="سالم")
        CompensationPlan.objects.create(
            employee=self.employee,
            pay_type=CompensationPlan.PayType.MONTHLY_SALARY,
            salary_type=CompensationPlan.SalaryType.MONTHLY_FIXED,
            amount=Decimal("1000.00"),
            effective_from=date(2026, 1, 1),
        )

    @staticmethod
    def _account(kind, name):
        """The shop's default account of a kind — seeded for cash."""
        account = MoneyAccount.objects.filter(kind=kind, is_default=True).first()
        if account is None:
            account = MoneyAccount.objects.create(name=name, kind=kind, is_default=True)
        MoneyAccount.objects.filter(pk=account.pk).update(name=name)
        account.refresh_from_db()
        return account

    @staticmethod
    def _user(username, group=None, permissions=()):
        user = get_user_model().objects.create_user(username=username, password="p")
        if group:
            user.groups.add(Group.objects.get(name=group))
        for code in permissions:
            app_label, codename = code.split(".")
            user.user_permissions.add(
                Permission.objects.get(
                    content_type__app_label=app_label, codename=codename
                )
            )
        return user

    @staticmethod
    def _client(user):
        client = APIClient()
        client.force_authenticate(user=user)
        return client

    def _terms(self, **overrides):
        return {
            "employee": self.employee.pk,
            "amount": "600.00",
            "monthly_deduction": "200.00",
            "purpose": "علاج",
            **overrides,
        }

    def _grant(self, client=None, **payload):
        return (client or self.client).post(
            reverse("employee-loan-grant"), self._terms(**payload), format="json"
        )

    def _record(self, client=None, **payload):
        return (client or self.client).post(
            reverse("employee-loan-list"), self._terms(**payload), format="json"
        )

    def test_recording_a_loan_for_an_employee_leaves_it_to_be_approved(self):
        response = self._record()

        self.assertEqual(response.status_code, status.HTTP_201_CREATED, response.data)
        loan = EmployeeLoan.objects.get(pk=response.data["id"])
        self.assertEqual(loan.employee, self.employee)
        self.assertEqual(loan.status, EmployeeLoan.Status.REQUESTED)
        self.assertEqual(loan.requested_by, self.manager)
        self.assertIsNone(loan.disbursed_at)

    def test_granting_hands_the_money_over_from_the_cash_box(self):
        response = self._grant()

        self.assertEqual(response.status_code, status.HTTP_201_CREATED, response.data)
        loan = EmployeeLoan.objects.get(pk=response.data["id"])
        self.assertEqual(loan.status, EmployeeLoan.Status.APPROVED)
        self.assertEqual(loan.outstanding_balance, Decimal("600.00"))
        self.assertEqual(loan.purpose, "علاج")
        # Given and handed over by the same person, and the record says so.
        self.assertEqual(loan.requested_by, self.manager)
        self.assertEqual(loan.reviewed_by, self.manager)
        self.assertEqual(loan.disbursed_by, self.manager)
        self.assertEqual(loan.disbursement_method, "cash")
        self.assertIsNotNone(loan.disbursed_at)
        self.assertIsNone(loan.cash_movement)
        self.assertEqual(response.data["status"], "approved")
        self.assertFalse(response.data["paid_from_register"])

    def test_granting_from_the_givers_own_drawer(self):
        opened = self.client.post(
            reverse("register-session-start"), {"opening_cash": "1000.00"}, format="json"
        )
        self.assertIn(opened.status_code, (200, 201), opened.data)
        session = RegisterSession.objects.get(pk=opened.data["id"])

        response = self._grant(pay_from_register=True)

        self.assertEqual(response.status_code, status.HTTP_201_CREATED, response.data)
        movement = RegisterCashMovement.objects.get(register_session=session)
        self.assertEqual(movement.movement_type, RegisterCashMovement.MovementType.PAY_OUT)
        self.assertEqual(movement.amount, Decimal("600.00"))
        self.assertEqual(movement.employee_loan.pk, response.data["id"])
        self.assertTrue(response.data["paid_from_register"])

    def test_granting_by_transfer_names_the_bank(self):
        response = self._grant(disbursement_method="transfer", money_account=self.bank.pk)

        self.assertEqual(response.status_code, status.HTTP_201_CREATED, response.data)
        self.assertEqual(response.data["disbursement_method"], "transfer")
        self.assertEqual(response.data["money_account_name"], "المصرف")

    def test_a_refused_hand_over_leaves_no_loan_behind(self):
        # No drawer is open, so the cash has nowhere to come out of.
        response = self._grant(pay_from_register=True)

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertEqual(response.data["code"], "register_session_required")
        self.assertFalse(EmployeeLoan.objects.exists())

    def test_an_account_that_is_not_a_bank_leaves_no_loan_behind(self):
        response = self._grant(disbursement_method="transfer", money_account=self.cash_box.pk)

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertIn("money_account", response.data)
        self.assertFalse(EmployeeLoan.objects.exists())

    def test_granting_takes_the_right_to_approve_as_well(self):
        clerk = self._user(
            "clerk",
            permissions=(
                "employees.view_employee",
                "employees.view_employeeloan",
                "employees.add_employeeloan",
            ),
        )
        client = self._client(clerk)

        granted = self._grant(client)
        recorded = self._record(client)

        self.assertEqual(granted.status_code, status.HTTP_403_FORBIDDEN)
        self.assertEqual(recorded.status_code, status.HTTP_201_CREATED, recorded.data)
        self.assertEqual(
            list(EmployeeLoan.objects.values_list("status", flat=True)),
            [EmployeeLoan.Status.REQUESTED],
        )

    def test_the_accountant_records_and_grants_loans(self):
        accountant = self._client(self._user("acc", ACCOUNTANT_GROUP))

        recorded = self._record(accountant)
        granted = self._grant(accountant)

        self.assertEqual(recorded.status_code, status.HTTP_201_CREATED, recorded.data)
        self.assertEqual(granted.status_code, status.HTTP_201_CREATED, granted.data)
        self.assertEqual(granted.data["status"], "approved")

    def test_a_deduction_larger_than_the_loan_is_refused(self):
        response = self._grant(monthly_deduction="700.00")

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertIn("monthly_deduction", response.data)
        self.assertFalse(EmployeeLoan.objects.exists())

    def test_nobody_off_payroll_is_lent_to(self):
        for employee_status in (Employee.Status.INACTIVE, Employee.Status.TERMINATED):
            with self.subTest(employee_status):
                Employee.objects.filter(pk=self.employee.pk).update(status=employee_status)

                granted = self._grant()
                recorded = self._record()

                self.assertEqual(granted.status_code, status.HTTP_400_BAD_REQUEST)
                self.assertIn("employee", granted.data)
                self.assertEqual(recorded.status_code, status.HTTP_400_BAD_REQUEST)
                self.assertIn("employee", recorded.data)
        self.assertFalse(EmployeeLoan.objects.exists())

    def test_an_employee_on_leave_is_still_on_payroll(self):
        Employee.objects.filter(pk=self.employee.pk).update(status=Employee.Status.ON_LEAVE)

        response = self._grant()

        self.assertEqual(response.status_code, status.HTTP_201_CREATED, response.data)

    def test_the_next_payroll_takes_the_first_instalment(self):
        granted = self._grant()

        # A whole month, so the wage is all there to deduct from.
        run, _created = draft_monthly_payroll_run(
            period_start=date(2026, 6, 1), period_end=date(2026, 6, 30)
        )

        instalment = PayrollAdjustment.objects.get(
            payroll_line__payroll_run=run, loan_id=granted.data["id"]
        )
        self.assertEqual(instalment.amount, Decimal("200.00"))
