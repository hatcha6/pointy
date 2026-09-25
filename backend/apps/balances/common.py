"""The rules both sides of the ledger share: what a valid entry is, when it may
be dated, and what it leaves behind in the trail.

Kept apart from the customer and supplier services so the two cannot quietly
disagree about, say, whether an adjustment needs a reason.
"""

from __future__ import annotations

from dataclasses import dataclass
from datetime import date, datetime
from decimal import Decimal, InvalidOperation

from django.utils import timezone
from rest_framework import serializers

from apps.core.money_dates import day_range_start
from apps.core.period_lock import assert_period_open
from apps.core.timeutils import business_local_date
from apps.documents import trail
from apps.documents.errors import DocumentBlocked
from apps.documents.models import DocumentEvent

from .models import MONEY, BalanceEntry

#: The largest figure every column an entry becomes part of can hold — the
#: carrier order's total, a supplier credit, a supplier payment are all ten
#: digits with two decimals.
MAX_AMOUNT = Decimal("99999999.99")

Kind = BalanceEntry.Kind
Direction = BalanceEntry.Direction


@dataclass(frozen=True)
class EntryInput:
    kind: str
    direction: str
    amount: Decimal
    effective_date: date
    note: str


def clean_entry_input(*, kind, direction, amount, effective_date=None, note=""):
    """Validate what a person typed into one entry, and normalise it.

    Raised as field errors, so a form can put each one under the field it is
    about.
    """
    errors = {}
    if kind not in Kind.values:
        errors["kind"] = "Choose an opening balance or an adjustment."
    if direction not in Direction.values:
        errors["direction"] = "Say whether they owe the shop or the shop owes them."

    try:
        amount = Decimal(str(amount)).quantize(MONEY)
    except (InvalidOperation, TypeError, ValueError):
        amount = None
    if amount is None or amount <= 0:
        errors["amount"] = "The amount must be more than zero."
    elif amount > MAX_AMOUNT:
        errors["amount"] = "The amount is too large."

    today = latest_allowed_date()
    if effective_date is None:
        effective_date = business_local_date()
    elif isinstance(effective_date, datetime):
        effective_date = effective_date.date()
    if isinstance(effective_date, date) and effective_date > today:
        # A balance "from next week" is a promise, not a balance — and a
        # future-dated debt would sit in every aging report as not yet owed
        # while every screen already counted it.
        errors["effective_date"] = "A balance cannot start in the future."

    note = (note or "").strip()
    if kind == Kind.ADJUSTMENT and not note:
        # The one question a customer holding the statement will ask about a
        # line that is not an invoice is "what is this?". Nobody can answer it
        # later if nobody wrote it down now.
        errors["note"] = "Say what the adjustment is for."

    if errors:
        raise serializers.ValidationError(errors)
    return EntryInput(
        kind=kind,
        direction=direction,
        amount=amount,
        effective_date=effective_date,
        note=note,
    )


def latest_allowed_date() -> date:
    """Today, on whichever clock is further ahead.

    Reports and the period lock date money on the app-wide clock
    (``apps.core.money_dates``) while the owner's date picker shows the shop's
    own day. Between midnight in Tripoli and midnight UTC the two disagree, and
    "today" as the owner reads it must not be refused as a date in the future.
    """
    return max(business_local_date(), timezone.localdate())


def effective_datetime(effective_date: date) -> datetime:
    """The instant an entry's balance is stamped at, for the rows that carry a
    timestamp rather than a date (a carrier order, a supplier credit).

    Today's entry happens now. A backdated one happens at the very start of its
    day, so an opening balance sits ahead of everything else that day — the
    oldest debt, which is what a collection settles first.
    """
    if effective_date >= timezone.localdate():
        return timezone.now()
    return day_range_start(effective_date)


def assert_entry_period_open(effective_date, *, user, entity_type):
    assert_period_open(
        effective_date,
        user=user,
        entity_type=entity_type,
        action=f"{entity_type}.create",
    )


def refuse_second_opening(existing_openings, *, party_label):
    """An account starts once.

    A second opening balance on the same account is almost always the first
    one typed again, and both would count. The honest ways to change an opening
    balance are to cancel it while nothing rests on it, or to post an adjustment
    — both of which leave a record of the change.
    """
    number = existing_openings.values_list("number", flat=True).first()
    if number is not None:
        raise serializers.ValidationError(
            {
                "kind": (
                    f"This {party_label} already has an opening balance ({number}). "
                    "Cancel it, or record an adjustment instead."
                ),
                "code": "opening_balance_exists",
            }
        )


