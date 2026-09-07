"""Dahua, and the OEM boxes that ship its CGI unchanged.

Everything is a flat ``key=value`` body rather than XML, and — the trap that
costs an hour if you miss it — **playback times are the recorder's own wall
clock**, not UTC. A DVR left on the factory timezone will happily serve you
footage from the wrong hour without erroring, so the observed clock offset from
``RecorderDriver.read_clock_offset_minutes`` is applied to every playback stamp
here, and to none of Hikvision's.
"""

from __future__ import annotations

from datetime import datetime

from .base import (
    ChannelInfo,
    DeviceInfo,
    RecorderDriver,
    RecorderError,
    RecordingSegment,
    StreamQuality,
    parse_device_datetime,
    rtsp_netloc,
)

SUBTYPE_BY_QUALITY = {StreamQuality.MAIN: 0, StreamQuality.SUB: 1}

# Dahua channels are 1-based everywhere in the CGI and the RTSP paths, while the
# config tables that back them (``table.ChannelTitle[0]``) are 0-based. Both
# appear below; the driver's own API is always 1-based.
CONFIG_INDEX_OFFSET = 1


def parse_key_values(text: str) -> dict[str, str]:
    values = {}
    for line in (text or "").splitlines():
        line = line.strip()
        if not line or "=" not in line:
            continue
        key, _, value = line.partition("=")
        values[key.strip()] = value.strip()
    return values


def _playback_time(moment: datetime) -> str:
    return moment.strftime("%Y_%m_%d_%H_%M_%S")


def _find_time(moment: datetime) -> str:
    return moment.strftime("%Y-%m-%d %H:%M:%S")


