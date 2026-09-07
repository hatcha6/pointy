"""What a purchase order means to the document lifecycle.

The hooks the primitive needs — how its progress is recomputed, what cancelling
it gives back, and how long it stays correctable — live here rather than in
``apps.documents``, because only purchasing knows what unwinding a delivery
means. The primitive only knows that it must happen, and when.
"""

from decimal import Decimal

from django.core.exceptions import PermissionDenied

from apps.purchasing.models import PurchaseOrder


def _has_rows(purchase_order, relation) -> bool:
    """Answer from a prefetch when the caller has one — the editability gate is
    asked once per row on the orders list, where three ``exists()`` per order
    would be three too many."""
    prefetched = getattr(purchase_order, "_prefetched_objects_cache", None)
    if prefetched is not None and relation in prefetched:
        return bool(prefetched[relation])
    return getattr(purchase_order, relation).exists()


def in_place_allowed(purchase_order) -> bool:
    """Whether the order can still be corrected in place.

    Receiving is not what closes an order to edits — money is. An owner who
    typed the wrong cost or miscounted a delivery keeps the right to fix it, and
    the receipt is unwound and re-recorded around the fix. The first supplier
    payment or credit ends that: from then on the order is what the money was
    settled against. A return, refund or exchange ends it too, since its lines
    hang off the very receipt an edit would replace.
    """
    return not (
        _has_rows(purchase_order, "supplier_payments")
        or _has_rows(purchase_order, "supplier_credits")
        or _has_rows(purchase_order, "adjustments")
    )


def progress_status(purchase_order, *, lines=None) -> str:
    """The delivery's progress, derived — never assigned by hand.

    ERPNext's equivalent is a ``set_status()`` per doctype called from a dozen
    places, and its standard support answer for a wrong status is "re-save the
    document". This is the one function, called from the one place.
    """
    from apps.documents.statuses import DocumentStatus

    if purchase_order.doc_status == DocumentStatus.DRAFT:
        return PurchaseOrder.Status.DRAFT
    if purchase_order.doc_status == DocumentStatus.CANCELLED:
        return PurchaseOrder.Status.CANCELLED

    if not purchase_order.receipts.exists():
        # An order received before receipts were recorded line by line (an
        # import, or a legacy one-shot receive) has nothing to derive from. Its
        # stored progress is the only evidence that the goods arrived, so it is
        # kept rather than silently downgraded to "nothing has come yet".
        if purchase_order.status in (
            PurchaseOrder.Status.RECEIVED,
            PurchaseOrder.Status.PARTIALLY_RECEIVED,
        ):
            return purchase_order.status
        return PurchaseOrder.Status.SUBMITTED

    if lines is None:
        lines = purchase_order.lines.all()
    has_outstanding = any(line.outstanding_quantity > 0 for line in lines)
    return (
        PurchaseOrder.Status.PARTIALLY_RECEIVED
        if has_outstanding
        else PurchaseOrder.Status.RECEIVED
    )


def recompute_progress(purchase_order, *, lines=None) -> None:
    status = progress_status(purchase_order, lines=lines)
    if purchase_order.status == status:
        return
    purchase_order.status = status
    purchase_order.save(update_fields=["status", "updated_at"])


def reverse(purchase_order, *, at, actor, reason="", context=None):
    """Give back everything this order put into stock.

    Two different kinds of position, and both have to go: the units that were
    only ever *expected* (an outstanding order line) and the units that actually
    arrived. The second is the one today's code cannot do — ``cancel`` refuses a
    received order outright — and it is exactly the case a shop hits when a
    delivery is recorded against the wrong order.

    Refuses when the goods are no longer on the shelf: an order whose stock has
    already been sold cannot be un-received, only returned to the supplier.
    """
    from apps.purchasing.services import (
        _receiving_snapshots,
        _release_expected_stock,
        _reverse_received_stock,
        lock_purchase_lines_for_update,
    )

    lines = lock_purchase_lines_for_update(purchase_order, prime_totals=True)
    # Runs after the order's receipts have cancelled themselves, so what they
    # gave back is already expectation again and shows here as outstanding.
    snapshots = _receiving_snapshots(purchase_order, lines=lines)
    _release_expected_stock(purchase_order, snapshots=snapshots, created_by=actor)

    legacy_delivery = any(snapshot["accepted"] > Decimal("0") for snapshot in snapshots)
    if legacy_delivery:
        # An order received before deliveries were recorded line by line — an
        # import, or a legacy one-shot receive. There is no receipt document to
        # undo, so the order takes the goods back itself.
        _assert_may_unwind_a_delivery(actor)
        _reverse_received_stock(
            purchase_order, snapshots=snapshots, created_by=actor
        )


