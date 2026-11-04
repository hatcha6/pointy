"""Correcting a received order whose goods carry identity: lots and serials.

The ordinary edit of a received order takes the whole delivery back off the
shelf and records it again against the corrected lines
(``services._write_purchase_order_with_lines``). That is right for a quantity
in a bin and impossible for identified stock once any of it has sold: a lot's
balance can never go below zero, and a sold handset names the sale that took
it. Taking such a delivery back and replaying it would either refuse, or mint a
second set of lots and articles for goods the shop bought once.

So an identified line is corrected *in place*. Its receipt rows, its lots and
its articles stay exactly where they are, and only the difference moves:

* **Fewer arrived.** The surplus leaves the way a cancelled receipt's goods
  leave — the lot gives back quantity, the articles the owner names are
  cancelled. What has already been sold cannot be un-received, and that is the
  one refusal: there is no true sentence the books could say instead.
* **More arrived.** The extra stays outstanding on the line and is received
  through the ordinary receipt, which is where lots and serials are captured.
  An edit payload has no identifiers in it, and inventing them is the bug this
  module exists to avoid.
* **The cost changed.** What is still on the shelf is re-valued with a
  value-only ledger entry, so the bin keeps agreeing with its articles and
  lots; the sales that already took some have their cost of goods restated,
  unless their period has been closed.
"""

from __future__ import annotations

from collections import defaultdict
from dataclasses import dataclass
from decimal import ROUND_HALF_UP, Decimal

from django.db.models import Min, Q, Sum
from django.utils import timezone
from rest_framework import serializers

from apps.core.money_dates import money_date_field
from apps.core.period_lock import period_is_locked
from apps.documents.statuses import DocumentStatus
from apps.inventory import tracking
from apps.inventory.models import (
    StockAllocation,
    StockBatchBalance,
    StockLedgerEntry,
    StockMovement,
    StockUnit,
    Warehouse,
)
from apps.inventory.services import (
    build_stock_movement,
    create_stock_movements,
    lock_stock_items,
    save_stock_item_quantities_bulk,
    stock_snapshot,
)
from apps.inventory.valuation_service import post_value_only_entry

from .models import PurchaseReceipt, PurchaseReceiptLine

ZERO = Decimal("0")
RATE_PLACES = Decimal("0.000001")
MONEY_PLACES = Decimal("0.01")

#: The line was not resent: an edit of the order's costs alone (a landed cost,
#: an order discount) leaves every line as it was.
UNCHANGED = object()


@dataclass
class KeptLine:
    """One identified line, corrected where it stands."""

    snapshot: dict
    #: The line's new payload, :data:`UNCHANGED`, or ``None`` when the edit
    #: dropped the line altogether.
    data: object
    #: What one base unit of it cost before the edit, so the restatement knows
    #: how far the cost moved.
    old_rate: Decimal
    accepted: Decimal = ZERO
    damaged: Decimal = ZERO
    cancelled: Decimal = ZERO

    @property
    def line(self):
        return self.snapshot["line"]

    @property
    def removed(self) -> bool:
        return self.data is None


def has_identities(snapshot) -> bool:
    """Did this line put identified goods anywhere — on the shelf, or aside as
    damaged articles? A tracked line that only had units cancelled moved
    nothing, and replays like any other."""
    return tracking.is_tracked(snapshot["line"].variant) and (
        snapshot["accepted"] > 0 or snapshot["damaged"] > 0
    )


