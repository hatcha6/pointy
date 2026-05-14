from decimal import Decimal

from django.db import models, transaction

from apps.catalog.models import Product
from apps.core.models import TimeStampedModel


class Order(TimeStampedModel):
    class Status(models.TextChoices):
        OPEN = "open", "Open"
        PAID = "paid", "Paid"
        VOID = "void", "Void"

    receipt_number = models.CharField(max_length=32, unique=True, blank=True)
    status = models.CharField(max_length=16, choices=Status.choices, default=Status.OPEN)
    subtotal = models.DecimalField(max_digits=10, decimal_places=2, default=0)
    tax_total = models.DecimalField(max_digits=10, decimal_places=2, default=0)
    total = models.DecimalField(max_digits=10, decimal_places=2, default=0)

    class Meta:
        ordering = ["-created_at"]

    def recalculate(self) -> None:
        subtotal = Decimal("0.00")
        tax_total = Decimal("0.00")
        for line in self.lines.select_related("product"):
            line_subtotal = line.unit_price * line.quantity
            subtotal += line_subtotal
            tax_total += line_subtotal * line.tax_rate
        self.subtotal = subtotal.quantize(Decimal("0.01"))
        self.tax_total = tax_total.quantize(Decimal("0.01"))
        self.total = (self.subtotal + self.tax_total).quantize(Decimal("0.01"))

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
    tax_rate = models.DecimalField(max_digits=5, decimal_places=4, default=0)

    class Meta:
        ordering = ["created_at"]

    @property
    def line_total(self):
        return (self.unit_price * self.quantity * (1 + self.tax_rate)).quantize(Decimal("0.01"))
