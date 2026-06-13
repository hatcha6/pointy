from datetime import date, datetime, time, timedelta
from decimal import Decimal
from unittest import mock

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group
from django.test import TestCase
from django.utils import timezone
from rest_framework import status
from rest_framework.test import APIClient

from apps.core.roles import (
    ACCOUNTANT_GROUP,
    CASHIER_GROUP,
    MANAGER_GROUP,
    ensure_role_groups,
)
from apps.employees.models import (
    CompensationPlan,
    Employee,
    PayrollLine,
    PayrollRun,
)

from .models import (
    AttendanceDay,
    AttendanceProfile,
    AttendancePunch,
    BioTimeConnection,
)
from .services import (
    apply_attendance_to_run,
    attendance_summary,
    rebuild_attendance_day,
    sync_biotime,
)


class FakeBioTimeClient:
    def __init__(self, employees=None, transactions=None):
        self.employees = employees or []
        self.transactions = transactions or []

    def iter_employees(self):
        yield from self.employees

    def iter_transactions(self, *, start_time=None, end_time=None):
        yield from self.transactions

    def count_employees(self):
        return len(self.employees)


def aware(day, hour, minute=0):
    return timezone.make_aware(datetime.combine(day, time(hour, minute)))


class AttendanceTestBase(TestCase):
    def setUp(self):
        ensure_role_groups()
        User = get_user_model()
        self.manager = User.objects.create_user(username="owner", password="pass")
        self.manager.groups.add(Group.objects.get(name=MANAGER_GROUP))
        self.accountant = User.objects.create_user(username="acct", password="pass")
        self.accountant.groups.add(Group.objects.get(name=ACCOUNTANT_GROUP))
        self.cashier = User.objects.create_user(username="cash", password="pass")
        self.cashier.groups.add(Group.objects.get(name=CASHIER_GROUP))

        self.connection = BioTimeConnection.load()
        self.connection.base_url = "http://biotime.local"
        self.connection.username = "api"
        self.connection.password = "secret"
        self.connection.is_enabled = True
        # Monday-Friday, 09:00-17:00, 15 minutes grace.
        self.connection.workdays = "0,1,2,3,4"
        self.connection.shift_start = time(9, 0)
        self.connection.shift_end = time(17, 0)
        self.connection.grace_minutes = 15
        self.connection.save()

        self.employee = Employee.objects.create(
            employee_number="1001",
            full_name="موظف الاختبار",
            hire_date=date(2024, 1, 1),
        )
        self.profile = AttendanceProfile.objects.create(
            employee=self.employee,
            biotime_emp_code="1001",
        )
        # A Monday well in the past so summaries never clip against "today".
        self.monday = date(2026, 6, 1)

    def client_for(self, user):
        client = APIClient()
        client.force_authenticate(user=user)
        return client

    def add_punch(self, when, *, biotime_id=None, employee=None, emp_code=None):
        return AttendancePunch.objects.create(
            biotime_id=biotime_id,
            employee=employee or self.employee,
            emp_code=emp_code or "1001",
            punch_time=when,
        )


