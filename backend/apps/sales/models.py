from decimal import Decimal
import secrets

from django.conf import settings
from django.contrib.contenttypes.fields import GenericRelation
from django.core.validators import MinValueValidator
from django.db import models, transaction
from django.db.models import Q, Sum

from apps.catalog.models import ProductVariant
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
    # Stamped by the backend from the request's credentials (see
    # apps.channels.services.resolve_sales_channel) — never from client input.
    sales_channel = models.ForeignKey(
        "channels.SalesChannel",
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
    public_token = models.CharField(
        max_length=64,
        unique=True,
        blank=True,
        null=True,
    )
    status = models.CharField(max_length=16, choices=Status.choices, default=Status.OPEN)
    subtotal = models.DecimalField(max_digits=10, decimal_places=2, default=0)
    discount_total = models.DecimalField(max_digits=10, decimal_places=2, default=0)
    total = models.DecimalField(max_digits=10, decimal_places=2, default=0)
    # Reverse accessor for the discounts applied to this order document so the
    # API can prefetch them in a single query instead of one lookup per order
    # row when serialising lists of orders.
    applied_discounts = GenericRelation(
        "discounts.AppliedDiscount",
        content_type_field="document_content_type",
        object_id_field="document_object_id",
    )

    class Meta:
        ordering = ["-created_at"]
        # Almost every aggregate filters status IN (paid, void) over a date
        # range; this composite serves those plus the default -created_at listing.
        indexes = [
            models.Index(
                fields=["status", "-created_at"],
                name="sales_order_status_created_idx",
            ),
        ]

    def recalculate(self) -> None:
        subtotal = Decimal("0.00")
        discount_total = Decimal("0.00")
        for line in self.lines.select_related("variant", "variant__product"):
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
        update_fields = kwargs.get("update_fields")
        if not self.public_token:
            self.public_token = self._generate_public_token()
            if update_fields is not None and "public_token" not in update_fields:
                kwargs["update_fields"] = [*update_fields, "public_token"]
        if not self.receipt_number:
            with transaction.atomic():
                super().save(*args, **kwargs)
                self.receipt_number = f"R{self.created_at:%Y%m%d}{self.id:06d}"
                return super().save(update_fields=["receipt_number", "public_token"])
        return super().save(*args, **kwargs)

    def __str__(self) -> str:
        return self.receipt_number or f"Order {self.pk}"

    @classmethod
    def _generate_public_token(cls) -> str:
        while True:
            token = secrets.token_urlsafe(24)
            if not cls.objects.filter(public_token=token).exists():
                return token


class OrderLine(TimeStampedModel):
    order = models.ForeignKey(Order, on_delete=models.CASCADE, related_name="lines")
    variant = models.ForeignKey(
        ProductVariant,
        on_delete=models.PROTECT,
        related_name="order_lines",
    )
    quantity = models.DecimalField(
        max_digits=10,
        decimal_places=3,
        default=1,
        validators=[MinValueValidator(Decimal("0.001"))],
    )
    unit_price = models.DecimalField(max_digits=10, decimal_places=2)
    unit_cost = models.DecimalField(max_digits=10, decimal_places=2, default=0)
    discount_total = models.DecimalField(max_digits=10, decimal_places=2, default=0)
    # The unit this line was sold in (a UnitOfMeasure.code); blank = the product's
    # base unit. ``unit_factor`` is a snapshot of how many base units one of that
    # unit is worth, so quantity/price/cost stay self-consistent and stock can be
    # reconciled in base units even after the product's units are later edited.
    unit = models.CharField(max_length=32, blank=True, default="")
    unit_factor = models.DecimalField(
        max_digits=18,
        decimal_places=6,
        default=Decimal("1"),
        validators=[MinValueValidator(Decimal("0.000001"))],
    )
    # Free-text kitchen instruction for a single line (e.g. "no onions").
    # Short by design so it never blows out a thermal kitchen chit.
    notes = models.CharField(max_length=255, blank=True, default="")

    class Meta:
        ordering = ["created_at"]

    @property
    def base_quantity(self):
        # Quantity converted into the product's base (stock) unit.
        return (self.quantity * self.unit_factor).quantize(Decimal("0.001"))

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
        # Sum in Python so a prefetched ``adjustment_lines`` is reused instead of
        # firing a per-line aggregate query when serialising lists of orders.
        total = sum((line.quantity for line in self.adjustment_lines.all()), 0)
        return total or 0

    @property
    def returnable_quantity(self) -> int:
        return max(self.quantity - self.returned_quantity, 0)

    @property
    def returned_discount_total(self) -> Decimal:
        total = sum(
            (line.discount_total for line in self.adjustment_lines.all()),
            Decimal("0.00"),
        )
        return total.quantize(Decimal("0.01"))


class OrderLineModifier(TimeStampedModel):
    """A structured modifier chosen for a single order line (e.g. "Oat milk",
    "Extra shot ×2"). The selected option's per-unit price delta is already
    folded into OrderLine.unit_price; these rows carry the breakdown for the
    chit/receipt and are snapshotted so reprints survive catalog edits."""

    order_line = models.ForeignKey(
        OrderLine,
        on_delete=models.CASCADE,
        related_name="modifiers",
    )
    modifier_option = models.ForeignKey(
        "catalog.ModifierOption",
        on_delete=models.SET_NULL,
        related_name="order_line_modifiers",
        blank=True,
        null=True,
    )
    group_name = models.CharField(max_length=160, blank=True)
    option_name = models.CharField(max_length=160, blank=True)
    unit_price_delta = models.DecimalField(max_digits=10, decimal_places=2, default=0)
    quantity = models.PositiveIntegerField(default=1)

    class Meta:
        ordering = ["id"]

    @property
    def line_price_delta(self) -> Decimal:
        return (self.unit_price_delta * self.quantity).quantize(Decimal("0.01"))

    def __str__(self) -> str:
        return f"{self.option_name} ×{self.quantity}"


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
    variant = models.ForeignKey(
        ProductVariant,
        on_delete=models.PROTECT,
        related_name="order_adjustment_lines",
    )
    quantity = models.DecimalField(
        max_digits=10,
        decimal_places=3,
        validators=[MinValueValidator(Decimal("0.001"))],
    )
    unit_price = models.DecimalField(max_digits=10, decimal_places=2)
    discount_total = models.DecimalField(max_digits=10, decimal_places=2, default=0)

    class Meta:
        ordering = ["created_at"]

    @property
    def line_total(self):
        gross_total = self.unit_price * self.quantity
        return (gross_total - self.discount_total).quantize(Decimal("0.01"))
