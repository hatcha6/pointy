"""Where uploaded database files live, and how they stop living there.

Two files exist per migration and both are temporary:

* the **staged** file — exactly the bytes the owner uploaded (``.mdb``,
  ``.sqlite``). Multi-GB. Deleted the moment conversion succeeds.
* the **prepared** file — the SQLite database every connector reads. Deleted
  when the import lands, when the owner discards it, or by the TTL sweep.

Both sit under ``POINTY_MIGRATION_STAGING_ROOT`` on a named volume, not under
``/tmp`` — the container mounts a 64 MB tmpfs there, which a 1.5 GB upload fills
in seconds.

Rows keep *file names*, never absolute paths, and every name is derived from the
source's primary key rather than from anything the client sent. A filename that
came from an upload is attacker-controlled: joining one to a root is how a
``../..`` walks out of the directory. Nothing here ever does that.
"""

from __future__ import annotations

import os
import shutil
from pathlib import Path

from django.conf import settings

#: Extensions we keep on staged files, purely so an operator looking at the
#: volume can tell what a file is. Never taken from the upload's own name.
STAGED_SUFFIXES = {"access": ".mdb", "sqlite": ".sqlite"}
PREPARED_SUFFIX = ".sqlite"


def staging_root() -> Path:
    root = Path(settings.POINTY_MIGRATION_STAGING_ROOT)
    root.mkdir(parents=True, exist_ok=True)
    return root


def staged_name(source_id: int, kind: str) -> str:
    return f"source-{source_id}-raw{STAGED_SUFFIXES.get(kind, '.bin')}"


def prepared_name(source_id: int) -> str:
    return f"source-{source_id}-prepared{PREPARED_SUFFIX}"


def _resolve(name: str) -> Path | None:
    """Join ``name`` under the staging root, refusing anything that escapes it.

    Belt and braces: every caller passes a name this module generated, but the
    check is here rather than in the callers so that stays true.
    """
    if not name:
        return None
    root = staging_root().resolve()
    candidate = (root / name).resolve()
    if candidate == root or root not in candidate.parents:
        return None
    return candidate


def staged_path(source) -> Path | None:
    return _resolve(source.staged_filename)


def prepared_path(source) -> Path | None:
    return _resolve(source.prepared_filename)


def file_size(path: Path | None) -> int:
    try:
        return path.stat().st_size if path else 0
    except OSError:
        return 0


def free_space_bytes() -> int:
    try:
        return shutil.disk_usage(staging_root()).free
    except OSError:
        return 0


def delete_quietly(path: Path | None) -> int:
    """Delete ``path``, returning the bytes freed. Never raises.

    Deletion runs on the success path of an import and on a scheduled sweep;
    neither should ever be turned into a user-visible failure by a file that was
    already gone or a volume that was briefly read-only.
    """
    if path is None:
        return 0
    try:
        size = path.stat().st_size
    except OSError:
        return 0
    try:
        path.unlink()
    except OSError:
        return 0
    return size


def adopt(external: Path, destination: Path) -> None:
    """Place a file that already exists on disk into the staging root.

    Hard-links when the volume allows it (instant, and a multi-GB copy is not),
    falling back to a copy across filesystems. Used by ``import_legacy`` so an
    operator running on the shop's own machine goes through exactly the same
    pipeline as an upload, rather than a second code path that is never tested.
    """
    if destination.exists():
        destination.unlink()
    try:
        os.link(external, destination)
    except OSError:
        shutil.copy2(external, destination)


def purge_source_files(source) -> int:
    """Delete both files for one source. Returns bytes freed."""
    freed = delete_quietly(staged_path(source)) + delete_quietly(prepared_path(source))
    return freed
