"""Tests for the DVR integration.

Nothing here talks to a recorder. The driver tests drive real firmware payloads
captured from Hikvision and Dahua boxes through the parsers, the broker tests
use a fake source, and the view tests stub the driver — so the suite proves the
parts that break in the field (URL shapes, clock offsets, fan-out, gating)
without needing a camera on the LAN.
"""

import io
import subprocess
import sys
import time
from datetime import datetime, timedelta, timezone as dt_timezone
from unittest.mock import patch

from django.contrib.auth import get_user_model
from django.core.cache import cache
from django.test import SimpleTestCase, TestCase, override_settings
from django.urls import reverse
from django.utils import timezone
from rest_framework import status
from rest_framework.test import APIClient

from apps.core.models import ShopSettings
from apps.core.roles import MANAGER_GROUP, SUPERVISOR_GROUP, ensure_role_groups
from apps.sales.models import Order

from . import breaker, services, telemetry, transcode
from .views import MAX_SNAPSHOT_FPS, resolve_live_stream
from . import views as views_module
from .drivers.base import (
    RecorderTarget,
    StreamQuality,
    parse_device_datetime,
    rtsp_netloc,
)
from .drivers.dahua import DahuaDriver, parse_key_values
from .drivers.hikvision import HikvisionDriver, stream_id
from .drivers.registry import detect_driver
from .models import Camera, Recorder
from .drivers.base import (
    RecorderCapabilityError,
    RecorderError,
    RecorderUnreachable,
)
from .streaming import (
    FfmpegSource,
    SnapshotSource,
    _jpeg_frame_end,
    Frame,
    FrameBroker,
    PipedSource,
    StreamError,
)

HIKVISION_DEVICE_INFO = """<?xml version="1.0" encoding="UTF-8"?>
<DeviceInfo version="2.0" xmlns="http://www.hikvision.com/ver20/XMLSchema">
<deviceName>Embedded Net DVR</deviceName>
<model>DS-7216HGHI-K1</model>
<serialNumber>DS-7216HGHI0120210101</serialNumber>
<firmwareVersion>V4.30.005</firmwareVersion>
<videoInputPortNums>16</videoInputPortNums>
</DeviceInfo>"""

HIKVISION_STREAMING_CHANNELS = """<?xml version="1.0" encoding="UTF-8"?>
<StreamingChannelList xmlns="http://www.hikvision.com/ver20/XMLSchema">
<StreamingChannel><id>101</id><channelName>Till 1</channelName>
<enabled>true</enabled></StreamingChannel>
<StreamingChannel><id>102</id><channelName>Till 1</channelName>
<enabled>true</enabled></StreamingChannel>
<StreamingChannel><id>201</id><channelName>Door</channelName>
<enabled>false</enabled></StreamingChannel>
</StreamingChannelList>"""

DAHUA_SYSTEM_INFO = """deviceType=DH-XVR5116HS-I3
processor=ARM
serialNumber=7K03A1BPAZ1E2F3
updateSerial=XVR5116HS
"""

DAHUA_CHANNEL_TITLES = """table.ChannelTitle[0].Name=Counter
table.ChannelTitle[1].Name=Store room
"""


def mjpeg_frame(payload: bytes = b"scan") -> bytes:
    """A structurally valid single-frame JPEG, as ffmpeg's mjpeg encoder emits.

    The demuxer walks JPEG's marker structure rather than scanning for the
    end-of-image bytes, because those bytes occur inside real frames. That makes
    it strict about what a frame *is*, so fixtures have to be shaped like one —
    ``b"\xff\xd8jpeg\xff\xd9"`` is not a JPEG and never was.
    """
    quantization = b"\xff\xdb" + (10).to_bytes(2, "big") + b"\x00" * 8
    start_of_scan = b"\xff\xda" + (4).to_bytes(2, "big") + b"\x01\x00"
    return b"\xff\xd8" + quantization + start_of_scan + payload + b"\xff\xd9"


class _StubDriverMixin:
    """Answer ``get_text``/``get_bytes`` from a dict instead of a device."""

    def __init__(self, target, responses):
        super().__init__(target)
        self.responses = responses
        self.requested = []

    def get_text(self, path, **kwargs):
        self.requested.append(path)
        for prefix, payload in self.responses.items():
            if path.startswith(prefix):
                return payload
        from .drivers.base import RecorderError

        raise RecorderError(f"no stub for {path}")

    def get_bytes(self, path, **kwargs):
        self.requested.append(path)
        return b"\xff\xd8stub\xff\xd9"


class StubHikvision(_StubDriverMixin, HikvisionDriver):
    pass


class StubDahua(_StubDriverMixin, DahuaDriver):
    pass


def target(**overrides):
    values = {
        "host": "192.168.1.64",
        "port": 80,
        "rtsp_port": 554,
        "username": "admin",
        "password": "secret",
    }
    values.update(overrides)
    return RecorderTarget(**values)


class HikvisionDriverTests(TestCase):
    def test_stream_id_encodes_channel_and_track(self):
        self.assertEqual(stream_id(1, StreamQuality.MAIN), 101)
        self.assertEqual(stream_id(1, StreamQuality.SUB), 102)
        self.assertEqual(stream_id(16, StreamQuality.SUB), 1602)

    def test_probe_reads_identity_and_channel_count(self):
        driver = StubHikvision(
            target(),
            {"/ISAPI/System/deviceInfo": HIKVISION_DEVICE_INFO},
        )
        info = driver.probe()
        self.assertEqual(info.brand, "hikvision")
        self.assertEqual(info.model, "DS-7216HGHI-K1")
        self.assertEqual(info.firmware, "V4.30.005")
        self.assertEqual(info.channel_count, 16)

    def test_list_channels_keeps_only_main_tracks(self):
        """The sub-stream entry repeats the channel and must not double it."""
        driver = StubHikvision(
            target(),
            {"/ISAPI/Streaming/channels": HIKVISION_STREAMING_CHANNELS},
        )
        channels = driver.list_channels()
        self.assertEqual([channel.channel for channel in channels], [1, 2])
        self.assertEqual(channels[0].name, "Till 1")
        self.assertFalse(channels[1].online)

    def test_live_and_playback_urls(self):
        driver = StubHikvision(target(), {})
        self.assertEqual(
            driver.live_rtsp_url(3, quality=StreamQuality.SUB),
            "rtsp://admin:secret@192.168.1.64:554/Streaming/Channels/302",
        )
        start = datetime(2026, 9, 7, 12, 0, 0, tzinfo=dt_timezone.utc)
        url = driver.playback_rtsp_url(3, start, start + timedelta(minutes=1))
        self.assertIn("/Streaming/tracks/301", url)
        self.assertIn("starttime=20260907T120000Z", url)
        self.assertIn("endtime=20260907T120100Z", url)

    def test_playback_times_ignore_the_clock_offset(self):
        """ISAPI addresses playback in UTC, so an offset must not shift it."""
        driver = StubHikvision(target(clock_offset_minutes=120), {})
        start = datetime(2026, 9, 7, 12, 0, 0, tzinfo=dt_timezone.utc)
        url = driver.playback_rtsp_url(1, start, start + timedelta(seconds=30))
        self.assertIn("starttime=20260907T120000Z", url)


