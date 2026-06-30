import json
import tempfile
import zipfile
from datetime import timedelta
from decimal import Decimal
from io import BytesIO
from pathlib import Path
from unittest import mock


def _png_logo_bytes(width=64, height=64):
    from PIL import Image

    buffer = BytesIO()
    Image.new("RGBA", (width, height), (11, 107, 100, 255)).save(
        buffer,
        format="PNG",
    )
    return buffer.getvalue()

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group
from django.core.cache import cache
from django.core.files.uploadedfile import SimpleUploadedFile
from django.core.management import call_command
from django.test import TestCase, override_settings
from django.urls import reverse
from django.utils import timezone
from rest_framework import status
from rest_framework.test import APIClient

from apps.catalog.models import ProductCategory, ProductVariant
from apps.catalog.testing import create_product_with_default_variant
from apps.attachments.models import Attachment
from apps.inventory.models import StockItem, StockMovement
from apps.payments.models import Payment
from apps.analytics.models import AnalyticsEvent
from apps.purchasing.models import (
    PurchaseOrder,
    PurchaseOrderAuditEvent,
    Supplier,
    SupplierPayment,
)
from apps.sales.models import Order, OrderLine, RegisterCashMovement, RegisterSession
from .models import RelayConnectorSetupToken, RelayInstallation, ShopSettings
from .roles import (
    ACCOUNTANT_GROUP,
    AUDITOR_GROUP,
    CASHIER_GROUP,
    INVENTORY_CLERK_GROUP,
    MANAGER_GROUP,
    PURCHASING_AGENT_GROUP,
    SUPERVISOR_GROUP,
    create_initial_admin_user,
    ensure_role_groups,
    initial_admin_setup_required,
    user_has_full_visibility,
)
from . import permission_catalog
from .discovery import private_network_host_for_peer


class FakeRelayConfig:
    public_api_url = "https://relay.example"
    connector_address = "relay.example:443"


class FakeRelayControlClient:
    config = FakeRelayConfig()

    def __init__(self, *, relay_enabled=False, subscription_active=False):
        self.relay_enabled = relay_enabled
        self.subscription_active = subscription_active
        self.provisioned_shop_name = ""
        self.issued_ticket_request = None
        self.issued_connector_certificate_request = None

    def provision_installation(self, *, shop_name):
        self.provisioned_shop_name = shop_name
        return {
            "installation": {
                "id": "installation-1",
                "shop_name": shop_name,
                "relay_enabled": False,
                "subscription_active": False,
                "ai_enabled": False,
                "subscription_ends_at": None,
            },
            "connector_token": "ptc1.installation-1.connector-secret",
            "access_token": "ptr1.installation-1.access-secret",
        }

    def get_installation(self, installation_id):
        return {
            "id": installation_id,
            "shop_name": "متجر آمن",
            "relay_enabled": self.relay_enabled,
            "subscription_active": self.subscription_active,
            "ai_enabled": False,
            "subscription_ends_at": None,
        }

    def issue_ticket(self, *, access_token, device_id="", device_name=""):
        self.issued_ticket_request = {
            "access_token": access_token,
            "device_id": device_id,
            "device_name": device_name,
        }
        return {
            "token": "ptt1.installation-1.ticket-secret",
            "installation_id": "installation-1",
            "device_id": device_id,
            "device_name": device_name,
            "expires_at": timezone.now() + timedelta(minutes=15),
            "refresh_token": "ptrf1.installation-1.refresh-secret",
            "refresh_expires_at": timezone.now() + timedelta(days=7),
        }

    def issue_connector_certificate(self, *, installation_id, csr_pem):
        self.issued_connector_certificate_request = {
            "installation_id": installation_id,
            "csr_pem": csr_pem,
        }
        return {
            "certificate_pem": "-----BEGIN CERTIFICATE-----\ncert\n-----END CERTIFICATE-----\n",
            "ca_certificate_pem": "-----BEGIN CERTIFICATE-----\nca\n-----END CERTIFICATE-----\n",
            "fingerprint_sha256": "fingerprint",
            "serial_number": "serial",
            "expires_at": timezone.now() + timedelta(days=90),
        }


class ApiAuthenticationTests(TestCase):
    def test_api_denies_unauthenticated_requests_by_default(self):
        response = APIClient().get(reverse("product-list"))

        self.assertEqual(response.status_code, status.HTTP_401_UNAUTHORIZED)

    def test_api_denies_authenticated_users_without_domain_permissions(self):
        user = get_user_model().objects.create_user(
            username="unassigned",
            password="pass",
        )
        client = APIClient()
        client.force_authenticate(user=user)

        response = client.get(reverse("product-list"))

        self.assertEqual(response.status_code, status.HTTP_403_FORBIDDEN)

    def test_login_me_and_logout_use_django_session_auth(self):
        ensure_role_groups()
        user = get_user_model().objects.create_user(
            username="cashier",
            password="secret-pass",
        )
        user.groups.add(Group.objects.get(name=CASHIER_GROUP))
        client = APIClient()

        login_response = client.post(
            reverse("auth-login"),
            {"username": "cashier", "password": "secret-pass"},
            format="json",
        )
        me_response = client.get(reverse("auth-me"))
        logout_response = client.post(reverse("auth-logout"))
        after_logout_response = client.get(reverse("auth-me"))

        self.assertEqual(login_response.status_code, status.HTTP_200_OK)
        self.assertEqual(login_response.data["user"]["username"], "cashier")
        self.assertEqual(login_response.data["user"]["role"], CASHIER_GROUP)
        self.assertIn("catalog.view_product", login_response.data["user"]["permissions"])
        self.assertIn(
            "sales.add_registersession",
            login_response.data["user"]["permissions"],
        )
        self.assertNotIn("auth.view_user", login_response.data["user"]["permissions"])
        self.assertIn("csrf_token", login_response.data)
        self.assertEqual(me_response.status_code, status.HTTP_200_OK)
        self.assertEqual(me_response.data["user"]["username"], "cashier")
        self.assertIn("permissions", me_response.data["user"])
        self.assertIn("csrf_token", me_response.data)
        self.assertEqual(logout_response.status_code, status.HTTP_204_NO_CONTENT)
        self.assertEqual(after_logout_response.status_code, status.HTTP_401_UNAUTHORIZED)

    def test_login_response_csrf_token_allows_authenticated_post(self):
        ensure_role_groups()
        user = get_user_model().objects.create_user(
            username="cashier",
            password="secret-pass",
        )
        user.groups.add(Group.objects.get(name=CASHIER_GROUP))
        client = APIClient(enforce_csrf_checks=True)

        login_response = client.post(
            reverse("auth-login"),
            {"username": "cashier", "password": "secret-pass"},
            format="json",
        )
        csrf_token = login_response.data["csrf_token"]
        start_response = client.post(
            reverse("register-session-start"),
            {"opening_cash": "10.00"},
            format="json",
            HTTP_X_CSRFTOKEN=csrf_token,
        )

        self.assertEqual(login_response.status_code, status.HTTP_200_OK)
        self.assertEqual(start_response.status_code, status.HTTP_200_OK)

    def test_current_user_can_update_profile_and_change_password(self):
        ensure_role_groups()
        user = get_user_model().objects.create_user(
            username="profile-cashier",
            password="secret-pass",
        )
        user.groups.add(Group.objects.get(name=CASHIER_GROUP))
        client = APIClient()
        client.force_authenticate(user=user)

        profile_response = client.patch(
            reverse("auth-me"),
            {
                "username": "profile-updated",
                "first_name": "سارة",
                "last_name": "علي",
                "email": "sara@example.test",
            },
            format="json",
        )
        password_response = client.post(
            reverse("auth-password-change"),
            {
                "current_password": "secret-pass",
                "new_password": "New-Strong-Pass-2026!",
            },
            format="json",
        )
        wrong_password_response = client.post(
            reverse("auth-password-change"),
            {
                "current_password": "secret-pass",
                "new_password": "Another-Strong-Pass-2026!",
            },
            format="json",
        )

        self.assertEqual(profile_response.status_code, status.HTTP_200_OK)
        self.assertEqual(profile_response.data["user"]["username"], "profile-updated")
        self.assertEqual(profile_response.data["user"]["first_name"], "سارة")
        self.assertEqual(profile_response.data["user"]["last_name"], "علي")
        self.assertIn("csrf_token", profile_response.data)
        self.assertEqual(password_response.status_code, status.HTTP_204_NO_CONTENT)
        user.refresh_from_db()
        self.assertTrue(user.check_password("New-Strong-Pass-2026!"))
        self.assertEqual(wrong_password_response.status_code, status.HTTP_400_BAD_REQUEST)


