from datetime import date
from decimal import Decimal

from django.contrib.contenttypes.models import ContentType
from django.db import models, transaction
from django.db.models import Prefetch, prefetch_related_objects
from django.utils import timezone
from rest_framework import serializers
from rest_framework.exceptions import PermissionDenied

from apps.analytics.models import AnalyticsEvent
from apps.analytics.services import record_domain_event
from apps.documents import services as document_services
from apps.documents.statuses import DocumentStatus
from apps.holidays.services import special_day_keys_for
from apps.discounts.models import (
    AppliedDiscount,
    DiscountRedemption,
    normalize_coupon_code,
)
from apps.discounts.services import DiscountUsageLimitExceeded, persist_applied_discounts
from apps.inventory import tracking
from apps.inventory.models import (
    StockLedgerEntry,
    StockMovement,
    StockUnit,
)
from apps.sales.registers import selling_warehouse_id
from apps.inventory.services import (
    build_stock_movement,
    consume_expiring_stock_batches,
    create_expiring_stock_batch,
    discard_expiring_stock_batches,
    create_stock_movement,
    create_stock_movements,
    lock_stock_item,
    lock_stock_items,
    save_stock_item_quantities,
    save_stock_item_quantities_bulk,
    stock_snapshot,
)
from . import documents as purchase_documents
from .models import (
    PurchaseLine,
    PurchaseOrder,
    PurchaseOrderAdjustment,
    PurchaseOrderAdjustmentLine,
    PurchaseOrderAdjustmentReplacementLine,
    PurchaseOrderAuditEvent,
    PurchaseOrderLandedCostEntry,
    PurchaseReceipt,
    PurchaseReceiptLine,
    Supplier,
    SupplierCredit,
    SupplierPayment,
)
from .tasks import schedule_supplier_refresh


_DATE_MIN = date.min


def latest_purchase_line_for_variant(variant_id, *, before_line=None):
    lines = PurchaseLine.objects.filter(variant_id=variant_id).exclude(
        purchase_order__status=PurchaseOrder.Status.CANCELLED,
    )
    if before_line is not None:
        lines = lines.exclude(pk=before_line.pk)
        if before_line.created_at is not None:
            lines = lines.filter(created_at__lt=before_line.created_at)
    return lines.order_by("-created_at", "-id").first()


def _previous_purchase_line_query():
    """The previous purchase of the same variant, as a correlated subquery.

    One definition of the selection rule ``latest_purchase_line_for_variant``
    applies — same variant, not on a cancelled order, strictly older, newest
    first with ``-id`` breaking ties — shared by both batching strategies below.
    The ``exclude(pk=before_line.pk)`` there is redundant here because
    ``created_at`` is ``auto_now_add`` (never null on a saved row), so
    ``created_at__lt`` already rules the line itself out.
    """
    return (
        PurchaseLine.objects.filter(variant_id=models.OuterRef("variant_id"))
        .exclude(purchase_order__status=PurchaseOrder.Status.CANCELLED)
        .filter(created_at__lt=models.OuterRef("created_at"))
        .order_by("-created_at", "-id")
    )


def previous_purchase_line_annotations():
    """The previous purchase's raw cost columns, for a ``PurchaseLine`` queryset
    that is already being read — 0 extra queries instead of the primer's 2.

    ``previous_purchase_lines_for`` below batches the lookup for any caller that
    hands the serializer bare lines. When the lines arrive from a queryset we
    control, though, they can carry the answer already: the PO detail tree
    prefetches ``lines`` regardless, so folding these two subqueries into that
    prefetch makes the payload flat in the line count. It also stops the primer
    repeating per order on ``supplier-purchase-history``, which serializes a
    whole page of orders through the detail serializer.

    Only the previous line's RAW columns are annotated — the per-base-unit
    division stays in ``_base_unit_cost_of`` so every path runs one arithmetic
    implementation. Dividing in SQL would break that: Django's SQLite decimal
    converter quantizes an annotated value to the declared scale, and re-scaled
    to a 162-per-carton pack that drift is a phantom "cost changed" flag.
    """
    previous = _previous_purchase_line_query()
    return {
        "previous_line_unit_cost": models.Subquery(previous.values("unit_cost")[:1]),
        "previous_line_unit_factor": models.Subquery(
            previous.values("unit_factor")[:1]
        ),
    }


def previous_purchase_lines_for(lines):
    """Batched ``latest_purchase_line_for_variant(variant_id, before_line=line)``
    for many lines at once — 2 queries total instead of 1 per line.

    Serializing a purchase order reads ``previous_unit_cost`` on every line (it
    drives the "cost changed" flag), and each read was its own
    ``ORDER BY created_at LIMIT 1`` lookup: the last per-line query on
    ``purchaseorder-detail``. Measured on a 20-line order: retrieve 43 -> 24
    queries (1.0 -> 0.0 per line).

    Returns ``{line_pk: PurchaseLine | None}``, selected by
    ``_previous_purchase_line_query``. Lines that already carry the annotations
    from ``previous_purchase_line_annotations`` never reach here — the serializer
    filters them out first.
    """
    rows = [
        line
        for line in lines
        if line.pk is not None and line.variant_id is not None
    ]
    if not rows:
        return {}

    previous = _previous_purchase_line_query()
    previous_ids = dict(
        PurchaseLine.objects.filter(pk__in=[line.pk for line in rows])
        .annotate(previous_line_id=models.Subquery(previous.values("pk")[:1]))
        .values_list("pk", "previous_line_id")
    )
    # ``in_bulk`` short-circuits on an empty id list, so a page of first-ever
    # purchases costs one query, not two.
    found = PurchaseLine.objects.in_bulk(
        [line_id for line_id in previous_ids.values() if line_id is not None]
    )
    return {
        line_pk: found.get(previous_id)
        for line_pk, previous_id in previous_ids.items()
    }


def latest_purchase_line_for_product(product_id, *, variant_id=None, before_line=None):
    if variant_id is not None:
        return latest_purchase_line_for_variant(variant_id, before_line=before_line)

    lines = PurchaseLine.objects.filter(variant__product_id=product_id).exclude(
        purchase_order__status=PurchaseOrder.Status.CANCELLED,
    )
    if before_line is not None:
        lines = lines.exclude(pk=before_line.pk)
        if before_line.created_at is not None:
            lines = lines.filter(created_at__lt=before_line.created_at)
    return lines.order_by("-created_at", "-id").first()


def latest_variant_unit_cost(variant_id):
    line = latest_purchase_line_for_variant(variant_id)
    # Normalise to per *base* unit so the sales cost lookup (which multiplies by
    # the line's own unit factor) stays correct even when the purchase was a pack.
    return None if line is None else line.base_unit_cost


def latest_variant_unit_costs(variant_ids):
    """Batched ``latest_variant_unit_cost`` — ``{variant_id: base_unit_cost}`` for
    the given variants in ONE query (no N+1). Variants with no non-cancelled
    purchase are absent from the result. Backend-agnostic: rows come back
    newest-first per variant and the first seen wins (no Postgres-only DISTINCT ON).
    """
    ids = {variant_id for variant_id in variant_ids if variant_id is not None}
    if not ids:
        return {}
    costs = {}
    lines = (
        PurchaseLine.objects.filter(variant_id__in=ids)
        .exclude(purchase_order__status=PurchaseOrder.Status.CANCELLED)
        .order_by("variant_id", "-created_at", "-id")
        .only("variant_id", "unit_cost", "unit_factor", "created_at", "id")
    )
    for line in lines.iterator():
        if line.variant_id not in costs:
            costs[line.variant_id] = line.base_unit_cost
    return costs


def latest_product_unit_cost(product_id, *, variant_id=None):
    if variant_id is not None:
        return latest_variant_unit_cost(variant_id)

    line = latest_purchase_line_for_product(product_id)
    # Per base unit, like the variant path — the raw column is per purchase
    # pack (162 for a carton), which would read as a per-piece cost here.
    return None if line is None else line.base_unit_cost


def supplier_candidates_for_variants(variant_ids):
    """For each variant, the suppliers it has historically been purchased from, as a
    ranked list of candidates (not a single winner) so a caller can choose on the
    full evidence — recency, purchase frequency and price. Cancelled POs are
    excluded. One bulk query, aggregated in Python (no N+1).

    Returns ``{variant_id: [candidate, ...]}`` where each candidate rolls up that
    variant × supplier history::

        {
            "supplier_id", "supplier_name",
            "order_count",            # distinct purchase orders from this supplier
            "last_purchased_at",      # most recent purchase date (date or None)
            "last_base_unit_cost",    # cost-per-base-unit of the most recent line
            "last_unit", "last_unit_factor",  # purchase pack of the most recent line
            "avg_base_unit_cost", "min_base_unit_cost",
        }

    Candidates are sorted most-recent-first then by ``order_count`` as a sensible
    default, but every raw signal is exposed so the caller makes the final call. A
    variant with no purchase history is absent from the result (caller treats it as
    unassigned)."""
    ids = [int(v) for v in variant_ids if v is not None]
    if not ids:
        return {}

    lines = (
        PurchaseLine.objects.filter(variant_id__in=ids)
        .exclude(purchase_order__status=PurchaseOrder.Status.CANCELLED)
        .select_related("purchase_order", "purchase_order__supplier")
        .order_by("-created_at", "-id")  # newest first → first seen wins for "last_*"
    )

    # variant_id -> supplier_id -> rollup
    grouped: dict[int, dict[int, dict]] = {}
    for line in lines:
        po = line.purchase_order
        supplier = po.supplier if po is not None else None
        if supplier is None:
            continue
        per_variant = grouped.setdefault(line.variant_id, {})
        agg = per_variant.get(supplier.id)
        base_cost = line.base_unit_cost
        purchased_at = (po.received_at or po.created_at)
        purchased_date = purchased_at.date() if purchased_at is not None else None
        if agg is None:
            # First line seen for this supplier is the most recent (queryset is
            # ordered newest-first), so it defines the "last_*" snapshot.
            per_variant[supplier.id] = {
                "supplier_id": supplier.id,
                "supplier_name": supplier.name,
                "supplier_is_active": supplier.is_active,
                "order_ids": {po.id},
                "last_purchased_at": purchased_date,
                "last_base_unit_cost": base_cost,
                "last_unit": line.unit or "",
                "last_unit_factor": line.unit_factor or Decimal("1"),
                "_cost_sum": base_cost,
                "_cost_n": 1,
                "min_base_unit_cost": base_cost,
            }
        else:
            agg["order_ids"].add(po.id)
            agg["_cost_sum"] += base_cost
            agg["_cost_n"] += 1
            if base_cost < agg["min_base_unit_cost"]:
                agg["min_base_unit_cost"] = base_cost
            if purchased_date is not None and (
                agg["last_purchased_at"] is None
                or purchased_date > agg["last_purchased_at"]
            ):
                # Defensive: ordering should already guarantee this, but keep the
                # truly-latest date if created_at/received_at disagree.
                agg["last_purchased_at"] = purchased_date

    out: dict[int, list] = {}
    for variant_id, suppliers in grouped.items():
        candidates = []
        for agg in suppliers.values():
            n = agg.pop("_cost_n")
            cost_sum = agg.pop("_cost_sum")
            agg["order_count"] = len(agg.pop("order_ids"))
            agg["avg_base_unit_cost"] = (cost_sum / n).quantize(Decimal("0.01"))
            candidates.append(agg)
        candidates.sort(
            key=lambda c: (
                c["last_purchased_at"] or _DATE_MIN,
                c["order_count"],
            ),
            reverse=True,
        )
        out[variant_id] = candidates
    return out


