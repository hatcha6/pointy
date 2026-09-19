import secrets
from datetime import timedelta
from decimal import Decimal

from django.conf import settings
from django.core.validators import MinValueValidator
from django.db import models, transaction
from django.utils import timezone

from apps.catalog.models import BillOfMaterials, ProductVariant
from apps.core.models import TimeStampedModel
from apps.customers.models import Asset, Customer

JOB_NUMBER_PREFIXES = {
    "repair": "REP",
    "production": "PRD",
    "kitchen": "KIT",
    "work_order": "WRK",
}


class WorkflowTemplate(TimeStampedModel):
    """An ordered set of stages a job moves through.

    Templates are data, not code: a repair shop, a bakery, and a restaurant
    are different templates over the same engine. The seeded defaults are
    marked ``is_system`` so a shop cannot delete its last usable workflow.
    """

    class JobType(models.TextChoices):
        REPAIR = "repair", "Repair order"
        PRODUCTION = "production", "Production batch"
        KITCHEN = "kitchen", "Kitchen order"
        WORK_ORDER = "work_order", "Work order"

    name = models.CharField(max_length=120)
    job_type = models.CharField(max_length=24, choices=JobType.choices)
    is_active = models.BooleanField(default=True)
    is_system = models.BooleanField(default=False)

    class Meta:
        ordering = ["job_type", "name"]

    def __str__(self) -> str:
        return self.name

    def initial_stage(self):
        return self.stages.filter(is_initial=True).order_by("display_order").first()


class WorkflowStage(TimeStampedModel):
    template = models.ForeignKey(
        WorkflowTemplate,
        on_delete=models.CASCADE,
        related_name="stages",
    )
    code = models.SlugField(max_length=48, allow_unicode=True)
    name = models.CharField(max_length=120)
    display_order = models.PositiveIntegerField(default=0)
    is_initial = models.BooleanField(default=False)
    is_terminal = models.BooleanField(default=False)
    # Forward moves *out of* this stage require an approved price on the job.
    requires_customer_approval = models.BooleanField(default=False)
    # Moves *into* this stage require the job to be settled: invoiced, and
    # either paid in full or booked to an آجل invoice against a customer.
    #
    # Note the deliberate asymmetry with ``requires_customer_approval`` above:
    # approval gates *leaving* (you may sit in "awaiting approval" as long as
    # you like, you just cannot move on), settlement gates *entering* (you may
    # sit in "ready for pickup" as long as you like, you just cannot hand the
    # customer's property back). Each is stated where a shop reads it.
    requires_settlement = models.BooleanField(default=False)
    # Entering this stage hands the customer's property back: it stamps
    # ``Job.handed_over_at`` and ends the shop's custody of the job's assets.
    releases_custody = models.BooleanField(default=False)
    # Entering this stage consumes the job's pending materials.
    consumes_materials = models.BooleanField(default=False)
    # Entering this stage receives the job's output into stock (production).
    produces_output = models.BooleanField(default=False)

    class Meta:
        ordering = ["display_order", "id"]
        constraints = [
            models.UniqueConstraint(
                fields=["template", "code"],
                name="unique_stage_code_per_template",
            )
        ]

    def __str__(self) -> str:
        return f"{self.template.name}: {self.name}"


