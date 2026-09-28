"""What an uploaded file's path says: which camera, and when.

A DVR decides its own folder layout and file names, and the installer rarely
changes them, so reading the path is the only identification there is. The
shapes below are the ones the brands in this market actually produce:

* **Dahua** (and the XVR OEMs, and Xiongmai, whose file system imitates it)::

      192.168.1.108/2026-09-27/001/dav/14/14.00.00-14.15.00[R][0@0][0].dav
      192.168.1.108/2026-09-27/001/jpg/14/14.03.11[M][0@0][0].jpg

  The three-digit folder after the date is the channel; the name carries the
  time range, the date folder carries the day.
* **Hikvision** pictures::

      DVR/Camera 01/192.168.1.64_01_20260927140311123_TIMING.jpg

  ``_01_`` after the address is the channel; 17 digits are the moment to the
  millisecond.
* Everything else: 14-digit stamps, ``20260927_140311``, ISO-ish
  ``2026-09-27 14-03-11``, and ``ch01``/``channel 1``/``Camera1`` markers.

Nothing here touches the disk or the database. Times are the DEVICE's wall
clock, naive; turning them into UTC needs the recorder's clock offset, which is
measured from these same uploads — see ``clock``.
"""

from __future__ import annotations

import re
from dataclasses import dataclass
from datetime import datetime, time, timedelta
from pathlib import PurePosixPath

VIDEO_EXTENSIONS = frozenset(
    {
        "dav", "mp4", "mkv", "avi", "ts", "mov", "m4v", "flv", "asf", "mpg",
        "mpeg", "ps", "h264", "264", "h265", "265", "hevc",
    }
)
PICTURE_EXTENSIONS = frozenset({"jpg", "jpeg"})
#: Elementary streams: no container, so no timing. ffmpeg has to be told the
#: format and, when the name gives the span, the frame rate.
RAW_VIDEO_EXTENSIONS = {"h264": "h264", "264": "h264", "h265": "hevc", "265": "hevc", "hevc": "hevc"}

KIND_VIDEO = "video"
KIND_PICTURE = "picture"
KIND_OTHER = "other"

DEFAULT_CHANNEL = 1

#: Folder names that describe the upload rather than the camera. Skipped when
#: the camera has to be identified by folder name.
_GENERIC_FOLDERS = frozenset(
    {
        "dav", "jpg", "jpeg", "pic", "pics", "picture", "pictures", "image",
        "images", "img", "video", "videos", "record", "records", "recording",
        "recordings", "rec", "snapshot", "snapshots", "snap", "mp4", "h264",
        "h265", "alarm", "alarms", "motion", "event", "events", "ftp", "upload",
        "uploads", "data", "capture", "captures", "regular", "timing", "manual",
        "continuous", "schedule", "normal", "idx", "tmp", "temp",
    }
)

_DATE_FOLDER = re.compile(r"^(\d{4})[-_.]?(\d{2})[-_.]?(\d{2})$")
_HOUR_FOLDER = re.compile(r"^\d{1,2}$")
_DAHUA_CHANNEL_FOLDER = re.compile(r"^\d{3}$")
_IP_LIKE = re.compile(r"^\d{1,3}(?:[._-]\d{1,3}){3}$")
_IP_IN_NAME = re.compile(r"(?<![\d.])\d{1,3}(?:\.\d{1,3}){3}(?![\d.])")

# Hikvision picture names: <ip>_<channel>_<17 or 14 digit stamp>...
_HIKVISION_NAME = re.compile(
    r"^\d{1,3}(?:\.\d{1,3}){3}_0*(\d{1,3})_(\d{14,17})(?!\d)"
)
_CHANNEL_MARKER = re.compile(
    r"(?:^|[^a-z])(?:camera|cam|channel|chn|ch)[\s_\-]?0*(\d{1,3})(?!\d)",
    re.IGNORECASE,
)

