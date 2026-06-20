"""Shared implementation for DB-API 2.0 SQL transports.

``SqlTransport`` provides everything the SQL engines have in common —
parameterised reads, ``INFORMATION_SCHEMA`` introspection, identifier quoting,
and a legacy-codepage decoder. Concrete engines (SQLite, Postgres, SQL Server)
only supply ``_create_connection`` and any dialect overrides.
"""

from __future__ import annotations

import abc
from collections.abc import Iterator

from ..exceptions import TransportError
from .base import DEFAULT_BATCH_SIZE, BaseTransport, ColumnInfo, TableInfo


class SqlTransport(BaseTransport):
    #: DB-API ``paramstyle``: "qmark" -> ``?``  /  "format" -> ``%s``.
    param_style = "qmark"

    def __init__(self, config=None):
        super().__init__(config)
        self._connection = None

    # --- connection lifecycle -------------------------------------------
    @abc.abstractmethod
    def _create_connection(self):
        """Return an open DB-API connection (lazy-imports the driver)."""

    def connect(self) -> None:
        if self._connection is None:
            self._connection = self._create_connection()

    def close(self) -> None:
        if self._connection is not None:
            try:
                self._connection.close()
            except Exception:  # noqa: BLE001 - closing must never raise
                pass
            finally:
                self._connection = None

    # --- dialect knobs ---------------------------------------------------
    def _placeholder(self) -> str:
        return "?" if self.param_style == "qmark" else "%s"

    def _quote_identifier(self, name: str) -> str:
        # ANSI double-quote with doubling; SQL Server overrides to [brackets].
        return '"' + str(name).replace('"', '""') + '"'

    # --- introspection ---------------------------------------------------
    def list_tables(self) -> list[str]:
        rows = self._fetch_all("SELECT TABLE_NAME FROM INFORMATION_SCHEMA.TABLES")
        return [row[0] for row in rows]

    def describe_table(self, name: str) -> TableInfo:
        placeholder = self._placeholder()
        rows = self._fetch_all(
            "SELECT COLUMN_NAME, DATA_TYPE, IS_NULLABLE "
            f"FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_NAME = {placeholder}",
            [name],
        )
        columns = tuple(
            ColumnInfo(
                name=row[0],
                data_type=str(row[1] or ""),
                nullable=str(row[2]).upper() != "NO",
            )
            for row in rows
        )
        return TableInfo(name=name, columns=columns)

    # --- data access -----------------------------------------------------
    def _build_where(self, where: dict | None):
        if not where:
            return "", []
        placeholder = self._placeholder()
        clauses = []
        params: list = []
        for column, value in where.items():
            clauses.append(f"{self._quote_identifier(column)} = {placeholder}")
            params.append(value)
        return " WHERE " + " AND ".join(clauses), params

    def iter_records(
        self,
        table: str,
        *,
        fields: list[str] | None = None,
        where: dict | None = None,
        batch_size: int = DEFAULT_BATCH_SIZE,
    ) -> Iterator[dict]:
        self.connect()
        select = "*" if not fields else ", ".join(self._quote_identifier(field) for field in fields)
        where_sql, params = self._build_where(where)
        sql = f"SELECT {select} FROM {self._quote_identifier(table)}{where_sql}"
        cursor = self._connection.cursor()
        try:
            cursor.execute(sql, params)
            column_names = [description[0] for description in cursor.description]
            while True:
                rows = cursor.fetchmany(batch_size)
                if not rows:
                    break
                for row in rows:
                    yield self._row_to_dict(column_names, row)
        except Exception as exc:  # noqa: BLE001 - surface as a transport error
            raise TransportError(f"Failed to read from {table!r}: {exc}") from exc
        finally:
            cursor.close()

    def count(self, table: str, *, where: dict | None = None) -> int:
        where_sql, params = self._build_where(where)
        rows = self._fetch_all(
            f"SELECT COUNT(*) FROM {self._quote_identifier(table)}{where_sql}",
            params,
        )
        return int(rows[0][0]) if rows else 0

    def raw_query(self, sql: str, params: list | None = None) -> Iterator[dict]:
        """SQL-only escape hatch for connectors that genuinely need a join.

        Intentionally absent from :class:`MongoTransport` — that asymmetry is
        correct, and connectors that use it declare a SQL-only ``required_transport``.
        """
        self.connect()
        cursor = self._connection.cursor()
        try:
            cursor.execute(sql, params or [])
            column_names = [description[0] for description in cursor.description]
            for row in cursor.fetchall():
                yield self._row_to_dict(column_names, row)
        except Exception as exc:  # noqa: BLE001
            raise TransportError(f"Query failed: {exc}") from exc
        finally:
            cursor.close()

    # --- internals -------------------------------------------------------
    def _fetch_all(self, sql: str, params: list | None = None):
        self.connect()
        cursor = self._connection.cursor()
        try:
            cursor.execute(sql, params or [])
            return cursor.fetchall()
        except Exception as exc:  # noqa: BLE001
            raise TransportError(f"Query failed: {exc}") from exc
        finally:
            cursor.close()

    def _row_to_dict(self, column_names, row) -> dict:
        return {name: self._decode_value(value) for name, value in zip(column_names, row)}

    def _decode_value(self, value):
        # Legacy SQL Server databases frequently return text as bytes in a
        # non-UTF-8 codepage (Windows-1256 for Arabic). Decode with the
        # configured encoding, falling back gracefully.
        if isinstance(value, bytes):
            encoding = self.options.get("encoding") or "utf-8"
            try:
                return value.decode(encoding, errors="replace")
            except (LookupError, UnicodeDecodeError):
                return value.decode("utf-8", errors="replace")
        return value
