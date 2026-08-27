"""Database export and import for the backup archive.

``dumpdata``/``loaddata`` were the original pair here, and they do not survive
contact with a real shop. A JSON fixture of a first client's database (779k
orders, 2.1M order lines) is tens of gigabytes and ``loaddata`` restores it one
``Model.save()`` at a time — so the archive is slow to write, enormous to keep on
a USB stick, and a restore is measured in hours or days. A backup nobody can
restore inside a trading day is not a backup.

This module writes the same data with Postgres' own bulk path, ``COPY``, through
psycopg. No external ``pg_dump`` binary (the runtime image deliberately ships no
shell and no package manager), and ``COPY`` is a single statement per table, so
it works unchanged through PgBouncer's transaction pooling — the thing that broke
the fixture path in the field.

Layout inside the archive::

    pointy-backup/database/index.json     tables, columns, row counts, digests
    pointy-backup/database/0001_<table>   COPY ... TO STDOUT text payload
    pointy-backup/database/0002_<table>
    ...

One entry per table makes verification specific: a short or corrupt table names
itself instead of failing the whole archive anonymously.

Restore runs in one transaction. Django declares its foreign keys ``DEFERRABLE
INITIALLY DEFERRED``, so the loads do not have to be ordered — every constraint
is checked once at commit, which is also what makes a partial restore impossible
to commit.

SQLite (development, and the test suite's fast path) has no ``COPY``; there the
fixture path is still used, and archives written by older releases are still
restored through it, keyed off the manifest.
"""

import hashlib
import logging

from django.apps import apps
from django.conf import settings
from django.core.management import call_command
from django.core.management.color import no_style
from django.db import DEFAULT_DB_ALIAS, connections, transaction

logger = logging.getLogger(__name__)

DATABASE_DIR_NAME = "database"
DATABASE_INDEX_NAME = "index.json"
COPY_FORMAT = "pointy-pgcopy-v1"
FIXTURE_FORMAT = "django-fixture-json"
LEGACY_DUMP_NAME = "database.json"
COPY_CHUNK_BYTES = 1024 * 1024

# Tables deliberately left out of the archive. Every one of these is machine
# exhaust rather than a business record, and together they are the overwhelming
# majority of the bytes: on the first client's database the analytics table alone
# was 86% of a 6.4 GB dump. Excluding them is only safe while nothing that IS
# backed up points at them -- `_assert_exclusions_are_safe` enforces exactly that
# at dump time, so this list can be tuned without silently producing an archive
# that fails its own restore on a foreign key.
DEFAULT_EXCLUDED_TABLES = (
    "analytics_analyticsevent",
    "core_idempotencyrecord",
    "printing_printjobevent",
    "django_session",
)
# Never truncated on restore, and never dumped: the row driving the restore lives
# here, and wiping content types out from under a running process breaks the
# generic relations still resolving during the load.
PRESERVED_TABLES = ("core_systemmaintenancejob",)


class BackupDatabaseError(Exception):
    pass


def database_is_postgres(connection=None):
    connection = connection or connections[DEFAULT_DB_ALIAS]
    return connection.vendor == "postgresql"


def excluded_tables():
    configured = getattr(settings, "POINTY_BACKUP_EXCLUDED_TABLES", None)
    if configured is None:
        configured = DEFAULT_EXCLUDED_TABLES
    return {str(table).strip() for table in configured if str(table).strip()}


def managed_tables():
    """Every table the archive is responsible for, in a stable order.

    ``include_auto_created`` picks up many-to-many through tables, which hold
    real data (a product's categories, a discount's targets) and are invisible in
    ``get_models()`` without it. ``django_migrations`` is deliberately absent:
    it is not in the app registry, and a restore must keep the target's own
    migration history rather than adopt the archive's.
    """
    tables = set()
    for model in apps.get_models(include_auto_created=True):
        if not model._meta.managed:
            continue
        tables.add(model._meta.db_table)
    return sorted(tables - set(PRESERVED_TABLES))


def backup_tables():
    return [table for table in managed_tables() if table not in excluded_tables()]


def _assert_exclusions_are_safe():
    """Refuse to write an archive whose own restore would fail on a foreign key.

    Dropping a table is safe only when nothing that IS kept references it.
    ``printing_printjobevent`` qualifies (its parent references it in no
    direction); ``printing_printjob`` would not, because print audit events carry
    its id. A nullable foreign key does not make it safe either -- the retained
    rows still hold the real ids, and a deferred constraint check at commit will
    reject them.
    """
    excluded = excluded_tables()
    if not excluded:
        return
    kept = set(backup_tables())
    offenders = []
    for model in apps.get_models(include_auto_created=True):
        if not model._meta.managed or model._meta.db_table not in kept:
            continue
        for field in model._meta.local_fields:
            remote = getattr(field, "remote_field", None)
            if remote is None or remote.model is None:
                continue
            target_table = remote.model._meta.db_table
            if target_table in excluded:
                offenders.append(
                    f"{model._meta.db_table}.{field.column} -> {target_table}"
                )
    if offenders:
        raise BackupDatabaseError(
            "Backup exclusion list is unsafe; these retained columns reference "
            "excluded tables and the restore would fail: " + ", ".join(sorted(offenders))
        )


