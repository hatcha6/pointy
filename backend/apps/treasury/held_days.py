"""Held card takings, one processor day at a time.

What the settlement screen lists and the overdue alert reads: every day that
still has card takings the processor has not paid in, with the day they should
have landed by. Days are the processor's (``settlement_calendar``), not the
till's shift and not the UTC report day — the deposit covers exactly one of
those.

One grouping rule beyond the calendar: a cancelled card payment and its counter
row are kept on the ORIGINAL payment's day while both are still held. A sale
voided on the terminal is never paid by the processor, so its day's deposit is
short of it; with the counter row on that day too, the day nets to what really
arrives. Once the original has been paid out, a later cancellation is money the
processor takes back from a later deposit, and stays on its own day.
"""

from __future__ import annotations

from dataclasses import dataclass
from datetime import date, datetime, timedelta
from decimal import Decimal

from apps.core.timeutils import business_local_date

from . import clearing
from .settlement_calendar import (
    bank_closed_dates,
    expected_settlement_date,
    parse_weekdays,
    processor_day,
)
from .settlement_match import PendingDay

MONEY_PLACES = Decimal("0.01")
ZERO = Decimal("0.00")
# Rows listed for one day. A day of a busy shop is a few hundred card sales;
# the list says when it was cut.
DAY_PAYMENT_LIMIT = 500


@dataclass(frozen=True)
class HeldPayment:
    id: int
    day: date
    paid_at: datetime
    amount: Decimal
    commission: Decimal
    reverses_id: int | None

    @property
    def net(self) -> Decimal:
        return (self.amount - self.commission).quantize(MONEY_PLACES)


def held_rows(account):
    """Every payment ``account`` still holds, each with its processor day."""
    rows = list(
        clearing.pending_payments(account)
        .order_by("paid_at", "id")
        .values_list("id", "paid_at", "amount", "commission_amount", "reverses_id")
    )
    days = {
        pk: processor_day(paid_at, cutoff=account.settlement_cutoff)
        for pk, paid_at, _amount, _commission, _reverses in rows
    }
    held = []
    for pk, paid_at, amount, commission, reverses_id in rows:
        # A counter row joins the day of the payment it gives back, while that
        # payment is itself still held.
        day = days.get(reverses_id, days[pk]) if reverses_id else days[pk]
        held.append(
            HeldPayment(
                id=pk,
                day=day,
                paid_at=paid_at,
                amount=amount or ZERO,
                commission=commission or ZERO,
                reverses_id=reverses_id,
            )
        )
    return held


def _schedule(account):
    return {
        "settlement_weekdays": parse_weekdays(account.settlement_weekdays),
        "lag_days": account.settlement_lag_days,
    }


def expected_dates(account, days):
    """The day each processor day's money should land, for many days at once."""
    if not days:
        return {}
    schedule = _schedule(account)
    first, last = min(days), max(days)
    # Room for the lag, a weekend and a long Eid closure after the last day.
    closed = bank_closed_dates(first, last + timedelta(days=account.settlement_lag_days + 21))
    return {
        day: expected_settlement_date(day, closed_dates=closed, **schedule)
        for day in days
    }


def pending_days(account, *, rows=None):
    """The held days, oldest first, as ``settlement_match.PendingDay``."""
    rows = held_rows(account) if rows is None else rows
    totals = {}
    for row in rows:
        gross, commission, count = totals.get(row.day, (ZERO, ZERO, 0))
        totals[row.day] = (gross + row.amount, commission + row.commission, count + 1)
    expected = expected_dates(account, list(totals))
    return [
        PendingDay(
            day=day,
            expected_on=expected[day],
            gross=gross.quantize(MONEY_PLACES),
            commission=commission.quantize(MONEY_PLACES),
            count=count,
        )
        for day, (gross, commission, count) in sorted(totals.items())
    ]


def overdue_days(account, *, today=None):
    """Held days whose money should already have reached the bank.

    Late once the expected day has passed without a deposit — not on the
    expected day itself, when the money may simply not have shown yet.
    """
    today = today or business_local_date()
    return [day for day in pending_days(account) if day.expected_on < today]


def held_summary(account, *, today=None):
    """How many held days are waiting, and how much of it is late."""
    today = today or business_local_date()
    days = pending_days(account)
    overdue = [day for day in days if day.expected_on < today]
    return {
        "days": len(days),
        "payments": sum(day.count for day in days),
        "oldest_day": days[0].day if days else None,
        "next_expected_on": min((day.expected_on for day in days), default=None),
        "overdue_days": len(overdue),
        "overdue_amount": sum((day.net for day in overdue), ZERO),
    }


def day_payments(account, day, *, rows=None):
    """The held payments of one processor day, with what the slip said."""
    from apps.payments.models import Payment

    rows = held_rows(account) if rows is None else rows
    chosen = [row for row in rows if row.day == day]
    by_id = {row.id: row for row in chosen}
    payments = (
        Payment.objects.filter(pk__in=list(by_id)[: DAY_PAYMENT_LIMIT + 1])
        .select_related("order")
        .order_by("paid_at", "id")
    )
    listed = []
    for payment in payments[:DAY_PAYMENT_LIMIT]:
        receipt = payment.card_receipt_data or {}
        listed.append(
            {
                "id": payment.pk,
                "order_id": payment.order_id,
                "invoice_number": getattr(payment.order, "invoice_number", "") or "",
                "paid_at": payment.paid_at,
                "amount": payment.amount,
                "commission": payment.commission_amount,
                "net": by_id[payment.pk].net,
                "reverses_id": payment.reverses_id,
                "terminal_id": str(receipt.get("terminal_id") or ""),
                "masked_pan": str(receipt.get("masked_pan") or ""),
                "batch": str(receipt.get("batch") or ""),
                "rrn": str(receipt.get("rrn") or ""),
            }
        )
    return {"payments": listed, "truncated": len(chosen) > DAY_PAYMENT_LIMIT}


__all__ = [
    "DAY_PAYMENT_LIMIT",
    "HeldPayment",
    "day_payments",
    "expected_dates",
    "held_rows",
    "overdue_days",
    "pending_days",
]
