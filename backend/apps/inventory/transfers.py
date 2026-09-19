"""Moving stock from one of a shop's places to another.

Two documents and a transit location. The dispatch takes goods out of the
source and puts them on the road; a receipt takes them off the road and puts
them at the destination. SAP, Oracle and Odoo all model it this way and the
reason is physical rather than architectural — goods in a van are somewhere,
and a single-step move values them in neither place while the driver is out.

The valuation is the part worth reading twice. Issuing from the source is what
*decides* the rate: the engine consumes the source's own queue and hands back
what those units actually cost. That rate is then fed to the receiving leg as
its declared cost, so the goods arrive valued at exactly what they left at and
an internal move books no profit. Nowhere in this file does anything invent a
cost.
"""

from decimal import Decimal

from django.db import transaction
from django.utils import timezone
from rest_framework import serializers

from apps.documents import services as document_services
from apps.documents import trail
from apps.documents.models import DocumentEvent
from apps.documents.statuses import DocumentStatus

from . import tracking
from .models import (
    StockLedgerEntry,
    StockMovement,
    StockTransfer,
    StockTransferReceipt,
    StockTransferReceiptLine,
    StockUnit,
    Warehouse,
)
from .oversell import may_oversell_document
from .services import (
    build_stock_movement,
    create_stock_movements,
    lock_stock_rows,
    save_stock_item_quantities_bulk,
    stock_snapshot,
)

ZERO = Decimal("0.000")


def _actor(request=None, actor=None):
    if actor is not None:
        return actor
    user = getattr(request, "user", None)
    return user if getattr(user, "is_authenticated", False) else None


def _move(*, pairs, movement_type, note, actor, positive):
    """Apply one leg of a move to a set of locked rows, and build its movements.

    ``pairs`` is ``[(stock_item, base_quantity, plan), ...]``, where ``plan`` is
    the identified stock this leg moves and is ``None`` for everything that is
    not tracked. Returns the unsaved movements, which the caller saves and then
    values.
    """
    movements = []
    touched = []
    for stock_item, quantity, plan in pairs:
        if quantity <= 0:
            continue
        before = stock_snapshot(stock_item)
        stock_item.quantity_on_hand += quantity if positive else -quantity
        touched.append(stock_item)
        movements.append(
            build_stock_movement(
                stock_item=stock_item,
                movement_type=movement_type,
                quantity=quantity,
                note=note,
                created_by=actor,
                before=before,
                tracked_plan=plan,
            )
        )
    save_stock_item_quantities_bulk(touched)
    return [movement for movement in movements if movement is not None]


def _carry(out_pairs, in_pairs, *, note, actor, voucher_type, voucher_id, posting_at):
    """Move one leg out and the other in, carrying the cost between them.

    This is the whole of the transfer's valuation, and it rests on one fact:
    issuing stock is what *decides* what those units cost. ``create_stock_movements``
    values the outgoing leg and stamps ``valuation_rate_applied`` on each
    movement — the rate the source's own queue produced — and handing that
    straight back as the incoming leg's ``unit_costs`` means the goods arrive at
    exactly what they left at. Nothing here invents a cost, so an internal move
    books no profit and the shop's stock value does not flicker while the
    driver is out.

    The two legs are inserted and valued separately rather than together
    because a valuation run rebuilds one bin per variant and a bin belongs to
    one warehouse; posting both ends at once would ask the engine to be in two
    places at the same time.
    """
    out = _move(
        pairs=out_pairs,
        movement_type=StockMovement.Type.TRANSFER_OUT,
        note=note,
        actor=actor,
        positive=False,
    )
    sent = create_stock_movements(
        out, voucher_type=voucher_type, voucher_id=voucher_id, posting_at=posting_at
    )
    rates = {
        movement.variant_id: movement.valuation_rate_applied
        for movement in sent
        if getattr(movement, "valuation_rate_applied", None) is not None
    }
    arriving = _move(
        pairs=in_pairs,
        movement_type=StockMovement.Type.TRANSFER_IN,
        note=note,
        actor=actor,
        positive=True,
    )
    create_stock_movements(
        arriving,
        voucher_type=voucher_type,
        voucher_id=voucher_id,
        posting_at=posting_at,
        unit_costs=rates,
    )
    return rates