def default_purchase_pack_for_product(product, *, preferred_unit_code=None):
    """The unit a reorder quantity should be expressed in for ``product``.

    Prefers the unit a supplier last actually bought in (``preferred_unit_code``,
    when that product still has a purchasable ProductUnit for it). Otherwise the
    largest purchasable pack (so we suggest whole cartons rather than loose pieces),
    falling back to the base unit. Returns ``(unit_code, factor_to_base)`` where an
    empty ``unit_code`` means the product's base unit (factor 1)."""
    units = [u for u in product.units.all() if u.is_purchasable and u.unit.is_active]
    if preferred_unit_code:
        for u in units:
            if u.unit.code == preferred_unit_code:
                return u.unit.code, (u.factor_to_base or Decimal("1"))
    if units:
        biggest = max(units, key=lambda u: u.factor_to_base or Decimal("1"))
        return biggest.unit.code, (biggest.factor_to_base or Decimal("1"))
    return "", Decimal("1")


def purchase_created_by(request):
    if request is not None and request.user.is_authenticated:
        return request.user
    return None


def record_purchase_order_audit_event(
    purchase_order,
    action,
    *,
    request=None,
    created_by=None,
    message="",
    details=None,
):
    if created_by is None:
        created_by = purchase_created_by(request)
    audit_event = PurchaseOrderAuditEvent.objects.create(
        purchase_order=purchase_order,
        order_number=purchase_order.order_number,
        action=action,
        message=message,
        details=details or {},
        created_by=created_by,
    )
    action_value = str(action)
    record_domain_event(
        name=f"purchasing.purchase_order.{action_value}",
        event_type=AnalyticsEvent.EventType.AUDIT,
        severity=(
            AnalyticsEvent.Severity.WARNING
            if action_value
            in {
                PurchaseOrderAuditEvent.Action.ADJUSTED,
                PurchaseOrderAuditEvent.Action.CANCELLED,
                PurchaseOrderAuditEvent.Action.DELETED,
            }
            else AnalyticsEvent.Severity.INFO
        ),
        user=created_by,
        entity_type="purchase_order",
        entity_id=purchase_order.pk,
        attributes={
            "purchase_order_audit_event_id": audit_event.pk,
            "order_number": purchase_order.order_number,
            "action": action_value,
            "status": purchase_order.status,
            "supplier_id": purchase_order.supplier_id,
            "message_present": bool(message),
            "details": details or {},
        },
        metrics={"total": float(purchase_order.total)},
    )
    return audit_event


def decrement_expected(stock_item, quantity):
    expected_reduction = min(quantity, stock_item.quantity_expected)
    stock_item.quantity_expected -= expected_reduction
    return expected_reduction


def purchase_order_is_editable(purchase_order) -> bool:
    """Whether the order can still be corrected.

    A draft always can. A cancelled order never can. A submitted one can until
    money settles against it — the condition the document type declares as its
    in-place correction window, so this and the primitive cannot disagree.
    """
    if purchase_order.doc_status == DocumentStatus.DRAFT:
        return True
    if purchase_order.doc_status == DocumentStatus.CANCELLED:
        return False
    return purchase_documents.in_place_allowed(purchase_order)


def _require_receiving_permission(request):
    """Undoing and re-recording a receipt moves stock, which is not what the
    edit-a-draft permission grants. Service callers with no request (the
    importer, management commands) are not user actions and pass through."""
    user = getattr(request, "user", None)
    if user is None or not getattr(user, "is_authenticated", False):
        return
    if user.has_perm("purchasing.receive_purchaseorder"):
        return
    raise PermissionDenied(
        "Changing a received purchase order re-records its receipt, which "
        "needs the receiving permission."
    )


# Order fields that change what a line cost, and so what the stock it put on
# the shelf is worth. Editing one of these re-records the delivery the same way
# editing the lines does.
_COST_BASIS_FIELDS = frozenset(
    {
        "extra_discount_amount",
        "discount_codes",
        "landed_cost_allocation_method",
    }
)


def _receipt_totals_by_line(purchase_order):
    """Accepted/damaged/cancelled per purchase line, in one query.

    The line properties answer the same question, but each is its own
    aggregate — asking them line by line on a twenty-line order is sixty
    queries where this is one.
    """
    return {
        row["purchase_line_id"]: row
        for row in (
            PurchaseReceiptLine.objects.filter(
                purchase_line__purchase_order=purchase_order
            )
            # A retracted delivery did not arrive. This is what lets an order's
            # own reversal see its expectation as outstanding again once its
            # receipts have given the goods back.
            .exclude(receipt__doc_status=DocumentStatus.CANCELLED)
            .values("purchase_line_id")
            .annotate(
                accepted=models.Sum("accepted_quantity"),
                damaged=models.Sum("damaged_quantity"),
                cancelled=models.Sum("cancelled_quantity"),
            )
        )
    }


def _receiving_snapshots(purchase_order, *, lines):
    """What each line has already had received, taken before its receipts are
    undone. The ordered quantity rides along because that is what says whether
    the owner actually changed the line: an untouched line is put back exactly
    as it arrived, a changed one is re-received to its new quantity.
    """
    totals = _receipt_totals_by_line(purchase_order)
    # "Received, with nothing written down about it" is a real state — an
    # import, or a legacy one-shot receive — and it is the only case the
    # fallback below is for. An order whose deliveries were *retracted* also
    # has no live receipt totals, and must not be mistaken for one: its goods
    # have already come off the shelf, and taking them off twice is how a
    # cancellation ends up refusing itself for stock it just removed.
    has_receipt_rows = PurchaseReceiptLine.objects.filter(
        purchase_line__purchase_order=purchase_order
    ).exists()
    fully_received = (
        purchase_order.status == PurchaseOrder.Status.RECEIVED
        and not has_receipt_rows
    )
    snapshots = []
    for line in lines:
        row = totals.get(line.pk)
        if row is None:
            # An order that was received without its receipt being recorded
            # line by line (an import, or a legacy one-shot receive) still put
            # its goods on the shelf — the line properties say the same.
            accepted = line.quantity if fully_received else Decimal("0")
            damaged = cancelled = Decimal("0")
        else:
            accepted = row["accepted"] or Decimal("0")
            damaged = row["damaged"] or Decimal("0")
            cancelled = row["cancelled"] or Decimal("0")
        snapshots.append(
            {
                "line": line,
                "key": (line.variant_id, line.unit),
                "ordered": line.quantity,
                "accepted": accepted,
                "damaged": damaged,
                "cancelled": cancelled,
                "outstanding": max(
                    line.quantity - accepted - damaged - cancelled,
                    Decimal("0"),
                ),
            }
        )
    return snapshots


def _release_expected_stock(purchase_order, *, snapshots, created_by):
    """Reverse the expected-stock counters this order still holds. Used when
    its lines are about to be replaced, so their expectation cannot linger.
    Only what is still outstanding is released: units a receipt already
    turned into stock stopped being expected when it did.

    The whole order's stock rows are locked, written and journalled as one
    batch (the same shape ``receive_purchase_order`` uses): a twenty-line edit
    used to pay a lock, an update, an insert and a savepoint per line here,
    and again in ``_add_expected_stock``.
    """
    pending = sorted(
        (snapshot for snapshot in snapshots if snapshot["outstanding"] > 0),
        key=lambda row: row["line"].variant_id,
    )
    if not pending:
        return
    stock_items = lock_stock_items(
        [snapshot["line"].variant for snapshot in pending],
        warehouse=purchase_order.warehouse_id,
    )
    movements = []
    touched = {}
    for snapshot in pending:
        line = snapshot["line"]
        stock_item = stock_items[line.variant_id]
        before = stock_snapshot(stock_item)
        expected_reduction = decrement_expected(
            stock_item, line.to_base_quantity(snapshot["outstanding"])
        )
        if expected_reduction <= 0:
            continue
        touched[stock_item.pk] = stock_item
        movements.append(
            build_stock_movement(
                stock_item=stock_item,
                variant=line.variant,
                movement_type=StockMovement.Type.CANCEL_EXPECTED,
                quantity=expected_reduction,
                note=f"تعديل أمر شراء {purchase_order.order_number}",
                created_by=created_by,
                before=before,
            )
        )
    save_stock_item_quantities_bulk(touched.values())
    create_stock_movements(movements)


def _reverse_received_stock(purchase_order, *, snapshots, created_by):
    """Take the delivery back off the shelf so the edited order can put it back.

    Only accepted units ever reached ``quantity_on_hand`` — damaged and
    cancelled ones stopped at the expectation — so those are what comes off, at
    whatever the ledger says that stock is worth, exactly as a purchase return
    leaves. Refuses when the units are no longer there to take back: an order
    whose goods have already been sold can only be corrected with a return.
    """
    received = [
        (snapshot["line"], snapshot["accepted"])
        for snapshot in snapshots
        if snapshot["accepted"] > 0
    ]
    if received:
        stock_items = validate_purchase_stock_available(
            received, warehouse=purchase_order.warehouse_id
        )
        movements = []
        touched = {}
        for line, quantity in received:
            stock_item = stock_items[line.variant_id]
            before = stock_snapshot(stock_item)
            base_quantity = line.to_base_quantity(quantity)
            stock_item.quantity_on_hand -= base_quantity
            touched[stock_item.pk] = stock_item
            movements.append(
                build_stock_movement(
                    variant=line.variant,
                    stock_item=stock_item,
                    movement_type=StockMovement.Type.DECREASE,
                    quantity=base_quantity,
                    note=f"تعديل استلام {purchase_order.order_number}",
                    created_by=created_by,
                    before=before,
                )
            )
        # One write and one valuation pass for the whole take-back, valued
        # in line order exactly as the per-line version was.
        save_stock_item_quantities_bulk(touched.values())
        create_stock_movements(
            movements,
            voucher_type=StockLedgerEntry.VoucherType.PURCHASE_RETURN,
            voucher_id=purchase_order.pk,
        )
    # Expiry cohorts are keyed on the receipt lines that brought them in and
    # PROTECT them, so they go first; the edited order records its own receipt,
    # cohorts included.
    receipt_lines = list(
        PurchaseReceiptLine.objects.filter(receipt__purchase_order=purchase_order)
    )
    discard_expiring_stock_batches(receipt_lines=receipt_lines)
    PurchaseReceiptLine.objects.filter(
        receipt__purchase_order=purchase_order
    ).delete()
    purchase_order.receipts.all().delete()
    # Back to "ordered, nothing arrived" — the caller's save writes it, and
    # _rerecord_receiving puts the delivery back once the edit has settled.
    purchase_order.status = PurchaseOrder.Status.SUBMITTED
    purchase_order.received_at = None
    purchase_order.cancelled_total = Decimal("0.00")