class DahuaDriverTests(TestCase):
    def test_probe_reads_key_value_body(self):
        driver = StubDahua(
            target(),
            {"/cgi-bin/magicBox.cgi?action=getSystemInfo": DAHUA_SYSTEM_INFO},
        )
        info = driver.probe()
        self.assertEqual(info.brand, "dahua")
        self.assertEqual(info.model, "DH-XVR5116HS-I3")
        self.assertEqual(info.serial, "7K03A1BPAZ1E2F3")

    def test_channel_titles_are_one_based(self):
        """``ChannelTitle[0]`` is channel 1 everywhere else in the CGI."""
        driver = StubDahua(
            target(),
            {
                "/cgi-bin/configManager.cgi": DAHUA_CHANNEL_TITLES,
                "/cgi-bin/magicBox.cgi?action=getProductDefinition": "",
            },
        )
        channels = driver.list_channels()
        self.assertEqual([channel.channel for channel in channels], [1, 2])
        self.assertEqual(channels[0].name, "Counter")
        self.assertEqual(channels[1].name, "Store room")

    def test_playback_url_uses_device_local_time(self):
        """A recorder two hours ahead of UTC must be addressed in its own hour."""
        driver = StubDahua(target(clock_offset_minutes=120), {})
        start = datetime(2026, 9, 7, 12, 0, 0, tzinfo=dt_timezone.utc)
        url = driver.playback_rtsp_url(2, start, start + timedelta(minutes=1))
        self.assertIn("channel=2", url)
        self.assertIn("starttime=2026_09_07_14_00_00", url)
        self.assertIn("endtime=2026_09_07_14_01_00", url)

    def test_live_url_subtypes(self):
        driver = StubDahua(target(), {})
        self.assertIn(
            "subtype=0", driver.live_rtsp_url(1, quality=StreamQuality.MAIN)
        )
        self.assertIn("subtype=1", driver.live_rtsp_url(1, quality=StreamQuality.SUB))

    def test_parse_key_values_ignores_noise(self):
        self.assertEqual(
            parse_key_values("a=1\n\ngarbage\nb = 2\n"), {"a": "1", "b": "2"}
        )


class DriverHelperTests(TestCase):
    def test_rtsp_credentials_are_percent_encoded(self):
        """``Admin@123`` is a real DVR password and would redraw the authority."""
        url = rtsp_netloc(target(password="Admin@123", username="ad min"))
        self.assertEqual(url, "ad%20min:Admin%40123@192.168.1.64:554")

    def test_device_datetime_accepts_every_separator_seen_in_the_field(self):
        expected = datetime(2026, 9, 7, 14, 3, 11)
        for raw in (
            "2026-09-07 14:03:11",
            "2026_09_07_14_03_11",
            "2026-09-07T14:03:11",
            "2026-09-07T14:03:11+02:00",
        ):
            self.assertEqual(parse_device_datetime(raw), expected, raw)

    def test_clock_offset_snaps_to_the_quarter_hour(self):
        driver = StubHikvision(target(), {})
        now = datetime.now(dt_timezone.utc).replace(tzinfo=None)
        with patch.object(
            StubHikvision,
            "read_device_local_time",
            return_value=now + timedelta(minutes=119, seconds=42),
        ):
            self.assertEqual(driver.read_clock_offset_minutes(), 120)

    def test_detection_reraises_bad_credentials_instead_of_trying_the_next_brand(self):
        from .drivers.base import RecorderAuthError

        with patch.object(
            HikvisionDriver, "probe", side_effect=RecorderAuthError("bad password")
        ), patch.object(DahuaDriver, "probe") as dahua_probe:
            with self.assertRaises(RecorderAuthError):
                detect_driver(target())
            dahua_probe.assert_not_called()


class _CountingSource:
    """A source that reports how many times it was constructed.

    Unbounded by default, because that is what a live camera is — and a source
    that *finishes* is legitimately retired by the broker, so a finite one would
    make the sharing tests measure the wrong thing.
    """

    starts = 0

    def __init__(self, limit=None, interval=0.01):
        self.limit = limit
        self.interval = interval
        type(self).starts += 1

    def frames(self, should_stop):
        index = 0
        while not should_stop():
            if self.limit is not None and index >= self.limit:
                return
            yield Frame(
                data=b"\xff\xd8" + bytes([index % 251]) + b"\xff\xd9",
                sequence=index + 1,
                captured_at=datetime.now(dt_timezone.utc),
            )
            index += 1
            time.sleep(self.interval)