def _line_selection(lines, picks):
    """``picks`` keyed by line id, however the caller spelled the keys."""
    if not picks:
        return {}
    by_line = {}
    ids = {line.pk for line in lines}
    for key, value in picks.items():
        try:
            line_id = int(key)
        except (TypeError, ValueError):
            continue
        if line_id in ids and isinstance(value, dict):
            by_line[line_id] = {
                "unit_ids": value.get("unit_ids") or value.get("units"),
                "unit_codes": value.get("unit_codes") or value.get("codes"),
                "batch_ids": value.get("batch_ids") or value.get("batches"),
            }
    return by_line


def _refuse_unnamed_units(line, chosen):
    """A serialized line must name its articles before it leaves.

    Not auto-picked, deliberately, and this is the one place a transfer
    differs from a sale. The till may take the oldest handset off the shelf
    because the customer is holding whichever one it hands them; a van driver
    has already physically chosen five, and a system that picked a different
    five would make the far end's *«sent 5, arrived 4, missing 351…333»*
    reconciliation a lie about which handset is gone.
    """
    if not tracking.tracks_units(tracking.mode_of(line.variant)):
        return
    named = len(chosen.get("unit_ids") or []) + len(chosen.get("unit_codes") or [])
    if named != int(line.base_quantity):
        raise serializers.ValidationError(
            {
                "detail": (
                    f"«{line.variant.full_name}» صنف مسلسل — حدّد "
                    f"{int(line.base_quantity)} وحدة بالمسح قبل إرسال التحويل."
                ),
                "line": line.pk,
                "variant": line.variant_id,
                "named": named,
            }
        )


def _plan_off_the_road(*, line, quantity, transit_id, chosen):
    """What one receiving line takes out of transit.

    A serialized line takes the very articles the dispatch put on the road —
    named if the receiver scanned them, and otherwise in the order they were
    sent. A short delivery is therefore *sent 5, arrived 4, and here is the
    IMEI of the missing one*, which is a shrinkage report a phone shop will
    actually read; the outstanding article stays ``in_transit`` until somebody
    accounts for it.
    """
    return tracking.plan_off_road(
        variant=line.variant,
        warehouse=transit_id,
        quantity=quantity,
        unit_ids=chosen.get("unit_ids"),
        unit_codes=chosen.get("unit_codes"),
        batch_ids=chosen.get("batch_ids"),
    )