class Job(TimeStampedModel):
    """A unit of operational work: a repair, a production batch, a kitchen order.

    The channel is stamped from the request credentials (same rule as orders)
    and money only ever leaves through a normal ``sales.Order``, so register
    reconciliation and the blind close are untouched by operations work.
    """

    class Status(models.TextChoices):
        OPEN = "open", "Open"
        COMPLETED = "completed", "Completed"
        CANCELLED = "cancelled", "Cancelled"

    class Priority(models.TextChoices):
        LOW = "low", "Low"
        NORMAL = "normal", "Normal"
        HIGH = "high", "High"
        URGENT = "urgent", "Urgent"

    job_number = models.CharField(max_length=32, unique=True, blank=True)
    job_type = models.CharField(max_length=24, choices=WorkflowTemplate.JobType.choices)
    workflow_template = models.ForeignKey(
        WorkflowTemplate,
        on_delete=models.PROTECT,
        related_name="jobs",
    )
    current_stage = models.ForeignKey(
        WorkflowStage,
        on_delete=models.PROTECT,
        related_name="jobs_in_stage",
    )
    status = models.CharField(max_length=16, choices=Status.choices, default=Status.OPEN)
    customer = models.ForeignKey(
        Customer,
        on_delete=models.SET_NULL,
        related_name="jobs",
        blank=True,
        null=True,
    )
    assigned_to = models.ForeignKey(
        settings.AUTH_USER_MODEL,
        on_delete=models.SET_NULL,
        related_name="assigned_jobs",
        blank=True,
        null=True,
    )
    # Who gets credited for the work (drives operations-commission pay). Kept in
    # sync with ``assigned_to`` when the employee has a linked user account, but
    # works for technicians who never log in too.
    assigned_employee = models.ForeignKey(
        "employees.Employee",
        on_delete=models.SET_NULL,
        related_name="assigned_jobs",
        blank=True,
        null=True,
    )
    priority = models.CharField(
        max_length=16,
        choices=Priority.choices,
        default=Priority.NORMAL,
    )
    due_at = models.DateTimeField(blank=True, null=True)
    completed_at = models.DateTimeField(blank=True, null=True)
    cancelled_at = models.DateTimeField(blank=True, null=True)
    # Custody: when the customer's property actually went back to them, and who
    # physically collected it ("his brother came for it" is the norm here). A
    # job can be paid for days before this happens — a repaired car sits in the
    # yard — so handover is its own fact, never inferred from payment.
    handed_over_at = models.DateTimeField(blank=True, null=True)
    handed_over_to = models.CharField(max_length=120, blank=True)
    # Hold: work stopped for a reason outside the shop's control, almost always
    # a part on order. Held time is accumulated into ``held_seconds`` on resume
    # so a job's age can be read without counting the wait as workshop time.
    on_hold_since = models.DateTimeField(blank=True, null=True)
    hold_reason = models.CharField(max_length=200, blank=True)
    held_seconds = models.PositiveIntegerField(default=0)
    symptoms = models.TextField(blank=True)
    diagnosis = models.TextField(blank=True)
    technician_notes = models.TextField(blank=True)
    quoted_price = models.DecimalField(
        max_digits=10,
        decimal_places=2,
        blank=True,
        null=True,
        validators=[MinValueValidator(Decimal("0.00"))],
    )
    approved_price = models.DecimalField(
        max_digits=10,
        decimal_places=2,
        blank=True,
        null=True,
        validators=[MinValueValidator(Decimal("0.00"))],
    )
    warranty_days = models.PositiveIntegerField(default=0)
    # Refurbishment: the article on the shop's own shelf that this work is being
    # done to, as opposed to ``job_assets``, which are the customer's property.
    # A used-goods trader buys a handset at 1200, spends 150 on a screen, and
    # must not then sell it at 1300 — so when a job with this target completes,
    # its materials and labour capitalise into ``StockUnit.refurb_cost`` and the
    # loss guard starts comparing the asking price against the truth.
    stock_unit = models.ForeignKey(
        "inventory.StockUnit",
        on_delete=models.SET_NULL,
        related_name="refurb_jobs",
        blank=True,
        null=True,
    )
    #: What this job actually capitalised, stamped when it completed. Stored so
    #: reopening or re-completing a job cannot add the same 150 twice.
    capitalised_cost = models.DecimalField(max_digits=12, decimal_places=2, default=0)
    capitalised_at = models.DateTimeField(blank=True, null=True)
    # Production fields: what this job produces, and at what computed cost.
    bom = models.ForeignKey(
        BillOfMaterials,
        on_delete=models.SET_NULL,
        related_name="jobs",
        blank=True,
        null=True,
    )
    output_variant = models.ForeignKey(
        ProductVariant,
        on_delete=models.PROTECT,
        related_name="production_jobs",
        blank=True,
        null=True,
    )
    output_quantity = models.PositiveIntegerField(blank=True, null=True)
    output_unit_cost = models.DecimalField(
        max_digits=10,
        decimal_places=2,
        blank=True,
        null=True,
    )
    output_received_at = models.DateTimeField(blank=True, null=True)
    sales_channel = models.ForeignKey(
        "channels.SalesChannel",
        on_delete=models.PROTECT,
        related_name="jobs",
        blank=True,
        null=True,
    )
    order = models.ForeignKey(
        "sales.Order",
        on_delete=models.PROTECT,
        related_name="jobs",
        blank=True,
        null=True,
    )
    public_token = models.CharField(max_length=64, unique=True, blank=True, null=True)
    created_by = models.ForeignKey(
        settings.AUTH_USER_MODEL,
        on_delete=models.SET_NULL,
        related_name="created_jobs",
        blank=True,
        null=True,
    )

    class Meta:
        ordering = ["-created_at"]
        # The jobs board lists by status ordered by -created_at; this composite
        # serves the (usually open) board plus the default listing as completed
        # history grows (mirrors sales.Order's status/created index).
        indexes = [
            models.Index(
                fields=["status", "-created_at"],
                name="job_status_created_idx",
            ),
        ]
        permissions = [
            ("approve_job_quote", "Can approve a job quote"),
            ("reopen_job", "Can reopen a completed or cancelled job"),
            ("assign_job", "Can assign jobs to users"),
            (
                "release_unpaid_job",
                "Can hand a job's property back before it is settled",
            ),
        ]

    def __str__(self) -> str:
        return self.job_number or f"Job {self.pk}"

    @property
    def is_locked(self) -> bool:
        return self.status != self.Status.OPEN

    @property
    def is_on_hold(self) -> bool:
        return self.on_hold_since is not None

    @property
    def settlement_state(self) -> str:
        """Where this job stands with money, derived — never stored.

        The order is the single source of truth (``amount_paid`` /
        ``balance_due`` already net refunds), so this can never drift from what
        the customer actually owes.
        """
        order = self.order
        if order is None:
            return "not_invoiced"
        if order.balance_due <= Decimal("0.00"):
            return "settled"
        if order.amount_paid > Decimal("0.00"):
            return "deposit_paid"
        return "credit_open"

    @property
    def custody_state(self) -> str:
        return "released" if self.handed_over_at is not None else "with_shop"

    @property
    def warranty_expires_on(self):
        """The day this repair's warranty runs out, or None if it has none.

        Counted from the handover, not the invoice: the customer's cover starts
        when they get the thing back. Derived rather than stored, so a corrected
        ``warranty_days`` or a reopened job cannot leave a stale date behind.
        """
        if self.warranty_days <= 0 or self.handed_over_at is None:
            return None
        return timezone.localtime(self.handed_over_at).date() + timedelta(
            days=self.warranty_days
        )

    @property
    def is_under_warranty(self) -> bool:
        """Is this repair still covered today?

        The comparison ERPNext's Serial No makes for "Under Warranty" vs "Out of
        Warranty" — expiry on or after today is still covered — applied to the
        repair rather than to a stock serial, because the cover a shop gives is
        on the work it did, not on the item.
        """
        expiry = self.warranty_expires_on
        return expiry is not None and expiry >= timezone.localdate()

    def save(self, *args, **kwargs):
        update_fields = kwargs.get("update_fields")
        if not self.public_token:
            self.public_token = self._generate_public_token()
            if update_fields is not None and "public_token" not in update_fields:
                kwargs["update_fields"] = [*update_fields, "public_token"]
        if not self.job_number:
            with transaction.atomic():
                super().save(*args, **kwargs)
                prefix = JOB_NUMBER_PREFIXES.get(self.job_type, "JOB")
                self.job_number = f"{prefix}-{self.created_at:%Y%m%d}-{self.id:06d}"
                return super().save(update_fields=["job_number", "public_token"])
        return super().save(*args, **kwargs)

    @classmethod
    def _generate_public_token(cls) -> str:
        while True:
            token = secrets.token_urlsafe(24)
            if not cls.objects.filter(public_token=token).exists():
                return token


