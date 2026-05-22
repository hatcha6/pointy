from uuid import uuid4

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group
from django.test import TestCase
from django.urls import reverse
from django.utils import timezone
from rest_framework import status
from rest_framework.test import APIClient

from apps.core.roles import CASHIER_GROUP, MANAGER_GROUP, ensure_role_groups

from .models import AnalyticsEvent


class AnalyticsEventApiTests(TestCase):
    def setUp(self):
        ensure_role_groups()
        User = get_user_model()
        self.manager = User.objects.create_user(username="analytics-manager", password="pass")
        self.manager.groups.add(Group.objects.get(name=MANAGER_GROUP))
        self.cashier = User.objects.create_user(username="analytics-cashier", password="pass")
        self.cashier.groups.add(Group.objects.get(name=CASHIER_GROUP))

    def test_cashier_can_ingest_usage_event(self):
        client = APIClient()
        client.force_authenticate(user=self.cashier)
        event_id = str(uuid4())

        response = client.post(
            reverse("analytics-event-ingest"),
            {
                "events": [
                    {
                        "client_event_id": event_id,
                        "event_type": "usage",
                        "name": "pos.checkout.completed",
                        "severity": "info",
                        "source": "frontend",
                        "occurred_at": timezone.now().isoformat(),
                        "session_id": "register:1",
                        "device_id": "terminal-1",
                        "installation_id": "shop-1",
                        "platform": "flutter-web",
                        "entity_type": "sale_order",
                        "entity_id": "42",
                        "attributes": {"payment_method_count": 1},
                        "metrics": {"total": 12.5},
                    }
                ]
            },
            format="json",
            HTTP_USER_AGENT="Pointy test",
            REMOTE_ADDR="127.0.0.1",
        )

        self.assertEqual(response.status_code, status.HTTP_201_CREATED)
        self.assertEqual(response.data["accepted"], 1)
        event = AnalyticsEvent.objects.get(client_event_id=event_id)
        self.assertEqual(event.received_by, self.cashier)
        self.assertEqual(event.request_path, "/api/analytics-events/ingest/")
        self.assertEqual(event.ip_address, "127.0.0.1")
        self.assertEqual(event.attributes["payment_method_count"], 1)
        self.assertEqual(event.metrics["total"], 12.5)

    def test_ingest_is_idempotent_by_client_event_id(self):
        client = APIClient()
        client.force_authenticate(user=self.cashier)
        event_id = str(uuid4())
        payload = {
            "events": [
                {
                    "client_event_id": event_id,
                    "event_type": "error",
                    "name": "app.flutter_error",
                    "severity": "error",
                    "source": "frontend",
                    "attributes": {"message": "boom"},
                    "metrics": {},
                }
            ]
        }

        first_response = client.post(
            reverse("analytics-event-ingest"),
            payload,
            format="json",
        )
        second_response = client.post(
            reverse("analytics-event-ingest"),
            payload,
            format="json",
        )

        self.assertEqual(first_response.status_code, status.HTTP_201_CREATED)
        self.assertEqual(second_response.status_code, status.HTTP_201_CREATED)
        self.assertEqual(second_response.data["accepted"], 0)
        self.assertEqual(second_response.data["duplicates"], 1)
        self.assertEqual(
            AnalyticsEvent.objects.filter(source=AnalyticsEvent.Source.FRONTEND).count(),
            1,
        )

    def test_manager_can_list_events_and_cashier_cannot(self):
        AnalyticsEvent.objects.create(
            event_type=AnalyticsEvent.EventType.USAGE,
            name="app.started",
            severity=AnalyticsEvent.Severity.INFO,
            source=AnalyticsEvent.Source.FRONTEND,
            occurred_at=timezone.now(),
            received_by=self.cashier,
        )
        manager_client = APIClient()
        manager_client.force_authenticate(user=self.manager)
        cashier_client = APIClient()
        cashier_client.force_authenticate(user=self.cashier)

        manager_response = manager_client.get(reverse("analytics-event-list"))
        cashier_response = cashier_client.get(reverse("analytics-event-list"))

        self.assertEqual(manager_response.status_code, status.HTTP_200_OK)
        self.assertEqual(manager_response.data["results"][0]["name"], "app.started")
        self.assertEqual(cashier_response.status_code, status.HTTP_403_FORBIDDEN)

    def test_ingest_rejects_invalid_event_payloads(self):
        client = APIClient()
        client.force_authenticate(user=self.cashier)

        response = client.post(
            reverse("analytics-event-ingest"),
            {
                "events": [
                    {
                        "event_type": "fraud_signal",
                        "name": "sale.void.risk",
                        "risk_score": 101,
                        "attributes": [],
                        "metrics": {"risk": "high"},
                    }
                ]
            },
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertEqual(
            AnalyticsEvent.objects.filter(source=AnalyticsEvent.Source.FRONTEND).count(),
            0,
        )

    def test_backend_performance_middleware_records_api_timings(self):
        client = APIClient()
        client.force_login(self.manager)

        response = client.get(reverse("auth-me"))

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        event = AnalyticsEvent.objects.filter(name="backend.request").latest("id")
        self.assertEqual(event.event_type, AnalyticsEvent.EventType.PERFORMANCE)
        self.assertEqual(event.source, AnalyticsEvent.Source.BACKEND)
        self.assertEqual(event.received_by, self.manager)
        self.assertEqual(event.attributes["method"], "GET")
        self.assertEqual(event.attributes["path"], "/api/auth/me/")
        self.assertEqual(event.attributes["status_family"], "2xx")
        self.assertEqual(event.metrics["status_code"], 200)
        self.assertIn("duration_ms", event.metrics)
        self.assertIn("db_query_count", event.metrics)