class FrameBrokerTests(TestCase):
    def setUp(self):
        self.broker = FrameBroker()
        _CountingSource.starts = 0
        self.addCleanup(self.broker.shutdown)

    def test_two_subscribers_share_one_producer(self):
        with self.broker.subscribe("cam1:live", lambda: _CountingSource()):
            with self.broker.subscribe("cam1:live", lambda: _CountingSource()):
                pass
        self.assertEqual(_CountingSource.starts, 1)

    def test_different_keys_get_different_producers(self):
        with self.broker.subscribe("cam1:live", lambda: _CountingSource()):
            with self.broker.subscribe("cam2:live", lambda: _CountingSource()):
                pass
        self.assertEqual(_CountingSource.starts, 2)

    def test_subscriber_receives_frames(self):
        with self.broker.subscribe("cam1", lambda: _CountingSource(limit=3)) as stream:
            received = list(stream)
        self.assertGreaterEqual(len(received), 1)
        self.assertTrue(all(frame.data.startswith(b"\xff\xd8") for frame in received))

    def test_producer_error_reaches_the_subscriber(self):
        class _Failing:
            def frames(self, should_stop):
                raise RuntimeError("recorder said no")
                yield  # pragma: no cover - generator marker

        with self.broker.subscribe("cam-bad", _Failing) as stream:
            with self.assertRaises(StreamError) as caught:
                list(stream)
        self.assertIn("recorder said no", str(caught.exception))


    def test_a_reattach_paints_the_last_frame_before_the_stream_warms_up(self):
        """The scroll-away-and-back case, which is what a wall of tiles is for.

        A cold start cannot produce anything until the recorder has accepted an
        RTSP session and sent a keyframe. Without this the tile is blank for
        those seconds and the owner reads the feature as broken.
        """
        with self.broker.subscribe("cam1", lambda: _CountingSource(limit=2)) as stream:
            first = list(stream)
        self.assertTrue(first)

        with self.broker.subscribe("cam1", lambda: _CountingSource(limit=2)) as stream:
            second = list(stream)
        # The very first thing the second viewer got is the frame the first
        # viewer last saw, not a wait.
        self.assertEqual(second[0].data, first[-1].data)

    def test_the_warm_frame_never_swallows_the_live_ones(self):
        """The cached frame carries a high sequence from its old producer; a new
        producer restarts at 1. Handed through unchanged, ``stream()`` would
        discard every real frame as older than the warm one and the tile would
        freeze on a still image."""
        with self.broker.subscribe("cam1", lambda: _CountingSource(limit=6)) as stream:
            list(stream)
        with self.broker.subscribe("cam1", lambda: _CountingSource(limit=6)) as stream:
            received = list(stream)
        self.assertGreater(len(received), 1, "live frames were swallowed by the warm one")
        self.assertEqual(received[0].sequence, 0)

    def test_joining_a_running_producer_is_not_sent_a_stale_frame(self):
        """It would be a step backwards: the live producer's current frame is
        already newer than anything cached."""
        self.broker.remember(
            "cam1",
            Frame(
                data=b"\xff\xd8STALE\xff\xd9",
                sequence=99,
                captured_at=datetime.now(dt_timezone.utc),
            ),
        )
        with self.broker.subscribe("cam1", lambda: _CountingSource()):
            with self.broker.subscribe("cam1", lambda: _CountingSource()) as second:
                frame = next(iter(second))
        self.assertNotIn(b"STALE", frame.data)

    @override_settings(POINTY_SURVEILLANCE_LAST_FRAME_TTL_SECONDS=0)
    def test_the_warm_frame_can_be_turned_off(self):
        with self.broker.subscribe("cam1", lambda: _CountingSource(limit=2)) as stream:
            list(stream)
        self.assertIsNone(self.broker.last_frame("cam1"))

    def test_a_frame_older_than_the_ttl_is_not_shown_as_live(self):
        """Painting a ten-minute-old still as if it were the camera now is worse
        than an honest wait."""
        self.broker.remember(
            "cam1",
            Frame(
                data=b"\xff\xd8OLD\xff\xd9",
                sequence=1,
                captured_at=datetime.now(dt_timezone.utc) - timedelta(hours=1),
            ),
        )
        self.assertIsNone(self.broker.last_frame("cam1"))

    def test_remembered_frames_are_bounded(self):
        with override_settings(POINTY_SURVEILLANCE_MAX_PRODUCERS=3):
            for index in range(10):
                self.broker.remember(
                    f"cam{index}",
                    Frame(
                        data=b"\xff\xd8x\xff\xd9",
                        sequence=1,
                        captured_at=datetime.now(dt_timezone.utc),
                    ),
                )
            self.assertLessEqual(len(self.broker._last_frames), 3)


    @override_settings(POINTY_SURVEILLANCE_MAX_PRODUCERS=2)
    def test_a_viewer_beats_a_lingering_stream_for_the_last_slot(self):
        """Scrolling a wall leaves streams lingering with nobody watching. Those
        must not hold the ceiling against the camera the person actually stopped
        on — refusing that is a worse bug than the cold start lingering fixes."""
        with self.broker.subscribe("cam1", lambda: _CountingSource()):
            pass  # detaches, but lingers
        with self.broker.subscribe("cam2", lambda: _CountingSource()):
            pass  # so does this one — both slots are now held by idle streams
        self.assertEqual(len(self.broker.active_keys()), 2)

        with self.broker.subscribe("cam3", lambda: _CountingSource()) as stream:
            self.assertIsNotNone(next(iter(stream)))
        self.assertIn("cam3", self.broker.active_keys())

    @override_settings(POINTY_SURVEILLANCE_MAX_PRODUCERS=1)
    def test_a_watched_stream_is_never_evicted_for_a_new_one(self):
        """Eviction may only reclaim streams nobody is looking at. Killing a
        live picture to draw another is not a trade worth making."""
        with self.broker.subscribe("watched", lambda: _CountingSource()):
            with self.assertRaises(StreamError):
                with self.broker.subscribe("newcomer", lambda: _CountingSource()):
                    pass
            self.assertIn("watched", self.broker.active_keys())

    @override_settings(POINTY_SURVEILLANCE_MAX_PRODUCERS=1)
    def test_producer_ceiling_is_enforced(self):
        with self.broker.subscribe("a", lambda: _CountingSource()):
            with self.assertRaises(StreamError):
                with self.broker.subscribe("b", lambda: _CountingSource()):
                    pass


class LiveStreamPolicyTests(TestCase):
    """Which live path runs, and how fast it is allowed to."""

    def test_the_real_path_carries_whatever_the_client_asks_for(self):
        smooth, fps = views_module.resolve_live_stream(
            "30", None, ffmpeg_available=True
        )
        self.assertTrue(smooth)
        self.assertEqual(fps, 30)

    def test_a_wall_of_nine_may_ask_for_thirty_each(self):
        # The point of the ceiling being 60: nothing in our code decides that a
        # recorder streaming 30fps arrives at less than 30.
        for _ in range(9):
            _, fps = views_module.resolve_live_stream(
                "30", None, ffmpeg_available=True
            )
            self.assertEqual(fps, 30)

    def test_the_snapshot_fallback_is_capped_where_http_stops_coping(self):
        smooth, fps = views_module.resolve_live_stream(
            "30", None, ffmpeg_available=False
        )
        self.assertFalse(smooth)
        self.assertEqual(fps, views_module.MAX_SNAPSHOT_FPS)

    def test_a_client_may_force_the_snapshot_path(self):
        smooth, fps = views_module.resolve_live_stream(
            "30", "false", ffmpeg_available=True
        )
        self.assertFalse(smooth)
        self.assertEqual(fps, views_module.MAX_SNAPSHOT_FPS)

    def test_an_absurd_request_is_clamped_rather_than_refused(self):
        _, fps = views_module.resolve_live_stream(
            "9999", None, ffmpeg_available=True
        )
        self.assertEqual(fps, views_module.MAX_FPS)
        _, fps = views_module.resolve_live_stream(
            "junk", None, ffmpeg_available=True
        )
        self.assertEqual(fps, views_module.DEFAULT_LIVE_FPS)


class TranscodeTests(TestCase):
    def setUp(self):
        transcode.reset_probe_cache()
        self.addCleanup(transcode.reset_probe_cache)

    @override_settings(POINTY_FFMPEG_PATH="/definitely/not/here")
    def test_missing_ffmpeg_is_reported_not_raised(self):
        self.assertFalse(transcode.ffmpeg_available())

    @override_settings(POINTY_FFMPEG_PATH="/definitely/not/here")
    def test_opening_a_stream_without_ffmpeg_raises_a_readable_error(self):
        with self.assertRaises(transcode.TranscodeUnavailable) as caught:
            transcode.open_mjpeg_stream("rtsp://x/y")
        self.assertIn("ffmpeg", str(caught.exception))

    def test_slots_are_released(self):
        before = transcode.active_process_count()
        slot = transcode.reserve_slot()
        self.assertEqual(transcode.active_process_count(), before + 1)
        slot.release()
        slot.release()
        self.assertEqual(transcode.active_process_count(), before)


