"""Receiving a multi-gigabyte database over a shop's network.

A single ``POST`` of a 1.5 GB file is the wrong shape three times over: the front
door caps a request body at 100 MB, Django's form parser wants it in memory, and
a connection that drops at 94% throws away twenty minutes of a cashier's evening.
Shop networks drop connections.

So the file arrives in chunks against a durable offset:

    POST   uploads/                        → {id, chunk_size, received_bytes}
    PUT    uploads/{id}/chunk/?offset=N    → {received_bytes}
    POST   uploads/{id}/complete/          → queues preparation

``received_bytes`` is the contract. It is what the server has actually written and
``fsync``-ed, it only ever moves forward, and a client that reconnects asks for it
and continues from there. A ``PUT`` whose offset disagrees is refused with **409**
carrying the real offset rather than being appended anyway — writing a chunk at
the wrong place corrupts a database silently, and silence is the one failure mode
that must not survive here.
"""

from __future__ import annotations

import hashlib
import os
from pathlib import Path

from django.conf import settings
from django.db import transaction
from rest_framework.serializers import ValidationError

from . import storage
from .models import MigrationSource

_READ_CHUNK = 1 << 20


def chunk_size() -> int:
    """How many bytes a client should send per request.

    Clamped here, at the point it is handed out, rather than only where it is
    configured: this number has to stay under the browser front door's
    ``client_max_body_size`` (100m, deploy/onprem/web/nginx.conf), and those two
    live in different files. Over the cap, an upload fails with a bare nginx 413
    from the browser while a native till — which reaches ``edge``, where the body
    size is uncapped — carries on working. A failure that depends on how you
    opened the app is not one to leave configurable.
    """
    ceiling = getattr(settings, "POINTY_MIGRATION_MAX_CHUNK_BYTES", 64 * 1024 * 1024)
    return max(min(settings.POINTY_MIGRATION_CHUNK_BYTES, ceiling), 64 * 1024)


class OffsetConflict(Exception):
    """The client's idea of the offset and the server's disagree."""

    def __init__(self, expected):
        super().__init__(f"Expected offset {expected}.")
        self.expected = expected


def begin_upload(*, filename, size_bytes, user=None) -> MigrationSource:
    """Reserve a source row and an empty staged file."""
    size_bytes = int(size_bytes or 0)
    if size_bytes <= 0:
        raise ValidationError({"detail": "حجم الملف غير صالح."})
    maximum = settings.POINTY_MIGRATION_MAX_UPLOAD_BYTES
    if size_bytes > maximum:
        raise ValidationError(
            {"detail": f"حجم الملف أكبر من الحد المسموح ({maximum // (1 << 30)} جيجابايت)."}
        )
    free = storage.free_space_bytes()
    # Conversion needs room for the converted copy alongside the original, and
    # Fahd's reconstruction needs a third file for a while. Refusing now, with a
    # number, beats failing at 90% with "no space left on device".
    if free and free < size_bytes * 2:
        raise ValidationError(
            {
                "detail": (
                    "لا توجد مساحة كافية على الخادم لاستقبال هذا الملف "
                    f"(المتاح {free // (1 << 30)} جيجابايت، المطلوب نحو "
                    f"{max(1, size_bytes * 2 // (1 << 30))} جيجابايت)."
                )
            }
        )

    clean_name = _display_name(filename)
    source = MigrationSource.objects.create(
        name=clean_name,
        original_filename=clean_name,
        declared_size_bytes=size_bytes,
        received_bytes=0,
        upload_state=MigrationSource.UploadState.UPLOADING,
    )
    # Name the file after the row, never after anything the client sent.
    source.staged_filename = storage.staged_name(source.pk, _suffix_kind(clean_name))
    source.save(update_fields=["staged_filename", "updated_at"])

    path = storage.staged_path(source)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(b"")
    return source


def append_chunk(source: MigrationSource, offset: int, stream) -> MigrationSource:
    """Append one chunk at ``offset``. Returns the refreshed source.

    The offset check and the write happen under a row lock, so two clients (or
    one client's retry racing its own timed-out request) cannot both believe they
    own the end of the file.
    """
    with transaction.atomic():
        locked = MigrationSource.objects.select_for_update().get(pk=source.pk)
        if locked.upload_state != MigrationSource.UploadState.UPLOADING:
            raise ValidationError({"detail": "اكتمل رفع هذا الملف بالفعل."})
        if int(offset) != locked.received_bytes:
            raise OffsetConflict(locked.received_bytes)

        path = storage.staged_path(locked)
        if path is None:
            raise ValidationError({"detail": "لم نعثر على الملف المرفوع."})

        written = _append(path, stream, limit=locked.declared_size_bytes - locked.received_bytes)
        locked.received_bytes += written
        if locked.received_bytes >= locked.declared_size_bytes:
            locked.upload_state = MigrationSource.UploadState.UPLOADED
        locked.save(update_fields=["received_bytes", "upload_state", "updated_at"])
    return locked


def _append(path: Path, stream, *, limit: int) -> int:
    """Write the stream to the end of ``path``, at most ``limit`` bytes.

    ``fsync`` before returning: ``received_bytes`` is a promise that these bytes
    survive a power cut, and on a shop's server behind a generator that is not a
    theoretical concern. Without it a resume would skip a range that only ever
    existed in the page cache.
    """
    written = 0
    with open(path, "ab") as handle:
        while written < limit:
            chunk = stream.read(min(_READ_CHUNK, limit - written))
            if not chunk:
                break
            handle.write(chunk)
            written += len(chunk)
        handle.flush()
        os.fsync(handle.fileno())
    return written


def complete_upload(source: MigrationSource, *, expected_checksum="") -> MigrationSource:
    """Verify the received bytes and hand the file to the preparation pipeline."""
    source.refresh_from_db()
    if source.upload_state == MigrationSource.UploadState.UPLOADING:
        raise ValidationError(
            {
                "detail": "لم يكتمل رفع الملف بعد.",
                "received_bytes": source.received_bytes,
            }
        )
    path = storage.staged_path(source)
    actual = storage.file_size(path)
    if actual != source.declared_size_bytes:
        raise ValidationError(
            {
                "detail": f"حجم الملف المستلم ({actual}) لا يطابق المتوقع "
                f"({source.declared_size_bytes})."
            }
        )

    source.staged_size_bytes = actual
    if expected_checksum:
        digest = checksum(path)
        if digest.lower() != expected_checksum.lower():
            raise ValidationError({"detail": "الملف المستلم تالف. أعد رفعه من فضلك."})
        source.checksum_sha256 = digest
    source.save(update_fields=["staged_size_bytes", "checksum_sha256", "updated_at"])
    return source


def checksum(path: Path) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(_READ_CHUNK), b""):
            digest.update(chunk)
    return digest.hexdigest()


# --- helpers ----------------------------------------------------------------
def _display_name(filename) -> str:
    """A human label from the client's filename — display only, never a path.

    Strips directory separators and NULs so the value is safe to render and to
    log. It is never joined to a directory: staged file names come from the row's
    primary key.
    """
    name = str(filename or "database").replace("\x00", "")
    name = name.replace("\\", "/").rsplit("/", 1)[-1].strip()
    return (name or "database")[:120]


def _suffix_kind(filename: str) -> str:
    lowered = filename.lower()
    if lowered.endswith((".mdb", ".accdb")):
        return "access"
    if lowered.endswith((".sqlite", ".sqlite3", ".db")):
        return "sqlite"
    return "access"
