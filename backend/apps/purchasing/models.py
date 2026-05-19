from decimal import Decimal

from django.core.validators import MinValueValidator
from django.conf import settings
from django.db import models, transaction
from django.db.models import Sum

from apps.catalog.models import Product
from apps.core.models import TimeStampedModel


class Supplier(TimeStampedModel):
    name = models.CharField(max_length=255)
    contact_name = models.CharField(max_length=255, blank=True)
    phone = models.CharField(max_length=64, blank=True)
    email = models.EmailField(blank=True)
    address = models.TextField(blank=True)
    notes = models.TextField(blank=True)
    is_active = models.BooleanField(default=True)

    class Meta:
        ordering = ["name"]

    def __str__(self) -> str:
        return self.name


class PurchaseOrder(TimeStampedModel):
    class Status(models.TextChoices):
        DRAFT = "draft", "Draft"
        SUBMITTED = "submitted", "Submitted"
        RECEIVED = "received", "Received"
        CANCELLED = "cancelled", "Cancelled"

    supplier = models.ForeignKey(
        Supplier,
        on_delete=models.SET_NULL,
        related_name="purchase_orders",
        blank=True,
        null=True,
    )
    order_number = models.CharField(max_length=32, unique=True, blank=True)
    status = models.CharField(
        max_length=16,
        choices=Status.choices,
        default=Status.DRAFT,
    )
    supplier_reference = models.CharField(max_length=120, blank=True)
    notes = models.TextField(blank=True)
    subtotal = models.DecimalField(max_digits=10, decimal_places=2, default=0)
    total = models.DecimalField(max_digits=10, decimal_places=2, default=0)
    submitted_at = models.DateTimeField(blank=True, null=True)
    received_at = models.DateTimeField(blank=True, null=True)

    class Meta:
        ordering = ["-created_at"]

    def recalculate(self) -> None:
        subtotal = Decimal("0.00")
        for line in self.lines.select_related("product"):
            subtotal += line.line_total
        self.subtotal = subtotal.quantize(Decimal("0.01"))
        self.total = self.subtotal

    def save(self, *args, **kwargs):
        if not self.order_number:
            with transaction.atomic():
                super().save(*args, **kwargs)
                self.order_number = f"P{self.created_at:%Y%m%d}{self.id:06d}"
                return super().save(update_fields=["order_number"])
        return super().save(*args, **kwargs)

    def __str__(self) -> str:
        return self.order_number or f"Purchase order {self.pk}"


class PurchaseLine(TimeStampedModel):
    purchase_order = models.ForeignKey(
        PurchaseOrder,
        on_delete=models.CASCADE,
        related_name="lines",
    )
    product = models.ForeignKey(Product, on_delete=models.PROTECT)
    quantity = models.PositiveIntegerField(default=1)
    unit_cost = models.DecimalField(
        max_digits=10,
        decimal_places=2,
        validators=[MinValueValidator(Decimal("0.00"))],
    )

    class Meta:
        ordering = ["created_at"]

    @property
    def line_total(self):
        return (self.unit_cost * self.quantity).quantize(Decimal("0.01"))

    @property
    def adjusted_quantity(self) -> int:
        total = self.adjustment_lines.aggregate(total=Sum("quantity"))["total"]
        return total or 0

    @property
    def adjustable_quantity(self) -> int:
        return max(self.quantity - self.adjusted_quantity, 0)


class PurchaseOrderAdjustment(TimeStampedModel):
    class AdjustmentType(models.TextChoices):
        RETURN = "return", "Return"
        REFUND = "refund", "Refund"
        EXCHANGE = "exchange", "Exchange"

    purchase_order = models.ForeignKey(
        PurchaseOrder,
        on_delete=models.PROTECT,
        related_name="adjustments",
    )
    adjustment_type = models.CharField(max_length=16, choices=AdjustmentType.choices)
    amount = models.DecimalField(max_digits=10, decimal_places=2)
    reason = models.TextField(blank=True)
    created_by = models.ForeignKey(
        settings.AUTH_USER_MODEL,
        on_delete=models.SET_NULL,
        related_name="purchase_order_adjustments",
        blank=True,
        null=True,
    )

    class Meta:
        ordering = ["-created_at"]

    def __str__(self) -> str:
        return f"{self.adjustment_type} {self.amount} for {self.purchase_order_id}"


class PurchaseOrderAdjustmentLine(TimeStampedModel):
    adjustment = models.ForeignKey(
        PurchaseOrderAdjustment,
        on_delete=models.CASCADE,
        related_name="lines",
    )
    purchase_line = models.ForeignKey(
        PurchaseLine,
        on_delete=models.PROTECT,
        related_name="adjustment_lines",
    )
    product = models.ForeignKey(Product, on_delete=models.PROTECT)
    quantity = models.PositiveIntegerField()
    unit_cost = models.DecimalField(max_digits=10, decimal_places=2)

    class Meta:
        ordering = ["created_at"]

    @property
    def line_total(self):
        return (self.unit_cost * self.quantity).quantize(Decimal("0.01"))
