"""BioTime sync and attendance rollups feeding payroll."""

from datetime import datetime, timedelta
from decimal import Decimal

from django.db import transaction
from django.db.models import Max, Min, Q
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
# Only used when BioTime itself reports no transactions at all; a real first
# sync starts from the server's own oldest punch (or an explicit start date).
FIRST_SYNC_LOOKBACK_DAYS = 30
# Rows per bulk INSERT and per existence probe while importing punches.
PUNCH_BATCH_SIZE = 1000
# How many punches to import before persisting progress. A first backfill runs
# for minutes against a real BioTime server (measured: ~150s for 20k rows, which
# it serves at roughly 1000 rows per 5s). Without a checkpoint, a request that
# dies part-way leaves the punches committed but the cursor unmoved, so the next
# sync re-reads the entire history from the beginning -- and over the relay,
# whose request timeout is far shorter than a full backfill, it would never
# converge at all. Coarser than the write batch so the day rollups it forces
# stay cheap.
CHECKPOINT_EVERY_PUNCHES = 5000
# Re-read a small window behind the cursor so late-arriving device uploads are
# still captured; upserts keep this idempotent.
RESYNC_OVERLAP_HOURS = 24
# How long a RUNNING sync may go without a heartbeat before another run may take
# it over. A live sync heartbeats at every checkpoint, so this only ever fires
# for a worker that died mid-run -- which would otherwise leave the row claiming
# RUNNING forever and lock out every future sync.
SYNC_HEARTBEAT_STALE_MINUTES = 15


def release_sync_slot(connection):
    """Drop the run lock without recording a result.

    For a claim that never became a run (the dispatch failed). Restores the
    status the row's own history implies, since claiming overwrote it.
    """
    if not connection.is_syncing:
        return
    connection.last_sync_status = (
        BioTimeConnection.SyncStatus.OK
        if connection.last_synced_at is not None
        else BioTimeConnection.SyncStatus.NEVER
    )
    connection.sync_started_at = None
    connection.save(
        update_fields=["last_sync_status", "sync_started_at", "updated_at"]
    )


def claim_sync_slot(connection):
    """Take the run lock, or return False when a sync is already going.

    A backfill hammers a slow BioTime server for minutes; two of them at once
    (a manual press landing on top of the hourly beat) doubles that load for
    nothing, since both would import the same rows. The claim is a single
    conditional UPDATE so two workers racing cannot both win it.
    """
    now = timezone.now()
    stale_before = now - timedelta(minutes=SYNC_HEARTBEAT_STALE_MINUTES)
    claimed = (
        BioTimeConnection.objects.filter(pk=connection.pk)
        .filter(
            Q(last_sync_status=BioTimeConnection.SyncStatus.RUNNING)
            & (Q(sync_heartbeat_at__isnull=True) | Q(sync_heartbeat_at__lt=stale_before))
            | ~Q(last_sync_status=BioTimeConnection.SyncStatus.RUNNING)
        )
        .update(
            last_sync_status=BioTimeConnection.SyncStatus.RUNNING,
            sync_started_at=now,
            sync_heartbeat_at=now,
            sync_progress_punches=0,
            last_sync_error="",
            updated_at=now,
        )
    )
    if claimed:
        connection.refresh_from_db()
    return bool(claimed)


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


def _day_fields(punch_times, day_date, schedule):
    """Compute one AttendanceDay's values from that day's ordered punch times."""
    workdays, shift_start, shift_end, grace_minutes = schedule
    first_in = punch_times[0]
    last_out = punch_times[-1] if len(punch_times) > 1 else None
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
        if shift_end <= shift_start:
            # A night shift (22:00 -> 06:00) ends the following morning. Without
            # this the shift would "end" before it started, and every minute
            # worked in the evening would be counted — and paid — as overtime.
            expected_end += timedelta(days=1)
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

    return {
        "status": status,
        "first_in": first_in,
        "last_out": last_out,
        "punch_count": len(punch_times),
        "worked_minutes": worked_minutes,
        "late_minutes": late_minutes,
        "early_leave_minutes": early_leave_minutes,
        "overtime_minutes": overtime_minutes,
    }


DAY_VALUE_FIELDS = (
    "status",
    "first_in",
    "last_out",
    "punch_count",
    "worked_minutes",
    "late_minutes",
    "early_leave_minutes",
    "overtime_minutes",
)