class AttendanceDayRollupTests(AttendanceTestBase):
    def test_on_time_full_day_is_present(self):
        self.add_punch(aware(self.monday, 9, 5))
        self.add_punch(aware(self.monday, 17, 0))
        day = rebuild_attendance_day(self.employee, self.monday)
        self.assertEqual(day.status, AttendanceDay.Status.PRESENT)
        self.assertEqual(day.late_minutes, 0)
        self.assertEqual(day.worked_minutes, 475)
        self.assertEqual(day.overtime_minutes, 0)

    def test_arriving_past_grace_counts_late_from_shift_start(self):
        self.add_punch(aware(self.monday, 9, 30))
        self.add_punch(aware(self.monday, 17, 0))
        day = rebuild_attendance_day(self.employee, self.monday)
        self.assertEqual(day.status, AttendanceDay.Status.LATE)
        self.assertEqual(day.late_minutes, 30)

    def test_overtime_and_early_leave_are_measured(self):
        self.add_punch(aware(self.monday, 9, 0))
        self.add_punch(aware(self.monday, 19, 0))
        day = rebuild_attendance_day(self.employee, self.monday)
        self.assertEqual(day.overtime_minutes, 120)
        self.assertEqual(day.early_leave_minutes, 0)

        AttendancePunch.objects.all().delete()
        self.add_punch(aware(self.monday, 9, 0))
        self.add_punch(aware(self.monday, 15, 0))
        day = rebuild_attendance_day(self.employee, self.monday)
        self.assertEqual(day.early_leave_minutes, 120)
        self.assertEqual(day.overtime_minutes, 0)

    def test_single_punch_is_partial(self):
        self.add_punch(aware(self.monday, 9, 0))
        day = rebuild_attendance_day(self.employee, self.monday)
        self.assertEqual(day.status, AttendanceDay.Status.PARTIAL)
        self.assertEqual(day.worked_minutes, 0)

    def test_work_on_day_off_is_all_overtime(self):
        saturday = self.monday + timedelta(days=5)
        self.add_punch(aware(saturday, 10, 0))
        self.add_punch(aware(saturday, 14, 0))
        day = rebuild_attendance_day(self.employee, saturday)
        self.assertEqual(day.status, AttendanceDay.Status.DAY_OFF)
        self.assertEqual(day.overtime_minutes, 240)
        self.assertEqual(day.late_minutes, 0)

    def test_no_punches_removes_the_day_row(self):
        self.add_punch(aware(self.monday, 9, 0))
        rebuild_attendance_day(self.employee, self.monday)
        AttendancePunch.objects.all().delete()
        self.assertIsNone(rebuild_attendance_day(self.employee, self.monday))
        self.assertFalse(AttendanceDay.objects.exists())

    def test_profile_schedule_override_wins(self):
        self.profile.shift_start = time(7, 0)
        self.profile.grace_minutes = 0
        self.profile.save()
        self.add_punch(aware(self.monday, 7, 30))
        self.add_punch(aware(self.monday, 17, 0))
        day = rebuild_attendance_day(self.employee, self.monday)
        self.assertEqual(day.late_minutes, 30)


