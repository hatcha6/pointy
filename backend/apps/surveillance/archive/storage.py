"""Where uploaded footage lives on disk, and how much of the disk it may take.

Three trees under ``POINTY_FOOTAGE_ROOT``, all on one filesystem so that moving
a kept upload into the archive is a rename rather than a copy:

* ``inbox/<recorder id>/`` — each FTP account's home. The DVR decides what goes
  in it, down to the folder layout; nothing there is ours until it is decided.
* ``archive/<camera id>/YYYY/MM/DD/`` — what was kept.
* ``work/`` — ffmpeg's scratch space while an upload is being cut.

The budgets are shares of the disk rather than fixed numbers because the same
image runs on a 128 GB mini PC and on a 4 TB box, and a shop never configures
either.
"""

from __future__ import annotations

import logging
import os
import secrets
import shutil
from dataclasses import dataclass
from datetime import datetime, timezone as dt_timezone
from pathlib import Path, PurePosixPath

from django.conf import settings

logger = logging.getLogger(__name__)

GIB = 1024 ** 3


def footage_root() -> Path:
    return Path(getattr(settings, "POINTY_FOOTAGE_ROOT", "footage"))


def inbox_root() -> Path:
    return footage_root() / "inbox"


def archive_root() -> Path:
    return footage_root() / "archive"


def work_root() -> Path:
    return footage_root() / "work"


def inbox_dir(recorder_id: int) -> Path:
    return inbox_root() / str(int(recorder_id))


def ensure_tree() -> None:
    for directory in (inbox_root(), archive_root(), work_root()):
        directory.mkdir(parents=True, exist_ok=True)


def ensure_inbox(recorder_id: int) -> Path:
    directory = inbox_dir(recorder_id)
    directory.mkdir(parents=True, exist_ok=True)
    return directory


def relative_inbox_path(recorder_id: int, absolute: str | os.PathLike) -> str:
    """``absolute`` as a path inside the recorder's inbox, with forward slashes.

    Raises ``ValueError`` for anything outside it. The FTP layer already
    confines a session to its home; this is the second lock on the same door,
    because the path ends up in a database row that later drives a delete.
    """
    root = os.path.realpath(inbox_dir(recorder_id))
    resolved = os.path.realpath(absolute)
    relative = os.path.relpath(resolved, root)
    if relative == "." or relative.startswith(".." + os.sep) or relative == "..":
        raise ValueError(f"{absolute!r} is not inside inbox {recorder_id}")
    return PurePosixPath(*Path(relative).parts).as_posix()


def absolute_inbox_path(recorder_id: int, relative: str) -> Path:
    candidate = inbox_dir(recorder_id).joinpath(*PurePosixPath(relative).parts)
    # Resolve and re-check rather than trust the row: a path is only ever
    # deleted through here.
    root = os.path.realpath(inbox_dir(recorder_id))
    resolved = os.path.realpath(candidate)
    if os.path.commonpath([root, resolved]) != root or resolved == root:
        raise ValueError(f"{relative!r} escapes inbox {recorder_id}")
    return Path(resolved)


def new_archive_path(camera_id: int, start: datetime, suffix: str) -> tuple[str, Path]:
    """A fresh (relative, absolute) path for a kept clip.

    Dated by what the footage depicts, in UTC, so a folder holds one day of one
    camera and pruning by age can remove whole folders. The random tail keeps
    two clips starting in the same second — two invoices a second apart, cut
    from two uploads — from ever colliding.
    """
    moment = start.astimezone(dt_timezone.utc)
    relative = PurePosixPath(
        str(int(camera_id)),
        f"{moment:%Y}",
        f"{moment:%m}",
        f"{moment:%d}",
        f"{moment:%H%M%S}-{secrets.token_hex(4)}{suffix}",
    ).as_posix()
    absolute = archive_root().joinpath(*PurePosixPath(relative).parts)
    absolute.parent.mkdir(parents=True, exist_ok=True)
    return relative, absolute


