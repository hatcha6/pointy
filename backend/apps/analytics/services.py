import csv
import io
import json
import uuid
import zipfile
from collections import deque
from dataclasses import dataclass

from django.db import transaction
from django.db.models import F, Q
from django.utils import timezone

from .models import AnalyticsEvent


ANALYTICS_EXPORT_CSV_FIELDS = (
    "id",
    "client_event_id",
    "event_type",
    "name",
    "severity",
    "source",
    "occurred_at",
    "received_by_id",
    "received_by_username",
    "session_id",
    "device_id",
    "installation_id",
    "app_version",
    "platform",
    "request_path",
    "ip_address",
    "user_agent",
    "trace_id",
    "entity_type",
    "entity_id",
    "risk_score",
    "attributes",
    "metrics",
    "created_at",
    "updated_at",
)

# ``received_by_username`` is an annotation (LEFT JOIN on the user table); every
# other CSV column is a concrete AnalyticsEvent column we can pull via values().
_EXPORT_ROW_FIELDS = tuple(
    field for field in ANALYTICS_EXPORT_CSV_FIELDS if field != "received_by_username"
)

# Rows fetched per keyset batch. Each batch is one indexed query and at most a
# few MB of dicts, so memory stays flat no matter how large the table grows.
ANALYTICS_EXPORT_BATCH_SIZE = 2000

# Compressed bytes buffered before the generator hands a chunk to the response.
_EXPORT_STREAM_CHUNK_BYTES = 64 * 1024


@dataclass(frozen=True)
class AnalyticsIngestResult:
    accepted: int
    duplicates: int
    event_ids: tuple[str, ...]
    duplicate_event_ids: tuple[str, ...]


def ingest_events(*, events, user, request=None) -> AnalyticsIngestResult:
    """Queue a batch of client telemetry for buffered bulk insertion.

    Deliberately does no per-request SELECT and opens no transaction: this is
    the single busiest endpoint in the fleet, and a telemetry POST must never
    hold a worker or contend on the (ever-growing) events table while the shop
    is trading. Rows go through the shared analytics buffer, which amortises the
    INSERT across requests and dedupes retried ``client_event_id``s at write
    time via the column's unique constraint (``ignore_conflicts``).

    The result is optimistic — ``accepted`` counts what was queued. Duplicates
    are dropped silently at insert rather than reported back (the old dedup
    SELECT grew with the table and the client never read the count: it keys its
    own retry queue by ``client_event_id``)."""
    from . import buffer

    request_path = getattr(request, "path", "") if request is not None else ""
    ip_address = _client_ip(request) if request is not None else None
    user_agent = _user_agent(request) if request is not None else ""
    received_by = user if getattr(user, "is_authenticated", False) else None

    rows = []
    event_ids = []
    for event in events:
        client_event_id = event.get("client_event_id") or uuid.uuid4()
        event_ids.append(str(client_event_id))
        rows.append(
            AnalyticsEvent(
                client_event_id=client_event_id,
                event_type=event["event_type"],
                name=event["name"],
                severity=event.get("severity", AnalyticsEvent.Severity.INFO),
                source=event.get("source", AnalyticsEvent.Source.FRONTEND),
                occurred_at=event.get("occurred_at") or timezone.now(),
                received_by=received_by,
                session_id=event.get("session_id", ""),
                device_id=event.get("device_id", ""),
                installation_id=event.get("installation_id", ""),
                app_version=event.get("app_version", ""),
                platform=event.get("platform", ""),
                request_path=request_path[:256],
                ip_address=ip_address,
                user_agent=user_agent,
                trace_id=event.get("trace_id", ""),
                entity_type=event.get("entity_type", ""),
                entity_id=event.get("entity_id", ""),
                risk_score=event.get("risk_score"),
                attributes=event.get("attributes", {}),
                metrics=event.get("metrics", {}),
            )
        )

    buffer.enqueue_many(rows)

    return AnalyticsIngestResult(
        accepted=len(rows),
        duplicates=0,
        event_ids=tuple(event_ids),
        duplicate_event_ids=(),
    )


