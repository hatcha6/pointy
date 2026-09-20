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

    # Charges that were SENT and never answered. Done after the pending pass
    # so a row this settles back to pending is not also matched in the same
    # sweep — one attempt per sweep, and the next one picks it up.
    settled = _resolve_submitted(account, driver, since=since, now=now)

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
        # What the sent-but-unanswered pass did: confirmed against the
        # provider's log, returned to retryable on proof of absence, or left
        # alone because nothing could be proved.
        "resolved": settled,
        "unperformed": [_fulfillment_brief(row) for row in unperformed],
        "off_book": off_book,
        "expected_balance": expected,
        "reported_balance": reported,
        "drift": drift,
        "drift_material": drift is not None and abs(drift) > DRIFT_TOLERANCE,
        "at": now,
    }


def _resolve_submitted(account, driver, *, since, now) -> dict:
    """Settle the charges that were sent and never answered.

    ``submitted`` means "we sent a write and do not know what it did". The
    guard in :mod:`apps.integrations.recharge` will never touch such a row
    again, so without this it stays there for good. Only the provider's own
    log can settle it, and there are exactly three honest endings:

    **Confirmed** — the provider has it. Either we already hold its reference
    (LNET hands one back even when the second half of its write fails) or it
    matches on cost and card like any other sale. The customer got what they
    paid for.

    **Retryable** — the provider does *not* have it, and the page we read
    reaches back past the attempt, so absence is proof rather than ignorance.
    Only then does the row go back to ``pending``, which re-arms the one
    attempt it is allowed.

    **Still unknown** — anything else: the read failed, or the log does not
    reach back far enough to prove absence. The row stays put and keeps
    raising ``integrations.unresolved_recharge`` for a human, because the
    alternative is charging a customer twice on the strength of a short page.

    Note what "confirmed" does and does not assert for a two-step provider: it
    says the customer was credited, not that the float was debited. A payment
    that exists while the float never paid for it shows up as drift, which is
    the right place for it — a discrepancy in the shop's money, not a sale in
    doubt.
    """
    rows = list(
        IntegrationFulfillment.objects.filter(
            account=account,
            status=IntegrationFulfillment.Status.SUBMITTED,
            created_at__gte=since,
        )
        .select_related("order_line")
        .order_by("created_at")
    )
    settled = {"confirmed": 0, "retryable": 0, "unknown": [], "checked": len(rows)}
    if not rows:
        return settled

    for card_no in sorted({row.subscriber_ref for row in rows}):
        mine = [row for row in rows if row.subscriber_ref == card_no]
        history = driver.purchase_history(card_no, limit=HISTORY_PAGE, offset=0)
        if not history.ok:
            settled["unknown"].extend(_fulfillment_brief(row) for row in mine)
            continue

        # Same rule as the pending path: one provider entry can never settle
        # two sales, or a genuine unperformed row hides behind a real one.
        claimed = set(
            IntegrationFulfillment.objects.exclude(provider_reference="")
            .filter(account=account, subscriber_ref=card_no)
            .values_list("provider_reference", flat=True)
        )
        by_reference = {e.reference: e for e in history.purchases if e.reference}
        ours = [e for e in history.purchases if e.is_ours and e.at is not None]

        for row in mine:
            if row.provider_reference:
                # We were handed a reference before the answer stopped
                # coming, which means a payment was created. Identity beats
                # inference: settle on that reference or not at all. It is
                # NEVER retryable — whether or not the log still shows it,
                # the provider told us it existed, and a second attempt would
                # credit the customer twice. Missing from a log that reaches
                # back past it is a contradiction for a person to look at.
                entry = by_reference.get(row.provider_reference)
            else:
                entry = _best_match(row, ours, claimed)

            if entry is not None:
                _confirm(row, entry, now=now)
                claimed.add(entry.reference)
                settled["confirmed"] += 1
                continue

            if not row.provider_reference and history.covers(row.submitted_at):
                # Proof of absence: the provider never performed it, so the
                # sale may be attempted once more.
                row.status = IntegrationFulfillment.Status.PENDING
                row.last_error_code = ""
                row.last_error = ""
                row.save(
                    update_fields=[
                        "status",
                        "last_error_code",
                        "last_error",
                        "updated_at",
                    ]
                )
                settled["retryable"] += 1
                continue

            settled["unknown"].append(_fulfillment_brief(row))
    return settled


def _confirm(row, entry, *, now) -> None:
    """Write a provider entry onto a fulfillment as proof it was performed."""
    with transaction.atomic():
        row.status = IntegrationFulfillment.Status.CONFIRMED
        row.provider_reference = entry.reference[:64]
        row.confirmed_at = entry.at or now
        # The provider's own record, kept so the shop can print theirs beside
        # ours instead of a retyped version.
        row.provider_receipt = {
            "reference": entry.reference,
            "cost": str(entry.cost) if entry.cost is not None else "",
            "months": entry.months,
            "package_name": entry.package_name,
            "operator_name": entry.operator_name,
            "at": entry.at.isoformat() if entry.at else "",
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
        _confirm(row, candidate, now=now)
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