class ServiceTests(TestCase):
    def test_blank_password_on_update_keeps_the_stored_one(self):
        recorder = Recorder.objects.create(
            host="10.0.0.5", username="admin", password="kept"
        )
        built = services.target_from_payload({"password": ""}, fallback=recorder)
        self.assertEqual(built.password, "kept")

    def test_sync_keeps_local_names_when_a_channel_goes_offline(self):
        recorder = Recorder.objects.create(host="10.0.0.5", username="admin")
        camera = Camera.objects.create(
            recorder=recorder, channel=1, name="الصندوق", covers_checkout=True
        )
        services.sync_cameras(recorder, [])
        camera.refresh_from_db()
        self.assertEqual(camera.name, "الصندوق")
        self.assertTrue(camera.covers_checkout)
        self.assertEqual(camera.status, Camera.Status.OFFLINE)

    def test_invoice_window_brackets_the_sale(self):
        settings = ShopSettings.load()
        settings.surveillance_pre_roll_seconds = 10
        settings.surveillance_post_roll_seconds = 20
        settings.save()
        order = Order.objects.create()
        start, end = services.invoice_window(order, settings)
        self.assertEqual((order.created_at - start).total_seconds(), 10)
        self.assertEqual((end - order.created_at).total_seconds(), 20)

    def test_clamp_window_bounds_a_runaway_request(self):
        start = timezone.now()
        _, end = services.clamp_window(
            start, start + timedelta(hours=99), maximum_seconds=60
        )
        self.assertEqual((end - start).total_seconds(), 60)

    def test_stream_key_separates_windows_and_speeds(self):
        recorder = Recorder.objects.create(host="10.0.0.5", username="admin")
        camera = Camera.objects.create(recorder=recorder, channel=1)
        start = datetime(2026, 9, 7, 12, 0, tzinfo=dt_timezone.utc)
        first = services.stream_key(
            camera, mode="playback", quality="main", window=(start, start), speed=1
        )
        second = services.stream_key(
            camera, mode="playback", quality="main", window=(start, start), speed=2
        )
        self.assertNotEqual(first, second)


class ApiTests(TestCase):
    def setUp(self):
        ensure_role_groups()
        self.client = APIClient()
        user_model = get_user_model()
        self.manager = user_model.objects.create_user(
            username="manager", password="pass1234"
        )
        self.manager.groups.add(*[
            group for group in self.manager.groups.model.objects.filter(
                name=MANAGER_GROUP
            )
        ])
        self.recorder = Recorder.objects.create(
            host="10.0.0.9",
            username="admin",
            password="secret",
            detected_brand="hikvision",
            status=Recorder.Status.OK,
        )
        self.camera = Camera.objects.create(
            recorder=self.recorder, channel=1, name="الصندوق", covers_checkout=True
        )

    def login_manager(self):
        self.client.force_authenticate(self.manager)

    def test_status_reports_capabilities(self):
        self.login_manager()
        with patch.object(transcode, "probe", return_value={
            "available": False,
            "path": "",
            "version": "",
            "supports_readrate": False,
        }):
            response = self.client.get(reverse("surveillance-status"))
        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertTrue(response.data["configured"])
        self.assertFalse(response.data["playback_available"])
        self.assertEqual(response.data["camera_count"], 1)

    def test_recorder_password_is_never_returned(self):
        self.login_manager()
        response = self.client.get(
            reverse("surveillance-recorder-detail", args=[self.recorder.pk])
        )
        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertNotIn("password", response.data)
        self.assertTrue(response.data["has_password"])

    def test_camera_can_be_renamed(self):
        self.login_manager()
        response = self.client.patch(
            reverse("surveillance-camera-detail", args=[self.camera.pk]),
            {"name": "الباب الأمامي"},
            format="json",
        )
        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.camera.refresh_from_db()
        self.assertEqual(self.camera.name, "الباب الأمامي")

    def test_camera_channel_cannot_be_moved_by_a_client(self):
        self.login_manager()
        self.client.patch(
            reverse("surveillance-camera-detail", args=[self.camera.pk]),
            {"channel": 9},
            format="json",
        )
        self.camera.refresh_from_db()
        self.assertEqual(self.camera.channel, 1)

    def test_invoice_footage_offers_checkout_cameras_and_a_window(self):
        self.login_manager()
        order = Order.objects.create()
        response = self.client.get(
            reverse("surveillance-invoice-footage", args=[order.pk])
        )
        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(len(response.data["cameras"]), 1)
        self.assertLess(response.data["start"], order.created_at)
        self.assertGreater(response.data["end"], order.created_at)

    def test_streams_require_authentication(self):
        response = self.client.get(
            reverse("surveillance-camera-live", args=[self.camera.pk])
        )
        self.assertIn(
            response.status_code,
            (status.HTTP_401_UNAUTHORIZED, status.HTTP_403_FORBIDDEN),
        )

    def test_export_is_refused_without_the_export_permission(self):
        user_model = get_user_model()
        supervisor = user_model.objects.create_user(
            username="floor", password="pass1234"
        )
        supervisor.groups.add(
            *supervisor.groups.model.objects.filter(name=SUPERVISOR_GROUP)
        )
        self.client.force_authenticate(supervisor)
        response = self.client.get(
            reverse("surveillance-camera-export", args=[self.camera.pk]),
            {"start": "2026-09-07T12:00:00Z", "end": "2026-09-07T12:01:00Z"},
        )
        self.assertEqual(response.status_code, status.HTTP_403_FORBIDDEN)

    def test_supervisor_may_watch_live(self):
        user_model = get_user_model()
        supervisor = user_model.objects.create_user(
            username="floor2", password="pass1234"
        )
        supervisor.groups.add(
            *supervisor.groups.model.objects.filter(name=SUPERVISOR_GROUP)
        )
        self.client.force_authenticate(supervisor)
        with patch.object(services, "open_driver") as open_driver:
            open_driver.return_value = StubHikvision(target(), {})
            response = self.client.get(
                reverse("surveillance-camera-live", args=[self.camera.pk]),
                # The snapshot path explicitly: this stub answers HTTP, not RTSP.
                {"fps": 1, "smooth": "false"},
            )
        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertIn("multipart/x-mixed-replace", response["Content-Type"])
        # Drain so the producer thread unwinds with the test, not after it.
        chunks = iter(response.streaming_content)
        self.assertIn(b"\xff\xd8", next(chunks))
        response.close()

    def test_live_defaults_to_the_rtsp_path_when_ffmpeg_is_present(self):
        """The only path that can carry a real frame rate is the default.

        Snapshot polling costs an HTTP round trip per frame, so it cannot serve
        the 30fps a modern recorder streams — asking a DVR for thirty stills a
        second on nine channels is how you take the DVR down.
        """
        self.login_manager()
        driver = StubHikvision(target(), {})
        with patch.object(transcode, "ffmpeg_available", return_value=True), \
                patch.object(services, "open_driver", return_value=driver), \
                patch.object(FfmpegSource, "frames") as frames:
            frames.return_value = iter(())
            self.client.get(
                reverse("surveillance-camera-live", args=[self.camera.pk]),
                {"fps": 30},
            )
        frames.assert_called()

    def test_status_reports_the_frame_rate_this_server_can_carry(self):
        self.login_manager()
        with patch.object(transcode, "probe", return_value={
            "available": True,
            "path": "/usr/bin/ffmpeg",
            "version": "6.1",
            "supports_readrate": True,
        }):
            response = self.client.get(reverse("surveillance-status"))
        self.assertEqual(response.data["max_live_fps"], views_module.MAX_FPS)
        self.assertGreaterEqual(response.data["max_live_fps"], 30)
        self.assertTrue(response.data["smooth_live_available"])

    def test_status_reports_the_snapshot_ceiling_without_ffmpeg(self):
        self.login_manager()
        with patch.object(transcode, "probe", return_value={
            "available": False,
            "path": "",
            "version": "",
            "supports_readrate": False,
        }):
            response = self.client.get(reverse("surveillance-status"))
        self.assertEqual(
            response.data["max_live_fps"], views_module.MAX_SNAPSHOT_FPS
        )
        self.assertFalse(response.data["smooth_live_available"])

    def test_playback_without_ffmpeg_says_so(self):
        self.login_manager()
        with patch.object(transcode, "ffmpeg_available", return_value=False):
            response = self.client.get(
                reverse("surveillance-camera-playback", args=[self.camera.pk]),
                {"start": "2026-09-07T12:00:00Z", "end": "2026-09-07T12:01:00Z"},
            )
        self.assertEqual(response.status_code, status.HTTP_503_SERVICE_UNAVAILABLE)
        self.assertIn("ffmpeg", response.data["detail"])

    def test_a_disabled_camera_does_not_stream(self):
        self.login_manager()
        Camera.objects.filter(pk=self.camera.pk).update(is_enabled=False)
        response = self.client.get(
            reverse("surveillance-camera-live", args=[self.camera.pk])
        )
        self.assertEqual(response.status_code, status.HTTP_404_NOT_FOUND)


