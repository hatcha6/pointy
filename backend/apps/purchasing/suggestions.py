"""Purchase suggestions: the products and quantities a shop habitually buys.

A Libyan shop's purchase orders repeat. The same supplier arrives, the same
twenty products get typed, in roughly the same sequence, in the same quantities.
Everything in this module exists to turn that repetition into two offers on the
purchasing screen — *which product next* and *how many* — and to stay silent
whenever the shop's own history does not actually support an answer.

Two halves:

* **The rebuild** (:func:`rebuild_supplier_suggestions`) reads a supplier's
  recent purchase orders and writes three denormalized tables — a per-supplier
  profile, a habit row per (supplier, product) and a bounded set of affinity
  pairs. It runs in a worker: nightly for every supplier, and per supplier the
  moment one of its orders is submitted, received or edited.
* **The read** (:func:`suggestions_for_draft`) ranks those rows against the draft
  the buyer is looking at, in a handful of indexed queries. It never aggregates
  ``PurchaseLine`` — that read pattern is what made the purchases list hang at
  12K orders, and this one runs on every draft mutation.

The thresholds below are the whole design. A purchase quantity becomes stock and
becomes cost basis, so a suggestion that is merely plausible is worse than no
suggestion at all: every one of these floors exists to make the feature shut up
rather than guess.
"""

import logging
from collections import Counter, defaultdict
from datetime import timedelta
from decimal import Decimal
from statistics import fmean, pstdev

from django.db import transaction
from django.utils import timezone

from .models import (
    PurchaseLine,
    PurchaseOrder,
    Supplier,
    SupplierPurchaseAffinity,
    SupplierPurchaseHabit,
    SupplierPurchaseProfile,
)

logger = logging.getLogger(__name__)

# --- Evidence selection -----------------------------------------------------

# Only orders the shop actually committed to. A cancelled order is not evidence,
# and neither is a DRAFT: an abandoned draft is the buyer changing their mind,
# and feeding it back would let the feature reinforce its own bad guesses.
EVIDENCE_STATUSES = (
    PurchaseOrder.Status.SUBMITTED,
    PurchaseOrder.Status.PARTIALLY_RECEIVED,
    PurchaseOrder.Status.RECEIVED,
)

# Three quarters: long enough for a monthly restock cycle to appear ~9 times,
# short enough to forget a line the shop stopped carrying.
WINDOW_DAYS = 270

# Recency half-life. Last month's basket counts roughly four times what a basket
# from six months ago counts, so a supplier whose range changed drifts onto the
# new range by itself instead of needing a manual reset.
HALF_LIFE_DAYS = 60.0

# Per-supplier evidence cap, so one enormous supplier cannot make the rebuild
# unbounded. The most recent orders are the ones kept.
MAX_ORDERS = 400

# --- Support floors ---------------------------------------------------------

# No pair is ever suggested on fewer than this many shared orders.
MIN_TOGETHER = 3
# ...nor below this recency-weighted P(neighbour | anchor).
MIN_CONFIDENCE = 0.35
# Neighbours kept per anchor, and anchors kept per supplier. Both bound the
# affinity table by construction rather than by hoping it stays small.
MAX_NEIGHBOURS = 12
MAX_ANCHORS = 2000

# Quantity hints: at least this many recent purchases, of which at least this
# share must be for the *same exact* quantity in the same unit.
MIN_QUANTITY_SAMPLES = 3
QUANTITY_SAMPLE_SIZE = 8
MIN_QUANTITY_CONFIDENCE = 0.5

# "Due again": a cadence is only predictable with this many orders behind it and
# this little variation between the gaps (stdev / mean).
MIN_CADENCE_ORDERS = 4
MAX_INTERVAL_CV = 0.5
# Offer it slightly before the average gap elapses — a buyer standing in front of
# the supplier wants the reminder now, not next week.
DUE_FACTOR = 0.9

# The "usual order" basket: products present on at least this weighted share of
# the supplier's orders, capped so one tap can never dump a thousand lines.
USUAL_BASKET_MIN_PRESENCE = 0.7
USUAL_BASKET_MAX_LINES = 60

# Read-time floors.
MIN_SCORE = 0.25
MAX_STALE_DAYS = 120
DEFAULT_LIMIT = 8

