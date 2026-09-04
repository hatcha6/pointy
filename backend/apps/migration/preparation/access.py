"""Convert a Microsoft Access database into SQLite, with progress.

This is ``scripts/mdb_to_sqlite.sh`` brought into the app. That script worked —
it is how Sufian's 1.5 GB ``db.mdb`` became a readable file — but it ran on
somebody's laptop, which meant a migration required a person who knew about it.
Now the server does it, and the owner sees it happen.

Mechanics, unchanged from the script because they are the ones that survived
contact with a real file:

* ``mdb-schema`` first, then one ``mdb-export`` per table. Table at a time, never
  the whole database at once — a 4.6 million-row audit log will not fit anywhere.
* Binary (OLE/attachment) columns are stripped. They are the bulk of the bytes in
  a typical Access file and no connector reads them.
* Journalling off and a large page cache: this database is written once, read
  once, and deleted. Durability during the write buys nothing — if the process
  dies the whole conversion restarts anyway.

The bytes are pumped through this process rather than by a shell pipeline so we
can count them and report progress; ``sqlite3`` parses the SQL because it does it
correctly, and text values in a legacy Arabic database contain quotes, semicolons
and newlines that naive line-splitting gets wrong.
"""

from __future__ import annotations

import shutil
import subprocess
import tempfile
import time
from pathlib import Path

from django.conf import settings

from ..exceptions import MigrationError

_PRAGMAS = (
    "PRAGMA journal_mode=OFF;\n"
    "PRAGMA synchronous=OFF;\n"
    "PRAGMA temp_store=MEMORY;\n"
    "PRAGMA cache_size=-200000;\n"
)
_PUMP_CHUNK = 1 << 16
_TOOLS = ("mdb-tables", "mdb-schema", "mdb-export", "sqlite3")


class ConversionError(MigrationError):
    pass


def tools_available() -> bool:
    return all(shutil.which(tool) for tool in _TOOLS)


def require_tools() -> None:
    missing = [tool for tool in _TOOLS if not shutil.which(tool)]
    if missing:
        raise ConversionError(
            "أدوات تحويل ملفات Access غير متوفرة على الخادم "
            f"({', '.join(missing)})."
        )


