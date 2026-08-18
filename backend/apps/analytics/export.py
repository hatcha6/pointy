"""PostgreSQL ``COPY``-backed analytics export.

The ORM export in ``services.py`` formats every row in Python: a keyset query
per batch, a dict per row, ``json.dumps`` per JSON column, ``csv.DictWriter``
per line. That costs tens of microseconds per row, which is invisible at a
thousand rows and fatal at a hundred million — a month of one busy shop's
telemetry took long enough that nobody ever saw an export finish.

This module removes Python from the row path entirely. Postgres formats the
rows itself (``COPY ... TO STDOUT``) and we pump the resulting bytes straight
into the zip member, so the export runs at the speed of the sequential scan and
the compressor instead of the speed of the interpreter. Two consequences worth
knowing:

* There is **no ``ORDER BY``**. Ordering a full-table export forces either a
  sort or a random-order index scan; an unordered sequential scan is the whole
  point. Rows come back in physical order, which for an append-only telemetry
  table is close to insertion order anyway. Callers that need determinism sort
  the export, not the database.
* The row count is only known when the COPY finishes, so it lands in the zip
  manifest rather than in a response header (see ``views.py``).

The output is byte-compatible with the ORM path: same columns, same order, same
value formatting. ``services.iter_events_export_zip`` picks between the two, so
SQLite (tests, dev) still works.
"""

import json
import zipfile

from django.conf import settings
from django.db import connections
from django.db.models import TextField, Value
from django.db.models.expressions import RawSQL
from django.db.models.functions import Coalesce

from .models import AnalyticsEvent


#: Formats the export endpoint accepts. ``json`` is a single JSON array (what
#: the app has always produced); ``jsonl`` is newline-delimited JSON, which is
#: what you actually want at this scale — every streaming tool reads it, and it
#: needs no array wrapping pass over the bytes.
ANALYTICS_EXPORT_FORMATS = ("csv", "json", "jsonl")

#: Compressed bytes buffered before the generator hands a chunk to the response.
EXPORT_STREAM_CHUNK_BYTES = 256 * 1024

#: Bytes pulled from the COPY stream at a time.
_COPY_READ_BYTES = 256 * 1024

# NDJSON comes out of Postgres through COPY's CSV formatter with delimiter and
# quote set to control characters that JSON text can never contain: ``to_json``
# escapes every character below U+0020 as ``\uXXXX``. With no delimiter, quote,
# newline or carriage return in the field, the CSV writer emits it verbatim —
# so we get one untouched JSON document per line and pay no un-escaping pass.
# (COPY's ``text`` format would double every backslash; CSV's default quote
# would double every ``"``. Both would need a rewrite of every byte.)
_NDJSON_DELIMITER = "\\x02"
_NDJSON_QUOTE = "\\x01"


def copy_export_enabled():
    """Whether the COPY engine may be used at all (escape hatch for ops)."""
    return getattr(settings, "POINTY_ANALYTICS_EXPORT_COPY", True)


def copy_export_supported(alias="default"):
    """True when ``alias`` is a Postgres connection the COPY engine can drive."""
    return copy_export_enabled() and connections[alias].vendor == "postgresql"


def _quote(name, connection):
    return connection.ops.quote_name(name)


def _event_column(field_name, connection):
    field = AnalyticsEvent._meta.get_field(field_name)
    table = _quote(AnalyticsEvent._meta.db_table, connection)
    return f"{table}.{_quote(field.column, connection)}"


def _raw(sql):
    return RawSQL(sql, (), output_field=TextField())


def _iso(column):
    """ISO-8601 rendering byte-identical to Python's ``datetime.isoformat()``.

    Getting this exactly right matters: it is the only thing standing between
    "the fast export is a drop-in" and "every timestamp in your archive changed
    shape". Neither obvious spelling works — ``timestamptz::text`` gives
    ``2026-05-20 09:00:00+00`` (space, truncated offset), and Postgres' JSON
    encoder drops trailing zeros from the microseconds where Python always pads
    to six digits. So format it explicitly, and reproduce Python's one piece of
    conditional behaviour: the fractional part disappears entirely at a whole
    second, rather than becoming ``.000000``.
    """
    utc = f"({column} AT TIME ZONE 'UTC')"
    # mod(), not ``%``: psycopg reads a lone ``%`` in the statement as the
    # start of a parameter placeholder and refuses to run it.
    fraction = f"mod(EXTRACT(MICROSECONDS FROM {utc})::bigint, 1000000)"
    return (
        f"""to_char({utc}, 'YYYY-MM-DD"T"HH24:MI:SS')"""
        f""" || CASE WHEN {fraction} = 0 THEN '' ELSE to_char({utc}, '.US') END"""
        f""" || '+00:00'"""
    )


def _nullable_number_or_blank(column):
    """``5`` when set, ``""`` when NULL — the shape the JSON export has always
    had for ``received_by_id`` and ``risk_score`` (the ORM path wrote
    ``row[...] or ""``). Typed ``json`` so the row encoder embeds it as-is."""
    return f"CASE WHEN {column} IS NULL THEN '\"\"'::json ELSE to_json({column}) END"


