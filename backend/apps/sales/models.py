from decimal import Decimal

from django.conf import settings
from django.core.validators import MinValueValidator
from django.db import models, transaction
from django.db.models import Q, Sum

from apps.catalog.models import Product
from apps.core.models import TimeStampedModel
from apps.customers.models import Customer


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

    @property
    def cash_sales_total(self) -> Decimal:
        from apps.payments.models import Payment

        total = Payment.objects.filter(
            order__register_session=self,
            order__status__in=(Order.Status.PAID, Order.Status.VOID),
            method=Payment.Method.CASH,
            amount__gt=0,
        ).aggregate(total=Sum("amount"))["total"]
        return (total or Decimal("0.00")).quantize(Decimal("0.01"))

    @property
    def cash_refund_total(self) -> Decimal:
        from apps.payments.models import Payment

        total = self.order_adjustments.filter(
            refund_method=Payment.Method.CASH,
        ).aggregate(total=Sum("amount"))["total"]
        return (total or Decimal("0.00")).quantize(Decimal("0.01"))

    @property
    def pay_in_total(self) -> Decimal:
        return self._cash_movement_total(RegisterCashMovement.MovementType.PAY_IN)

    @property
    def pay_out_total(self) -> Decimal:
        return self._cash_movement_total(RegisterCashMovement.MovementType.PAY_OUT)

    @property
    def expected_cash(self) -> Decimal:
        total = self.opening_cash + self.cash_sales_total + self.pay_in_total
        return (total - self.pay_out_total - self.cash_refund_total).quantize(
            Decimal("0.01")
        )

    @property
    def denomination_total(self) -> Decimal:
        total = (
            Decimal("0.25") * self.count_025
            + Decimal("0.50") * self.count_050
            + Decimal("0.75") * self.count_075
            + Decimal("1.00") * self.count_100
        )
        return total.quantize(Decimal("0.01"))

    @property
    def cash_variance(self) -> Decimal | None:
        if self.closing_cash is None:
            return None
        return (self.closing_cash - self.expected_cash).quantize(Decimal("0.01"))

    @property
    def has_cash_variance(self) -> bool:
        return self.cash_variance not in (None, Decimal("0.00"))

    def _cash_movement_total(self, movement_type) -> Decimal:
        total = self.cash_movements.filter(movement_type=movement_type).aggregate(
            total=Sum("amount"),
        )["total"]
        return (total or Decimal("0.00")).quantize(Decimal("0.01"))


