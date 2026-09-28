"""ffprobe and ffmpeg against files on our own disk.

``transcode`` is the streaming half of ffmpeg — RTSP in, a pipe out, one slot
per viewer. This is the file half: read what an upload is, remux it into
Matroska, cut windows out of it, pull one frame. Everything runs with
``-c copy`` except the one-frame still, so none of it costs a decode of the
whole file.

Matroska is the archive's container because it takes what recorders actually
record — H.264 or H.265 with G.711 sound — which MP4 refuses, and because a
Matroska file cut short by a crash is still readable up to the cut.
"""

from __future__ import annotations

import json
import logging
import subprocess
from dataclasses import dataclass
from pathlib import Path

from .. import transcode

logger = logging.getLogger(__name__)

#: A remux reads the whole file; give it time in proportion to its size.
BASE_TIMEOUT_SECONDS = 60
SECONDS_PER_100_MB = 20
PROBE_TIMEOUT_SECONDS = 60

#: What ffmpeg assumes for an elementary stream when nothing says otherwise.
DEFAULT_RAW_FRAMERATE = 25.0


class MediaError(RuntimeError):
    """The file could not be read or written as video."""


@dataclass(frozen=True)
class MediaInfo:
    duration: float
    video_codec: str
    width: int
    height: int
    audio_codec: str
    format_name: str
    #: Where the file's own timeline begins. Not always 0: a stream with
    #: reordered frames starts at its first presentation time, and every seek
    #: into the file is in these terms.
    start_time: float = 0.0

    @property
    def has_audio(self) -> bool:
        return bool(self.audio_codec)


def available() -> bool:
    return transcode.ffmpeg_available() and bool(transcode.ffprobe_path())


def _timeout_for(path: Path) -> float:
    try:
        size = path.stat().st_size
    except OSError:
        size = 0
    return BASE_TIMEOUT_SECONDS + SECONDS_PER_100_MB * (size / (100 * 1024 * 1024))


def _input_args(input_format: str = "", framerate: float | None = None) -> list[str]:
    args: list[str] = []
    if input_format:
        args += ["-f", input_format]
        # Only an elementary stream takes a frame rate: it has no timestamps of
        # its own, and ffmpeg's guess of 25 is wrong for most DVR sub-streams.
        if framerate:
            args += ["-framerate", f"{framerate:.3f}"]
    return args


def _run(args: list[str], *, timeout: float, capture: bool = True) -> subprocess.CompletedProcess:
    try:
        return subprocess.run(  # noqa: S603 - fixed argv, never a shell
            args,
            capture_output=capture,
            timeout=timeout,
            check=False,
            stdin=subprocess.DEVNULL,
        )
    except subprocess.TimeoutExpired as exc:
        raise MediaError(f"{Path(args[0]).name} timed out after {timeout:.0f}s") from exc
    except OSError as exc:
        raise MediaError(f"could not run {Path(args[0]).name}: {exc}") from exc


def _stderr(completed: subprocess.CompletedProcess) -> str:
    text = (completed.stderr or b"").decode("utf-8", "replace").strip()
    return text.splitlines()[-1][:300] if text else f"exit {completed.returncode}"


def probe(path: Path, *, input_format: str = "", framerate: float | None = None) -> MediaInfo:
    ffprobe = transcode.ffprobe_path()
    if not ffprobe:
        raise MediaError("ffprobe is not installed")
    completed = _run(
        [
            ffprobe,
            "-v",
            "error",
            *_input_args(input_format, framerate),
            "-print_format",
            "json",
            "-show_format",
            "-show_streams",
            str(path),
        ],
        timeout=PROBE_TIMEOUT_SECONDS,
    )
    if completed.returncode != 0:
        raise MediaError(f"unreadable video: {_stderr(completed)}")
    try:
        payload = json.loads(completed.stdout or b"{}")
    except ValueError as exc:
        raise MediaError("ffprobe returned unreadable output") from exc
    streams = payload.get("streams") or []
    video = next((s for s in streams if s.get("codec_type") == "video"), None)
    if video is None:
        raise MediaError("the file has no video in it")
    audio = next((s for s in streams if s.get("codec_type") == "audio"), None)
    fmt = payload.get("format", {}) or {}
    duration = _float(fmt.get("duration")) or _float(video.get("duration"))
    return MediaInfo(
        duration=duration or 0.0,
        video_codec=str(video.get("codec_name") or ""),
        width=int(video.get("width") or 0),
        height=int(video.get("height") or 0),
        audio_codec=str((audio or {}).get("codec_name") or ""),
        format_name=str(fmt.get("format_name") or ""),
        start_time=_float(fmt.get("start_time")) or 0.0,
    )


def count_video_packets(path: Path, *, input_format: str = "") -> int:
    """How many video frames an elementary stream holds, without decoding."""
    ffprobe = transcode.ffprobe_path()
    if not ffprobe:
        raise MediaError("ffprobe is not installed")
    completed = _run(
        [
            ffprobe,
            "-v",
            "error",
            *_input_args(input_format),
            "-count_packets",
            "-select_streams",
            "v:0",
            "-show_entries",
            "stream=nb_read_packets",
            "-of",
            "csv=p=0",
            str(path),
        ],
        timeout=_timeout_for(path),
    )
    if completed.returncode != 0:
        raise MediaError(f"unreadable video: {_stderr(completed)}")
    try:
        return int((completed.stdout or b"0").decode().strip().split(",")[0] or 0)
    except ValueError:
        return 0


