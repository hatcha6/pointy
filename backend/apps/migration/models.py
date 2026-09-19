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


class CollapsePlan(TimeStampedModel):
    """A proposal to turn "one product per handset" back into stock (§12).

    The prospect's catalogue is 340 products that are really 340 *units* of a
    dozen products. This row is what that observation looks like before anybody
    has agreed to it: built from the file, reviewed one line at a time, approved
    by the owner, and only then handed to an import run.

    It is deliberately a **document rather than a switch**. A collapse rewrites
    what a shop's catalogue means, and the difference between a tool that a shop
    trusts with four years of history and one it does not is that this one shows
    its work first — every row, what it read out of the name, and how sure it
    was — and writes nothing until somebody says yes.
    """

    class Status(models.TextChoices):
        QUEUED = "queued", "Queued"
        RUNNING = "running", "Reading the catalogue"
        # Built and waiting for a person.
        READY = "ready", "Ready to review"
        FAILED = "failed", "Failed"
        # A person said yes. The next import run may use it.
        APPROVED = "approved", "Approved"
        # An import run used it. Terminal, and the goal.
        APPLIED = "applied", "Applied"
        # A newer plan was built for the same file.
        SUPERSEDED = "superseded", "Superseded"

    #: Statuses a run may be launched against. ``applied`` is in the list
    #: because re-running an import is the ordinary way to finish one that came
    #: back partial, and the plan being applied already is exactly the state it
    #: is in by then — the identity map makes the second pass an update.
    USABLE = (Status.APPROVED, Status.APPLIED)

    source = models.ForeignKey(
        MigrationSource,
        on_delete=models.CASCADE,
        related_name="collapse_plans",
    )
    status = models.CharField(
        max_length=16,
        choices=Status.choices,
        default=Status.QUEUED,
        db_index=True,
    )
    #: Build timeline, same shape as the preparation stages.
    stages = models.JSONField(default=list, blank=True, db_default=[])
    error_message = models.TextField(blank=True, db_default="")

    #: What kind of identified thing these become — the shop-editable registry
    #: the workshop side already maintains, so a migrated handset's intake sheet
    #: is the one the shop already uses. Chosen by the builder from what the
    #: identifiers turned out to be, and editable before approval.
    asset_type = models.ForeignKey(
        "customers.AssetType",
        on_delete=models.SET_NULL,
        null=True,
        blank=True,
        related_name="collapse_plans",
    )
    #: Warranty granted on sale for every product the collapse creates, in days.
    warranty_days = models.PositiveIntegerField(default=0, db_default=0)

    #: Headline counts — "340 products → 12 products, 31 variants, 340 units".
    #: Recomputed from the candidate rows whenever one is edited, so the number
    #: on the screen is never a memory of an earlier answer.
    stats = models.JSONField(default=dict, blank=True, db_default={})

    built_at = models.DateTimeField(blank=True, null=True)
    approved_at = models.DateTimeField(blank=True, null=True)
    approved_by_user_id = models.PositiveBigIntegerField(blank=True, null=True)
    approved_by_username = models.CharField(max_length=150, blank=True, db_default="")
    applied_run = models.ForeignKey(
        MigrationRun,
        on_delete=models.SET_NULL,
        blank=True,
        null=True,
        related_name="collapse_plans",
    )

    class Meta:
        ordering = ["-created_at"]
        indexes = [models.Index(fields=["source", "-created_at"])]

    def __str__(self):
        return f"collapse #{self.pk} ({self.status})"

    @property
    def is_active(self):
        return self.status in {self.Status.QUEUED, self.Status.RUNNING}

    @property
    def is_editable(self):
        """Can a person still change what this says?

        Approval is the line. Afterwards the plan is a record of what was
        agreed, and an edit would make the import disagree with the screen the
        owner looked at.
        """
        return self.status == self.Status.READY


