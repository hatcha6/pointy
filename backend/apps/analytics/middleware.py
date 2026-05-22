import time

from django.conf import settings
from django.db import connections

from .models import AnalyticsEvent
from .services import record_event


class BackendPerformanceAnalyticsMiddleware:
    def __init__(self, get_response):
        self.get_response = get_response

    def __call__(self, request):
        if not _is_enabled_for_request(request):
            return self.get_response(request)

        started_at = time.perf_counter()
        query_counts = _query_counts()
        query_times = _query_times()
        try:
            response = self.get_response(request)
        except Exception as exc:
            elapsed_ms = _elapsed_ms(started_at)
            metrics = _request_metrics(
                elapsed_ms=elapsed_ms,
                status_code=500,
                query_counts=query_counts,
                query_times=query_times,
            )
            attributes = _request_attributes(request, status_code=500)
            attributes.update(
                {
                    "error_type": exc.__class__.__name__,
                    "error_message": str(exc)[:512],
                }
            )
            _safe_record_event(
                name="backend.exception",
                event_type=AnalyticsEvent.EventType.ERROR,
                severity=AnalyticsEvent.Severity.CRITICAL,
                user=getattr(request, "user", None),
                request=request,
                attributes=attributes,
                metrics=metrics,
            )
            raise

        elapsed_ms = _elapsed_ms(started_at)
        status_code = getattr(response, "status_code", 0)
        metrics = _request_metrics(
            elapsed_ms=elapsed_ms,
            status_code=status_code,
            query_counts=query_counts,
            query_times=query_times,
            response=response,
        )
        attributes = _request_attributes(request, status_code=status_code)
        severity = _severity_for(status_code=status_code, elapsed_ms=elapsed_ms)
        _safe_record_event(
            name="backend.request",
            event_type=AnalyticsEvent.EventType.PERFORMANCE,
            severity=severity,
            user=getattr(request, "user", None),
            request=request,
            attributes=attributes,
            metrics=metrics,
        )
        if status_code >= 500:
            _safe_record_event(
                name="backend.response_error",
                event_type=AnalyticsEvent.EventType.ERROR,
                severity=AnalyticsEvent.Severity.ERROR,
                user=getattr(request, "user", None),
                request=request,
                attributes=attributes,
                metrics=metrics,
            )
        return response


def _is_enabled_for_request(request):
    if not getattr(settings, "POINTY_ANALYTICS_BACKEND_PERFORMANCE_ENABLED", True):
        return False
    path = getattr(request, "path", "")
    prefixes = getattr(settings, "POINTY_ANALYTICS_BACKEND_PERFORMANCE_PATHS", ("/api/",))
    return any(path.startswith(prefix) for prefix in prefixes)


def _query_counts():
    return {
        alias: len(connection.queries)
        for alias, connection in _connection_items()
    }


def _query_times():
    return {
        alias: _connection_query_time_ms(connection)
        for alias, connection in _connection_items()
    }


def _connection_items():
    return ((alias, connections[alias]) for alias in connections)


def _connection_query_time_ms(connection):
    total = 0.0
    for query in connection.queries:
        try:
            total += float(query.get("time", 0)) * 1000
        except (TypeError, ValueError):
            continue
    return total


def _elapsed_ms(started_at):
    return round((time.perf_counter() - started_at) * 1000, 3)


def _request_metrics(
    *,
    elapsed_ms,
    status_code,
    query_counts,
    query_times,
    response=None,
):
    db_query_count = 0
    db_time_ms = 0.0
    for alias, connection in _connection_items():
        db_query_count += max(len(connection.queries) - query_counts.get(alias, 0), 0)
        db_time_ms += max(
            _connection_query_time_ms(connection) - query_times.get(alias, 0),
            0,
        )

    metrics = {
        "duration_ms": elapsed_ms,
        "status_code": status_code,
        "db_query_count": db_query_count,
        "db_time_ms": round(db_time_ms, 3),
    }
    response_size = _response_size(response)
    if response_size is not None:
        metrics["response_size_bytes"] = response_size
    return metrics


def _response_size(response):
    if response is None:
        return None
    try:
        return len(response.content)
    except (AttributeError, TypeError):
        return None


def _request_attributes(request, *, status_code):
    resolver_match = getattr(request, "resolver_match", None)
    view_name = getattr(resolver_match, "view_name", "") if resolver_match else ""
    return {
        "method": request.method,
        "path": request.path[:256],
        "view_name": view_name,
        "status_family": f"{status_code // 100}xx" if status_code else "unknown",
        "query_string_present": bool(request.META.get("QUERY_STRING", "")),
        "user_authenticated": bool(
            getattr(getattr(request, "user", None), "is_authenticated", False)
        ),
    }


def _severity_for(*, status_code, elapsed_ms):
    slow_request_ms = getattr(settings, "POINTY_ANALYTICS_BACKEND_SLOW_REQUEST_MS", 750)
    if status_code >= 500:
        return AnalyticsEvent.Severity.ERROR
    if status_code >= 400 or elapsed_ms >= slow_request_ms:
        return AnalyticsEvent.Severity.WARNING
    return AnalyticsEvent.Severity.INFO


def _safe_record_event(
    *,
    name,
    event_type,
    severity,
    user,
    request,
    attributes,
    metrics,
):
    try:
        record_event(
            name=name,
            event_type=event_type,
            severity=severity,
            source=AnalyticsEvent.Source.BACKEND,
            user=user,
            session_id=getattr(getattr(request, "session", None), "session_key", "") or "",
            trace_id=request.headers.get("X-Request-ID", ""),
            attributes=attributes,
            metrics=metrics,
        )
    except Exception:
        return
