"""Upload bookkeeping, written off the FTP server's IO loop.

The loop only ever puts a tuple on a queue — it cannot block on the database
(see ``directory``). A side thread drains the queue: completed uploads become
``FootageUpload`` rows, renames and deletes follow the file, and each account's
last-seen facts and counters are written once per drain rather than once per
file, which matters for a DVR sending a picture a second on every channel.

If the database is away, events wait in memory and are retried; if it stays
away long enough to fill the queue, the oldest are dropped, and housekeeping's
orphan sweep adopts those files from the disk an hour later. Nothing uploaded
is ever lost to bookkeeping — only delayed.
"""

from __future__ import annotations

import logging
import os
import queue
import threading
import time
from collections import deque
from dataclasses import dataclass, field
from datetime import datetime, timedelta

from django.db import InterfaceError, OperationalError, transaction
from django.db.models import F
from django.utils import timezone

from ..archive import retention, storage
from ..archive.uploads import upload_row, upsert
from ..models import FootageUpload, FtpAccount, Recorder
from ..services import enable_surveillance_feature

logger = logging.getLogger(__name__)

QUEUE_LIMIT = 50_000
PENDING_LIMIT = 50_000
ROLLS_TTL_SECONDS = 60.0
RECENT_UNKNOWN_LIMIT = 8


@dataclass
class _Stats:
    files: int = 0
    bytes: int = 0
    last_upload_at: datetime | None = None
    last_upload_peer: str = ""
    last_upload_name: str = ""
    last_login_at: datetime | None = None
    last_login_peer: str = ""
    failed: int = 0
    failed_at: datetime | None = None
    failed_peer: str = ""


@dataclass
class UnknownLogin:
    """A login with a username no setup has — the typo an installer makes."""

    username: str
    peer: str
    at: datetime


