import csv
import io
import json
import zipfile
from decimal import Decimal
from uuid import uuid4

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group
from django.db import connection
from django.test import TestCase
from django.test.utils import CaptureQueriesContext
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

    def _manager_client(self):
        client = APIClient()
        client.force_authenticate(user=self.manager)
        return client

    def _occurred_at(self, day, hour=9):
        return timezone.datetime(
            2026,
            5,
            day,
            hour,
            0,
            tzinfo=timezone.get_current_timezone(),
        )

    def _create_event(
        self,
        *,
        name,
        occurred_at=None,
        event_type=AnalyticsEvent.EventType.USAGE,
        severity=AnalyticsEvent.Severity.INFO,
        source=AnalyticsEvent.Source.BACKEND,
        received_by=None,
        session_id="",
        risk_score=None,
    ):
        return AnalyticsEvent.objects.create(
            event_type=event_type,
            name=name,
            severity=severity,
            source=source,
            occurred_at=occurred_at or timezone.now(),
            received_by=received_by,
            session_id=session_id,
            risk_score=risk_score,
        )

    def _list_event_names(self, params):
        response = self._manager_client().get(reverse("analytics-event-list"), params)
        self.assertEqual(response.status_code, status.HTTP_200_OK, response.data)
        return [event["name"] for event in response.data["results"]]

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

        self.assertEqual(response.status_code, status.HTTP_202_ACCEPTED)
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

        self.assertEqual(first_response.status_code, status.HTTP_202_ACCEPTED)
        self.assertEqual(second_response.status_code, status.HTTP_202_ACCEPTED)
        # Ingest acknowledges optimistically (no per-request dedup SELECT);
        # idempotency is enforced at insert time by the unique client_event_id
        # constraint, so the repeat is silently skipped and never doubles the row.
        self.assertEqual(second_response.data["accepted"], 1)
        self.assertEqual(
            AnalyticsEvent.objects.filter(
                source=AnalyticsEvent.Source.FRONTEND
            ).count(),
            1,
        )

    def test_ingest_never_reads_back_the_events_table(self):
        # The old dedup SELECT (client_event_id__in) ran on the busiest endpoint
        # in the fleet and got slower as the events table grew. Ingest must now
        # only ever write the table, never read it.
        client = APIClient()
        client.force_authenticate(user=self.cashier)
        table = AnalyticsEvent._meta.db_table
        payload = {
            "events": [
                {
                    "client_event_id": str(uuid4()),
                    "event_type": "performance",
                    "name": "frontend.frame_timing",
                    "source": "frontend",
                    "metrics": {"frame_count": 3},
                }
                for _ in range(5)
            ]
        }

        with CaptureQueriesContext(connection) as queries:
            response = client.post(
                reverse("analytics-event-ingest"),
                payload,
                format="json",
            )

        self.assertEqual(response.status_code, status.HTTP_202_ACCEPTED)
        reads = [
            query
            for query in queries.captured_queries
            if table in query["sql"]
            and query["sql"].lstrip().upper().startswith("SELECT")
        ]
        self.assertEqual(reads, [], reads)
        self.assertEqual(
            AnalyticsEvent.objects.filter(name="frontend.frame_timing").count(), 5
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

    def test_manager_list_filters_activity_fields_and_ordering(self):
        self._create_event(
            name="app.old",
            occurred_at=self._occurred_at(19, 8),
            received_by=self.manager,
            session_id="register-0",
            risk_score=5,
        )
        self._create_event(
            name="sales.checkout.completed",
            occurred_at=self._occurred_at(20, 9),
            received_by=self.cashier,
            session_id="register-1",
            risk_score=82,
        )
        self._create_event(
            name="app.new",
            occurred_at=self._occurred_at(21, 10),
            received_by=self.manager,
            session_id="register-2",
            risk_score=40,
        )
        other_user = get_user_model().objects.create_user(
            username="analytics-other",
            password="pass",
        )
        self._create_event(
            name="other.user.event",
            occurred_at=self._occurred_at(22, 11),
            received_by=other_user,
        )

        self.assertEqual(
            self._list_event_names(
                {
                    "occurred_at_after": "2026-05-20T00:00:00Z",
                    "occurred_at_before": "2026-05-20T23:59:59Z",
                }
            ),
            ["sales.checkout.completed"],
        )
        self.assertEqual(
            self._list_event_names(
                {
                    "date_from": "2026-05-20T00:00:00Z",
                    "date_to": "2026-05-20T23:59:59Z",
                }
            ),
            ["sales.checkout.completed"],
        )
        self.assertEqual(
            self._list_event_names({"user": self.cashier.id}),
            ["sales.checkout.completed"],
        )
        self.assertEqual(
            self._list_event_names(
                {
                    "received_by": f"{self.manager.id},{self.cashier.id}",
                    "risk_score_min": 0,
                }
            ),
            ["app.new", "sales.checkout.completed", "app.old"],
        )
        self.assertEqual(
            self._list_event_names(
                {
                    "risk_score_min": 80,
                    "risk_score_max": 90,
                }
            ),
            ["sales.checkout.completed"],
        )
        self.assertEqual(
            self._list_event_names({"name": "sales.checkout.completed"}),
            ["sales.checkout.completed"],
        )
        self.assertEqual(
            self._list_event_names({"session_id": "register-1"}),
            ["sales.checkout.completed"],
        )
        self.assertEqual(
            self._list_event_names({"register_session": "register-1"}),
            ["sales.checkout.completed"],
        )
        self.assertEqual(
            self._list_event_names(
                {
                    "risk_score_min": 0,
                    "ordering": "occurred_at",
                }
            ),
            ["app.old", "sales.checkout.completed", "app.new"],
        )

    def test_manager_list_filters_by_action_categories(self):
        self._create_event(
            name="sale.void.risk",
            event_type=AnalyticsEvent.EventType.FRAUD_SIGNAL,
            occurred_at=self._occurred_at(20, 8),
        )
        action_names = {
            "pos_line_added": "pos.cart.line.added",
            "pos_line_deleted": "pos.cart.line.deleted",
            "pos_cart_cleared": "pos.cart.cleared",
            "purchase_line_added": "purchasing.draft.line.added",
            "purchase_line_deleted": "purchasing.draft.line.deleted",
            "purchase_draft_cleared": "purchasing.draft.cleared",
            "purchase_draft_submitted": "purchasing.draft.submitted",
            "invoice_created": "sales.checkout.completed",
            "customer_created": "customers.customer.created",
            "register_cash_movement": "sales.register_cash_movement.created",
            "register_session_started": "sales.register_session.started",
            "register_session_closed": "sales.register_session.closed",
            "receipt_reprinted": "sales.receipt.reprint.queued",
            "order_voided": "sales.order.voided",
            "order_returned": "sales.order.returned",
            "product_changed": "catalog.product.created",
            "stock_movement_created": "catalog.stock_movement.created",
            "barcode_labels_printed": "printing.barcode_labels.printed",
            "user_changed": "users.management.user.role_changed",
            "settings_changed": "settings.device.usage_mode_changed",
            "discount_changed": "discounts.rule.updated",
            "report_activity": "report.generated",
            "printer_activity": "printing.printer.tested",
            "analytics_export": "analytics.export.downloaded",
            "purchase_order_deleted": "purchasing.purchase_order.deleted",
        }
        for index, event_name in enumerate(action_names.values()):
            self._create_event(
                name=event_name,
                event_type=AnalyticsEvent.EventType.AUDIT,
                occurred_at=self._occurred_at(20 + index // 12, 8 + index % 12),
            )
        self._create_event(
            name="app.started",
            occurred_at=self._occurred_at(21, 9),
        )

        self.assertEqual(
            self._list_event_names({"action": "fraud_signal"}),
            ["sale.void.risk"],
        )
        for action_name, event_name in action_names.items():
            with self.subTest(action=action_name):
                expected_names = [event_name]
                if action_name == "printer_activity":
                    expected_names = [
                        "printing.printer.tested",
                        "printing.barcode_labels.printed",
                        "sales.receipt.reprint.queued",
                    ]
                self.assertEqual(
                    self._list_event_names({"action": action_name}),
                    expected_names,
                )
        self._create_event(
            name="pos.cart.line.quantity_increased",
            event_type=AnalyticsEvent.EventType.AUDIT,
            occurred_at=self._occurred_at(21, 9),
        )
        self._create_event(
            name="pos.cart.line.quantity_decreased",
            event_type=AnalyticsEvent.EventType.AUDIT,
            occurred_at=self._occurred_at(21, 10),
        )
        self.assertCountEqual(
            self._list_event_names({"action": "pos_line_quantity_changed"}),
            [
                "pos.cart.line.quantity_increased",
                "pos.cart.line.quantity_decreased",
            ],
        )
        self._create_event(
            name="purchasing.draft.line.quantity_increased",
            event_type=AnalyticsEvent.EventType.AUDIT,
            occurred_at=self._occurred_at(21, 11),
        )
        self._create_event(
            name="purchasing.draft.line.quantity_decreased",
            event_type=AnalyticsEvent.EventType.AUDIT,
            occurred_at=self._occurred_at(21, 12),
        )
        self.assertCountEqual(
            self._list_event_names({"action": "purchase_line_quantity_changed"}),
            [
                "purchasing.draft.line.quantity_increased",
                "purchasing.draft.line.quantity_decreased",
            ],
        )
        self.assertCountEqual(
            self._list_event_names({"action": "any_deleted"}),
            [
                "pos.cart.line.deleted",
                "purchasing.draft.line.deleted",
                "purchasing.purchase_order.deleted",
            ],
        )

    def test_manager_list_filters_reviewable_activity_scope(self):
        self._create_event(
            name="backend.request",
            event_type=AnalyticsEvent.EventType.PERFORMANCE,
            occurred_at=self._occurred_at(20, 8),
        )
        self._create_event(
            name="frontend.interaction",
            event_type=AnalyticsEvent.EventType.USAGE,
            occurred_at=self._occurred_at(20, 9),
        )
        self._create_event(
            name="sales.checkout.completed",
            event_type=AnalyticsEvent.EventType.AUDIT,
            occurred_at=self._occurred_at(20, 10),
        )
        self._create_event(
            name="sale.void.risk",
            event_type=AnalyticsEvent.EventType.FRAUD_SIGNAL,
            occurred_at=self._occurred_at(20, 11),
        )

        self.assertEqual(
            self._list_event_names({"activity_scope": "reviewable"}),
            ["sale.void.risk", "sales.checkout.completed"],
        )
        technical_names = self._list_event_names(
            {
                "activity_scope": "technical",
                "ordering": "occurred_at",
            }
        )
        self.assertIn("backend.request", technical_names)
        self.assertIn("frontend.interaction", technical_names)
        self.assertNotIn("sales.checkout.completed", technical_names)
        self.assertNotIn("sale.void.risk", technical_names)

    def test_manager_list_rejects_invalid_filter_ranges(self):
        invalid_queries = (
            {
                "occurred_at_after": "2026-05-21T00:00:00Z",
                "occurred_at_before": "2026-05-20T00:00:00Z",
            },
            {
                "date_from": "2026-05-21T00:00:00Z",
                "date_to": "2026-05-20T00:00:00Z",
            },
            {
                "risk_score_min": 90,
                "risk_score_max": 10,
            },
        )
        client = self._manager_client()

        for query in invalid_queries:
            with self.subTest(query=query):
                response = client.get(reverse("analytics-event-list"), query)
                self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)

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
        # Counted via execute_wrapper, not the DEBUG query log — so it must be
        # a real count even here (DEBUG=False), and it never touches
        # ``connection.queries`` (whose 9000-entry cap used to raise
        # "Limit for query logging exceeded" on batched ingests).
        self.assertGreater(event.metrics["db_query_count"], 0)
        self.assertGreaterEqual(event.metrics["db_time_ms"], 0)

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