def split_received_lines(snapshots, lines_data):
    """Separate the lines corrected in place from the ones the edit replays.

    Returns ``(kept, replayed, claimed)``: ``claimed`` maps a payload index to
    the kept line it updates. A payload line is matched to an old one the way
    the replay matches them — same product, same pack size, in order — so an
    identified line that changed product or pack is the old line removed and a
    new one added, which is exactly what it is.
    """
    kept = []
    replayed = []
    pools = defaultdict(list)
    for snapshot in snapshots:
        if has_identities(snapshot):
            pools[snapshot["key"]].append(snapshot)
        else:
            replayed.append(snapshot)
    claimed = {}

    def keep(snapshot, data):
        item = KeptLine(
            snapshot=snapshot,
            data=data,
            old_rate=snapshot["line"].effective_base_unit_cost_exact,
        )
        item.accepted, item.damaged, item.cancelled = _targets(item)
        kept.append(item)
        return item

    if lines_data is None:
        for pool in pools.values():
            for snapshot in pool:
                keep(snapshot, UNCHANGED)
        return kept, replayed, claimed
    from .services import line_match_key

    for index, data in enumerate(lines_data):
        pool = pools.get(
            line_match_key(data["variant"].pk, data.get("unit_factor"))
        )
        if pool:
            claimed[index] = keep(pool.pop(0), data)
    for pool in pools.values():
        for snapshot in pool:
            keep(snapshot, None)
    return kept, replayed, claimed


def _targets(item):
    """What the corrected line should have had accepted, damaged, cancelled.

    The replay's own rule (``_replayed_receipt_quantities``), with one
    difference: nothing identified arrives by edit. Whatever the rule would add
    to ``accepted`` stays outstanding for a receipt to capture.
    """
    from .services import _replayed_receipt_quantities

    snapshot = item.snapshot
    if item.removed:
        return ZERO, ZERO, ZERO
    quantity = (
        snapshot["ordered"]
        if item.data is UNCHANGED
        else Decimal(item.data["quantity"])
    )
    accepted, damaged, cancelled, _over = _replayed_receipt_quantities(
        snapshot, quantity, fully_received=False
    )
    return (
        min(accepted, snapshot["accepted"]),
        min(damaged, snapshot["damaged"]),
        min(cancelled, snapshot["cancelled"]),
    )


def _warehouse_id(purchase_order):
    return purchase_order.warehouse_id or Warehouse.default_id()


def _receipt_rows(lines):
    """Each line's live receipt rows, newest first — the order a correction
    takes quantity back in."""
    rows = defaultdict(list)
    for row in (
        PurchaseReceiptLine.objects.select_for_update()
        .filter(purchase_line__in=lines)
        .exclude(receipt__doc_status=DocumentStatus.CANCELLED)
        .order_by("-pk")
    ):
        rows[row.purchase_line_id].append(row)
    return rows


def _stock_row(line, *, requested, available):
    variant = line.variant
    return {
        "product": variant.product_id,
        "product_id": variant.product_id,
        "variant": variant.pk,
        "variant_id": variant.pk,
        "product_name": variant.product.name,
        "variant_name": variant.full_name,
        "requested": float(requested),
        "available": float(available),
    }


def _sold_error(line, *, requested, available):
    return serializers.ValidationError(
        {
            "code": "purchase_stock_already_sold",
            "detail": (
                f"لا يمكن إنقاص «{line.variant.product.name}» في هذا الأمر: "
                f"بيع جزء مما استُلم منه أو لم يعد في المخزون، والمتبقي منه "
                f"{_plain(available)} فقط. صحّح المخزون بالجرد بدلًا من ذلك."
            ),
            "stock": [_stock_row(line, requested=requested, available=available)],
        }
    )


def _plain(value) -> str:
    return format(Decimal(value).normalize(), "f")


