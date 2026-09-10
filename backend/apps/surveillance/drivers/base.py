"""What a DVR looks like from the outside.

Both brands we support speak HTTP digest auth on port 80 for control and RTSP on
554 for video, so a driver is a small pile of URL shapes and two XML/INI dialects
rather than a protocol implementation. Everything above this layer — the frame
broker, the views, the client — is brand-agnostic and must stay that way: a
third brand should be one new module here and nothing else.

Three failure modes are named separately because the UI says different things
about each: unreachable (wrong IP, box off, VLAN), auth (wrong password, or the
account lacks the remote-access right), and everything else.
"""

from __future__ import annotations

import re
from abc import ABC, abstractmethod
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone as dt_timezone
from urllib.parse import quote
from xml.etree import ElementTree

import requests
from requests.auth import HTTPBasicAuth, HTTPDigestAuth

# Control calls are chatty and local; a DVR that has not answered in this long
# is not going to. Snapshots get their own, longer budget because the box has to
# encode a JPEG off a live encoder pipeline and a busy 16-channel DVR is slow.
CONNECT_TIMEOUT = 4.0
READ_TIMEOUT = 8.0
SNAPSHOT_READ_TIMEOUT = 12.0

# A control response is a few KB of XML. Anything wildly larger is a device
# misbehaving (or a captive portal), and parsing it is how a LAN box turns into
# our memory problem — so responses are read with a hard cap rather than
# streamed into ElementTree unbounded.
MAX_CONTROL_BYTES = 2 * 1024 * 1024

JPEG_CONTENT_TYPES = ("image/jpeg", "image/jpg")


class StreamQuality:
    """Which encoder track to pull. Sub is the default everywhere.

    The main stream is 2–8 Mbit of 4MP video; the sub-stream is typically
    640×480 or 704×576. For a wall of tiles on a shop PC the sub-stream is not a
    compromise, it is the correct choice — and it is what keeps a 16-channel DVR
    from refusing the ninth simultaneous pull.
    """

    MAIN = "main"
    SUB = "sub"

    CHOICES = (MAIN, SUB)

    @classmethod
    def normalize(cls, value):
        value = str(value or "").strip().lower()
        return value if value in cls.CHOICES else cls.SUB


class RecorderError(Exception):
    """The recorder could not do what was asked."""

    code = "error"


class RecorderUnreachable(RecorderError):
    code = "unreachable"


class RecorderAuthError(RecorderError):
    code = "auth"


class RecorderCapabilityError(RecorderError):
    """This firmware family cannot do this at all.

    Structural, not transient — retrying, backing off or tripping a circuit
    breaker are all wasted on it, and a caller that treats it as a failure to
    recover from will loop forever. The right answer is to stop asking: route
    around the missing capability where an alternative exists, and say plainly
    that it does not where none does.
    """

    code = "unsupported"


@dataclass(frozen=True)
class DeviceInfo:
    brand: str = ""
    model: str = ""
    serial: str = ""
    firmware: str = ""
    channel_count: int = 0
    # Minutes the device's own clock is ahead of UTC, as *observed* — not as
    # configured. See ``RecorderDriver.read_clock_offset_minutes``.
    clock_offset_minutes: int | None = None


@dataclass(frozen=True)
class ChannelInfo:
    channel: int
    name: str = ""
    online: bool = True


@dataclass(frozen=True)
class RecordingSegment:
    """A stretch of stored footage. ``start``/``end`` are always UTC-aware.

    Drivers normalise at their own boundary — the recorder reports these in its
    own terms (Dahua local, Hikvision UTC) and letting either leak upwards is
    how a playback window ends up an hour out.
    """

    start: datetime
    end: datetime
    # Opaque, brand-specific handle for the stored file. Only the driver that
    # produced it may interpret it.
    handle: str = ""
    size_bytes: int = 0


@dataclass
class RecorderTarget:
    """The connection details a driver needs, decoupled from the ORM.

    Kept as a plain dataclass so drivers can be exercised in tests, and by the
    "test connection" endpoint, against credentials that have not been saved.
    """

    host: str
    port: int = 80
    rtsp_port: int = 554
    username: str = ""
    password: str = ""
    use_https: bool = False
    clock_offset_minutes: int = 0
    extra: dict = field(default_factory=dict)


def strip_namespace(tag: str) -> str:
    return tag.rsplit("}", 1)[-1]


def parse_xml(text: str) -> ElementTree.Element:
    """Parse a control response, with namespaces flattened.

    Hikvision stamps every element with one of several schema namespaces that
    vary by firmware generation, so every lookup would otherwise need to try
    each. Flattening once here is what lets the driver read plain tag names.
    """
    try:
        root = ElementTree.fromstring(text)
    except ElementTree.ParseError as exc:  # pragma: no cover - malformed device
        raise RecorderError(f"Unreadable device response: {exc}") from exc
    for element in root.iter():
        element.tag = strip_namespace(element.tag)
    return root


