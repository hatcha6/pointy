"""The Celery broker must never be able to block a request forever.

Redis is both the cache and the Celery broker here. The cache side is bounded
(see ``test_redis_timeouts``), but kombu builds its own redis clients and
inherits redis-py's ``socket_timeout``/``socket_connect_timeout`` default of
``None`` — block forever. So a broker that *refuses* connections raises at once
and the ``try/except`` around every dispatch site absorbs it, while a broker that
accepts the TCP handshake and then stops answering never raises at all and
``.delay()`` simply parks the calling thread.

That thread is a cashier's. ``schedule_targeted_sweep`` fires on returns, voids,
exchanges, register pay-outs and register close, from a ``transaction.on_commit``
hook that runs inside the request: the sale commits and the till never gets its
response.

Same probe as the cache tests — a listening socket with a backlog, which the
kernel handshakes on our behalf while user space never sends a byte. Celery reads
``CELERY_BROKER_URL`` from the environment ahead of its configured value, so
pointing the *real* app at that socket needs no monkeypatching of the code under
test.
"""

from __future__ import annotations

import os
import socket
import threading
import time
from contextlib import contextmanager
from unittest import mock

from django.test import SimpleTestCase, TestCase

from apps.core.dispatch import (
    broker_transport_options,
    enqueue_best_effort,
    enqueue_or_raise,
)
from apps.core.tasks import run_due_scheduled_backup
from pointy.celery import app as celery_app


def _reset_broker_pools():
    """Drop the cached producer/connection pools so the next publish re-dials."""
    celery_app.__dict__.pop("amqp", None)
    celery_app._pool = None


@contextmanager
def black_hole_broker():
    """Point the real Celery app at a socket that answers nothing."""
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.bind(("127.0.0.1", 0))
    # A backlog is all that is needed: the kernel completes the handshake for
    # queued connections, so connect() succeeds and only the read hangs.
    sock.listen(8)
    previous = os.environ.get("CELERY_BROKER_URL")
    os.environ["CELERY_BROKER_URL"] = f"redis://127.0.0.1:{sock.getsockname()[1]}/0"
    _reset_broker_pools()
    try:
        yield
    finally:
        if previous is None:
            os.environ.pop("CELERY_BROKER_URL", None)
        else:
            os.environ["CELERY_BROKER_URL"] = previous
        _reset_broker_pools()
        # Dropping the listener resets the queued connections, so a thread still
        # parked on one is released instead of outliving the test run.
        sock.close()


def _time_it(call, *, give_up_after):
    """Run ``call`` in a worker thread; report whether it came back at all."""
    result = {}

    def run():
        started = time.monotonic()
        try:
            result["outcome"] = call()
        except Exception as exc:  # noqa: BLE001 — the outcome under test
            result["outcome"] = type(exc).__name__
        result["elapsed"] = time.monotonic() - started

    worker = threading.Thread(target=run, daemon=True)
    worker.start()
    worker.join(timeout=give_up_after)
    return result


class BrokerDispatchTimeoutTests(SimpleTestCase):
    def test_best_effort_enqueue_gives_up_on_an_unresponsive_broker(self):
        """The caller gets ``False`` and its thread back, not a permanent park."""
        with black_hole_broker():
            result = _time_it(
                lambda: enqueue_best_effort(run_due_scheduled_backup),
                give_up_after=15,
            )

        self.assertIn(
            "outcome",
            result,
            "enqueue_best_effort never returned against an unresponsive broker — "
            "the transport options in apps.core.dispatch are missing or too "
            "large, so a wedged Redis hangs every request that enqueues a task",
        )
        self.assertIs(result["outcome"], False)
        self.assertLess(result["elapsed"], 10)

    def test_without_the_bound_a_plain_delay_never_comes_back(self):
        """The regression this pins: the stock publish blocks forever.

        Kept so the assertions here can never pass vacuously (e.g. if some
        future refactor made the probe socket answer).
        """
        with black_hole_broker():
            result = _time_it(run_due_scheduled_backup.delay, give_up_after=3)

        self.assertEqual(result, {}, "expected the unbounded publish to still be blocked")

    def test_raising_enqueue_also_gives_up_instead_of_parking(self):
        """Callers that must know the work was queued get an error, not a wait.

        Backup, restore and data-migration dispatch already mark their job row
        failed and answer with a real error; the bound only decides how long the
        admin waits for it.
        """
        with black_hole_broker():
            result = _time_it(
                lambda: enqueue_or_raise(run_due_scheduled_backup),
                give_up_after=15,
            )

        self.assertIn(
            "outcome",
            result,
            "enqueue_or_raise never returned against an unresponsive broker",
        )
        self.assertEqual(result["outcome"], "OperationalError")
        self.assertLess(result["elapsed"], 10)

    def test_transport_options_are_finite_and_small(self):
        options = broker_transport_options()
        for key in ("socket_timeout", "socket_connect_timeout"):
            with self.subTest(option=key):
                value = options.get(key)
                self.assertIsNotNone(value, f"{key} must be set: None means block forever")
                self.assertGreater(value, 0)
                # Redis is local or on the shop LAN; anything near a
                # human-visible pause here is a misconfiguration.
                self.assertLessEqual(value, 5)
        # Re-dialling a broker that just proved it is not answering only
        # multiplies the deadline the caller is waiting on.
        self.assertEqual(options.get("max_retries"), 0)


