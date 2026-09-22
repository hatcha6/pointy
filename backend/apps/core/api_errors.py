"""What an API client is told when a request crashes.

Django answers an unhandled exception with ``ERROR_PAGE_TEMPLATE`` — an HTML
document that opens with a newline. Every Pointy client decodes an API body as
JSON, so what a cashier actually saw was::

    FormatException: Unexpected character (at line 2, character 1)

which is the app failing to parse ``\\n<!doctype html>``. It names no endpoint,
no error and no server; it is indistinguishable from a proxy's 502 page; and it
sent a real shop chasing a JSON bug while the server was reporting something
else entirely. The status code was not even visible, because the parse happens
before the client looks at it.

The exception itself was never lost — ``apps.analytics.middleware`` catches
``got_request_exception`` and records the type, message and traceback against
the request. That reaches an export days later. It does not reach the person
standing at the till, which is where the diagnosis has to start.

So this middleware re-answers a 500 on an API path in the shape every client
already reads: ``detail`` for a human, ``error_type`` and ``error_message`` for
whoever is diagnosing it. The traceback stays out of the response and in the
analytics row, where it is already kept.

It works on the *response* rather than through ``process_exception`` on
purpose. Returning a response from that hook would stop Django raising, and
``got_request_exception`` would never fire — buying a readable error at the cost
of the recorded traceback. Reading the attribute that signal leaves behind keeps
both.
"""

from __future__ import annotations

from django.http import JsonResponse

#: Where apps.analytics.middleware stashes the exception it captured.
_EXCEPTION_ATTR = "_pointy_analytics_exception"

#: Shown to whoever is holding the device. The specifics follow in the fields
#: beside it; this is the sentence, not the diagnosis.
_DETAIL = "حدث خطأ غير متوقع في الخادم. أعد المحاولة، وإن تكرر فأرسل هذه الرسالة للدعم."


class ApiErrorResponseMiddleware:
    """Re-answer an unhandled 500 on an API path as JSON."""

    def __init__(self, get_response):
        self.get_response = get_response

    def __call__(self, request):
        response = self.get_response(request)
        if not self._should_replace(request, response):
            return response
        captured = getattr(request, _EXCEPTION_ATTR, None) or {}
        payload = {"detail": _DETAIL}
        error_type = str(captured.get("error_type", "") or "")
        error_message = str(captured.get("error_message", "") or "")
        if error_type:
            payload["error_type"] = error_type
        if error_message:
            payload["error_message"] = error_message[:512]
        trace_id = str(request.headers.get("X-Request-ID", "") or "")[:128]
        if trace_id:
            payload["trace_id"] = trace_id
        replacement = JsonResponse(payload, status=response.status_code)
        # Carry over the headers this application stamped. The state-version
        # vector is the one that matters: a client revalidates its caches
        # against it, and dropping it on every crash would quietly stale them.
        # Nothing else is copied — Content-Type and Content-Length describe the
        # body that was just replaced.
        for header, value in response.items():
            if header.lower().startswith("x-pointy-"):
                replacement[header] = value
        return replacement

    def _should_replace(self, request, response) -> bool:
        if response.status_code != 500:
            return False
        if not request.path.startswith("/api/"):
            return False
        # A view that already answered in JSON (DRF's own 500, or an endpoint
        # that builds one deliberately) is left exactly as it is.
        content_type = str(response.headers.get("Content-Type", "") or "")
        if "json" in content_type.lower():
            return False
        # Streaming responses have no body to inspect or replace safely; a
        # crash mid-stream is a different problem with a different fix.
        return not getattr(response, "streaming", False)