def _run(argv, *, timeout=120) -> str:
    try:
        result = subprocess.run(  # noqa: S603 - fixed argv, no shell
            argv, capture_output=True, timeout=timeout, check=False
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise ConversionError(f"فشل تشغيل {argv[0]}: {exc}") from exc
    if result.returncode != 0:
        detail = result.stderr.decode("utf-8", "replace").strip()[:300]
        raise ConversionError(f"فشل {argv[0]}: {detail or result.returncode}")
    return result.stdout.decode("utf-8", "replace")


def list_tables(source: Path) -> list[str]:
    output = _run(["mdb-tables", "-1", str(source)])
    return [line.strip() for line in output.splitlines() if line.strip()]


def convert(source: Path, destination: Path, *, tracker=None, stage_key="convert") -> dict:
    """Convert ``source`` (.mdb/.accdb) into a new SQLite file at ``destination``.

    Returns a stats dict: tables converted, tables that failed, bytes streamed.
    A table that fails to export does **not** abort the conversion: legacy Access
    files routinely carry one corrupt or exotically-typed table that nothing
    reads, and losing the other sixty because of it helps nobody. Which tables
    were lost is reported, and compatibility detection afterwards is what decides
    whether the ones that matter made it.
    """
    require_tools()
    if destination.exists():
        destination.unlink()

    tables = list_tables(source)
    if not tables:
        raise ConversionError("لا توجد جداول في هذا الملف.")

    _apply_schema(source, destination)

    converted: list[str] = []
    failed: list[str] = []
    total_bytes = 0
    for index, table in enumerate(tables):
        if tracker is not None:
            tracker.progress(
                stage_key,
                percent=int(index / len(tables) * 100),
                detail=f"الجدول {index + 1} من {len(tables)} · {table}",
                counts={"tables_total": len(tables), "tables_done": index},
            )
        try:
            total_bytes += _export_table(source, destination, table, tracker, stage_key, index, len(tables))
        except ConversionError:
            failed.append(table)
        else:
            converted.append(table)

    if not converted:
        raise ConversionError("تعذر تحويل أي جدول من هذا الملف.")

    stats = {
        "tables_total": len(tables),
        "tables_converted": len(converted),
        "tables_failed": failed,
        "bytes_streamed": total_bytes,
    }
    if tracker is not None:
        detail = f"{len(converted)} جدول"
        if failed:
            detail += f" · تعذر تحويل {len(failed)}"
        tracker.done(stage_key, detail=detail, counts=stats)
    return stats


def _apply_schema(source: Path, destination: Path) -> None:
    schema = _run(["mdb-schema", str(source), "sqlite"], timeout=300)
    _feed_sqlite(destination, _PRAGMAS + schema)


def _export_table(source, destination, table, tracker, stage_key, index, table_count) -> int:
    """Stream one table's INSERTs from mdb-export into sqlite3. Returns bytes."""
    timeout = settings.POINTY_MIGRATION_CONVERT_TABLE_TIMEOUT_SECONDS
    deadline = time.monotonic() + timeout
    export_argv = [
        "mdb-export",
        "-I", "sqlite",
        "-S", "500",          # SQL-escape, not shell-escape
        "-b", "strip",        # drop OLE/binary columns
        "-D", "%Y-%m-%d",
        "-T", "%Y-%m-%d %H:%M:%S",
        str(source),
        table,
    ]
    streamed = 0
    with tempfile.TemporaryFile() as export_err, tempfile.TemporaryFile() as sqlite_err:
        # stderr goes to files, never to a pipe: a pipe nobody drains is how a
        # subprocess pair deadlocks halfway through a large table.
        export = subprocess.Popen(  # noqa: S603
            export_argv, stdout=subprocess.PIPE, stderr=export_err
        )
        sqlite = subprocess.Popen(  # noqa: S603
            ["sqlite3", "-bail", str(destination)],
            stdin=subprocess.PIPE,
            stdout=subprocess.DEVNULL,
            stderr=sqlite_err,
        )
        try:
            sqlite.stdin.write((_PRAGMAS + "BEGIN;\n").encode())
            while True:
                if time.monotonic() > deadline:
                    raise ConversionError(f"تجاوز تحويل الجدول {table} الوقت المسموح.")
                chunk = export.stdout.read(_PUMP_CHUNK)
                if not chunk:
                    break
                sqlite.stdin.write(chunk)
                streamed += len(chunk)
                if tracker is not None and streamed % (64 << 20) < _PUMP_CHUNK:
                    tracker.progress(
                        stage_key,
                        percent=int(index / table_count * 100),
                        detail=(
                            f"الجدول {index + 1} من {table_count} · {table} · "
                            f"{streamed // (1 << 20)} ميجابايت"
                        ),
                    )
            sqlite.stdin.write(b"COMMIT;\n")
            sqlite.stdin.close()
        except (BrokenPipeError, OSError) as exc:
            _terminate(export, sqlite)
            raise ConversionError(f"فشل تصدير الجدول {table}: {exc}") from exc
        finally:
            export.stdout.close()

        export_code = export.wait()
        sqlite_code = sqlite.wait()
        if export_code != 0 or sqlite_code != 0:
            raise ConversionError(
                f"فشل تصدير الجدول {table}: "
                f"{_tail(sqlite_err) or _tail(export_err) or 'رمز الخطأ ' + str(sqlite_code)}"
            )
    return streamed


def _tail(handle, limit=300) -> str:
    try:
        handle.seek(0)
        return handle.read().decode("utf-8", "replace").strip()[-limit:]
    except OSError:
        return ""


def _terminate(*processes) -> None:
    for process in processes:
        try:
            process.kill()
        except OSError:
            pass


def _feed_sqlite(destination: Path, script: str) -> None:
    try:
        result = subprocess.run(  # noqa: S603
            ["sqlite3", "-bail", str(destination)],
            input=script.encode(),
            capture_output=True,
            timeout=600,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise ConversionError(f"فشل إنشاء قاعدة البيانات: {exc}") from exc
    if result.returncode != 0:
        detail = result.stderr.decode("utf-8", "replace").strip()[:300]
        raise ConversionError(f"فشل إنشاء الجداول: {detail}")
