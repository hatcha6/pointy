"""One upstream pull per camera, however many people are watching.

A shop with four tills all showing the wall is the normal case, and the naive
implementation hits the DVR with four times the snapshots — or, worse, four
RTSP sessions, which a 16-channel box simply refuses past its session cap. So
viewers never touch the recorder: they subscribe to a *producer*, keyed by what
is actually being watched (camera, mode, quality, and for playback the window),
and the producer is the only thing that talks to the device.

The subscriber contract is deliberately lossy. A viewer that falls behind skips
to the newest frame rather than accumulating a backlog, because a late frame of
live video is worthless and a queue of them is a memory leak with a spinner in
front of it. That is what makes one slow client — a manager watching over the
relay tunnel — cost the tills on the LAN nothing.

Producers linger briefly after their last viewer leaves so that flipping between
the wall and a single camera, or a reconnect after a wifi blip, reuses the
running pipeline instead of paying ffmpeg's start-up again.
"""

from __future__ import annotations

import logging
import threading
import time
from contextlib import contextmanager
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone as dt_timezone

from django.conf import settings

from . import transcode
from .drivers.base import RecorderError, StreamQuality

logger = logging.getLogger(__name__)

JPEG_SOI = b"\xff\xd8"
JPEG_EOI = b"\xff\xd9"

# Seconds a producer keeps running with nobody watching. Long enough to cover a
# screen change or a page reload, short enough that a shop that closed the wall
# stops loading its DVR almost immediately.
DEFAULT_LINGER_SECONDS = 6.0

# A producer that has published nothing for this long is dead upstream: a
# recorder that accepted the connection and went quiet. Subscribers are released
# with an error so the client can show "reconnecting" and retry.
DEFAULT_STALL_SECONDS = 20.0

# Hard ceiling on distinct producers in one worker. Each is a thread plus, for
# the RTSP paths, an ffmpeg process. Comfortably above a full wall on several
# tills at once, so it is only ever reached by something pathological (a client
# looping requests with a moving timestamp) — where refusing beats thrashing the
# machine the till runs on.
DEFAULT_MAX_PRODUCERS = 32

MAX_FRAME_BYTES = 8 * 1024 * 1024


def _setting(name, default):
    return getattr(settings, name, default)


@dataclass(frozen=True)
class Frame:
    """One JPEG plus what moment it depicts.

    ``captured_at`` is the wall-clock time of the *footage*, not of delivery —
    for playback that is a time in the past, and it is what drives the client's
    scrubber and the timestamp burned into the corner of the player. Live frames
    carry the moment they were pulled.
    """

    data: bytes
    sequence: int
    captured_at: datetime


class StreamError(RuntimeError):
    """The stream could not be started or has died."""


# ---------------------------------------------------------------------------
# Sources
# ---------------------------------------------------------------------------
class SnapshotSource:
    """Live view without ffmpeg: ask the recorder for a JPEG, repeatedly.

    Every DVR worth supporting serves a still over HTTP, so this is the path
    that works on any install. The cost is frame rate — a busy box answers a
    snapshot in 100-300ms — which is why the target rate is a ceiling, not a
    promise, and why the loop measures its own round trip and sleeps only for
    what is left of the interval.
    """

    def __init__(self, driver, channel, *, quality=StreamQuality.SUB, fps=4):
        self.driver = driver
        self.channel = channel
        self.quality = StreamQuality.normalize(quality)
        self.interval = 1.0 / max(float(fps), 0.2)

    def frames(self, should_stop):
        sequence = 0
        consecutive_failures = 0
        try:
            while not should_stop():
                started = time.monotonic()
                try:
                    payload = self.driver.snapshot(self.channel, quality=self.quality)
                    consecutive_failures = 0
                except RecorderError as exc:
                    consecutive_failures += 1
                    # A single miss is a busy encoder, not an outage. Give up
                    # only once the box has refused several in a row, so a
                    # momentarily loaded DVR does not blank the wall.
                    if consecutive_failures >= 4:
                        raise StreamError(str(exc)) from exc
                    time.sleep(min(1.0 * consecutive_failures, 3.0))
                    continue
                if payload[:2] == JPEG_SOI:
                    sequence += 1
                    yield Frame(
                        data=payload,
                        sequence=sequence,
                        captured_at=datetime.now(dt_timezone.utc),
                    )
                remaining = self.interval - (time.monotonic() - started)
                if remaining > 0:
                    time.sleep(remaining)
        finally:
            self.driver.close()


