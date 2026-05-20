from decimal import Decimal, ROUND_DOWN

from django.core.validators import MinValueValidator
from django.conf import settings
from django.db import models, transaction
from django.db.models import Q, Sum
from django.utils import timezone

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

    @property
    def payable_balance(self):
        total = Decimal("0.00")
        for order in self.purchase_orders.exclude(status=PurchaseOrder.Status.CANCELLED):
            total += max(order.raw_balance_due, Decimal("0.00"))
        unallocated = self.payments.filter(purchase_order__isnull=True).exclude(
            method=SupplierPayment.Method.SUPPLIER_CREDIT,
        )
        paid_total = unallocated.aggregate(total=Sum("amount"))["total"] or Decimal("0.00")
        return max(total - paid_total, Decimal("0.00")).quantize(Decimal("0.01"))

    @property
    def credit_balance(self):
        total = self.credits.filter(status=SupplierCredit.Status.OPEN).aggregate(
            total=Sum("remaining_amount")
        )["total"]
        return (total or Decimal("0.00")).quantize(Decimal("0.01"))

    @property
    def net_balance(self):
        return (self.payable_balance - self.credit_balance).quantize(Decimal("0.01"))


class PurchaseOrder(TimeStampedModel):
    MONEY_PLACES = Decimal("0.01")

    class Status(models.TextChoices):
        DRAFT = "draft", "Draft"
        SUBMITTED = "submitted", "Submitted"
        PARTIALLY_RECEIVED = "partially_received", "Partially received"
        RECEIVED = "received", "Received"
        CANCELLED = "cancelled", "Cancelled"

    class LandedCostAllocationMethod(models.TextChoices):
        LINE_VALUE = "line_value", "By line value"
        QUANTITY = "quantity", "By quantity"

    supplier = models.ForeignKey(
        Supplier,
        on_delete=models.PROTECT,
        related_name="purchase_orders",
    )
    order_number = models.CharField(max_length=32, unique=True, blank=True)
    status = models.CharField(
        max_length=24,
        choices=Status.choices,
        default=Status.DRAFT,
    )
    supplier_invoice_number = models.CharField(max_length=120, blank=True)
    supplier_invoice_date = models.DateField(blank=True, null=True)
    notes = models.TextField(blank=True)
    subtotal = models.DecimalField(max_digits=10, decimal_places=2, default=0)
    shipping_amount = models.DecimalField(
        max_digits=10,
        decimal_places=2,
        default=0,
        validators=[MinValueValidator(Decimal("0.00"))],
    )
    customs_amount = models.DecimalField(
        max_digits=10,
        decimal_places=2,
        default=0,
        validators=[MinValueValidator(Decimal("0.00"))],
    )
    handling_amount = models.DecimalField(
        max_digits=10,
        decimal_places=2,
        default=0,
        validators=[MinValueValidator(Decimal("0.00"))],
    )
    landed_cost_allocation_method = models.CharField(
        max_length=16,
        choices=LandedCostAllocationMethod.choices,
        default=LandedCostAllocationMethod.LINE_VALUE,
    )
    total = models.DecimalField(max_digits=10, decimal_places=2, default=0)
    due_date = models.DateField(blank=True, null=True)
    submitted_at = models.DateTimeField(blank=True, null=True)
    received_at = models.DateTimeField(blank=True, null=True)

    class Meta:
        ordering = ["-created_at"]
        constraints = [
            models.UniqueConstraint(
                fields=["supplier", "supplier_invoice_number"],
                condition=~Q(supplier_invoice_number=""),
                name="unique_supplier_invoice_number_per_supplier",
            ),
        ]

    def recalculate(self) -> None:
        subtotal = Decimal("0.00")
        lines = list(self.lines.select_related("product").order_by("created_at", "id"))
        for line in lines:
            subtotal += line.line_total
        self.subtotal = subtotal.quantize(self.MONEY_PLACES)
        landed_cost_total = self.landed_cost_total
        self.total = (self.subtotal + landed_cost_total).quantize(self.MONEY_PLACES)
        self.allocate_landed_costs(lines, landed_cost_total)

    @property
    def landed_cost_total(self):
        return (
            Decimal(self.shipping_amount)
            + Decimal(self.customs_amount)
            + Decimal(self.handling_amount)
        ).quantize(self.MONEY_PLACES)

    def allocate_landed_costs(self, lines, landed_cost_total) -> None:
        if not lines:
            return

        allocations = self._landed_cost_allocations(lines, landed_cost_total)
        for line in lines:
            allocated_landed_cost = allocations[line.pk]
            landed_unit_cost = Decimal("0.00")
            if line.quantity > 0:
                landed_unit_cost = (
                    allocated_landed_cost / Decimal(line.quantity)
                ).quantize(self.MONEY_PLACES)
            line.allocated_landed_cost = allocated_landed_cost
            line.landed_unit_cost = landed_unit_cost
            line.effective_unit_cost = (
                line.unit_cost + landed_unit_cost
            ).quantize(self.MONEY_PLACES)
            line.save(
                update_fields=[
                    "allocated_landed_cost",
                    "landed_unit_cost",
                    "effective_unit_cost",
                    "updated_at",
                ],
            )

    def _landed_cost_allocations(self, lines, landed_cost_total):
        if landed_cost_total == Decimal("0.00"):
            return {line.pk: Decimal("0.00") for line in lines}

        weights = self._landed_cost_weights(lines)
        total_weight = sum(weights.values(), Decimal("0.00"))
        if total_weight == Decimal("0.00"):
            weights = {line.pk: Decimal(line.quantity) for line in lines}
            total_weight = sum(weights.values(), Decimal("0.00"))

        allocations = {}
        remainders = []
        allocated_total = Decimal("0.00")
        for line in lines:
            exact_share = landed_cost_total * weights[line.pk] / total_weight
            rounded_share = exact_share.quantize(self.MONEY_PLACES, rounding=ROUND_DOWN)
            allocations[line.pk] = rounded_share
            allocated_total += rounded_share
            remainders.append((exact_share - rounded_share, line.pk))

        remaining_cents = int(
            ((landed_cost_total - allocated_total) * Decimal("100")).to_integral_value()
        )
        remainders.sort(key=lambda item: (-item[0], item[1]))
        for _, line_pk in remainders[:remaining_cents]:
            allocations[line_pk] += self.MONEY_PLACES
        return allocations

    def _landed_cost_weights(self, lines):
        if (
            self.landed_cost_allocation_method
            == self.LandedCostAllocationMethod.QUANTITY
        ):
            return {line.pk: Decimal(line.quantity) for line in lines}
        return {line.pk: line.line_total for line in lines}

    def save(self, *args, **kwargs):
        if not self.order_number:
            with transaction.atomic():
                super().save(*args, **kwargs)
                self.order_number = f"P{self.created_at:%Y%m%d}{self.id:06d}"
                return super().save(update_fields=["order_number"])
        return super().save(*args, **kwargs)

    def __str__(self) -> str:
        return self.order_number or f"Purchase order {self.pk}"

    @property
    def paid_total(self):
        total = self.supplier_payments.exclude(
            method=SupplierPayment.Method.SUPPLIER_CREDIT,
        ).aggregate(total=Sum("amount"))["total"]
        return (total or Decimal("0.00")).quantize(Decimal("0.01"))

    @property
    def credit_applied_total(self):
        total = self.supplier_payments.filter(
            method=SupplierPayment.Method.SUPPLIER_CREDIT,
        ).aggregate(total=Sum("amount"))["total"]
        return (total or Decimal("0.00")).quantize(Decimal("0.01"))

    @property
    def adjustment_credit_total(self):
        total = self.supplier_credits.aggregate(total=Sum("amount"))["total"]
        return (total or Decimal("0.00")).quantize(Decimal("0.01"))

    @property
    def raw_balance_due(self):
        return (
            self.total
            - self.paid_total
            - self.credit_applied_total
        ).quantize(Decimal("0.01"))

    @property
    def balance_due(self):
        return max(self.raw_balance_due, Decimal("0.00")).quantize(Decimal("0.01"))

    @property
    def payment_status(self):
        if self.raw_balance_due < 0:
            return "credit"
        if self.balance_due == Decimal("0.00"):
            return "paid"
        if (
            self.paid_total > 0
            or self.credit_applied_total > 0
            or self.adjustment_credit_total > 0
        ):
            return "partial"
        return "unpaid"

    @property
    def is_overdue(self):
        return (
            self.due_date is not None
            and self.balance_due > Decimal("0.00")
            and self.due_date < timezone.localdate()
            and self.status != self.Status.CANCELLED
        )


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
    allocated_landed_cost = models.DecimalField(
        max_digits=10,
        decimal_places=2,
        default=0,
        validators=[MinValueValidator(Decimal("0.00"))],
    )
    landed_unit_cost = models.DecimalField(
        max_digits=10,
        decimal_places=2,
        default=0,
        validators=[MinValueValidator(Decimal("0.00"))],
    )
    effective_unit_cost = models.DecimalField(
        max_digits=10,
        decimal_places=2,
        default=0,
        validators=[MinValueValidator(Decimal("0.00"))],
    )

    class Meta:
        ordering = ["created_at"]

    @property
    def line_total(self):
        return (self.unit_cost * self.quantity).quantize(Decimal("0.01"))

    @property
    def effective_line_total(self):
        return (
            self.unit_cost * self.quantity + self.allocated_landed_cost
        ).quantize(Decimal("0.01"))

    def save(self, *args, **kwargs):
        if (
            self.allocated_landed_cost == Decimal("0.00")
            and self.landed_unit_cost == Decimal("0.00")
        ):
            self.effective_unit_cost = self.unit_cost
            update_fields = kwargs.get("update_fields")
            if update_fields is not None and "unit_cost" in update_fields:
                kwargs["update_fields"] = set(update_fields) | {"effective_unit_cost"}
        return super().save(*args, **kwargs)

    @property
    def adjusted_quantity(self) -> int:
        total = self.adjustment_lines.aggregate(total=Sum("quantity"))["total"]
        return total or 0

    @property
    def accepted_quantity(self) -> int:
        total = self.receipt_lines.aggregate(total=Sum("accepted_quantity"))["total"]
        if total is not None:
            return total
        if self.purchase_order.status == PurchaseOrder.Status.RECEIVED:
            return self.quantity
        return 0

    @property
    def damaged_quantity(self) -> int:
        total = self.receipt_lines.aggregate(total=Sum("damaged_quantity"))["total"]
        return total or 0

    @property
    def cancelled_quantity(self) -> int:
        total = self.receipt_lines.aggregate(total=Sum("cancelled_quantity"))["total"]
        return total or 0

    @property
    def received_quantity(self) -> int:
        return self.accepted_quantity + self.damaged_quantity

    @property
    def closed_quantity(self) -> int:
        return self.received_quantity + self.cancelled_quantity

    @property
    def outstanding_quantity(self) -> int:
        return max(self.quantity - self.closed_quantity, 0)

    @property
    def backordered_quantity(self) -> int:
        return self.outstanding_quantity

    @property
    def over_received_quantity(self) -> int:
        return max(self.received_quantity - self.quantity, 0)

    @property
    def adjustable_quantity(self) -> int:
        return max(self.accepted_quantity - self.adjusted_quantity, 0)


