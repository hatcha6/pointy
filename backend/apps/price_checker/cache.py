"""Redis cache for price-checker barcode lookups.

A kiosk scan is unauthenticated, LAN-facing, and its answer (name/price/
discounts) is identical for every scanner — the perfect cache candidate. The
key embeds both invalidation levers, so a hit can never be stale against an
edit:

- the **catalog version** (``apps.catalog.cache``) — bumped on any product/
  variant/unit-barcode/image change AND on every stock save, which keeps the
  ``in_stock`` flag honest;
- the **discount rules version** (``apps.discounts.cache``) — bumped on any
  rule/tier/category edit.

The short TTL only bounds what versions can't see: discount time-window
boundaries crossing mid-TTL and out-of-band DB edits. Not-found results are
cached too (a mistyped barcode rescanned in frustration is the hottest lookup
of all). Fail-open: any Redis trouble falls through to a live lookup. The
audit trail is untouched — ``perform_lookup`` still logs a PriceCheckEvent per
scan; only the pricing math is memoised.
"""

from __future__ import annotations

import hashlib
import logging

from django.conf import settings
from django.core.cache import cache

from apps.catalog.cache import catalog_version
from apps.catalog.models import normalize_barcode
from apps.discounts.cache import rules_version

from .pricing import PriceResult, lookup_price

logger = logging.getLogger(__name__)

# The version segment is the *shape* of the cached PriceResult. Bump it
# whenever a field is added or removed: an entry pickled by the previous
# release would otherwise be unpickled into the new dataclass and read back
# missing its newest fields.
_KEY = "pointy:pricecheck:v2:{catalog_v}:{rules_v}:{channel}:{image}:{digest}"
_MISS = "__miss__"


def _ttl() -> int:
    return int(getattr(settings, "POINTY_PRICE_LOOKUP_CACHE_TTL", 0))


def lookup_price_cached(barcode: str, *, with_image: bool = False) -> PriceResult:
    """``lookup_price`` behind Redis. Falls back to a live lookup whenever the
    cache is disabled, the version stamps are unavailable, or Redis errors."""
    ttl = _ttl()
    code = normalize_barcode(barcode)
    if ttl <= 0 or not code:
        return lookup_price(barcode, with_image=with_image)

    catalog_v = catalog_version()
    if catalog_v is None:
        return lookup_price(barcode, with_image=with_image)

    key = _KEY.format(
        catalog_v=catalog_v,
        rules_v=rules_version(),
        channel="sales",
        image=int(with_image),
        # Scanners emit arbitrary bytes; hash so any input is a safe cache key.
        digest=hashlib.md5(code.encode()).hexdigest(),
    )
    try:
        cached = cache.get(key, _MISS)
    except Exception:  # noqa: BLE001 — redis down: price the scan live
        logger.warning("price lookup cache get failed", exc_info=True)
        cached = _MISS
    if cached is not _MISS:
        return cached

    result = lookup_price(barcode, with_image=with_image)
    try:
        cache.set(key, result, ttl)
    except Exception:  # noqa: BLE001
        logger.warning("price lookup cache set failed", exc_info=True)
    return result