def export_annotations(*, json_mode, connection):
    """The export's output columns, in order, as Django expressions.

    Everything is an annotation on purpose. ``QuerySet.values()`` emits
    concrete fields first and annotations afterwards, so a mix of the two would
    silently reorder the columns; with annotations only, the SELECT order is
    exactly the order given here. ``received_by_username`` stays a real ORM
    expression so Django writes the LEFT JOIN (and its alias) itself.
    """
    column = {
        name: _event_column(name, connection)
        for name in (
            "id",
            "client_event_id",
            "event_type",
            "name",
            "severity",
            "source",
            "occurred_at",
            "received_by",
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
    }

    annotations = {
        "id": _raw(column["id"]),
        # uuid::text so the JSON encoder writes a plain string, matching
        # ``str(row["client_event_id"])`` on the ORM path.
        "client_event_id": _raw(f"{column['client_event_id']}::text"),
        "event_type": _raw(column["event_type"]),
        "name": _raw(column["name"]),
        "severity": _raw(column["severity"]),
        "source": _raw(column["source"]),
        "occurred_at": _raw(_iso(column["occurred_at"])),
        "received_by_id": _raw(
            _nullable_number_or_blank(column["received_by"])
            if json_mode
            else column["received_by"]
        ),
        "received_by_username": Coalesce(
            "received_by__username", Value(""), output_field=TextField()
        ),
        "session_id": _raw(column["session_id"]),
        "device_id": _raw(column["device_id"]),
        "installation_id": _raw(column["installation_id"]),
        "app_version": _raw(column["app_version"]),
        "platform": _raw(column["platform"]),
        "request_path": _raw(column["request_path"]),
        # host(), not ::text: Postgres stores the column as ``inet`` and renders
        # it with its netmask ("192.168.1.42/32"), which is not what the ORM
        # path (or anyone reading the export) means by an IP address.
        "ip_address": _raw(f"COALESCE(host({column['ip_address']}), '')"),
        "user_agent": _raw(column["user_agent"]),
        "trace_id": _raw(column["trace_id"]),
        "entity_type": _raw(column["entity_type"]),
        "entity_id": _raw(column["entity_id"]),
        "risk_score": _raw(
            _nullable_number_or_blank(column["risk_score"])
            if json_mode
            else column["risk_score"]
        ),
        # Both exports carry the JSON columns as encoded TEXT, not as nested
        # objects — ``::text`` keeps that contract on both paths.
        "attributes": _raw(f"{column['attributes']}::text"),
        "metrics": _raw(f"{column['metrics']}::text"),
        "created_at": _raw(_iso(column["created_at"])),
        "updated_at": _raw(_iso(column["updated_at"])),
    }
    return annotations


#: Annotation aliases are prefixed because half the export's columns ("id",
#: "name", "source", ...) are also model field names, and Django refuses an
#: annotation that shadows a field. An outer SELECT renames them back, so the
#: CSV header and the JSON keys still read exactly as they always have.
_ALIAS_PREFIX = "pointy_export_"


def build_export_sql(queryset, *, json_mode, connection):
    """Compile ``queryset`` into the SELECT the COPY will stream.

    Only the filters come from the caller's queryset; the model's default
    ordering is dropped (``order_by()``) because sorting a whole-table export
    is exactly the cost this engine exists to avoid.
    """
    annotations = export_annotations(json_mode=json_mode, connection=connection)
    aliased = {f"{_ALIAS_PREFIX}{name}": value for name, value in annotations.items()}
    inner_sql, params = (
        queryset.order_by().annotate(**aliased).values(*aliased).query.sql_with_params()
    )
    projection = ", ".join(
        f"{_quote(f'{_ALIAS_PREFIX}{name}', connection)} AS {_quote(name, connection)}"
        for name in annotations
    )
    sql = f"SELECT {projection} FROM ({inner_sql}) {_quote('pointy_export', connection)}"
    return sql, params, tuple(annotations)


def build_copy_statement(inner_sql, *, export_format):
    if export_format == "csv":
        return f"COPY ({inner_sql}) TO STDOUT WITH (FORMAT csv, HEADER)"
    return (
        f"COPY (SELECT to_json(t) FROM ({inner_sql}) t) TO STDOUT "
        f"WITH (FORMAT csv, DELIMITER E'{_NDJSON_DELIMITER}', "
        f"QUOTE E'{_NDJSON_QUOTE}')"
    )


def wrap_ndjson_as_json_array(chunks):
    """Turn a stream of NDJSON bytes into one JSON array, at memcpy speed.

    Every row is a complete JSON document on its own line and no row can
    contain a newline, so the whole transformation is "newline -> comma
    newline" minus the final terminator. One byte of lookbehind is enough to
    hold that terminator back, and ``bytes.replace`` runs in C — the array
    wrapper costs a fraction of what the compressor does.
    """
    yield b"[\n"
    carry = b""
    for chunk in chunks:
        if not chunk:
            continue
        buffer = carry + chunk
        carry = buffer[-1:]
        body = buffer[:-1]
        if body:
            yield body.replace(b"\n", b",\n")
    yield b"\n]\n"


def zip_compression(compression):
    """Map the ``compression`` filter onto zipfile's knobs.

    Deflate at level 1 is the default: telemetry compresses ~5-10x, so on a
    LAN or a USB drive the compressor pays for itself. ``none`` exists for the
    case where the destination is faster than the CPU (a local NVMe copy on a
    weak shop PC), where compressing is the only thing left slowing it down.
    """
    if compression == "none":
        return zipfile.ZIP_STORED, None
    return zipfile.ZIP_DEFLATED, 1


def iter_events_export_zip_copy(
    *,
    queryset,
    filters,
    exported_by,
    exported_at,
    alias="default",
):
    """Stream the export zip, formatting every row inside Postgres.

    Uses the calling thread's own connection rather than opening one. Under
    ASGI the generator is consumed on ``aiter_in_thread``'s dedicated bridge
    thread, so that is already a private connection which the bridge closes
    when the stream ends; under WSGI it is the request's connection, still
    open for as long as the streaming response is being iterated. A connection
    created here instead would sit outside any ambient transaction — which
    also means tests (wrapped in one, never committed) would export nothing.
    """
    export_format = filters.get("format", "csv")
    compression, compresslevel = zip_compression(filters.get("compression", "deflate"))
    data_filename = f"analytics_events.{export_format}"

    connection = connections[alias]

    from .services import ZipStreamSink, manifest_filters

    sink = ZipStreamSink()
    event_count = 0
    sql, params, _columns = build_export_sql(
        queryset, json_mode=export_format != "csv", connection=connection
    )
    statement = build_copy_statement(sql, export_format=export_format)

    with zipfile.ZipFile(
        sink, "w", compression=compression, compresslevel=compresslevel
    ) as archive:
        # force_zip64: the member header cannot be rewritten on an
        # unseekable sink, so a >4GB member has to be declared up front.
        with archive.open(data_filename, mode="w", force_zip64=True) as member:
            with connection.cursor() as cursor:
                with cursor.cursor.copy(statement, params) as copy:
                    rows = _iter_copy_bytes(copy)
                    if export_format == "json":
                        rows = wrap_ndjson_as_json_array(rows)
                    for chunk in rows:
                        member.write(chunk)
                        if sink.pending >= EXPORT_STREAM_CHUNK_BYTES:
                            yield from sink.drain()
                # The COPY command tag carries the definitive row count.
                event_count = max(cursor.cursor.rowcount, 0)

        archive.writestr(
            "manifest.json",
            json.dumps(
                {
                    "generated_at": exported_at.isoformat(),
                    "generated_by": {
                        "id": getattr(exported_by, "id", None),
                        "username": getattr(exported_by, "username", ""),
                    },
                    "event_count": event_count,
                    "engine": "postgres-copy",
                    "ordered": False,
                    "filters": manifest_filters(filters),
                    "files": [data_filename],
                },
                ensure_ascii=False,
                indent=2,
            ),
        )
    yield from sink.drain()


def _iter_copy_bytes(copy, read_bytes=_COPY_READ_BYTES):
    """Yield the COPY stream as ``bytes`` in bounded pieces.

    psycopg hands back memoryviews over a reusable buffer, so each one is
    copied out before the next read invalidates it.
    """
    while True:
        block = copy.read()
        if not block:
            return
        view = memoryview(block)
        for start in range(0, len(view), read_bytes):
            yield bytes(view[start : start + read_bytes])


def estimate_export_rows(queryset, *, alias="default"):
    """Planner row estimate for an export, in a millisecond-scale query.

    The export used to run ``COUNT(*)`` before the first byte so the response
    could carry an exact row count. On a table with a month of telemetry in it
    that count is a full scan — minutes of dead air before the download even
    starts, for a number nothing depends on. Postgres already keeps an estimate
    for exactly this shape of question, so ask the planner instead and let the
    zip manifest carry the exact count once the COPY has actually run.

    Returns ``None`` when no estimate is available (non-Postgres, or an EXPLAIN
    that came back in a shape we don't recognise) — callers just omit the
    header.
    """
    connection = connections[alias]
    if connection.vendor != "postgresql":
        return None
    sql, params = queryset.order_by().values("id").query.sql_with_params()
    try:
        with connection.cursor() as cursor:
            cursor.execute(f"EXPLAIN (FORMAT JSON) {sql}", params)
            plan = cursor.fetchone()[0]
    except Exception:
        return None
    if isinstance(plan, str):
        plan = json.loads(plan)
    try:
        return int(plan[0]["Plan"]["Plan Rows"])
    except (KeyError, IndexError, TypeError, ValueError):
        return None