# 14.00.00-14.15.00 (Dahua, Xiongmai). Dots or colons inside a time.
_TIME_RANGE = re.compile(
    r"(?<!\d)(\d{2})[.:](\d{2})[.:](\d{2})\s*-\s*(\d{2})[.:](\d{2})[.:](\d{2})(?!\d)"
)
# 14.03.11 on its own (a Dahua snapshot).
_SINGLE_TIME = re.compile(r"(?<!\d)(\d{2})[.:](\d{2})[.:](\d{2})(?![\d.:])")
# Two full stamps, start then end: 20260927140000_20260927141500.
_TWO_COMPACT = re.compile(r"(?<!\d)(\d{14})(?:\d{3})?\D{1,3}(\d{14})(?:\d{3})?(?!\d)")
# One full stamp, 14 digits, optionally 3 more for milliseconds.
_ONE_COMPACT = re.compile(r"(?<!\d)(\d{14})(\d{3})?(?!\d)")
# 20260927_140311, 20260927-140311, 20260927T140311
_SPLIT_COMPACT = re.compile(r"(?<!\d)(\d{8})[_\-T ](\d{6})(?!\d)")
# 2026-09-27 14:03:11, 2026-09-27_14-03-11, 2026_09_27_14_03_11 ...
_SEPARATED = re.compile(
    r"(?<!\d)(\d{4})[-_/.](\d{2})[-_/.](\d{2})[T _\-](\d{2})[-_:.](\d{2})[-_:.](\d{2})(?!\d)"
)


@dataclass(frozen=True)
class ParsedUpload:
    kind: str
    #: The camera's identity on its recorder: ``ch:3`` or ``dir:front door``.
    source_key: str
    #: A human name for a folder-identified camera; empty for a numbered one.
    source_label: str
    channel: int | None
    #: Device wall clock, naive. ``None`` when the name does not say.
    wall_start: datetime | None
    wall_end: datetime | None


def extension_of(path: str) -> str:
    name = PurePosixPath(path).name
    if "." not in name:
        return ""
    return name.rsplit(".", 1)[1].strip().lower()


def kind_of(path: str) -> str:
    extension = extension_of(path)
    if extension in VIDEO_EXTENSIONS:
        return KIND_VIDEO
    if extension in PICTURE_EXTENSIONS:
        return KIND_PICTURE
    return KIND_OTHER


def raw_format_of(path: str) -> str:
    """The ffmpeg demuxer for an elementary stream, or ``""`` for a container."""
    return RAW_VIDEO_EXTENSIONS.get(extension_of(path), "")


def parse_upload_path(path: str) -> ParsedUpload:
    """Everything the path says about one upload.

    ``path`` is relative to the recorder's inbox, forward slashes.
    """
    parts = [part for part in PurePosixPath(path).parts if part not in ("", "/", ".")]
    if not parts:
        return ParsedUpload(KIND_OTHER, f"ch:{DEFAULT_CHANNEL}", "", DEFAULT_CHANNEL, None, None)
    filename = parts[-1]
    folders = parts[:-1]
    stem = filename.rsplit(".", 1)[0] if "." in filename else filename

    channel, label = _identify_source(folders, filename)
    if channel is not None:
        source_key = f"ch:{channel}"
    elif label:
        source_key = f"dir:{_normalise_label(label)}"
    else:
        channel = DEFAULT_CHANNEL
        source_key = f"ch:{DEFAULT_CHANNEL}"

    wall_start, wall_end = _read_times(folders, stem)
    return ParsedUpload(
        kind=kind_of(filename),
        source_key=source_key[:160],
        source_label=(label or "")[:120],
        channel=channel,
        wall_start=wall_start,
        wall_end=wall_end,
    )


