from django.core.cache import cache
from django.db import connection
from django.http import JsonResponse


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

    status_code = 200 if all(value == "ok" for value in checks.values()) else 503
    payload = {
        "status": "ready" if status_code == 200 else "not_ready",
        "service": "pointy-backend",
        "checks": checks,
    }
    if errors:
        payload["errors"] = errors
    return JsonResponse(payload, status=status_code)