def _replayed_receipt_quantities(snapshot, quantity, *, fully_received):
    """How much of an edited line to re-receive.

    An untouched line replays exactly what arrived, over-delivery included. A
    line whose quantity the owner changed is re-received to the new quantity:
    in full if that line had been closed (the point of such an edit is "12
    arrived, not 10"), otherwise up to what had actually arrived, leaving the
    rest outstanding as it was. A line that is new to a fully-received order
    arrives with it; one added to a part-delivered order stays outstanding.
    """
    zero = Decimal("0")
    if snapshot is None:
        if not fully_received:
            return zero, zero, zero, zero
        accepted, damaged, cancelled = quantity, zero, zero
    elif snapshot["ordered"] == quantity:
        accepted = snapshot["accepted"]
        damaged = snapshot["damaged"]
        cancelled = snapshot["cancelled"]
    elif snapshot["outstanding"] <= 0:
        damaged = min(snapshot["damaged"], quantity)
        cancelled = min(snapshot["cancelled"], quantity - damaged)
        accepted = quantity - damaged - cancelled
    else:
        accepted = min(snapshot["accepted"], quantity)
        damaged = min(snapshot["damaged"], quantity - accepted)
        cancelled = min(snapshot["cancelled"], quantity - accepted - damaged)
    over_received = max(accepted + damaged - quantity, zero)
    # A delivery can overshoot the order or fall short of it, never both at
    # once — the receipt validator refuses cancelled units alongside an
    # over-delivery, and a replay that did would be refused by its own order.
    if over_received > 0:
        cancelled = zero
    return accepted, damaged, cancelled, over_received


# The receipt an edit re-records is the same delivery, told again against the
# corrected order.
EDIT_RECEIPT_NOTE = "إعادة تسجيل الاستلام بعد تعديل أمر الشراء"


def _rerecord_receiving(purchase_order, *, snapshots, request):
    """Put the delivery back against the edited lines.

    Runs last, once the edit's discounts and landed costs have settled, so the
    stock goes back on the shelf valued at what the corrected order says it
    cost — which is the whole point of letting a received order be edited.
    """
    if not any(
        snapshot["accepted"] or snapshot["damaged"] or snapshot["cancelled"]
        for snapshot in snapshots
    ):
        return
    fully_received = all(snapshot["outstanding"] <= 0 for snapshot in snapshots)
    pools = {}
    for snapshot in snapshots:
        pools.setdefault(snapshot["key"], []).append(snapshot)

    lines_data = []
    for line in purchase_order.lines.select_related(
        "variant",
        "variant__product",
    ).order_by("created_at", "id"):
        pool = pools.get((line.variant_id, line.unit))
        snapshot = pool.pop(0) if pool else None
        accepted, damaged, cancelled, over_received = _replayed_receipt_quantities(
            snapshot,
            line.quantity,
            fully_received=fully_received,
        )
        if accepted + damaged + cancelled <= 0:
            continue
        lines_data.append(
            {
                "line": line,
                "accepted_quantity": accepted,
                "damaged_quantity": damaged,
                "cancelled_quantity": cancelled,
                "allowed_over_receipt_quantity": over_received,
                "expiry_date": line.expiry_date,
            }
        )
    if not lines_data:
        return
    receive_purchase_order(
        purchase_order,
        request=request,
        lines_data=lines_data,
        notes=EDIT_RECEIPT_NOTE,
    )
    purchase_order.refresh_from_db()


def _add_expected_stock(purchase_order, *, created_by):
    """Register the expected-stock counters for the order's current lines —
    the second half of an edit-while-submitted (mirrors submit). Batched like
    ``_release_expected_stock``."""
    lines = list(
        purchase_order.lines.select_related("variant", "variant__product").order_by(
            "variant_id"
        )
    )
    if not lines:
        return
    stock_items = lock_stock_items(
        [line.variant for line in lines], warehouse=purchase_order.warehouse_id
    )
    movements = []
    touched = {}
    for line in lines:
        stock_item = stock_items[line.variant_id]
        before = stock_snapshot(stock_item)
        expected_base = line.to_base_quantity(line.quantity)
        stock_item.quantity_expected += expected_base
        touched[stock_item.pk] = stock_item
        movements.append(
            build_stock_movement(
                stock_item=stock_item,
                variant=line.variant,
                movement_type=StockMovement.Type.EXPECTED,
                quantity=expected_base,
                note=f"شراء متوقع {purchase_order.order_number}",
                created_by=created_by,
                before=before,
            )
        )
    save_stock_item_quantities_bulk(touched.values())
    create_stock_movements(movements)


def _seeded_purchase_line(purchase_order, line_data):
    # ``units`` is a capture payload, not a column: the counter purchase reads
    # it off the line and hands it to the receipt (see
    # ``_counter_purchase_receipt_lines``). Dropped here rather than in each
    # caller so an ordinary purchase order that happens to carry one is saved
    # rather than refused with a TypeError.
    line_data = {key: value for key, value in line_data.items() if key != "units"}
    line = PurchaseLine(purchase_order=purchase_order, **line_data)
    line.net_line_total = line.line_total
    line.net_unit_cost = line.unit_cost
    line.effective_unit_cost = line.unit_cost
    return line


@transaction.atomic
def save_purchase_order_with_lines(
    *,
    purchase_order=None,
    lines_data=None,
    landed_cost_entries_data=None,
    request=None,
    **order_fields,
):
    """Create a draft, or correct an order that is already out in the world.

    The second half of that is the deliberate divergence from ERPNext, where a
    submitted document can only be fixed by cancelling it. Here it is a
    first-class route (``Correction.IN_PLACE``): the primitive checks that money
    has not settled, that the period is open and that the user may, and records
    the before/after of every field the rewrite touched — which is what the old
    bare "updated" audit line could never say.
    """
    if (
        purchase_order is not None
        and purchase_order.doc_status == DocumentStatus.SUBMITTED
    ):
        # Keep the structured error the API already speaks; the primitive would
        # otherwise refuse with its own generic "blocked" code.
        if not purchase_order_is_editable(purchase_order):
            raise serializers.ValidationError(
                {
                    "code": "purchase_order_settled",
                    "detail": (
                        "A purchase order cannot be changed once a payment "
                        "or credit is recorded against it."
                    ),
                }
            )
        return document_services.correct_in_place(
            purchase_order,
            mutate=lambda locked: _write_purchase_order_with_lines(
                purchase_order=locked,
                lines_data=lines_data,
                landed_cost_entries_data=landed_cost_entries_data,
                request=request,
                **order_fields,
            ),
            reason=order_fields.get("notes", "") or "تعديل أمر شراء",
            request=request,
        )
    return _write_purchase_order_with_lines(
        purchase_order=purchase_order,
        lines_data=lines_data,
        landed_cost_entries_data=landed_cost_entries_data,
        request=request,
        **order_fields,
    )


def _write_purchase_order_with_lines(
    *,
    purchase_order=None,
    lines_data=None,
    landed_cost_entries_data=None,
    request=None,
    **order_fields,
):
    is_create = purchase_order is None
    rebuild_expected = False
    snapshots = None
    if purchase_order is None:
        # Tag the PO with the special day(s) active on its creation date (the
        # user's "when ordered" choice) — a stable forecasting signal. Defensive:
        # degrades to an empty list, never blocks PO creation.
        if "special_day_keys" not in order_fields:
            order_fields["special_day_keys"] = special_day_keys_for()
        purchase_order = PurchaseOrder.objects.create(**order_fields)
    else:
        purchase_order = PurchaseOrder.objects.select_for_update().get(
            pk=purchase_order.pk
        )
        if purchase_order.status != PurchaseOrder.Status.DRAFT:
            # Anything money has not settled against can still be corrected, a
            # received order included: its expected stock, its delivery and its
            # receipt are all unwound here and rebuilt around the line
            # replacement below.
            if not purchase_order_is_editable(purchase_order):
                raise serializers.ValidationError(
                    {
                        "code": "purchase_order_settled",
                        "detail": (
                            "A purchase order cannot be changed once a payment "
                            "or credit is recorded against it."
                        ),
                    }
                )
            # Anything that moves a line's cost basis has to be re-recorded
            # against the stock it valued, not just the lines themselves: a
            # landed cost or an order-level discount changes what the delivery
            # was worth every bit as much as a corrected unit cost does.
            rebuild_expected = (
                lines_data is not None
                or landed_cost_entries_data is not None
                or bool(_COST_BASIS_FIELDS.intersection(order_fields))
            )
        if rebuild_expected:
            if purchase_order.status != PurchaseOrder.Status.SUBMITTED:
                _require_receiving_permission(request)
            _refuse_cost_edit_on_identified_stock(purchase_order)
            created_by = purchase_created_by(request)
            snapshots = _receiving_snapshots(
                purchase_order,
                lines=lock_purchase_lines_for_update(purchase_order),
            )
            _release_expected_stock(
                purchase_order, snapshots=snapshots, created_by=created_by
            )
            _reverse_received_stock(
                purchase_order, snapshots=snapshots, created_by=created_by
            )
        for field, value in order_fields.items():
            setattr(purchase_order, field, value)
        purchase_order.save()
        if lines_data is not None:
            purchase_order.lines.all().delete()

    if lines_data is not None:
        # One INSERT for the order's lines. ``PurchaseLine.save`` seeds the net
        # and effective figures from the raw ones; ``recalculate`` below
        # rewrites every one of them for the whole order in one statement, so
        # the seed only has to be the same starting point save() would give.
        PurchaseLine.objects.bulk_create(
            [
                _seeded_purchase_line(purchase_order, line_data)
                for line_data in lines_data
            ]
        )

    if rebuild_expected:
        # The order is already submitted, so the new lines take effect as
        # expected stock immediately — hold them to the same bar submit does.
        missing_expiry = purchase_order.lines.filter(
            variant__product__tracks_expiry=True,
            expiry_date__isnull=True,
        ).exists()
        if missing_expiry:
            raise serializers.ValidationError(
                {"lines": "Expiry date is required for products that track expiry."}
            )
        if not purchase_order.lines.exists():
            raise serializers.ValidationError(
                {"detail": "Purchase order must include at least one line."}
            )
        _add_expected_stock(purchase_order, created_by=purchase_created_by(request))

    if landed_cost_entries_data is not None:
        replace_purchase_order_landed_cost_entries(
            purchase_order,
            landed_cost_entries_data,
        )

    clear_purchase_order_applied_discounts(purchase_order)
    discount_result = purchase_order.recalculate()
    validate_requested_purchase_discount_codes(purchase_order, discount_result)
    purchase_order.save(
        update_fields=["subtotal", "discount_total", "total", "updated_at"]
    )
    persist_purchase_order_applied_discounts(purchase_order, discount_result)
    record_purchase_order_audit_event(
        purchase_order,
        (
            PurchaseOrderAuditEvent.Action.CREATED
            if is_create
            else PurchaseOrderAuditEvent.Action.UPDATED
        ),
        request=request,
    )
    if snapshots:
        _rerecord_receiving(purchase_order, snapshots=snapshots, request=request)
    # Editing a committed order rewrites what the shop actually bought, so the
    # suggestion tables have to be rebuilt from the corrected history too.
    if purchase_order.status != PurchaseOrder.Status.DRAFT:
        schedule_supplier_refresh(purchase_order.supplier_id)
    return purchase_order



