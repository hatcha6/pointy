"""The Redis-backed cache one provider login is kept in.

Deliberately dumb by design (see the module docstring), so what is worth
proving here is narrow: a saved session round-trips, a credential or URL
change misses rather than reuses somebody else's session, the whole thing is
a no-op when disabled (which is the state every OTHER test in this app runs
in — TTL forced to 0 under TESTING, same as apps.core.caching), and a Redis
hiccup degrades to a cache miss rather than a crash.
"""

from django.core.cache import cache
from django.test import SimpleTestCase, TestCase, override_settings

from . import session_cache
from .tests import make_account

CACHED = override_settings(
    CACHES={
        "default": {
            "BACKEND": "django.core.cache.backends.locmem.LocMemCache",
            "LOCATION": "integrations-session-cache-tests",
        },
    },
    POINTY_INTEGRATION_SESSION_CACHE_TTL=600,
)


@CACHED
class SessionCacheTests(TestCase):
    def setUp(self):
        cache.clear()

    def test_a_saved_session_round_trips(self):
        account = make_account()
        session_cache.save("hdbox", account, {"cookies": {"JSESSIONID": "abc123"}})
        self.assertEqual(
            session_cache.load("hdbox", account),
            {"cookies": {"JSESSIONID": "abc123"}},
        )

    def test_a_miss_is_none_not_an_empty_dict(self):
        account = make_account()
        self.assertIsNone(session_cache.load("hdbox", account))

    def test_two_providers_on_the_same_account_id_never_collide(self):
        # Never true today (one account per provider), but the key must not
        # rely on that — a provider column is part of the identity.
        account = make_account()
        session_cache.save("hdbox", account, {"cookies": {"a": "1"}})
        self.assertIsNone(session_cache.load("lnet", account))

    def test_two_accounts_never_share_a_session(self):
        one = make_account(username="agency-one")
        two = make_account(provider="lnet", username="agency-two")
        session_cache.save("hdbox", one, {"cookies": {"who": "one"}})
        self.assertIsNone(session_cache.load("lnet", two))

    def test_a_password_change_misses_the_old_session(self):
        # This is not just hygiene: probe() is run specifically to verify a
        # NEW password, right after Shop Settings saves it. If the fingerprint
        # ignored the password, that probe would silently replay the old
        # session and report success without ever trying the new one.
        account = make_account()
        session_cache.save("hdbox", account, {"cookies": {"a": "1"}})
        account.set_secret("password", "a-different-password")
        account.save()
        self.assertIsNone(session_cache.load("hdbox", account))

    def test_a_username_change_misses_the_old_session(self):
        account = make_account()
        session_cache.save("hdbox", account, {"cookies": {"a": "1"}})
        account.username = "somebody-else"
        account.save()
        self.assertIsNone(session_cache.load("hdbox", account))

    def test_a_base_url_change_misses_the_old_session(self):
        account = make_account()
        session_cache.save("hdbox", account, {"cookies": {"a": "1"}})
        account.base_url = "http://a-different-host:1"
        account.save()
        self.assertIsNone(session_cache.load("hdbox", account))

    def test_invalidate_forgets_it(self):
        account = make_account()
        session_cache.save("hdbox", account, {"cookies": {"a": "1"}})
        session_cache.invalidate("hdbox", account)
        self.assertIsNone(session_cache.load("hdbox", account))

    def test_invalidating_something_never_saved_does_not_raise(self):
        session_cache.invalidate("hdbox", make_account())

    def test_an_unsaved_account_is_never_cached(self):
        # No stable pk to key on — and nothing here needs one badly enough to
        # save() against a row that may not exist by the time it is read.
        from .models import IntegrationAccount

        unsaved = IntegrationAccount(provider="hdbox", username="x")
        session_cache.save("hdbox", unsaved, {"cookies": {"a": "1"}})
        self.assertIsNone(session_cache.load("hdbox", unsaved))


class SessionCacheDisabledByDefaultTests(TestCase):
    """The state every other test in this app runs in — no override at all."""

    def test_save_then_load_is_a_miss_under_the_default_test_settings(self):
        account = make_account()
        session_cache.save("hdbox", account, {"cookies": {"a": "1"}})
        self.assertIsNone(session_cache.load("hdbox", account))


@CACHED
class SessionCacheFailsOpenTests(TestCase):
    def setUp(self):
        cache.clear()

    def test_a_read_that_cannot_reach_redis_is_a_miss_not_a_crash(self):
        from unittest import mock

        account = make_account()
        session_cache.save("hdbox", account, {"cookies": {"a": "1"}})
        with mock.patch.object(
            session_cache.cache, "get", side_effect=ConnectionError("redis down")
        ):
            self.assertIsNone(session_cache.load("hdbox", account))

    def test_a_write_that_cannot_reach_redis_does_not_raise(self):
        from unittest import mock

        account = make_account()
        with mock.patch.object(
            session_cache.cache, "set", side_effect=ConnectionError("redis down")
        ):
            session_cache.save("hdbox", account, {"cookies": {"a": "1"}})  # must not raise

    def test_invalidate_that_cannot_reach_redis_does_not_raise(self):
        from unittest import mock

        account = make_account()
        with mock.patch.object(
            session_cache.cache, "delete", side_effect=ConnectionError("redis down")
        ):
            session_cache.invalidate("hdbox", account)  # must not raise
