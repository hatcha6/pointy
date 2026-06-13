"""BioTime sync and attendance rollups feeding payroll."""

from datetime import datetime, timedelta
from decimal import Decimal

from django.db import transaction
from django.utils import timezone
from rest_framework.serializers import ValidationError

from apps.analytics.models import AnalyticsEvent
from apps.analytics.services import record_domain_event
from apps.employees.models import Employee, PayrollRun

from .biotime import BioTimeClient, BioTimeError
from .models import (
    AttendanceDay,
    AttendanceProfile,
    AttendancePunch,
    BioTimeConnection,
    parse_workdays,
)

MONEY_PLACES = Decimal("0.01")
DAYS_PLACES = Decimal("0.01")
HOURS_PLACES = Decimal("0.01")
FIRST_SYNC_LOOKBACK_DAYS = 30
# Re-read a small window behind the cursor so late-arriving device uploads are
# still captured; upserts keep this idempotent.
RESYNC_OVERLAP_HOURS = 24


def record_attendance_event(
    *,
    name,
    user,
    entity_type,
    entity_id,
    attributes=None,
    metrics=None,
    severity=AnalyticsEvent.Severity.INFO,
):
    record_domain_event(
        name=name,
        event_type=AnalyticsEvent.EventType.AUDIT,
        severity=severity,
        user=user,
        entity_type=entity_type,
        entity_id=entity_id,
        attributes=attributes or {},
        metrics=metrics or {},
    )


def build_client(connection):
    if not connection.is_configured:
        raise ValidationError({"detail": "BioTime connection is not configured."})
    return BioTimeClient(connection.base_url, connection.username, connection.password)


def test_biotime_connection(connection):
    client = build_client(connection)
    try:
        return {"employee_count": client.count_employees()}
    except BioTimeError as exc:
        raise ValidationError({"detail": str(exc)}) from exc


def effective_schedule(employee, connection):
    """Resolve the schedule for an employee: profile overrides, else shop defaults."""
    profile = getattr(employee, "attendance_profile", None)
    workdays = connection.workday_set
    shift_start = connection.shift_start
    shift_end = connection.shift_end
    grace_minutes = connection.grace_minutes
    if profile is not None:
        if profile.workdays:
            override = parse_workdays(profile.workdays)
            if override:
                workdays = override
        if profile.shift_start is not None:
            shift_start = profile.shift_start
        if profile.shift_end is not None:
            shift_end = profile.shift_end
        if profile.grace_minutes is not None:
            grace_minutes = profile.grace_minutes
    return workdays, shift_start, shift_end, grace_minutes


def _aware(day_date, time_of_day):
    return timezone.make_aware(datetime.combine(day_date, time_of_day))


