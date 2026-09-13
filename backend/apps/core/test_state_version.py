"""Tests for the state-version registry, its header, and the poll endpoint.

The feature is globally disabled under the test runner (test rollbacks do not
fire signals, so a version bumped in one test would leak into the next), so
every test here opts back in with ``override_settings`` and a LocMem cache.
"""

from decimal import Decimal
from unittest import mock

from django.contrib.auth.models import Group, User
from django.core.cache import cache
from django.core.cache.backends.base import BaseCache
from django.db import transaction
from django.test import TestCase, override_settings
from django.utils import timezone
from django.urls import reverse

from apps.catalog.models import Product, ProductCategory, ProductVariant
from apps.core import state_version
from apps.core.models import ShopSettings
from apps.core.roles import CASHIER_GROUP, MANAGER_GROUP
from apps.core.state_middleware import DISCOUNTS_VERSION_HEADER
from apps.catalog.cache import CATALOG_VERSION_HEADER
from apps.inventory.models import StockItem

STATE_ON = override_settings(
    CACHES={
        "default": {
            "BACKEND": "django.core.cache.backends.locmem.LocMemCache",
            "LOCATION": "state-version-tests",
        },
    },
    POINTY_STATE_VERSION_ENABLED=True,
)


class _ExplodingCache(BaseCache):
    """Every operation raises — the only way to actually exercise fail-open."""

    def __init__(self, *args, **kwargs):
        super().__init__({})

    def _boom(self, *args, **kwargs):
        raise RuntimeError("redis is down")

    get = set = add = delete = incr = decr = get_many = set_many = _boom


EXPLODING = override_settings(
    CACHES={"default": {"BACKEND": "apps.core.test_state_version._ExplodingCache"}},
    POINTY_STATE_VERSION_ENABLED=True,
)



class CommitsMixin:
    """Bumps live in ``transaction.on_commit`` hooks (deliberately — see
    ``state_version.bump``). Django's TestCase wraps each test in a transaction
    that never commits, so without this every hook would sit unrun and every
    assertion here would read a counter that never moved."""

    def commit(self):
        return self.captureOnCommitCallbacks(execute=True)


