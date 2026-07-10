"""Serve a blocking sync generator as a live async stream under ASGI.

Django can serve a ``StreamingHttpResponse`` built from a sync iterator over
ASGI, but only by warning ("StreamingHttpResponse must consume synchronous
iterators … Use an asynchronous iterator instead.") and then buffering the
ENTIRE body via ``sync_to_async(list)`` before sending the first byte. For an
SSE endpoint that kills streaming outright: under uvicorn the client stares at
a silent connection until the whole turn finishes (and in practice times out),
even though the same response streams fine under WSGI.

The generators we stream (the AI chat turn) are deeply synchronous — blocking
relay reads, ORM writes — so instead of rewriting them async, the bridge runs
the generator on its own dedicated thread: the same one-thread,
one-DB-connection world it gets under WSGI. Each chunk is handed to the event
loop the moment it's produced, restoring token-by-token delivery.
"""

import asyncio
import threading

from django.db import connections


class _StreamEnd:
    """Sentinel closing the stream; carries the producer's exception, if any."""

    def __init__(self, error=None):
        self.error = error


async def aiter_in_thread(generator):
    """Async-iterate a blocking sync ``generator``, chunk by chunk.

    The generator body only starts executing (and the worker thread only
    starts) on first ``__anext__``, mirroring generator laziness. Closing the
    async iterator early — Django does this when the client disconnects —
    closes the sync generator on its thread, so its ``finally`` blocks (persist
    the partial answer, close the upstream relay stream) still run, exactly as
    they would under WSGI. A generator exception is re-raised here, aborting
    the response mid-stream like the sync path would.
    """
    loop = asyncio.get_running_loop()
    queue = asyncio.Queue()
    closed = threading.Event()

    def emit(item):
        # Hand one item to the event loop, blocking the worker until the loop
        # accepts it. Raises — ending the worker — if the loop is gone
        # (server shutdown mid-stream).
        asyncio.run_coroutine_threadsafe(queue.put(item), loop).result()

    def produce():
        error = None
        try:
            for chunk in generator:
                if closed.is_set():
                    break
                emit(chunk)
        except BaseException as exc:
            error = exc
        finally:
            try:
                generator.close()
            except Exception:
                pass
            # The generator's ORM work opened connections owned by this
            # thread; nothing else (no request_finished, no handler) will ever
            # close them.
            connections.close_all()
            try:
                emit(_StreamEnd(error))
            except Exception:
                pass  # consumer/loop already gone; nothing left to notify

    thread = threading.Thread(target=produce, name="sse-stream-bridge", daemon=True)
    thread.start()
    try:
        while True:
            item = await queue.get()
            if isinstance(item, _StreamEnd):
                if item.error is not None:
                    raise item.error
                return
            yield item
    finally:
        closed.set()