# Baskets up to this many lines pair every product with every other. Longer ones
# pair only within a sliding window of entry position: it bounds a 200-line
# restock (which would otherwise emit ~40k pairs) and is the more faithful
# signal anyway — in a long order "what comes next" is a local property of the
# buyer's walk down the invoice, not of the whole document.
FULL_PAIR_MAX_LINES = 40
SEQUENCE_WINDOW = 12

# Scoring weights.
BASELINE_WEIGHT = 0.5
DUE_BASE_SCORE = 0.55
DUE_MAX_BONUS = 0.2
SEQUENCE_BONUS = 1.15
SEQUENCE_LOOKAHEAD = 0.25


def decay(age_days, *, half_life=HALF_LIFE_DAYS):
    """Recency weight for evidence ``age_days`` old (1.0 today, 0.5 at the
    half-life). Clamped at zero age so clock skew cannot inflate a basket."""
    return 0.5 ** (max(age_days, 0.0) / half_life)


# --- Rebuild ----------------------------------------------------------------


def _basket_rows(supplier_id, since):
    """The supplier's recent orders as ``[(order_id, ordered_at, [line, ...])]``,
    newest order first and each order's lines in the buyer's entry order.

    Two queries regardless of how many orders come back.
    """
    orders = list(
        PurchaseOrder.objects.filter(
            supplier_id=supplier_id,
            status__in=EVIDENCE_STATUSES,
            created_at__gte=since,
        )
        .order_by("-created_at", "-id")
        .values_list("id", "created_at")[:MAX_ORDERS]
    )
    if not orders:
        return []

    ordered_at_by_id = dict(orders)
    lines_by_order = defaultdict(list)
    line_rows = (
        PurchaseLine.objects.filter(purchase_order_id__in=ordered_at_by_id)
        # ``PurchaseLine.Meta.ordering`` is created_at — that ordering IS the
        # buyer's entry sequence, which is the only reason a "next product"
        # signal exists at all.
        .order_by("purchase_order_id", "created_at", "id")
        .values_list(
            "purchase_order_id",
            "variant_id",
            "quantity",
            "unit",
            "unit_factor",
            "unit_cost",
        )
    )
    for order_id, variant_id, quantity, unit, unit_factor, unit_cost in line_rows.iterator():
        lines_by_order[order_id].append(
            {
                "variant_id": variant_id,
                "quantity": quantity,
                "unit": unit or "",
                "unit_factor": unit_factor or Decimal("1"),
                "unit_cost": unit_cost,
            }
        )

    baskets = []
    for order_id, ordered_at in orders:
        lines = lines_by_order.get(order_id)
        if not lines:
            continue
        # One entry per variant: a duplicated line (imported history does this)
        # must not count as two orders' worth of evidence. First occurrence wins,
        # so entry position stays the position the buyer actually typed it at.
        seen = set()
        deduped = []
        for line in lines:
            if line["variant_id"] in seen:
                continue
            seen.add(line["variant_id"])
            deduped.append(line)
        baskets.append((order_id, ordered_at, deduped))
    return baskets


def _base_unit_cost(unit_cost, unit_factor):
    """``unit_cost`` per base unit — the same definition
    ``PurchaseLine.base_unit_cost`` and the last-cost endpoint use, so a seeded
    client cache and a fetched one can never disagree."""
    factor = unit_factor or Decimal("1")
    if factor <= 0:
        return unit_cost
    return (Decimal(unit_cost) / Decimal(factor)).quantize(Decimal("0.01"))


