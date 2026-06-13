from django.conf import settings
from django.db import models
from django.db.models import Q

from apps.core.models import TimeStampedModel
from apps.purchasing.models import PurchaseOrder
from apps.sales.models import Order


class PrintTemplate(TimeStampedModel):
    class Type(models.TextChoices):
        RECEIPT = "receipt", "Receipt"
        KITCHEN = "kitchen", "Kitchen ticket"

    slug = models.SlugField(max_length=80, unique=True)
    name = models.CharField(max_length=120)
    template_type = models.CharField(
        max_length=32,
        choices=Type.choices,
        default=Type.RECEIPT,
    )
    description = models.TextField(blank=True)
    is_active = models.BooleanField(default=True)
    current_version = models.ForeignKey(
        "PrintTemplateVersion",
        on_delete=models.SET_NULL,
        related_name="+",
        blank=True,
        null=True,
    )

    class Meta:
        ordering = ["slug"]

    def __str__(self) -> str:
        return self.name


class PrintTemplateVersion(TimeStampedModel):
    class Status(models.TextChoices):
        DRAFT = "draft", "Draft"
        PUBLISHED = "published", "Published"

    template = models.ForeignKey(
        PrintTemplate,
        on_delete=models.CASCADE,
        related_name="versions",
    )
    version_number = models.PositiveIntegerField()
    status = models.CharField(
        max_length=16,
        choices=Status.choices,
        default=Status.DRAFT,
    )
    content = models.TextField(blank=True)
    schema = models.JSONField(default=dict, blank=True)
    created_by = models.ForeignKey(
        settings.AUTH_USER_MODEL,
        on_delete=models.SET_NULL,
        related_name="print_template_versions",
        blank=True,
        null=True,
    )
    published_at = models.DateTimeField(blank=True, null=True)

    class Meta:
        ordering = ["template__slug", "-version_number"]
        constraints = [
            models.UniqueConstraint(
                fields=["template", "version_number"],
                name="unique_print_template_version_number",
            )
        ]

    def __str__(self) -> str:
        return f"{self.template.slug} v{self.version_number}"


class PrinterProfile(TimeStampedModel):
    class Type(models.TextChoices):
        ESCPOS = "escpos", "ESC/POS"
        PDF = "pdf", "PDF"
        RAW = "raw", "Raw"

    name = models.CharField(max_length=120, unique=True)
    printer_type = models.CharField(
        max_length=32,
        choices=Type.choices,
        default=Type.ESCPOS,
    )
    settings = models.JSONField(default=dict, blank=True)
    is_default = models.BooleanField(default=False)
    is_active = models.BooleanField(default=True)

    class Meta:
        ordering = ["name"]
        constraints = [
            models.UniqueConstraint(
                fields=["is_default"],
                condition=Q(is_default=True),
                name="unique_default_printer_profile",
            )
        ]

    def __str__(self) -> str:
        return self.name


class PrepStation(TimeStampedModel):
    """A kitchen/production station (grill, bar, pastry, ...) that prints the
    made-to-order lines routed to it. A station binds to a PrinterProfile (the
    physical destination) and owns a set of product categories; a prepared line
    whose product is in any of those categories prints here. Exactly one station
    may be the default catch-all for lines that match no station's categories.
    """

    name = models.CharField(max_length=120, unique=True)
    printer_profile = models.ForeignKey(
        PrinterProfile,
        on_delete=models.PROTECT,
        related_name="prep_stations",
        blank=True,
        null=True,
    )
    categories = models.ManyToManyField(
        "catalog.ProductCategory",
        related_name="prep_stations",
        blank=True,
    )
    is_default = models.BooleanField(default=False)
    is_active = models.BooleanField(default=True)
    priority = models.IntegerField(default=0)

    class Meta:
        ordering = ["name"]
        constraints = [
            models.UniqueConstraint(
                fields=["is_default"],
                condition=Q(is_default=True),
                name="unique_default_prep_station",
            )
        ]

    def __str__(self) -> str:
        return self.name


class PrintAgent(TimeStampedModel):
    name = models.CharField(max_length=120)
    identifier = models.SlugField(max_length=80, unique=True)
    printer_profile = models.ForeignKey(
        PrinterProfile,
        on_delete=models.SET_NULL,
        related_name="agents",
        blank=True,
        null=True,
    )
    is_active = models.BooleanField(default=True)
    last_seen_at = models.DateTimeField(blank=True, null=True)

    class Meta:
        ordering = ["name"]

    def __str__(self) -> str:
        return self.name


