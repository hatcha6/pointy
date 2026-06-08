import warnings
from datetime import date, datetime, timedelta
from decimal import Decimal

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group
from django.conf import settings
from django.core.paginator import UnorderedObjectListWarning
from django.test import TestCase
from django.urls import reverse
from django.utils import timezone
from rest_framework import status
from rest_framework.test import APIClient

from apps.catalog.testing import create_product_with_default_variant
from apps.notifications.models import BusinessNotification
from apps.notifications.services import sync_business_notifications
from apps.core.roles import ACCOUNTANT_GROUP, CASHIER_GROUP, MANAGER_GROUP, ensure_role_groups
from apps.sales.models import Order, OrderLine, RegisterSession

from .models import (
    CompensationPlan,
    Employee,
    EmployeeLoan,
    EmployeeLoanPayment,
    PayrollAdjustment,
    PayrollRun,
)
from .services import approve_payroll_run, draft_monthly_payroll_run, mark_payroll_run_paid


class EmployeePayrollApiTests(TestCase):
    def setUp(self):
        ensure_role_groups()
        User = get_user_model()
        self.manager = User.objects.create_user(username="owner", password="pass")
        self.manager.groups.add(Group.objects.get(name=MANAGER_GROUP))
        self.accountant = User.objects.create_user(username="accountant", password="pass")
        self.accountant.groups.add(Group.objects.get(name=ACCOUNTANT_GROUP))
        self.cashier = User.objects.create_user(username="cashier", password="pass")
        self.cashier.groups.add(Group.objects.get(name=CASHIER_GROUP))

    def authenticated_client(self, user):
        client = APIClient()
        client.force_authenticate(user=user)
        return client

    def create_order_for_user(self, user, *, total, created_at, order_status=Order.Status.PAID):
        session = RegisterSession.objects.create(
            owner=user,
            owner_key=f"user:{user.pk}:test:{RegisterSession.objects.count() + 1}",
        )
        order = Order.objects.create(
            register_session=session,
            status=order_status,
            subtotal=Decimal(total),
            total=Decimal(total),
        )
        Order.objects.filter(pk=order.pk).update(created_at=created_at)
        order.refresh_from_db()
        return order

    def test_cashier_cannot_read_employee_records(self):
        response = self.authenticated_client(self.cashier).get(reverse("employee-list"))

        self.assertEqual(response.status_code, status.HTTP_403_FORBIDDEN)

    def test_accountant_can_create_employee_and_payroll_run(self):
        client = self.authenticated_client(self.accountant)
        employee_response = client.post(
            reverse("employee-list"),
            {
                "full_name": "سارة علي",
                "job_title": "محاسبة",
                "department": "الإدارة",
                "employment_type": Employee.EmploymentType.FULL_TIME,
                "hire_date": timezone.localdate().isoformat(),
            },
            format="json",
        )

        self.assertEqual(employee_response.status_code, status.HTTP_201_CREATED)
        employee_id = employee_response.data["id"]
        self.assertTrue(employee_response.data["employee_number"].startswith("E"))

        plan_response = client.post(
            reverse("compensation-plan-list"),
            {
                "employee": employee_id,
                "pay_type": CompensationPlan.PayType.MONTHLY_SALARY,
                "salary_type": CompensationPlan.SalaryType.MONTHLY_FIXED,
                "amount": "900.00",
                "effective_from": timezone.localdate().isoformat(),
            },
            format="json",
        )

        self.assertEqual(plan_response.status_code, status.HTTP_201_CREATED)
        self.assertEqual(
            plan_response.data["salary_type"],
            CompensationPlan.SalaryType.MONTHLY_FIXED,
        )

        payroll_response = client.post(
            reverse("payroll-run-list"),
            {
                "period_start": timezone.localdate().replace(day=1).isoformat(),
                "period_end": timezone.localdate().isoformat(),
                "lines": [
                    {
                        "employee": employee_id,
                        "compensation_plan": plan_response.data["id"],
                        "units": "1.00",
                        "adjustments": [
                            {
                                "direction": "addition",
                                "adjustment_type": "bonus",
                                "amount": "25.00",
                            },
                            {
                                "direction": "deduction",
                                "adjustment_type": "advance",
                                "amount": "10.00",
                            },
                        ],
                    }
                ],
            },
            format="json",
        )

        self.assertEqual(payroll_response.status_code, status.HTTP_201_CREATED)
        self.assertTrue(payroll_response.data["run_number"].startswith("PR"))
        self.assertEqual(payroll_response.data["gross_total"], "900.00")
        self.assertEqual(payroll_response.data["additions_total"], "25.00")
        self.assertEqual(payroll_response.data["deductions_total"], "10.00")
        self.assertEqual(payroll_response.data["net_total"], "915.00")

    def test_payroll_run_detail_returns_employee_lines(self):
        employee = Employee.objects.create(full_name="سارة أحمد")
        plan = CompensationPlan.objects.create(
            employee=employee,
            pay_type=CompensationPlan.PayType.MONTHLY_SALARY,
            salary_type=CompensationPlan.SalaryType.MONTHLY_FIXED_PLUS_SALES_COMMISSION,
            amount=Decimal("900.00"),
            commission_percent=Decimal("10.00"),
        )
        payroll = PayrollRun.objects.create(
            period_start=timezone.localdate().replace(day=1),
            period_end=timezone.localdate(),
            notes="Monthly draft",
        )
        line = payroll.lines.create(
            employee=employee,
            compensation_plan=plan,
            units=Decimal("1.00"),
        )
        line.adjustments.create(
            direction=PayrollAdjustment.Direction.ADDITION,
            adjustment_type=PayrollAdjustment.AdjustmentType.COMMISSION,
            amount=Decimal("20.00"),
            notes="10.00% commission on 200.00 sales",
        )
        payroll.recalculate(save_lines=True)
        payroll.save()

        response = self.authenticated_client(self.accountant).get(
            reverse("payroll-run-detail", args=[payroll.pk])
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(response.data["line_count"], 1)
        self.assertEqual(response.data["gross_total"], "900.00")
        self.assertEqual(response.data["additions_total"], "20.00")
        self.assertEqual(response.data["net_total"], "920.00")
        self.assertEqual(response.data["lines"][0]["employee_name"], "سارة أحمد")
        self.assertEqual(
            response.data["lines"][0]["salary_type"],
            CompensationPlan.SalaryType.MONTHLY_FIXED_PLUS_SALES_COMMISSION,
        )
        self.assertEqual(
            response.data["lines"][0]["adjustments"][0]["adjustment_type"],
            PayrollAdjustment.AdjustmentType.COMMISSION,
        )

    def test_payroll_run_detail_updates_line_absence_and_adjustment_totals(self):
        employee = Employee.objects.create(full_name="خالد محمود")
        plan = CompensationPlan.objects.create(
            employee=employee,
            pay_type=CompensationPlan.PayType.MONTHLY_SALARY,
            salary_type=CompensationPlan.SalaryType.MONTHLY_FIXED,
            amount=Decimal("900.00"),
        )
        payroll = PayrollRun.objects.create(
            period_start=date(2026, 6, 1),
            period_end=date(2026, 6, 30),
        )
        line = payroll.lines.create(
            employee=employee,
            compensation_plan=plan,
            units=Decimal("1.00"),
        )
        payroll.recalculate(save_lines=True)
        payroll.save()

        response = self.authenticated_client(self.accountant).patch(
            reverse("payroll-run-update-line-adjustments", args=[payroll.pk, line.pk]),
            {
                "absence_days": "2.00",
                "raise_amount": "100.00",
                "manual_addition_amount": "25.00",
                "manual_deduction_amount": "10.00",
                "notes": "خصم غياب مع زيادة هذا الشهر",
            },
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(response.data["gross_total"], "900.00")
        self.assertEqual(response.data["additions_total"], "125.00")
        self.assertEqual(response.data["deductions_total"], "70.00")
        self.assertEqual(response.data["net_total"], "955.00")

        updated_line = response.data["lines"][0]
        self.assertEqual(updated_line["absence_days"], "2.00")
        self.assertEqual(updated_line["absence_day_rate"], "30.00")
        self.assertEqual(updated_line["absence_deduction_amount"], "60.00")
        self.assertEqual(updated_line["raise_amount"], "100.00")
        self.assertEqual(updated_line["manual_addition_amount"], "25.00")
        self.assertEqual(updated_line["manual_deduction_amount"], "10.00")
        self.assertEqual(updated_line["additions_amount"], "125.00")
        self.assertEqual(updated_line["deductions_amount"], "70.00")
        self.assertEqual(updated_line["net_amount"], "955.00")

    def test_payroll_line_adjustments_are_locked_after_draft_status(self):
        employee = Employee.objects.create(full_name="منى صالح")
        payroll = PayrollRun.objects.create(
            status=PayrollRun.Status.APPROVED,
            period_start=date(2026, 6, 1),
            period_end=date(2026, 6, 30),
        )
        line = payroll.lines.create(
            employee=employee,
            units=Decimal("1.00"),
            rate=Decimal("300.00"),
        )

        response = self.authenticated_client(self.accountant).patch(
            reverse("payroll-run-update-line-adjustments", args=[payroll.pk, line.pk]),
            {"manual_addition_amount": "10.00"},
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)

    def test_payroll_run_list_paginates_with_stable_ordering(self):
        older = PayrollRun.objects.create(
            period_start=timezone.localdate() - timedelta(days=60),
            period_end=timezone.localdate() - timedelta(days=30),
            net_total=Decimal("500.00"),
        )
        newer = PayrollRun.objects.create(
            period_start=timezone.localdate() - timedelta(days=29),
            period_end=timezone.localdate(),
            net_total=Decimal("700.00"),
        )

        with warnings.catch_warnings():
            warnings.simplefilter("error", UnorderedObjectListWarning)
            response = self.authenticated_client(self.accountant).get(
                reverse("payroll-run-list")
            )

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(response.data["results"][0]["id"], newer.pk)
        self.assertEqual(response.data["results"][1]["id"], older.pk)

    def test_employee_user_link_must_be_unique(self):
        Employee.objects.create(full_name="موظف مرتبط", user=self.cashier)

        response = self.authenticated_client(self.accountant).post(
            reverse("employee-list"),
            {
                "full_name": "موظف آخر",
                "hire_date": timezone.localdate().isoformat(),
                "user": self.cashier.pk,
            },
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertIn("user", response.data)

    def test_monthly_payroll_draft_uses_base_salary_and_sales_commission(self):
        employee = Employee.objects.create(
            full_name="كاشير عمولة",
            user=self.cashier,
        )
        plan = CompensationPlan.objects.create(
            employee=employee,
            pay_type=CompensationPlan.PayType.MONTHLY_SALARY,
            salary_type=CompensationPlan.SalaryType.MONTHLY_FIXED_PLUS_SALES_COMMISSION,
            amount=Decimal("900.00"),
            commission_percent=Decimal("10.00"),
        )
        session = RegisterSession.objects.create(
            owner=self.cashier,
            owner_key=f"user:{self.cashier.pk}",
        )
        Order.objects.create(
            register_session=session,
            status=Order.Status.PAID,
            subtotal=Decimal("200.00"),
            total=Decimal("200.00"),
        )
        today = timezone.localdate()
        period_start = today.replace(day=1)

        payroll, created = draft_monthly_payroll_run(
            period_start=period_start,
            period_end=today,
        )

        self.assertTrue(created)
        self.assertEqual(payroll.lines.count(), 1)
        line = payroll.lines.get()
        self.assertEqual(line.compensation_plan, plan)
        self.assertEqual(line.gross_amount, Decimal("900.00"))
        self.assertEqual(line.additions_amount, Decimal("20.00"))
        self.assertEqual(line.net_amount, Decimal("920.00"))
        self.assertEqual(payroll.net_total, Decimal("920.00"))

    def test_monthly_payroll_draft_commission_uses_only_cashier_paid_sales_in_period(self):
        employee = Employee.objects.create(
            full_name="كاشير مبيعات متعددة",
            user=self.cashier,
        )
        CompensationPlan.objects.create(
            employee=employee,
            pay_type=CompensationPlan.PayType.MONTHLY_SALARY,
            salary_type=CompensationPlan.SalaryType.MONTHLY_FIXED_PLUS_SALES_COMMISSION,
            amount=Decimal("900.00"),
            commission_percent=Decimal("10.00"),
        )
        in_period = timezone.make_aware(datetime(2026, 6, 10, 12, 0))
        outside_period = timezone.make_aware(datetime(2026, 5, 31, 12, 0))
        self.create_order_for_user(
            self.cashier,
            total="200.00",
            created_at=in_period,
        )
        self.create_order_for_user(
            self.cashier,
            total="150.00",
            created_at=in_period + timedelta(days=2),
        )
        self.create_order_for_user(
            self.cashier,
            total="80.00",
            created_at=in_period,
            order_status=Order.Status.OPEN,
        )
        self.create_order_for_user(
            self.cashier,
            total="90.00",
            created_at=in_period,
            order_status=Order.Status.VOID,
        )
        self.create_order_for_user(
            self.cashier,
            total="125.00",
            created_at=outside_period,
        )
        self.create_order_for_user(
            self.accountant,
            total="999.00",
            created_at=in_period,
        )

        payroll, created = draft_monthly_payroll_run(
            period_start=date(2026, 6, 1),
            period_end=date(2026, 6, 30),
        )

        self.assertTrue(created)
        line = payroll.lines.get()
        self.assertEqual(line.gross_amount, Decimal("900.00"))
        self.assertEqual(line.additions_amount, Decimal("35.00"))
        self.assertEqual(line.net_amount, Decimal("935.00"))
        commission = line.adjustments.get(
            adjustment_type=PayrollAdjustment.AdjustmentType.COMMISSION
        )
        self.assertEqual(commission.amount, Decimal("35.00"))
        self.assertIn("350.00 sales", commission.notes)

    def test_monthly_payroll_draft_uses_commission_only_salary(self):
        employee = Employee.objects.create(
            full_name="مندوب عمولة",
            user=self.cashier,
        )
        CompensationPlan.objects.create(
            employee=employee,
            pay_type=CompensationPlan.PayType.COMMISSION,
            salary_type=CompensationPlan.SalaryType.SALES_COMMISSION_ONLY,
            amount=Decimal("0.00"),
            commission_percent=Decimal("12.50"),
        )
        session = RegisterSession.objects.create(
            owner=self.cashier,
            owner_key=f"user:{self.cashier.pk}",
        )
        Order.objects.create(
            register_session=session,
            status=Order.Status.PAID,
            subtotal=Decimal("400.00"),
            total=Decimal("400.00"),
        )
        today = timezone.localdate()

        payroll, created = draft_monthly_payroll_run(
            period_start=today.replace(day=1),
            period_end=today,
        )

        self.assertTrue(created)
        line = payroll.lines.get()
        self.assertEqual(line.gross_amount, Decimal("0.00"))
        self.assertEqual(line.additions_amount, Decimal("50.00"))
        self.assertEqual(line.net_amount, Decimal("50.00"))
        self.assertEqual(payroll.net_total, Decimal("50.00"))

    def test_monthly_payroll_draft_uses_rate_based_salary_units(self):
        employee = Employee.objects.create(full_name="موظف بالساعة")
        CompensationPlan.objects.create(
            employee=employee,
            pay_type=CompensationPlan.PayType.HOURLY,
            salary_type=CompensationPlan.SalaryType.HOURLY_RATE,
            amount=Decimal("15.00"),
            expected_units_per_period=Decimal("120.00"),
        )
        today = timezone.localdate()

        payroll, created = draft_monthly_payroll_run(
            period_start=today.replace(day=1),
            period_end=today,
        )

        self.assertTrue(created)
        line = payroll.lines.get()
        self.assertEqual(line.units, Decimal("120.00"))
        self.assertEqual(line.rate, Decimal("15.00"))
        self.assertEqual(line.gross_amount, Decimal("1800.00"))
        self.assertEqual(line.net_amount, Decimal("1800.00"))

    def test_compensation_plan_salary_type_validation(self):
        employee = Employee.objects.create(full_name="تحقق الراتب")
        client = self.authenticated_client(self.accountant)
        invalid_cases = [
            {
                "salary_type": CompensationPlan.SalaryType.MONTHLY_FIXED,
                "amount": "800.00",
                "commission_percent": "5.00",
                "error_field": "commission_percent",
            },
            {
                "salary_type": CompensationPlan.SalaryType.SALES_COMMISSION_ONLY,
                "amount": "100.00",
                "commission_percent": "5.00",
                "error_field": "amount",
            },
            {
                "salary_type": CompensationPlan.SalaryType.MONTHLY_FIXED_PLUS_SALES_COMMISSION,
                "amount": "800.00",
                "commission_percent": "0.00",
                "error_field": "commission_percent",
            },
            {
                "salary_type": CompensationPlan.SalaryType.HOURLY_RATE,
                "amount": "15.00",
                "expected_units_per_period": "0.00",
                "error_field": "expected_units_per_period",
            },
        ]

        for payload in invalid_cases:
            error_field = payload.pop("error_field")
            response = client.post(
                reverse("compensation-plan-list"),
                {
                    "employee": employee.pk,
                    **payload,
                },
                format="json",
            )

            self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
            self.assertIn(error_field, response.data)

    def test_monthly_payroll_draft_skips_manual_and_expired_plans(self):
        daily_employee = Employee.objects.create(full_name="عامل يومي")
        expired_employee = Employee.objects.create(full_name="راتب منتهي")
        today = timezone.localdate()
        CompensationPlan.objects.create(
            employee=daily_employee,
            pay_type=CompensationPlan.PayType.DAILY_RATE,
            amount=Decimal("50.00"),
        )
        CompensationPlan.objects.create(
            employee=expired_employee,
            pay_type=CompensationPlan.PayType.MONTHLY_SALARY,
            salary_type=CompensationPlan.SalaryType.MONTHLY_FIXED,
            amount=Decimal("700.00"),
            effective_from=today - timedelta(days=40),
            effective_to=today - timedelta(days=1),
        )

        payroll, created = draft_monthly_payroll_run(
            period_start=today.replace(day=1),
            period_end=today,
        )

        self.assertFalse(created)
        self.assertIsNone(payroll)

    def test_monthly_payroll_draft_is_idempotent_for_period(self):
        Employee.objects.create(full_name="موظف ثابت")
        employee = Employee.objects.get(full_name="موظف ثابت")
        CompensationPlan.objects.create(
            employee=employee,
            pay_type=CompensationPlan.PayType.MONTHLY_SALARY,
            salary_type=CompensationPlan.SalaryType.MONTHLY_FIXED,
            amount=Decimal("500.00"),
        )
        today = timezone.localdate()
        period_start = today.replace(day=1)

        first, first_created = draft_monthly_payroll_run(
            period_start=period_start,
            period_end=today,
        )
        second, second_created = draft_monthly_payroll_run(
            period_start=period_start,
            period_end=today,
        )

        self.assertTrue(first_created)
        self.assertFalse(second_created)
        self.assertEqual(first.pk, second.pk)
        self.assertEqual(
            PayrollRun.objects.filter(
                period_start=period_start,
                period_end=today,
            ).count(),
            1,
        )

    def test_employee_can_request_loan_and_admin_can_approve_it(self):
        employee = Employee.objects.create(
            full_name="موظف قرض",
            user=self.cashier,
        )

        request_response = self.authenticated_client(self.cashier).post(
            reverse("employee-loan-request"),
            {
                "amount": "300.00",
                "monthly_deduction": "75.00",
                "purpose": "مصروفات عائلية",
            },
            format="json",
        )
        mine_response = self.authenticated_client(self.cashier).get(
            reverse("employee-loan-mine")
        )
        approve_response = self.authenticated_client(self.accountant).post(
            reverse("employee-loan-approve", args=[request_response.data["id"]]),
            {"review_notes": "مقبول للخصم الشهري"},
            format="json",
        )

        self.assertEqual(request_response.status_code, status.HTTP_201_CREATED)
        self.assertEqual(request_response.data["employee"], employee.pk)
        self.assertEqual(request_response.data["status"], EmployeeLoan.Status.REQUESTED)
        self.assertEqual(request_response.data["outstanding_balance"], "0.00")
        self.assertEqual(mine_response.status_code, status.HTTP_200_OK)
        self.assertEqual(mine_response.data["employee"]["id"], employee.pk)
        self.assertEqual(len(mine_response.data["loans"]), 1)
        self.assertEqual(approve_response.status_code, status.HTTP_200_OK)
        self.assertEqual(approve_response.data["status"], EmployeeLoan.Status.APPROVED)
        self.assertEqual(approve_response.data["outstanding_balance"], "300.00")

    def test_unlinked_user_cannot_request_employee_loan(self):
        response = self.authenticated_client(self.cashier).post(
            reverse("employee-loan-request"),
            {"amount": "300.00", "monthly_deduction": "75.00"},
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertIn("employee", response.data)

    def test_monthly_payroll_deducts_approved_loan_when_payroll_is_paid(self):
        employee = Employee.objects.create(
            full_name="موظف خصم قرض",
            user=self.cashier,
        )
        CompensationPlan.objects.create(
            employee=employee,
            pay_type=CompensationPlan.PayType.MONTHLY_SALARY,
            salary_type=CompensationPlan.SalaryType.MONTHLY_FIXED,
            amount=Decimal("500.00"),
        )
        loan = EmployeeLoan.objects.create(
            employee=employee,
            requested_by=self.cashier,
            reviewed_by=self.accountant,
            status=EmployeeLoan.Status.APPROVED,
            amount=Decimal("120.00"),
            monthly_deduction=Decimal("50.00"),
            outstanding_balance=Decimal("120.00"),
            reviewed_at=timezone.now(),
        )

        payroll, created = draft_monthly_payroll_run(
            period_start=date(2026, 6, 1),
            period_end=date(2026, 6, 30),
        )
        line = payroll.lines.get()
        loan.refresh_from_db()
        approved_payroll = approve_payroll_run(payroll)
        paid_payroll = mark_payroll_run_paid(approved_payroll)
        loan.refresh_from_db()

        self.assertTrue(created)
        self.assertEqual(line.gross_amount, Decimal("500.00"))
        self.assertEqual(line.deductions_amount, Decimal("50.00"))
        self.assertEqual(line.net_amount, Decimal("450.00"))
        self.assertEqual(payroll.net_total, Decimal("450.00"))
        self.assertEqual(loan.outstanding_balance, Decimal("70.00"))
        self.assertEqual(loan.status, EmployeeLoan.Status.APPROVED)
        payment = EmployeeLoanPayment.objects.get(loan=loan)
        self.assertEqual(payment.amount, Decimal("50.00"))
        self.assertEqual(payment.payroll_line_id, line.pk)
        self.assertEqual(paid_payroll.status, PayrollRun.Status.PAID)
        adjustment = line.adjustments.get(
            adjustment_type=PayrollAdjustment.AdjustmentType.LOAN
        )
        self.assertEqual(adjustment.loan_id, loan.pk)

    def test_monthly_payroll_loan_deduction_caps_to_remaining_balance(self):
        employee = Employee.objects.create(full_name="موظف آخر قرض")
        CompensationPlan.objects.create(
            employee=employee,
            pay_type=CompensationPlan.PayType.MONTHLY_SALARY,
            salary_type=CompensationPlan.SalaryType.MONTHLY_FIXED,
            amount=Decimal("500.00"),
        )
        loan = EmployeeLoan.objects.create(
            employee=employee,
            requested_by=self.cashier,
            reviewed_by=self.accountant,
            status=EmployeeLoan.Status.APPROVED,
            amount=Decimal("120.00"),
            monthly_deduction=Decimal("50.00"),
            outstanding_balance=Decimal("30.00"),
            reviewed_at=timezone.now(),
        )

        payroll, created = draft_monthly_payroll_run(
            period_start=date(2026, 6, 1),
            period_end=date(2026, 6, 30),
        )
        line = payroll.lines.get()
        mark_payroll_run_paid(approve_payroll_run(payroll))
        loan.refresh_from_db()

        self.assertTrue(created)
        self.assertEqual(line.deductions_amount, Decimal("30.00"))
        self.assertEqual(line.net_amount, Decimal("470.00"))
        self.assertEqual(loan.outstanding_balance, Decimal("0.00"))
        self.assertEqual(loan.status, EmployeeLoan.Status.PAID)
        self.assertEqual(EmployeeLoanPayment.objects.get(loan=loan).amount, Decimal("30.00"))

    def test_unpaid_loan_deductions_are_not_double_scheduled(self):
        employee = Employee.objects.create(full_name="موظف جدولة قرض")
        CompensationPlan.objects.create(
            employee=employee,
            pay_type=CompensationPlan.PayType.MONTHLY_SALARY,
            salary_type=CompensationPlan.SalaryType.MONTHLY_FIXED,
            amount=Decimal("500.00"),
        )
        loan = EmployeeLoan.objects.create(
            employee=employee,
            requested_by=self.cashier,
            reviewed_by=self.accountant,
            status=EmployeeLoan.Status.APPROVED,
            amount=Decimal("80.00"),
            monthly_deduction=Decimal("50.00"),
            outstanding_balance=Decimal("80.00"),
            reviewed_at=timezone.now(),
        )

        first, first_created = draft_monthly_payroll_run(
            period_start=date(2026, 6, 1),
            period_end=date(2026, 6, 30),
        )
        second, second_created = draft_monthly_payroll_run(
            period_start=date(2026, 7, 1),
            period_end=date(2026, 7, 31),
        )
        loan.refresh_from_db()

        self.assertTrue(first_created)
        self.assertTrue(second_created)
        self.assertEqual(first.lines.get().deductions_amount, Decimal("50.00"))
        self.assertEqual(second.lines.get().deductions_amount, Decimal("30.00"))
        self.assertEqual(loan.outstanding_balance, Decimal("80.00"))

    def test_draft_payroll_run_generates_admin_notification(self):
        employee = Employee.objects.create(full_name="تنبيه الرواتب")
        CompensationPlan.objects.create(
            employee=employee,
            pay_type=CompensationPlan.PayType.MONTHLY_SALARY,
            salary_type=CompensationPlan.SalaryType.MONTHLY_FIXED,
            amount=Decimal("700.00"),
        )
        today = timezone.localdate()
        period_start = today.replace(day=1)
        payroll, _ = draft_monthly_payroll_run(
            period_start=period_start,
            period_end=today,
        )

        sync_business_notifications()
        notification = BusinessNotification.objects.get(
            code="employees.payroll_ready"
        )

        self.assertEqual(notification.entity_id, str(payroll.pk))
        self.assertEqual(notification.payload["amount"], "700.00")
        self.assertEqual(notification.payload["count"], 1)

    def test_monthly_payroll_draft_is_scheduled_in_celery_beat(self):
        schedule = settings.CELERY_BEAT_SCHEDULE[
            "employees.draft-monthly-payroll"
        ]

        self.assertEqual(schedule["task"], "employees.draft_monthly_payroll")

    def test_payroll_run_transitions_are_guarded_and_audited_by_status(self):
        employee = Employee.objects.create(full_name="أحمد محمود")
        plan = CompensationPlan.objects.create(
            employee=employee,
            pay_type=CompensationPlan.PayType.DAILY_RATE,
            amount=Decimal("50.00"),
        )
        payroll = PayrollRun.objects.create(
            period_start=timezone.localdate() - timedelta(days=7),
            period_end=timezone.localdate(),
        )
        line = payroll.lines.create(
            employee=employee,
            compensation_plan=plan,
            units=Decimal("5.00"),
        )
        line.recalculate(save=True)
        payroll.recalculate()
        payroll.save()

        client = self.authenticated_client(self.manager)
        approve_response = client.post(reverse("payroll-run-approve", args=[payroll.pk]))
        paid_response = client.post(
            reverse("payroll-run-mark-paid", args=[payroll.pk]),
            {"payment_date": timezone.localdate().isoformat()},
            format="json",
        )
        void_response = client.post(reverse("payroll-run-void", args=[payroll.pk]))

        self.assertEqual(approve_response.status_code, status.HTTP_200_OK)
        self.assertEqual(approve_response.data["status"], PayrollRun.Status.APPROVED)
        self.assertEqual(approve_response.data["net_total"], "250.00")
        self.assertEqual(paid_response.status_code, status.HTTP_200_OK)
        self.assertEqual(paid_response.data["status"], PayrollRun.Status.PAID)
        self.assertEqual(void_response.status_code, status.HTTP_400_BAD_REQUEST)

    def test_dashboard_shows_payroll_to_manager_and_hides_from_cashier(self):
        employee = Employee.objects.create(full_name="منى سالم")
        payroll = PayrollRun.objects.create(
            status=PayrollRun.Status.PAID,
            period_start=timezone.localdate() - timedelta(days=2),
            period_end=timezone.localdate(),
            payment_date=timezone.localdate(),
            net_total=Decimal("120.00"),
        )
        payroll.lines.create(employee=employee, units=1, rate=Decimal("120.00"), net_amount=Decimal("120.00"))

        product = create_product_with_default_variant(
            sku="PAY-DASH",
            barcode="",
            name="Payroll dashboard product",
            unit_price=Decimal("20.00"),
        )
        session = RegisterSession.objects.create(
            owner=self.cashier,
            owner_key=f"user:{self.cashier.pk}",
        )
        order = Order.objects.create(
            register_session=session,
            status=Order.Status.PAID,
            subtotal=Decimal("200.00"),
            total=Decimal("200.00"),
        )
        OrderLine.objects.create(
            order=order,
            variant=product.default_variant,
            quantity=10,
            unit_price=Decimal("20.00"),
            unit_cost=Decimal("8.00"),
        )

        manager_response = self.authenticated_client(self.manager).get(
            reverse("dashboard"),
            {"days": 7},
        )
        cashier_response = self.authenticated_client(self.cashier).get(
            reverse("dashboard"),
            {"days": 7},
        )

        self.assertEqual(manager_response.status_code, status.HTTP_200_OK)
        manager_sections = manager_response.data["sections"]
        self.assertEqual(
            manager_sections["payroll"]["summary"]["paid_total"],
            "120.00",
        )
        self.assertEqual(
            manager_sections["profitability"]["summary"]["payroll_paid_total"],
            "120.00",
        )
        self.assertEqual(
            manager_sections["profitability"]["summary"]["net_operating_profit"],
            "0.00",
        )
        self.assertEqual(cashier_response.status_code, status.HTTP_200_OK)
        self.assertNotIn("payroll", cashier_response.data["sections"])
