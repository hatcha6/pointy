from django.conf import settings
from django.db import models
from django.db.models import Q

from apps.core.models import TimeStampedModel
from apps.sales.models import Order


class PrintTemplate(TimeStampedModel):
    class Type(models.TextChoices):
        RECEIPT = "receipt", "Receipt"

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
