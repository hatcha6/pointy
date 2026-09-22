"""A crash on an API path has to arrive as something a client can read."""

import json

from django.conf import settings
from django.http import HttpResponse, JsonResponse, StreamingHttpResponse
from django.test import RequestFactory, SimpleTestCase
from django.views.defaults import ERROR_PAGE_TEMPLATE

from .api_errors import ApiErrorResponseMiddleware

#: Byte for byte what Django answers an unhandled exception with, and the whole
#: reason this middleware exists: it opens with a newline, so a client decoding
#: it as JSON fails at line 2, column 1 and never sees the status code at all.
DJANGO_HTML_500 = ERROR_PAGE_TEMPLATE % {"title": "Server Error (500)", "details": ""}


def _crashed(request, *, body=DJANGO_HTML_500, status=500, content_type="text/html"):
    return HttpResponse(body, status=status, content_type=content_type)


class ApiErrorResponseMiddlewareTests(SimpleTestCase):
    def setUp(self):
        self.factory = RequestFactory()

    def _run(self, request, response):
        return ApiErrorResponseMiddleware(lambda _request: response)(request)

    def test_the_html_page_django_sends_starts_a_line_too_late(self):
        """The premise, pinned: this is why the client reported a parse error."""
        self.assertTrue(DJANGO_HTML_500.startswith("\n<"))
        with self.assertRaises(json.JSONDecodeError) as ctx:
            json.loads(DJANGO_HTML_500)
        self.assertEqual((ctx.exception.lineno, ctx.exception.colno), (2, 1))

    def test_an_api_crash_is_answered_as_json(self):
        request = self.factory.put("/api/migration/sources/30/chunk/?offset=0")
        request._pointy_analytics_exception = {
            "error_type": "OSError",
            "error_message": "[Errno 28] No space left on device",
            "error_traceback": "Traceback (most recent call last): ...",
        }
        response = self._run(request, _crashed(request))

        self.assertEqual(response.status_code, 500)
        self.assertEqual(response.headers["Content-Type"], "application/json")
        payload = json.loads(response.content)
        self.assertEqual(payload["error_type"], "OSError")
        self.assertIn("No space left on device", payload["error_message"])
        self.assertTrue(payload["detail"])

    def test_the_traceback_stays_out_of_the_response(self):
        """It is recorded against the request; it is not shown to the till."""
        request = self.factory.get("/api/products/")
        request._pointy_analytics_exception = {
            "error_type": "ValueError",
            "error_message": "boom",
            "error_traceback": 'File "/app/backend/apps/secret.py", line 1',
        }
        response = self._run(request, _crashed(request))
        self.assertNotIn(b"Traceback", response.content)
        self.assertNotIn(b"secret.py", response.content)

    def test_a_crash_with_nothing_captured_still_answers_json(self):
        response = self._run(self.factory.get("/api/products/"), _crashed(None))
        self.assertEqual(response.headers["Content-Type"], "application/json")
        self.assertTrue(json.loads(response.content)["detail"])

    def test_state_version_headers_survive_the_replacement(self):
        """Clients revalidate caches against these; dropping them stales them."""
        crashed = _crashed(None)
        crashed["X-Pointy-State"] = "catalog=7"
        crashed["X-Pointy-Catalog-Version"] = "7"
        response = self._run(self.factory.get("/api/products/"), crashed)
        self.assertEqual(response["X-Pointy-State"], "catalog=7")
        self.assertEqual(response["X-Pointy-Catalog-Version"], "7")

    def test_a_json_error_a_view_built_itself_is_left_alone(self):
        original = JsonResponse({"detail": "deliberate"}, status=500)
        response = self._run(self.factory.get("/api/products/"), original)
        self.assertIs(response, original)

    def test_non_api_paths_are_left_alone(self):
        original = _crashed(None)
        self.assertIs(self._run(self.factory.get("/admin/"), original), original)

    def test_successful_responses_are_left_alone(self):
        original = HttpResponse("<p>fine</p>", content_type="text/html")
        self.assertIs(self._run(self.factory.get("/api/products/"), original), original)

    def test_a_streaming_response_is_left_alone(self):
        original = StreamingHttpResponse(iter([b"a"]), status=500)
        self.assertIs(self._run(self.factory.get("/api/ai/stream/"), original), original)


class MiddlewareOrderTests(SimpleTestCase):
    """Where this sits in the stack is load-bearing, so it is pinned here."""

    MINE = "apps.core.api_errors.ApiErrorResponseMiddleware"
    ANALYTICS = "apps.analytics.middleware.BackendPerformanceAnalyticsMiddleware"

    def test_it_is_installed(self):
        self.assertIn(self.MINE, settings.MIDDLEWARE)

    def test_it_wraps_the_analytics_middleware(self):
        """Analytics has to see the real 500, not the JSON put in its place.

        It reads ``response.status_code`` and pairs it with the traceback the
        ``got_request_exception`` receiver stashed. Replacing the response
        underneath it would still be a 500, but re-ordering these two is the
        kind of change that silently costs the traceback, so it is asserted
        rather than left to the list's shape.
        """
        self.assertLess(
            settings.MIDDLEWARE.index(self.MINE),
            settings.MIDDLEWARE.index(self.ANALYTICS),
        )
