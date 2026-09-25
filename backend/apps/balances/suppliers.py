"""Opening balances and adjustments on a supplier's account.

* **We owe them** — an open item of its own. A supplier payment settles it by
  naming it (``SupplierPayment.balance_entry``), exactly as one names a
  purchase order, so the entry always knows how much of it is left.
* **They owe us** — a ``SupplierCredit``, the note the shop already spends
  against purchase orders. Reusing it is the point: the purchase-order payment
  dialog, the available-credit figure, the balance sheet and the supplier's
  own balance all read supplier credit already, and none of them had to learn
  a new source.

Neither is applied automatically. The supplier side has always shown what the
shop owes and what it is owed side by side, with the credit spent when someone
chooses to — and an account payment (:func:`record_supplier_account_payment`)
can now spend it against an opening balance as well as against an order.
"""

from __future__ import annotations

from decimal import Decimal

from django.db import transaction
from django.db.models import DecimalField, OuterRef, Subquery, Sum, Value
from django.db.models.functions import Coalesce
from rest_framework import serializers

from apps.analytics.models import AnalyticsEvent
from apps.analytics.services import record_domain_event

from . import common
from .models import SupplierBalanceEntry

ZERO = Decimal("0.00")
MONEY_FIELD = DecimalField(max_digits=12, decimal_places=2)
ENTITY = "supplier_balance_entry"


# ---------------------------------------------------------------------------
# Writing an entry
# ---------------------------------------------------------------------------


@transaction.atomic
def create_supplier_entry(
    *,
    supplier,
    kind,
    direction,
    amount,
    effective_date=None,
    note="",
    actor=None,
):
    """Record an opening balance or an adjustment on ``supplier``'s account."""
    from apps.purchasing.models import Supplier, SupplierCredit

    common.refuse_written_refund(kind)
    cleaned = common.clean_entry_input(
        kind=kind,
        direction=direction,
        amount=amount,
        effective_date=effective_date,
        note=note,
    )
    supplier = Supplier.objects.select_for_update().get(pk=supplier.pk)
    if cleaned.kind == common.Kind.OPENING:
        common.refuse_second_opening(
            supplier.balance_entries.live().filter(kind=common.Kind.OPENING),
            party_label="supplier",
        )
    common.assert_entry_period_open(
        cleaned.effective_date, user=actor, entity_type=ENTITY
    )

    entry = SupplierBalanceEntry.objects.create(
        supplier=supplier,
        kind=cleaned.kind,
        direction=cleaned.direction,
        amount=cleaned.amount,
        effective_date=cleaned.effective_date,
        note=cleaned.note,
        created_by=actor,
    )
    if cleaned.direction == common.Direction.THEY_OWE_US:
        credit = SupplierCredit.objects.create(
            supplier=supplier,
            balance_entry=entry,
            amount=entry.amount,
            remaining_amount=entry.amount,
            reason=entry.note or entry.number,
        )
        stamped = common.effective_datetime(entry.effective_date)
        if stamped != credit.created_at:
            # The balance sheet rebuilds supplier credit as of a date from the
            # notes issued by then, so the note carries the entry's own date.
            SupplierCredit.objects.filter(pk=credit.pk).update(created_at=stamped)
    common.record_issued(entry, actor=actor)
    record_domain_event(
        name="balances.supplier_entry.created",
        event_type=AnalyticsEvent.EventType.AUDIT,
        user=actor,
        entity_type=ENTITY,
        entity_id=entry.pk,
        attributes={
            "number": entry.number,
            "supplier_id": supplier.pk,
            "kind": entry.kind,
            "direction": entry.direction,
            "effective_date": entry.effective_date.isoformat(),
        },
        metrics={"amount": float(entry.amount)},
    )
    return entry