def _refuse_cost_edit_on_identified_stock(purchase_order):
    """Refuse an edit that would un-receive identified stock.

    Editing a received order un-records the whole delivery and re-records it,
    which is exactly right for a quantity in a bin and exactly wrong for forty
    handsets: the identifiers were captured at the receiving bay and are not in
    this payload, so the re-record would either refuse for want of them or
    invent a second set — and the shop would own eighty units it never bought.

    §5.5 of the plan wants landed cost to *re-stamp* those units and repost
    rather than recreate them; until it does, this refuses rather than
    duplicating, and names the units so the owner knows what is in the way.
    The correction that still works is a purchase return, which moves the
    articles it names.
    """
    from apps.inventory.models import StockAllocation, StockLedgerEntry, StockUnit

    # Every article this order ever created, live or not. A sold handset still
    # points at the receipt line the edit is about to delete, and
    # ``source_receipt_line`` is ``SET_NULL`` — so leaving those out does not
    # make the edit safe, it makes it quietly destroy the provenance that
    # answers "where has this IMEI been".
    units = list(
        StockUnit.objects.filter(
            source_receipt_line__receipt__purchase_order=purchase_order,
        ).values_list("code", flat=True)[:10]
    )
    # A lot-tracked order has no units at all, and is the worse case: the
    # un-record leaves the old lot's balance untouched and the re-record has no
    # captured codes to work from, so it mints a second lot for the same goods
    # and the shop's stock value doubles.
    lots = []
    if not units:
        lots = list(
            StockAllocation.objects.filter(
                voucher_type=StockLedgerEntry.VoucherType.PURCHASE_RECEIPT,
                voucher_id=purchase_order.pk,
                direction=StockAllocation.Direction.IN,
                batch__isnull=False,
            )
            .values_list("batch__code", flat=True)
            .distinct()[:10]
        )
    if not units and not lots:
        # Nothing identified has been written yet, but the order may still hold
        # tracked lines that simply have not been received. Those are safe:
        # there is no article and no balance for the re-record to duplicate.
        return
    raise serializers.ValidationError(
        {
            "code": "purchase_order_has_identified_stock",
            "detail": (
                "لا يمكن تعديل تكلفة هذا الأمر لأن بضاعته مسجّلة بمعرّفات. "
                "استخدم مرتجع مشتريات بدلًا من ذلك."
            ),
            "stock_units": units,
            "stock_batches": lots,
        }
    )


def replace_purchase_order_landed_cost_entries(purchase_order, entries_data):
    purchase_order.landed_cost_entries.all().delete()
    PurchaseOrderLandedCostEntry.objects.bulk_create(
        [
            PurchaseOrderLandedCostEntry(
                purchase_order=purchase_order,
                name=entry["name"],
                amount=entry["amount"],
            )
            for entry in entries_data
        ]
    )
    if hasattr(purchase_order, "_prefetched_objects_cache"):
        purchase_order._prefetched_objects_cache.pop("landed_cost_entries", None)


def purchase_order_content_type():
    return ContentType.objects.get_for_model(PurchaseOrder, for_concrete_model=False)


def clear_purchase_order_applied_discounts(purchase_order):
    document_content_type = purchase_order_content_type()
    applied_discounts = AppliedDiscount.objects.filter(
        document_content_type=document_content_type,
        document_object_id=purchase_order.pk,
    )
    DiscountRedemption.objects.filter(applied_discount__in=applied_discounts).delete()
    applied_discounts.delete()


def validate_requested_purchase_discount_codes(purchase_order, discount_result):
    requested_codes = [
        normalize_coupon_code(code)
        for code in (purchase_order.discount_codes or [])
        if normalize_coupon_code(code)
    ]
    if not requested_codes:
        return

    applied_codes = {
        normalize_coupon_code(application.coupon_code)
        for application in discount_result.applications
        if application.coupon_code
    }
    missing_codes = [
        code for code in dict.fromkeys(requested_codes) if code not in applied_codes
    ]
    if missing_codes:
        raise serializers.ValidationError(
            {
                "discount_codes": (
                    "Discount code is invalid, disabled, expired, or unavailable: "
                    + ", ".join(missing_codes)
                )
            }
        )


def persist_purchase_order_applied_discounts(purchase_order, discount_result):
    lines_by_key = {
        str(line.pk): line
        for line in purchase_order.lines.select_related(
            "variant",
            "variant__product",
        ).order_by("created_at", "id")
    }
    try:
        return persist_applied_discounts(
            document=purchase_order,
            result=discount_result,
            line_objects_by_key=lines_by_key,
        )
    except DiscountUsageLimitExceeded as exc:
        raise serializers.ValidationError(
            discount_usage_limit_error_payload(exc, "discount_codes")
        )


def discount_usage_limit_error_payload(exc, field_name):
    if exc.coupon_codes:
        return {
            field_name: (
                "Discount code is invalid, disabled, expired, or unavailable: "
                + ", ".join(exc.coupon_codes)
            )
        }
    return {"detail": "A discount is no longer available."}


@transaction.atomic
def submit_purchase_order(purchase_order, *, request=None):
    locked_order = (
        PurchaseOrder.objects.select_for_update()
        .prefetch_related("lines__variant__product")
        .get(pk=purchase_order.pk)
    )
    if locked_order.status != PurchaseOrder.Status.DRAFT:
        raise serializers.ValidationError(
            {"detail": "Only draft purchase orders can be submitted."}
        )
    if not locked_order.lines.exists():
        raise serializers.ValidationError(
            {"detail": "Purchase order must include at least one line."}
        )
    missing_expiry = locked_order.lines.filter(
        variant__product__tracks_expiry=True,
        expiry_date__isnull=True,
    ).exists()
    if missing_expiry:
        raise serializers.ValidationError(
            {
                "lines": (
                    "Expiry date is required for products that track expiry."
                )
            }
        )

    created_by = purchase_created_by(request)
    for line in locked_order.lines.select_related(
        "variant",
        "variant__product",
    ).order_by("variant_id"):
        stock_item = lock_stock_item(
            variant=line.variant, warehouse=locked_order.warehouse_id
        )
        before = stock_snapshot(stock_item)
        # Stock is kept in base units; a line bought in packs becomes base units.
        expected_base = line.to_base_quantity(line.quantity)
        stock_item.quantity_expected += expected_base
        save_stock_item_quantities(stock_item)
        create_stock_movement(
            stock_item=stock_item,
            variant=line.variant,
            movement_type=StockMovement.Type.EXPECTED,
            quantity=expected_base,
            note=f"شراء متوقع {locked_order.order_number}",
            created_by=created_by,
            before=before,
        )

    # The lifecycle move itself belongs to the primitive: it stamps who and
    # when, checks the permission and the period, recomputes the progress field
    # and writes the document trail.
    locked_order = document_services.submit(locked_order, request=request)
    record_purchase_order_audit_event(
        locked_order,
        PurchaseOrderAuditEvent.Action.SUBMITTED,
        created_by=created_by,
    )
    # A committed order is evidence: tomorrow's suggestions for this supplier
    # should already know about today's. Best-effort and post-commit — never a
    # reason a submit can fail.
    schedule_supplier_refresh(locked_order.supplier_id)
    return locked_order


def lock_purchase_lines_for_update(purchase_order, *, line_ids=None, prime_totals=False):
    """Lock an order's lines (and their receipt/adjustment rows) for a write.

    With ``prime_totals`` the locked receipt and adjustment rows are also
    handed to the lines as prefetched relations, so ``accepted_quantity``,
    ``outstanding_quantity`` & co. answer from memory instead of running three
    aggregates per line per read — receiving a twenty-line order asked those
    questions three hundred times. The rows are the same ones the lock reads;
    only where they are kept changes. A caller that then writes receipt or
    adjustment rows must call ``refresh_purchase_line_totals`` before reading
    the properties again, which is why this is opt-in.
    """
    queryset = (
        PurchaseLine.objects.select_for_update()
        .filter(purchase_order=purchase_order)
        .select_related("variant", "variant__product")
        .order_by("pk")
    )
    if line_ids is not None:
        queryset = queryset.filter(pk__in=line_ids)
    lines = list(queryset)
    for line in lines:
        # ``accepted_quantity`` reads the order's status when nothing has been
        # received; the caller holds the order, so no query per line for it.
        line.purchase_order = purchase_order
    if lines:
        line_ids = [line.pk for line in lines]
        receipt_rows = (
            PurchaseReceiptLine.objects.select_for_update()
            .filter(purchase_line_id__in=line_ids)
            .order_by("pk")
        )
        adjustment_rows = (
            PurchaseOrderAdjustmentLine.objects.select_for_update()
            .filter(purchase_line_id__in=line_ids)
            .order_by("pk")
        )
        if prime_totals:
            prefetch_related_objects(
                lines,
                Prefetch("receipt_lines", queryset=receipt_rows),
                Prefetch("adjustment_lines", queryset=adjustment_rows),
            )
        else:
            list(receipt_rows)
            list(adjustment_rows)
    return lines


def refresh_purchase_line_totals(lines):
    """Re-read the receipt/adjustment rows behind the lines' quantity
    properties after a write changed them (two queries for the whole order)."""
    lines = list(lines)
    for line in lines:
        cache = getattr(line, "_prefetched_objects_cache", None)
        if cache:
            cache.pop("receipt_lines", None)
            cache.pop("adjustment_lines", None)
    if lines:
        prefetch_related_objects(lines, "receipt_lines", "adjustment_lines")


