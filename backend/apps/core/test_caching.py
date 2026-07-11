"""Tests for the ShopSettings singleton cache, the auth User-row cache, and the
per-user permission cache.

The caches are globally disabled under the test runner (their TTLs are forced to
0 — see ``TESTING`` in settings), so every test here opts back in explicitly
with ``override_settings`` and an isolated LocMem cache.
"""

from unittest import mock

from django.contrib.auth.models import Group, Permission, User
from django.core.cache import cache
from django.test import TestCase, override_settings

from apps.core import caching
from apps.core.auth_backends import CachedPermissionsBackend
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
    POINTY_USER_CACHE_TTL=60,
    POINTY_RELAY_INSTALLATION_CACHE_TTL=60,
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


@CACHED
class AuthenticatedCeilingThrottleTests(TestCase):
    """The wide per-user ceiling: bounds a runaway client, invisible otherwise."""

    def setUp(self):
        cache.clear()

    def _throttle(self, rate="2/min"):
        from apps.core.throttling import AuthenticatedBurstCeilingThrottle

        throttle = AuthenticatedBurstCeilingThrottle()
        throttle.rate = rate
        throttle.num_requests, throttle.duration = throttle.parse_rate(rate)
        return throttle

    def test_runaway_authenticated_client_is_bounded(self):
        from django.test import RequestFactory

        user = User.objects.create_user(username="till", password="x")
        request = RequestFactory().get("/api/products/")
        request.user = user
        throttle = self._throttle(rate="2/min")
        self.assertTrue(throttle.allow_request(request, None))
        self.assertTrue(throttle.allow_request(request, None))
        self.assertFalse(throttle.allow_request(request, None))

    def test_anonymous_requests_pass_through(self):
        from django.contrib.auth.models import AnonymousUser
        from django.test import RequestFactory

        request = RequestFactory().get("/api/price-check/")
        request.user = AnonymousUser()
        throttle = self._throttle(rate="1/min")
        for _ in range(5):
            self.assertTrue(throttle.allow_request(request, None))

    def test_fails_open_when_redis_is_down(self):
        from django.test import RequestFactory

        user = User.objects.create_user(username="till2", password="x")
        request = RequestFactory().get("/api/products/")
        request.user = user
        throttle = self._throttle(rate="1/min")
        throttle.cache = mock.Mock()
        throttle.cache.get.side_effect = ConnectionError("redis down")
        # Even the throttle bookkeeping failing must not reject requests.
        self.assertTrue(throttle.allow_request(request, None))
    def setUp(self):
        cache.clear()

    def test_hit_skips_compute(self):
        calls = []
        caching.get_or_compute_single_flight("sf:key", lambda: calls.append(1) or "v", 60)
        value = caching.get_or_compute_single_flight(
            "sf:key", lambda: calls.append(1) or "v", 60
        )
        self.assertEqual(value, "v")
        self.assertEqual(len(calls), 1)

    def test_winner_releases_the_lock(self):
        caching.get_or_compute_single_flight("sf:key", lambda: "v", 60)
        self.assertIsNone(cache.get("sf:key:lock"))

    def test_loser_polls_for_the_winners_result(self):
        # A concurrent winner holds the lock; its value lands while the loser
        # is polling — the loser must serve it without computing.
        cache.add("sf:key:lock", 1, 5)
        reads = iter([None, "winner"])  # initial miss, then the winner's value

        def compute():
            raise AssertionError("loser must serve the winner's value")

        with mock.patch.object(
            caching,
            "_safe_get",
            side_effect=lambda key, default=None: next(reads, "winner"),
        ):
            value = caching.get_or_compute_single_flight(
                "sf:key", compute, 60, wait_ms=1, max_waits=3
            )
        self.assertEqual(value, "winner")

    def test_loser_computes_anyway_when_the_winner_stalls(self):
        cache.add("sf:key:lock", 1, 5)  # a winner that never finishes
        value = caching.get_or_compute_single_flight(
            "sf:key", lambda: "computed", 60, wait_ms=1, max_waits=2
        )
        self.assertEqual(value, "computed")
        # The stalled winner's lock is not ours to release.
        self.assertIsNotNone(cache.get("sf:key:lock"))

    def test_zero_ttl_bypasses_caching(self):
        calls = []
        for _ in range(2):
            caching.get_or_compute_single_flight(
                "sf:key", lambda: calls.append(1) or "v", 0
            )
        self.assertEqual(len(calls), 2)


