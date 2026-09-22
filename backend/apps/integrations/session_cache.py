"""Reusing a provider login across the calls one shop action makes.

Logging into HD Box or LNET is the single most expensive thing this app does
on a provider's behalf — a full round trip to a remote portal that answered
anywhere from two to nine seconds in the field (Annaseem, 2026-09-21). Every
driver method called its own ``_login()`` with no memory of the last one, so
looking a customer up — lookup, then offers, then their profile, all for the
same card, all in the same request — paid for three logins instead of one,
and a shop's own busy hour bought a fresh login for every single search that
followed the first.

This is the cache that fixes that. A driver's successful login is kept here,
keyed by account, and ``_login()`` tries it before ever touching the network.
It is deliberately dumb: it holds cookies (and, for LNET, the login-time CSRF
token) and nothing else, because that is all a session *is*. Nothing here
decides whether a cached session still works — the driver finds that out the
way it always has, by using it, and calls :func:`invalidate` the moment a
cached session turns out to be dead. See
``providers.hdbox.HdBoxProvider._authenticated_get`` and
``providers.lnet.LnetProvider._get`` for the one-shot retry that follows: a
stale cache costs exactly one extra login, never a wrong answer.

Fail-open throughout, like every other Redis-backed cache in this app (see
``apps.core.caching``): a cache a shop's till leans on to sell must never be
the reason it cannot.
"""

from __future__ import annotations

import hashlib
import logging

from django.conf import settings
from django.core.cache import cache

logger = logging.getLogger(__name__)


def _ttl() -> int:
    return int(getattr(settings, "POINTY_INTEGRATION_SESSION_CACHE_TTL", 0))


def _fingerprint(account) -> str:
    """Folds the credentials — and the portal URL — into the cache key.

    So that editing the password, the username or the base URL in Shop
    Settings misses the cache rather than replaying a session that belongs to
    whatever was true before the edit. This is also what keeps ``probe()`` —
    run the moment new credentials are saved, specifically to check them — an
    honest check of the *new* password: without the password in the
    fingerprint, a probe run one second after a password change would hit a
    still-live cached session for the OLD password and report success without
    ever trying the new one.
    """
    raw = "\x00".join(
        [
            account.username or "",
            account.password or "",
            account.resolved_base_url(),
        ]
    )
    return hashlib.sha256(raw.encode("utf-8")).hexdigest()[:16]


def _key(provider: str, account) -> str:
    return f"pointy:integrations:session:{provider}:{account.pk}:{_fingerprint(account)}"


def load(provider: str, account) -> dict | None:
    """The cached session payload for this account, or ``None``.

    ``None`` on a genuine miss, a disabled cache (TTL 0 — always true under
    tests, see settings.TESTING), an unsaved account, or a Redis hiccup.
    Never raises: a driver that cannot consult the cache must fall back to
    logging in for real, exactly as it did before this module existed.
    """
    if _ttl() <= 0 or not account.pk:
        return None
    try:
        return cache.get(_key(provider, account))
    except Exception:  # noqa: BLE001 - redis down/misconfigured: log in cold
        logger.warning("integration session cache read failed", exc_info=True)
        return None


def save(provider: str, account, payload: dict) -> None:
    """Remember a session that just logged in for real. Never raises."""
    ttl = _ttl()
    if ttl <= 0 or not account.pk:
        return
    try:
        cache.set(_key(provider, account), payload, ttl)
    except Exception:  # noqa: BLE001
        logger.warning("integration session cache write failed", exc_info=True)


def invalidate(provider: str, account) -> None:
    """Forget a session that turned out to be dead server-side. Never raises.

    Called the instant a cached session's first authenticated request comes
    back looking like a login form — never on an ordinary business refusal
    (a card not found is not a reason to distrust the session that found
    nothing).
    """
    if not account.pk:
        return
    try:
        cache.delete(_key(provider, account))
    except Exception:  # noqa: BLE001
        pass