def record_issued(entry, *, actor):
    """The entry's first line in the document trail.

    A born-submitted document never passes through ``submit()``, which is what
    writes that line for everything else, so without this the trail of an
    opening balance would begin at its cancellation.
    """
    trail.record(
        entry,
        DocumentEvent.Action.SUBMITTED,
        actor=actor,
        details={
            "kind": entry.kind,
            "direction": entry.direction,
            "amount": str(entry.amount),
            "effective_date": entry.effective_date.isoformat(),
        },
    )


def statement_kind(kind):
    """What a statement calls an entry: an opening balance, an adjustment, or
    a refund — cash handed over against a balance. Which way it runs is said
    by its debit or credit column. One name for both parties' statements."""
    return {
        Kind.OPENING: "opening_balance",
        Kind.REFUND: "balance_refund",
    }.get(kind, "balance_adjustment")


def allocate_number(entry):
    """Give an entry its number before it is written.

    For the entries whose number another row has to carry — a carrier order,
    a drawer movement's reason — and which, being born submitted, cannot be
    touched after their first write. ``BalanceEntry.save`` numbers every other
    entry the same way, from the same gapless series.
    """
    from apps.documents.numbering import PARTY_BALANCE_SERIES, next_document_number

    issued_at = timezone.now()
    entry.number = (
        f"B{issued_at:%Y%m%d}{next_document_number(PARTY_BALANCE_SERIES):06d}"
    )


def refuse_written_refund(kind):
    """A refund moves money, so it is written only by the refund services,
    which move it. Through the ordinary entry form it would be a figure that
    claims cash changed hands while no drawer ever saw it."""
    if kind == Kind.REFUND:
        raise serializers.ValidationError(
            {"kind": "A refund is recorded with the cash it pays or receives."}
        )


def refuse_refund_cancel(entry):
    """Money that moved stays moved. A refund in error is put right the way
    a payment is — by recording the money going back the other way."""
    if entry.kind == Kind.REFUND:
        raise serializers.ValidationError(
            {
                "code": "refund_is_final",
                "detail": (
                    "This refund handed over cash; it cannot be cancelled. "
                    "Record an adjustment and the cash coming back instead."
                ),
            }
        )


def open_drawer_for(actor):
    """The actor's own open register session — where a refund's cash moves.

    Its own, never someone else's: the drawer a refund leaves is the drawer
    whose count will be short by it, so it has to be the one in front of the
    person handing the money over.
    """
    from apps.sales.models import RegisterSession

    session = RegisterSession.open_for(actor)
    if session is None:
        raise serializers.ValidationError(
            {
                "code": "register_session_required",
                "detail": (
                    "Cash moves through a drawer. Open a register session "
                    "before recording a refund."
                ),
            }
        )
    return session


def drawer_movement(session, *, outgoing, amount, reason, actor):
    """The refund's cash, as the drawer records every other pay-in and
    pay-out — so the count, the Z-report and the money position see it
    without learning anything new."""
    from apps.sales.models import RegisterCashMovement

    return RegisterCashMovement.objects.create(
        register_session=session,
        movement_type=(
            RegisterCashMovement.MovementType.PAY_OUT
            if outgoing
            else RegisterCashMovement.MovementType.PAY_IN
        ),
        amount=amount,
        reason=reason,
        created_by=actor,
    )


def blocked(entry, *, label, rows):
    """Refuse a cancellation in the same shape the primitive refuses one, so
    the client shows it the same way whichever check caught it."""
    rows = list(rows)
    return DocumentBlocked(
        number=entry.number,
        blockers=[
            {
                "accessor": "settlements",
                "label": label,
                "count": len(rows),
                "ids": [row.pk for row in rows[:5]],
            }
        ],
    )


__all__ = [
    "Direction",
    "allocate_number",
    "EntryInput",
    "Kind",
    "MAX_AMOUNT",
    "assert_entry_period_open",
    "blocked",
    "clean_entry_input",
    "drawer_movement",
    "effective_datetime",
    "latest_allowed_date",
    "open_drawer_for",
    "record_issued",
    "refuse_refund_cancel",
    "refuse_second_opening",
    "refuse_written_refund",
    "statement_kind",
]