class FeatureGateTests(TestCase):
    def test_a_successful_connection_turns_the_feature_on(self):
        self.assertFalse(ShopSettings.load().enable_surveillance)
        recorder = Recorder.objects.create(host="10.0.0.5", username="admin")
        result = services.ConnectionResult(
            info=type(
                "Info",
                (),
                {
                    "brand": "hikvision",
                    "model": "DS",
                    "serial": "",
                    "firmware": "",
                    "channel_count": 1,
                    "clock_offset_minutes": 0,
                },
            )(),
            channels=[],
        )
        services.apply_connection_result(recorder, result)
        self.assertTrue(ShopSettings.load().enable_surveillance)

    def test_a_manager_who_turned_it_off_stays_off(self):
        settings = ShopSettings.load()
        settings.enable_surveillance = False
        settings.save()
        Recorder.objects.create(
            host="10.0.0.5", username="admin", status=Recorder.Status.OK
        )
        # Nothing re-enables it without a fresh successful connection.
        self.assertFalse(ShopSettings.load().enable_surveillance)


class PipedSourceTests(TestCase):
    """Playback for recorders that hand back bytes instead of a URL.

    The two things worth pinning are ownership and blame: this source owns the
    driver (its protocol session has to outlive the response, unlike the URL
    path where the driver is closed before streaming starts), and when nothing
    comes out it must report the *recorder's* reason rather than ffmpeg's, which
    only ever describes the symptom.
    """

    class _FakeProcess:
        def __init__(self, output=b""):
            self.stdin = io.BytesIO()
            self.stdout = io.BytesIO(output)
            self.written = b""

        def poll(self):
            return 0

    class _Driver:
        supports_playback = True
        playback_is_streamed = True

        def __init__(self, chunks=(), error=None):
            self.chunks = list(chunks)
            self.error = error
            self.closed = False
            self.stopped = False

        def playback_stream(self, channel, start, end, *, quality="main"):
            try:
                if self.error:
                    raise self.error
                yield from self.chunks
            finally:
                self.stopped = True

        def close(self):
            self.closed = True

    def _run(self, driver, output=b""):
        process = self._FakeProcess(output)
        slot = object()
        with patch.object(
            transcode, "open_mjpeg_from_h264", return_value=(process, slot)
        ), patch.object(transcode, "stop"), patch.object(
            transcode, "drain_error", return_value=""
        ):
            source = PipedSource(
                driver,
                1,
                timezone.now(),
                timezone.now(),
                label="cam",
            )
            frames = list(source.frames(lambda: False))
        return frames, process

    def test_the_recorders_reason_beats_ffmpegs(self):
        """'no footage stored for that time' is actionable; 'invalid data found'
        is not, and it is what ffmpeg would say about the same situation."""
        driver = self._Driver(error=RecorderError("The recorder has no footage stored."))
        with self.assertRaises(StreamError) as caught:
            self._run(driver)
        self.assertIn("no footage", str(caught.exception).lower())

    def test_the_driver_is_closed_when_the_stream_ends(self):
        """It is the source of the bytes, so nothing else can close it — and a
        leaked protocol session is one the recorder will not grant again."""
        driver = self._Driver(chunks=[b"\x00\x00\x01\x65IDR"])
        self._run(driver, output=mjpeg_frame())
        self.assertTrue(driver.closed)
        self.assertTrue(driver.stopped)

    def test_frames_reach_the_consumer(self):
        driver = self._Driver(chunks=[b"\x00\x00\x01\x65IDR"])
        frames, _process = self._run(
            driver, output=mjpeg_frame(b"one") + mjpeg_frame(b"two")
        )
        self.assertEqual(len(frames), 2)
        self.assertTrue(all(frame.data.startswith(b"\xff\xd8") for frame in frames))


class FfmpegStderrTests(TestCase):
    """ffmpeg's diagnostics have to be read, not just captured.

    stderr is a pipe with a buffer of a few dozen KB and nothing read it until a
    stream had already failed. A pipeline that complains steadily — which is
    exactly what a decoder chewing through a damaged stream does — fills it, and
    ffmpeg then blocks writing to it. The video stops, and the error that
    explains why is the thing that stopped it.
    """

    def test_a_chatty_pipeline_cannot_block_on_its_own_error_pipe(self):
        process = self._spawn_echoing_stderr(
            "[h264] non-existing PPS 0 referenced ", repeat=4000
        )
        try:
            # Far more than a pipe buffer holds. If nothing drained it the
            # process would still be alive and stuck on write().
            process.wait(timeout=10)
        except subprocess.TimeoutExpired:  # pragma: no cover - the bug this pins
            process.kill()
            self.fail("ffmpeg blocked writing to stderr: nobody was reading it")
        self.assertEqual(process.returncode, 0)

    def test_the_last_complaints_are_kept_for_the_error_message(self):
        process = self._spawn_echoing_stderr("Invalid data found when processing input")
        process.wait(timeout=10)
        for _ in range(50):
            if transcode.drain_error(process):
                break
            time.sleep(0.05)
        self.assertIn("Invalid data", transcode.drain_error(process))

    def _spawn_echoing_stderr(self, text, repeat=1):
        slot = transcode.reserve_slot()
        self.addCleanup(slot.release)
        # The child multiplies the line itself rather than being handed the
        # finished blob. Linux caps a single argv entry at 128 KB
        # (MAX_ARG_STRLEN) and refuses the exec outright above it, which is a
        # problem for a test whose whole point is writing more than a pipe
        # holds. macOS has no such per-argument cap, so passing it in argv
        # worked here and failed only on CI.
        script = (
            "import sys; sys.stderr.write(%r * %d + '\\n'); sys.stderr.flush()"
            % (text, repeat)
        )
        process, _slot = transcode._spawn([sys.executable, "-c", script], slot)
        self.addCleanup(lambda: transcode.stop(process))
        return process


