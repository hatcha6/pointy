"""ffmpeg, kept at arm's length.

Live view deliberately does not need this module — it polls JPEGs straight off
the recorder — so a backend with no ffmpeg still shows every camera. Playback,
export and stills do need it, because they start from an RTSP stream carrying
H.264/H.265 that nothing in this stack can decode.

So ffmpeg is a *detected capability*, not a dependency: :func:`ffmpeg_available`
is reported to the client, which hides the buttons it cannot honour rather than
offering one that fails. The shipped image installs it, so in practice the
capability is on; a source install without it degrades to live-only.

Nothing here uses ``shell=True`` and no argument is ever interpolated into a
shell string — the RTSP URL carries the recorder password, and a password with a
``;`` in it must be a password, not a command.
"""

from __future__ import annotations

import logging
import os
import re
import shutil
import subprocess
import threading

from django.conf import settings

logger = logging.getLogger(__name__)

# How many ffmpeg processes may run at once across this worker.
#
# Sized so a full 3x3 wall streams live *and* someone reviews a recording at the
# same time, because a cap that refuses the ninth camera is indistinguishable
# from a broken ninth camera. Each pipeline is one decode+encode of a
# sub-stream, which is small; the shops that push past this are the ones that
# should raise it, so it is a setting rather than a constant.
DEFAULT_MAX_PROCESSES = 12

# A pipeline that has produced nothing for this long is wedged — a recorder that
# accepted the RTSP session and then stopped sending, which is routine when a
# DVR is busy. The reader kills it; the client reconnects.
DEFAULT_IDLE_TIMEOUT = 20.0

_probe_lock = threading.Lock()
_probe_cache: dict | None = None

_process_lock = threading.Lock()
_process_count = 0


def _setting(name, default):
    return getattr(settings, name, default)


def ffmpeg_path() -> str:
    configured = str(_setting("POINTY_FFMPEG_PATH", "") or "").strip()
    if configured:
        return configured if os.path.exists(configured) else ""
    return shutil.which("ffmpeg") or ""


def probe() -> dict:
    """``{"available", "path", "version", "supports_readrate"}``, cached.

    ``readrate`` (ffmpeg 5.1+) is what makes variable-speed playback possible;
    it is the generalisation of ``-re``. Without it playback still works, at 1x
    only, so the capability is reported rather than assumed.
    """
    global _probe_cache
    if _probe_cache is not None:
        return _probe_cache
    with _probe_lock:
        if _probe_cache is not None:
            return _probe_cache
        path = ffmpeg_path()
        result = {
            "available": False,
            "path": path,
            "version": "",
            "supports_readrate": False,
        }
        if path:
            try:
                completed = subprocess.run(
                    [path, "-hide_banner", "-version"],
                    capture_output=True,
                    timeout=10,
                    check=False,
                )
                banner = completed.stdout.decode("utf-8", "replace")
                match = re.search(r"ffmpeg version (\d+)\.(\d+)", banner)
                result["available"] = completed.returncode == 0
                if match:
                    major, minor = int(match.group(1)), int(match.group(2))
                    result["version"] = f"{major}.{minor}"
                    result["supports_readrate"] = (major, minor) >= (5, 1)
            except (OSError, subprocess.SubprocessError) as exc:
                logger.warning("ffmpeg probe failed: %s", exc)
        _probe_cache = result
        return result


def reset_probe_cache():
    """Test seam: forget what we learned about the host's ffmpeg."""
    global _probe_cache
    with _probe_lock:
        _probe_cache = None


def ffmpeg_available() -> bool:
    return bool(probe()["available"])


def max_processes() -> int:
    return int(_setting("POINTY_SURVEILLANCE_MAX_FFMPEG", DEFAULT_MAX_PROCESSES))


class TranscodeUnavailable(RuntimeError):
    """ffmpeg is missing, or every slot is already in use."""


class _Slot:
    """A reservation on the process budget, released exactly once."""

    def __init__(self):
        self._released = False

    def release(self):
        global _process_count
        if self._released:
            return
        self._released = True
        with _process_lock:
            _process_count = max(0, _process_count - 1)


def reserve_slot() -> _Slot:
    global _process_count
    with _process_lock:
        if _process_count >= max_processes():
            raise TranscodeUnavailable(
                "Too many camera streams are already running. "
                "Close one and try again."
            )
        _process_count += 1
    return _Slot()


def active_process_count() -> int:
    return _process_count