class PosUserManagementTests(TestCase):
    def setUp(self):
        ensure_role_groups()
        User = get_user_model()
        self.manager = User.objects.create_user(username="manager", password="pass")
        self.manager.groups.add(Group.objects.get(name=MANAGER_GROUP))
        self.cashier = User.objects.create_user(username="cashier", password="pass")
        self.cashier.groups.add(Group.objects.get(name=CASHIER_GROUP))

    def test_cashier_cannot_manage_users(self):
        client = APIClient()
        client.force_authenticate(user=self.cashier)

        response = client.get(reverse("pos-user-list"))

        self.assertEqual(response.status_code, status.HTTP_403_FORBIDDEN)

    def test_cashier_cannot_read_user_activity(self):
        client = APIClient()
        client.force_authenticate(user=self.cashier)

        response = client.get(reverse("pos-user-activity", args=[self.cashier.pk]))

        self.assertEqual(response.status_code, status.HTTP_403_FORBIDDEN)

    def test_manager_can_create_cashier_user(self):
        client = APIClient()
        client.force_authenticate(user=self.manager)

        response = client.post(
            reverse("pos-user-list"),
            {
                "username": "new-cashier",
                "password": "new-secret-pass",
                "role": CASHIER_GROUP,
                "is_active": True,
            },
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_201_CREATED)
        user = get_user_model().objects.get(username="new-cashier")
        self.assertTrue(user.check_password("new-secret-pass"))
        self.assertTrue(user.groups.filter(name=CASHIER_GROUP).exists())

    def test_creating_user_auto_creates_linked_employee(self):
        from apps.employees.models import Employee

        client = APIClient()
        client.force_authenticate(user=self.manager)

        response = client.post(
            reverse("pos-user-list"),
            {
                "username": "new-cashier",
                "first_name": "سالم الكاسير",
                "password": "new-secret-pass",
                "role": CASHIER_GROUP,
                "is_active": True,
            },
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_201_CREATED)
        user = get_user_model().objects.get(username="new-cashier")
        employee = Employee.objects.get(user=user)
        self.assertEqual(employee.full_name, "سالم الكاسير")
        self.assertEqual(employee.status, Employee.Status.ACTIVE)

    def test_manager_can_assign_manager_role(self):
        client = APIClient()
        client.force_authenticate(user=self.manager)

        response = client.patch(
            reverse("pos-user-detail", args=[self.cashier.pk]),
            {"role": MANAGER_GROUP},
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.cashier.refresh_from_db()
        self.assertTrue(self.cashier.groups.filter(name=MANAGER_GROUP).exists())
        self.assertFalse(self.cashier.groups.filter(name=CASHIER_GROUP).exists())

    def test_manager_can_read_user_activity_overview(self):
        client = APIClient()
        client.force_authenticate(user=self.manager)
        owner_key = f"user:{self.cashier.pk}"
        session = RegisterSession.objects.create(
            owner=self.cashier,
            owner_key=owner_key,
            status=RegisterSession.Status.CLOSED,
            opening_cash=Decimal("10.00"),
            closing_cash=Decimal("35.00"),
            closed_at=timezone.now(),
        )
        order = Order.objects.create(
            register_session=session,
            status=Order.Status.PAID,
            subtotal=Decimal("25.00"),
            total=Decimal("25.00"),
        )
        RegisterCashMovement.objects.create(
            register_session=session,
            movement_type=RegisterCashMovement.MovementType.PAY_IN,
            amount=Decimal("5.00"),
            reason="Opening correction",
            created_by=self.cashier,
        )
        supplier = Supplier.objects.create(name="مورد المستخدم")
        purchase_order = PurchaseOrder.objects.create(
            supplier=supplier,
            status=PurchaseOrder.Status.RECEIVED,
            supplier_invoice_number="SUP-INV-1",
            subtotal=Decimal("40.00"),
            total=Decimal("40.00"),
        )
        PurchaseOrderAuditEvent.objects.create(
            purchase_order=purchase_order,
            order_number=purchase_order.order_number,
            action=PurchaseOrderAuditEvent.Action.CREATED,
            created_by=self.cashier,
        )
        SupplierPayment.objects.create(
            supplier=supplier,
            purchase_order=purchase_order,
            amount=Decimal("15.00"),
            method=SupplierPayment.Method.CASH,
            created_by=self.cashier,
        )
        AnalyticsEvent.objects.create(
            name="sales.register_session.closed",
            event_type=AnalyticsEvent.EventType.AUDIT,
            severity=AnalyticsEvent.Severity.INFO,
            source=AnalyticsEvent.Source.BACKEND,
            occurred_at=timezone.now(),
            received_by=self.cashier,
        )

        response = client.get(reverse("pos-user-activity", args=[self.cashier.pk]))

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(response.data["user"]["id"], self.cashier.pk)
        self.assertEqual(response.data["summary"]["sales"]["invoice_count"], 1)
        self.assertEqual(response.data["summary"]["sales"]["net_sales"], "25.00")
        self.assertEqual(
            response.data["summary"]["register_sessions"]["session_count"],
            1,
        )
        self.assertEqual(
            response.data["summary"]["cash_movements"]["pay_in_total"],
            "5.00",
        )
        self.assertEqual(
            response.data["summary"]["purchasing"]["supplier_invoice_count"],
            1,
        )
        self.assertEqual(
            response.data["summary"]["purchasing"]["purchase_total"],
            "40.00",
        )
        self.assertEqual(
            response.data["summary"]["supplier_payments"]["payment_total"],
            "15.00",
        )
        self.assertEqual(response.data["recent_sales"][0]["id"], order.pk)
        self.assertEqual(
            response.data["recent_purchase_orders"][0]["supplier_invoice_number"],
            "SUP-INV-1",
        )
        self.assertEqual(
            response.data["recent_activity"][0]["name"],
            "sales.register_session.closed",
        )


class ShopSettingsApiTests(TestCase):
    def setUp(self):
        ensure_role_groups()
        User = get_user_model()
        self.manager = User.objects.create_user(username="manager", password="pass")
        self.manager.groups.add(Group.objects.get(name=MANAGER_GROUP))
        self.cashier = User.objects.create_user(username="cashier", password="pass")
        self.cashier.groups.add(Group.objects.get(name=CASHIER_GROUP))

    def test_manager_can_read_and_update_shop_settings(self):
        client = APIClient()
        client.force_authenticate(user=self.manager)

        read_response = client.get(reverse("shop-settings"))
        update_response = client.patch(
            reverse("shop-settings"),
            {
                "shop_name": "متجر الوردية",
                "receipt_header": "أهلا بكم",
                "receipt_footer": "شكرا لزيارتكم",
                "enable_online_invoices": True,
                "require_opening_cash": False,
                "auto_print_receipts": True,
                "prevent_selling_at_loss": False,
                "low_stock_threshold": 12,
                "cashier_return_window_hours": 42,
                "enable_cash_payments": True,
                "enable_card_payments": False,
                "enable_transfer_payments": True,
                "require_card_payment_receipt": True,
                "trusted_card_terminal_ids": ["0JA8Y13W", " 0ja8y13w ", ""],
                "card_commission_percent": "1.50",
                "transfer_commission_percent": "0.25",
            },
            format="json",
        )

        self.assertEqual(read_response.status_code, status.HTTP_200_OK)
        self.assertEqual(update_response.status_code, status.HTTP_200_OK)
        self.assertEqual(update_response.data["shop_name"], "متجر الوردية")
        self.assertTrue(update_response.data["enable_online_invoices"])
        self.assertFalse(update_response.data["require_opening_cash"])
        self.assertTrue(update_response.data["auto_print_receipts"])
        self.assertFalse(update_response.data["prevent_selling_at_loss"])
        self.assertEqual(update_response.data["low_stock_threshold"], 12)
        self.assertEqual(update_response.data["cashier_return_window_hours"], 42)
        self.assertTrue(update_response.data["enable_cash_payments"])
        self.assertFalse(update_response.data["enable_card_payments"])
        self.assertTrue(update_response.data["enable_transfer_payments"])
        self.assertTrue(update_response.data["require_card_payment_receipt"])
        self.assertEqual(update_response.data["trusted_card_terminal_ids"], ["0JA8Y13W"])
        self.assertEqual(update_response.data["card_commission_percent"], "1.50")
        self.assertEqual(update_response.data["transfer_commission_percent"], "0.25")

    def test_shop_settings_requires_at_least_one_payment_method(self):
        client = APIClient()
        client.force_authenticate(user=self.manager)

        response = client.patch(
            reverse("shop-settings"),
            {
                "enable_cash_payments": False,
                "enable_card_payments": False,
                "enable_transfer_payments": False,
            },
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertIn("payment_methods", response.data)

    def test_manager_can_upload_and_remove_shop_logo(self):
        client = APIClient()
        client.force_authenticate(user=self.manager)

        with tempfile.TemporaryDirectory() as storage_root:
            (Path(storage_root) / "volume-a").mkdir()
            with override_settings(
                POINTY_ATTACHMENT_STORAGE_ROOT=storage_root,
                POINTY_ATTACHMENT_ALLOWED_CONTENT_TYPES=[],
                POINTY_ATTACHMENT_MAX_UPLOAD_BYTES=1024 * 1024,
            ):
                upload_response = client.post(
                    reverse("shop-settings-logo"),
                    {
                        "file": SimpleUploadedFile(
                            "logo.png",
                            _png_logo_bytes(),
                            content_type="image/png",
                        ),
                    },
                    format="multipart",
                )
                read_response = client.get(reverse("shop-settings"))
                delete_response = client.delete(reverse("shop-settings-logo"))

        self.assertEqual(upload_response.status_code, status.HTTP_201_CREATED)
        self.assertEqual(
            upload_response.data["logo_attachment"]["role"],
            Attachment.Role.SHOP_LOGO,
        )
        self.assertTrue(upload_response.data["logo_attachment"]["is_primary"])
        self.assertIn("content_url", upload_response.data["logo_attachment"])
        self.assertEqual(
            read_response.data["logo_attachment"]["id"],
            upload_response.data["logo_attachment"]["id"],
        )
        self.assertEqual(delete_response.status_code, status.HTTP_200_OK)
        self.assertIsNone(delete_response.data["logo_attachment"])
        self.assertEqual(
            Attachment.objects.get(pk=upload_response.data["logo_attachment"]["id"]).status,
            Attachment.Status.DELETED,
        )

    def test_shop_logo_uploads_are_downscaled_to_embedding_budget(self):
        import os

        from PIL import Image

        from apps.attachments.services import open_attachment
        from apps.core.images import LOGO_MAX_BYTES, LOGO_MAX_DIMENSION

        client = APIClient()
        client.force_authenticate(user=self.manager)
        # Random noise is incompressible, so this PNG is far over the budget
        # and forces both the resize and the halving loop to run.
        noise = Image.frombytes("RGB", (1600, 1200), os.urandom(1600 * 1200 * 3))
        buffer = BytesIO()
        noise.save(buffer, format="PNG")
        self.assertGreater(buffer.tell(), LOGO_MAX_BYTES)

        response = client.post(
            reverse("shop-settings-logo"),
            {
                "file": SimpleUploadedFile(
                    "big-logo.png",
                    buffer.getvalue(),
                    content_type="image/png",
                ),
            },
            format="multipart",
        )

        self.assertEqual(response.status_code, status.HTTP_201_CREATED)
        attachment = Attachment.objects.get(
            pk=response.data["logo_attachment"]["id"],
        )
        self.assertLessEqual(attachment.original_size, LOGO_MAX_BYTES)
        with open_attachment(attachment) as handle:
            stored = Image.open(handle)
            stored.load()
        self.assertLessEqual(max(stored.size), LOGO_MAX_DIMENSION)
        self.assertEqual(stored.format, "PNG")

    def test_shop_logo_rejects_undecodable_image_bytes(self):
        client = APIClient()
        client.force_authenticate(user=self.manager)

        response = client.post(
            reverse("shop-settings-logo"),
            {
                "file": SimpleUploadedFile(
                    "logo.png",
                    b"not really a png",
                    content_type="image/png",
                ),
            },
            format="multipart",
        )

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)

    def test_shop_logo_rejects_non_reportable_files(self):
        client = APIClient()
        client.force_authenticate(user=self.manager)

        response = client.post(
            reverse("shop-settings-logo"),
            {
                "file": SimpleUploadedFile(
                    "logo.svg",
                    b"<svg />",
                    content_type="image/svg+xml",
                ),
            },
            format="multipart",
        )

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertEqual(Attachment.objects.count(), 0)

    def test_cashier_can_read_but_not_update_shop_settings(self):
        client = APIClient()
        client.force_authenticate(user=self.cashier)

        read_response = client.get(reverse("shop-settings"))
        update_response = client.patch(
            reverse("shop-settings"),
            {"shop_name": "غير مسموح"},
            format="json",
        )
        upload_response = client.post(reverse("shop-settings-logo"), {}, format="multipart")

        self.assertEqual(read_response.status_code, status.HTTP_200_OK)
        self.assertIn("auto_print_receipts", read_response.data)
        self.assertTrue(read_response.data["prevent_selling_at_loss"])
        self.assertEqual(update_response.status_code, status.HTTP_403_FORBIDDEN)
        self.assertEqual(upload_response.status_code, status.HTTP_403_FORBIDDEN)


class RelayBackendApiTests(TestCase):
    def setUp(self):
        ensure_role_groups()
        User = get_user_model()
        self.manager = User.objects.create_user(username="relay-manager", password="pass")
        self.manager.groups.add(Group.objects.get(name=MANAGER_GROUP))
        self.cashier = User.objects.create_user(username="relay-cashier", password="pass")
        self.cashier.groups.add(Group.objects.get(name=CASHIER_GROUP))
        settings = ShopSettings.load()
        settings.shop_name = "متجر آمن"
        settings.save(update_fields=["shop_name"])

    def test_manager_can_provision_relay_installation_with_safe_defaults(self):
        fake_relay = FakeRelayControlClient()
        client = APIClient()
        client.force_authenticate(user=self.manager)

        with self.captureOnCommitCallbacks(execute=True):
            with mock.patch("apps.core.relay.RelayControlClient", return_value=fake_relay):
                response = client.post(reverse("relay-installation"), {}, format="json")

        self.assertEqual(response.status_code, status.HTTP_201_CREATED)
        self.assertFalse(response.data["remote_access_supported"])
        self.assertFalse(response.data["relay_enabled"])
        self.assertFalse(response.data["subscription_active"])
        self.assertEqual(response.data["shop_name"], "متجر آمن")
        self.assertEqual(fake_relay.provisioned_shop_name, "متجر آمن")
        installation = RelayInstallation.objects.get()
        self.assertEqual(installation.installation_id, "installation-1")
        self.assertFalse(installation.relay_enabled)
        self.assertFalse(installation.subscription_active)
        self.assertEqual(
            installation.connector_token,
            "ptc1.installation-1.connector-secret",
        )
        event = AnalyticsEvent.objects.get(name="relay.installation.provisioned")
        self.assertEqual(event.event_type, AnalyticsEvent.EventType.AUDIT)
        self.assertEqual(event.source, AnalyticsEvent.Source.BACKEND)
        self.assertEqual(event.received_by, self.manager)
        self.assertEqual(event.entity_type, "relay_installation")
        self.assertEqual(event.entity_id, str(installation.pk))
        self.assertEqual(event.attributes["installation_id"], "installation-1")
        self.assertFalse(event.attributes["relay_enabled"])
        self.assertFalse(event.attributes["subscription_active"])

    def test_cashier_cannot_manage_relay_installation(self):
        client = APIClient()
        client.force_authenticate(user=self.cashier)

        response = client.post(reverse("relay-installation"), {}, format="json")

        self.assertEqual(response.status_code, status.HTTP_403_FORBIDDEN)
        self.assertEqual(RelayInstallation.objects.count(), 0)

    def test_manager_syncs_relay_installation_with_audit_event(self):
        installation = RelayInstallation.objects.create(
            installation_id="installation-1",
            shop_name="متجر آمن",
            relay_public_api_url="https://relay.example",
            relay_connector_address="relay.example:443",
            connector_token="ptc1.installation-1.connector-secret",
            access_token="ptr1.installation-1.access-secret",
            relay_enabled=False,
            subscription_active=False,
        )
        fake_relay = FakeRelayControlClient(
            relay_enabled=True,
            subscription_active=True,
        )
        client = APIClient()
        client.force_authenticate(user=self.manager)

        with self.captureOnCommitCallbacks(execute=True):
            with mock.patch("apps.core.relay.RelayControlClient", return_value=fake_relay):
                response = client.post(
                    reverse("relay-installation"),
                    {"sync": True},
                    format="json",
                )

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        installation.refresh_from_db()
        self.assertTrue(installation.relay_enabled)
        self.assertTrue(installation.subscription_active)
        event = AnalyticsEvent.objects.get(name="relay.installation.synced")
        self.assertEqual(event.event_type, AnalyticsEvent.EventType.AUDIT)
        self.assertEqual(event.received_by, self.manager)
        self.assertEqual(event.entity_type, "relay_installation")
        self.assertEqual(event.entity_id, str(installation.pk))
        self.assertEqual(event.attributes["installation_id"], "installation-1")
        self.assertTrue(event.attributes["relay_enabled"])
        self.assertTrue(event.attributes["subscription_active"])

    def test_pairing_returns_short_lived_ticket_when_subscription_is_active(self):
        installation = RelayInstallation.objects.create(
            installation_id="installation-1",
            shop_name="متجر آمن",
            relay_public_api_url="https://relay.example",
            relay_connector_address="relay.example:443",
            connector_token="ptc1.installation-1.connector-secret",
            access_token="ptr1.installation-1.access-secret",
            relay_enabled=True,
            subscription_active=True,
        )
        fake_relay = FakeRelayControlClient(
            relay_enabled=True,
            subscription_active=True,
        )
        client = APIClient()
        client.force_authenticate(user=self.cashier)

        with self.captureOnCommitCallbacks(execute=True):
            with mock.patch("apps.core.relay.RelayControlClient", return_value=fake_relay):
                response = client.post(
                    reverse("relay-pairing"),
                    {"device_id": "phone-1", "device_name": "هاتف المدير"},
                    format="json",
                )

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertTrue(response.data["remote_access_supported"])
        self.assertEqual(response.data["relay_token"], "ptt1.installation-1.ticket-secret")
        self.assertEqual(
            response.data["relay_refresh_token"],
            "ptrf1.installation-1.refresh-secret",
        )
        self.assertEqual(response.data["relay_public_api_url"], "https://relay.example")
        self.assertEqual(
            fake_relay.issued_ticket_request,
            {
                "access_token": "ptr1.installation-1.access-secret",
                "device_id": "phone-1",
                "device_name": "هاتف المدير",
            },
        )
        installation.refresh_from_db()
        self.assertIsNotNone(installation.last_pairing_issued_at)
        event = AnalyticsEvent.objects.get(name="relay.pairing.ticket_issued")
        self.assertEqual(event.event_type, AnalyticsEvent.EventType.AUDIT)
        self.assertEqual(event.received_by, self.cashier)
        self.assertEqual(event.installation_id, "installation-1")
        self.assertEqual(event.device_id, "phone-1")
        self.assertEqual(event.entity_type, "relay_installation")
        self.assertEqual(event.entity_id, str(installation.pk))
        self.assertTrue(event.attributes["relay_enabled"])
        self.assertTrue(event.attributes["subscription_active"])
        self.assertTrue(event.attributes["device_id_present"])
        self.assertTrue(event.attributes["device_name_present"])

    def test_pairing_does_not_issue_ticket_when_subscription_is_inactive(self):
        RelayInstallation.objects.create(
            installation_id="installation-1",
            shop_name="متجر آمن",
            relay_public_api_url="https://relay.example",
            relay_connector_address="relay.example:443",
            connector_token="ptc1.installation-1.connector-secret",
            access_token="ptr1.installation-1.access-secret",
            relay_enabled=True,
            subscription_active=True,
        )
        fake_relay = FakeRelayControlClient(
            relay_enabled=True,
            subscription_active=False,
        )
        client = APIClient()
        client.force_authenticate(user=self.cashier)

        with mock.patch("apps.core.relay.RelayControlClient", return_value=fake_relay):
            response = client.post(reverse("relay-pairing"), {}, format="json")

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertFalse(response.data["remote_access_supported"])
        self.assertEqual(response.data["relay_token"], "")
        self.assertEqual(response.data["relay_refresh_token"], "")
        self.assertEqual(response.data["reason"], "relay_not_active")
        self.assertIsNone(fake_relay.issued_ticket_request)

    def test_pairing_refresh_can_issue_repeated_lan_tickets(self):
        installation = RelayInstallation.objects.create(
            installation_id="installation-1",
            shop_name="متجر آمن",
            relay_public_api_url="https://relay.example",
            relay_connector_address="relay.example:443",
            connector_token="ptc1.installation-1.connector-secret",
            access_token="ptr1.installation-1.access-secret",
            relay_enabled=True,
            subscription_active=True,
        )
        fake_relay = FakeRelayControlClient(
            relay_enabled=True,
            subscription_active=True,
        )
        client = APIClient()
        client.force_authenticate(user=self.cashier)

        with mock.patch("apps.core.relay.RelayControlClient", return_value=fake_relay):
            first = client.post(
                reverse("relay-pairing"),
                {"device_id": "phone-1"},
                format="json",
            )
            first_issued_at = RelayInstallation.objects.get().last_pairing_issued_at
            second = client.post(
                reverse("relay-pairing"),
                {"device_id": "phone-1"},
                format="json",
            )

        self.assertEqual(first.status_code, status.HTTP_200_OK)
        self.assertEqual(second.status_code, status.HTTP_200_OK)
        self.assertTrue(first.data["remote_access_supported"])
        self.assertTrue(second.data["remote_access_supported"])
        installation.refresh_from_db()
        self.assertIsNotNone(first_issued_at)
        self.assertGreaterEqual(
            installation.last_pairing_issued_at,
            first_issued_at,
        )

    def test_pairing_requires_lan_request(self):
        RelayInstallation.objects.create(
            installation_id="installation-1",
            shop_name="متجر آمن",
            relay_public_api_url="https://relay.example",
            relay_connector_address="relay.example:443",
            connector_token="ptc1.installation-1.connector-secret",
            access_token="ptr1.installation-1.access-secret",
            relay_enabled=True,
            subscription_active=True,
        )
        fake_relay = FakeRelayControlClient(
            relay_enabled=True,
            subscription_active=True,
        )
        client = APIClient()
        client.force_authenticate(user=self.cashier)

        with mock.patch("apps.core.relay.RelayControlClient", return_value=fake_relay):
            response = client.post(
                reverse("relay-pairing"),
                {},
                format="json",
                REMOTE_ADDR="8.8.8.8",
                HTTP_X_FORWARDED_FOR="192.168.1.10",
            )

        self.assertEqual(response.status_code, status.HTTP_403_FORBIDDEN)
        self.assertFalse(response.data["remote_access_supported"])
        self.assertEqual(response.data["reason"], "relay_requires_lan_pairing")
        self.assertIsNone(fake_relay.issued_ticket_request)

    def test_pairing_rejects_relay_tunneled_request(self):
        RelayInstallation.objects.create(
            installation_id="installation-1",
            shop_name="متجر آمن",
            relay_public_api_url="https://relay.example",
            relay_connector_address="relay.example:443",
            connector_token="ptc1.installation-1.connector-secret",
            access_token="ptr1.installation-1.access-secret",
            relay_enabled=True,
            subscription_active=True,
        )
        fake_relay = FakeRelayControlClient(
            relay_enabled=True,
            subscription_active=True,
        )
        client = APIClient()
        client.force_authenticate(user=self.cashier)

        with mock.patch("apps.core.relay.RelayControlClient", return_value=fake_relay):
            response = client.post(
                reverse("relay-pairing"),
                {},
                format="json",
                REMOTE_ADDR="127.0.0.1",
                HTTP_X_POINTY_RELAYED_REQUEST="1",
            )

        self.assertEqual(response.status_code, status.HTTP_403_FORBIDDEN)
        self.assertFalse(response.data["remote_access_supported"])
        self.assertEqual(response.data["reason"], "relay_requires_lan_pairing")
        self.assertIsNone(fake_relay.issued_ticket_request)

    def test_first_pairing_rejects_relay_tunneled_request_before_configuration(self):
        fake_relay = FakeRelayControlClient(
            relay_enabled=True,
            subscription_active=True,
        )
        client = APIClient()
        client.force_authenticate(user=self.cashier)

        with mock.patch("apps.core.relay.RelayControlClient", return_value=fake_relay):
            response = client.post(
                reverse("relay-pairing"),
                {},
                format="json",
                REMOTE_ADDR="127.0.0.1",
                HTTP_X_POINTY_RELAYED_REQUEST="1",
            )

        self.assertEqual(response.status_code, status.HTTP_403_FORBIDDEN)
        self.assertFalse(response.data["remote_access_supported"])
        self.assertEqual(response.data["reason"], "relay_requires_lan_pairing")
        self.assertIsNone(fake_relay.issued_ticket_request)
        self.assertEqual(RelayInstallation.objects.count(), 0)

    @override_settings(POINTY_RELAY_CONNECTOR_SETUP_TOKEN="setup-secret")
    def test_connector_config_requires_setup_token(self):
        fake_relay = FakeRelayControlClient()

        with self.captureOnCommitCallbacks(execute=True):
            with mock.patch(
                "apps.core.relay.RelayControlClient",
                return_value=fake_relay,
            ), mock.patch(
                "apps.core.relay_views.RelayControlClient",
                return_value=fake_relay,
            ):
                rejected = APIClient().post(
                    reverse("relay-connector-config"),
                    {},
                    format="json",
                )
                accepted = APIClient().post(
                    reverse("relay-connector-config"),
                    {"csr_pem": "-----BEGIN CERTIFICATE REQUEST-----\ncsr\n-----END CERTIFICATE REQUEST-----\n"},
                    format="json",
                    HTTP_X_POINTY_CONNECTOR_SETUP_TOKEN="setup-secret",
                )
                replayed = APIClient().post(
                    reverse("relay-connector-config"),
                    {},
                    format="json",
                    HTTP_X_POINTY_CONNECTOR_SETUP_TOKEN="setup-secret",
                )
                renewed = APIClient().post(
                    reverse("relay-connector-config"),
                    {"csr_pem": "-----BEGIN CERTIFICATE REQUEST-----\nrenew\n-----END CERTIFICATE REQUEST-----\n"},
                    format="json",
                    HTTP_X_POINTY_CONNECTOR_TOKEN="ptc1.installation-1.connector-secret",
                )

        self.assertEqual(rejected.status_code, status.HTTP_403_FORBIDDEN)
        self.assertEqual(accepted.status_code, status.HTTP_200_OK)
        self.assertEqual(replayed.status_code, status.HTTP_403_FORBIDDEN)
        self.assertEqual(renewed.status_code, status.HTTP_200_OK)
        self.assertEqual(
            accepted.data["connector_token"],
            "ptc1.installation-1.connector-secret",
        )
        self.assertEqual(accepted.data["relay_connector_address"], "relay.example:443")
        self.assertIn("BEGIN CERTIFICATE", accepted.data["connector_certificate_pem"])
        self.assertIn(
            "BEGIN CERTIFICATE",
            accepted.data["connector_ca_certificate_pem"],
        )
        self.assertEqual(
            fake_relay.issued_connector_certificate_request["installation_id"],
            "installation-1",
        )
        self.assertIn(
            "renew",
            fake_relay.issued_connector_certificate_request["csr_pem"],
        )
        setup_token = RelayConnectorSetupToken.objects.get()
        self.assertNotEqual(setup_token.token_hash, "setup-secret")
        self.assertIsNotNone(setup_token.consumed_at)
        installation = RelayInstallation.objects.get()
        event = AnalyticsEvent.objects.get(name="relay.connector.bootstrap_succeeded")
        self.assertEqual(event.event_type, AnalyticsEvent.EventType.AUDIT)
        self.assertIsNone(event.received_by)
        self.assertEqual(event.installation_id, "installation-1")
        self.assertEqual(event.entity_type, "relay_installation")
        self.assertEqual(event.entity_id, str(installation.pk))
        self.assertTrue(event.attributes["certificate_issued"])
        self.assertNotIn("connector_token", event.attributes)
        renewal_event = AnalyticsEvent.objects.get(
            name="relay.connector.certificate_renewed"
        )
        self.assertEqual(renewal_event.installation_id, "installation-1")
        self.assertNotIn("connector_token", renewal_event.attributes)

    @override_settings(
        POINTY_RELAY_CONTROL_URL="https://relay.example",
        POINTY_RELAY_PUBLIC_API_URL="https://relay.example",
        POINTY_RELAY_CONNECTOR_ADDR="relay.example:443",
        POINTY_RELAY_ADMIN_TOKEN="",
        POINTY_RELAY_ACCESS_TOKEN="ptr1.installation-1.access-secret",
        POINTY_RELAY_INSTALLATION_ID="installation-1",
    )
    def test_scoped_access_token_used_and_admin_not_required(self):
        from apps.core.relay import (
            RelayControlClient,
            relay_config,
            validate_relay_config,
        )

        config = relay_config()
        # Must not raise even though no admin token is configured (on-prem).
        validate_relay_config(config)
        client = RelayControlClient(config=config)
        self.assertEqual(
            client._installation_auth(),
            {"relay_token": "ptr1.installation-1.access-secret"},
        )

    @override_settings(
        POINTY_RELAY_CONTROL_URL="https://relay.example",
        POINTY_RELAY_PUBLIC_API_URL="https://relay.example",
        POINTY_RELAY_CONNECTOR_ADDR="relay.example:443",
        POINTY_RELAY_ADMIN_TOKEN="admin-token",
        POINTY_RELAY_ACCESS_TOKEN="",
        POINTY_RELAY_INSTALLATION_ID="",
    )
    def test_admin_auth_used_without_scoped_token(self):
        from apps.core.relay import RelayControlClient, relay_config

        client = RelayControlClient(config=relay_config())
        self.assertEqual(client._installation_auth(), {"admin": True})

    @override_settings(
        POINTY_RELAY_CONTROL_URL="https://relay.example",
        POINTY_RELAY_PUBLIC_API_URL="https://relay.example",
        POINTY_RELAY_CONNECTOR_ADDR="relay.example:443",
        POINTY_RELAY_ADMIN_TOKEN="",
        POINTY_RELAY_ACCESS_TOKEN="",
        POINTY_RELAY_INSTALLATION_ID="",
    )
    def test_relay_config_requires_some_auth(self):
        from django.core.exceptions import ImproperlyConfigured

        from apps.core.relay import relay_config, validate_relay_config

        with self.assertRaises(ImproperlyConfigured):
            validate_relay_config(relay_config())

    @override_settings(
        POINTY_RELAY_CONTROL_URL="https://relay.example",
        POINTY_RELAY_PUBLIC_API_URL="https://relay.example",
        POINTY_RELAY_CONNECTOR_ADDR="relay.example:443",
        POINTY_RELAY_ADMIN_TOKEN="",
        POINTY_RELAY_ACCESS_TOKEN="ptr1.installation-1.access-secret",
        POINTY_RELAY_INSTALLATION_ID="installation-1",
        POINTY_RELAY_CONNECTOR_TOKEN="ptc1.installation-1.connector-secret",
        POINTY_RELAY_CONNECTOR_SETUP_TOKEN="setup-secret",
    )
    def test_connector_config_bootstraps_from_config_without_admin(self):
        # On-prem path: the backend has only scoped credentials and must NOT call
        # the admin provision endpoint, yet still bootstrap the connector + cert.
        fake_relay = FakeRelayControlClient()
        with self.captureOnCommitCallbacks(execute=True):
            with mock.patch(
                "apps.core.relay.RelayControlClient",
                return_value=fake_relay,
            ), mock.patch(
                "apps.core.relay_views.RelayControlClient",
                return_value=fake_relay,
            ):
                response = APIClient().post(
                    reverse("relay-connector-config"),
                    {"csr_pem": "-----BEGIN CERTIFICATE REQUEST-----\ncsr\n-----END CERTIFICATE REQUEST-----\n"},
                    format="json",
                    HTTP_X_POINTY_CONNECTOR_SETUP_TOKEN="setup-secret",
                )

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        installation = RelayInstallation.objects.get()
        # Built from the configured scoped credentials, not an admin provision call.
        self.assertEqual(installation.installation_id, "installation-1")
        self.assertEqual(installation.access_token, "ptr1.installation-1.access-secret")
        self.assertEqual(
            installation.connector_token, "ptc1.installation-1.connector-secret"
        )
        self.assertEqual(fake_relay.provisioned_shop_name, "")
        self.assertIsNotNone(fake_relay.issued_connector_certificate_request)
        self.assertEqual(
            response.data["connector_token"], "ptc1.installation-1.connector-secret"
        )

    @override_settings(POINTY_RELAY_CONNECTOR_SETUP_TOKEN="setup-secret")
    def test_connector_config_rejects_relay_tunneled_request(self):
        with mock.patch("apps.core.relay_views.ensure_relay_installation") as ensure:
            response = APIClient().post(
                reverse("relay-connector-config"),
                {},
                format="json",
                HTTP_X_POINTY_CONNECTOR_SETUP_TOKEN="setup-secret",
                HTTP_X_POINTY_RELAYED_REQUEST="1",
            )

        self.assertEqual(response.status_code, status.HTTP_403_FORBIDDEN)
        ensure.assert_not_called()
        self.assertEqual(RelayConnectorSetupToken.objects.count(), 0)

    def test_discovery_service_returns_safe_lan_metadata(self):
        RelayInstallation.objects.create(
            installation_id="installation-1",
            shop_name="متجر آمن",
            relay_public_api_url="https://relay.example",
            relay_connector_address="relay.example:443",
            connector_token="ptc1.installation-1.connector-secret",
            access_token="ptr1.installation-1.access-secret",
            relay_enabled=True,
            subscription_active=True,
        )

        response = APIClient().get(
            reverse("discovery-service"),
            REMOTE_ADDR="192.168.1.10",
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(response.data["service"], "pointy-backend")
        self.assertEqual(response.data["shop_name"], "متجر آمن")
        self.assertIn("backend_url", response.data)
        self.assertEqual(response.data["installation_id"], "installation-1")
        self.assertEqual(response.data["pairing_path"], "/api/relay/pairing/")
        self.assertTrue(response.data["remote_access_supported"])
        self.assertEqual(response.data["relay_public_api_url"], "https://relay.example")
        self.assertNotIn("access_token", response.data)
        self.assertNotIn("connector_token", response.data)

    def test_discovery_service_is_private_network_only_by_default(self):
        response = APIClient().get(
            reverse("discovery-service"),
            REMOTE_ADDR="8.8.8.8",
        )

        self.assertEqual(response.status_code, status.HTTP_404_NOT_FOUND)

    def test_discovery_service_does_not_trust_forwarded_for_by_default(self):
        response = APIClient().get(
            reverse("discovery-service"),
            REMOTE_ADDR="8.8.8.8",
            HTTP_X_FORWARDED_FOR="192.168.1.10",
        )

        self.assertEqual(response.status_code, status.HTTP_404_NOT_FOUND)

    def test_discovery_service_rejects_relay_tunneled_request(self):
        response = APIClient().get(
            reverse("discovery-service"),
            REMOTE_ADDR="127.0.0.1",
            HTTP_X_POINTY_RELAYED_REQUEST="1",
        )

        self.assertEqual(response.status_code, status.HTTP_404_NOT_FOUND)

    @override_settings(POINTY_DISCOVERY_TRUST_PROXY_HEADERS=True)
    def test_discovery_service_can_trust_forwarded_for_when_configured(self):
        response = APIClient().get(
            reverse("discovery-service"),
            REMOTE_ADDR="8.8.8.8",
            HTTP_X_FORWARDED_FOR="192.168.1.10",
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK)

    @override_settings(POINTY_DISCOVERY_ENABLED=False)
    def test_discovery_service_respects_disabled_setting(self):
        response = APIClient().get(
            reverse("discovery-service"),
            REMOTE_ADDR="192.168.1.10",
        )

        self.assertEqual(response.status_code, status.HTTP_404_NOT_FOUND)

    def test_udp_discovery_uses_local_interface_for_peer(self):
        fake_socket = mock.Mock()
        fake_socket.getsockname.return_value = ("192.168.1.5", 47777)
        fake_socket_factory = mock.Mock(return_value=fake_socket)

        with mock.patch("apps.core.discovery.socket.socket", fake_socket_factory):
            host = private_network_host_for_peer("192.168.1.10")

        self.assertEqual(host, "192.168.1.5")
        fake_socket.connect.assert_called_once_with(("192.168.1.10", 9))
        fake_socket.close.assert_called_once()

    def test_connector_heartbeat_updates_installation_metadata(self):
        installation = RelayInstallation.objects.create(
            installation_id="installation-1",
            shop_name="متجر آمن",
            relay_public_api_url="https://relay.example",
            relay_connector_address="relay.example:443",
            connector_token="ptc1.installation-1.connector-secret",
            access_token="ptr1.installation-1.access-secret",
        )

        rejected = APIClient().post(
            reverse("relay-connector-heartbeat"),
            {"version": "pointy-relay/test"},
            format="json",
        )
        accepted = APIClient().post(
            reverse("relay-connector-heartbeat"),
            {"version": "pointy-relay/test"},
            format="json",
            HTTP_X_POINTY_CONNECTOR_TOKEN="ptc1.installation-1.connector-secret",
        )
        setup_token_rejected = APIClient().post(
            reverse("relay-connector-heartbeat"),
            {"version": "pointy-relay/test"},
            format="json",
            HTTP_X_POINTY_CONNECTOR_SETUP_TOKEN="setup-secret",
        )

        self.assertEqual(rejected.status_code, status.HTTP_403_FORBIDDEN)
        self.assertEqual(accepted.status_code, status.HTTP_200_OK)
        self.assertEqual(setup_token_rejected.status_code, status.HTTP_403_FORBIDDEN)
        installation.refresh_from_db()
        self.assertIsNotNone(installation.connector_last_seen_at)
        self.assertEqual(installation.connector_version, "pointy-relay/test")


class RelayDiagnosticsAnalyticsExportTests(TestCase):
    def setUp(self):
        self.installation = RelayInstallation.objects.create(
            installation_id="installation-1",
            shop_name="متجر آمن",
            relay_public_api_url="https://relay.example",
            relay_connector_address="relay.example:443",
            connector_token="ptc1.installation-1.connector-secret",
            access_token="ptr1.installation-1.access-secret",
            relay_enabled=True,
            subscription_active=True,
            connector_version="pointy-relay/test",
        )

    def _create_event(self, **kwargs):
        defaults = dict(
            event_type=AnalyticsEvent.EventType.USAGE,
            name="app.started",
            severity=AnalyticsEvent.Severity.INFO,
            source=AnalyticsEvent.Source.FRONTEND,
            occurred_at=timezone.now(),
        )
        defaults.update(kwargs)
        return AnalyticsEvent.objects.create(**defaults)

    def test_valid_connector_token_returns_zip_with_headers(self):
        self._create_event(
            name="error.boom",
            event_type=AnalyticsEvent.EventType.ERROR,
            severity=AnalyticsEvent.Severity.ERROR,
        )

        response = APIClient().get(
            reverse("relay-diagnostics-analytics-export"),
            HTTP_X_POINTY_CONNECTOR_TOKEN="ptc1.installation-1.connector-secret",
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(response["Content-Type"], "application/zip")
        self.assertEqual(response["X-Pointy-Analytics-Event-Count"], "1")
        self.assertEqual(response["X-Pointy-Connector-Version"], "pointy-relay/test")
        self.assertIn("X-Pointy-App-Version", response)
        self.assertIn("attachment;", response["Content-Disposition"])
        archive = zipfile.ZipFile(BytesIO(response.content))
        self.assertEqual(
            sorted(archive.namelist()),
            ["analytics_events.csv", "manifest.json"],
        )

    def test_missing_or_wrong_connector_token_is_rejected(self):
        missing = APIClient().get(reverse("relay-diagnostics-analytics-export"))
        wrong = APIClient().get(
            reverse("relay-diagnostics-analytics-export"),
            HTTP_X_POINTY_CONNECTOR_TOKEN="not-the-token",
        )

        self.assertEqual(missing.status_code, status.HTTP_403_FORBIDDEN)
        self.assertEqual(wrong.status_code, status.HTTP_403_FORBIDDEN)

    def test_returns_404_when_installation_not_configured(self):
        RelayInstallation.objects.all().delete()

        response = APIClient().get(
            reverse("relay-diagnostics-analytics-export"),
            HTTP_X_POINTY_CONNECTOR_TOKEN="ptc1.installation-1.connector-secret",
        )

        self.assertEqual(response.status_code, status.HTTP_404_NOT_FOUND)

    def test_filters_are_applied(self):
        self._create_event(
            name="error.boom",
            event_type=AnalyticsEvent.EventType.ERROR,
            severity=AnalyticsEvent.Severity.ERROR,
        )
        self._create_event(name="app.started")

        response = APIClient().get(
            reverse("relay-diagnostics-analytics-export"),
            {"event_type": "error", "format": "json"},
            HTTP_X_POINTY_CONNECTOR_TOKEN="ptc1.installation-1.connector-secret",
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        archive = zipfile.ZipFile(BytesIO(response.content))
        rows = json.loads(archive.read("analytics_events.json").decode())
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]["name"], "error.boom")

    def test_records_support_pull_audit_event(self):
        with self.captureOnCommitCallbacks(execute=True):
            response = APIClient().get(
                reverse("relay-diagnostics-analytics-export"),
                HTTP_X_POINTY_CONNECTOR_TOKEN="ptc1.installation-1.connector-secret",
            )

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertTrue(
            AnalyticsEvent.objects.filter(
                name="analytics.export.support_pull"
            ).exists()
        )


@override_settings(
    CACHES={
        "default": {
            "BACKEND": "django.core.cache.backends.locmem.LocMemCache",
            "LOCATION": "dashboard-tests",
        }
    }
)
class DashboardApiTests(TestCase):
    def setUp(self):
        cache.clear()
        ensure_role_groups()
        User = get_user_model()
        self.manager = User.objects.create_user(username="dashboard-manager", password="pass")
        self.manager.groups.add(Group.objects.get(name=MANAGER_GROUP))
        self.cashier = User.objects.create_user(username="dashboard-cashier", password="pass")
        self.cashier.groups.add(Group.objects.get(name=CASHIER_GROUP))
        self.other_cashier = User.objects.create_user(
            username="dashboard-other-cashier",
            password="pass",
        )
        self.other_cashier.groups.add(Group.objects.get(name=CASHIER_GROUP))

        self.product = create_product_with_default_variant(
            sku="DASH-COF",
            name="قهوة لوحة التحكم",
            unit_price=Decimal("5.00"),
        )
        self.variant = self.product.default_variant
        self.stock_item = StockItem.objects.create(
            variant=self.variant,
            quantity_on_hand=2,
            reorder_level=3,
        )
        StockMovement.objects.create(
            variant=self.variant,
            stock_item=self.stock_item,
            movement_type=StockMovement.Type.INCREASE,
            quantity=4,
            on_hand_before=0,
            on_hand_after=4,
            committed_before=0,
            committed_after=0,
            expected_before=0,
            expected_after=0,
        )
        self._create_paid_order(
            user=self.cashier,
            receipt_number="R-DASH-1",
            total=Decimal("10.00"),
        )
        self._create_paid_order(
            user=self.other_cashier,
            receipt_number="R-DASH-2",
            total=Decimal("40.00"),
        )
        self.supplier = Supplier.objects.create(name="مورد لوحة التحكم")
        self.purchase_order = PurchaseOrder.objects.create(
            supplier=self.supplier,
            status=PurchaseOrder.Status.SUBMITTED,
            subtotal=Decimal("120.00"),
            total=Decimal("120.00"),
            due_date=timezone.localdate() - timezone.timedelta(days=1),
        )
        SupplierPayment.objects.create(
            supplier=self.supplier,
            purchase_order=self.purchase_order,
            method=SupplierPayment.Method.CASH,
            amount=Decimal("20.00"),
            created_by=self.manager,
        )

    def tearDown(self):
        cache.clear()

    def test_dashboard_hides_revenue_aggregates_from_cashiers(self):
        # A cashier who can read cash totals can pocket the difference and
        # type a "perfect" closing count, so the blind close requires that no
        # revenue aggregate ever reaches a register-only role.
        client = APIClient()
        client.force_authenticate(user=self.cashier)

        response = client.get(reverse("dashboard"))

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        sections = response.data["sections"]
        self.assertNotIn("sales", sections)
        self.assertNotIn("payments", sections)
        self.assertNotIn("profitability", sections)
        self.assertNotIn("inventory", sections)
        self.assertNotIn("purchasing", sections)
        self.assertIn("printing", sections)

    def test_dashboard_shows_revenue_aggregates_to_reporting_roles(self):
        User = get_user_model()
        accountant = User.objects.create_user(
            username="dashboard-accountant",
            password="pass",
        )
        accountant.groups.add(Group.objects.get(name=ACCOUNTANT_GROUP))
        client = APIClient()
        client.force_authenticate(user=accountant)

        response = client.get(reverse("dashboard"))

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        sections = response.data["sections"]
        self.assertIn("sales", sections)
        self.assertIn("payments", sections)
        self.assertIn("profitability", sections)
        self.assertEqual(sections["sales"]["summary"]["net_sales"], "50.00")

    def test_manager_dashboard_includes_admin_sections_and_all_sales(self):
        client = APIClient()
        client.force_authenticate(user=self.manager)

        response = client.get(reverse("dashboard"))

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        sections = response.data["sections"]
        self.assertIn("inventory", sections)
        self.assertIn("purchasing", sections)
        self.assertIn("customers", sections)
        self.assertIn("discounts", sections)
        self.assertEqual(sections["sales"]["summary"]["net_sales"], "50.00")
        self.assertEqual(sections["inventory"]["summary"]["low_stock_count"], 1)
        self.assertEqual(
            sections["inventory"]["movement_mix"][0]["movement_type"],
            StockMovement.Type.INCREASE,
        )
        self.assertEqual(sections["inventory"]["movement_mix"][0]["quantity"], 4)
        self.assertEqual(sections["purchasing"]["summary"]["due_total"], "100.00")
        self.assertEqual(sections["purchasing"]["summary"]["overdue_order_count"], 1)
        self.assertEqual(
            sections["purchasing"]["top_supplier_balances"][0]["net_balance"],
            "100.00",
        )

    def test_dashboard_short_caches_aggregate_sections(self):
        client = APIClient()
        client.force_authenticate(user=self.manager)

        first_response = client.get(reverse("dashboard"))
        self._create_paid_order(
            user=self.cashier,
            receipt_number="R-DASH-CACHED",
            total=Decimal("20.00"),
        )
        cached_response = client.get(reverse("dashboard"))
        cache.clear()
        fresh_response = client.get(reverse("dashboard"))

        self.assertEqual(first_response.status_code, status.HTTP_200_OK)
        self.assertEqual(cached_response.status_code, status.HTTP_200_OK)
        self.assertEqual(fresh_response.status_code, status.HTTP_200_OK)
        self.assertEqual(
            first_response.data["sections"]["payments"]["summary"]["total"],
            "50.00",
        )
        self.assertEqual(
            cached_response.data["sections"]["payments"]["summary"]["total"],
            "50.00",
        )
        self.assertEqual(
            fresh_response.data["sections"]["payments"]["summary"]["total"],
            "70.00",
        )

    def test_dashboard_reports_parent_products_and_variant_breakdown(self):
        large_variant = ProductVariant.objects.create(
            product=self.product,
            name="كبير",
            sku="DASH-COF-L",
            unit_price=Decimal("7.00"),
        )
        StockItem.objects.create(
            variant=large_variant,
            quantity_on_hand=1,
            reorder_level=2,
        )
        self._create_paid_order(
            user=self.cashier,
            receipt_number="R-DASH-3",
            total=Decimal("14.00"),
            variant=large_variant,
            quantity=2,
            unit_price=Decimal("7.00"),
            unit_cost=Decimal("3.00"),
        )
        client = APIClient()
        client.force_authenticate(user=self.manager)

        response = client.get(reverse("dashboard"))

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        sales = response.data["sections"]["sales"]
        top_product = sales["top_products"][0]
        self.assertEqual(top_product["product_id"], self.product.pk)
        self.assertEqual(top_product["product_name"], "قهوة لوحة التحكم")
        self.assertEqual(top_product["quantity"], 12)
        self.assertEqual(top_product["revenue"], "64.00")
        self.assertEqual(top_product["profit"], "38.00")
        self.assertEqual(top_product["variant_count"], 2)
        self.assertNotIn("variant_id", top_product)

        variant_revenue = sales["reports"]["variants"]["revenue"]
        self.assertEqual(variant_revenue[0]["product_name"], "قهوة لوحة التحكم")
        self.assertEqual(variant_revenue[0]["sku"], "DASH-COF")
        self.assertEqual(variant_revenue[1]["product_name"], "قهوة لوحة التحكم - كبير")
        self.assertEqual(variant_revenue[1]["variant_id"], large_variant.pk)
        self.assertEqual(variant_revenue[1]["sku"], "DASH-COF-L")

        low_stock_variant_ids = {
            item["variant_id"]
            for item in response.data["sections"]["inventory"]["low_stock_variants"]
        }
        self.assertIn(large_variant.pk, low_stock_variant_ids)

    def test_dashboard_top_categories_split_revenue_across_categories(self):
        # A product can sit in several categories (M2M). Its sales must be
        # allocated evenly across them, not counted once per category, so the
        # category breakdown reconciles with real revenue.
        hot = ProductCategory.objects.create(name="ساخن")
        seasonal = ProductCategory.objects.create(name="موسمي")
        self.product.categories.add(hot, seasonal)
        client = APIClient()
        client.force_authenticate(user=self.manager)

        response = client.get(reverse("dashboard"))

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        categories = {
            row["category_name"]: row
            for row in response.data["sections"]["sales"]["top_categories"]
        }
        # setUp sold 10 units of this product for 50.00 across two orders;
        # split over two categories that is 25.00 and 5 units each.
        self.assertEqual(categories["ساخن"]["revenue"], "25.00")
        self.assertEqual(categories["موسمي"]["revenue"], "25.00")
        self.assertEqual(categories["ساخن"]["quantity"], 5)
        self.assertEqual(categories["موسمي"]["quantity"], 5)

    def _create_paid_order(
        self,
        *,
        user,
        receipt_number,
        total,
        variant=None,
        quantity=None,
        unit_price=None,
        unit_cost=Decimal("2.00"),
    ):
        variant = variant or self.product.default_variant
        unit_price = unit_price or variant.unit_price
        quantity = quantity or int(total / unit_price)
        session, _ = RegisterSession.objects.get_or_create(
            owner_key=f"user:{user.pk}",
            status=RegisterSession.Status.OPEN,
            defaults={
                "owner": user,
                "opening_cash": Decimal("0.00"),
            },
        )
        order = Order.objects.create(
            register_session=session,
            receipt_number=receipt_number,
            status=Order.Status.PAID,
            subtotal=total,
            total=total,
        )
        OrderLine.objects.create(
            order=order,
            variant=variant,
            quantity=quantity,
            unit_price=unit_price,
            unit_cost=unit_cost,
        )
        Payment.objects.create(
            order=order,
            method=Payment.Method.CASH,
            amount=total,
        )
        return order


class RolePermissionBootstrapTests(TestCase):
    def test_role_groups_receive_domain_permissions(self):
        ensure_role_groups()
        User = get_user_model()
        manager = User.objects.create_user(username="manager-perms", password="pass")
        cashier = User.objects.create_user(username="cashier-perms", password="pass")
        manager.groups.add(Group.objects.get(name=MANAGER_GROUP))
        cashier.groups.add(Group.objects.get(name=CASHIER_GROUP))

        self.assertTrue(manager.has_perm("catalog.add_product"))
        self.assertTrue(manager.has_perm("core.change_shopsettings"))
        self.assertTrue(manager.has_perm("inventory.change_stockitem"))
        self.assertTrue(manager.has_perm("inventory.add_stockmovement"))
        self.assertTrue(manager.has_perm("sales.delete_order"))
        self.assertTrue(manager.has_perm("payments.change_payment"))
        self.assertTrue(manager.has_perm("auth.view_user"))

        self.assertTrue(cashier.has_perm("catalog.view_product"))
        self.assertTrue(cashier.has_perm("catalog.view_productcategory"))
        self.assertTrue(cashier.has_perm("sales.add_order"))
        self.assertTrue(cashier.has_perm("sales.change_registersession"))
        self.assertTrue(cashier.has_perm("sales.add_registercashmovement"))
        self.assertTrue(cashier.has_perm("sales.view_registercashmovement"))
        self.assertTrue(cashier.has_perm("payments.add_payment"))
        self.assertFalse(cashier.has_perm("catalog.add_product"))
        self.assertFalse(cashier.has_perm("inventory.view_stockitem"))
        self.assertFalse(cashier.has_perm("inventory.add_stockmovement"))
        self.assertFalse(cashier.has_perm("auth.view_user"))


class BootstrapAdminTests(TestCase):
    def setUp(self):
        get_user_model().objects.all().delete()
        # The setup endpoint is rate-limited per client IP; clear throttle
        # state so accumulated counts across test methods (or repeated test
        # runs against a persistent cache) cannot trip the limit.
        cache.clear()

    def test_initial_admin_setup_reports_required_only_without_users(self):
        self.assertTrue(initial_admin_setup_required())

        get_user_model().objects.create_user(username="existing", password="pass")

        self.assertFalse(initial_admin_setup_required())

    def test_initial_admin_setup_ignores_operational_analytics_events(self):
        AnalyticsEvent.objects.create(
            name="backend.request",
            event_type=AnalyticsEvent.EventType.PERFORMANCE,
            occurred_at=timezone.now(),
        )

        self.assertTrue(initial_admin_setup_required())

    def test_initial_admin_setup_rejects_existing_domain_data(self):
        ShopSettings.load()

        self.assertFalse(initial_admin_setup_required())

    def test_initial_admin_creates_superuser_once_when_no_users_exist(self):
        admin = create_initial_admin_user(
            username="admin",
            email="admin@example.com",
            password="first-pass",
        )
        skipped = create_initial_admin_user(
            username="other-admin",
            email="other@example.com",
            password="second-pass",
        )

        self.assertIsNotNone(admin)
        self.assertIsNone(skipped)
        self.assertEqual(get_user_model().objects.count(), 1)
        admin.refresh_from_db()
        self.assertTrue(admin.is_superuser)
        self.assertTrue(admin.groups.filter(name=MANAGER_GROUP).exists())
        self.assertTrue(admin.check_password("first-pass"))

    def test_initial_admin_requires_explicit_password(self):
        admin = create_initial_admin_user(username="admin")

        self.assertIsNone(admin)
        self.assertFalse(get_user_model().objects.exists())

    def test_initial_admin_can_be_disabled(self):
        admin = create_initial_admin_user(
            username="admin",
            password="first-pass",
            enabled=False,
        )

        self.assertIsNone(admin)
        self.assertFalse(get_user_model().objects.exists())

    def test_initial_admin_does_not_repair_existing_unusable_user(self):
        existing_admin = get_user_model().objects.create_superuser(
            username="admin",
            password=None,
        )
        existing_admin.set_unusable_password()
        existing_admin.save(update_fields=["password"])

        skipped = create_initial_admin_user(username="admin", password="repair-pass")

        self.assertIsNone(skipped)
        existing_admin.refresh_from_db()
        self.assertFalse(existing_admin.has_usable_password())

    def test_bootstrap_management_command_creates_admin(self):
        call_command("bootstrap_admin", username="admin", password="admin-pass")

        admin = get_user_model().objects.get(username="admin")
        self.assertTrue(admin.is_superuser)
        self.assertTrue(admin.groups.filter(name=MANAGER_GROUP).exists())

    def test_setup_status_endpoint_reports_required(self):
        response = APIClient().get(reverse("setup-status"))

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(response.data, {"requires_onboarding": True})

    def test_setup_admin_endpoint_creates_and_logs_in_admin(self):
        client = APIClient()

        response = client.post(
            reverse("setup-initial-admin"),
            {
                "username": "owner",
                "email": "owner@example.com",
                "first_name": "سارة",
                "last_name": "علي",
                "password": "Owner-Strong-Pass-2026!",
            },
            format="json",
        )
        current_user_response = client.get(reverse("auth-me"))

        self.assertEqual(response.status_code, status.HTTP_201_CREATED)
        self.assertIn("csrf_token", response.data)
        self.assertEqual(response.data["user"]["username"], "owner")
        admin = get_user_model().objects.get(username="owner")
        self.assertTrue(admin.is_superuser)
        self.assertTrue(admin.groups.filter(name=MANAGER_GROUP).exists())
        self.assertTrue(admin.check_password("Owner-Strong-Pass-2026!"))
        self.assertEqual(current_user_response.status_code, status.HTTP_200_OK)
        self.assertEqual(current_user_response.data["user"]["username"], "owner")
        from apps.employees.models import Employee

        employee = Employee.objects.get(user=admin)
        self.assertEqual(employee.full_name, "سارة علي")

    def test_setup_admin_endpoint_allows_status_probe_before_create(self):
        client = APIClient()

        status_response = client.get(reverse("setup-status"))
        create_response = client.post(
            reverse("setup-initial-admin"),
            {
                "username": "owner",
                "password": "Owner-Strong-Pass-2026!",
            },
            format="json",
        )

        self.assertEqual(status_response.status_code, status.HTTP_200_OK)
        self.assertEqual(create_response.status_code, status.HTTP_201_CREATED)

    def test_setup_admin_endpoint_rejects_when_user_exists(self):
        get_user_model().objects.create_user(username="existing", password="pass")

        response = APIClient().post(
            reverse("setup-initial-admin"),
            {
                "username": "owner",
                "password": "Owner-Strong-Pass-2026!",
            },
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_409_CONFLICT)
        self.assertFalse(get_user_model().objects.filter(username="owner").exists())

    def test_setup_admin_endpoint_rejects_weak_password(self):
        response = APIClient().post(
            reverse("setup-initial-admin"),
            {
                "username": "owner",
                "password": "password",
            },
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertFalse(get_user_model().objects.exists())


_THROTTLE_TEST_CACHE = {
    "default": {
        "BACKEND": "django.core.cache.backends.locmem.LocMemCache",
        "LOCATION": "pointy-throttle-tests",
    }
}


@override_settings(CACHES=_THROTTLE_TEST_CACHE)
class AuthThrottlingTests(TestCase):
    """The login/setup endpoints are rate-limited to resist brute-force.

    A dedicated local-memory cache keeps throttle state isolated from the rest
    of the suite, and is cleared before each test for determinism.
    """

    def setUp(self):
        cache.clear()

    def test_login_is_throttled_per_username(self):
        get_user_model().objects.create_user(
            username="cashier",
            password="secret-pass",
        )
        client = APIClient()
        # Default rate is 6/min for the per-username throttle.
        for _ in range(6):
            response = client.post(
                reverse("auth-login"),
                {"username": "cashier", "password": "wrong-pass"},
                format="json",
            )
            self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)

        throttled = client.post(
            reverse("auth-login"),
            {"username": "cashier", "password": "wrong-pass"},
            format="json",
        )
        self.assertEqual(throttled.status_code, status.HTTP_429_TOO_MANY_REQUESTS)

    def test_login_throttle_is_scoped_to_each_username(self):
        get_user_model().objects.create_user(username="alice", password="pw-alice")
        get_user_model().objects.create_user(username="bob", password="pw-bob")
        client = APIClient()
        for _ in range(6):
            client.post(
                reverse("auth-login"),
                {"username": "alice", "password": "wrong"},
                format="json",
            )

        # A different username shares the per-IP budget (30/min) but not the
        # per-username one, so it is not blocked by alice's failures.
        bob_response = client.post(
            reverse("auth-login"),
            {"username": "bob", "password": "pw-bob"},
            format="json",
        )
        self.assertEqual(bob_response.status_code, status.HTTP_200_OK)

    def test_setup_admin_endpoint_is_throttled(self):
        client = APIClient()
        # Default rate is 5/hour for the setup throttle; weak passwords keep
        # each attempt at 400 without completing onboarding.
        for _ in range(5):
            response = client.post(
                reverse("setup-initial-admin"),
                {"username": "owner", "password": "password"},
                format="json",
            )
            self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)

        throttled = client.post(
            reverse("setup-initial-admin"),
            {"username": "owner", "password": "password"},
            format="json",
        )
        self.assertEqual(throttled.status_code, status.HTTP_429_TOO_MANY_REQUESTS)

    def test_login_throttle_fails_open_when_cache_unavailable(self):
        from apps.core.throttling import LoginRateThrottle

        throttle = LoginRateThrottle()
        with mock.patch(
            "rest_framework.throttling.SimpleRateThrottle.allow_request",
            side_effect=RuntimeError("cache down"),
        ):
            self.assertTrue(throttle.allow_request(mock.Mock(), mock.Mock()))


class CorsPreflightTests(TestCase):
    """The browser must be told the POS's custom headers are allowed, or it
    silently blocks the real request after a successful preflight.
    """

    @override_settings(CORS_ALLOWED_ORIGINS=["http://127.0.0.1:8080"])
    def test_checkout_preflight_allows_idempotency_key_header(self):
        response = self.client.options(
            "/api/orders/checkout/",
            HTTP_ORIGIN="http://127.0.0.1:8080",
            HTTP_ACCESS_CONTROL_REQUEST_METHOD="POST",
            HTTP_ACCESS_CONTROL_REQUEST_HEADERS="content-type,idempotency-key",
        )
        self.assertEqual(response.status_code, 200)
        self.assertEqual(
            response.headers.get("access-control-allow-origin"),
            "http://127.0.0.1:8080",
        )
        allow_headers = response.headers.get(
            "access-control-allow-headers", ""
        ).lower()
        self.assertIn("idempotency-key", allow_headers)
        self.assertIn("x-pointy-relay-token", allow_headers)


class ShopSetupTests(TestCase):
    def setUp(self):
        ensure_role_groups()
        self.client = APIClient()
        self.user = get_user_model().objects.create_user(
            username="setup-user",
            password="pass",
        )
        self.user.groups.add(Group.objects.get(name=MANAGER_GROUP))
        self.client.force_authenticate(user=self.user)

    def test_setup_applies_restaurant_preset_with_overrides(self):
        response = self.client.post(
            reverse("shop-setup"),
            {
                "shop_type": "restaurant",
                "shop_name": "مطعمي",
                "allow_overselling": True,
                "require_opening_cash": False,
            },
            format="json",
        )
        self.assertEqual(response.status_code, status.HTTP_200_OK)
        settings = ShopSettings.load()
        self.assertEqual(settings.shop_type, "restaurant")
        # Preset turns the kitchen lane on.
        self.assertTrue(settings.enable_kitchen_operations)
        self.assertTrue(settings.auto_print_kitchen_tickets)
        # Explicit wizard choices win over the preset.
        self.assertEqual(settings.shop_name, "مطعمي")
        self.assertTrue(settings.allow_overselling)
        self.assertFalse(settings.require_opening_cash)

    def test_setup_phone_repair_enables_repair(self):
        response = self.client.post(
            reverse("shop-setup"),
            {"shop_type": "phone_repair"},
            format="json",
        )
        self.assertEqual(response.status_code, status.HTTP_200_OK)
        settings = ShopSettings.load()
        self.assertEqual(settings.shop_type, "phone_repair")
        self.assertTrue(settings.enable_repair_operations)
        self.assertTrue(settings.enable_job_tracking)
        self.assertFalse(settings.enable_kitchen_operations)

    def test_setup_rejects_unknown_type(self):
        response = self.client.post(
            reverse("shop-setup"),
            {"shop_type": "spaceship"},
            format="json",
        )
        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)