class PurchaseReceipt(TimeStampedModel):
    purchase_order = models.ForeignKey(
        PurchaseOrder,
        on_delete=models.PROTECT,
        related_name="receipts",
    )
    notes = models.TextField(blank=True)
    received_at = models.DateTimeField(default=timezone.now)
    created_by = models.ForeignKey(
        settings.AUTH_USER_MODEL,
        on_delete=models.SET_NULL,
        related_name="purchase_receipts",
        blank=True,
        null=True,
    )

    class Meta:
        ordering = ["-received_at", "-created_at"]

    def __str__(self) -> str:
        return f"Receipt {self.pk} for {self.purchase_order_id}"


class PurchaseReceiptLine(TimeStampedModel):
    receipt = models.ForeignKey(
        PurchaseReceipt,
        on_delete=models.CASCADE,
        related_name="lines",
    )
    purchase_line = models.ForeignKey(
        PurchaseLine,
        on_delete=models.PROTECT,
        related_name="receipt_lines",
    )
    product = models.ForeignKey(Product, on_delete=models.PROTECT)
    ordered_quantity = models.PositiveIntegerField()
    outstanding_before = models.PositiveIntegerField()
    accepted_quantity = models.PositiveIntegerField(default=0)
    damaged_quantity = models.PositiveIntegerField(default=0)
    cancelled_quantity = models.PositiveIntegerField(default=0)
    expected_reduction_quantity = models.PositiveIntegerField(default=0)
    over_received_quantity = models.PositiveIntegerField(default=0)
    outstanding_after = models.PositiveIntegerField(default=0)
    notes = models.TextField(blank=True)

    class Meta:
        ordering = ["created_at", "id"]

    @property
    def received_quantity(self) -> int:
        return self.accepted_quantity + self.damaged_quantity

    @property
    def backordered_quantity(self) -> int:
        return self.outstanding_after


