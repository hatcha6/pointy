"""Real-time verification while a checkout is open.

At rest the token is only kept warm (every ~4 minutes). While a till has a
checkout open — its payment sheet is up — or a card payment was just taken,
the backend reads the terminal's transactions every few seconds instead, so the
till can show "the card went through" before the cashier confirms, and the
payment is verified within seconds of being recorded. When nothing is open the
loop stops by itself and the relaxed keepalive takes over again.

The loop is a self-rescheduling Celery task guarded by a short-lived Redis
key, so at most one runs however many tills are watching; if its worker dies,
the key expires and the next heartbeat starts a new one.

It can never run away against Moamalat, whatever a till does:

- **a till that crashes stops it within HEARTBEAT_HOLDS** — the loop runs only
  while ``hot_until`` lies ahead, and only a live heartbeat moves it;
- **no hot stretch outlives MAX_HOT_STRETCH** from its start, however many
  heartbeats or card sales keep asking (a till stuck re-sending, a busy hour);
  after it, the loop stays cold for HOT_COOLDOWN before anything can restart it;
- **a failed read ends the stretch at once** — fast polling a server that is
  failing would be hammering it; the keepalive's own back-off takes over;
- **at most one read every FAST_INTERVAL** per shop, by the single-loop key.

So the worst a shop can cost Moamalat is one read every 5 s for 10 minutes,
then 2 minutes of nothing.
"""

from __future__ import annotations

import logging
from datetime import timedelta

from django.utils import timezone

from . import custody

logger = logging.getLogger(__name__)

#: How often the terminal's list is read while a checkout is open.
FAST_INTERVAL = timedelta(seconds=5)
#: One heartbeat from a till keeps the loop hot this long; the till repeats it
#: while its payment sheet stays open.
HEARTBEAT_HOLDS = timedelta(seconds=30)
#: After a card payment is recorded, stay hot until it is verified or this passes.
AFTER_SALE_HOLDS = timedelta(minutes=3)
#: The hard ceiling on one hot stretch, and the rest enforced after it.
MAX_HOT_STRETCH = timedelta(minutes=10)
HOT_COOLDOWN = timedelta(minutes=2)
_LOOP_KEY = "moamalat:fast-loop"
_LOOP_TTL = 20


def heat(hold: timedelta, now=None) -> bool:
    """Keep the fast loop running for up to ``hold`` from now, within the
    current stretch's ceiling. Returns whether the loop is (now) hot."""
    from apps.payments.models import MoamalatLink

    now = now or timezone.now()
    link = custody.load_link()
    if link.state != link.State.ALIVE:
        return False
    cold = link.hot_until is None or link.hot_until <= now
    if cold:
        if link.hot_until is not None and link.hot_since is not None:
            # A stretch that hit the ceiling rests before another may start.
            capped_at = link.hot_since + MAX_HOT_STRETCH
            if link.hot_until >= capped_at and now < capped_at + HOT_COOLDOWN:
                return False
        hot_since = now
    else:
        hot_since = link.hot_since or now
    until = min(now + hold, hot_since + MAX_HOT_STRETCH)
    if until <= now:
        return False
    if cold or link.hot_until < until:
        MoamalatLink.objects.filter(pk=1, state=MoamalatLink.State.ALIVE).update(
            hot_until=until, hot_since=hot_since
        )
    ensure_loop()
    return True


def cool_down(reason: str) -> None:
    """End the stretch now (the loop sees it on its next beat)."""
    from apps.payments.models import MoamalatLink

    MoamalatLink.objects.filter(pk=1).update(hot_until=timezone.now())
    logger.info("moamalat: fast loop stopped (%s)", reason)


def ensure_loop() -> None:
    from apps.core.dispatch import enqueue_best_effort

    if custody._cache_add(_LOOP_KEY, 1, _LOOP_TTL):
        if not enqueue_best_effort("payments.moamalat_fast_poll"):
            custody._cache_delete(_LOOP_KEY)


def is_hot(link, now=None) -> bool:
    now = now or timezone.now()
    if not link.hot_until or link.hot_until <= now:
        return False
    # Belt and braces: the ceiling holds even if hot_until was set past it.
    return not (link.hot_since and now >= link.hot_since + MAX_HOT_STRETCH)


def fast_poll() -> bool:
    """One beat of the fast loop. Returns whether it rescheduled itself."""
    from apps.core.dispatch import enqueue_best_effort

    from . import matching

    link = custody.load_link()
    if link.state != link.State.ALIVE or not is_hot(link):
        custody._cache_delete(_LOOP_KEY)
        return False
    try:
        custody._cache_set(_LOOP_KEY, 1, _LOOP_TTL)
    except custody.LinkError:
        pass
    try:
        read = matching.fetch_live(link)
    except Exception:  # noqa: BLE001
        logger.warning("moamalat: live read failed", exc_info=True)
        read = None
    if read is None or not read.ok:
        # Never fast-poll a failing server: the keepalive's back-off takes it.
        cool_down("a read failed")
        custody._cache_delete(_LOOP_KEY)
        return False
    link.refresh_from_db()
    if link.state != link.State.ALIVE or not is_hot(link):
        custody._cache_delete(_LOOP_KEY)
        return False
    try:
        from .tasks import moamalat_fast_poll

        moamalat_fast_poll.apply_async(countdown=FAST_INTERVAL.total_seconds())
    except Exception:  # noqa: BLE001 - the broker is down: let the key lapse
        logger.warning("moamalat: fast loop not rescheduled", exc_info=True)
        custody._cache_delete(_LOOP_KEY)
        return False
    return True


def payment_recorded(payment) -> None:
    """A card payment was just taken: verify it in real time."""
    if payment.method != payment.Method.CARD or payment.amount <= 0:
        return
    heat(AFTER_SALE_HOLDS)
