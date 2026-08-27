"""A burst ceiling for unauthenticated API traffic.

The DRF ceiling (``apps.core.throttling.AuthenticatedBurstCeilingThrottle``)
deliberately exempts anonymous callers, and DRF could not have bounded this case
anyway: ``APIView.initial`` checks permissions *before* throttles, so a request
that is going to 401 never reaches a throttle class at all.

That is precisely the traffic that needs bounding. A client looping on rejected
telemetry sent 5,127,075 unauthenticated ingest requests over seven weeks — 85%
of every HTTP request the backend served and 68% of its request time — and
nothing anywhere slowed it down, because the one class of caller that can loop
without ever succeeding was the one class nothing was watching.

Running as middleware puts the check ahead of authentication, permissions,
routing and the view, so a runaway costs a cache read rather than a request
cycle. Authenticated traffic passes straight through to the DRF ceiling.

Keyed by the client's device id when it sends one, so several tills sharing one
address behind nginx are counted apart, and by peer address otherwise. The rate
is set far above real anonymous use — sign-in, first-run setup, price-checker
lookups and discovery, a few calls a minute between them.
"""

import logging
import time

from django.conf import settings
from django.core.cache import cache
from django.http import JsonResponse

logger = logging.getLogger(__name__)

CACHE_PREFIX = "throttle:anon-ceiling:"

# Sign-in and first-run setup are never throttled here. They carry their own,
# much tighter scoped throttles (login: 30/min per IP, 6/min per username), and
# they are the paths that must keep working *during* a storm. Behind nginx an
# older client that sends no device id is keyed by peer address, which every
# till shares — so without this exemption one runaway kiosk could lock the shop
# out of its own POS, which is a worse outcome than the flood.
EXEMPT_PREFIXES = ("/api/auth/", "/api/setup/")


class AnonymousBurstCeilingMiddleware:
    def __init__(self, get_response):
        self.get_response = get_response
        self.limit = int(getattr(settings, "POINTY_ANONYMOUS_BURST_LIMIT", 0) or 0)
        self.window_seconds = max(
            int(getattr(settings, "POINTY_ANONYMOUS_BURST_WINDOW_SECONDS", 60) or 60), 1
        )
        self.paths = tuple(
            getattr(settings, "POINTY_ANALYTICS_BACKEND_PERFORMANCE_PATHS", ("/api/",))
        )

    def __call__(self, request):
        if self._is_over_limit(request):
            return JsonResponse(
                {"detail": "Too many requests from this device."},
                status=429,
            )
        return self.get_response(request)

    def _is_over_limit(self, request):
        if self.limit <= 0:
            return False
        path = getattr(request, "path", "")
        if not any(path.startswith(prefix) for prefix in self.paths):
            return False
        if path.startswith(EXEMPT_PREFIXES):
            return False
        if _carries_credentials(request):
            return False
        try:
            return self._count(_client_key(request)) > self.limit
        except Exception:  # pragma: no cover - depends on cache backend failure
            # A POS must keep serving through a Redis outage; fail open the way
            # the DRF throttles do, and make the outage visible instead.
            logger.warning(
                "Anonymous throttle cache unavailable; allowing request through.",
                exc_info=True,
            )
            return False

    def _count(self, ident):
        # Fixed windows, so a caller can burst across a boundary. That is fine
        # for a ceiling whose job is to bound a runaway, not to pace clients.
        window = int(time.time()) // self.window_seconds
        key = f"{CACHE_PREFIX}{window}:{ident}"
        added = cache.add(key, 1, timeout=self.window_seconds * 2)
        if added:
            return 1
        try:
            return cache.incr(key)
        except ValueError:
            # The key expired between add and incr; treat it as a fresh window.
            cache.set(key, 1, timeout=self.window_seconds * 2)
            return 1


def _carries_credentials(request):
    """Whether this request offers ANY credential, not whether one validates.

    Deliberately generous. Middleware runs ahead of DRF, so it sees Django's
    session user and nothing else: a caller authenticating by a header DRF
    resolves later (Basic, or the relay tunnel's token) would look anonymous
    here and get throttled as a runaway. A ceiling that could throttle a working
    till is worse than one that lets a few odd cases through, so anything
    carrying credentials is waved past and left to the authenticated ceiling.

    The traffic this exists to bound carries none of these: 5.1M requests with
    no cookie, no header, nothing — the backend recorded them all as
    ``user_authenticated: false``.
    """
    user = getattr(request, "user", None)
    if user is not None and getattr(user, "is_authenticated", False):
        return True
    headers = getattr(request, "headers", None)
    if headers is not None:
        for header in ("Authorization", "X-Pointy-Relay-Token"):
            if str(headers.get(header, "") or "").strip():
                return True
    session_cookie = getattr(settings, "SESSION_COOKIE_NAME", "sessionid")
    return bool(request.COOKIES.get(session_cookie))


def _client_key(request):
    headers = getattr(request, "headers", None)
    device_id = ""
    if headers is not None:
        device_id = str(headers.get("X-Pointy-Device-Id", "") or "").strip()[:96]
    if device_id:
        return f"device:{device_id}"
    # REMOTE_ADDR is the immediate peer: an X-Forwarded-For the client sets is
    # worse than none, because it would let a runaway rotate its own key.
    return f"ip:{request.META.get('REMOTE_ADDR', '') or 'unknown'}"