def unwind_kept_quantities(purchase_order, kept, *, removed_unit_ids, created_by):
    """Take off the shelf whatever the corrected lines no longer say arrived.

    Every refusal is decided before anything moves, so a correction either
    lands whole or not at all — the caller's transaction holds the rest.
    """
    if not kept:
        return
    warehouse_id = _warehouse_id(purchase_order)
    wanted_ids = {int(pk) for pk in (removed_unit_ids or ())}
    rows_by_line = _receipt_rows([item.line for item in kept])
    named = set()
    units_needed = []
    leaving = []
    for item in kept:
        line = item.line
        snapshot = item.snapshot
        rows = rows_by_line.get(line.pk, [])
        if not rows:
            # Received before receipts were recorded line by line: there is no
            # record of which articles or lots this delivery was, so there is
            # nothing to correct in place.
            raise serializers.ValidationError(
                {
                    "code": "purchase_order_has_identified_stock",
                    "detail": (
                        "استُلم هذا الأمر قبل تسجيل الاستلام بالتفصيل، فلا يمكن "
                        "تعديل بضاعته المعرّفة. استخدم مرتجع مشتريات بدلًا من ذلك."
                    ),
                    "stock_units": [],
                    "stock_batches": [],
                }
            )
        item.receipt_rows = rows
        surplus = snapshot["accepted"] - item.accepted
        if surplus <= 0:
            continue
        base = line.to_base_quantity(surplus)
        mode = tracking.mode_of(line.variant)
        if tracking.tracks_units(mode):
            live = list(
                StockUnit.objects.filter(
                    source_receipt_line__in=rows,
                    variant=line.variant,
                    status=StockUnit.Status.IN_STOCK,
                    warehouse_id=warehouse_id,
                ).order_by("pk")
            )
            count = int(base)
            if len(live) < count:
                raise _sold_error(line, requested=base, available=len(live))
            chosen = [unit for unit in live if unit.pk in wanted_ids]
            named.update(unit.pk for unit in chosen)
            if not chosen and len(live) == count:
                # Every article still here has to go: there is no choice to ask.
                chosen = live
            if len(chosen) != count:
                units_needed.append(
                    {
                        "line": line.pk,
                        "variant": line.variant_id,
                        "product_name": line.variant.product.name,
                        "variant_name": line.variant.full_name,
                        "remove_count": count,
                        "candidates": [
                            {"id": unit.pk, "code": unit.code} for unit in live
                        ],
                    }
                )
                continue
            plan = tracking.plan_receipt_reversal(
                variant=line.variant,
                warehouse=warehouse_id,
                quantity=base,
                receipt_lines=rows,
                voucher_type=StockLedgerEntry.VoucherType.PURCHASE_RECEIPT,
                voucher_id=purchase_order.pk,
                units=chosen,
            )
        else:
            plan = tracking.plan_receipt_reversal(
                variant=line.variant,
                warehouse=warehouse_id,
                quantity=base,
                receipt_lines=rows,
                voucher_type=StockLedgerEntry.VoucherType.PURCHASE_RECEIPT,
                voucher_id=purchase_order.pk,
            )
        if plan is None or plan.quantity < base:
            raise _sold_error(
                line,
                requested=base,
                available=plan.quantity if plan is not None else ZERO,
            )
        leaving.append((line, base, plan))

    if units_needed:
        raise serializers.ValidationError(
            {
                "code": "purchase_edit_units_required",
                "detail": (
                    "اختر الوحدات التي ستُحذف من هذا الأمر — كل وحدة لها رقمها "
                    "ولا يمكن تخمين أيها لم يصل."
                ),
                "lines": units_needed,
            }
        )
    stray = wanted_ids - named
    if stray:
        raise serializers.ValidationError(
            {
                "code": "purchase_edit_unknown_units",
                "detail": (
                    "بعض الوحدات المختارة لا تخص هذا الأمر أو لم تعد في المخزون."
                ),
                "stock_units": sorted(stray),
            }
        )

    _take_off_shelf(purchase_order, leaving, created_by=created_by)
    for item in kept:
        _cancel_damaged_surplus(item)
        _shrink_receipt_rows(item)
    # A dropped line's rows on a receipt that was itself cancelled moved
    # nothing, but they still hold the line in place.
    PurchaseReceiptLine.objects.filter(
        purchase_line__in=[item.line for item in kept if item.removed],
        receipt__doc_status=DocumentStatus.CANCELLED,
    ).delete()