class FfmpegSource:
    """RTSP in, JPEG frames out — used for playback, export stills and smooth live.

    Frame times are computed rather than read back from ffmpeg: with a fixed
    output rate and a known read rate, footage advances exactly
    ``speed / fps`` seconds per frame, which is drift-free against the window
    the caller asked for and needs nothing on the wire. ``anchor`` is where that
    clock starts — the beginning of a playback window, or ``None`` for live,
    where the answer is simply "now".
    """

    def __init__(
        self,
        url,
        *,
        fps=8,
        quality=6,
        width=0,
        speed=None,
        anchor: datetime | None = None,
        label="",
    ):
        self.url = url
        self.fps = max(int(fps), 1)
        self.quality = quality
        self.width = width
        self.speed = speed
        self.anchor = anchor
        self.label = label

    def frames(self, should_stop):
        process, slot = transcode.open_mjpeg_stream(
            self.url,
            fps=self.fps,
            quality=self.quality,
            width=self.width,
            readrate=self.speed,
        )
        seconds_per_frame = (self.speed or 1.0) / self.fps
        buffer = bytearray()
        sequence = 0
        try:
            stdout = process.stdout
            while not should_stop():
                chunk = stdout.read(65536)
                if not chunk:
                    error = transcode.drain_error(process)
                    if sequence == 0:
                        raise StreamError(
                            _humanize_ffmpeg_error(error)
                            or "The recorder did not return any video."
                        )
                    # Ran to the end of the requested window: a normal finish.
                    return
                buffer += chunk
                if len(buffer) > MAX_FRAME_BYTES:
                    raise StreamError("The video stream sent an unreadable frame.")
                while True:
                    end = buffer.find(JPEG_EOI)
                    if end == -1:
                        break
                    payload = bytes(buffer[: end + 2])
                    del buffer[: end + 2]
                    start = payload.find(JPEG_SOI)
                    if start == -1:
                        continue
                    sequence += 1
                    captured_at = (
                        self.anchor
                        + timedelta(seconds=(sequence - 1) * seconds_per_frame)
                        if self.anchor is not None
                        else datetime.now(dt_timezone.utc)
                    )
                    yield Frame(
                        data=payload[start:],
                        sequence=sequence,
                        captured_at=captured_at,
                    )
        finally:
            transcode.stop(process, slot)


def _humanize_ffmpeg_error(raw: str) -> str:
    """Turn ffmpeg's stderr into something a shop owner can act on."""
    lowered = (raw or "").lower()
    if "401" in lowered or "unauthorized" in lowered:
        return "The recorder rejected the username or password."
    if "connection refused" in lowered or "no route to host" in lowered:
        return "The recorder is not answering on the video port (RTSP)."
    if "timed out" in lowered or "timeout" in lowered:
        return "The recorder stopped responding while sending video."
    if "404" in lowered or "not found" in lowered:
        return "The recorder has no footage for that channel and time."
    if "immediate exit" in lowered or "server returned 5" in lowered:
        return "The recorder refused the video request."
    return raw.splitlines()[0][:200] if raw else ""


