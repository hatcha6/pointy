from decimal import Decimal

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group
from django.urls import reverse
from rest_framework import status
from rest_framework.test import APIClient, APITestCase

from apps.catalog.testing import create_product_with_default_variant
from apps.core.roles import CASHIER_GROUP, MANAGER_GROUP, ensure_role_groups
from apps.inventory.models import StockItem
from apps.notifications.models import BusinessNotification
from apps.purchasing.models import PurchaseOrder, Supplier


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