def _typical_quantity(samples):
    """The habitual quantity from recent purchases, or ``(None, "", 1, 0.0)``.

    ``samples`` arrives newest-first as ``(quantity, unit, unit_factor)``. Only
    the dominant purchase unit is considered — a shop that moved from pieces to
    cartons must never be offered a piece quantity — and only the *exact* mode
    counts. Deliberately not a mean or a median: the mean of 10 and 15 is 12.5,
    a quantity this shop has never once bought. The feature exists because shops
    repeat themselves exactly; where they do not, it says nothing.
    """
    recent = samples[:QUANTITY_SAMPLE_SIZE]
    if len(recent) < MIN_QUANTITY_SAMPLES:
        return None, "", Decimal("1"), 0.0

    unit_counts = Counter((unit, factor) for _quantity, unit, factor in recent)
    (unit, factor), _unit_hits = unit_counts.most_common(1)[0]
    in_unit = [
        quantity
        for quantity, sample_unit, sample_factor in recent
        if (sample_unit, sample_factor) == (unit, factor)
    ]
    if len(in_unit) < MIN_QUANTITY_SAMPLES:
        return None, "", Decimal("1"), 0.0

    quantity, hits = Counter(in_unit).most_common(1)[0]
    confidence = hits / len(in_unit)
    if confidence < MIN_QUANTITY_CONFIDENCE:
        return None, "", Decimal("1"), 0.0
    return quantity, unit, factor, confidence


def _cadence(order_dates):
    """``(avg_interval_days, interval_cv)`` for a variant's order dates, or
    ``(None, None)`` when there is not enough of a rhythm to call one."""
    if len(order_dates) < MIN_CADENCE_ORDERS:
        return None, None
    ordered = sorted(order_dates)
    gaps = [
        (later - earlier).total_seconds() / 86400.0
        for earlier, later in zip(ordered, ordered[1:])
    ]
    gaps = [gap for gap in gaps if gap > 0]
    if len(gaps) < MIN_CADENCE_ORDERS - 1:
        return None, None
    mean = fmean(gaps)
    if mean <= 0:
        return None, None
    return mean, pstdev(gaps) / mean


def _pair_positions(count):
    """Index pairs to count within one basket of ``count`` lines."""
    if count <= FULL_PAIR_MAX_LINES:
        for first in range(count):
            for second in range(count):
                if first != second:
                    yield first, second
        return
    for first in range(count):
        low = max(0, first - SEQUENCE_WINDOW)
        high = min(count, first + SEQUENCE_WINDOW + 1)
        for second in range(low, high):
            if first != second:
                yield first, second


