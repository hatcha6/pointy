from decimal import Decimal, ROUND_DOWN, ROUND_HALF_UP

from django.contrib.contenttypes.fields import GenericRelation
from django.core.validators import MinValueValidator
from django.conf import settings
from django.db import models, transaction
from django.db.models import Q, Sum
from django.utils import timezone

from apps.catalog.models import ProductVariant
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
        # Each order owes its total minus everything paid against it (cash or
        # applied credit) — i.e. ``raw_balance_due``. Batch the per-order paid
        # totals into one aggregate so a supplier with many orders does not fan
        # out into two queries per order.
        po_rows = (
            self.purchase_orders.exclude(status=PurchaseOrder.Status.CANCELLED)
            .annotate(_paid=Sum("supplier_payments__amount"))
            .values_list("total", "_paid")
        )
        outstanding = sum(
            (
                max(po_total - (paid or Decimal("0.00")), Decimal("0.00"))
                for po_total, paid in po_rows
            ),
            Decimal("0.00"),
        )
        unallocated = (
            self.payments.filter(purchase_order__isnull=True)
            .exclude(method=SupplierPayment.Method.SUPPLIER_CREDIT)
            .aggregate(total=Sum("amount"))["total"]
            or Decimal("0.00")
        )
        return max(outstanding - unallocated, Decimal("0.00")).quantize(Decimal("0.01"))

    @property
    def credit_balance(self):
        total = self.credits.filter(status=SupplierCredit.Status.OPEN).aggregate(
            total=Sum("remaining_amount")
        )["total"]
        return (total or Decimal("0.00")).quantize(Decimal("0.01"))

    @property
    def net_balance(self):
        return (self.payable_balance - self.credit_balance).quantize(Decimal("0.01"))