def _base_input_args(url: str, *, readrate: float | None) -> list[str]:
    args = [
        "-hide_banner",
        "-loglevel",
        "error",
        "-nostdin",
        # TCP, always. UDP RTSP over a shop's wifi loses packets and the result
        # is a smeared frame the owner reads as a broken feature; the recorder
        # is three metres away, so the cost of TCP is nothing.
        "-rtsp_transport",
        "tcp",
    ]
    if readrate is not None and probe()["supports_readrate"]:
        args += ["-readrate", f"{readrate:g}"]
    elif readrate is not None:
        # No readrate support: pace at 1x, the only rate ``-re`` offers.
        args += ["-re"]
    return args + ["-i", url]


def open_mjpeg_stream(
    url: str,
    *,
    fps: int = 8,
    quality: int = 6,
    width: int = 0,
    readrate: float | None = None,
) -> tuple[subprocess.Popen, _Slot]:
    """Start ffmpeg turning an RTSP stream into a pipe of JPEG frames.

    The caller owns the process and MUST call ``terminate``/``wait`` and release
    the returned slot; :mod:`apps.surveillance.streaming` does both in a
    ``finally``. ``quality`` is ffmpeg's ``-q:v`` (2 best, 31 worst); 6 is a
    clean tile at a fraction of the bytes.
    """
    path = ffmpeg_path()
    if not path:
        raise TranscodeUnavailable(
            "Video playback needs ffmpeg, which is not installed on this server."
        )
    slot = reserve_slot()
    args = [path] + _base_input_args(url, readrate=readrate)
    args += ["-an", "-f", "mjpeg", "-q:v", str(int(quality)), "-r", str(int(fps))]
    if width:
        # -2 keeps the aspect ratio and an even height, which the JPEG encoder
        # requires for chroma-subsampled output.
        args += ["-vf", f"scale={int(width)}:-2"]
    args += ["pipe:1"]
    return _spawn(args, slot)


def open_mp4_stream(url: str) -> tuple[subprocess.Popen, _Slot]:
    """Remux an RTSP playback stream into a downloadable MP4, without re-encoding.

    ``-c copy`` is the point: an export is a byte-for-byte copy of what the
    recorder already stored, so a ten-minute clip takes seconds and costs no
    quality. The fragmented ``movflags`` are what let it stream from a pipe —
    a normal MP4 writes its index at the end and therefore needs a seekable
    output, which a download response is not.
    """
    path = ffmpeg_path()
    if not path:
        raise TranscodeUnavailable(
            "Exporting video needs ffmpeg, which is not installed on this server."
        )
    slot = reserve_slot()
    args = [path] + _base_input_args(url, readrate=None)
    args += [
        "-c",
        "copy",
        # Recorders routinely start a playback stream mid-GOP with timestamps
        # that begin negative; without these the file plays back with a stall at
        # the front or refuses to open at all.
        "-fflags",
        "+genpts",
        "-avoid_negative_ts",
        "make_zero",
        "-f",
        "mp4",
        "-movflags",
        "frag_keyframe+empty_moov+default_base_moof",
        "pipe:1",
    ]
    return _spawn(args, slot)


def _spawn(args: list[str], slot: _Slot) -> tuple[subprocess.Popen, _Slot]:
    try:
        process = subprocess.Popen(  # noqa: S603 - fixed argv, never a shell
            args,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            stdin=subprocess.DEVNULL,
            bufsize=0,
        )
    except OSError as exc:
        slot.release()
        raise TranscodeUnavailable(f"Could not start ffmpeg: {exc}") from exc
    return process, slot


def stop(process: subprocess.Popen, slot: _Slot | None = None):
    """End a pipeline and reap it. Safe to call twice, and never raises.

    ffmpeg holding an RTSP session open is not free on the recorder — a DVR has
    a hard cap on concurrent sessions and hands out "device busy" once it is
    reached — so a stream nobody is watching has to actually die, promptly.
    """
    try:
        if process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=3)
    except Exception:  # pragma: no cover - defensive
        logger.debug("ffmpeg teardown failed", exc_info=True)
    finally:
        for pipe in (process.stdout, process.stderr):
            try:
                if pipe is not None:
                    pipe.close()
            except Exception:  # pragma: no cover - defensive
                pass
        if slot is not None:
            slot.release()


def drain_error(process: subprocess.Popen, limit: int = 2000) -> str:
    """ffmpeg's last words, for the log line that explains a dead stream."""
    try:
        if process.stderr is None:
            return ""
        return process.stderr.read(limit).decode("utf-8", "replace").strip()
    except Exception:  # pragma: no cover - defensive
        return ""
