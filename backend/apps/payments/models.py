from django.db import models
from django.core.validators import MinValueValidator

from apps.core.models import TimeStampedModel
from apps.sales.models import Order


class Payment(TimeStampedModel):
    class Method(models.TextChoices):
        CASH = "cash", "Cash"
        CARD = "card", "Card"
        TRANSFER = "transfer", "Transfer"

    order = models.ForeignKey(Order, on_delete=models.PROTECT, related_name="payments")
    method = models.CharField(max_length=16, choices=Method.choices)
    amount = models.DecimalField(max_digits=10, decimal_places=2)
    commission_percent = models.DecimalField(
        max_digits=5,
        decimal_places=2,
        default=0,
        validators=[MinValueValidator(0)],
    )
    commission_amount = models.DecimalField(max_digits=10, decimal_places=2, default=0)
    external_reference = models.CharField(max_length=128, blank=True)
    card_receipt_data = models.JSONField(default=dict, blank=True)

    class Meta:
        ordering = ["-created_at"]
        # Payment-mix dashboard and payment-method reports group by method over a
        # date range.
        indexes = [
            models.Index(
                fields=["method", "-created_at"],
                name="payments_method_created_idx",
            ),
        ]

    def __str__(self) -> str:
        return f"{self.method} {self.amount} for {self.order_id}"
