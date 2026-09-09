"""What we learn from a camera stream, without becoming the reason it is slow.

Telemetry has taken this product down before — 5.1 million rejected ingest calls
were 70% of one shop's server time, and the 2026-08-17 outage was worker
starvation from the same source. So the rules here are not stylistic:

**One row per stream session, never per frame.** A nine-tile wall at 8fps is 72
frames a second; a row each would be a self-inflicted write storm on the machine
the till runs on. A session accumulates in memory — the per-frame cost is one
integer increment — and writes once when it ends.

**Failures are throttled, successes are not.** A working stream ends when a
person navigates away, so successes are bounded by human behaviour. A broken one
is retried by a client that does not know better, and a camera unplugged on a
Friday would otherwise write rows until Monday. Repeats inside the window are
counted, not written.

**Nothing here may raise, and nothing may block.** Every entry point swallows its
own errors: a telemetry bug must never be the reason a shop cannot see its
cameras. Rows go through ``record_event_buffered``, which batches them into one
bulk INSERT per window and drops a failed batch instead of retrying it.

What it is *for* is the questions we could not answer from the field: how long a
tile really takes to show a picture, whether the warm-frame cache is earning its
keep, which drivers fail and how, and whether a recorder is sending video ffmpeg
has to complain about — which is the difference between diagnosing a shop's
picture problem and guessing at it from a description.
"""

from __future__ import annotations

import logging
import threading
import time
from dataclasses import dataclass, field

from django.conf import settings

logger = logging.getLogger(__name__)

EVENT_NAME = "camera.stream"

#: Outcomes, ordered roughly by how much they tell an installer.
OK = "ok"
UNREACHABLE = "unreachable"
AUTH = "auth"
UNSUPPORTED = "unsupported"
NO_FFMPEG = "no_ffmpeg"
BUSY = "busy"
FAILED = "failed"

#: Seconds a repeated failure for one camera is folded into a count instead of a
#: row. A camera that has been unplugged is one fact, however many times a wall
#: of tiles rediscovers it.
DEFAULT_FAILURE_WINDOW_SECONDS = 300.0


def _setting(name, default):
    return getattr(settings, name, default)


def enabled() -> bool:
    return bool(_setting("POINTY_SURVEILLANCE_TELEMETRY", True))


@dataclass
class StreamReport:
    """One viewing session, accumulated cheaply and written once.

    Everything a driver or a pipeline learns along the way lands here rather
    than in a log line nobody greps: the codec a recorder is really sending, the
    resolution the tile really got, how many times ffmpeg complained.
    """

    camera_id: int | None = None
    recorder_id: int | None = None
    brand: str = ""
    mode: str = ""
    quality: str = ""
    outcome: str = OK
    error_kind: str = ""

    #: Set when the first frame came from the warm-frame cache rather than the
    #: recorder, which is the whole question about whether that cache works.
    warm_start: bool = False
    #: Set when this viewer joined a producer someone else had already started.
    shared: bool = False

    started_at: float = field(default_factory=time.monotonic)
    first_frame_at: float | None = None
    frames: int = 0

    codec: str = ""
    source_width: int = 0
    source_height: int = 0
    source_fps: float = 0.0
    requested_fps: int = 0
    #: How many lines ffmpeg wrote to stderr. A healthy pipeline writes none; a
    #: recorder sending damaged video writes a stream of them, which is exactly
    #: the signal behind a picture that looks wrong rather than absent.
    decoder_complaints: int = 0

    def first_frame(self):
        """Cheap enough for the frame path: one comparison and one assignment."""
        if self.first_frame_at is None:
            self.first_frame_at = time.monotonic()

    @property
    def first_frame_ms(self) -> float | None:
        if self.first_frame_at is None:
            return None
        return round((self.first_frame_at - self.started_at) * 1000.0, 1)

    @property
    def duration_ms(self) -> float:
        return round((time.monotonic() - self.started_at) * 1000.0, 1)

    def as_metrics(self) -> dict:
        metrics = {
            "frames": self.frames,
            "duration_ms": self.duration_ms,
            "decoder_complaints": self.decoder_complaints,
        }
        if self.first_frame_ms is not None:
            metrics["first_frame_ms"] = self.first_frame_ms
        if self.requested_fps:
            metrics["requested_fps"] = self.requested_fps
        if self.source_fps:
            metrics["source_fps"] = round(float(self.source_fps), 2)
        if self.source_width and self.source_height:
            metrics["source_width"] = self.source_width
            metrics["source_height"] = self.source_height
        # Only meaningful once a stream has run long enough to have a rate.
        if self.frames > 1 and self.duration_ms > 1000:
            metrics["effective_fps"] = round(
                self.frames / (self.duration_ms / 1000.0), 2
            )
        return metrics

    def as_attributes(self) -> dict:
        attributes = {
            "brand": self.brand,
            "mode": self.mode,
            "quality": self.quality,
            "outcome": self.outcome,
            "warm_start": self.warm_start,
            "shared": self.shared,
        }
        if self.codec:
            attributes["codec"] = self.codec
        if self.error_kind:
            attributes["error_kind"] = self.error_kind
        return attributes


