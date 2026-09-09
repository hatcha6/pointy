#!/usr/bin/env python
"""Can a shop on the last release take this one *live*?

An on-prem update runs the new backend beside the running one, migrates, and
only then flips the front door (``deploy/onprem/README.md``). For about a minute
the OLD code serves against the NEW schema, so the schema has to be one the old
code can still write. Two ways it stops being one:

* **A NOT NULL column added to an existing table with no database default.**
  Django backfills with the *Python* default and then drops the database one, so
  the old backend's ``INSERT`` — which names no such column — fails. The fix is
  ``db_default=`` alongside ``default=``.
* **A column dropped from a table the old code still writes.** That is the
  contract half of expand/contract, and it belongs in a later release.

Neither is visible to the test suite, which only ever sees one schema at a time.
This builds both and compares them::

    backend/.venv/bin/python scripts/check_upgrade_compatibility.py v0.4.7

With no argument it uses the newest non-compat tag. Needs a running Postgres
(``make postgres``) and the backend venv; no ``psql`` client required.
"""

from __future__ import annotations

import os
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
MANAGE = ROOT / "backend" / "manage.py"
OLD_DB = "upgrade_compat_old"
NEW_DB = "upgrade_compat_new"

GREEN, RED, YELLOW, OFF = "\033[32m", "\033[31m", "\033[33m", "\033[0m"


def dsn(database: str) -> str:
    host = os.environ.get("POINTY_CHECK_DB_HOST", "127.0.0.1")
    port = os.environ.get("POINTY_CHECK_DB_PORT", "5432")
    user = os.environ.get("POINTY_CHECK_DB_USER", "postgres")
    password = os.environ.get("POINTY_CHECK_DB_PASS", "postgres")
    return f"postgres://{user}:{password}@{host}:{port}/{database}"


def connect(database: str):
    import psycopg

    return psycopg.connect(dsn(database).replace("postgres://", "postgresql://"))


def recreate(database: str) -> None:
    with connect("postgres") as conn:
        conn.autocommit = True
        with conn.cursor() as cursor:
            cursor.execute(f'DROP DATABASE IF EXISTS "{database}"')
            cursor.execute(f'CREATE DATABASE "{database}"')


def drop(database: str) -> None:
    try:
        with connect("postgres") as conn:
            conn.autocommit = True
            with conn.cursor() as cursor:
                cursor.execute(f'DROP DATABASE IF EXISTS "{database}"')
    except Exception:
        pass


def migrate(manage_py: Path, database: str) -> None:
    subprocess.run(
        [sys.executable, str(manage_py), "migrate"],
        check=True,
        env={**os.environ, "DATABASE_URL": dsn(database)},
        stdout=subprocess.DEVNULL,
    )


def read_schema(database: str):
    with connect(database) as conn, conn.cursor() as cursor:
        cursor.execute(
            "SELECT table_name, column_name, is_nullable, column_default "
            "FROM information_schema.columns WHERE table_schema = 'public'"
        )
        columns = {
            f"{table}.{column}": (nullable, default)
            for table, column, nullable, default in cursor.fetchall()
        }
        cursor.execute(
            "SELECT table_name FROM information_schema.tables "
            "WHERE table_schema = 'public'"
        )
        tables = {row[0] for row in cursor.fetchall()}
    return columns, tables


def newest_tag() -> str:
    tags = subprocess.run(
        ["git", "tag", "-l", "--sort=-v:refname"],
        cwd=ROOT,
        capture_output=True,
        text=True,
        check=True,
    ).stdout.split()
    for tag in tags:
        if "-compat" not in tag:
            return tag
    raise SystemExit("no release tag to compare against; pass one explicitly")


def main() -> int:
    ref = sys.argv[1] if len(sys.argv) > 1 else newest_tag()
    worktree = Path(tempfile.mkdtemp()) / "released"
    print(f"== Building the schema at {ref} and at the working tree ==")
    subprocess.run(
        ["git", "worktree", "add", str(worktree), ref],
        cwd=ROOT,
        check=True,
        stdout=subprocess.DEVNULL,
    )
    try:
        for database, manage_py in (
            (OLD_DB, worktree / "backend" / "manage.py"),
            (NEW_DB, MANAGE),
        ):
            recreate(database)
            migrate(manage_py, database)
        old_columns, old_tables = read_schema(OLD_DB)
        new_columns, _ = read_schema(NEW_DB)
    finally:
        subprocess.run(
            ["git", "worktree", "remove", str(worktree), "--force"],
            cwd=ROOT,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        drop(OLD_DB)
        drop(NEW_DB)

    undefaulted = sorted(
        name
        for name, (nullable, default) in new_columns.items()
        if name not in old_columns
        and name.split(".")[0] in old_tables
        and nullable == "NO"
        and default is None
    )
    dropped = sorted(set(old_columns) - set(new_columns))
    # Columns that were nullable and are not any more. Invisible to the check
    # above, which only inspects columns that are *new* — and yet it is the same
    # hazard: the older backend omits the column from its INSERT, and now the
    # database refuses it. Found the hard way in 0.5.2, where making the
    # warehouse columns required passed this script and then deadlocked against
    # a trading till on a 1.6M-row table.
    tightened = sorted(
        name
        for name, (nullable, default) in new_columns.items()
        if name in old_columns
        and old_columns[name][0] == "YES"
        and nullable == "NO"
        and default is None
    )

    print(f"\n== Writable by a {ref} backend during the flip ==")
    if undefaulted:
        print(f"  {RED}FAIL{OFF}  NOT NULL with no database default (add db_default=):")
        for name in undefaulted:
            print(f"          {name}")
    else:
        print(
            f"  {GREEN}PASS{OFF}  every added column is nullable or has a "
            f"database default"
        )

    print("\n== Columns that became required ==")
    if tightened:
        print(
            f"  {YELLOW}WARN{OFF}  nullable in {ref}, NOT NULL now — an older "
            f"backend that omits these will fail its INSERT:"
        )
        for name in tightened:
            print(f"          {name}")
        print(f"        Safe only if {ref} always writes them. If it does not,")
        print("        ship UPDATE_STRATEGY.txt containing 'restart'.")
        print("        Either way, prefer the non-blocking form: a plain")
        print("        SET NOT NULL takes ACCESS EXCLUSIVE and will queue every")
        print("        checkout behind it. See inventory/0023_warehouse_required.")
    else:
        print(f"  {GREEN}PASS{OFF}  no column became required in this release")

    print(f"\n== Columns a {ref} backend still writes ==")
    if dropped:
        print(
            f"  {YELLOW}WARN{OFF}  dropped in this release (contract belongs in "
            f"a later one):"
        )
        for name in dropped:
            print(f"          {name}")
        print("        Either keep them for one release, or ship")
        print("        UPDATE_STRATEGY.txt containing 'restart' in the bundle.")
    else:
        print(
            f"  {GREEN}PASS{OFF}  nothing an older backend writes has been dropped"
        )

    return 1 if undefaulted else 0


if __name__ == "__main__":
    raise SystemExit(main())