class RolePermissionBootstrapTests(TestCase):
    def test_new_role_groups_bootstrap_with_expected_permissions(self):
        ensure_role_groups()
        for role in (
            SUPERVISOR_GROUP,
            INVENTORY_CLERK_GROUP,
            PURCHASING_AGENT_GROUP,
            AUDITOR_GROUP,
        ):
            self.assertTrue(Group.objects.filter(name=role).exists(), role)

        def codes(role):
            return {
                f"{perm.content_type.app_label}.{perm.codename}"
                for perm in Group.objects.get(name=role).permissions.all()
            }

        supervisor = codes(SUPERVISOR_GROUP)
        self.assertIn("reports.view_reportrun", supervisor)
        self.assertIn("inventory.apply_stockcount", supervisor)
        self.assertIn("operations.assign_job", supervisor)
        # Supervisor is shop-wide but not an admin.
        self.assertNotIn("auth.change_user", supervisor)
        self.assertNotIn("core.change_shopsettings", supervisor)

        clerk = codes(INVENTORY_CLERK_GROUP)
        self.assertIn("inventory.apply_stockcount", clerk)
        self.assertIn("purchasing.receive_purchaseorder", clerk)
        self.assertNotIn("purchasing.add_purchaseorder", clerk)

        buyer = codes(PURCHASING_AGENT_GROUP)
        self.assertIn("purchasing.add_purchaseorder", buyer)
        self.assertIn("purchasing.cancel_purchaseorder", buyer)

        auditor = codes(AUDITOR_GROUP)
        self.assertIn("reports.view_reportrun", auditor)
        self.assertIn("sales.view_order", auditor)
        # Read-only: no write permissions leak in.
        self.assertFalse({c for c in auditor if c.split(".", 1)[1].startswith(
            ("add_", "change_", "delete_")
        )})

    def test_ensure_role_groups_prunes_stale_role_permissions(self):
        ensure_role_groups()
        from django.contrib.auth.models import Permission

        cashier_group = Group.objects.get(name=CASHIER_GROUP)
        stray = Permission.objects.get(
            content_type__app_label="payments", codename="delete_payment"
        )
        cashier_group.permissions.add(stray)
        # Re-running the idempotent bootstrap must remove anything not in the
        # role's code constant (set semantics), keeping groups authoritative.
        ensure_role_groups()
        self.assertFalse(
            cashier_group.permissions.filter(pk=stray.pk).exists()
        )

    def test_user_has_full_visibility(self):
        ensure_role_groups()
        User = get_user_model()
        manager = User.objects.create_user(username="m", password="p")
        manager.groups.add(Group.objects.get(name=MANAGER_GROUP))
        supervisor = User.objects.create_user(username="s", password="p")
        supervisor.groups.add(Group.objects.get(name=SUPERVISOR_GROUP))
        auditor = User.objects.create_user(username="a", password="p")
        auditor.groups.add(Group.objects.get(name=AUDITOR_GROUP))
        cashier = User.objects.create_user(username="c", password="p")
        cashier.groups.add(Group.objects.get(name=CASHIER_GROUP))

        self.assertTrue(user_has_full_visibility(manager))
        self.assertTrue(user_has_full_visibility(supervisor))
        self.assertTrue(user_has_full_visibility(auditor))
        self.assertFalse(user_has_full_visibility(cashier))