# ---------------------------------------------------------------------------
# Broker
# ---------------------------------------------------------------------------
class _Producer:
    def __init__(self, key, source, broker):
        self.key = key
        self.source = source
        self.broker = broker
        self.lock = threading.Condition()
        self.latest: Frame | None = None
        self.error: str = ""
        self.finished = False
        self.subscribers = 0
        self.idle_since = time.monotonic()
        self.started_at = time.monotonic()
        self.thread = threading.Thread(
            target=self._run,
            name=f"surveillance-{key[:40]}",
            daemon=True,
        )

    # -- producer side -----------------------------------------------------
    def _should_stop(self):
        with self.lock:
            if self.finished:
                return True
            if self.subscribers:
                return False
            return (time.monotonic() - self.idle_since) > self.broker.linger_seconds

    def _run(self):
        error = ""
        try:
            for frame in self.source.frames(self._should_stop):
                with self.lock:
                    self.latest = frame
                    self.lock.notify_all()
        except Exception as exc:  # noqa: BLE001 - surfaced to every subscriber
            error = str(exc) or exc.__class__.__name__
            logger.info("camera stream %s ended: %s", self.key, error)
        finally:
            with self.lock:
                self.error = error
                self.finished = True
                self.lock.notify_all()
            self.broker._retire(self.key, self)

    # -- consumer side -----------------------------------------------------
    def attach(self):
        with self.lock:
            self.subscribers += 1

    def detach(self):
        with self.lock:
            self.subscribers = max(0, self.subscribers - 1)
            if not self.subscribers:
                self.idle_since = time.monotonic()
            self.lock.notify_all()

    def stream(self, stall_seconds):
        """Yield frames as they arrive, newest-only, until the producer ends."""
        last_sequence = 0
        last_progress = time.monotonic()
        while True:
            with self.lock:
                while (
                    (self.latest is None or self.latest.sequence <= last_sequence)
                    and not self.finished
                ):
                    if not self.lock.wait(timeout=1.0):
                        # Nothing yet. A stream that has never produced gets the
                        # same patience as one that has stopped: both are the
                        # recorder failing to send, and both end the same way.
                        if time.monotonic() - last_progress > stall_seconds:
                            raise StreamError(
                                "The recorder stopped sending video."
                            )
                if self.latest is not None and self.latest.sequence > last_sequence:
                    frame = self.latest
                    last_sequence = frame.sequence
                    last_progress = time.monotonic()
                elif self.finished:
                    if self.error:
                        raise StreamError(self.error)
                    return
                else:
                    continue
            yield frame


class FrameBroker:
    def __init__(self):
        self._lock = threading.Lock()
        self._producers: dict[str, _Producer] = {}

    @property
    def linger_seconds(self):
        return float(
            _setting("POINTY_SURVEILLANCE_LINGER_SECONDS", DEFAULT_LINGER_SECONDS)
        )

    @property
    def stall_seconds(self):
        return float(
            _setting("POINTY_SURVEILLANCE_STALL_SECONDS", DEFAULT_STALL_SECONDS)
        )

    @property
    def max_producers(self):
        return int(
            _setting("POINTY_SURVEILLANCE_MAX_PRODUCERS", DEFAULT_MAX_PRODUCERS)
        )

    def _retire(self, key, producer):
        with self._lock:
            if self._producers.get(key) is producer:
                del self._producers[key]

    @contextmanager
    def subscribe(self, key: str, build_source):
        """Join (or start) the producer for ``key`` and iterate its frames.

        ``build_source`` is called only when a producer has to be created, so
        the common case — a second viewer of a camera someone is already
        watching — never opens a connection to the recorder at all.
        """
        with self._lock:
            producer = self._producers.get(key)
            if producer is not None and producer.finished:
                producer = None
            if producer is None:
                if len(self._producers) >= self.max_producers:
                    raise StreamError(
                        "Too many camera streams are open on this server."
                    )
                producer = _Producer(key, build_source(), self)
                self._producers[key] = producer
                producer.attach()
                producer.thread.start()
            else:
                producer.attach()
        try:
            yield producer.stream(self.stall_seconds)
        finally:
            producer.detach()

    def shutdown(self):
        """Test seam: stop every producer and wait for the threads to unwind."""
        with self._lock:
            producers = list(self._producers.values())
        for producer in producers:
            with producer.lock:
                producer.finished = True
                producer.lock.notify_all()
        for producer in producers:
            producer.thread.join(timeout=5)
        with self._lock:
            self._producers.clear()

    def active_keys(self):
        with self._lock:
            return sorted(self._producers)


broker = FrameBroker()
