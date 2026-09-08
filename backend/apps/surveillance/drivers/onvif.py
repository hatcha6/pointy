"""ONVIF, for the boxes that are neither Hikvision nor Dahua.

Most recorders sold in Libya are not either brand. They are Xiongmai, Uniview,
TVT and a long tail of OEM relabels, and the one thing they agree on is ONVIF —
so this driver is what turns "we support two brands" into "we support the ones
a shop actually bought".

**What it can and cannot do, and why that is not a shortcoming here.** ONVIF is
sold in profiles. *Profile S* is live video and is near-universal. *Profile G*
is recording search and playback, and the cheap boxes overwhelmingly do not
implement it. So this driver discovers which services the device actually
carries (:meth:`_load_capabilities`) and reports the truth through
``supports_playback`` / ``supports_search`` rather than offering a playback
button that returns an error. A shop that wants invoice-linked footage still
needs a Hikvision or a Dahua; a shop that wants to see its tills on screen no
longer needs to buy anything.

**Three places this deliberately distrusts the device.**

``GetCapabilities`` answers with absolute service URLs, and a box behind NAT, on
a second NIC, or freshly cloned answers with the address *it* believes it has —
regularly an address that is not the one we just reached it on. Only the path is
taken from those URLs; the host and port stay the ones that worked.

Credentials go in the SOAP header as a WS-Security digest, never as
``PasswordText``: the transport is plain HTTP on a shop LAN, and the digest is
the only part of ONVIF's auth that does not put the password on the wire. A
device that rejects digest is a device we decline to send a plaintext password
to.

A channel is a *video source*, not a profile. Devices publish one profile per
encoder, so a 16-channel NVR answers ``GetProfiles`` with 32 entries — main and
sub for each camera. Treating each as a channel would show every camera twice
and halve the tile wall's usefulness, so profiles are grouped by the video
source they share and the resolutions inside a group become main and sub.
"""

from __future__ import annotations

import base64
import hashlib
import os
from datetime import datetime, timezone as dt_timezone
from urllib.parse import quote, urlparse, urlunparse

from .base import (
    ChannelInfo,
    DeviceInfo,
    RecorderAuthError,
    RecorderDriver,
    RecorderError,
    RecorderUnreachable,
    StreamQuality,
    parse_xml,
)

#: Where the device service lives. The first is the ONVIF-recommended path and
#: what the overwhelming majority answer on; the rest are OEM firmwares that
#: chose otherwise. Tried in order, once, and the winner is remembered.
DEVICE_SERVICE_PATHS = (
    "/onvif/device_service",
    "/onvif/Device",
    "/onvif/services",
    "/onvif/device",
)

NS = {
    "s": "http://www.w3.org/2003/05/soap-envelope",
    "tds": "http://www.onvif.org/ver10/device/wsdl",
    "trt": "http://www.onvif.org/ver10/media/wsdl",
    "trp": "http://www.onvif.org/ver10/replay/wsdl",
    "tse": "http://www.onvif.org/ver10/search/wsdl",
    "tt": "http://www.onvif.org/ver10/schema",
}

WSSE = (
    "http://docs.oasis-open.org/wss/2004/01/"
    "oasis-200401-wss-wssecurity-secext-1.0.xsd"
)
WSU = (
    "http://docs.oasis-open.org/wss/2004/01/"
    "oasis-200401-wss-wssecurity-utility-1.0.xsd"
)
PASSWORD_DIGEST = (
    "http://docs.oasis-open.org/wss/2004/01/"
    "oasis-200401-wss-username-token-profile-1.0#PasswordDigest"
)
BASE64_BINARY = (
    "http://docs.oasis-open.org/wss/2004/01/"
    "oasis-200401-wss-soap-message-security-1.0#Base64Binary"
)

#: SOAP fault subcodes that mean "wrong password", not "broken device". ONVIF
#: returns these with HTTP 400, so without reading them every auth failure would
#: be reported to the installer as an unsupported recorder.
AUTH_FAULTS = ("notauthorized", "failedauthentication", "unauthorized", "accessdenied")


