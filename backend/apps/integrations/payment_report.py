"""The provider's own payments report, mirrored a page at a time.

LNET keeps one report of every payment the agency ever made — each line, each
operator, the till's and the website's alike — and it is the only record of a
top-up somebody did on the website while the till could not sell it. It prints
**ten rows a page over the agency's whole life**, newest first (the captured
account had ~9,400). Read live, one page is roughly the last day of trade, and
that was the whole of what the till's history for a line could ever show.

So the report is copied into :class:`~apps.integrations.models.ProviderPayment`
and read from there. Three rules make the copy trustworthy:

* **It is always read from the newest row down**, the only order the report can
  be walked in. New payments land at the top while a reader is paging, which
  shifts every row down: consecutive pages then *overlap*, and never skip.
  Overlap is harmless — rows are keyed on the provider's own reference.

* **Coverage is claimed, never assumed.** The account records the stretch the
  copy is known to be whole for — ``payments_covered_since`` up to
  ``payments_synced_at``. A read extends it only when it reached back into the
  previous stretch; one that could not (too many pages since) starts it over.
  "Every payment of this day is listed" is a statement a screen may only make
  on the strength of that stretch.

* **A copy is for reading.** Anything that moves money because of a payment in
  it re-reads the report live first (see :mod:`apps.integrations.portal_sales`).
"""

from __future__ import annotations

import logging
from dataclasses import dataclass
from datetime import date, datetime, time, timedelta
from datetime import timezone as dt_timezone

from django.core.cache import cache
from django.db import transaction
from django.utils import timezone

from apps.core.timeutils import business_timezone

from . import catalog
from .models import IntegrationAccount, ProviderPayment
from .providers import provider_for
from .providers.base import (
    ERROR_NOT_CONFIGURED,
    ERROR_UNAVAILABLE,
    ERROR_UNEXPECTED,
    HistoryResult,
    PurchaseEntry,
)

logger = logging.getLogger(__name__)

#: A portal's clock and ours disagree by a minute or so (LNET's did by one in
#: the capture). A payment is only certain to have been printed by a read that
#: began this long after the payment's own timestamp.
CLOCK_SKEW = timedelta(minutes=10)
#: How far back the very first read of an account goes, before the sweep has
#: deepened it.
FIRST_READ_WINDOW = timedelta(days=2)
#: How deep the sweep fills the mirror: three months of a line's top-ups is
#: what a cashier looking at its history needs, and a line topped up monthly
#: shows three of them.
KEEP_WINDOW = timedelta(days=90)

#: Pages one read may spend while a cashier waits — opening a line's history.
#: Every page is a round trip to a portal measured at 0.7–4.4 seconds.
INTERACTIVE_PAGES = 3
#: Pages a manager's read of one day may spend. A busy day is a few pages; a
#: day long past can be forty pages down.
DAY_PAGES = 40
#: Pages one sweep may spend. Ten rows a page, so this is 1,500 payments —
#: months for a shop that sells ten top-ups a day.
SWEEP_PAGES = 150
#: How often the sweep tries to deepen the mirror towards ``KEEP_WINDOW``, and
#: how long it leaves a report alone after a deepening ran out of pages first.
DEEPEN_EVERY = timedelta(hours=6)
DEEPEN_BACKOFF = timedelta(days=7)

#: "Before anything": a read that reached the report's last page has seen all.
BEGINNING_OF_TIME = datetime(1970, 1, 1, tzinfo=dt_timezone.utc)

#: One sweep per account at a time. A deepening read can run for minutes and
#: the next half-hourly sweep must not start the same walk beside it.
_SWEEP_LOCK = "pointy:integrations:payment-report:sweep:{account}"
_SWEEP_LOCK_SECONDS = 30 * 60
_DEEPENED_KEY = "pointy:integrations:payment-report:deepened:{account}"


@dataclass(frozen=True)
class SyncResult:
    """What one walk down the report did."""

    ok: bool
    pages: int = 0
    rows: int = 0
    #: The oldest instant the walk read back to; ``BEGINNING_OF_TIME`` when it
    #: reached the report's last page.
    reached: datetime | None = None
    #: The walk got as far back as it was asked to.
    complete: bool = False
    error_code: str = ""
    error_detail: str = ""


def supports_payment_report(account) -> bool:
    spec = account.spec
    return spec is not None and catalog.CAPABILITY_PAYMENT_REPORT in spec.capabilities


