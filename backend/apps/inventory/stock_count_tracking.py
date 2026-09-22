"""Counting a shelf whose articles have names.

§6.6. For a serialized variant, counting a *number* is meaningless — two
handsets of one model are not interchangeable, and "4" is not an answer to
which four. The count becomes **scan every unit present**, and the delta is
two lists that are each actionable on their own:

* expected but not scanned → **missing**, a write-off proposal
* scanned but not expected → **found**, an opening-identification proposal

For a batch variant the count is per **balance**, which is what a counter
actually does: they are standing in one room counting the packs of one lot on
one shelf. Variance is ``counted − balance.remaining_quantity`` in that
warehouse, and the lot's stock elsewhere is neither shown nor touched.

Both of these fall out of the model nearly for free, which is the argument for
having built it this way: ``StockCount`` already has the blind scan→count
loop, the manager-applies split and the variance threshold.
"""

from __future__ import annotations

from decimal import Decimal

from django.utils import timezone
from rest_framework import serializers

from . import tracking
from .identity import normalize_identifier
from .models import (
    StockBatchBalance,
    StockCountLine,
    StockCountScan,
    StockUnit,
)

ZERO = Decimal("0")
ONE = Decimal("1")


# ---------------------------------------------------------------------------
# What kind of count a line is
# ---------------------------------------------------------------------------


def counts_by_scan(variant) -> bool:
    """Is this variant counted by scanning articles rather than by number?"""
    return tracking.tracks_units(tracking.mode_of(variant))


def counts_by_lot(variant) -> bool:
    """Is this variant counted one lot at a time?"""
    mode = tracking.mode_of(variant)
    return tracking.tracks_lots(mode) and not tracking.tracks_units(mode)


# ---------------------------------------------------------------------------
# The scan loop
# ---------------------------------------------------------------------------


def expected_units(stock_count, variant=None):
    """The articles this warehouse believes it is holding, right now."""
    rows = StockUnit.objects.filter(
        warehouse_id=stock_count.warehouse_id,
        status__in=StockUnit.ON_HAND_STATUSES,
    )
    if variant is not None:
        rows = rows.filter(variant=variant)
    elif stock_count.scope == stock_count.Scope.CATEGORY and stock_count.category_id:
        from apps.catalog.services import category_ids_with_descendants

        # A product belongs to categories (plural, M2M) and always has — there
        # is no ``category_id`` column to filter on, and the helper takes a set
        # of ids, not one. Both mistakes only fired on a category-scoped count
        # of serialized stock, so the endpoint 500'd where a full count was
        # fine. ``distinct`` because a product in two of the chosen categories
        # would otherwise list its units twice.
        rows = rows.filter(
            variant__product__categories__id__in=category_ids_with_descendants(
                [stock_count.category_id]
            )
        ).distinct()
    return rows


def record_scan(stock_count, *, code, variant=None, actor=None, at=None):
    """One article, read off the shelf.

    Blind, like the rest of the count: this says what the identifier *is*, not
    whether it was expected. Telling a counter "that one is a surprise" while
    they are still counting is how a count becomes a search for the number the
    system wanted.

    ``variant`` is for the one case the identifier cannot answer by itself: a
    code nothing in the shop has ever seen. There is no way to know what
    product it is, so the count records the finding and the counter says what
    it is — which is §6.6's *opening-identification proposal* made actionable
    rather than a line of prose in a report.
    """
    code = str(code or "").strip()
    normalized = normalize_identifier(code)
    if not normalized:
        raise serializers.ValidationError({"code": "امسح معرّفًا صالحًا."})

    at = at or timezone.now()
    existing = StockCountScan.objects.filter(
        stock_count=stock_count, code_normalized=normalized
    ).first()
    if existing is not None:
        # Scanning the same handset twice is one handset, and saying so is
        # more useful than a duplicate-key error a counter cannot act on.
        return existing, False

    unit = (
        StockUnit.objects.select_related("variant", "variant__product", "batch")
        .filter(code_normalized=normalized, status__in=StockUnit.LIVE_STATUSES)
        .order_by("-id")
        .first()
    )
    if unit is None:
        # Not live anywhere. It may still be an article this shop sold or wrote
        # off, which is a different and more interesting finding than a code
        # nobody has ever seen.
        unit = (
            StockUnit.objects.select_related("variant", "variant__product", "batch")
            .filter(code_normalized=normalized)
            .order_by("-id")
            .first()
        )

    scan = StockCountScan(
        stock_count=stock_count,
        code=code,
        unit=unit,
        variant=unit.variant if unit is not None else variant,
        found_elsewhere=(
            unit is not None
            and unit.status in StockUnit.ON_HAND_STATUSES
            and unit.warehouse_id != stock_count.warehouse_id
        ),
        scanned_at=at,
        scanned_by=actor,
    )
    scan.save()
    if scan.variant_id is not None:
        scan.line = sync_scanned_line(
            stock_count, scan.variant, actor=actor, at=at
        )
        scan.save(update_fields=["line", "updated_at"])
    return scan, True


