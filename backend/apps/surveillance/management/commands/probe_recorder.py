"""Ask a real recorder what it is, from inside the container that has to talk to it.

Written because the two things that go wrong on site cannot be told apart from
a screenshot, and because the drivers for the boxes nobody chose on purpose —
Xiongmai, ONVIF, Direct RTSP — are built against reverse-engineered or loosely
followed protocols that no amount of unit testing can confirm against the
firmware actually in the shop.

    docker compose exec backend python manage.py probe_recorder 192.168.1.100 \\
        --username admin --password 'secret'

It runs *inside the backend container*, which is the whole point: that is the
network position the cameras are reached from, so a failure here is the failure
the shop will have, and a success rules the network out entirely.

Add ``--search`` to prove recording search works (the thing invoice-linked
footage rests on) and ``--stream`` to have ffmpeg actually open the video and
report the codec and resolution it got. Nothing here writes to the database.
"""

from __future__ import annotations

import subprocess
from datetime import timedelta

from django.core.management.base import BaseCommand, CommandError
from django.utils import timezone

from apps.surveillance import transcode
from apps.surveillance.drivers.base import (
    RecorderAuthError,
    RecorderError,
    RecorderTarget,
    RecorderUnreachable,
    StreamQuality,
)
from apps.surveillance.drivers.registry import (
    DRIVERS_BY_BRAND,
    build_driver,
    detect_driver,
)


def _redact(url: str) -> str:
    """A stream URL carries the DVR password; this output gets pasted around."""
    if "@" not in url:
        return url
    scheme, _, rest = url.partition("://")
    _credentials, _, host = rest.partition("@")
    return f"{scheme}://***:***@{host}"