class BioTimeSyncTests(AttendanceTestBase):
    def fake_client(self, employees=None, transactions=None):
        return FakeBioTimeClient(employees=employees, transactions=transactions)

    def test_sync_matches_employees_and_imports_punches(self):
        other = Employee.objects.create(
            employee_number="1002",
            full_name="موظف بدون ربط",
            hire_date=date(2024, 1, 1),
        )
        client = self.fake_client(
            employees=[
                {"emp_code": "1001", "first_name": "Test", "last_name": "One"},
                {"emp_code": "1002", "first_name": "Test", "last_name": "Two"},
                {"emp_code": "9999", "first_name": "Stranger", "last_name": ""},
            ],
            transactions=[
                {
                    "id": 11,
                    "emp_code": "1001",
                    "punch_time": f"{self.monday} 09:00:00",
                    "punch_state": "0",
                    "terminal_alias": "Door",
                },
                {
                    "id": 12,
                    "emp_code": "1001",
                    "punch_time": f"{self.monday} 17:30:00",
                    "punch_state": "1",
                    "terminal_alias": "Door",
                },
            ],
        )
        with mock.patch("apps.attendance.services.build_client", return_value=client):
            summary = sync_biotime(connection=self.connection)

        self.assertEqual(summary["matched_employees"], 2)
        self.assertEqual(summary["unmatched_biotime"], [{"emp_code": "9999", "name": "Stranger"}])
        self.assertEqual(summary["punches_imported"], 2)
        self.assertTrue(
            AttendanceProfile.objects.filter(
                employee=other, biotime_emp_code="1002"
            ).exists()
        )
        day = AttendanceDay.objects.get(employee=self.employee, date=self.monday)
        self.assertEqual(day.overtime_minutes, 30)
        self.connection.refresh_from_db()
        self.assertEqual(
            self.connection.last_sync_status, BioTimeConnection.SyncStatus.OK
        )
        self.assertIsNotNone(self.connection.last_punch_cursor)

    def test_sync_is_idempotent_across_runs(self):
        transactions = [
            {
                "id": 21,
                "emp_code": "1001",
                "punch_time": f"{self.monday} 09:00:00",
            },
            {
                "id": 22,
                "emp_code": "1001",
                "punch_time": f"{self.monday} 17:00:00",
            },
        ]
        client = self.fake_client(
            employees=[{"emp_code": "1001", "first_name": "Test"}],
            transactions=transactions,
        )
        with mock.patch("apps.attendance.services.build_client", return_value=client):
            first = sync_biotime(connection=self.connection)
            second = sync_biotime(connection=self.connection)

        self.assertEqual(first["punches_imported"], 2)
        self.assertEqual(second["punches_imported"], 0)
        self.assertEqual(AttendancePunch.objects.count(), 2)
        self.assertEqual(AttendanceDay.objects.count(), 1)

    def test_sync_requires_enabled_connection(self):
        self.connection.is_enabled = False
        self.connection.save()
        from rest_framework.serializers import ValidationError

        with self.assertRaises(ValidationError):
            sync_biotime(connection=self.connection)

    def test_untracked_profiles_keep_punches_unassigned(self):
        self.profile.is_tracked = False
        self.profile.save()
        client = self.fake_client(
            transactions=[
                {
                    "id": 31,
                    "emp_code": "1001",
                    "punch_time": f"{self.monday} 09:00:00",
                }
            ]
        )
        with mock.patch("apps.attendance.services.build_client", return_value=client):
            sync_biotime(connection=self.connection)
        punch = AttendancePunch.objects.get(biotime_id=31)
        self.assertIsNone(punch.employee)
        self.assertFalse(AttendanceDay.objects.exists())


class AttendanceSummaryTests(AttendanceTestBase):
    def test_summary_counts_absences_only_on_expected_workdays(self):
        # Week of Mon 2026-06-01: punches Monday + Tuesday only.
        for offset, hours in ((0, (9, 17)), (1, (9, 18))):
            day = self.monday + timedelta(days=offset)
            self.add_punch(aware(day, hours[0], 0))
            self.add_punch(aware(day, hours[1], 0))
            rebuild_attendance_day(self.employee, day)

        summary = attendance_summary(
            self.employee, self.monday, self.monday + timedelta(days=6)
        )
        self.assertEqual(summary["expected_days"], 5)
        self.assertEqual(summary["present_days"], 2)
        self.assertEqual(summary["absent_days"], 3)
        self.assertEqual(summary["overtime_minutes"], 60)

    def test_summary_ignores_days_before_hire(self):
        self.employee.hire_date = self.monday + timedelta(days=2)
        self.employee.save()
        summary = attendance_summary(
            self.employee, self.monday, self.monday + timedelta(days=6)
        )
        self.assertEqual(summary["expected_days"], 3)