def subscriber_key(subscriber_ref: str) -> str:
    """The folded form every lookup by line compares on — exact, case-blind.

    Exact matters: the portal's own search is a substring match, and a
    top-up of ``basheir`` must never be shown as one of ``basheir.shop``.
    """
    return (subscriber_ref or "").strip().casefold()[:64]


# --- reading ----------------------------------------------------------------
def sync(account, *, back_to=None, max_pages=INTERACTIVE_PAGES, now=None) -> SyncResult:
    """Walk the report from its newest row down, storing every row on the way.

    Stops at the first of: the report's last page; a row at or before the
    *floor* — the older of ``back_to`` and where the previous read began (less
    the clock skew), which is how far back a read must go for the mirror to be
    whole again; or ``max_pages``. Never raises.

    Not locked: two readers at once store the same rows twice, which the
    reference key makes harmless, and the coverage they claim is merged under
    a row lock. Only the sweep, which can walk for minutes, keeps to itself.
    """
    if not supports_payment_report(account):
        return SyncResult(ok=False, error_code=ERROR_UNAVAILABLE)
    if not account.is_configured:
        return SyncResult(ok=False, error_code=ERROR_NOT_CONFIGURED)
    try:
        return _walk(account, back_to=back_to, max_pages=max_pages, now=now)
    except Exception as exc:  # noqa: BLE001 - a read must never 500 a screen
        logger.exception("payments report read crashed for %s", account.provider)
        return SyncResult(
            ok=False,
            error_code=ERROR_UNEXPECTED,
            error_detail=f"{type(exc).__name__}: {exc}",
        )


def _walk(account, *, back_to, max_pages, now) -> SyncResult:
    started = now or timezone.now()
    previous = (
        IntegrationAccount.objects.filter(pk=account.pk)
        .values_list("payments_synced_at", flat=True)
        .first()
    )
    floor = _floor(back_to=back_to, previous=previous, started=started)

    driver = provider_for(account)
    offset = 0
    pages = 0
    stored = 0
    oldest = None
    at_end = False
    while pages < max_pages:
        page = driver.payment_report_page(offset=offset)
        if not page.ok:
            # What was stored before the failure stays stored — every row of
            # it was really printed — but no coverage is claimed for a walk
            # that did not finish.
            return SyncResult(
                ok=False,
                pages=pages,
                rows=stored,
                error_code=page.error_code,
                error_detail=page.error_detail,
            )
        stored += store(account, page.payments)
        pages += 1
        stamps = [payment.at for payment in page.payments if payment.at is not None]
        if stamps:
            lowest = min(stamps)
            oldest = lowest if oldest is None else min(oldest, lowest)
        if page.next_offset is None or not page.payments:
            at_end = True
            break
        if oldest is not None and oldest <= floor:
            break
        if page.next_offset <= offset:
            # A pager that points backwards would walk in a circle for ever.
            return SyncResult(
                ok=False,
                pages=pages,
                rows=stored,
                error_code=ERROR_UNEXPECTED,
                error_detail="the report's pager did not move forward",
            )
        offset = page.next_offset

    reached = BEGINNING_OF_TIME if at_end else oldest
    if reached is not None:
        # A portal clock running ahead can stamp a row after the moment we
        # began reading; a stretch must never end before it starts.
        reached = min(reached, started)
    if reached is None:
        # Pages full of rows, and not one date we could read: nothing can be
        # said about where this walk got to.
        return SyncResult(
            ok=False,
            pages=pages,
            rows=stored,
            error_code=ERROR_UNEXPECTED,
            error_detail="no dated rows in the payments report",
        )
    _merge_coverage(account, reached=reached, started=started)
    return SyncResult(
        ok=True,
        pages=pages,
        rows=stored,
        reached=reached,
        complete=at_end or reached <= floor,
    )


def _floor(*, back_to, previous, started):
    candidates = []
    if back_to is not None:
        candidates.append(back_to)
    if previous is not None:
        candidates.append(previous - CLOCK_SKEW)
    if not candidates:
        candidates.append(started - FIRST_READ_WINDOW)
    return min(candidates)


