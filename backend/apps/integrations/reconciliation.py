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

The company's own relay (``catalog.ProviderSpec.relay_hosted``) needs none of
that: every purchase is made under a key of ours, so a sale whose answer was
lost is read back by that key (:func:`settle_attempts`) — every two minutes,
since a customer is waiting on its code (:func:`settle_relay_attempts`), and
again here nightly. Its rows are never matched against a log.
"""

from __future__ import annotations

import logging
from datetime import timedelta
from decimal import Decimal

from django.db import transaction
from django.utils import timezone

from apps.core.state_version import bump

from . import catalog, switches
from .fulfillment import fulfillment_kind, retire_withdrawn
from .models import IntegrationAccount, IntegrationFulfillment, ProviderPayment
from .providers import provider_for
from .providers.base import ATTEMPT_ABSENT, ATTEMPT_CHARGED, ATTEMPT_REFUSED
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

#: A card off a shelf is bought within seconds of the checkout being sent, so
#: an entry outside this window around the attempt is somebody else's purchase
#: of the same card — the owner's phone buys from the same shelf. The wide
#: CLOCK_SLACK above suits a portal a human types into; it would let a card
#: bought an hour earlier on the phone "confirm" a sale it has nothing to do
#: with, and hand that customer a PIN somebody else already has.
VOUCHER_MATCH_BEFORE = timedelta(minutes=2)
VOUCHER_MATCH_AFTER = timedelta(minutes=15)


def reconcile_all(*, lookback_days: int = DEFAULT_LOOKBACK_DAYS) -> dict:
    """Reconcile every configured provider still switched on. Never raises."""
    results = []
    for account in switches.running(IntegrationAccount.objects.filter(is_active=True)):
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

    # A sale that was given back owes the provider nothing: retire what a void
    # from before voids withdrew their own fulfillments left chargeable, or it is
    # reported below as a customer who paid and got nothing.
    retire_withdrawn(account)

    # Refresh the provider's own balance first: every figure below is compared
    # against it, and a stale one would invent drift that is not there.
    probe_account(account)
    account.refresh_from_db()

    pending = [
        row
        for row in IntegrationFulfillment.objects.filter(
            account=account,
            status=IntegrationFulfillment.Status.PENDING,
            created_at__gte=since,
        ).order_by("created_at")
        # A card nobody ever sent for cannot have been bought for this sale:
        # anything in the log that matches it is somebody else's card, and
        # "confirming" on it would hand the customer a PIN already sold. The
        # company's top-ups and bill payments have no log to match against
        # either: only an ordinary recharge is proved by the provider's own.
        if fulfillment_kind(row) == "recharge"
    ]

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
    if _settles_by_attempt(account, driver):
        # Read back by identity, never matched against a log: see
        # ``settle_attempts``.
        return settle_attempts(driver, rows, now=now)
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
                entry = _best_match(row, ours, claimed, window=_voucher_window(row))

            if entry is not None:
                claimed.add(entry.reference)
                if _confirm(row, entry, now=now):
                    settled["confirmed"] += 1
                    continue
                # Another sale holds that payment now. Two sales, one
                # payment: nothing a sweep may settle — a person must look.
                settled["unknown"].append(_fulfillment_brief(row))
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


# --- attempts a provider reads back by key (the company's relay) ----------------------
#: A sent attempt goes back to retryable only once it is this old, and only on
#: the provider's word. Longer than a purchase waits for its own answer
#: (``providers.pointy``): a settle must never meet an attempt whose request is
#: still out, or that request's late answer would be written over the next one.
ATTEMPT_SETTLE_AFTER = timedelta(minutes=2)


def _settles_by_attempt(account, driver) -> bool:
    """Whether this account's sent writes are read back rather than matched.

    Decided by the catalog as well as the driver, so a relay-hosted provider
    the operator switched off — whose stand-in driver reads nothing — is left
    unsettled rather than matched against a purchase log it does not have.
    """
    spec = account.spec
    return bool(getattr(driver, "reads_attempts", False)) or bool(
        spec is not None and spec.relay_hosted
    )


def settle_relay_attempts(*, now=None) -> dict:
    """Every two minutes: settle the relay purchases whose answer was lost.

    A card the customer paid for is waiting on this, so it runs far more often
    than the nightly sweep — and costs one query when there is nothing to do.
    An account the owner switched off since is still settled: the sale stands.
    """
    now = now or timezone.now()
    relay_keys = [spec.key for spec in catalog.PROVIDERS if spec.relay_hosted]
    sent = IntegrationFulfillment.objects.filter(
        status=IntegrationFulfillment.Status.SUBMITTED, provider__in=relay_keys
    )
    account_ids = set(sent.values_list("account_id", flat=True))
    results = []
    if not account_ids:
        return {"accounts": results}
    for account in switches.running(
        IntegrationAccount.objects.filter(pk__in=account_ids)
    ):
        if not account.is_configured:
            continue
        rows = list(
            sent.filter(account=account)
            .select_related("order_line")
            .order_by("created_at")
        )
        try:
            settled = settle_attempts(provider_for(account), rows, now=now)
        except Exception:  # pragma: no cover - a driver bug must not stop the sweep
            logger.exception(
                "settling relay purchases crashed for %s", account.provider
            )
            continue
        results.append({"provider": account.provider, **settled})
    return {"accounts": results}


def settle_attempts(driver, rows, *, now) -> dict:
    """Settle sent attempts by reading each back under its own key.

    Identity, never inference: the provider says what it did with exactly this
    attempt, so nothing is matched on cost and time and no other sale's card
    can be handed over. Three honest endings, as for a log:

    **Charged** — CONFIRMED, with the code on the receipt the customer is
    reprinted, and the cost corrected to what was charged.

    **Refused, or never heard of** — back to PENDING, which re-arms the one
    attempt the row is allowed (under a new key), once the attempt is older
    than ``ATTEMPT_SETTLE_AFTER``.

    **Anything else** — still being bought, the code not read back yet, the
    read failed: left as it is, and asked again next time.

    One row that cannot be settled — a driver bug, a row the database will not
    give — is left as it is and does not stop the others: a customer is waiting
    on every one of them.
    """
    settled = {"confirmed": 0, "retryable": 0, "unknown": [], "checked": len(rows)}
    for row in rows:
        try:
            ending = _settle_attempt(driver, row, now=now)
        except Exception:  # noqa: BLE001 - one row must not abort the run
            logger.exception("settling the attempt of fulfillment %s crashed", row.pk)
            ending = None
        if ending is None:
            settled["unknown"].append(_fulfillment_brief(row))
        else:
            settled[ending] += 1
    return settled


def _settle_attempt(driver, row, *, now) -> str | None:
    """``confirmed`` or ``retryable`` when this row's attempt was settled, else ``None``."""
    from . import recharge

    # The driver is told which fulfillment it reads back, so a service's slip is
    # written for the country the sale named instead of a search of the directory.
    driver.bind(row)
    outcome = driver.attempt_outcome(
        recharge.attempt_key(row), option_code=row.option_code
    )
    if outcome.state == ATTEMPT_CHARGED and _confirm_attempt(row, outcome, now=now):
        return "confirmed"
    old_enough = (
        row.submitted_at is None or row.submitted_at <= now - ATTEMPT_SETTLE_AFTER
    )
    if (
        outcome.state in (ATTEMPT_REFUSED, ATTEMPT_ABSENT)
        and old_enough
        and _rearm_attempt(row, outcome, now=now)
    ):
        return "retryable"
    return None