class ApplyAttendanceToPayrollTests(AttendanceTestBase):
    def setUp(self):
        super().setUp()
        CompensationPlan.objects.create(
            employee=self.employee,
            pay_type=CompensationPlan.PayType.MONTHLY_SALARY,
            amount=Decimal("3000.00"),
            effective_from=date(2024, 1, 1),
        )
        self.run = PayrollRun.objects.create(
            period_start=self.monday,
            period_end=self.monday + timedelta(days=6),
        )
        self.line = PayrollLine.objects.create(
            payroll_run=self.run,
            employee=self.employee,
            compensation_plan=self.employee.active_compensation_plan,
        )
        self.line.recalculate(save=True)

    def attend(self, *, days_present, overtime_day_hours=None):
        for offset in range(days_present):
            day = self.monday + timedelta(days=offset)
            self.add_punch(aware(day, 9, 0))
            end_hour = 17
            if overtime_day_hours and offset == 0:
                end_hour = 17 + overtime_day_hours
            self.add_punch(aware(day, end_hour, 0))
            rebuild_attendance_day(self.employee, day)

    def test_apply_sets_absences_and_overtime_hours(self):
        self.attend(days_present=4, overtime_day_hours=2)
        result = apply_attendance_to_run(self.run)

        self.line.refresh_from_db()
        self.assertEqual(self.line.absence_days, Decimal("1.00"))
        # One day ended 2h late → 2.00 overtime hours on the line itself.
        self.assertEqual(self.line.overtime_hours, Decimal("2.00"))
        # Default multiplier (1.50): day rate 3000/7=428.57, hourly 53.57,
        # 2h × 53.57 × 1.50 = 160.71.
        self.assertEqual(self.line.overtime_multiplier, Decimal("1.50"))
        self.assertEqual(self.line.overtime_amount, Decimal("160.71"))
        self.assertGreater(self.line.additions_amount, Decimal("0.00"))
        self.assertEqual(result["applied_lines"][0]["overtime_hours"], 2.0)
        # No OVERTIME adjustment row is created; overtime lives on the line.
        self.assertEqual(self.line.adjustments.count(), 0)

    def test_per_employee_multiplier_changes_overtime_pay(self):
        plan = self.employee.active_compensation_plan
        plan.overtime_multiplier = Decimal("2.00")
        plan.save()
        self.attend(days_present=5, overtime_day_hours=2)
        apply_attendance_to_run(self.run)

        self.line.refresh_from_db()
        # Same 2h, but at 2.0x: 2 × 53.57 × 2.00 = 214.28.
        self.assertEqual(self.line.overtime_multiplier, Decimal("2.00"))
        self.assertEqual(self.line.overtime_amount, Decimal("214.28"))

    def test_apply_is_idempotent_and_clears_stale_overtime(self):
        self.attend(days_present=5, overtime_day_hours=2)
        apply_attendance_to_run(self.run)
        apply_attendance_to_run(self.run)
        self.line.refresh_from_db()
        self.assertEqual(self.line.overtime_hours, Decimal("2.00"))
        self.assertEqual(self.line.adjustments.count(), 0)

        # Remove the overtime punches and re-apply: overtime clears to zero.
        AttendancePunch.objects.all().delete()
        for offset in range(5):
            day = self.monday + timedelta(days=offset)
            self.add_punch(aware(day, 9, 0))
            self.add_punch(aware(day, 17, 0))
            rebuild_attendance_day(self.employee, day)
        apply_attendance_to_run(self.run)
        self.line.refresh_from_db()
        self.assertEqual(self.line.overtime_hours, Decimal("0.00"))
        self.assertEqual(self.line.overtime_amount, Decimal("0.00"))

    def test_apply_requires_draft_run(self):
        from rest_framework.serializers import ValidationError

        self.run.status = PayrollRun.Status.APPROVED
        self.run.save()
        with self.assertRaises(ValidationError):
            apply_attendance_to_run(self.run)