@transaction.atomic
def dispatch_transfer(transfer, *, request=None, actor=None, picks=None):
    """Send a draft transfer on its way: source -> transit.

    ``picks`` maps a line's id to the identified stock it moves —
    ``{"units": [...], "batches": [...]}`` — for the lines whose product
    has any. A serialized line with nothing named is refused, because
    which handset went is not derivable and a made-up IMEI in the ledger
    is worse than a transfer that has to be picked properly.
    """
    actor = _actor(request, actor)
    locked = (
        StockTransfer.objects.select_for_update()
        .select_related("source", "destination")
        .get(pk=transfer.pk)
    )
    if locked.doc_status != DocumentStatus.DRAFT:
        raise serializers.ValidationError(
            {"detail": "Only a draft transfer can be dispatched."}
        )
    lines = list(locked.lines.select_related("variant").order_by("variant_id"))
    if not lines:
        raise serializers.ValidationError(
            {"detail": "A transfer must move at least one product."}
        )
    if locked.source_id == locked.destination_id:
        raise serializers.ValidationError(
            {"detail": "A transfer must go somewhere else."}
        )
    for line in lines:
        # ERPNext's ``test_stock_entry_qty``: zero and negative are refused at
        # submission, not merely ignored.
        if line.quantity <= 0:
            raise serializers.ValidationError(
                {"lines": "Every line must move a positive quantity."}
            )

    transit_id = Warehouse.transit_id()
    rows = lock_stock_rows(
        [(line.variant_id, locked.source_id) for line in lines]
        + [(line.variant_id, transit_id) for line in lines]
    )

    # ERPNext's ``test_future_negative_sle``, at the source end: a move cannot
    # take out what is not there unless this place is allowed to go below zero.
    if not may_oversell_document(
        locked.source, variants=[line.variant for line in lines]
    ):
        short = []
        for line in lines:
            available = rows[(line.variant_id, locked.source_id)].quantity_on_hand
            if available < line.base_quantity:
                short.append(
                    {
                        "variant": line.variant_id,
                        "variant_name": line.variant.full_name,
                        "requested": float(line.base_quantity),
                        "available": float(available),
                    }
                )
        if short:
            raise serializers.ValidationError(
                {"detail": "Insufficient stock to transfer.", "stock": short}
            )

    note = f"تحويل {locked.transfer_number or locked.pk}"
    posting_at = timezone.now()
    # Which handsets, and out of which lots. A serialized line says so or is
    # refused — «سيارة فيها خمسة هواتف» is not an answer to *which* five, and
    # the shrinkage report at the far end is the whole reason to ask.
    selection = _line_selection(lines, picks)
    out_plans, in_plans = [], []
    for line in lines:
        chosen = selection.get(line.pk, {})
        _refuse_unnamed_units(line, chosen)
        out_plan = tracking.plan_dispatch(
            variant=line.variant,
            warehouse=locked.source_id,
            quantity=line.base_quantity,
            unit_ids=chosen.get("unit_ids"),
            unit_codes=chosen.get("unit_codes"),
            batch_ids=chosen.get("batch_ids"),
        )
        out_plans.append(out_plan)
        in_plans.append(
            tracking.mirror_plan_into(
                out_plan, warehouse=transit_id, variant=line.variant
            )
        )
    for out_plan in out_plans:
        tracking.apply_dispatch(out_plan, transit_warehouse=transit_id, at=posting_at)
    for in_plan in in_plans:
        # The units have already moved; this receives the lot quantities into
        # the transit balances so the road's own bin has something under it.
        tracking.apply_arrival(
            in_plan, warehouse=transit_id, status=None, at=posting_at
        )

    _carry(
        [
            (
                rows[(line.variant_id, locked.source_id)],
                line.base_quantity,
                out_plans[index],
            )
            for index, line in enumerate(lines)
        ],
        [
            (rows[(line.variant_id, transit_id)], line.base_quantity, in_plans[index])
            for index, line in enumerate(lines)
        ],
        note=note,
        actor=actor,
        voucher_type=StockLedgerEntry.VoucherType.TRANSFER,
        voucher_id=locked.pk,
        posting_at=posting_at,
    )

    # Stamped while the transfer is still a draft, so the freeze has nothing to
    # object to and no escape hatch is needed. ``dispatched_at`` is declared a
    # derived field for the same reason ``StockCount.applied_at`` is: it mirrors
    # the lifecycle's own ``submitted_at`` for an API that predates it.
    locked.dispatched_at = posting_at
    locked.save(update_fields=["dispatched_at", "updated_at"])
    return document_services.submit(locked, actor=actor, request=request)