def _locked_attempt(row):
    """``row`` locked, if it is still the sent attempt it was when it was read."""
    return (
        IntegrationFulfillment.objects.select_for_update()
        .select_related("account", "order_line")
        .filter(
            pk=row.pk,
            status=IntegrationFulfillment.Status.SUBMITTED,
            attempt_count=row.attempt_count,
        )
        .first()
    )


def _confirm_attempt(row, outcome, *, now) -> bool:
    from . import recharge

    with transaction.atomic():
        locked = _locked_attempt(row)
        if locked is None:
            return False
        locked.status = IntegrationFulfillment.Status.CONFIRMED
        # When the provider performed it: the float was drawn then.
        locked.confirmed_at = outcome.at or now
        locked.provider_reference = (outcome.reference or "")[:64]
        locked.provider_receipt = outcome.receipt or {}
        locked.last_error_code = ""
        locked.last_error = ""
        fields = [
            "status",
            "confirmed_at",
            "provider_reference",
            "provider_receipt",
            "last_error_code",
            "last_error",
            "updated_at",
        ]
        fields += recharge.apply_actual_cost(locked, outcome.actual_cost)
        locked.save(update_fields=fields)
        _note_balance(locked.account, outcome.balance_after, now=now)
        bump("integrations")
    return True


def _rearm_attempt(row, outcome, *, now) -> bool:
    with transaction.atomic():
        locked = _locked_attempt(row)
        if locked is None:
            return False
        locked.status = IntegrationFulfillment.Status.PENDING
        # Why, when the provider said: the till offers "try again" with it.
        locked.last_error_code = (outcome.error_code or "")[:32]
        locked.last_error = outcome.error_detail or ""
        locked.save(
            update_fields=["status", "last_error_code", "last_error", "updated_at"]
        )
        _note_balance(locked.account, outcome.balance_after, now=now)
        bump("integrations")
    return True