class PermissionCatalogTests(TestCase):
    def setUp(self):
        ensure_role_groups()
        User = get_user_model()
        self.manager = User.objects.create_user(username="manager", password="pass")
        self.manager.groups.add(Group.objects.get(name=MANAGER_GROUP))
        self.cashier = User.objects.create_user(username="cashier", password="pass")
        self.cashier.groups.add(Group.objects.get(name=CASHIER_GROUP))

    def test_catalog_codes_are_all_real_permissions(self):
        from django.contrib.auth.models import Permission

        for code in permission_catalog.catalog_codes():
            app_label, codename = code.split(".", 1)
            self.assertTrue(
                Permission.objects.filter(
                    content_type__app_label=app_label, codename=codename
                ).exists(),
                f"catalog code {code} has no matching permission",
            )

    def test_manager_can_read_catalog_with_everything_grantable(self):
        client = APIClient()
        client.force_authenticate(user=self.manager)
        response = client.get(reverse("pos-user-permission-catalog"))
        self.assertEqual(response.status_code, status.HTTP_200_OK)
        groups = response.data["groups"]
        self.assertTrue(groups)
        all_items = [p for g in groups for p in g["permissions"]]
        self.assertTrue(all(item["grantable"] for item in all_items))

    def test_cashier_cannot_read_catalog(self):
        client = APIClient()
        client.force_authenticate(user=self.cashier)
        response = client.get(reverse("pos-user-permission-catalog"))
        self.assertEqual(response.status_code, status.HTTP_403_FORBIDDEN)

    def test_delegated_admin_grantable_reflects_held_permissions(self):
        from django.contrib.auth.models import Permission

        delegate = get_user_model().objects.create_user(
            username="delegate", password="pass"
        )
        delegate.user_permissions.add(
            Permission.objects.get(
                content_type__app_label="auth", codename="view_user"
            )
        )
        client = APIClient()
        client.force_authenticate(user=delegate)
        response = client.get(reverse("pos-user-permission-catalog"))
        self.assertEqual(response.status_code, status.HTTP_200_OK)
        grantable = {
            p["code"]
            for g in response.data["groups"]
            for p in g["permissions"]
            if p["grantable"]
        }
        self.assertIn("auth.view_user", grantable)
        self.assertNotIn("inventory.apply_stockcount", grantable)


