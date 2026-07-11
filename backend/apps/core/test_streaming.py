"""Tests for the sync-generator → async-iterator streaming bridge.

The bridge exists so SSE responses stream live under ASGI (Django itself would
buffer a sync iterator wholesale). These tests exercise the contract the AI
chat stream depends on: chunk-by-chunk ordering, exception propagation, the
generator's ``finally`` running when the client disconnects mid-stream, and the
worker thread closing its own DB connections.
"""

import asyncio
import gzip
import tempfile
import threading
from pathlib import Path
from unittest import mock

from django.test import SimpleTestCase

from apps.core.streaming import aiter_file, aiter_handle, aiter_in_thread


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


class AiterFileTests(SimpleTestCase):
    """The pull-based file iterator behind large client-installer downloads."""

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.path = Path(self._tmp.name) / "installer.bin"

    def record_opens(self):
        # aiter_file opens its handle internally; wrap builtins.open so the
        # tests can assert the handle ends up closed. Only opens of our file
        # are recorded — the event loop may open unrelated things.
        real_open = open
        opened = []

        def recording_open(file, *args, **kwargs):
            handle = real_open(file, *args, **kwargs)
            if str(file) == str(self.path):
                opened.append(handle)
            return handle

        patcher = mock.patch("builtins.open", recording_open)
        patcher.start()
        self.addCleanup(patcher.stop)
        return opened

    def test_yields_exact_bytes_in_bounded_chunks(self):
        data = bytes(range(256)) * 40  # 10240 bytes, not chunk-aligned below
        self.path.write_bytes(data)
        opened = self.record_opens()

        async def consume():
            return [chunk async for chunk in aiter_file(self.path, chunk_size=4096)]

        chunks = asyncio.run(consume())
        self.assertEqual(b"".join(chunks), data)
        self.assertEqual([len(chunk) for chunk in chunks], [4096, 4096, 2048])
        self.assertEqual(len(opened), 1)
        self.assertTrue(opened[0].closed)

    def test_early_close_closes_the_file(self):
        # A client that disconnects mid-download closes the async iterator;
        # the file handle must not stay open until GC.
        self.path.write_bytes(b"abcdefgh")
        opened = self.record_opens()

        async def consume_one():
            stream = aiter_file(self.path, chunk_size=2)
            first = await anext(stream)
            await stream.aclose()
            return first

        first = asyncio.run(consume_one())
        self.assertEqual(first, b"ab")
        self.assertEqual(len(opened), 1)
        self.assertTrue(opened[0].closed)


class AiterHandleTests(SimpleTestCase):
    """The already-open-handle variant behind attachment streaming."""

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.path = Path(self._tmp.name) / "attachment.bin"

    def test_streams_through_a_decompressing_wrapper_and_closes_it(self):
        # Gzip-encoded attachments are opened as a decompressing wrapper, not
        # a plain file — the stored path's raw bytes are NOT the response
        # body, so the iterator must read through the handle it was given.
        data = bytes(range(256)) * 40  # 10240 bytes, not chunk-aligned below
        with gzip.open(self.path, "wb") as target:
            target.write(data)
        handle = gzip.open(self.path, "rb")

        async def consume():
            return [chunk async for chunk in aiter_handle(handle, chunk_size=4096)]

        chunks = asyncio.run(consume())
        self.assertEqual(b"".join(chunks), data)
        self.assertEqual([len(chunk) for chunk in chunks], [4096, 4096, 2048])
        self.assertTrue(handle.closed)

    def test_early_close_closes_the_handle(self):
        # A client that disconnects mid-download closes the async iterator;
        # the handle must not stay open until GC.
        self.path.write_bytes(b"abcdefgh")
        handle = self.path.open("rb")

        async def consume_one():
            stream = aiter_handle(handle, chunk_size=2)
            first = await anext(stream)
            await stream.aclose()
            return first

        first = asyncio.run(consume_one())
        self.assertEqual(first, b"ab")
        self.assertTrue(handle.closed)
