from datetime import timedelta
from decimal import Decimal
from unittest import mock

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group
from django.core.cache import cache
from django.test import override_settings
from django.urls import reverse
from django.utils import timezone
from rest_framework import status
from rest_framework.test import APIClient, APITestCase

from apps.analytics.models import AnalyticsEvent
from apps.catalog.testing import create_product_with_default_variant
from apps.core.roles import CASHIER_GROUP, MANAGER_GROUP, ensure_role_groups
from apps.inventory.models import StockBatch, StockItem
from apps.notifications import services as notification_services
from apps.notifications.models import (
    BusinessNotification,
    BusinessNotificationUserState,
)
from apps.printing.models import PrintJob, PrintTemplate, PrintTemplateVersion
from apps.purchasing.models import PurchaseOrder, PurchaseReceipt, Supplier
from apps.sales.models import RegisterSession

# Reads now top up the feed inline only once per throttle window (via cache.add).
# Pin a local in-process cache so the throttle is hermetic and deterministic —
# no dependency on a live Redis, and one test's lock can't leak into the next.
_INLINE_SYNC_TEST_CACHE = {
    "default": {
        "BACKEND": "django.core.cache.backends.locmem.LocMemCache",
        "LOCATION": "notifications-inline-sync-tests",
    }
}


@override_settings(CACHES=_INLINE_SYNC_TEST_CACHE)
class BusinessNotificationApiTests(APITestCase):
    def setUp(self):
        # The inline-sync throttle lives in the cache, which outlives a TestCase;
        # clear it so each test's first read recomputes.
        cache.clear()
        self.addCleanup(cache.clear)
        # Reads now ENQUEUE the recompute onto the Celery worker instead of
        # running it on the request path. No worker runs under the test runner,
        # so stand in for one: make the enqueue execute the sync synchronously.
        # The module-qualified call keeps late binding, so a test that patches
        # sync_business_notifications still intercepts it.
        worker = mock.patch(
            "apps.notifications.tasks.sync_business_notifications_task.apply_async",
            side_effect=lambda *args, **kwargs: (
                notification_services.sync_business_notifications()
            ),
        )
        worker.start()
        self.addCleanup(worker.stop)
        ensure_role_groups()
        User = get_user_model()
        self.manager = User.objects.create_user(
            username="notification-manager",
            password="pass",
        )
        self.manager.groups.add(Group.objects.get(name=MANAGER_GROUP))
        self.cashier = User.objects.create_user(
            username="notification-cashier",
            password="pass",
        )
        self.cashier.groups.add(Group.objects.get(name=CASHIER_GROUP))

    def test_manager_reads_backend_generated_alerts_and_user_state(self):
        product = create_product_with_default_variant(
            name="قهوة التنبيهات",
            sku="ALERT-COF",
            unit_price=Decimal("5.00"),
        )
        StockItem.objects.create(
            variant=product.default_variant,
            quantity_on_hand=0,
            reorder_level=5,
        )
        client = APIClient()
        client.force_authenticate(user=self.manager)

        response = client.get(reverse("business-notification-list"))

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        notification = response.data["results"][0]
        self.assertEqual(notification["code"], "inventory.out_of_stock")
        self.assertEqual(notification["payload"]["product_name"], "قهوة التنبيهات")
        self.assertFalse(notification["is_hidden"])
        self.assertEqual(BusinessNotification.objects.count(), 1)

        dismiss_response = client.post(
            reverse("business-notification-dismiss", args=[notification["id"]])
        )
        self.assertEqual(dismiss_response.status_code, status.HTTP_200_OK)
        self.assertTrue(dismiss_response.data["is_hidden"])
        self.assertEqual(dismiss_response.data["hidden_reason"], "acknowledged")

        hidden_response = client.get(reverse("business-notification-list"))
        self.assertEqual(hidden_response.status_code, status.HTTP_200_OK)
        self.assertEqual(hidden_response.data["results"], [])

        included_response = client.get(
            reverse("business-notification-list"),
            {"include_hidden": "true"},
        )
        self.assertEqual(included_response.status_code, status.HTTP_200_OK)
        self.assertEqual(len(included_response.data["results"]), 1)
        self.assertTrue(included_response.data["results"][0]["is_hidden"])

        restore_response = client.post(
            reverse("business-notification-restore-hidden")
        )
        self.assertEqual(restore_response.status_code, status.HTTP_200_OK)
        self.assertEqual(restore_response.data["restored"], 1)

        visible_response = client.get(reverse("business-notification-list"))
        self.assertEqual(len(visible_response.data["results"]), 1)
        self.assertFalse(visible_response.data["results"][0]["is_hidden"])

    def test_dismiss_all_hides_every_visible_alert(self):
        # Three genuinely out-of-stock products -> three active alerts the feed
        # keeps active across reads (hand-made rows get resolved by the inline
        # sync, so seed real stock instead).
        for index in range(3):
            product = create_product_with_default_variant(
                name=f"صنف التنبيه {index}",
                sku=f"DISMISS-{index}",
                unit_price=Decimal("5.00"),
            )
            StockItem.objects.create(
                variant=product.default_variant,
                quantity_on_hand=0,
                reorder_level=5,
            )
        client = APIClient()
        client.force_authenticate(user=self.manager)
        results = client.get(reverse("business-notification-list")).data["results"]
        self.assertEqual(len(results), 3)
        # Dismiss one first so "hide all" also has to update an existing state,
        # not just create fresh ones.
        client.post(
            reverse("business-notification-dismiss", args=[results[0]["id"]])
        )

        response = client.post(reverse("business-notification-dismiss-all"))

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(response.data["dismissed"], 3)
        self.assertEqual(
            client.get(reverse("business-notification-list")).data["results"], []
        )
        included = client.get(
            reverse("business-notification-list"), {"include_hidden": "true"}
        )
        self.assertEqual(len(included.data["results"]), 3)
        self.assertTrue(all(row["is_hidden"] for row in included.data["results"]))

    def test_dismiss_all_query_count_does_not_grow_with_alert_count(self):
        from django.db import connection
        from django.test.utils import CaptureQueriesContext

        from apps.notifications.services import (
            acknowledge_notifications_for_user,
            visible_notifications_for_user,
        )

        def _count_for(alert_count):
            BusinessNotification.objects.all().delete()
            for index in range(alert_count):
                BusinessNotification.objects.create(
                    code="inventory.out_of_stock",
                    category=BusinessNotification.Category.INVENTORY,
                    severity=BusinessNotification.Severity.CRITICAL,
                    fingerprint=f"inventory.out_of_stock:count:{index}",
                )
            queryset = visible_notifications_for_user(self.manager)
            with CaptureQueriesContext(connection) as ctx:
                acknowledge_notifications_for_user(self.manager, queryset)
            return len(ctx)

        # The old code did a get_or_create per alert; the rewrite is set-based,
        # so dismissing 20 alerts costs the same statements as dismissing 2.
        self.assertEqual(_count_for(2), _count_for(20))

    def test_read_enqueues_the_recompute_instead_of_running_it_inline(self):
        # The whole-catalog recompute (~1300 queries, several seconds) must never
        # run on the bell/badge request path: the read hands it to the worker.
        client = APIClient()
        client.force_authenticate(user=self.manager)
        with (
            mock.patch(
                "apps.notifications.tasks.sync_business_notifications_task.apply_async"
            ) as enqueue,
            mock.patch(
                "apps.notifications.services.sync_business_notifications"
            ) as inline_sync,
        ):
            response = client.get(reverse("business-notification-list"))
        self.assertEqual(response.status_code, status.HTTP_200_OK)
        enqueue.assert_called_once()
        inline_sync.assert_not_called()

    def test_list_query_count_does_not_grow_with_notification_count(self):
        from django.db import connection
        from django.test.utils import CaptureQueriesContext

        client = APIClient()
        client.force_authenticate(user=self.manager)
        throttle_key = notification_services.INLINE_SYNC_THROTTLE_CACHE_KEY

        def _count_for(alert_count):
            BusinessNotification.objects.all().delete()
            for index in range(alert_count):
                BusinessNotification.objects.create(
                    code="inventory.out_of_stock",
                    category=BusinessNotification.Category.INVENTORY,
                    severity=BusinessNotification.Severity.CRITICAL,
                    fingerprint=f"inventory.out_of_stock:list:{index}",
                )
            # No-op the enqueue so the read never recomputes (which would resolve
            # these hand-made alerts); isolate the read + serialize cost.
            with mock.patch(
                "apps.notifications.tasks.sync_business_notifications_task.apply_async"
            ):
                # A warm-up read first so the measured read is steady-state
                # (version / permission / content-type caches populated).
                cache.delete(throttle_key)
                client.get(reverse("business-notification-list"))
                cache.delete(throttle_key)
                with CaptureQueriesContext(connection) as ctx:
                    response = client.get(reverse("business-notification-list"))
            self.assertEqual(response.status_code, status.HTTP_200_OK)
            self.assertEqual(len(response.data["results"]), alert_count)
            return len(ctx)

        # The serializer reads each notification's per-user state; with user_states
        # prefetched and the redundant per-row fallback query removed, serializing
        # 20 alerts costs the same statements as 2 (no per-notification N+1).
        self.assertEqual(_count_for(2), _count_for(20))

    def test_feed_state_rows_do_not_grow_with_staff_count(self):
        """The bell poll must not pay for other people's dismissals.

        ``_state_for_user`` wants exactly one row per alert — the reader's own
        state — but the feed's prefetch used to load *every* member of staff's
        state for every alert and discard all but one. The statement count is
        identical either way (the test above stays green with or without the
        fix), so this measures the rows actually materialized as headcount
        grows.
        """
        User = get_user_model()
        manager_group = Group.objects.get(name=MANAGER_GROUP)
        throttle_key = notification_services.INLINE_SYNC_THROTTLE_CACHE_KEY
        alert_count = 8

        def _state_rows_for(staff_count):
            BusinessNotification.objects.all().delete()
            BusinessNotificationUserState.objects.all().delete()
            colleagues = []
            for index in range(staff_count - 1):
                colleague = User.objects.create_user(
                    username=f"notification-staff-{staff_count}-{index}",
                    password="pass",
                )
                colleague.groups.add(manager_group)
                colleagues.append(colleague)
            alerts = [
                BusinessNotification.objects.create(
                    code="inventory.out_of_stock",
                    category=BusinessNotification.Category.INVENTORY,
                    severity=BusinessNotification.Severity.CRITICAL,
                    fingerprint=f"inventory.out_of_stock:staff{staff_count}:{index}",
                )
                for index in range(alert_count)
            ]
            # Everyone has interacted with every alert — the steady state of a
            # shop whose staff use the bell. The states carry neither an
            # acknowledgement nor a live snooze, so every alert stays visible
            # and the page size is the same at both headcounts.
            BusinessNotificationUserState.objects.bulk_create(
                [
                    BusinessNotificationUserState(notification=alert, user=person)
                    for alert in alerts
                    for person in [self.manager, *colleagues]
                ]
            )

            client = APIClient()
            client.force_authenticate(user=self.manager)
            loaded = []
            build_instance = BusinessNotificationUserState.from_db.__func__

            def counting_from_db(cls, db, field_names, values):
                loaded.append(1)
                return build_instance(cls, db, field_names, values)

            with mock.patch(
                "apps.notifications.tasks.sync_business_notifications_task.apply_async"
            ):
                # A warm-up read first, so the measured read is steady state.
                cache.delete(throttle_key)
                client.get(reverse("business-notification-list"))
                cache.delete(throttle_key)
                with mock.patch.object(
                    BusinessNotificationUserState,
                    "from_db",
                    classmethod(counting_from_db),
                ):
                    response = client.get(reverse("business-notification-list"))
            self.assertEqual(response.status_code, status.HTTP_200_OK)
            self.assertEqual(len(response.data["results"]), alert_count)
            return len(loaded)

        solo = _state_rows_for(1)
        crowded = _state_rows_for(6)
        # One row per alert, whoever else works here. Unfiltered, ``crowded``
        # was six times ``solo`` — the feed read every colleague's state too.
        self.assertEqual(solo, alert_count)
        self.assertEqual(crowded, solo)

    def test_cashier_only_sees_alert_categories_allowed_by_permissions(self):
        product = create_product_with_default_variant(
            name="شاي الإدارة",
            sku="ALERT-TEA",
            unit_price=Decimal("3.00"),
        )
        StockItem.objects.create(
            variant=product.default_variant,
            quantity_on_hand=0,
            reorder_level=5,
        )
        supplier = Supplier.objects.create(name="مورد الإدارة")
        PurchaseOrder.objects.create(
            supplier=supplier,
            status=PurchaseOrder.Status.SUBMITTED,
            subtotal=Decimal("50.00"),
            total=Decimal("50.00"),
        )
        manager_client = APIClient()
        manager_client.force_authenticate(user=self.manager)
        manager_response = manager_client.get(reverse("business-notification-list"))
        self.assertEqual(manager_response.status_code, status.HTTP_200_OK)
        self.assertGreaterEqual(len(manager_response.data["results"]), 1)

        cashier_client = APIClient()
        cashier_client.force_authenticate(user=self.cashier)
        cashier_response = cashier_client.get(reverse("business-notification-list"))

        self.assertEqual(cashier_response.status_code, status.HTTP_200_OK)
        self.assertEqual(cashier_response.data["results"], [])

    def test_notification_resolves_when_source_condition_clears(self):
        product = create_product_with_default_variant(
            name="سكر التنبيهات",
            sku="ALERT-SGR",
            unit_price=Decimal("2.00"),
        )
        stock_item = StockItem.objects.create(
            variant=product.default_variant,
            quantity_on_hand=0,
            reorder_level=5,
        )
        client = APIClient()
        client.force_authenticate(user=self.manager)
        self.assertEqual(
            client.get(reverse("business-notification-list")).status_code,
            status.HTTP_200_OK,
        )
        notification = BusinessNotification.objects.get(
            code="inventory.out_of_stock",
            entity_id=str(product.default_variant.pk),
        )
        self.assertEqual(notification.status, BusinessNotification.Status.ACTIVE)

        stock_item.quantity_on_hand = 12
        stock_item.save(update_fields=["quantity_on_hand", "updated_at"])
        # A plain read is throttled (the beat is the primary refresher), so force
        # an immediate recompute through the explicit refresh endpoint.
        self.assertEqual(
            client.post(reverse("business-notification-refresh")).status_code,
            status.HTTP_200_OK,
        )
        notification.refresh_from_db()
        self.assertEqual(notification.status, BusinessNotification.Status.RESOLVED)

    def test_manager_sees_expiring_stock_batch_alert(self):
        product = create_product_with_default_variant(
            name="حليب قريب الانتهاء",
            sku="ALERT-MILK",
            unit_price=Decimal("6.00"),
        )
        product.tracks_expiry = True
        product.save(update_fields=["tracks_expiry", "updated_at"])
        supplier = Supplier.objects.create(name="مورد الحليب")
        order = PurchaseOrder.objects.create(supplier=supplier)
        purchase_line = order.lines.create(
            variant=product.default_variant,
            quantity=5,
            unit_cost=Decimal("4.00"),
            expiry_date=timezone.localdate() + timedelta(days=3),
        )
        receipt = PurchaseReceipt.objects.create(purchase_order=order)
        receipt_line = receipt.lines.create(
            purchase_line=purchase_line,
            variant=product.default_variant,
            ordered_quantity=5,
            outstanding_before=5,
            accepted_quantity=5,
            outstanding_after=0,
            expiry_date=purchase_line.expiry_date,
        )
        StockBatch.objects.create(
            variant=product.default_variant,
            source_receipt_line=receipt_line,
            expiry_date=purchase_line.expiry_date,
            received_quantity=5,
            remaining_quantity=5,
        )
        client = APIClient()
        client.force_authenticate(user=self.manager)

        response = client.get(reverse("business-notification-list"))

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        expiry_alert = next(
            item
            for item in response.data["results"]
            if item["code"] == "inventory.expiring_batch"
        )
        self.assertEqual(expiry_alert["payload"]["sku"], "ALERT-MILK")
        self.assertEqual(expiry_alert["payload"]["quantity"], 5)
        self.assertEqual(expiry_alert["payload"]["days"], 3)
        self.assertEqual(expiry_alert["payload"]["supplier_name"], "مورد الحليب")

    def test_backend_errors_are_not_reported_as_business_notifications(self):
        AnalyticsEvent.objects.create(
            event_type=AnalyticsEvent.EventType.ERROR,
            name="backend.checkout_failed",
            severity=AnalyticsEvent.Severity.ERROR,
            source=AnalyticsEvent.Source.BACKEND,
            occurred_at=timezone.now(),
            attributes={"message": "Internal processing failed."},
        )
        legacy_notification = BusinessNotification.objects.create(
            code="operations.backend_error",
            category=BusinessNotification.Category.OPERATIONS,
            severity=BusinessNotification.Severity.WARNING,
            fingerprint="operations.backend_error:legacy",
            entity_type="analytics.analyticsevent",
            entity_id="legacy",
            payload={"message": "Legacy error notification"},
        )
        client = APIClient()
        client.force_authenticate(user=self.manager)

        response = client.get(reverse("business-notification-list"))

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(response.data["results"], [])
        legacy_notification.refresh_from_db()
        self.assertEqual(
            legacy_notification.status,
            BusinessNotification.Status.RESOLVED,
        )
        self.assertFalse(
            BusinessNotification.objects.filter(
                code="operations.backend_error",
                status=BusinessNotification.Status.ACTIVE,
            ).exists()
        )

    def test_cashier_only_sees_cashier_safe_notification_codes(self):
        self._create_failed_print_job()
        RegisterSession.objects.create(
            owner=self.cashier,
            owner_key=f"user:{self.cashier.pk}:closed",
            status=RegisterSession.Status.CLOSED,
            opening_cash=Decimal("100.00"),
            closing_cash=Decimal("80.00"),
            closed_at=timezone.now(),
        )
        manager_client = APIClient()
        manager_client.force_authenticate(user=self.manager)
        cashier_client = APIClient()
        cashier_client.force_authenticate(user=self.cashier)

        manager_response = manager_client.get(reverse("business-notification-list"))
        cashier_response = cashier_client.get(reverse("business-notification-list"))

        self.assertEqual(manager_response.status_code, status.HTTP_200_OK)
        self.assertEqual(cashier_response.status_code, status.HTTP_200_OK)
        manager_codes = {
            notification["code"]
            for notification in manager_response.data["results"]
        }
        cashier_codes = {
            notification["code"]
            for notification in cashier_response.data["results"]
        }
        self.assertIn("printing.failed_job", manager_codes)
        self.assertIn("sales.register_variance", manager_codes)
        self.assertEqual(cashier_codes, {"printing.failed_job"})

    def test_consecutive_reads_recompute_at_most_once_per_window(self):
        # The dominant pre-beta cost was a full recompute on every bell/badge
        # poll. Throttled, repeated reads in one window recompute only once.
        client = APIClient()
        client.force_authenticate(user=self.manager)
        with mock.patch(
            "apps.notifications.services.sync_business_notifications",
            return_value={"active": 0, "generated": 0},
        ) as mocked_sync:
            for _ in range(3):
                response = client.get(reverse("business-notification-list"))
                self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(mocked_sync.call_count, 1)

    @override_settings(POINTY_NOTIFICATION_INLINE_SYNC_THROTTLE_SECONDS=0)
    def test_throttle_can_be_disabled_via_settings(self):
        # The escape hatch restores recompute-on-every-read for anyone who wants
        # it (e.g. a deployment without a running beat).
        client = APIClient()
        client.force_authenticate(user=self.manager)
        with mock.patch(
            "apps.notifications.services.sync_business_notifications",
            return_value={"active": 0, "generated": 0},
        ) as mocked_sync:
            client.get(reverse("business-notification-list"))
            client.get(reverse("business-notification-list"))
        self.assertEqual(mocked_sync.call_count, 2)

    def _create_failed_print_job(self):
        template = PrintTemplate.objects.create(
            slug="notification-receipt",
            name="Notification receipt",
        )
        version = PrintTemplateVersion.objects.create(
            template=template,
            version_number=1,
            content="{{ receipt }}",
            schema={"kind": "receipt"},
        )
        return PrintJob.objects.create(
            job_type=PrintJob.Type.RECEIPT,
            status=PrintJob.Status.FAILED,
            template_version=version,
            payload={"order": {"receipt_number": "R-NOTIFY"}},
            idempotency_key="notification-print-failed",
            failed_at=timezone.now(),
            error_message="Printer disconnected",
        )
