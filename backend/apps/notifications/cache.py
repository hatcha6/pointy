"""Redis version stamps + ETag for the notifications feed.

The bell/badge is the most-polled per-user endpoint in the app: every signed-in
device GETs the full list on start, drawer-open, and after actions. The payload
almost never changes, so polls answer 304 from two version stamps:

- **Global version** — bumped by ``sync_business_notifications`` only when a
  sync *materially* changes the feed (created / reactivated / resolved rows or
  changed payloads). The sync's per-row ``last_seen_at`` refresh deliberately
  does NOT bump: it would otherwise orphan every device's ETag on every beat
  tick while the visible feed is byte-identical except for timestamps.
- **Per-user version** — bumped on every user-state write (dismiss / snooze /
  restore, single and bulk), so a user's own action is visible on their very
  next poll.

The ETag also embeds the global permission version (visibility is
permission-shaped) and a coarse time bucket
(``POINTY_NOTIFICATIONS_ETAG_MAX_AGE_SECONDS``, default 5 min) that bounds
every indirect staleness path — snooze expiry (visibility changes with no
write), admin edits, missed bumps — without any per-poll DB work.

Fail-open like the catalog version: Redis trouble reads as None and the view
skips conditional GET entirely. Disabled under tests (rollbacks don't fire the
service-level bumps' surrounding writes deterministically across cases).
"""

from __future__ import annotations

import logging
import time

from django.conf import settings
from django.core.cache import cache

logger = logging.getLogger(__name__)

_VERSION_KEY = "pointy:notifications:version"
_USER_VERSION_KEY = "pointy:notifications:user-version:{user_id}"


def notifications_cache_enabled() -> bool:
    return bool(getattr(settings, "POINTY_NOTIFICATIONS_CACHE_ENABLED", False))


def _etag_max_age_seconds() -> int:
    return int(
        getattr(settings, "POINTY_NOTIFICATIONS_ETAG_MAX_AGE_SECONDS", 300)
    )


def _read_version(key) -> int | None:
    try:
        value = cache.get(key)
        if value is None:
            value = 1
            cache.set(key, value, None)
        return int(value)
    except Exception:  # noqa: BLE001 — redis down/misconfigured
        logger.warning("notifications version read failed for %s", key, exc_info=True)
        return None


def _bump(key) -> None:
    from apps.core.state_version import state_versions_enabled

    # This counter has two consumers: the cache below and the state vector
    # clients revalidate on. Either one being switched on has to keep it
    # moving, or a client would trust a frozen number and never re-fetch.
    if not notifications_cache_enabled() and not state_versions_enabled():
        return
    try:
        cache.incr(key)
    except Exception:  # noqa: BLE001 — key missing (never set) or redis down
        try:
            cache.set(key, (_read_version(key) or 0) + 1, None)
        except Exception:  # noqa: BLE001
            pass


def bump_notifications_version() -> None:
    """The feed's content changed for everyone (sync created/reactivated/
    resolved rows or rewrote payloads)."""
    _bump(_VERSION_KEY)


def bump_user_notifications_version(user_id) -> None:
    """One user's visibility changed (dismiss/snooze/restore)."""
    _bump(_USER_VERSION_KEY.format(user_id=user_id))


def notifications_etag(request) -> str | None:
    """Weak ETag for the notifications list, or None to skip conditional GET."""
    if not notifications_cache_enabled():
        return None
    version = _read_version(_VERSION_KEY)
    if version is None:
        return None
    user_id = getattr(getattr(request, "user", None), "pk", None) or 0
    user_version = _read_version(_USER_VERSION_KEY.format(user_id=user_id))
    if user_version is None:
        return None
    # Visibility is permission-shaped; the perm version orphans ETags minted
    # under a different role.
    from apps.core.caching import perm_version

    bucket = int(time.time()) // max(_etag_max_age_seconds(), 1)
    return (
        f'W/"notif-v{version}-p{perm_version()}-s{user_version}'
        f'-u{user_id}-t{bucket}"'
    )
