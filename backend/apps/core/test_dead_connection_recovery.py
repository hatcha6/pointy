"""A pooled connection can be dead on the server while it still looks alive here.

On-prem runs ``CONN_MAX_AGE=120`` (``deploy/onprem/.env.example``), so every
worker thread holds a Postgres connection open across requests. Postgres and
PgBouncer both get restarted for reasons the shop does not control — a mains
blip, a container recycle, an update flip — and a restart does not tell the
client anything: the socket is simply gone the next time we write to it.

Django only notices if it is asked to look. ``close_old_connections`` (fired on
``request_started``) closes a connection that is *obsolete* or that has already
errored; a connection inside its 120s window that has never failed is handed
straight to the view, which then raises on its first query. That is one 500 per
pooled connection after every database restart, and one of them can be a
checkout — even though reconnecting would have worked immediately.

``CONN_HEALTH_CHECKS`` makes Django ping the connection before the request's
first query and reconnect when the ping fails. These tests inject the failure
the way the real thing happens — ``pg_terminate_backend`` from a second session,
which is exactly what a Postgres restart does to a pooled backend — and pin both
sides: recovery with the health check, and the pre-fix 503/500 without it.
"""

from __future__ import annotations

from django.conf import settings
from django.db import close_old_connections, connections
from django.test import TransactionTestCase

from apps.core.models import ShopSettings


class DeadPooledConnectionTests(TransactionTestCase):
    databases = {"default"}

    def setUp(self):
        engine = str(settings.DATABASES["default"].get("ENGINE", ""))
        if not engine.endswith("postgresql"):
            self.skipTest("persistent connections only apply to the postgresql engine")
        self.conn = connections["default"]
        self._original_max_age = self.conn.settings_dict["CONN_MAX_AGE"]
        self.addCleanup(self._restore)
        # The test runner leaves CONN_MAX_AGE at 0, where every request opens a
        # fresh connection and this failure cannot happen. Put the connection in
        # the shape a shop actually runs it in.
        self.conn.close()
        self.conn.settings_dict["CONN_MAX_AGE"] = 120
        self.conn.connect()
        self.assertIsNotNone(self.conn.close_at, "expected a persistent connection")

    def _restore(self):
        self.conn.close()
        self.conn.settings_dict["CONN_MAX_AGE"] = self._original_max_age
        self.conn.health_check_enabled = self.conn.settings_dict["CONN_HEALTH_CHECKS"]

    def _kill_server_side(self):
        """Drop our backend from a second session, as a restart would."""
        with self.conn.cursor() as cursor:
            cursor.execute("SELECT pg_backend_pid()")
            pid = cursor.fetchone()[0]
        killer = connections.create_connection("default")
        try:
            with killer.cursor() as cursor:
                cursor.execute("SELECT pg_terminate_backend(%s)", [pid])
        finally:
            killer.close()
        # Nothing has told our side yet: Django still believes it holds a socket.
        self.assertIsNotNone(self.conn.connection)
        self.assertFalse(self.conn.errors_occurred)

    def _start_request(self):
        """What ``request_started`` does in production.

        Calling it by hand rather than letting the test client fire the signal:
        ``ClientHandler`` disconnects ``close_old_connections`` around the
        request so it cannot tear down the harness's own transaction, which
        would also skip the very boundary under test here.
        """
        close_old_connections()
        self.assertFalse(self.conn.health_check_done)

    def test_readyz_reconnects_instead_of_reporting_the_database_down(self):
        self._kill_server_side()
        self._start_request()

        response = self.client.get("/readyz/")

        self.assertEqual(response.status_code, 200, response.content)
        self.assertEqual(response.json()["checks"]["database"], "ok")

    def test_a_request_that_queries_recovers_on_its_first_query(self):
        # The shape every authenticated request has: a request boundary, then
        # a query. Before the fix this raised OperationalError out of the view.
        self._kill_server_side()
        self._start_request()

        # The assertion that matters is that this does not raise.
        self.assertGreaterEqual(ShopSettings.objects.count(), 0)

    def test_health_checks_are_what_saves_it(self):
        """Pre-fix behaviour: a healthy database is reported as down."""
        self.conn.health_check_enabled = False
        self._kill_server_side()
        self._start_request()

        response = self.client.get("/readyz/")

        self.assertEqual(response.status_code, 503)
        self.assertEqual(response.json()["checks"]["database"], "error")
        # Leave a usable connection behind for the fixture teardown.
        self.conn.close()