def sync_scanned_line(stock_count, variant, *, actor=None, at=None):
    """Keep the variant's line equal to how many of it have been scanned.

    The line still exists, and still carries the count's variance machinery —
    what changes is who writes ``counted_quantity``. A counter scanning a shelf
    is not typing a number, so nothing may let them.
    """
    at = at or timezone.now()
    counted = StockCountScan.objects.filter(
        stock_count=stock_count, variant=variant
    ).count()
    expected = expected_units(stock_count, variant=variant).count()
    line, _ = StockCountLine.objects.update_or_create(
        stock_count=stock_count,
        variant=variant,
        batch=None,
        defaults={
            "counted_quantity": Decimal(counted),
            "expected_quantity": Decimal(expected),
            "counted_at": at,
            "counted_by": actor,
            "needs_review": counted != expected,
        },
    )
    StockCountScan.objects.filter(
        stock_count=stock_count, variant=variant, line__isnull=True
    ).update(line=line)
    return line


# ---------------------------------------------------------------------------
# The two lists
# ---------------------------------------------------------------------------


def reconcile_scans(stock_count):
    """The four findings a scanned count produces, by name.

    ``missing`` and ``found`` are §6.6's two lists. The other two are the cases
    a serial number makes visible and a quantity never could: an article
    standing in this room whose row says another branch (a transfer nobody
    wrote down) and an article the books say was sold (a sale that never left).
    """
    scans = list(
        StockCountScan.objects.filter(stock_count=stock_count)
        .select_related("unit", "variant", "variant__product", "unit__warehouse")
        .order_by("scanned_at", "id")
    )
    scanned_unit_ids = {scan.unit_id for scan in scans if scan.unit_id}

    expected = list(
        expected_units(stock_count)
        .select_related("variant", "variant__product")
        .order_by("variant_id", "id")
    )
    missing = [unit for unit in expected if unit.pk not in scanned_unit_ids]

    unknown, relocated, resurrected = [], [], []
    for scan in scans:
        if scan.unit_id is None:
            unknown.append(scan)
        elif scan.found_elsewhere:
            relocated.append(scan)
        elif scan.unit.status not in StockUnit.ON_HAND_STATUSES:
            resurrected.append(scan)
    return {
        "missing": missing,
        "unknown": unknown,
        "relocated": relocated,
        "resurrected": resurrected,
        "scanned": len(scans),
        "expected": len(expected),
    }