class CameraTelemetryTests(TestCase):
    """Telemetry has taken this product down before, so these are guards, not
    coverage: one row per session, failures folded, and nothing that can raise
    into the video path."""

    def setUp(self):
        telemetry.reset()
        self.addCleanup(telemetry.reset)

    def _report(self, **overrides):
        values = {
            "camera_id": 7,
            "brand": "xiongmai",
            "mode": "live-rtsp",
            "quality": "sub",
        }
        values.update(overrides)
        return telemetry.StreamReport(**values)

    def test_a_session_writes_one_row_however_many_frames_it_carried(self):
        """A nine-tile wall at 8fps is 72 frames a second. A row each would be a
        write storm on the machine the till runs on."""
        report = self._report()
        for _ in range(5000):
            report.frames += 1
            report.first_frame()
        with patch("apps.analytics.services.record_event_buffered") as recorded:
            telemetry.record(report)
        self.assertEqual(recorded.call_count, 1)
        self.assertEqual(recorded.call_args.kwargs["metrics"]["frames"], 5000)

    def test_repeated_failures_for_one_camera_are_folded_into_a_count(self):
        """A camera unplugged on a Friday would otherwise write rows until
        Monday, once per retry, from every tile."""
        with patch("apps.analytics.services.record_event_buffered") as recorded:
            for _ in range(20):
                telemetry.record(self._report(outcome=telemetry.UNREACHABLE))
        self.assertEqual(recorded.call_count, 1)

        # The next one past the window carries what it stood in for. Only the
        # window is overridden: patching the settings reader wholesale would
        # also answer `enabled()` and switch telemetry off entirely.
        with override_settings(POINTY_SURVEILLANCE_TELEMETRY_FAILURE_WINDOW=0), patch(
            "apps.analytics.services.record_event_buffered"
        ) as recorded:
            telemetry.record(self._report(outcome=telemetry.UNREACHABLE))
        self.assertEqual(recorded.call_args.kwargs["metrics"]["suppressed_repeats"], 19)

    def test_a_different_camera_is_not_folded_into_the_first(self):
        with patch("apps.analytics.services.record_event_buffered") as recorded:
            telemetry.record(self._report(camera_id=1, outcome=telemetry.UNREACHABLE))
            telemetry.record(self._report(camera_id=2, outcome=telemetry.UNREACHABLE))
        self.assertEqual(recorded.call_count, 2)

    def test_successes_are_never_throttled(self):
        """They are bounded by human behaviour: a session ends when someone
        navigates away."""
        with patch("apps.analytics.services.record_event_buffered") as recorded:
            for _ in range(6):
                telemetry.record(self._report())
        self.assertEqual(recorded.call_count, 6)

    def test_a_telemetry_failure_never_reaches_the_caller(self):
        """The video path calls this. A bug here must not be the reason a shop
        cannot see its cameras."""
        with patch(
            "apps.analytics.services.record_event_buffered",
            side_effect=RuntimeError("analytics is down"),
        ):
            telemetry.record(self._report())  # must not raise

    @override_settings(POINTY_SURVEILLANCE_TELEMETRY=False)
    def test_it_can_be_switched_off_entirely(self):
        with patch("apps.analytics.services.record_event_buffered") as recorded:
            telemetry.record(self._report())
        self.assertEqual(recorded.call_count, 0)

    def test_it_reports_whether_the_warm_cache_spared_a_cold_start(self):
        """The question the last-frame work exists to answer."""
        report = self._report()
        report.warm_start = True
        report.shared = False
        with patch("apps.analytics.services.record_event_buffered") as recorded:
            telemetry.record(report)
        attributes = recorded.call_args.kwargs["attributes"]
        self.assertTrue(attributes["warm_start"])
        self.assertFalse(attributes["shared"])

    def test_time_to_first_frame_is_measured_once_and_not_reset(self):
        report = self._report()
        report.first_frame()
        first = report.first_frame_at
        report.first_frame()
        self.assertEqual(report.first_frame_at, first)
        self.assertIsNotNone(report.first_frame_ms)

    def test_the_broker_reports_a_shared_producer_as_shared(self):
        broker = FrameBroker()
        self.addCleanup(broker.shutdown)
        cold = self._report()
        with broker.subscribe("cam1", lambda: _CountingSource(), report=cold):
            warm = self._report()
            with broker.subscribe("cam1", lambda: _CountingSource(), report=warm):
                pass
        self.assertFalse(cold.shared)
        self.assertTrue(warm.shared)


class JpegDimensionTests(TestCase):
    """What the tile actually received — the one measurement available on every
    driver, whatever protocol the video arrived by."""

    def _jpeg(self, width, height):
        # A minimal JPEG: SOI, a segment to skip over, then SOF0.
        return (
            b"\xff\xd8"
            + b"\xff\xe0\x00\x04ab"
            + b"\xff\xc0\x00\x11\x08"
            + bytes([height >> 8, height & 0xFF, width >> 8, width & 0xFF])
            + b"\x03\x01\x22\x00"
        )

    def test_it_reads_the_frame_header(self):
        self.assertEqual(telemetry.jpeg_dimensions(self._jpeg(704, 576)), (704, 576))

    def test_it_skips_segments_before_the_frame_header(self):
        self.assertEqual(telemetry.jpeg_dimensions(self._jpeg(1920, 1080)), (1920, 1080))

    def test_junk_yields_nothing_rather_than_raising(self):
        for payload in (b"", b"\xff\xd8", b"not a jpeg at all", b"\xff\xd8\xff\xc0\x00"):
            self.assertEqual(telemetry.jpeg_dimensions(payload), (0, 0))


