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

# Seconds a producer keeps running with nobody watching.
#
# Raised from 6s after the first field install (2026-09-08): six seconds covers
# a page reload but *not* a person scrolling a camera out of view, glancing at
# another, and scrolling back — which is the single most common thing anyone
# does with a wall of tiles. Every one of those cost a full ffmpeg cold start
# against the DVR, and the owner reads that as the feature being broken.
#
# The cost of holding it open is one ffmpeg per camera someone was recently
# watching, which is why this is a linger and not a keep-warm: a shop that
# navigates away from the wall entirely still stops loading its recorder inside
# a minute.
DEFAULT_LINGER_SECONDS = 30.0

# How long a retired stream's final frame stays worth showing.
#
# A cold start cannot produce a frame until the recorder has accepted an RTSP
# session and sent a keyframe — seconds, on the boxes in this market. Painting
# the last frame we held immediately turns that wait from a blank tile into a
# still image that starts moving, which is the difference between "slow" and
# "broken". Past this, a stale frame would be a lie about what the camera can
# see, so it is dropped and the tile waits honestly.
DEFAULT_LAST_FRAME_TTL_SECONDS = 300.0

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
        #: Read by the viewer that started this producer, for telemetry. A
        #: complaining decoder is the signal behind a picture that looks wrong
        #: rather than absent, and it is invisible anywhere else.
        self.stats: dict = {}

    def frames(self, should_stop):
        process, slot = transcode.open_mjpeg_stream(
            self.url,
            fps=self.fps,
            quality=self.quality,
            width=self.width,
            readrate=self.speed,
        )
        try:
            yield from _jpeg_frames(
                process,
                should_stop,
                seconds_per_frame=(self.speed or 1.0) / self.fps,
                anchor=self.anchor,
            )
        finally:
            self.stats["decoder_complaints"] = len(
                getattr(process, "_pointy_errors", ()) or ()
            )
            transcode.stop(process, slot)


class PipedSource:
    """Playback for recorders whose stored video is not reachable over RTSP.

    The driver speaks its own protocol, produces an H.264 elementary stream, and
    a writer thread pushes it into ffmpeg's stdin; from ffmpeg onwards this is
    the same MJPEG pipe as everything else, so the broker, the views and the
    client cannot tell the difference.

    The thread exists because the driver's byte generator blocks on the DVR's
    socket while the consumer blocks on ffmpeg's stdout. Driving both from one
    thread would deadlock the moment ffmpeg's input buffer filled — which for a
    quarter-hour recording is immediately.

    This source owns the driver, unlike the URL path where the driver is closed
    before streaming starts: here it *is* the source of the bytes, and its DVRIP
    session has to outlive the response.
    """

    def __init__(
        self,
        driver,
        channel,
        start,
        end,
        *,
        quality=StreamQuality.MAIN,
        fps=8,
        quality_scale=6,
        width=0,
        speed=None,
        label="",
    ):
        self.driver = driver
        self.channel = channel
        self.start = start
        self.end = end
        self.quality = quality
        self.fps = max(int(fps), 1)
        self.quality_scale = quality_scale
        self.width = width
        self.speed = speed
        self.label = label
        self._upstream_error = ""
        self.stats: dict = {}

    def frames(self, should_stop):
        process, slot = transcode.open_mjpeg_from_h264(
            fps=self.fps, quality=self.quality_scale, width=self.width
        )
        stop_writing = threading.Event()
        writer = threading.Thread(
            target=self._pump,
            args=(process, stop_writing),
            name=f"surveillance-feed-{self.label[:30]}",
            daemon=True,
        )
        writer.start()
        try:
            yield from _jpeg_frames(
                process,
                should_stop,
                seconds_per_frame=(self.speed or 1.0) / self.fps,
                anchor=self.start,
                # The recorder's complaint beats ffmpeg's: "no footage stored
                # for that time" is actionable, "invalid data found" is not.
                on_empty=lambda: self._upstream_error,
            )
        finally:
            stop_writing.set()
            self.stats["decoder_complaints"] = len(
                getattr(process, "_pointy_errors", ()) or ()
            )
            # Whatever the driver read off the wire on the way past — the codec
            # and geometry a recorder is really sending, which no probe of ours
            # would otherwise see.
            self.stats.update(getattr(self.driver, "stream_stats", None) or {})
            transcode.stop(process, slot)
            writer.join(timeout=5)
            self.driver.close()

    def _pump(self, process, stop_writing):
        stdin = process.stdin
        try:
            stream = self.driver.playback_stream(
                self.channel, self.start, self.end, quality=self.quality
            )
            try:
                for chunk in stream:
                    if stop_writing.is_set():
                        break
                    stdin.write(chunk)
            finally:
                # Closing the generator runs the driver's own cleanup, which is
                # what tells the recorder to stop the download. Without it the
                # box keeps a session open for a viewer who has walked away, and
                # it only holds a handful.
                stream.close()
        except RecorderError as exc:
            self._upstream_error = str(exc)
        except (BrokenPipeError, OSError):
            # ffmpeg exited first — normal when the viewer navigates away.
            pass
        except Exception as exc:  # noqa: BLE001 - surfaced through _upstream_error
            self._upstream_error = str(exc) or exc.__class__.__name__
            logger.info("playback feed for %s failed: %s", self.label, exc)
        finally:
            try:
                stdin.close()
            except OSError:
                pass