def _merge_coverage(account, *, reached, started) -> None:
    """Fold one finished walk into the stretch the mirror is known whole for.

    A walk covers ``[reached, started − skew]``: everything stamped in that
    stretch was already in the report when the walk began at its top. It
    joins the stretch on record only where the two overlap; otherwise the
    newer of the two wins and the older is let go — claiming the gap between
    them would be claiming rows nobody read.
    """
    with transaction.atomic():
        row = IntegrationAccount.objects.select_for_update().get(pk=account.pk)
        since, until = row.payments_covered_since, row.payments_synced_at
        if since is None or until is None:
            since, until = reached, started
        elif reached <= until - CLOCK_SKEW and since <= started - CLOCK_SKEW:
            since, until = min(since, reached), max(until, started)
        elif started > until:
            since, until = reached, started
        else:
            return
        IntegrationAccount.objects.filter(pk=row.pk).update(
            payments_covered_since=since, payments_synced_at=until
        )
    account.payments_covered_since = since
    account.payments_synced_at = until


def store(account, payments) -> int:
    """Upsert one page of report rows. Returns how many rows it wrote.

    Keyed on the provider's reference, so a row read twice — pages overlap as
    payments arrive — is one row. Everything the provider may change about a
    payment afterwards (a cancellation, above all) is refreshed; the float's
    cost is not, because it was fixed by the commission in force when the row
    was first read, and an owner editing that setting today does not reach
    back into payments already made.
    """
    rows = [payment for payment in payments if payment.reference]
    if not rows:
        return 0
    seen_at = timezone.now()
    references = [payment.reference[:64] for payment in rows]
    with transaction.atomic():
        existing = {
            row.reference: row
            for row in ProviderPayment.objects.filter(
                account=account, reference__in=references
            )
        }
        created = []
        changed = []
        for payment in rows:
            reference = payment.reference[:64]
            fields = _fields_of(payment)
            row = existing.get(reference)
            if row is None:
                created.append(
                    ProviderPayment(
                        account=account,
                        provider=account.provider,
                        reference=reference,
                        cost=payment.cost,
                        last_seen_at=seen_at,
                        **fields,
                    )
                )
                continue
            if row.cost is None and payment.cost is not None:
                row.cost = payment.cost
            for name, value in fields.items():
                setattr(row, name, value)
            row.last_seen_at = seen_at
            changed.append(row)
        if created:
            ProviderPayment.objects.bulk_create(created, ignore_conflicts=True)
        if changed:
            # Always in id order, so two readers updating overlapping pages
            # take their row locks in the same order and cannot deadlock.
            changed.sort(key=lambda row: row.pk)
            ProviderPayment.objects.bulk_update(
                changed, [*_REFRESHED_FIELDS, "cost", "last_seen_at", "updated_at"]
            )
    return len(rows)


_REFRESHED_FIELDS = (
    "paid_at",
    "amount",
    "balance_after",
    "subscriber_ref",
    "subscriber_key",
    "operator_name",
    "status",
    "status_label",
    "payment_type",
    "extra",
    "comment",
)


def _fields_of(payment) -> dict:
    return {
        "paid_at": payment.at,
        "amount": payment.amount,
        "balance_after": payment.balance_after,
        "subscriber_ref": (payment.subscriber_ref or "")[:64],
        "subscriber_key": subscriber_key(payment.subscriber_ref),
        "operator_name": (payment.operator_name or "")[:120],
        "status": (payment.status or "")[:32],
        "status_label": (payment.status_label or "")[:64],
        "payment_type": (payment.payment_type or "")[:32],
        "extra": (payment.extra or "")[:32],
        "comment": (payment.comment or "")[:255],
        "updated_at": timezone.now(),
    }


# --- the sweep --------------------------------------------------------------
def sweep_all(*, now=None) -> dict:
    """Keep every report's mirror current, and deepen a young one. Never raises.

    Half-hourly: one walk down to where the last one began — a page, for a
    shop's half hour — so the till's history and a manager's day are a page
    away rather than a morning away. While the mirror is shallower than
    ``KEEP_WINDOW`` it is also walked deeper, at most every ``DEEPEN_EVERY``,
    and left alone for ``DEEPEN_BACKOFF`` once a walk runs out of pages
    before getting there: that is as deep as this report will be kept.
    """
    now = now or timezone.now()
    results = []
    for account in IntegrationAccount.objects.filter(is_active=True):
        if not supports_payment_report(account) or not account.is_configured:
            continue
        lock = _SWEEP_LOCK.format(account=account.pk)
        if not _acquire(lock):
            results.append({"provider": account.provider, "skipped": True})
            continue
        try:
            head = sync(account, max_pages=SWEEP_PAGES, now=now)
            outcome = {
                "provider": account.provider,
                "ok": head.ok,
                "pages": head.pages,
                "error_code": head.error_code,
            }
            if head.ok and _wants_deepening(account, now=now):
                deeper = sync(
                    account,
                    back_to=now - KEEP_WINDOW,
                    max_pages=SWEEP_PAGES,
                    now=now,
                )
                _remember_deepening(account, deeper, now=now)
                outcome["deepened"] = {
                    "ok": deeper.ok,
                    "pages": deeper.pages,
                    "complete": deeper.complete,
                }
            results.append(outcome)
        except Exception:  # noqa: BLE001 - one report must not stop the rest
            logger.exception("payments report sweep crashed for %s", account.provider)
            results.append({"provider": account.provider, "ok": False})
        finally:
            _release(lock)
    return {"accounts": results}


