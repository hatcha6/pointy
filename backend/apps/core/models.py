from datetime import time

from django.conf import settings as django_settings
from django.core.validators import MaxValueValidator, MinValueValidator
from django.db import models
from django.utils import timezone


class TimeStampedModel(models.Model):
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        abstract = True


class IdempotencyRecord(TimeStampedModel):
    key = models.CharField(max_length=180)
    owner_key = models.CharField(max_length=128, db_index=True)
    method = models.CharField(max_length=12)
    path = models.CharField(max_length=512)
    request_hash = models.CharField(max_length=64)
    response_status_code = models.PositiveSmallIntegerField(blank=True, null=True)
    response_data = models.JSONField(blank=True, null=True)
    replay_count = models.PositiveIntegerField(default=0)
    completed_at = models.DateTimeField(blank=True, null=True)

    class Meta:
        ordering = ["-created_at"]
        constraints = [
            models.UniqueConstraint(
                fields=["owner_key", "method", "path", "key"],
                name="unique_idempotency_record_per_request_scope",
            )
        ]
        indexes = [
            models.Index(fields=["owner_key", "key"]),
            models.Index(fields=["method", "path"]),
        ]

    def __str__(self):
        return f"{self.owner_key} {self.method} {self.path} {self.key}"


class ShopSettings(TimeStampedModel):
    shop_name = models.CharField(max_length=120, default="نقطة البيع")
    receipt_header = models.CharField(max_length=240, blank=True)
    receipt_footer = models.CharField(max_length=240, blank=True)
    enable_online_invoices = models.BooleanField(default=False)
    # Operations modes: which job workflows this shop uses. All off by default
    # so a pure retail shop never sees the feature.
    enable_repair_operations = models.BooleanField(default=False)
    enable_production_operations = models.BooleanField(default=False)
    enable_kitchen_operations = models.BooleanField(default=False)
    # Public job tracking page (relay-gated), like online invoices.
    enable_job_tracking = models.BooleanField(default=False)
    require_opening_cash = models.BooleanField(default=True)
    auto_print_receipts = models.BooleanField(default=False)
    auto_print_kitchen_tickets = models.BooleanField(default=False)
    allow_overselling = models.BooleanField(default=False)
    prevent_selling_at_loss = models.BooleanField(default=True)
    low_stock_threshold = models.PositiveIntegerField(default=5)
    cashier_return_window_hours = models.PositiveIntegerField(default=42)
    enable_cash_payments = models.BooleanField(default=True)
    enable_card_payments = models.BooleanField(default=True)
    enable_transfer_payments = models.BooleanField(default=True)
    require_card_payment_receipt = models.BooleanField(default=False)
    trusted_card_terminal_ids = models.JSONField(default=list, blank=True)
    card_commission_percent = models.DecimalField(
        max_digits=5,
        decimal_places=2,
        default=1,
        validators=[MinValueValidator(0)],
    )
    transfer_commission_percent = models.DecimalField(
        max_digits=5,
        decimal_places=2,
        default=0,
        validators=[MinValueValidator(0)],
    )

    class Meta:
        verbose_name = "shop settings"
        verbose_name_plural = "shop settings"

    def __str__(self):
        return self.shop_name

    @classmethod
    def load(cls):
        settings, _ = cls.objects.get_or_create(pk=1)
        return settings

    def payment_method_enabled(self, method: str) -> bool:
        return {
            "cash": self.enable_cash_payments,
            "card": self.enable_card_payments,
            "transfer": self.enable_transfer_payments,
        }.get(method, False)

    def payment_commission_percent(self, method: str):
        return {
            "card": self.card_commission_percent,
            "transfer": self.transfer_commission_percent,
        }.get(method, 0)


class SystemBackupSchedule(TimeStampedModel):
    enabled = models.BooleanField(default=False)
    destination_path = models.CharField(max_length=1024, blank=True)
    scheduled_time = models.TimeField(default=time(hour=2, minute=0))
    retention_count = models.PositiveSmallIntegerField(
        default=7,
        validators=[MinValueValidator(1)],
    )
    last_scheduled_backup_date = models.DateField(blank=True, null=True)

    class Meta:
        verbose_name = "system backup schedule"
        verbose_name_plural = "system backup schedules"

    def __str__(self):
        if not self.enabled:
            return "System backup schedule disabled"
        return f"System backup schedule at {self.scheduled_time}"

    @classmethod
    def load(cls):
        schedule, _ = cls.objects.get_or_create(
            pk=1,
            defaults={
                "retention_count": django_settings.POINTY_BACKUP_RETENTION_COUNT,
            },
        )
        return schedule