class RiskyActionSweepTests(TestCase):
    """The fraud sweep rides the returns/void/exchange/register requests."""

    def test_a_wedged_broker_does_not_hold_the_returns_desk_open(self):
        from apps.fraud.services import schedule_targeted_sweep

        def run_hook():
            with self.captureOnCommitCallbacks(execute=True):
                schedule_targeted_sweep()
            return "returned"

        with black_hole_broker():
            result = _time_it(run_hook, give_up_after=15)

        self.assertIn(
            "outcome",
            result,
            "schedule_targeted_sweep never returned — a wedged broker would hang "
            "every return, void, exchange, register pay-out and register close, "
            "after the sale had already committed",
        )
        self.assertEqual(result["outcome"], "returned")
        self.assertLess(result["elapsed"], 10)


class NotificationTopUpTests(TestCase):
    """The bell/badge poll runs on every device, every few seconds."""

    def test_a_wedged_broker_does_not_hold_the_bell_poll_open(self):
        from apps.notifications import services

        def poll():
            # Claim the throttle slot unconditionally so the broker, not the
            # cache, decides the outcome; stub the inline fallback so the test
            # measures the enqueue rather than a whole-catalog recompute.
            with (
                mock.patch.object(services.cache, "add", return_value=True),
                mock.patch.object(
                    services, "sync_business_notifications", return_value={}
                ),
            ):
                services.maybe_sync_business_notifications()
            return "returned"

        with black_hole_broker():
            result = _time_it(poll, give_up_after=20)

        self.assertIn(
            "outcome",
            result,
            "maybe_sync_business_notifications never returned — a wedged broker "
            "would park one request thread per polling device until the pool ran "
            "out and took the tills with it",
        )
        self.assertEqual(result["outcome"], "returned")
        self.assertLess(result["elapsed"], 15)


class ByNameDispatchTests(SimpleTestCase):
    """A registry miss must be a dropped enqueue, not a 500.

    Cross-app dispatch (messaging → crm) looks the task up by *name* precisely
    because the owning tasks module may not be imported yet — and Celery's
    registry raises ``NotRegistered`` when it is not. Resolving that name at the
    call site (``enqueue_best_effort(current_app.tasks[name], ...)``) evaluates
    the lookup as an argument, i.e. before the guard inside the publisher is
    entered, so the miss escapes it: the inbound SMS row is written and the
    gateway then gets a 500 for a message that *was* stored, and retries it.

    These two pin the publisher's half of that contract — by-name dispatch
    resolves, and a miss is a ``False``. The call site is pinned end to end by
    ``apps.messaging.tests.TokenInboundAuthTests`` \
    ``.test_accepted_even_when_the_crm_task_is_not_registered``, which is the
    test that actually fails if the lookup moves back out to the caller.
    """

    def test_an_unregistered_name_is_a_dropped_enqueue_not_an_exception(self):
        self.assertIs(enqueue_best_effort("crm.no_such_task", 1), False)

    def test_a_registered_name_still_reaches_the_task(self):
        """Guard against the above passing because every name now misses."""
        with mock.patch.object(run_due_scheduled_backup, "apply_async") as publish:
            self.assertIs(enqueue_best_effort(run_due_scheduled_backup.name), True)
        publish.assert_called_once()