@dataclass
class EventSink:
    _queue: queue.Queue = field(default_factory=lambda: queue.Queue(maxsize=QUEUE_LIMIT))
    _pending: list = field(default_factory=list)
    _lock: threading.Lock = field(default_factory=threading.Lock)
    dropped: int = 0
    recent_unknown: deque = field(default_factory=lambda: deque(maxlen=RECENT_UNKNOWN_LIMIT))
    _rolls: tuple | None = None
    _rolls_at: float = 0.0

    # -- called on the IO loop: never touches the database ------------------
    def _put(self, event: tuple) -> None:
        try:
            self._queue.put_nowait(event)
        except queue.Full:
            self.dropped += 1

    def uploaded(
        self,
        recorder_id: int,
        path: str,
        *,
        peer: str,
        complete: bool,
        transfer_seconds: float = 0.0,
    ) -> None:
        try:
            size = os.path.getsize(path)
        except OSError:
            size = 0
        self._put(
            ("upload", recorder_id, path, size, peer, complete, timezone.now(), transfer_seconds)
        )

    def renamed(self, recorder_id: int, source: str, target: str) -> None:
        self._put(("rename", recorder_id, source, target, timezone.now()))

    def deleted(self, recorder_id: int, path: str) -> None:
        self._put(("delete", recorder_id, path))

    def logged_in(self, recorder_id: int, peer: str) -> None:
        self._put(("login", recorder_id, peer, timezone.now()))

    def login_failed(self, recorder_id: int | None, username: str, peer: str) -> None:
        self._put(("login_failed", recorder_id, username, peer, timezone.now()))

    # -- called on the bookkeeping thread -----------------------------------
    def drain(self, *, max_events: int = 10_000) -> int:
        """Apply queued events to the database. Returns how many were applied."""
        with self._lock:
            events = self._pending
            self._pending = []
            while len(events) < max_events:
                try:
                    events.append(self._queue.get_nowait())
                except queue.Empty:
                    break
            if not events:
                return 0
            try:
                self._apply(events)
            except (OperationalError, InterfaceError):
                # The database is away. Everything is kept and retried.
                logger.warning("database unavailable; holding %s FTP events", len(events))
                self._pending = events[-PENDING_LIMIT:]
                self.dropped += max(0, len(events) - PENDING_LIMIT)
                return 0
            except Exception:  # noqa: BLE001 - see _apply_one_by_one
                logger.exception("could not record %s FTP events together", len(events))
                return self._apply_one_by_one(events)
            return len(events)

    def _apply_one_by_one(self, events: list[tuple]) -> int:
        """Apply a batch that failed as a whole, one event at a time.

        Something in it was refused on its own merits — an upload by a session
        whose setup was deleted while it was logged in, say. Retrying the whole
        batch would fail forever and hold every good event behind the bad one,
        so each is tried alone and the ones that still fail are dropped: the
        file itself stays on disk, and housekeeping adopts it or clears it.
        """
        applied = 0
        for index, event in enumerate(events):
            try:
                with transaction.atomic():
                    self._apply([event])
                applied += 1
            except (OperationalError, InterfaceError):
                self._pending = events[index:][-PENDING_LIMIT:]
                break
            except Exception as exc:  # noqa: BLE001
                self.dropped += 1
                logger.warning("dropping an FTP event that cannot be recorded (%s): %r", exc, event[:3])
        return applied

    def _pre_roll(self) -> timedelta:
        now = time.monotonic()
        if self._rolls is None or now - self._rolls_at > ROLLS_TTL_SECONDS:
            self._rolls = retention.rolls()
            self._rolls_at = now
        return self._rolls[0]

    def _apply(self, events: list[tuple]) -> None:
        pre = self._pre_roll()
        stats: dict[int, _Stats] = {}
        batch = []
        # A session keeps its recorder id after the setup behind it is deleted;
        # its events have nowhere to go, and inserting them would fail the
        # whole batch on the foreign key.
        mentioned = {event[1] for event in events if event[1] is not None}
        existing = set(
            Recorder.objects.filter(pk__in=mentioned).values_list("pk", flat=True)
        ) if mentioned else set()
        events = [event for event in events if event[1] is None or event[1] in existing]

        def flush():
            if batch:
                upsert(list(batch))
                batch.clear()

        for event in events:
            kind = event[0]
            if kind == "upload":
                _, recorder_id, path, size, peer, complete, at, transfer = event
                relative = _relative(recorder_id, path)
                if relative is None:
                    continue
                batch.append(
                    upload_row(
                        recorder_id,
                        relative,
                        size=size,
                        received_at=at,
                        peer=peer,
                        complete=complete,
                        transfer_seconds=transfer,
                        pre=pre,
                    )
                )
                entry = stats.setdefault(recorder_id, _Stats())
                if complete:
                    entry.files += 1
                entry.bytes += int(size or 0)
                entry.last_upload_at = at
                entry.last_upload_peer = peer
                entry.last_upload_name = relative
            elif kind == "rename":
                flush()
                _, recorder_id, source, target, at = event
                self._apply_rename(recorder_id, source, target, pre)
            elif kind == "delete":
                flush()
                _, recorder_id, path = event
                relative = _relative(recorder_id, path)
                if relative is not None:
                    FootageUpload.objects.filter(recorder_id=recorder_id, path=relative).delete()
            elif kind == "login":
                _, recorder_id, peer, at = event
                entry = stats.setdefault(recorder_id, _Stats())
                entry.last_login_at = at
                entry.last_login_peer = peer
                entry.failed = 0
                entry.failed_at = None
            elif kind == "login_failed":
                _, recorder_id, username, peer, at = event
                if recorder_id is None:
                    self.recent_unknown.append(
                        UnknownLogin(username=str(username)[:64], peer=peer, at=at)
                    )
                    continue
                entry = stats.setdefault(recorder_id, _Stats())
                entry.failed += 1
                entry.failed_at = at
                entry.failed_peer = peer
        flush()
        for recorder_id, entry in stats.items():
            _write_stats(recorder_id, entry)

    def _apply_rename(self, recorder_id: int, source: str, target: str, pre: timedelta) -> None:
        """Follow the file (or a whole folder) to its new name.

        Some DVRs upload to a temporary name and rename it once complete; the
        row must then describe the final name, because the name is where the
        camera and the time come from.
        """
        source_rel = _relative(recorder_id, source)
        target_rel = _relative(recorder_id, target)
        if source_rel is None or target_rel is None:
            return
        if os.path.isdir(target):
            prefix = source_rel.rstrip("/") + "/"
            moved = list(
                FootageUpload.objects.filter(recorder_id=recorder_id, path__startswith=prefix)
            )
            renamed = {row.path: target_rel.rstrip("/") + "/" + row.path[len(prefix):] for row in moved}
        else:
            moved = list(FootageUpload.objects.filter(recorder_id=recorder_id, path=source_rel))
            renamed = {source_rel: target_rel}
        if not moved:
            return
        FootageUpload.objects.filter(pk__in=[row.pk for row in moved]).delete()
        upsert(
            [
                upload_row(
                    recorder_id,
                    renamed[row.path],
                    size=row.size_bytes,
                    received_at=row.received_at,
                    peer=row.peer,
                    complete=row.complete,
                    transfer_seconds=row.transfer_seconds,
                    pre=pre,
                )
                for row in moved
            ]
        )


def _relative(recorder_id: int, path: str) -> str | None:
    try:
        return storage.relative_inbox_path(recorder_id, path)
    except ValueError:
        logger.warning("ignoring a path outside inbox %s: %r", recorder_id, path)
        return None


def _write_stats(recorder_id: int, entry: _Stats) -> None:
    updates = {}
    if entry.files:
        updates["files_received"] = F("files_received") + entry.files
    if entry.bytes:
        updates["bytes_received"] = F("bytes_received") + entry.bytes
    if entry.last_upload_at is not None:
        updates["last_upload_at"] = entry.last_upload_at
        updates["last_upload_peer"] = entry.last_upload_peer[:64]
        updates["last_upload_name"] = entry.last_upload_name[-255:]
    if entry.last_login_at is not None:
        updates["last_login_at"] = entry.last_login_at
        updates["last_login_peer"] = entry.last_login_peer[:64]
        if not entry.failed:
            updates["failed_login_count"] = 0
    if entry.failed:
        updates["failed_login_count"] = F("failed_login_count") + entry.failed
        updates["failed_login_at"] = entry.failed_at
        updates["failed_login_peer"] = entry.failed_peer[:64]
    if updates:
        FtpAccount.objects.filter(recorder_id=recorder_id).update(**updates)
    if entry.last_upload_at is not None:
        first = Recorder.objects.filter(pk=recorder_id, status=Recorder.Status.NEVER).exists()
        Recorder.objects.filter(pk=recorder_id).update(
            status=Recorder.Status.OK, last_seen_at=entry.last_upload_at, last_error=""
        )
        if first:
            # The FTP equivalent of a first successful connection: footage is
            # arriving, so the shop should find its cameras in the app.
            enable_surveillance_feature()
