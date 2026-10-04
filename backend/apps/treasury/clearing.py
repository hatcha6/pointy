"""Which card payments a clearing account is holding.

A clearing account is never named on a payment — the till, the terminal map and
every payment serializer name a *bank*, and keep doing so. What makes a card
payment "held" is a rule, derived on read like the rest of the money position:

    a CARD payment, taken inside the clearing account's window, that names the
    bank the clearing account settles into — or names no bank at all, when the
    clearing account is the one that holds untagged takings.

Deriving it instead of re-tagging payments matters three ways. Every route that
writes a card payment — checkout, a debt collection, a refund's negative row, a
cancellation's counter row, an exchange — is covered without being touched.
Starting to hold card takings from last Thursday (the oldest day Moamalat has
not paid yet) is choosing a date, not rewriting frozen documents. And nothing
about the rule depends on which bank is the default *today*: the clearing
account's bank and its hold on untagged takings are fixed when it is opened.

The window is on the shop's own clock (``settlement_calendar.day_start``),
because it is the processor's day that is being held, not a UTC report day.
"""

from __future__ import annotations

from datetime import timedelta
from functools import reduce
from operator import or_

from django.db.models import Exists, OuterRef, Q

from apps.payments.models import Payment

from .models import CardSettlement, CardSettlementLine, MoneyAccount
from .settlement_calendar import day_start


def clearing_accounts(accounts=None):
    """Every clearing account, open or closed.

    A closed one still owns the takings of its window — settled or not — so a
    bank must keep leaving them out after the shop stops holding.
    """
    if accounts is not None:
        return [account for account in accounts if account.is_clearing]
    return list(MoneyAccount.objects.filter(kind=MoneyAccount.Kind.CLEARING))


def window_start(clearing):
    """The first instant whose card takings the account holds."""
    return day_start(clearing.opening_at)


def window_end(clearing):
    """The first instant it no longer holds, or ``None`` while it is open."""
    if clearing.closed_on is None:
        return None
    return day_start(clearing.closed_on + timedelta(days=1))


def claim_q(clearing, *, prefix=""):
    """The payments ``clearing`` holds, as a filter on ``Payment``.

    ``prefix`` reaches the same rule through a relation (``"payment__"``).
    """
    if clearing.settles_into_id is None:
        # A clearing account with no bank holds nothing — the serializer
        # refuses one, and this keeps a half-saved row from swallowing money.
        return Q(**{f"{prefix}pk__in": []})
    rule = Q(
        **{
            f"{prefix}method": Payment.Method.CARD,
            f"{prefix}paid_at__gte": window_start(clearing),
        }
    )
    end = window_end(clearing)
    if end is not None:
        rule &= Q(**{f"{prefix}paid_at__lt": end})
    owner = Q(**{f"{prefix}money_account_id": clearing.settles_into_id})
    if clearing.holds_untagged_card:
        owner |= Q(**{f"{prefix}money_account__isnull": True})
    return rule & owner


def held_by_any_q(clearings):
    """Payments held by any of ``clearings``, or ``None`` when there are none.

    ``None`` rather than an always-false filter, so a shop that never opened a
    clearing account runs exactly the queries it ran before.
    """
    claims = [claim_q(clearing) for clearing in clearings]
    return reduce(or_, claims) if claims else None


def held_payments(clearing):
    """Every card payment the account has held, settled or not."""
    return Payment.objects.filter(claim_q(clearing))


def live_line_exists():
    return Exists(
        CardSettlementLine.objects.filter(payment=OuterRef("pk"), is_live=True)
    )


def pending_payments(clearing):
    """The held payments no live settlement has paid for yet."""
    return held_payments(clearing).exclude(live_line_exists())


def live_settlements():
    return CardSettlement.objects.live()


def is_held_by(payment, clearing) -> bool:
    """Whether one payment falls under ``clearing``'s rule.

    The same rule as ``claim_q``, read off a row already in memory, so a
    settlement can check what it was handed without a query per payment.
    """
    if clearing.settles_into_id is None or payment.method != Payment.Method.CARD:
        return False
    if payment.paid_at < window_start(clearing):
        return False
    end = window_end(clearing)
    if end is not None and payment.paid_at >= end:
        return False
    if payment.money_account_id == clearing.settles_into_id:
        return True
    return payment.money_account_id is None and clearing.holds_untagged_card


__all__ = [
    "claim_q",
    "clearing_accounts",
    "held_by_any_q",
    "held_payments",
    "is_held_by",
    "live_line_exists",
    "live_settlements",
    "pending_payments",
    "window_end",
    "window_start",
]
