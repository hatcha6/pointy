from django.conf import settings
from django.db import models
from django.core.validators import MinValueValidator
from django.utils import timezone

from apps.core.models import TimeStampedModel
from apps.sales.models import Order, RegisterSession


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
    # Set when a card payment's receipt is captured: links the payment to the
    # deduped PaymentCard (and, through it, a customer). Nullable so cash/transfer
    # and the refund/migration paths leave it empty.
    card = models.ForeignKey(
        "customers.PaymentCard",
        on_delete=models.SET_NULL,
        related_name="payments",
        blank=True,
        null=True,
    )
    # Audit + cash-drawer attribution. ``register_session`` is the session that
    # COLLECTED this payment: it defaults to the order's session at checkout, but
    # a debt invoice settled in a later shift is attributed to the COLLECTING
    # shift's drawer (see RegisterSession.cash_sales_total). ``paid_at`` is when
    # money changed hands; ``created_by`` is who recorded it.
    register_session = models.ForeignKey(
        RegisterSession,
        on_delete=models.PROTECT,
        related_name="payments",
        blank=True,
        null=True,
    )
    created_by = models.ForeignKey(
        settings.AUTH_USER_MODEL,
        on_delete=models.SET_NULL,
        related_name="payments_taken",
        blank=True,
        null=True,
    )
    paid_at = models.DateTimeField(default=timezone.now)

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
