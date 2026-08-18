import csv
import io
import json
import unittest
import zipfile
from decimal import Decimal
from uuid import uuid4

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group
from django.db import connection
from django.test import TestCase, TransactionTestCase, override_settings
from django.test.utils import CaptureQueriesContext
from django.urls import reverse
from django.utils import timezone
from rest_framework import status
from rest_framework.test import APIClient

from apps.core.roles import CASHIER_GROUP, MANAGER_GROUP, ensure_role_groups

from .export import build_copy_statement, build_export_sql, wrap_ndjson_as_json_array
from .models import AnalyticsEvent
from .services import (
    ANALYTICS_EXPORT_CSV_FIELDS,
    filter_events_for_export,
    iter_events_export_zip,
    record_domain_event,
)


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
                # The exact pre-count is opt-in now (it is a full scan); the
                # manifest carries it for free on every export.
                "count": "exact",
            },
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(response["Content-Type"], "application/zip")
        self.assertEqual(response["X-Pointy-Analytics-Event-Count"], "1")
        self.assertIn("attachment;", response["Content-Disposition"])

        archive = zipfile.ZipFile(io.BytesIO(b"".join(response.streaming_content)))
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
        archive = zipfile.ZipFile(io.BytesIO(b"".join(response.streaming_content)))
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

    def test_export_accepts_explicit_csv_format_param(self):
        """``?format=csv`` must reach the view, not DRF's renderer override.

        The app always sends ``format`` (csv is its default); DRF's default
        negotiation used to read it as a renderer name and 404 before the
        view ran — no "csv" renderer exists.
        """
        AnalyticsEvent.objects.create(
            event_type=AnalyticsEvent.EventType.USAGE,
            name="app.started",
            severity=AnalyticsEvent.Severity.INFO,
            source=AnalyticsEvent.Source.FRONTEND,
            occurred_at=timezone.now(),
        )

        response = self._manager_client().get(
            reverse("analytics-event-export"), {"format": "csv"}
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(response["Content-Type"], "application/zip")
        archive = zipfile.ZipFile(io.BytesIO(b"".join(response.streaming_content)))
        self.assertIn("analytics_events.csv", archive.namelist())

    def test_export_zip_streams_keyset_batches_with_bounded_queries(self):
        events = [
            AnalyticsEvent.objects.create(
                event_type=AnalyticsEvent.EventType.USAGE,
                name="app.started",
                severity=AnalyticsEvent.Severity.INFO,
                source=AnalyticsEvent.Source.FRONTEND,
                occurred_at=timezone.now(),
                received_by=self.manager if index % 2 else None,
                attributes={"index": index},
            )
            for index in range(7)
        ]

        queryset = filter_events_for_export(AnalyticsEvent.objects.all(), {})
        with CaptureQueriesContext(connection) as queries:
            chunks = list(
                iter_events_export_zip(
                    queryset=queryset,
                    # engine=orm: this test is about the fallback exporter's
                    # batching. Postgres installs stream through COPY instead,
                    # which issues one statement and is covered separately.
                    filters={"format": "csv", "engine": "orm"},
                    exported_by=self.manager,
                    batch_size=3,
                )
            )

        # 7 rows at batch_size=3 → exactly 3 keyset queries, regardless of the
        # table size: the export must never materialize the whole result set.
        self.assertEqual(len(queries.captured_queries), 3)

        archive = zipfile.ZipFile(io.BytesIO(b"".join(chunks)))
        rows = list(
            csv.DictReader(io.StringIO(archive.read("analytics_events.csv").decode()))
        )
        manifest = json.loads(archive.read("manifest.json").decode())

        self.assertEqual(
            [int(row["id"]) for row in rows],
            sorted(event.id for event in events),
        )
        self.assertEqual(
            [json.loads(row["attributes"])["index"] for row in rows],
            list(range(7)),
        )
        self.assertEqual(
            {row["received_by_username"] for row in rows},
            {"", "analytics-manager"},
        )
        self.assertEqual(manifest["event_count"], 7)

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


@unittest.skipUnless(
    connection.vendor == "postgresql",
    "The COPY export engine is Postgres-only; SQLite installs use the ORM path.",
)
class AnalyticsExportCopyEngineTests(TestCase):
    """The COPY engine must be a drop-in for the ORM exporter.

    Everything about the fast path is a rewrite of how bytes are produced —
    Postgres formats the rows instead of Python — so the only thing worth
    testing is that the bytes still say the same thing. Each test exports the
    same events twice (``engine=orm`` vs the default) and compares the parsed
    results, with a fixture chosen to break naive escaping: quotes, backslashes,
    embedded newlines and tabs, Arabic text, and NULLs in every nullable column.
    """

    maxDiff = None

    #: Every fixture carries this in ``trace_id`` and every export filters on
    #: it. Without that, the buffered ``backend.request`` telemetry these very
    #: API calls produce can land in the table mid-test and change the counts.
    MARKER = "copy-parity-fixture"

    def setUp(self):
        ensure_role_groups()
        User = get_user_model()
        self.manager = User.objects.create_user(
            username="copy-export-manager", password="pass"
        )
        self.manager.groups.add(Group.objects.get(name=MANAGER_GROUP))
        self.client = APIClient()
        self.client.force_authenticate(user=self.manager)

    def _create_events(self):
        base = timezone.now()
        return [
            AnalyticsEvent.objects.create(
                event_type=AnalyticsEvent.EventType.ERROR,
                name="frontend.http_request",
                severity=AnalyticsEvent.Severity.ERROR,
                source=AnalyticsEvent.Source.FRONTEND,
                occurred_at=base,
                received_by=self.manager,
                session_id="session-1",
                device_id="till-1",
                installation_id="inst-1",
                app_version="1.2.3",
                platform="windows",
                request_path="/api/sales/orders/",
                ip_address="192.168.1.42",
                user_agent='Mozilla/5.0 "quoted" \\ back\\slash\tand\ttabs',
                trace_id=self.MARKER,
                entity_type="sale_order",
                entity_id="42",
                risk_score=91,
                attributes={
                    "message": 'he said "boom"\nsecond line\ttabbed',
                    "path": "C:\\Users\\pointy\\log.txt",
                    "عربي": "قيمة",
                    "nested": {"list": [1, 2, {"deep": None}]},
                },
                metrics={"duration_ms": 1234.5, "retries": 2},
            ),
            # Every nullable column left empty: NULL user, NULL ip, NULL risk.
            AnalyticsEvent.objects.create(
                event_type=AnalyticsEvent.EventType.USAGE,
                name="app.started",
                severity=AnalyticsEvent.Severity.INFO,
                source=AnalyticsEvent.Source.FRONTEND,
                occurred_at=base,
                received_by=None,
                ip_address=None,
                risk_score=None,
                trace_id=self.MARKER,
                attributes={},
                metrics={},
            ),
        ]

    def _export(self, **params):
        params.setdefault("search", self.MARKER)
        response = self.client.get(reverse("analytics-event-export"), params)
        self.assertEqual(response.status_code, status.HTTP_200_OK)
        return zipfile.ZipFile(io.BytesIO(b"".join(response.streaming_content)))

    @staticmethod
    def _by_id(rows):
        return sorted(rows, key=lambda row: int(row["id"]))

    def test_csv_matches_the_orm_exporter_row_for_row(self):
        self._create_events()

        copied = self._export(format="csv")
        ormed = self._export(format="csv", engine="orm")

        copy_rows = self._by_id(
            csv.DictReader(io.StringIO(copied.read("analytics_events.csv").decode()))
        )
        orm_rows = self._by_id(
            csv.DictReader(io.StringIO(ormed.read("analytics_events.csv").decode()))
        )

        self.assertEqual(len(copy_rows), 2)
        for copy_row, orm_row in zip(copy_rows, orm_rows, strict=True):
            # attributes/metrics are JSON text on both paths, but Postgres and
            # Python order object keys differently. Compare them as documents.
            for column in ("attributes", "metrics"):
                self.assertEqual(
                    json.loads(copy_row.pop(column)),
                    json.loads(orm_row.pop(column)),
                )
            self.assertEqual(copy_row, orm_row)

    def test_csv_header_is_unchanged(self):
        self._create_events()

        header = (
            self._export(format="csv")
            .read("analytics_events.csv")
            .decode()
            .splitlines()[0]
        )

        self.assertEqual(header.split(","), list(ANALYTICS_EXPORT_CSV_FIELDS))

    def test_json_matches_the_orm_exporter_document_for_document(self):
        self._create_events()

        copy_rows = self._by_id(
            json.loads(self._export(format="json").read("analytics_events.json"))
        )
        orm_rows = self._by_id(
            json.loads(
                self._export(format="json", engine="orm").read("analytics_events.json")
            )
        )

        self.assertEqual(len(copy_rows), 2)
        for copy_row, orm_row in zip(copy_rows, orm_rows, strict=True):
            for column in ("attributes", "metrics"):
                self.assertEqual(
                    json.loads(copy_row.pop(column)),
                    json.loads(orm_row.pop(column)),
                )
            self.assertEqual(copy_row, orm_row)

    def test_json_survives_quotes_backslashes_and_non_ascii(self):
        [noisy, _] = self._create_events()

        rows = json.loads(self._export(format="json").read("analytics_events.json"))
        row = next(row for row in rows if row["id"] == noisy.id)

        self.assertEqual(row["user_agent"], noisy.user_agent)
        self.assertEqual(json.loads(row["attributes"]), noisy.attributes)
        self.assertEqual(row["received_by_username"], "copy-export-manager")

    def test_jsonl_writes_one_document_per_line(self):
        self._create_events()

        body = self._export(format="jsonl").read("analytics_events.jsonl").decode()
        lines = body.splitlines()

        self.assertEqual(len(lines), 2)
        self.assertEqual(
            {json.loads(line)["name"] for line in lines},
            {"frontend.http_request", "app.started"},
        )

    def test_jsonl_embeds_json_columns_as_objects_not_strings(self):
        """jsonl carries ``attributes``/``metrics`` as real nested objects.

        The ``json`` array format double-encodes them as strings for backwards
        compatibility; jsonl is new and does the right thing, so a reader gets
        an object it can index instead of a string it has to parse again. This
        is also what makes the COPY path cheaper — one encode instead of three.
        """
        [noisy, _] = self._create_events()

        rows = [
            json.loads(line)
            for line in self._export(format="jsonl")
            .read("analytics_events.jsonl")
            .decode()
            .splitlines()
        ]
        row = next(row for row in rows if row["id"] == noisy.id)

        self.assertIsInstance(row["attributes"], dict)
        self.assertEqual(row["attributes"], noisy.attributes)
        self.assertIsInstance(row["metrics"], dict)

    def test_jsonl_matches_the_orm_exporter_document_for_document(self):
        """COPY and ORM jsonl must agree, nested objects and all."""
        self._create_events()

        def rows(engine):
            body = (
                self._export(format="jsonl", **engine)
                .read("analytics_events.jsonl")
                .decode()
            )
            return self._by_id([json.loads(line) for line in body.splitlines()])

        copy_rows = rows({})
        orm_rows = rows({"engine": "orm"})

        self.assertEqual(len(copy_rows), 2)
        self.assertEqual(copy_rows, orm_rows)

    def test_parallel_workers_land_in_the_copy_statement_and_manifest(self):
        """With workers configured, the export declares them and still runs.

        The plan knobs are ``SET LOCAL`` so they never outlive the export's
        transaction; here we just prove the wiring — a configured worker count
        is recorded, the archive is still correct, and nothing about the output
        depends on whether the planner actually chose a parallel plan.
        """
        self._create_events()

        with override_settings(POINTY_ANALYTICS_EXPORT_PARALLEL_WORKERS=4):
            archive = self._export(format="csv")

        manifest = json.loads(archive.read("manifest.json"))
        self.assertEqual(manifest["parallel_workers"], 4)
        self.assertEqual(manifest["event_count"], 2)
        rows = list(
            csv.DictReader(io.StringIO(archive.read("analytics_events.csv").decode()))
        )
        self.assertEqual(len(rows), 2)


    def test_empty_export_is_still_a_valid_archive(self):
        self._create_events()
        # Filters that match nothing: an export with no rows must still be a
        # well-formed archive rather than a truncated or invalid one.
        copied = self._export(format="json", search="matches-absolutely-nothing")
        self.assertEqual(json.loads(copied.read("analytics_events.json")), [])
        self.assertEqual(json.loads(copied.read("manifest.json"))["event_count"], 0)

        self.assertEqual(
            self._export(
                format="jsonl", search="matches-absolutely-nothing"
            ).read("analytics_events.jsonl"),
            b"",
        )
        self.assertEqual(
            self._export(format="csv", search="matches-absolutely-nothing")
            .read("analytics_events.csv")
            .decode()
            .strip(),
            ",".join(ANALYTICS_EXPORT_CSV_FIELDS),
        )

    def test_manifest_records_the_exact_count_and_engine(self):
        self._create_events()

        manifest = json.loads(self._export(format="csv").read("manifest.json"))

        self.assertEqual(manifest["event_count"], 2)
        self.assertEqual(manifest["engine"], "postgres-copy")
        self.assertEqual(manifest["generated_by"]["username"], "copy-export-manager")

    def test_uncompressed_archives_are_readable(self):
        self._create_events()

        archive = self._export(format="csv", compression="none")

        self.assertEqual(
            archive.getinfo("analytics_events.csv").compress_type,
            zipfile.ZIP_STORED,
        )
        self.assertEqual(
            len(list(csv.DictReader(io.StringIO(archive.read("analytics_events.csv").decode())))),
            2,
        )

    def test_filters_still_apply(self):
        [noisy, _] = self._create_events()

        archive = self._export(format="csv", event_type="error", severity="error")
        rows = list(
            csv.DictReader(io.StringIO(archive.read("analytics_events.csv").decode()))
        )

        self.assertEqual([int(row["id"]) for row in rows], [noisy.id])

    def _export_query_count(self, filters):
        queryset = filter_events_for_export(
            AnalyticsEvent.objects.all(), {"search": self.MARKER}
        )
        with CaptureQueriesContext(connection) as queries:
            chunks = list(
                iter_events_export_zip(
                    queryset=queryset,
                    filters=filters,
                    exported_by=self.manager,
                    exported_at=timezone.now(),
                )
            )
        archive = zipfile.ZipFile(io.BytesIO(b"".join(chunks)))
        count = json.loads(archive.read("manifest.json"))["event_count"]
        return len(queries.captured_queries), count

    def test_round_trips_do_not_grow_with_the_number_of_rows(self):
        """The whole point: row count must not drive round-trip count.

        The ORM exporter runs a keyset query per batch, so a month of telemetry
        is tens of thousands of round trips — that is the export nobody could
        sit through. COPY streams the entire result set in one statement, so
        the round-trip count is a small CONSTANT (the parallel ``SET LOCAL``
        preamble) that does not move whether the export returns 2 rows or half
        a million.
        """
        self._create_events()
        small_queries, small_count = self._export_query_count({"format": "csv"})

        AnalyticsEvent.objects.bulk_create(
            AnalyticsEvent(
                event_type=AnalyticsEvent.EventType.USAGE,
                name="app.started",
                severity=AnalyticsEvent.Severity.INFO,
                source=AnalyticsEvent.Source.FRONTEND,
                occurred_at=timezone.now(),
                trace_id=self.MARKER,
            )
            for _ in range(500)
        )
        large_queries, large_count = self._export_query_count({"format": "csv"})

        self.assertEqual(small_count, 2)
        self.assertEqual(large_count, 502)
        # A small fixed preamble (SET LOCAL x4) plus the COPY, independent of
        # row count — that constancy is the property under test.
        self.assertLess(small_queries, 10)
        self.assertEqual(large_queries, small_queries)

    def test_copy_statement_streams_the_filtered_select(self):
        sql, _params, _columns = build_export_sql(
            filter_events_for_export(
                AnalyticsEvent.objects.all(), {"event_type": "error"}
            ),
            export_format="csv",
            connection=connection,
        )

        statement = build_copy_statement(sql, export_format="csv")

        self.assertTrue(statement.startswith("COPY ("))
        self.assertIn("TO STDOUT WITH (FORMAT csv, HEADER)", statement)
        self.assertIn("event_type", statement)

    def test_export_does_not_sort_the_whole_table(self):
        """No ORDER BY: sorting a full export is the cost this engine avoids."""
        sql, _params, columns = build_export_sql(
            filter_events_for_export(AnalyticsEvent.objects.all(), {}),
            export_format="csv",
            connection=connection,
        )

        self.assertNotIn("ORDER BY", sql.upper())
        self.assertEqual(columns, ANALYTICS_EXPORT_CSV_FIELDS)


@unittest.skipUnless(
    connection.vendor == "postgresql",
    "The COPY export engine is Postgres-only.",
)
class AnalyticsExportParallelLeakTests(TransactionTestCase):
    """The parallel plan knobs must not survive the export.

    A ``TransactionTestCase`` on purpose: the export wraps its ``SET LOCAL``
    knobs in ``transaction.atomic``, and under the ordinary ``TestCase`` the
    surrounding test transaction turns that into a mere savepoint — where
    ``SET LOCAL`` scopes to the outermost transaction and so appears to "leak"
    for the rest of the test. Only without that wrapping transaction (as in
    production autocommit) does ``atomic`` become a real ``BEGIN/COMMIT`` and
    ``SET LOCAL`` reset at commit, which is exactly the property that keeps a
    ``parallel_tuple_cost = 0`` from bleeding onto the next client of a pooled
    connection. This test would silently pass under ``TestCase`` for the wrong
    reason, so it lives on its own.
    """

    def setUp(self):
        ensure_role_groups()
        User = get_user_model()
        self.manager = User.objects.create_user(
            username="parallel-leak-manager", password="pass"
        )
        self.manager.groups.add(Group.objects.get(name=MANAGER_GROUP))
        self.client = APIClient()
        self.client.force_authenticate(user=self.manager)

    def _guc(self, name):
        with connection.cursor() as cursor:
            cursor.execute(f"SHOW {name}")
            return cursor.fetchone()[0]

    def test_parallel_gucs_reset_after_the_export(self):
        AnalyticsEvent.objects.create(
            event_type=AnalyticsEvent.EventType.USAGE,
            name="app.started",
            severity=AnalyticsEvent.Severity.INFO,
            source=AnalyticsEvent.Source.FRONTEND,
            occurred_at=timezone.now(),
        )
        before = {
            name: self._guc(name)
            for name in ("parallel_tuple_cost", "max_parallel_workers_per_gather")
        }

        with override_settings(POINTY_ANALYTICS_EXPORT_PARALLEL_WORKERS=4):
            response = self.client.get(
                reverse("analytics-event-export"), {"format": "csv"}
            )
            # Drain the streamed body so the export's transaction commits.
            b"".join(response.streaming_content)

        after = {name: self._guc(name) for name in before}
        self.assertEqual(before, after)


class AnalyticsExportNdjsonWrapperTests(TestCase):
    """The NDJSON -> JSON-array wrapper works on arbitrary byte boundaries."""

    def _wrap(self, chunks):
        return b"".join(wrap_ndjson_as_json_array(chunks))

    def test_wraps_rows_split_across_chunks(self):
        documents = [{"id": index, "name": f"row-{index}"} for index in range(5)]
        ndjson = "".join(json.dumps(doc) + "\n" for doc in documents).encode()

        for size in (1, 2, 3, 7, 64, len(ndjson), len(ndjson) + 10):
            with self.subTest(chunk_size=size):
                chunks = [ndjson[at : at + size] for at in range(0, len(ndjson), size)]
                self.assertEqual(json.loads(self._wrap(chunks)), documents)

    def test_empty_stream_is_an_empty_array(self):
        self.assertEqual(json.loads(self._wrap([])), [])
        self.assertEqual(json.loads(self._wrap([b""])), [])
