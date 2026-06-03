from datetime import timedelta
from decimal import Decimal

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group
from django.urls import reverse
from django.utils import timezone
from rest_framework import status
from rest_framework.test import APIClient, APITestCase

from apps.analytics.models import AnalyticsEvent
from apps.catalog.testing import create_product_with_default_variant
from apps.core.roles import CASHIER_GROUP, MANAGER_GROUP, ensure_role_groups
from apps.inventory.models import StockBatch, StockItem
from apps.notifications.models import BusinessNotification
from apps.printing.models import PrintJob, PrintTemplate, PrintTemplateVersion
from apps.purchasing.models import PurchaseOrder, PurchaseReceipt, Supplier
from apps.sales.models import RegisterSession


class BusinessNotificationApiTests(APITestCase):
    def setUp(self):
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
        self.assertEqual(
            client.get(reverse("business-notification-list")).status_code,
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
