from django.db import models


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
    low_stock_threshold = models.PositiveIntegerField(default=5)
    cashier_return_window_hours = models.PositiveIntegerField(default=42)

    class Meta:
        verbose_name = "shop settings"
        verbose_name_plural = "shop settings"

    def __str__(self):
        return self.shop_name

    @classmethod
    def load(cls):
        settings, _ = cls.objects.get_or_create(pk=1)
        return settings
