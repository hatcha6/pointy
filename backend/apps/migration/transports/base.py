"""Driver-agnostic, read-only access to one source database.

The interface is deliberately document/collection oriented — dicts in, dicts
out — so SQL engines and MongoDB share it without leaking SQL-isms into the
connectors. The portable ``where`` filter is a simple equality dict
(``{"column": value}``) translated per transport. **Source access is strictly
read-only**: no transport ever issues a write, and connect/read timeouts mirror
``apps.attendance.biotime.BioTimeClient`` so a wrong host cannot hang a worker.
"""

from __future__ import annotations

import abc
from collections.abc import Iterator
from dataclasses import dataclass, field

# Mirror BioTimeClient's timeouts.
CONNECT_TIMEOUT_SECONDS = 10
READ_TIMEOUT_SECONDS = 30
DEFAULT_BATCH_SIZE = 1000


@dataclass(frozen=True)
class ColumnInfo:
    name: str
    data_type: str = ""
    nullable: bool = True


@dataclass(frozen=True)
class TableInfo:
    name: str
    columns: tuple[ColumnInfo, ...] = field(default_factory=tuple)

    def column_names(self) -> set[str]:
        """Lower-cased column names for case-insensitive compatibility checks."""
        return {column.name.lower() for column in self.columns}


class BaseTransport(abc.ABC):
    """Base class every source transport implements.

    Subclasses lazily import their third-party driver inside ``connect`` (or the
    SQL helper that opens the connection) and raise
    :class:`~apps.migration.exceptions.DriverNotInstalled` if it is missing, so
    importing this package never requires every driver to be present.
    """

    #: Stable key used in the transport registry and on ``MigrationSource``.
    kind: str = ""

    def __init__(self, config: dict | None = None):
        self.config = dict(config or {})
        self.options = dict(self.config.get("options") or {})

    # --- lifecycle -------------------------------------------------------
    @abc.abstractmethod
    def connect(self) -> None:
        """Open the connection (idempotent). Raises TransportError on failure."""

    @abc.abstractmethod
    def close(self) -> None:
        """Close the connection if open. Safe to call more than once."""

    def __enter__(self):
        self.connect()
        return self

    def __exit__(self, *exc):
        self.close()
        return False

    # --- schema introspection (powers compatibility detection) -----------
    @abc.abstractmethod
    def list_tables(self) -> list[str]:
        """All readable tables/views (SQL) or collection names (Mongo)."""

    @abc.abstractmethod
    def describe_table(self, name: str) -> TableInfo:
        """Columns for one table (SQL) or sampled document keys (Mongo)."""

    # --- data access -----------------------------------------------------
    @abc.abstractmethod
    def iter_records(
        self,
        table: str,
        *,
        fields: list[str] | None = None,
        where: dict | None = None,
        batch_size: int = DEFAULT_BATCH_SIZE,
    ) -> Iterator[dict]:
        """Stream rows/documents as plain dicts, batched to bound memory."""

    @abc.abstractmethod
    def count(self, table: str, *, where: dict | None = None) -> int:
        """Row/document count, used for progress estimation."""

    # --- convenience -----------------------------------------------------
    def has_table(self, name: str) -> bool:
        target = name.lower()
        return any(table.lower() == target for table in self.list_tables())
