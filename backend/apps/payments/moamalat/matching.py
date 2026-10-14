"""Reading the terminal's transactions and matching card payments to them.

A card payment is **verified** once a Moamalat transaction is linked to it,
**pending verification** while it waits for one, and never anything a sale can
fail on. Verification is a link beside the payment, never a change to it: the
money position, the drawer and the clearing account read the payment exactly
as they did (``card-settlement-moamalat``).

Matching, in order of strength:

1. the slip's reference number (RRN), when the cashier scanned the receipt —
   exact, and the transaction then also proves the slip genuine;
2. otherwise the same amount on a sale within the time window around the
   payment, restricted to the slip's terminal when there is one, nearest first.

The RRN is unique, so one transaction proves at most one payment.

⚠ The transaction list filters on the PROCESSING (settlement) date, not the
swipe date. Live verification assumes a fresh sale is listed with a processing
date inside the forward window below. Unproven until one real sale is watched
(``TOKEN_CUSTODY_DESIGN.md`` §Verification); if it is not, nothing breaks —
payments wait as pending until their batch settles and the sweep finds them.
"""

from __future__ import annotations

import logging
from dataclasses import dataclass
from datetime import timedelta
from decimal import ROUND_HALF_UP, Decimal

from django.db import transaction
from django.db.models import Q
from django.utils import timezone

from apps.core.timeutils import business_local_date

from . import custody, portal

logger = logging.getLogger(__name__)

#: A swipe this long before the payment was recorded can be its proof (the
#: cashier swipes, then confirms), or this long after (a slow terminal clock).
MATCH_BEFORE = timedelta(minutes=30)
MATCH_AFTER = timedelta(minutes=15)
#: The processing-date window of a live read: settled yesterday through a week
#: ahead, where a sale rung up today will settle.
LIVE_BACK_DAYS = 1
LIVE_AHEAD_DAYS = 7
#: The portal refuses a range over 30 days.
MAX_RANGE_DAYS = 29
#: A sweep looks back this far for pending payments.
SWEEP_LOOKBACK = timedelta(days=21)

VERIFIED = "verified"
PENDING = "pending"


@dataclass
class FetchResult:
    ok: bool = False
    seen: int = 0
    new: int = 0
    matched: int = 0


def _cents(value) -> Decimal:
    return Decimal(value).quantize(Decimal("0.01"), rounding=ROUND_HALF_UP)


def pending_payments(link=None):
    """Card payments still waiting for their transaction."""
    from apps.documents.statuses import DocumentStatus
    from apps.payments.models import Payment

    link = link or custody.load_link()
    if link.state == link.State.UNLINKED or link.verify_since is None:
        return Payment.objects.none()
    return Payment.objects.filter(
        method=Payment.Method.CARD,
        amount__gt=0,
        paid_at__gte=link.verify_since,
        moamalat_transaction__isnull=True,
    ).exclude(doc_status=DocumentStatus.CANCELLED)


def verification_state(payment, link) -> str | None:
    """``verified`` / ``pending`` / None (not a payment this checks)."""
    if payment.method != payment.Method.CARD or payment.amount <= 0:
        return None
    if getattr(payment, "moamalat_transaction", None) is not None:
        return VERIFIED
    if (
        link is None
        or link.state == link.State.UNLINKED
        or link.verify_since is None
        or payment.paid_at < link.verify_since
        or payment.is_cancelled
    ):
        return None
    return PENDING


# -- reading -------------------------------------------------------------------


def fetch_live(link=None) -> FetchResult:
    """The fast read while a checkout is open: the first and last page of the
    live window (newest rows sit at one end, whichever order the portal
    keeps). It is an authenticated call, so it doubles as the keepalive."""
    link = link or custody.load_link()
    today = business_local_date()
    return _fetch(
        link,
        processed_from=today - timedelta(days=LIVE_BACK_DAYS),
        processed_to=today + timedelta(days=LIVE_AHEAD_DAYS),
        all_pages=False,
    )


def fetch_sweep(link=None) -> FetchResult:
    """Every page back to the oldest pending payment (bounded): catches what
    the live read missed, and everything left pending while the token was
    dead."""
    link = link or custody.load_link()
    today = business_local_date()
    oldest = (
        pending_payments(link)
        .filter(paid_at__gte=timezone.now() - SWEEP_LOOKBACK)
        .order_by("paid_at")
        .values_list("paid_at", flat=True)
        .first()
    )
    processed_to = today + timedelta(days=LIVE_AHEAD_DAYS)
    start = business_local_date(oldest) if oldest else today - timedelta(days=LIVE_BACK_DAYS)
    processed_from = max(start, processed_to - timedelta(days=MAX_RANGE_DAYS))
    return _fetch(link, processed_from=processed_from, processed_to=processed_to, all_pages=True)


def _fetch(link, *, processed_from, processed_to, all_pages) -> FetchResult:
    result = FetchResult()
    token = custody.token_of(link)
    if link.state != link.State.ALIVE or not token or not link.mid:
        return result
    rows = []

    def read(token_value):
        first = portal.transactions(
            token_value, link.mid, processed_from=processed_from, processed_to=processed_to, page=1
        )
        rows.extend(first.rows)
        last = first.pages
        wanted = range(2, last + 1) if all_pages else ([last] if last > 1 else [])
        for page in wanted:
            rows.extend(
                portal.transactions(
                    token_value,
                    link.mid,
                    processed_from=processed_from,
                    processed_to=processed_to,
                    page=page,
                ).rows
            )

    from apps.payments.models import MoamalatLink

    outcome = custody.poke(link, call=read)
    now = timezone.now()
    if outcome != portal.ALIVE:
        MoamalatLink.objects.filter(pk=1).update(
            last_fetch_at=now, last_fetch_error=(link.last_error or outcome)[:300]
        )
        return result
    result.ok = True
    result.seen = len(rows)
    result.new = store_transactions(rows, mid=link.mid)
    result.matched = match_pending(link)
    MoamalatLink.objects.filter(pk=1).update(last_fetch_at=now, last_fetch_error="")
    return result