class SystemMaintenanceJob(TimeStampedModel):
    class Operation(models.TextChoices):
        BACKUP = "backup", "Backup"
        RESTORE = "restore", "Restore"

    class Status(models.TextChoices):
        QUEUED = "queued", "Queued"
        RUNNING = "running", "Running"
        SUCCEEDED = "succeeded", "Succeeded"
        FAILED = "failed", "Failed"

    operation = models.CharField(max_length=16, choices=Operation.choices)
    status = models.CharField(
        max_length=16,
        choices=Status.choices,
        default=Status.QUEUED,
        db_index=True,
    )
    progress_percent = models.PositiveSmallIntegerField(
        default=0,
        validators=[MaxValueValidator(100)],
    )
    progress_message = models.CharField(max_length=240, blank=True)
    destination_path = models.CharField(max_length=1024, blank=True)
    backup_file_name = models.CharField(max_length=255, blank=True)
    backup_file_path = models.CharField(max_length=1024, blank=True)
    archive_size_bytes = models.PositiveBigIntegerField(default=0)
    error_message = models.TextField(blank=True)
    metadata = models.JSONField(default=dict, blank=True)
    initiated_by_user_id = models.PositiveBigIntegerField(blank=True, null=True)
    initiated_by_username = models.CharField(max_length=150, blank=True)
    started_at = models.DateTimeField(blank=True, null=True)
    completed_at = models.DateTimeField(blank=True, null=True)

    class Meta:
        ordering = ["-created_at"]
        indexes = [
            models.Index(fields=["operation", "status", "-created_at"]),
            models.Index(fields=["status", "-created_at"]),
        ]

    def __str__(self):
        return f"{self.operation} {self.status} #{self.pk}"

    @property
    def is_active(self):
        return self.status in {self.Status.QUEUED, self.Status.RUNNING}

    def mark_running(self, message=""):
        self.status = self.Status.RUNNING
        self.started_at = self.started_at or timezone.now()
        if message:
            self.progress_message = message
        self.save(update_fields=["status", "started_at", "progress_message", "updated_at"])

    def update_progress(self, percent, message=""):
        self.progress_percent = max(0, min(100, int(percent)))
        if message:
            self.progress_message = message
        self.save(update_fields=["progress_percent", "progress_message", "updated_at"])

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

    def mark_failed(self, error_message):
        self.status = self.Status.FAILED
        self.error_message = str(error_message)
        self.completed_at = timezone.now()
        if not self.progress_message:
            self.progress_message = "فشلت العملية."
        self.save(
            update_fields=[
                "status",
                "error_message",
                "progress_message",
                "completed_at",
                "updated_at",
            ]
        )


class RelayInstallation(TimeStampedModel):
    installation_id = models.CharField(max_length=80, unique=True)
    shop_name = models.CharField(max_length=120, blank=True)
    relay_public_api_url = models.URLField(max_length=500)
    relay_connector_address = models.CharField(max_length=255, blank=True)
    connector_token = models.TextField()
    access_token = models.TextField()
    relay_enabled = models.BooleanField(default=False)
    subscription_active = models.BooleanField(default=False)
    ai_enabled = models.BooleanField(default=False)
    subscription_ends_at = models.DateTimeField(null=True, blank=True)
    last_synced_at = models.DateTimeField(null=True, blank=True)
    last_pairing_issued_at = models.DateTimeField(null=True, blank=True)
    connector_last_seen_at = models.DateTimeField(null=True, blank=True)
    connector_version = models.CharField(max_length=80, blank=True)

    class Meta:
        verbose_name = "relay installation"
        verbose_name_plural = "relay installations"

    def __str__(self):
        return self.installation_id

    @classmethod
    def load(cls):
        return cls.objects.order_by("created_at").first()

    @property
    def remote_access_supported(self):
        if not self.relay_enabled or not self.subscription_active:
            return False
        if self.subscription_ends_at is None:
            return True
        return timezone.now() < self.subscription_ends_at


class RelayConnectorSetupToken(TimeStampedModel):
    token_hash = models.CharField(max_length=96, unique=True)
    expires_at = models.DateTimeField(null=True, blank=True)
    consumed_at = models.DateTimeField(null=True, blank=True)

    class Meta:
        verbose_name = "relay connector setup token"
        verbose_name_plural = "relay connector setup tokens"

    @property
    def is_consumed(self):
        return self.consumed_at is not None

    @property
    def is_expired(self):
        return self.expires_at is not None and timezone.now() >= self.expires_at
