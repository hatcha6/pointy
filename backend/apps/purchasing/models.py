from decimal import Decimal, ROUND_DOWN, ROUND_HALF_UP

from django.contrib.contenttypes.fields import GenericRelation
from django.core.validators import MinValueValidator
from django.conf import settings
from django.db import models, transaction
from django.db.models import Q, Sum
from django.utils import timezone

from apps.catalog.models import ProductVariant
from apps.core.models import TimeStampedModel
from apps.documents.guards import DocumentQuerySetMixin, is_live
from apps.documents.models import DocumentMixin
from apps.documents.statuses import DocumentStatus


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
        # Primed in bulk by ``prime_supplier_balances`` when this supplier is
        # part of a serialized page or report; otherwise computed on demand.
        primed = getattr(self, "_payable_balance", None)
        if primed is not None:
            return primed
        # Each order owes its billable total — what was ordered, less anything
        # a receipt cancelled — minus everything paid against it (cash or
        # applied credit); i.e. ``raw_balance_due``. Batch the per-order paid
        # totals into one aggregate so a supplier with many orders does not fan
        # out into two queries per order.
        po_rows = (
            self.purchase_orders.exclude(status=PurchaseOrder.Status.CANCELLED)
            .annotate(
                _paid=Sum(
                    "supplier_payments__amount",
                    filter=~Q(supplier_payments__doc_status=DocumentStatus.CANCELLED),
                )
            )
            .values_list("pk", "total", "cancelled_total", "_paid")
        )
        outstanding = sum(
            (
                max(
                    po_total
                    - (cancelled or Decimal("0.00"))
                    - (paid or Decimal("0.00")),
                    Decimal("0.00"),
                )
                for _po_id, po_total, cancelled, paid in po_rows
            ),
            Decimal("0.00"),
        )
        unallocated = (
            self.payments.live()
            .filter(purchase_order__isnull=True)
            .exclude(method=SupplierPayment.Method.SUPPLIER_CREDIT)
            .aggregate(total=Sum("amount"))["total"]
            or Decimal("0.00")
        )
        return max(outstanding - unallocated, Decimal("0.00")).quantize(Decimal("0.01"))

    @property
    def credit_balance(self):
        primed = getattr(self, "_credit_balance", None)
        if primed is not None:
            return primed
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


class PurchaseOrderQuerySet(DocumentQuerySetMixin, models.QuerySet):
    pass