class JobStageEvent(TimeStampedModel):
    job = models.ForeignKey(Job, on_delete=models.CASCADE, related_name="stage_events")
    from_stage = models.ForeignKey(
        WorkflowStage,
        on_delete=models.SET_NULL,
        related_name="+",
        blank=True,
        null=True,
    )
    to_stage = models.ForeignKey(
        WorkflowStage,
        on_delete=models.PROTECT,
        related_name="+",
    )
    changed_by = models.ForeignKey(
        settings.AUTH_USER_MODEL,
        on_delete=models.SET_NULL,
        related_name="+",
        blank=True,
        null=True,
    )
    note = models.TextField(blank=True)

    class Meta:
        ordering = ["created_at", "id"]

    def __str__(self) -> str:
        return f"{self.job_id}: → {self.to_stage_id}"


class JobAsset(TimeStampedModel):
    job = models.ForeignKey(Job, on_delete=models.CASCADE, related_name="job_assets")
    asset = models.ForeignKey(Asset, on_delete=models.PROTECT, related_name="job_links")

    class Meta:
        constraints = [
            models.UniqueConstraint(fields=["job", "asset"], name="unique_asset_per_job")
        ]

    def __str__(self) -> str:
        return f"{self.job_id} ↔ {self.asset_id}"


class JobService(TimeStampedModel):
    """Priced work done on a job: a diagnosis fee, an oil change, a screen swap.

    Deliberately a separate table from :class:`JobMaterial` rather than a flag on
    it. Two reasons, both load-bearing:

    * ``_commissionable_jobs_total(..., base="labor")`` in
      ``apps/employees/services.py`` computes a technician's labour as
      ``approved_price − consumed parts at sale price``. Folding services into
      materials would silently subtract them as parts and under-pay every
      technician on a commission plan.
    * Services point at ``Product.is_service`` variants, which hold no stock, so
      none of the consume / reverse / stock-movement machinery applies. There is
      nothing to reverse — a service line is added or removed, full stop.
    """

    job = models.ForeignKey(Job, on_delete=models.CASCADE, related_name="services")
    variant = models.ForeignKey(
        ProductVariant,
        on_delete=models.PROTECT,
        related_name="job_services",
    )
    quantity = models.DecimalField(
        max_digits=10,
        decimal_places=3,
        default=Decimal("1"),
        validators=[MinValueValidator(Decimal("0.001"))],
    )
    # Snapshot at the moment the service was added, like OrderLine.unit_price:
    # re-pricing the catalog tomorrow must not silently re-price yesterday's
    # agreed repair.
    unit_price = models.DecimalField(max_digits=10, decimal_places=2, default=0)
    note = models.CharField(max_length=200, blank=True)
    added_by = models.ForeignKey(
        settings.AUTH_USER_MODEL,
        on_delete=models.SET_NULL,
        related_name="+",
        blank=True,
        null=True,
    )

    class Meta:
        ordering = ["created_at", "id"]

    def __str__(self) -> str:
        return f"{self.job_id}: {self.variant_id} ×{self.quantity}"

    @property
    def line_total(self):
        return (self.unit_price * self.quantity).quantize(Decimal("0.01"))


