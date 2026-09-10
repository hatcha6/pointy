import contextlib
import sys
import time
import traceback

from django.conf import settings
from django.core.exceptions import ValidationError
from django.core.signals import got_request_exception
from django.core.validators import validate_ipv46_address
from django.db import connections
from django.dispatch import receiver

from .models import AnalyticsEvent
from .services import record_event, record_event_buffered

# Where the crashing view stashes its exception for the middleware to read.
_EXCEPTION_ATTR = "_pointy_analytics_exception"


@receiver(got_request_exception)
def _capture_request_exception(sender, request=None, **kwargs):
    """Stash an unhandled view exception on the request.

    Django wraps the view (and every middleware layer) in
    ``convert_exception_to_response``, so by the time a view's exception reaches
    this middleware it is already a plain 500 *response* — an ``except`` block
    here can never see it. That left every 500 recorded with no error type, no
    message and no traceback, which is why a 5xx flood on the busiest endpoint
    (the POS discount preview) could not be diagnosed from tracking at all.
    ``got_request_exception`` fires at the moment of that conversion, which is
    the only seam that still has the exception.
    """
    if request is None:
        return
    exc_type, exc_value, exc_tb = sys.exc_info()
    if exc_value is None:
        return
    setattr(
        request,
        _EXCEPTION_ATTR,
        {
            "error_type": exc_type.__name__,
            "error_message": str(exc_value)[:512],
            # The innermost frames are what identify the bug; the outer ones are
            # the same middleware stack on every request.
            "error_traceback": "".join(
                traceback.format_exception(exc_type, exc_value, exc_tb)
            )[-2048:],
        },
    )


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
            # Only reachable for exceptions raised *outside* the converted
            # chain (e.g. by a middleware layered above this one).
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
        severity = _severity_for(status_code=status_code, elapsed_ms=elapsed_ms)
        metrics = _request_metrics(
            elapsed_ms=elapsed_ms,
            status_code=status_code,
            recorder=recorder,
            response=response,
        )
        attributes = {
            **_request_attributes(request, status_code=status_code),
            **_client_error_attributes(response, status_code=status_code),
        }
        if _should_record_request_event(
            request, status_code=status_code, severity=severity
        ):
            _safe_record_event(
                name="backend.request",
                event_type=AnalyticsEvent.EventType.PERFORMANCE,
                severity=severity,
                user=getattr(request, "user", None),
                request=request,
                attributes=attributes,
                metrics=metrics,
                buffered=True,
            )
        if status_code >= 500:
            _safe_record_event(
                name="backend.response_error",
                event_type=AnalyticsEvent.EventType.ERROR,
                severity=AnalyticsEvent.Severity.ERROR,
                user=getattr(request, "user", None),
                request=request,
                # A 500 with no cause attached is a row that only says
                # "something broke"; attach whatever the signal captured.
                attributes={
                    **attributes,
                    **getattr(request, _EXCEPTION_ATTR, {}),
                },
                metrics=metrics,
            )
        return response


#: Hard cap on the reason text kept per row. Serializer messages are written by
#: us and describe rules rather than values, but a few interpolate the input, so
#: this is short enough that nothing meaningful about a customer survives it.
_MAX_ERROR_DETAIL = 200

#: Field names never worth recording — noisy, and the interesting part of an
#: auth failure is the status, not the word "detail".
_UNINTERESTING_ERROR_FIELDS = frozenset({"detail", "code", "non_field_errors"})


def _client_error_attributes(response, *, status_code):
    """Why a 4xx was refused, as far as the response says.

    5xx already carries ``error_type`` and a traceback from
    ``got_request_exception``; 4xx carried nothing at all, and the field export
    showed exactly what that costs. Across 4-5 September 2026 one shop met a 400
    on ``PATCH /api/purchase-orders/`` 41 times and a 403 on one attachment 63
    times, and neither the screen nor the telemetry could say why — so the
    failures read as a shop that would not do its bookkeeping rather than an app
    refusing to let it.

    Reads the DRF payload, never the rendered bytes: touching ``content`` on a
    streaming response consumes it.
    """
    if not (400 <= status_code < 500):
        return {}
    if getattr(response, "streaming", False):
        return {}
    data = getattr(response, "data", None)
    if not isinstance(data, dict):
        return {}

    attributes = {}
    code = data.get("code")
    if isinstance(code, str) and code:
        attributes["error_code"] = code[:64]

    fields = sorted(
        key
        for key in data
        if isinstance(key, str) and key not in _UNINTERESTING_ERROR_FIELDS
    )
    if fields:
        attributes["error_fields"] = fields[:10]

    detail = " · ".join(_error_messages(data))
    if detail:
        attributes["error_detail"] = detail[:_MAX_ERROR_DETAIL]
    return attributes


