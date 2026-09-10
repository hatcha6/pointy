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
    RecorderCapabilityError,
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

#: ``OPFileQuery`` answers at most this many rows and then reports success, so a
#: single query silently truncates a busy day. The caller cannot tell a short
#: answer from a complete one, which for invoice-linked footage means "nothing
#: was recorded then" for a sale the box has perfectly good video of. Paginate by
#: advancing ``BeginTime`` and de-duplicating.
SEARCH_PAGE_SIZE = 64

#: A ceiling on that pagination. Firmware that ignores ``BeginTime`` would
#: otherwise return the same page forever; the de-duplication catches it too,
#: and between them a search cannot become an unbounded loop against a DVR.
MAX_SEARCH_PAGES = 16
TIME_QUERY = 1452
#: Playback and download share one command; the ``Action`` in the body decides.
PLAYBACK = 1420

#: Media-frame markers. On the wire each is a four-byte big-endian value whose
#: low byte follows an H.264 start code — ``00 00 01 FC`` and friends. That is
#: not a coincidence and it is load-bearing: a real H.264 NAL header has its top
#: bit clear (the forbidden_zero_bit), so a marker in 0xF9-0xFE can never be
#: mistaken for one, which is what makes this framing separable from the video
#: inside it.
FRAME_VIDEO_I = 0x1FC
FRAME_VIDEO_P = 0x1FD
FRAME_JPEG = 0x1FE
FRAME_AUDIO = 0x1FA
FRAME_INFO = 0x1F9
#: Header length in bytes, marker included, per marker.
FRAME_HEADER_BYTES = {
    FRAME_VIDEO_I: 16,
    FRAME_JPEG: 16,
    FRAME_VIDEO_P: 8,
    FRAME_AUDIO: 8,
    FRAME_INFO: 8,
}
#: The markers whose payload is the video we want. Audio and metadata frames are
#: parsed only so their bytes can be skipped without desynchronising the stream.
VIDEO_FRAMES = (FRAME_VIDEO_I, FRAME_VIDEO_P)

#: What the ``media`` byte in a video frame header means. Read for telemetry: a
#: recorder quietly sending H.265 to a pipeline expecting H.264 is the kind of
#: thing that shows up as "the picture looks wrong" and nothing else.
CODECS = {1: "mpeg4", 2: "h264", 3: "h265"}

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

    def send_only(self, message_id: int, payload: dict):
        """Send a command without consuming a reply.

        The download path needs this: once ``DownloadStart`` is acknowledged the
        socket carries video, and a JSON read there would eat the first frames.
        """
        self.connect()
        body = dict(payload)
        if self.session_id:
            body.setdefault("SessionID", self._session_hex)
        self._send(message_id, body)

    def read_payloads(self):
        """Yield raw payload bodies until the recorder signals the end.

        The terminator is a header declaring zero bytes, which is how this
        protocol says "that is the whole file". Yielding rather than
        accumulating is deliberate: a quarter-hour of H.264 is tens of
        megabytes and the reference implementation buffers all of it before
        writing, which on a two-core till would be felt.
        """
        while True:
            header = self._read_exactly(_HEADER_SIZE)
            length = _HEADER.unpack(header)[7]
            if length == 0:
                return
            if length > MAX_PAYLOAD:
                raise RecorderError(
                    "The recorder sent an implausibly large video packet."
                )
            yield self._read_exactly(length)

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


