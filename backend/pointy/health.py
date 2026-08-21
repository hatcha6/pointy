import logging

from django.core.cache import cache
from django.db import connection
from django.http import JsonResponse

logger = logging.getLogger(__name__)

# Dependencies this backend is designed to keep serving without. Redis is a
# cache and a broker, never a system of record: every path that reads it is
# deliberately fail-open (apps.core.caching, apps.core.sessions,
# apps.core.auth_backends, apps.core.throttling, the discount preview) and every
# path that writes to the broker is bounded (apps.core.dispatch), so a shop
# keeps selling right through a Redis restart — apps.core.test_sessions
# ::test_login_and_authenticated_request_survive_dead_cache pins that down.
#
# Readiness must agree with that, because a 503 here is not a report — it is an
# action. /readyz/ is the container healthcheck, so a sustained Redis outage
# would mark the backend unhealthy, and the on-prem watchdog heals an unhealthy
# container by restarting it: a backend that was serving every till correctly
# gets SIGTERMed mid-checkout, on every cycle, until Redis returns. The worker,
# beat and the relay connector all wait on `backend: service_healthy` too, and
# the zero-downtime update flip only moves traffic to a container that answered
# this endpoint.
OPTIONAL_CHECKS = ("cache",)


def healthz(request):
    return JsonResponse({"status": "ok", "service": "pointy-backend"})


def readyz(request):
    checks = {}
    errors = {}

    try:
        with connection.cursor() as cursor:
            cursor.execute("SELECT 1")
            cursor.fetchone()
        checks["database"] = "ok"
    except Exception as exc:  # pragma: no cover - exact backend failure varies.
        checks["database"] = "error"
        errors["database"] = exc.__class__.__name__

    try:
        cache_key = "pointy:readyz"
        cache.set(cache_key, "ok", timeout=5)
        if cache.get(cache_key) != "ok":
            raise RuntimeError("cache round trip failed")
        checks["cache"] = "ok"
    except Exception as exc:  # pragma: no cover - exact cache failure varies.
        checks["cache"] = "error"
        errors["cache"] = exc.__class__.__name__

    failed = [name for name, value in checks.items() if value != "ok"]
    degraded = [name for name in failed if name in OPTIONAL_CHECKS]
    required_failed = [name for name in failed if name not in OPTIONAL_CHECKS]

    status_code = 503 if required_failed else 200
    payload = {
        "status": "ready" if status_code == 200 else "not_ready",
        "service": "pointy-backend",
        "checks": checks,
    }
    if degraded:
        # Still ready, but say so out loud: an operator reading /readyz/ (or the
        # diagnostics export) has to be able to see that Redis is down, even
        # though nothing is being restarted over it.
        payload["degraded"] = degraded
        logger.warning("readyz: serving degraded without %s", ", ".join(degraded))
    if errors:
        payload["errors"] = errors
    return JsonResponse(payload, status=status_code)