class ExtraPermissionGrantTests(TestCase):
    def setUp(self):
        ensure_role_groups()
        User = get_user_model()
        self.manager = User.objects.create_user(username="manager", password="pass")
        self.manager.groups.add(Group.objects.get(name=MANAGER_GROUP))
        self.cashier = User.objects.create_user(username="cashier", password="pass")
        self.cashier.groups.add(Group.objects.get(name=CASHIER_GROUP))

    def _patch(self, actor, target, body):
        client = APIClient()
        client.force_authenticate(user=actor)
        return client.patch(
            reverse("pos-user-detail", args=[target.pk]), body, format="json"
        )

    def test_manager_grants_extra_permission_flows_through(self):
        response = self._patch(
            self.manager,
            self.cashier,
            {"extra_permissions": ["inventory.apply_stockcount"]},
        )
        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertIn("inventory.apply_stockcount", response.data["extra_permissions"])
        self.assertIn(
            "inventory.apply_stockcount", response.data["effective_permissions"]
        )
        self.cashier.refresh_from_db()
        # Direct grant merges into effective permissions used by capabilities.
        self.assertIn(
            "inventory.apply_stockcount", self.cashier.get_all_permissions()
        )

    def test_extra_permission_must_be_in_catalog(self):
        # sales.delete_order exists but is intentionally not grantable per-user.
        response = self._patch(
            self.manager, self.cashier, {"extra_permissions": ["sales.delete_order"]}
        )
        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)

    def test_no_privilege_escalation_beyond_actor_permissions(self):
        from django.contrib.auth.models import Permission

        delegate = get_user_model().objects.create_user(
            username="delegate", password="pass"
        )
        delegate.user_permissions.add(
            Permission.objects.get(content_type__app_label="auth", codename="view_user"),
            Permission.objects.get(
                content_type__app_label="auth", codename="change_user"
            ),
        )
        # Delegate may manage users but does not hold apply_stockcount, so they
        # cannot grant it to anyone (including themselves).
        response = self._patch(
            delegate, self.cashier, {"extra_permissions": ["inventory.apply_stockcount"]}
        )
        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertNotIn(
            "inventory.apply_stockcount", self.cashier.get_all_permissions()
        )

    def test_role_change_reconciles_redundant_extras(self):
        # Grant two extras to a cashier: one the accountant role covers, one it
        # does not.
        self._patch(
            self.manager,
            self.cashier,
            {
                "extra_permissions": [
                    "payments.view_payment",  # accountant role includes this
                    "inventory.apply_stockcount",  # accountant role does not
                ]
            },
        )
        response = self._patch(
            self.manager, self.cashier, {"role": ACCOUNTANT_GROUP}
        )
        self.assertEqual(response.status_code, status.HTTP_200_OK)
        extras = response.data["extra_permissions"]
        self.assertNotIn("payments.view_payment", extras)  # now redundant
        self.assertIn("inventory.apply_stockcount", extras)  # still extra

    def test_promotion_to_manager_clears_extras(self):
        self._patch(
            self.manager,
            self.cashier,
            {"extra_permissions": ["inventory.apply_stockcount"]},
        )
        response = self._patch(self.manager, self.cashier, {"role": MANAGER_GROUP})
        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(response.data["extra_permissions"], [])

    def test_create_user_with_extras_creates_employee_and_grants(self):
        from apps.employees.models import Employee

        client = APIClient()
        client.force_authenticate(user=self.manager)
        response = client.post(
            reverse("pos-user-list"),
            {
                "username": "power-cashier",
                "first_name": "نور",
                "password": "new-secret-pass",
                "role": CASHIER_GROUP,
                "extra_permissions": ["inventory.apply_stockcount"],
            },
            format="json",
        )
        self.assertEqual(response.status_code, status.HTTP_201_CREATED)
        user = get_user_model().objects.get(username="power-cashier")
        self.assertTrue(Employee.objects.filter(user=user).exists())
        self.assertIn("inventory.apply_stockcount", user.get_all_permissions())

    def test_user_list_serialization_query_count_is_constant(self):
        # Serialize the prefetched queryset directly so the count is not polluted
        # by the per-request ensure_role_groups() bootstrap in the viewset; this
        # isolates the serializer's N+1 behaviour, which the prefetch must flatten.
        from django.db import connection
        from django.test.utils import CaptureQueriesContext

        from apps.core.serializers import PosUserSerializer

        User = get_user_model()

        class _ListView:
            action = "list"

        def serialize_query_count():
            queryset = User.objects.order_by("username").prefetch_related(
                "groups", "user_permissions__content_type"
            )
            with CaptureQueriesContext(connection) as ctx:
                # Touch .data to force full evaluation + prefetch.
                _ = PosUserSerializer(
                    queryset, many=True, context={"view": _ListView()}
                ).data
            return len(ctx.captured_queries)

        from django.contrib.auth.models import Permission

        apply_stockcount = Permission.objects.get(
            content_type__app_label="inventory", codename="apply_stockcount"
        )

        def add_users(prefix, count):
            for index in range(count):
                user = User.objects.create_user(
                    username=f"{prefix}{index}", password="pass"
                )
                user.groups.add(Group.objects.get(name=CASHIER_GROUP))
                # Give everyone an extra grant so the content_type prefetch fires
                # in both measurements (it is skipped entirely when no user has
                # any direct permission).
                user.user_permissions.add(apply_stockcount)

        add_users("batch-a-", 3)
        first = serialize_query_count()
        add_users("batch-b-", 3)
        second = serialize_query_count()

        # No N+1: doubling the user set must not change the query count.
        self.assertEqual(first, second)
        self.assertLessEqual(second, 4)


