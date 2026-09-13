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
    """Throttle initial-admin-setup attempts per client IP.

    Deliberately looser than the login throttle, because this endpoint is not
    guessable: it creates the *first* user and then answers 409 forever, so
    there is no secret to grind at and an attacker who wanted to claim a fresh
    install would need exactly one request, not thousands. A tight limit buys
    almost nothing here and costs a great deal — every rejected attempt counts,
    including plain validation errors, so an owner who mistypes a password a
    few times on the first-run wizard would be locked out of their own new
    installation for an hour with no way in but ``docker exec``.
    """

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


class AuthenticatedBurstCeilingThrottle(_FailOpenThrottleMixin, UserRateThrottle):
    """A wide per-user ceiling on authenticated traffic — not a product rate
    limit.

    Normal POS bursts never come near the default (see settings); this exists
    so a runaway client — a retry loop, a stuck poller — cannot convert one
    device's bug into a shop-wide DB flood (PgBouncer queues at 25 concurrent
    transactions, so one device looping flat-out degrades every till).

    Keyed per user, so the shared-REMOTE_ADDR web path can never
    cross-throttle different users. Anonymous requests pass through
    untouched: behind nginx they share one IP and would false-positive, and
    the sensitive anonymous endpoints (login/setup) keep their own scoped
    throttles above.
    """

    scope = "authenticated_ceiling"

    def allow_request(self, request, view):
        user = getattr(request, "user", None)
        if user is None or not getattr(user, "is_authenticated", False):
            return True
        return super().allow_request(request, view)


class CompanionPairRateThrottle(_FailOpenThrottleMixin, SimpleRateThrottle):
    """Throttle companion pairing-code claims per client IP.

    The pairing code is short and typable on purpose, so it is the one
    companion secret with an entropy budget worth defending. At this rate a
    phone on the LAN gets a handful of guesses per minute against a code that
    lives for two, which leaves brute force far outside the window.
    """

    scope = "companion_pair"

    def get_cache_key(self, request, view):
        return self.cache_format % {
            "scope": self.scope,
            "ident": self.get_ident(request),
        }


class CompanionUploadRateThrottle(_FailOpenThrottleMixin, SimpleRateThrottle):
    """Bound how fast one paired phone can push photos into the shop's storage.

    Keyed on the device, not the address: several phones behind one WiFi NAT
    are a normal shop, a single phone stuck in a retry loop is not.
    """

    scope = "companion_upload"

    def get_cache_key(self, request, view):
        device = getattr(request, "companion_device", None)
        ident = f"device:{device.pk}" if device is not None else self.get_ident(request)
        return self.cache_format % {"scope": self.scope, "ident": ident}