def _take_off_shelf(purchase_order, leaving, *, created_by):
    if not leaving:
        return
    stock_items = lock_stock_items(
        [line.variant for line, _base, _plan in leaving],
        warehouse=_warehouse_id(purchase_order),
    )
    movements = []
    for line, base, plan in leaving:
        stock_item = stock_items[line.variant_id]
        before = stock_snapshot(stock_item)
        stock_item.quantity_on_hand -= base
        movements.append(
            build_stock_movement(
                variant=line.variant,
                stock_item=stock_item,
                movement_type=StockMovement.Type.DECREASE,
                quantity=base,
                note=f"تعديل استلام {purchase_order.order_number}",
                created_by=created_by,
                before=before,
                tracked_plan=plan,
            )
        )
    save_stock_item_quantities_bulk(stock_items.values())
    # The articles and lots move before the ledger reads the plans, exactly as
    # a cancelled receipt's do.
    for _line, _base, plan in leaving:
        tracking.apply_receipt_reversal(plan)
    create_stock_movements(
        movements,
        voucher_type=StockLedgerEntry.VoucherType.PURCHASE_RETURN,
        voucher_id=purchase_order.pk,
    )


def _cancel_damaged_surplus(item):
    """Damaged articles the corrected line no longer says arrived.

    They never reached the shelf, so nothing is valued; the rows are cancelled
    so their identifiers are free and the line stops counting them.
    """
    surplus = item.snapshot["damaged"] - item.damaged
    line = item.line
    if surplus <= 0 or not tracking.tracks_units(tracking.mode_of(line.variant)):
        return
    for unit in StockUnit.objects.select_for_update().filter(
        source_receipt_line__in=item.receipt_rows,
        status=StockUnit.Status.DAMAGED,
    ).order_by("-pk")[: int(line.to_base_quantity(surplus))]:
        tracking.transition_unit(unit, StockUnit.Status.CANCELLED)


def _shrink_receipt_rows(item):
    """Write the corrected quantities onto the line's receipt rows, newest
    first. Over-delivery goes before what the order expected, which keeps
    ``expected_reduction_quantity`` true for a later cancellation of the
    receipt. A row left with nothing on it goes."""
    remaining = {
        "accepted_quantity": item.snapshot["accepted"] - item.accepted,
        "damaged_quantity": item.snapshot["damaged"] - item.damaged,
        "cancelled_quantity": item.snapshot["cancelled"] - item.cancelled,
    }
    if all(value <= 0 for value in remaining.values()):
        return
    for row in item.receipt_rows:
        removed = ZERO
        for field, wanted in remaining.items():
            take = min(getattr(row, field), max(wanted, ZERO))
            if take <= 0:
                continue
            setattr(row, field, getattr(row, field) - take)
            remaining[field] = wanted - take
            removed += take
        if removed <= 0:
            continue
        over = min(row.over_received_quantity, removed)
        row.over_received_quantity -= over
        row.expected_reduction_quantity = max(
            row.expected_reduction_quantity - (removed - over), ZERO
        )
        if (
            row.accepted_quantity <= 0
            and row.damaged_quantity <= 0
            and row.cancelled_quantity <= 0
        ):
            row.delete()
        else:
            row.save(
                update_fields=[
                    "accepted_quantity",
                    "damaged_quantity",
                    "cancelled_quantity",
                    "over_received_quantity",
                    "expected_reduction_quantity",
                    "updated_at",
                ]
            )


def apply_kept_line_data(item, data):
    """Write the corrected figures onto the line that is kept, rather than
    replacing it: its receipt rows and its articles point at this row."""
    line = item.line
    for field, value in data.items():
        setattr(line, field, value)
    line.save()


# ---------------------------------------------------------------------------
# Cost
# ---------------------------------------------------------------------------