@STATE_ON
class RegistryTests(CommitsMixin, TestCase):
    def setUp(self):
        cache.clear()

    def test_every_domain_name_is_unique(self):
        names = [domain.name for domain in state_version.DOMAINS]
        self.assertEqual(len(names), len(set(names)))

    def test_every_domain_has_its_own_redis_key(self):
        # versions() reads the whole vector with one MGET keyed by redis key;
        # two domains sharing one would silently collapse into a single entry.
        keys = [domain.redis_key(1) for domain in state_version.DOMAINS]
        self.assertEqual(len(keys), len(set(keys)))

    def test_the_poll_reads_redis_once_per_request(self):
        # Every till asks every few seconds. The view stashes its vector for
        # the header middleware rather than both of them fetching it.
        user = User.objects.create_user(username="عدّاد", password="1234")
        user.groups.add(Group.objects.get(name=CASHIER_GROUP))
        self.client.force_login(user)
        from apps.core import state_middleware

        with mock.patch.object(
            state_middleware, "versions", wraps=state_version.versions
        ) as spy:
            response = self.client.get(reverse("state"))
        self.assertEqual(spy.call_count, 0, "the middleware re-read the vector")
        self.assertIn(
            state_version.REQUEST_CACHE_ATTR, response.wsgi_request.__dict__
        )

    def test_versions_lists_every_global_domain(self):
        current = state_version.versions()
        self.assertEqual(
            set(current),
            {domain.name for domain in state_version.GLOBAL_DOMAINS},
        )

    def test_unwritten_counters_read_as_zero_not_as_gaps(self):
        # A missing key must look like a stable value, not like a change: a gap
        # would make every client re-fetch on the first response after a flush.
        self.assertEqual(state_version.versions()["settings"], "0")

    def test_versions_are_strings(self):
        with self.commit():
            state_version.bump("settings")
        self.assertIsInstance(state_version.versions()["settings"], str)

    def test_bump_advances_only_its_own_domain(self):
        before = state_version.versions()
        with self.commit():
            state_version.bump("settings")
        after = state_version.versions()
        changed = {name for name in after if after[name] != before[name]}
        self.assertEqual(changed, {"settings"})

    def test_a_bump_is_invisible_until_its_transaction_commits(self):
        """The window that would otherwise poison a client permanently.

        If the counter moved while the write was still uncommitted, a client
        polling in that instant would re-read the OLD row, store it under the
        NEW number, and never refresh again — the number it holds is already
        current. Deferring to commit closes it.
        """
        before = state_version.versions()["settings"]
        with self.captureOnCommitCallbacks(execute=True):
            with transaction.atomic():
                state_version.bump("settings")
                self.assertEqual(state_version.versions()["settings"], before)
            self.assertEqual(
                state_version.versions()["settings"],
                before,
                "a nested block exiting is a savepoint release, not a commit",
            )
        self.assertNotEqual(state_version.versions()["settings"], before)

    def test_bump_is_monotonic(self):
        with self.commit():
            state_version.bump("settings")
        first = state_version.versions()["settings"]
        with self.commit():
            state_version.bump("settings")
        self.assertNotEqual(state_version.versions()["settings"], first)

    def test_externally_owned_domains_cannot_be_bumped_here(self):
        # One integer per fact: the catalog counter is owned by apps.catalog,
        # and a second writer would let the two drift.
        with self.assertRaises(RuntimeError):
            state_version.bump("catalog")

    def test_unknown_domain_is_a_loud_error(self):
        with self.assertRaises(LookupError):
            state_version.bump("no-such-domain")

    def test_disabled_reads_empty_and_writes_nothing(self):
        with override_settings(POINTY_STATE_VERSION_ENABLED=False):
            with self.commit():
                state_version.bump("settings")
            self.assertEqual(state_version.versions(), {})

    def test_header_value_is_stable_and_parseable(self):
        value = state_version.header_value({"b": "2", "a": "1"})
        self.assertEqual(value, "a=1,b=2")

    def test_fingerprint_changes_with_any_counter(self):
        base = {"a": "1", "b": "1"}
        self.assertNotEqual(
            state_version.fingerprint(base),
            state_version.fingerprint({"a": "1", "b": "2"}),
        )


