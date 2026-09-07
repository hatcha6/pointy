"""Tests for the DVR integration.

Nothing here talks to a recorder. The driver tests drive real firmware payloads
captured from Hikvision and Dahua boxes through the parsers, the broker tests
use a fake source, and the view tests stub the driver — so the suite proves the
parts that break in the field (URL shapes, clock offsets, fan-out, gating)
without needing a camera on the LAN.
"""

import time
from datetime import datetime, timedelta, timezone as dt_timezone
from unittest.mock import patch

from django.contrib.auth import get_user_model
from django.test import TestCase, override_settings
from django.urls import reverse
from django.utils import timezone
from rest_framework import status
from rest_framework.test import APIClient

from apps.core.models import ShopSettings
from apps.core.roles import MANAGER_GROUP, SUPERVISOR_GROUP, ensure_role_groups
from apps.sales.models import Order

from . import services, transcode
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
from .streaming import FfmpegSource, Frame, FrameBroker, StreamError

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