@transaction.atomic
def receive_transfer(
    transfer, *, lines, request=None, actor=None, note="", picks=None
):
    """Take goods off the road: transit -> destination.

    ``lines`` is ``[(StockTransferLine, base_quantity), ...]``. A transfer may
    arrive in more than one load, which is why this is its own document rather
    than a flag.
    """
    actor = _actor(request, actor)
    locked = (
        StockTransfer.objects.select_for_update()
        .select_related("source", "destination")
        .get(pk=transfer.pk)
    )
    if locked.doc_status != DocumentStatus.SUBMITTED:
        raise serializers.ValidationError(
            {"detail": "Only a dispatched transfer can be received."}
        )

    wanted = []
    for line, quantity in lines:
        quantity = Decimal(quantity)
        if quantity <= 0:
            raise serializers.ValidationError(
                {"lines": "Every received line must be a positive quantity."}
            )
        # ERPNext's ``test_transfer_qty_validation``: you cannot receive more
        # than is on the road, whatever unit the line was written in.
        if quantity > line.outstanding_quantity:
            raise serializers.ValidationError(
                {
                    "lines": (
                        f"Only {line.outstanding_quantity} of "
                        f"{line.variant.full_name} is still in transit."
                    )
                }
            )
        wanted.append((line, quantity))
    if not wanted:
        raise serializers.ValidationError({"lines": "Nothing to receive."})

    transit_id = Warehouse.transit_id()
    rows = lock_stock_rows(
        [(line.variant_id, transit_id) for line, _ in wanted]
        + [(line.variant_id, locked.destination_id) for line, _ in wanted]
    )

    receipt = StockTransferReceipt.objects.create(transfer=locked, note=note)
    StockTransferReceiptLine.objects.bulk_create(
        [
            StockTransferReceiptLine(
                receipt=receipt,
                transfer_line=line,
                variant_id=line.variant_id,
                quantity=quantity,
            )
            for line, quantity in wanted
        ]
    )

    label = f"استلام تحويل {locked.transfer_number or locked.pk}"
    posting_at = timezone.now()
    selection = _line_selection([line for line, _ in wanted], picks)
    out_plans, in_plans = [], []
    for line, quantity in wanted:
        chosen = selection.get(line.pk, {})
        out_plan = _plan_off_the_road(
            line=line,
            quantity=quantity,
            transit_id=transit_id,
            chosen=chosen,
        )
        out_plans.append(out_plan)
        in_plans.append(
            tracking.mirror_plan_into(
                out_plan, warehouse=locked.destination_id, variant=line.variant
            )
        )
    for out_plan in out_plans:
        # Only the lot quantities: the units are transitioned by the arrival,
        # which is the leg that knows where they landed.
        tracking.apply_lot_drawdown(out_plan)
    for in_plan in in_plans:
        tracking.apply_arrival(
            in_plan,
            warehouse=locked.destination_id,
            status=StockUnit.Status.IN_STOCK,
            at=posting_at,
        )

    _carry(
        [
            (rows[(line.variant_id, transit_id)], quantity, out_plans[index])
            for index, (line, quantity) in enumerate(wanted)
        ],
        [
            (
                rows[(line.variant_id, locked.destination_id)],
                quantity,
                in_plans[index],
            )
            for index, (line, quantity) in enumerate(wanted)
        ],
        note=label,
        actor=actor,
        voucher_type=StockLedgerEntry.VoucherType.TRANSFER_RECEIPT,
        voucher_id=receipt.pk,
        posting_at=posting_at,
    )

    for line, quantity in wanted:
        line.received_quantity += quantity
        line.save(update_fields=["received_quantity", "updated_at"])

    # Born submitted — ``has_draft_state=False``, so ``DocumentMixin`` stamped
    # it on insert and asking the lifecycle to submit it again would be an
    # invalid transition. ``PurchaseReceipt`` works exactly this way. What the
    # lifecycle would have written is the trail entry, so that is written here:
    # an arrival is a thing that happened to a document, and the permission for
    # it is gated at the endpoint the way receiving a delivery is.
    trail.record(
        receipt,
        DocumentEvent.Action.SUBMITTED,
        actor=actor,
        details={"transfer": locked.pk, "lines": len(wanted)},
    )

    from apps.inventory import documents as inventory_documents

    inventory_documents.recompute_transfer_progress(locked)
    return receipt


# -- the lifecycle's hooks ---------------------------------------------------


