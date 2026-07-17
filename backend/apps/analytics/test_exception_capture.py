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


urlpatterns = [
    path("api/boom/", boom_view),
    path("api/fine/", healthy_view),
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
