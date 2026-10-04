"""Recording — and undoing — the processor's deposit of held card takings.

``record_settlement`` is the one writer of ``CardSettlement``. It is given the
amount that reached the bank and the processor days (or, rarely, the individual
payments) the deposit paid for, and stores the deposit against exactly those
payments. Everything it checks is there to keep the clearing account a balance
that can always be taken apart again:

* only payments the account is still holding can be paid out, and only once
  (the partial unique index on live lines backs the check up under a race);
* a deposit cannot pay for takings from after the day it landed;
* the period lock applies, because a settlement moves a month's bank balance;
* and if the held takings changed while the owner was looking — another card
  sale on a day they ticked, a settlement recorded from a second device — the
  figure they confirmed is no longer the figure that would be stored, so it is
  refused rather than silently stored differently.
"""

from __future__ import annotations

from decimal import Decimal

from django.db import transaction

from apps.core.money_dates import day_range_end
from apps.core.period_lock import assert_period_open
from apps.core.timeutils import business_local_date

from . import held_days
from .models import CardSettlement, CardSettlementLine, MoneyAccount

MONEY_PLACES = Decimal("0.01")
ZERO = Decimal("0.00")


class SettlementError(ValueError):
    """A settlement that cannot be recorded, with an Arabic reason and a code."""

    def __init__(self, message, *, code):
        super().__init__(message)
        self.code = code


def _money(value) -> Decimal:
    return Decimal(value).quantize(MONEY_PLACES)


def _choose(rows, *, days, payment_ids, exclude_payment_ids):
    if payment_ids:
        wanted = {int(pk) for pk in payment_ids}
        chosen = [row for row in rows if row.id in wanted]
        if len(chosen) != len(wanted):
            raise SettlementError(
                "بعض المبالغ المختارة لم تعد قيد التسوية. حدّث الشاشة وأعد الاختيار.",
                code="payments_not_held",
            )
        return chosen
    wanted_days = set(days or ())
    excluded = {int(pk) for pk in exclude_payment_ids or ()}
    return [row for row in rows if row.day in wanted_days and row.id not in excluded]


@transaction.atomic
def record_settlement(
    *,
    clearing_account,
    settled_on,
    amount_received,
    days=None,
    payment_ids=None,
    exclude_payment_ids=None,
    expected_amount=None,
    reference="",
    note="",
    actor=None,
):
    """Store a deposit of ``amount_received`` against the payments it paid."""
    # Serialises settlements on one account: the held set read below is the
    # set the lines are written against.
    account = MoneyAccount.objects.select_for_update().get(pk=clearing_account.pk)
    if not account.is_clearing or account.settles_into_id is None:
        raise SettlementError(
            "هذا الحساب لا يحتجز مبالغ البطاقات.", code="not_a_clearing_account"
        )
    if settled_on > business_local_date():
        raise SettlementError(
            "لا يمكن تسجيل وصول تحويل بتاريخ لم يأتِ بعد.", code="settled_in_future"
        )
    assert_period_open(
        settled_on,
        user=actor,
        entity_type="card_settlement",
        entity_id=None,
        action="treasury.card_settlement",
    )

    rows = held_days.held_rows(account)
    chosen = _choose(
        rows,
        days=days,
        payment_ids=payment_ids,
        exclude_payment_ids=exclude_payment_ids,
    )
    if not chosen:
        raise SettlementError(
            "اختر يومًا واحدًا على الأقل من المبالغ قيد التسوية.",
            code="nothing_selected",
        )
    deposit_end = day_range_end(settled_on)
    if any(row.day > settled_on or row.paid_at >= deposit_end for row in chosen):
        raise SettlementError(
            "لا يمكن أن يغطي التحويل مبيعات بعد تاريخ وصوله.",
            code="takings_after_deposit",
        )

    gross = _money(sum((row.amount for row in chosen), ZERO))
    commission = _money(sum((row.commission for row in chosen), ZERO))
    expected = _money(gross - commission)
    if expected_amount is not None and _money(expected_amount) != expected:
        raise SettlementError(
            "تغيّرت المبالغ قيد التسوية منذ فتح الشاشة. حدّثها وأعد التأكيد.",
            code="held_amount_changed",
        )
    received = _money(amount_received)

    settlement = CardSettlement.objects.create(
        clearing_account=account,
        bank_account_id=account.settles_into_id,
        settled_on=settled_on,
        amount_received=received,
        expected_amount=expected,
        gross_amount=gross,
        commission_amount=commission,
        difference=_money(received - expected),
        payment_count=len(chosen),
        first_day=min(row.day for row in chosen),
        last_day=max(row.day for row in chosen),
        reference=(reference or "").strip()[:128],
        note=(note or "").strip(),
        created_by=actor if getattr(actor, "is_authenticated", False) else None,
    )
    CardSettlementLine.objects.bulk_create(
        [CardSettlementLine(settlement=settlement, payment_id=row.id) for row in chosen]
    )
    return settlement


def cancel_settlement(settlement, *, reason="", request=None, actor=None):
    """Undo a settlement: the bank loses the deposit, the payments are held again."""
    from apps.documents import services as document_services

    return document_services.cancel(
        settlement, reason=reason, request=request, actor=actor
    )


def settlement_fee_total(start, end) -> Decimal:
    """What card processors kept beyond the fee estimated at each sale.

    Over the deposits that landed between two days (inclusive): positive when a
    processor kept more than the estimate — an extra cost to the shop —
    negative when it kept less. The commission charged at each sale is an
    estimate; this is its correction, known only once the deposit is in.

    The one definition the profit report, the dashboard and the expense ledger
    read, so the three cannot disagree about it.
    """
    from django.db.models import Sum

    from apps.core.money_dates import money_period

    total = money_period(CardSettlement.objects.live(), start, end).aggregate(
        total=Sum("difference")
    )["total"]
    return (ZERO - Decimal(total or 0)).quantize(MONEY_PLACES)


def settlement_payments(settlement):
    """The payments a settlement paid for, oldest first."""
    from apps.payments.models import Payment

    return (
        Payment.objects.filter(settlement_lines__settlement=settlement)
        .select_related("order")
        .order_by("paid_at", "id")
    )


__all__ = [
    "SettlementError",
    "cancel_settlement",
    "record_settlement",
    "settlement_fee_total",
    "settlement_payments",
]