def _jpeg_frames(process, should_stop, *, seconds_per_frame, anchor, on_empty=None):
    """Demux ffmpeg's MJPEG pipe into frames, whatever fed it.

    Shared by the URL-driven source and the piped one so the two cannot drift:
    the frame clock, the size ceiling and the "no video at all" diagnosis are
    the same question regardless of how the video reached ffmpeg.

    ``on_empty`` lets the caller supply a better explanation when nothing was
    produced — for a piped source the real cause is usually upstream of ffmpeg,
    and ffmpeg's own complaint would only describe the symptom.
    """
    buffer = bytearray()
    sequence = 0
    stdout = process.stdout
    while not should_stop():
        chunk = stdout.read(65536)
        if not chunk:
            if sequence == 0:
                upstream = on_empty() if on_empty else None
                raise StreamError(
                    upstream
                    or _humanize_ffmpeg_error(transcode.drain_error(process))
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
                anchor + timedelta(seconds=(sequence - 1) * seconds_per_frame)
                if anchor is not None
                else datetime.now(dt_timezone.utc)
            )
            yield Frame(data=payload[start:], sequence=sequence, captured_at=captured_at)


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
        # The last frame each stream produced, kept past the producer's death so
        # a reattach paints instantly. Bounded by the same ceiling as producers,
        # so this is a few MB of JPEG at worst, and every entry is one a person
        # was recently looking at.
        self._last_frames: dict[str, Frame] = {}

    @property
    def linger_seconds(self):
        return float(
            _setting("POINTY_SURVEILLANCE_LINGER_SECONDS", DEFAULT_LINGER_SECONDS)
        )

    @property
    def last_frame_ttl_seconds(self):
        return float(
            _setting(
                "POINTY_SURVEILLANCE_LAST_FRAME_TTL_SECONDS",
                DEFAULT_LAST_FRAME_TTL_SECONDS,
            )
        )

    def remember(self, key: str, frame: Frame):
        with self._lock:
            self._last_frames[key] = frame
            # Evict in insertion order rather than by age: the oldest inserted
            # is the one nobody has watched for longest, and a dict preserves
            # that ordering for free.
            while len(self._last_frames) > self.max_producers:
                self._last_frames.pop(next(iter(self._last_frames)))

    def last_frame(self, key: str) -> Frame | None:
        """The newest frame this stream produced, if it is still worth showing."""
        ttl = self.last_frame_ttl_seconds
        if ttl <= 0:
            return None
        with self._lock:
            frame = self._last_frames.get(key)
        if frame is None:
            return None
        now = datetime.now(dt_timezone.utc)
        age = (now - frame.captured_at).total_seconds()
        if age > ttl or age < -60:
            # Negative means a playback frame from the future of this window —
            # not a live still, and not something to paint as one.
            return None
        return frame

    def forget(self, key: str):
        with self._lock:
            self._last_frames.pop(key, None)

    def _evict_idle_locked(self):
        """Reclaim the longest-idle unwatched producer. Caller holds ``_lock``.

        Lingering is what makes scrolling a wall cheap, but it also means a
        person who scrolls past sixteen cameras can leave every slot held by a
        stream nobody is watching — and then the camera they actually stopped
        on is refused with "too many streams", which is a worse bug than the
        one the linger fixed.

        So a viewer always wins against a linger: the least recently watched
        idle producer is told to stop. Producers with a live subscriber are
        never touched, which is why this can still refuse — a genuine wall of
        real viewers is the case the ceiling exists for.
        """
        idle = [
            (producer.idle_since, key, producer)
            for key, producer in self._producers.items()
            if producer.subscribers == 0 and not producer.finished
        ]
        if not idle:
            return
        _, key, producer = min(idle, key=lambda item: item[0])
        with producer.lock:
            if producer.subscribers or producer.finished:
                # Someone attached while we were choosing. Leave it alone and
                # let the ceiling refuse instead of killing a live viewer's
                # picture to make room for another.
                return
            producer.finished = True
            producer.lock.notify_all()
        # Drop it from the registry now rather than waiting for the thread to
        # notice: the caller is about to check the ceiling again, and the
        # producer's own ``_retire`` is idempotent about a key already gone.
        if self._producers.get(key) is producer:
            del self._producers[key]
        logger.debug("camera stream %s evicted to make room", key)

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
        # Hold on to what it last showed, so the next viewer of this camera
        # sees that instead of a blank tile while ffmpeg starts again.
        final = producer.latest
        if final is not None:
            self.remember(key, final)

    @contextmanager
    def subscribe(self, key: str, build_source, report=None):
        """Join (or start) the producer for ``key`` and iterate its frames.

        ``build_source`` is called only when a producer has to be created, so
        the common case — a second viewer of a camera someone is already
        watching — never opens a connection to the recorder at all.
        """
        started_cold = False
        with self._lock:
            producer = self._producers.get(key)
            if producer is not None and producer.finished:
                producer = None
            if producer is None:
                if len(self._producers) >= self.max_producers:
                    self._evict_idle_locked()
                if len(self._producers) >= self.max_producers:
                    raise StreamError(
                        "Too many camera streams are open on this server."
                    )
                producer = _Producer(key, build_source(), self)
                self._producers[key] = producer
                producer.attach()
                producer.thread.start()
                started_cold = True
            else:
                producer.attach()
        # Only a cold start needs the warm frame. Joining a producer that is
        # already running yields its current frame immediately anyway, and
        # prepending a stale one there would show a viewer a step backwards.
        warm = self.last_frame(key) if started_cold else None
        if report is not None:
            # Whether this viewer paid for a cold start, and whether the warm
            # cache spared them the wait, are the two questions the linger and
            # last-frame work exists to answer.
            report.shared = not started_cold
            report.warm_start = warm is not None
        try:
            yield self._with_warm_frame(warm, producer.stream(self.stall_seconds))
        finally:
            producer.detach()

    @staticmethod
    def _with_warm_frame(warm: Frame | None, live):
        """Paint the last known frame first, then hand over to the live stream.

        The sequence is rewritten to 0 so it cannot collide with the new
        producer's numbering, which restarts at 1 — without that, a cached
        sequence of 500 would make ``stream()`` discard every real frame until
        the producer caught up, and the tile would sit on a still image
        forever.
        """
        if warm is not None:
            yield Frame(
                data=warm.data, sequence=0, captured_at=warm.captured_at
            )
        yield from live

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