@transaction.atomic
def receive_supplier_refund(*, supplier, amount, note="", actor=None):
    """Take in, in cash, money a supplier owed the shop.

    The mirror of paying them: what the shop owes on the account goes up by
    ``amount`` — the supplier has paid it back — and is settled at once from
    their credit note, by the same supplier-credit payment an order is settled
    with; the cash comes into the actor's own drawer as a pay-in, which the
    drawer count, the Z-report and the money position all read.
    """
    from apps.purchasing.models import Supplier, SupplierPayment
    from apps.purchasing.services import (
        create_supplier_payment,
        supplier_available_credit,
    )

    cleaned = common.clean_entry_input(
        kind=common.Kind.REFUND,
        direction=common.Direction.WE_OWE_THEM,
        amount=amount,
        note=note,
    )
    session = common.open_drawer_for(actor)
    supplier = Supplier.objects.select_for_update().get(pk=supplier.pk)
    available = supplier_available_credit(supplier)
    if cleaned.amount > available:
        raise serializers.ValidationError(
            {
                "amount": (
                    f"This supplier owes the shop {available:.2f}; it cannot "
                    f"take in {cleaned.amount:.2f}."
                ),
                "code": "refund_exceeds_credit",
                "available": f"{available:.2f}",
            }
        )

    entry = SupplierBalanceEntry(
        supplier=supplier,
        kind=common.Kind.REFUND,
        direction=common.Direction.WE_OWE_THEM,
        amount=cleaned.amount,
        effective_date=cleaned.effective_date,
        note=cleaned.note,
        created_by=actor,
    )
    # Numbered before it is written, so the drawer movement can name it and the
    # entry is issued once, link and all — it is frozen from the moment it
    # exists.
    common.allocate_number(entry)
    entry.cash_movement = common.drawer_movement(
        session,
        outgoing=False,
        amount=entry.amount,
        reason=f"مبلغ مسترد من المورد {supplier.name} ({entry.number})",
        actor=actor,
    )
    entry.save()
    create_supplier_payment(
        created_by=actor,
        supplier=supplier,
        balance_entry=entry,
        amount=entry.amount,
        method=SupplierPayment.Method.SUPPLIER_CREDIT,
        notes=entry.note or entry.number,
    )
    common.record_issued(entry, actor=actor)
    record_domain_event(
        name="balances.supplier_refund.received",
        event_type=AnalyticsEvent.EventType.AUDIT,
        user=actor,
        entity_type=ENTITY,
        entity_id=entry.pk,
        attributes={
            "number": entry.number,
            "supplier_id": supplier.pk,
            "register_session_id": session.pk,
        },
        metrics={"amount": float(entry.amount)},
    )
    return entry


def reverse_entry(entry, *, at, actor, reason="", context=None):
    """What cancelling an entry gives back — the registry's ``reverse`` hook.

    A payable entry that anything has been paid against is refused by the
    registration's ``blocks_cancel`` before this runs. A credit entry is
    refused here once any of its note has been spent: the note's draw-down is
    not itemised (``purchasing.services.consume_supplier_credit``), so an
    untouched note is the only one whose removal provably undoes nothing else.
    """
    from apps.purchasing.models import SupplierCredit

    common.refuse_refund_cancel(entry)
    if entry.direction == common.Direction.WE_OWE_THEM:
        return None
    credit = (
        SupplierCredit.objects.select_for_update().filter(balance_entry=entry).first()
    )
    if credit is None:
        return None
    if credit.remaining_amount < credit.amount:
        raise common.blocked(
            entry, label="رصيد مستخدم في دفعات للمورد", rows=[credit]
        )
    # Removed rather than marked used: a used note is still counted as issued by
    # the as-of rebuilds, and one with nothing drawn on it is refillable by a
    # cancelled credit payment elsewhere. The entry keeps the record.
    credit.delete()
    return None


# ---------------------------------------------------------------------------
# What is owed on entries
# ---------------------------------------------------------------------------


def _live_payments_total():
    """What has been paid against one payable entry: every live payment naming
    it, credit applied as much as cash — the same rule an order's balance uses."""
    from apps.purchasing.models import SupplierPayment

    return (
        SupplierPayment.objects.live()
        .filter(balance_entry_id=OuterRef("pk"))
        .order_by()
        .values("balance_entry_id")
        .annotate(total=Sum("amount"))
        .values("total")[:1]
    )


