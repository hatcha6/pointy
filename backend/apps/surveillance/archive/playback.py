"""Kept footage, served back exactly the way a recorder's own footage is.

The player cannot tell the difference and must not have to: frames go out as
the same MJPEG parts with the same ``X-Pointy-Frame-Time``, the timeline reads
the same segments, and still and export answer the same requests. What changes
is only where the bytes come from — clips on this server's disk instead of a
DVR's playback stream.

Video clips are decoded by ffmpeg from the file; pictures (a Hikvision uploads
nothing else) need no decoder at all — each stored JPEG *is* a frame, sent at
the moment it was taken.
"""

from __future__ import annotations

import logging
import os
import tempfile
import time
from pathlib import Path
from dataclasses import dataclass
from datetime import datetime, timedelta
from functools import lru_cache

from .. import transcode
from ..drivers.base import RecordingSegment
from ..models import Camera, FootageClip
from ..streaming import Frame, StreamError, StreamFailure, _jpeg_frames
from . import media, storage

logger = logging.getLogger(__name__)

#: A gap between two stored pictures is shortened to this when played back,
#: so a camera that uploaded once a minute does not show one frame for a
#: minute. The frame times still say the truth; only the wait is shortened.
MAX_PICTURE_WAIT_SECONDS = 2.0
#: Pictures closer together than this are drawn as one stretch on the timeline.
PICTURE_SEGMENT_GAP = timedelta(seconds=5)
PICTURE_SEGMENT_TAIL = timedelta(seconds=1)
#: How far from the asked moment a stored picture still answers "a still".
STILL_TOLERANCE = timedelta(seconds=10)
#: Frames per wall-clock second a sped-up playback may decode.
MAX_DECODED_FPS = 60


def clips_between(camera: Camera, start: datetime, end: datetime):
    return list(
        FootageClip.objects.filter(camera=camera, start__lte=end, end__gte=start).order_by(
            "start", "id"
        )
    )


def _prefer_video(clips):
    """Video when there is any; a recorder uploading both does not need both."""
    videos = [clip for clip in clips if clip.kind == FootageClip.Kind.VIDEO]
    return videos if videos else clips


def has_footage(camera: Camera, start: datetime, end: datetime) -> bool:
    return FootageClip.objects.filter(camera=camera, start__lte=end, end__gte=start).exists()


def recording_segments(camera: Camera, start: datetime, end: datetime) -> list[RecordingSegment]:
    """The kept footage in a window, as the timeline draws it."""
    clips = _prefer_video(clips_between(camera, start, end))
    segments: list[RecordingSegment] = []
    for clip in clips:
        clip_end = clip.end
        if clip.kind == FootageClip.Kind.PICTURE:
            clip_end = clip.start + PICTURE_SEGMENT_TAIL
            if segments and clip.start - segments[-1].end <= PICTURE_SEGMENT_GAP:
                last = segments[-1]
                segments[-1] = RecordingSegment(
                    start=last.start,
                    end=max(last.end, clip_end),
                    size_bytes=last.size_bytes + int(clip.size_bytes or 0),
                )
                continue
        segments.append(
            RecordingSegment(start=clip.start, end=clip_end, size_bytes=int(clip.size_bytes or 0))
        )
    return segments


@lru_cache(maxsize=256)
def _start_time(path: str, mtime: float) -> float:
    """Where a clip's own timeline begins (see ``media.MediaInfo.start_time``)."""
    try:
        return media.probe(storage.archive_file(path)).start_time
    except (media.MediaError, ValueError):
        return 0.0


def clip_start_time(clip: FootageClip) -> float:
    try:
        absolute = storage.archive_file(clip.path)
        return _start_time(clip.path, os.path.getmtime(absolute))
    except (OSError, ValueError):
        return 0.0