def keyframes(path: Path) -> list[float]:
    """Where the file can be cut without re-encoding, in seconds, ascending."""
    ffprobe = transcode.ffprobe_path()
    if not ffprobe:
        raise MediaError("ffprobe is not installed")
    completed = _run(
        [
            ffprobe,
            "-v",
            "error",
            "-select_streams",
            "v:0",
            "-show_entries",
            "packet=pts_time,flags",
            "-of",
            "csv=p=0",
            str(path),
        ],
        timeout=_timeout_for(path),
    )
    if completed.returncode != 0:
        raise MediaError(f"could not read keyframes: {_stderr(completed)}")
    times = []
    for line in (completed.stdout or b"").decode("utf-8", "replace").splitlines():
        fields = line.strip().split(",")
        if len(fields) < 2 or "K" not in fields[1]:
            continue
        value = _float(fields[0])
        if value is not None:
            times.append(value)
    return sorted(set(times))


def remux_to_matroska(
    source: Path,
    target: Path,
    *,
    input_format: str = "",
    framerate: float | None = None,
) -> None:
    """Copy an upload's video (and first sound track) into Matroska.

    The container a DVR uploads is whatever it records — Dahua's DHAV, an
    elementary stream, a Hikvision PS file dressed as MP4 — and cutting it
    precisely needs an index. One copy into Matroska gives every one of them
    the same shape, with keyframes ffprobe can list and ffmpeg can seek to.
    """
    ffmpeg = transcode.ffmpeg_path()
    if not ffmpeg:
        raise MediaError("ffmpeg is not installed")
    completed = _run(
        [
            ffmpeg,
            "-hide_banner",
            "-loglevel",
            "error",
            "-nostdin",
            "-y",
            "-fflags",
            "+genpts+discardcorrupt",
            *_input_args(input_format, framerate),
            "-i",
            str(source),
            "-map",
            "0:v:0",
            "-map",
            "0:a:0?",
            "-c",
            "copy",
            "-avoid_negative_ts",
            "make_zero",
            "-f",
            "matroska",
            str(target),
        ],
        timeout=_timeout_for(source),
    )
    if completed.returncode != 0 or not target.exists() or target.stat().st_size == 0:
        target.unlink(missing_ok=True)
        raise MediaError(f"could not read the upload as video: {_stderr(completed)}")


def cut(source: Path, target: Path, *, start: float, duration: float) -> None:
    """``[start, start + duration)`` of a Matroska file, without re-encoding.

    ``start`` must be a keyframe (see :func:`keyframes`): with ``-c copy`` a cut
    can only begin on one, and starting anywhere else would open on grey until
    the next.
    """
    ffmpeg = transcode.ffmpeg_path()
    if not ffmpeg:
        raise MediaError("ffmpeg is not installed")
    completed = _run(
        [
            ffmpeg,
            "-hide_banner",
            "-loglevel",
            "error",
            "-nostdin",
            "-y",
            "-ss",
            f"{max(0.0, start):.3f}",
            "-i",
            str(source),
            "-t",
            f"{max(0.001, duration):.3f}",
            "-map",
            "0",
            "-c",
            "copy",
            "-avoid_negative_ts",
            "make_zero",
            "-f",
            "matroska",
            str(target),
        ],
        timeout=_timeout_for(source),
    )
    if completed.returncode != 0 or not target.exists() or target.stat().st_size == 0:
        target.unlink(missing_ok=True)
        raise MediaError(f"could not cut the upload: {_stderr(completed)}")


def still_jpeg(source: Path, *, at: float, quality: int = 3) -> bytes:
    """One frame at ``at`` seconds into ``source``, as a JPEG."""
    ffmpeg = transcode.ffmpeg_path()
    if not ffmpeg:
        raise MediaError("ffmpeg is not installed")
    completed = _run(
        [
            ffmpeg,
            "-hide_banner",
            "-loglevel",
            "error",
            "-nostdin",
            "-ss",
            f"{max(0.0, at):.3f}",
            "-i",
            str(source),
            "-frames:v",
            "1",
            "-f",
            "mjpeg",
            "-q:v",
            str(int(quality)),
            "pipe:1",
        ],
        timeout=PROBE_TIMEOUT_SECONDS,
    )
    data = completed.stdout or b""
    if completed.returncode != 0 or not data.startswith(b"\xff\xd8"):
        raise MediaError(f"no frame at that moment: {_stderr(completed)}")
    return data


def looks_like_jpeg(path: Path) -> bool:
    try:
        with path.open("rb") as handle:
            head = handle.read(3)
    except OSError:
        return False
    return head[:2] == b"\xff\xd8"


def _float(value) -> float | None:
    try:
        number = float(value)
    except (TypeError, ValueError):
        return None
    if number != number or number < 0:  # NaN or negative
        return None
    return number