def payable_entries(queryset=None):
    """Live we-owe-them entries, annotated with what has been paid on each."""
    queryset = queryset if queryset is not None else SupplierBalanceEntry.objects.all()
    return (
        queryset.live()
        .filter(direction=common.Direction.WE_OWE_THEM)
        .annotate(
            paid_total=Coalesce(
                Subquery(_live_payments_total(), output_field=MONEY_FIELD),
                Value(ZERO),
            )
        )
    )


def payable_entries_outstanding(supplier_ids=None):
    """What the shop still owes on each supplier's account entries, in one query.

    Each entry floored at zero on its own, the way each purchase order is: an
    overpaid entry does not quietly pay another one down. ``None`` asks for
    every supplier at once — the dashboard's total of what is due.
    """
    queryset = SupplierBalanceEntry.objects.all()
    if supplier_ids is not None:
        supplier_ids = [pk for pk in supplier_ids if pk is not None]
        if not supplier_ids:
            return {}
        queryset = queryset.filter(supplier_id__in=supplier_ids)
    owed = {}
    rows = payable_entries(queryset).values_list(
        "supplier_id", "amount", "paid_total"
    )
    for supplier_id, amount, paid in rows:
        left = max(amount - (paid or ZERO), ZERO)
        if left > 0:
            owed[supplier_id] = owed.get(supplier_id, ZERO) + left
    return owed


def entry_outstanding(entry) -> Decimal:
    """What is left to pay on one payable entry (zero for anything else)."""
    if entry.direction != common.Direction.WE_OWE_THEM or not entry.is_submitted:
        return ZERO
    paid = (
        entry.payments.live().aggregate(total=Sum("amount"))["total"] or ZERO
    )
    return max(entry.amount - paid, ZERO).quantize(ZERO)


def entries_with_settlement(queryset):
    """Annotate what each entry has settled: paid against a payable entry, or
    drawn from a credit entry's note."""
    from apps.purchasing.models import SupplierCredit

    drawn = SupplierCredit.objects.filter(balance_entry_id=OuterRef("pk")).values(
        "remaining_amount"
    )[:1]
    return queryset.select_related("created_by", "cancelled_by").annotate(
        paid_total=Coalesce(
            Subquery(_live_payments_total(), output_field=MONEY_FIELD), Value(ZERO)
        ),
        credit_remaining=Subquery(drawn, output_field=MONEY_FIELD),
    )


def settled_amount(entry) -> Decimal:
    if entry.direction == common.Direction.WE_OWE_THEM:
        paid = getattr(entry, "paid_total", None)
        if paid is None:
            return (entry.amount - entry_outstanding(entry)).quantize(ZERO)
        return min(max(Decimal(paid), ZERO), entry.amount).quantize(ZERO)
    if not entry.is_submitted:
        return ZERO
    remaining = getattr(entry, "credit_remaining", None)
    if remaining is None:
        credit = getattr(entry, "supplier_credit", None)
        remaining = credit.remaining_amount if credit is not None else entry.amount
    return max(entry.amount - Decimal(remaining), ZERO).quantize(ZERO)


def has_live_opening(supplier) -> bool:
    return (
        SupplierBalanceEntry.objects.live()
        .filter(supplier_id=supplier.pk, kind=common.Kind.OPENING)
        .exists()
    )


# ---------------------------------------------------------------------------
# Paying a supplier on account
# ---------------------------------------------------------------------------


def _open_items(supplier):
    """Everything the shop owes this supplier, oldest first: the purchase
    orders ``payable_balance`` counts, and the payable entries.

    Returned as ``(date, kind, object, owed)``. Orders and entries are sorted
    together by the date each became owed, so an opening balance is settled
    before the orders that came after it.
    """
    from apps.purchasing.models import PurchaseOrder

    items = []
    orders = (
        PurchaseOrder.objects.filter(supplier=supplier)
        .exclude(status=PurchaseOrder.Status.CANCELLED)
        .select_for_update()
        .order_by("created_at", "id")
    )
    for order in orders.prefetch_related("supplier_payments", "supplier_credits"):
        owed = order.balance_due
        if owed > 0:
            items.append((order.created_at, 0, order, owed))
    entries = (
        SupplierBalanceEntry.objects.filter(supplier=supplier)
        .live()
        .filter(direction=common.Direction.WE_OWE_THEM)
        .select_for_update()
        .order_by("effective_date", "id")
    )
    for entry in entries:
        owed = entry_outstanding(entry)
        if owed > 0:
            items.append((common.effective_datetime(entry.effective_date), 1, entry, owed))
    items.sort(key=lambda item: (item[0], item[1], item[2].pk))
    return items


