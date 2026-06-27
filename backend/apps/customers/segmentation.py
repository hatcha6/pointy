"""RFM (recency / frequency / monetary) customer segmentation.

Run nightly by the ``customers.recompute_customer_segments`` Celery task (see
``apps.customers.tasks``). For every customer we measure three things from their
*recognized* sales history:

* **Recency**  — days since their last committed sale (smaller is better).
* **Frequency**— how many committed sales they have made.
* **Monetary** — net spend (committed sale totals less returns).

Each axis is scored 1–5 by quintile *relative to the rest of the purchasing
base*, so the scoring self-calibrates to the shop — a "5" always means "top 20%
of this shop's customers", whatever the absolute numbers are. The (R, F, M)
triple is then mapped onto a named rank via a fixed grid that fully partitions
the 5×5 score space, so every scored customer lands in exactly one rank and the
result is deterministic and explainable.

Money/quantity definitions deliberately mirror ``Customer.sales_summary`` so the
segmentation agrees with what a manager sees on a customer's profile:
``committed_sales()`` is the recognized-revenue set (paid standard orders + open
or paid credit invoices, never quotations or voids), and RETURN adjustments are
netted out of monetary value.
"""

import bisect
import math
from collections import defaultdict
from decimal import Decimal

from django.db import transaction
from django.db.models import Count, Max, Sum
from django.utils import timezone

from apps.sales.models import Order, OrderAdjustment

from .models import Customer

Rank = Customer.Rank

ZERO = Decimal("0.00")
SCORE_BUCKETS = 5

# Fields written back by a recompute, in one place so the reset path and the
# bulk_update stay in lock-step.
_RFM_FIELDS = (
    "rfm_segment",
    "rfm_recency_score",
    "rfm_frequency_score",
    "rfm_monetary_score",
    "rfm_score",
    "rfm_recency_days",
    "rfm_frequency",
    "rfm_monetary",
    "rfm_last_purchase_at",
    "rfm_calculated_at",
)

# Rank grid indexed by recency score (rows, 1–5) then combined frequency-monetary
# score (columns, 1–5). It covers all 25 cells, so a scored customer always maps
# to exactly one rank. Read a row as "given how recently they bought, how much
# they buy/spend decides the rank".
_SEGMENT_GRID = {
    5: [Rank.NEW, Rank.PROMISING, Rank.POTENTIAL_LOYALIST, Rank.LOYAL, Rank.CHAMPION],
    4: [Rank.NEW, Rank.PROMISING, Rank.POTENTIAL_LOYALIST, Rank.LOYAL, Rank.CHAMPION],
    3: [
        Rank.NEEDS_ATTENTION,
        Rank.NEEDS_ATTENTION,
        Rank.POTENTIAL_LOYALIST,
        Rank.LOYAL,
        Rank.LOYAL,
    ],
    2: [
        Rank.AT_RISK,
        Rank.AT_RISK,
        Rank.NEEDS_ATTENTION,
        Rank.CANT_LOSE,
        Rank.CANT_LOSE,
    ],
    1: [Rank.LOST, Rank.HIBERNATING, Rank.AT_RISK, Rank.CANT_LOSE, Rank.CANT_LOSE],
}


def _clamp_score(value):
    return min(SCORE_BUCKETS, max(1, value))


def _percentile_scorer(values):
    """Build ``f(value) -> 1..SCORE_BUCKETS`` ranking ascending (bigger = higher).

    Scores by quantile so the buckets are population-relative and tie-tolerant:
    a value sitting at the 80th percentile scores 4, the top quantile scores 5.
    Returns ``None`` when there is nothing to score against.
    """
    ordered = sorted(values)
    n = len(ordered)
    if n == 0:
        return None

    def score(value):
        # Count of values <= ``value`` (1..n), turned into a 1..5 quantile bucket.
        rank = bisect.bisect_right(ordered, value)
        return _clamp_score(math.ceil(rank / n * SCORE_BUCKETS))

    return score


def _segment_for(recency_score, frequency_score, monetary_score):
    """Map an (R, F, M) score triple onto a named rank."""
    combined = _clamp_score(round((frequency_score + monetary_score) / 2))
    return _SEGMENT_GRID[recency_score][combined - 1]