def latest_purchase_lines_for_variants(variant_ids):
    """Batched ``latest_purchase_line_for_variant``: ``{variant_id: line}`` for
    the newest non-cancelled purchase of each variant, in one query. Variants
    never bought are absent."""
    ids = {variant_id for variant_id in variant_ids if variant_id is not None}
    if not ids:
        return {}
    latest = {}
    lines = (
        PurchaseLine.objects.filter(variant_id__in=ids)
        .exclude(purchase_order__status=PurchaseOrder.Status.CANCELLED)
        .order_by("variant_id", "-created_at", "-id")
    )
    for line in lines.iterator():
        if line.variant_id not in latest:
            latest[line.variant_id] = line
    return latest


def default_receipt_lines(locked_order, lines=None):
    lines = lock_purchase_lines_for_update(locked_order) if lines is None else lines
    return [
        {
            "line": line,
            "accepted_quantity": line.outstanding_quantity,
            "damaged_quantity": 0,
            "cancelled_quantity": 0,
            "allowed_over_receipt_quantity": 0,
            "expiry_date": line.expiry_date,
            "notes": "",
        }
        for line in lines
        if line.outstanding_quantity > 0
    ]


def receipt_line_expected_quantities(line, accepted_quantity, damaged_quantity, cancelled_quantity):
    outstanding_before = line.outstanding_quantity
    accepted_expected = min(accepted_quantity, outstanding_before)
    remaining_after_accepted = max(outstanding_before - accepted_expected, 0)
    damaged_expected = min(damaged_quantity, remaining_after_accepted)
    remaining_after_damaged = max(remaining_after_accepted - damaged_expected, 0)
    cancelled_expected = min(cancelled_quantity, remaining_after_damaged)
    expected_reduction = accepted_expected + damaged_expected + cancelled_expected
    outstanding_after = max(outstanding_before - expected_reduction, 0)
    over_received = max(accepted_quantity + damaged_quantity - outstanding_before, 0)
    return {
        "outstanding_before": outstanding_before,
        "accepted_expected": accepted_expected,
        "damaged_expected": damaged_expected,
        "cancelled_expected": cancelled_expected,
        "expected_reduction": expected_reduction,
        "outstanding_after": outstanding_after,
        "over_received": over_received,
    }


def validate_receipt_line_quantities(
    line,
    accepted_quantity,
    damaged_quantity,
    cancelled_quantity,
    *,
    allowed_over_receipt_quantity=0,
):
    if accepted_quantity + damaged_quantity + cancelled_quantity <= 0:
        raise serializers.ValidationError(
            {"lines": "At least one received, damaged, or cancelled quantity is required."}
        )
    outstanding_before = line.outstanding_quantity
    received_quantity = accepted_quantity + damaged_quantity
    if received_quantity > outstanding_before + allowed_over_receipt_quantity:
        raise serializers.ValidationError(
            {"lines": "Received quantity exceeds the remaining outstanding quantity."}
        )
    if cancelled_quantity > 0:
        if accepted_quantity + damaged_quantity + cancelled_quantity > outstanding_before:
            raise serializers.ValidationError(
                {
                    "lines": (
                        "Cancelled quantity cannot be combined with quantities beyond "
                        "the outstanding order quantity."
                    )
                }
            )


def validate_receipt_line_expiry(line, accepted_quantity, expiry_date):
    if (
        accepted_quantity > 0
        and line.variant.product.tracks_expiry
        and expiry_date is None
    ):
        raise serializers.ValidationError(
            {
                "expiry_date": (
                    "Expiry date is required for received products that track expiry."
                )
            }
        )


def fresh_purchase_receipt_lines(locked_order, lines_data, *, locked_lines):
    requested_by_line = {}
    for line_data in lines_data:
        line = line_data["line"]
        if line.purchase_order_id != locked_order.pk:
            raise serializers.ValidationError(
                {"lines": "Receipt line does not belong to this purchase order."}
            )
        if line.pk in requested_by_line:
            raise serializers.ValidationError(
                {"lines": "Each purchase line can be received only once per receipt."}
            )
        requested_by_line[line.pk] = line_data

    lines_by_id = {line.pk: line for line in locked_lines}
    if set(requested_by_line) - set(lines_by_id):
        raise serializers.ValidationError(
            {"lines": "Receipt line does not belong to this purchase order."}
        )

    fresh_lines = []
    for line_id, line_data in requested_by_line.items():
        line = lines_by_id[line_id]
        accepted_quantity = line_data.get("accepted_quantity", 0)
        damaged_quantity = line_data.get("damaged_quantity", 0)
        cancelled_quantity = line_data.get("cancelled_quantity", 0)
        allowed_over_receipt_quantity = line_data.get("allowed_over_receipt_quantity")
        if allowed_over_receipt_quantity is None:
            allowed_over_receipt_quantity = 0
        validate_receipt_line_quantities(
            line,
            accepted_quantity,
            damaged_quantity,
            cancelled_quantity,
            allowed_over_receipt_quantity=allowed_over_receipt_quantity,
        )
        expiry_date = line_data.get("expiry_date", line.expiry_date)
        validate_receipt_line_expiry(line, accepted_quantity, expiry_date)
        fresh_lines.append(
            {
                "line": line,
                "accepted_quantity": accepted_quantity,
                "damaged_quantity": damaged_quantity,
                "cancelled_quantity": cancelled_quantity,
                "allowed_over_receipt_quantity": allowed_over_receipt_quantity,
                "expiry_date": expiry_date,
                "notes": line_data.get("notes", ""),
                # Captured identifiers travel with the line, not beside it: this
                # function re-reads every quantity off the locked row, and a
                # payload key it forgets to carry is a payload key the receipt
                # silently drops.
                "units": line_data.get("units") or [],
                "batches": line_data.get("batches") or [],
            }
        )
    return fresh_lines



def _shop_settings():
    from apps.core.models import ShopSettings

    return ShopSettings.load()


def apply_receipt_stock_changes(
    *,
    locked_order,
    line,
    accepted_quantity,
    damaged_quantity,
    cancelled_quantity,
    expected_quantities,
    created_by,
    stock_items=None,
    warehouse=None,
    capture=None,
):
    """Adjust one received line's stock and return its unsaved movements.

    The movements are returned rather than saved so the whole receipt is written
    and valued in one batch. Valuing line by line cost a fixed handful of
    queries per line, which a twenty-line delivery pays twenty times over. The
    per-line arithmetic is untouched — each movement is still built from the
    snapshot taken before its own adjustment.
    """
    movements = []
    if stock_items is None:
        stock_item = lock_stock_item(variant=line.variant, warehouse=warehouse)
        save = save_stock_item_quantities
    else:
        # The caller locked the whole delivery's rows in one statement and
        # writes them back in one UPDATE once every line has been applied; the
        # in-memory row is the one source of truth in between.
        stock_item = stock_items[line.variant_id]

        def save(_stock_item):
            return None

    # Receipt quantities are in the line's purchase unit (whole packs); stock is
    # kept in base units, so convert each at the boundary via the line's factor.
    accepted_expected = expected_quantities["accepted_expected"]
    accepted_overage = accepted_quantity - accepted_expected
    if accepted_expected > 0:
        accepted_expected_base = line.to_base_quantity(accepted_expected)
        before = stock_snapshot(stock_item)
        stock_item.quantity_on_hand += accepted_expected_base
        decrement_expected(stock_item, accepted_expected_base)
        save(stock_item)
        movements.append(
            build_stock_movement(
                stock_item=stock_item,
                variant=line.variant,
                movement_type=StockMovement.Type.RECEIVE_EXPECTED,
                quantity=accepted_expected_base,
                note=f"استلام مشتريات {locked_order.order_number}",
                created_by=created_by,
                before=before,
                # Net of discounts and landed costs: what this stock actually
                # cost to put on the shelf is what it is worth on it.
                unit_cost=line.effective_base_unit_cost_exact,
                tracked_plan=(
                    capture.take(
                        quantity=accepted_expected_base,
                        rate=line.effective_base_unit_cost_exact,
                    )
                    if capture is not None
                    else None
                ),
            )
        )

    if accepted_overage > 0:
        accepted_overage_base = line.to_base_quantity(accepted_overage)
        before = stock_snapshot(stock_item)
        stock_item.quantity_on_hand += accepted_overage_base
        save(stock_item)
        movements.append(
            build_stock_movement(
                stock_item=stock_item,
                variant=line.variant,
                movement_type=StockMovement.Type.INCREASE,
                quantity=accepted_overage_base,
                note=f"زيادة توريد {locked_order.order_number}",
                created_by=created_by,
                before=before,
                unit_cost=line.effective_base_unit_cost_exact,
                tracked_plan=(
                    capture.take(
                        quantity=accepted_overage_base,
                        rate=line.effective_base_unit_cost_exact,
                    )
                    if capture is not None
                    else None
                ),
            )
        )

    damaged_expected = expected_quantities["damaged_expected"]
    if damaged_expected > 0:
        before = stock_snapshot(stock_item)
        decrement_expected(stock_item, line.to_base_quantity(damaged_expected))
        save(stock_item)
        movements.append(
            build_stock_movement(
                stock_item=stock_item,
                variant=line.variant,
                movement_type=StockMovement.Type.RECEIVE_DAMAGED,
                quantity=line.to_base_quantity(damaged_expected),
                note=f"تالف عند الاستلام {locked_order.order_number}",
                created_by=created_by,
                before=before,
            )
        )

    cancelled_expected = expected_quantities["cancelled_expected"]
    if cancelled_expected > 0:
        before = stock_snapshot(stock_item)
        decrement_expected(stock_item, line.to_base_quantity(cancelled_expected))
        save(stock_item)
        movements.append(
            build_stock_movement(
                stock_item=stock_item,
                variant=line.variant,
                movement_type=StockMovement.Type.CANCEL_EXPECTED,
                quantity=line.to_base_quantity(cancelled_expected),
                note=f"إلغاء توريد {locked_order.order_number}",
                created_by=created_by,
                before=before,
            )
        )

    return movements


