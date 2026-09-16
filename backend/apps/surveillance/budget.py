"""How many streams one recorder will actually serve at once.

This is not our ffmpeg ceiling — that one lives in :mod:`transcode`, is 12, and
was never reached. This is the recorder's own limit, and the field made it
measurable: on 2026-09-12 a sixteen-camera wall opened seventeen streams against
one Xiongmai box and exactly nine returned video. Two days earlier, a different
session: twelve opened, exactly nine returned video. Nine, twice, independently.

A DVR at its session cap does not say so. It accepts the TCP connection, sends
nothing, and lets the request die on a timeout three seconds later — which is
indistinguishable, from the client's side, from a camera that is broken. So a
wall of sixteen shows nine pictures and seven black rectangles, every time it is
opened, and the shop reads that as seven broken cameras.

Refusing early is strictly better than that. A request we decline gets an
immediate 503 with ``Retry-After``, which the client already understands and
already backs off on; a request the recorder swallows costs three seconds, a
thread, and a black tile that never explains itself.

The limit can be set per recorder by whoever installs it. When it is not set we
learn it, because nobody reads a DVR's datasheet and the number differs per
firmware: a stream that fails while others on the same box are healthy is
evidence about the box, not about that camera.
"""

from __future__ import annotations

import threading

from django.core.cache import cache

#: Never learn a limit below this. A single failure at low concurrency is a blip
#: — a camera rebooting, a switch reconverging — and teaching a recorder a
#: ceiling of one over it would be a far worse bug than the one this fixes.
LEARNED_FLOOR = 4

#: How long a learned ceiling is trusted. Long enough to survive a night, short
#: enough that replacing the recorder, or the shop moving it onto a better
#: switch, is not remembered against it forever.
LEARNED_TTL_SECONDS = 7 * 24 * 3600

#: What a refused viewer is told to wait. Short: the usual reason a slot frees
#: up is somebody closing a tile, which happens on human timescales.
RETRY_AFTER_SECONDS = 5

_lock = threading.Lock()
_in_flight: dict[int, int] = {}


class RecorderAtCapacity(Exception):
    """Raised instead of opening a stream the recorder would not serve."""

    def __init__(self, limit: int, in_flight: int) -> None:
        self.limit = limit
        self.in_flight = in_flight
        self.retry_after = RETRY_AFTER_SECONDS
        super().__init__(
            f"This recorder is already sending {in_flight} live streams, which "
            "is as many as it will carry at once."
        )


def _key(recorder_id) -> str:
    return f"surveillance:budget:{recorder_id}"


def learned_limit(recorder_id) -> int | None:
    """What we have worked out about this recorder, if anything."""
    try:
        value = cache.get(_key(recorder_id))
    except Exception:  # pragma: no cover - depends on the cache backend
        return None
    try:
        return int(value) if value else None
    except (TypeError, ValueError):
        return None


def _remember(recorder_id, value: int) -> None:
    try:
        cache.set(_key(recorder_id), int(value), LEARNED_TTL_SECONDS)
    except Exception:  # pragma: no cover - depends on the cache backend
        pass


def forget(recorder_id) -> None:
    """Drop what we learned. Used when someone edits or re-tests the recorder."""
    try:
        cache.delete(_key(recorder_id))
    except Exception:  # pragma: no cover - depends on the cache backend
        pass


def limit_for(recorder) -> int | None:
    """The ceiling to enforce: what an installer set, else what we learned."""
    configured = getattr(recorder, "max_concurrent_streams", None)
    if configured:
        return max(1, int(configured))
    return learned_limit(getattr(recorder, "pk", recorder))


def in_flight(recorder_id) -> int:
    with _lock:
        return _in_flight.get(int(recorder_id), 0)


def note_refusal(recorder_id, at_concurrency: int) -> None:
    """Learn from a stream that failed while others on the box were fine.

    ``at_concurrency`` is how many streams this recorder was *already* serving
    when the failed one was attempted. That is the number it managed, so it is
    the ceiling — and we only ever lower it, so repeated evidence converges
    rather than oscillating.
    """
    candidate = max(LEARNED_FLOOR, int(at_concurrency))
    known = learned_limit(recorder_id)
    if known is not None and known <= candidate:
        return
    _remember(recorder_id, candidate)


def note_success(recorder_id, at_concurrency: int) -> None:
    """Raise the ceiling when the box beats what we thought it could do.

    Without this, one bad evening would cap a recorder for a week. A stream that
    *worked* at a concurrency above the learned limit is direct evidence the
    limit was wrong, and it is the only evidence that can be trusted to raise
    it.
    """
    known = learned_limit(recorder_id)
    if known is None or at_concurrency < known:
        return
    _remember(recorder_id, int(at_concurrency) + 1)


class _Reservation:
    """One held slot. Released exactly once, whatever unwinds it."""

    __slots__ = ("recorder_id", "at_start", "_released")

    def __init__(self, recorder_id: int, at_start: int) -> None:
        self.recorder_id = recorder_id
        #: How many streams the recorder was already serving. The learning
        #: signal, captured at reservation time because by the time a stream
        #: fails the others may have come and gone.
        self.at_start = at_start
        self._released = False

    def release(self) -> None:
        if self._released:
            return
        self._released = True
        with _lock:
            remaining = _in_flight.get(self.recorder_id, 0) - 1
            if remaining > 0:
                _in_flight[self.recorder_id] = remaining
            else:
                _in_flight.pop(self.recorder_id, None)

    def __enter__(self):
        return self

    def __exit__(self, *_exc):
        self.release()


def check(recorder, *, limit: int | None = None) -> None:
    """Peek without taking a slot. Raises :class:`RecorderAtCapacity` if full.

    The views call this before subscribing, because the authoritative
    reservation happens inside the producer — and by the time a producer fails,
    the response has already gone out as a 200 carrying the last frame we held.
    That is correct for a camera that blinked and wrong for a recorder that is
    full: a stale picture is not an answer to "wait five seconds". So the
    request path asks first, and the reservation stays where the lifetime is.
    """
    recorder_id = int(getattr(recorder, "pk", recorder))
    if limit is None:
        limit = limit_for(recorder)
    if limit is None:
        return
    with _lock:
        held = _in_flight.get(recorder_id, 0)
    if held >= limit:
        raise RecorderAtCapacity(limit=limit, in_flight=held)


def reserve(recorder, *, limit: int | None = None) -> _Reservation:
    """Take a slot on this recorder, or refuse before anything is dialled.

    ``limit`` is passed in by the live views, which hold the ``Recorder`` row
    already and resolve it there. A producer thread outlives the request that
    started it, so it is handed the number rather than the object — reaching
    back into the ORM from a stream thread to re-read a column that cannot have
    changed would be a query per camera per reconnect, for nothing.
    """
    recorder_id = int(getattr(recorder, "pk", recorder))
    if limit is None:
        limit = limit_for(recorder)
    with _lock:
        held = _in_flight.get(recorder_id, 0)
        if limit is not None and held >= limit:
            raise RecorderAtCapacity(limit=limit, in_flight=held)
        _in_flight[recorder_id] = held + 1
    return _Reservation(recorder_id, at_start=held)


def reset() -> None:
    """Test seam: forget every slot this process thinks it is holding."""
    with _lock:
        _in_flight.clear()


def snapshot() -> dict[int, int]:
    """Test/diagnostic seam: streams in flight per recorder."""
    with _lock:
        return dict(_in_flight)
