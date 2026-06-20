"""SQLite source transport (stdlib — no optional driver needed).

Used both for real SQLite-backed legacy systems and as the engine of the
generic reference connector / the test suite.
"""

from __future__ import annotations

import sqlite3

from ..exceptions import TransportError
from .base import CONNECT_TIMEOUT_SECONDS, ColumnInfo, TableInfo
from .sql_base import SqlTransport


class SqliteTransport(SqlTransport):
    kind = "sqlite"
    param_style = "qmark"

    def _create_connection(self):
        path = self.config.get("database")
        if not path:
            raise TransportError("A SQLite database file path is required.")
        try:
            connection = sqlite3.connect(
                path,
                timeout=CONNECT_TIMEOUT_SECONDS,
                detect_types=0,
            )
            # Read-only intent: SQLite has no INFORMATION_SCHEMA, so the SQL
            # base's introspection is overridden below with sqlite_master/PRAGMA.
            connection.execute("SELECT 1")
        except sqlite3.Error as exc:
            raise TransportError(f"Could not open the SQLite database: {exc}") from exc
        return connection

    def list_tables(self) -> list[str]:
        rows = self._fetch_all("SELECT name FROM sqlite_master WHERE type IN ('table', 'view')")
        return [row[0] for row in rows]

    def describe_table(self, name: str) -> TableInfo:
        # PRAGMA cannot be parameterised; quote the identifier instead.
        rows = self._fetch_all(f"PRAGMA table_info({self._quote_identifier(name)})")
        # PRAGMA table_info columns: cid, name, type, notnull, dflt_value, pk
        columns = tuple(
            ColumnInfo(
                name=row[1],
                data_type=str(row[2] or ""),
                nullable=not bool(row[3]),
            )
            for row in rows
        )
        return TableInfo(name=name, columns=columns)
