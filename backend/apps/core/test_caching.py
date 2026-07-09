"""Tests for the ShopSettings singleton cache and the per-user permission cache.

The caches are globally disabled under the test runner (their TTLs are forced to
0 — see ``TESTING`` in settings), so every test here opts back in explicitly
with ``override_settings`` and an isolated LocMem cache.
"""

from unittest import mock

from django.contrib.auth.models import Group, Permission, User
from django.core.cache import cache
from django.test import TestCase, override_settings

from apps.core import caching
from apps.core.models import ShopSettings
from apps.core.roles import CASHIER_GROUP

CACHED = override_settings(
    CACHES={
        "default": {
            "BACKEND": "django.core.cache.backends.locmem.LocMemCache",
            "LOCATION": "core-caching-tests",
        },
    },
    POINTY_SHOP_SETTINGS_CACHE_TTL=60,
    POINTY_PERMISSION_CACHE_TTL=300,
)


@CACHED
class ShopSettingsCacheTests(TestCase):
    def setUp(self):
        cache.clear()

    def test_load_is_served_from_cache_after_first_read(self):
        ShopSettings.load()  # warm (may also create the row)
        with self.assertNumQueries(0):
            settings = ShopSettings.load()
        self.assertEqual(settings.pk, 1)

    def test_cached_instances_are_independent_copies(self):
        ShopSettings.load()
        first = ShopSettings.load()
        first.shop_name = "mutated but never saved"
        self.assertNotEqual(ShopSettings.load().shop_name, "mutated but never saved")

    def test_save_invalidates(self):
        settings = ShopSettings.load()
        ShopSettings.load()  # cached
        settings.shop_name = "الاسم الجديد"
        settings.save()
        self.assertEqual(ShopSettings.load().shop_name, "الاسم الجديد")

    def test_queryset_update_invalidates(self):
        settings = ShopSettings.load()
        self.assertTrue(settings.prevent_selling_at_loss)
        ShopSettings.load()  # cached
        ShopSettings.objects.filter(pk=1).update(prevent_selling_at_loss=False)
        self.assertFalse(ShopSettings.load().prevent_selling_at_loss)

    def test_fails_open_when_redis_is_down(self):
        boom = mock.Mock(side_effect=ConnectionError("redis down"))
        with mock.patch.object(caching.cache, "get", boom), mock.patch.object(
            caching.cache, "set", boom
        ):
            settings = ShopSettings.load()
        self.assertEqual(settings.pk, 1)


@CACHED
class PermissionCacheTests(TestCase):
    def setUp(self):
        cache.clear()
        self.user = User.objects.create_user(username="cashier", password="x")
        self.user.groups.add(Group.objects.get(name=CASHIER_GROUP))

    def _fresh_user(self):
        # A new instance, so ModelBackend's per-instance memo can't mask the
        # Redis layer.
        return User.objects.get(pk=self.user.pk)

    def test_permission_checks_hit_zero_queries_once_warm(self):
        self.assertTrue(self.user.has_perm("sales.add_order"))  # warm
        fresh = self._fresh_user()
        with self.assertNumQueries(0):
            self.assertTrue(fresh.has_perm("sales.add_order"))
            self.assertFalse(fresh.has_perm("employees.view_payrollrun"))

    def test_direct_grant_is_visible_immediately(self):
        self.assertFalse(self.user.has_perm("purchasing.view_purchaseorder"))  # warm
        permission = Permission.objects.get(
            codename="view_purchaseorder", content_type__app_label="purchasing"
        )
        self.user.user_permissions.add(permission)  # m2m signal bumps version
        self.assertTrue(self._fresh_user().has_perm("purchasing.view_purchaseorder"))

    def test_role_change_is_visible_immediately(self):
        self.assertTrue(self.user.has_perm("sales.add_order"))  # warm
        self.user.groups.clear()  # m2m signal bumps version
        self.assertFalse(self._fresh_user().has_perm("sales.add_order"))

    def test_group_permission_edit_is_visible_immediately(self):
        self.assertTrue(self.user.has_perm("sales.add_order"))  # warm
        group = Group.objects.get(name=CASHIER_GROUP)
        permission = Permission.objects.get(
            codename="add_order", content_type__app_label="sales"
        )
        group.permissions.remove(permission)  # m2m signal bumps version
        self.assertFalse(self._fresh_user().has_perm("sales.add_order"))

    def test_superuser_flip_is_visible_immediately(self):
        self.assertFalse(self.user.has_perm("employees.view_payrollrun"))  # warm
        self.user.is_superuser = True
        self.user.save()  # post_save bumps version
        self.assertTrue(self._fresh_user().has_perm("employees.view_payrollrun"))

    def test_login_last_login_write_does_not_bump_version(self):
        self.assertTrue(self.user.has_perm("sales.add_order"))  # warm
        before = caching.perm_version()
        self.user.save(update_fields=["last_login"])
        self.assertEqual(caching.perm_version(), before)

    def test_fails_open_when_redis_is_down(self):
        boom = mock.Mock(side_effect=ConnectionError("redis down"))
        with mock.patch.object(caching.cache, "get", boom), mock.patch.object(
            caching.cache, "set", boom
        ):
            self.assertTrue(self._fresh_user().has_perm("sales.add_order"))
