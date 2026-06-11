"""Rate-limiting throttles for sensitive authentication endpoints.

These guard the unauthenticated ``login`` and ``setup/admin`` endpoints (and
the authenticated password-change endpoint) against brute-force and abuse.
They are applied per-view rather than globally so that normal authenticated
POS traffic, which is high volume, is never throttled.

Client identity for IP-based throttles comes from
``SimpleRateThrottle.get_ident``, which honours the DRF ``NUM_PROXIES``
setting. Configure ``DJANGO_NUM_PROXIES`` to the number of trusted reverse
proxies in front of the backend so the real client address is used. The
default of ``0`` keys on the immediate peer (``REMOTE_ADDR``) so a client
cannot bypass the throttle by spoofing ``X-Forwarded-For``.

Throttle state lives in the Redis-backed cache. If the cache is unavailable
(for example during a Redis outage) the throttles fail open: requests are
allowed rather than rejected, so cashiers can still sign in. Brute-force
protection therefore depends on the cache being healthy, which it is in normal
operation.
"""

import logging

from rest_framework.throttling import SimpleRateThrottle, UserRateThrottle

logger = logging.getLogger(__name__)


class _FailOpenThrottleMixin:
    """Allow the request when the throttle cache backend is unavailable.

    A POS must keep accepting logins even if Redis is down; a hard failure
    here would lock everyone out. We still log so the outage is visible.
    """

    def allow_request(self, request, view):
        try:
            return super().allow_request(request, view)
        except Exception:  # pragma: no cover - depends on cache backend failure
            logger.warning(
                "Throttle cache unavailable; allowing request through %s",
                type(self).__name__,
                exc_info=True,
            )
            return True


class LoginRateThrottle(_FailOpenThrottleMixin, SimpleRateThrottle):
    """Throttle login attempts per client IP (bounds a single source)."""

    scope = "login"

    def get_cache_key(self, request, view):
        return self.cache_format % {
            "scope": self.scope,
            "ident": self.get_ident(request),
        }


class LoginUsernameRateThrottle(_FailOpenThrottleMixin, SimpleRateThrottle):
    """Throttle login attempts per submitted username.

    Blocks a targeted attack on one account even when the source IP rotates
    or many terminals share a single address behind the relay. Falls back to
    the client IP when no username is supplied so blank floods stay bounded.
    """

    scope = "login_username"

    def get_cache_key(self, request, view):
        username = ""
        data = getattr(request, "data", None)
        if isinstance(data, dict):
            raw = data.get("username", "")
            if isinstance(raw, str):
                username = raw.strip().casefold()
        ident = username or self.get_ident(request)
        return self.cache_format % {"scope": self.scope, "ident": ident}


class SetupRateThrottle(_FailOpenThrottleMixin, SimpleRateThrottle):
    """Throttle initial-admin-setup attempts per client IP."""

    scope = "setup"

    def get_cache_key(self, request, view):
        return self.cache_format % {
            "scope": self.scope,
            "ident": self.get_ident(request),
        }


class PasswordChangeRateThrottle(_FailOpenThrottleMixin, UserRateThrottle):
    """Throttle password-change attempts per authenticated user.

    The endpoint verifies the current password, so an attacker on a hijacked
    session could otherwise brute-force it.
    """

    scope = "password_change"
