"""What a sale means to the document lifecycle.

The sales viewset has said the right thing for a long time — *"orders are
append-only: they may be created and then only adjusted through the audited
void and return_items actions … so a sale can never be silently edited or
erased, including by a manager"* — and enforced it at the HTTP layer only.
These hooks are what make that true of the model as well, and they are where
the two meanings tangled up in ``Order.status`` finally come apart.
"""

from decimal import Decimal

from apps.sales.models import Order, OrderAdjustment


def _fully_returned(order) -> bool:
    return all(line.returnable_quantity <= 0 for line in order.lines.all())


def progress_status(order) -> str:
    """Where the *money and the goods* have got to — not whether the document
    is live.

    ``open`` has meant two unrelated things since credit invoices shipped: a
    sale still being rung up, and an issued, delivered, revenue-recognised
    invoice that happens to be unpaid. That is why ``recognized_sale_q`` has to
    exist and why forty-one call sites have to know about it. The lifecycle now
    carries the first meaning, and this function derives the second — so the
    field keeps every value and every query that reads it, while the ambiguity
    stops being load-bearing.
    """
    from apps.documents.statuses import DocumentStatus

    if order.doc_status == DocumentStatus.CANCELLED:
        return Order.Status.VOID
    if order.doc_status == DocumentStatus.DRAFT:
        return Order.Status.OPEN

    # Submitted. A sale whose every line has come back is spent, whatever its
    # payments say — the rule ``return_order_items`` has always applied, now
    # stated once. The adjustment amounts are read first because they are
    # needed either way, and a checkout has none.
    refunded = list(order.adjustments.values_list("amount", flat=True))
    if refunded and _fully_returned(order):
        return Order.Status.VOID

    # "Paid" is about the sale having been settled, not about what is in the
    # drawer now: a refund is recorded as a negative payment, so a part-returned
    # sale's balance climbs back above zero even though the customer settled it
    # in full and was given part of it back. What was refunded therefore counts
    # towards what was paid — which is exactly the high-water mark the assigned
    # status used to hold by never being written again.
    settled = order.amount_paid + sum(refunded, Decimal("0.00"))
    return (
        Order.Status.PAID
        if settled >= order.total
        else Order.Status.OPEN
    )


def recompute_progress(order) -> None:
    status = progress_status(order)
    if order.status == status:
        return
    order.status = status
    order.save(update_fields=["status", "updated_at"])


def reverse(order, *, at, actor, reason="", context=None):
    """Give back a sale: the goods to the shelf, the money to the customer.

    This is the body of today's ``void_order``, moved behind the primitive so
    that everything around it — the period lock it never had, the trail, the
    status — happens for every document in the same way and in the same order.
    A sale that has already been returned in full has nothing left to give
    back, and reversing it is a no-op rather than an error: the counter-
    documents did the work already.
    """
    from apps.sales.services import (
        create_order_adjustment,
        lock_order_lines_for_update,
        release_quote_reservations,
    )

    if order.sale_type == Order.SaleType.QUOTATION:
        # A quotation moved no stock and took no money: what it holds is a
        # reservation, and giving that back is the whole of its reversal.
        release_quote_reservations(order)
        return None

    context = context or {}
    # The caller has usually locked the lines and worked out what is left to
    # give back already — it needs that to refuse an empty void with a sentence
    # a cashier can read. Reuse its answer rather than asking every line again.
    lines = context.get("lines")
    if lines is None:
        locked_lines = lock_order_lines_for_update(order)
        lines = [
            (line, line.returnable_quantity)
            for line in locked_lines
            if line.returnable_quantity > 0
        ]
    if not lines:
        return None
    # The refund leaves the drawer that is open now, not the one that took the
    # money — a sale voided in tomorrow's shift is tomorrow's cash out. The
    # caller knows which that is; the primitive passes it through untouched.
    return create_order_adjustment(
        order=order,
        adjustment_type=OrderAdjustment.AdjustmentType.VOID,
        lines=lines,
        reason=reason,
        created_by=actor,
        register_session=context.get("register_session") or order.register_session,
    )


__all__ = [
    "progress_status",
    "recompute_progress",
    "reverse",
]
