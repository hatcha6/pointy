import contextlib
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
        recorder = _QueryRecorder()
        try:
            with _instrumented_connections(recorder):
                response = self.get_response(request)
        except Exception as exc:
            elapsed_ms = _elapsed_ms(started_at)
            metrics = _request_metrics(
                elapsed_ms=elapsed_ms,
                status_code=500,
                recorder=recorder,
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
            recorder=recorder,
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


class _QueryRecorder:
    """Counts and times this request's queries via ``execute_wrapper``.

    Unlike diffing ``connection.queries``, this needs no DEBUG query log —
    so it works in production, costs no memory, and never trips Django's
    9000-entry logging cap (whose overflow warning it used to raise on
    query-heavy requests such as batched analytics ingests).
    """

    __slots__ = ("count", "time_ms")

    def __init__(self):
        self.count = 0
        self.time_ms = 0.0

    def __call__(self, execute, sql, params, many, context):
        started_at = time.perf_counter()
        try:
            return execute(sql, params, many, context)
        finally:
            self.count += 1
            self.time_ms += (time.perf_counter() - started_at) * 1000


@contextlib.contextmanager
def _instrumented_connections(recorder):
    with contextlib.ExitStack() as stack:
        for alias in connections:
            try:
                stack.enter_context(connections[alias].execute_wrapper(recorder))
            except Exception:
                continue
        yield


def _elapsed_ms(started_at):
    return round((time.perf_counter() - started_at) * 1000, 3)


def _request_metrics(
    *,
    elapsed_ms,
    status_code,
    recorder,
    response=None,
):
    metrics = {
        "duration_ms": elapsed_ms,
        "status_code": status_code,
        "db_query_count": recorder.count,
        "db_time_ms": round(recorder.time_ms, 3),
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