def _error_messages(data, *, limit=3):
    """The leaf strings of a DRF error body, outermost keys first."""
    seen = []

    def walk(value, depth=0):
        if len(seen) >= limit or depth > 4:
            return
        if isinstance(value, str):
            text = value.strip()
            if text and text not in seen:
                seen.append(text)
            return
        if isinstance(value, (list, tuple)):
            for item in value:
                walk(item, depth + 1)
            return
        if isinstance(value, dict):
            for key, item in value.items():
                if key == "code":
                    continue
                walk(item, depth + 1)

    walk(data.get("detail"))
    for key, value in data.items():
        if key in ("detail", "code"):
            continue
        walk(value)
    return seen


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


def _should_record_request_event(request, *, status_code, severity):
    """Drop perf rows that carry no signal but arrive in floods.

    A 304 is a conditional-GET hit — the whole point of the ETag layer is that
    those cost nothing, so they must not each buy a DB write. Attachment
    *content* serves (product images) are the highest-volume 2xx endpoint once
    a catalog screen scrolls; keep only the slow/error ones.

    The ingest endpoint itself is excluded outright. Recording a telemetry row
    about the delivery of telemetry is circular, and in the field it was the
    single largest thing in the database: a client stuck in a rejection loop
    sent 5.1M ingest requests, and because each rejection was written down, the
    failure to store telemetry became 50% of the stored telemetry. Ingest still
    reports its 5xx through ``backend.response_error``, which is rare and
    genuinely diagnostic.
    """
    if status_code == 304:
        return False
    if _is_analytics_ingest_path(getattr(request, "path", "")):
        return False
    if severity == AnalyticsEvent.Severity.INFO and _is_attachment_content_path(
        getattr(request, "path", "")
    ):
        return False
    return True


def _is_analytics_ingest_path(path):
    return path.startswith("/api/analytics-events/ingest")


def _is_attachment_content_path(path):
    return path.startswith("/api/attachments/") and (
        path.endswith("/content/") or path.endswith("/content")
    )


# Field widths on AnalyticsEvent; headers are attacker-controlled, so truncate.
_DEVICE_ID_MAX = 64
_PLATFORM_MAX = 32
_APP_VERSION_MAX = 40
_USER_AGENT_MAX = 512


def _client_identity(request):
    """Who sent this, using only what an unauthenticated request still carries.

    Device and session used to be taken from the request's *session*, so a
    rejected request recorded nothing identifying at all — no ip, no device, no
    user agent. That is why 5.1M unauthenticated ingest calls could be measured
    precisely and still not be traced to a machine. The client now stamps its
    installation id on every request (PosApiSession.describeClient); the peer
    address and user agent are always available.
    """
    headers = getattr(request, "headers", {})
    meta = getattr(request, "META", {})
    device_id = str(headers.get("X-Pointy-Device-Id", "") or "")[:_DEVICE_ID_MAX]
    platform = str(headers.get("X-Pointy-Platform", "") or "")[:_PLATFORM_MAX]
    app_version = str(headers.get("X-Pointy-App-Version", "") or "")[:_APP_VERSION_MAX]
    user_agent = str(headers.get("User-Agent", "") or "")[:_USER_AGENT_MAX]
    # REMOTE_ADDR is the immediate peer, which is the honest answer: an
    # X-Forwarded-For a client can set is worse than none.
    raw_address = meta.get("REMOTE_ADDR") or ""
    identity = {  # noqa: E501 - keys mirror AnalyticsEvent's identity columns
        "session_id": getattr(getattr(request, "session", None), "session_key", "") or "",
        "trace_id": str(headers.get("X-Request-ID", "") or "")[:_DEVICE_ID_MAX],
        "device_id": device_id,
        "installation_id": device_id,
        "platform": platform,
        "app_version": app_version,
        "user_agent": user_agent,
        "request_path": str(getattr(request, "path", ""))[:256],
    }
    # ip_address is a GenericIPAddressField: an unparseable value would raise on
    # save, and these rows are written through a bulk buffer, so one malformed
    # address would take a whole batch of unrelated events down with it.
    if raw_address:
        try:
            validate_ipv46_address(raw_address)
        except ValidationError:
            pass
        else:
            identity["ip_address"] = raw_address
    return identity


def _safe_record_event(
    *,
    name,
    event_type,
    severity,
    user,
    request,
    attributes,
    metrics,
    buffered=False,
):
    record = record_event_buffered if buffered else record_event
    try:
        record(
            name=name,
            event_type=event_type,
            severity=severity,
            source=AnalyticsEvent.Source.BACKEND,
            user=user,
            attributes=attributes,
            metrics=metrics,
            **_client_identity(request),
        )
    except Exception:
        return
