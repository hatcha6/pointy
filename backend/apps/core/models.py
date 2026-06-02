from django.db import models
from django.core.validators import MinValueValidator
from django.utils import timezone


class TimeStampedModel(models.Model):
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        abstract = True


class ShopSettings(TimeStampedModel):
    shop_name = models.CharField(max_length=120, default="نقطة البيع")
    receipt_header = models.CharField(max_length=240, blank=True)
    receipt_footer = models.CharField(max_length=240, blank=True)
    require_opening_cash = models.BooleanField(default=True)
    auto_print_receipts = models.BooleanField(default=False)
    allow_overselling = models.BooleanField(default=False)
    prevent_selling_at_loss = models.BooleanField(default=True)
    low_stock_threshold = models.PositiveIntegerField(default=5)
    cashier_return_window_hours = models.PositiveIntegerField(default=42)
    enable_cash_payments = models.BooleanField(default=True)
    enable_card_payments = models.BooleanField(default=True)
    enable_transfer_payments = models.BooleanField(default=True)
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