def _wants_deepening(account, *, now) -> bool:
    since = account.payments_covered_since
    if since is not None and since <= now - KEEP_WINDOW + timedelta(days=1):
        return False
    try:
        not_before = cache.get(_DEEPENED_KEY.format(account=account.pk))
    except Exception:  # noqa: BLE001 - no cache: deepen, at worst too often
        not_before = None
    return not_before is None or now >= not_before


def _remember_deepening(account, result: SyncResult, *, now) -> None:
    wait = DEEPEN_EVERY if (not result.ok or result.complete) else DEEPEN_BACKOFF
    try:
        cache.set(
            _DEEPENED_KEY.format(account=account.pk),
            now + wait,
            int(wait.total_seconds()),
        )
    except Exception:  # noqa: BLE001
        pass


def _acquire(key: str) -> bool:
    try:
        return bool(cache.add(key, 1, _SWEEP_LOCK_SECONDS))
    except Exception:  # noqa: BLE001 - no cache: run; overlap only wastes reads
        return True


def _release(key: str) -> None:
    try:
        cache.delete(key)
    except Exception:  # noqa: BLE001
        pass


# --- asking the mirror ------------------------------------------------------
def day_bounds(day: date) -> tuple[datetime, datetime]:
    """One shop-local day as a half-open UTC stretch ``[start, end)``.

    The report prints the shop's own wall clock, and "today's payments" means
    the shop's today — a payment at 01:30 Tripoli time belongs to the day it
    was made in Tripoli, not to the UTC day before it.
    """
    zone = business_timezone()
    start = datetime.combine(day, time.min, tzinfo=zone)
    end = datetime.combine(day + timedelta(days=1), time.min, tzinfo=zone)
    return start.astimezone(dt_timezone.utc), end.astimezone(dt_timezone.utc)


def payments_between(account, start, end):
    return ProviderPayment.objects.filter(
        account=account, paid_at__gte=start, paid_at__lt=end
    ).order_by("-paid_at", "-id")


def covered_from(account, start) -> bool:
    """Whether the mirror holds every payment from ``start`` to its last read.

    "Up to its last read", never "up to now": a read can only vouch for what
    the report printed when it began, which is why a screen built on this
    says *when* the report was read (``payments_synced_at``) rather than
    claiming the present.
    """
    since, until = account.payments_covered_since, account.payments_synced_at
    return since is not None and until is not None and since <= start


def line_history(account, card_no: str, *, limit: int, offset: int) -> HistoryResult:
    """One line's payments, newest first, out of the mirror.

    Reads the head of the report first — a page, normally — so a top-up made
    a minute ago is there. If the provider cannot be reached the mirror still
    answers: every row in it was really printed by the provider. Only a line
    the mirror knows nothing about, with the provider unreachable, is an
    error rather than "no history" — that would be a guess.
    """
    fresh = sync(account, max_pages=INTERACTIVE_PAGES)
    rows = ProviderPayment.objects.filter(
        account=account, subscriber_key=subscriber_key(card_no)
    ).order_by("-paid_at", "-id")
    total = rows.count()
    if not fresh.ok and total == 0:
        return HistoryResult(
            ok=False, error_code=fresh.error_code, error_detail=fresh.error_detail
        )
    mine = (account.username or "").strip().casefold()
    return HistoryResult(
        ok=True,
        total=total,
        purchases=tuple(
            PurchaseEntry(
                reference=row.reference,
                cost=row.cost,
                at=row.paid_at,
                operator_name=row.operator_name,
                is_ours=not mine or row.operator_name.strip().casefold() == mine,
                amount=row.amount,
                status=row.status,
            )
            for row in rows[offset : offset + limit]
        ),
    )
