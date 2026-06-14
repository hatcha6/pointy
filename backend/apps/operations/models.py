import secrets
from decimal import Decimal

from django.conf import settings
from django.core.validators import MinValueValidator
from django.db import models, transaction

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
    # Forward moves past this stage require an approved price on the job.
    requires_customer_approval = models.BooleanField(default=False)
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
        permissions = [
            ("approve_job_quote", "Can approve a job quote"),
            ("reopen_job", "Can reopen a completed or cancelled job"),
            ("assign_job", "Can assign jobs to users"),
        ]

    def __str__(self) -> str:
        return self.job_number or f"Job {self.pk}"

    @property
    def is_locked(self) -> bool:
        return self.status != self.Status.OPEN

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