def reconcile_lots(stock_count):
    """Per-lot variance for the batch lines of this count."""
    rows = []
    lines = (
        stock_count.lines.filter(batch__isnull=False)
        .select_related("batch", "variant", "variant__product")
        .order_by("variant_id", "batch__expiry_date", "batch_id")
    )
    for line in lines:
        balance = StockBatchBalance.objects.filter(
            batch_id=line.batch_id, warehouse_id=stock_count.warehouse_id
        ).first()
        remaining = balance.remaining_quantity if balance is not None else ZERO
        rows.append(
            {
                "line": line,
                "balance": balance,
                "remaining": remaining,
                "counted": line.counted_quantity,
                "variance": line.counted_quantity - remaining,
                # A lot found in a warehouse that has no balance for it is how
                # stock that walked between branches without paperwork gets
                # found, and it is worth surfacing by name rather than
                # absorbing into a number.
                "new_here": balance is None,
            }
        )
    return rows


# ---------------------------------------------------------------------------
# Applying
# ---------------------------------------------------------------------------


def lot_line_expected(stock_count, line):
    """What the books say about this lot in this room."""
    balance = StockBatchBalance.objects.filter(
        batch_id=line.batch_id, warehouse_id=stock_count.warehouse_id
    ).first()
    return balance.remaining_quantity if balance is not None else ZERO


def scanned_line_deltas(stock_count, line):
    """``(units_out, unit_rows_in)`` for one scanned variant's line.

    ``units_out`` are the articles the shelf no longer has; ``unit_rows_in``
    are capture rows for the ones it has and the books did not. Both are fed
    straight to :func:`apps.inventory.services.allocate_adjustment`, which is
    the same door a manual adjustment and a job's materials go through.
    """
    scanned_units = {
        scan.unit_id: scan
        for scan in StockCountScan.objects.filter(
            stock_count=stock_count, variant=line.variant
        ).select_related("unit")
        if scan.unit_id
    }
    expected = list(expected_units(stock_count, variant=line.variant))
    units_out = [unit for unit in expected if unit.pk not in scanned_units]

    rows_in = []
    for scan in StockCountScan.objects.filter(
        stock_count=stock_count, variant=line.variant, unit__isnull=True
    ):
        rows_in.append(
            {
                "code": scan.code,
                "notes": f"وُجد في الجرد {stock_count.count_number}",
            }
        )
    return units_out, rows_in


def apply_scanned_line(stock_count, line, *, actor=None, at=None):
    """Write both sides of a scanned line, as two movements.

    **Never netted**, and that is the whole of this function. One handset
    missing and one unrecognised article found is a shelf that counts the same
    either way — and a net of zero would write nothing at all, leaving the
    missing one still in stock and the found one still not existing. A net of
    minus one is worse: the quantity and the named articles disagree, and
    ``plan_adjustment`` refuses outright.

    So *three went missing* and *one turned up* are two events, they are
    posted as two, and the ledger reads the way the count actually went.
    Returns the last movement, for the line to point at.
    """
    from .models import StockLedgerEntry, StockMovement
    from .services import (
        allocate_adjustment,
        create_stock_movement,
        lock_stock_item,
        save_stock_item_quantities,
        stock_snapshot,
    )

    at = at or timezone.now()
    units_out, rows_in = scanned_line_deltas(stock_count, line)
    note = _movement_note(stock_count)
    movement = None

    for quantity, rows, movement_type, direction in (
        (len(units_out), units_out, StockMovement.Type.DECREASE, -1),
        (len(rows_in), rows_in, StockMovement.Type.INCREASE, 1),
    ):
        if not quantity:
            continue
        stock_item = lock_stock_item(
            variant=line.variant, warehouse=stock_count.warehouse_id
        )
        delta = Decimal(direction * quantity)
        if direction < 0 and stock_item.quantity_on_hand + delta < ZERO:
            raise serializers.ValidationError(
                {
                    "variant": (
                        f"Applying the count would make {line.variant.sku} "
                        "negative."
                    )
                }
            )
        before = stock_snapshot(stock_item)
        stock_item.quantity_on_hand += delta
        save_stock_item_quantities(stock_item)
        plan = allocate_adjustment(
            variant=line.variant,
            warehouse=stock_count.warehouse_id,
            delta=delta,
            units=[unit.pk for unit in rows] if direction < 0 else rows,
            placeholder_key=f"SC-{stock_count.pk}-{line.pk}",
            what="هذا الجرد",
        )
        movement = create_stock_movement(
            stock_item=stock_item,
            movement_type=movement_type,
            quantity=Decimal(quantity),
            note=note,
            created_by=actor,
            before=before,
            variant=line.variant,
            voucher_type=StockLedgerEntry.VoucherType.STOCK_COUNT,
            voucher_id=stock_count.pk,
            posting_at=at,
            tracked_plan=plan,
        )
        for unit in rows if direction < 0 else []:
            record_unit_event(
                unit,
                kind="counted",
                actor=actor,
                at=at,
                to_value=StockUnit.Status.WRITTEN_OFF,
                note=note,
                reference_type="stock_count",
                reference_id=stock_count.pk,
            )
    return movement