class PrintJob(TimeStampedModel):
    class Type(models.TextChoices):
        RECEIPT = "receipt", "Receipt"
        KITCHEN = "kitchen", "Kitchen ticket"

    class Status(models.TextChoices):
        QUEUED = "queued", "Queued"
        CLAIMED = "claimed", "Claimed"
        PRINTED = "printed", "Printed"
        FAILED = "failed", "Failed"
        CANCELED = "canceled", "Canceled"

    job_type = models.CharField(max_length=32, choices=Type.choices, default=Type.RECEIPT)
    status = models.CharField(
        max_length=16,
        choices=Status.choices,
        default=Status.QUEUED,
        db_index=True,
    )
    order = models.ForeignKey(
        Order,
        on_delete=models.PROTECT,
        related_name="print_jobs",
        blank=True,
        null=True,
    )
    template_version = models.ForeignKey(
        PrintTemplateVersion,
        on_delete=models.PROTECT,
        related_name="jobs",
    )
    printer_profile = models.ForeignKey(
        PrinterProfile,
        on_delete=models.SET_NULL,
        related_name="jobs",
        blank=True,
        null=True,
    )
    prep_station = models.ForeignKey(
        "PrepStation",
        on_delete=models.SET_NULL,
        related_name="print_jobs",
        blank=True,
        null=True,
    )
    payload = models.JSONField(default=dict)
    idempotency_key = models.CharField(max_length=160, unique=True)
    priority = models.IntegerField(default=0)
    attempts = models.PositiveIntegerField(default=0)
    claimed_by = models.ForeignKey(
        PrintAgent,
        on_delete=models.SET_NULL,
        related_name="claimed_jobs",
        blank=True,
        null=True,
    )
    claimed_at = models.DateTimeField(blank=True, null=True)
    lease_expires_at = models.DateTimeField(blank=True, null=True, db_index=True)
    printed_at = models.DateTimeField(blank=True, null=True)
    failed_at = models.DateTimeField(blank=True, null=True)
    error_message = models.TextField(blank=True)

    class Meta:
        ordering = ["-priority", "created_at"]

    def __str__(self) -> str:
        return f"{self.job_type} {self.status} #{self.pk}"


class PrintJobEvent(models.Model):
    class Type(models.TextChoices):
        CREATED = "created", "Created"
        CLAIMED = "claimed", "Claimed"
        PRINTED = "printed", "Printed"
        FAILED = "failed", "Failed"
        REQUEUED = "requeued", "Requeued"
        CANCELED = "canceled", "Canceled"

    job = models.ForeignKey(PrintJob, on_delete=models.CASCADE, related_name="events")
    event_type = models.CharField(max_length=32, choices=Type.choices)
    user = models.ForeignKey(
        settings.AUTH_USER_MODEL,
        on_delete=models.SET_NULL,
        related_name="print_job_events",
        blank=True,
        null=True,
    )
    agent = models.ForeignKey(
        PrintAgent,
        on_delete=models.SET_NULL,
        related_name="events",
        blank=True,
        null=True,
    )
    message = models.TextField(blank=True)
    metadata = models.JSONField(default=dict, blank=True)
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        ordering = ["created_at", "id"]

    def __str__(self) -> str:
        return f"{self.event_type} for job {self.job_id}"


class PrintAuditEvent(TimeStampedModel):
    class DocumentType(models.TextChoices):
        SALE_ORDER = "sale_order", "Sale order"
        PURCHASE_ORDER = "purchase_order", "Purchase order"

    class Action(models.TextChoices):
        PRINT = "print", "Print"
        SHARE = "share", "Share"

    class Status(models.TextChoices):
        REQUESTED = "requested", "Requested"
        COMPLETED = "completed", "Completed"
        CANCELED = "canceled", "Canceled"
        FAILED = "failed", "Failed"

    document_type = models.CharField(max_length=32, choices=DocumentType.choices)
    action = models.CharField(max_length=16, choices=Action.choices)
    status = models.CharField(
        max_length=16,
        choices=Status.choices,
        default=Status.REQUESTED,
        db_index=True,
    )
    sale_order = models.ForeignKey(
        Order,
        on_delete=models.SET_NULL,
        related_name="print_audit_events",
        blank=True,
        null=True,
    )
    purchase_order = models.ForeignKey(
        PurchaseOrder,
        on_delete=models.SET_NULL,
        related_name="print_audit_events",
        blank=True,
        null=True,
    )
    document_number = models.CharField(max_length=64, db_index=True)
    print_job = models.ForeignKey(
        PrintJob,
        on_delete=models.SET_NULL,
        related_name="document_audit_events",
        blank=True,
        null=True,
    )
    user = models.ForeignKey(
        settings.AUTH_USER_MODEL,
        on_delete=models.SET_NULL,
        related_name="print_audit_events",
        blank=True,
        null=True,
    )
    agent = models.ForeignKey(
        PrintAgent,
        on_delete=models.SET_NULL,
        related_name="audit_events",
        blank=True,
        null=True,
    )
    agent_identifier = models.CharField(max_length=120, blank=True)
    device_name = models.CharField(max_length=160, blank=True)
    printer_name = models.CharField(max_length=160, blank=True)
    printer_endpoint = models.JSONField(default=dict, blank=True)
    message = models.TextField(blank=True)
    metadata = models.JSONField(default=dict, blank=True)

    class Meta:
        ordering = ["-created_at", "-id"]
        indexes = [
            models.Index(
                fields=["document_type", "sale_order", "-created_at"],
                name="print_audit_sale_doc_idx",
            ),
            models.Index(
                fields=["document_type", "purchase_order", "-created_at"],
                name="print_audit_purchase_idx",
            ),
        ]

    def __str__(self) -> str:
        return f"{self.action} {self.status} {self.document_number}"