class AttendanceApiTests(AttendanceTestBase):
    def test_connection_api_hides_password_and_updates(self):
        client = self.client_for(self.manager)
        response = client.get("/api/attendance/connection/")
        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertNotIn("password", response.json())
        self.assertTrue(response.json()["has_password"])

        response = client.patch(
            "/api/attendance/connection/",
            {"base_url": "http://10.0.0.5:8081", "grace_minutes": 10},
            format="json",
        )
        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.connection.refresh_from_db()
        self.assertEqual(self.connection.base_url, "http://10.0.0.5:8081")
        # Blank password keeps the stored secret.
        client.patch("/api/attendance/connection/", {"password": ""}, format="json")
        self.connection.refresh_from_db()
        self.assertEqual(self.connection.password, "secret")

    def test_connection_api_denies_cashier(self):
        client = self.client_for(self.cashier)
        self.assertEqual(
            client.get("/api/attendance/connection/").status_code,
            status.HTTP_403_FORBIDDEN,
        )
        self.assertEqual(
            client.post("/api/attendance/sync/").status_code,
            status.HTTP_403_FORBIDDEN,
        )

    def test_accountant_can_manage_mapping_and_view_days(self):
        client = self.client_for(self.accountant)
        response = client.post("/api/attendance/profiles/ensure/")
        self.assertEqual(response.status_code, status.HTTP_200_OK)

        response = client.get("/api/attendance/profiles/")
        self.assertEqual(response.status_code, status.HTTP_200_OK)
        profile_id = self.profile.pk
        response = client.patch(
            f"/api/attendance/profiles/{profile_id}/",
            {"biotime_emp_code": "2002"},
            format="json",
        )
        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.profile.refresh_from_db()
        self.assertEqual(self.profile.biotime_emp_code, "2002")

        self.add_punch(aware(self.monday, 9, 0))
        self.add_punch(aware(self.monday, 17, 0))
        rebuild_attendance_day(self.employee, self.monday)
        response = client.get(
            "/api/attendance/days/",
            {"employee": self.employee.pk, "date_from": str(self.monday)},
        )
        self.assertEqual(response.status_code, status.HTTP_200_OK)
        rows = response.json()["results"]
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]["status"], "present")

        response = client.get(
            "/api/attendance/days/summary/",
            {
                "employee": self.employee.pk,
                "date_from": str(self.monday),
                "date_to": str(self.monday + timedelta(days=6)),
            },
        )
        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(response.json()["present_days"], 1)

    def test_duplicate_biotime_code_is_rejected(self):
        other = Employee.objects.create(
            employee_number="1003",
            full_name="آخر",
            hire_date=date(2024, 1, 1),
        )
        other_profile = AttendanceProfile.objects.create(employee=other)
        client = self.client_for(self.manager)
        response = client.patch(
            f"/api/attendance/profiles/{other_profile.pk}/",
            {"biotime_emp_code": "1001"},
            format="json",
        )
        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)

    def test_sync_endpoint_reports_biotime_errors(self):
        from .biotime import BioTimeError

        client = self.client_for(self.manager)
        with mock.patch(
            "apps.attendance.services.build_client",
            return_value=mock.Mock(
                iter_employees=mock.Mock(side_effect=BioTimeError("boom")),
            ),
        ):
            response = client.post("/api/attendance/sync/")
        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.connection.refresh_from_db()
        self.assertEqual(
            self.connection.last_sync_status, BioTimeConnection.SyncStatus.ERROR
        )

    def test_apply_attendance_endpoint_updates_run(self):
        CompensationPlan.objects.create(
            employee=self.employee,
            pay_type=CompensationPlan.PayType.MONTHLY_SALARY,
            amount=Decimal("3000.00"),
            effective_from=date(2024, 1, 1),
        )
        run = PayrollRun.objects.create(
            period_start=self.monday,
            period_end=self.monday + timedelta(days=6),
        )
        line = PayrollLine.objects.create(
            payroll_run=run,
            employee=self.employee,
            compensation_plan=self.employee.active_compensation_plan,
        )
        line.recalculate(save=True)

        for offset in range(4):
            day = self.monday + timedelta(days=offset)
            self.add_punch(aware(day, 9, 0))
            self.add_punch(aware(day, 17, 0))
            rebuild_attendance_day(self.employee, day)

        client = self.client_for(self.accountant)
        response = client.post(f"/api/payroll-runs/{run.pk}/apply-attendance/")
        self.assertEqual(response.status_code, status.HTTP_200_OK)
        payload = response.json()
        self.assertEqual(payload["attendance"]["applied_lines"][0]["absent_days"], 1)
        line.refresh_from_db()
        self.assertEqual(line.absence_days, Decimal("1.00"))