@transaction.atomic
def rebuild_supplier_suggestions(supplier_id, *, reference_time=None, window_days=WINDOW_DAYS):
    """Recompute one supplier's profile, habits and affinities from scratch.

    Idempotent: the tables are pure derived caches, so the rows are replaced
    wholesale rather than reconciled. Returns a summary dict for logging.
    """
    reference_time = reference_time or timezone.now()
    since = reference_time - timedelta(days=window_days)
    baskets = _basket_rows(supplier_id, since)

    habits = {}
    order_dates = defaultdict(list)
    quantity_samples = defaultdict(list)
    pair_weights = Counter()
    pair_counts = Counter()
    weighted_orders = 0.0

    for _order_id, ordered_at, lines in baskets:
        age_days = (reference_time - ordered_at).total_seconds() / 86400.0
        weight = decay(age_days)
        weighted_orders += weight
        count = len(lines)

        for index, line in enumerate(lines):
            variant_id = line["variant_id"]
            # 0.0 = always typed first, 1.0 = always last. A one-line order has
            # no position to speak of, so it sits in the middle.
            position = index / (count - 1) if count > 1 else 0.5
            habit = habits.get(variant_id)
            if habit is None:
                habit = habits[variant_id] = {
                    "order_count": 0,
                    "weighted_count": 0.0,
                    "position_sum": 0.0,
                    "last_ordered_at": None,
                    "last_base_unit_cost": None,
                }
            habit["order_count"] += 1
            habit["weighted_count"] += weight
            habit["position_sum"] += weight * position
            # Baskets arrive newest-first, so the first sighting is the latest.
            if habit["last_ordered_at"] is None:
                habit["last_ordered_at"] = ordered_at
                habit["last_base_unit_cost"] = _base_unit_cost(
                    line["unit_cost"], line["unit_factor"]
                )
            order_dates[variant_id].append(ordered_at)
            quantity_samples[variant_id].append(
                (line["quantity"], line["unit"], line["unit_factor"])
            )

        for first, second in _pair_positions(count):
            pair = (lines[first]["variant_id"], lines[second]["variant_id"])
            pair_weights[pair] += weight
            pair_counts[pair] += 1

    profile, _created = SupplierPurchaseProfile.objects.get_or_create(
        supplier_id=supplier_id
    )
    SupplierPurchaseHabit.objects.filter(supplier_id=supplier_id).delete()
    SupplierPurchaseAffinity.objects.filter(supplier_id=supplier_id).delete()

    habit_rows = []
    for variant_id, habit in habits.items():
        weighted_count = habit["weighted_count"]
        quantity, unit, factor, quantity_confidence = _typical_quantity(
            quantity_samples[variant_id]
        )
        avg_interval, interval_cv = _cadence(order_dates[variant_id])
        next_due_at = None
        if (
            avg_interval is not None
            and interval_cv is not None
            and interval_cv <= MAX_INTERVAL_CV
            and habit["order_count"] >= MIN_CADENCE_ORDERS
            and habit["last_ordered_at"] is not None
        ):
            next_due_at = habit["last_ordered_at"] + timedelta(
                days=DUE_FACTOR * avg_interval
            )
        habit_rows.append(
            SupplierPurchaseHabit(
                supplier_id=supplier_id,
                variant_id=variant_id,
                order_count=habit["order_count"],
                weighted_count=weighted_count,
                last_ordered_at=habit["last_ordered_at"],
                typical_quantity=quantity,
                typical_unit=unit,
                typical_unit_factor=factor,
                quantity_confidence=quantity_confidence,
                avg_interval_days=avg_interval,
                interval_cv=interval_cv,
                next_due_at=next_due_at,
                avg_position=(
                    habit["position_sum"] / weighted_count if weighted_count else 0.5
                ),
                presence_ratio=(
                    weighted_count / weighted_orders if weighted_orders else 0.0
                ),
                last_base_unit_cost=habit["last_base_unit_cost"],
            )
        )
    SupplierPurchaseHabit.objects.bulk_create(habit_rows, batch_size=500)

    # Anchors are capped to the supplier's most-bought products: the tail is
    # where the table would grow without bound and where confidence is thinnest.
    anchors = {
        variant_id
        for variant_id, _weight in sorted(
            ((vid, h["weighted_count"]) for vid, h in habits.items()),
            key=lambda row: row[1],
            reverse=True,
        )[:MAX_ANCHORS]
    }
    by_anchor = defaultdict(list)
    for (anchor_id, variant_id), weight in pair_weights.items():
        if anchor_id not in anchors:
            continue
        if pair_counts[(anchor_id, variant_id)] < MIN_TOGETHER:
            continue
        anchor_weight = habits[anchor_id]["weighted_count"]
        if anchor_weight <= 0:
            continue
        confidence = weight / anchor_weight
        if confidence < MIN_CONFIDENCE:
            continue
        by_anchor[anchor_id].append((confidence, variant_id))

    affinity_rows = []
    for anchor_id, neighbours in by_anchor.items():
        neighbours.sort(key=lambda row: (-row[0], row[1]))
        for confidence, variant_id in neighbours[:MAX_NEIGHBOURS]:
            affinity_rows.append(
                SupplierPurchaseAffinity(
                    supplier_id=supplier_id,
                    anchor_variant_id=anchor_id,
                    variant_id=variant_id,
                    together_count=pair_counts[(anchor_id, variant_id)],
                    confidence=min(confidence, 1.0),
                )
            )
    SupplierPurchaseAffinity.objects.bulk_create(affinity_rows, batch_size=500)

    profile.order_count = len(baskets)
    profile.weighted_orders = weighted_orders
    profile.rebuilt_at = reference_time
    profile.version = (profile.version or 0) + 1
    profile.save(
        update_fields=[
            "order_count",
            "weighted_orders",
            "rebuilt_at",
            "version",
            "updated_at",
        ]
    )

    return {
        "supplier_id": supplier_id,
        "orders": len(baskets),
        "habits": len(habit_rows),
        "affinities": len(affinity_rows),
        "version": profile.version,
    }