@STATE_ON
class SignalWiringTests(CommitsMixin, TestCase):
    def setUp(self):
        cache.clear()

    def _version(self, name):
        return state_version.versions()[name]

    def test_shop_settings_save_bumps_settings(self):
        before = self._version("settings")
        settings_row = ShopSettings.load()
        settings_row.shop_name = "دفتر"
        with self.commit():
            settings_row.save()
        self.assertNotEqual(self._version("settings"), before)

    def test_shop_settings_queryset_update_bumps_settings(self):
        # .filter(pk=1).update() skips post_save; the queryset override is what
        # catches it for the cache, and the same path must move the version or
        # tills would never hear about a settings write made this way.
        ShopSettings.load()
        before = self._version("settings")
        with self.commit():
            ShopSettings.objects.filter(pk=1).update(shop_name="آخر")
        self.assertNotEqual(self._version("settings"), before)

    def test_product_save_bumps_catalog_defs_not_stock(self):
        before = state_version.versions()
        with self.commit():
            Product.objects.create(name="شاي")
        after = state_version.versions()
        self.assertNotEqual(after["catalog_defs"], before["catalog_defs"])
        self.assertEqual(after["stock"], before["stock"])

    def test_variant_price_change_bumps_catalog_defs(self):
        # The case the whole feature exists for: a till must never quote a
        # price the back office changed a minute ago.
        product = Product.objects.create(name="قهوة")
        variant = ProductVariant.objects.create(
            product=product, sku="COFFEE-1", unit_price=Decimal("10.00")
        )
        before = self._version("catalog_defs")
        variant.unit_price = Decimal("12.00")
        with self.commit():
            variant.save()
        self.assertNotEqual(self._version("catalog_defs"), before)

    def test_variant_rename_bumps_catalog_defs(self):
        product = Product.objects.create(name="حليب")
        variant = ProductVariant.objects.create(
            product=product, sku="MILK-1", unit_price=Decimal("2.00")
        )
        before = self._version("catalog_defs")
        variant.name = "حليب كامل الدسم"
        with self.commit():
            variant.save()
        self.assertNotEqual(self._version("catalog_defs"), before)

    def test_stock_write_bumps_stock_not_catalog_defs(self):
        # Sales move stock constantly. Keeping that out of catalog_defs is what
        # lets a client refresh the screen on a price edit without churning on
        # every other till's checkouts.
        product = Product.objects.create(name="سكر")
        variant = ProductVariant.objects.create(
            product=product, sku="SUGAR-1", unit_price=Decimal("1.00")
        )
        before = state_version.versions()
        with self.commit():
            StockItem.objects.create(
                variant=variant, quantity_on_hand=Decimal("5")
            )
        after = state_version.versions()
        self.assertNotEqual(after["stock"], before["stock"])
        self.assertEqual(after["catalog_defs"], before["catalog_defs"])

    def test_categorisation_m2m_bumps_catalog_defs(self):
        product = Product.objects.create(name="أرز")
        category = ProductCategory.objects.create(name="مواد غذائية")
        before = self._version("catalog_defs")
        with self.commit():
            product.categories.add(category)
        self.assertNotEqual(self._version("catalog_defs"), before)

    def test_user_save_bumps_users(self):
        before = self._version("users")
        with self.commit():
            User.objects.create_user(username="سالم", password="1234")
        self.assertNotEqual(self._version("users"), before)

    def test_a_login_timestamp_is_not_a_change(self):
        # Django writes last_login on every session start. Treating that as
        # news would have every device in the shop re-reading the roster each
        # time anybody signs in.
        user = User.objects.create_user(username="سعاد", password="1234")
        before = self._version("users")
        user.last_login = timezone.now()
        with self.commit():
            user.save(update_fields=["last_login"])
        self.assertEqual(self._version("users"), before)

    def test_declared_models_all_resolve(self):
        # A typo in a label would otherwise only surface at app start.
        for domain in state_version.DOMAINS:
            if domain.external:
                continue
            self.assertEqual(
                len(state_version.resolve_models(domain.name)), len(domain.models)
            )


@STATE_ON
class CatalogVersionCompositeTests(CommitsMixin, TestCase):
    """The catalog counter must keep covering everything it covered before the
    definitions/quantities split, or server-side ETags and the price-checker
    cache would start serving stale rows."""

    def setUp(self):
        cache.clear()

    def test_catalog_senders_are_exactly_defs_plus_stock_plus_scale_rules(self):
        from apps.catalog.models import ScaleBarcodeRule
        from apps.catalog.signals import _SENDERS

        expected = {
            *state_version.resolve_models("catalog_defs"),
            *state_version.resolve_models("stock"),
            ScaleBarcodeRule,
        }
        self.assertEqual(set(_SENDERS), expected)

    @override_settings(POINTY_CATALOG_CACHE_ENABLED=True)
    def test_stock_write_still_advances_the_catalog_counter(self):
        from apps.catalog.cache import catalog_version

        product = Product.objects.create(name="ملح")
        variant = ProductVariant.objects.create(
            product=product, sku="SALT-1", unit_price=Decimal("1.00")
        )
        before = catalog_version()
        with self.commit():
            StockItem.objects.create(
                variant=variant, quantity_on_hand=Decimal("3")
            )
        self.assertNotEqual(catalog_version(), before)