def archive_file(relative: str) -> Path:
    candidate = archive_root().joinpath(*PurePosixPath(relative).parts)
    root = os.path.realpath(archive_root())
    resolved = os.path.realpath(candidate)
    if os.path.commonpath([root, resolved]) != root or resolved == root:
        raise ValueError(f"{relative!r} escapes the archive")
    return Path(resolved)


def work_file(suffix: str) -> Path:
    work_root().mkdir(parents=True, exist_ok=True)
    return work_root() / f"{secrets.token_hex(8)}{suffix}"


def clear_work() -> None:
    """Scratch left by a pass that died mid-cut. Only ever ours."""
    root = work_root()
    if not root.exists():
        return
    for entry in root.iterdir():
        remove_quietly(entry)


def remove_quietly(path: Path) -> None:
    try:
        if path.is_dir() and not path.is_symlink():
            shutil.rmtree(path, ignore_errors=True)
        else:
            path.unlink(missing_ok=True)
    except OSError as exc:
        logger.warning("could not remove %s: %s", path, exc)


def prune_empty_dirs(root: Path, *, keep_root: bool = True) -> None:
    """Remove folders a DVR created and emptied, deepest first."""
    if not root.exists():
        return
    for directory, _subdirs, _files in os.walk(root, topdown=False):
        if keep_root and os.path.samefile(directory, root):
            continue
        try:
            os.rmdir(directory)
        except OSError:
            continue


def tree_size(root: Path) -> int:
    total = 0
    if not root.exists():
        return 0
    for directory, _subdirs, files in os.walk(root):
        for name in files:
            try:
                total += os.lstat(os.path.join(directory, name)).st_size
            except OSError:
                continue
    return total


@dataclass(frozen=True)
class DiskBudget:
    """How the footage disk stands, in bytes."""

    total: int
    free: int
    #: Below this much free space nothing new is accepted and old clips go.
    min_free: int
    #: The most the kept archive may occupy.
    archive_limit: int
    #: The most raw uploads may occupy while they wait to be decided.
    inbox_limit: int

    @property
    def below_floor(self) -> bool:
        return self.free < self.min_free


def disk_budget(path: Path | None = None) -> DiskBudget:
    target = path or footage_root()
    probe = target
    while not probe.exists() and probe != probe.parent:
        probe = probe.parent
    usage = shutil.disk_usage(probe)
    total = int(usage.total)
    min_free = max(
        int(float(getattr(settings, "POINTY_FOOTAGE_MIN_FREE_GB", 10.0)) * GIB),
        int(total * float(getattr(settings, "POINTY_FOOTAGE_MIN_FREE_SHARE", 0.05))),
    )
    archive_limit = int(total * float(getattr(settings, "POINTY_FOOTAGE_MAX_SHARE", 0.4)))
    absolute_cap = float(getattr(settings, "POINTY_FOOTAGE_MAX_GB", 0.0))
    if absolute_cap > 0:
        archive_limit = min(archive_limit, int(absolute_cap * GIB))
    inbox_limit = int(
        total * float(getattr(settings, "POINTY_FOOTAGE_INBOX_MAX_SHARE", 0.15))
    )
    return DiskBudget(
        total=total,
        free=int(usage.free),
        min_free=min_free,
        archive_limit=archive_limit,
        inbox_limit=inbox_limit,
    )


def remove_recorder_files(recorder_id: int, camera_ids) -> None:
    """A deleted recorder's inbox and its cameras' kept footage.

    Whole folders, because a recorder's clips can number in the tens of
    thousands and deleting them one row at a time would hold the request that
    removed the recorder. Housekeeping catches anything this misses.
    """
    remove_quietly(inbox_dir(recorder_id))
    for camera_id in camera_ids:
        remove_quietly(archive_root() / str(int(camera_id)))