@transaction.atomic
def record_supplier_account_payment(
    supplier,
    *,
    method,
    amount,
    reference="",
    notes="",
    paid_at=None,
    money_account=None,
    created_by=None,
):
    """Pay a supplier against their account rather than one document.

    The money is split across what the shop owes them, oldest first — orders
    and account entries alike — and written as one ordinary supplier payment per
    document it settles, so every order and every entry still knows exactly
    how much of it is left. ``SUPPLIER_CREDIT`` spends the supplier's credit
    the same way.

    Payments made on account before this existed (naming no document at all)
    are read the way the payables report reads them: as having already paid
    the oldest debts. This payment starts where they stopped.
    """
    from apps.purchasing.models import Supplier, SupplierPayment
    from apps.purchasing.services import (
        create_supplier_payment,
        supplier_available_credit,
    )

    supplier = Supplier.objects.select_for_update().get(pk=supplier.pk)
    try:
        amount = Decimal(str(amount)).quantize(Decimal("0.01"))
    except Exception as exc:  # pragma: no cover - the serializer validates first
        raise serializers.ValidationError({"amount": "Enter a valid amount."}) from exc
    if amount <= 0:
        raise serializers.ValidationError({"amount": "Payment amount must be positive."})
    if method == SupplierPayment.Method.SUPPLIER_CREDIT:
        if amount > supplier_available_credit(supplier):
            raise serializers.ValidationError(
                {"amount": "Payment exceeds available supplier credit."}
            )

    items = _open_items(supplier)
    unallocated = (
        supplier.payments.live()
        .filter(purchase_order__isnull=True, balance_entry__isnull=True)
        .exclude(method=SupplierPayment.Method.SUPPLIER_CREDIT)
        .aggregate(total=Sum("amount"))["total"]
        or ZERO
    )
    open_items = []
    for _when, _kind, document, owed in items:
        covered = min(unallocated, owed)
        unallocated -= covered
        owed -= covered
        if owed > 0:
            open_items.append((document, owed))

    total_owed = sum((owed for _document, owed in open_items), ZERO)
    if amount > total_owed:
        raise serializers.ValidationError(
            {"amount": "Payment exceeds what the shop owes this supplier."}
        )

    remaining = amount
    payments = []
    for document, owed in open_items:
        if remaining <= 0:
            break
        portion = min(owed, remaining)
        fields = {
            "supplier": supplier,
            "amount": portion,
            "method": method,
            "reference": reference,
            "notes": notes,
        }
        if paid_at is not None:
            fields["paid_at"] = paid_at
        if money_account is not None:
            fields["money_account"] = money_account
        if isinstance(document, SupplierBalanceEntry):
            fields["balance_entry"] = document
        else:
            fields["purchase_order"] = document
        payments.append(create_supplier_payment(created_by=created_by, **fields))
        remaining -= portion

    record_domain_event(
        name="purchasing.supplier_account_payment.recorded",
        event_type=AnalyticsEvent.EventType.AUDIT,
        user=created_by,
        entity_type="supplier",
        entity_id=supplier.pk,
        attributes={
            "method": method,
            "payment_ids": [payment.pk for payment in payments],
        },
        metrics={"amount": float(amount)},
    )
    return payments


__all__ = [
    "create_supplier_entry",
    "receive_supplier_refund",
    "entries_with_settlement",
    "entry_outstanding",
    "has_live_opening",
    "payable_entries",
    "payable_entries_outstanding",
    "record_supplier_account_payment",
    "reverse_entry",
    "settled_amount",
]