def resurrect_and_relocate(stock_count, *, actor=None, at=None):
    """Articles found here that the books had somewhere else, or gone.

    Both are handled before the variance is applied, and neither is a variance:
    nothing is created or destroyed, a row is put right. A relocation is a
    transfer that happened without paperwork; a resurrection is a unit that was
    written off and turned up. A unit the books say was **sold** is neither —
    that is a sale that never left the shop, and it is refused here rather than
    quietly un-sold, because the money side of it has to be decided by a
    person.
    """
    at = at or timezone.now()
    moved = 0
    scans = (
        StockCountScan.objects.filter(stock_count=stock_count, unit__isnull=False)
        .select_related("unit", "unit__variant", "unit__variant__product")
        .order_by("id")
    )
    for scan in scans:
        unit = scan.unit
        if unit.status == StockUnit.Status.SOLD:
            raise serializers.ValidationError(
                {
                    "detail": (
                        f"الوحدة {unit.code} مسجّلة كمباعة وهي على الرف — "
                        "عالج الإرجاع أولًا ثم أعد تطبيق الجرد."
                    ),
                    "stock_unit": unit.pk,
                }
            )
        if scan.found_elsewhere:
            _relocate(unit, stock_count, actor=actor, at=at)
            moved += 1
        elif unit.status == StockUnit.Status.WRITTEN_OFF:
            _resurrect(unit, stock_count, actor=actor, at=at)
            moved += 1
    return moved


def _movement_note(stock_count):
    return f"جرد المخزون {stock_count.count_number}"


def _relocate(unit, stock_count, *, actor, at):
    """Issue it where the books had it, receive it where it actually is.

    A transfer that happened without paperwork, written down after the fact —
    so it goes through the same two legs a real transfer does rather than
    flipping a column. Nothing is created and nothing is destroyed, which is
    why this runs *before* the variance and is not part of it.
    """
    from .models import StockLedgerEntry, StockMovement
    from .services import (
        build_stock_movement,
        create_stock_movements,
        lock_stock_item,
        save_stock_item_quantities_bulk,
        stock_snapshot,
    )

    origin_id = unit.warehouse_id
    source_item = lock_stock_item(variant=unit.variant, warehouse=origin_id)
    destination_item = lock_stock_item(
        variant=unit.variant, warehouse=stock_count.warehouse_id
    )

    out_plan = tracking.plan_issue(
        variant=unit.variant,
        warehouse=origin_id,
        quantity=ONE,
        unit_ids=[unit.pk],
        allow_expired=True,
    )
    in_plan = tracking.mirror_plan_into(
        out_plan, warehouse=stock_count.warehouse_id, variant=unit.variant
    )

    out_before = stock_snapshot(source_item)
    source_item.quantity_on_hand -= ONE
    tracking.apply_dispatch(
        out_plan, transit_warehouse=stock_count.warehouse_id, at=at
    )
    out_movement = build_stock_movement(
        variant=unit.variant,
        stock_item=source_item,
        movement_type=StockMovement.Type.TRANSFER_OUT,
        quantity=ONE,
        note=_movement_note(stock_count),
        created_by=actor,
        before=out_before,
        tracked_plan=out_plan,
    )
    save_stock_item_quantities_bulk([source_item])
    create_stock_movements(
        [out_movement],
        voucher_type=StockLedgerEntry.VoucherType.STOCK_COUNT,
        voucher_id=stock_count.pk,
        posting_at=at,
    )

    in_before = stock_snapshot(destination_item)
    destination_item.quantity_on_hand += ONE
    tracking.apply_arrival(
        in_plan,
        warehouse=stock_count.warehouse_id,
        status=StockUnit.Status.IN_STOCK,
        at=at,
    )
    in_movement = build_stock_movement(
        variant=unit.variant,
        stock_item=destination_item,
        movement_type=StockMovement.Type.TRANSFER_IN,
        quantity=ONE,
        note=_movement_note(stock_count),
        created_by=actor,
        before=in_before,
        tracked_plan=in_plan,
    )
    save_stock_item_quantities_bulk([destination_item])
    create_stock_movements(
        [in_movement],
        voucher_type=StockLedgerEntry.VoucherType.STOCK_COUNT,
        voucher_id=stock_count.pk,
        posting_at=at,
    )
    record_unit_event(
        unit,
        kind="relocated",
        actor=actor,
        at=at,
        from_value=str(origin_id),
        to_value=str(stock_count.warehouse_id),
        note=_movement_note(stock_count),
        reference_type="stock_count",
        reference_id=stock_count.pk,
    )


