"""The last resort: a box with no control API we can speak, but a working RTSP.

Some recorders answer nothing we understand — not Hikvision's ISAPI, not
Dahua's CGI, not even ONVIF, because the installer never switched it on and
nobody can reach the menu. What they almost always still have is port 554 with
a stream on it, because that is what their own phone app uses.

So this driver asks the shop for the one thing the device will not tell us — the
URL shape — and builds everything else from it. There is no probe beyond "is
554 open", no channel list beyond the count someone typed, and no playback at
all. That is the honest trade: live tiles on the till, and nothing more.

The template is per-recorder and carries ``{channel}``; a 16-channel DVR is one
row here, not sixteen. Placeholders:

``{channel}``   1-based channel number
``{channel0}``  0-based, for firmwares that count from zero
``{stream}``    ``0`` for the main stream, ``1`` for the sub-stream
``{username}`` / ``{password}``  for the firmwares that want them in the path
                rather than the authority — Xiongmai's does

Credentials go in the URL authority as well, percent-encoded, for the same
reason as everywhere else here: ffmpeg takes one argv element and a raw ``@`` in
a password would silently redraw the authority.
"""

from __future__ import annotations

import socket
from datetime import datetime

from .base import (
    CONNECT_TIMEOUT,
    ChannelInfo,
    DeviceInfo,
    RecorderDriver,
    RecorderError,
    RecorderUnreachable,
    StreamQuality,
    rtsp_netloc,
)

#: Ready-made shapes for the boxes seen in the field, so an installer picks a
#: name instead of inventing a URL. Kept here rather than in the client because
#: it is knowledge about devices, and the client should not be the place device
#: knowledge lives.
TEMPLATE_PRESETS = {
    # Xiongmai / XMEye and the many OEM relabels of it. Sufian's shop, 2026-09.
    "xmeye": "/user={username}&password={password}&channel={channel}&stream={stream}.sdp?",
    # Uniview, TVT and several ONVIF-era firmwares.
    "uniview": "/unicast/c{channel}/s{stream}/live",
    # A common OEM shape; also what several Hisilicon reference designs ship.
    "chNN": "/ch{channel}/{stream}",
    # Standards-ish: what many cameras expose when ONVIF is off.
    "live": "/live/ch{channel0}_{stream}",
}

#: The main stream is stream 0 on every firmware in the table above; the sub is
#: 1. Kept as a mapping so a preset that inverts them stays expressible.
STREAM_BY_QUALITY = {StreamQuality.MAIN: 0, StreamQuality.SUB: 1}


class GenericRtspDriver(RecorderDriver):
    brand = "generic_rtsp"
    label = "Direct RTSP"

    # Nothing but live video. Declared rather than discovered because there is
    # no device API to ask, and the UI must not offer a playback button that
    # can only ever fail.
    supports_playback = False
    supports_search = False
    #: No HTTP snapshot endpoint exists, so the snapshot-polling fallback the
    #: server uses when ffmpeg is missing cannot work here: this recorder needs
    #: ffmpeg, and the status endpoint says so before anyone configures it.
    supports_snapshot = False

    @property
    def _template(self) -> str:
        return str(self.target.extra.get("rtsp_path_template") or "").strip()

    @property
    def _channel_count(self) -> int:
        try:
            return max(int(self.target.extra.get("channel_count") or 0), 0)
        except (TypeError, ValueError):
            return 0

    # -- identity ----------------------------------------------------------
    def probe(self) -> DeviceInfo:
        """There is nothing to identify, so prove the one thing that matters.

        Opening the RTSP port is the whole test: it separates "wrong IP or the
        box is off" from "the box is there and the URL is the part to argue
        about", which is the only distinction an installer can act on.
        """
        if not self._template:
            raise RecorderError(
                "This recorder needs an RTSP address template before it can be used."
            )
        try:
            with socket.create_connection(
                (self.target.host, self.target.rtsp_port), timeout=CONNECT_TIMEOUT
            ):
                pass
        except OSError as exc:
            raise RecorderUnreachable(
                f"Nothing is listening for video on {self.target.host}:"
                f"{self.target.rtsp_port} ({exc.__class__.__name__})."
            ) from exc
        return DeviceInfo(
            brand=self.brand,
            model="Direct RTSP",
            channel_count=self._channel_count,
        )

    def list_channels(self) -> list[ChannelInfo]:
        count = self._channel_count
        if not count:
            raise RecorderError(
                "Set how many cameras this recorder has — it cannot be asked."
            )
        return [ChannelInfo(channel=channel) for channel in range(1, count + 1)]

    # -- video -------------------------------------------------------------
    def snapshot(self, channel: int, *, quality: str = StreamQuality.SUB) -> bytes:
        raise RecorderError(
            "This recorder has no snapshot address; its live view needs ffmpeg "
            "on the server."
        )

    def live_rtsp_url(self, channel: int, *, quality: str = StreamQuality.SUB) -> str:
        channel = int(channel)
        stream = STREAM_BY_QUALITY.get(StreamQuality.normalize(quality), 1)
        path = self._template
        try:
            path = path.format(
                channel=channel,
                channel0=channel - 1,
                stream=stream,
                username=self.target.username,
                password=self.target.password,
            )
        except (KeyError, IndexError, ValueError) as exc:
            # A template with a typo'd placeholder must not reach ffmpeg as a
            # half-substituted URL and fail there, where the message would be
            # about a stream rather than about the field someone just typed.
            raise RecorderError(
                f"The RTSP address template is not valid: {exc}"
            ) from exc
        if not path.startswith("/"):
            path = "/" + path
        return f"rtsp://{rtsp_netloc(self.target)}{path}"

    def playback_rtsp_url(
        self,
        channel: int,
        start: datetime,
        end: datetime,
        *,
        quality: str = StreamQuality.MAIN,
    ) -> str:
        raise RecorderError(
            "This recorder is configured for live video only; recorded footage "
            "cannot be played back through Pointy."
        )