class PurchaseOrderAdjustment(TimeStampedModel):
    class AdjustmentType(models.TextChoices):
        RETURN = "return", "Return"
        REFUND = "refund", "Refund"
        EXCHANGE = "exchange", "Exchange"

    class SettlementMethod(models.TextChoices):
        SUPPLIER_CREDIT = "supplier_credit", "Supplier credit"
        REFUND = "refund", "Refund"
        CASH = "cash", "Cash"
        CARD = "card", "Card"
        TRANSFER = "transfer", "Transfer"
        BANK_TRANSFER = "bank_transfer", "Bank transfer"

    purchase_order = models.ForeignKey(
        PurchaseOrder,
        on_delete=models.PROTECT,
        related_name="adjustments",
    )
    adjustment_type = models.CharField(max_length=16, choices=AdjustmentType.choices)
    amount = models.DecimalField(max_digits=10, decimal_places=2)
    outbound_amount = models.DecimalField(max_digits=10, decimal_places=2, default=0)
    replacement_amount = models.DecimalField(max_digits=10, decimal_places=2, default=0)
    net_amount = models.DecimalField(max_digits=10, decimal_places=2, default=0)
    settlement_method = models.CharField(
        max_length=24,
        choices=SettlementMethod.choices,
        blank=True,
    )
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