def purchase_order_cancelled_total(purchase_order, *, lines=None):
    """The goods value of every unit a receipt has closed as cancelled.

    Each line contributes its cancelled units' share of ``net_line_total`` —
    the discounted value of the ordered line. Multiplying before dividing keeps
    a fully cancelled line exact (``net x qty / qty`` has no remainder to
    lose), so an order whose whole shipment fell through carries exactly its
    net goods value and settles at zero. Recomputed from scratch rather than
    accumulated, so repeated partial receipts on the same line cannot
    double-count.
    """
    cancelled_by_line = {
        row["purchase_line_id"]: row["total"] or Decimal("0")
        for row in (
            PurchaseReceiptLine.objects.filter(
                purchase_line__purchase_order=purchase_order
            )
            # A retracted delivery did not arrive. This is what lets an order's
            # own reversal see its expectation as outstanding again once its
            # receipts have given the goods back.
            .exclude(receipt__doc_status=DocumentStatus.CANCELLED)
            .values("purchase_line_id")
            .annotate(total=models.Sum("cancelled_quantity"))
        )
    }
    if not cancelled_by_line:
        return Decimal("0.00")
    if lines is None:
        lines = list(purchase_order.lines.all())
    exact = Decimal("0")
    for line in lines:
        ordered = Decimal(line.quantity or 0)
        if ordered <= 0:
            continue
        cancelled = min(cancelled_by_line.get(line.pk, Decimal("0")), ordered)
        if cancelled <= 0:
            continue
        exact += line.net_line_total * cancelled / ordered
    return exact.quantize(Decimal("0.01"))


@transaction.atomic
def receive_purchase_order(purchase_order, *, request=None, lines_data=None, notes=""):
    locked_order = (
        PurchaseOrder.objects.select_for_update()
        .get(pk=purchase_order.pk)
    )
    if locked_order.status not in (
        PurchaseOrder.Status.SUBMITTED,
        PurchaseOrder.Status.PARTIALLY_RECEIVED,
    ):
        raise serializers.ValidationError(
            {"detail": "Only submitted purchase orders can be received."}
        )

    created_by = purchase_created_by(request)
    locked_lines = lock_purchase_lines_for_update(locked_order, prime_totals=True)
    if lines_data is None:
        lines_data = default_receipt_lines(locked_order, locked_lines)
    else:
        lines_data = fresh_purchase_receipt_lines(
            locked_order,
            lines_data,
            locked_lines=locked_lines,
        )
    if not lines_data:
        raise serializers.ValidationError(
            {"lines": "No outstanding purchase lines can be received."}
        )

    receipt = PurchaseReceipt.objects.create(
        purchase_order=locked_order,
        notes=notes,
        created_by=created_by,
    )

    # Collected across every line so the whole delivery is written and valued in
    # one batch rather than once per line — and its stock rows locked and
    # written back the same way.
    stock_movements = []
    stock_items = lock_stock_items(
        [line_data["line"].variant for line_data in lines_data],
        warehouse=locked_order.warehouse_id,
    )

    # Identified stock the delivery brought in, per line. Built before the
    # movements so a line whose identifiers do not add up refuses the whole
    # receipt rather than half-landing it, and applied after the receipt lines
    # exist so every unit can name the line that brought it.
    captures = []
    damaged_units = []
    capture_later = bool(_shop_settings().serialized_capture_later_allowed)
    for line_data in lines_data:
        line = line_data["line"]
        accepted_quantity = line_data.get("accepted_quantity", 0)
        damaged_quantity = line_data.get("damaged_quantity", 0)
        cancelled_quantity = line_data.get("cancelled_quantity", 0)
        validate_receipt_line_quantities(
            line,
            accepted_quantity,
            damaged_quantity,
            cancelled_quantity,
            allowed_over_receipt_quantity=line_data.get(
                "allowed_over_receipt_quantity",
                0,
            ),
        )
        expiry_date = line_data.get("expiry_date", line.expiry_date)
        validate_receipt_line_expiry(line, accepted_quantity, expiry_date)
        expected_quantities = receipt_line_expected_quantities(
            line,
            accepted_quantity,
            damaged_quantity,
            cancelled_quantity,
        )
        capture = tracking.ReceiptCapture(
            variant=line.variant,
            warehouse=locked_order.warehouse_id,
            units=line_data.get("units"),
            batches=line_data.get("batches"),
            supplier=locked_order.supplier,
            purchase_line=line,
            capture_later=capture_later,
            key=f"PO{locked_order.pk}L{line.pk}",
        )
        stock_movements.extend(
            apply_receipt_stock_changes(
                locked_order=locked_order,
                line=line,
                accepted_quantity=accepted_quantity,
                damaged_quantity=damaged_quantity,
                cancelled_quantity=cancelled_quantity,
                expected_quantities=expected_quantities,
                created_by=created_by,
                stock_items=stock_items,
                warehouse=locked_order.warehouse_id,
                capture=capture if capture.is_tracked else None,
            )
        )
        receipt_line = PurchaseReceiptLine.objects.create(
            receipt=receipt,
            purchase_line=line,
            variant=line.variant,
            ordered_quantity=line.quantity,
            outstanding_before=expected_quantities["outstanding_before"],
            accepted_quantity=accepted_quantity,
            damaged_quantity=damaged_quantity,
            cancelled_quantity=cancelled_quantity,
            expected_reduction_quantity=expected_quantities["expected_reduction"],
            over_received_quantity=expected_quantities["over_received"],
            outstanding_after=expected_quantities["outstanding_after"],
            expiry_date=expiry_date,
            notes=line_data.get("notes", ""),
        )
        create_expiring_stock_batch(
            receipt_line=receipt_line,
            expiry_date=expiry_date,
            # Batches are consumed in base units by FEFO, so store base units.
            quantity=line.to_base_quantity(accepted_quantity),
            warehouse=locked_order.warehouse_id,
            unit_cost=line.effective_base_unit_cost_exact,
        )
        if capture.is_tracked:
            capture.bind_receipt_line(receipt_line)
            damaged_units.extend(
                capture.create_damaged_units(
                    quantity=line.to_base_quantity(damaged_quantity),
                    rate=line.effective_base_unit_cost_exact,
                )
            )
            captures.append(capture)

    # The units and balances have to exist before the valuation pass writes the
    # allocations that name them.
    for capture in captures:
        for plan in capture.plans:
            tracking.apply_receipt(plan)
    if damaged_units:
        StockUnit.objects.bulk_create(damaged_units)

    # One insert and one valuation pass for the whole delivery.
    save_stock_item_quantities_bulk(stock_items.values())
    create_stock_movements(
        stock_movements,
        voucher_type=StockLedgerEntry.VoucherType.PURCHASE_RECEIPT,
        voucher_id=locked_order.pk,
    )
    # The receipt lines just written change every line's outstanding figure.
    refresh_purchase_line_totals(locked_lines)

    has_outstanding = any(
        line.outstanding_quantity > 0 for line in locked_lines
    )
    # Units the receipt cancelled will never arrive and can never be returned,
    # so the order must stop billing for them here — nothing downstream can
    # take them off the payable later.
    locked_order.cancelled_total = purchase_order_cancelled_total(
        locked_order,
        lines=locked_lines,
    )
    if not has_outstanding:
        locked_order.received_at = timezone.now()
        locked_order.save(
            update_fields=["received_at", "cancelled_total", "updated_at"]
        )
    else:
        locked_order.save(update_fields=["cancelled_total", "updated_at"])
    # Progress is derived, never assigned: one function, called from here and
    # from the lifecycle transitions, and from nowhere else.
    purchase_documents.recompute_progress(locked_order, lines=locked_lines)
    record_purchase_order_audit_event(
        locked_order,
        PurchaseOrderAuditEvent.Action.RECEIVED,
        created_by=created_by,
        details={"receipt": receipt.pk, "status": locked_order.status},
    )
    schedule_supplier_refresh(locked_order.supplier_id)
    return locked_order


def purchase_adjustable_line_value(line):
    """The most that can ever be credited back for this line.

    ``net_line_total`` is the discounted value of the whole *ordered* line, but
    only the units that actually arrived can go back to the supplier
    (``adjustable_quantity`` counts accepted units). On a line ordered 10 and
    received 4, the returnable value is the 4 units' share of the line, not all
    ten. Over-receipts stay capped at the ordered value: the order never billed
    for the surplus, so it cannot credit for it either.
    """
    ordered = Decimal(line.quantity or 0)
    if ordered <= 0:
        return Decimal("0.00")
    accepted = min(Decimal(line.accepted_quantity), ordered)
    if accepted >= ordered:
        return line.net_line_total.quantize(Decimal("0.01"))
    return (line.net_line_total * accepted / ordered).quantize(Decimal("0.01"))


def purchase_adjustable_unit_span(line):
    """How many units the line's returnable value is spread across.

    Normally that is the ordered quantity: each of the ten units on a line
    ordered ten is worth a tenth of it, whether four arrived or all ten did.
    But a supplier can over-ship, and then ``accepted_quantity`` exceeds
    ``quantity`` while the returnable value stays capped at what the order
    actually billed (see :func:`purchase_adjustable_line_value`). Spreading that
    capped value over the ordered count would price each *arrived* unit above
    its share, so the span is whichever count is larger.
    """
    ordered = Decimal(line.quantity or 0)
    accepted = Decimal(line.accepted_quantity or 0)
    return max(ordered, accepted)


def purchase_adjustment_line_amount(line, quantity):
    prior_amount = line.adjustment_lines.aggregate(total=models.Sum("line_amount"))[
        "total"
    ] or Decimal("0.00")
    if quantity >= line.adjustable_quantity:
        # Last units back: whatever of the returnable value is left unclaimed,
        # so repeated partial returns always add up to exactly that value.
        return (purchase_adjustable_line_value(line) - prior_amount).quantize(
            Decimal("0.01")
        )
    span = purchase_adjustable_unit_span(line)
    if span <= 0:
        return Decimal("0.00")
    return (line.net_line_total * Decimal(quantity) / span).quantize(
        Decimal("0.01")
    )


def purchase_adjustment_line_unit_cost(line, quantity):
    amount = purchase_adjustment_line_amount(line, quantity)
    return (amount / Decimal(quantity)).quantize(Decimal("0.01"))


def purchase_adjustment_amount(lines):
    amount = sum(
        (purchase_adjustment_line_amount(line, quantity) for line, quantity in lines),
        Decimal("0.00"),
    ).quantize(Decimal("0.01"))
    if amount <= 0:
        raise serializers.ValidationError({"detail": "Adjustment amount must be positive."})
    return amount


def purchase_replacement_amount(lines):
    return sum(
        (unit_cost * quantity for _, quantity, unit_cost in lines),
        Decimal("0.00"),
    ).quantize(Decimal("0.01"))


def validate_purchase_order_adjustment_allowed(purchase_order, *, lines=None):
    if purchase_order.status not in (
        PurchaseOrder.Status.PARTIALLY_RECEIVED,
        PurchaseOrder.Status.RECEIVED,
    ):
        raise serializers.ValidationError(
            {"detail": "Only received purchase orders can be adjusted."}
        )
    order_lines = purchase_order.lines.all() if lines is None else lines
    if not any(line.adjustable_quantity > 0 for line in order_lines):
        raise serializers.ValidationError(
            {"detail": "No remaining purchase lines can be adjusted."}
        )


