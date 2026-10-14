"""The keepalive cadence, shared word for word with the relay.

Both holders of the token — this backend and the relay
(``relay/internal/moamalat/cadence.go``) — follow these rules, each on its own
clock and unaware of the other. The design window is 14 minutes: the longest
silence measured to survive; the first measured death was at 15.
"""

from datetime import timedelta

#: The routine gap between pokes: three fit in the window.
TICK = timedelta(minutes=4)
#: Spreads the fleet so every shop is not poked in step.
TICK_JITTER = timedelta(seconds=15)
#: Without an accepted call for this long, retry every AT_RISK_RETRY and warn.
AT_RISK_AFTER = timedelta(minutes=8)
AT_RISK_RETRY = timedelta(seconds=30)
#: The latest a 429's Retry-After may push the next attempt.
WINDOW = timedelta(minutes=14)
#: Past the window the token may still live (the relay may have kept it warm);
#: only Moamalat's answer settles it, so keep asking, slower.
LAPSED_AFTER = timedelta(minutes=15)
LAPSED_RETRY = timedelta(minutes=2)
_MIN_DELAY = timedelta(seconds=5)
_RETRY_LADDER = (timedelta(seconds=20), timedelta(seconds=60), timedelta(seconds=120))


def next_after_success(jitter: float) -> timedelta:
    """The gap after an accepted call; ``jitter`` in [-1, 1]."""
    jitter = max(-1.0, min(1.0, jitter))
    return TICK + TICK_JITTER * jitter


def next_after_failure(age: timedelta, failures: int, retry_after: timedelta | None = None) -> timedelta:
    """The gap after a transient failure.

    ``age`` is the time since this holder's last accepted call (or since it got
    the token), ``failures`` the consecutive transient failures including this
    one.
    """
    if age >= LAPSED_AFTER:
        delay = LAPSED_RETRY
    elif age >= AT_RISK_AFTER:
        delay = AT_RISK_RETRY
    else:
        delay = _RETRY_LADDER[failures - 1] if 1 <= failures <= len(_RETRY_LADDER) else TICK
        # Never sleep past the point where the at-risk cadence should start.
        if age + delay > AT_RISK_AFTER:
            delay = AT_RISK_AFTER - age
    if retry_after and retry_after > delay:
        delay = retry_after
        # Politeness must not kill the token: land before the window closes.
        if age < WINDOW and age + delay > WINDOW - AT_RISK_RETRY:
            delay = WINDOW - AT_RISK_RETRY - age
    return max(delay, _MIN_DELAY)


def at_risk(age: timedelta) -> bool:
    return age >= AT_RISK_AFTER
