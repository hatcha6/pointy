"""Query-count scaling guard for ``employee-list``.

The page serializes two property-backed fields per employee
(``active_compensation_plan`` and ``payroll_total``). Both used to run their own
query per row, so the page cost grew with the roster. These tests measure at N
and at 2N: a flat count proves the per-row work is gone, a doubling proves it is
back.
"""

from datetime import timedelta
from decimal import Decimal

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group
from django.test import TestCase
from django.test.utils import CaptureQueriesContext
from django.db import connection
from django.urls import reverse
from django.utils import timezone
from rest_framework.test import APIClient

from apps.core.roles import ACCOUNTANT_GROUP, ensure_role_groups

from .models import CompensationPlan, Employee, PayrollLine, PayrollRun


class EmployeeListQueryScalingTests(TestCase):
    def setUp(self):
        ensure_role_groups()
        User = get_user_model()
        self.accountant = User.objects.create_user(username="accountant", password="pass")
        self.accountant.groups.add(Group.objects.get(name=ACCOUNTANT_GROUP))
        self.client = APIClient()
        self.client.force_authenticate(user=self.accountant)
        self.today = timezone.localdate()

    def _seed(self, count, *, prefix):
        """Create ``count`` employees, each with two plans and two payroll lines.

        The second plan is superseded (``effective_to`` in the past) and one of
        the runs is VOID, so both the "which plan is active" and the "which
        lines count" rules are actually exercised rather than trivially true.
        """
        paid_run = PayrollRun.objects.create(
            period_start=self.today - timedelta(days=30),
            period_end=self.today,
            status=PayrollRun.Status.PAID,
        )
        void_run = PayrollRun.objects.create(
            period_start=self.today - timedelta(days=60),
            period_end=self.today - timedelta(days=31),
            status=PayrollRun.Status.VOID,
        )
        for index in range(count):
            employee = Employee.objects.create(
                employee_number=f"{prefix}{index:03d}",
                full_name=f"{prefix} employee {index:03d}",
                hire_date=self.today - timedelta(days=365),
            )
            CompensationPlan.objects.create(
                employee=employee,
                pay_type=CompensationPlan.PayType.MONTHLY_SALARY,
                amount=Decimal("100.00"),
                effective_from=self.today - timedelta(days=200),
                effective_to=self.today - timedelta(days=100),
                is_active=True,
            )
            CompensationPlan.objects.create(
                employee=employee,
                pay_type=CompensationPlan.PayType.MONTHLY_SALARY,
                amount=Decimal("250.00"),
                effective_from=self.today - timedelta(days=99),
                is_active=True,
            )
            PayrollLine.objects.create(
                payroll_run=paid_run,
                employee=employee,
                net_amount=Decimal("250.00"),
            )
            PayrollLine.objects.create(
                payroll_run=void_run,
                employee=employee,
                net_amount=Decimal("999.00"),
            )

    def _list_queries(self, expected_rows):
        url = reverse("employee-list")
        # Warm permissions/content types first, or the first request's setup
        # cost shows up as if it were per-row work.
        self.client.get(url)
        with CaptureQueriesContext(connection) as ctx:
            response = self.client.get(url)
        self.assertEqual(response.status_code, 200)
        self.assertEqual(len(response.data["results"]), expected_rows)
        return len(ctx), response.data["results"]

    def test_page_cost_does_not_grow_with_the_roster(self):
        self._seed(5, prefix="A")
        small, _ = self._list_queries(5)

        self._seed(5, prefix="B")
        large, _ = self._list_queries(10)

        self.assertEqual(
            large,
            small,
            f"employee-list cost grew with the roster: {small} queries at 5 rows, "
            f"{large} at 10 — a property-backed field is querying per row again.",
        )

    def test_page_values_match_the_uncached_properties(self):
        self._seed(3, prefix="A")
        _, results = self._list_queries(3)

        for row in results:
            employee = Employee.objects.get(pk=row["id"])
            expected_plan = employee.active_compensation_plan
            self.assertIsNotNone(expected_plan)
            self.assertEqual(row["active_compensation_plan"]["id"], expected_plan.pk)
            self.assertEqual(Decimal(row["payroll_total"]), employee.payroll_total)
            # The superseded plan and the VOID run must both be excluded.
            self.assertEqual(row["active_compensation_plan"]["amount"], "250.00")
            self.assertEqual(Decimal(row["payroll_total"]), Decimal("250.00"))
