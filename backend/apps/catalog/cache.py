"""Redis-backed catalog version stamp.

One monotonically increasing integer that changes whenever anything the catalog
payload is built from changes: products, variants, units, unit barcodes,
categories, modifier sets, units of measure, attachments (product images), and
stock levels (every sale funnels through ``StockItem.save``, so quantities are
covered). Two consumers:

- **Conditional GET** on the catalog list endpoints (``ConditionalListMixin`` in
  views.py): the ETag embeds the version, so unchanged catalogs answer polls
  with an empty 304 instead of re-running the queryset + serializer.
- **Price-checker lookup cache** (``apps.price_checker.cache``): the version is
  part of the per-barcode key, so any catalog or stock change instantly orphans
  cached lookups.

Signal-driven (``signals.py``) with one deliberate exception: the nightly
popularity job writes via ``bulk_update`` (no signals) and bumps explicitly.
Fail-open: if Redis is unusable the version reads as None and both consumers
skip caching entirely. Disabled under tests via POINTY_CATALOG_CACHE_ENABLED
(test rollbacks don't fire signals; a stale version would leak across tests).
"""

from __future__ import annotations

import logging

from django.conf import settings
from django.core.cache import cache

logger = logging.getLogger(__name__)

_VERSION_KEY = "pointy:catalog:version"


def catalog_cache_enabled() -> bool:
    return bool(getattr(settings, "POINTY_CATALOG_CACHE_ENABLED", False))


def catalog_version() -> int | None:
    """Current version, or None when disabled/Redis is unusable (skip caching)."""
    if not catalog_cache_enabled():
        return None
    try:
        value = cache.get(_VERSION_KEY)
        if value is None:
            value = 1
            cache.set(_VERSION_KEY, value, None)
        return int(value)
    except Exception:  # noqa: BLE001 — redis down/misconfigured
        logger.warning("catalog version read failed", exc_info=True)
        return None


def bump_catalog_version() -> None:
    from apps.core.state_version import state_versions_enabled

    # This counter has two consumers: the cache below and the state vector
    # clients revalidate on. Either one being switched on has to keep it
    # moving, or a client would trust a frozen number and never re-fetch.
    if not catalog_cache_enabled() and not state_versions_enabled():
        return
    try:
        cache.incr(_VERSION_KEY)
    except Exception:  # noqa: BLE001 — key missing (never set) or redis down
        try:
            cache.set(_VERSION_KEY, (catalog_version() or 0) + 1, None)
        except Exception:  # noqa: BLE001
            pass


def catalog_etag(request, version=None) -> str | None:
    """Weak ETag for catalog list responses, or None to skip conditional GET.

    The user id is embedded so a response serialized for one role can never be
    304-validated against another user's cached copy.
    """
    version = catalog_version() if version is None else version
    if version is None:
        return None
    user_id = getattr(getattr(request, "user", None), "pk", None) or 0
    return f'W/"catalog-v{version}-u{user_id}"'


# Version-push header: stamped on the responses the POS receives constantly
# (catalog lists, discount preview — which fires on every cart edit — and
# checkout), so tills learn "the catalog changed" within one interaction and
# flush their local scan/search caches deterministically instead of trusting
# TTLs. Absent when caching is disabled or Redis is down — clients no-op.
CATALOG_VERSION_HEADER = "X-Pointy-Catalog-Version"


def attach_catalog_version(response, version=None):
    version = catalog_version() if version is None else version
    if version is not None:
        response[CATALOG_VERSION_HEADER] = str(version)
    return response
