"""Someone who joins mid-month is paid from the day they started.

That is how shops here pay a new hire, and payroll used to pay them the whole
month. A run now leaves out the days of the period before the hire date (or
after a termination date) at the period's daily rate, as its own deduction on
the line so the owner sees it and can correct it. A salary plan can also be
dated from the day the employee started, so a plan written down a week later
still covers the month they joined.
"""

from datetime import date, timedelta
from decimal import Decimal

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group
from django.test import TestCase
from django.urls import reverse
from django.utils import timezone
from rest_framework import status
from rest_framework.test import APIClient

from apps.core.roles import MANAGER_GROUP, ensure_role_groups

from .models import CompensationPlan, Employee, EmployeeLoan
from .services import draft_monthly_payroll_run

OCTOBER = (date(2026, 10, 1), date(2026, 10, 31))
# For what goes through the API, which refuses a plan dated ahead of today.
SEPTEMBER = (date(2026, 9, 1), date(2026, 9, 30))


def _monthly_plan(employee, amount="1550.00", **fields):
    return CompensationPlan.objects.create(
        employee=employee,
        pay_type=CompensationPlan.PayType.MONTHLY_SALARY,
        salary_type=CompensationPlan.SalaryType.MONTHLY_FIXED,
        amount=Decimal(amount),
        effective_from=fields.pop("effective_from", date(2026, 1, 1)),
        **fields,
    )


class DaysNotEmployedTests(TestCase):
    def days(self, *, hired, left=None, period=OCTOBER):
        employee = Employee(full_name="x", hire_date=hired, termination_date=left)
        return employee.days_not_employed(*period)

    def test_someone_hired_before_the_period_worked_all_of_it(self):
        self.assertEqual(self.days(hired=date(2025, 3, 1)), 0)
        self.assertEqual(self.days(hired=date(2026, 10, 1)), 0)

    def test_a_mid_month_hire_misses_the_days_before_they_started(self):
        # Started on the 15th: the 1st to the 14th are not theirs.
        self.assertEqual(self.days(hired=date(2026, 10, 15)), 14)
        self.assertEqual(self.days(hired=date(2026, 10, 31)), 30)

    def test_a_hire_after_the_period_misses_all_of_it(self):
        self.assertEqual(self.days(hired=date(2026, 11, 3)), 31)

    def test_a_leaver_misses_the_days_after_they_left(self):
        self.assertEqual(
            self.days(hired=date(2025, 1, 1), left=date(2026, 10, 20)), 11
        )
        # Joined and left inside the same month.
        self.assertEqual(
            self.days(hired=date(2026, 10, 10), left=date(2026, 10, 20)), 20
        )


class MonthlyDraftProrationTests(TestCase):
    def test_a_mid_month_hire_is_paid_from_their_start_day(self):
        employee = Employee.objects.create(
            full_name="موظف جديد", hire_date=date(2026, 10, 15)
        )
        _monthly_plan(employee, effective_from=date(2026, 10, 15))

        run, created = draft_monthly_payroll_run(
            period_start=OCTOBER[0], period_end=OCTOBER[1]
        )
        line = run.lines.get()

        self.assertTrue(created)
        self.assertEqual(line.gross_amount, Decimal("1550.00"))
        self.assertEqual(line.days_not_employed, Decimal("14.00"))
        # 1550 / 31 x 14, from the unrounded daily rate.
        self.assertEqual(line.not_employed_deduction_amount, Decimal("700.00"))
        self.assertEqual(line.net_amount, Decimal("850.00"))
        self.assertEqual(run.net_total, Decimal("850.00"))

    def test_staff_hired_before_the_month_are_paid_in_full(self):
        employee = Employee.objects.create(
            full_name="قديم", hire_date=date(2024, 5, 1)
        )
        _monthly_plan(employee)

        run, _created = draft_monthly_payroll_run(
            period_start=OCTOBER[0], period_end=OCTOBER[1]
        )
        line = run.lines.get()

        self.assertEqual(line.days_not_employed, Decimal("0.00"))
        self.assertEqual(line.net_amount, Decimal("1550.00"))

    def test_a_daily_rate_hire_is_prorated_the_same_way(self):
        employee = Employee.objects.create(
            full_name="يومي", hire_date=date(2026, 10, 15)
        )
        CompensationPlan.objects.create(
            employee=employee,
            pay_type=CompensationPlan.PayType.DAILY_RATE,
            salary_type=CompensationPlan.SalaryType.DAILY_RATE,
            amount=Decimal("50.00"),
            expected_units_per_period=Decimal("31.00"),
            effective_from=date(2026, 10, 15),
        )

        run, _created = draft_monthly_payroll_run(
            period_start=OCTOBER[0], period_end=OCTOBER[1]
        )
        line = run.lines.get()

        # 31 expected days at 50 = 1550, less the 14 before they started.
        self.assertEqual(line.gross_amount, Decimal("1550.00"))
        self.assertEqual(line.net_amount, Decimal("850.00"))

    def test_a_loan_instalment_fits_in_the_prorated_pay(self):
        employee = Employee.objects.create(
            full_name="سلفة مبكرة", hire_date=date(2026, 10, 25)
        )
        _monthly_plan(employee, effective_from=date(2026, 10, 25))
        EmployeeLoan.objects.create(
            employee=employee,
            status=EmployeeLoan.Status.APPROVED,
            amount=Decimal("1000.00"),
            monthly_deduction=Decimal("500.00"),
            outstanding_balance=Decimal("1000.00"),
            reviewed_at=timezone.now(),
        )

        # Seven days of 1550 is 350: the instalment takes that, not 500,
        # instead of the line going negative and the whole draft failing.
        run, _created = draft_monthly_payroll_run(
            period_start=OCTOBER[0], period_end=OCTOBER[1]
        )
        line = run.lines.get()

        self.assertEqual(line.net_amount, Decimal("0.00"))
        self.assertEqual(line.deductions_amount, Decimal("1550.00"))