class SupplierPayment(TimeStampedModel):
    class Method(models.TextChoices):
        CASH = "cash", "Cash"
        CARD = "card", "Card"
        TRANSFER = "transfer", "Transfer"
        BANK_TRANSFER = "bank_transfer", "Bank transfer"
        SUPPLIER_CREDIT = "supplier_credit", "Supplier credit"
        REFUND = "refund", "Refund"

    supplier = models.ForeignKey(
        Supplier,
        on_delete=models.PROTECT,
        related_name="payments",
    )
    purchase_order = models.ForeignKey(
        PurchaseOrder,
        on_delete=models.PROTECT,
        related_name="supplier_payments",
        blank=True,
        null=True,
    )
    amount = models.DecimalField(
        max_digits=10,
        decimal_places=2,
        validators=[MinValueValidator(Decimal("0.01"))],
    )
    method = models.CharField(max_length=24, choices=Method.choices)
    reference = models.CharField(max_length=128, blank=True)
    notes = models.TextField(blank=True)
    paid_at = models.DateTimeField(default=timezone.now)
    created_by = models.ForeignKey(
        settings.AUTH_USER_MODEL,
        on_delete=models.SET_NULL,
        related_name="supplier_payments",
        blank=True,
        null=True,
    )

    class Meta:
        ordering = ["-paid_at", "-created_at"]

    def __str__(self) -> str:
        return f"{self.method} {self.amount} for supplier {self.supplier_id}"


class SupplierCredit(TimeStampedModel):
    class Status(models.TextChoices):
        OPEN = "open", "Open"
        USED = "used", "Used"

    supplier = models.ForeignKey(
        Supplier,
        on_delete=models.PROTECT,
        related_name="credits",
    )
    purchase_order = models.ForeignKey(
        PurchaseOrder,
        on_delete=models.PROTECT,
        related_name="supplier_credits",
    )
    adjustment = models.OneToOneField(
        PurchaseOrderAdjustment,
        on_delete=models.PROTECT,
        related_name="supplier_credit",
    )
    amount = models.DecimalField(
        max_digits=10,
        decimal_places=2,
        validators=[MinValueValidator(Decimal("0.01"))],
    )
    remaining_amount = models.DecimalField(
        max_digits=10,
        decimal_places=2,
        validators=[MinValueValidator(Decimal("0.00"))],
    )
    status = models.CharField(
        max_length=16,
        choices=Status.choices,
        default=Status.OPEN,
    )
    reason = models.TextField(blank=True)

    class Meta:
        ordering = ["created_at"]

    def __str__(self) -> str:
        return f"{self.remaining_amount} credit for supplier {self.supplier_id}"


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


class PurchaseOrderAdjustmentReplacementLine(TimeStampedModel):
    adjustment = models.ForeignKey(
        PurchaseOrderAdjustment,
        on_delete=models.CASCADE,
        related_name="replacement_lines",
    )
    product = models.ForeignKey(Product, on_delete=models.PROTECT)
    quantity = models.PositiveIntegerField()
    unit_cost = models.DecimalField(max_digits=10, decimal_places=2)

    class Meta:
        ordering = ["created_at"]

    @property
    def line_total(self):
        return (self.unit_cost * self.quantity).quantize(Decimal("0.01"))
