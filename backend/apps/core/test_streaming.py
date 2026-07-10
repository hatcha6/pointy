"""Tests for the sync-generator → async-iterator streaming bridge.

The bridge exists so SSE responses stream live under ASGI (Django itself would
buffer a sync iterator wholesale). These tests exercise the contract the AI
chat stream depends on: chunk-by-chunk ordering, exception propagation, the
generator's ``finally`` running when the client disconnects mid-stream, and the
worker thread closing its own DB connections.
"""

import asyncio
import threading
from unittest import mock

from django.test import SimpleTestCase

from apps.core.streaming import aiter_in_thread


class AiterInThreadTests(SimpleTestCase):
    def collect(self, generator):
        async def consume():
            return [chunk async for chunk in aiter_in_thread(generator)]

        return asyncio.run(consume())

    def test_yields_all_chunks_in_order(self):
        chunks = self.collect(iter(f"chunk-{i}" for i in range(500)))
        self.assertEqual(chunks, [f"chunk-{i}" for i in range(500)])

    def test_generator_exception_propagates_to_the_consumer(self):
        def gen():
            yield "a"
            raise RuntimeError("boom")

        async def consume():
            received = []
            async for chunk in aiter_in_thread(gen()):
                received.append(chunk)
            return received

        with self.assertRaisesMessage(RuntimeError, "boom"):
            asyncio.run(consume())

    def test_early_close_runs_the_generator_finally(self):
        # A client disconnect closes the async iterator; the sync generator's
        # finally (persist partial answer, close the relay stream) must run.
        release = threading.Event()
        cleaned = threading.Event()

        def gen():
            try:
                yield "one"
                release.wait(timeout=5)
                yield "two"
                yield "three"
            finally:
                cleaned.set()

        async def consume_one():
            stream = aiter_in_thread(gen())
            first = await anext(stream)
            await stream.aclose()
            release.set()
            return first

        first = asyncio.run(consume_one())
        self.assertEqual(first, "one")
        self.assertTrue(cleaned.wait(timeout=5))

    def test_worker_thread_closes_its_db_connections(self):
        # The generator's ORM work runs on the bridge's thread; no request
        # machinery will ever close that thread's connections, so the bridge
        # must (it matters with PgBouncer + CONN_MAX_AGE).
        closed_on = []

        def record_close():
            closed_on.append(threading.current_thread().name)

        with mock.patch("apps.core.streaming.connections") as fake_connections:
            fake_connections.close_all.side_effect = record_close
            chunks = self.collect(iter(["x"]))

        self.assertEqual(chunks, ["x"])
        self.assertEqual(closed_on, ["sse-stream-bridge"])
