from django.core.validators import MaxValueValidator
from django.db import models
from django.db.models import Q

from apps.core.models import TimeStampedModel

# Python weekday numbers: Monday=0 .. Sunday=6. Default work week is Sun-Thu.
DEFAULT_WORKDAYS = "6,0,1,2,3"


def parse_workdays(value):
    days = set()
    for part in str(value or "").split(","):
        part = part.strip()
        if part.isdigit() and 0 <= int(part) <= 6:
            days.add(int(part))
    return days


class BioTimeConnection(TimeStampedModel):
    """Singleton holding the ZKTeco BioTime server link and shop work schedule.

    BioTime credentials are stored as entered because the integration must
    re-authenticate against the (LAN-local) BioTime server on every sync.
    """

    class SyncStatus(models.TextChoices):
        NEVER = "never", "Never synced"
        OK = "ok", "Last sync succeeded"
        ERROR = "error", "Last sync failed"

    base_url = models.URLField(blank=True)
    username = models.CharField(max_length=150, blank=True)
    password = models.CharField(max_length=255, blank=True)
    is_enabled = models.BooleanField(default=False)

    workdays = models.CharField(max_length=32, default=DEFAULT_WORKDAYS)
    shift_start = models.TimeField(default="09:00")
    shift_end = models.TimeField(default="17:00")
    grace_minutes = models.PositiveSmallIntegerField(
        default=15, validators=[MaxValueValidator(240)]
    )

    last_synced_at = models.DateTimeField(blank=True, null=True)
    last_sync_status = models.CharField(
        max_length=16,
        choices=SyncStatus.choices,
        default=SyncStatus.NEVER,
    )
    last_sync_error = models.TextField(blank=True)
    last_punch_cursor = models.DateTimeField(blank=True, null=True)

    class Meta:
        verbose_name = "BioTime connection"

    def __str__(self):
        return self.base_url or "BioTime (not configured)"

    def save(self, *args, **kwargs):
        self.pk = 1
        return super().save(*args, **kwargs)

    @classmethod
    def load(cls):
        instance, _created = cls.objects.get_or_create(pk=1)
        return instance

    @property
    def is_configured(self):
        return bool(self.base_url and self.username and self.password)

    @property
    def workday_set(self):
        days = parse_workdays(self.workdays)
        return days or parse_workdays(DEFAULT_WORKDAYS)


class AttendanceProfile(TimeStampedModel):
    """Links one of our employees to a BioTime person and tunes their schedule."""

    employee = models.OneToOneField(
        "employees.Employee",
        on_delete=models.CASCADE,
        related_name="attendance_profile",
    )
    biotime_emp_code = models.CharField(max_length=32, blank=True)
    biotime_full_name = models.CharField(max_length=255, blank=True)
    is_tracked = models.BooleanField(default=True)

    # Optional per-employee schedule overrides; blank/null falls back to the
    # shop schedule on BioTimeConnection.
    shift_start = models.TimeField(blank=True, null=True)
    shift_end = models.TimeField(blank=True, null=True)
    workdays = models.CharField(max_length=32, blank=True)
    grace_minutes = models.PositiveSmallIntegerField(
        blank=True, null=True, validators=[MaxValueValidator(240)]
    )

    class Meta:
        ordering = ["employee__full_name", "id"]
        constraints = [
            models.UniqueConstraint(
                fields=["biotime_emp_code"],
                condition=~Q(biotime_emp_code=""),
                name="unique_biotime_emp_code",
            )
        ]

    def __str__(self):
        return f"{self.employee} ↔ {self.biotime_emp_code or '—'}"


class AttendancePunch(TimeStampedModel):
    """A raw clock punch, normally imported from a BioTime transaction."""

    class Source(models.TextChoices):
        BIOTIME = "biotime", "BioTime"
        MANUAL = "manual", "Manual"

    biotime_id = models.BigIntegerField(blank=True, null=True, unique=True)
    employee = models.ForeignKey(
        "employees.Employee",
        on_delete=models.CASCADE,
        related_name="attendance_punches",
        blank=True,
        null=True,
    )
    emp_code = models.CharField(max_length=32, db_index=True)
    punch_time = models.DateTimeField(db_index=True)
    punch_state = models.CharField(max_length=16, blank=True)
    terminal = models.CharField(max_length=120, blank=True)
    source = models.CharField(
        max_length=16,
        choices=Source.choices,
        default=Source.BIOTIME,
    )

    class Meta:
        ordering = ["punch_time", "id"]
        indexes = [models.Index(fields=["employee", "punch_time"])]

    def __str__(self):
        return f"{self.emp_code} @ {self.punch_time:%Y-%m-%d %H:%M}"


class AttendanceDay(TimeStampedModel):
    """One employee-day rolled up from punches against the work schedule."""

    class Status(models.TextChoices):
        PRESENT = "present", "Present"
        LATE = "late", "Late"
        PARTIAL = "partial", "Missing punch"
        DAY_OFF = "day_off", "Day off"

    employee = models.ForeignKey(
        "employees.Employee",
        on_delete=models.CASCADE,
        related_name="attendance_days",
    )
    date = models.DateField(db_index=True)
    status = models.CharField(max_length=16, choices=Status.choices)
    first_in = models.DateTimeField(blank=True, null=True)
    last_out = models.DateTimeField(blank=True, null=True)
    punch_count = models.PositiveSmallIntegerField(default=0)
    worked_minutes = models.PositiveIntegerField(default=0)
    late_minutes = models.PositiveIntegerField(default=0)
    early_leave_minutes = models.PositiveIntegerField(default=0)
    overtime_minutes = models.PositiveIntegerField(default=0)

    class Meta:
        ordering = ["-date", "employee__full_name"]
        constraints = [
            models.UniqueConstraint(
                fields=["employee", "date"],
                name="unique_attendance_day_per_employee",
            )
        ]

    def __str__(self):
        return f"{self.employee} {self.date} ({self.status})"
