import warnings
from datetime import timedelta
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

from .models import CompensationPlan, Employee, PayrollAdjustment, PayrollRun
from .services import draft_monthly_payroll_run


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