class JobMaterial(TimeStampedModel):
    """A part or ingredient used by a job.

    Pending until ``consumed_at`` is set; consumption and reversal go through
    the same inventory services the register uses, so stock movements stay a
    single audited stream.
    """

    job = models.ForeignKey(Job, on_delete=models.CASCADE, related_name="materials")
    variant = models.ForeignKey(
        ProductVariant,
        on_delete=models.PROTECT,
        related_name="job_materials",
    )
    quantity = models.DecimalField(
        max_digits=10,
        decimal_places=3,
        validators=[MinValueValidator(Decimal("0.001"))],
    )
    unit_cost = models.DecimalField(max_digits=10, decimal_places=2, default=0)
    unit_price = models.DecimalField(max_digits=10, decimal_places=2, default=0)
    #: The serialized part that was fitted, when the part has a number of its
    #: own. Which screen went into which handset is exactly the question a
    #: warranty claim asks six months later, and the job consuming it is the
    #: last moment anybody can answer it (§6.7). Null for everything counted by
    #: quantity, which is most materials in most shops.
    stock_unit = models.ForeignKey(
        "inventory.StockUnit",
        on_delete=models.PROTECT,
        related_name="consumed_by_jobs",
        blank=True,
        null=True,
    )
    #: The lot it came out of, for a batch-tracked material. Left to FEFO when
    #: nobody said otherwise, which is what the shelf itself would have handed
    #: over.
    batch = models.ForeignKey(
        "inventory.StockBatch",
        on_delete=models.PROTECT,
        related_name="consumed_by_jobs",
        blank=True,
        null=True,
    )
    consumed_at = models.DateTimeField(blank=True, null=True)
    reversed_at = models.DateTimeField(blank=True, null=True)
    stock_movement = models.ForeignKey(
        "inventory.StockMovement",
        on_delete=models.PROTECT,
        related_name="+",
        blank=True,
        null=True,
    )
    reversal_movement = models.ForeignKey(
        "inventory.StockMovement",
        on_delete=models.PROTECT,
        related_name="+",
        blank=True,
        null=True,
    )
    added_by = models.ForeignKey(
        settings.AUTH_USER_MODEL,
        on_delete=models.SET_NULL,
        related_name="+",
        blank=True,
        null=True,
    )

    class Meta:
        ordering = ["created_at", "id"]

    def __str__(self) -> str:
        return f"{self.job_id}: {self.variant_id} ×{self.quantity}"

    @property
    def is_consumed(self) -> bool:
        return self.consumed_at is not None and self.reversed_at is None