def _quantity_field(**kwargs):
    """A purchase-side quantity: decimal so fractional units (half an egg
    tray, 2.5 kg) transact; whole-number units are enforced at the serializer
    boundary via apps.catalog.units.validate_quantity, not the column type."""
    return models.DecimalField(
        max_digits=12,
        decimal_places=3,
        validators=[MinValueValidator(Decimal("0"))],
        **kwargs,
    )


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
        RETAIL_VALUE = "retail_value", "By retail value"
        EQUAL = "equal", "Equally by line"

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
    # One-off order-level discount entered by hand (independent of the
    # discount engine's rules/coupons); folded into discount_total by
    # recalculate(). Decimals welcome — its main job is killing fractions.
    extra_discount_amount = models.DecimalField(
        max_digits=10,
        decimal_places=2,
        default=Decimal("0.00"),
        validators=[MinValueValidator(Decimal("0.00"))],
    )
    discount_codes = models.JSONField(default=list, blank=True)
    # Snapshot of the special-day keys (apps.holidays) active on the shop-local
    # date this PO was created — an immutable feature signal for forecasting that
    # must survive later edits to the holiday calendar.
    special_day_keys = models.JSONField(default=list, blank=True)
    subtotal = models.DecimalField(max_digits=10, decimal_places=2, default=0)
    discount_total = models.DecimalField(
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
    attachments = GenericRelation(
        "attachments.Attachment",
        content_type_field="owner_content_type",
        object_id_field="owner_object_id",
        related_query_name="purchase_orders",
    )

    class Meta:
        ordering = ["-created_at"]
        # The PO list, payables view and dashboard aggregates all filter by
        # status and order by -created_at; this composite serves those plus the
        # default ordered listing (mirrors sales.Order's status/created index).
        indexes = [
            models.Index(
                fields=["status", "-created_at"],
                name="po_status_created_idx",
            ),
        ]
        permissions = [
            ("edit_draft_purchaseorder", "Can edit draft purchase order"),
            ("receive_purchaseorder", "Can receive purchase order"),
            ("adjust_received_purchaseorder", "Can adjust received purchase order"),
            ("cancel_purchaseorder", "Can cancel purchase order"),
        ]
        constraints = [
            models.UniqueConstraint(
                fields=["supplier", "supplier_invoice_number"],
                condition=~Q(supplier_invoice_number=""),
                name="unique_supplier_invoice_number_per_supplier",
            ),
        ]

    def recalculate(self):
        lines = list(
            self.lines.select_related("variant", "variant__product").order_by(
                "created_at",
                "id",
            )
        )
        discount_result = self.apply_discounts(lines)
        # One-off manual discount for THIS order (typed under the landed
        # costs; mostly a fraction eliminator). Folded into discount_total so
        # balances, payments, and receipts all see one number; clamped so the
        # combined discount never exceeds the subtotal.
        extra = min(
            self.extra_discount_amount or Decimal("0.00"),
            max(self.subtotal - self.discount_total, Decimal("0.00")),
        )
        self.discount_total = (self.discount_total + extra).quantize(
            self.MONEY_PLACES
        )
        landed_cost_total = self.landed_cost_total
        self.total = (
            self.subtotal - self.discount_total + landed_cost_total
        ).quantize(self.MONEY_PLACES)
        self.allocate_landed_costs(lines, landed_cost_total)
        self._discount_result = discount_result
        return discount_result

    def apply_discounts(self, lines):
        from apps.discounts.models import DiscountRule
        from apps.discounts.services import (
            DiscountContext,
            DiscountEngine,
            DiscountLineInput,
        )

        context = DiscountContext(
            channel=DiscountRule.Channel.PURCHASING,
            supplier_id=self.supplier_id,
            coupon_codes=tuple(self.discount_codes or ()),
            lines=tuple(
                DiscountLineInput(
                    key=str(line.pk),
                    product_id=line.variant.product_id,
                    variant_id=line.variant_id,
                    quantity=line.quantity,
                    unit_amount=line.unit_cost,
                    category_ids=tuple(
                        line.variant.product.categories.values_list("id", flat=True)
                    ),
                )
                for line in lines
            ),
        )
        result = DiscountEngine().calculate(context)
        allocations = {line.pk: Decimal("0.00") for line in lines}
        for application in result.applications:
            for allocation in application.allocations:
                allocations[int(allocation.line_key)] = (
                    allocations[int(allocation.line_key)] + allocation.amount
                ).quantize(self.MONEY_PLACES)

        self.subtotal = result.subtotal
        self.discount_total = result.discount_total
        for line in lines:
            discount_amount = allocations[line.pk]
            net_line_total = (line.line_total - discount_amount).quantize(
                self.MONEY_PLACES
            )
            net_unit_cost = Decimal("0.00")
            if line.quantity > 0:
                net_unit_cost = (net_line_total / Decimal(line.quantity)).quantize(
                    self.MONEY_PLACES,
                    rounding=ROUND_HALF_UP,
                )
            line.discount_amount = discount_amount
            line.net_line_total = net_line_total
            line.net_unit_cost = net_unit_cost
            line.save(
                update_fields=[
                    "discount_amount",
                    "net_line_total",
                    "net_unit_cost",
                    "updated_at",
                ],
            )
        return result

    @property
    def landed_cost_total(self):
        if self.pk is None:
            return Decimal("0.00")

        cached_entries = getattr(self, "_prefetched_objects_cache", {}).get(
            "landed_cost_entries"
        )
        if cached_entries is not None:
            return sum(
                (Decimal(entry.amount) for entry in cached_entries),
                Decimal("0.00"),
            ).quantize(self.MONEY_PLACES)

        total = self.landed_cost_entries.aggregate(total=Sum("amount"))["total"]
        return (total or Decimal("0.00")).quantize(self.MONEY_PLACES)

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
                line.net_unit_cost + landed_unit_cost
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
        if (
            self.landed_cost_allocation_method
            == self.LandedCostAllocationMethod.RETAIL_VALUE
        ):
            return {
                line.pk: (line.variant.unit_price * line.quantity).quantize(
                    self.MONEY_PLACES
                )
                for line in lines
            }
        if (
            self.landed_cost_allocation_method
            == self.LandedCostAllocationMethod.EQUAL
        ):
            return {line.pk: Decimal("1.00") for line in lines}
        return {line.pk: line.net_line_total for line in lines}

    def save(self, *args, **kwargs):
        from apps.discounts.models import normalize_coupon_code

        self.discount_codes = [
            normalize_coupon_code(code)
            for code in (self.discount_codes or [])
            if normalize_coupon_code(code)
        ]
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
        # Sum in Python so a prefetched ``supplier_payments`` is reused instead
        # of a per-order aggregate when serialising lists of purchase orders.
        total = sum(
            (
                payment.amount
                for payment in self.supplier_payments.all()
                if payment.method != SupplierPayment.Method.SUPPLIER_CREDIT
            ),
            Decimal("0.00"),
        )
        return total.quantize(Decimal("0.01"))

    @property
    def credit_applied_total(self):
        total = sum(
            (
                payment.amount
                for payment in self.supplier_payments.all()
                if payment.method == SupplierPayment.Method.SUPPLIER_CREDIT
            ),
            Decimal("0.00"),
        )
        return total.quantize(Decimal("0.01"))

    @property
    def adjustment_credit_total(self):
        # Sum in Python so a prefetched ``supplier_credits`` is reused instead
        # of a per-order aggregate when serialising lists of purchase orders
        # (``payment_status`` reaches this for every unpaid order).
        total = sum(
            (credit.amount for credit in self.supplier_credits.all()),
            Decimal("0.00"),
        )
        return total.quantize(Decimal("0.01"))

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


class PurchaseOrderLandedCostEntry(TimeStampedModel):
    purchase_order = models.ForeignKey(
        PurchaseOrder,
        on_delete=models.CASCADE,
        related_name="landed_cost_entries",
    )
    name = models.CharField(max_length=120)
    amount = models.DecimalField(
        max_digits=10,
        decimal_places=2,
        validators=[MinValueValidator(Decimal("0.00"))],
    )

    class Meta:
        ordering = ["created_at", "id"]

    def __str__(self) -> str:
        return f"{self.name} {self.amount}"


class PurchaseLine(TimeStampedModel):
    purchase_order = models.ForeignKey(
        PurchaseOrder,
        on_delete=models.CASCADE,
        related_name="lines",
    )
    variant = models.ForeignKey(
        ProductVariant,
        on_delete=models.PROTECT,
        related_name="purchase_lines",
    )
    # Fractional when the purchase unit allows it (half an egg tray, 2.5 kg);
    # whole-number units are enforced at the serializer via the same
    # apps.catalog.units.validate_quantity rule sales uses.
    quantity = models.DecimalField(
        max_digits=12,
        decimal_places=3,
        default=Decimal("1"),
        validators=[MinValueValidator(Decimal("0.001"))],
    )
    # The unit this line is purchased in (a UnitOfMeasure.code); blank = the
    # product's base unit. ``unit_factor`` snapshots how many base units one
    # purchase unit is worth and converts to base only at the stock boundary.
    # ``unit_cost`` is per purchase unit (cost of one carton), normalised to
    # per-base for the sales cost lookup.
    unit = models.CharField(max_length=32, blank=True, default="")
    unit_factor = models.DecimalField(
        max_digits=18,
        decimal_places=6,
        default=Decimal("1"),
        validators=[MinValueValidator(Decimal("0.000001"))],
    )
    unit_cost = models.DecimalField(
        max_digits=10,
        decimal_places=2,
        validators=[MinValueValidator(Decimal("0.00"))],
    )
    discount_amount = models.DecimalField(
        max_digits=10,
        decimal_places=2,
        default=0,
        validators=[MinValueValidator(Decimal("0.00"))],
    )
    net_line_total = models.DecimalField(
        max_digits=10,
        decimal_places=2,
        default=0,
        validators=[MinValueValidator(Decimal("0.00"))],
    )
    net_unit_cost = models.DecimalField(
        max_digits=10,
        decimal_places=2,
        default=0,
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
    expiry_date = models.DateField(null=True, blank=True, db_index=True)

    class Meta:
        ordering = ["created_at"]

    @property
    def line_total(self):
        return (self.unit_cost * self.quantity).quantize(Decimal("0.01"))

    def to_base_quantity(self, quantity) -> Decimal:
        """A quantity in this line's purchase unit → the product's base unit."""
        return (Decimal(quantity) * self.unit_factor).quantize(Decimal("0.001"))

    @property
    def base_unit_cost(self) -> Decimal:
        """``unit_cost`` re-expressed per base unit (per piece, not per carton)."""
        factor = self.unit_factor or Decimal("1")
        if factor <= 0:
            return self.unit_cost
        return (self.unit_cost / factor).quantize(Decimal("0.01"))

    @property
    def effective_line_total(self):
        return (
            self.net_line_total + self.allocated_landed_cost
        ).quantize(Decimal("0.01"))

    def save(self, *args, **kwargs):
        if self.discount_amount == Decimal("0.00"):
            self.net_line_total = self.line_total
            self.net_unit_cost = self.unit_cost
            update_fields = kwargs.get("update_fields")
            if update_fields is not None and (
                "unit_cost" in update_fields or "quantity" in update_fields
            ):
                kwargs["update_fields"] = set(update_fields) | {
                    "net_line_total",
                    "net_unit_cost",
                }
        if (
            self.allocated_landed_cost == Decimal("0.00")
            and self.landed_unit_cost == Decimal("0.00")
        ):
            self.effective_unit_cost = self.net_unit_cost
            update_fields = kwargs.get("update_fields")
            if update_fields is not None and (
                "unit_cost" in update_fields
                or "net_unit_cost" in update_fields
                or "discount_amount" in update_fields
            ):
                kwargs["update_fields"] = set(update_fields) | {"effective_unit_cost"}
        return super().save(*args, **kwargs)

    def _related_sum(self, relation_name, field):
        """Sum ``field`` over the ``relation_name`` reverse relation, reusing
        prefetched rows when present so serialising a page of orders does not
        run one aggregate query per line per field (aggregates always hit the
        DB, even with the relation prefetched). Returns None when there are no
        rows, matching SQL ``SUM`` over an empty set."""
        manager = getattr(self, relation_name)
        prefetched = getattr(self, "_prefetched_objects_cache", None)
        if prefetched is not None and relation_name in prefetched:
            rows = manager.all()
            if not rows:
                return None
            return sum(getattr(row, field) for row in rows)
        return manager.aggregate(total=Sum(field))["total"]

    @property
    def adjusted_quantity(self) -> Decimal:
        return self._related_sum("adjustment_lines", "quantity") or Decimal("0")

    @property
    def accepted_quantity(self) -> Decimal:
        total = self._related_sum("receipt_lines", "accepted_quantity")
        if total is not None:
            return total
        if self.purchase_order.status == PurchaseOrder.Status.RECEIVED:
            return self.quantity
        return Decimal("0")

    @property
    def damaged_quantity(self) -> Decimal:
        return self._related_sum("receipt_lines", "damaged_quantity") or Decimal("0")

    @property
    def cancelled_quantity(self) -> Decimal:
        return self._related_sum("receipt_lines", "cancelled_quantity") or Decimal("0")

    @property
    def received_quantity(self) -> Decimal:
        return self.accepted_quantity + self.damaged_quantity

    @property
    def closed_quantity(self) -> Decimal:
        return self.received_quantity + self.cancelled_quantity

    @property
    def outstanding_quantity(self) -> Decimal:
        return max(self.quantity - self.closed_quantity, Decimal("0"))

    @property
    def backordered_quantity(self) -> Decimal:
        return self.outstanding_quantity

    @property
    def over_received_quantity(self) -> Decimal:
        return max(self.received_quantity - self.quantity, Decimal("0"))

    @property
    def adjustable_quantity(self) -> Decimal:
        return max(self.accepted_quantity - self.adjusted_quantity, Decimal("0"))


class PurchaseOrderAuditEvent(TimeStampedModel):
    class Action(models.TextChoices):
        CREATED = "created", "Created"
        UPDATED = "updated", "Updated"
        SUBMITTED = "submitted", "Submitted"
        RECEIVED = "received", "Received"
        ADJUSTED = "adjusted", "Adjusted"
        CANCELLED = "cancelled", "Cancelled"
        DELETED = "deleted", "Deleted"

    purchase_order = models.ForeignKey(
        PurchaseOrder,
        on_delete=models.SET_NULL,
        related_name="audit_events",
        blank=True,
        null=True,
    )
    order_number = models.CharField(max_length=32)
    action = models.CharField(max_length=24, choices=Action.choices)
    message = models.TextField(blank=True)
    details = models.JSONField(default=dict, blank=True)
    created_by = models.ForeignKey(
        settings.AUTH_USER_MODEL,
        on_delete=models.SET_NULL,
        related_name="purchase_order_audit_events",
        blank=True,
        null=True,
    )

    class Meta:
        ordering = ["-created_at", "-id"]

    def __str__(self) -> str:
        return f"{self.action} {self.order_number}"


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
    variant = models.ForeignKey(
        ProductVariant,
        on_delete=models.PROTECT,
        related_name="purchase_receipt_lines",
    )
    # All quantities are in the purchase line's unit and may be fractional
    # (receiving half an egg tray); non-negativity is enforced per field.
    ordered_quantity = _quantity_field()
    outstanding_before = _quantity_field()
    accepted_quantity = _quantity_field(default=Decimal("0"))
    damaged_quantity = _quantity_field(default=Decimal("0"))
    cancelled_quantity = _quantity_field(default=Decimal("0"))
    expected_reduction_quantity = _quantity_field(default=Decimal("0"))
    over_received_quantity = _quantity_field(default=Decimal("0"))
    outstanding_after = _quantity_field(default=Decimal("0"))
    expiry_date = models.DateField(null=True, blank=True, db_index=True)
    notes = models.TextField(blank=True)

    class Meta:
        ordering = ["created_at", "id"]

    @property
    def received_quantity(self) -> Decimal:
        return self.accepted_quantity + self.damaged_quantity

    @property
    def backordered_quantity(self) -> Decimal:
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
    variant = models.ForeignKey(
        ProductVariant,
        on_delete=models.PROTECT,
        related_name="purchase_adjustment_lines",
    )
    quantity = _quantity_field()
    unit_cost = models.DecimalField(max_digits=10, decimal_places=2)
    line_amount = models.DecimalField(max_digits=10, decimal_places=2, default=0)

    class Meta:
        ordering = ["created_at"]

    @property
    def line_total(self):
        return self.line_amount.quantize(Decimal("0.01"))

    def save(self, *args, **kwargs):
        if self.line_amount == Decimal("0.00"):
            self.line_amount = (self.unit_cost * self.quantity).quantize(Decimal("0.01"))
            update_fields = kwargs.get("update_fields")
            if update_fields is not None and (
                "unit_cost" in update_fields or "quantity" in update_fields
            ):
                kwargs["update_fields"] = set(update_fields) | {"line_amount"}
        return super().save(*args, **kwargs)


class PurchaseOrderAdjustmentReplacementLine(TimeStampedModel):
    adjustment = models.ForeignKey(
        PurchaseOrderAdjustment,
        on_delete=models.CASCADE,
        related_name="replacement_lines",
    )
    variant = models.ForeignKey(
        ProductVariant,
        on_delete=models.PROTECT,
        related_name="purchase_adjustment_replacement_lines",
    )
    quantity = _quantity_field()
    unit_cost = models.DecimalField(max_digits=10, decimal_places=2)

    class Meta:
        ordering = ["created_at"]

    @property
    def line_total(self):
        return (self.unit_cost * self.quantity).quantize(Decimal("0.01"))