class Command(BaseCommand):
    help = "Identify a recorder on the LAN and report what Pointy can do with it."

    def add_arguments(self, parser):
        parser.add_argument("host", help="The recorder's address on the shop LAN.")
        parser.add_argument("--username", default="admin")
        parser.add_argument("--password", default="")
        parser.add_argument("--port", type=int, default=80, help="HTTP/control port.")
        parser.add_argument("--rtsp-port", type=int, default=554)
        parser.add_argument(
            "--brand",
            choices=sorted(DRIVERS_BY_BRAND),
            help="Skip detection and use this driver.",
        )
        parser.add_argument(
            "--rtsp-template",
            default="",
            help="Stream path for --brand generic_rtsp, e.g. "
            "'/user={username}&password={password}&channel={channel}&stream={stream}.sdp?'",
        )
        parser.add_argument(
            "--channels", type=int, default=0, help="Channel count for generic_rtsp."
        )
        parser.add_argument(
            "--search",
            action="store_true",
            help="Also search the last hour's recordings on channel 1.",
        )
        parser.add_argument(
            "--stream",
            action="store_true",
            help="Also have ffmpeg open the live stream and report what arrived.",
        )
        parser.add_argument("--channel", type=int, default=1)

    def handle(self, *args, **options):
        target = RecorderTarget(
            host=options["host"],
            port=options["port"],
            rtsp_port=options["rtsp_port"],
            username=options["username"],
            password=options["password"],
            extra={
                "rtsp_path_template": options["rtsp_template"],
                "channel_count": options["channels"],
            },
        )
        brand = options["brand"]

        self.stdout.write(f"Probing {target.host} from inside the backend container…")
        try:
            if brand:
                driver = build_driver(target, brand)
                info = driver.probe()
            else:
                driver, info = detect_driver(target)
        except RecorderAuthError as exc:
            raise CommandError(
                f"CREDENTIALS: {exc}\n"
                "  The box answered, so the network is fine. Check the username "
                "and password, and that the account may be used remotely."
            ) from exc
        except RecorderUnreachable as exc:
            raise CommandError(
                f"NETWORK: {exc}\n"
                "  Nothing answered. Check the address, that the recorder is on, "
                "and — if this container is on a different subnet — that the host "
                "can route to it (the container follows the host's routing table)."
            ) from exc
        except RecorderError as exc:
            raise CommandError(
                f"UNSUPPORTED: {exc}\n"
                "  Something answered but Pointy does not recognise it. Try "
                "--brand onvif, or --brand generic_rtsp with --rtsp-template."
            ) from exc

        try:
            self._report(driver, info, options)
        finally:
            driver.close()

    def _report(self, driver, info, options):
        ok, warn = self.style.SUCCESS, self.style.WARNING
        self.stdout.write(ok("\nIDENTIFIED"))
        for label, value in (
            ("driver", driver.label),
            ("brand", info.brand),
            ("model", info.model or "—"),
            ("firmware", info.firmware or "—"),
            ("serial", info.serial or "—"),
            ("channels", info.channel_count),
            ("clock offset", f"{info.clock_offset_minutes} min from UTC"),
        ):
            self.stdout.write(f"  {label:14} {value}")

        self.stdout.write("\nWHAT POINTY CAN DO WITH IT")
        for label, able, note in (
            ("live video", True, "camera tiles on the till"),
            ("snapshots", driver.supports_snapshot, "live view without ffmpeg"),
            ("recording search", driver.supports_search, "needed for invoice footage"),
            ("playback", driver.supports_playback, "watching a sale back"),
        ):
            mark = ok("yes") if able else warn("no ")
            self.stdout.write(f"  {label:18} {mark}   {note}")

        if not transcode.ffmpeg_available():
            self.stdout.write(
                warn("\n  ffmpeg is NOT installed here — live video needs it.")
            )

        try:
            channels = driver.list_channels()
        except RecorderError as exc:
            self.stdout.write(warn(f"\nCHANNELS: could not be listed ({exc})"))
            channels = []
        if channels:
            self.stdout.write(f"\nCHANNELS ({len(channels)})")
            for channel in channels[:32]:
                self.stdout.write(f"  {channel.channel:3}  {channel.name or '—'}")

        channel = options["channel"]
        try:
            url = driver.live_rtsp_url(channel, quality=StreamQuality.SUB)
            self.stdout.write(f"\nLIVE URL (channel {channel})\n  {_redact(url)}")
        except RecorderError as exc:
            self.stdout.write(warn(f"\nLIVE URL: unavailable ({exc})"))
            url = ""

        if options["search"] and driver.supports_search:
            self._search(driver, channel)
        if options["stream"] and url:
            self._stream(url)

    def _search(self, driver, channel):
        end = timezone.now()
        start = end - timedelta(hours=1)
        self.stdout.write(f"\nRECORDING SEARCH (channel {channel}, last hour)")
        try:
            segments = driver.search_recordings(channel, start, end)
        except RecorderError as exc:
            self.stdout.write(self.style.WARNING(f"  failed: {exc}"))
            return
        if not segments:
            self.stdout.write(
                self.style.WARNING(
                    "  nothing returned — either the hour was not recorded, or "
                    "this box does not answer searches."
                )
            )
            return
        self.stdout.write(self.style.SUCCESS(f"  {len(segments)} stretch(es) found"))
        for segment in segments[:10]:
            self.stdout.write(
                f"  {segment.start:%Y-%m-%d %H:%M:%S} -> {segment.end:%H:%M:%S}"
                f"  {segment.size_bytes or '?'} bytes"
            )

    def _stream(self, url):
        """Open the stream for real. A URL that looks right and serves nothing
        is the failure mode this whole command exists to catch."""
        binary = transcode.ffmpeg_path()
        if not binary:
            self.stdout.write(self.style.WARNING("\nSTREAM: ffmpeg is not installed."))
            return
        probe = binary.replace("ffmpeg", "ffprobe")
        self.stdout.write("\nSTREAM (opening with ffprobe, 15s budget)")
        try:
            result = subprocess.run(
                [
                    probe, "-v", "error", "-rtsp_transport", "tcp",
                    "-select_streams", "v:0",
                    "-show_entries", "stream=codec_name,width,height,avg_frame_rate",
                    "-of", "default=noprint_wrappers=1", "-i", url,
                ],
                capture_output=True, text=True, timeout=15,
            )
        except (OSError, subprocess.TimeoutExpired) as exc:
            self.stdout.write(self.style.ERROR(f"  no video: {exc}"))
            return
        if result.returncode != 0 or not result.stdout.strip():
            self.stdout.write(
                self.style.ERROR(f"  no video: {result.stderr.strip()[:400] or 'empty reply'}")
            )
            self.stdout.write(
                "  If the identity above was right, the stream PATH is the part to "
                "change — try another --rtsp-template."
            )
            return
        self.stdout.write(self.style.SUCCESS("  video is arriving:"))
        for line in result.stdout.strip().splitlines():
            self.stdout.write(f"    {line}")
        self.stdout.write(
            "\n"
            + self.style.SUCCESS(
                "This recorder works with Pointy. Add it in Settings → Cameras "
                "with the brand reported above."
            )
        )
