"""Regression tests for the PgBouncer transaction-pooling database settings.

On-prem serves Postgres through PgBouncer in transaction-pooling mode. Two
psycopg3/Django features quietly break there because each transaction may land
on a different pooled backend:

* server-side prepared statements -> ``prepared statement ... does not exist``
* named (server-side) cursors     -> ``cursor "_django_curs_..._sync_N" does
  not exist`` / ``already exists``  (GitHub issue #5)

``pointy/settings.py`` neutralises both for the postgresql engine. These tests
pin that so the fix can't silently regress.
"""

from django.conf import settings
from django.test import SimpleTestCase


class PgBouncerDatabaseSettingsTests(SimpleTestCase):
    def _is_postgres(self):
        engine = str(settings.DATABASES["default"].get("ENGINE", ""))
        return engine.endswith("postgresql")

    def test_server_side_cursors_disabled_on_postgres(self):
        # Named cursors can't survive transaction pooling: the DECLARE and the
        # FETCH land on different PgBouncer backends. Disabling them makes
        # QuerySet.iterator() stream client-side instead (issue #5).
        if not self._is_postgres():
            self.skipTest("only applies to the postgresql engine")
        self.assertIs(
            settings.DATABASES["default"].get("DISABLE_SERVER_SIDE_CURSORS"),
            True,
        )

    def test_prepared_statements_disabled_on_postgres(self):
        if not self._is_postgres():
            self.skipTest("only applies to the postgresql engine")
        self.assertIsNone(
            settings.DATABASES["default"].get("OPTIONS", {}).get("prepare_threshold"),
        )
