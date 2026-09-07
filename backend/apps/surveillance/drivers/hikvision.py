"""Hikvision, and the very large family of boxes that clone its ISAPI.

Channel addressing is the thing to hold on to: ISAPI does not name a channel, it
names a *stream* — ``channel * 100 + track``, where track 1 is the main stream
and 2 the sub. So camera 3's sub-stream is 302. Every path below that takes a
number takes that composite, which is why nothing here passes a bare channel.
"""

from __future__ import annotations

import uuid
from datetime import datetime

from .base import (
    ChannelInfo,
    DeviceInfo,
    RecorderDriver,
    RecorderError,
    RecordingSegment,
    StreamQuality,
    find_text,
    parse_device_datetime,
    parse_xml,
    rtsp_netloc,
)

TRACK_BY_QUALITY = {StreamQuality.MAIN: 1, StreamQuality.SUB: 2}


def stream_id(channel: int, quality: str) -> int:
    track = TRACK_BY_QUALITY.get(StreamQuality.normalize(quality), 2)
    return int(channel) * 100 + track


def _isapi_time(moment: datetime) -> str:
    """ISAPI's ISO-ish UTC stamp, e.g. ``20260907T140311Z``."""
    return moment.strftime("%Y%m%dT%H%M%SZ")


def _search_time(moment: datetime) -> str:
    """The other one. ``ContentMgmt/search`` wants separators; playback does not."""
    return moment.strftime("%Y-%m-%dT%H:%M:%SZ")