def _resurrect(unit, stock_count, *, actor, at):
    """A written-off article that turned up. The only way back."""
    from .models import StockLedgerEntry, StockMovement
    from .services import (
        build_stock_movement,
        create_stock_movements,
        lock_stock_item,
        save_stock_item_quantities_bulk,
        stock_snapshot,
    )

    stock_item = lock_stock_item(
        variant=unit.variant, warehouse=stock_count.warehouse_id
    )
    plan = tracking.plan_return(
        units=[unit], warehouse=stock_count.warehouse_id, variant=unit.variant
    )
    before = stock_snapshot(stock_item)
    stock_item.quantity_on_hand += ONE
    tracking.apply_return(plan, at=at, warehouse_id=stock_count.warehouse_id)
    movement = build_stock_movement(
        variant=unit.variant,
        stock_item=stock_item,
        movement_type=StockMovement.Type.INCREASE,
        quantity=ONE,
        note=_movement_note(stock_count),
        created_by=actor,
        before=before,
        tracked_plan=plan,
    )
    save_stock_item_quantities_bulk([stock_item])
    create_stock_movements(
        [movement],
        voucher_type=StockLedgerEntry.VoucherType.STOCK_COUNT,
        voucher_id=stock_count.pk,
        posting_at=at,
    )
    record_unit_event(
        unit,
        kind="counted",
        actor=actor,
        at=at,
        from_value=StockUnit.Status.WRITTEN_OFF,
        to_value=StockUnit.Status.IN_STOCK,
        note=_movement_note(stock_count),
        reference_type="stock_count",
        reference_id=stock_count.pk,
    )


def record_unit_event(unit, *, kind, actor=None, at=None, **fields):
    """§6.9's audit row, written by the one helper so the shape stays one shape."""
    from .models import StockUnitEvent

    return StockUnitEvent.objects.create(
        unit=unit,
        kind=kind,
        actor=actor,
        at=at or timezone.now(),
        from_value=str(fields.get("from_value", ""))[:240],
        to_value=str(fields.get("to_value", ""))[:240],
        note=str(fields.get("note", ""))[:240],
        reference_type=fields.get("reference_type", ""),
        reference_id=fields.get("reference_id"),
    )


__all__ = [
    "apply_scanned_line",
    "counts_by_lot",
    "counts_by_scan",
    "expected_units",
    "lot_line_expected",
    "reconcile_lots",
    "reconcile_scans",
    "record_scan",
    "record_unit_event",
    "resurrect_and_relocate",
    "scanned_line_deltas",
    "sync_scanned_line",
]
