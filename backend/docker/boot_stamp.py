"""Skipping the boot work a previous boot of this very image already did.

Every start of the `web` container used to run `manage.py migrate` and
`manage.py collectstatic` before the server: two whole Django imports, a
migration graph, the permission and role rebuild, a walk of every static file —
to conclude, on all but one boot per release, that there was nothing to do. On a
shop's PC that was most of the time between power-on and a till that answers.

Two stamps remember that the work was done, each kept WITH the thing it
describes, so it can never outlive it:

* **Migrations** — a comment on the ``django_migrations`` table, holding the
  image's build id and a digest of the rows in that table. It lives in the
  database, so a restored backup or a moved server carries the stamp of the
  schema it actually has; an older backup under a newer image mismatches and
  migrates. Anything that touches the migration table changes the digest.
* **Static files** — a file in ``STATIC_ROOT`` holding the build id. A wiped
  volume loses the stamp with the files.

The build id is written into the image when it is built (``/app/BUILD_ID``, a
hash of everything shipped). Without one — a source checkout, an image built
before this existed — nothing is ever skipped.

**Why a migration stamp has to be seen twice before it counts.** Some
``post_migrate`` hooks are catch-ups for a live update (see
``apps/sales/reconciliation.py``): the new backend migrates while the old one is
still serving, and the rows the old one writes in that minute are put right by
the migrate of the NEXT boot, when the managed container is rebuilt on the new
image. So the first boot of a build writes its stamp as ``pending`` and only a
later boot that finds that same stamp, on that same schema, marks it
``settled``.

**A standby never skips and never settles.** The backend a live update starts
beside the running one always migrates, and whatever it stamps stays
``pending``: the old backend is still writing beside it. The updater says so
(``POINTY_BOOT_ROLE=standby``), but an updater installed before this existed
does not, and a shop rolled back to such a release and updated again would meet
a settled stamp from the first attempt. So the container also looks for itself:
in the compose network the name ``backend`` belongs to the managed container
alone, and a backend that finds it answering from another address is standing
beside a live one.

Every failure here means "do the work": a stamp that cannot be read, parsed or
written costs a slow boot, never a wrong one. ``POINTY_FAST_BOOT=0`` turns the
whole thing off.
"""

from __future__ import annotations

import hashlib
import os
import re
import socket
import sys
import threading
from dataclasses import dataclass
from pathlib import Path

BUILD_ID_FILE = "/app/BUILD_ID"
STATIC_STAMP_NAME = ".pointy-build"
_FORMAT = "pointy-boot/1"
_BUILD_ID = re.compile(r"[0-9a-f]{16,64}")

# The digest orders by the C collation so the same rows always hash the same,
# whatever locale the cluster (or the one a backup is restored into) was
# created with.
_READ_SQL = """
SELECT obj_description('django_migrations'::regclass, 'pg_class'),
       (SELECT md5(coalesce(string_agg(app || ':' || name, ','
                   ORDER BY app COLLATE "C", name COLLATE "C"), ''))
          FROM django_migrations)
"""


def enabled() -> bool:
    return os.environ.get("POINTY_FAST_BOOT", "1").strip().lower() not in {
        "0",
        "false",
        "no",
        "off",
    }


def is_standby() -> bool:
    if os.environ.get("POINTY_BOOT_ROLE", "").strip().lower() == "standby":
        return True
    return _another_backend_is_live()


def _another_backend_is_live() -> bool:
    """Does the managed backend's name answer from an address that is not ours?

    Bounded, because a name nobody holds makes Docker's resolver ask the
    shop's upstream DNS, which on a LAN with no internet answers late or never.
    Not knowing reads as "no": the two-boot rule still stands behind it.
    """
    name = os.environ.get("POINTY_MANAGED_BACKEND_HOST", "backend").strip()
    if not name:
        return False
    found = []

    def look():
        try:
            theirs = set(socket.gethostbyname_ex(name)[2])
            ours = set(socket.gethostbyname_ex(socket.gethostname())[2])
        except OSError:
            return
        found.append(bool(theirs - ours))

    thread = threading.Thread(target=look, daemon=True)
    thread.start()
    thread.join(1.0)
    return bool(found and found[0])


def build_id() -> str:
    """This image's build id, or "" when there is none to trust."""
    path = os.environ.get("POINTY_BUILD_ID_FILE", BUILD_ID_FILE)
    try:
        value = Path(path).read_text(encoding="ascii").strip()
    except (OSError, ValueError):
        return ""
    return value if _BUILD_ID.fullmatch(value) else ""


# --- migrations -------------------------------------------------------------


