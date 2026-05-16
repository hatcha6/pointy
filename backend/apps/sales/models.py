from decimal import Decimal

from django.conf import settings
from django.core.validators import MinValueValidator
from django.db import models, transaction
from django.db.models import Q

from apps.catalog.models import Product
from apps.core.models import TimeStampedModel


class RegisterSession(TimeStampedModel):
    class Status(models.TextChoices):
        OPEN = "open", "Open"
        CLOSED = "closed", "Closed"

    owner = models.ForeignKey(
        settings.AUTH_USER_MODEL,
        on_delete=models.SET_NULL,
        related_name="register_sessions",
        blank=True,
        null=True,
    )
    owner_key = models.CharField(max_length=64, db_index=True)
    status = models.CharField(max_length=16, choices=Status.choices, default=Status.OPEN)
    opening_cash = models.DecimalField(
        max_digits=10,
        decimal_places=2,
        default=0,
        validators=[MinValueValidator(Decimal("0.00"))],
    )
    closing_cash = models.DecimalField(
        max_digits=10,
        decimal_places=2,
        blank=True,
        null=True,
        validators=[MinValueValidator(Decimal("0.00"))],
    )
    count_025 = models.PositiveIntegerField(default=0)
    count_050 = models.PositiveIntegerField(default=0)
    count_075 = models.PositiveIntegerField(default=0)
    count_100 = models.PositiveIntegerField(default=0)
    opened_at = models.DateTimeField(auto_now_add=True)
    closed_at = models.DateTimeField(blank=True, null=True)

    class Meta:
        ordering = ["-created_at"]
        constraints = [
            models.UniqueConstraint(
                fields=["owner_key"],
                condition=Q(status="open"),
                name="unique_open_register_session_per_owner",
            )
        ]

    def __str__(self) -> str:
        return f"{self.owner_key} {self.status} register session"

    @property
    def session_number(self) -> str:
        if self.pk is None:
            return "RS"
        return f"RS-{self.pk}"


class Order(TimeStampedModel):
    class Status(models.TextChoices):
        OPEN = "open", "Open"
        PAID = "paid", "Paid"
        VOID = "void", "Void"

    register_session = models.ForeignKey(
        RegisterSession,
        on_delete=models.PROTECT,
        related_name="orders",
        blank=True,
        null=True,
    )
    receipt_number = models.CharField(max_length=32, unique=True, blank=True)
    status = models.CharField(max_length=16, choices=Status.choices, default=Status.OPEN)
    subtotal = models.DecimalField(max_digits=10, decimal_places=2, default=0)
    total = models.DecimalField(max_digits=10, decimal_places=2, default=0)

    class Meta:
        ordering = ["-created_at"]

    def recalculate(self) -> None:
        subtotal = Decimal("0.00")
        for line in self.lines.select_related("product"):
            line_subtotal = line.unit_price * line.quantity
            subtotal += line_subtotal
        self.subtotal = subtotal.quantize(Decimal("0.01"))
        self.total = self.subtotal

    def save(self, *args, **kwargs):
        if not self.receipt_number:
            with transaction.atomic():
                super().save(*args, **kwargs)
                self.receipt_number = f"R{self.created_at:%Y%m%d}{self.id:06d}"
                return super().save(update_fields=["receipt_number"])
        return super().save(*args, **kwargs)

    def __str__(self) -> str:
        return self.receipt_number or f"Order {self.pk}"


class OrderLine(TimeStampedModel):
    order = models.ForeignKey(Order, on_delete=models.CASCADE, related_name="lines")
    product = models.ForeignKey(Product, on_delete=models.PROTECT)
    quantity = models.PositiveIntegerField(default=1)
    unit_price = models.DecimalField(max_digits=10, decimal_places=2)

    class Meta:
        ordering = ["created_at"]

    @property
    def line_total(self):
        return (self.unit_price * self.quantity).quantize(Decimal("0.01"))