def _digest(username: str, password: str) -> str:
    """A WS-Security UsernameToken header, or nothing when there is no user.

    A handful of boxes ship with ONVIF authentication disabled entirely and
    fault on a token they did not ask for, so an anonymous call stays possible.
    """
    if not username:
        return ""
    nonce = os.urandom(16)
    created = datetime.now(dt_timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    token = hashlib.sha1(nonce + created.encode() + password.encode()).digest()
    return (
        f'<s:Header><Security s:mustUnderstand="1" xmlns="{WSSE}">'
        f"<UsernameToken><Username>{username}</Username>"
        f'<Password Type="{PASSWORD_DIGEST}">{base64.b64encode(token).decode()}</Password>'
        f'<Nonce EncodingType="{BASE64_BINARY}">{base64.b64encode(nonce).decode()}</Nonce>'
        f'<Created xmlns="{WSU}">{created}</Created>'
        "</UsernameToken></Security></s:Header>"
    )


def _envelope(body: str, header: str) -> str:
    namespaces = " ".join(f'xmlns:{k}="{v}"' for k, v in NS.items())
    return (
        '<?xml version="1.0" encoding="UTF-8"?>'
        f"<s:Envelope {namespaces}>{header}<s:Body>{body}</s:Body></s:Envelope>"
    )


def _service_path(xaddr: str, fallback: str) -> str:
    """The path out of a device-reported service URL. See the module docstring.

    The host is thrown away on purpose: a device that answers ``GetCapabilities``
    with ``http://192.168.1.10/onvif/media`` while we are talking to it on
    ``192.168.8.10`` is not lying, it is reciting a static configuration nobody
    updated — and following it would send every later call into a black hole.
    """
    if not xaddr:
        return fallback
    parsed = urlparse(xaddr.strip())
    path = parsed.path or fallback
    if parsed.query:
        path = f"{path}?{parsed.query}"
    return path


def _with_credentials(url: str, username: str, password: str) -> str:
    """Put the login into an RTSP URL the device handed back bare.

    ``GetStreamUri`` returns the stream's address without credentials; ffmpeg is
    given one argv element and no separate place to put them, so they belong in
    the URL. Percent-encoded for the same reason as ``base.rtsp_netloc``: DVR
    installers like passwords such as ``Admin@123``, and an unescaped ``@``
    silently redraws the URL's authority.
    """
    if not username:
        return url
    parsed = urlparse(url)
    host = parsed.hostname or ""
    if not host:
        return url
    netloc = f"{quote(username, safe='')}:{quote(password, safe='')}@{host}"
    if parsed.port:
        netloc = f"{netloc}:{parsed.port}"
    return urlunparse(parsed._replace(netloc=netloc))


class OnvifDriver(RecorderDriver):
    brand = "onvif"
    label = "ONVIF"

    # Filled in by the capability probe. Pessimistic until the device says
    # otherwise, so nothing offers playback on a box that cannot do it.
    supports_playback = False
    supports_search = False
    supports_snapshot = True

    def __init__(self, target):
        super().__init__(target)
        self._device_path = str(target.extra.get("onvif_service_path") or "") or None
        self._media_path = None
        self._replay_path = None
        self._search_path = None
        # channel -> {"main": token, "sub": token, "name": str}
        self._channels: dict[int, dict] = {}

    # -- SOAP --------------------------------------------------------------
    def _call(self, path: str, body: str, *, authenticated: bool = True):
        header = _digest(self.target.username, self.target.password) if authenticated else ""
        response = self.request(
            path,
            method="POST",
            data=_envelope(body, header).encode("utf-8"),
            headers={"Content-Type": "application/soap+xml; charset=utf-8"},
        )
        text = response.content[: 2 * 1024 * 1024].decode("utf-8", "replace")
        if "Fault" in text:
            self._raise_fault(text)
        if response.status_code >= 400:
            raise RecorderError(f"{path} failed with status {response.status_code}")
        return parse_xml(text)

    def _raise_fault(self, text: str):
        try:
            root = parse_xml(text)
        except RecorderError:
            return
        if root.find(".//Fault") is None:
            return
        reason = " ".join(node.text or "" for node in root.iter("Text")).strip()
        codes = " ".join(node.text or "" for node in root.iter("Value")).lower()
        if any(marker in codes for marker in AUTH_FAULTS) or "auth" in reason.lower():
            raise RecorderAuthError("The recorder rejected the username or password.")
        raise RecorderError(reason or "The recorder refused the request.")

    # -- discovery ---------------------------------------------------------
    def _find_device_service(self) -> str:
        """The path this box answers ONVIF on.

        ``GetSystemDateAndTime`` is the probe because ONVIF requires it to work
        *without* credentials — so a wrong password cannot be mistaken for a
        wrong path, which would send the installer looking in the wrong place.
        """
        if self._device_path:
            return self._device_path
        unreachable = None
        for path in DEVICE_SERVICE_PATHS:
            try:
                root = self._call(path, "<tds:GetSystemDateAndTime/>", authenticated=False)
            except RecorderUnreachable as exc:
                # The host itself is not answering; trying three more paths on a
                # dead box just multiplies the connect timeout the installer waits.
                unreachable = exc
                break
            except RecorderError:
                continue
            if root.find(".//GetSystemDateAndTimeResponse") is not None:
                self._device_path = path
                return path
        if unreachable is not None:
            raise unreachable
        raise RecorderError("Not an ONVIF device.")

    def _load_capabilities(self):
        if self._media_path is not None:
            return
        device = self._find_device_service()
        root = self._call(
            device, "<tds:GetCapabilities><tds:Category>All</tds:Category></tds:GetCapabilities>"
        )
        found = {}
        for name in ("Media", "Replay", "Search", "Recording"):
            node = root.find(f".//{name}")
            if node is not None:
                found[name] = (node.findtext("XAddr") or "").strip()
        # Newer firmware answers GetServices instead; ask only if the older call
        # came back empty, so one round trip stays the common case.
        if not found:
            found = self._services_fallback(device)
        self._media_path = _service_path(found.get("Media", ""), "/onvif/media_service")
        self._replay_path = _service_path(found.get("Replay", ""), "") or None
        self._search_path = _service_path(found.get("Search", ""), "") or None
        self.supports_playback = bool(self._replay_path)
        self.supports_search = bool(self._search_path)

    def _services_fallback(self, device: str) -> dict:
        try:
            root = self._call(
                device,
                "<tds:GetServices><tds:IncludeCapability>false"
                "</tds:IncludeCapability></tds:GetServices>",
            )
        except RecorderError:
            return {}
        found = {}
        for service in root.iter("Service"):
            namespace = (service.findtext("Namespace") or "").lower()
            xaddr = (service.findtext("XAddr") or "").strip()
            for name, marker in (
                ("Media", "/media/wsdl"),
                ("Replay", "/replay/wsdl"),
                ("Search", "/search/wsdl"),
                ("Recording", "/recording/wsdl"),
            ):
                if marker in namespace:
                    found[name] = xaddr
        return found

    # -- identity ----------------------------------------------------------
    def probe(self) -> DeviceInfo:
        device = self._find_device_service()
        root = self._call(device, "<tds:GetDeviceInformation/>")
        self._load_capabilities()
        channels = self.list_channels()
        return DeviceInfo(
            brand=self.brand,
            model=" ".join(
                part
                for part in (
                    (root.findtext(".//Manufacturer") or "").strip(),
                    (root.findtext(".//Model") or "").strip(),
                )
                if part
            ),
            serial=(root.findtext(".//SerialNumber") or "").strip(),
            firmware=(root.findtext(".//FirmwareVersion") or "").strip(),
            channel_count=len(channels),
            clock_offset_minutes=self.read_clock_offset_minutes(),
        )

    def read_device_local_time(self):
        try:
            root = self._call(
                self._find_device_service(),
                "<tds:GetSystemDateAndTime/>",
                authenticated=False,
            )
        except RecorderError:
            return None
        local = root.find(".//LocalDateTime")
        if local is None:
            return None
        date, time = local.find("Date"), local.find("Time")
        if date is None or time is None:
            return None
        try:
            return datetime(
                int(date.findtext("Year") or 0),
                int(date.findtext("Month") or 0),
                int(date.findtext("Day") or 0),
                int(time.findtext("Hour") or 0),
                int(time.findtext("Minute") or 0),
                int(time.findtext("Second") or 0),
            )
        except ValueError:
            return None

    # -- channels ----------------------------------------------------------
    def _load_profiles(self):
        """Group the device's profiles into channels. See the module docstring."""
        if self._channels:
            return
        self._load_capabilities()
        root = self._call(self._media_path, "<trt:GetProfiles/>")

        sources: dict[str, list[tuple[int, str, str]]] = {}
        order: list[str] = []
        for profile in root.iter("Profiles"):
            token = (profile.get("token") or "").strip()
            if not token:
                continue
            source = profile.find(".//VideoSourceConfiguration")
            source_token = ""
            if source is not None:
                source_token = (source.findtext("SourceToken") or source.get("token") or "").strip()
            # A device that names no source still has one camera behind the
            # profile; keying on the profile keeps it visible rather than
            # collapsing every channel into one.
            source_token = source_token or token
            resolution = profile.find(".//VideoEncoderConfiguration/Resolution")
            pixels = 0
            if resolution is not None:
                try:
                    pixels = int(resolution.findtext("Width") or 0) * int(
                        resolution.findtext("Height") or 0
                    )
                except ValueError:
                    pixels = 0
            if source_token not in sources:
                sources[source_token] = []
                order.append(source_token)
            sources[source_token].append((pixels, token, (profile.findtext("Name") or "").strip()))

        for index, source_token in enumerate(order, start=1):
            entries = sorted(sources[source_token], key=lambda item: item[0], reverse=True)
            self._channels[index] = {
                "main": entries[0][1],
                "sub": entries[-1][1],
                "name": entries[0][2],
            }

    def list_channels(self) -> list[ChannelInfo]:
        self._load_profiles()
        if not self._channels:
            raise RecorderError("The recorder reported no video channels.")
        return [
            ChannelInfo(channel=channel, name=entry["name"])
            for channel, entry in sorted(self._channels.items())
        ]

    def _profile_token(self, channel: int, quality: str) -> str:
        self._load_profiles()
        entry = self._channels.get(int(channel))
        if entry is None:
            raise RecorderError(f"The recorder has no channel {channel}.")
        return entry[StreamQuality.normalize(quality)]

    # -- video -------------------------------------------------------------
    def snapshot(self, channel: int, *, quality: str = StreamQuality.SUB) -> bytes:
        token = self._profile_token(channel, quality)
        root = self._call(
            self._media_path,
            f"<trt:GetSnapshotUri><trt:ProfileToken>{token}</trt:ProfileToken>"
            "</trt:GetSnapshotUri>",
        )
        uri = (root.findtext(".//Uri") or "").strip()
        if not uri:
            raise RecorderError("The recorder did not offer a snapshot address.")
        # Snapshot URIs are absolute and carry the same wrong-host risk as the
        # service addresses, so only the path is kept and it is fetched through
        # the driver's own authenticated session.
        parsed = urlparse(uri)
        path = parsed.path + (f"?{parsed.query}" if parsed.query else "")
        return self.get_bytes(path)

    def live_rtsp_url(self, channel: int, *, quality: str = StreamQuality.SUB) -> str:
        token = self._profile_token(channel, quality)
        root = self._call(
            self._media_path,
            "<trt:GetStreamUri><trt:StreamSetup>"
            f'<Stream xmlns="{NS["tt"]}">RTP-Unicast</Stream>'
            f'<Transport xmlns="{NS["tt"]}"><Protocol>RTSP</Protocol></Transport>'
            f"</trt:StreamSetup><trt:ProfileToken>{token}</trt:ProfileToken>"
            "</trt:GetStreamUri>",
        )
        uri = (root.findtext(".//Uri") or "").strip()
        if not uri:
            raise RecorderError("The recorder did not offer a stream address.")
        return _with_credentials(uri, self.target.username, self.target.password)

    def playback_rtsp_url(
        self,
        channel: int,
        start: datetime,
        end: datetime,
        *,
        quality: str = StreamQuality.MAIN,
    ) -> str:
        self._load_capabilities()
        raise RecorderError(
            "This recorder speaks ONVIF for live video only (no Profile G), so "
            "recorded footage cannot be played back through Pointy."
        )