class MediaDeframer:
    """Xiongmai's framed media stream in, a plain H.264 elementary stream out.

    A download arrives as a run of media frames, each prefixed by a marker and a
    small header, with audio and metadata frames interleaved among the video.
    ffmpeg wants none of that — it wants the H.264 the headers wrap.

    Two properties make this safe to do on a byte stream rather than on whole
    packets. A frame's payload may be split across several DVRIP packets, so the
    parser carries ``remaining`` across feeds. And a marker cannot be confused
    with the video it contains: markers are 0xF9-0xFE, while an H.264 NAL header
    always has its top bit clear, so the two ranges do not overlap.

    **It also decides whether de-framing is wanted at all.** The reference
    implementation reads a download with a raw chunk loop and a live stream with
    a de-framer, which reads as though downloads arrive already unwrapped — but
    that is an inference from someone else's code, not something anyone has
    confirmed against this firmware. So the first bytes decide: a marker means
    framed, anything else is passed through untouched. Being wrong in either
    direction would hand ffmpeg noise, and there is no box here to ask.
    """

    #: Enough to see a marker. Nothing is emitted before this much has arrived.
    _SNIFF_BYTES = 4

    def __init__(self):
        self._buffer = bytearray()
        self._remaining = 0
        self._emit = False
        self._framed: bool | None = None
        #: Learned from the first I-frame header and never updated after: the
        #: codec and geometry the recorder is actually sending. Free — the
        #: header has to be parsed to skip it anyway — and otherwise invisible,
        #: since nothing else in the pipeline ever sees the source stream.
        self.stats: dict = {}

    @property
    def framed(self) -> bool | None:
        """``True``/``False`` once decided, ``None`` while still sniffing."""
        return self._framed

    def feed(self, chunk: bytes) -> bytes:
        self._buffer += chunk
        if self._framed is None:
            if len(self._buffer) < self._SNIFF_BYTES:
                return b""
            self._framed = self._looks_framed(self._buffer)
        if not self._framed:
            out = bytes(self._buffer)
            self._buffer.clear()
            return out
        return self._deframe()

    def flush(self) -> bytes:
        """Whatever is left once the download ends.

        Payload bytes are emitted as they arrive rather than held until a frame
        is complete — buffering per frame would defeat the point of streaming —
        so a recording that ends mid-frame passes its final partial NAL through.
        ffmpeg tolerates that: it decodes what it can and stops. What is *not*
        passed through is a partial header, which carries no video at all.
        """
        if not self._framed:
            out = bytes(self._buffer)
            self._buffer.clear()
            return out
        return self._deframe()

    @staticmethod
    def _looks_framed(prefix) -> bool:
        return (
            len(prefix) >= 4
            and bytes(prefix[:3]) == b"\x00\x00\x01"
            and prefix[3] in (0xF9, 0xFA, 0xFC, 0xFD, 0xFE)
        )

    def _deframe(self) -> bytes:
        out = bytearray()
        while True:
            if self._remaining:
                take = min(self._remaining, len(self._buffer))
                if not take:
                    break
                if self._emit:
                    out += self._buffer[:take]
                del self._buffer[:take]
                self._remaining -= take
                continue
            if not self._read_header():
                break
        return bytes(out)

    def _read_header(self) -> bool:
        """Start the next frame. ``False`` means wait for more bytes."""
        if len(self._buffer) < 4:
            return False
        (marker,) = struct.unpack(">I", bytes(self._buffer[:4]))
        header_bytes = FRAME_HEADER_BYTES.get(marker)
        if header_bytes is None:
            # Not a marker where one must be. Resynchronising by guessing would
            # invent video; stopping says plainly that the stream is not what we
            # were told it is.
            raise RecorderError(
                f"Unexpected data in the recording stream (0x{marker:08X})."
            )
        if len(self._buffer) < header_bytes:
            return False
        body = bytes(self._buffer[4:header_bytes])
        if marker in (FRAME_VIDEO_I, FRAME_JPEG):
            # media, fps, width/8, height/8, packed datetime, payload length
            media, fps, width, height, _dt, self._remaining = struct.unpack(
                "<BBBBII", body
            )
            if not self.stats:
                # Updated in place, never rebound: the driver hands this same
                # dict to the streaming layer before any frame has been read,
                # and rebinding would leave that holding an empty one forever.
                self.stats.update(
                    codec=CODECS.get(media, ""),
                    source_fps=float(fps),
                    # The header stores both in units of 8 pixels.
                    source_width=width * 8,
                    source_height=height * 8,
                )
        elif marker == FRAME_VIDEO_P:
            (self._remaining,) = struct.unpack("<I", body)
        else:
            self._remaining = struct.unpack("<BBH", body)[2]
        self._emit = marker in VIDEO_FRAMES
        del self._buffer[:header_bytes]
        return True