@dataclass(frozen=True)
class Stamp:
    build: str
    digest: str
    settled: bool

    def render(self) -> str:
        return f"{_FORMAT} {self.build} {self.digest} {'settled' if self.settled else 'pending'}"

    @classmethod
    def parse(cls, text) -> Stamp | None:
        parts = (text or "").split()
        if len(parts) != 4 or parts[0] != _FORMAT or parts[3] not in {"settled", "pending"}:
            return None
        return cls(build=parts[1], digest=parts[2], settled=parts[3] == "settled")


@dataclass(frozen=True)
class Observed:
    """What the database said before this boot did anything to it."""

    stamp: Stamp | None
    digest: str


def can_skip_migrate(build: str, observed: Observed | None, *, standby: bool = False) -> bool:
    if standby or not build or observed is None or observed.stamp is None:
        return False
    stamp = observed.stamp
    return stamp.settled and stamp.build == build and stamp.digest == observed.digest


def stamp_after_migrate(
    build: str, before: Observed | None, digest_after: str, *, standby: bool
) -> Stamp:
    """The stamp to leave once a migrate has succeeded.

    Settled only when this migrate was itself a confirmation: the same build
    had already stamped this exact schema, and running again changed nothing.
    """
    confirmed = (
        before is not None
        and before.stamp is not None
        and before.stamp.build == build
        and before.stamp.digest == before.digest == digest_after
    )
    return Stamp(build=build, digest=digest_after, settled=confirmed and not standby)


def observe(database_url: str) -> Observed | None:
    """Read the stamp and the current digest; None when either cannot be had."""
    try:
        import psycopg

        with psycopg.connect(database_url, connect_timeout=5, autocommit=True) as connection:
            comment, digest = connection.execute(_READ_SQL).fetchone()
    except Exception:  # noqa: BLE001 - no table yet, no database: do the work
        return None
    if not digest:
        return None
    return Observed(stamp=Stamp.parse(comment), digest=digest)


def record(database_url: str, build: str, before: Observed | None, *, standby: bool) -> None:
    """Stamp the schema a successful migrate just left. Never raises."""
    try:
        import psycopg
        from psycopg import sql

        after = observe(database_url)
        if after is None:
            return
        stamp = stamp_after_migrate(build, before, after.digest, standby=standby)
        if after.stamp == stamp:
            return
        # COMMENT is a utility statement: it takes no bound parameters.
        statement = sql.SQL("COMMENT ON TABLE django_migrations IS {}").format(
            sql.Literal(stamp.render())
        )
        with psycopg.connect(database_url, connect_timeout=5, autocommit=True) as connection:
            connection.execute(statement)
    except Exception as exc:  # noqa: BLE001 - the next boot simply migrates again
        print(f"[boot] could not record the migration stamp: {exc}", file=sys.stderr, flush=True)


# --- static files -----------------------------------------------------------


def _static_stamp() -> Path | None:
    root = os.environ.get("DJANGO_STATIC_ROOT", "").strip()
    return Path(root) / STATIC_STAMP_NAME if root else None


def static_is_current(build: str) -> bool:
    path = _static_stamp()
    if not build or path is None:
        return False
    try:
        return path.read_text(encoding="ascii").strip() == build
    except (OSError, ValueError):
        return False


def record_static(build: str) -> None:
    path = _static_stamp()
    if not build or path is None:
        return
    try:
        path.write_text(build + "\n", encoding="ascii")
    except OSError as exc:
        print(f"[boot] could not record the static stamp: {exc}", file=sys.stderr, flush=True)


# --- build time -------------------------------------------------------------


def compute_build_id(roots, extra=()) -> str:
    """Hash every shipped file (path and content) under ``roots``.

    ``extra`` carries what is not a file under them: the version, and the names
    of the installed distributions (a dependency bump can change what a migrate
    or a collectstatic does without touching the backend tree).
    """
    digest = hashlib.sha256()
    for item in extra:
        digest.update(f"extra\0{item}\0".encode())
    for root in roots:
        base = Path(root)
        for path in sorted(p for p in base.rglob("*") if p.is_file()):
            if "__pycache__" in path.parts:
                continue
            digest.update(f"file\0{path.relative_to(base)}\0".encode())
            digest.update(hashlib.sha256(path.read_bytes()).digest())
    return digest.hexdigest()[:32]


def _write_build_id(target, site_packages, roots) -> None:
    distributions = sorted(p.name for p in Path(site_packages).glob("*.dist-info"))
    extra = [os.environ.get("POINTY_VERSION", ""), *distributions]
    Path(target).write_text(compute_build_id(roots, extra) + "\n", encoding="ascii")


if __name__ == "__main__":
    # python boot_stamp.py <target file> <site-packages dir> <root> [<root> ...]
    _write_build_id(sys.argv[1], sys.argv[2], sys.argv[3:])