def table_columns(table, connection=None):
    connection = connection or connections[DEFAULT_DB_ALIAS]
    with connection.cursor() as cursor:
        cursor.execute(
            """
            SELECT column_name
            FROM information_schema.columns
            WHERE table_schema = current_schema() AND table_name = %s
              AND is_generated = 'NEVER'
            ORDER BY ordinal_position
            """,
            [table],
        )
        return [row[0] for row in cursor.fetchall()]


def _quote(connection, identifier):
    return connection.ops.quote_name(identifier)


def _psycopg_cursor(cursor):
    """The driver cursor beneath Django's wrapper -- ``copy()`` lives there."""
    inner = getattr(cursor, "cursor", None)
    if inner is None or not hasattr(inner, "copy"):
        raise BackupDatabaseError("The database driver does not support COPY.")
    return inner


def write_database_export(archive, *, archive_root, progress=None):
    """Stream every backed-up table into ``archive`` and return the index.

    ``progress(fraction)`` is called with 0..1 across tables so the caller can
    map it onto whatever slice of the job's progress bar it owns.
    """
    connection = connections[DEFAULT_DB_ALIAS]
    if not database_is_postgres(connection):
        raise BackupDatabaseError("COPY export requires PostgreSQL.")

    _assert_exclusions_are_safe()
    tables = backup_tables()
    entries = []
    for index, table in enumerate(tables, start=1):
        columns = table_columns(table, connection)
        if not columns:
            # A table in the app registry with no columns in this database means
            # migrations and code disagree. Skipping it silently would produce an
            # archive that looks complete, so refuse instead.
            raise BackupDatabaseError(f"Table {table} is missing from the database.")
        entry_name = f"{archive_root}/{DATABASE_DIR_NAME}/{index:04d}_{table}"
        rows, digest, byte_count = _copy_table_into_archive(
            archive=archive,
            entry_name=entry_name,
            table=table,
            columns=columns,
            connection=connection,
        )
        entries.append(
            {
                "table": table,
                "entry": entry_name,
                "columns": columns,
                "rows": rows,
                "bytes": byte_count,
                "sha256": digest,
            }
        )
        if progress is not None:
            progress(index / len(tables))
    return {
        "format": COPY_FORMAT,
        "tables": entries,
        "excluded_tables": sorted(excluded_tables()),
    }


def _copy_table_into_archive(*, archive, entry_name, table, columns, connection):
    column_sql = ", ".join(_quote(connection, column) for column in columns)
    statement = (
        f"COPY {_quote(connection, table)} ({column_sql}) TO STDOUT "
        "WITH (FORMAT text, ENCODING 'UTF8')"
    )
    digest = hashlib.sha256()
    rows = 0
    byte_count = 0
    with connection.cursor() as cursor:
        driver_cursor = _psycopg_cursor(cursor)
        with archive.open(entry_name, "w") as entry:
            with driver_cursor.copy(statement) as copy:
                for chunk in copy:
                    data = bytes(chunk)
                    if not data:
                        continue
                    # COPY text format escapes newlines inside values as "\n",
                    # so one physical newline is exactly one row.
                    rows += data.count(b"\n")
                    byte_count += len(data)
                    digest.update(data)
                    entry.write(data)
    return rows, digest.hexdigest(), byte_count


def write_fixture_export(database_dump_path, *, excludes):
    """The SQLite/dev path: a Django fixture, as before."""
    with database_dump_path.open("w", encoding="utf-8") as output:
        call_command(
            "dumpdata",
            exclude=excludes,
            use_natural_foreign_keys=True,
            verbosity=0,
            stdout=output,
        )


def verify_database_export(archive, index):
    """Re-read every table entry and check it against the index.

    ``ZipFile.testzip`` already proves each entry's CRC, which catches a
    truncated or corrupted archive. This is the stronger claim: that the bytes
    which came back are the rows that went in, table by table, so a short table
    names itself instead of surfacing as a mystery at restore time.
    """
    problems = []
    for entry in index.get("tables", []):
        name = entry["entry"]
        digest = hashlib.sha256()
        rows = 0
        byte_count = 0
        try:
            with archive.open(name, "r") as handle:
                while True:
                    chunk = handle.read(COPY_CHUNK_BYTES)
                    if not chunk:
                        break
                    rows += chunk.count(b"\n")
                    byte_count += len(chunk)
                    digest.update(chunk)
        except KeyError:
            problems.append(f"{entry['table']}: missing from the archive")
            continue
        if rows != entry["rows"]:
            problems.append(
                f"{entry['table']}: {rows} rows in the archive, {entry['rows']} expected"
            )
        if byte_count != entry["bytes"]:
            problems.append(
                f"{entry['table']}: {byte_count} bytes, {entry['bytes']} expected"
            )
        if digest.hexdigest() != entry["sha256"]:
            problems.append(f"{entry['table']}: checksum mismatch")
    return problems