def rebuild_purchase_suggestions(*, reference_time=None, window_days=WINDOW_DAYS):
    """Rebuild every supplier, and prune suppliers that fell out of the window.

    The nightly pass. Per-supplier refreshes keep the day fresh; this one applies
    recency decay across the board and reclaims rows nothing points at any more.
    """
    reference_time = reference_time or timezone.now()
    since = reference_time - timedelta(days=window_days)

    active_ids = set(
        PurchaseOrder.objects.filter(
            status__in=EVIDENCE_STATUSES,
            created_at__gte=since,
        )
        .values_list("supplier_id", flat=True)
        .distinct()
    )

    summary = {"suppliers": 0, "habits": 0, "affinities": 0, "pruned": 0}
    for supplier_id in sorted(active_ids):
        result = rebuild_supplier_suggestions(
            supplier_id,
            reference_time=reference_time,
            window_days=window_days,
        )
        summary["suppliers"] += 1
        summary["habits"] += result["habits"]
        summary["affinities"] += result["affinities"]

    stale = Supplier.objects.exclude(pk__in=active_ids).values_list("pk", flat=True)
    stale_ids = list(stale)
    if stale_ids:
        deleted, _ = SupplierPurchaseHabit.objects.filter(
            supplier_id__in=stale_ids
        ).delete()
        SupplierPurchaseAffinity.objects.filter(supplier_id__in=stale_ids).delete()
        SupplierPurchaseProfile.objects.filter(supplier_id__in=stale_ids).update(
            order_count=0, weighted_orders=0.0, rebuilt_at=reference_time
        )
        summary["pruned"] = deleted
    return summary


# --- Read -------------------------------------------------------------------


def suggestions_version(supplier_id):
    """The supplier's rebuild counter, for cache keys. 0 when never built."""
    return (
        SupplierPurchaseProfile.objects.filter(supplier_id=supplier_id)
        .values_list("version", flat=True)
        .first()
        or 0
    )


def _live_habits(supplier_id):
    """Habit rows whose product a buyer could actually put on an order today."""
    return SupplierPurchaseHabit.objects.filter(
        supplier_id=supplier_id,
        variant__is_active=True,
        variant__product__is_active=True,
        variant__product__archived_at__isnull=True,
    ).select_related("variant", "variant__product")