class ZipStreamSink(io.RawIOBase):
    """Unseekable write target for ``zipfile``: buffers written bytes until the
    export generator drains them to the response, so the archive is produced
    chunk by chunk instead of accumulating whole in memory. Being unseekable
    makes ``zipfile`` write data-descriptor records — no rewinding needed."""

    def __init__(self):
        self._chunks = deque()
        self._position = 0
        self.pending = 0

    def writable(self):
        return True

    def write(self, data):
        chunk = bytes(data)
        self._chunks.append(chunk)
        self._position += len(chunk)
        self.pending += len(chunk)
        return len(chunk)

    def tell(self):
        return self._position

    def drain(self):
        """Yield everything buffered so far as ONE chunk.

        Coalescing matters more than it looks. Under ASGI each yielded chunk
        crosses from the producer thread to the event loop and out through
        uvicorn's send — a fixed cost per chunk, not per byte. zipfile writes
        here in small pieces, so handing them on individually turned a 14s
        export into a 155s one, with the hand-off, not the database or the
        compressor, doing all the waiting. One buffer-sized chunk per drain
        cuts that by two orders of magnitude.
        """
        if not self._chunks:
            return
        chunk = b"".join(self._chunks)
        self._chunks.clear()
        self.pending -= len(chunk)
        yield chunk


def export_zip_filename(exported_at) -> str:
    return f"pointy-analytics-events-{exported_at.strftime('%Y%m%dT%H%M%SZ')}.zip"


def count_events_for_export(queryset) -> int:
    """One aggregate for the count header — cheap next to streaming the rows."""
    return queryset.order_by().count()


def iter_export_rows(queryset, *, batch_size=ANALYTICS_EXPORT_BATCH_SIZE):
    """Yield export rows as dicts, in id order, with flat memory at any size.

    ``queryset.iterator()`` cannot do this here: on-prem Postgres runs behind
    PgBouncer in transaction pooling, so ``DISABLE_SERVER_SIDE_CURSORS`` is set
    and ``iterator()`` silently fetches the ENTIRE result client-side — the
    exact blow-up that made large exports crawl and then die. Keyset pagination
    over the primary key keeps every batch a small indexed query that works
    through any pooler, on any backend, with any filter combination.

    ``values()`` (plus a username annotation instead of ``select_related``)
    also skips model instantiation — a large constant-factor win per row.
    """
    rows = queryset.order_by("id").values(
        *_EXPORT_ROW_FIELDS,
        received_by_username=F("received_by__username"),
    )
    last_id = None
    while True:
        batch = rows if last_id is None else rows.filter(id__gt=last_id)
        batch = list(batch[:batch_size])
        yield from batch
        if len(batch) < batch_size:
            return
        last_id = batch[-1]["id"]


def iter_events_export_zip(
    *,
    queryset,
    filters,
    exported_by,
    exported_at=None,
    batch_size=ANALYTICS_EXPORT_BATCH_SIZE,
):
    """Stream the export zip using the fastest engine this database supports.

    On Postgres that is ``COPY ... TO STDOUT`` (see ``export.py``), which keeps
    Python out of the row path entirely — the difference between an export that
    finishes and one nobody has ever managed to sit through. Everywhere else
    (SQLite in dev and most tests), and whenever a caller explicitly asks for
    ``engine=orm``, it falls back to the keyset generator below.
    """
    from . import export

    exported_at = exported_at or timezone.now()
    if filters.get("engine") != "orm" and export.copy_export_supported(queryset.db):
        yield from export.iter_events_export_zip_copy(
            queryset=queryset,
            filters=filters,
            exported_by=exported_by,
            exported_at=exported_at,
            alias=queryset.db,
        )
        return

    yield from iter_events_export_zip_orm(
        queryset=queryset,
        filters=filters,
        exported_by=exported_by,
        exported_at=exported_at,
        batch_size=batch_size,
    )