def find_text(root, path, default=""):
    node = root.find(path)
    if node is None or node.text is None:
        return default
    return node.text.strip()


def rtsp_netloc(target: RecorderTarget) -> str:
    """host:port with credentials, percent-encoded.

    ffmpeg is handed this URL as a single argv element, so a password containing
    ``@``, ``/`` or ``:`` — common, because DVR installers like ``Admin@123`` —
    would otherwise silently redraw the URL's authority and the connection would
    fail with a misleading "no route to host".
    """
    user = quote(target.username or "", safe="")
    password = quote(target.password or "", safe="")
    credentials = f"{user}:{password}@" if user else ""
    return f"{credentials}{target.host}:{target.rtsp_port}"


class RecorderDriver(ABC):
    """One brand's dialect. Instances are cheap but hold a pooled session.

    Keep an instance alive across a snapshot loop: ``requests``' digest auth
    caches the server challenge on the auth object, so a reused driver sends a
    pre-emptive ``Authorization`` header and costs one round trip per frame
    instead of two.
    """

    brand = ""
    label = ""

    # What this brand can actually do. Both shipped brands do everything, so
    # these default to true and only the newer drivers narrow them — a driver
    # that cannot play back says so here instead of raising from a button the
    # client should never have drawn. ONVIF sets ``supports_playback`` per
    # device, because Profile G is discovered rather than known in advance.
    supports_playback = True
    supports_search = True
    supports_snapshot = True

    #: How recorded video is obtained. False (the default) means the driver
    #: hands back an RTSP URL and ffmpeg opens it; True means the driver
    #: produces the bytes itself over its own protocol and ffmpeg is fed through
    #: a pipe. Xiongmai is the second kind — its recordings are not reachable
    #: over RTSP at all.
    playback_is_streamed = False

    def __init__(self, target: RecorderTarget):
        self.target = target
        self._session = requests.Session()
        # Digest is what both brands ship with; a few Dahua firmwares and most
        # ONVIF-ish clones still accept basic. ``requests`` sends digest only
        # after a 401, so starting with digest costs nothing when basic would
        # have worked, and starting with basic would leak the password to a box
        # that wanted digest.
        self._session.auth = HTTPDigestAuth(target.username, target.password)
        self._basic_auth = HTTPBasicAuth(target.username, target.password)
        self._basic_fallback_active = False

    # -- lifecycle ---------------------------------------------------------
    def close(self):
        try:
            self._session.close()
        except Exception:  # pragma: no cover - defensive
            pass

    def __enter__(self):
        return self

    def __exit__(self, *exc_info):
        self.close()
        return False

    # -- HTTP --------------------------------------------------------------
    @property
    def scheme(self) -> str:
        return "https" if self.target.use_https else "http"

    def url(self, path: str) -> str:
        if not path.startswith("/"):
            path = "/" + path
        return f"{self.scheme}://{self.target.host}:{self.target.port}{path}"

    def request(self, path, *, method="GET", read_timeout=READ_TIMEOUT, **kwargs):
        """One HTTP call to the device, with both brands' failure modes mapped.

        Retries once with basic auth on a 401: a handful of firmwares advertise
        digest and then reject it, and the alternative is a shop that cannot use
        the feature at all for a reason no error message would explain.
        """
        url = self.url(path)
        kwargs.setdefault("timeout", (CONNECT_TIMEOUT, read_timeout))
        kwargs.setdefault("verify", False)
        kwargs.setdefault("stream", False)
        try:
            response = self._session.request(method, url, **kwargs)
        except requests.exceptions.SSLError as exc:
            raise RecorderUnreachable(f"TLS handshake failed: {exc}") from exc
        except requests.exceptions.Timeout as exc:
            raise RecorderUnreachable("The recorder did not answer in time.") from exc
        except requests.exceptions.RequestException as exc:
            raise RecorderUnreachable(f"Could not reach the recorder: {exc}") from exc

        if response.status_code == 401 and not self._basic_fallback_active:
            self._basic_fallback_active = True
            self._session.auth = self._basic_auth
            kwargs.pop("timeout", None)
            return self.request(path, method=method, read_timeout=read_timeout, **kwargs)
        if response.status_code in (401, 403):
            raise RecorderAuthError(
                "The recorder rejected the username or password."
            )
        return response

    def get_text(self, path, **kwargs) -> str:
        response = self.request(path, **kwargs)
        if response.status_code >= 400:
            raise RecorderError(
                f"{path} failed with status {response.status_code}"
            )
        return response.content[:MAX_CONTROL_BYTES].decode("utf-8", "replace")

    def get_bytes(self, path, *, read_timeout=SNAPSHOT_READ_TIMEOUT, **kwargs) -> bytes:
        response = self.request(path, read_timeout=read_timeout, **kwargs)
        if response.status_code >= 400:
            raise RecorderError(
                f"{path} failed with status {response.status_code}"
            )
        return response.content

    # -- capability surface ------------------------------------------------
    @abstractmethod
    def probe(self) -> DeviceInfo:
        """Identify the box. Raises rather than guessing when it is not ours."""

    @abstractmethod
    def list_channels(self) -> list[ChannelInfo]:
        """Every video channel, with the name the device itself carries."""

    @abstractmethod
    def snapshot(self, channel: int, *, quality: str = StreamQuality.SUB) -> bytes:
        """One JPEG, now."""

    @abstractmethod
    def live_rtsp_url(self, channel: int, *, quality: str = StreamQuality.SUB) -> str:
        ...

    @abstractmethod
    def playback_rtsp_url(
        self,
        channel: int,
        start: datetime,
        end: datetime,
        *,
        quality: str = StreamQuality.MAIN,
    ) -> str:
        ...

    def playback_stream(
        self,
        channel: int,
        start: datetime,
        end: datetime,
        *,
        quality: str = StreamQuality.MAIN,
    ):
        """Recorded video as raw H.264 bytes, for ``playback_is_streamed`` drivers.

        Only meaningful when that flag is set; the URL-based drivers never
        implement it and callers check the flag rather than probing for the
        method.
        """
        raise RecorderError("This recorder does not stream recordings directly.")

    def search_recordings(
        self, channel: int, start: datetime, end: datetime
    ) -> list[RecordingSegment]:
        """Which parts of the window actually have footage.

        Optional: a driver that cannot answer returns ``[]``, and the caller
        treats that as "unknown", never as "nothing recorded" — a DVR that
        cannot be searched still plays back fine.
        """
        return []

    # -- clock -------------------------------------------------------------
    def read_clock_offset_minutes(self) -> int | None:
        """How far the device's own clock is from UTC, measured not configured.

        Playback URLs are addressed in the device's terms — Dahua in device-local
        time, Hikvision in UTC — and the device's timezone is whatever the
        installer left it on, frequently nothing. Asking the box what time *it*
        thinks it is and diffing against ours is the only reading that survives
        a wrong timezone, a drifted RTC, and a DST rule the firmware predates.

        Returns ``None`` when the device will not say; callers then assume the
        server's own offset, which is right whenever both sit in the same shop.
        """
        local = self.read_device_local_time()
        if local is None:
            return None
        now = datetime.now(dt_timezone.utc).replace(tzinfo=None)
        delta_minutes = (local - now).total_seconds() / 60.0
        # Snap to the quarter hour. Every real timezone is a multiple of 15
        # minutes, so this absorbs the RTC drift and the round trip without
        # ever inventing an offset no timezone has.
        return int(round(delta_minutes / 15.0)) * 15

    def read_device_local_time(self) -> datetime | None:
        """The device's wall clock, naive, in its own timezone."""
        return None

    # -- helpers -----------------------------------------------------------
    def to_device_local(self, moment: datetime) -> datetime:
        """A UTC instant, expressed in the recorder's own wall clock."""
        if moment.tzinfo is not None:
            moment = moment.astimezone(dt_timezone.utc).replace(tzinfo=None)
        return moment + timedelta(minutes=self.target.clock_offset_minutes or 0)

    def to_device_utc(self, moment: datetime) -> datetime:
        if moment.tzinfo is not None:
            moment = moment.astimezone(dt_timezone.utc).replace(tzinfo=None)
        return moment

    def from_device_local(self, moment: datetime) -> datetime:
        """The inverse of :meth:`to_device_local`: device wall clock -> UTC."""
        return (moment - timedelta(minutes=self.target.clock_offset_minutes or 0)).replace(
            tzinfo=dt_timezone.utc
        )

    def from_device_utc(self, moment: datetime) -> datetime:
        return moment.replace(tzinfo=dt_timezone.utc)


# Every separator these two vendors use, in one pattern: Dahua writes
# ``2026_09_07_14_03_11`` (underscore even between the date and the time),
# Hikvision writes ``2026-09-07T14:03:11``, and both appear with a space.
_DATETIME_PATTERN = re.compile(
    r"(\d{4})[-_/](\d{1,2})[-_/](\d{1,2})[T _](\d{1,2})[:_](\d{1,2})[:_](\d{1,2})"
)


def parse_device_datetime(raw: str) -> datetime | None:
    """Read a timestamp out of whatever punctuation the firmware chose.

    ``2026-09-07 14:03:11``, ``2026_09_07_14_03_11`` and ``2026-09-07T14:03:11``
    are all in the field, sometimes from the same vendor on different endpoints.
    """
    if not raw:
        return None
    match = _DATETIME_PATTERN.search(str(raw))
    if not match:
        return None
    try:
        return datetime(*(int(part) for part in match.groups()))
    except ValueError:
        return None
