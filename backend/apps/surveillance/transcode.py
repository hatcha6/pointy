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

import collections
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

#: Audio encoders a live listen can be served with, best first, as
#: ``(encoder, container)``. ``aac`` is ffmpeg's own — built into every build
#: including the minimal ones, needing no external library — and ADTS is a
#: self-framing byte stream, which is what lets it be played straight off a
#: chunked HTTP response the way an internet radio station is. libmp3lame is
#: only a fallback for a build that somehow lacks the native encoder.
AUDIO_ENCODERS = (("aac", "adts"), ("libmp3lame", "mp3"))

#: Sound from a shop camera is a G.711 telephone-quality microphone at best, so
#: there is nothing above this to preserve. 32 kbps mono is transparent for it
#: and costs a fifteenth of the video beside it.
AUDIO_BITRATE_KBPS = 32
AUDIO_SAMPLE_RATE = 16000

#: Opening an RTSP session and reading far enough to answer "is there a
#: microphone on this channel" against a busy DVR. Generous because the answer
#: is cached on the camera row and asked once, not per listen.
AUDIO_PROBE_TIMEOUT = 15.0

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
    """``{"available", "path", "version", "supports_readrate", "supports_fps_mode"}``, cached.

    ``readrate`` (ffmpeg 5.1+) is what makes variable-speed playback possible;
    it is the generalisation of ``-re``. Without it playback still works, at 1x
    only, so the capability is reported rather than assumed.

    ``fps_mode`` arrived in the same release and replaces ``-vsync``. The stills
    path needs one of the two, because its whole point is to emit exactly the
    frames it decoded and no duplicates; ``-vsync 0`` is the fallback and still
    works everywhere, it merely warns.
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
            "supports_fps_mode": False,
            "audio_encoder": "",
            "audio_format": "",
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
                    result["supports_fps_mode"] = (major, minor) >= (5, 1)
                if result["available"]:
                    encoder, container = _detect_audio_encoder(path)
                    result["audio_encoder"] = encoder
                    result["audio_format"] = container
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


def _detect_audio_encoder(path: str) -> tuple[str, str]:
    """The first of :data:`AUDIO_ENCODERS` this build actually has.

    Asked rather than assumed, like ``supports_readrate`` above it: the shipped
    image has both, but a source install may have an ffmpeg stripped to the
    video codecs, and a listen button that dies inside ffmpeg is worse than one
    that was never drawn.
    """
    try:
        completed = subprocess.run(
            [path, "-hide_banner", "-encoders"],
            capture_output=True,
            timeout=10,
            check=False,
        )
    except (OSError, subprocess.SubprocessError) as exc:
        logger.warning("ffmpeg audio encoder probe failed: %s", exc)
        return "", ""
    listing = completed.stdout.decode("utf-8", "replace")
    for encoder, container in AUDIO_ENCODERS:
        # The encoder table's rows begin with capability flags; the leading "A"
        # is what marks an audio encoder, and anchoring on it keeps a decoder
        # or a filter with a colliding name from matching.
        if re.search(rf"^\s*A\S*\s+{re.escape(encoder)}\s", listing, re.M):
            return encoder, container
    return "", ""


def audio_available() -> bool:
    """Whether this server can serve camera sound at all."""
    return bool(probe()["available"] and probe()["audio_encoder"])


def ffprobe_path() -> str:
    """ffprobe ships beside ffmpeg in every build and package we use."""
    binary = ffmpeg_path()
    if not binary:
        return ""
    candidate = binary.replace("ffmpeg", "ffprobe")
    if candidate != binary and os.path.exists(candidate):
        return candidate
    return shutil.which("ffprobe") or ""


def audio_track(url: str) -> str:
    """The codec of this stream's first audio track, or ``""`` if it has none.

    Measured, never assumed. Most analogue cameras have no microphone — sound
    on an XVR arrives on separate RCA inputs or over coax from the few HDCVI
    cameras that carry it — so on a typical install *some* channels are silent
    and the rest do not exist as audio at all. Guessing the other way is the
    snapshot-polling failure in a different costume: a listen button wired to a
    channel with no microphone opens a pipeline that can only ever time out.

    Slow (it opens an RTSP session), so the answer belongs in a cache on the
    camera row; this is the call behind that cache, not a per-listen check.
    """
    path = ffprobe_path()
    if not path:
        raise TranscodeUnavailable(
            "Checking a camera for sound needs ffprobe, which is not installed "
            "on this server."
        )
    args = [
        path,
        "-hide_banner",
        "-loglevel",
        "error",
        "-rtsp_transport",
        "tcp",
        # Deliberately NOT ``-allowed_media_types audio`` here, though the
        # stream itself does use it. Asking a server for audio-only on a
        # channel that HAS NO AUDIO makes it refuse the session outright — the
        # rig answers 501, a DVR will have its own number — and a refusal is
        # indistinguishable from a recorder that is down. Without the filter
        # the same channel answers successfully with nothing, which is the
        # question we actually asked. Getting this backwards means "no
        # microphone" never caches, and every tap re-opens an RTSP session
        # forever: the snapshot-polling failure, again.
        "-select_streams",
        "a:0",
        "-show_entries",
        "stream=codec_name",
        "-of",
        "default=nokey=1:noprint_wrappers=1",
        url,
    ]
    try:
        completed = subprocess.run(  # noqa: S603 - fixed argv, never a shell
            args, capture_output=True, timeout=AUDIO_PROBE_TIMEOUT, check=False
        )
    except subprocess.TimeoutExpired as exc:
        raise TranscodeUnavailable(
            "The recorder did not answer in time when it was checked for sound."
        ) from exc
    except OSError as exc:
        raise TranscodeUnavailable(f"Could not start ffprobe: {exc}") from exc
    if completed.returncode != 0:
        detail = redact_secrets(completed.stderr.decode("utf-8", "replace").strip())
        raise TranscodeUnavailable(
            detail or "The stream could not be opened to check it for sound."
        )
    # No audio track is a *successful* probe with empty output, which is the
    # answer we want rather than an error: this channel has no microphone.
    return completed.stdout.decode("utf-8", "replace").strip()


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


def _base_input_args(
    url: str,
    *,
    readrate: float | None,
    low_latency: bool = False,
    keyframes_only: bool = False,
    allowed_media_types: str = "",
) -> list[str]:
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
    if low_latency:
        # ffmpeg's defaults buy stream-detection accuracy with time: it reads up
        # to 5 MB or 5 seconds of input before it will emit anything. For a live
        # tile that is the entire wait — the shop sees a blank square while
        # ffmpeg makes up its mind about a stream we already know is H.264 over
        # RTSP. Half a second and 512 KB is ample to find the parameter sets on
        # every box we have seen, and cuts the cold start by several seconds.
        #
        # Deliberately NOT applied to the export/playback path: there a wrong
        # guess about the stream corrupts a file somebody keeps, and the extra
        # seconds cost nobody anything.
        args += [
            # `discardcorrupt` is the one that matters for picture quality: a
            # damaged packet fed to the decoder is decoded anyway, onto whatever
            # the reference frame holds, and the result is a still image with
            # colour only where something moved. Dropping the packet costs a
            # frame; decoding it costs the picture.
            "-fflags",
            "nobuffer+discardcorrupt",
            "-flags",
            "low_delay",
            # Deliberately not as small as they could be. Cutting these buys
            # start-up time, but cut too far and ffmpeg begins before it has the
            # parameter sets and the first keyframe — which produces exactly the
            # grey-with-moving-colour picture this file is trying to avoid. Half
            # a megabyte and a second still saves most of the default 5s wait.
            "-probesize",
            "1048576",
            "-analyzeduration",
            "1000000",
        ]
    if allowed_media_types:
        # Filters what the server is asked to SETUP, not what ffmpeg keeps — so
        # an audio pull never has the video sent to it in the first place. That
        # is the difference between a listen costing a few KB/s and it costing
        # a whole second video stream off a DVR that is counting them.
        args += ["-allowed_media_types", allowed_media_types]
    if readrate is not None and probe()["supports_readrate"]:
        args += ["-readrate", f"{readrate:g}"]
    elif readrate is not None:
        # No readrate support: pace at 1x, the only rate ``-re`` offers.
        args += ["-re"]
    if keyframes_only:
        # A decoder option, so it belongs before -i: ffmpeg discards every
        # non-key frame at the decoder rather than after it, which is where
        # essentially all the CPU of an H.264 stream is spent. The output rate
        # then follows the recorder's keyframe interval — a second or two on the
        # boxes in this market, which is the rate a dashboard tile wants anyway.
        args += ["-skip_frame", "nokey"]
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
    args = [path] + _base_input_args(
        url, readrate=readrate, low_latency=readrate is None
    )
    args += ["-an", "-f", "mjpeg", "-q:v", str(int(quality)), "-r", str(int(fps))]
    if width:
        # -2 keeps the aspect ratio and an even height, which the JPEG encoder
        # requires for chroma-subsampled output.
        args += ["-vf", f"scale={int(width)}:-2"]
    args += ["pipe:1"]
    return _spawn(args, slot)


def open_mjpeg_stills(
    url: str, *, quality: int = 6, width: int = 0
) -> tuple[subprocess.Popen, _Slot]:
    """The cheap live path for a recorder that serves no still images.

    Same JPEG pipe as :func:`open_mjpeg_stream`, with two differences that are
    the entire point. It decodes **keyframes only**, which is most of an H.264
    decode avoided; and it emits exactly the frames it decoded rather than
    padding to a fixed rate, so a recorder with a two-second keyframe interval
    costs one decode and one small JPEG every two seconds instead of a
    continuous transcode.

    This exists because a dashboard is a screen people leave open all day, and
    on a recorder with a still-image endpoint that costs nothing at all. On one
    without — Xiongmai has none — the only way to reach a frame is the video
    stream, and the choice is between this and running a full decode per camera
    for as long as the shop is open.

    The caller owns the process and MUST call ``stop``/release the slot, exactly
    as for :func:`open_mjpeg_stream`.
    """
    path = ffmpeg_path()
    if not path:
        raise TranscodeUnavailable(
            "Video playback needs ffmpeg, which is not installed on this server."
        )
    slot = reserve_slot()
    args = [path] + _base_input_args(
        url, readrate=None, low_latency=True, keyframes_only=True
    )
    args += ["-an", "-f", "mjpeg", "-q:v", str(int(quality))]
    # Passthrough, never a target rate: with -r, ffmpeg duplicates the last
    # keyframe to fill the gaps, and a tile would pay an encode and a network
    # frame for a picture it already has.
    args += (
        ["-fps_mode", "passthrough"]
        if probe()["supports_fps_mode"]
        else ["-vsync", "0"]
    )
    if width:
        # ``min(w, iw)`` so this only ever shrinks. A sub-stream is often
        # narrower than the tile already, and upscaling it would cost bytes and
        # sharpness to deliver exactly the same picture.
        args += ["-vf", f"scale='min({int(width)},iw)':-2"]
    args += ["pipe:1"]
    return _spawn(args, slot)


def open_mjpeg_from_h264(
    *, fps: int = 8, quality: int = 6, width: int = 0
) -> tuple[subprocess.Popen, _Slot]:
    """Same JPEG pipe as :func:`open_mjpeg_stream`, fed from stdin.

    For recorders whose stored video is not reachable over RTSP: the driver
    speaks its own protocol, hands us an H.264 elementary stream, and we push it
    in rather than giving ffmpeg an address. ``-f h264`` is required — a bare
    elementary stream has no container for ffmpeg to recognise, and without the
    hint it probes forever and gives up.

    The caller owns the process, MUST feed ``stdin`` and MUST call
    ``stop``/release the slot; :class:`apps.surveillance.streaming.PipedSource`
    does all three.
    """
    path = ffmpeg_path()
    if not path:
        raise TranscodeUnavailable(
            "Video playback needs ffmpeg, which is not installed on this server."
        )
    slot = reserve_slot()
    args = [
        path,
        "-hide_banner",
        "-loglevel",
        "error",
        # No -nostdin here, unlike every other invocation: stdin is the input.
        "-f",
        "h264",
        "-i",
        "pipe:0",
        "-an",
        "-f",
        "mjpeg",
        "-q:v",
        str(int(quality)),
        "-r",
        str(int(fps)),
    ]
    if width:
        args += ["-vf", f"scale={int(width)}:-2"]
    args += ["pipe:1"]
    return _spawn(args, slot, stdin=subprocess.PIPE)


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


def open_audio_stream(
    url: str,
    *,
    bitrate_kbps: int = AUDIO_BITRATE_KBPS,
    sample_rate: int = AUDIO_SAMPLE_RATE,
) -> tuple[subprocess.Popen, _Slot]:
    """Start ffmpeg turning an RTSP stream's sound into a pipe of audio bytes.

    Sound is a **second pipeline beside the video**, not part of it, because the
    live wire format is MJPEG and MJPEG has nowhere to put audio. Muxing both
    into a real container instead would buy lip-sync and cost the property the
    whole feature was built on — that a till needs no video codec to show a
    camera. Nobody lip-reads a shop camera, so the trade is not close.

    That makes a listen a second RTSP session on the recorder, which is why the
    caller must take a stream seat for it like any other pull.

    The output is a bare self-framing byte stream (ADTS, or MP3), so it plays
    from a chunked HTTP response with no container index and no seeking — the
    same shape as an internet radio station, which is the one live-audio shape
    every platform's player already handles.
    """
    path = ffmpeg_path()
    if not path:
        raise TranscodeUnavailable(
            "Listening to a camera needs ffmpeg, which is not installed on this "
            "server."
        )
    encoder = probe()["audio_encoder"]
    container = probe()["audio_format"]
    if not encoder:
        raise TranscodeUnavailable(
            "This server's ffmpeg has no audio encoder, so cameras cannot be "
            "listened to."
        )
    slot = reserve_slot()
    args = [path] + _base_input_args(
        url, readrate=None, low_latency=True, allowed_media_types="audio"
    )
    args += [
        # Belt and braces behind ``-allowed_media_types``: if a firmware
        # ignores the filter and sends video anyway, it is dropped here rather
        # than decoded. An audio pull that decoded H.264 would cost as much as
        # a second tile.
        "-vn",
        "-ac",
        "1",
        "-ar",
        str(int(sample_rate)),
        "-c:a",
        encoder,
        "-b:a",
        f"{int(bitrate_kbps)}k",
        # Without this the muxer fills a buffer before writing, which on a
        # 32 kbps stream is seconds of silence before the first sound and a
        # permanent lag behind the picture after it.
        "-flush_packets",
        "1",
        "-f",
        container,
        "pipe:1",
    ]
    return _spawn(args, slot)


#: How many of ffmpeg's last complaints to keep per pipeline.
ERROR_LINES_KEPT = 40

#: A recorder's password reaches ffmpeg inside the URL, and ffmpeg quotes the
#: URL back in most of its error messages. Xiongmai carries the credentials
#: twice on purpose — once in the authority, once in the path — so both shapes
#: have to go, and they have to go before the text is stored or logged rather
#: than on the way out. Telemetry leaves the shop; the log is read over a
#: support call; neither is a place for a password.
_SECRET_PATTERNS = (
    # rtsp://user:pass@host -> rtsp://***:***@host
    re.compile(r"(?<=//)[^/\s@]+:[^/\s@]*@"),
    # user=admin&password=secret -> user=***&password=***
    re.compile(r"\b(user(?:name)?|pass(?:word|wd)?|pwd|auth)=[^&\s\"']*", re.I),
)


def redact_secrets(text: str) -> str:
    """Strip recorder credentials out of anything ffmpeg says back to us."""
    if not text:
        return ""
    text = _SECRET_PATTERNS[0].sub("***:***@", text)
    return _SECRET_PATTERNS[1].sub(
        lambda m: f"{m.group(1)}=***", text
    )


def _drain_stderr(process: subprocess.Popen):
    """Read ffmpeg's diagnostics continuously, keeping the last few.

    Two reasons, and the first is a bug rather than an improvement. stderr is a
    pipe with a buffer of a few dozen KB; nothing read it until a stream had
    already failed, so a pipeline that complains steadily — a decoder chewing
    through a damaged stream does exactly that — eventually fills it and
    **ffmpeg blocks writing to it**. The video stops with no error anywhere,
    because the error is what stopped it.

    The second is that those complaints are the only account of what a recorder
    is really sending. Discarding them unread meant a picture problem in a shop
    could only be guessed at from a description of the picture.
    """
    lines = process._pointy_errors
    try:
        for raw in iter(process.stderr.readline, b""):
            line = redact_secrets(raw.decode("utf-8", "replace").strip())
            if not line:
                continue
            lines.append(line)
            logger.info("ffmpeg: %s", line)
    except Exception:  # pragma: no cover - the pipe closing is a normal end
        pass


def _spawn(
    args: list[str], slot: _Slot, *, stdin=subprocess.DEVNULL
) -> tuple[subprocess.Popen, _Slot]:
    try:
        process = subprocess.Popen(  # noqa: S603 - fixed argv, never a shell
            args,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            stdin=stdin,
            bufsize=0,
        )
    except OSError as exc:
        slot.release()
        raise TranscodeUnavailable(f"Could not start ffmpeg: {exc}") from exc
    process._pointy_errors = collections.deque(maxlen=ERROR_LINES_KEPT)
    threading.Thread(
        target=_drain_stderr, args=(process,), name="ffmpeg-stderr", daemon=True
    ).start()
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
    """ffmpeg's last words, for the log line that explains a dead stream.

    Read from what the drainer already collected rather than from the pipe: by
    the time anyone asks, the process is usually gone and the pipe with it.
    """
    lines = getattr(process, "_pointy_errors", None)
    if not lines:
        return ""
    return "\n".join(lines)[-limit:].strip()
