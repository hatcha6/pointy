"""Find out what a recorder will actually do, by making it do it.

``probe_recorder`` answers "what is this box and can we talk to it". This asks
the questions that only the box can settle, and that a shop's failure report
never contains:

* which ports are open, and how slow each one is to accept
* whether every channel really streams, at both qualities
* **how many simultaneous streams it survives** — the ladder, until it breaks
* whether TCP or UDP behaves differently on this firmware
* whether the native protocol logs in, lists channels and finds recordings

It exists because the 2026-09-08 outage was diagnosed from telemetry alone, and
telemetry could say *that* 18,160 live requests failed but never *why the box
was not answering*. Everything here is read-only: it opens streams, times them,
and closes them.

Run it from the network position the cameras are reached from — the backend
container on the shop's own machine:

    docker compose exec backend python manage.py camera_doctor 192.168.1.100 \\
        --username admin --password 'secret' --channels 4 --max-concurrent 8

Credentials never appear in the output, so the report can be pasted into a chat
or an issue as-is.
"""

from __future__ import annotations

import socket
import subprocess
import time
from concurrent.futures import ThreadPoolExecutor
from datetime import timedelta

from django.core.management.base import BaseCommand
from django.utils import timezone

from apps.surveillance import transcode
from apps.surveillance.drivers.base import (
    RecorderError,
    RecorderTarget,
    StreamQuality,
)
from apps.surveillance.drivers.registry import DRIVERS_BY_BRAND, build_driver, detect_driver

#: Xiongmai's native protocol. Worth probing separately from HTTP because on
#: this hardware it is the port that carries search and playback.
DVRIP_PORT = 34567

#: How long one stream in the ladder is held. Long enough that a box which
#: accepts a session and then starves it is caught, short enough that the whole
#: ladder stays inside a service visit.
HOLD_SECONDS = 5


def _redact(url: str) -> str:
    """Stream URLs carry the DVR password and this output gets pasted around."""
    if "@" not in url:
        return url
    scheme, _, rest = url.partition("://")
    _credentials, _, host = rest.partition("@")
    return f"{scheme}://***:***@{host}"


