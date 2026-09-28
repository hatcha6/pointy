"""The FTP server a recorder uploads to: pyftpdlib, narrowed to one job.

What the narrowing is, and why:

* **Write-only.** ``elawdfm`` — change directory, list, append, store, delete,
  rename, make directory. No ``RETR``: these credentials put footage in and
  never take it out, and no DVR needs to read back what it sent.
* **Binary, always.** A client that never sends ``TYPE I`` would otherwise get
  ASCII mode, which rewrites every CR LF in a video file into LF.
* **LAN-only.** A login from a public address is refused before the password
  is looked at (``POINTY_FTP_ALLOW_PUBLIC_PEERS`` lifts it).
* **Locked out after ten failures** from one address in ten minutes, for
  fifteen (per username behind a port proxy, below). A DVR with a mistyped
  password retries forever; so would a guesser.
* **Refuses rather than fills.** ``STOR``/``APPE`` answer 452 below the disk
  floor or when the inbox has backed up, and a transfer in progress is cut off
  if the floor is crossed under it — the DVR retries later, and the database
  sharing this disk keeps working.
* **PASV announces the address the installer was shown**, because inside
  Docker the server's own address is one the DVR cannot reach. EPSV and active
  mode carry no address and need nothing.

**Behind a port proxy** — a Windows server, where the stack runs in WSL and the
LAN reaches it through ``netsh portproxy`` — every DVR arrives from the same
address: the Windows host's own. Nothing above may then rest on the address
alone. A lockout is per username (one DVR with a stale password must not lock
out the others), there is no per-address connection cap, active mode may dial
the DVR's own LAN address (its ``PORT`` never matches the proxy's), and no
address is recorded as a DVR's. "LAN-only" is the Windows firewall rule's job
there. ``POINTY_FTP_BEHIND_PROXY=auto`` recognises WSL by its kernel, which a
container shares.

The IO loop never touches the database: accounts come from
:class:`~.directory.AccountDirectory`, bookkeeping goes to
:class:`~.events.EventSink`.
"""

from __future__ import annotations

import hmac
import ipaddress
import logging
import platform
import socket
import threading
import time
from collections import deque

from django.conf import settings
from pyftpdlib.authorizers import DummyAuthorizer
from pyftpdlib.exceptions import AuthenticationFailed
from pyftpdlib.handlers import DTPHandler, FTPHandler
from pyftpdlib.ioloop import IOLoop
from pyftpdlib.servers import FTPServer

from ..archive import storage
from .directory import AccountDirectory
from .events import EventSink

logger = logging.getLogger(__name__)

PERMISSIONS = "elawdfm"
BANNER = "Pointy camera upload ready."
LOGIN_MESSAGE = "Logged in. Upload footage here."
MAX_CONNECTIONS = 256
#: One NVR uploading every channel at once opens a connection per transfer.
MAX_CONNECTIONS_PER_IP = 48
#: Re-check free space this often during a transfer, in bytes.
SPACE_CHECK_EVERY = 64 * 1024 * 1024
#: The longest path, inside the inbox, an upload may have. The row that tracks
#: it holds 1024 characters; a DVR's own names are a small fraction of that.
MAX_PATH_CHARS = 1000


def parse_port_range(value: str) -> list[int] | None:
    """``"50000-50019"`` -> ports. ``""`` or ``"0"`` -> ``None`` (any port)."""
    text = str(value or "").strip()
    if not text or text == "0":
        return None
    if "-" in text:
        low, high = (int(part) for part in text.split("-", 1))
    else:
        low = high = int(text)
    if not 1024 <= low <= high <= 65535:
        raise ValueError(f"invalid passive port range {value!r}")
    return list(range(low, high + 1))


def _address(value: str):
    text = str(value or "")
    if text.startswith("::ffff:"):
        text = text[7:]
    try:
        return ipaddress.ip_address(text)
    except ValueError:
        return None


def peer_is_private(address: str) -> bool:
    parsed = _address(address)
    if parsed is None:
        return False
    return parsed.is_private or parsed.is_loopback or parsed.is_link_local