@override_settings(
    CACHES={
        "default": {
            "BACKEND": "django.core.cache.backends.locmem.LocMemCache",
            "LOCATION": "surveillance-breaker-tests",
        }
    }
)
class RecorderCircuitBreakerTests(TestCase):
    """The guard against 2026-09-08.

    A shop switched its cameras on, the DVR did not answer, and the live view
    returned 5xx 18,160 times over three days — each one burning a six-second
    connect timeout on a threadpool the tills share. These prove the breaker
    stops dialling, and just as importantly that it does not stop dialling for
    the wrong reasons.
    """

    def setUp(self):
        ensure_role_groups()
        cache.clear()
        # The module-level broker keeps a live stream alive per key, so without
        # a fresh one a test that opened a working stream would hand the next
        # test its frames and the driver would never be dialled at all.
        isolated = FrameBroker()
        patcher = patch.object(views_module, "broker", isolated)
        patcher.start()
        self.addCleanup(patcher.stop)
        self.addCleanup(isolated.shutdown)
        self.client = APIClient()
        user_model = get_user_model()
        self.manager = user_model.objects.create_user(
            username="breaker-manager", password="pass1234"
        )
        self.manager.groups.add(
            *self.manager.groups.model.objects.filter(name=MANAGER_GROUP)
        )
        self.client.force_authenticate(self.manager)
        self.recorder = Recorder.objects.create(
            host="10.0.0.44",
            username="admin",
            password="secret",
            detected_brand="hikvision",
            status=Recorder.Status.OK,
        )
        self.camera = Camera.objects.create(
            recorder=self.recorder, channel=1, name="الصندوق"
        )
        self.other_camera = Camera.objects.create(
            recorder=self.recorder, channel=2, name="الباب"
        )

    def tearDown(self):
        cache.clear()

    def _live(self, camera=None):
        return self.client.get(
            reverse(
                "surveillance-camera-live", args=[(camera or self.camera).pk]
            ),
            {"fps": 1, "smooth": "false"},
        )

    def test_unreachable_recorder_trips_the_breaker_and_stops_dialling(self):
        unreachable = RecorderUnreachable("The recorder did not answer in time.")
        with patch.object(
            services, "open_driver", side_effect=unreachable
        ) as open_driver:
            for _ in range(breaker.FAILURE_THRESHOLD):
                self.assertEqual(self._live().status_code, 502)
            dials_before = open_driver.call_count

            response = self._live()

        self.assertEqual(response.status_code, status.HTTP_503_SERVICE_UNAVAILABLE)
        self.assertEqual(response.data["code"], "recorder_cooling_down")
        self.assertGreater(response.data["retry_after"], 0)
        self.assertEqual(response["Retry-After"], str(response.data["retry_after"]))
        # The point of the whole exercise: no fourth connect attempt.
        self.assertEqual(dials_before, breaker.FAILURE_THRESHOLD)

    def test_one_dead_recorder_trips_once_for_all_its_channels(self):
        """Sixteen channels behind one unreachable box is one outage, not sixteen."""
        with patch.object(
            services, "open_driver", side_effect=RecorderUnreachable("down")
        ):
            for _ in range(breaker.FAILURE_THRESHOLD):
                self._live()

        with patch.object(services, "open_driver") as open_driver:
            response = self._live(self.other_camera)

        self.assertEqual(response.status_code, status.HTTP_503_SERVICE_UNAVAILABLE)
        open_driver.assert_not_called()

    def test_a_working_recorder_is_never_paused(self):
        with patch.object(services, "open_driver") as open_driver:
            open_driver.return_value = StubHikvision(target(), {})
            for _ in range(breaker.FAILURE_THRESHOLD + 3):
                response = self._live()
                self.assertEqual(response.status_code, status.HTTP_200_OK)
                # Drain so the producer thread unwinds with the test.
                next(iter(response.streaming_content))
                response.close()

    def test_a_success_clears_an_in_progress_run_of_failures(self):
        with patch.object(
            services, "open_driver", side_effect=RecorderUnreachable("down")
        ):
            for _ in range(breaker.FAILURE_THRESHOLD - 1):
                self._live()

        with patch.object(services, "open_driver") as open_driver:
            open_driver.return_value = StubHikvision(target(), {})
            response = self._live()
            next(iter(response.streaming_content))
            response.close()

        # The run is over, so the next failure starts counting from one and the
        # breaker must not open on it. Asked on the other channel of the same
        # recorder: same breaker, but a stream key the broker has not cached, so
        # the driver is genuinely dialled rather than served an open stream.
        with patch.object(
            services, "open_driver", side_effect=RecorderUnreachable("down")
        ) as open_driver:
            response = self._live(self.other_camera)
        self.assertEqual(response.status_code, 502)
        open_driver.assert_called_once()

    def test_a_live_stream_that_yields_no_video_trips_the_breaker(self):
        """The failure that actually happened, and the one the first cut missed.

        A live stream ending with zero frames surfaces as ``StreamError``, not
        as a connection error — so a breaker that counted only the latter would
        have watched all 18,160 of them go past.
        """
        with patch.object(
            views_module,
            "_start_stream",
            side_effect=StreamError("The recorder did not return any video."),
        ) as start_stream:
            for _ in range(breaker.FAILURE_THRESHOLD):
                self.assertEqual(self._live().status_code, 502)
            attempts_before = start_stream.call_count

            response = self._live()

        self.assertEqual(response.status_code, status.HTTP_503_SERVICE_UNAVAILABLE)
        self.assertEqual(response.data["code"], "recorder_cooling_down")
        self.assertEqual(attempts_before, breaker.FAILURE_THRESHOLD)

    def test_playback_with_no_footage_in_the_window_pauses_nothing(self):
        """Scrubbing into a gap is a normal answer, not an outage.

        Same exception class as the live failure above, deliberately treated
        differently: the box replied, it simply has nothing recorded then.
        Letting that pause live view would take working cameras down whenever
        someone dragged the timeline past the end of a recording.
        """
        playback = reverse(
            "surveillance-camera-playback", args=[self.camera.pk]
        )
        window = {
            "start": "2026-09-07T12:00:00Z",
            "end": "2026-09-07T12:00:30Z",
        }
        with patch.object(transcode, "ffmpeg_available", return_value=True), patch.object(
            views_module,
            "_start_stream",
            side_effect=StreamError("The recorder returned no footage for that time."),
        ):
            for _ in range(breaker.FAILURE_THRESHOLD + 2):
                self.assertEqual(
                    self.client.get(playback, window).status_code,
                    status.HTTP_404_NOT_FOUND,
                )

        with patch.object(services, "open_driver") as open_driver:
            open_driver.return_value = StubHikvision(target(), {})
            response = self._live()
        self.assertEqual(response.status_code, status.HTTP_200_OK)
        next(iter(response.streaming_content))
        response.close()

    def test_cooldown_lengthens_while_the_recorder_stays_down(self):
        first = breaker.cooldown_for(breaker.FAILURE_THRESHOLD)
        later = breaker.cooldown_for(breaker.FAILURE_THRESHOLD + 3)
        self.assertEqual(first, breaker.INITIAL_COOLDOWN_SECONDS)
        self.assertGreater(later, first)
        self.assertLessEqual(
            breaker.cooldown_for(breaker.FAILURE_THRESHOLD + 50),
            breaker.MAX_COOLDOWN_SECONDS,
        )

    def test_reset_lets_a_repaired_recorder_be_used_immediately(self):
        with patch.object(
            services, "open_driver", side_effect=RecorderUnreachable("down")
        ):
            for _ in range(breaker.FAILURE_THRESHOLD):
                self._live()
        self.assertEqual(self._live().status_code, 503)

        breaker.reset(self.recorder.pk)

        with patch.object(services, "open_driver") as open_driver:
            open_driver.return_value = StubHikvision(target(), {})
            response = self._live()
        self.assertEqual(response.status_code, status.HTTP_200_OK)
        next(iter(response.streaming_content))
        response.close()

    def test_editing_a_recorder_clears_its_cooldown(self):
        """The address may be exactly what was just corrected."""
        with patch.object(
            services, "open_driver", side_effect=RecorderUnreachable("down")
        ):
            for _ in range(breaker.FAILURE_THRESHOLD):
                self._live()
        self.assertEqual(self._live().status_code, 503)

        # Saving a recorder re-probes it; stubbed so the test neither reaches the
        # network nor waits out a connect timeout.
        with patch.object(
            services,
            "probe_recorder",
            return_value=services.ConnectionResult(
                info=None, channels=[], error="stubbed"
            ),
        ):
            response = self.client.patch(
                reverse("surveillance-recorder-detail", args=[self.recorder.pk]),
                {"host": "10.0.0.45"},
                format="json",
            )
        self.assertEqual(response.status_code, status.HTTP_200_OK)

        with patch.object(services, "open_driver") as open_driver:
            open_driver.return_value = StubHikvision(target(), {})
            live = self._live()
        self.assertEqual(live.status_code, status.HTTP_200_OK)
        next(iter(live.streaming_content))
        live.close()

    def test_a_broken_cache_fails_open(self):
        """A breaker that cannot read its own state must still let the shop try."""
        with patch.object(
            breaker.cache, "get", side_effect=RuntimeError("redis is down")
        ), patch.object(services, "open_driver") as open_driver:
            open_driver.return_value = StubHikvision(target(), {})
            response = self._live()
        self.assertEqual(response.status_code, status.HTTP_200_OK)
        next(iter(response.streaming_content))
        response.close()