def validate_purchase_stock_available(lines, *, warehouse=None):
    # Compare against base-unit stock (a returned pack frees up base units), but
    # report the shortage in the unit the user actually entered (packs).
    requested_base_by_variant = {}
    requested_display_by_variant = {}
    variants_by_id = {}
    for line, quantity in lines:
        variants_by_id[line.variant_id] = line.variant
        requested_base_by_variant[line.variant_id] = requested_base_by_variant.get(
            line.variant_id, Decimal("0")
        ) + line.to_base_quantity(quantity)
        requested_display_by_variant[line.variant_id] = (
            requested_display_by_variant.get(line.variant_id, 0) + quantity
        )

    stock_items = lock_stock_items(variants_by_id.values(), warehouse=warehouse)
    shortages = []
    for variant_id in sorted(requested_base_by_variant):
        variant = variants_by_id[variant_id]
        base_needed = requested_base_by_variant[variant_id]
        stock_item = stock_items[variant_id]
        if stock_item.quantity_on_hand < base_needed:
            shortages.append(
                {
                    "product": variant.product_id,
                    "product_id": variant.product_id,
                    "variant": variant.pk,
                    "variant_id": variant.pk,
                    "product_name": variant.product.name,
                    "variant_name": variant.full_name,
                    "requested": requested_display_by_variant[variant_id],
                    "available": float(stock_item.quantity_on_hand),
                }
            )

    if shortages:
        raise serializers.ValidationError(
            {
                "code": "purchase_stock_already_sold",
                "detail": (
                    "لا يمكن تعديل أمر الشراء لأن الكمية المستلمة بيعت أو لم تعد "
                    "متوفرة في المخزون."
                ),
                "stock": shortages,
            }
        )
    return stock_items


def purchase_adjustment_note(adjustment_type, order_number):
    label = {
        PurchaseOrderAdjustment.AdjustmentType.RETURN: "إرجاع مشتريات",
        PurchaseOrderAdjustment.AdjustmentType.REFUND: "استرداد مشتريات",
        PurchaseOrderAdjustment.AdjustmentType.EXCHANGE: "استبدال مشتريات",
    }.get(adjustment_type, "تعديل مشتريات")
    return f"{label} {order_number}"


def purchase_replacement_note(order_number):
    return f"استلام بديل مشتريات {order_number}"


def record_purchase_adjustment_stock_movements(
    *,
    purchase_order,
    adjustment_type,
    lines,
    stock_items,
    created_by,
):
    for line, quantity in lines:
        stock_item = stock_items[line.variant_id]
        before = stock_snapshot(stock_item)
        # Returned packs leave stock in base units.
        base_quantity = line.to_base_quantity(quantity)
        stock_item.quantity_on_hand -= base_quantity
        save_stock_item_quantities(stock_item)
        consume_expiring_stock_batches(
            variant=line.variant,
            quantity=base_quantity,
            warehouse=stock_item.warehouse_id,
        )
        create_stock_movement(
            variant=line.variant,
            stock_item=stock_item,
            movement_type=StockMovement.Type.DECREASE,
            quantity=base_quantity,
            note=purchase_adjustment_note(adjustment_type, purchase_order.order_number),
            created_by=created_by,
            before=before,
            voucher_type=StockLedgerEntry.VoucherType.PURCHASE_RETURN,
            voucher_id=purchase_order.pk,
        )


def lock_replacement_stock_items(lines, stock_items=None, *, warehouse=None):
    stock_items = {} if stock_items is None else dict(stock_items)
    variants_by_id = {variant.pk: variant for variant, _, _ in lines}
    for variant_id in sorted(variants_by_id):
        if variant_id in stock_items:
            continue
        variant = variants_by_id[variant_id]
        stock_item = lock_stock_item(variant=variant, warehouse=warehouse)
        stock_items[variant_id] = stock_item
    return stock_items


def record_purchase_replacement_stock_movements(
    *,
    purchase_order,
    lines,
    stock_items,
    created_by,
):
    for variant, quantity, _ in lines:
        stock_item = stock_items[variant.pk]
        before = stock_snapshot(stock_item)
        stock_item.quantity_on_hand += quantity
        save_stock_item_quantities(stock_item)
        create_stock_movement(
            variant=variant,
            stock_item=stock_item,
            movement_type=StockMovement.Type.INCREASE,
            quantity=quantity,
            note=purchase_replacement_note(purchase_order.order_number),
            created_by=created_by,
            before=before,
            # No explicit cost: a replacement is the same goods arriving again,
            # so it is worth what the stock it replaces is worth. Falling back
            # to the bin's own rate says exactly that.
            voucher_type=StockLedgerEntry.VoucherType.PURCHASE_RECEIPT,
            voucher_id=purchase_order.pk,
        )


def create_purchase_order_adjustment(
    *,
    purchase_order,
    adjustment_type,
    lines,
    reason,
    replacement_lines=None,
    request=None,
    settlement_method="",
):
    created_by = purchase_created_by(request)
    # A return goes back from where the delivery landed, and a replacement
    # arrives in the same place. Both read the order's own destination rather
    # than the shop's default, or a store-room purchase would be returned off
    # the showroom's shelves.
    warehouse_id = purchase_order.warehouse_id
    stock_items = validate_purchase_stock_available(lines, warehouse=warehouse_id)
    replacement_lines = replacement_lines or []
    stock_items = lock_replacement_stock_items(
        replacement_lines, stock_items, warehouse=warehouse_id
    )
    outbound_amount = purchase_adjustment_amount(lines)
    replacement_amount = purchase_replacement_amount(replacement_lines)
    net_amount = (replacement_amount - outbound_amount).quantize(Decimal("0.01"))
    adjustment = PurchaseOrderAdjustment.objects.create(
        purchase_order=purchase_order,
        adjustment_type=adjustment_type,
        amount=outbound_amount,
        outbound_amount=outbound_amount,
        replacement_amount=replacement_amount,
        net_amount=net_amount,
        settlement_method=settlement_method,
        reason=reason,
        created_by=created_by,
    )
    for line, quantity in lines:
        line_amount = purchase_adjustment_line_amount(line, quantity)
        PurchaseOrderAdjustmentLine.objects.create(
            adjustment=adjustment,
            purchase_line=line,
            variant=line.variant,
            quantity=quantity,
            unit_cost=purchase_adjustment_line_unit_cost(line, quantity),
            line_amount=line_amount,
        )
    for variant, quantity, unit_cost in replacement_lines:
        PurchaseOrderAdjustmentReplacementLine.objects.create(
            adjustment=adjustment,
            variant=variant,
            quantity=quantity,
            unit_cost=unit_cost,
        )
    record_purchase_adjustment_stock_movements(
        purchase_order=purchase_order,
        adjustment_type=adjustment_type,
        lines=lines,
        stock_items=stock_items,
        created_by=created_by,
    )
    record_purchase_replacement_stock_movements(
        purchase_order=purchase_order,
        lines=replacement_lines,
        stock_items=stock_items,
        created_by=created_by,
    )
    settle_purchase_order_adjustment(adjustment, created_by=created_by)
    record_purchase_order_audit_event(
        purchase_order,
        PurchaseOrderAuditEvent.Action.ADJUSTED,
        created_by=created_by,
        details={
            "adjustment": adjustment.pk,
            "adjustment_type": adjustment.adjustment_type,
            "outbound_amount": str(adjustment.outbound_amount),
            "replacement_amount": str(adjustment.replacement_amount),
            "net_amount": str(adjustment.net_amount),
        },
    )
    return adjustment


def settle_purchase_order_adjustment(adjustment, *, created_by=None):
    supplier = adjustment.purchase_order.supplier
    if supplier is None or not adjustment.settlement_method:
        return

    if adjustment.settlement_method == PurchaseOrderAdjustment.SettlementMethod.SUPPLIER_CREDIT:
        SupplierCredit.objects.create(
            supplier=supplier,
            purchase_order=adjustment.purchase_order,
            adjustment=adjustment,
            amount=adjustment.outbound_amount,
            remaining_amount=adjustment.outbound_amount,
            reason=adjustment.reason,
        )
        return

    SupplierPayment.objects.create(
        supplier=supplier,
        purchase_order=adjustment.purchase_order,
        amount=adjustment.outbound_amount,
        method=adjustment.settlement_method,
        notes=adjustment.reason,
        created_by=created_by,
    )


def fresh_purchase_adjustment_lines(locked_order, lines, *, locked_lines):
    requested_by_line = {}
    for line, quantity in lines:
        if line.purchase_order_id != locked_order.pk:
            raise serializers.ValidationError(
                {"lines": "Adjustment line does not belong to this purchase order."}
            )
        requested_by_line[line.pk] = requested_by_line.get(line.pk, 0) + quantity

    lines_by_id = {line.pk: line for line in locked_lines}
    if set(requested_by_line) - set(lines_by_id):
        raise serializers.ValidationError(
            {"lines": "Adjustment line does not belong to this purchase order."}
        )

    fresh_lines = []
    for line_id, quantity in requested_by_line.items():
        line = lines_by_id[line_id]
        adjustable_quantity = line.adjustable_quantity
        if quantity > adjustable_quantity:
            raise serializers.ValidationError(
                {
                    "lines": (
                        f"Cannot adjust more than {adjustable_quantity} "
                        "remaining items."
                    )
                }
            )
        fresh_lines.append((line, quantity))
    return fresh_lines


@transaction.atomic
def adjust_purchase_order_items(
    *,
    purchase_order,
    adjustment_type,
    lines,
    reason,
    replacement_lines=None,
    request=None,
    settlement_method="",
):
    locked_order = (
        PurchaseOrder.objects.select_for_update()
        .get(pk=purchase_order.pk)
    )
    locked_lines = lock_purchase_lines_for_update(locked_order)
    validate_purchase_order_adjustment_allowed(locked_order, lines=locked_lines)
    lines = fresh_purchase_adjustment_lines(
        locked_order,
        lines,
        locked_lines=locked_lines,
    )
    return create_purchase_order_adjustment(
        purchase_order=locked_order,
        adjustment_type=adjustment_type,
        lines=lines,
        replacement_lines=replacement_lines,
        reason=reason,
        request=request,
        settlement_method=settlement_method,
    )


def supplier_available_credit(supplier):
    total = supplier.credits.filter(status=SupplierCredit.Status.OPEN).aggregate(
        total=models.Sum("remaining_amount")
    )["total"]
    return (total or Decimal("0.00")).quantize(Decimal("0.01"))


def validate_supplier_payment_order(supplier, purchase_order):
    if purchase_order is None:
        return
    if purchase_order.supplier_id != supplier.pk:
        raise serializers.ValidationError(
            {"purchase_order": "Purchase order does not belong to this supplier."}
        )
    if purchase_order.status == PurchaseOrder.Status.CANCELLED:
        raise serializers.ValidationError(
            {"purchase_order": "Cannot pay a cancelled purchase order."}
        )