@STATE_ON
class HeaderTests(CommitsMixin, TestCase):
    def setUp(self):
        cache.clear()
        self.user = User.objects.create_user(username="مدير", password="1234")
        self.user.groups.add(Group.objects.get(name=MANAGER_GROUP))
        self.client.force_login(self.user)

    def test_api_responses_carry_the_vector(self):
        response = self.client.get(reverse("shop-settings"))
        self.assertIn(state_version.STATE_HEADER, response)
        self.assertIn("settings=", response[state_version.STATE_HEADER])

    @override_settings(POINTY_CATALOG_CACHE_ENABLED=True)
    def test_legacy_single_value_headers_are_still_stamped(self):
        # Older clients and the frozen compat branch know only these. They
        # follow the catalog cache's own switch, not this feature's, so
        # turning state versions off leaves that push exactly as it was.
        response = self.client.get(reverse("shop-settings"))
        self.assertIn(CATALOG_VERSION_HEADER, response)
        self.assertIn(DISCOUNTS_VERSION_HEADER, response)

    @override_settings(POINTY_CATALOG_CACHE_ENABLED=True)
    def test_state_off_still_pushes_the_legacy_catalog_version(self):
        with override_settings(POINTY_STATE_VERSION_ENABLED=False):
            response = self.client.get(reverse("shop-settings"))
        self.assertNotIn(state_version.STATE_HEADER, response)
        self.assertIn(CATALOG_VERSION_HEADER, response)

    @override_settings(POINTY_CATALOG_CACHE_ENABLED=False)
    def test_catalog_cache_off_leaves_only_the_vector(self):
        response = self.client.get(reverse("shop-settings"))
        self.assertIn(state_version.STATE_HEADER, response)
        self.assertNotIn(CATALOG_VERSION_HEADER, response)

    def test_non_api_paths_are_untouched(self):
        response = self.client.get("/healthz")
        self.assertNotIn(state_version.STATE_HEADER, response)

    def test_a_write_advances_the_vector_the_next_response_carries(self):
        first = self.client.get(reverse("shop-settings"))[state_version.STATE_HEADER]
        with self.commit():
            response = self.client.patch(
                reverse("shop-settings"),
                data={"shop_name": "دفتر"},
                content_type="application/json",
            )
        self.assertEqual(response.status_code, 200)
        second = self.client.get(reverse("shop-settings"))[state_version.STATE_HEADER]
        self.assertNotEqual(second, first)


@STATE_ON
@override_settings(POINTY_USER_CACHE_TTL=60, POINTY_PERMISSION_CACHE_TTL=300)
class StateEndpointTests(CommitsMixin, TestCase):
    def setUp(self):
        cache.clear()
        self.user = User.objects.create_user(username="كاشير", password="1234")
        self.user.groups.add(Group.objects.get(name=CASHIER_GROUP))
        self.url = reverse("state")

    def test_requires_authentication(self):
        response = self.client.get(self.url)
        self.assertIn(response.status_code, (401, 403))

    def test_returns_the_vector_and_the_poll_interval(self):
        self.client.force_login(self.user)
        response = self.client.get(self.url)
        self.assertEqual(response.status_code, 200)
        self.assertTrue(response.data["enabled"])
        self.assertIn("settings", response.data["versions"])
        self.assertGreater(response.data["poll_interval_seconds"], 0)

    def test_unchanged_vector_answers_304(self):
        self.client.force_login(self.user)
        first = self.client.get(self.url)
        second = self.client.get(self.url, HTTP_IF_NONE_MATCH=first["ETag"])
        self.assertEqual(second.status_code, 304)
        self.assertEqual(second.content, b"")

    def test_a_change_breaks_the_304(self):
        self.client.force_login(self.user)
        first = self.client.get(self.url)
        with self.commit():
            state_version.bump("settings")
        second = self.client.get(self.url, HTTP_IF_NONE_MATCH=first["ETag"])
        self.assertEqual(second.status_code, 200)

    def test_never_cached_by_anything_in_between(self):
        self.client.force_login(self.user)
        response = self.client.get(self.url)
        self.assertIn("no-store", response["Cache-Control"])

    def test_makes_no_database_queries(self):
        # The point of the poll is that it costs one Redis read: every till in
        # the shop asks every few seconds, so anything per-request that touches
        # the database here is multiplied by the whole floor.
        self.client.force_login(self.user)
        self.client.get(self.url)  # warm the session/user/permission caches
        with self.assertNumQueries(0):
            self.client.get(self.url)

    def test_successful_polls_are_not_written_to_telemetry(self):
        # A poll answers 200 whenever anything moved, which in a busy shop is
        # most of them — recording each one would make the freshness mechanism
        # the largest writer in the analytics table.
        from apps.analytics.models import AnalyticsEvent

        self.client.force_login(self.user)
        AnalyticsEvent.objects.all().delete()
        with self.commit():
            state_version.bump("settings")
        self.assertEqual(self.client.get(self.url).status_code, 200)
        self.assertFalse(
            AnalyticsEvent.objects.filter(request_path="/api/state/").exists()
        )


