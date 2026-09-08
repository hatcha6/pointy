"""Xiongmai (XMEye), spoken natively — the boxes half of Libya actually bought.

Sufian's shop is a 16-channel Xiongmai on firmware ``V4.03.R11`` (2026-09-08).
It answers no Hikvision ISAPI, no Dahua CGI, and — with ONVIF switched off in a
menu nobody could reach — no SOAP either. What it does answer is its own
protocol on **TCP 34567**, which is what the XMEye phone app uses, and which is
the only way to get this hardware more than a bare video stream.

That "more" is the point of this driver existing alongside
:mod:`.generic_rtsp`. Direct RTSP gives live tiles. This gives the device's real
identity, the channel names the shop typed into the DVR, and — the one that
matters — **recording search**, which is what invoice-linked footage is built
on. Without a search the player cannot know whether a sale's minute was even
recorded.

**The protocol.** Undocumented and reverse-engineered, so everything here is
written to fail loudly and specifically rather than to guess. A 20-byte binary
header frames a JSON body; the login password is an eight-character digest of
its MD5 that Xiongmai invented (:func:`sofia_hash`); a session id threads the
rest of the conversation. Where the firmware disagrees with any of that, login
returns a numbered error and the installer is told which of the two problems
they have — wrong password, or a box that does not speak this at all.

**Video still comes over RTSP.** The native protocol streams video too, as
length-prefixed binary over the same socket, but the frame path here is built on
handing ffmpeg a URL — so live and playback use port 554 and the control channel
is used for what only it can answer. Playback-by-time over RTSP is the one part
that varies by firmware: see :meth:`XiongmaiDriver.playback_rtsp_url`.
"""

from __future__ import annotations

import hashlib
import json
import socket
import struct
from datetime import datetime

from .base import (
    CONNECT_TIMEOUT,
    READ_TIMEOUT,
    ChannelInfo,
    DeviceInfo,
    RecorderAuthError,
    RecorderDriver,
    RecorderError,
    RecorderTarget,
    RecordingSegment,
    RecorderUnreachable,
    StreamQuality,
    parse_device_datetime,
    rtsp_netloc,
)

#: The port the XMEye app talks to. Open on every one of these boxes and on
#: almost nothing else, which is what makes it a reliable fingerprint.
DVRIP_PORT = 34567

# Message ids. Requests are even, replies are the request plus one.
LOGIN = 1000
LOGOUT = 1002
SYSINFO = 1020
CHANNEL_TITLE = 1048
FILE_SEARCH = 1440
TIME_QUERY = 1452

#: ``Ret`` values that mean the credentials were refused rather than the request
#: being wrong. Reported apart because they send the installer to a different
#: place: the password field, not the address field.
AUTH_RETURNS = {106, 107, 203, 205}
OK_RETURNS = {100, 515}

#: 0 is the main stream and 1 the sub, the same way round as everywhere else.
STREAM_BY_QUALITY = {StreamQuality.MAIN: 0, StreamQuality.SUB: 1}

_HEADER = struct.Struct("<BB2xIIBBHI")
_HEADER_SIZE = 20
#: Every frame ends with these two bytes and the header's length counts them.
TAIL = b"\x0a\x00"
#: A file-search reply on a busy 16-channel box is large but bounded; anything
#: past this is a device misbehaving, and reading it unbounded is how a DVR on
#: the shop LAN becomes our memory problem.
MAX_PAYLOAD = 4 * 1024 * 1024


def sofia_hash(password: str) -> str:
    """Xiongmai's own password digest: eight characters out of an MD5.

    Not a standard construction and not a strong one — it folds a 128-bit hash
    into 48 bits — but it is what the firmware compares against, so it is what
    has to be sent. The plaintext password never goes on the wire.
    """
    digest = hashlib.md5(password.encode("utf-8")).digest()
    alphabet = (
        "0123456789"
        "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
        "abcdefghijklmnopqrstuvwxyz"
    )
    return "".join(
        alphabet[(digest[2 * i] + digest[2 * i + 1]) % 62] for i in range(8)
    )


