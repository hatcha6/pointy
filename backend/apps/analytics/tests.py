import csv
import io
import json
import zipfile
from decimal import Decimal
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
from .services import record_domain_event


class AnalyticsEventApiTests(TestCase):
    def setUp(self):
        ensure_role_groups()
        User = get_user_model()
        self.manager = User.objects.create_user(
            username="analytics-manager", password="pass"
        )
        self.manager.groups.add(Group.objects.get(name=MANAGER_GROUP))
        self.cashier = User.objects.create_user(
            username="analytics-cashier", password="pass"
        )
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
            AnalyticsEvent.objects.filter(
                source=AnalyticsEvent.Source.FRONTEND
            ).count(),
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

    def test_manager_can_export_filtered_events_zip(self):
        sale_event = AnalyticsEvent.objects.create(
            event_type=AnalyticsEvent.EventType.FRAUD_SIGNAL,
            name="sale.void.risk",
            severity=AnalyticsEvent.Severity.WARNING,
            source=AnalyticsEvent.Source.BACKEND,
            occurred_at=timezone.datetime(
                2026,
                5,
                20,
                9,
                0,
                tzinfo=timezone.get_current_timezone(),
            ),
            received_by=self.cashier,
            platform="django",
            session_id="register-1",
            device_id="terminal-1",
            entity_type="sale_order",
            entity_id="42",
            risk_score=82,
            attributes={"reason": "large_void"},
            metrics={"risk": 82},
        )
        AnalyticsEvent.objects.create(
            event_type=AnalyticsEvent.EventType.USAGE,
            name="app.started",
            severity=AnalyticsEvent.Severity.INFO,
            source=AnalyticsEvent.Source.FRONTEND,
            occurred_at=timezone.datetime(
                2026,
                5,
                21,
                9,
                0,
                tzinfo=timezone.get_current_timezone(),
            ),
            received_by=self.manager,
            entity_type="session",
            entity_id="register:1",
            risk_score=10,
        )
        client = APIClient()
        client.force_authenticate(user=self.manager)

        response = client.get(
            reverse("analytics-event-export"),
            {
                "event_type": "fraud_signal",
                "source": "backend",
                "severity": "warning",
                "name": "sale.void.risk",
                "user": self.cashier.id,
                "date_from": "2026-05-20T00:00:00Z",
                "date_to": "2026-05-20T23:59:59Z",
                "platform": "django",
                "session_id": "register-1",
                "device_id": "terminal-1",
                "search": "void",
                "entity_type": "sale_order",
                "entity_id": "42",
                "risk_score_min": 80,
                "risk_score_max": 90,
            },
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(response["Content-Type"], "application/zip")
        self.assertEqual(response["X-Pointy-Analytics-Event-Count"], "1")
        self.assertIn("attachment;", response["Content-Disposition"])

        archive = zipfile.ZipFile(io.BytesIO(response.content))
        self.assertEqual(
            sorted(archive.namelist()),
            ["analytics_events.csv", "manifest.json"],
        )
        rows = list(
            csv.DictReader(io.StringIO(archive.read("analytics_events.csv").decode()))
        )
        manifest = json.loads(archive.read("manifest.json").decode())

        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]["id"], str(sale_event.id))
        self.assertEqual(rows[0]["name"], "sale.void.risk")
        self.assertEqual(rows[0]["received_by_username"], "analytics-cashier")
        self.assertEqual(rows[0]["risk_score"], "82")
        self.assertEqual(json.loads(rows[0]["attributes"])["reason"], "large_void")
        self.assertEqual(manifest["event_count"], 1)
        self.assertEqual(manifest["generated_by"]["username"], "analytics-manager")
        self.assertEqual(manifest["filters"]["received_by"], self.cashier.id)
        self.assertEqual(manifest["filters"]["format"], "csv")
        self.assertEqual(manifest["filters"]["risk_score_min"], 80)

    def test_manager_can_export_json_inside_zip(self):
        event = AnalyticsEvent.objects.create(
            event_type=AnalyticsEvent.EventType.PERFORMANCE,
            name="frontend.operation",
            severity=AnalyticsEvent.Severity.INFO,
            source=AnalyticsEvent.Source.FRONTEND,
            occurred_at=timezone.now(),
            received_by=self.manager,
            platform="flutter-web",
            session_id="session-1",
            device_id="device-1",
            metrics={"duration_ms": 42},
        )
        client = APIClient()
        client.force_authenticate(user=self.manager)

        response = client.get(
            reverse("analytics-event-export"),
            {
                "format": "json",
                "platform": "flutter-web",
                "session_id": "session-1",
                "device_id": "device-1",
                "search": "operation",
            },
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        archive = zipfile.ZipFile(io.BytesIO(response.content))
        self.assertEqual(
            sorted(archive.namelist()),
            ["analytics_events.json", "manifest.json"],
        )
        rows = json.loads(archive.read("analytics_events.json").decode())
        manifest = json.loads(archive.read("manifest.json").decode())

        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]["id"], event.id)
        self.assertEqual(rows[0]["platform"], "flutter-web")
        self.assertEqual(manifest["filters"]["format"], "json")

    def test_cashier_cannot_export_events(self):
        client = APIClient()
        client.force_authenticate(user=self.cashier)

        response = client.get(reverse("analytics-event-export"))

        self.assertEqual(response.status_code, status.HTTP_403_FORBIDDEN)

    def test_export_rejects_invalid_filter_ranges(self):
        client = APIClient()
        client.force_authenticate(user=self.manager)

        response = client.get(
            reverse("analytics-event-export"),
            {
                "risk_score_min": 90,
                "risk_score_max": 10,
            },
        )

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)

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
            AnalyticsEvent.objects.filter(
                source=AnalyticsEvent.Source.FRONTEND
            ).count(),
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

    def test_domain_event_records_after_commit_with_json_safe_payload(self):
        occurred_at = timezone.now()

        with self.captureOnCommitCallbacks(execute=True) as callbacks:
            record_domain_event(
                name="settings.shop.updated",
                user=self.manager,
                entity_type="shop_settings",
                entity_id=1,
                attributes={
                    "amount": Decimal("12.50"),
                    "occurred_at": occurred_at,
                },
                metrics={"amount": Decimal("12.50")},
            )

        self.assertEqual(len(callbacks), 1)
        event = AnalyticsEvent.objects.get(name="settings.shop.updated")
        self.assertEqual(event.event_type, AnalyticsEvent.EventType.AUDIT)
        self.assertEqual(event.received_by, self.manager)
        self.assertEqual(event.entity_type, "shop_settings")
        self.assertEqual(event.entity_id, "1")
        self.assertEqual(event.attributes["amount"], "12.50")
        self.assertEqual(event.attributes["occurred_at"], occurred_at.isoformat())
        self.assertEqual(event.metrics["amount"], "12.50")
