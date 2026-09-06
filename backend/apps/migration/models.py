from django.contrib.contenttypes.fields import GenericForeignKey
from django.contrib.contenttypes.models import ContentType
from django.core.validators import MaxValueValidator
from django.db import models
from django.utils import timezone

from apps.core.models import TimeStampedModel


class MigrationSource(TimeStampedModel):
    """One uploaded legacy-POS database file, and everything derived from it.

    A migration starts with a file. The owner picks their old system's database
    off a USB stick or a network share, the app uploads it in resumable chunks,
    and the server converts it, identifies which POS wrote it, imports it, and
    then deletes it. There is no host, no port, and no password: this model used
    to describe a *database server* to connect to, and every field that did has
    been removed, because in the field those fields were the migration.

    The row outlives the file it came from. Purging clears the bytes, not the
    record — :class:`MigrationIdentityMap` hangs off this row and is what makes a
    second import update the same products instead of duplicating them, so the
    row is what "this shop's data came from here" means afterwards.
    """

    class UploadState(models.TextChoices):
        # Chunks are still arriving; `received_bytes` is the resume offset.
        UPLOADING = "uploading", "Receiving"
        # All bytes in and verified, waiting for (or queued for) preparation.
        UPLOADED = "uploaded", "Received"
        # Converting / reconstructing / identifying — see `stages`.
        PREPARING = "preparing", "Preparing"
        # A readable database the connector understands. Ready to import.
        READY = "ready", "Ready"
        FAILED = "failed", "Failed"
        # Bytes deleted from the server. Terminal, and the goal.
        PURGED = "purged", "Deleted"

    class CompatStatus(models.TextChoices):
        UNKNOWN = "unknown", "Not checked"
        COMPATIBLE = "compatible", "Compatible"
        INCOMPATIBLE = "incompatible", "Incompatible"

    #: Display label. Defaults to the uploaded file's name.
    name = models.CharField(max_length=120)
    original_filename = models.CharField(max_length=255, blank=True, db_default="")
    #: Size the client declared up front, so progress has a denominator before
    #: the last chunk lands.
    declared_size_bytes = models.PositiveBigIntegerField(default=0, db_default=0)
    #: Bytes durably written. The resume offset: a client that reconnects asks
    #: for this and continues from it rather than starting the GB again.
    received_bytes = models.PositiveBigIntegerField(default=0, db_default=0)
    checksum_sha256 = models.CharField(max_length=64, blank=True, db_default="")

    upload_state = models.CharField(
        max_length=16,
        choices=UploadState.choices,
        default=UploadState.UPLOADING,
        db_default=UploadState.UPLOADING,
        db_index=True,
    )
    #: File names (not paths) inside the staging root — see `storage.py`. Keeping
    #: them relative means the volume can move without rewriting rows.
    staged_filename = models.CharField(max_length=255, blank=True, db_default="")
    prepared_filename = models.CharField(max_length=255, blank=True, db_default="")
    #: Byte sizes kept after the files are gone, so the report can still say how
    #: much was uploaded and how much was freed.
    staged_size_bytes = models.PositiveBigIntegerField(default=0, db_default=0)
    prepared_size_bytes = models.PositiveBigIntegerField(default=0, db_default=0)

    #: Preparation timeline: a list of stage dicts (see `preparation.stages`).
    #: The UI renders it as a checklist rather than one meaningless percentage,
    #: because converting a 1.5 GB Access file takes long enough that "62%" with
    #: no other information is indistinguishable from a hang.
    stages = models.JSONField(default=list, blank=True, db_default=[])
    error_message = models.TextField(blank=True, db_default="")

    #: Connector key, *detected* from the file's schema rather than chosen by the
    #: owner — who knows their POS by its splash screen, not its table names.
    system_key = models.CharField(max_length=64, blank=True)
    detected_version = models.CharField(max_length=64, blank=True)
    #: Every connector's score against this file, best first. Kept so an
    #: unrecognised file can say what it looked closest to and what was missing.
    detection = models.JSONField(default=dict, blank=True, db_default={})
    last_compat_status = models.CharField(
        max_length=16,
        choices=CompatStatus.choices,
        default=CompatStatus.UNKNOWN,
    )
    last_compat_report = models.JSONField(default=dict, blank=True)
    #: What is inside: per-entity counts and the date range of the history.
    #: Shown before the owner commits to anything.
    analysis = models.JSONField(default=dict, blank=True, db_default={})

    last_run_at = models.DateTimeField(blank=True, null=True)
    purged_at = models.DateTimeField(blank=True, null=True)

    class Meta:
        ordering = ["-created_at"]
        indexes = [models.Index(fields=["upload_state", "-created_at"])]

    def __str__(self):
        return f"{self.name} ({self.system_key or 'unidentified'})"

    # --- state helpers ---------------------------------------------------
    @property
    def is_uploading(self):
        return self.upload_state == self.UploadState.UPLOADING

    @property
    def is_ready(self):
        return self.upload_state == self.UploadState.READY

    @property
    def is_purged(self):
        return self.upload_state == self.UploadState.PURGED

    @property
    def is_busy(self):
        """Preparation is in flight — the UI polls rather than offers actions."""
        return self.upload_state in {
            self.UploadState.UPLOADED,
            self.UploadState.PREPARING,
        }

    @property
    def upload_percent(self):
        if not self.declared_size_bytes:
            return 0
        return min(100, int(self.received_bytes / self.declared_size_bytes * 100))

    def connection_dict(self):
        """The shape transports consume. One key now: the prepared file."""
        from .storage import prepared_path

        path = prepared_path(self)
        return {"database": str(path) if path else "", "options": {}}


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
    # Per-run toggles, generic across connectors:
    #   stock_source: "snapshot" | "reconstruct" | "none" — how stock on hand is
    #     established (see `reconstruct.resolve_stock_source`)
    #   keep_file: bool — skip the post-import purge (operators re-running from
    #     the command line against one staged copy)
    options = models.JSONField(default=dict, blank=True)
    progress_percent = models.PositiveSmallIntegerField(
        default=0,
        validators=[MaxValueValidator(100)],
    )
    progress_message = models.CharField(max_length=240, blank=True)
    current_entity = models.CharField(max_length=48, blank=True)
    #: Per-stage timeline (see `preparation.stages`) — one entry per entity plus
    #: the framing stages. An import that walks 900,000 sale lines needs to show
    #: *what* it is doing, not just how far along a single bar has crept.
    stages = models.JSONField(default=list, blank=True, db_default=[])
    # Per-entity aggregate counts:
    # {"product": {"created": 10, "updated": 2, "skipped": 0, "failed": 1}, ...}
    summary = models.JSONField(default=dict, blank=True)
    error_message = models.TextField(blank=True, db_default="")
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
