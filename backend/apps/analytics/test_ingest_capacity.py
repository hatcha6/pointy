"""Telemetry must never be able to stop the shop selling.

On 2026-08-17 at 11:38 a signed-in till flushed a queued telemetry backlog.
Accepted ingest went 5 -> 292 -> 495 -> 2,123 -> 2,101 requests a minute and then
stopped. For those four minutes the shop's own traffic queued behind it:
``product-list`` took 104 seconds, ``backup-operations`` 7.9s, and the till could
not complete a sale. It was not the database (ingest spent 1.1% of its time
there); it was three uvicorn workers against 37 requests a second.
"""

from unittest import mock

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group
from django.core.cache import cache
from django.test import TestCase, override_settings
from django.urls import reverse
from rest_framework.test import APIClient

from apps.core.roles import MANAGER_GROUP, ensure_role_groups

from . import throttling


class IngestIsolationTestCase(TestCase):
    def setUp(self):
        ensure_role_groups()
        cache.clear()
        self.addCleanup(cache.clear)
        # The semaphore is process-global; make each test start clean.
        throttling._semaphore = None
        throttling._semaphore_limit = None
        self.addCleanup(setattr, throttling, "_semaphore", None)

        self.user = get_user_model().objects.create_user(
            username="till", password="pass"
        )
        self.user.groups.add(Group.objects.get(name=MANAGER_GROUP))
        self.client = APIClient()
        self.client.force_authenticate(self.user)

    def ingest(self, client=None):
        return (client or self.client).post(
            reverse("analytics-event-ingest"),
            {
                "events": [
                    {"name": "pos.checkout.completed", "event_type": "usage"}
                ]
            },
            format="json",
        )


@override_settings(POINTY_ANALYTICS_INGEST_CONCURRENCY=1)
class IngestConcurrencyTests(IngestIsolationTestCase):
    """A rate limit still admits a burst inside its window, and the burst is
    what buried the box. This bounds what is in flight."""

    def test_ingest_beyond_the_limit_is_refused_immediately(self):
        # Hold the only slot, as a request already being processed would.
        with throttling.ingest_capacity():
            response = self.ingest()

        self.assertEqual(response.status_code, 429)
        self.assertEqual(response.headers.get("Retry-After"), "60")

    def test_the_slot_is_returned_afterwards(self):
        """A leaked slot would wedge telemetry permanently — worse than the
        flood, because it never recovers."""
        with throttling.ingest_capacity():
            self.assertEqual(self.ingest().status_code, 429)

        self.assertEqual(self.ingest().status_code, 202)

    def test_a_slot_is_returned_even_when_the_request_fails(self):
        with mock.patch(
            "apps.analytics.views.ingest_events",
            side_effect=RuntimeError("boom"),
        ):
            with self.assertRaises(RuntimeError):
                self.ingest()

        self.assertEqual(self.ingest().status_code, 202)

    @override_settings(POINTY_ANALYTICS_INGEST_CONCURRENCY=0)
    def test_the_limit_can_be_switched_off(self):
        throttling._semaphore = None
        throttling._semaphore_limit = None

        with throttling.ingest_capacity():
            self.assertEqual(self.ingest().status_code, 202)


class IngestThrottleScopeTests(IngestIsolationTestCase):
    """Ingest gets its own bucket. Sharing the per-user ceiling is why the
    storm's 429s also landed on backup-destinations and backup-operations — the
    till spent its whole allowance on history and its real work was refused."""

    def test_ingest_does_not_use_the_shared_authenticated_ceiling(self):
        from apps.analytics.views import AnalyticsEventViewSet

        view = AnalyticsEventViewSet()
        view.action = "ingest"
        throttles = view.get_throttles()

        self.assertEqual(len(throttles), 1)
        self.assertIsInstance(throttles[0], throttling.AnalyticsIngestRateThrottle)
        self.assertEqual(throttles[0].scope, "analytics_ingest")

    def test_other_actions_keep_the_shared_ceiling(self):
        from apps.core.throttling import AuthenticatedBurstCeilingThrottle
        from apps.analytics.views import AnalyticsEventViewSet

        view = AnalyticsEventViewSet()
        view.action = "list"

        self.assertTrue(
            any(
                isinstance(t, AuthenticatedBurstCeilingThrottle)
                for t in view.get_throttles()
            )
        )

    def test_tills_are_counted_apart_by_device(self):
        """One till flushing a backlog must not spend another till's
        allowance."""
        throttle = throttling.AnalyticsIngestRateThrottle()

        class _Request:
            def __init__(self, device):
                self.headers = {"X-Pointy-Device-Id": device}
                self.user = None
                self.META = {"REMOTE_ADDR": "10.0.0.1"}

        first = throttle.get_cache_key(_Request("till-a"), None)
        second = throttle.get_cache_key(_Request("till-b"), None)

        self.assertNotEqual(first, second)
        self.assertIn("till-a", first)