def restate_kept_costs(purchase_order, kept):
    """Carry a corrected cost onto the stock it valued, and the sales it fed.

    Runs once the order has been recalculated, so each line's effective cost —
    discounts and landed costs included — is final.
    """
    items = [item for item in kept if not item.removed]
    if not items:
        return
    lines = {
        line.pk: line
        for line in purchase_order.lines.filter(
            pk__in=[item.line.pk for item in items]
        ).select_related("variant", "variant__product")
    }
    lot_changes = defaultdict(lambda: [ZERO, ZERO])
    for item in items:
        line = lines.get(item.line.pk)
        if line is None:
            continue
        delta = line.effective_base_unit_cost_exact - item.old_rate
        if delta == 0:
            continue
        if tracking.tracks_units(tracking.mode_of(line.variant)):
            _restate_units(purchase_order, line, delta)
        elif item.accepted > 0:
            # A lot does not know which order line filled it, only which
            # order: lines of one product are restated together, at their
            # quantity-weighted change.
            base = line.to_base_quantity(item.accepted)
            change = lot_changes[line.variant_id]
            change[0] += delta * base
            change[1] += base
    for variant_id, (value, quantity) in lot_changes.items():
        if quantity > 0:
            _restate_lots(purchase_order, variant_id, value / quantity)


def _note(purchase_order):
    return f"تعديل تكلفة أمر شراء {purchase_order.order_number}"


def _restate_units(purchase_order, line, delta):
    ids = set(
        StockUnit.objects.filter(
            Q(source_receipt_line__purchase_line=line) | Q(purchase_line=line)
        )
        .exclude(status=StockUnit.Status.CANCELLED)
        .values_list("pk", flat=True)
    )
    if not ids:
        return
    units = list(StockUnit.objects.select_for_update().filter(pk__in=ids))
    travelling = [
        unit.code for unit in units if unit.status == StockUnit.Status.IN_TRANSIT
    ]
    if travelling:
        # Between two places the article belongs to neither bin, so there is
        # nowhere to post its new value. Landing the transfer first is cheap.
        raise serializers.ValidationError(
            {
                "code": "purchase_edit_units_in_transit",
                "detail": (
                    "لا يمكن تعديل تكلفة هذا الأمر الآن: بعض وحداته في طريقها "
                    "إلى فرع آخر. أكمل استلام التحويل ثم عدّل."
                ),
                "stock_units": travelling[:10],
            }
        )
    now = timezone.now()
    on_hand = defaultdict(lambda: ZERO)
    sold = defaultdict(lambda: ZERO)
    changed = []
    for unit in units:
        old = Decimal(unit.incoming_rate)
        new = max(old + delta, ZERO).quantize(RATE_PLACES)
        diff = new - old
        if diff == 0:
            continue
        unit.incoming_rate = new
        unit.updated_at = now
        changed.append(unit)
        if unit.status in StockUnit.ON_HAND_STATUSES:
            on_hand[unit.warehouse_id] += diff
        if unit.sold_order_line_id:
            sold[unit.sold_order_line_id] += diff
    if not changed:
        return
    StockUnit.objects.bulk_update(changed, ["incoming_rate", "updated_at"])
    for warehouse_id, value in on_hand.items():
        post_value_only_entry(
            variant_id=line.variant_id,
            warehouse_id=warehouse_id,
            value=value,
            voucher_type=StockLedgerEntry.VoucherType.PURCHASE_RECEIPT,
            voucher_id=purchase_order.pk,
            note=_note(purchase_order),
        )
    if sold:
        from apps.sales.models import OrderLine

        _restate_sale_lines(
            {
                order_line: sold[order_line.pk]
                for order_line in OrderLine.objects.select_related("order").filter(
                    pk__in=sold
                )
            }
        )