class CollapseCandidate(TimeStampedModel):
    """One legacy product, and what the collapse proposes to make of it.

    The unit of review and the unit of editing: a person disagreeing with the
    parser disagrees about *one handset*, and says so by changing this row.
    Clusters are derived by grouping on :attr:`stem_key` rather than stored,
    which is what makes "merge these two into one product" an edit to a name
    instead of a second table to keep in step.
    """

    class Decision(models.TextChoices):
        # Becomes a unit of a collapsed product.
        COLLAPSE = "collapse", "Collapse into a unit"
        # Stays an ordinary product, exactly as it is today. §12.4's escape
        # hatch, and the default for anything the parser could not read.
        KEEP = "keep", "Keep as a product"

    class UnitStatus(models.TextChoices):
        IN_STOCK = "in_stock", "In stock"
        SOLD = "sold", "Sold"

    plan = models.ForeignKey(
        CollapsePlan,
        on_delete=models.CASCADE,
        related_name="candidates",
    )
    #: The legacy product's key in the source system — the join to everything
    #: the import does with it.
    source_key = models.CharField(max_length=255)
    #: Its name, verbatim, because the review screen has to show what was read.
    source_name = models.CharField(max_length=255, blank=True, db_default="")
    #: The sellable row under it. Equal to ``source_key`` for the flat systems
    #: this is really about; a separate key for a source that keeps a variant
    #: table, because that is the key its invoices name.
    variant_source_key = models.CharField(max_length=255, blank=True, db_default="")
    #: The shelf label the old system printed for this handset. Carried onto the
    #: unit as its secondary code, so four years of printed barcodes keep
    #: scanning and keep resolving to the right article.
    legacy_barcode = models.CharField(max_length=64, blank=True, db_default="")

    decision = models.CharField(
        max_length=12,
        choices=Decision.choices,
        default=Decision.COLLAPSE,
        db_index=True,
    )
    #: The product this becomes part of, as it will be named.
    stem = models.CharField(max_length=255, blank=True, db_default="")
    #: Its comparison form. Two candidates sharing this share a product.
    stem_key = models.CharField(max_length=255, blank=True, db_default="", db_index=True)

    identifier = models.CharField(max_length=120, blank=True, db_default="")
    identifier_kind = models.CharField(max_length=16, blank=True, db_default="")
    #: ``{"storage": "256GB", "colour": "blue"}`` — the variant's axes.
    options = models.JSONField(default=dict, blank=True, db_default={})
    #: ``{"battery_health": 86, "condition_grade": "a"}`` — this article's own
    #: facts, written onto the unit.
    attributes = models.JSONField(default=dict, blank=True, db_default={})

    unit_status = models.CharField(
        max_length=12,
        choices=UnitStatus.choices,
        default=UnitStatus.IN_STOCK,
    )
    unit_cost = models.DecimalField(max_digits=18, decimal_places=6, default=0, db_default=0)
    list_price = models.DecimalField(
        max_digits=10, decimal_places=2, blank=True, null=True
    )
    sold_price = models.DecimalField(
        max_digits=10, decimal_places=2, blank=True, null=True
    )
    acquired_at = models.DateTimeField(blank=True, null=True)
    sold_at = models.DateTimeField(blank=True, null=True)
    #: Source keys, resolved to Pointy rows through the identity map at apply
    #: time — the supplier it came from, the invoice it left on, and who bought
    #: it. This is the difference between importing units and importing history.
    supplier_source_key = models.CharField(max_length=255, blank=True, db_default="")
    sale_source_key = models.CharField(max_length=255, blank=True, db_default="")

    #: 0–1. Drives the review order: least sure first, because those are the
    #: rows a person can actually help with.
    confidence = models.DecimalField(max_digits=3, decimal_places=2, default=0)
    #: Machine codes explaining the confidence (``imei_check_digit_failed``,
    #: ``singleton_cluster``, …). The client turns them into sentences.
    reasons = models.JSONField(default=list, blank=True, db_default=[])
    #: Set when a person changed this row, so a rebuild can say what it would
    #: overwrite and the summary can say how much of this was human.
    edited = models.BooleanField(default=False, db_default=False)

    class Meta:
        ordering = ["confidence", "stem_key", "id"]
        constraints = [
            models.UniqueConstraint(
                fields=["plan", "source_key"],
                name="uniq_collapse_candidate_per_plan",
            )
        ]
        indexes = [
            models.Index(fields=["plan", "confidence", "id"]),
            models.Index(fields=["plan", "stem_key"]),
            models.Index(fields=["plan", "decision"]),
        ]

    def __str__(self):
        return f"{self.source_name} -> {self.stem} / {self.identifier}"

    @property
    def is_sold(self) -> bool:
        return self.unit_status == self.UnitStatus.SOLD

    @property
    def needs_review(self) -> bool:
        """Low enough that a person should look at it before approving."""
        from .collapse.extract import LOW_CONFIDENCE

        return (
            self.decision == self.Decision.COLLAPSE
            and float(self.confidence) < LOW_CONFIDENCE
        )
