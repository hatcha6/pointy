"""Tests for the buffered backend.request telemetry path (buffer.py).

Buffering is disabled under the test runner (POINTY_ANALYTICS_BUFFER_SIZE is
forced to 0 — see TESTING in settings) so the rest of the suite keeps seeing
rows synchronously; every test here opts back in explicitly.
"""

from unittest import mock

from django.contrib.auth.models import User
from django.test import RequestFactory, TestCase, override_settings
from rest_framework import status
from rest_framework.test import APIClient

from apps.analytics import buffer
from apps.analytics.middleware import _should_record_request_event
from apps.analytics.models import AnalyticsEvent
from apps.analytics.services import record_event_buffered


class BufferTests(TestCase):
    def setUp(self):
        buffer.reset()

    def tearDown(self):
        buffer.reset()

    @override_settings(
        POINTY_ANALYTICS_BUFFER_SIZE=3,
        POINTY_ANALYTICS_BUFFER_MAX_AGE_SECONDS=3600,
    )
    def test_rows_accumulate_until_the_buffer_fills_then_bulk_insert(self):
        record_event_buffered(name="backend.request")
        record_event_buffered(name="backend.request")
        self.assertEqual(AnalyticsEvent.objects.count(), 0)

        with self.assertNumQueries(1):  # one bulk INSERT for the whole batch
            record_event_buffered(name="backend.request")
        self.assertEqual(AnalyticsEvent.objects.count(), 3)

    @override_settings(
        POINTY_ANALYTICS_BUFFER_SIZE=100,
        POINTY_ANALYTICS_BUFFER_MAX_AGE_SECONDS=0,
    )
    def test_stale_buffer_flushes_on_the_next_enqueue(self):
        record_event_buffered(name="backend.request")
        self.assertEqual(AnalyticsEvent.objects.count(), 1)

    def test_size_zero_inserts_synchronously(self):
        # The TESTING default: no buffering at all.
        record_event_buffered(name="backend.request")
        self.assertEqual(AnalyticsEvent.objects.count(), 1)

    @override_settings(
        POINTY_ANALYTICS_BUFFER_SIZE=100,
        POINTY_ANALYTICS_BUFFER_MAX_AGE_SECONDS=3600,
    )
    def test_flush_drains_the_tail(self):
        record_event_buffered(name="backend.request")
        self.assertEqual(AnalyticsEvent.objects.count(), 0)
        buffer.flush()
        self.assertEqual(AnalyticsEvent.objects.count(), 1)

    @override_settings(
        POINTY_ANALYTICS_BUFFER_SIZE=2,
        POINTY_ANALYTICS_BUFFER_MAX_AGE_SECONDS=3600,
    )
    def test_failed_bulk_insert_drops_the_batch_without_raising(self):
        with mock.patch.object(
            AnalyticsEvent.objects, "bulk_create", side_effect=Exception("db down")
        ):
            record_event_buffered(name="backend.request")
            record_event_buffered(name="backend.request")  # triggers the flush

        self.assertEqual(AnalyticsEvent.objects.count(), 0)
        # The failed batch must have been discarded, not retained for retry.
        record_event_buffered(name="backend.request")
        record_event_buffered(name="backend.request")
        self.assertEqual(AnalyticsEvent.objects.count(), 2)

    @override_settings(
        POINTY_ANALYTICS_BUFFER_SIZE=3,
        POINTY_ANALYTICS_BUFFER_MAX_AGE_SECONDS=3600,
    )
    def test_buffered_rows_keep_their_payload(self):
        user = User.objects.create_user(username="cashier", password="x")
        for index in range(3):
            record_event_buffered(
                name="backend.request",
                event_type=AnalyticsEvent.EventType.PERFORMANCE,
                user=user,
                attributes={"index": index},
                metrics={"duration_ms": 12.5},
            )
        rows = AnalyticsEvent.objects.order_by("id")
        self.assertEqual(rows.count(), 3)
        for index, row in enumerate(rows):
            self.assertEqual(row.received_by, user)
            self.assertEqual(row.attributes, {"index": index})
            self.assertEqual(row.metrics, {"duration_ms": 12.5})
            self.assertIsNotNone(row.created_at)  # auto_now_add under bulk_create


class RequestEventSkipTests(TestCase):
    """The middleware drops perf rows that arrive in floods but carry no signal."""

    def _request(self, path="/api/products/"):
        return RequestFactory().get(path)

    def test_304_revalidations_are_never_recorded(self):
        self.assertFalse(
            _should_record_request_event(
                self._request(),
                status_code=304,
                severity=AnalyticsEvent.Severity.INFO,
            )
        )

    def test_healthy_attachment_content_serves_are_not_recorded(self):
        self.assertFalse(
            _should_record_request_event(
                self._request("/api/attachments/42/content/"),
                status_code=200,
                severity=AnalyticsEvent.Severity.INFO,
            )
        )

    def test_slow_or_failing_attachment_serves_are_still_recorded(self):
        request = self._request("/api/attachments/42/content/")
        self.assertTrue(
            _should_record_request_event(
                request,
                status_code=200,
                severity=AnalyticsEvent.Severity.WARNING,  # slow
            )
        )
        self.assertTrue(
            _should_record_request_event(
                request,
                status_code=404,
                severity=AnalyticsEvent.Severity.WARNING,
            )
        )

    def test_ordinary_api_requests_are_recorded(self):
        self.assertTrue(
            _should_record_request_event(
                self._request(),
                status_code=200,
                severity=AnalyticsEvent.Severity.INFO,
            )
        )

    def test_non_content_attachment_routes_are_recorded(self):
        self.assertTrue(
            _should_record_request_event(
                self._request("/api/attachments/42/"),
                status_code=200,
                severity=AnalyticsEvent.Severity.INFO,
            )
        )


class MiddlewareBufferingIntegrationTests(TestCase):
    def setUp(self):
        buffer.reset()

    def tearDown(self):
        buffer.reset()

    @override_settings(
        POINTY_ANALYTICS_BUFFER_SIZE=1000,
        POINTY_ANALYTICS_BUFFER_MAX_AGE_SECONDS=3600,
    )
    def test_backend_request_rows_ride_the_buffer(self):
        user = User.objects.create_user(username="manager", password="x")
        client = APIClient()
        client.force_login(user)

        response = client.get("/api/auth/me/")

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertFalse(
            AnalyticsEvent.objects.filter(name="backend.request").exists()
        )
        buffer.flush()
        event = AnalyticsEvent.objects.filter(name="backend.request").latest("id")
        self.assertEqual(event.attributes["path"], "/api/auth/me/")
        self.assertEqual(event.received_by, user)