def _note_balance(account, balance, *, now) -> None:
    if balance is None:
        return
    account.balance = balance
    account.balance_at = now
    account.save(update_fields=["balance", "balance_at", "updated_at"])


def _confirm(row, entry, *, now) -> bool:
    """Write a provider entry onto a fulfillment as proof it was performed.

    Returns ``False``, writing nothing, when some other live fulfillment
    already holds the entry's reference. The ``claimed`` sets the callers keep
    are read once per card and cannot see a claim made since — a manager
    recording that very payment as a sale from the payments report
    (:mod:`apps.integrations.portal_sales`), say. So the check is made again
    here, under the same report-row lock that path takes: whichever of the
    two gets there second finds the other's claim and stands down, and one
    payment can never settle two sales.
    """
    with transaction.atomic():
        ProviderPayment.objects.select_for_update().filter(
            account_id=row.account_id, reference=entry.reference
        ).first()
        taken = (
            IntegrationFulfillment.objects.filter(
                account_id=row.account_id, provider_reference=entry.reference
            )
            .exclude(pk=row.pk)
            .exclude(status=IntegrationFulfillment.Status.CANCELLED)
            .exists()
        )
        if taken:
            return False
        row.status = IntegrationFulfillment.Status.CONFIRMED
        row.provider_reference = entry.reference[:64]
        row.confirmed_at = entry.at or now
        # The provider's own record, kept so the shop can print theirs beside
        # ours instead of a retyped version.
        receipt = {
            "reference": entry.reference,
            "cost": str(entry.cost) if entry.cost is not None else "",
            "months": entry.months,
            "package_name": entry.package_name,
            "operator_name": entry.operator_name,
            "at": entry.at.isoformat() if entry.at else "",
        }
        # A card whose checkout reply was lost carries its PIN in the log: the
        # customer can still be handed it, on a reprint of the same receipt.
        printed = entry.printed or (row.provider_receipt or {}).get("printed")
        if printed:
            receipt["printed"] = printed
        row.provider_receipt = receipt
        row.save(
            update_fields=[
                "status",
                "provider_reference",
                "confirmed_at",
                "provider_receipt",
                "updated_at",
            ]
        )
    return True


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
        while True:
            candidate = _best_match(row, ours, claimed)
            if candidate is None:
                break
            claimed.add(candidate.reference)
            # False when somebody claimed it since ``claimed`` was read; the
            # next candidate, if any, is still this sale's to have.
            if _confirm(row, candidate, now=now):
                confirmed += 1
                break

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


def _voucher_window(row):
    """The instants a voucher row's card can have been bought in, or ``None``."""
    if fulfillment_kind(row) != "voucher" or row.submitted_at is None:
        return None
    return (
        row.submitted_at - VOUCHER_MATCH_BEFORE,
        row.submitted_at + VOUCHER_MATCH_AFTER,
    )


def _best_match(row, entries, claimed, *, window=None):
    """The earliest unclaimed provider entry that this sale could be.

    Cost must agree exactly — it is the figure the provider itself quoted us —
    and the purchase cannot predate the sale by more than clock skew. A
    ``window`` narrows that to the instants the attempt itself could have
    produced (see ``VOUCHER_MATCH_BEFORE``).
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
        if window is not None and not (window[0] <= entry.at <= window[1]):
            continue
        # Where both sides name what was bought, they must agree: a 10-dinar
        # Libyana card and a 10-dinar Almadar card cost the float the same.
        if row.package_id and entry.package_id and row.package_id != entry.package_id:
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