class ArchiveSource:
    """Frames for one window of one camera's kept footage, for the broker."""

    def __init__(
        self,
        camera: Camera,
        start: datetime,
        end: datetime,
        *,
        fps: int = 10,
        width: int = 0,
        speed: float = 1.0,
        label: str = "",
    ):
        self.camera = camera
        self.start = start
        self.end = end
        self.speed = max(0.25, float(speed or 1.0))
        self.fps = max(1, min(int(fps), int(MAX_DECODED_FPS / self.speed) or 1))
        self.width = width
        self.label = label
        self.stats: dict = {}
        # Read here, on the request thread that builds the source. ``frames``
        # runs on a broker producer thread, which must not touch the database:
        # it would hold a connection for as long as someone watches.
        self.clips = _prefer_video(clips_between(camera, start, end))

    def frames(self, should_stop):
        clips = self.clips
        if not clips:
            raise StreamError(
                "لم تُحفظ لقطات لهذا الوقت.", reason=StreamFailure.NO_VIDEO
            )
        if clips[0].kind == FootageClip.Kind.PICTURE:
            produced = yield from self._pictures(clips, should_stop)
        else:
            produced = yield from self._videos(clips, should_stop)
        if not produced:
            raise StreamError(
                "تعذّرت قراءة اللقطات المحفوظة لهذا الوقت.",
                reason=StreamFailure.UNREADABLE,
            )

    def _videos(self, clips, should_stop):
        sequence = 0
        for clip in clips:
            if should_stop():
                break
            begin = max(self.start, clip.start)
            finish = min(self.end, clip.end)
            if finish <= begin:
                continue
            try:
                path = storage.archive_file(clip.path)
            except ValueError:
                continue
            if not path.exists():
                continue
            seek = clip_start_time(clip) + (begin - clip.start).total_seconds()
            process, slot = transcode.open_mjpeg_from_file(
                str(path),
                seek=seek,
                duration=(finish - begin).total_seconds(),
                fps=self.fps,
                width=self.width,
                readrate=self.speed,
            )
            try:
                for frame in _jpeg_frames(
                    process,
                    should_stop,
                    seconds_per_frame=1.0 / self.fps,
                    anchor=begin,
                ):
                    sequence += 1
                    yield Frame(data=frame.data, sequence=sequence, captured_at=frame.captured_at)
            except StreamError as exc:
                # One unreadable clip is not the end of the window.
                logger.info("skipping unreadable archive clip %s: %s", clip.path, exc)
            finally:
                transcode.stop(process, slot)
        return sequence

    def _pictures(self, clips, should_stop):
        sequence = 0
        previous: datetime | None = None
        for clip in clips:
            if should_stop():
                break
            if not (self.start <= clip.start <= self.end):
                continue
            try:
                data = storage.archive_file(clip.path).read_bytes()
            except (OSError, ValueError):
                continue
            if data[:2] != b"\xff\xd8":
                continue
            if previous is not None:
                wait = min((clip.start - previous).total_seconds(), MAX_PICTURE_WAIT_SECONDS)
                deadline = time.monotonic() + max(0.0, wait) / self.speed
                while not should_stop() and time.monotonic() < deadline:
                    time.sleep(min(0.1, max(0.0, deadline - time.monotonic())))
            previous = clip.start
            sequence += 1
            yield Frame(data=data, sequence=sequence, captured_at=clip.start)
        return sequence


def still(camera: Camera, at: datetime) -> bytes:
    """One JPEG of what the camera saw at ``at``, from kept footage."""
    clips = clips_between(camera, at - STILL_TOLERANCE, at + STILL_TOLERANCE)
    videos = [clip for clip in clips if clip.kind == FootageClip.Kind.VIDEO and clip.start <= at <= clip.end]
    for clip in videos:
        try:
            return media.still_jpeg(
                storage.archive_file(clip.path),
                at=clip_start_time(clip) + (at - clip.start).total_seconds(),
            )
        except (media.MediaError, ValueError):
            continue
    pictures = [clip for clip in clips if clip.kind == FootageClip.Kind.PICTURE]
    pictures.sort(key=lambda clip: abs((clip.start - at).total_seconds()))
    for clip in pictures:
        try:
            data = storage.archive_file(clip.path).read_bytes()
        except (OSError, ValueError):
            continue
        if data[:2] == b"\xff\xd8":
            return data
    raise StreamError("لم تُحفظ لقطة لهذه اللحظة.", reason=StreamFailure.NO_VIDEO)