@CACHED
class RelayInstallationCacheTests(TestCase):
    def setUp(self):
        cache.clear()

    def _create(self):
        from apps.core.models import RelayInstallation

        return RelayInstallation.objects.create(
            installation_id="inst-1",
            relay_public_api_url="https://relay.example.com",
            connector_token="c",
            access_token="a",
        )

    def test_load_is_served_from_cache_after_first_read(self):
        from apps.core.models import RelayInstallation

        self._create()
        RelayInstallation.load()  # warm
        with self.assertNumQueries(0):
            installation = RelayInstallation.load()
        self.assertEqual(installation.installation_id, "inst-1")

    def test_absence_is_cached_too(self):
        from apps.core.models import RelayInstallation

        self.assertIsNone(RelayInstallation.load())  # warm the sentinel
        with self.assertNumQueries(0):
            self.assertIsNone(RelayInstallation.load())

    def test_save_invalidates(self):
        from apps.core.models import RelayInstallation

        installation = self._create()
        RelayInstallation.load()  # cached
        installation.ai_enabled = True
        installation.save()
        self.assertTrue(RelayInstallation.load().ai_enabled)

    def test_enrollment_after_cached_absence_is_visible_immediately(self):
        from apps.core.models import RelayInstallation

        self.assertIsNone(RelayInstallation.load())  # sentinel cached
        self._create()  # post_save invalidates the sentinel
        self.assertIsNotNone(RelayInstallation.load())

    def test_fails_open_when_redis_is_down(self):
        from apps.core.models import RelayInstallation

        self._create()
        boom = mock.Mock(side_effect=ConnectionError("redis down"))
        with mock.patch.object(caching.cache, "get", boom), mock.patch.object(
            caching.cache, "set", boom
        ):
            self.assertIsNotNone(RelayInstallation.load())


@CACHED
class UserRowCacheTests(TestCase):
    def setUp(self):
        cache.clear()
        self.user = User.objects.create_user(
            username="cashier", password="x", first_name="Amal"
        )
        self.backend = CachedPermissionsBackend()

    def test_get_user_is_served_from_cache_after_first_read(self):
        self.backend.get_user(self.user.pk)  # warm
        with self.assertNumQueries(0):
            user = self.backend.get_user(self.user.pk)
        self.assertEqual(user.pk, self.user.pk)
        self.assertEqual(user.first_name, "Amal")

    def test_user_save_invalidates(self):
        self.backend.get_user(self.user.pk)  # warm
        self.user.first_name = "Basma"
        self.user.save()
        self.assertEqual(self.backend.get_user(self.user.pk).first_name, "Basma")

    def test_last_login_only_save_still_invalidates_the_row(self):
        from django.utils import timezone

        self.backend.get_user(self.user.pk)  # warm (last_login is None)
        self.user.last_login = timezone.now()
        self.user.save(update_fields=["last_login"])
        self.assertIsNotNone(self.backend.get_user(self.user.pk).last_login)

    def test_deactivation_takes_effect_immediately(self):
        self.backend.get_user(self.user.pk)  # warm
        self.user.is_active = False
        self.user.save()  # post_save invalidates the cached row
        self.assertIsNone(self.backend.get_user(self.user.pk))

    def test_stale_inactive_copy_is_refused_on_hit(self):
        # Even if an inactive row somehow survives in the cache (e.g. a raw-SQL
        # deactivation inside the TTL), the hit path re-checks
        # user_can_authenticate and refuses it.
        self.user.is_active = False
        caching.set_cached_user(self.user)
        self.assertIsNone(self.backend.get_user(self.user.pk))

    def test_delete_invalidates(self):
        self.backend.get_user(self.user.pk)  # warm
        user_id = self.user.pk
        self.user.delete()
        self.assertIsNone(self.backend.get_user(user_id))

    def test_fails_open_when_redis_is_down(self):
        boom = mock.Mock(side_effect=ConnectionError("redis down"))
        with mock.patch.object(caching.cache, "get", boom), mock.patch.object(
            caching.cache, "set", boom
        ):
            user = self.backend.get_user(self.user.pk)
        self.assertEqual(user.pk, self.user.pk)
