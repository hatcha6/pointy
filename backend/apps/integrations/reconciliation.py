"""Proving that what Pointy sold is what the provider actually did.

A recharge is two events that can drift apart: the shop took money, and the
provider put time on a card. Pointy records the first at the till; the second
happens on the provider's own system, today by a human typing it in. Nothing
connects them until something goes and looks.

This is that something. Nightly, per provider account, it:

1. re-reads the float balance from the provider, so drift is current;
2. matches every ``pending`` fulfillment against the provider's own purchase
   log for that card, and confirms the ones it can prove;
3. reports the three ways it can go wrong.

The three failures are deliberately kept apart, because they mean different
things and need different people:

**Unperformed** — Pointy sold it, the provider never did it. A customer paid
and got nothing. This is the one that has a person standing in the shop.

**Off-book** — the provider's log shows this agency recharging a card that no
Pointy sale accounts for. Somebody took cash and did it on the portal.

**Drift** — the provider's balance disagrees with our arithmetic by more than
the matched rows explain. The catch-all: it fires even for cards we have never
seen, which the per-card checks above cannot.

Matching is conservative. A provider entry is only claimed when its cost and
card match, no other fulfillment has already claimed it, and it did not happen
*before* the sale. When in doubt it leaves the row pending: a false confirm
would quietly assert that a customer got what they paid for.
"""

from __future__ import annotations

import logging
from datetime import timedelta
from decimal import Decimal

from django.db import transaction
from django.utils import timezone

from .models import IntegrationAccount, IntegrationFulfillment
from .providers import provider_for
from .services import probe_account

logger = logging.getLogger(__name__)

#: How far back to re-examine. A top-up nobody performed for a month is not
#: going to be performed; it needs a human, not another sweep.
DEFAULT_LOOKBACK_DAYS = 30

#: A provider entry may predate our sale by this much and still be the same
#: event — clock skew between their server and ours, nothing more.
CLOCK_SLACK = timedelta(hours=2)

#: Sold but unperformed for longer than this is reported as a problem.
UNPERFORMED_AFTER = timedelta(hours=6)

#: Ignore float drift smaller than this: providers round, and a shop should
#: not get an alert about half a dinar.
DRIFT_TOLERANCE = Decimal("1.00")

#: Buy-log rows to read per card. A card renewed yearly for a decade has ten.
HISTORY_PAGE = 25


def reconcile_all(*, lookback_days: int = DEFAULT_LOOKBACK_DAYS) -> dict:
    """Reconcile every configured provider. Never raises."""
    results = []
    for account in IntegrationAccount.objects.filter(is_active=True):
        if not account.is_configured:
            continue
        try:
            results.append(reconcile_account(account, lookback_days=lookback_days))
        except Exception:  # pragma: no cover - a driver bug must not stop the sweep
            logger.exception("reconciliation crashed for %s", account.provider)
            results.append({"provider": account.provider, "ok": False})
    return {"accounts": results}