# -- camera -----------------------------------------------------------------
def _identify_source(folders: list[str], filename: str) -> tuple[int | None, str]:
    # Dahua: the three-digit folder right after the date folder.
    for index, folder in enumerate(folders[:-1]):
        if _DATE_FOLDER.match(folder) and _DAHUA_CHANNEL_FOLDER.match(folders[index + 1]):
            number = int(folders[index + 1])
            if number >= 1:
                return number, ""
    # Hikvision: <ip>_<channel>_<stamp>.
    match = _HIKVISION_NAME.match(filename)
    if match:
        number = int(match.group(1))
        if number >= 1:
            return number, ""
    # A marker in the name, then in the folders from the nearest outwards.
    for candidate in [filename, *reversed(folders)]:
        match = _CHANNEL_MARKER.search(candidate)
        if match:
            number = int(match.group(1))
            if number >= 1:
                return number, ""
    # No number anywhere: the nearest folder that names something.
    for folder in reversed(folders):
        if _is_descriptive_folder(folder):
            return None, folder.strip()
    return None, ""


def _is_descriptive_folder(folder: str) -> bool:
    text = folder.strip()
    if not text:
        return False
    lowered = text.lower()
    if lowered in _GENERIC_FOLDERS:
        return False
    if _DATE_FOLDER.match(text) or _HOUR_FOLDER.match(text):
        return False
    if _DAHUA_CHANNEL_FOLDER.match(text) or _IP_LIKE.match(text):
        return False
    if text.isdigit():
        return False
    return True


def _normalise_label(label: str) -> str:
    return " ".join(label.split()).casefold()


# -- time -------------------------------------------------------------------
def _read_times(folders: list[str], stem: str) -> tuple[datetime | None, datetime | None]:
    day = _date_from_folders(folders)
    # An address in the name ("10.20.30.40_01_…") is dotted digits too, and
    # would otherwise read as the time 20:30:40.
    stem = _IP_IN_NAME.sub(" ", stem)

    match = _TIME_RANGE.search(stem)
    if match:
        base = _date_in(stem) or day
        if base is not None:
            start = _at(base, match.group(1, 2, 3))
            end = _at(base, match.group(4, 5, 6))
            if start is not None and end is not None:
                if end < start:
                    # A segment that runs across midnight is named by its
                    # start day.
                    end += timedelta(days=1)
                return start, end

    match = _TWO_COMPACT.search(stem)
    if match:
        start = _compact(match.group(1))
        end = _compact(match.group(2))
        if start is not None and end is not None and end >= start:
            return start, end

    for pattern in (_SEPARATED, _SPLIT_COMPACT, _ONE_COMPACT):
        match = pattern.search(stem)
        if not match:
            continue
        if pattern is _SEPARATED:
            moment = _parts(match.groups())
        elif pattern is _SPLIT_COMPACT:
            moment = _compact(match.group(1) + match.group(2))
        else:
            moment = _compact(match.group(1))
            if moment is not None and match.group(2):
                moment += timedelta(milliseconds=int(match.group(2)))
        if moment is not None:
            return moment, None

    match = _SINGLE_TIME.search(stem)
    if match and day is not None:
        moment = _at(day, match.group(1, 2, 3))
        if moment is not None:
            return moment, None
    return None, None


def _date_from_folders(folders: list[str]) -> datetime | None:
    for folder in reversed(folders):
        match = _DATE_FOLDER.match(folder.strip())
        if match:
            moment = _parts((*match.groups(), "00", "00", "00"))
            if moment is not None:
                return moment
    return None


def _date_in(stem: str) -> datetime | None:
    match = re.search(r"(?<!\d)(\d{4})[-_](\d{2})[-_](\d{2})(?![\d])", stem)
    if not match:
        return None
    return _parts((*match.groups(), "00", "00", "00"))


def _at(day: datetime, hms) -> datetime | None:
    try:
        hour, minute, second = (int(value) for value in hms)
        return datetime.combine(day.date(), time(hour, minute, second))
    except ValueError:
        return None


def _compact(digits: str) -> datetime | None:
    if len(digits) < 14:
        return None
    return _parts(
        (digits[0:4], digits[4:6], digits[6:8], digits[8:10], digits[10:12], digits[12:14])
    )


def _parts(values) -> datetime | None:
    try:
        year, month, day, hour, minute, second = (int(value) for value in values)
        if not 2000 <= year <= 2100:
            return None
        return datetime(year, month, day, hour, minute, second)
    except (TypeError, ValueError):
        return None
