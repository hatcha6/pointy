"""The FTP service: the server's IO loop plus the two threads that keep it honest.

* the **IO loop** (main thread) talks FTP and nothing else;
* the **bookkeeping thread** reloads accounts, writes upload events to the
  database and publishes the heartbeat;
* the **ingest thread** decides uploads (``archive.ingest``) and, every few
  minutes, holds the archive to its budget (``archive.housekeeping``).

The ingest lives here rather than in Celery on purpose. The service that owns
the inbox is the one that empties it: nothing about it waits behind a backup
or a data import holding the worker's two slots, and a shop that is not using
FTP runs no ingest at all.

Stopping is graceful: SIGTERM stops accepting, closes sessions (a DVR retries
an interrupted upload), and flushes the events already queued.
"""

from __future__ import annotations

import logging
import os
import signal
import threading
import time
from datetime import timedelta

from django.conf import settings
from django.db import close_old_connections
from django.utils import timezone

from ..archive import housekeeping, ingest, storage
from . import status
from .directory import AccountDirectory
from .events import EventSink
from .server import StorageGuard, build_server, quiet_library_logging

logger = logging.getLogger(__name__)

BOOKKEEPING_SECONDS = 1.0
DIRECTORY_REFRESH_SECONDS = 5.0
HEARTBEAT_SECONDS = 10.0
INGEST_SECONDS = 20.0
HOUSEKEEPING_SECONDS = 600.0


class FtpService:
    def __init__(self, *, host: str | None = None, port: int | None = None):
        self.host = host if host is not None else settings.POINTY_FTP_BIND
        self.port = port if port is not None else int(settings.POINTY_FTP_PORT)
        self.directory = AccountDirectory()
        self.events = EventSink()
        self.guard = StorageGuard()
        self.stop_event = threading.Event()
        self.server = None
        self.started_at = timezone.now()
        self.last_ingest_at = None
        self.last_ingest_error = ""
        self._threads: list[threading.Thread] = []

    # -- lifecycle -----------------------------------------------------------
    def start(self) -> None:
        quiet_library_logging()
        storage.ensure_tree()
        storage.clear_work()
        # Only this process decides uploads, so anything claimed now was
        # claimed by a previous run of it that died mid-pass.
        ingest.release_stale_claims(older_than=timedelta(0))
        while not self.directory.refresh():
            if self.stop_event.wait(5.0):
                return
        self.server = build_server(
            directory=self.directory,
            events=self.events,
            guard=self.guard,
            host=self.host,
            port=self.port,
        )
        for target, name in (
            (self._bookkeeping_loop, "ftp-bookkeeping"),
            (self._ingest_loop, "ftp-ingest"),
        ):
            thread = threading.Thread(target=target, name=name, daemon=True)
            thread.start()
            self._threads.append(thread)
        logger.info(
            "FTP upload server listening on %s:%s (public port %s, passive %s), %s account(s)",
            self.host,
            self.port,
            settings.POINTY_FTP_PUBLIC_PORT,
            settings.POINTY_FTP_PASSIVE_PORTS or "any",
            len(self.directory),
        )
        if self.server.handler.behind_proxy:
            logger.info(
                "FTP clients arrive through a port proxy (WSL): lockouts are per username, "
                "and no client address is recorded (POINTY_FTP_BEHIND_PROXY)"
            )

    def serve_forever(self) -> None:
        self._install_signal_handlers()
        self.start()
        try:
            while not self.stop_event.is_set():
                # One poll at a time, so the stop flag is seen within a second.
                # Straight to the loop rather than ``serve_forever``, which logs
                # "starting FTP server" on every call.
                self.server.ioloop.loop(timeout=1.0, blocking=False)
        finally:
            self.shutdown()

    def stop(self, *_args) -> None:
        self.stop_event.set()

    def shutdown(self) -> None:
        self.stop_event.set()
        if self.server is not None:
            try:
                self.server.close_all()
            except Exception:  # noqa: BLE001 - shutting down regardless
                logger.debug("closing FTP sessions failed", exc_info=True)
        for thread in self._threads:
            thread.join(timeout=15)
        try:
            close_old_connections()
            self.events.drain()
        except Exception:  # noqa: BLE001
            logger.warning("could not flush FTP events on shutdown", exc_info=True)
        status.clear()
        logger.info("FTP upload server stopped")

    def _install_signal_handlers(self) -> None:
        if threading.current_thread() is not threading.main_thread():
            return
        for signum in (signal.SIGTERM, signal.SIGINT):
            signal.signal(signum, self.stop)

    # -- threads -------------------------------------------------------------
    def _bookkeeping_loop(self) -> None:
        next_refresh = 0.0
        next_heartbeat = 0.0
        while not self.stop_event.wait(BOOKKEEPING_SECONDS):
            try:
                close_old_connections()
                now = time.monotonic()
                if now >= next_refresh:
                    self.directory.refresh()
                    next_refresh = now + DIRECTORY_REFRESH_SECONDS
                self.events.drain()
                if now >= next_heartbeat:
                    status.publish(self.heartbeat())
                    next_heartbeat = now + HEARTBEAT_SECONDS
            except Exception:  # noqa: BLE001 - the loop must outlive any one failure
                logger.exception("FTP bookkeeping failed")

    def _ingest_loop(self) -> None:
        next_housekeeping = time.monotonic() + 30.0
        # A first pass soon after start: uploads may have been waiting while
        # the service was down.
        wait = 5.0
        while not self.stop_event.wait(wait):
            wait = INGEST_SECONDS
            try:
                close_old_connections()
                report = ingest.run_pass()
                self.last_ingest_at = timezone.now()
                self.last_ingest_error = "; ".join(report.errors[-3:])
                if report.claimed:
                    logger.info(
                        "footage ingest: %s decided, %s kept (%s clips), %s discarded, %s unreadable, %s retried",
                        report.claimed,
                        report.kept,
                        report.clips,
                        report.discarded,
                        report.unreadable,
                        report.retried,
                    )
                self.guard.inbox_bytes = storage.tree_size(storage.inbox_root())
                if time.monotonic() >= next_housekeeping:
                    close_old_connections()
                    housekeeping.run()
                    next_housekeeping = time.monotonic() + HOUSEKEEPING_SECONDS
                    self.guard.refresh()
            except Exception as exc:  # noqa: BLE001
                self.last_ingest_error = f"{exc.__class__.__name__}: {exc}"
                logger.exception("footage ingest failed")

    def heartbeat(self) -> dict:
        accepting = self.guard.accepting()
        budget = self.guard.budget
        return {
            "pid": os.getpid(),
            "started_at": self.started_at.isoformat(),
            "heartbeat_at": timezone.now().isoformat(),
            "port": self.port,
            "public_port": int(settings.POINTY_FTP_PUBLIC_PORT),
            "passive_ports": str(settings.POINTY_FTP_PASSIVE_PORTS or ""),
            "accounts": len(self.directory),
            "accepting": accepting,
            "refusing_reason": self.guard.reason,
            "free_bytes": budget.free if budget else None,
            "min_free_bytes": budget.min_free if budget else None,
            "inbox_bytes": self.guard.inbox_bytes,
            "dropped_events": self.events.dropped,
            "last_ingest_at": self.last_ingest_at.isoformat() if self.last_ingest_at else None,
            "last_ingest_error": self.last_ingest_error[:500],
            "recent_unknown_logins": [
                {"username": item.username, "peer": item.peer, "at": item.at.isoformat()}
                for item in list(self.events.recent_unknown)
            ],
        }