def _minutes_between(start, end):
    if start is None or end is None or end <= start:
        return 0
    return int((end - start).total_seconds() // 60)


def rebuild_attendance_day(employee, day_date, *, connection=None):
    """Recompute the AttendanceDay row for one employee-day from raw punches."""
    connection = connection or BioTimeConnection.load()
    day_start = _aware(day_date, datetime.min.time())
    day_end = day_start + timedelta(days=1)
    punches = list(
        AttendancePunch.objects.filter(
            employee=employee,
            punch_time__gte=day_start,
            punch_time__lt=day_end,
        ).order_by("punch_time")
    )
    if not punches:
        AttendanceDay.objects.filter(employee=employee, date=day_date).delete()
        return None

    workdays, shift_start, shift_end, grace_minutes = effective_schedule(
        employee, connection
    )
    first_in = punches[0].punch_time
    last_out = punches[-1].punch_time if len(punches) > 1 else None
    worked_minutes = _minutes_between(first_in, last_out)

    if day_date.weekday() not in workdays:
        status = AttendanceDay.Status.DAY_OFF
        late_minutes = 0
        early_leave_minutes = 0
        # Everything worked on a day off counts as overtime.
        overtime_minutes = worked_minutes
    else:
        expected_start = _aware(day_date, shift_start)
        expected_end = _aware(day_date, shift_end)
        grace_deadline = expected_start + timedelta(minutes=grace_minutes)
        # Arriving past the grace window counts lateness from the shift start.
        late_minutes = (
            _minutes_between(expected_start, first_in) if first_in > grace_deadline else 0
        )
        early_leave_minutes = (
            _minutes_between(last_out, expected_end) if last_out is not None else 0
        )
        overtime_minutes = (
            _minutes_between(expected_end, last_out) if last_out is not None else 0
        )
        if last_out is None:
            status = AttendanceDay.Status.PARTIAL
        elif late_minutes > 0:
            status = AttendanceDay.Status.LATE
        else:
            status = AttendanceDay.Status.PRESENT

    day, _created = AttendanceDay.objects.update_or_create(
        employee=employee,
        date=day_date,
        defaults={
            "status": status,
            "first_in": first_in,
            "last_out": last_out,
            "punch_count": len(punches),
            "worked_minutes": worked_minutes,
            "late_minutes": late_minutes,
            "early_leave_minutes": early_leave_minutes,
            "overtime_minutes": overtime_minutes,
        },
    )
    return day


def sync_biotime(*, request=None, connection=None):
    """Pull employees and punches from BioTime; returns a summary dict.

    Idempotent: punches upsert on the BioTime transaction id, and day rollups
    are recomputed from raw punches.
    """
    connection = connection or BioTimeConnection.load()
    if not connection.is_enabled:
        raise ValidationError({"detail": "BioTime integration is disabled."})
    client = build_client(connection)
    user = getattr(request, "user", None)
    if user is not None and not user.is_authenticated:
        user = None

    try:
        match_summary = _sync_employees(client)
        punch_summary = _sync_punches(client, connection)
    except BioTimeError as exc:
        connection.last_sync_status = BioTimeConnection.SyncStatus.ERROR
        connection.last_sync_error = str(exc)
        connection.save(update_fields=["last_sync_status", "last_sync_error", "updated_at"])
        record_attendance_event(
            name="attendance.sync.failed",
            user=user,
            entity_type="biotime_connection",
            entity_id=connection.pk,
            attributes={"error": str(exc)},
            severity=AnalyticsEvent.Severity.WARNING,
        )
        raise ValidationError({"detail": str(exc)}) from exc

    connection.last_synced_at = timezone.now()
    connection.last_sync_status = BioTimeConnection.SyncStatus.OK
    connection.last_sync_error = ""
    connection.save(
        update_fields=[
            "last_synced_at",
            "last_sync_status",
            "last_sync_error",
            "last_punch_cursor",
            "updated_at",
        ]
    )
    summary = {**match_summary, **punch_summary}
    record_attendance_event(
        name="attendance.sync.completed",
        user=user,
        entity_type="biotime_connection",
        entity_id=connection.pk,
        attributes={
            "unmatched_biotime_codes": summary["unmatched_biotime"][:20],
        },
        metrics={
            "matched_employees": summary["matched_employees"],
            "punches_imported": summary["punches_imported"],
            "days_rebuilt": summary["days_rebuilt"],
        },
    )
    return summary


def _sync_employees(client):
    """Match BioTime people to our employees by employee number / existing links."""
    profiles_by_code = {
        profile.biotime_emp_code: profile
        for profile in AttendanceProfile.objects.exclude(biotime_emp_code="")
    }
    employees_by_number = {
        employee.employee_number: employee
        for employee in Employee.objects.exclude(
            status=Employee.Status.TERMINATED
        )
    }
    matched = 0
    unmatched = []
    for person in client.iter_employees():
        emp_code = str(person.get("emp_code") or "").strip()
        if not emp_code:
            continue
        full_name = " ".join(
            part
            for part in (person.get("first_name"), person.get("last_name"))
            if part
        ).strip()
        profile = profiles_by_code.get(emp_code)
        if profile is None:
            employee = employees_by_number.get(emp_code)
            if employee is None:
                unmatched.append({"emp_code": emp_code, "name": full_name})
                continue
            profile, _created = AttendanceProfile.objects.get_or_create(
                employee=employee,
                defaults={"biotime_emp_code": emp_code},
            )
            if not profile.biotime_emp_code:
                profile.biotime_emp_code = emp_code
        if profile.biotime_full_name != full_name:
            profile.biotime_full_name = full_name
        profile.save()
        matched += 1
    return {"matched_employees": matched, "unmatched_biotime": unmatched}


def _parse_punch_time(value):
    if not value:
        return None
    parsed = None
    for fmt in ("%Y-%m-%d %H:%M:%S", "%Y-%m-%dT%H:%M:%S"):
        try:
            parsed = datetime.strptime(str(value)[:19], fmt)
            break
        except ValueError:
            continue
    if parsed is None:
        return None
    if timezone.is_naive(parsed):
        parsed = timezone.make_aware(parsed)
    return parsed


def _sync_punches(client, connection):
    if connection.last_punch_cursor is not None:
        start_time = connection.last_punch_cursor - timedelta(hours=RESYNC_OVERLAP_HOURS)
    else:
        start_time = timezone.now() - timedelta(days=FIRST_SYNC_LOOKBACK_DAYS)
    start_local = timezone.localtime(start_time)

    employees_by_code = {
        profile.biotime_emp_code: profile.employee
        for profile in AttendanceProfile.objects.filter(is_tracked=True)
        .exclude(biotime_emp_code="")
        .select_related("employee")
    }
    existing_ids = set(
        AttendancePunch.objects.filter(biotime_id__isnull=False).values_list(
            "biotime_id", flat=True
        )
    )

    imported = 0
    cursor = connection.last_punch_cursor
    affected = set()
    for row in client.iter_transactions(start_time=start_local):
        biotime_id = row.get("id")
        punch_time = _parse_punch_time(row.get("punch_time"))
        emp_code = str(row.get("emp_code") or "").strip()
        if biotime_id is None or punch_time is None or not emp_code:
            continue
        if cursor is None or punch_time > cursor:
            cursor = punch_time
        if biotime_id in existing_ids:
            continue
        employee = employees_by_code.get(emp_code)
        AttendancePunch.objects.create(
            biotime_id=biotime_id,
            employee=employee,
            emp_code=emp_code,
            punch_time=punch_time,
            punch_state=str(row.get("punch_state") or ""),
            terminal=str(row.get("terminal_alias") or row.get("terminal_sn") or ""),
        )
        existing_ids.add(biotime_id)
        imported += 1
        if employee is not None:
            affected.add((employee.pk, timezone.localtime(punch_time).date()))

    employees = Employee.objects.in_bulk(pk for pk, _date in affected)
    for employee_pk, day_date in sorted(affected, key=lambda pair: (pair[0], pair[1])):
        rebuild_attendance_day(employees[employee_pk], day_date, connection=connection)

    connection.last_punch_cursor = cursor
    return {"punches_imported": imported, "days_rebuilt": len(affected)}


def attendance_summary(employee, period_start, period_end, *, connection=None):
    """Roll a date range up into payroll-ready numbers for one employee."""
    connection = connection or BioTimeConnection.load()
    workdays, _start, _end, _grace = effective_schedule(employee, connection)
    today = timezone.localdate()
    countable_end = min(period_end, today)

    days_by_date = {
        day.date: day
        for day in AttendanceDay.objects.filter(
            employee=employee,
            date__gte=period_start,
            date__lte=period_end,
        )
    }

    expected_days = 0
    present_days = 0
    absent_days = 0
    current = period_start
    while current <= countable_end:
        is_workday = (
            current.weekday() in workdays
            and current >= employee.hire_date
            and (
                employee.termination_date is None
                or current <= employee.termination_date
            )
        )
        if is_workday:
            expected_days += 1
            if current in days_by_date:
                present_days += 1
            else:
                absent_days += 1
        current += timedelta(days=1)

    totals = {
        "worked_minutes": 0,
        "late_minutes": 0,
        "early_leave_minutes": 0,
        "overtime_minutes": 0,
    }
    for day in days_by_date.values():
        totals["worked_minutes"] += day.worked_minutes
        totals["late_minutes"] += day.late_minutes
        totals["early_leave_minutes"] += day.early_leave_minutes
        totals["overtime_minutes"] += day.overtime_minutes

    return {
        "expected_days": expected_days,
        "present_days": present_days,
        "absent_days": absent_days,
        **totals,
    }


def _overtime_hours_from_minutes(overtime_minutes):
    return (Decimal(overtime_minutes) / Decimal(60)).quantize(HOURS_PLACES)


def apply_attendance_to_run(payroll_run, *, request=None):
    """Stamp BioTime attendance onto a draft payroll run.

    Sets each line's absence days and overtime hours from the attendance
    summary; the line's own recalculate values the overtime at the employee's
    hourly wage and overtime multiplier. Safe to re-run.
    """
    if payroll_run.status != PayrollRun.Status.DRAFT:
        raise ValidationError(
            {"detail": "Attendance can only be applied to draft payroll runs."}
        )
    connection = BioTimeConnection.load()
    if not connection.is_enabled:
        raise ValidationError({"detail": "BioTime integration is disabled."})

    user = getattr(request, "user", None)
    if user is not None and not user.is_authenticated:
        user = None

    applied_lines = []
    with transaction.atomic():
        for line in payroll_run.lines.select_related(
            "employee", "compensation_plan"
        ).all():
            profile = getattr(line.employee, "attendance_profile", None)
            if profile is None or not profile.is_tracked or not profile.biotime_emp_code:
                continue
            summary = attendance_summary(
                line.employee,
                payroll_run.period_start,
                payroll_run.period_end,
                connection=connection,
            )
            line.absence_days = Decimal(summary["absent_days"]).quantize(DAYS_PLACES)
            line.overtime_hours = _overtime_hours_from_minutes(
                summary["overtime_minutes"]
            )
            line.save(
                update_fields=["absence_days", "overtime_hours", "updated_at"]
            )
            line.recalculate(save=True)

            applied_lines.append(
                {
                    "line": line.pk,
                    "employee": line.employee_id,
                    "employee_name": line.employee.display_name,
                    "absent_days": summary["absent_days"],
                    "overtime_minutes": summary["overtime_minutes"],
                    "overtime_hours": float(line.overtime_hours),
                    "overtime_amount": float(line.overtime_amount),
                }
            )
        # Clear any prefetched line cache from the viewset queryset so totals
        # are computed from the rows just updated.
        payroll_run.refresh_from_db()
        payroll_run.recalculate()
        payroll_run.save()

    record_attendance_event(
        name="attendance.payroll_run.applied",
        user=user,
        entity_type="payroll_run",
        entity_id=payroll_run.pk,
        attributes={"run_number": payroll_run.run_number},
        metrics={
            "lines_applied": len(applied_lines),
            "net_total": float(payroll_run.net_total),
        },
    )
    return {"applied_lines": applied_lines}
