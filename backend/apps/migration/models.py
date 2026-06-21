from django.contrib.contenttypes.fields import GenericForeignKey
from django.contrib.contenttypes.models import ContentType
from django.core.validators import MaxValueValidator
from django.db import models
from django.utils import timezone

from apps.core.models import TimeStampedModel


class TransportKind(models.TextChoices):
    MSSQL = "mssql", "Microsoft SQL Server"
    POSTGRES = "postgres", "PostgreSQL"
    SQLITE = "sqlite", "SQLite"
    MONGO = "mongo", "MongoDB"


class MigrationSource(TimeStampedModel):
    """A saved connection to a shop's previous POS database.

    Unlike :class:`~apps.attendance.models.BioTimeConnection` there can be more
    than one (an owner may keep a separate sales-archive DB), so this is a
    normal table rather than a ``pk=1`` singleton. Credentials are stored as
    entered because the connection must be re-opened on every test,
    compatibility check, and run (mirroring BioTime). Because migration is a
    one-time task, the password is blanked after a successful import — see
    ``services.finalize_source_after_import`` — so it is not left at rest.
    """

    class CompatStatus(models.TextChoices):
        UNKNOWN = "unknown", "Not checked"
        COMPATIBLE = "compatible", "Compatible"
        INCOMPATIBLE = "incompatible", "Incompatible"

    name = models.CharField(max_length=120)
    # Key of the connector that interprets this system, e.g. "aboghris_mssql".
    system_key = models.CharField(max_length=64)
    transport_kind = models.CharField(max_length=16, choices=TransportKind.choices)
    host = models.CharField(max_length=255, blank=True)
    port = models.PositiveIntegerField(blank=True, null=True)
    # Database name for server engines; absolute file path for SQLite.
    database_name = models.CharField(max_length=255, blank=True)
    username = models.CharField(max_length=150, blank=True)
    password = models.CharField(max_length=255, blank=True)
    # Driver knobs that don't deserve a column of their own: ODBC driver name,
    # TLS/encrypt flags, text encoding (legacy MSSQL is often Windows-1256),
    # Mongo auth database, etc. Validated per-transport, never executed.
    extra_options = models.JSONField(default=dict, blank=True)

    detected_version = models.CharField(max_length=64, blank=True)
    last_compat_status = models.CharField(
        max_length=16,
        choices=CompatStatus.choices,
        default=CompatStatus.UNKNOWN,
    )
    last_compat_report = models.JSONField(default=dict, blank=True)
    last_run_at = models.DateTimeField(blank=True, null=True)
    credentials_cleared = models.BooleanField(default=False)
    is_archived = models.BooleanField(default=False)

    class Meta:
        ordering = ["-created_at"]

    def __str__(self):
        return f"{self.name} ({self.system_key})"

    @property
    def has_password(self):
        return bool(self.password)

    def connection_dict(self):
        """The shape consumed by transports (kept stable + driver-agnostic)."""
        return {
            "host": self.host,
            "port": self.port,
            "database": self.database_name,
            "username": self.username,
            "password": self.password,
            "options": dict(self.extra_options or {}),
        }