def rebuild_attendance_day(employee, day_date, *, connection=None):
    """Recompute the AttendanceDay row for one employee-day from raw punches."""
    connection = connection or BioTimeConnection.load()
    day_start = _aware(day_date, datetime.min.time())
    day_end = day_start + timedelta(days=1)
    punch_times = list(
        AttendancePunch.objects.filter(
            employee=employee,
            punch_time__gte=day_start,
            punch_time__lt=day_end,
        )
        .order_by("punch_time")
        .values_list("punch_time", flat=True)
    )
    if not punch_times:
        AttendanceDay.objects.filter(employee=employee, date=day_date).delete()
        return None

    day, _created = AttendanceDay.objects.update_or_create(
        employee=employee,
        date=day_date,
        defaults=_day_fields(
            punch_times, day_date, effective_schedule(employee, connection)
        ),
    )
    return day


def rebuild_attendance_days(employee_dates, *, connection=None):
    """Recompute many employee-days at once.

    The per-day path costs three queries per day, which a multi-year backfill
    multiplies into tens of thousands. This reads each employee's punches for
    the whole affected span in one query and writes the rollups with two bulk
    statements per employee instead.
    """
    connection = connection or BioTimeConnection.load()
    dates_by_employee = {}
    for employee_pk, day_date in employee_dates:
        dates_by_employee.setdefault(employee_pk, set()).add(day_date)
    if not dates_by_employee:
        return 0

    employees = Employee.objects.in_bulk(dates_by_employee)
    written = 0
    for employee_pk, day_dates in dates_by_employee.items():
        employee = employees.get(employee_pk)
        if employee is None:
            continue
        schedule = effective_schedule(employee, connection)
        span_start = _aware(min(day_dates), datetime.min.time())
        span_end = _aware(max(day_dates), datetime.min.time()) + timedelta(days=1)
        by_date = {}
        punch_rows = (
            AttendancePunch.objects.filter(
                employee=employee,
                punch_time__gte=span_start,
                punch_time__lt=span_end,
            )
            .order_by("punch_time")
            .values_list("punch_time", flat=True)
        )
        # DISABLE_SERVER_SIDE_CURSORS is on for Postgres (PgBouncer), so
        # iterator() would buffer client-side anyway; a plain loop is the same
        # cost without implying chunking that cannot happen.
        for punch_time in punch_rows:
            local_date = timezone.localtime(punch_time).date()
            if local_date in day_dates:
                by_date.setdefault(local_date, []).append(punch_time)

        existing = {
            day.date: day
            for day in AttendanceDay.objects.filter(
                employee=employee, date__in=day_dates
            )
        }
        to_create = []
        to_update = []
        for day_date in day_dates:
            punch_times = by_date.get(day_date)
            if not punch_times:
                continue
            fields = _day_fields(punch_times, day_date, schedule)
            day = existing.get(day_date)
            if day is None:
                to_create.append(
                    AttendanceDay(employee=employee, date=day_date, **fields)
                )
            else:
                for name, value in fields.items():
                    setattr(day, name, value)
                to_update.append(day)
        emptied = [d for d in day_dates if not by_date.get(d)]
        if emptied:
            AttendanceDay.objects.filter(employee=employee, date__in=emptied).delete()
        if to_create:
            AttendanceDay.objects.bulk_create(to_create, batch_size=500)
        if to_update:
            # bulk_update does not run pre_save, so auto_now would leave
            # updated_at at its stale in-memory value; stamp it by hand.
            stamped_at = timezone.now()
            for day in to_update:
                day.updated_at = stamped_at
            AttendanceDay.objects.bulk_update(
                to_update, [*DAY_VALUE_FIELDS, "updated_at"], batch_size=500
            )
        written += len(to_create) + len(to_update)
    return written


