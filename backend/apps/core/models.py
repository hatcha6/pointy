from datetime import time

from django.conf import settings as django_settings
from django.core.validators import MaxValueValidator, MinValueValidator
from django.db import models
from django.utils import timezone


class TimeStampedModel(models.Model):
    # Indexed because nearly every list, dashboard, and report query filters or
    # orders on created_at; without this they full-scan + filesort as data grows.
    created_at = models.DateTimeField(auto_now_add=True, db_index=True)
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
    class ShopType(models.TextChoices):
        GENERAL = "general", "General retail"
        RESTAURANT = "restaurant", "Restaurant / Café"
        GROCERY = "grocery", "Grocery / Supermarket"
        PHARMACY = "pharmacy", "Pharmacy"
        PHONE_REPAIR = "phone_repair", "Phone shop & repair"
        BAKERY = "bakery", "Bakery / Pastry"
        RETAIL = "retail", "Clothing / Retail"

    shop_name = models.CharField(max_length=120, default="نقطة البيع")
    # The shop's vertical, chosen in the first-run setup wizard. Empty until
    # then; drives the preset defaults but every setting stays editable after.
    shop_type = models.CharField(max_length=32, blank=True, default="")
    # Display currency. One currency per shop for now; ``currency_symbol`` is
    # what the apps and printed documents render next to amounts (the setup
    # wizard hints at fuller multi-currency support as a future step).
    currency_code = models.CharField(max_length=8, default="LYD")
    currency_symbol = models.CharField(max_length=8, default="د.ل")
    receipt_header = models.CharField(max_length=240, blank=True)
    receipt_footer = models.CharField(max_length=240, blank=True)
    enable_online_invoices = models.BooleanField(default=False)
    # Operations modes: which job workflows this shop uses. All off by default
    # so a pure retail shop never sees the feature.
    enable_repair_operations = models.BooleanField(default=False)
    enable_production_operations = models.BooleanField(default=False)
    enable_kitchen_operations = models.BooleanField(default=False)
    # Kitchen lane. When on (the default), a paid POS order's kitchen job is
    # finalized immediately — recipe ingredients leave stock at the sale and the
    # job is marked complete — so cooks just read the printed chit and never
    # touch a screen. Turn it off to keep the staged received→preparing→served
    # flow (the foundation for a future kitchen display / KDS).
    kitchen_auto_complete = models.BooleanField(default=True)
    # Public job tracking page (relay-gated), like online invoices.
    enable_job_tracking = models.BooleanField(default=False)
    require_opening_cash = models.BooleanField(default=True)
    auto_print_receipts = models.BooleanField(default=False)
    auto_print_kitchen_tickets = models.BooleanField(default=False)
    allow_overselling = models.BooleanField(default=False)
    prevent_selling_at_loss = models.BooleanField(default=True)
    low_stock_threshold = models.PositiveIntegerField(default=5)
    # Stock-count variance review thresholds. A counted line is flagged for
    # review only when the gap is at least ``min_units`` AND at least
    # ``percent`` of the expected quantity (see apps.inventory.services).
    stock_count_variance_min_units = models.DecimalField(
        max_digits=12,
        decimal_places=3,
        default=1,
        validators=[MinValueValidator(0)],
    )
    stock_count_variance_percent = models.DecimalField(
        max_digits=5,
        decimal_places=2,
        default=10,
        validators=[MinValueValidator(0)],
    )
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

    def apply_shop_type_preset(self, shop_type: str):
        """Flip the feature defaults for a shop vertical, then record the type.

        Presets are non-destructive defaults — every field stays editable in
        Settings afterwards; the wizard simply gives a sensible starting point.
        """
        for field, value in SHOP_TYPE_PRESETS.get(shop_type, {}).items():
            setattr(self, field, value)
        self.shop_type = shop_type


# Per-vertical default toggles applied by the first-run setup wizard. Only the
# fields that differ from a plain retail shop are listed; everything else keeps
# the model default. All of these remain editable in Settings afterwards.
SHOP_TYPE_PRESETS = {
    ShopSettings.ShopType.GENERAL: {
        "enable_kitchen_operations": False,
        "enable_repair_operations": False,
        "enable_production_operations": False,
        "allow_overselling": False,
        "prevent_selling_at_loss": True,
    },
    ShopSettings.ShopType.RESTAURANT: {
        "enable_kitchen_operations": True,
        "auto_print_kitchen_tickets": True,
        "kitchen_auto_complete": True,
        "enable_repair_operations": False,
        "enable_production_operations": False,
    },
    ShopSettings.ShopType.GROCERY: {
        "enable_kitchen_operations": False,
        "enable_repair_operations": False,
        "allow_overselling": False,
        "prevent_selling_at_loss": True,
        "low_stock_threshold": 10,
    },
    ShopSettings.ShopType.PHARMACY: {
        "enable_kitchen_operations": False,
        "enable_repair_operations": False,
        "allow_overselling": False,
        "prevent_selling_at_loss": True,
    },
    ShopSettings.ShopType.PHONE_REPAIR: {
        "enable_repair_operations": True,
        "enable_job_tracking": True,
        "enable_kitchen_operations": False,
    },
    ShopSettings.ShopType.BAKERY: {
        "enable_kitchen_operations": True,
        "enable_production_operations": True,
        "auto_print_kitchen_tickets": False,
    },
    ShopSettings.ShopType.RETAIL: {
        "enable_kitchen_operations": False,
        "enable_repair_operations": False,
        "allow_overselling": False,
        "prevent_selling_at_loss": True,
    },
}


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
