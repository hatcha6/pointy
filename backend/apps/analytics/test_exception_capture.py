"""A recorded 500 must carry the reason it happened.

Django converts a view's exception into a 500 response *inside* the middleware
chain, so the middleware only ever sees the response. Without the
``got_request_exception`` hook, every 5xx row said "something broke" and nothing
more — which is exactly what made a 5xx flood on the busiest endpoint
undiagnosable from tracking.
"""

from django.http import HttpResponse
from django.test import TestCase, override_settings
from django.urls import path

from apps.analytics.models import AnalyticsEvent


def boom_view(request):
    raise RuntimeError("kaboom from the view")


def healthy_view(request):
    return HttpResponse("fine")


def refusing_view(request):
    """A 5xx that raises nothing — a proxy timeout handed back as a response.

    The shape that mattered in the field: the camera live view returns 502 when
    the recorder does not answer, and returns it *normally*.
    """
    return HttpResponse("upstream said no", status=502)


urlpatterns = [
    path("api/boom/", boom_view),
    path("api/fine/", healthy_view),
    path("api/refused/", refusing_view),
    path("api/analytics-events/ingest/", refusing_view),
]


@override_settings(ROOT_URLCONF=__name__, DEBUG=False)
class ViewExceptionCaptureTests(TestCase):
    def _crash(self):
        try:
            self.client.get("/api/boom/")
        except RuntimeError:
            # The test client re-raises the view's exception; the middleware has
            # already recorded by this point.
            pass

    def test_response_error_carries_the_exception(self):
        self._crash()

        event = AnalyticsEvent.objects.get(name="backend.response_error")
        self.assertEqual(event.attributes["status_family"], "5xx")
        self.assertEqual(event.attributes["error_type"], "RuntimeError")
        self.assertEqual(event.attributes["error_message"], "kaboom from the view")
        self.assertIn("boom_view", event.attributes["error_traceback"])

    def test_healthy_requests_carry_no_exception_fields(self):
        response = self.client.get("/api/fine/")

        self.assertEqual(response.status_code, 200)
        self.assertFalse(
            AnalyticsEvent.objects.filter(name="backend.response_error").exists()
        )
        self.assertNotIn(
            "error_type",
            AnalyticsEvent.objects.get(name="backend.request").attributes,
        )

    def test_exception_state_does_not_leak_between_requests(self):
        self._crash()
        AnalyticsEvent.objects.all().delete()

        self.client.get("/api/fine/")

        self.assertNotIn(
            "error_type",
            AnalyticsEvent.objects.get(name="backend.request").attributes,
        )


@override_settings(ROOT_URLCONF=__name__, DEBUG=False)
class OneRowPerFailedRequestTests(TestCase):
    """A 5xx that raised nothing does not need saying twice.

    Both rows were written for every 5xx, and when nothing was raised the
    second was a byte-for-byte copy of the first — same attributes, same
    metrics, same moment. One shop's week: 95,345 request rows at 5xx and
    95,356 response-error rows, 45.7% of the whole export, and thirteen of
    those 95,356 carried an exception. The rest said nothing the request row
    had not already said.
    """

    def test_a_5xx_with_no_exception_is_recorded_once(self):
        response = self.client.get("/api/refused/")

        self.assertEqual(response.status_code, 502)
        request_rows = AnalyticsEvent.objects.filter(name="backend.request")
        self.assertEqual(request_rows.count(), 1)
        self.assertFalse(
            AnalyticsEvent.objects.filter(name="backend.response_error").exists()
        )

    def test_the_surviving_row_still_says_it_failed(self):
        """Dropping the duplicate must not cost the diagnosis: everything the
        second row carried for a raise-less 5xx was already on the first."""
        self.client.get("/api/refused/")

        event = AnalyticsEvent.objects.get(name="backend.request")
        self.assertEqual(event.severity, AnalyticsEvent.Severity.ERROR)
        self.assertEqual(event.attributes["status_family"], "5xx")
        self.assertEqual(event.metrics["status_code"], 502)

    def test_a_5xx_that_raised_still_writes_both(self):
        """The exception row is the one that carries a traceback, so it stays."""
        try:
            self.client.get("/api/boom/")
        except RuntimeError:
            pass

        self.assertTrue(
            AnalyticsEvent.objects.filter(name="backend.request").exists()
        )
        self.assertTrue(
            AnalyticsEvent.objects.filter(name="backend.response_error").exists()
        )

    def test_an_ingest_failure_is_still_recorded(self):
        """Ingest writes no request row at all — recording telemetry about
        delivering telemetry is how a rejection loop became half the database —
        so for that path the error row is the only row, raised or not."""
        response = self.client.post("/api/analytics-events/ingest/")

        self.assertEqual(response.status_code, 502)
        self.assertFalse(
            AnalyticsEvent.objects.filter(name="backend.request").exists()
        )
        error = AnalyticsEvent.objects.get(name="backend.response_error")
        self.assertEqual(error.metrics["status_code"], 502)
