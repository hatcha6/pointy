"""كشف حساب صاحب الأمانة — one consignor's whole page, across every agreement.

The agreement's own ``statement`` is one signed page; a consignor who brought
eight handbags in March and a watch in May has two, and when they ask *"what do
you owe me?"* the honest answer covers both. This is that answer: what is held
for them, what sold and waits for them, what was paid, and what went back.

Every money figure is read from :mod:`apps.inventory.consignment` — the one
module that knows how a payout is computed — and none is stored.

**The period** narrows the *history*, never the open items. Articles still on
the shelf and payouts still owed are listed whatever the dates, because a
statement that hid a debt for being older than the window would be the wrong
page to hand somebody across a counter. Paid, returned and lost articles are
listed when their closing date falls in the window; the period figures (sold,
paid out, the shop's commission) are the window's.
"""

from __future__ import annotations

from decimal import Decimal

from django.db.models import (
    Case,
    CharField,
    Count,
    DateTimeField,
    F,
    IntegerField,
    Min,
    Q,
    Sum,
    Value,
    When,
)
from django.db.models.functions import Coalesce

from apps.documents.statuses import DocumentStatus

from . import consignment as figures
from .consignment_reminders import MAX_ROUNDS, last_reminder_for, reminder_settings
from .models import ConsignmentAgreement, ConsignorPayout, StockUnit


class LineState:
    """Where one article stands with its owner, in the order the page lists them."""

    AWAITING = "awaiting"  # sold; the money waits for them
    HELD = "held"  # on our shelf, still theirs
    PAID = "paid"  # sold and settled
    RETURNED = "returned"  # handed back unsold
    LOST = "lost"  # damaged, written off — see its custody incident

    ORDER = (AWAITING, HELD, PAID, RETURNED, LOST)
    OPEN = (AWAITING, HELD)


_SOLD = StockUnit.Status.SOLD
_HELD_STATUSES = StockUnit.LIVE_STATUSES


def _state():
    return Case(
        When(status=_SOLD, consignor_paid_at__isnull=True, then=Value(LineState.AWAITING)),
        When(status=_SOLD, then=Value(LineState.PAID)),
        When(status__in=_HELD_STATUSES, then=Value(LineState.HELD)),
        When(status=StockUnit.Status.RETURNED, then=Value(LineState.RETURNED)),
        default=Value(LineState.LOST),
        output_field=CharField(),
    )


def _rank():
    return Case(
        *[
            When(state=state, then=Value(index))
            for index, state in enumerate(LineState.ORDER)
        ],
        default=Value(len(LineState.ORDER)),
        output_field=IntegerField(),
    )


def _activity_at():
    """The date that places an article in time: when it sold, was paid for,
    came in, or — returned or lost — last changed."""
    return Case(
        When(state=LineState.AWAITING, then=F("sold_at")),
        When(state=LineState.PAID, then=Coalesce("consignor_paid_at", "sold_at")),
        When(state=LineState.HELD, then=Coalesce("acquired_at", "created_at")),
        default=F("updated_at"),
        output_field=DateTimeField(),
    )


def consignor_units(consignor):
    """Every article this consignor ever left with the shop, cancelled aside."""
    return StockUnit.objects.filter(
        is_consignment=True, consignor=getattr(consignor, "pk", consignor)
    ).exclude(status=StockUnit.Status.CANCELLED)


def statement_lines(consignor, *, start=None, end=None, states=None):
    """The article lines, open ones first, newest first within each state."""
    rows = (
        consignor_units(consignor)
        .annotate(state=_state())
        .annotate(state_rank=_rank(), activity_at=_activity_at())
    )
    if start is not None or end is not None:
        window = Q()
        if start is not None:
            window &= Q(activity_at__gte=start)
        if end is not None:
            window &= Q(activity_at__lt=end)
        rows = rows.filter(Q(state__in=LineState.OPEN) | window)
    if states:
        rows = rows.filter(state__in=states)
    return (
        rows.select_related(
            "variant",
            "variant__product",
            "agreement",
            "consignor_payout",
            "sold_order_line__order",
        )
        # ``variant.full_name`` reads the option values: once for the page,
        # not once per handset.
        .prefetch_related("variant__option_values__option")
        .order_by("state_rank", "-activity_at", "-id")
    )


