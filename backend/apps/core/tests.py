from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group
from django.core.management import call_command
from django.test import TestCase
from django.urls import reverse
from rest_framework import status
from rest_framework.test import APIClient

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


class RolePermissionBootstrapTests(TestCase):
    def test_role_groups_receive_domain_permissions(self):
        ensure_role_groups()
        User = get_user_model()
        manager = User.objects.create_user(username="manager-perms", password="pass")
        cashier = User.objects.create_user(username="cashier-perms", password="pass")
        manager.groups.add(Group.objects.get(name=MANAGER_GROUP))
        cashier.groups.add(Group.objects.get(name=CASHIER_GROUP))

        self.assertTrue(manager.has_perm("catalog.add_product"))
        self.assertTrue(manager.has_perm("inventory.change_stockitem"))
        self.assertTrue(manager.has_perm("sales.delete_order"))
        self.assertTrue(manager.has_perm("payments.change_payment"))
        self.assertTrue(manager.has_perm("auth.view_user"))

        self.assertTrue(cashier.has_perm("catalog.view_product"))
        self.assertTrue(cashier.has_perm("sales.add_order"))
        self.assertTrue(cashier.has_perm("sales.change_registersession"))
        self.assertTrue(cashier.has_perm("payments.add_payment"))
        self.assertFalse(cashier.has_perm("catalog.add_product"))
        self.assertFalse(cashier.has_perm("inventory.view_stockitem"))
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
