"""Adopting a file that is already on this machine.

The app's way in is an upload. An operator sitting at the shop's own computer
with the ``.mdb`` on a USB stick does not need one, and neither does anybody
debugging a real export before a meeting — but they do need *the same*
identify → convert → prepare → detect → analyze pipeline, or the thing they
prove works is not the thing the owner will run.

So: stage the file where an upload would have put it, then hand it to
``pipeline.prepare_source``. One code path, and it is the one that is exercised.
Shared by ``import_legacy`` and ``collapse_preview`` rather than written twice.
"""

from __future__ import annotations

from pathlib import Path

from .. import storage
from ..models import MigrationSource
from . import pipeline

ACCESS_SUFFIXES = {".mdb", ".accdb"}


def adopt_and_prepare(path: Path, *, reprepare: bool = False, log=None) -> MigrationSource:
    """The prepared :class:`MigrationSource` for a local file.

    Re-uses an already-prepared source for the same filename unless
    ``reprepare`` — dry run → collapse → import against one export must not
    reconvert gigabytes three times, and the identity map on that row is what
    keeps the second pass an update rather than a duplicate.
    """
    write = log or (lambda _message: None)
    name = path.name[:120]
    existing = (
        MigrationSource.objects.filter(original_filename=name)
        .exclude(upload_state=MigrationSource.UploadState.PURGED)
        .order_by("-created_at")
        .first()
    )
    if existing is not None and existing.is_ready and not reprepare:
        write(
            f"Source #{existing.pk} already prepared — reusing it "
            "(identity map preserved, so this stays idempotent)."
        )
        return existing

    source = existing or MigrationSource.objects.create(
        name=name,
        original_filename=name,
        declared_size_bytes=path.stat().st_size,
    )
    kind = "access" if path.suffix.lower() in ACCESS_SUFFIXES else "sqlite"
    source.staged_filename = storage.staged_name(source.pk, kind)
    source.received_bytes = source.declared_size_bytes = path.stat().st_size
    source.staged_size_bytes = source.declared_size_bytes
    source.upload_state = MigrationSource.UploadState.UPLOADED
    source.save()

    destination = storage.staged_path(source)
    destination.parent.mkdir(parents=True, exist_ok=True)
    write(f"Staging {path} → {destination}")
    storage.adopt(path, destination)

    write("Preparing (convert → reconstruct → detect)…")
    pipeline.prepare_source(source)
    source.refresh_from_db()
    for stage in source.stages or []:
        write(f"  {stage['status']:>8}  {stage['label']}  {stage['detail']}")
    return source


__all__ = ["adopt_and_prepare"]