def statement_figures(consignor, *, start=None, end=None, sees_margins=False) -> dict:
    """The headline: what is owed now, and what the period did."""
    in_period = Q()
    if start is not None:
        in_period &= Q(sold_at__gte=start)
    if end is not None:
        in_period &= Q(sold_at__lt=end)
    awaiting = Q(status=_SOLD, consignor_paid_at__isnull=True)
    held = Q(status__in=_HELD_STATUSES)
    counts = consignor_units(consignor).aggregate(
        total_count=Count("id"),
        held_count=Count("id", filter=held),
        held_declared_value=Sum("declared_value", filter=held),
        awaiting_count=Count("id", filter=awaiting),
        oldest_awaiting_at=Min("sold_at", filter=awaiting),
        paid_count=Count("id", filter=Q(status=_SOLD, consignor_paid_at__isnull=False)),
        returned_count=Count("id", filter=Q(status=StockUnit.Status.RETURNED)),
        lost_count=Count(
            "id",
            filter=~Q(status__in=(*_HELD_STATUSES, _SOLD, StockUnit.Status.RETURNED)),
        ),
        period_sold_count=Count("id", filter=Q(status=_SOLD) & in_period),
        period_sold_value=Sum("sold_price", filter=Q(status=_SOLD) & in_period),
    )

    paid_in_period = Q()
    if start is not None:
        paid_in_period &= Q(paid_at__gte=start)
    if end is not None:
        paid_in_period &= Q(paid_at__lt=end)
    payouts = (
        ConsignorPayout.objects.filter(consignor=getattr(consignor, "pk", consignor))
        .exclude(doc_status=DocumentStatus.CANCELLED)
        .filter(paid_in_period)
        .aggregate(total=Sum("amount"), count=Count("id"))
    )

    result = {
        "payable": figures.consignor_payable(consignor=consignor),
        "receivable": figures.consignor_receivable(consignor=consignor),
        "claims_open": figures.consignor_claims_open(consignor=consignor),
        "claims_unassessed": figures.consignor_claims_unassessed(consignor=consignor),
        "total_count": counts["total_count"],
        "held_count": counts["held_count"],
        "held_declared_value": _money(counts["held_declared_value"]),
        "awaiting_count": counts["awaiting_count"],
        "oldest_awaiting_at": counts["oldest_awaiting_at"],
        "paid_count": counts["paid_count"],
        "returned_count": counts["returned_count"],
        "lost_count": counts["lost_count"],
        "period_sold_count": counts["period_sold_count"],
        "period_sold_value": _money(counts["period_sold_value"]),
        "period_paid_total": _money(payouts["total"]),
        "period_payout_count": payouts["count"],
        "agreement_count": ConsignmentAgreement.objects.filter(
            consignor=getattr(consignor, "pk", consignor)
        )
        .exclude(doc_status=DocumentStatus.CANCELLED)
        .count(),
    }
    # The shop's earning is its margin, and margins are for the reporting
    # roles (``roles-and-permissions``). Left out, not zeroed: a zero would
    # read as "we made nothing on your goods".
    if sees_margins:
        result["shop_commission"] = figures.shop_consignment_commission(
            start=start, end=end, consignor=consignor
        )
    return result


def reminder_summary(consignor, settings=None) -> dict:
    """Whether reminders run for this shop, and the last one this person got."""
    every, enabled = reminder_settings(settings)
    last = last_reminder_for(consignor)
    return {
        "enabled": enabled,
        "every_days": every,
        "max_rounds": MAX_ROUNDS,
        "last_at": last.sent_at if last is not None else None,
        "last_status": (
            last.message.status if last is not None and last.message_id else None
        ),
    }


def _money(value) -> Decimal:
    return Decimal(value or 0).quantize(Decimal("0.01"))


__all__ = [
    "LineState",
    "consignor_units",
    "reminder_summary",
    "statement_figures",
    "statement_lines",
]