class RegisterCashMovement(TimeStampedModel):
    class MovementType(models.TextChoices):
        PAY_IN = "pay_in", "Pay in"
        PAY_OUT = "pay_out", "Pay out"

    register_session = models.ForeignKey(
        RegisterSession,
        on_delete=models.PROTECT,
        related_name="cash_movements",
    )
    movement_type = models.CharField(max_length=16, choices=MovementType.choices)
    amount = models.DecimalField(
        max_digits=10,
        decimal_places=2,
        validators=[MinValueValidator(Decimal("0.01"))],
    )
    reason = models.TextField()
    created_by = models.ForeignKey(
        settings.AUTH_USER_MODEL,
        on_delete=models.SET_NULL,
        related_name="register_cash_movements",
        blank=True,
        null=True,
    )

    class Meta:
        ordering = ["-created_at"]

    def __str__(self) -> str:
        return f"{self.get_movement_type_display()} {self.amount} for {self.register_session}"


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
    customer = models.ForeignKey(
        Customer,
        on_delete=models.SET_NULL,
        related_name="orders",
        blank=True,
        null=True,
    )
    receipt_number = models.CharField(max_length=32, unique=True, blank=True)
    status = models.CharField(max_length=16, choices=Status.choices, default=Status.OPEN)
    subtotal = models.DecimalField(max_digits=10, decimal_places=2, default=0)
    discount_total = models.DecimalField(max_digits=10, decimal_places=2, default=0)
    total = models.DecimalField(max_digits=10, decimal_places=2, default=0)

    class Meta:
        ordering = ["-created_at"]

    def recalculate(self) -> None:
        subtotal = Decimal("0.00")
        discount_total = Decimal("0.00")
        for line in self.lines.select_related("product"):
            subtotal += line.line_subtotal
            discount_total += line.discount_total
        self.subtotal = subtotal.quantize(Decimal("0.01"))
        self.discount_total = min(
            discount_total.quantize(Decimal("0.01")),
            self.subtotal,
        )
        self.total = (self.subtotal - self.discount_total).quantize(Decimal("0.01"))

    @property
    def total_cost(self):
        total = sum((line.line_cost for line in self.lines.all()), Decimal("0.00"))
        return total.quantize(Decimal("0.01"))

    @property
    def total_profit(self):
        total = sum((line.line_profit for line in self.lines.all()), Decimal("0.00"))
        return total.quantize(Decimal("0.01"))

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
    unit_cost = models.DecimalField(max_digits=10, decimal_places=2, default=0)
    discount_total = models.DecimalField(max_digits=10, decimal_places=2, default=0)

    class Meta:
        ordering = ["created_at"]

    @property
    def line_subtotal(self):
        return (self.unit_price * self.quantity).quantize(Decimal("0.01"))

    @property
    def line_total(self):
        return (self.line_subtotal - self.discount_total).quantize(Decimal("0.01"))

    @property
    def line_cost(self):
        return (self.unit_cost * self.quantity).quantize(Decimal("0.01"))

    @property
    def line_profit(self):
        return (self.line_total - self.line_cost).quantize(Decimal("0.01"))

    @property
    def returned_quantity(self) -> int:
        total = self.adjustment_lines.aggregate(total=Sum("quantity"))["total"]
        return total or 0

    @property
    def returnable_quantity(self) -> int:
        return max(self.quantity - self.returned_quantity, 0)

    @property
    def returned_discount_total(self) -> Decimal:
        total = self.adjustment_lines.aggregate(total=Sum("discount_total"))["total"]
        return (total or Decimal("0.00")).quantize(Decimal("0.01"))


class OrderAdjustment(TimeStampedModel):
    class AdjustmentType(models.TextChoices):
        VOID = "void", "Void"
        RETURN = "return", "Return"

    order = models.ForeignKey(
        Order,
        on_delete=models.PROTECT,
        related_name="adjustments",
    )
    register_session = models.ForeignKey(
        RegisterSession,
        on_delete=models.PROTECT,
        related_name="order_adjustments",
    )
    adjustment_type = models.CharField(max_length=16, choices=AdjustmentType.choices)
    amount = models.DecimalField(max_digits=10, decimal_places=2)
    refund_method = models.CharField(max_length=16, default="cash")
    reason = models.TextField(blank=True)
    created_by = models.ForeignKey(
        settings.AUTH_USER_MODEL,
        on_delete=models.SET_NULL,
        related_name="order_adjustments",
        blank=True,
        null=True,
    )

    class Meta:
        ordering = ["-created_at"]

    def __str__(self) -> str:
        return f"{self.adjustment_type} {self.amount} for {self.order_id}"


class OrderAdjustmentLine(TimeStampedModel):
    adjustment = models.ForeignKey(
        OrderAdjustment,
        on_delete=models.CASCADE,
        related_name="lines",
    )
    order_line = models.ForeignKey(
        OrderLine,
        on_delete=models.PROTECT,
        related_name="adjustment_lines",
    )
    product = models.ForeignKey(Product, on_delete=models.PROTECT)
    quantity = models.PositiveIntegerField()
    unit_price = models.DecimalField(max_digits=10, decimal_places=2)
    discount_total = models.DecimalField(max_digits=10, decimal_places=2, default=0)

    class Meta:
        ordering = ["created_at"]

    @property
    def line_total(self):
        gross_total = self.unit_price * self.quantity
        return (gross_total - self.discount_total).quantize(Decimal("0.01"))