def _restate_lots(purchase_order, variant_id, delta):
    """Re-rate the lots this order filled, by the share of each it filled.

    A lot delivered twice is one balance at a blended rate, and nothing records
    which of its remaining packs came from which delivery. This order's share of
    everything the lot received is the honest answer, and the exact one in the
    usual case of a lot that only ever came on this order.
    """
    warehouse_id = _warehouse_id(purchase_order)
    contributed = defaultdict(lambda: ZERO)
    for row in (
        StockAllocation.objects.filter(
            variant_id=variant_id,
            warehouse_id=warehouse_id,
            voucher_id=purchase_order.pk,
            voucher_type__in=[
                StockLedgerEntry.VoucherType.PURCHASE_RECEIPT,
                StockLedgerEntry.VoucherType.PURCHASE_RETURN,
            ],
            batch__isnull=False,
        )
        .values("batch_id", "direction")
        .annotate(quantity=Sum("quantity"))
    ):
        sign = 1 if row["direction"] == StockAllocation.Direction.IN else -1
        contributed[row["batch_id"]] += sign * Decimal(row["quantity"])
    since = PurchaseReceipt.objects.filter(purchase_order=purchase_order).aggregate(
        first=Min("received_at")
    )["first"]
    value = ZERO
    sold = defaultdict(lambda: ZERO)
    for batch_id, quantity in sorted(contributed.items()):
        if quantity <= 0:
            continue
        balance = (
            StockBatchBalance.objects.select_for_update()
            .filter(batch_id=batch_id, warehouse_id=warehouse_id)
            .first()
        )
        if balance is None:
            continue
        received = Decimal(balance.received_quantity)
        share = min(quantity / received, Decimal("1")) if received > 0 else Decimal("1")
        old = Decimal(balance.incoming_rate)
        new = max(old + delta * share, ZERO).quantize(RATE_PLACES)
        diff = new - old
        if diff == 0:
            continue
        balance.incoming_rate = new
        balance.save(update_fields=["incoming_rate", "updated_at"])
        value += Decimal(balance.remaining_quantity) * diff
        sales = StockAllocation.objects.filter(
            batch_id=batch_id,
            warehouse_id=warehouse_id,
            voucher_type=StockLedgerEntry.VoucherType.SALE,
            direction=StockAllocation.Direction.OUT,
        )
        if since is not None:
            sales = sales.filter(posting_at__gte=since)
        for row in sales.values("voucher_id").annotate(quantity=Sum("quantity")):
            sold[row["voucher_id"]] += Decimal(row["quantity"]) * diff
    post_value_only_entry(
        variant_id=variant_id,
        warehouse_id=warehouse_id,
        value=value,
        voucher_type=StockLedgerEntry.VoucherType.PURCHASE_RECEIPT,
        voucher_id=purchase_order.pk,
        note=_note(purchase_order),
    )
    if sold:
        _restate_sold_lots(variant_id, sold)


def _restate_sold_lots(variant_id, value_by_order):
    """Spread each sale's restated cost over its lines of the product, by the
    base quantity each sold — a lot allocation names the sale, not the line."""
    from apps.sales.models import OrderLine

    by_order = defaultdict(list)
    for order_line in OrderLine.objects.select_related("order").filter(
        order_id__in=value_by_order, variant_id=variant_id
    ):
        by_order[order_line.order_id].append(order_line)
    extras = {}
    for order_id, order_lines in by_order.items():
        bases = {
            order_line.pk: Decimal(order_line.quantity)
            * Decimal(order_line.unit_factor or 1)
            for order_line in order_lines
        }
        total = sum(bases.values(), ZERO)
        if total <= 0:
            continue
        for order_line in order_lines:
            extras[order_line] = (
                value_by_order[order_id] * bases[order_line.pk] / total
            )
    _restate_sale_lines(extras)


def _restate_sale_lines(extra_by_line):
    """Add ``extra`` to what each sale line's goods cost.

    ``OrderLine.unit_cost`` is what every profit report reads, so this is where
    a corrected purchase cost reaches gross profit. A sale in a closed period is
    left as the books closed it.
    """
    from apps.sales.models import Order, OrderLine

    date_field = money_date_field(Order)
    updated = []
    now = timezone.now()
    for order_line, extra in extra_by_line.items():
        quantity = Decimal(order_line.quantity)
        if quantity <= 0 or extra == 0:
            continue
        if period_is_locked(getattr(order_line.order, date_field)):
            continue
        total = Decimal(order_line.unit_cost) * quantity + extra
        unit_cost = max(total / quantity, ZERO).quantize(
            MONEY_PLACES, rounding=ROUND_HALF_UP
        )
        if unit_cost != order_line.unit_cost:
            order_line.unit_cost = unit_cost
            order_line.updated_at = now
            updated.append(order_line)
    if updated:
        OrderLine.objects.bulk_update(updated, ["unit_cost", "updated_at"])
