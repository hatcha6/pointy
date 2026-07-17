"""Fail-open cached_db session backend.

Django's ``cached_db`` engine reads sessions through the cache with the DB as the
source of truth — but only *some* of its cache calls are guarded. ``load()``
swallows errors from the cache read, yet not from the write that repopulates the
cache on a miss; ``exists()`` and ``delete()`` call the cache directly. Since
``load()`` runs on every authenticated request, a Redis that is merely refusing
writes — restarting, failing over, evicting under memory pressure, or out of
connections — turns the whole API into 500s. This store wraps the cache side so
any Redis trouble silently degrades to plain DB sessions: nobody gets logged out
and no request fails because a *cache* hiccuped.

The wrapper must be applied to the attribute ``cached_db.SessionStore.__init__``
assigns. It sets ``self._cache`` directly, so declaring ``_cache`` here as a
``cached_property`` (or any descriptor) silently does nothing: the instance
``__dict__`` entry always wins, and the raw backend stays in place.

Uses the ``default`` cache alias (see ``SESSION_ENGINE`` in settings) so tests
that override ``CACHES`` keep working without knowing about sessions.
"""

import logging

from django.contrib.sessions.backends.cached_db import (
    SessionStore as CachedDbSessionStore,
)

logger = logging.getLogger(__name__)


class _FailOpenCache:
    """The subset of the cache API cached_db uses, with errors swallowed.

    Every fallback returns "the cache knows nothing", which sends cached_db to
    the DB — the source of truth — rather than to an exception.
    """

    def __init__(self, backend):
        self._backend = backend

    def get(self, key, default=None):
        try:
            return self._backend.get(key, default)
        except Exception:  # noqa: BLE001 — redis down: read from the DB instead
            logger.warning("session cache get failed", exc_info=True)
            return default

    def set(self, key, value, timeout=None):
        try:
            self._backend.set(key, value, timeout)
        except Exception:  # noqa: BLE001 — the DB write already succeeded
            logger.warning("session cache set failed", exc_info=True)

    def delete(self, key):
        try:
            self._backend.delete(key)
        except Exception:  # noqa: BLE001
            logger.warning("session cache delete failed", exc_info=True)

    def __contains__(self, key):
        # cached_db.exists() does `key in self._cache` and falls back to the DB
        # on a miss, so reporting "not cached" is the fail-open answer.
        try:
            return key in self._backend
        except Exception:  # noqa: BLE001
            logger.warning("session cache has_key failed", exc_info=True)
            return False

    async def aget(self, key, default=None):
        try:
            return await self._backend.aget(key, default)
        except Exception:  # noqa: BLE001
            logger.warning("session cache aget failed", exc_info=True)
            return default

    async def aset(self, key, value, timeout=None):
        try:
            await self._backend.aset(key, value, timeout)
        except Exception:  # noqa: BLE001
            logger.warning("session cache aset failed", exc_info=True)

    async def adelete(self, key):
        try:
            await self._backend.adelete(key)
        except Exception:  # noqa: BLE001
            logger.warning("session cache adelete failed", exc_info=True)


class SessionStore(CachedDbSessionStore):
    def __init__(self, session_key=None):
        super().__init__(session_key)
        # Wrap the raw backend super() just assigned (see the module docstring
        # for why this cannot be a descriptor).
        self._cache = _FailOpenCache(self._cache)
