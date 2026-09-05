"""Redis must never be able to block a request forever.

A Redis that *refuses* connections is the easy outage: the connect fails
immediately and the fail-open guards in ``apps.core.caching`` fall through to a
live database read. The dangerous outage is a Redis that accepts the TCP
connection and then stops answering — a host that is swapping, a container
wedged mid-restart, a LAN link that starts dropping packets after the handshake.
redis-py defaults ``socket_timeout``/``socket_connect_timeout`` to ``None``, so
that read blocks with no timeout at all, and because sessions, the user row and
the permission set are read from Redis on every authenticated request, the whole
backend stops answering with it.

These tests pin the timeouts down by simulating exactly that: a listening socket
with a backlog, which the kernel handshakes on our behalf while user space never
sends a byte.
"""

from __future__ import annotations

import socket
import threading
import time

from django.conf import settings
from django.test import SimpleTestCase
from django_redis.cache import RedisCache


class _BlackHoleRedis:
    """A socket that completes the TCP handshake and then answers nothing."""

    def __enter__(self):
        self._sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self._sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self._sock.bind(("127.0.0.1", 0))
        # A backlog is all that is needed: the kernel completes the handshake for
        # queued connections, so connect() succeeds and only the read hangs.
        self._sock.listen(8)
        return f"redis://127.0.0.1:{self._sock.getsockname()[1]}/0"

    def __exit__(self, *exc):
        self._sock.close()
        return False


def _time_a_get(location, options, *, give_up_after):
    """Run one ``cache.get`` in a worker thread; report whether it came back."""
    result = {}

    def run():
        started = time.monotonic()
        try:
            cache.get("pointy:blackhole-probe")
            result["outcome"] = "returned"
        except Exception as exc:  # noqa: BLE001 — the outcome under test
            result["outcome"] = type(exc).__name__
        result["elapsed"] = time.monotonic() - started

    cache = RedisCache(location, {"OPTIONS": options})
    worker = threading.Thread(target=run, daemon=True)
    worker.start()
    worker.join(timeout=give_up_after)
    # Snapshot while the black-hole listener is still open. Closing it RSTs the
    # connection the kernel handshook on our behalf, which wakes a thread parked
    # on an unbounded read: hand back the live dict and it grows an outcome a
    # fraction of a second after the caller has already read it as empty.
    return dict(result)


class RedisSocketTimeoutTests(SimpleTestCase):
    def test_configured_cache_gives_up_on_an_unresponsive_redis(self):
        """The shipped OPTIONS bound the read; the caller gets an exception it
        can fail open on instead of a thread parked forever."""
        options = settings.CACHES["default"]["OPTIONS"]
        with _BlackHoleRedis() as location:
            result = _time_a_get(location, options, give_up_after=15)

        self.assertIn(
            "outcome",
            result,
            "cache.get never returned against an unresponsive Redis — the "
            "socket timeouts in CACHES['default']['OPTIONS'] are missing or "
            "too large, so a wedged Redis hangs every request that touches it",
        )
        self.assertEqual(result["outcome"], "TimeoutError")
        self.assertLess(result["elapsed"], 10)

    def test_without_the_timeouts_the_same_read_never_comes_back(self):
        """The regression this pins: stock django-redis OPTIONS block forever.

        Kept so the assertion above can never pass vacuously (e.g. if some
        future refactor made the probe socket answer).
        """
        with _BlackHoleRedis() as location:
            result = _time_a_get(
                location,
                {"CLIENT_CLASS": "django_redis.client.DefaultClient"},
                give_up_after=3,
            )

        self.assertEqual(result, {}, "expected the unbounded read to still be blocked")

    def test_timeouts_are_finite_and_small(self):
        options = settings.CACHES["default"]["OPTIONS"]
        for key in ("SOCKET_TIMEOUT", "SOCKET_CONNECT_TIMEOUT"):
            with self.subTest(option=key):
                value = options.get(key)
                self.assertIsNotNone(value, f"{key} must be set: None means block forever")
                self.assertGreater(value, 0)
                # Redis is local or on the shop LAN; anything near a human-visible
                # pause here is a misconfiguration, not a slow round-trip.
                self.assertLessEqual(value, 5)
