"""The session cache must never be able to fail a request.

``load()`` runs on every authenticated request, and the cache write it does on a
miss is unguarded upstream — so a Redis hiccup used to 500 the whole API, which
showed up as a flood of 5xx on the busiest endpoint (the POS discount preview).
"""

from django.contrib.auth import get_user_model
from django.core.cache.backends.base import BaseCache
from django.test import TestCase, override_settings

from apps.core.sessions import SessionStore, _FailOpenCache


class BoomCache(BaseCache):
    """A cache that raises on every operation, like a Redis that is down."""

    def __init__(self, location, params):
        super().__init__(params)

    def _boom(self, *args, **kwargs):
        raise ConnectionError("redis is down")

    add = get = set = touch = delete = clear = _boom
    get_many = set_many = delete_many = incr = decr = has_key = _boom


BOOM_CACHES = {"default": {"BACKEND": "apps.core.test_sessions.BoomCache"}}


class FailOpenSessionStoreTests(TestCase):
    def test_cache_is_wrapped(self):
        # cached_db assigns self._cache in __init__, so anything declared as a
        # descriptor here is silently shadowed and the wrapper never applies.
        store = SessionStore()

        self.assertIsInstance(store._cache, _FailOpenCache)

    @override_settings(CACHES=BOOM_CACHES)
    def test_session_round_trip_survives_dead_cache(self):
        store = SessionStore()
        store["hello"] = "world"
        store.save()
        session_key = store.session_key

        # The DB is the source of truth, so the value must survive a cache that
        # never stored it.
        reloaded = SessionStore(session_key)
        self.assertEqual(reloaded["hello"], "world")
        self.assertTrue(reloaded.exists(session_key))

        reloaded.delete(session_key)
        self.assertEqual(SessionStore(session_key).load(), {})

    @override_settings(CACHES=BOOM_CACHES)
    def test_load_from_db_survives_dead_cache(self):
        """The unguarded-upstream path: a cache miss repopulates the cache."""
        store = SessionStore()
        store["user"] = 7
        store.save()

        # A fresh store cannot hit the cache, so it loads from the DB and then
        # tries to write back — the exact call that used to raise.
        self.assertEqual(SessionStore(store.session_key)["user"], 7)


class AuthenticatedRequestSurvivesDeadCacheTests(TestCase):
    def setUp(self):
        self.user = get_user_model().objects.create_user(
            username="cashier",
            password="pass",
        )

    @override_settings(CACHES=BOOM_CACHES)
    def test_login_and_authenticated_request_survive_dead_cache(self):
        self.assertTrue(self.client.login(username="cashier", password="pass"))

        # Any authenticated endpoint exercises session load on the way in.
        response = self.client.get("/api/products/")

        self.assertLess(response.status_code, 500, response.content[:500])