class MigrationRun(TimeStampedModel):
    """A single execution against a source — a dry run or a real import.

    The lifecycle helpers mirror ``core.SystemMaintenanceJob`` so the frontend
    polling flow transfers 1:1, with an extra ``partial`` terminal state for
    "finished, but N records could not be imported".
    """

    class Mode(models.TextChoices):
        DRY_RUN = "dry_run", "Dry run"
        IMPORT = "import", "Import"

    class Status(models.TextChoices):
        QUEUED = "queued", "Queued"
        RUNNING = "running", "Running"
        SUCCEEDED = "succeeded", "Succeeded"
        PARTIAL = "partial", "Completed with issues"
        FAILED = "failed", "Failed"

    source = models.ForeignKey(
        MigrationSource,
        on_delete=models.PROTECT,
        related_name="runs",
    )
    mode = models.CharField(max_length=8, choices=Mode.choices)
    status = models.CharField(
        max_length=16,
        choices=Status.choices,
        default=Status.QUEUED,
        db_index=True,
    )
    # Entity types the owner chose to transfer (subset of ENTITY_PLAN keys).
    selected_entities = models.JSONField(default=list, blank=True)
    # Per-run toggles chosen in the UI, generic across connectors. Currently:
    # {"products_without_quantities": bool} — when true the stock entity is
    # skipped so products are imported with no stock on hand.
    options = models.JSONField(default=dict, blank=True)
    progress_percent = models.PositiveSmallIntegerField(
        default=0,
        validators=[MaxValueValidator(100)],
    )
    progress_message = models.CharField(max_length=240, blank=True)
    current_entity = models.CharField(max_length=48, blank=True)
    # Per-entity aggregate counts:
    # {"product": {"created": 10, "updated": 2, "skipped": 0, "failed": 1}, ...}
    summary = models.JSONField(default=dict, blank=True)
    error_message = models.TextField(blank=True)
    initiated_by_user_id = models.PositiveBigIntegerField(blank=True, null=True)
    initiated_by_username = models.CharField(max_length=150, blank=True)
    started_at = models.DateTimeField(blank=True, null=True)
    completed_at = models.DateTimeField(blank=True, null=True)

    class Meta:
        ordering = ["-created_at"]
        indexes = [
            models.Index(fields=["source", "-created_at"]),
            models.Index(fields=["status", "-created_at"]),
        ]

    def __str__(self):
        return f"{self.mode} {self.status} #{self.pk}"

    @property
    def is_active(self):
        return self.status in {self.Status.QUEUED, self.Status.RUNNING}

    def mark_running(self, message=""):
        self.status = self.Status.RUNNING
        self.started_at = self.started_at or timezone.now()
        if message:
            self.progress_message = message
        self.save(update_fields=["status", "started_at", "progress_message", "updated_at"])

    def update_progress(self, percent, message="", *, current_entity=None):
        self.progress_percent = max(0, min(100, int(percent)))
        if message:
            self.progress_message = message
        fields = ["progress_percent", "progress_message", "updated_at"]
        if current_entity is not None:
            self.current_entity = current_entity
            fields.append("current_entity")
        self.save(update_fields=fields)

    def mark_succeeded(self, message=""):
        self.status = self.Status.SUCCEEDED
        self.progress_percent = 100
        self.completed_at = timezone.now()
        if message:
            self.progress_message = message
        self.save(
            update_fields=[
                "status",
                "progress_percent",
                "progress_message",
                "completed_at",
                "updated_at",
            ]
        )

    def mark_partial(self, message=""):
        self.status = self.Status.PARTIAL
        self.progress_percent = 100
        self.completed_at = timezone.now()
        if message:
            self.progress_message = message
        self.save(
            update_fields=[
                "status",
                "progress_percent",
                "progress_message",
                "completed_at",
                "updated_at",
            ]
        )

    def mark_failed(self, error_message):
        self.status = self.Status.FAILED
        self.error_message = str(error_message)
        self.completed_at = timezone.now()
        if not self.progress_message:
            self.progress_message = "فشلت عملية النقل."
        self.save(
            update_fields=[
                "status",
                "error_message",
                "progress_message",
                "completed_at",
                "updated_at",
            ]
        )


class MigrationIdentityMap(TimeStampedModel):
    """Maps a source record (by its connector-stable key) to the Pointy row it
    became.

    The spine of idempotency. Re-runs update the mapped row instead of
    duplicating it, and downstream entities resolve their foreign keys (a
    sale's customer/variant) to already-imported Pointy ids through this table.
    Keyed on the *source* key — never on Pointy's auto-generated numbers
    (``customer_number``/``order_number``/``sku``), which are fabricated at
    insert time and absent from the source.
    """

    source = models.ForeignKey(
        MigrationSource,
        on_delete=models.CASCADE,
        related_name="identities",
    )
    entity_type = models.CharField(max_length=48, db_index=True)
    source_key = models.CharField(max_length=255)
    target_content_type = models.ForeignKey(ContentType, on_delete=models.PROTECT)
    target_object_id = models.PositiveBigIntegerField()
    target = GenericForeignKey("target_content_type", "target_object_id")
    first_run = models.ForeignKey(
        MigrationRun,
        on_delete=models.SET_NULL,
        null=True,
        blank=True,
        related_name="+",
    )
    last_seen_run = models.ForeignKey(
        MigrationRun,
        on_delete=models.SET_NULL,
        null=True,
        blank=True,
        related_name="+",
    )

    class Meta:
        constraints = [
            models.UniqueConstraint(
                fields=["source", "entity_type", "source_key"],
                name="uniq_identity_per_source_entity_key",
            )
        ]
        indexes = [models.Index(fields=["source", "entity_type"])]

    def __str__(self):
        return (
            f"{self.entity_type}:{self.source_key} -> "
            f"{self.target_content_type_id}:{self.target_object_id}"
        )


class MigrationIssue(TimeStampedModel):
    """One per-record warning/error for the run report.

    A real import can emit thousands of these; storing them in a table (rather
    than on ``MigrationRun.summary``) keeps the run row small and lets the UI
    paginate the drill-down. The engine caps how many it persists per
    (run, entity_type) and rolls the overflow into ``summary``.
    """

    class Severity(models.TextChoices):
        WARNING = "warning", "Warning"
        ERROR = "error", "Error"

    run = models.ForeignKey(
        MigrationRun,
        on_delete=models.CASCADE,
        related_name="issues",
    )
    entity_type = models.CharField(max_length=48, db_index=True)
    source_key = models.CharField(max_length=255, blank=True)
    severity = models.CharField(max_length=8, choices=Severity.choices)
    code = models.CharField(max_length=48)
    message = models.TextField()
    detail = models.JSONField(default=dict, blank=True)

    class Meta:
        ordering = ["id"]
        indexes = [
            models.Index(fields=["run", "severity"]),
            models.Index(fields=["run", "entity_type"]),
        ]

    def __str__(self):
        return f"[{self.severity}] {self.entity_type}:{self.source_key} {self.code}"