def reconcile_account(
    account: IntegrationAccount,
    *,
    lookback_days: int = DEFAULT_LOOKBACK_DAYS,
    now=None,
) -> dict:
    """Match one provider's pending sales against its own purchase log."""
    from . import float_ledger

    now = now or timezone.now()
    since = now - timedelta(days=lookback_days)

    # Refresh the provider's own balance first: every figure below is compared
    # against it, and a stale one would invent drift that is not there.
    probe_account(account)
    account.refresh_from_db()

    pending = list(
        IntegrationFulfillment.objects.filter(
            account=account,
            status=IntegrationFulfillment.Status.PENDING,
            created_at__gte=since,
        ).order_by("created_at")
    )

    driver = provider_for(account)
    confirmed = 0
    unperformed = []
    off_book = []
    unreachable = False

    for card_no in sorted({row.subscriber_ref for row in pending}):
        history = driver.purchase_history(card_no, limit=HISTORY_PAGE, offset=0)
        if not history.ok:
            unreachable = True
            continue
        rows = [row for row in pending if row.subscriber_ref == card_no]
        matched, orphans = _match_card(rows, history.purchases, since=since, now=now)
        confirmed += matched
        off_book.extend(orphans)

    for row in IntegrationFulfillment.objects.filter(
        account=account,
        status=IntegrationFulfillment.Status.PENDING,
        created_at__gte=since,
        created_at__lte=now - UNPERFORMED_AFTER,
    ):
        unperformed.append(row)

    expected = float_ledger.expected_balance(account)
    reported = account.balance
    drift = None if reported is None else (Decimal(reported) - expected)

    return {
        "provider": account.provider,
        "ok": not unreachable,
        "checked": len(pending),
        "confirmed": confirmed,
        "unperformed": [_fulfillment_brief(row) for row in unperformed],
        "off_book": off_book,
        "expected_balance": expected,
        "reported_balance": reported,
        "drift": drift,
        "drift_material": drift is not None and abs(drift) > DRIFT_TOLERANCE,
        "at": now,
    }


def _match_card(rows, purchases, *, since, now) -> tuple[int, list]:
    """Confirm what can be proved for one card; report what cannot be explained.

    Returns ``(confirmed_count, off_book_entries)``.
    """
    # References already spoken for, so one provider entry can never confirm
    # two sales — the exact mistake that would hide a genuine unperformed row.
    claimed = set(
        IntegrationFulfillment.objects.exclude(provider_reference="")
        .filter(account=rows[0].account, subscriber_ref=rows[0].subscriber_ref)
        .values_list("provider_reference", flat=True)
    )
    ours = [
        entry
        for entry in purchases
        if entry.is_ours and entry.at is not None and entry.at >= since
    ]

    confirmed = 0
    for row in rows:
        candidate = _best_match(row, ours, claimed)
        if candidate is None:
            continue
        with transaction.atomic():
            row.status = IntegrationFulfillment.Status.CONFIRMED
            row.provider_reference = candidate.reference[:64]
            row.confirmed_at = candidate.at or now
            # The provider's own record of the purchase, kept so the shop can
            # print theirs beside ours instead of a retyped version.
            row.provider_receipt = {
                "reference": candidate.reference,
                "cost": str(candidate.cost) if candidate.cost is not None else "",
                "months": candidate.months,
                "package_name": candidate.package_name,
                "operator_name": candidate.operator_name,
                "at": candidate.at.isoformat() if candidate.at else "",
            }
            row.save(
                update_fields=[
                    "status",
                    "provider_reference",
                    "confirmed_at",
                    "provider_receipt",
                    "updated_at",
                ]
            )
        claimed.add(candidate.reference)
        confirmed += 1

    off_book = [
        {
            "card_no": rows[0].subscriber_ref,
            "reference": entry.reference,
            "cost": entry.cost,
            "months": entry.months,
            "at": entry.at,
            "operator_name": entry.operator_name,
        }
        for entry in ours
        if entry.reference not in claimed
    ]
    return confirmed, off_book


def _best_match(row, entries, claimed):
    """The earliest unclaimed provider entry that this sale could be.

    Cost must agree exactly — it is the figure the provider itself quoted us —
    and the purchase cannot predate the sale by more than clock skew.
    """
    floor = row.created_at - CLOCK_SLACK
    for entry in sorted(
        (e for e in entries if e.reference and e.reference not in claimed),
        key=lambda e: e.at,
    ):
        if entry.cost is None or Decimal(entry.cost) != Decimal(row.cost):
            continue
        if entry.at < floor:
            continue
        return entry
    return None


def _fulfillment_brief(row) -> dict:
    return {
        "id": row.id,
        "card_no": row.subscriber_ref,
        "cost": row.cost,
        "option_label": row.option_label,
        "sold_at": row.created_at,
        "order_id": row.order_line.order_id,
    }
