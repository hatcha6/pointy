"""Redis-backed caches for the fixed per-request overhead: the ShopSettings
singleton, the auth User row, and the resolved per-user permission set.

Both are **fail-open** (any Redis hiccup falls straight through to a live DB
read — a cache must never break a request) and both are invalidated the moment
the underlying data changes, so the TTLs are safety nets, not the correctness
mechanism:

- **ShopSettings** mutates via ``.save()`` (post_save signal in ``signals.py``)
  and via ``ShopSettings.objects.filter(pk=1).update(...)`` (caught by the
  ``update()`` override on ``ShopSettingsQuerySet``). The TTL only bounds
  staleness from out-of-band writes (raw SQL in psql).
- **Permissions** invalidate through a single global version stamp bumped by
  every permission-affecting signal (role/group membership, direct grants,
  group permission edits, user saves). One bump orphans every cached set at
  once — permission edits are rare, so the blunt lever is the simple one.

Both caches are DISABLED under the test runner (their TTL settings default to
0 when ``settings.TESTING``): test transactions roll back without firing
signals, so a pk=1 singleton cached in one test would leak stale state into
the next. The dedicated tests in ``test_caching.py`` opt back in explicitly.
"""

from __future__ import annotations

import hashlib
import logging

from django.conf import settings
from django.core.cache import cache

logger = logging.getLogger(__name__)

_MISS = "__miss__"

_PERM_VERSION_KEY = "pointy:auth:perm-version"
_PERM_KEY = "pointy:auth:perms:{user_id}:{version}"


# --- fail-open Redis primitives ----------------------------------------------
def _safe_get(key, default=None):
    try:
        value = cache.get(key, _MISS)
    except Exception:  # noqa: BLE001 — redis down/misconfigured: fall through
        logger.warning("cache get failed for %s", key, exc_info=True)
        return default
    return default if value is _MISS else value


def _safe_set(key, value, timeout):
    try:
        cache.set(key, value, timeout)
    except Exception:  # noqa: BLE001
        logger.warning("cache set failed for %s", key, exc_info=True)


def _safe_delete(key):
    try:
        cache.delete(key)
    except Exception:  # noqa: BLE001
        pass


# --- ShopSettings singleton ---------------------------------------------------
def _shop_settings_key():
    # The key embeds a fingerprint of the concrete schema, so a pickle cached by
    # the previous release can never be served after a migration adds a field —
    # the new code simply reads a different key and misses.
    from apps.core.models import ShopSettings

    fields = ",".join(sorted(f.attname for f in ShopSettings._meta.concrete_fields))
    digest = hashlib.md5(fields.encode()).hexdigest()[:10]
    return f"pointy:core:shop-settings:{digest}"


def _shop_settings_ttl() -> int:
    return int(getattr(settings, "POINTY_SHOP_SETTINGS_CACHE_TTL", 0))


def get_shop_settings(loader):
    """Return the ShopSettings singleton, from Redis when possible.

    Every hit unpickles a FRESH instance, so callers that mutate the object
    without saving can never poison another request's copy.
    """
    ttl = _shop_settings_ttl()
    if ttl <= 0:
        return loader()
    key = _shop_settings_key()
    cached = _safe_get(key)
    if cached is not None:
        return cached
    instance = loader()
    _safe_set(key, instance, ttl)
    return instance


def invalidate_shop_settings():
    if _shop_settings_ttl() <= 0:
        return  # nothing is ever cached; skip the Redis round-trip (tests/CI)
    _safe_delete(_shop_settings_key())


# --- RelayInstallation singleton ------------------------------------------------
# Loaded on /me, discovery beacons, every AI view, and the usage-ring poll; the
# row changes only on enrollment/sync/heartbeat writes, all of which fire the
# post_save signal. "No installation yet" is a legitimate cacheable answer, so
# it is stored as a sentinel rather than treated as a miss.
_RELAY_INSTALLATION_NONE = "__none__"


def _relay_installation_ttl() -> int:
    return int(getattr(settings, "POINTY_RELAY_INSTALLATION_CACHE_TTL", 0))


def _relay_installation_key() -> str:
    from apps.core.models import RelayInstallation

    fields = ",".join(
        sorted(f.attname for f in RelayInstallation._meta.concrete_fields)
    )
    digest = hashlib.md5(fields.encode()).hexdigest()[:10]
    return f"pointy:core:relay-installation:{digest}"


def get_relay_installation(loader):
    ttl = _relay_installation_ttl()
    if ttl <= 0:
        return loader()
    key = _relay_installation_key()
    cached = _safe_get(key)
    if cached is not None:
        return None if cached == _RELAY_INSTALLATION_NONE else cached
    instance = loader()
    _safe_set(key, _RELAY_INSTALLATION_NONE if instance is None else instance, ttl)
    return instance


def invalidate_relay_installation():
    if _relay_installation_ttl() <= 0:
        return  # nothing is ever cached; skip the Redis round-trip (tests/CI)
    _safe_delete(_relay_installation_key())


# --- the auth user row ----------------------------------------------------------
def _user_ttl() -> int:
    return int(getattr(settings, "POINTY_USER_CACHE_TTL", 0))


def _user_key(user_id) -> str:
    # Same schema-fingerprint trick as ShopSettings: a pickle cached by the
    # previous release can never be unpickled into a migrated User model.
    from django.contrib.auth import get_user_model

    fields = ",".join(
        sorted(f.attname for f in get_user_model()._meta.concrete_fields)
    )
    digest = hashlib.md5(fields.encode()).hexdigest()[:10]
    return f"pointy:auth:user:{user_id}:{digest}"


def get_cached_user(user_id):
    """Return the cached User row for the auth middleware, or None on miss."""
    if _user_ttl() <= 0:
        return None
    return _safe_get(_user_key(user_id))


def set_cached_user(user) -> None:
    ttl = _user_ttl()
    if ttl <= 0:
        return
    _safe_set(_user_key(user.pk), user, ttl)


def invalidate_user(user_id) -> None:
    if _user_ttl() <= 0:
        return  # nothing is ever cached; skip the Redis round-trip (tests/CI)
    _safe_delete(_user_key(user_id))


# --- per-user permission sets -------------------------------------------------
def _permission_ttl() -> int:
    return int(getattr(settings, "POINTY_PERMISSION_CACHE_TTL", 0))


def perm_version() -> int:
    value = _safe_get(_PERM_VERSION_KEY)
    if value is None:
        value = 1
        _safe_set(_PERM_VERSION_KEY, value, None)
    return int(value)


def bump_perm_version() -> None:
    """Orphan every cached permission set: each key embeds the version, so
    advancing it makes the old keys unreachable (they expire on their own)."""
    if _permission_ttl() <= 0:
        return  # nothing is ever cached; skip the Redis round-trip (tests/CI)
    try:
        cache.incr(_PERM_VERSION_KEY)
    except Exception:  # noqa: BLE001 — key missing (never set) or redis down
        _safe_set(_PERM_VERSION_KEY, perm_version() + 1, None)


def get_cached_user_permissions(user_id):
    """Return the cached permission set for a user, or None on miss/disabled."""
    if _permission_ttl() <= 0:
        return None
    key = _PERM_KEY.format(user_id=user_id, version=perm_version())
    return _safe_get(key)


def set_cached_user_permissions(user_id, perms) -> None:
    ttl = _permission_ttl()
    if ttl <= 0:
        return
    key = _PERM_KEY.format(user_id=user_id, version=perm_version())
    _safe_set(key, frozenset(perms), ttl)