class PayrollProrationApiTests(TestCase):
    def setUp(self):
        ensure_role_groups()
        manager = get_user_model().objects.create_user(username="owner", password="p")
        manager.groups.add(Group.objects.get(name=MANAGER_GROUP))
        self.client = APIClient()
        self.client.force_authenticate(user=manager)
        self.employee = Employee.objects.create(
            full_name="موظف جديد", hire_date=date(2026, 9, 15)
        )

    def test_a_plan_can_be_dated_from_the_day_the_employee_started(self):
        response = self.client.post(
            reverse("compensation-plan-list"),
            {
                "employee": self.employee.pk,
                "salary_type": "monthly_fixed",
                "amount": "1500.00",
                "effective_from": "2026-09-15",
            },
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_201_CREATED, response.data)
        self.assertEqual(response.data["effective_from"], "2026-09-15")

    def test_a_plan_without_a_start_date_starts_today(self):
        response = self.client.post(
            reverse("compensation-plan-list"),
            {
                "employee": self.employee.pk,
                "salary_type": "monthly_fixed",
                "amount": "1500.00",
            },
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_201_CREATED, response.data)
        self.assertEqual(
            response.data["effective_from"], timezone.localdate().isoformat()
        )

    def test_a_plan_cannot_start_in_the_future(self):
        # It would retire the current plan at once and leave the months until
        # then with none.
        response = self.client.post(
            reverse("compensation-plan-list"),
            {
                "employee": self.employee.pk,
                "salary_type": "monthly_fixed",
                "amount": "1500.00",
                "effective_from": (
                    timezone.localdate() + timedelta(days=3)
                ).isoformat(),
            },
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertIn("effective_from", response.data)

    def test_a_run_made_by_hand_prorates_unless_told_otherwise(self):
        plan = _monthly_plan(self.employee, amount="1500.00")
        other = Employee.objects.create(full_name="آخر", hire_date=date(2026, 9, 15))
        other_plan = _monthly_plan(other, amount="1500.00")

        response = self.client.post(
            reverse("payroll-run-list"),
            {
                "period_start": "2026-09-01",
                "period_end": "2026-09-30",
                "lines": [
                    {"employee": self.employee.pk, "compensation_plan": plan.pk},
                    # The owner knows better: they worked the whole month.
                    {
                        "employee": other.pk,
                        "compensation_plan": other_plan.pk,
                        "days_not_employed": "0.00",
                    },
                ],
            },
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_201_CREATED, response.data)
        lines = {line["employee"]: line for line in response.data["lines"]}
        self.assertEqual(lines[self.employee.pk]["days_not_employed"], "14.00")
        self.assertEqual(lines[self.employee.pk]["net_amount"], "800.00")
        self.assertEqual(lines[other.pk]["days_not_employed"], "0.00")
        self.assertEqual(lines[other.pk]["net_amount"], "1500.00")

    def test_the_owner_can_correct_the_days_on_a_draft(self):
        _monthly_plan(
            self.employee, amount="1500.00", effective_from=date(2026, 9, 15)
        )
        run, _created = draft_monthly_payroll_run(
            period_start=SEPTEMBER[0], period_end=SEPTEMBER[1]
        )
        line = run.lines.get()

        response = self.client.patch(
            reverse("payroll-run-update-line-adjustments", args=[run.pk, line.pk]),
            {"days_not_employed": "10.00"},
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK, response.data)
        line.refresh_from_db()
        self.assertEqual(line.days_not_employed, Decimal("10.00"))
        self.assertEqual(line.not_employed_deduction_amount, Decimal("500.00"))
        self.assertEqual(line.net_amount, Decimal("1000.00"))

    def test_days_not_employed_and_absences_cannot_outrun_the_period(self):
        _monthly_plan(
            self.employee, amount="1500.00", effective_from=date(2026, 9, 15)
        )
        run, _created = draft_monthly_payroll_run(
            period_start=SEPTEMBER[0], period_end=SEPTEMBER[1]
        )
        line = run.lines.get()

        response = self.client.patch(
            reverse("payroll-run-update-line-adjustments", args=[run.pk, line.pk]),
            {"absence_days": "20.00"},
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