class _Session:
    """One logged-in TCP conversation with the recorder.

    Held open across a call sequence because logging in costs a round trip and
    the box limits how many sessions it will hold; closed explicitly, because a
    leaked session is one fewer the shop's own phone app can open.
    """

    def __init__(self, target: RecorderTarget, port: int):
        self.target = target
        self.port = port
        self.socket = None
        self.session_id = 0
        self.sequence = 0

    # -- transport ---------------------------------------------------------
    def connect(self):
        if self.socket is not None:
            return
        try:
            self.socket = socket.create_connection(
                (self.target.host, self.port), timeout=CONNECT_TIMEOUT
            )
            self.socket.settimeout(READ_TIMEOUT)
        except OSError as exc:
            raise RecorderUnreachable(
                f"Could not reach the recorder on {self.target.host}:{self.port} "
                f"({exc.__class__.__name__})."
            ) from exc

    def close(self):
        if self.socket is None:
            return
        try:
            if self.session_id:
                self._send(LOGOUT, {"Name": "", "SessionID": self._session_hex})
        except Exception:  # pragma: no cover - closing must never raise
            pass
        try:
            self.socket.close()
        finally:
            self.socket = None
            self.session_id = 0

    @property
    def _session_hex(self) -> str:
        return f"0x{self.session_id:08x}"

    def _send(self, message_id: int, payload: dict):
        # The frame ends "\n\0" and the declared length counts both. Verified
        # against OpenIPC/python-dvr, which is the reference implementation for
        # this protocol; a one-byte tail is refused by the firmware.
        body = json.dumps(payload).encode("utf-8") + TAIL
        header = _HEADER.pack(
            0xFF, 0x00, self.session_id, self.sequence, 0, 0, message_id, len(body)
        )
        self.sequence += 1
        try:
            self.socket.sendall(header + body)
        except OSError as exc:
            raise RecorderUnreachable(f"The recorder closed the connection: {exc}") from exc

    def _read_exactly(self, count: int) -> bytes:
        chunks = []
        remaining = count
        while remaining > 0:
            try:
                chunk = self.socket.recv(remaining)
            except socket.timeout as exc:
                raise RecorderUnreachable("The recorder did not answer in time.") from exc
            except OSError as exc:
                raise RecorderUnreachable(f"The recorder closed the connection: {exc}") from exc
            if not chunk:
                raise RecorderUnreachable("The recorder closed the connection.")
            chunks.append(chunk)
            remaining -= len(chunk)
        return b"".join(chunks)

    def _receive(self) -> dict:
        header = self._read_exactly(_HEADER_SIZE)
        _, _, session, _, _, _, _, length = _HEADER.unpack(header)
        if length > MAX_PAYLOAD:
            raise RecorderError("The recorder sent an implausibly large reply.")
        body = self._read_exactly(length) if length else b""
        if session and not self.session_id:
            self.session_id = session
        # Strip the "\n\0" tail by position, then drop the stray control
        # bytes some firmwares emit mid-JSON — both as python-dvr does, because
        # a strict parse fails on perfectly ordinary replies otherwise.
        payload = body[:-len(TAIL)] if len(body) >= len(TAIL) else body
        text = bytes(
            b for b in payload if b >= 32 or b in (9, 10, 13)
        ).decode("latin1").strip()
        if not text:
            return {}
        try:
            return json.loads(text)
        except ValueError as exc:
            # A box that answers this port with something other than DVRIP JSON
            # is not a Xiongmai, and saying so is what lets detection move on.
            raise RecorderError(f"Not a Xiongmai recorder: {exc}") from exc

    def call(self, message_id: int, payload: dict) -> dict:
        self.connect()
        body = dict(payload)
        if self.session_id:
            body.setdefault("SessionID", self._session_hex)
        self._send(message_id, body)
        reply = self._receive()
        self._check(reply)
        return reply

    @staticmethod
    def _check(reply: dict):
        ret = reply.get("Ret")
        if ret is None or ret in OK_RETURNS:
            return
        if ret in AUTH_RETURNS:
            raise RecorderAuthError("The recorder rejected the username or password.")
        raise RecorderError(f"The recorder refused the request (code {ret}).")

    # -- session -----------------------------------------------------------
    def login(self):
        if self.session_id:
            return
        self.connect()
        self._send(
            LOGIN,
            {
                "EncryptType": "MD5",
                "LoginType": "DVRIP-Web",
                "UserName": self.target.username or "admin",
                "PassWord": sofia_hash(self.target.password or ""),
            },
        )
        reply = self._receive()
        self._check(reply)
        raw = reply.get("SessionID") or "0x0"
        try:
            self.session_id = int(str(raw), 16)
        except ValueError:
            self.session_id = 0
        if not self.session_id:
            raise RecorderError("The recorder did not open a session.")