def _collect_metrics(reference_time):
    """Per-customer raw RFM inputs for everyone with a recognized purchase.

    Returns ``{customer_id: {frequency, monetary, last_purchase, recency_days}}``.
    """
    sales_rows = (
        Order.objects.committed_sales()
        .filter(customer_id__isnull=False)
        .values("customer_id")
        .annotate(
            frequency=Count("id"),
            gross=Sum("total"),
            last_purchase=Max("created_at"),
        )
    )
    # RETURN adjustments shrink monetary value. VOID adjustments belong to orders
    # that committed_sales() already excludes (the order itself is VOID), so they
    # must NOT be subtracted again here.
    returns_rows = (
        OrderAdjustment.objects.filter(
            adjustment_type=OrderAdjustment.AdjustmentType.RETURN,
            order__customer_id__isnull=False,
        )
        .values("order__customer_id")
        .annotate(returned=Sum("amount"))
    )
    returns_map = {
        row["order__customer_id"]: (row["returned"] or ZERO) for row in returns_rows
    }

    metrics = {}
    for row in sales_rows:
        customer_id = row["customer_id"]
        gross = row["gross"] or ZERO
        net = gross - returns_map.get(customer_id, ZERO)
        if net < ZERO:
            net = ZERO
        last_purchase = row["last_purchase"]
        recency_days = (
            max((reference_time - last_purchase).days, 0) if last_purchase else None
        )
        metrics[customer_id] = {
            "frequency": row["frequency"],
            "monetary": net,
            "last_purchase": last_purchase,
            "recency_days": recency_days,
        }
    return metrics


def _score_metrics(metrics):
    """Annotate each customer's metrics in-place with R/F/M scores and a rank."""
    recency_scorer = _percentile_scorer(
        [m["recency_days"] for m in metrics.values() if m["recency_days"] is not None]
    )
    frequency_scorer = _percentile_scorer([m["frequency"] for m in metrics.values()])
    monetary_scorer = _percentile_scorer([m["monetary"] for m in metrics.values()])

    for entry in metrics.values():
        # Recency is "smaller is better", so invert the ascending quantile score.
        if entry["recency_days"] is None or recency_scorer is None:
            recency = 1
        else:
            recency = SCORE_BUCKETS + 1 - recency_scorer(entry["recency_days"])
        frequency = frequency_scorer(entry["frequency"]) if frequency_scorer else 1
        monetary = monetary_scorer(entry["monetary"]) if monetary_scorer else 1
        entry["recency_score"] = recency
        entry["frequency_score"] = frequency
        entry["monetary_score"] = monetary
        entry["total_score"] = recency + frequency + monetary
        entry["segment"] = _segment_for(recency, frequency, monetary)


def _apply_to_customer(customer, entry, reference_time):
    """Copy a scored ``entry`` (or a reset) onto an unsaved ``customer``."""
    if entry is None:
        customer.rfm_segment = Rank.INACTIVE
        customer.rfm_recency_score = 0
        customer.rfm_frequency_score = 0
        customer.rfm_monetary_score = 0
        customer.rfm_score = 0
        customer.rfm_recency_days = None
        customer.rfm_frequency = 0
        customer.rfm_monetary = ZERO
        customer.rfm_last_purchase_at = None
    else:
        customer.rfm_segment = entry["segment"]
        customer.rfm_recency_score = entry["recency_score"]
        customer.rfm_frequency_score = entry["frequency_score"]
        customer.rfm_monetary_score = entry["monetary_score"]
        customer.rfm_score = entry["total_score"]
        customer.rfm_recency_days = entry["recency_days"]
        customer.rfm_frequency = entry["frequency"]
        customer.rfm_monetary = entry["monetary"]
        customer.rfm_last_purchase_at = entry["last_purchase"]
    customer.rfm_calculated_at = reference_time


@transaction.atomic
def recompute_customer_segments(*, reference_time=None, batch_size=500):
    """Recompute the RFM rank for **every** customer and persist it.

    Idempotent: running it twice over the same data yields the same ranks.
    Customers with no recognized purchase are reset to ``INACTIVE`` so a customer
    who returns everything, or whose only orders get voided, doesn't keep a stale
    rank. Writes happen through batched ``bulk_update`` (no per-row ``save``), so
    the model's ``full_clean`` is intentionally skipped — every value written
    here is machine-generated and already valid.

    Returns a summary dict (counts per rank) suitable for logging / task result.
    """
    reference_time = reference_time or timezone.now()

    metrics = _collect_metrics(reference_time)
    _score_metrics(metrics)

    segment_counts = defaultdict(int)
    updated = 0
    batch = []
    # iterator() keeps memory flat on large bases; bulk_update only touches rows
    # by pk and never the ordering columns, so the snapshot we iterate is stable.
    for customer in Customer.objects.all().iterator(chunk_size=batch_size):
        _apply_to_customer(customer, metrics.get(customer.pk), reference_time)
        segment_counts[customer.rfm_segment] += 1
        batch.append(customer)
        if len(batch) >= batch_size:
            Customer.objects.bulk_update(batch, _RFM_FIELDS, batch_size=batch_size)
            updated += len(batch)
            batch = []
    if batch:
        Customer.objects.bulk_update(batch, _RFM_FIELDS, batch_size=batch_size)
        updated += len(batch)

    return {
        "customers_updated": updated,
        "purchasers": len(metrics),
        "reference_time": reference_time.isoformat(),
        "segments": {segment: segment_counts[segment] for segment in sorted(segment_counts)},
    }