class XiongmaiDriver(RecorderDriver):
    brand = "xiongmai"
    label = "Xiongmai / XMEye"

    #: ``OPFileQuery`` is documented, implemented by the reference library and
    #: pinned by tests, so search is claimed with confidence. It is also the half
    #: that invoice-linked footage actually needs: knowing whether a sale's
    #: minute was recorded at all.
    supports_search = True
    #: Playback goes over the native protocol, not RTSP: ``OPPlayBack`` with
    #: ``PlayMode: "ByName"`` streams a recording the search already named. That
    #: is the documented path in the reference implementation, and it composes
    #: with :meth:`search_recordings`, which the field has confirmed works.
    supports_playback = True
    #: ...but not as a URL. This driver hands back *bytes*, so the frame path
    #: feeds ffmpeg through a pipe rather than pointing it at an address.
    playback_is_streamed = True
    #: No JPEG endpoint. Live tiles come from ffmpeg over RTSP, like Direct RTSP.
    supports_snapshot = False

    def __init__(self, target: RecorderTarget):
        super().__init__(target)
        self._port = int(target.extra.get("dvrip_port") or DVRIP_PORT)
        self._session = _Session(target, self._port)
        self._channel_names: dict[int, str] | None = None
        #: Whatever the last playback read off the wire, for telemetry.
        self.stream_stats: dict = {}

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
        raise RecorderCapabilityError(
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
        """Not how this recorder plays back. See :meth:`playback_stream`.

        Kept so the abstract contract is satisfied and so anything that reaches
        for a URL fails with a sentence rather than an AttributeError.
        """
        raise RecorderError(
            "This recorder streams recordings over its own protocol, not RTSP."
        )

    def playback_stream(
        self,
        channel: int,
        start: datetime,
        end: datetime,
        *,
        quality: str = StreamQuality.MAIN,
    ):
        """The window's footage, as a plain H.264 elementary stream.

        Recordings are fetched by *name*, which is why this rests on
        :meth:`search_recordings` rather than asking for a time range directly:
        the search is the documented, confirmed-in-the-field call, and the
        filenames it returns are exactly what ``PlayMode: "ByName"`` wants.
        Asking by time is the same command with a different parameter and would
        avoid pulling a whole quarter-hour file to show a minute of it — but
        nobody has been able to try it against real firmware, and a playback
        that silently returns nothing is worse than one that fetches too much.

        A window spanning several recordings yields them in order, so the
        consumer sees one continuous stream. Each file is claimed, streamed and
        then explicitly stopped, including when the consumer walks away
        mid-file: a download the recorder still believes is running is one of
        the handful of sessions it will hold, and leaking those is how a DVR
        stops answering anybody.
        """
        segments = self.search_recordings(channel, start, end)
        if not segments:
            raise RecorderError(
                "The recorder has no footage stored for that time."
            )
        for segment in segments:
            if not segment.handle:
                continue
            yield from self._download(segment.handle, start, end)

    def _download(self, filename: str, start: datetime, end: datetime):
        window = {
            "StartTime": self.to_device_local(start).strftime("%Y-%m-%d %H:%M:%S"),
            "EndTime": self.to_device_local(end).strftime("%Y-%m-%d %H:%M:%S"),
        }

        def body(action: str) -> dict:
            return {
                "Name": "OPPlayBack",
                "OPPlayBack": {
                    "Action": action,
                    "Parameter": {
                        "PlayMode": "ByName",
                        "FileName": filename,
                        "StreamType": 0,
                        "Value": 0,
                        # TCP for the same reason RTSP uses it: a smeared frame
                        # reads as a broken camera, and the box is on the LAN.
                        "TransMode": "TCP",
                    },
                    **window,
                },
            }

        self._session.login()
        self._session.call(PLAYBACK, body("Claim"))
        deframer = MediaDeframer()
        started = False
        self.stream_stats = deframer.stats
        try:
            # No reply is consumed here: from this point the socket carries
            # video, and a JSON read would swallow the first frames.
            self._session.send_only(PLAYBACK, body("DownloadStart"))
            for payload in self._session.read_payloads():
                # Some firmwares acknowledge the start in JSON before the video.
                if not started and payload[:1] == b"{":
                    continue
                started = True
                chunk = deframer.feed(payload)
                if chunk:
                    yield chunk
            tail = deframer.flush()
            if tail:
                yield tail
        finally:
            # Best effort, and deliberately not raising: this runs when the
            # viewer scrolls away mid-file, and the session is about to be
            # closed regardless.
            try:
                self._session.send_only(PLAYBACK, body("DownloadStop"))
            except RecorderError:
                pass

    # -- recordings --------------------------------------------------------
    def search_recordings(
        self, channel: int, start: datetime, end: datetime
    ) -> list[RecordingSegment]:
        """Which parts of the window the box actually recorded.

        This is what makes invoice-linked footage work on this hardware: without
        it the player cannot tell "nothing was recorded then" from "the recorder
        is not answering", and would offer to play a gap.
        """
        segments: list[RecordingSegment] = []
        seen: set[tuple] = set()
        cursor = start
        for _ in range(MAX_SEARCH_PAGES):
            rows = self._file_query_page(channel, cursor, end)
            if not rows:
                break
            added = 0
            for row in rows:
                if not isinstance(row, dict):
                    continue
                begins = parse_device_datetime(str(row.get("BeginTime") or ""))
                ends = parse_device_datetime(str(row.get("EndTime") or ""))
                if begins is None or ends is None:
                    continue
                handle = str(row.get("FileName") or "")
                key = (begins, ends, handle)
                if key in seen:
                    continue
                seen.add(key)
                added += 1
                segments.append(
                    RecordingSegment(
                        start=self.from_device_local(begins),
                        end=self.from_device_local(ends),
                        handle=handle,
                        size_bytes=_file_length(row.get("FileLength")),
                    )
                )
            if len(rows) < SEARCH_PAGE_SIZE:
                # A short page is the last page.
                break
            if not added:
                # A full page that told us nothing new: the box is ignoring
                # BeginTime. Stop rather than ask the same question forever.
                break
            # Advance past the newest segment this page returned. The rows are
            # device-local and `cursor` is UTC — the conversion back is not
            # optional, and mixing the two is how a paginating search silently
            # asks the same question forever.
            device_times = [
                parsed
                for row in rows
                if isinstance(row, dict)
                and (parsed := parse_device_datetime(str(row.get("EndTime") or "")))
                is not None
            ]
            if not device_times:
                break
            newest = self.from_device_local(max(device_times))
            if newest <= cursor:
                break
            cursor = newest
        segments.sort(key=lambda segment: segment.start)
        return segments

    def _file_query_page(self, channel: int, start: datetime, end: datetime) -> list:
        """One ``OPFileQuery``, which is at most :data:`SEARCH_PAGE_SIZE` rows."""
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
        return rows if isinstance(rows, list) else []


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