def iter_events_export_zip_orm(
    *,
    queryset,
    filters,
    exported_by,
    exported_at=None,
    batch_size=ANALYTICS_EXPORT_BATCH_SIZE,
):
    """Generate the export zip's bytes incrementally, in bounded memory.

    The old builder assembled the full CSV/JSON in a StringIO, compressed it
    into a BytesIO, then copied that into the response — several times the raw
    data size resident at once, and zero bytes on the wire until all of it was
    done. This generator writes each row straight into the zip member and
    yields compressed chunks as they accumulate, so the download starts
    immediately and peak memory no longer depends on the export size.

    Level-1 deflate: shop PCs are CPU-poor and the LAN is not the bottleneck;
    with streaming, transfer overlaps compression anyway, so the cheaper
    compressor wins end-to-end.
    """
    from .export import zip_compression

    exported_at = exported_at or timezone.now()
    export_format = filters.get("format", "csv")
    compression, compresslevel = zip_compression(filters.get("compression", "deflate"))
    data_filename = f"analytics_events.{export_format}"

    sink = ZipStreamSink()
    event_count = 0
    with zipfile.ZipFile(
        sink, "w", compression=compression, compresslevel=compresslevel
    ) as archive:
        # force_zip64: with an unseekable sink the member header cannot be
        # rewritten, so oversized (>4GB) members must be declared up front.
        with archive.open(data_filename, mode="w", force_zip64=True) as member:
            with io.TextIOWrapper(member, encoding="utf-8", newline="") as text:
                if export_format == "csv":
                    writer = csv.DictWriter(
                        text, fieldnames=ANALYTICS_EXPORT_CSV_FIELDS
                    )
                    writer.writeheader()
                    for row in iter_export_rows(queryset, batch_size=batch_size):
                        writer.writerow(_event_export_row(row))
                        event_count += 1
                        if sink.pending >= _EXPORT_STREAM_CHUNK_BYTES:
                            yield from sink.drain()
                else:
                    # json wraps the same documents in an array; jsonl leaves
                    # them one per line.
                    as_array = export_format == "json"
                    if as_array:
                        text.write("[\n")
                    for row in iter_export_rows(queryset, batch_size=batch_size):
                        if as_array and event_count:
                            text.write(",\n")
                        text.write(
                            json.dumps(
                                _event_export_row(row),
                                ensure_ascii=False,
                                sort_keys=True,
                            )
                        )
                        if not as_array:
                            text.write("\n")
                        event_count += 1
                        if sink.pending >= _EXPORT_STREAM_CHUNK_BYTES:
                            yield from sink.drain()
                    if as_array:
                        text.write("\n]\n")
        manifest = {
            "generated_at": exported_at.isoformat(),
            "generated_by": {
                "id": getattr(exported_by, "id", None),
                "username": getattr(exported_by, "username", ""),
            },
            "event_count": event_count,
            "engine": "orm-keyset",
            "ordered": True,
            "filters": manifest_filters(filters),
            "files": [data_filename],
        }
        archive.writestr(
            "manifest.json",
            json.dumps(manifest, ensure_ascii=False, indent=2),
        )
    yield from sink.drain()


def filter_events_for_export(queryset, filters):
    if event_type := filters.get("event_type"):
        queryset = queryset.filter(event_type=event_type)
    if source := filters.get("source"):
        queryset = queryset.filter(source=source)
    if severity := filters.get("severity"):
        queryset = queryset.filter(severity=severity)
    if name := filters.get("name"):
        queryset = queryset.filter(name=name)
    if received_by := filters.get("received_by"):
        queryset = queryset.filter(received_by_id=received_by)
    if occurred_at_after := filters.get("occurred_at_after"):
        queryset = queryset.filter(occurred_at__gte=occurred_at_after)
    if occurred_at_before := filters.get("occurred_at_before"):
        queryset = queryset.filter(occurred_at__lte=occurred_at_before)
    if platform := filters.get("platform"):
        queryset = queryset.filter(platform=platform)
    if session_id := filters.get("session_id"):
        queryset = queryset.filter(session_id=session_id)
    if device_id := filters.get("device_id"):
        queryset = queryset.filter(device_id=device_id)
    if entity_type := filters.get("entity_type"):
        queryset = queryset.filter(entity_type=entity_type)
    if entity_id := filters.get("entity_id"):
        queryset = queryset.filter(entity_id=entity_id)
    if search := filters.get("search"):
        queryset = queryset.filter(
            Q(name__icontains=search)
            | Q(trace_id__icontains=search)
            | Q(entity_type__icontains=search)
            | Q(entity_id__icontains=search)
            | Q(request_path__icontains=search)
        )
    if filters.get("risk_score_min") is not None:
        queryset = queryset.filter(risk_score__gte=filters["risk_score_min"])
    if filters.get("risk_score_max") is not None:
        queryset = queryset.filter(risk_score__lte=filters["risk_score_max"])
    # Ordering is left to iter_export_rows: keyset pagination needs id order,
    # which the primary key serves for free on every filter combination.
    return queryset