class _FailureThrottle:
    """Fold repeated failures for one camera into a count.

    Keyed on camera and outcome rather than on the message, because the message
    of a box that is off carries a changing errno and would defeat the fold.
    """

    def __init__(self):
        self._lock = threading.Lock()
        self._seen: dict[tuple, tuple[float, int]] = {}

    @property
    def window(self) -> float:
        return float(
            _setting(
                "POINTY_SURVEILLANCE_TELEMETRY_FAILURE_WINDOW",
                DEFAULT_FAILURE_WINDOW_SECONDS,
            )
        )

    def take(self, key) -> int | None:
        """``None`` to suppress, otherwise how many were folded into this one."""
        now = time.monotonic()
        window = self.window
        with self._lock:
            # Opportunistic sweep: bounded by the number of cameras a shop has,
            # and it keeps a long-lived worker from holding retired keys.
            if len(self._seen) > 256:
                self._seen = {
                    k: v for k, v in self._seen.items() if now - v[0] < window
                }
            seen_at, count = self._seen.get(key, (0.0, 0))
            if seen_at and now - seen_at < window:
                self._seen[key] = (seen_at, count + 1)
                return None
            self._seen[key] = (now, 0)
            return count


_failures = _FailureThrottle()


def reset():
    """Test seam: forget what has been throttled."""
    global _failures
    _failures = _FailureThrottle()


def record(report: StreamReport, *, user=None):
    """Write one session. Never raises, never blocks on the recorder."""
    if not enabled():
        return
    try:
        _record(report, user)
    except Exception:  # noqa: BLE001 - telemetry must never break the feature
        logger.debug("camera telemetry failed", exc_info=True)


def _record(report: StreamReport, user):
    from apps.analytics.models import AnalyticsEvent
    from apps.analytics.services import record_event_buffered

    attributes = report.as_attributes()
    metrics = report.as_metrics()
    severity = AnalyticsEvent.Severity.INFO

    if report.outcome != OK:
        folded = _failures.take((report.camera_id, report.outcome))
        if folded is None:
            return
        if folded:
            metrics["suppressed_repeats"] = folded
        severity = AnalyticsEvent.Severity.WARNING

    record_event_buffered(
        name=EVENT_NAME,
        event_type=AnalyticsEvent.EventType.USAGE,
        severity=severity,
        source=AnalyticsEvent.Source.BACKEND,
        user=user,
        entity_type="camera",
        entity_id=str(report.camera_id or ""),
        attributes=attributes,
        metrics=metrics,
    )


def jpeg_dimensions(payload: bytes) -> tuple[int, int]:
    """Width and height out of a JPEG's frame header, or ``(0, 0)``.

    The one measurement available on every driver, however the video reached us:
    what the tile actually received. Reading it costs a walk over a few marker
    segments — microseconds — and it is done once per session, on the first
    frame only.
    """
    try:
        index = 2  # past SOI
        total = len(payload)
        while index + 9 < total:
            if payload[index] != 0xFF:
                index += 1
                continue
            marker = payload[index + 1]
            # SOF0/1/2/3 and the other non-differential start-of-frame markers
            # carry the dimensions; 0xC4/0xC8/0xCC are tables, not frames.
            if marker in (0xC0, 0xC1, 0xC2, 0xC3, 0xC5, 0xC6, 0xC7, 0xC9, 0xCA, 0xCB):
                height = (payload[index + 5] << 8) | payload[index + 6]
                width = (payload[index + 7] << 8) | payload[index + 8]
                return width, height
            if marker in (0xD8, 0x01) or 0xD0 <= marker <= 0xD7:
                index += 2
                continue
            segment = (payload[index + 2] << 8) | payload[index + 3]
            if segment <= 0:
                return 0, 0
            index += 2 + segment
    except (IndexError, ValueError):  # pragma: no cover - defensive
        pass
    return 0, 0
