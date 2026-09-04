"""Source-transport registry.

Only one transport survives the move to file-based migration: SQLite. Every
supported input format is converted to a SQLite file by ``preparation/`` before
a connector ever sees it, so a connector reads exactly one kind of thing no
matter what the shop handed over.

The registry is kept (rather than collapsed into a direct import) because the
two-axis transport × connector split is still what lets a connector stay a pure
schema interpreter, and because the next format that needs a genuinely different
reader plugs in here.
"""

from __future__ import annotations

from ..exceptions import TransportError
from .base import BaseTransport, ColumnInfo, TableInfo
from .sqlite import SqliteTransport

TRANSPORT_REGISTRY: dict[str, type[BaseTransport]] = {
    transport.kind: transport for transport in (SqliteTransport,)
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
    "SqliteTransport",
]
