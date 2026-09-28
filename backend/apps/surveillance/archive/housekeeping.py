"""Holding the archive to its retention and its share of the disk.

Runs every few minutes inside the FTP service, beside the ingest. Four jobs, in
order of how much it matters that they happen:

1. **The disk floor.** Below it the oldest clips are deleted until it is met:
   Postgres lives on the same disk, and a POS that cannot write a sale because
   camera footage filled the disk is the worst failure this feature could
   cause.
2. **Retention by age** — the shop's own setting.
3. **Orphan uploads.** A file whose completion was never recorded (the FTP
   process restarted mid-transfer, the DVR never came back to finish it) is
   adopted once it has sat untouched for an hour, and decided like any other.
4. **Leftovers** of recorders and cameras that were deleted, and clip rows
   whose file is gone.
"""

from __future__ import annotations

import logging
import os
import time
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone as dt_timezone

from django.db.models import Sum
from django.utils import timezone

from apps.core.models import ShopSettings

from ..models import Camera, FootageClip, FootageUpload, Recorder
from . import storage
from .uploads import upload_row

logger = logging.getLogger(__name__)

#: An inbox file nobody reported finished, untouched this long, is adopted.
ORPHAN_AGE = timedelta(hours=1)
DELETE_BATCH = 500
#: Clip rows checked for a missing file per run. Bounded so a large archive
#: costs a slice of a pass, not all of it.
EXISTENCE_CHECKS_PER_RUN = 2000


@dataclass
class HousekeepingReport:
    expired: int = 0
    pruned_for_space: int = 0
    adopted: int = 0
    missing_rows: int = 0
    orphan_dirs: int = 0


_existence_cursor = 0


def run(*, now: datetime | None = None) -> HousekeepingReport:
    now = now or timezone.now()
    report = HousekeepingReport()
    storage.ensure_tree()
    report.pruned_for_space = enforce_disk_budget()
    report.expired = expire_by_age(now)
    report.adopted = adopt_orphan_uploads(now)
    report.orphan_dirs = remove_leftovers()
    report.missing_rows = forget_missing_clips()
    return report


def delete_clips(clips) -> tuple[int, int]:
    """Remove clips' files, then their rows. Returns (count, bytes)."""
    ids = []
    freed = 0
    for clip in clips:
        try:
            storage.remove_quietly(storage.archive_file(clip.path))
        except ValueError:
            pass
        ids.append(clip.pk)
        freed += int(clip.size_bytes or 0)
    if ids:
        FootageClip.objects.filter(pk__in=ids).delete()
    return len(ids), freed


def expire_by_age(now: datetime) -> int:
    days = int(getattr(ShopSettings.load(), "surveillance_archive_retention_days", 30) or 30)
    cutoff = now - timedelta(days=max(1, days))
    removed = 0
    while True:
        batch = list(
            FootageClip.objects.filter(end__lt=cutoff).only("pk", "path", "size_bytes")[:DELETE_BATCH]
        )
        if not batch:
            break
        count, _ = delete_clips(batch)
        removed += count
    if removed:
        storage.prune_empty_dirs(storage.archive_root())
    return removed


def archive_bytes() -> int:
    return int(FootageClip.objects.aggregate(total=Sum("size_bytes"))["total"] or 0)


def enforce_disk_budget() -> int:
    """Oldest clips out until the archive fits its share and the floor holds."""
    budget = storage.disk_budget()
    used = archive_bytes()
    removed = 0
    while used > budget.archive_limit or budget.below_floor:
        oldest = list(
            FootageClip.objects.order_by("start", "id").only("pk", "path", "size_bytes")[:200]
        )
        if not oldest:
            break
        # Only as many as it takes: the budget is a ceiling, not a target.
        chosen = []
        freed = 0
        for clip in oldest:
            chosen.append(clip)
            freed += int(clip.size_bytes or 0)
            if used - freed <= budget.archive_limit and budget.free + freed >= budget.min_free:
                break
        count, freed = delete_clips(chosen)
        removed += count
        used -= freed
        budget = storage.disk_budget()
    if removed:
        logger.warning(
            "pruned %s oldest footage clips to keep the disk floor / archive budget", removed
        )
        storage.prune_empty_dirs(storage.archive_root())
    return removed


def adopt_orphan_uploads(now: datetime) -> int:
    adopted = 0
    cutoff = time.time() - ORPHAN_AGE.total_seconds()
    for recorder in Recorder.objects.filter(connection=Recorder.Connection.FTP):
        root = storage.inbox_dir(recorder.pk)
        if not root.exists():
            continue
        known = set(
            FootageUpload.objects.filter(recorder=recorder).values_list("path", flat=True)
        )
        rows = []
        for directory, _subdirs, files in os.walk(root):
            for name in files:
                absolute = os.path.join(directory, name)
                try:
                    stat = os.stat(absolute)
                    relative = storage.relative_inbox_path(recorder.pk, absolute)
                except (OSError, ValueError):
                    continue
                if relative in known or stat.st_mtime > cutoff:
                    continue
                received_at = datetime.fromtimestamp(stat.st_mtime, tz=dt_timezone.utc)
                rows.append(
                    upload_row(
                        recorder.pk,
                        relative,
                        size=stat.st_size,
                        received_at=received_at,
                        peer="",
                        complete=True,
                        decide_at=now,
                    )
                )
        if rows:
            FootageUpload.objects.bulk_create(rows, ignore_conflicts=True)
            adopted += len(rows)
            logger.info("adopted %s unreported uploads for FTP recorder %s", len(rows), recorder.pk)
        storage.prune_empty_dirs(root)
    return adopted


def remove_leftovers() -> int:
    """Inboxes and archive folders whose recorder or camera no longer exists."""
    removed = 0
    ftp_recorders = {
        str(pk)
        for pk in Recorder.objects.filter(connection=Recorder.Connection.FTP).values_list(
            "pk", flat=True
        )
    }
    inbox = storage.inbox_root()
    if inbox.exists():
        for entry in inbox.iterdir():
            if entry.name not in ftp_recorders:
                storage.remove_quietly(entry)
                removed += 1
    cameras = {str(pk) for pk in Camera.objects.values_list("pk", flat=True)}
    archive = storage.archive_root()
    if archive.exists():
        for entry in archive.iterdir():
            if entry.name not in cameras:
                storage.remove_quietly(entry)
                removed += 1
    return removed


def forget_missing_clips() -> int:
    """Clip rows whose file has gone (a disk swapped, a hand-deleted folder)."""
    global _existence_cursor
    batch = list(
        FootageClip.objects.filter(pk__gt=_existence_cursor)
        .order_by("pk")
        .only("pk", "path")[:EXISTENCE_CHECKS_PER_RUN]
    )
    if not batch:
        _existence_cursor = 0
        return 0
    _existence_cursor = batch[-1].pk
    missing = []
    for clip in batch:
        try:
            if not storage.archive_file(clip.path).exists():
                missing.append(clip.pk)
        except ValueError:
            missing.append(clip.pk)
    if missing:
        FootageClip.objects.filter(pk__in=missing).delete()
    return len(missing)
