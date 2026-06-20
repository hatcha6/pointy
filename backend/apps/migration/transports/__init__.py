"""Source-transport registry.

Importing this package is always safe even when optional drivers (pyodbc,
pymongo) are missing — the drivers are imported lazily inside each transport's
``connect``/``_create_connection``, never at module load.
"""

from __future__ import annotations

from ..exceptions import TransportError
from .base import BaseTransport, ColumnInfo, TableInfo
from .mongo import MongoTransport
from .mssql import MssqlTransport
from .postgres import PostgresTransport
from .sqlite import SqliteTransport

TRANSPORT_REGISTRY: dict[str, type[BaseTransport]] = {
    transport.kind: transport
    for transport in (
        MssqlTransport,
        PostgresTransport,
        SqliteTransport,
        MongoTransport,
    )
}


def get_transport_class(kind: str) -> type[BaseTransport]:
    try:
        return TRANSPORT_REGISTRY[kind]
    except KeyError as exc:
        raise TransportError(f"Unknown source database type: {kind!r}.") from exc


def build_transport(kind: str, config: dict) -> BaseTransport:
    return get_transport_class(kind)(config)


__all__ = [
    "BaseTransport",
    "ColumnInfo",
    "TableInfo",
    "TRANSPORT_REGISTRY",
    "get_transport_class",
    "build_transport",
    "MssqlTransport",
    "PostgresTransport",
    "SqliteTransport",
    "MongoTransport",
]
