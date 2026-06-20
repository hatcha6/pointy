"""MongoDB source transport (pymongo — optional ``migration`` extra).

Document oriented: ``describe_table`` infers field presence by sampling
documents (Mongo is schemaless, so there is no catalogue to query). Install the
driver with ``pip install pointy-backend[migration]``.
"""

from __future__ import annotations

from collections.abc import Iterator

from ..exceptions import DriverNotInstalled, TransportError
from .base import (
    CONNECT_TIMEOUT_SECONDS,
    DEFAULT_BATCH_SIZE,
    BaseTransport,
    ColumnInfo,
    TableInfo,
)

_DEFAULT_SAMPLE_SIZE = 50


class MongoTransport(BaseTransport):
    kind = "mongo"

    def __init__(self, config=None):
        super().__init__(config)
        self._client = None
        self._db = None

    def connect(self) -> None:
        if self._client is not None:
            return
        try:
            import pymongo
        except ImportError as exc:
            raise DriverNotInstalled(
                "The MongoDB driver (pymongo) is not installed. "
                "Install it with: pip install pointy-backend[migration]"
            ) from exc

        database_name = self.config.get("database")
        if not database_name:
            raise TransportError("A MongoDB database name is required.")
        uri = self.options.get("uri")
        try:
            if uri:
                client = pymongo.MongoClient(
                    uri, serverSelectionTimeoutMS=CONNECT_TIMEOUT_SECONDS * 1000
                )
            else:
                client = pymongo.MongoClient(
                    host=self.config.get("host") or "localhost",
                    port=self.config.get("port") or 27017,
                    username=self.config.get("username") or None,
                    password=self.config.get("password") or None,
                    authSource=self.options.get("auth_source") or "admin",
                    serverSelectionTimeoutMS=CONNECT_TIMEOUT_SECONDS * 1000,
                )
            # Force a round-trip now so connection errors surface here, friendly.
            client.admin.command("ping")
        except Exception as exc:  # noqa: BLE001 - pymongo.errors.*
            raise TransportError(f"Could not connect to MongoDB: {exc}") from exc
        self._client = client
        self._db = client[database_name]

    def close(self) -> None:
        if self._client is not None:
            try:
                self._client.close()
            except Exception:  # noqa: BLE001
                pass
            finally:
                self._client = None
                self._db = None

    def list_tables(self) -> list[str]:
        self.connect()
        return list(self._db.list_collection_names())

    def describe_table(self, name: str) -> TableInfo:
        self.connect()
        sample_size = int(self.options.get("sample_size") or _DEFAULT_SAMPLE_SIZE)
        seen: dict[str, str] = {}
        for document in self._db[name].find({}, limit=sample_size):
            for key, value in document.items():
                seen.setdefault(key, type(value).__name__)
        columns = tuple(
            ColumnInfo(name=key, data_type=data_type, nullable=True)
            for key, data_type in seen.items()
        )
        return TableInfo(name=name, columns=columns)

    def iter_records(
        self,
        table: str,
        *,
        fields: list[str] | None = None,
        where: dict | None = None,
        batch_size: int = DEFAULT_BATCH_SIZE,
    ) -> Iterator[dict]:
        self.connect()
        projection = {field: 1 for field in fields} if fields else None
        try:
            cursor = self._db[table].find(where or {}, projection=projection, batch_size=batch_size)
            for document in cursor:
                yield self._normalize(document)
        except Exception as exc:  # noqa: BLE001
            raise TransportError(f"Failed to read collection {table!r}: {exc}") from exc

    def count(self, table: str, *, where: dict | None = None) -> int:
        self.connect()
        return int(self._db[table].count_documents(where or {}))

    @staticmethod
    def _normalize(document: dict) -> dict:
        # ObjectId isn't JSON-serialisable; expose it as a plain string so
        # connectors can use it as a stable source key.
        identifier = document.get("_id")
        if identifier is not None and not isinstance(identifier, (str, int)):
            document["_id"] = str(identifier)
        return document