def consume_supplier_credit(*, supplier, amount):
    remaining = amount
    credits = supplier.credits.select_for_update().filter(
        status=SupplierCredit.Status.OPEN,
        remaining_amount__gt=0,
    ).order_by("created_at", "id")
    for credit in credits:
        if remaining <= 0:
            break
        applied = min(credit.remaining_amount, remaining)
        credit.remaining_amount = (credit.remaining_amount - applied).quantize(
            Decimal("0.01")
        )
        if credit.remaining_amount == Decimal("0.00"):
            credit.status = SupplierCredit.Status.USED
        credit.save(update_fields=["remaining_amount", "status", "updated_at"])
        remaining = (remaining - applied).quantize(Decimal("0.01"))


def restore_supplier_credit(*, supplier, amount):
    """Put back credit that a cancelled payment had consumed.

    ``consume_supplier_credit`` draws down the oldest credits first and keeps no
    record of which one paid for what, so this refills the newest first until
    the whole amount is back. The supplier's *available* credit — the only
    figure anything reads — ends up exactly where it started; which note holds
    it can differ, and that is the honest limit of undoing a draw-down nobody
    itemised.
    """
    remaining = amount
    credits = (
        supplier.credits.select_for_update()
        .filter(remaining_amount__lt=models.F("amount"))
        .order_by("-created_at", "-id")
    )
    for credit in credits:
        if remaining <= 0:
            break
        headroom = (credit.amount - credit.remaining_amount).quantize(Decimal("0.01"))
        restored = min(headroom, remaining)
        credit.remaining_amount = (credit.remaining_amount + restored).quantize(
            Decimal("0.01")
        )
        credit.status = SupplierCredit.Status.OPEN
        credit.save(update_fields=["remaining_amount", "status", "updated_at"])
        remaining = (remaining - restored).quantize(Decimal("0.01"))


@transaction.atomic
def cancel_supplier_payment(payment, *, reason, request=None, register_session=None):
    """Undo a payment to a supplier.

    There was no way to do this at all before: the endpoint offered create and
    read, so a mistyped payment was permanent — and because a payment blocks its
    purchase order from being cancelled, one typo could lock an order shut for
    good.
    """
    from apps.sales.models import RegisterSession

    if payment.cash_movement_id is not None and register_session is None:
        register_session = RegisterSession.open_for(getattr(request, "user", None))
        if register_session is None:
            raise serializers.ValidationError(
                {
                    "detail": (
                        "This payment left the drawer, so it has to come back "
                        "into one. Open a register session first."
                    )
                }
            )
    return document_services.cancel(
        payment,
        reason=reason,
        request=request,
        context={"register_session": register_session},
    )


@transaction.atomic
def create_supplier_payment(*, created_by=None, **payment_fields):
    supplier = Supplier.objects.select_for_update().get(pk=payment_fields["supplier"].pk)
    payment_fields["supplier"] = supplier

    purchase_order = payment_fields.get("purchase_order")
    if purchase_order is not None:
        purchase_order = PurchaseOrder.objects.select_for_update().get(
            pk=purchase_order.pk
        )
        payment_fields["purchase_order"] = purchase_order
    validate_supplier_payment_order(supplier, purchase_order)

    amount = payment_fields["amount"].quantize(Decimal("0.01"))
    method = payment_fields["method"]
    if amount <= 0:
        raise serializers.ValidationError({"amount": "Payment amount must be positive."})

    if method == SupplierPayment.Method.SUPPLIER_CREDIT:
        if purchase_order is None:
            raise serializers.ValidationError(
                {"purchase_order": "Supplier credit payments require a purchase order."}
            )
        available_credit = supplier_available_credit(supplier)
        if amount > available_credit:
            raise serializers.ValidationError(
                {"amount": "Payment exceeds available supplier credit."}
            )
    elif purchase_order is None and amount > supplier.payable_balance:
        raise serializers.ValidationError(
            {"amount": "Payment exceeds the supplier payable balance."}
        )

    if purchase_order is not None and amount > purchase_order.balance_due:
        raise serializers.ValidationError(
            {"amount": "Payment exceeds the purchase order balance."}
        )

    payment_fields["amount"] = amount
    payment_fields["created_by"] = created_by
    # No commission on supplier pay-outs: a processing fee is the terminal
    # operator's cost, and here the shop is paying out, not collecting. Commission
    # is captured only on customer payments (where the shop runs the terminal).
    payment = SupplierPayment.objects.create(**payment_fields)
    if method == SupplierPayment.Method.SUPPLIER_CREDIT:
        consume_supplier_credit(supplier=supplier, amount=amount)
    return payment


def _counter_purchase_receipt_lines(purchase_order, captures):
    """Pair each captured identifier list with the line it was scanned against.

    ``None`` when nothing was captured at all, which is every counter purchase
    of anything a shop counts rather than identifies — and which makes
    ``receive_purchase_order`` take its ordinary default-everything path.
    """
    if not any(captures):
        return None
    lines = list(purchase_order.lines.select_related("variant__product").order_by("id"))
    rows = []
    for line, captured in zip(lines, captures):
        row = {"line": line, "accepted_quantity": line.outstanding_quantity}
        if captured:
            row["units"] = captured
        rows.append(row)
    return rows


@transaction.atomic
def create_pos_cash_purchase(*, request, validated_data):
    """One-tap drawer purchase from the sell screen: create → submit → receive
    a purchase order, pay it in full in cash, and record the linked register
    pay-out so the drawer reconciles automatically
    (``RegisterSession.expected_cash`` nets out pay-outs).

    Refuses to run without an open register session — the drawer effect is the
    whole point; a purchase paid some other way belongs in the purchasing
    screen. ``validated_data`` is ``PurchaseOrderSerializer.validated_data``,
    so lines carry the same UoM/pack-cost semantics as any other PO.
    """
    from apps.core.models import ShopSettings
    from apps.sales.models import RegisterCashMovement, RegisterSession

    session = RegisterSession.open_for(getattr(request, "user", None))
    if session is None:
        raise serializers.ValidationError(
            {"detail": "An open register session is required for a POS cash purchase."}
        )

    # A POS cash purchase is paid out of the drawer, and the drawer holds the
    # shop's own currency. Letting a cashier record a foreign-currency purchase
    # would put a converted figure against a cash pay-out that never happened in
    # that currency, and the register would reconcile against a number nobody
    # counted. Foreign purchases belong on the purchasing screen, where a buyer
    # sets the rate deliberately.
    if validated_data.get("currency") is not None:
        raise serializers.ValidationError(
            {
                "currency": (
                    "لا يمكن تسجيل شراء نقدي من نقطة البيع بعملة أجنبية. "
                    "استخدم شاشة المشتريات."
                )
            }
        )

    lines_data = validated_data.pop("lines", [])
    landed_cost_entries_data = validated_data.pop("landed_cost_entries", None)
    # The counter purchase is the one flow where ordering and receiving are the
    # same act — a shop buying a handset off a walk-in scans the IMEI while the
    # seller is still standing there — so the identifiers ride in on the order's
    # own lines and are handed to the receipt below. Stripped here because they
    # belong to the receipt, not to the order line.
    captures = [line.pop("units", None) for line in lines_data]

    # Hard stop, with no acknowledgement path: a cashier cannot judge whether
    # 130.00 per loaf is plausible and has no permission to override it. In the
    # field exactly this entry — the amount paid typed into unit_cost against
    # quantity 1 — went unnoticed for weeks and erased 11 points of gross
    # margin. The API path sets this through serializer context; repeating it
    # here covers any caller that reaches the service directly, and costs one
    # pass over the lines.
    from .cost_guard import block_thresholds, find_cost_anomalies
    from .serializers import raise_cost_warnings

    raise_cost_warnings(
        find_cost_anomalies(lines_data, thresholds=block_thresholds()),
        blocking=True,
    )

    # The goods are being carried in through the door of the place this till
    # stands in, so that is where they land. A cashier is never asked and never
    # told: for the shop with one location this is the only warehouse there is,
    # and for a shop with a store room a till on the shop floor buying bread is
    # buying it for the shop floor.
    validated_data.setdefault("warehouse_id", selling_warehouse_id(request))
    purchase_order = save_purchase_order_with_lines(
        lines_data=lines_data,
        landed_cost_entries_data=landed_cost_entries_data,
        request=request,
        **validated_data,
    )

    # The cap reads the total AFTER discounts/landed costs — the exact amount
    # that would leave the drawer. Raising here rolls back the whole purchase.
    limit = ShopSettings.load().pos_cash_purchase_limit
    if limit is not None and limit > 0 and purchase_order.total > limit:
        raise serializers.ValidationError(
            {"detail": f"POS cash purchases are capped at {limit}."}
        )

    purchase_order = submit_purchase_order(purchase_order, request=request)
    purchase_order = receive_purchase_order(
        purchase_order,
        request=request,
        lines_data=_counter_purchase_receipt_lines(purchase_order, captures),
    )

    created_by = purchase_created_by(request)
    if purchase_order.total > 0:
        movement = RegisterCashMovement.objects.create(
            register_session=session,
            movement_type=RegisterCashMovement.MovementType.PAY_OUT,
            amount=purchase_order.total,
            reason=(
                f"شراء نقدي: {purchase_order.supplier.name}"
                f" — {purchase_order.order_number}"
            ),
            created_by=created_by,
        )
        create_supplier_payment(
            created_by=created_by,
            supplier=purchase_order.supplier,
            purchase_order=purchase_order,
            amount=purchase_order.total,
            method=SupplierPayment.Method.CASH,
            notes="شراء نقدي من نقطة البيع",
            register_session=session,
            cash_movement=movement,
        )
    record_domain_event(
        name="purchasing.pos_cash_purchase.created",
        user=created_by,
        attributes={
            "purchase_order_id": purchase_order.pk,
            "order_number": purchase_order.order_number,
            "supplier_id": purchase_order.supplier_id,
            "register_session_id": session.pk,
        },
        metrics={"amount": float(purchase_order.total)},
    )
    return purchase_order


@transaction.atomic
def cancel_purchase_order(purchase_order, *, request=None, reason=""):
    """Retract an order and give back everything it put into stock.

    The unwinding itself is ``apps.purchasing.documents.reverse``; what happens
    around it — the money that blocks a cancellation, the period lock, the
    permission, the trail — belongs to the primitive. A received order can now
    be cancelled where before it could not, provided its goods are still on the
    shelf and the caller may receive; that is the case a shop hits when a
    delivery was recorded against the wrong order.
    """
    created_by = purchase_created_by(request)
    locked_order = document_services.cancel(
        purchase_order, reason=reason, request=request
    )
    record_purchase_order_audit_event(
        locked_order,
        PurchaseOrderAuditEvent.Action.CANCELLED,
        created_by=created_by,
    )
    return locked_order
