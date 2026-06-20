"""PostgreSQL source transport (psycopg — already a base dependency)."""

from __future__ import annotations

from ..exceptions import DriverNotInstalled, TransportError
from .base import CONNECT_TIMEOUT_SECONDS
from .sql_base import SqlTransport

# Tables in these schemas are PostgreSQL internals, never shop data.
_SYSTEM_SCHEMAS = ("pg_catalog", "information_schema")


class PostgresTransport(SqlTransport):
    kind = "postgres"
    param_style = "format"  # psycopg uses %s placeholders

    def _create_connection(self):
        try:
            import psycopg
        except ImportError as exc:  # pragma: no cover - psycopg is a base dep
            raise DriverNotInstalled("The PostgreSQL driver (psycopg) is not installed.") from exc
        try:
            return psycopg.connect(
                host=self.config.get("host") or "localhost",
                port=self.config.get("port") or 5432,
                dbname=self.config.get("database") or "",
                user=self.config.get("username") or "",
                password=self.config.get("password") or "",
                connect_timeout=CONNECT_TIMEOUT_SECONDS,
                autocommit=True,
            )
        except Exception as exc:  # noqa: BLE001 - psycopg.OperationalError etc.
            raise TransportError(f"Could not connect to PostgreSQL: {exc}") from exc

    def list_tables(self) -> list[str]:
        placeholders = ", ".join([self._placeholder()] * len(_SYSTEM_SCHEMAS))
        rows = self._fetch_all(
            "SELECT table_name FROM information_schema.tables "
            f"WHERE table_schema NOT IN ({placeholders})",
            list(_SYSTEM_SCHEMAS),
        )
        return [row[0] for row in rows]
