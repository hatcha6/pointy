"""Hold the `ftp` role back until a shop actually has an FTP upload setup.

The FTP server is a whole Django process (~110 MB) that most shops never use:
it only matters once someone adds a recorder as an "FTP upload" in the camera
settings. Until then this gate stands in for it, without importing Django:

- it polls Postgres for an FTP recorder every few seconds, and when one appears
  the entrypoint exec's the real server in its place;
- meanwhile it holds the FTP port and answers like the real server would to a
  DVR with no account (`220 ... Pointy`, then `530` to every login), so the
  container healthcheck, install.sh's port-21 fallback and the Windows keeper's
  bridge check (which looks for "220*Pointy*") all keep seeing a live service.

POINTY_FTP_MODE overrides the check: `on` starts the server at once, `off`
never does (the gate keeps answering). Anything else means `auto`.
"""

from __future__ import annotations

import os
import selectors
import socket
import time

import psycopg

GREETING = b"220 Pointy camera upload is idle: no FTP upload setup exists yet.\r\n"
REFUSAL = b"530 No FTP upload setup exists on this Pointy yet.\r\n"
GOODBYE = b"221 Goodbye.\r\n"
SETUP_QUERY = "SELECT EXISTS (SELECT 1 FROM surveillance_recorder WHERE connection = 'ftp')"
MAX_CLIENTS = 32
CLIENT_IDLE_SECONDS = 30


def mode() -> str:
    value = os.environ.get("POINTY_FTP_MODE", "auto").strip().lower()
    return value if value in {"on", "off"} else "auto"


def has_ftp_setup(database_url: str) -> bool | None:
    """True/False from the database; None when it cannot be asked right now."""
    if not database_url.startswith(("postgres://", "postgresql://")):
        return None
    try:
        with psycopg.connect(database_url, connect_timeout=5, autocommit=True) as conn:
            return bool(conn.execute(SETUP_QUERY).fetchone()[0])
    except psycopg.errors.UndefinedTable:
        return False  # a fresh install before its first migration
    except Exception:  # noqa: BLE001 - asked again next poll
        return None


class IdleFtp:
    """A listener that greets, refuses every login, and never touches a disk."""

    def __init__(self, bind: str, port: int):
        self.selector = selectors.DefaultSelector()
        self.server = socket.create_server((bind, port), reuse_port=False, backlog=16)
        self.server.setblocking(False)
        self.selector.register(self.server, selectors.EVENT_READ, None)
        self.clients: dict[socket.socket, float] = {}

    def serve(self, seconds: float) -> None:
        deadline = time.monotonic() + seconds
        while (left := deadline - time.monotonic()) > 0:
            for key, _ in self.selector.select(timeout=min(left, 1.0)):
                if key.data is None:
                    self._accept()
                else:
                    self._read(key.fileobj)
            self._expire()

    def close(self) -> None:
        for client in list(self.clients):
            self._drop(client)
        self.selector.unregister(self.server)
        self.server.close()
        self.selector.close()

    def _accept(self) -> None:
        try:
            client, _ = self.server.accept()
        except OSError:
            return
        if len(self.clients) >= MAX_CLIENTS:
            client.close()
            return
        client.setblocking(False)
        try:
            client.send(GREETING)
        except OSError:
            client.close()
            return
        self.clients[client] = time.monotonic()
        self.selector.register(client, selectors.EVENT_READ, "client")

    def _read(self, client: socket.socket) -> None:
        try:
            data = client.recv(1024)
        except OSError:
            data = b""
        if not data:
            self._drop(client)
            return
        self.clients[client] = time.monotonic()
        quit_ = any(line.strip().upper().startswith(b"QUIT") for line in data.splitlines())
        try:
            client.send(GOODBYE if quit_ else REFUSAL * max(1, data.count(b"\n")))
        except OSError:
            quit_ = True
        if quit_:
            self._drop(client)

    def _expire(self) -> None:
        cutoff = time.monotonic() - CLIENT_IDLE_SECONDS
        for client, seen in list(self.clients.items()):
            if seen < cutoff:
                self._drop(client)

    def _drop(self, client: socket.socket) -> None:
        self.clients.pop(client, None)
        try:
            self.selector.unregister(client)
        except (KeyError, ValueError):
            pass
        client.close()


def wait_until_needed(*, check=has_ftp_setup, listener_factory=IdleFtp, log=print) -> None:
    """Return when the real FTP server should start; never returns in `off`."""
    current = mode()
    if current == "on":
        return
    interval = float(os.environ.get("POINTY_FTP_GATE_INTERVAL", "10"))
    database_url = os.environ.get("DATABASE_URL", "")
    if current == "auto" and check(database_url):
        return
    listener = listener_factory(
        os.environ.get("POINTY_FTP_BIND", "0.0.0.0"),
        int(os.environ.get("POINTY_FTP_PORT", "2121")),
    )
    log(
        "[ftp] no FTP upload setup yet: answering on the FTP port without the server"
        + ("" if current == "auto" else " (POINTY_FTP_MODE=off)"),
        flush=True,
    )
    unanswered = False
    try:
        while True:
            listener.serve(interval)
            if current != "auto":
                continue
            found = check(database_url)
            if found:
                log("[ftp] an FTP upload setup exists: starting the server", flush=True)
                return
            if found is None and not unanswered:
                log(
                    "[ftp] cannot ask the database for FTP upload setups yet; still trying",
                    flush=True,
                )
            unanswered = found is None
    finally:
        listener.close()