def reverse_transfer(transfer, *, at, actor, reason="", context=None):
    """Bring back what never arrived: transit -> source.

    Only the outstanding part comes back. Anything a receipt already took off
    the road belongs to the destination now, and ``blocks_cancel`` refuses the
    cancellation while such a receipt still stands — you undo the arrival
    first, deliberately, rather than having a cascade reach into the far end's
    shelves.
    """
    lines = list(transfer.lines.select_related("variant").order_by("variant_id"))
    outstanding = [(line, line.outstanding_quantity) for line in lines]
    outstanding = [(line, quantity) for line, quantity in outstanding if quantity > 0]
    if not outstanding:
        return None

    transit_id = Warehouse.transit_id()
    rows = lock_stock_rows(
        [(line.variant_id, transit_id) for line, _ in outstanding]
        + [(line.variant_id, transfer.source_id) for line, _ in outstanding]
    )
    note = f"إلغاء تحويل {transfer.transfer_number or transfer.pk}"
    out_plans, in_plans = [], []
    for line, quantity in outstanding:
        out_plan = tracking.plan_off_road(
            variant=line.variant, warehouse=transit_id, quantity=quantity
        )
        out_plans.append(out_plan)
        in_plans.append(
            tracking.mirror_plan_into(
                out_plan, warehouse=transfer.source_id, variant=line.variant
            )
        )
    for out_plan in out_plans:
        tracking.apply_lot_drawdown(out_plan)
    for in_plan in in_plans:
        tracking.apply_arrival(
            in_plan,
            warehouse=transfer.source_id,
            status=StockUnit.Status.IN_STOCK,
            at=at,
        )
    _carry(
        [
            (rows[(line.variant_id, transit_id)], q, out_plans[index])
            for index, (line, q) in enumerate(outstanding)
        ],
        [
            (rows[(line.variant_id, transfer.source_id)], q, in_plans[index])
            for index, (line, q) in enumerate(outstanding)
        ],
        note=note,
        actor=actor,
        voucher_type=StockLedgerEntry.VoucherType.TRANSFER,
        voucher_id=transfer.pk,
        posting_at=at,
    )
    return None


def reverse_transfer_receipt(receipt, *, at, actor, reason="", context=None):
    """Put an arrival back on the road: destination -> transit.

    The goods are still the shop's either way; what a cancelled receipt says is
    that they never got to the far end, so they go back to being in transit and
    the transfer is outstanding again.
    """
    lines = list(
        receipt.lines.select_related("variant", "transfer_line").order_by("variant_id")
    )
    if not lines:
        return None
    transfer = receipt.transfer
    transit_id = Warehouse.transit_id()
    rows = lock_stock_rows(
        [(line.variant_id, transfer.destination_id) for line in lines]
        + [(line.variant_id, transit_id) for line in lines]
    )

    # Refuses when the goods are no longer there to send back — stock that has
    # already been sold from the destination cannot be un-received, only
    # returned. ERPNext's ``test_negative_batch`` guards the same corner.
    if not may_oversell_document(
        transfer.destination, variants=[line.variant for line in lines]
    ):
        for line in lines:
            available = rows[(line.variant_id, transfer.destination_id)].quantity_on_hand
            if available < line.quantity:
                raise serializers.ValidationError(
                    {
                        "detail": (
                            "Cannot undo this arrival: some of the stock has "
                            "already left the destination."
                        ),
                        "variant": line.variant_id,
                    }
                )

    note = f"إلغاء استلام تحويل {transfer.transfer_number or transfer.pk}"
    out_plans, in_plans = [], []
    for line in lines:
        # Back on the road at the destination's own rate, which for identified
        # stock is each article's own — the same articles going back the way
        # they came, so nothing is revalued by being un-received.
        out_plan = tracking.plan_issue(
            variant=line.variant,
            warehouse=transfer.destination_id,
            quantity=line.quantity,
            allow_expired=True,
        )
        out_plans.append(out_plan)
        in_plans.append(
            tracking.mirror_plan_into(
                out_plan, warehouse=transit_id, variant=line.variant
            )
        )
    for out_plan in out_plans:
        tracking.apply_dispatch(out_plan, transit_warehouse=transit_id, at=at)
    for in_plan in in_plans:
        tracking.apply_arrival(in_plan, warehouse=transit_id, status=None, at=at)
    _carry(
        [
            (
                rows[(line.variant_id, transfer.destination_id)],
                line.quantity,
                out_plans[index],
            )
            for index, line in enumerate(lines)
        ],
        [
            (rows[(line.variant_id, transit_id)], line.quantity, in_plans[index])
            for index, line in enumerate(lines)
        ],
        note=note,
        actor=actor,
        voucher_type=StockLedgerEntry.VoucherType.TRANSFER_RECEIPT,
        voucher_id=receipt.pk,
        posting_at=at,
    )

    for line in lines:
        transfer_line = line.transfer_line
        transfer_line.received_quantity = max(
            transfer_line.received_quantity - line.quantity, ZERO
        )
        transfer_line.save(update_fields=["received_quantity", "updated_at"])
    return None


__all__ = [
    "dispatch_transfer",
    "receive_transfer",
    "reverse_transfer",
    "reverse_transfer_receipt",
]