class PurchaseOrder(DocumentMixin, TimeStampedModel):
    MONEY_PLACES = Decimal("0.01")

    class Status(models.TextChoices):
        """Where the *delivery* has got to — not whether the document is live.

        Lifecycle moved to ``doc_status`` (draft / submitted / cancelled) when
        the order became a document. This field stayed, demoted to what it was
        always really describing: fulfilment progress. It is derived now,
        recomputed by ``apps.purchasing.documents.recompute_progress`` and
        written nowhere else, so it cannot drift the way ERPNext's hand-set
        statuses do. Every existing query that filters on it keeps working.
        """

        DRAFT = "draft", "Draft"
        SUBMITTED = "submitted", "Submitted"
        PARTIALLY_RECEIVED = "partially_received", "Partially received"
        RECEIVED = "received", "Received"
        CANCELLED = "cancelled", "Cancelled"

    objects = PurchaseOrderQuerySet.as_manager()

    class LandedCostAllocationMethod(models.TextChoices):
        LINE_VALUE = "line_value", "By line value"
        QUANTITY = "quantity", "By quantity"
        RETAIL_VALUE = "retail_value", "By retail value"
        EQUAL = "equal", "Equally by line"

    # Where the goods land. A shop with one place never sees this asked and
    # never has to answer it — the default is resolved in ``save``, which is
    # also what keeps every existing purchase order and every older client
    # working unchanged. Nullable for exactly one release, like every other
    # column this phase adds, so an older backend's inserts survive a flip.
    warehouse = models.ForeignKey(
        "inventory.Warehouse",
        on_delete=models.PROTECT,
        related_name="purchase_orders",
        blank=True,
    )
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
    # --- Supplier currency -------------------------------------------------
    # The currency the SUPPLIER invoiced in. NULL (the default, and every
    # existing order) means the shop's own currency.
    #
    # Every money column on this order and its lines stays base currency —
    # subtotal, discounts, landed costs, totals, and the ``unit_cost`` that
    # becomes stock valuation. What this adds is the foreign figure the buyer
    # actually read off the invoice, plus the rate that turned it into dinars,
    # so a cost basis can be audited instead of being a hand-typed guess.
    currency = models.ForeignKey(
        "fx.Currency",
        on_delete=models.PROTECT,
        related_name="purchase_orders",
        null=True,
        blank=True,
    )
    # Frozen on the document, exactly like a product's price rate. Seeded from
    # the resolver when the currency is chosen and editable while the order is a
    # draft — a shop that negotiated its own rate with a changer types that one,
    # and it is the rate the cost basis is built from either way.
    exchange_rate = models.DecimalField(
        max_digits=18,
        decimal_places=8,
        null=True,
        blank=True,
        validators=[MinValueValidator(Decimal("0"))],
    )
    rate_effective_at = models.DateTimeField(null=True, blank=True)
    rate_source = models.CharField(max_length=16, blank=True, default="")
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
    # The goods value of ordered units that will never arrive: whatever a
    # receipt closed as ``cancelled_quantity`` (the supplier could not supply
    # it, or the shop rejected it at the door). ``total`` stays the value of
    # what was *ordered* — it is the document's own number and the lines still
    # sum to it — so the units that fell out are carried here instead and
    # subtracted wherever the question is "what does the shop still owe".
    # Maintained by ``receive_purchase_order``, which recomputes it from every
    # receipt line each time (idempotent across repeated partial receipts).
    cancelled_total = models.DecimalField(
        max_digits=10,
        decimal_places=2,
        default=Decimal("0.00"),
        validators=[MinValueValidator(Decimal("0.00"))],
    )
    due_date = models.DateField(blank=True, null=True)
    # ``submitted_at`` now comes from DocumentMixin, with the submitting user
    # beside it — the same column, finally with the answer to "who".
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
            # Narrow POS capability: create a PO that is immediately received and
            # paid in cash from the holder's open register drawer. Grants none of
            # the wider PO lifecycle (drafting, receiving, cancelling).
            ("add_pos_cash_purchase", "Can create POS cash purchase"),
        ]
        constraints = [
            models.UniqueConstraint(
                fields=["supplier", "supplier_invoice_number"],
                condition=~Q(supplier_invoice_number=""),
                name="unique_supplier_invoice_number_per_supplier",
            ),
        ]

    # Every per-line figure ``recalculate`` derives; written back in ONE
    # ``bulk_update`` at the end instead of two saves per line.
    _RECALCULATED_LINE_FIELDS = (
        "discount_amount",
        "net_line_total",
        "net_unit_cost",
        "allocated_landed_cost",
        "landed_unit_cost",
        "effective_unit_cost",
        "updated_at",
    )

    def recalculate(self):
        lines = list(
            self.lines.select_related("variant", "variant__product")
            # The discount engine reads each line's product categories.
            .prefetch_related("variant__product__categories")
            .order_by("created_at", "id")
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
        # ...and pushed down onto the lines too. It is a discount on THESE
        # goods, so it has to reach every per-line cost figure derived from
        # net_line_total: net_unit_cost, effective_unit_cost (the cost basis a
        # margin is measured against) and purchase_adjustment_line_amount (the
        # credit a supplier owes for a return). Leaving it document-only made
        # sum(effective_line_total) overshoot the order total by exactly
        # `extra` — the lines claimed a cost the shop never paid.
        if extra > Decimal("0.00"):
            self._apply_extra_discount(lines, extra)
        self.discount_total = (self.discount_total + extra).quantize(
            self.MONEY_PLACES
        )
        landed_cost_total = self.landed_cost_total
        self.total = (
            self.subtotal - self.discount_total + landed_cost_total
        ).quantize(self.MONEY_PLACES)
        self.allocate_landed_costs(lines, landed_cost_total)
        self._flush_line_figures(lines)
        self._discount_result = discount_result
        return discount_result

    def _flush_line_figures(self, lines):
        """Persist what ``apply_discounts`` / ``allocate_landed_costs`` set on
        the lines in memory. ``bulk_update`` skips ``auto_now``, so
        ``updated_at`` is stamped here the way a save would."""
        if not lines:
            return
        now = timezone.now()
        for line in lines:
            line.updated_at = now
        PurchaseLine.objects.bulk_update(lines, self._RECALCULATED_LINE_FIELDS)

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
                    # ``.all()`` (not ``values_list``) so the prefetch in
                    # ``recalculate`` answers this instead of a query per line.
                    category_ids=tuple(
                        category.id
                        for category in line.variant.product.categories.all()
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
            self._write_line_net(line, allocations[line.pk])
        return result

    def _write_line_net(self, line, discount_amount):
        """Set a line's discount and the net figures derived from it (in
        memory — ``recalculate`` flushes every line at once)."""
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

    def _apply_extra_discount(self, lines, extra):
        """Spread the manual order-level discount over the lines in proportion
        to what each still costs after the engine's discounts, through the same
        largest-remainder allocator the engine uses so not one cent is created
        or lost. Weighting by ``net_line_total`` — whose sum is exactly the
        amount ``extra`` is already clamped to — is what keeps every share
        inside its own line, so no line can be discounted below zero."""
        from apps.discounts.services import allocate_discount_amount

        keys = {line.pk: f"{index:06d}" for index, line in enumerate(lines)}
        shares = {
            allocation.line_key: allocation.amount
            for allocation in allocate_discount_amount(
                extra,
                {keys[line.pk]: line.net_line_total for line in lines},
            )
        }
        for line in lines:
            share = shares.get(keys[line.pk], Decimal("0.00"))
            if share <= Decimal("0.00"):
                continue
            self._write_line_net(
                line,
                min(line.discount_amount + share, line.line_total),
            )

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
            # ``unit_price`` is per BASE unit (per egg, never per tray), while
            # ``quantity`` is in the line's purchase unit. Multiplying them
            # directly values a line of 5 cartons of 24 at five eggs' retail,
            # so on a mixed-unit order the freight lands almost entirely on the
            # loose-piece lines. Convert to base units first — the same rule
            # ``effective_base_unit_cost`` documents for the other direction.
            return {
                line.pk: (
                    line.variant.unit_price * line.to_base_quantity(line.quantity)
                ).quantize(self.MONEY_PLACES)
                for line in lines
            }
        if (
            self.landed_cost_allocation_method
            == self.LandedCostAllocationMethod.EQUAL
        ):
            return {line.pk: Decimal("1.00") for line in lines}
        return {line.pk: line.net_line_total for line in lines}

    def _follow_progress_on_insert(self):
        """Bridge for the migration window: an order created with a progress
        status and no lifecycle gets the lifecycle that status implies.

        Plenty of code — the POS cash purchase, the importer, the simulation,
        a hundred tests — creates a purchase order already submitted or already
        received. Until every one of those writers says so in the lifecycle's
        own words, the two fields are kept in step here rather than left to
        disagree. Only on insert, and only when the caller said nothing about
        the lifecycle: an explicit ``doc_status`` always wins.
        """
        from apps.documents.statuses import DocumentStatus

        if not self._state.adding or self.doc_status != DocumentStatus.DRAFT:
            return
        if self.status == PurchaseOrder.Status.DRAFT:
            return
        self.doc_status = (
            DocumentStatus.CANCELLED
            if self.status == PurchaseOrder.Status.CANCELLED
            else DocumentStatus.SUBMITTED
        )

    def save(self, *args, **kwargs):
        from apps.discounts.models import normalize_coupon_code

        if self.warehouse_id is None:
            from apps.inventory.models import Warehouse

            self.warehouse_id = Warehouse.default_id()
            if (
                self.warehouse_id is not None
                and kwargs.get("update_fields") is not None
            ):
                kwargs["update_fields"] = [*kwargs["update_fields"], "warehouse"]
        self._follow_progress_on_insert()
        self.discount_codes = [
            normalize_coupon_code(code)
            for code in (self.discount_codes or [])
            if normalize_coupon_code(code)
        ]
        if self.order_number:
            return super().save(*args, **kwargs)

        # The number and the row it belongs to are written as one unit, even
        # when the caller brought no transaction of its own. A number taken by
        # a write that then fails is a hole in the series, which is the thing
        # this is here to avoid.
        with transaction.atomic():
            self.order_number = self._next_order_number()
            update_fields = kwargs.get("update_fields")
            if update_fields is not None and "order_number" not in update_fields:
                kwargs["update_fields"] = [*update_fields, "order_number"]
            return super().save(*args, **kwargs)

    def _next_order_number(self) -> str:
        """The next number in the shop's purchase-order series.

        It used to be ``P{date}{self.id}`` — the row's own primary key, which
        meant the series inherited every gap a key is allowed to have. A
        rolled-back insert keeps the value it took, and PostgreSQL crash
        recovery resumes a sequence from the 32 values it had reserved in WAL
        rather than the ones it handed out; that is what skipped 155 receipt
        numbers in one field week. A supplier reconciling against these numbers
        has the same question a shop had about its invoices. See
        ``apps.documents.numbering``.

        Taking the number before the insert also costs one write per order
        instead of two, and removes the ``system_write`` escape the second write
        needed: an order created already submitted (the POS cash purchase, the
        importer) used to have its own numbering refused as an edit to a
        submitted document.
        """
        from apps.documents.numbering import (
            PURCHASE_ORDER_SERIES,
            next_document_number,
        )

        # `created_at` is auto_now_add, so it is not set until the insert; this
        # is the same clock it will be stamped from, and the date part of the
        # number is unchanged from when it was read off the saved row.
        issued_at = self.created_at or timezone.now()
        return (
            f"P{issued_at:%Y%m%d}{next_document_number(PURCHASE_ORDER_SERIES):06d}"
        )

    def __str__(self) -> str:
        return self.order_number or f"Purchase order {self.pk}"

    @property
    def paid_total(self):
        # Sum in Python so a prefetched ``supplier_payments`` is reused instead
        # of a per-order aggregate when serialising lists of purchase orders.
        # A cancelled payment is money that came back, so it stops counting —
        # the same effect deleting the row used to have, minus the amnesia.
        total = sum(
            (
                payment.amount
                for payment in self.supplier_payments.all()
                if payment.method != SupplierPayment.Method.SUPPLIER_CREDIT
                and is_live(payment)
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
                and is_live(payment)
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
    def billable_total(self):
        """What this order can ever be invoiced for.

        The ordered total less the goods that were cancelled at receipt. A
        supplier that ships 4 of the 10 crates ordered and cancels the rest
        bills for 4; billing the shop for 10 leaves a payable that no payment,
        credit or adjustment can ever clear, because cancelled units are not
        returnable either (``adjustable_quantity`` counts accepted units only).
        Landed costs are deliberately untouched — freight and customs were
        incurred on the shipment that did arrive.
        """
        return max(
            self.total - (self.cancelled_total or Decimal("0.00")),
            Decimal("0.00"),
        ).quantize(Decimal("0.01"))

    @property
    def raw_balance_due(self):
        return (
            self.billable_total
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
    # What the supplier's invoice says for one of this unit, in the ORDER's
    # currency. NULL for a base-currency order. ``unit_cost`` below is derived
    # from this at the order's frozen rate and stays the single number every
    # downstream figure is built on — net cost, landed cost, valuation, COGS,
    # margin — so none of them had to learn about currencies.
    unit_cost_in_currency = models.DecimalField(
        max_digits=10,
        decimal_places=2,
        null=True,
        blank=True,
        validators=[MinValueValidator(Decimal("0.00"))],
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
    def effective_base_unit_cost(self) -> Decimal:
        """``effective_unit_cost`` (net of discounts + landed costs) per base
        unit. Any comparison against a variant's ``unit_price`` (always per base
        unit) must use this, never the raw per-pack figure — a 162-per-carton
        line is 0.45 per egg, not a 161-dinar loss."""
        factor = self.unit_factor or Decimal("1")
        if factor <= 0:
            return self.effective_unit_cost
        return (self.effective_unit_cost / factor).quantize(Decimal("0.01"))

    @property
    def effective_base_unit_cost_exact(self) -> Decimal:
        """The same figure at the precision the ledger actually stores.

        ``effective_base_unit_cost`` rounds to money because that is what a
        screen shows and what a price comparison means. Stock does not: a
        100.00 carton of twelve is 8.33 on a label and 8.333333 in the bin, and
        rounding before the multiply books 99.96 of stock value against 100.00
        paid — four qirsh per carton, which on a thousand-carton delivery is a
        difference against the payable that nothing explains. ``incoming_rate``
        and ``StockMovement.unit_cost`` are six-place columns for this reason,
        so give them six places.
        """
        factor = self.unit_factor or Decimal("1")
        if factor <= 0:
            return self.effective_unit_cost
        return (self.effective_unit_cost / factor).quantize(Decimal("0.000001"))

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


class PurchaseReceiptQuerySet(DocumentQuerySetMixin, models.QuerySet):
    pass


class PurchaseReceipt(DocumentMixin, TimeStampedModel):
    """A delivery that arrived: what was accepted, damaged or refused.

    A document from the moment it exists — goods either turned up or they did
    not. It is retracted *with* its purchase order rather than on its own: the
    line-level totals that say how much of an order has arrived still count a
    cancelled receipt's rows, so an independently cancelled receipt would leave
    its order reading "received" with the goods off the shelf. Teaching those
    totals about cancellation is what a receipt-level undo needs, and it is not
    what this phase set out to do.
    """

    objects = PurchaseReceiptQuerySet.as_manager()

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


class SupplierPaymentQuerySet(DocumentQuerySetMixin, models.QuerySet):
    pass


class SupplierPayment(DocumentMixin, TimeStampedModel):
    """Money paid to a supplier, optionally against a specific purchase order.

    When paid in cash from an open register (the POS cash-purchase flow), the
    payment also records a linked ``RegisterCashMovement`` pay-out
    (``cash_movement``) so the drawer reconciles — mirroring
    ``expenses.Expense``. The unified expense ledger excludes such pay-outs from
    the register-pay-out source so a drawer-paid purchase is never counted twice.
    """

    objects = SupplierPaymentQuerySet.as_manager()

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
    register_session = models.ForeignKey(
        "sales.RegisterSession",
        on_delete=models.PROTECT,
        related_name="supplier_payments",
        blank=True,
        null=True,
    )
    cash_movement = models.OneToOneField(
        "sales.RegisterCashMovement",
        on_delete=models.PROTECT,
        related_name="supplier_payment",
        blank=True,
        null=True,
    )
    # Which of the shop's bank accounts this money left. NULL means the shop
    # did not say, and routes to the default account of its kind — the
    # behaviour of every row written before this column existed. Only a bank
    # account is ever named: a cash pay-out already carries its drawer
    # (``cash_movement``).
    money_account = models.ForeignKey(
        "treasury.MoneyAccount",
        on_delete=models.PROTECT,
        related_name="supplier_payments",
        blank=True,
        null=True,
    )
    created_by = models.ForeignKey(
        settings.AUTH_USER_MODEL,
        on_delete=models.SET_NULL,
        related_name="supplier_payments",
        blank=True,
        null=True,
    )

    class Meta:
        ordering = ["-paid_at", "-created_at"]
        indexes = [
            # The money position sums supplier payments by method over a date
            # range; ``paid_at`` is the money date and carried no index.
            models.Index(
                fields=["method", "-paid_at"],
                name="supplier_payment_method_idx",
            ),
            # …and now asks it once per bank account.
            models.Index(
                fields=["money_account", "method", "-paid_at"],
                name="supplier_payment_account_idx",
            ),
        ]

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


def prime_supplier_balances(suppliers):
    """Compute ``payable_balance``/``credit_balance`` for many suppliers using a
    fixed 3 queries instead of 6 per supplier.

    Serializing a supplier reads ``payable_balance`` (2 queries), then
    ``credit_balance`` (1), then ``net_balance`` — which re-ran both. That is 6
    queries per row: a 50-row supplier page cost ~300 queries. The arithmetic
    here is identical to the properties above (only the *fetching* is batched),
    so a primed supplier and a cold one always agree.

    Measured on ``supplier-list`` (SQLite, 2 orders + 1 payment per supplier):
    6.0 queries/row -> 0.0. A full 50-row page goes 303 -> 6 queries; 20 rows
    129 -> 6; a single supplier (retrieve/create/update) 8 -> 5.
    """
    suppliers = list(suppliers)
    ids = [supplier.pk for supplier in suppliers if supplier.pk is not None]
    if not ids:
        return suppliers

    zero = Decimal("0.00")
    outstanding = {}
    po_rows = (
        PurchaseOrder.objects.filter(supplier_id__in=ids)
        .exclude(status=PurchaseOrder.Status.CANCELLED)
        .annotate(
            _paid=Sum(
                "supplier_payments__amount",
                filter=~Q(supplier_payments__doc_status=DocumentStatus.CANCELLED),
            )
        )
        .values_list("supplier_id", "pk", "total", "cancelled_total", "_paid")
    )
    for supplier_id, _po_id, po_total, cancelled, paid in po_rows:
        outstanding[supplier_id] = outstanding.get(supplier_id, zero) + max(
            po_total - (cancelled or zero) - (paid or zero), zero
        )

    unallocated = {
        row["supplier_id"]: row["total"] or zero
        for row in (
            SupplierPayment.objects.live()
            .filter(
                supplier_id__in=ids,
                purchase_order__isnull=True,
            )
            .exclude(method=SupplierPayment.Method.SUPPLIER_CREDIT)
            .values("supplier_id")
            .annotate(total=Sum("amount"))
        )
    }
    open_credits = {
        row["supplier_id"]: row["total"] or zero
        for row in (
            SupplierCredit.objects.filter(
                supplier_id__in=ids,
                status=SupplierCredit.Status.OPEN,
            )
            .values("supplier_id")
            .annotate(total=Sum("remaining_amount"))
        )
    }

    for supplier in suppliers:
        supplier._payable_balance = max(
            outstanding.get(supplier.pk, zero) - unallocated.get(supplier.pk, zero),
            zero,
        ).quantize(Decimal("0.01"))
        supplier._credit_balance = open_credits.get(supplier.pk, zero).quantize(
            Decimal("0.01")
        )
    return suppliers


class SupplierPurchaseHabit(TimeStampedModel):
    """How this shop habitually buys one product from one supplier.

    A denormalized rollup of the supplier's purchase history, rebuilt by
    :mod:`apps.purchasing.suggestions` — never edited by hand and never a source
    of truth for anything financial. It exists so the purchasing screen can
    answer "how many of these do we usually buy?" without aggregating
    ``PurchaseLine`` on every draft change (the read pattern that made the
    purchases list hang at 12K orders).

    ``typical_quantity`` is NULL whenever the shop's quantities for this pair are
    not repeatable enough to state — the feature stays silent rather than
    inventing a number that would flow into stock and cost basis.
    """

    supplier = models.ForeignKey(
        Supplier,
        on_delete=models.CASCADE,
        related_name="purchase_habits",
    )
    variant = models.ForeignKey(
        ProductVariant,
        on_delete=models.CASCADE,
        related_name="purchase_habits",
    )
    # Distinct purchase orders in the window that contain this variant, and the
    # same count with each order weighted by recency (see suggestions.decay).
    order_count = models.PositiveIntegerField(default=0)
    weighted_count = models.FloatField(default=0.0)
    last_ordered_at = models.DateTimeField(null=True, blank=True)

    # The habitual quantity, in the habitual purchase unit. Both travel together
    # — "12" is meaningless without knowing whether it counts cartons or pieces,
    # and unit_factor is what keeps the cost-per-base-unit arithmetic honest.
    typical_quantity = _quantity_field(null=True, blank=True)
    typical_unit = models.CharField(max_length=32, blank=True, default="")
    typical_unit_factor = models.DecimalField(
        max_digits=18,
        decimal_places=6,
        default=Decimal("1"),
        validators=[MinValueValidator(Decimal("0.000001"))],
    )
    # Share of the recent purchases that were for exactly ``typical_quantity``.
    quantity_confidence = models.FloatField(default=0.0)

    # Purchase cadence, for the "due again" suggestion. ``interval_cv`` is the
    # coefficient of variation (stdev / mean) of the gaps between orders: low
    # means a regular rhythm, high means sporadic buying we must not predict.
    avg_interval_days = models.FloatField(null=True, blank=True)
    interval_cv = models.FloatField(null=True, blank=True)
    # When this product becomes "due again", precomputed so the read is an
    # indexed ``next_due_at <= now`` instead of per-row date arithmetic. NULL
    # whenever the cadence is too irregular (or too thinly evidenced) to predict
    # — the overwhelming majority of pairs, and deliberately so.
    next_due_at = models.DateTimeField(null=True, blank=True)

    # ``weighted_count`` as a share of the supplier's total weighted order mass:
    # 1.0 = on literally every order from this supplier. Drives the "usual
    # order" basket, and stored rather than divided at read time so that basket
    # is one indexed query.
    presence_ratio = models.FloatField(default=0.0)

    # Mean normalized entry position across the window's orders: 0.0 = always
    # the first line typed, 1.0 = always the last. Only ever a tie-breaker —
    # imported history whose lines share one timestamp collapses this to 0.5 for
    # everything, which is harmless.
    avg_position = models.FloatField(default=0.0)

    last_base_unit_cost = models.DecimalField(
        max_digits=10,
        decimal_places=2,
        null=True,
        blank=True,
        validators=[MinValueValidator(Decimal("0.00"))],
    )

    class Meta:
        constraints = [
            models.UniqueConstraint(
                fields=["supplier", "variant"],
                name="purchasing_habit_supplier_variant_uniq",
            )
        ]
        indexes = [
            models.Index(
                fields=["supplier", "-weighted_count"],
                name="purch_habit_rank_idx",
            ),
            models.Index(
                fields=["supplier", "next_due_at"],
                name="purch_habit_due_idx",
            ),
            models.Index(
                fields=["supplier", "-presence_ratio"],
                name="purch_habit_basket_idx",
            ),
        ]

    def __str__(self) -> str:
        return f"{self.supplier_id}/{self.variant_id}"


class SupplierPurchaseAffinity(TimeStampedModel):
    """"What gets bought with what", per supplier — the "next product" signal.

    One directed row per (supplier, anchor, neighbour): given that ``anchor`` is
    already on the draft, ``confidence`` is the recency-weighted share of this
    supplier's orders containing the anchor that also contained ``variant``.
    Both directions are stored so a read is a single indexed lookup.

    Bounded by construction: only the top neighbours per anchor survive, and only
    above the support floors in :mod:`apps.purchasing.suggestions`.
    """

    supplier = models.ForeignKey(
        Supplier,
        on_delete=models.CASCADE,
        related_name="purchase_affinities",
    )
    anchor_variant = models.ForeignKey(
        ProductVariant,
        on_delete=models.CASCADE,
        related_name="+",
    )
    variant = models.ForeignKey(
        ProductVariant,
        on_delete=models.CASCADE,
        related_name="+",
    )
    together_count = models.PositiveIntegerField(default=0)
    confidence = models.FloatField(default=0.0)

    class Meta:
        constraints = [
            models.UniqueConstraint(
                fields=["supplier", "anchor_variant", "variant"],
                name="purchasing_affinity_pair_uniq",
            )
        ]
        indexes = [
            models.Index(
                fields=["supplier", "anchor_variant", "-confidence"],
                name="purch_affinity_anchor_idx",
            ),
        ]

    def __str__(self) -> str:
        return f"{self.anchor_variant_id}→{self.variant_id}"


class SupplierPurchaseProfile(TimeStampedModel):
    """Per-supplier rollup that the habit rows are measured against.

    ``version`` is bumped on every rebuild and is what read caches key on, so a
    freshly received delivery invalidates that supplier's cached suggestions and
    nobody else's.
    """

    supplier = models.OneToOneField(
        Supplier,
        on_delete=models.CASCADE,
        related_name="purchase_profile",
    )
    # Purchase orders in the evidence window (capped — see suggestions.MAX_ORDERS).
    order_count = models.PositiveIntegerField(default=0)
    # The same count with each order weighted by recency; the denominator of
    # every habit's ``presence_ratio`` and every affinity's ``confidence``.
    weighted_orders = models.FloatField(default=0.0)
    rebuilt_at = models.DateTimeField(null=True, blank=True)
    version = models.PositiveIntegerField(default=0)

    def __str__(self) -> str:
        return f"profile/{self.supplier_id}"