@dataclass
class Export:
    """A running export: the ffmpeg process, its slot, and its scratch file."""

    process: object
    slot: object
    list_path: object
    _first: bytes = b""

    def prime(self, size: int = 64 * 1024) -> None:
        """Read the first bytes before the response starts.

        An export that fails inside ffmpeg would otherwise download as an empty
        file with a success status; this makes it an HTTP error with a reason.
        """
        self._first = self.process.stdout.read(size)
        if not self._first:
            detail = transcode.drain_error(self.process)
            self.close()
            raise StreamError(
                "تعذّر تجهيز المقطع للتنزيل.",
                reason=StreamFailure.UNREADABLE,
                detail=detail.splitlines()[0][:200] if detail else "",
            )

    def chunks(self, size: int = 64 * 1024):
        try:
            if self._first:
                yield self._first
            while True:
                chunk = self.process.stdout.read(size)
                if not chunk:
                    return
                yield chunk
        finally:
            self.close()

    def close(self) -> None:
        transcode.stop(self.process, self.slot)
        storage.remove_quietly(self.list_path)


def start_export(camera: Camera, start: datetime, end: datetime) -> Export:
    """The kept footage in ``[start, end]`` as one MP4 on a pipe."""
    clips = _prefer_video(clips_between(camera, start, end))
    if not clips:
        raise StreamError("لم تُحفظ لقطات لهذا الوقت.", reason=StreamFailure.NO_VIDEO)
    # The web process's own temp directory, not the footage work folder: the
    # FTP service empties that one whenever it starts.
    handle, name = tempfile.mkstemp(suffix=".ffconcat", prefix="pointy-export-")
    os.close(handle)
    list_path = Path(name)
    try:
        return _start_export(clips, start, end, list_path)
    except BaseException:
        storage.remove_quietly(list_path)
        raise


def _start_export(clips, start: datetime, end: datetime, list_path: Path) -> Export:
    lines = ["ffconcat version 1.0"]
    if clips[0].kind == FootageClip.Kind.PICTURE:
        pictures = [clip for clip in clips if start <= clip.start <= end]
        if not pictures:
            raise StreamError("لم تُحفظ لقطات لهذا الوقت.", reason=StreamFailure.NO_VIDEO)
        for index, clip in enumerate(pictures):
            path = storage.archive_file(clip.path)
            following = pictures[index + 1].start if index + 1 < len(pictures) else clip.start + timedelta(seconds=1)
            seconds = max(0.2, min((following - clip.start).total_seconds(), 10.0))
            lines += [f"file {_quote(path)}", f"duration {seconds:.3f}"]
        # The concat demuxer ignores the last entry's duration without this.
        lines.append(f"file {_quote(storage.archive_file(pictures[-1].path))}")
        list_path.write_text("\n".join(lines) + "\n", encoding="utf-8")
        process, slot = transcode.open_mp4_from_pictures(str(list_path))
        return Export(process=process, slot=slot, list_path=list_path)

    with_audio = True
    hevc = False
    for clip in clips:
        path = storage.archive_file(clip.path)
        begin = max(start, clip.start)
        finish = min(end, clip.end)
        if finish <= begin or not path.exists():
            continue
        try:
            info = media.probe(path)
        except media.MediaError:
            continue
        with_audio = with_audio and info.has_audio
        hevc = hevc or info.video_codec in ("hevc", "h265")
        offset = info.start_time
        lines += [
            f"file {_quote(path)}",
            f"inpoint {offset + (begin - clip.start).total_seconds():.3f}",
            f"outpoint {offset + (finish - clip.start).total_seconds():.3f}",
        ]
    if len(lines) == 1:
        raise StreamError("تعذّرت قراءة اللقطات المحفوظة لهذا الوقت.", reason=StreamFailure.UNREADABLE)
    list_path.write_text("\n".join(lines) + "\n", encoding="utf-8")
    process, slot = transcode.open_mp4_from_concat(str(list_path), with_audio=with_audio, hevc=hevc)
    return Export(process=process, slot=slot, list_path=list_path)


def _quote(path) -> str:
    """A path for an ffconcat ``file`` line: single-quoted, quotes escaped."""
    return "'" + str(path).replace("'", "'\\''") + "'"