class SupervisorVisibilityTests(TestCase):
    def setUp(self):
        ensure_role_groups()
        User = get_user_model()
        self.supervisor = User.objects.create_user(username="sup", password="pass")
        self.supervisor.groups.add(Group.objects.get(name=SUPERVISOR_GROUP))
        self.cashier = User.objects.create_user(username="till", password="pass")
        self.cashier.groups.add(Group.objects.get(name=CASHIER_GROUP))
        self.other_cashier = User.objects.create_user(username="till2", password="pass")
        self.other_cashier.groups.add(Group.objects.get(name=CASHIER_GROUP))
        # An order owned by `cashier`'s register session.
        session = RegisterSession.objects.create(
            owner=self.cashier,
            owner_key=f"user:{self.cashier.pk}",
            status=RegisterSession.Status.OPEN,
            opening_cash=Decimal("0.00"),
        )
        self.order = Order.objects.create(
            register_session=session,
            status=Order.Status.PAID,
            subtotal=Decimal("10.00"),
            total=Decimal("10.00"),
        )

    def _order_ids(self, user):
        client = APIClient()
        client.force_authenticate(user=user)
        response = client.get(reverse("order-list"))
        self.assertEqual(response.status_code, status.HTTP_200_OK)
        results = response.data.get("results", response.data)
        return {row["id"] for row in results}

    def test_supervisor_sees_all_sessions_other_cashier_does_not(self):
        self.assertIn(self.order.id, self._order_ids(self.supervisor))
        self.assertNotIn(self.order.id, self._order_ids(self.other_cashier))