class HikvisionDriver(RecorderDriver):
    brand = "hikvision"
    label = "Hikvision"

    # -- identity ----------------------------------------------------------
    def probe(self) -> DeviceInfo:
        root = parse_xml(self.get_text("/ISAPI/System/deviceInfo"))
        if root.tag not in ("DeviceInfo", "ResponseStatus"):
            raise RecorderError("Not an ISAPI device.")
        if root.tag == "ResponseStatus":
            raise RecorderError(
                find_text(root, "statusString", "The recorder refused the request.")
            )
        channel_count = 0
        for tag in ("videoInputPortNums", "channelNums", "analogChannelNums"):
            raw = find_text(root, tag)
            if raw.isdigit():
                channel_count = max(channel_count, int(raw))
        return DeviceInfo(
            brand=self.brand,
            model=find_text(root, "model") or find_text(root, "deviceType"),
            serial=find_text(root, "serialNumber"),
            firmware=find_text(root, "firmwareVersion"),
            channel_count=channel_count,
            clock_offset_minutes=self.read_clock_offset_minutes(),
        )

    def read_device_local_time(self):
        try:
            root = parse_xml(self.get_text("/ISAPI/System/time"))
        except RecorderError:
            return None
        raw = find_text(root, "localTime")
        parsed = parse_device_datetime(raw)
        if parsed is None:
            return None
        # ``localTime`` usually carries the offset (``...T14:03:11+02:00``). When
        # it does the device has already told us its wall clock, and the suffix
        # is exactly what we are trying to measure — so it is deliberately
        # ignored rather than applied twice.
        return parsed

    # -- channels ----------------------------------------------------------
    def list_channels(self) -> list[ChannelInfo]:
        """Every channel, from whichever of three endpoints this firmware has.

        ``Streaming/channels`` is first because it is the only one present on
        both DVRs (analog inputs) and NVRs (IP channels); the other two exist on
        one or the other. A box that answers none of them still yields channels
        from the port count in ``deviceInfo`` — an unnamed channel that streams
        beats an empty list.
        """
        for reader in (
            self._channels_from_streaming,
            self._channels_from_video_inputs,
            self._channels_from_input_proxy,
        ):
            try:
                channels = reader()
            except RecorderError:
                continue
            if channels:
                return channels
        info = self.probe()
        return [
            ChannelInfo(channel=index, name="")
            for index in range(1, max(info.channel_count, 0) + 1)
        ]

    def _channels_from_streaming(self) -> list[ChannelInfo]:
        root = parse_xml(self.get_text("/ISAPI/Streaming/channels"))
        found: dict[int, ChannelInfo] = {}
        for node in root.iter("StreamingChannel"):
            raw_id = find_text(node, "id")
            if not raw_id.isdigit():
                continue
            composite = int(raw_id)
            channel, track = divmod(composite, 100)
            # Only the main track names the camera; the sub-stream entry repeats
            # it and would otherwise overwrite the name with a blank.
            if channel < 1 or track != 1:
                continue
            found[channel] = ChannelInfo(
                channel=channel,
                name=find_text(node, "channelName"),
                online=find_text(node, "enabled", "true").lower() != "false",
            )
        return [found[key] for key in sorted(found)]

    def _channels_from_video_inputs(self) -> list[ChannelInfo]:
        root = parse_xml(self.get_text("/ISAPI/System/Video/inputs/channels"))
        channels = []
        for node in root.iter("VideoInputChannel"):
            raw_id = find_text(node, "id")
            if not raw_id.isdigit():
                continue
            channels.append(
                ChannelInfo(
                    channel=int(raw_id),
                    name=find_text(node, "name"),
                    online=find_text(node, "videoInputEnabled", "true").lower()
                    != "false",
                )
            )
        return channels

    def _channels_from_input_proxy(self) -> list[ChannelInfo]:
        root = parse_xml(self.get_text("/ISAPI/ContentMgmt/InputProxy/channels"))
        channels = []
        for node in root.iter("InputProxyChannel"):
            raw_id = find_text(node, "id")
            if not raw_id.isdigit():
                continue
            channels.append(
                ChannelInfo(
                    channel=int(raw_id),
                    name=find_text(node, "name"),
                    online=find_text(node, "online", "true").lower() != "false",
                )
            )
        return channels

    # -- video -------------------------------------------------------------
    def snapshot(self, channel: int, *, quality: str = StreamQuality.SUB) -> bytes:
        return self.get_bytes(
            f"/ISAPI/Streaming/channels/{stream_id(channel, quality)}/picture"
        )

    def live_rtsp_url(self, channel: int, *, quality: str = StreamQuality.SUB) -> str:
        return (
            f"rtsp://{rtsp_netloc(self.target)}"
            f"/Streaming/Channels/{stream_id(channel, quality)}"
        )

    def playback_rtsp_url(
        self,
        channel: int,
        start: datetime,
        end: datetime,
        *,
        quality: str = StreamQuality.MAIN,
    ) -> str:
        # Playback lives on ``tracks``, not ``Channels``, and the times are UTC
        # with a literal Z — which is why the observed clock offset is applied to
        # the *device* rather than to these stamps.
        start_utc = self.to_device_utc(start)
        end_utc = self.to_device_utc(end)
        return (
            f"rtsp://{rtsp_netloc(self.target)}"
            f"/Streaming/tracks/{stream_id(channel, quality)}"
            f"?starttime={_isapi_time(start_utc)}&endtime={_isapi_time(end_utc)}"
        )

    def search_recordings(
        self, channel: int, start: datetime, end: datetime
    ) -> list[RecordingSegment]:
        track = stream_id(channel, StreamQuality.MAIN)
        body = (
            "<CMSearchDescription>"
            f"<searchID>{uuid.uuid4()}</searchID>"
            f"<trackIDList><trackID>{track}</trackID></trackIDList>"
            "<timeSpanList><timeSpan>"
            f"<startTime>{_search_time(self.to_device_utc(start))}</startTime>"
            f"<endTime>{_search_time(self.to_device_utc(end))}</endTime>"
            "</timeSpan></timeSpanList>"
            "<maxResults>60</maxResults>"
            # Not a typo on our side: ISAPI ships this field misspelled and a
            # correctly spelled one is ignored.
            "<searchResultPostion>0</searchResultPostion>"
            "<metadataList><metadataDescriptor>"
            "//recordType.meta.std-cgi.com"
            "</metadataDescriptor></metadataList>"
            "</CMSearchDescription>"
        )
        try:
            text = self.get_text(
                "/ISAPI/ContentMgmt/search",
                method="POST",
                data=body.encode("utf-8"),
                headers={"Content-Type": "application/xml"},
            )
            root = parse_xml(text)
        except RecorderError:
            return []
        segments = []
        for node in root.iter("searchMatchItem"):
            span = node.find("timeSpan")
            if span is None:
                continue
            begins = parse_device_datetime(find_text(span, "startTime"))
            ends = parse_device_datetime(find_text(span, "endTime"))
            if begins is None or ends is None:
                continue
            descriptor = node.find("mediaSegmentDescriptor")
            segments.append(
                RecordingSegment(
                    start=self.from_device_utc(begins),
                    end=self.from_device_utc(ends),
                    handle=find_text(descriptor, "playbackURI")
                    if descriptor is not None
                    else "",
                )
            )
        return segments