def restore_database_export(archive, index, *, progress=None):
    """Truncate and reload every backed-up table inside one transaction.

    Foreign keys are deferred to commit, so table order does not matter and a
    restore that fails part way cannot leave the shop with half its data: the
    transaction rolls back to the pre-restore state.
    """
    connection = connections[DEFAULT_DB_ALIAS]
    if not database_is_postgres(connection):
        raise BackupDatabaseError("COPY restore requires PostgreSQL.")

    entries = index.get("tables", [])
    if not entries:
        raise BackupDatabaseError("Backup archive has no database tables.")

    with transaction.atomic():
        with connection.cursor() as cursor:
            cursor.execute("SET CONSTRAINTS ALL DEFERRED")
        _truncate_tables([entry["table"] for entry in entries], connection)
        for position, entry in enumerate(entries, start=1):
            _copy_table_from_archive(
                archive=archive,
                entry=entry,
                connection=connection,
            )
            if progress is not None:
                progress(position / len(entries))
        _reset_sequences(connection)


def _truncate_tables(tables, connection):
    quoted = ", ".join(_quote(connection, table) for table in tables)
    with connection.cursor() as cursor:
        # CASCADE also empties the excluded telemetry tables, because they hold
        # foreign keys into tables being replaced -- which is what should happen:
        # analytics rows pointing at users from a database that no longer exists
        # are not worth keeping. `core_systemmaintenancejob` survives, because it
        # records the initiating user as a plain integer rather than a foreign
        # key, so the row driving this restore is not cascaded out from under it.
        #
        # RESTART IDENTITY is deliberately absent: sequences are reset from the
        # restored data afterwards, which is correct even for tables the archive
        # does not carry.
        cursor.execute(f"TRUNCATE TABLE {quoted} CASCADE")


def _copy_table_from_archive(*, archive, entry, connection):
    table = entry["table"]
    _assert_schema_accepts(table, entry["columns"], connection)
    column_sql = ", ".join(_quote(connection, column) for column in entry["columns"])
    statement = (
        f"COPY {_quote(connection, table)} ({column_sql}) FROM STDIN "
        "WITH (FORMAT text, ENCODING 'UTF8')"
    )
    with connection.cursor() as cursor:
        driver_cursor = _psycopg_cursor(cursor)
        with archive.open(entry["entry"], "r") as handle:
            with driver_cursor.copy(statement) as copy:
                while True:
                    chunk = handle.read(COPY_CHUNK_BYTES)
                    if not chunk:
                        break
                    copy.write(chunk)


def _assert_schema_accepts(table, archived_columns, connection):
    """Catch schema drift before COPY does, and say which column.

    An archive taken on an older release is the normal case for a restore -- the
    shop is recovering from something, and the newest backup may predate the last
    update. Most drift is harmless (a new nullable column, a new table), and this
    lets it through. Two shapes are not, and Postgres reports both as an opaque
    failure part way through a multi-gigabyte load, so they are named here
    instead: a column the archive carries that no longer exists, and a new
    NOT NULL column with no default that the archived rows cannot fill.
    """
    with connection.cursor() as cursor:
        cursor.execute(
            """
            SELECT column_name, is_nullable, column_default, identity_generation
            FROM information_schema.columns
            WHERE table_schema = current_schema() AND table_name = %s
              AND is_generated = 'NEVER'
            """,
            [table],
        )
        columns = {
            row[0]: {
                "nullable": row[1] == "YES",
                "default": row[2],
                "identity": row[3],
            }
            for row in cursor.fetchall()
        }

    dropped = [column for column in archived_columns if column not in columns]
    if dropped:
        raise BackupDatabaseError(
            f"This backup of {table} has columns the database no longer has "
            f"({', '.join(dropped)}). It was taken on a newer version of Pointy "
            "than this one."
        )

    archived = set(archived_columns)
    unfillable = [
        name
        for name, spec in columns.items()
        if name not in archived
        and not spec["nullable"]
        and spec["default"] is None
        and spec["identity"] is None
    ]
    if unfillable:
        raise BackupDatabaseError(
            f"The database expects values for {table}.{', '.join(sorted(unfillable))} "
            "that this backup does not carry. It was taken on an older version of "
            "Pointy; restore it on that version instead."
        )


def _reset_sequences(connection):
    models = [
        model
        for model in apps.get_models(include_auto_created=True)
        if model._meta.managed and model._meta.db_table not in PRESERVED_TABLES
    ]
    statements = connection.ops.sequence_reset_sql(no_style(), models)
    if not statements:
        return
    with connection.cursor() as cursor:
        for statement in statements:
            cursor.execute(statement)
