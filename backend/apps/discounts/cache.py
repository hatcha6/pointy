"""Redis-backed guard for the discount PREVIEW.

The POS re-runs a discount preview on every cart edit, so a shop with no
discounts — or a cart that resolves to the same result twice while a cashier
types — would otherwise hammer the DB with the engine pass on every keystroke.
Two layers, both **fail-open** (any Redis hiccup falls straight through to a live
DB compute — a cache must never break a sale):

1. **active-rules gate** — if no active rule targets the channel, skip the engine
   and the DB entirely and return an empty result. This is the common case for a
   shop that runs no promotions, and it turns ~9 queries/preview into one Redis
   read.
2. **per-cart result cache** — memoise the ``DiscountCalculationResult`` for a few
   seconds, keyed by the exact cart + customer + coupons + a rules-version stamp,
   so debounced re-previews of an unchanged cart are served from Redis.

Only the PREVIEW uses this. Checkout always recomputes live and re-validates
usage limits under a row lock (``lock_and_validate_usage_limits``), so any
staleness here is cosmetic and self-corrects at the till.

Invalidation is signal-driven (``signals.py``): editing a rule, its targets, its
tiers, or the category tree bumps the rules-version — which both drops the gate
and orphans every per-cart key (they embed the old version and simply expire).
Usage/redemption changes deliberately do NOT invalidate: the short TTL bounds
that staleness, and checkout is the real enforcer.
"""

from __future__ import annotations

import hashlib
import logging
from decimal import Decimal

from django.conf import settings
from django.core.cache import cache
from django.db.models import Q

from .models import DiscountRule
from .services import DiscountCalculationResult, DiscountContext, money

logger = logging.getLogger(__name__)

_VERSION_KEY = "pointy:discounts:rules_version"
_GATE_KEY = "pointy:discounts:active:{channel}"
_RESULT_KEY = "pointy:discounts:preview:{digest}"
_MISS = "__miss__"
_DEFAULT_RESULT_TTL = 15  # seconds — bounds usage/time-window staleness in preview
# Safety net only: normal edits refresh the gate via signals. Kept short so a rare
# bulk .update()/.bulk_create() (which does NOT emit post_save) self-heals fast.
_GATE_TTL = 120


def _result_ttl() -> int:
    return int(getattr(settings, "POINTY_DISCOUNT_PREVIEW_CACHE_TTL", _DEFAULT_RESULT_TTL))


# --- fail-open Redis primitives ---------------------------------------------
def _safe_get(key, default=None):
    try:
        value = cache.get(key, _MISS)
    except Exception:  # noqa: BLE001 — redis down/misconfigured: fall through
        logger.warning("discount cache get failed for %s", key, exc_info=True)
        return default
    return default if value is _MISS else value


def _safe_set(key, value, timeout):
    try:
        cache.set(key, value, timeout)
    except Exception:  # noqa: BLE001
        logger.warning("discount cache set failed for %s", key, exc_info=True)


def _safe_delete(key):
    try:
        cache.delete(key)
    except Exception:  # noqa: BLE001
        pass


# --- rules version (the invalidation lever) ---------------------------------
def rules_version() -> int:
    value = _safe_get(_VERSION_KEY)
    if value is None:
        value = 1
        _safe_set(_VERSION_KEY, value, None)
    return int(value)


def bump_rules_version() -> None:
    """Invalidate everything: advance the version so every cached per-cart result
    key (which embeds the version) can never be read again, and drop the gate."""
    try:
        cache.incr(_VERSION_KEY)
    except Exception:  # noqa: BLE001 — key missing (never set) or redis down
        # A fresh, non-colliding value is enough to orphan old keys.
        _safe_set(_VERSION_KEY, rules_version() + 1, None)
    for channel in (
        DiscountRule.Channel.SALES,
        DiscountRule.Channel.PURCHASING,
        DiscountRule.Channel.BOTH,
    ):
        _safe_delete(_GATE_KEY.format(channel=channel))


# --- layer 1: active-rules gate ---------------------------------------------
def active_rules_exist(channel: str) -> bool:
    key = _GATE_KEY.format(channel=channel)
    try:
        cached = cache.get(key, _MISS)
    except Exception:  # noqa: BLE001 — redis down: assume rules may exist and let
        # the engine decide, rather than adding a DB probe on every call.
        return True
    if cached is not _MISS:
        return bool(cached)
    exists = (
        DiscountRule.objects.filter(is_active=True)
        .filter(Q(channel=channel) | Q(channel=DiscountRule.Channel.BOTH))
        .exists()
    )
    _safe_set(key, exists, _GATE_TTL)
    return exists


# --- layer 2: per-cart result cache -----------------------------------------
def _digest(context: DiscountContext) -> str:
    parts = [
        str(context.channel),
        str(context.customer_id or ""),
        str(context.supplier_id or ""),
        str(context.customer_rank or ""),
        "|".join(sorted(context.normalized_coupon_codes)),
        f"v{rules_version()}",
    ]
    for line in sorted(
        context.lines,
        key=lambda ln: (
            ln.product_id or 0,
            ln.variant_id or 0,
            str(ln.unit_amount),
            str(ln.quantity),
        ),
    ):
        categories = ",".join(sorted(str(cat) for cat in line.category_ids))
        parts.append(
            f"{line.product_id}:{line.variant_id}:{line.quantity}:"
            f"{line.unit_amount}:{categories}"
        )
    raw = "\x1f".join(parts)
    return hashlib.sha256(raw.encode("utf-8")).hexdigest()


def _empty_result(context: DiscountContext) -> DiscountCalculationResult:
    subtotal = context.subtotal
    return DiscountCalculationResult(
        channel=context.channel,
        customer_id=context.customer_id,
        supplier_id=context.supplier_id,
        subtotal=subtotal,
        discount_total=money(Decimal("0.00")),
        total=subtotal,
        applications=(),
    )


def preview_with_cache(context: DiscountContext, compute) -> DiscountCalculationResult:
    """Preview-only cached discount calculation. ``compute`` is a zero-arg callable
    that runs the live engine on a miss. Never raises on cache failure."""
    # Layer 1: no active rules for this channel -> no engine, no DB.
    if not active_rules_exist(context.channel):
        return _empty_result(context)

    # Layer 2: exact-cart result memoised for a few seconds.
    key = _RESULT_KEY.format(digest=_digest(context))
    cached = _safe_get(key)
    if isinstance(cached, DiscountCalculationResult):
        return cached

    result = compute()
    _safe_set(key, result, _result_ttl())
    return result