_LAN_NETWORKS = tuple(
    ipaddress.ip_network(network)
    for network in ("10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "fc00::/7")
)


def is_lan_target(address: str) -> bool:
    """Whether an active-mode data connection may be opened to ``address``.

    The private ranges only: never loopback (this machine), link-local or
    anything public, which is what an FTP bounce would aim at.
    """
    parsed = _address(address)
    return parsed is not None and any(parsed in network for network in _LAN_NETWORKS)


def behind_port_proxy(value: str | None = None) -> bool:
    """Whether every client reaches this server through one forwarding hop.

    ``POINTY_FTP_BEHIND_PROXY``: ``true``/``false``, or ``auto`` (the default),
    which means "on WSL". A container shares its host's kernel, so the kernel
    release names WSL from inside Docker too — and on a Windows server the LAN
    reaches WSL only through ``netsh portproxy``, which connects from the host.
    """
    if value is None:
        value = getattr(settings, "POINTY_FTP_BEHIND_PROXY", "auto")
    text = str(value or "").strip().lower()
    if text in {"1", "true", "yes", "on"}:
        return True
    if text in {"0", "false", "no", "off"}:
        return False
    return "microsoft" in platform.release().lower()


class LoginLockout:
    """Failed logins, in memory — this process is the only door.

    Counted per address and per address-and-username. On the LAN every DVR
    has an address of its own, and ten failures from one address lock it out.
    Behind a port proxy every DVR shares the proxy's address, so that rule
    would let one DVR with a stale password lock out all the others: there a
    username is locked on its own, and the address only after enough failures
    to be somebody trying many names.
    """

    WINDOW = 600.0
    LIMIT = 10
    SHARED_ADDRESS_LIMIT = 100
    BAN = 900.0
    MAX_TRACKED = 10_000

    def __init__(self, clock=time.monotonic, *, shared_address: bool = False):
        self._clock = clock
        self.shared_address = shared_address
        self.address_limit = self.SHARED_ADDRESS_LIMIT if shared_address else self.LIMIT
        self._failures: dict[tuple, deque] = {}
        self._banned: dict[tuple, float] = {}
        self._lock = threading.Lock()

    def _counters(self, peer: str, username: str):
        name = str(username or "").strip().lower()
        return ((("address", peer), self.address_limit), (("user", peer, name), self.LIMIT))

    def is_locked(self, peer: str, username: str = "") -> bool:
        with self._lock:
            now = self._clock()
            for key, _limit in self._counters(peer, username):
                until = self._banned.get(key)
                if until is None:
                    continue
                if now >= until:
                    del self._banned[key]
                    continue
                return True
            return False

    def failed(self, peer: str, username: str = "") -> None:
        now = self._clock()
        with self._lock:
            if len(self._failures) > self.MAX_TRACKED:
                self._failures.clear()
            locked = []
            for key, limit in self._counters(peer, username):
                attempts = self._failures.setdefault(key, deque())
                attempts.append(now)
                while attempts and now - attempts[0] > self.WINDOW:
                    attempts.popleft()
                if len(attempts) >= limit:
                    self._banned[key] = now + self.BAN
                    attempts.clear()
                    locked.append(key)
        if locked and locked[0][0] == "address":
            logger.warning("FTP logins from %s locked out after repeated failures", peer)
        elif locked:
            logger.warning("FTP logins as %r from %s locked out after repeated failures", locked[0][2], peer)

    def succeeded(self, peer: str, username: str = "") -> None:
        with self._lock:
            (address, _), (user, _) = self._counters(peer, username)
            self._failures.pop(user, None)
            # A shared address is every DVR's: one logging in says nothing
            # about the failures of another, or of a guesser.
            if not self.shared_address:
                self._failures.pop(address, None)


class StorageGuard:
    """Whether there is room for another upload. Cheap enough to ask per STOR.

    ``inbox_bytes`` is set by the ingest thread after each pass; the free
    space is re-read at most every few seconds.
    """

    RECHECK_SECONDS = 5.0

    def __init__(self, clock=time.monotonic):
        self._clock = clock
        self._checked = -1e9
        self._budget = None
        self.inbox_bytes = 0
        self.reason = ""

    def refresh(self) -> None:
        try:
            self._budget = storage.disk_budget()
        except OSError as exc:
            logger.warning("could not read free space for footage: %s", exc)
            self._budget = None
        self._checked = self._clock()

    def accepting(self, *, force: bool = False) -> bool:
        if force or self._clock() - self._checked > self.RECHECK_SECONDS:
            self.refresh()
        budget = self._budget
        if budget is None:
            self.reason = ""
            return True
        if budget.below_floor:
            self.reason = "disk_floor"
            return False
        if budget.inbox_limit and self.inbox_bytes > budget.inbox_limit:
            self.reason = "inbox_full"
            return False
        self.reason = ""
        return True

    @property
    def budget(self):
        return self._budget


class PointyAuthorizer(DummyAuthorizer):
    """Accounts from the in-memory directory; one fixed set of permissions."""

    def __init__(self, directory: AccountDirectory, events: EventSink, lockout: LoginLockout, *, allow_public: bool):
        super().__init__()
        self.directory = directory
        self.events = events
        self.lockout = lockout
        self.allow_public = allow_public

    def validate_authentication(self, username, password, handler):
        peer = str(getattr(handler, "remote_ip", "") or "")
        if not self.allow_public and not peer_is_private(peer):
            raise AuthenticationFailed("Uploads are accepted only from the shop network.")
        if self.lockout.is_locked(peer, username):
            raise AuthenticationFailed("Too many failed logins. Try again later.")
        entry = self.directory.lookup(username)
        if entry is None or not hmac.compare_digest(
            entry.password.encode("utf-8"), str(password or "").encode("utf-8")
        ):
            self.lockout.failed(peer, username)
            self.events.login_failed(
                entry.recorder_id if entry else None,
                username,
                getattr(handler, "reported_peer", peer),
            )
            raise AuthenticationFailed("Authentication failed.")
        if not entry.enabled:
            raise AuthenticationFailed("This recorder is switched off in Pointy.")
        self.lockout.succeeded(peer, username)

    def get_home_dir(self, username):
        entry = self.directory.lookup(username)
        if entry is None:
            raise AuthenticationFailed("Authentication failed.")
        return str(storage.ensure_inbox(entry.recorder_id).resolve())

    def has_user(self, username):
        return self.directory.lookup(username) is not None

    def has_perm(self, username, perm, path=None):
        return perm in PERMISSIONS

    def get_perms(self, username):
        return PERMISSIONS

    def get_msg_login(self, username):
        return LOGIN_MESSAGE

    def get_msg_quit(self, username):
        return "Goodbye."


class PointyDTPHandler(DTPHandler):
    """A data channel that is always binary and stops at the size limit."""

    def enable_receiving(self, type, cmd):  # noqa: A002 - pyftpdlib's name
        super().enable_receiving("i", cmd)

    def handle_read(self):
        super().handle_read()
        control = self.cmd_channel
        if getattr(self, "_closed", False) or not self.receive:
            return
        received = self.tot_bytes_received
        limit = getattr(control, "max_upload_bytes", 0)
        if limit and received > limit:
            self._resp = ("552 Upload exceeds the size limit; transfer aborted.", logger.info)
            self.close()
            return
        checkpoint = getattr(self, "_next_space_check", SPACE_CHECK_EVERY)
        if received >= checkpoint:
            self._next_space_check = received + SPACE_CHECK_EVERY
            guard = getattr(control, "guard", None)
            if guard is not None and not guard.accepting(force=True):
                self._resp = ("452 Insufficient storage space; transfer aborted.", logger.info)
                self.close()

    # pyftpdlib binds the IO loop's read event to ``handle_read`` by class
    # attribute ("small speedup"), so an override is never called unless the
    # alias is re-pointed at it.
    handle_read_event = handle_read


class PointyFTPHandler(FTPHandler):
    """One DVR's session. Class attributes are bound per server by ``build_server``."""

    dtp_handler = PointyDTPHandler
    banner = BANNER
    # A DVR holds its control connection open between uploads.
    timeout = 600
    max_login_attempts = 3
    auth_failed_timeout = 2
    permit_foreign_addresses = False
    permit_privileged_ports = False
    use_sendfile = False

    directory: AccountDirectory = None
    events: EventSink = None
    guard: StorageGuard = None
    max_upload_bytes = 0
    #: Operator override for PASV; normally empty.
    forced_passive_address = ""
    #: Every client arrives through one forwarding hop (see the module notes).
    behind_proxy = False

    recorder_id = None

    @property
    def reported_peer(self) -> str:
        """The client's address, as worth recording against a DVR.

        Behind a port proxy it is the proxy's own and the same for every DVR;
        an installer shown it would go looking for a device that is not there.
        """
        return "" if self.behind_proxy else str(self.remote_ip or "")

    def on_login(self, username):
        entry = self.directory.lookup(username)
        if entry is None:
            self.close_when_done()
            return
        self.recorder_id = entry.recorder_id
        announced = self.forced_passive_address or entry.advertised_host
        self.masquerade_address = _resolve_ipv4(announced) if announced else None
        self.events.logged_in(entry.recorder_id, self.reported_peer)
        logger.info("FTP recorder %s logged in from %s", entry.recorder_id, self.remote_ip)

    def _make_eport(self, ip, port):
        # Through a proxy the control connection comes from the proxy, so the
        # address in every PORT/EPRT looks "foreign": it is the DVR's own.
        # RFC 2577's concern is a server made to send data to somebody else's
        # host; a private address is the shop network, where the DVRs are.
        if self.behind_proxy and is_lan_target(ip):
            self.permit_foreign_addresses = True
            try:
                return super()._make_eport(ip, port)
            finally:
                self.permit_foreign_addresses = False
        return super()._make_eport(ip, port)

    def _refuse_upload(self, path: str | None = None) -> bool:
        """Whether to turn this upload away, having already answered why."""
        entry = self.directory.lookup(self.username) if self.username else None
        if entry is None or not entry.enabled:
            # The setup was deleted or switched off after this session logged
            # in. The DVR keeps its connection open between uploads, so the
            # check at login is not enough on its own.
            self.respond("530 This recorder is no longer accepted.")
            self.close_when_done()
            return True
        if path is not None and len(path) - len(self.fs.root) > MAX_PATH_CHARS:
            self.respond("553 File name too long.")
            return True
        if self.guard is not None and not self.guard.accepting():
            self.respond("452 Insufficient storage space. Try again later.")
            return True
        return False

    def ftp_STOR(self, file, mode="w"):
        if self._refuse_upload(file):
            return None
        return super().ftp_STOR(file, mode)

    def ftp_STOU(self, line):
        if self._refuse_upload():
            return None
        return super().ftp_STOU(line)

    def ftp_RETR(self, file):
        # Belt and braces behind the permission string.
        self.respond("550 Not permitted.")

    def _transfer_seconds(self) -> float:
        # Called from the data channel's close, before it is detached.
        channel = self.data_channel
        try:
            return float(channel.get_elapsed_time()) if channel is not None else 0.0
        except Exception:  # noqa: BLE001 - a missing timing is only a worse estimate
            return 0.0

    def on_file_received(self, file):
        if self.recorder_id is not None:
            self.events.uploaded(
                self.recorder_id,
                file,
                peer=self.reported_peer,
                complete=True,
                transfer_seconds=self._transfer_seconds(),
            )

    def on_incomplete_file_received(self, file):
        if self.recorder_id is not None:
            self.events.uploaded(
                self.recorder_id,
                file,
                peer=self.reported_peer,
                complete=False,
                transfer_seconds=self._transfer_seconds(),
            )

    def ftp_RNTO(self, path):
        result = super().ftp_RNTO(path)
        if result and self.recorder_id is not None:
            source, target = result
            self.events.renamed(self.recorder_id, source, target)
        return result

    def ftp_DELE(self, path):
        result = super().ftp_DELE(path)
        if result and self.recorder_id is not None:
            self.events.deleted(self.recorder_id, result)
        return result


_resolved: dict[str, tuple[str | None, float]] = {}


def _resolve_ipv4(host: str) -> str | None:
    """An IPv4 literal for PASV. A host name is resolved, and cached briefly."""
    try:
        return str(ipaddress.IPv4Address(host))
    except ValueError:
        pass
    cached = _resolved.get(host)
    if cached and time.monotonic() - cached[1] < 300:
        return cached[0]
    try:
        address = socket.gethostbyname(host)
    except OSError:
        address = None
    _resolved[host] = (address, time.monotonic())
    return address


def build_server(
    *,
    directory: AccountDirectory,
    events: EventSink,
    guard: StorageGuard,
    host: str | None = None,
    port: int | None = None,
    passive_ports: list[int] | None | str = "settings",
    forced_passive_address: str | None = None,
    max_upload_bytes: int | None = None,
    allow_public: bool | None = None,
    behind_proxy: bool | None = None,
    lockout: LoginLockout | None = None,
    ioloop: IOLoop | None = None,
) -> FTPServer:
    """An FTPServer bound to ``host:port``, not yet serving."""
    if passive_ports == "settings":
        passive_ports = parse_port_range(getattr(settings, "POINTY_FTP_PASSIVE_PORTS", ""))
    if max_upload_bytes is None:
        max_upload_bytes = int(getattr(settings, "POINTY_FTP_MAX_FILE_MB", 4096)) * 1024 * 1024
    if allow_public is None:
        allow_public = bool(getattr(settings, "POINTY_FTP_ALLOW_PUBLIC_PEERS", False))
    if forced_passive_address is None:
        forced_passive_address = str(getattr(settings, "POINTY_FTP_PASSIVE_ADDRESS", "") or "")
    if behind_proxy is None:
        behind_proxy = behind_port_proxy()
    authorizer = PointyAuthorizer(
        directory,
        events,
        lockout or LoginLockout(shared_address=behind_proxy),
        allow_public=allow_public,
    )
    handler = type(
        "BoundPointyFTPHandler",
        (PointyFTPHandler,),
        {
            "authorizer": authorizer,
            "directory": directory,
            "events": events,
            "guard": guard,
            "passive_ports": passive_ports,
            "max_upload_bytes": max_upload_bytes,
            "forced_passive_address": forced_passive_address,
            "behind_proxy": behind_proxy,
        },
    )
    storage.ensure_tree()
    server = FTPServer(
        (
            host if host is not None else getattr(settings, "POINTY_FTP_BIND", "0.0.0.0"),
            port if port is not None else int(getattr(settings, "POINTY_FTP_PORT", 2121)),
        ),
        handler,
        ioloop=ioloop or IOLoop(),
    )
    server.max_cons = MAX_CONNECTIONS
    # Behind a proxy one address is every DVR in the shop; only the total holds.
    server.max_cons_per_ip = 0 if behind_proxy else MAX_CONNECTIONS_PER_IP
    return server


def quiet_library_logging() -> None:
    """pyftpdlib logs every command at INFO; a shop's log needs our lines only.

    Setting the level is not enough on its own: on its first poll pyftpdlib
    installs an INFO handler of its own — resetting the level — unless it sees
    one already. A do-nothing handler is what stops that; its warnings still
    propagate to the process's own handler.
    """
    library = logging.getLogger("pyftpdlib")
    library.setLevel(logging.WARNING)
    if not library.handlers:
        library.addHandler(logging.NullHandler())


__all__ = [
    "LoginLockout",
    "PointyAuthorizer",
    "PointyFTPHandler",
    "StorageGuard",
    "behind_port_proxy",
    "build_server",
    "is_lan_target",
    "parse_port_range",
    "peer_is_private",
    "quiet_library_logging",
]
