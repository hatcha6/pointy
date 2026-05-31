from django.db import models
from django.core.validators import MinValueValidator


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
