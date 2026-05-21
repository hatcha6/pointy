from decimal import Decimal

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group
from django.core.management import call_command
from django.test import TestCase
from django.urls import reverse
from django.utils import timezone
from rest_framework import status
from rest_framework.test import APIClient

from apps.catalog.models import Product, ProductVariant
from apps.inventory.models import StockItem, StockMovement
from apps.payments.models import Payment
from apps.purchasing.models import PurchaseOrder, Supplier, SupplierPayment
from apps.sales.models import Order, OrderLine, RegisterSession
from .roles import CASHIER_GROUP, MANAGER_GROUP, bootstrap_admin_user, ensure_role_groups


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
                "require_opening_cash": False,
                "auto_print_receipts": True,
                "low_stock_threshold": 12,
                "cashier_return_window_hours": 42,
                "enable_cash_payments": True,
                "enable_card_payments": False,
                "enable_transfer_payments": True,
                "card_commission_percent": "1.50",
                "transfer_commission_percent": "0.25",
            },
            format="json",
        )

        self.assertEqual(read_response.status_code, status.HTTP_200_OK)
        self.assertEqual(update_response.status_code, status.HTTP_200_OK)
        self.assertEqual(update_response.data["shop_name"], "متجر الوردية")
        self.assertFalse(update_response.data["require_opening_cash"])
        self.assertTrue(update_response.data["auto_print_receipts"])
        self.assertEqual(update_response.data["low_stock_threshold"], 12)
        self.assertEqual(update_response.data["cashier_return_window_hours"], 42)
        self.assertTrue(update_response.data["enable_cash_payments"])
        self.assertFalse(update_response.data["enable_card_payments"])
        self.assertTrue(update_response.data["enable_transfer_payments"])
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

    def test_cashier_can_read_but_not_update_shop_settings(self):
        client = APIClient()
        client.force_authenticate(user=self.cashier)

        read_response = client.get(reverse("shop-settings"))
        update_response = client.patch(
            reverse("shop-settings"),
            {"shop_name": "غير مسموح"},
            format="json",
        )

        self.assertEqual(read_response.status_code, status.HTTP_200_OK)
        self.assertIn("auto_print_receipts", read_response.data)
        self.assertEqual(update_response.status_code, status.HTTP_403_FORBIDDEN)


class DashboardApiTests(TestCase):
    def setUp(self):
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

        self.product = Product.objects.create(
            sku="DASH-COF",
            name="قهوة لوحة التحكم",
            unit_price=Decimal("5.00"),
        )
        self.stock_item = StockItem.objects.create(
            product=self.product,
            quantity_on_hand=2,
            reorder_level=3,
        )
        StockMovement.objects.create(
            product=self.product,
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

    def test_dashboard_scopes_cashier_sales_and_sections(self):
        client = APIClient()
        client.force_authenticate(user=self.cashier)

        response = client.get(reverse("dashboard"))

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertIn("sales", response.data["sections"])
        self.assertIn("payments", response.data["sections"])
        self.assertIn("printing", response.data["sections"])
        self.assertNotIn("inventory", response.data["sections"])
        self.assertNotIn("purchasing", response.data["sections"])
        self.assertEqual(response.data["sections"]["sales"]["summary"]["net_sales"], "10.00")
        self.assertEqual(response.data["sections"]["payments"]["summary"]["total"], "10.00")

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

    def test_bootstrap_admin_creates_superuser_once_when_no_users_exist(self):
        admin = bootstrap_admin_user(
            username="admin",
            email="admin@example.com",
            password="first-pass",
        )
        skipped = bootstrap_admin_user(
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

    def test_bootstrap_admin_without_password_generates_password(self):
        admin = bootstrap_admin_user(username="admin")

        self.assertIsNotNone(admin)
        generated_password = getattr(admin, "_pointy_bootstrap_password")
        self.assertTrue(admin.has_usable_password())
        self.assertTrue(admin.check_password(generated_password))

    def test_bootstrap_admin_can_be_disabled(self):
        admin = bootstrap_admin_user(username="admin", enabled=False)

        self.assertIsNone(admin)
        self.assertFalse(get_user_model().objects.exists())

    def test_bootstrap_admin_repairs_single_unusable_bootstrap_admin_once(self):
        existing_admin = get_user_model().objects.create_superuser(
            username="admin",
            password=None,
        )
        existing_admin.set_unusable_password()
        existing_admin.save(update_fields=["password"])

        repaired_admin = bootstrap_admin_user(username="admin", password="repair-pass")
        skipped = bootstrap_admin_user(username="admin", password="second-pass")

        self.assertEqual(repaired_admin.pk, existing_admin.pk)
        self.assertTrue(getattr(repaired_admin, "_pointy_bootstrap_repaired"))
        repaired_admin.refresh_from_db()
        self.assertTrue(repaired_admin.check_password("repair-pass"))
        self.assertIsNone(skipped)
        self.assertFalse(repaired_admin.check_password("second-pass"))

    def test_bootstrap_management_command_creates_admin(self):
        call_command("bootstrap_admin", username="admin", password="admin-pass")

        admin = get_user_model().objects.get(username="admin")
        self.assertTrue(admin.is_superuser)
        self.assertTrue(admin.groups.filter(name=MANAGER_GROUP).exists())
