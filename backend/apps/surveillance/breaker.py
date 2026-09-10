"""A per-recorder circuit breaker for the streaming and snapshot paths.

Why this exists, precisely: on 2026-09-08 a shop switched its cameras on and the
DVR did not answer. ``surveillance-camera-live`` then returned 5xx **18,160 times
out of 18,594** over three days — a 99.4% failure rate — and every one of those
failures spent about six seconds inside a connect timeout before giving up. The
client reconnects on a fixed delay, so the loop never ended on its own. That one
unreachable box became 82.9% of the backend's entire request time and 32.5 hours
of held connections.

The streaming views are synchronous, so each of those waits also pins one ASGI
threadpool thread. The tills survived it, but only because two or three streams
were open at once; a wall of sixteen would have scaled the same way.

So: after a few connection-level failures we stop dialling and start answering
immediately. A recorder that is unreachable is unreachable for every one of its
channels, which is why the breaker is keyed on the recorder and not the camera —
one dead box trips once, not sixteen times.

Deliberately **not** applied to the configuration endpoints. Someone editing a
recorder's address is actively trying to fix it, and a breaker that refuses to
dial while they retype the password is worse than the wait.
"""

from __future__ import annotations

import time
from dataclasses import dataclass

from django.core.cache import cache

#: Consecutive connection failures before the breaker opens. Three rather than
#: one: a single timeout is a blip (a DVR reboots, a switch reconverges) and
#: shutting a working camera off for half a minute over one bad dial would be a
#: worse bug than the one this fixes.
FAILURE_THRESHOLD = 3

#: How long the first trip lasts, then doubling per failed probe up to the cap.
#: Thirty seconds is short enough that a recorder coming back is noticed quickly
#: and long enough that a wall of tiles cannot spin.
INITIAL_COOLDOWN_SECONDS = 30
MAX_COOLDOWN_SECONDS = 300

#: State outlives the cooldown so a flapping box escalates instead of resetting
#: to a 30-second cycle forever.
_STATE_TTL_SECONDS = MAX_COOLDOWN_SECONDS * 4

#: Failures worth pausing a recorder over: it did not answer, or it answered
#: and then produced no video at all.
#:
#: ``StreamError`` earned its place the hard way. The first cut of this breaker
#: counted only the two connection errors, on the reasoning that a box replying
#: "no footage for that window" has answered and must stay available. True for
#: playback — but the failure that actually took a shop down for three days was
#: a *live* stream ending with zero frames, which surfaces as ``StreamError``.
#: A breaker that does not cover the observed failure is decoration, so callers
#: on the live paths pass it and the playback path deliberately does not.
#:
#: ``RecorderCapabilityError`` is excluded on purpose and must stay excluded: it
#: is structural, it is answered instantly, and pausing a recorder over it would
#: hide a permanent misconfiguration behind a temporary-looking symptom.
CONNECTION_FAILURES = frozenset(
    {"RecorderUnreachable", "RecorderAuthError", "StreamError"}
)


class RecorderCircuitOpen(Exception):
    """Raised instead of dialling a recorder that is known to be down."""

    def __init__(self, retry_after: int) -> None:
        self.retry_after = retry_after
        super().__init__(
            "The recorder is not responding. Pausing reconnection attempts for "
            f"{retry_after} seconds."
        )


@dataclass
class _State:
    failures: int
    open_until: float

    def as_dict(self) -> dict:
        return {"failures": self.failures, "open_until": self.open_until}

    @classmethod
    def from_dict(cls, raw) -> "_State | None":
        if not isinstance(raw, dict):
            return None
        try:
            return cls(
                failures=int(raw.get("failures", 0)),
                open_until=float(raw.get("open_until", 0.0)),
            )
        except (TypeError, ValueError):
            return None


def _key(recorder_id) -> str:
    return f"surveillance:breaker:{recorder_id}"


def _load(recorder_id) -> _State | None:
    # Cache failures fail *open*. A breaker exists to avoid waiting on a dead
    # box; refusing to stream because Redis blinked would trade a real outage
    # for an imaginary one.
    try:
        return _State.from_dict(cache.get(_key(recorder_id)))
    except Exception:  # pragma: no cover - depends on the cache backend
        return None


def _store(recorder_id, state: _State) -> None:
    try:
        cache.set(_key(recorder_id), state.as_dict(), _STATE_TTL_SECONDS)
    except Exception:  # pragma: no cover - depends on the cache backend
        pass


def cooldown_for(failures: int) -> int:
    """Seconds to stay open after ``failures`` consecutive connection failures."""
    over = max(0, failures - FAILURE_THRESHOLD)
    return min(INITIAL_COOLDOWN_SECONDS * (2**over), MAX_COOLDOWN_SECONDS)


def check(recorder_id) -> None:
    """Raise :class:`RecorderCircuitOpen` if this recorder is in cooldown.

    Call before doing anything that dials the box.
    """
    state = _load(recorder_id)
    if state is None:
        return
    remaining = state.open_until - time.time()
    if remaining > 0:
        raise RecorderCircuitOpen(retry_after=max(1, int(round(remaining))))


def note_failure(recorder_id, exc) -> None:
    """Record a failed attempt, opening the breaker once the run is long enough.

    Only connection-level failures count. Everything else is cheap to retry and
    frequently camera-specific, so letting it trip a recorder-wide breaker would
    take working channels down with it.
    """
    if exc.__class__.__name__ not in CONNECTION_FAILURES:
        return
    state = _load(recorder_id) or _State(failures=0, open_until=0.0)
    state.failures += 1
    if state.failures >= FAILURE_THRESHOLD:
        state.open_until = time.time() + cooldown_for(state.failures)
    _store(recorder_id, state)


def note_success(recorder_id) -> None:
    """Clear the breaker: the box answered, so the run of failures is over."""
    if _load(recorder_id) is None:
        return
    reset(recorder_id)


def reset(recorder_id) -> None:
    """Forget this recorder's failure history.

    Used by :func:`note_success` and by the explicit "try again" path, so a
    person who has just fixed the wiring is never told to wait.
    """
    try:
        cache.delete(_key(recorder_id))
    except Exception:  # pragma: no cover - depends on the cache backend
        pass