def store_transactions(rows, *, mid="") -> int:
    """Upsert by RRN; a row seen again may now carry its settlement."""
    from apps.payments.models import MoamalatTransaction

    created = 0
    for row in rows:
        _, was_created = MoamalatTransaction.objects.update_or_create(
            rrn=row.rrn,
            defaults={
                "mid": mid,
                "terminal_id": row.terminal_id,
                "amount": row.amount,
                "transaction_at": row.transaction_at,
                "processing_date": row.processing_date,
                "settlement_amount": row.settlement_amount,
                "transaction_type": row.transaction_type,
                "card_mask": row.card_mask,
            },
        )
        created += int(was_created)
    return created


# -- matching ------------------------------------------------------------------


def _slip_reference(payment) -> str:
    data = payment.card_receipt_data or {}
    raw = data.get("raw_fields") if isinstance(data.get("raw_fields"), dict) else {}
    for value in (data.get("rrn"), raw.get("RRN")):
        if value:
            return str(value).strip()
    return ""


def _slip_terminal(payment) -> str:
    from apps.payments.card_receipts.ocr import normalize_terminal_id

    data = payment.card_receipt_data or {}
    raw = data.get("terminal_id") or ""
    return normalize_terminal_id(str(raw)) if raw else ""


def match_pending(link=None) -> int:
    """Link every pending payment it can to an unclaimed transaction."""
    from apps.payments.models import MoamalatTransaction

    link = link or custody.load_link()
    matched = 0
    open_rows = MoamalatTransaction.objects.filter(payment__isnull=True).exclude(
        transaction_type__iexact="refund"
    )
    if not open_rows.exists():
        return 0
    for payment in pending_payments(link).order_by("paid_at", "pk"):
        candidate = _best_candidate(payment, open_rows)
        if candidate is None:
            continue
        with transaction.atomic():
            # Claimed only if still unclaimed: two workers never give one
            # transaction to two payments (the column is also unique).
            claimed = MoamalatTransaction.objects.filter(
                pk=candidate.pk, payment__isnull=True
            ).update(payment=payment, matched_at=timezone.now())
        matched += claimed
    if matched:
        logger.info("moamalat: verified %s card payment(s)", matched)
    return matched


def _best_candidate(payment, open_rows):
    reference = _slip_reference(payment)
    if reference:
        exact = open_rows.filter(rrn=reference).first()
        if exact is not None:
            return exact
    amount = _cents(payment.amount)
    window = open_rows.filter(
        transaction_at__gte=payment.paid_at - MATCH_BEFORE,
        transaction_at__lte=payment.paid_at + MATCH_AFTER,
        # Stored to the dirham; a payment is to the cent.
        amount__gte=amount - Decimal("0.005"),
        amount__lt=amount + Decimal("0.005"),
    )
    terminal = _slip_terminal(payment)
    if terminal:
        window = window.filter(Q(terminal_id=terminal) | Q(terminal_id=""))
    candidates = list(window[:20])
    if not candidates:
        return None
    return min(candidates, key=lambda row: abs((row.transaction_at - payment.paid_at).total_seconds()))


def recent_unclaimed(*, since, amount=None):
    """Transactions the terminal took lately that no payment claims yet: what a
    till watching a checkout shows as 'the card went through'."""
    from apps.payments.models import MoamalatTransaction

    rows = MoamalatTransaction.objects.filter(
        payment__isnull=True, transaction_at__gte=since
    ).exclude(transaction_type__iexact="refund")
    if amount is not None:
        cents = _cents(amount)
        rows = rows.filter(amount__gte=cents - Decimal("0.005"), amount__lt=cents + Decimal("0.005"))
    return rows.order_by("-transaction_at")[:10]


#: A payment gets this long to be matched before a different-amount swipe
#: beside it counts as a mistake (the read may simply not have run yet).
MISMATCH_GRACE = timedelta(minutes=2)
MISMATCH_LOOKBACK = timedelta(days=3)


def amount_mismatches(link=None, now=None):
    """Pending card payments whose only nearby swipe is for another amount.

    The terminal took one figure and the till recorded another: the payment
    will never match by itself, and the shop is short or over by the
    difference. Said within minutes rather than when the payment is days
    overdue. Returns ``[(payment, transaction), ...]``, oldest first.
    """
    from apps.payments.models import MoamalatTransaction

    link = link or custody.load_link()
    now = now or timezone.now()
    open_rows = MoamalatTransaction.objects.filter(payment__isnull=True).exclude(
        transaction_type__iexact="refund"
    )
    found = []
    pending = (
        pending_payments(link)
        .filter(paid_at__gte=now - MISMATCH_LOOKBACK, paid_at__lte=now - MISMATCH_GRACE)
        .order_by("paid_at")[:50]
    )
    for payment in pending:
        cents = _cents(payment.amount)
        near = (
            open_rows.filter(
                transaction_at__gte=payment.paid_at - MATCH_BEFORE,
                transaction_at__lte=payment.paid_at + MATCH_AFTER,
            )
            .exclude(amount__gte=cents - Decimal("0.005"), amount__lt=cents + Decimal("0.005"))
            .order_by("transaction_at")
            .first()
        )
        if near is not None:
            found.append((payment, near))
    return found