def sync_biotime(*, request=None, connection=None, claim=True):
    """Pull employees and punches from BioTime; returns a summary dict.

    Idempotent: punches upsert on the BioTime transaction id, and day rollups
    are recomputed from raw punches.

    Holds the run lock for its duration (``claim=False`` only when the caller
    already claimed it, i.e. the worker task), and always releases it -- a run
    that leaves the row RUNNING would lock out every later sync.
    """
    connection = connection or BioTimeConnection.load()
    if not connection.is_enabled:
        raise ValidationError({"detail": "BioTime integration is disabled."})
    if claim and not claim_sync_slot(connection):
        raise ValidationError({"detail": "A BioTime sync is already running."})
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
        # Release the run lock even on the failure path. The progress the run
        # checkpointed stays on the row; only the RUNNING claim is dropped.
        connection.sync_started_at = None
        connection.save(
            update_fields=[
                "last_sync_status",
                "last_sync_error",
                "sync_started_at",
                "updated_at",
            ]
        )
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
    connection.sync_started_at = None
    connection.save(
        update_fields=[
            "last_synced_at",
            "last_sync_status",
            "last_sync_error",
            "sync_started_at",
            "last_punch_cursor",
            "first_punch_cursor",
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
    changed = []
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
                changed.append(profile)
        if profile.biotime_full_name != full_name:
            profile.biotime_full_name = full_name
            if profile not in changed:
                changed.append(profile)
        matched += 1
    # Every sync used to re-save all matched profiles even when nothing about
    # them had moved; only the rows that actually changed are written now.
    if changed:
        stamped_at = timezone.now()
        for profile in changed:
            profile.updated_at = stamped_at
        AttendanceProfile.objects.bulk_update(
            changed, ["biotime_emp_code", "biotime_full_name", "updated_at"]
        )
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


def _resolve_punch_start(client, connection):
    """Where this pull should start reading BioTime from.

    A resumed sync re-reads a small window behind the cursor. A FIRST sync has
    no cursor, and must not guess: a fixed lookback window silently imports
    nothing at all from a server whose history is older than the window (a real
    installation whose newest punch was 17 months old imported 0 of 20,203
    rows, and payroll then read that silence as everyone being absent). Start
    from the configured date, else from BioTime's own oldest punch.
    """
    if connection.last_punch_cursor is not None:
        return connection.last_punch_cursor - timedelta(hours=RESYNC_OVERLAP_HOURS)
    if connection.sync_start_date is not None:
        return _aware(connection.sync_start_date, datetime.min.time())
    earliest = _parse_punch_time(client.earliest_transaction_time())
    if earliest is not None:
        # A minute of slack so the oldest row itself is inside the window.
        return earliest - timedelta(minutes=1)
    return timezone.now() - timedelta(days=FIRST_SYNC_LOOKBACK_DAYS)


def _sync_punches(client, connection):
    start_time = _resolve_punch_start(client, connection)
    start_local = timezone.localtime(start_time)

    employees_by_code = {
        profile.biotime_emp_code: profile.employee
        for profile in AttendanceProfile.objects.filter(is_tracked=True)
        .exclude(biotime_emp_code="")
        .select_related("employee")
    }
    imported = 0
    # Distinct employee-days touched. A day whose punches straddle a checkpoint
    # is rebuilt twice (correctly -- the second pass sees all of them), so the
    # reported figure counts days, not rebuild passes.
    rebuilt_days = set()
    cursor = connection.last_punch_cursor
    earliest_seen = None
    affected = set()
    # Punches arrive one row at a time but are written a batch at a time: a
    # multi-year backfill is 20k+ INSERTs otherwise. Membership is checked per
    # batch rather than by holding every id ever imported in memory.
    batch = []
    since_checkpoint = 0

    def flush(batch):
        nonlocal imported
        if not batch:
            return
        known = set(
            AttendancePunch.objects.filter(
                biotime_id__in=[punch.biotime_id for punch in batch]
            ).values_list("biotime_id", flat=True)
        )
        fresh = [punch for punch in batch if punch.biotime_id not in known]
        if fresh:
            # ignore_conflicts guards against a concurrent sync inserting the
            # same transaction between the probe above and this write.
            AttendancePunch.objects.bulk_create(
                fresh, batch_size=PUNCH_BATCH_SIZE, ignore_conflicts=True
            )
            imported += len(fresh)

    def checkpoint(through):
        """Persist progress up to ``through`` so a killed sync can resume.

        Order matters: the day rollups for everything imported so far are built
        BEFORE the cursor moves. Moving the cursor first would let a sync die
        between the two and leave punches on disk that no rollup ever covers --
        the resume only re-reads the last day behind the cursor, so those days
        would read as absences forever.
        """
        nonlocal affected
        rebuild_attendance_days(affected, connection=connection)
        rebuilt_days.update(affected)
        affected = set()
        connection.last_punch_cursor = through
        if earliest_seen is not None and (
            connection.first_punch_cursor is None
            or earliest_seen < connection.first_punch_cursor
        ):
            connection.first_punch_cursor = earliest_seen
        # The heartbeat is what tells a later run whether this one is alive or
        # died on a killed worker; the count is what the settings screen shows
        # while a multi-minute backfill runs.
        connection.sync_heartbeat_at = timezone.now()
        connection.sync_progress_punches = imported
        connection.save(
            update_fields=[
                "last_punch_cursor",
                "first_punch_cursor",
                "sync_heartbeat_at",
                "sync_progress_punches",
                "updated_at",
            ]
        )

    for row in client.iter_transactions(start_time=start_local):
        biotime_id = row.get("id")
        punch_time = _parse_punch_time(row.get("punch_time"))
        emp_code = str(row.get("emp_code") or "").strip()
        if biotime_id is None or punch_time is None or not emp_code:
            continue
        if cursor is None or punch_time > cursor:
            cursor = punch_time
        if earliest_seen is None or punch_time < earliest_seen:
            earliest_seen = punch_time
        employee = employees_by_code.get(emp_code)
        batch.append(
            AttendancePunch(
                biotime_id=biotime_id,
                employee=employee,
                emp_code=emp_code,
                punch_time=punch_time,
                punch_state=str(row.get("punch_state") or ""),
                terminal=str(row.get("terminal_alias") or row.get("terminal_sn") or ""),
            )
        )
        if employee is not None:
            affected.add((employee.pk, timezone.localtime(punch_time).date()))
        if len(batch) >= PUNCH_BATCH_SIZE:
            # The rows are time-ordered, so this batch's last punch is the point
            # everything older than which is now on disk.
            through = batch[-1].punch_time
            since_checkpoint += len(batch)
            flush(batch)
            batch = []
            if since_checkpoint >= CHECKPOINT_EVERY_PUNCHES:
                checkpoint(through)
                since_checkpoint = 0
    flush(batch)

    rebuild_attendance_days(affected, connection=connection)
    rebuilt_days.update(affected)

    connection.last_punch_cursor = cursor
    if earliest_seen is not None and (
        connection.first_punch_cursor is None
        or earliest_seen < connection.first_punch_cursor
    ):
        connection.first_punch_cursor = earliest_seen
    return {"punches_imported": imported, "days_rebuilt": len(rebuilt_days)}


def attendance_summary(
    employee, period_start, period_end, *, connection=None, days=None
):
    """Roll a date range up into payroll-ready numbers for one employee."""
    connection = connection or BioTimeConnection.load()
    workdays, _start, _end, _grace = effective_schedule(employee, connection)
    today = timezone.localdate()
    countable_end = min(period_end, today)

    if days is None:
        days = AttendanceDay.objects.filter(
            employee=employee,
            date__gte=period_start,
            date__lte=period_end,
        )
    days_by_date = {day.date: day for day in days}

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


def synced_coverage(connection=None):
    """The date range attendance data can be trusted over.

    ``start`` is the oldest data we hold. ``end`` is how far forward a sync has
    actually READ BioTime -- which is not the same as the last punch it found:
    a sync that read through Friday and saw nobody clock in on Friday has
    genuinely observed an absence. ``end`` is None when no sync has ever run
    (punches entered by hand say nothing about how far forward we have looked).
    """
    connection = connection or BioTimeConnection.load()
    # The punch table is the honest answer to "what do we hold": it also covers
    # punches entered by hand, which no sync cursor knows about.
    bounds = AttendancePunch.objects.aggregate(
        lo=Min("punch_time"), hi=Max("punch_time")
    )
    starts = [value for value in (bounds["lo"], connection.first_punch_cursor) if value]
    start = timezone.localtime(min(starts)).date() if starts else None
    end = (
        timezone.localtime(connection.last_punch_cursor).date()
        if connection.last_punch_cursor is not None
        else None
    )
    if start is None and end is None and bounds["hi"]:
        end = timezone.localtime(bounds["hi"]).date()
    return start, end


def uncovered_period(period_start, period_end, *, connection=None):
    """Describe how a payroll period falls outside the data we hold.

    Empty string when the period is safe to cost absences from. This exists
    because "no AttendanceDay row" is read as "absent": outside the imported
    window that inference is wrong, and it silently deducts a full period's
    pay from every employee.
    """
    connection = connection or BioTimeConnection.load()
    start, end = synced_coverage(connection)
    if start is None:
        return "No attendance data has been imported yet."
    if end is not None and (period_end < start or period_start > end):
        return (
            f"No attendance was imported for {period_start} to {period_end}; "
            f"attendance data covers {start} to {end}."
        )
    if period_start < start:
        return (
            f"Attendance data starts on {start}, after the period begins on "
            f"{period_start}."
        )
    # Only a sync can say how far forward BioTime was read. Where it stopped
    # short of the period, the tail would be counted as absence it never saw.
    if end is not None and period_end > end and end < timezone.localdate():
        return (
            f"Attendance has only been synced through {end}, before the period "
            f"ends on {period_end}."
        )
    return ""


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

    # A period with no imported punches is not a period where everybody was
    # absent. Without this guard a sync that quietly fetched nothing turns into
    # a full-period absence deduction on every line -- measured at a 71% cut to
    # a real run -- with nothing on screen to say the data was never there.
    gap = uncovered_period(
        payroll_run.period_start, payroll_run.period_end, connection=connection
    )
    if gap:
        raise ValidationError({"detail": gap})

    user = getattr(request, "user", None)
    if user is not None and not user.is_authenticated:
        user = None

    applied_lines = []
    # Employees the period expected at work but whose punches are entirely
    # missing. Arithmetically that is a full-period absence; in practice it is
    # just as often someone never enrolled on the terminal, or enrolled under a
    # code we did not match. Deducting a whole month's pay on that ambiguity is
    # exactly the failure this integration must not repeat silently, so each
    # one is reported back for a human to confirm.
    lines_without_attendance = []
    line_fields = [
        "absence_days",
        "overtime_hours",
        "rate",
        "gross_amount",
        "absence_deduction_amount",
        "overtime_multiplier",
        "overtime_amount",
        "additions_amount",
        "deductions_amount",
        "net_amount",
        "updated_at",
    ]
    with transaction.atomic():
        # One read of the period's rollups for the whole run instead of one per
        # line.
        days_by_employee = {}
        for day in AttendanceDay.objects.filter(
            employee__payroll_lines__payroll_run=payroll_run,
            date__gte=payroll_run.period_start,
            date__lte=payroll_run.period_end,
        ):
            days_by_employee.setdefault(day.employee_id, []).append(day)
        # attendance_profile is read for every line (tracking flag + schedule
        # overrides); without it here each line costs an extra query.
        for line in payroll_run.lines.select_related(
            "employee", "employee__attendance_profile", "compensation_plan"
        ).prefetch_related("adjustments"):
            profile = getattr(line.employee, "attendance_profile", None)
            if profile is None or not profile.is_tracked or not profile.biotime_emp_code:
                continue
            summary = attendance_summary(
                line.employee,
                payroll_run.period_start,
                payroll_run.period_end,
                connection=connection,
                days=days_by_employee.get(line.employee_id, []),
            )
            line.absence_days = Decimal(summary["absent_days"]).quantize(DAYS_PLACES)
            line.overtime_hours = _overtime_hours_from_minutes(
                summary["overtime_minutes"]
            )
            # recalculate(save=True) does not persist the two input fields, so
            # both writes are folded into a single UPDATE per line.
            line.recalculate()
            line.save(update_fields=line_fields)

            if summary["expected_days"] > 0 and summary["present_days"] == 0:
                lines_without_attendance.append(
                    {
                        "line": line.pk,
                        "employee": line.employee_id,
                        "employee_name": line.employee.display_name,
                        "biotime_emp_code": profile.biotime_emp_code,
                        "expected_days": summary["expected_days"],
                    }
                )
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
            "lines_without_attendance": len(lines_without_attendance),
            "net_total": float(payroll_run.net_total),
        },
    )
    return {
        "applied_lines": applied_lines,
        "lines_without_attendance": lines_without_attendance,
    }