class JpegDemuxTests(SimpleTestCase):
    """Where the frames on a wall come from.

    Every live and playback path funnels through ``_jpeg_frames``, so a framing
    mistake here is not one camera's problem — it is every camera, at every
    quality, which is exactly how it was reported from the field after 0.5.2.
    """

    @staticmethod
    def segment(marker: int, payload: bytes) -> bytes:
        return bytes([0xFF, marker]) + (len(payload) + 2).to_bytes(2, "big") + payload

    @classmethod
    def frame(cls, *, table: bytes = b"\x10" * 8, entropy: bytes = b"scan") -> bytes:
        return b"".join(
            [
                b"\xff\xd8",
                cls.segment(0xDB, table),
                cls.segment(0xDA, b"\x01\x00"),
                entropy,
                b"\xff\xd9",
            ]
        )

    def test_a_marker_inside_a_quantization_table_does_not_end_the_frame(self):
        """The grey-pixel bug, exactly.

        Quantization tables are raw bytes with no stuffing, so a table holding
        255 next to 217 contains a literal end-of-image marker. Scanning for
        ``FFD9`` cut the frame there and handed the decoder a header with no
        image behind it, which paints flat grey.
        """
        frame = self.frame(table=b"\x10\x10\xff\xd9\x10\x10")
        self.assertLess(
            frame.find(b"\xff\xd9") + 2,
            len(frame),
            "the fixture must actually contain an early FFD9",
        )

        self.assertEqual(_jpeg_frame_end(bytearray(frame)), len(frame))

    def test_stuffed_bytes_and_restart_markers_survive_the_scan(self):
        """Inside entropy data ``FF00`` is a literal 0xFF and ``FFD0``-``FFD7``
        are restart markers. Neither ends the image."""
        frame = self.frame(entropy=b"a\xff\x00b\xff\xd0c\xff\x00")

        self.assertEqual(_jpeg_frame_end(bytearray(frame)), len(frame))

    def test_a_frame_still_arriving_is_reported_incomplete_not_emitted(self):
        frame = self.frame()
        for cut in (2, 6, len(frame) - 3, len(frame) - 1):
            with self.subTest(cut=cut):
                self.assertEqual(_jpeg_frame_end(bytearray(frame[:cut])), -1)

    def test_two_frames_in_one_read_are_split_at_the_right_place(self):
        first = self.frame(table=b"\x10\xff\xd9\x10")
        second = self.frame(entropy=b"\xff\x00zz")
        buffer = bytearray(first + second)

        end = _jpeg_frame_end(buffer)
        self.assertEqual(end, len(first))
        del buffer[:end]
        self.assertEqual(_jpeg_frame_end(buffer), len(second))

    def test_rubbish_where_a_marker_belongs_is_refused_rather_than_emitted(self):
        # A resync point: better to drop this and hunt the next SOI than to ship
        # a frame we already know the decoder cannot finish.
        self.assertEqual(_jpeg_frame_end(bytearray(b"\xff\xd8zzzz")), -2)
        self.assertEqual(_jpeg_frame_end(bytearray(b"not a jpeg")), -2)


@override_settings(
    CACHES={
        "default": {
            "BACKEND": "django.core.cache.backends.locmem.LocMemCache",
            "LOCATION": "surveillance-capability-tests",
        }
    }
)
class CapabilityRoutingTests(TestCase):
    """Never ask a recorder a question its firmware cannot answer.

    A Xiongmai box has no still-image endpoint. The driver has always said so —
    ``supports_snapshot = False`` — but nothing consulted it, so any client
    asking for the snapshot path got routed onto hardware that cannot serve it.
    It failed every time, six seconds per attempt: 18,160 failures in three days
    at one shop, 82.9% of the backend's entire request time, and not one frame
    to show for it.
    """

    def setUp(self):
        ensure_role_groups()
        cache.clear()
        self.client = APIClient()
        user_model = get_user_model()
        self.manager = user_model.objects.create_user(
            username="caps-manager", password="pass1234"
        )
        self.manager.groups.add(
            *self.manager.groups.model.objects.filter(name=MANAGER_GROUP)
        )
        self.client.force_authenticate(self.manager)
        self.recorder = Recorder.objects.create(
            host="10.0.0.77",
            username="admin",
            password="secret",
            detected_brand="xiongmai",
            status=Recorder.Status.OK,
        )
        self.camera = Camera.objects.create(
            recorder=self.recorder, channel=1, name="الصندوق"
        )

    def tearDown(self):
        cache.clear()

    def test_the_recorder_that_started_this_declares_no_snapshot(self):
        self.assertFalse(self.recorder.driver_capabilities["snapshot"])

    def test_a_snapshotless_recorder_is_routed_to_rtsp_even_when_asked_not_to(self):
        """`smooth=false` asks for a path this hardware does not have. Honouring
        it would only choose a guaranteed failure, so the policy overrides it."""
        smooth, _fps = resolve_live_stream(
            None, "false", ffmpeg_available=True, supports_snapshot=False
        )
        self.assertTrue(smooth)

    def test_a_recorder_with_snapshots_still_honours_the_request(self):
        smooth, fps = resolve_live_stream(
            "8", "false", ffmpeg_available=True, supports_snapshot=True
        )
        self.assertFalse(smooth)
        self.assertLessEqual(fps, MAX_SNAPSHOT_FPS)

    def test_no_snapshot_and_no_ffmpeg_is_refused_at_once(self):
        """The honest answer, immediately — not six seconds of pretending."""
        with patch.object(transcode, "ffmpeg_available", return_value=False), patch.object(
            services, "open_driver"
        ) as open_driver:
            response = self.client.get(
                reverse("surveillance-camera-live", args=[self.camera.pk]),
                {"fps": 1},
            )

        self.assertEqual(response.status_code, status.HTTP_503_SERVICE_UNAVAILABLE)
        self.assertIn("ffmpeg", response.data["detail"])
        open_driver.assert_not_called()

    def test_the_poster_frame_refuses_without_dialling_the_box(self):
        with patch.object(services, "open_driver") as open_driver:
            response = self.client.get(
                reverse("surveillance-camera-snapshot", args=[self.camera.pk])
            )

        self.assertEqual(response.status_code, status.HTTP_501_NOT_IMPLEMENTED)
        open_driver.assert_not_called()

    def test_a_capability_refusal_costs_no_retries_and_no_sleeps(self):
        """The 6,017 ms in the field was 1s + 2s + 3s of backoff, spent
        rediscovering a fact the driver already knew."""

        class _NoSnapshots:
            def __init__(self):
                self.calls = 0
                self.closed = False

            def snapshot(self, channel, *, quality):
                self.calls += 1
                raise RecorderCapabilityError("no snapshot endpoint")

            def close(self):
                self.closed = True

        driver = _NoSnapshots()
        source = SnapshotSource(driver, channel=1, fps=2)
        started = time.monotonic()

        with self.assertRaises(StreamError):
            next(iter(source.frames(lambda: False)))

        self.assertEqual(driver.calls, 1, "asked once, not four times")
        self.assertLess(time.monotonic() - started, 0.5, "and without sleeping")
        self.assertTrue(driver.closed)