@STATE_ON
class PermissionIsolationTests(CommitsMixin, TestCase):
    """The vector is counters only, and per-user counters follow the caller.

    Revalidation cannot widen what anyone can see — a client that learns "the
    catalog changed" still has to fetch the catalog through its own
    permission-checked endpoint — so these guard the two things that could
    genuinely leak: another user's counter, and payload data riding along.
    """

    def setUp(self):
        cache.clear()
        self.cashier = User.objects.create_user(username="كاشير٢", password="1234")
        self.cashier.groups.add(Group.objects.get(name=CASHIER_GROUP))
        self.manager = User.objects.create_user(username="مدير٢", password="1234")
        self.manager.groups.add(Group.objects.get(name=MANAGER_GROUP))
        self.url = reverse("state")

    def test_body_carries_counters_and_nothing_else(self):
        self.client.force_login(self.cashier)
        response = self.client.get(self.url)
        self.assertEqual(
            set(response.data),
            {"versions", "poll_interval_seconds", "enabled"},
        )
        for name, value in response.data["versions"].items():
            self.assertIn(name, {d.name for d in state_version.DOMAINS})
            self.assertTrue(value.isdigit(), f"{name} is not a plain counter")

    def test_roles_see_the_same_shape(self):
        # No domain is permission-gated, and none may be: hiding a counter from
        # a cashier would leave their till trusting a stale cache instead.
        self.client.force_login(self.cashier)
        cashier_names = set(self.client.get(self.url).data["versions"])
        self.client.force_login(self.manager)
        manager_names = set(self.client.get(self.url).data["versions"])
        self.assertEqual(cashier_names, manager_names)

    def test_per_user_counters_follow_the_caller(self):
        from apps.notifications.cache import bump_user_notifications_version

        with override_settings(POINTY_NOTIFICATIONS_CACHE_ENABLED=True):
            bump_user_notifications_version(self.manager.pk)
        self.client.force_login(self.cashier)
        cashier = self.client.get(self.url).data["versions"]["notifications_user"]
        self.client.force_login(self.manager)
        manager = self.client.get(self.url).data["versions"]["notifications_user"]
        self.assertNotEqual(cashier, manager)

    def test_anonymous_vector_has_no_per_user_counters(self):
        current = state_version.versions(user_id=None)
        self.assertNotIn("notifications_user", current)

    def test_a_permission_change_moves_the_permissions_counter(self):
        # This is the one clients must treat as "drop everything cached and
        # re-resolve who I am", so it has to actually move.
        self.client.force_login(self.cashier)
        before = self.client.get(self.url).data["versions"]["permissions"]
        with self.commit():
            self.cashier.groups.add(Group.objects.get(name=MANAGER_GROUP))
        after = self.client.get(self.url).data["versions"]["permissions"]
        self.assertNotEqual(after, before)


@EXPLODING
class FailOpenTests(CommitsMixin, TestCase):
    """Redis down must cost clients their freshness, never their request."""

    def test_versions_read_empty(self):
        self.assertEqual(state_version.versions(), {})

    def test_bump_does_not_raise(self):
        with self.commit():
            state_version.bump("settings")  # must not raise

    def test_requests_still_succeed_without_the_header(self):
        user = User.objects.create_user(username="مدير٣", password="1234")
        user.groups.add(Group.objects.get(name=MANAGER_GROUP))
        self.client.force_login(user)
        response = self.client.get(reverse("shop-settings"))
        self.assertEqual(response.status_code, 200)
        self.assertNotIn(state_version.STATE_HEADER, response)

    def test_endpoint_reports_itself_disabled(self):
        user = User.objects.create_user(username="كاشير٣", password="1234")
        user.groups.add(Group.objects.get(name=CASHIER_GROUP))
        self.client.force_login(user)
        response = self.client.get(reverse("state"))
        self.assertEqual(response.status_code, 200)
        self.assertFalse(response.data["enabled"])
        self.assertEqual(response.data["versions"], {})
