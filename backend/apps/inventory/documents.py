"""What a stock count means to the document lifecycle.

Counting is the draft: nothing has moved while a shelf is being walked. Applying
is the submission — the moment the count's discrepancies become stock movements
and the shop's on-hand figures change. Undoing that was impossible before, so a
miscount applied by mistake rewrote the shelf permanently; it is a reversal like
any other now, and it needs the same permission applying it did.
"""

from decimal import Decimal


def progress_status(stock_count) -> str:
    from apps.documents.statuses import DocumentStatus
    from apps.inventory.models import StockCount

    if stock_count.doc_status == DocumentStatus.CANCELLED:
        return StockCount.Status.CANCELLED
    if stock_count.doc_status == DocumentStatus.SUBMITTED:
        return StockCount.Status.APPLIED
    return StockCount.Status.IN_PROGRESS


def recompute_progress(stock_count) -> None:
    status = progress_status(stock_count)
    changed = []
    if stock_count.status != status:
        stock_count.status = status
        changed.append("status")
    # The legacy stamp, mirrored from the lifecycle's own.
    if stock_count.applied_at != stock_count.submitted_at:
        stock_count.applied_at = stock_count.submitted_at
        changed.append("applied_at")
    if stock_count.applied_by_id != stock_count.submitted_by_id:
        stock_count.applied_by_id = stock_count.submitted_by_id
        changed.append("applied_by")
    if changed:
        stock_count.save(update_fields=[*changed, "updated_at"])


def reverse(stock_count, *, at, actor, reason="", context=None):
    """Put the shelf back the way the count found it.

    Every line that moved stock recorded the movement it made, so this is not
    inference: each one is undone by its opposite, of exactly the quantity it
    applied. What it cannot undo is anything that happened *since* — a sale of
    the counted goods is not reversed, so the reversal simply adds back what the
    count took away, and the shelf ends where it would have been had the count
    never been applied.
    """
    from apps.inventory.models import StockLedgerEntry, StockMovement
    from apps.inventory.services import (
        build_stock_movement,
        create_stock_movements,
        lock_stock_items,
        save_stock_item_quantities_bulk,
        stock_snapshot,
    )

    lines = list(
        stock_count.lines.select_related("variant", "movement")
        .filter(applied=True, movement__isnull=False)
        .order_by("variant_id", "id")
    )
    if not lines:
        return None

    stock_items = lock_stock_items([line.variant for line in lines])
    movements = []
    touched = {}
    for line in lines:
        stock_item = stock_items[line.variant_id]
        before = stock_snapshot(stock_item)
        quantity = line.movement.quantity
        if line.movement.movement_type == StockMovement.Type.INCREASE:
            stock_item.quantity_on_hand -= quantity
            movement_type = StockMovement.Type.DECREASE
        else:
            stock_item.quantity_on_hand += quantity
            movement_type = StockMovement.Type.INCREASE
        if stock_item.quantity_on_hand < Decimal("0"):
            from rest_framework import serializers

            raise serializers.ValidationError(
                {
                    "detail": (
                        f"Undoing this count would make {line.variant.sku} "
                        f"negative: the stock it added has already been sold."
                    )
                }
            )
        touched[stock_item.pk] = stock_item
        movements.append(
            build_stock_movement(
                variant=line.variant,
                stock_item=stock_item,
                movement_type=movement_type,
                quantity=quantity,
                note=f"إلغاء جرد {stock_count.count_number}",
                created_by=actor,
                before=before,
            )
        )

    save_stock_item_quantities_bulk(touched.values())
    create_stock_movements(
        movements,
        voucher_type=StockLedgerEntry.VoucherType.STOCK_COUNT,
        voucher_id=stock_count.pk,
    )
    return None


__all__ = ["progress_status", "recompute_progress", "reverse"]


# -- warehouse transfers -----------------------------------------------------


def transfer_progress_status(transfer, *, lines=None) -> str:
    """Where the goods have got to — not whether the document is live.

    The same separation the sale and the purchase order make: ``doc_status``
    says whether this transfer still counts, and this says how much of it has
    arrived. Derived from the lines, written by ``recompute_transfer_progress``
    and nowhere else.
    """
    from apps.documents.statuses import DocumentStatus
    from apps.inventory.models import StockTransfer

    if transfer.doc_status == DocumentStatus.DRAFT:
        return StockTransfer.Status.DRAFT
    if transfer.doc_status == DocumentStatus.CANCELLED:
        return StockTransfer.Status.CANCELLED

    if lines is None:
        lines = transfer.lines.all()
    lines = list(lines)
    outstanding = sum((line.outstanding_quantity for line in lines), Decimal("0.000"))
    received = sum((line.received_quantity for line in lines), Decimal("0.000"))
    if outstanding <= 0:
        return StockTransfer.Status.RECEIVED
    if received > 0:
        return StockTransfer.Status.PARTIALLY_RECEIVED
    return StockTransfer.Status.IN_TRANSIT


def recompute_transfer_progress(transfer, *, lines=None) -> None:
    status = transfer_progress_status(transfer, lines=lines)
    if transfer.status == status:
        return
    transfer.status = status
    transfer.save(update_fields=["status", "updated_at"])