def _assert_may_unwind_a_delivery(actor):
    """Cancelling a received order moves stock, which the cancel permission on
    its own does not grant."""
    if actor is None or not getattr(actor, "is_authenticated", False):
        return
    if actor.has_perm("purchasing.receive_purchaseorder"):
        return
    raise PermissionDenied(
        "Cancelling a received purchase order takes its delivery back off the "
        "shelf, which needs the receiving permission."
    )


__all__ = [
    "in_place_allowed",
    "progress_status",
    "recompute_progress",
    "reverse",
]


def reverse_supplier_payment(payment, *, at, actor, reason="", context=None):
    """Give back what a payment to a supplier took.

    Three different kinds of money, and only the ones that actually moved get
    an entry: credit drawn down against a supplier note goes back on the note;
    cash paid out of a till comes back into the till that is open now; a bank
    transfer moved nothing of ours to give back, and the payment simply stops
    counting towards what the shop has paid.
    """
    from apps.purchasing.models import SupplierPayment
    from apps.purchasing.services import restore_supplier_credit
    from apps.sales.models import RegisterCashMovement

    context = context or {}
    if payment.method == SupplierPayment.Method.SUPPLIER_CREDIT:
        restore_supplier_credit(supplier=payment.supplier, amount=payment.amount)
        return None

    if payment.cash_movement_id is None:
        return None

    session = context.get("register_session") or payment.register_session
    return RegisterCashMovement.objects.create(
        register_session=session,
        movement_type=RegisterCashMovement.MovementType.PAY_IN,
        amount=payment.amount,
        reason=f"إلغاء دفعة مورد: {payment.supplier.name}",
        created_by=actor,
    )


def reverse_purchase_receipt(receipt, *, at, actor, reason="", context=None):
    """Un-receive a delivery: goods off the shelf, expectation back on the order.

    Both halves matter, and the second is the one that is easy to forget. When
    goods arrive they stop being *expected* and start being *on hand*; undoing
    that has to put the expectation back, or the order is left owing units that
    nothing is waiting for. The quantities are not inferred — each receipt line
    recorded exactly how much expectation it consumed when it was written.

    Refuses when the goods are no longer there to take back: stock that has
    already been sold can only be corrected with a purchase return.
    """
    from apps.inventory.models import StockBatch, StockLedgerEntry, StockMovement
    from apps.purchasing.services import (
        build_stock_movement,
        create_stock_movements,
        lock_stock_items,
        save_stock_item_quantities_bulk,
        stock_snapshot,
        validate_purchase_stock_available,
    )

    lines = list(
        receipt.lines.select_related("purchase_line", "variant", "variant__product")
        .order_by("purchase_line__variant_id", "id")
    )
    accepted = [
        (line.purchase_line, line.accepted_quantity)
        for line in lines
        if line.accepted_quantity > Decimal("0")
    ]
    # Un-receiving takes the goods back off the shelves they landed on, which
    # is the order's own destination — not the shop's default.
    warehouse_id = receipt.purchase_order.warehouse_id
    if accepted:
        validate_purchase_stock_available(accepted, warehouse=warehouse_id)

    variants = [line.purchase_line.variant for line in lines]
    if not variants:
        return None
    stock_items = lock_stock_items(variants, warehouse=warehouse_id)
    movements = []
    touched = {}
    for line in lines:
        purchase_line = line.purchase_line
        stock_item = stock_items[purchase_line.variant_id]
        before = stock_snapshot(stock_item)
        changed = False
        if line.accepted_quantity > Decimal("0"):
            stock_item.quantity_on_hand -= purchase_line.to_base_quantity(
                line.accepted_quantity
            )
            changed = True
            movements.append(
                build_stock_movement(
                    variant=purchase_line.variant,
                    stock_item=stock_item,
                    movement_type=StockMovement.Type.DECREASE,
                    quantity=purchase_line.to_base_quantity(line.accepted_quantity),
                    note=f"إلغاء استلام {receipt.purchase_order.order_number}",
                    created_by=actor,
                    before=before,
                )
            )
        if line.expected_reduction_quantity > Decimal("0"):
            # What arriving took off the expectation goes back on it: those
            # units are owed by the supplier again.
            stock_item.quantity_expected += purchase_line.to_base_quantity(
                line.expected_reduction_quantity
            )
            changed = True
        if changed:
            touched[stock_item.pk] = stock_item

    if touched:
        save_stock_item_quantities_bulk(touched.values())
    if movements:
        create_stock_movements(
            movements,
            voucher_type=StockLedgerEntry.VoucherType.PURCHASE_RETURN,
            voucher_id=receipt.purchase_order_id,
        )
    # An expiry batch is a claim that this stock is on the shelf. It is not.
    StockBatch.objects.filter(source_receipt_line__receipt=receipt).delete()
    return None