class XiongmaiDriver(RecorderDriver):
    brand = "xiongmai"
    label = "Xiongmai / XMEye"

    #: ``OPFileQuery`` is documented, implemented by the reference library and
    #: pinned by tests, so search is claimed with confidence. It is also the half
    #: that invoice-linked footage actually needs: knowing whether a sale's
    #: minute was recorded at all.
    supports_search = True
    #: Playback is NOT claimed. Xiongmai streams recorded video over its own
    #: protocol as length-prefixed binary, and the RTSP-by-time URL built below
    #: — while it is the shape several OEM firmwares accept — is documented
    #: nowhere and could not be confirmed against real hardware. Claiming it
    #: would put a button in the client whose only outcome might be an error,
    #: which is the exact thing this flag exists to prevent. Prove it with
    #: ``manage.py probe_recorder --stream`` against a real box and this becomes
    #: a one-line change.
    supports_playback = False
    #: No JPEG endpoint. Live tiles come from ffmpeg over RTSP, like Direct RTSP.
    supports_snapshot = False

    def __init__(self, target: RecorderTarget):
        super().__init__(target)
        self._port = int(target.extra.get("dvrip_port") or DVRIP_PORT)
        self._session = _Session(target, self._port)
        self._channel_names: dict[int, str] | None = None

    def close(self):
        self._session.close()
        super().close()

    def _call(self, message_id: int, payload: dict) -> dict:
        self._session.login()
        return self._session.call(message_id, payload)

    # -- identity ----------------------------------------------------------
    def probe(self) -> DeviceInfo:
        reply = self._call(SYSINFO, {"Name": "SystemInfo"})
        info = reply.get("SystemInfo") or {}
        if not info:
            raise RecorderError("Not a Xiongmai recorder.")
        channels = self._declared_channel_count(info)
        return DeviceInfo(
            brand=self.brand,
            model=str(info.get("HardWare") or "").strip(),
            serial=str(info.get("SerialNo") or "").strip(),
            firmware=str(info.get("SoftWareVersion") or "").strip(),
            channel_count=channels,
            clock_offset_minutes=self.read_clock_offset_minutes(),
        )

    @staticmethod
    def _declared_channel_count(info: dict) -> int:
        """How many cameras the box says it has.

        ``VideoInChannel`` counts analogue inputs and ``DigChannel`` the IP ones;
        a hybrid XVR has both and a shop with a mixed install would otherwise see
        only half its cameras.
        """
        total = 0
        for key in ("VideoInChannel", "DigChannel"):
            try:
                total += int(info.get(key) or 0)
            except (TypeError, ValueError):
                continue
        return total

    def read_device_local_time(self):
        try:
            reply = self._call(TIME_QUERY, {"Name": "OPTimeQuery"})
        except RecorderError:
            return None
        return parse_device_datetime(str(reply.get("OPTimeQuery") or ""))

    # -- channels ----------------------------------------------------------
    def _titles(self) -> dict[int, str]:
        if self._channel_names is not None:
            return self._channel_names
        names: dict[int, str] = {}
        try:
            reply = self._call(CHANNEL_TITLE, {"Name": "ChannelTitle"})
        except RecorderError:
            # A box that will not give up its channel names is still usable;
            # the shop renames them in Pointy anyway.
            self._channel_names = names
            return names
        titles = reply.get("ChannelTitle") or []
        if isinstance(titles, list):
            for index, title in enumerate(titles, start=1):
                names[index] = str(title or "").strip()
        self._channel_names = names
        return names

    def list_channels(self) -> list[ChannelInfo]:
        names = self._titles()
        reply = self._call(SYSINFO, {"Name": "SystemInfo"})
        count = self._declared_channel_count(reply.get("SystemInfo") or {})
        count = max(count, max(names) if names else 0)
        if not count:
            raise RecorderError("The recorder reported no video channels.")
        return [
            ChannelInfo(channel=channel, name=names.get(channel, ""))
            for channel in range(1, count + 1)
        ]

    # -- video -------------------------------------------------------------
    def snapshot(self, channel: int, *, quality: str = StreamQuality.SUB) -> bytes:
        raise RecorderError(
            "This recorder has no snapshot address; its live view needs ffmpeg "
            "on the server."
        )

    def _rtsp(self, path: str) -> str:
        return f"rtsp://{rtsp_netloc(self.target)}{path}"

    def live_rtsp_url(self, channel: int, *, quality: str = StreamQuality.SUB) -> str:
        """The documented XMEye stream URL, overridable per recorder.

        The default is the shape the camera databases record for this firmware
        family. OEMs vary it — a trailing ``?real_stream``, a bare ``.sdp``, port
        5544 instead of 554 — so a recorder that carries an
        ``rtsp_path_template`` uses that instead. Control still comes from the
        native protocol either way, which is what keeps channel names and
        recording search working while the stream path is argued about.

        The credentials appear twice on purpose: in the authority, which is what
        ffmpeg authenticates with, and in the path, which is what this firmware
        family parses. Boxes in the field want both.
        """
        stream = STREAM_BY_QUALITY.get(StreamQuality.normalize(quality), 1)
        override = str(self.target.extra.get("rtsp_path_template") or "").strip()
        if override:
            try:
                path = override.format(
                    channel=int(channel),
                    channel0=int(channel) - 1,
                    stream=stream,
                    username=self.target.username,
                    password=self.target.password,
                )
            except (KeyError, IndexError, ValueError) as exc:
                raise RecorderError(
                    f"The RTSP address template is not valid: {exc}"
                ) from exc
            return self._rtsp(path if path.startswith("/") else "/" + path)
        return self._rtsp(
            f"/user={self.target.username}&password={self.target.password}"
            f"&channel={int(channel)}&stream={stream}.sdp?"
        )

    def playback_rtsp_url(
        self,
        channel: int,
        start: datetime,
        end: datetime,
        *,
        quality: str = StreamQuality.MAIN,
    ) -> str:
        """Playback by time, in the recorder's own wall clock.

        The times are converted through the measured clock offset for the same
        reason Dahua's are: the box serves whatever hour its own RTC believes,
        and a DVR left on the factory timezone will happily return footage from
        the wrong hour without erroring.

        **This is unverified and the driver does not advertise it** — see
        ``supports_playback``. No public source documents playback-by-time over
        RTSP for this firmware family; the shape below is inferred from the
        live URL and from what neighbouring OEMs accept. It is built rather than
        omitted so that a shop which turns out to support it needs one flag
        flipped instead of a driver written, and so
        ``manage.py probe_recorder --stream`` has something to test.
        """
        stream = STREAM_BY_QUALITY.get(StreamQuality.normalize(quality), 0)
        started = self.to_device_local(start).strftime("%Y_%m_%d_%H_%M_%S")
        ended = self.to_device_local(end).strftime("%Y_%m_%d_%H_%M_%S")
        return self._rtsp(
            f"/user={self.target.username}&password={self.target.password}"
            f"&channel={int(channel)}&stream={stream}"
            f"&starttime={started}&endtime={ended}.sdp?"
        )

    # -- recordings --------------------------------------------------------
    def search_recordings(
        self, channel: int, start: datetime, end: datetime
    ) -> list[RecordingSegment]:
        """Which parts of the window the box actually recorded.

        This is what makes invoice-linked footage work on this hardware: without
        it the player cannot tell "nothing was recorded then" from "the recorder
        is not answering", and would offer to play a gap.
        """
        payload = {
            "Name": "OPFileQuery",
            "OPFileQuery": {
                "BeginTime": self.to_device_local(start).strftime("%Y-%m-%d %H:%M:%S"),
                "EndTime": self.to_device_local(end).strftime("%Y-%m-%d %H:%M:%S"),
                # The wire protocol counts channels from zero; every other
                # surface in this driver counts from one.
                "Channel": int(channel) - 1,
                "DriverTypeMask": "0x0000FFFF",
                "Event": "*",
                "StreamType": "0x00000000",
                "Type": "h264",
            },
        }
        try:
            reply = self._call(FILE_SEARCH, payload)
        except RecorderError:
            # Documented as "unknown", never as "nothing recorded" — a box that
            # cannot be searched still plays back fine.
            return []
        rows = reply.get("OPFileQuery") or []
        if not isinstance(rows, list):
            return []
        segments = []
        for row in rows:
            if not isinstance(row, dict):
                continue
            begins = parse_device_datetime(str(row.get("BeginTime") or ""))
            ends = parse_device_datetime(str(row.get("EndTime") or ""))
            if begins is None or ends is None:
                continue
            segments.append(
                RecordingSegment(
                    start=self.from_device_local(begins),
                    end=self.from_device_local(ends),
                    handle=str(row.get("FileName") or ""),
                    size_bytes=_file_length(row.get("FileLength")),
                )
            )
        return segments


def _file_length(raw) -> int:
    """``FileLength`` arrives as ``"0x1a2b"`` on some firmwares and ``6699`` on
    others, and a size is cosmetic — so neither form may raise."""
    text = str(raw or "").strip()
    if not text:
        return 0
    try:
        return int(text, 16) if text.lower().startswith("0x") else int(text)
    except ValueError:
        return 0