class DahuaDriver(RecorderDriver):
    brand = "dahua"
    label = "Dahua"

    # -- identity ----------------------------------------------------------
    def probe(self) -> DeviceInfo:
        info = parse_key_values(
            self.get_text("/cgi-bin/magicBox.cgi?action=getSystemInfo")
        )
        if not info:
            raise RecorderError("Not a Dahua CGI device.")
        version = parse_key_values(
            self._safe_text("/cgi-bin/magicBox.cgi?action=getSoftwareVersion")
        )
        return DeviceInfo(
            brand=self.brand,
            model=info.get("deviceType", "") or info.get("processor", ""),
            serial=info.get("serialNumber", ""),
            firmware=version.get("version", "").split(",")[0],
            channel_count=self._channel_count(),
            clock_offset_minutes=self.read_clock_offset_minutes(),
        )

    def _safe_text(self, path: str) -> str:
        try:
            return self.get_text(path)
        except RecorderError:
            return ""

    def read_device_local_time(self):
        raw = parse_key_values(
            self._safe_text("/cgi-bin/global.cgi?action=getCurrentTime")
        ).get("result", "")
        return parse_device_datetime(raw)

    def _channel_count(self) -> int:
        for name in ("MaxRemoteInputChannels", "MaxExtraStream"):
            values = parse_key_values(
                self._safe_text(
                    f"/cgi-bin/magicBox.cgi?action=getProductDefinition&name={name}"
                )
            )
            raw = values.get(f"table.{name}", "")
            if raw.isdigit() and name == "MaxRemoteInputChannels":
                return int(raw)
        return len(self._channel_titles())

    # -- channels ----------------------------------------------------------
    def _channel_titles(self) -> dict[int, str]:
        values = parse_key_values(
            self._safe_text(
                "/cgi-bin/configManager.cgi?action=getConfig&name=ChannelTitle"
            )
        )
        titles = {}
        for key, value in values.items():
            # table.ChannelTitle[7].Name=Till 2
            if not key.startswith("table.ChannelTitle[") or not key.endswith(".Name"):
                continue
            index = key[len("table.ChannelTitle[") : key.index("]")]
            if index.isdigit():
                titles[int(index) + CONFIG_INDEX_OFFSET] = value
        return titles

    def list_channels(self) -> list[ChannelInfo]:
        titles = self._channel_titles()
        count = max(self._channel_count(), max(titles) if titles else 0)
        if not count:
            raise RecorderError("The recorder reported no video channels.")
        return [
            ChannelInfo(channel=channel, name=titles.get(channel, ""))
            for channel in range(1, count + 1)
        ]

    # -- video -------------------------------------------------------------
    def snapshot(self, channel: int, *, quality: str = StreamQuality.SUB) -> bytes:
        return self.get_bytes(f"/cgi-bin/snapshot.cgi?channel={int(channel)}")

    def live_rtsp_url(self, channel: int, *, quality: str = StreamQuality.SUB) -> str:
        subtype = SUBTYPE_BY_QUALITY.get(StreamQuality.normalize(quality), 1)
        return (
            f"rtsp://{rtsp_netloc(self.target)}/cam/realmonitor"
            f"?channel={int(channel)}&subtype={subtype}"
        )

    def playback_rtsp_url(
        self,
        channel: int,
        start: datetime,
        end: datetime,
        *,
        quality: str = StreamQuality.MAIN,
    ) -> str:
        subtype = SUBTYPE_BY_QUALITY.get(StreamQuality.normalize(quality), 0)
        return (
            f"rtsp://{rtsp_netloc(self.target)}/cam/playback"
            f"?channel={int(channel)}&subtype={subtype}"
            f"&starttime={_playback_time(self.to_device_local(start))}"
            f"&endtime={_playback_time(self.to_device_local(end))}"
        )

    def search_recordings(
        self, channel: int, start: datetime, end: datetime
    ) -> list[RecordingSegment]:
        """Walk the media-file finder, and always tear the handle down.

        The finder is a server-side object with a hard limit on how many can be
        open at once; leaking one per search bricks recording search on the box
        until it reboots, so the close/destroy pair runs even when the walk
        raises.
        """
        created = parse_key_values(
            self._safe_text("/cgi-bin/mediaFileFind.cgi?action=factory.create")
        ).get("result", "")
        if not created:
            return []
        handle = created
        try:
            started = self._safe_text(
                "/cgi-bin/mediaFileFind.cgi?action=findFile"
                f"&object={handle}"
                f"&condition.Channel={int(channel)}"
                f"&condition.StartTime={_find_time(self.to_device_local(start))}"
                f"&condition.EndTime={_find_time(self.to_device_local(end))}"
                "&condition.Types[0]=dav"
            )
            if "ok" not in started.lower():
                return []
            found = parse_key_values(
                self._safe_text(
                    f"/cgi-bin/mediaFileFind.cgi?action=findNextFile&object={handle}"
                    "&count=100"
                )
            )
            return self._segments_from_find(found)
        finally:
            self._safe_text(
                f"/cgi-bin/mediaFileFind.cgi?action=close&object={handle}"
            )
            self._safe_text(
                f"/cgi-bin/mediaFileFind.cgi?action=destroy&object={handle}"
            )

    def _segments_from_find(self, values: dict[str, str]) -> list[RecordingSegment]:
        rows: dict[int, dict[str, str]] = {}
        for key, value in values.items():
            if not key.startswith("items["):
                continue
            index = key[len("items[") : key.index("]")]
            if not index.isdigit():
                continue
            field = key.split("].", 1)[-1]
            rows.setdefault(int(index), {})[field] = value
        segments = []
        for index in sorted(rows):
            row = rows[index]
            begins = parse_device_datetime(row.get("StartTime", ""))
            ends = parse_device_datetime(row.get("EndTime", ""))
            if begins is None or ends is None:
                continue
            raw_size = row.get("Length", "0")
            segments.append(
                RecordingSegment(
                    start=self.from_device_local(begins),
                    end=self.from_device_local(ends),
                    handle=row.get("FilePath", ""),
                    size_bytes=int(raw_size) if raw_size.isdigit() else 0,
                )
            )
        return segments