def build_event(
    *,
    name,
    event_type=AnalyticsEvent.EventType.USAGE,
    severity=AnalyticsEvent.Severity.INFO,
    source=AnalyticsEvent.Source.BACKEND,
    user=None,
    occurred_at=None,
    attributes=None,
    metrics=None,
    **kwargs,
) -> AnalyticsEvent:
    return AnalyticsEvent(
        name=name,
        event_type=event_type,
        severity=severity,
        source=source,
        occurred_at=occurred_at or timezone.now(),
        received_by=user if getattr(user, "is_authenticated", False) else None,
        attributes=attributes or {},
        metrics=metrics or {},
        **kwargs,
    )


def record_event(**kwargs) -> AnalyticsEvent:
    event = build_event(**kwargs)
    event.save(force_insert=True)
    return event


def record_event_buffered(**kwargs) -> None:
    """``record_event`` for high-volume telemetry: rows are batched into one
    bulk INSERT per buffer window (see ``buffer.py``) and nothing is returned.
    Only for events nobody reads back synchronously — audit trails and
    anything whose pk matters must use ``record_event``."""
    from . import buffer

    buffer.enqueue(build_event(**kwargs))


def record_domain_event(
    *,
    name,
    event_type=AnalyticsEvent.EventType.AUDIT,
    severity=AnalyticsEvent.Severity.INFO,
    source=AnalyticsEvent.Source.BACKEND,
    user=None,
    occurred_at=None,
    attributes=None,
    metrics=None,
    **kwargs,
):
    def create_event():
        try:
            record_event(
                name=name,
                event_type=event_type,
                severity=severity,
                source=source,
                user=user,
                occurred_at=occurred_at,
                attributes=_json_safe(attributes or {}),
                metrics=_json_safe(metrics or {}),
                **kwargs,
            )
        except Exception:
            return

    try:
        transaction.on_commit(create_event)
    except Exception:
        create_event()


def _event_export_row(row):
    """Format one ``iter_export_rows`` values() dict for the CSV/JSON member."""
    return {
        "id": row["id"],
        "client_event_id": str(row["client_event_id"]),
        "event_type": row["event_type"],
        "name": row["name"],
        "severity": row["severity"],
        "source": row["source"],
        "occurred_at": row["occurred_at"].isoformat(),
        "received_by_id": row["received_by_id"] or "",
        "received_by_username": row["received_by_username"] or "",
        "session_id": row["session_id"],
        "device_id": row["device_id"],
        "installation_id": row["installation_id"],
        "app_version": row["app_version"],
        "platform": row["platform"],
        "request_path": row["request_path"],
        "ip_address": str(row["ip_address"] or ""),
        "user_agent": row["user_agent"],
        "trace_id": row["trace_id"],
        "entity_type": row["entity_type"],
        "entity_id": row["entity_id"],
        "risk_score": row["risk_score"] if row["risk_score"] is not None else "",
        "attributes": json.dumps(row["attributes"], ensure_ascii=False, sort_keys=True),
        "metrics": json.dumps(row["metrics"], ensure_ascii=False, sort_keys=True),
        "created_at": row["created_at"].isoformat(),
        "updated_at": row["updated_at"].isoformat(),
    }


def manifest_filters(filters):
    manifest_filters = {}
    for key, value in filters.items():
        # ``engine``/``count`` describe how the export ran, not what it
        # selected; the manifest records the engine it actually used itself.
        if key in {"user", "date_from", "date_to", "engine", "count"}:
            continue
        if hasattr(value, "isoformat"):
            manifest_filters[key] = value.isoformat()
        else:
            manifest_filters[key] = value
    return manifest_filters


def _json_safe(value):
    if isinstance(value, dict):
        return {str(key): _json_safe(item) for key, item in value.items()}
    if isinstance(value, (list, tuple)):
        return [_json_safe(item) for item in value]
    if hasattr(value, "isoformat"):
        return value.isoformat()
    if isinstance(value, uuid.UUID):
        return str(value)
    try:
        json.dumps(value)
    except (TypeError, ValueError):
        return str(value)
    return value


def _client_ip(request):
    forwarded_for = request.META.get("HTTP_X_FORWARDED_FOR", "")
    if forwarded_for:
        return forwarded_for.split(",")[0].strip() or None
    return request.META.get("REMOTE_ADDR") or None


def _user_agent(request):
    return request.META.get("HTTP_USER_AGENT", "")[:512]