class Command(BaseCommand):
    help = "Stress a recorder from the shop LAN and report what it can really do."

    def add_arguments(self, parser):
        parser.add_argument("host", help="The recorder's address on the shop LAN.")
        parser.add_argument("--username", default="admin")
        parser.add_argument("--password", default="")
        parser.add_argument("--port", type=int, default=80)
        parser.add_argument("--rtsp-port", type=int, default=554)
        parser.add_argument("--dvrip-port", type=int, default=DVRIP_PORT)
        parser.add_argument(
            "--brand",
            choices=sorted(DRIVERS_BY_BRAND),
            default="",
            help="Skip detection and use this driver.",
        )
        parser.add_argument(
            "--channels",
            type=int,
            default=4,
            help="How many channels to test individually.",
        )
        parser.add_argument(
            "--max-concurrent",
            type=int,
            default=8,
            help="Top of the concurrency ladder. 0 skips it.",
        )
        parser.add_argument(
            "--skip-udp",
            action="store_true",
            help="Skip the transport comparison.",
        )

    # -- entry point ------------------------------------------------------
    def handle(self, *args, **options):
        target = RecorderTarget(
            host=options["host"],
            port=options["port"],
            rtsp_port=options["rtsp_port"],
            username=options["username"],
            password=options["password"],
            extra={"dvrip_port": options["dvrip_port"]},
        )
        self.stdout.write(f"CAMERA DOCTOR — {target.host}")
        self.stdout.write("=" * 60)

        self._ports(target, options)
        binary = self._tooling()
        driver = self._identify(target, options)
        if driver is not None:
            self._native(driver, options)
        if binary is None:
            self.stdout.write(
                self.style.WARNING(
                    "\nNo ffmpeg here, so the stream tests cannot run. On this "
                    "hardware that is not a limitation of the doctor — it is the "
                    "shop's live view, which has no other path."
                )
            )
            return
        if driver is None:
            self.stdout.write(
                self.style.WARNING("\nNo driver, so no stream URLs to test.")
            )
            return
        urls = self._stream_urls(driver, options)
        self._per_channel(binary, urls)
        if not options["skip_udp"]:
            self._transport(binary, urls)
        if options["max_concurrent"] > 0:
            self._ladder(binary, urls, options["max_concurrent"])
        self.stdout.write("\nDone. Nothing here changed the recorder or the database.")

    # -- sections ---------------------------------------------------------
    def _ports(self, target, options):
        """Which doors are open, and how long each takes to answer.

        A slow accept is its own finding: a box that takes four seconds to
        complete a TCP handshake is overloaded before any video is asked for.
        """
        self.stdout.write("\nPORTS")
        for label, port in (
            ("http/control", options["port"]),
            ("rtsp", options["rtsp_port"]),
            ("dvrip (native)", options["dvrip_port"]),
        ):
            started = time.monotonic()
            try:
                with socket.create_connection((target.host, port), timeout=4):
                    elapsed = (time.monotonic() - started) * 1000
                style = self.style.SUCCESS if elapsed < 500 else self.style.WARNING
                self.stdout.write(
                    style(f"  {label:16} {port:>6}  open   {elapsed:7.0f} ms")
                )
            except OSError as exc:
                elapsed = (time.monotonic() - started) * 1000
                self.stdout.write(
                    self.style.ERROR(
                        f"  {label:16} {port:>6}  closed {elapsed:7.0f} ms  ({exc})"
                    )
                )

    def _tooling(self):
        binary = transcode.ffmpeg_path()
        self.stdout.write("\nTOOLING")
        if not binary:
            self.stdout.write(self.style.ERROR("  ffmpeg      missing"))
            return None
        self.stdout.write(self.style.SUCCESS(f"  ffmpeg      {binary}"))
        return binary

    def _identify(self, target, options):
        self.stdout.write("\nIDENTITY")
        try:
            if options["brand"]:
                driver = build_driver(options["brand"], target)
                self.stdout.write(f"  brand       {options['brand']} (forced)")
            else:
                driver = detect_driver(target)
                if driver is None:
                    self.stdout.write(self.style.ERROR("  nothing recognised here"))
                    return None
                self.stdout.write(f"  brand       {driver.brand}")
        except RecorderError as exc:
            self.stdout.write(self.style.ERROR(f"  {exc}"))
            return None
        for label, attribute in (
            ("playback", "supports_playback"),
            ("search", "supports_search"),
            ("snapshot", "supports_snapshot"),
        ):
            supported = getattr(type(driver), attribute, False)
            mark = "yes" if supported else "no"
            self.stdout.write(f"  {label:11} {mark}")
        if not getattr(type(driver), "supports_snapshot", True):
            self.stdout.write(
                "              (so live view here is RTSP-only, by design)"
            )
        return driver

    def _native(self, driver, options):
        """Login, channel list and a recording search over the native protocol.

        Separate from the stream tests on purpose: on Xiongmai this is the port
        that answers search and playback, so it can be healthy while RTSP is not
        — or the reverse — and knowing which is half the diagnosis.
        """
        self.stdout.write("\nNATIVE PROTOCOL")
        try:
            channels = driver.list_channels()
            self.stdout.write(
                self.style.SUCCESS(f"  login+list  ok, {len(channels)} channels")
            )
            for channel in channels[: options["channels"]]:
                self.stdout.write(f"                ch{channel.number}: {channel.name!r}")
        except RecorderError as exc:
            self.stdout.write(self.style.ERROR(f"  login+list  {exc}"))
            return
        if not getattr(type(driver), "supports_search", False):
            return
        end = timezone.now()
        start = end - timedelta(hours=2)
        try:
            segments = driver.search_recordings(1, start, end)
        except RecorderError as exc:
            self.stdout.write(self.style.ERROR(f"  search      {exc}"))
            return
        self.stdout.write(
            self.style.SUCCESS(
                f"  search      ch1, last 2h: {len(segments)} recordings"
            )
            if segments
            else self.style.WARNING("  search      ch1, last 2h: nothing recorded")
        )

    def _stream_urls(self, driver, options):
        urls = []
        for channel in range(1, max(1, options["channels"]) + 1):
            for quality in (StreamQuality.SUB, StreamQuality.MAIN):
                try:
                    url = driver.live_rtsp_url(channel, quality=quality)
                except RecorderError as exc:
                    self.stdout.write(
                        self.style.ERROR(f"  ch{channel} {quality}: no URL ({exc})")
                    )
                    continue
                urls.append((channel, quality, url))
        return urls

    def _open(self, binary, url, *, transport="tcp", hold=0):
        """Pull from ``url`` and report what came back.

        ``hold`` seconds of real video rather than a header read: a box that
        accepts a session and then sends nothing is exactly the failure being
        hunted, and a header-only probe would call that a success.
        """
        probe = binary.replace("ffmpeg", "ffprobe")
        started = time.monotonic()
        if hold:
            command = [
                binary, "-hide_banner", "-loglevel", "error",
                "-rtsp_transport", transport, "-i", url,
                "-t", str(hold), "-f", "null", "-",
            ]
            budget = hold + 12
        else:
            command = [
                probe, "-v", "error", "-rtsp_transport", transport,
                "-select_streams", "v:0", "-show_entries",
                "stream=codec_name,width,height,avg_frame_rate",
                "-of", "default=noprint_wrappers=1", "-i", url,
            ]
            budget = 15
        try:
            result = subprocess.run(
                command, capture_output=True, text=True, timeout=budget
            )
        except subprocess.TimeoutExpired:
            return False, f"timed out after {budget}s", time.monotonic() - started
        except OSError as exc:
            return False, str(exc), time.monotonic() - started
        elapsed = time.monotonic() - started
        if result.returncode != 0:
            return False, (result.stderr.strip().splitlines() or ["failed"])[-1][:120], elapsed
        detail = " ".join(result.stdout.split()) if not hold else "streamed"
        return True, detail or "opened", elapsed

    def _per_channel(self, binary, urls):
        self.stdout.write("\nPER-CHANNEL (ffprobe, one at a time)")
        if urls:
            # The path is the part that varies between OEMs of the same chipset,
            # so it belongs in the report — with the password taken out, because
            # this gets pasted into chats.
            self.stdout.write(f"  url shape   {_redact(urls[0][2])}")
        for channel, quality, url in urls:
            ok, detail, elapsed = self._open(binary, url)
            style = self.style.SUCCESS if ok else self.style.ERROR
            self.stdout.write(
                style(f"  ch{channel:<3} {quality:<5} {elapsed:6.1f}s  {detail}")
            )

    def _transport(self, binary, urls):
        """TCP against UDP on one channel.

        Pointy forces TCP everywhere, and this is the check that says whether
        that is carrying the feature or merely tidy.
        """
        if not urls:
            return
        channel, quality, url = urls[0]
        self.stdout.write(f"\nTRANSPORT (ch{channel} {quality})")
        for transport in ("tcp", "udp"):
            ok, detail, elapsed = self._open(binary, url, transport=transport)
            style = self.style.SUCCESS if ok else self.style.ERROR
            self.stdout.write(style(f"  {transport:<4} {elapsed:6.1f}s  {detail}"))

    def _ladder(self, binary, urls, ceiling):
        """The question a failure report never answers: how many at once?

        Many low-cost recorders record sixteen channels happily and serve four
        RTSP clients badly. This walks 1, 2, 4, 8… until it reaches the ceiling
        or the box starts refusing, holding real streams rather than opening and
        closing sessions — the pattern that upsets this hardware most.
        """
        if not urls:
            return
        self.stdout.write(
            f"\nCONCURRENCY LADDER (holding {HOLD_SECONDS}s of video each)"
        )
        rung = 1
        while rung <= ceiling:
            batch = [urls[index % len(urls)] for index in range(rung)]
            started = time.monotonic()
            with ThreadPoolExecutor(max_workers=rung) as pool:
                results = list(
                    pool.map(
                        lambda item: self._open(
                            binary, item[2], hold=HOLD_SECONDS
                        ),
                        batch,
                    )
                )
            succeeded = sum(1 for ok, _detail, _elapsed in results if ok)
            elapsed = time.monotonic() - started
            line = f"  {rung:>2} at once   {succeeded}/{rung} streamed   {elapsed:5.1f}s"
            if succeeded == rung:
                self.stdout.write(self.style.SUCCESS(line))
            else:
                self.stdout.write(self.style.ERROR(line))
                first_failure = next(
                    detail for ok, detail, _elapsed in results if not ok
                )
                self.stdout.write(f"                first failure: {first_failure}")
                self.stdout.write(
                    self.style.WARNING(
                        f"  → this recorder tops out below {rung} simultaneous "
                        "streams. Keep the wall on the sub-stream and below that "
                        "number, and open the main stream only full screen."
                    )
                )
                return
            rung *= 2
        self.stdout.write(
            self.style.SUCCESS(
                f"  → held {ceiling} at once without complaint; concurrency is "
                "not this box's problem."
            )
        )