def _habit_payload(habit, *, reason, score, confidence=None, anchor_id=None, now):
    variant = habit.variant
    product = variant.product
    quantity = habit.typical_quantity
    unit_cost = None
    if habit.last_base_unit_cost is not None:
        unit_cost = (
            habit.last_base_unit_cost * (habit.typical_unit_factor or Decimal("1"))
        ).quantize(Decimal("0.01"))
    days_since_last = None
    if habit.last_ordered_at is not None:
        days_since_last = int((now - habit.last_ordered_at).total_seconds() // 86400)
    return {
        "variant": variant.id,
        "product": product.id,
        "product_name": product.name,
        "variant_name": variant.name or "",
        "sku": variant.sku,
        "suggested_quantity": quantity,
        "unit": habit.typical_unit or "",
        "unit_factor": habit.typical_unit_factor or Decimal("1"),
        "unit_cost": unit_cost,
        # Per BASE unit, and the same definition the last-cost endpoint returns,
        # so seeding the client's cost cache from here can never disagree with
        # fetching it.
        "base_unit_cost": habit.last_base_unit_cost,
        "reason": reason,
        "reason_variant": anchor_id,
        "score": round(score, 4),
        "evidence": {
            "orders": habit.order_count,
            "days_since_last": days_since_last,
            "confidence": round(
                confidence if confidence is not None else habit.presence_ratio, 4
            ),
        },
    }


def suggestions_for_draft(
    *, supplier_id, anchor_variant_ids=(), limit=DEFAULT_LIMIT, reference_time=None
):
    """Rank what this buyer is most likely to add next, given what is already on
    the draft. Returns ``(items, usual_basket)``.

    Three sources, in descending order of how much the shop's own history
    supports them:

    * ``often_with`` — products that share this supplier's orders with the ones
      already on the draft. Combined across anchors with a noisy-or, so three
      anchors that each point weakly at a product beat one that points strongly.
    * ``due_again`` — products bought from this supplier on a regular cadence
      whose interval has elapsed. This is what fills the strip the instant a
      supplier is chosen, before a single product is typed.
    * ``usual_for_supplier`` — the supplier's most-bought products, as a floor
      when the first two have nothing to say.

    Everything is filtered by :data:`MIN_SCORE`, by :data:`MAX_STALE_DAYS`, and
    by whether the product is still sellable at all.
    """
    now = reference_time or timezone.now()
    anchors = [int(v) for v in anchor_variant_ids if v is not None]
    anchor_set = set(anchors)
    stale_before = now - timedelta(days=MAX_STALE_DAYS)

    # 1. Affinity candidates for everything already on the draft.
    confidences = defaultdict(dict)  # candidate -> {anchor: confidence}
    if anchors:
        rows = SupplierPurchaseAffinity.objects.filter(
            supplier_id=supplier_id,
            anchor_variant_id__in=anchors,
        ).values_list("anchor_variant_id", "variant_id", "confidence")
        for anchor_id, variant_id, confidence in rows:
            if variant_id in anchor_set:
                continue
            confidences[variant_id][anchor_id] = confidence

    # 2. Habit rows for those candidates plus the anchors themselves (the
    #    anchors are only needed for the entry-position tie-breaker).
    wanted = set(confidences) | anchor_set
    habits = {}
    if wanted:
        for habit in _live_habits(supplier_id).filter(variant_id__in=wanted):
            habits[habit.variant_id] = habit

    # 3. Due-again candidates: precomputed at rebuild, so this is an indexed
    #    range scan rather than per-row date arithmetic.
    due = {}
    for habit in (
        _live_habits(supplier_id)
        .filter(next_due_at__isnull=False, next_due_at__lte=now)
        .exclude(variant_id__in=anchor_set)
        .order_by("next_due_at")[: limit * 3]
    ):
        due[habit.variant_id] = habit
        habits.setdefault(habit.variant_id, habit)

    # 4. Baseline, only when the evidence above has not already filled the strip.
    baseline = {}
    if len(confidences) + len(due) < limit:
        for habit in (
            _live_habits(supplier_id)
            .exclude(variant_id__in=anchor_set)
            .order_by("-weighted_count")[: limit * 3]
        ):
            baseline[habit.variant_id] = habit
            habits.setdefault(habit.variant_id, habit)

    max_weighted = max(
        (habit.weighted_count for habit in baseline.values()), default=0.0
    )

    # The entry-position tie-breaker: where in the order the buyer usually is
    # right now. Degrades to nothing on imported history whose lines all share a
    # timestamp (every position collapses to 0.5), which is exactly right.
    last_position = None
    if anchors:
        last_anchor = habits.get(anchors[-1])
        if last_anchor is not None:
            last_position = last_anchor.avg_position

    items = []
    for variant_id, habit in habits.items():
        if variant_id in anchor_set:
            continue
        if habit.last_ordered_at is not None and habit.last_ordered_at < stale_before:
            continue

        scored = []
        by_anchor = confidences.get(variant_id)
        if by_anchor:
            # Noisy-or: independent weak agreement accumulates, and the result
            # stays bounded in [0, 1) so it is comparable with the other sources.
            combined = 1.0
            for confidence in by_anchor.values():
                combined *= 1.0 - min(max(confidence, 0.0), 0.999)
            best_anchor = max(by_anchor, key=by_anchor.get)
            scored.append(
                ("often_with", 1.0 - combined, by_anchor[best_anchor], best_anchor)
            )
        if variant_id in due:
            overdue = 0.0
            if habit.avg_interval_days:
                elapsed = (now - habit.last_ordered_at).total_seconds() / 86400.0
                overdue = min(elapsed / habit.avg_interval_days - DUE_FACTOR, 1.0)
            scored.append(
                (
                    "due_again",
                    DUE_BASE_SCORE + DUE_MAX_BONUS * max(overdue, 0.0),
                    None,
                    None,
                )
            )
        if variant_id in baseline and max_weighted > 0:
            scored.append(
                (
                    "usual_for_supplier",
                    BASELINE_WEIGHT * (habit.weighted_count / max_weighted),
                    None,
                    None,
                )
            )
        if not scored:
            continue

        reason, score, confidence, anchor_id = max(scored, key=lambda row: row[1])
        if (
            last_position is not None
            and last_position < habit.avg_position <= last_position + SEQUENCE_LOOKAHEAD
        ):
            score *= SEQUENCE_BONUS
        if score < MIN_SCORE:
            continue
        items.append(
            _habit_payload(
                habit,
                reason=reason,
                score=min(score, 1.0),
                confidence=confidence,
                anchor_id=anchor_id,
                now=now,
            )
        )

    items.sort(key=lambda item: (-item["score"], item["product_name"], item["variant"]))
    return items[:limit], usual_basket(supplier_id, now=now)


def usual_basket(supplier_id, *, now=None):
    """The products that appear on very nearly every order from this supplier —
    the one-tap "usual order". Empty unless the supplier has enough orders behind
    it for "usual" to mean anything."""
    now = now or timezone.now()
    profile = SupplierPurchaseProfile.objects.filter(supplier_id=supplier_id).first()
    if profile is None or profile.order_count < MIN_CADENCE_ORDERS:
        return {"available": False, "line_count": 0, "items": []}

    habits = (
        _live_habits(supplier_id)
        .filter(
            presence_ratio__gte=USUAL_BASKET_MIN_PRESENCE,
            last_ordered_at__gte=now - timedelta(days=MAX_STALE_DAYS),
        )
        .order_by("avg_position", "-presence_ratio")[:USUAL_BASKET_MAX_LINES]
    )
    items = [
        _habit_payload(
            habit,
            reason="usual_for_supplier",
            score=habit.presence_ratio,
            now=now,
        )
        for habit in habits
    ]
    return {
        "available": bool(items),
        "line_count": len(items),
        "items": items,
    }


def variants_missing_habits(supplier_id, variant_ids):
    """Which of ``variant_ids`` this supplier has no habit row for — used by
    tests and the management command to explain a silent strip."""
    known = set(
        SupplierPurchaseHabit.objects.filter(
            supplier_id=supplier_id, variant_id__in=variant_ids
        ).values_list("variant_id", flat=True)
    )
    return [variant_id for variant_id in variant_ids if variant_id not in known]


__all__ = [
    "cached_suggestions_for_draft",
    "decay",
    "rebuild_purchase_suggestions",
    "rebuild_supplier_suggestions",
    "suggestions_for_draft",
    "suggestions_version",
    "usual_basket",
    "variants_missing_habits",
]


# --- Read cache -------------------------------------------------------------
#
# The purchasing screen asks again on every draft mutation, and the answer only
# changes when the supplier's history changes or a product is renamed/archived.
# So the key carries the supplier's rebuild counter AND the catalog version, and
# the TTL is only a safety net. Fail-open throughout: suggestions are decoration
# and a Redis hiccup must never cost the buyer a keystroke.

_CACHE_KEY = "pointy:purchasing:suggestions:{supplier}:{version}:{catalog}:{digest}"
_CACHE_TTL = 120
_MISS = "__miss__"


def _cache_key(supplier_id, anchors, limit):
    import hashlib

    from apps.catalog.cache import catalog_version

    digest = hashlib.md5(
        f"{sorted(set(anchors))}|{limit}".encode()
    ).hexdigest()[:12]
    return _CACHE_KEY.format(
        supplier=supplier_id,
        version=suggestions_version(supplier_id),
        catalog=catalog_version() or 0,
        digest=digest,
    )


def cached_suggestions_for_draft(
    *, supplier_id, anchor_variant_ids=(), limit=DEFAULT_LIMIT
):
    """:func:`suggestions_for_draft`, memoised per (supplier, draft, catalog)."""
    from django.core.cache import cache

    anchors = [int(v) for v in anchor_variant_ids if v is not None]
    try:
        key = _cache_key(supplier_id, anchors, limit)
        hit = cache.get(key, _MISS)
    except Exception:  # noqa: BLE001 — no cache / Redis down: compute live
        logger.debug("suggestion cache read failed", exc_info=True)
        return suggestions_for_draft(
            supplier_id=supplier_id, anchor_variant_ids=anchors, limit=limit
        )
    if hit is not _MISS:
        return hit

    result = suggestions_for_draft(
        supplier_id=supplier_id, anchor_variant_ids=anchors, limit=limit
    )
    try:
        cache.set(key, result, _CACHE_TTL)
    except Exception:  # noqa: BLE001
        logger.debug("suggestion cache write failed", exc_info=True)
    return result
