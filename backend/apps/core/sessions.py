"""Fail-open cached_db session backend.

Django's ``cached_db`` engine reads sessions through the cache with the DB as
the source of truth — but while its ``load()`` already swallows cache errors,
``save()``/``delete()`` call the cache directly and would 500 every
authenticated request if Redis restarts. This store wraps the cache side so any
Redis trouble silently degrades to plain DB sessions; nobody gets logged out
and no request fails because a *cache* hiccuped.

Uses the ``default`` cache alias (see ``SESSION_ENGINE`` in settings) so tests
that override ``CACHES`` keep working without knowing about sessions.
"""

import logging

from django.conf import settings
from django.contrib.sessions.backends.cached_db import (
    SessionStore as CachedDbSessionStore,
)
from django.core.cache import caches
from django.utils.functional import cached_property

logger = logging.getLogger(__name__)


class _FailOpenCache:
    """The subset of the cache API cached_db uses, with errors swallowed."""

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
    @cached_property
    def _cache(self):
        return _FailOpenCache(caches[settings.SESSION_CACHE_ALIAS])
