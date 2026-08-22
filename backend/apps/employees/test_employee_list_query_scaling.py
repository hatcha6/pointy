"""Query-count scaling for the employee list.

``Employee.active_compensation_plan`` re-``filter()``s the ``compensation_plans``
relation the viewset already prefetches, and ``Employee.payroll_total`` is a
per-row ``Sum`` aggregate. Both are serialized on every row of
``employee-list``, so the page cost grew with the staff count. These tests keep
it flat.
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
from rest_framework.test import APIClient

from apps.core.roles import MANAGER_GROUP, ensure_role_groups

from .models import CompensationPlan, Employee, PayrollLine, PayrollRun

PAYROLL_RUNS_PER_EMPLOYEE = 2


@override_settings(
    CACHES={"default": {"BACKEND": "django.core.cache.backends.locmem.LocMemCache"}}
)
class EmployeeListQueryScalingTests(TestCase):
    def setUp(self):
        ensure_role_groups()
        User = get_user_model()
        self.manager = User.objects.create_user(username="owner", password="pass")
        self.manager.groups.add(Group.objects.get(name=MANAGER_GROUP))
        self.created = 0

    def _add_employees(self, count):
        today = timezone.localdate()
        for _ in range(count):
            self.created += 1
            index = self.created
            employee = Employee.objects.create(
                employee_number=f"E{index:04d}",
                full_name=f"موظف {index}",
                job_title="بائع",
                hire_date=today - timedelta(days=365),
            )
            # Two plans, so "pick the active one" has something to choose from.
            CompensationPlan.objects.create(
                employee=employee,
                pay_type=CompensationPlan.PayType.MONTHLY_SALARY,
                amount=Decimal("800.00"),
                effective_from=today - timedelta(days=365),
                effective_to=today - timedelta(days=30),
                is_active=False,
            )
            plan = CompensationPlan.objects.create(
                employee=employee,
                pay_type=CompensationPlan.PayType.MONTHLY_SALARY,
                amount=Decimal("1000.00"),
                effective_from=today - timedelta(days=29),
                is_active=True,
            )
            for run_index in range(PAYROLL_RUNS_PER_EMPLOYEE):
                run = PayrollRun.objects.create(
                    period_start=today - timedelta(days=60 + run_index * 30),
                    period_end=today - timedelta(days=31 + run_index * 30),
                    status=PayrollRun.Status.PAID,
                )
                PayrollLine.objects.create(
                    payroll_run=run,
                    employee=employee,
                    compensation_plan=plan,
                    gross_amount=Decimal("1000.00"),
                    net_amount=Decimal("950.00"),
                )

    def _list_query_count(self):
        url = reverse("employee-list")
        client = APIClient()
        client.force_authenticate(user=self.manager)
        # Warm permissions / content types / settings singletons first, or the
        # first request's fixed overhead pollutes the count.
        client.get(url)
        with CaptureQueriesContext(connection) as ctx:
            response = client.get(url)
        self.assertEqual(response.status_code, 200)
        return len(ctx), response

    def test_measure(self):
        self._add_employees(5)
        five, response_five = self._list_query_count()
        self.assertEqual(len(response_five.data["results"]), 5)
        self._add_employees(5)
        ten, response_ten = self._list_query_count()
        self.assertEqual(len(response_ten.data["results"]), 10)
        print(f"\n>>> employee-list: 5 rows = {five} queries, 10 rows = {ten} queries")
        print(f">>> slope = {(ten - five) / 5:.2f} queries/row")
