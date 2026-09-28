"""FTP-uploaded footage: reading names, measuring clocks, deciding what to keep,
holding the archive to its budget, and playing it back.

The ingest tests put real files in a temporary footage root and drive a real
pass; nothing is mocked but the clock. The video tests need ffmpeg (the shipped
image has it) and are skipped without it — the picture path, which is what a
Hikvision uploads, needs no ffmpeg and always runs.
"""

from __future__ import annotations

import io
import os
import shutil
import subprocess
import tempfile
import unittest
from datetime import datetime, timedelta, timezone as dt_timezone
from pathlib import Path
from unittest.mock import patch

from django.contrib.auth import get_user_model
from django.test import SimpleTestCase, TestCase, override_settings
from django.urls import reverse
from django.utils import timezone
from PIL import Image
from rest_framework import status
from rest_framework.test import APIClient

from apps.core.models import ShopSettings
from apps.core.roles import CASHIER_GROUP, MANAGER_GROUP, ensure_role_groups
from apps.sales.models import Order

from . import transcode
from .archive import clock, housekeeping, ingest, media, naming, playback, retention, storage
from .archive.uploads import upload_row
from .ftp import accounts
from .ftp import status as ftp_status
from .models import Camera, FootageClip, FootageUpload, FtpAccount, Recorder

UTC = dt_timezone.utc


def jpeg_bytes(color="red", size=(64, 48)) -> bytes:
    buffer = io.BytesIO()
    Image.new("RGB", size, color).save(buffer, "JPEG")
    return buffer.getvalue()


def make_video(path: Path, seconds: int, *, fps: int = 10, gop: int = 10) -> None:
    """A real H.264 file with a keyframe every ``gop`` frames."""
    path.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(
        [
            transcode.ffmpeg_path(),
            "-hide_banner",
            "-loglevel",
            "error",
            "-y",
            "-f",
            "lavfi",
            "-i",
            f"testsrc=duration={seconds}:size=160x120:rate={fps}",
            "-c:v",
            "libx264" if transcode.video_encoder() == "libx264" else "mpeg4",
            "-g",
            str(gop),
            "-keyint_min",
            str(gop),
            "-sc_threshold",
            "0",
            "-bf",
            "0",
            "-pix_fmt",
            "yuv420p",
            str(path),
        ],
        check=True,
        capture_output=True,
    )


def has_ffmpeg() -> bool:
    transcode.reset_probe_cache()
    return media.available()


# ---------------------------------------------------------------------------
# Names
# ---------------------------------------------------------------------------
class UploadNameTests(SimpleTestCase):
    def test_a_dahua_recording_names_its_channel_and_its_span(self):
        parsed = naming.parse_upload_path(
            "192.168.1.108/2026-09-27/001/dav/14/14.00.00-14.15.00[R][0@0][0].dav"
        )
        self.assertEqual(parsed.kind, naming.KIND_VIDEO)
        self.assertEqual(parsed.source_key, "ch:1")
        self.assertEqual(parsed.wall_start, datetime(2026, 9, 27, 14, 0, 0))
        self.assertEqual(parsed.wall_end, datetime(2026, 9, 27, 14, 15, 0))

    def test_a_segment_across_midnight_ends_the_next_day(self):
        parsed = naming.parse_upload_path(
            "2026-09-27/001/dav/23/23.50.00-00.05.00[R][0@0][0].dav"
        )
        self.assertEqual(parsed.wall_end, datetime(2026, 9, 28, 0, 5, 0))

    def test_a_dahua_snapshot_takes_its_day_from_the_folder(self):
        parsed = naming.parse_upload_path(
            "192.168.1.108/2026-09-27/002/jpg/14/14.03.11[M][0@0][0].jpg"
        )
        self.assertEqual(parsed.kind, naming.KIND_PICTURE)
        self.assertEqual(parsed.channel, 2)
        self.assertEqual(parsed.wall_start, datetime(2026, 9, 27, 14, 3, 11))
        self.assertIsNone(parsed.wall_end)

    def test_a_hikvision_picture_names_channel_and_moment_to_the_millisecond(self):
        parsed = naming.parse_upload_path(
            "DVR/Camera 03/192.168.1.64_03_20260927140311123_TIMING.jpg"
        )
        self.assertEqual(parsed.source_key, "ch:3")
        self.assertEqual(parsed.wall_start, datetime(2026, 9, 27, 14, 3, 11, 123000))

    def test_the_address_in_a_name_is_not_read_as_a_time(self):
        parsed = naming.parse_upload_path("2026-09-27/10.20.30.40_note.jpg")
        self.assertIsNone(parsed.wall_start)

    def test_channel_markers_in_names_and_folders(self):
        self.assertEqual(naming.parse_upload_path("ch02_2026-09-27_14-03-11.mp4").channel, 2)
        self.assertEqual(naming.parse_upload_path("Camera1_00_20260927140000.mp4").channel, 1)
        self.assertEqual(naming.parse_upload_path("NVR/channel 7/clip.mp4").channel, 7)

    def test_a_marker_needs_a_word_boundary(self):
        # "match12" is not channel 12.
        self.assertEqual(naming.parse_upload_path("match12.jpg").source_key, "ch:1")

    def test_a_camera_named_by_its_folder(self):
        parsed = naming.parse_upload_path(
            "NVR/Front  Door/2026-09-27/20260927140000_20260927141500.mp4"
        )
        self.assertIsNone(parsed.channel)
        self.assertEqual(parsed.source_key, "dir:front door")
        self.assertEqual(parsed.source_label, "Front  Door")
        self.assertEqual(parsed.wall_end, datetime(2026, 9, 27, 14, 15, 0))

    def test_generic_folders_do_not_name_a_camera(self):
        parsed = naming.parse_upload_path("upload/pictures/20260927_140311.jpg")
        self.assertEqual(parsed.source_key, "ch:1")
        self.assertEqual(parsed.wall_start, datetime(2026, 9, 27, 14, 3, 11))

    def test_nothing_to_go_on_is_channel_one_with_no_time(self):
        parsed = naming.parse_upload_path("snapshot.jpg")
        self.assertEqual(parsed.source_key, "ch:1")
        self.assertIsNone(parsed.wall_start)

    def test_implausible_years_are_not_times(self):
        self.assertIsNone(naming.parse_upload_path("19700101000000.jpg").wall_start)

    def test_kinds_and_raw_formats(self):
        self.assertEqual(naming.kind_of("a/b.DAV"), naming.KIND_VIDEO)
        self.assertEqual(naming.kind_of("a/b.JPEG"), naming.KIND_PICTURE)
        self.assertEqual(naming.kind_of("a/b.idx"), naming.KIND_OTHER)
        self.assertEqual(naming.kind_of("noext"), naming.KIND_OTHER)
        self.assertEqual(naming.raw_format_of("x.h264"), "h264")
        self.assertEqual(naming.raw_format_of("x.265"), "hevc")
        self.assertEqual(naming.raw_format_of("x.mp4"), "")


# ---------------------------------------------------------------------------
# Clock
# ---------------------------------------------------------------------------
class ClockTests(SimpleTestCase):
    received = datetime(2026, 9, 27, 12, 0, 40, tzinfo=UTC)

    def test_a_reading_is_the_offset_less_the_latency_snapped(self):
        # Device on Libyan time (UTC+2); the file ended 40s before it arrived.
        wall_end = datetime(2026, 9, 27, 14, 0, 0)
        self.assertEqual(clock.reading(wall_end, self.received), 120)

    def test_an_absurd_reading_is_no_reading(self):
        self.assertIsNone(clock.reading(datetime(2000, 1, 1), self.received))

    def test_the_first_reading_is_adopted_outright(self):
        state = clock.ClockState(offset_minutes=120, measured=False)
        after = clock.advance(state, [0], self.received)
        self.assertEqual(after, clock.ClockState(offset_minutes=0, measured=True))

    def test_a_higher_reading_is_adopted_at_once(self):
        state = clock.ClockState(offset_minutes=60, measured=True)
        self.assertEqual(clock.advance(state, [60, 120], self.received).offset_minutes, 120)

    def test_a_lower_reading_waits_for_sustained_agreement(self):
        start = self.received
        state = clock.ClockState(offset_minutes=120, measured=True)
        state = clock.advance(state, [60], start)
        self.assertEqual(state.offset_minutes, 120)
        self.assertEqual(state.lower_minutes, 60)
        state = clock.advance(state, [45, 60], start + timedelta(hours=3))
        self.assertEqual(state.offset_minutes, 120)
        state = clock.advance(state, [60], start + clock.LOWER_AFTER)
        self.assertEqual(state, clock.ClockState(offset_minutes=60, measured=True))

    def test_one_punctual_upload_cancels_a_lowering(self):
        # The backlog case: late uploads read low, then a fresh one arrives.
        state = clock.ClockState(offset_minutes=120, measured=True)
        state = clock.advance(state, [0, 15, 30], self.received)
        self.assertIsNotNone(state.lower_since)
        state = clock.advance(state, [120], self.received + timedelta(hours=1))
        self.assertEqual(state, clock.ClockState(offset_minutes=120, measured=True))

    def test_no_readings_change_nothing(self):
        state = clock.ClockState(offset_minutes=120, measured=True)
        self.assertIs(clock.advance(state, [None], self.received), state)

    def test_wall_to_utc(self):
        self.assertEqual(
            clock.to_utc(datetime(2026, 9, 27, 14, 0), 120),
            datetime(2026, 9, 27, 12, 0, tzinfo=UTC),
        )

    def test_an_unmeasured_recorder_is_assumed_on_shop_time(self):
        with override_settings(POINTY_BUSINESS_TIMEZONE="Africa/Tripoli"):
            self.assertEqual(clock.assumed_offset_minutes(self.received), 120)


# ---------------------------------------------------------------------------
# Windows
# ---------------------------------------------------------------------------
class RetentionWindowTests(SimpleTestCase):
    t0 = datetime(2026, 9, 27, 12, 0, tzinfo=UTC)

    def test_close_windows_merge(self):
        merged = retention.merge(
            [
                (self.t0, self.t0 + timedelta(seconds=10)),
                (self.t0 + timedelta(seconds=20), self.t0 + timedelta(seconds=30)),
                (self.t0 + timedelta(minutes=5), self.t0 + timedelta(minutes=6)),
            ]
        )
        self.assertEqual(len(merged), 2)
        self.assertEqual(merged[0], (self.t0, self.t0 + timedelta(seconds=30)))

    def test_clip_and_coverage(self):
        windows = [(self.t0 + timedelta(seconds=30), self.t0 + timedelta(seconds=90))]
        clipped = retention.clip_to(windows, self.t0, self.t0 + timedelta(seconds=60))
        self.assertEqual(clipped, [(self.t0 + timedelta(seconds=30), self.t0 + timedelta(seconds=60))])
        self.assertAlmostEqual(
            retention.coverage(windows, self.t0, self.t0 + timedelta(seconds=60)), 0.5
        )

    def test_the_decision_waits_past_the_pre_roll(self):
        received = self.t0
        pre = timedelta(seconds=30)
        self.assertEqual(
            retention.decide_after(received, pre), received + pre + retention.COMMIT_GRACE
        )
        self.assertEqual(
            retention.decide_after(received, pre, partial=True),
            received + pre + retention.COMMIT_GRACE + retention.PARTIAL_GRACE,
        )


class RetentionMomentTests(TestCase):
    def test_till_orders_and_returns_count_account_entries_do_not(self):
        start = timezone.now() - timedelta(minutes=1)
        sale = Order.objects.create()
        quote = Order.objects.create(sale_type=Order.SaleType.QUOTATION)
        Order.objects.create(sale_type=Order.SaleType.ACCOUNT_ENTRY)
        moments = retention.moments_between(start, timezone.now() + timedelta(minutes=1))
        self.assertEqual(sorted(moments), sorted([sale.created_at, quote.created_at]))


# ---------------------------------------------------------------------------
# Ingest
# ---------------------------------------------------------------------------
class _FootageRootMixin:
    def setUp(self):
        super().setUp()
        self._root = tempfile.mkdtemp(prefix="pointy-footage-")
        self._override = override_settings(POINTY_FOOTAGE_ROOT=self._root)
        self._override.enable()
        storage.ensure_tree()

    def tearDown(self):
        self._override.disable()
        shutil.rmtree(self._root, ignore_errors=True)
        super().tearDown()

    def make_recorder(self, *, offset=120, measured=True) -> Recorder:
        recorder = Recorder.objects.create(
            connection=Recorder.Connection.FTP,
            name="FTP",
            clock_offset_minutes=offset,
            clock_offset_is_measured=measured,
        )
        accounts.create_account(recorder, advertised_host="192.168.1.10")
        return recorder

    def upload(self, recorder, relative, data, *, received_at, complete=True) -> FootageUpload:
        path = storage.ensure_inbox(recorder.pk) / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
        row = upload_row(
            recorder.pk,
            relative,
            size=len(data),
            received_at=received_at,
            peer="192.168.1.108",
            complete=complete,
            decide_at=received_at,
        )
        row.save()
        return row

    @staticmethod
    def wall(moment: datetime, offset=120) -> str:
        """``moment`` (UTC) as a device on ``offset`` names it."""
        local = moment.astimezone(UTC).replace(tzinfo=None) + timedelta(minutes=offset)
        return local.strftime("%Y%m%d%H%M%S")


class PictureIngestTests(_FootageRootMixin, TestCase):
    def setUp(self):
        super().setUp()
        self.recorder = self.make_recorder()
        self.now = timezone.now().replace(microsecond=0)

    def run_pass(self, at=None):
        return ingest.run_pass(now=at or self.now + timedelta(minutes=10))

    def test_a_picture_inside_an_invoice_window_is_kept(self):
        order = Order.objects.create()
        taken = order.created_at + timedelta(seconds=5)
        name = f"192.168.1.64_01_{self.wall(taken)}000_TIMING.jpg"
        self.upload(self.recorder, name, jpeg_bytes(), received_at=taken + timedelta(seconds=1))

        report = self.run_pass()

        self.assertEqual((report.kept, report.discarded), (1, 0))
        clip = FootageClip.objects.get()
        self.assertEqual(clip.kind, FootageClip.Kind.PICTURE)
        self.assertEqual(clip.start.replace(microsecond=0), taken.replace(microsecond=0))
        self.assertTrue(storage.archive_file(clip.path).exists())
        self.assertFalse((storage.inbox_dir(self.recorder.pk) / name).exists())
        self.assertFalse(FootageUpload.objects.exists())
        account = FtpAccount.objects.get(recorder=self.recorder)
        self.assertEqual(account.files_kept, 1)

    def test_a_picture_nobody_bought_anything_in_front_of_is_deleted(self):
        Order.objects.create()
        taken = self.now - timedelta(hours=2)
        name = f"192.168.1.64_01_{self.wall(taken)}000_TIMING.jpg"
        self.upload(self.recorder, name, jpeg_bytes(), received_at=taken + timedelta(seconds=1))

        report = self.run_pass()

        self.assertEqual((report.kept, report.discarded), (0, 1))
        self.assertFalse(FootageClip.objects.exists())
        self.assertFalse((storage.inbox_dir(self.recorder.pk) / name).exists())

    def test_a_new_source_becomes_a_checkout_camera(self):
        order = Order.objects.create()
        name = f"192.168.1.64_04_{self.wall(order.created_at)}000_TIMING.jpg"
        self.upload(self.recorder, name, jpeg_bytes(), received_at=order.created_at)

        self.run_pass()

        camera = Camera.objects.get(recorder=self.recorder)
        self.assertEqual((camera.channel, camera.source_key), (4, "ch:4"))
        self.assertTrue(camera.covers_checkout)
        self.assertFalse(camera.supports_live)
        self.recorder.refresh_from_db()
        self.assertEqual(self.recorder.channel_count, 1)

    def test_a_camera_switched_off_the_checkout_keeps_nothing(self):
        order = Order.objects.create()
        Camera.objects.create(
            recorder=self.recorder, channel=1, source_key="ch:1", covers_checkout=False
        )
        name = f"192.168.1.64_01_{self.wall(order.created_at)}000_TIMING.jpg"
        self.upload(self.recorder, name, jpeg_bytes(), received_at=order.created_at)

        report = self.run_pass()

        self.assertEqual(report.discarded, 1)
        self.assertFalse(FootageClip.objects.exists())

    def test_an_upload_is_not_decided_before_its_time(self):
        order = Order.objects.create()
        name = f"192.168.1.64_01_{self.wall(order.created_at)}000_TIMING.jpg"
        row = self.upload(self.recorder, name, jpeg_bytes(), received_at=order.created_at)
        FootageUpload.objects.filter(pk=row.pk).update(decide_after=self.now + timedelta(hours=1))

        report = self.run_pass(at=self.now)

        self.assertEqual(report.claimed, 0)
        self.assertTrue((storage.inbox_dir(self.recorder.pk) / name).exists())

    def test_a_picture_with_no_time_in_its_name_is_placed_by_its_arrival(self):
        order = Order.objects.create()
        self.upload(self.recorder, "snapshot.jpg", jpeg_bytes(), received_at=order.created_at)

        report = self.run_pass()

        self.assertEqual(report.kept, 1)

    def test_a_picture_that_is_not_a_jpeg_is_given_up_on(self):
        order = Order.objects.create()
        name = f"192.168.1.64_01_{self.wall(order.created_at)}000_TIMING.jpg"
        self.upload(self.recorder, name, b"not a picture", received_at=order.created_at)

        report = self.run_pass()

        self.assertEqual(report.unreadable, 1)
        account = FtpAccount.objects.get(recorder=self.recorder)
        self.assertEqual(account.files_unreadable, 1)
        self.assertIn("JPEG", account.last_ingest_error)

    def test_files_that_are_not_footage_are_discarded(self):
        self.upload(self.recorder, "test.txt", b"hello", received_at=self.now)
        report = self.run_pass()
        self.assertEqual(report.discarded, 1)

    def test_a_file_the_dvr_deleted_just_drops_its_row(self):
        row = self.upload(self.recorder, "gone.jpg", jpeg_bytes(), received_at=self.now)
        (storage.inbox_dir(self.recorder.pk) / "gone.jpg").unlink()
        self.run_pass()
        self.assertFalse(FootageUpload.objects.filter(pk=row.pk).exists())

    def test_a_disabled_recorder_keeps_nothing(self):
        order = Order.objects.create()
        Recorder.objects.filter(pk=self.recorder.pk).update(is_enabled=False)
        self.upload(self.recorder, "snapshot.jpg", jpeg_bytes(), received_at=order.created_at)
        report = self.run_pass()
        self.assertEqual(report.discarded, 1)

    def test_the_first_upload_measures_the_recorder_clock(self):
        Recorder.objects.filter(pk=self.recorder.pk).update(
            clock_offset_minutes=120, clock_offset_is_measured=False
        )
        order = Order.objects.create()
        # This DVR was left on UTC: its names read two hours behind Libya.
        name = f"192.168.1.64_01_{self.wall(order.created_at, offset=0)}000_TIMING.jpg"
        self.upload(self.recorder, name, jpeg_bytes(), received_at=order.created_at + timedelta(seconds=2))

        report = self.run_pass()

        self.recorder.refresh_from_db()
        self.assertEqual(self.recorder.clock_offset_minutes, 0)
        self.assertTrue(self.recorder.clock_offset_is_measured)
        self.assertEqual(report.kept, 1)

    def test_a_slow_upload_of_a_finished_segment_does_not_skew_the_clock(self):
        # An hour of footage that took twenty minutes to arrive: reading the
        # clock at the finish would put the DVR a quarter hour behind.
        Recorder.objects.filter(pk=self.recorder.pk).update(clock_offset_is_measured=False)
        segment_end = self.now - timedelta(minutes=20)
        local_start = (segment_end - timedelta(hours=1)).replace(tzinfo=None) + timedelta(hours=2)
        local_end = segment_end.replace(tzinfo=None) + timedelta(hours=2)
        name = (
            f"{local_start:%Y-%m-%d}/001/dav/{local_start:%H}/"
            f"{local_start:%H.%M.%S}-{local_end:%H.%M.%S}[R][0@0][0].dav"
        )
        row = self.upload(self.recorder, name, b"\x00" * 64, received_at=self.now)
        FootageUpload.objects.filter(pk=row.pk).update(transfer_seconds=20 * 60)
        self.run_pass()
        self.recorder.refresh_from_db()
        self.assertEqual(self.recorder.clock_offset_minutes, 120)

    def test_where_footage_ended_follows_how_it_was_sent(self):
        row = FootageUpload(received_at=self.now, transfer_seconds=600)
        self.assertEqual(ingest._footage_ended(row, 3600), self.now - timedelta(seconds=600))
        # Sent as it was recorded: the transfer lasted as long as the footage.
        row.transfer_seconds = 3500
        self.assertEqual(ingest._footage_ended(row, 3600), self.now)
        # Nothing to compare against: the finish, which is never too early.
        self.assertEqual(ingest._footage_ended(row, None), self.now)

    def test_a_claim_taken_back_by_a_new_upload_is_left_alone(self):
        order = Order.objects.create()
        name = f"192.168.1.64_01_{self.wall(order.created_at)}000_TIMING.jpg"
        self.upload(self.recorder, name, jpeg_bytes(), received_at=order.created_at)
        with patch.object(ingest, "_still_ours", return_value=False):
            self.run_pass()
        self.assertTrue((storage.inbox_dir(self.recorder.pk) / name).exists())
        self.assertFalse(FootageClip.objects.exists())

    def test_stale_claims_go_back_to_the_queue(self):
        row = self.upload(self.recorder, "a.jpg", jpeg_bytes(), received_at=self.now)
        FootageUpload.objects.filter(pk=row.pk).update(
            status=FootageUpload.Status.CLAIMED,
            claim_token="dead",
            claimed_at=timezone.now() - timedelta(hours=1),
        )
        self.assertEqual(ingest.release_stale_claims(), 1)
        row.refresh_from_db()
        self.assertEqual((row.status, row.attempts), (FootageUpload.Status.PENDING, 1))


@unittest.skipUnless(has_ffmpeg(), "needs ffmpeg")
class VideoIngestTests(_FootageRootMixin, TestCase):
    def setUp(self):
        super().setUp()
        self.recorder = self.make_recorder()
        self.start = (timezone.now() - timedelta(minutes=5)).replace(microsecond=0)

    def dahua_name(self, start, end) -> str:
        local_start = start.replace(tzinfo=None) + timedelta(hours=2)
        local_end = end.replace(tzinfo=None) + timedelta(hours=2)
        return (
            f"192.168.1.108/{local_start:%Y-%m-%d}/001/dav/{local_start:%H}/"
            f"{local_start:%H.%M.%S}-{local_end:%H.%M.%S}[R][0@0][0].mp4"
        )

    def upload_video(self, seconds, name=None, received_at=None):
        end = self.start + timedelta(seconds=seconds)
        relative = name or self.dahua_name(self.start, end)
        target = storage.ensure_inbox(self.recorder.pk) / relative
        make_video(target, seconds)
        row = upload_row(
            self.recorder.pk,
            relative,
            size=target.stat().st_size,
            received_at=received_at or end + timedelta(seconds=3),
            peer="192.168.1.108",
            complete=True,
            decide_at=end,
        )
        row.save()
        return target

    def test_only_the_invoice_window_is_cut_out(self):
        order = Order.objects.create()
        Order.objects.filter(pk=order.pk).update(created_at=self.start + timedelta(seconds=150))
        source = self.upload_video(300)

        report = ingest.run_pass(now=timezone.now() + timedelta(minutes=10))

        self.assertEqual(report.kept, 1, report.errors)
        self.assertFalse(source.exists())
        clip = FootageClip.objects.get()
        pre, post = retention.rolls()
        moment = self.start + timedelta(seconds=150)
        # Cut from the keyframe at or before the window: never late, at most a
        # GOP (1s here) early; and it runs to the end of the window.
        self.assertLessEqual(clip.start, moment - pre)
        self.assertGreaterEqual(clip.start, moment - pre - timedelta(seconds=1.5))
        self.assertGreaterEqual(clip.end, moment + post - timedelta(seconds=0.5))
        self.assertLess(clip.end - clip.start, timedelta(seconds=150))
        info = media.probe(storage.archive_file(clip.path))
        self.assertAlmostEqual(info.duration, (clip.end - clip.start).total_seconds(), delta=0.5)

    def test_a_mostly_wanted_file_is_kept_whole(self):
        order = Order.objects.create()
        Order.objects.filter(pk=order.pk).update(created_at=self.start + timedelta(seconds=30))
        self.upload_video(60)

        ingest.run_pass(now=timezone.now() + timedelta(minutes=10))

        clip = FootageClip.objects.get()
        self.assertEqual(clip.start, self.start)
        self.assertAlmostEqual((clip.end - clip.start).total_seconds(), 60, delta=0.5)

    def test_an_unwanted_video_is_deleted_without_being_opened(self):
        source = self.upload_video(60)
        with patch.object(media, "remux_to_matroska") as remux:
            report = ingest.run_pass(now=timezone.now() + timedelta(minutes=10))
        remux.assert_not_called()
        self.assertEqual(report.discarded, 1)
        self.assertFalse(source.exists())

    def test_a_video_with_no_times_is_placed_by_its_arrival(self):
        arrived = self.start + timedelta(seconds=60)
        order = Order.objects.create()
        Order.objects.filter(pk=order.pk).update(created_at=arrived - timedelta(seconds=30))
        self.upload_video(60, name="clip.mp4", received_at=arrived)

        ingest.run_pass(now=timezone.now() + timedelta(minutes=10))

        clip = FootageClip.objects.get()
        self.assertAlmostEqual((clip.start - self.start).total_seconds(), 0, delta=0.5)

    def test_a_video_that_will_not_read_is_retried_then_dropped(self):
        order = Order.objects.create()
        relative = self.dahua_name(order.created_at - timedelta(seconds=30), order.created_at + timedelta(seconds=30))
        target = storage.ensure_inbox(self.recorder.pk) / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(b"\x00" * 4096)
        upload_row(
            self.recorder.pk,
            relative,
            size=4096,
            received_at=order.created_at + timedelta(seconds=31),
            peer="",
            complete=True,
            decide_at=order.created_at,
        ).save()
        later = timezone.now() + timedelta(hours=1)
        for _ in range(ingest.MAX_ATTEMPTS):
            ingest.run_pass(now=later)
            later += timedelta(hours=1)
        self.assertFalse(FootageUpload.objects.exists())
        self.assertFalse(target.exists())
        self.assertEqual(FtpAccount.objects.get(recorder=self.recorder).files_unreadable, 1)

    def test_kept_video_plays_back_and_exports(self):
        order = Order.objects.create()
        Order.objects.filter(pk=order.pk).update(created_at=self.start + timedelta(seconds=30))
        self.upload_video(60)
        ingest.run_pass(now=timezone.now() + timedelta(minutes=10))
        camera = Camera.objects.get(recorder=self.recorder)

        source = playback.ArchiveSource(
            camera, self.start + timedelta(seconds=10), self.start + timedelta(seconds=12), fps=5
        )
        frames = list(source.frames(lambda: False))
        self.assertGreaterEqual(len(frames), 8)
        self.assertEqual(frames[0].captured_at, self.start + timedelta(seconds=10))
        self.assertEqual(frames[0].data[:2], b"\xff\xd8")

        still = playback.still(camera, self.start + timedelta(seconds=20))
        self.assertEqual(still[:2], b"\xff\xd8")

        export = playback.start_export(camera, self.start, self.start + timedelta(seconds=20))
        export.prime()
        data = b"".join(export.chunks())
        self.assertIn(b"ftyp", data[:64])


# ---------------------------------------------------------------------------
# Housekeeping
# ---------------------------------------------------------------------------
class HousekeepingTests(_FootageRootMixin, TestCase):
    def setUp(self):
        super().setUp()
        self.recorder = self.make_recorder()
        self.camera = Camera.objects.create(
            recorder=self.recorder, channel=1, source_key="ch:1", covers_checkout=True
        )

    def clip(self, start, size=1000) -> FootageClip:
        relative, absolute = storage.new_archive_path(self.camera.pk, start, ".jpg")
        absolute.write_bytes(b"\xff\xd8" + b"\x00" * (size - 2))
        return FootageClip.objects.create(
            camera=self.camera,
            kind=FootageClip.Kind.PICTURE,
            start=start,
            end=start,
            path=relative,
            size_bytes=size,
        )

    def test_clips_past_retention_are_deleted_with_their_files(self):
        settings = ShopSettings.load()
        settings.surveillance_archive_retention_days = 7
        settings.save()
        now = timezone.now()
        old = self.clip(now - timedelta(days=8))
        young = self.clip(now - timedelta(days=6))

        self.assertEqual(housekeeping.expire_by_age(now), 1)

        self.assertFalse(FootageClip.objects.filter(pk=old.pk).exists())
        self.assertFalse(storage.archive_root().joinpath(*old.path.split("/")).exists())
        self.assertTrue(FootageClip.objects.filter(pk=young.pk).exists())

    def test_the_oldest_clips_go_when_the_archive_is_over_budget(self):
        now = timezone.now()
        oldest = self.clip(now - timedelta(days=3), size=4000)
        middle = self.clip(now - timedelta(days=2), size=4000)
        newest = self.clip(now - timedelta(days=1), size=4000)
        budget = storage.DiskBudget(
            total=10**12, free=10**11, min_free=0, archive_limit=8500, inbox_limit=10**9
        )
        with patch.object(storage, "disk_budget", return_value=budget):
            housekeeping.enforce_disk_budget()
        remaining = set(FootageClip.objects.values_list("pk", flat=True))
        self.assertNotIn(oldest.pk, remaining)
        self.assertEqual(remaining, {middle.pk, newest.pk})

    def test_the_disk_floor_prunes_even_a_small_archive(self):
        self.clip(timezone.now() - timedelta(days=1))
        budgets = iter(
            [
                storage.DiskBudget(total=10**12, free=1, min_free=10, archive_limit=10**12, inbox_limit=10**9),
                storage.DiskBudget(total=10**12, free=100, min_free=10, archive_limit=10**12, inbox_limit=10**9),
            ]
        )
        with patch.object(storage, "disk_budget", side_effect=lambda *a, **k: next(budgets)):
            self.assertEqual(housekeeping.enforce_disk_budget(), 1)

    def test_an_unreported_upload_is_adopted_after_an_hour(self):
        inbox = storage.ensure_inbox(self.recorder.pk)
        stale = inbox / "2026-09-27" / "stale.jpg"
        stale.parent.mkdir(parents=True)
        stale.write_bytes(jpeg_bytes())
        old = (timezone.now() - timedelta(hours=2)).timestamp()
        os.utime(stale, (old, old))
        fresh = inbox / "fresh.jpg"
        fresh.write_bytes(jpeg_bytes())

        self.assertEqual(housekeeping.adopt_orphan_uploads(timezone.now()), 1)

        row = FootageUpload.objects.get()
        self.assertEqual(row.path, "2026-09-27/stale.jpg")
        self.assertEqual(row.kind, FootageUpload.Kind.PICTURE)

    def test_leftovers_of_deleted_recorders_and_cameras_go(self):
        (storage.inbox_root() / "999").mkdir()
        (storage.archive_root() / "888").mkdir()
        storage.ensure_inbox(self.recorder.pk)
        self.assertEqual(housekeeping.remove_leftovers(), 2)
        self.assertTrue(storage.inbox_dir(self.recorder.pk).exists())

    def test_a_factory_reset_takes_the_clip_files_with_the_rows(self):
        from apps.core.factory_reset import _stored_files_to_discard

        clip = self.clip(timezone.now())
        self.assertIn(storage.archive_file(clip.path), _stored_files_to_discard())

    def test_rows_whose_file_vanished_are_forgotten(self):
        clip = self.clip(timezone.now())
        storage.archive_file(clip.path).unlink()
        housekeeping._existence_cursor = 0
        self.assertEqual(housekeeping.forget_missing_clips(), 1)


# ---------------------------------------------------------------------------
# API
# ---------------------------------------------------------------------------
class FtpApiTests(_FootageRootMixin, TestCase):
    def setUp(self):
        super().setUp()
        ensure_role_groups()
        user_model = get_user_model()
        self.manager = user_model.objects.create_user(username="manager", password="pass1234")
        self.manager.groups.add(*self.manager.groups.model.objects.filter(name=MANAGER_GROUP))
        self.client = APIClient()
        self.client.force_authenticate(self.manager)
        ftp_status.clear()

    def create_ftp(self, **extra):
        with patch("apps.surveillance.services.probe_recorder") as probe:
            response = self.client.post(
                reverse("surveillance-recorder-list"),
                {"connection": "ftp", "name": "المخزن", "ftp_host": "192.168.1.10", **extra},
                format="json",
            )
        probe.assert_not_called()
        return response

    def test_an_ftp_setup_is_created_with_generated_credentials(self):
        response = self.create_ftp()

        self.assertEqual(response.status_code, status.HTTP_201_CREATED, response.data)
        ftp = response.data["ftp"]
        self.assertRegex(ftp["username"], r"^cam\d{4}$")
        self.assertEqual(len(ftp["password"]), accounts.PASSWORD_LENGTH)
        self.assertTrue(set(ftp["password"]) <= set(accounts.PASSWORD_ALPHABET))
        self.assertEqual(ftp["host"], "192.168.1.10")
        self.assertFalse(ftp["server"]["running"])
        recorder = Recorder.objects.get(pk=response.data["id"])
        self.assertEqual((recorder.connection, recorder.host), ("ftp", ""))
        self.assertEqual(recorder.status, Recorder.Status.NEVER)
        self.assertTrue(storage.inbox_dir(recorder.pk).is_dir())

    def test_two_ftp_setups_can_coexist(self):
        self.assertEqual(self.create_ftp().status_code, status.HTTP_201_CREATED)
        self.assertEqual(self.create_ftp(name="الثاني").status_code, status.HTTP_201_CREATED)
        self.assertEqual(FtpAccount.objects.count(), 2)

    def test_a_direct_recorder_still_needs_an_address(self):
        response = self.client.post(
            reverse("surveillance-recorder-list"), {"name": "DVR"}, format="json"
        )
        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertIn("host", response.data)

    def test_the_password_is_only_shown_to_those_who_may_change_recorders(self):
        recorder_id = self.create_ftp().data["id"]
        user_model = get_user_model()
        viewer = user_model.objects.create_user(username="viewer", password="pass1234")
        from django.contrib.auth.models import Permission

        viewer.user_permissions.add(
            Permission.objects.get(codename="view_recorder", content_type__app_label="surveillance")
        )
        self.client.force_authenticate(viewer)
        response = self.client.get(reverse("surveillance-recorder-detail", args=[recorder_id]))
        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertIsNone(response.data["ftp"]["password"])
        self.assertTrue(response.data["ftp"]["username"])

    def test_the_connection_cannot_change_after_creation(self):
        recorder_id = self.create_ftp().data["id"]
        response = self.client.patch(
            reverse("surveillance-recorder-detail", args=[recorder_id]),
            {"connection": "direct"},
            format="json",
        )
        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)

    def test_the_password_can_be_regenerated(self):
        created = self.create_ftp().data
        response = self.client.post(
            reverse("surveillance-recorder-regenerate-ftp-password", args=[created["id"]])
        )
        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertNotEqual(response.data["ftp"]["password"], created["ftp"]["password"])
        self.assertEqual(response.data["ftp"]["username"], created["ftp"]["username"])

    def test_the_shown_address_is_stored_and_loopback_refused(self):
        recorder_id = self.create_ftp().data["id"]
        url = reverse("surveillance-recorder-set-ftp-address", args=[recorder_id])
        self.assertEqual(
            self.client.post(url, {"host": "127.0.0.1"}, format="json").status_code,
            status.HTTP_400_BAD_REQUEST,
        )
        response = self.client.post(url, {"host": "192.168.1.77"}, format="json")
        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(response.data["ftp"]["host"], "192.168.1.77")

    def test_sync_on_an_ftp_setup_probes_nothing(self):
        recorder_id = self.create_ftp().data["id"]
        with patch("apps.surveillance.services.probe_recorder") as probe:
            response = self.client.post(reverse("surveillance-recorder-sync", args=[recorder_id]))
        probe.assert_not_called()
        self.assertEqual(response.status_code, status.HTTP_200_OK)

    def ftp_camera(self) -> Camera:
        recorder = Recorder.objects.get(pk=self.create_ftp().data["id"])
        return Camera.objects.create(
            recorder=recorder, channel=1, source_key="ch:1", covers_checkout=True
        )

    def test_live_surfaces_leave_archive_cameras_out(self):
        camera = self.ftp_camera()
        live = self.client.get(reverse("surveillance-camera-list"), {"enabled": "true"})
        everything = self.client.get(reverse("surveillance-camera-list"))
        live_ids = [row["id"] for row in (live.data.get("results", live.data))]
        all_rows = everything.data.get("results", everything.data)
        self.assertNotIn(camera.pk, live_ids)
        self.assertIn(camera.pk, [row["id"] for row in all_rows])
        self.assertFalse(next(row for row in all_rows if row["id"] == camera.pk)["supports_live"])

    def test_live_snapshot_and_sound_say_archive_only(self):
        camera = self.ftp_camera()
        for name in ("surveillance-camera-live", "surveillance-camera-snapshot"):
            response = self.client.get(reverse(name, args=[camera.pk]))
            self.assertEqual(response.status_code, status.HTTP_409_CONFLICT, name)
            self.assertEqual(response.data["code"], "camera_archive_only")
        response = self.client.post(reverse("surveillance-camera-audio-ticket", args=[camera.pk]))
        self.assertEqual(response.status_code, status.HTTP_409_CONFLICT)

    def keep_picture(self, camera, moment, color="red") -> FootageClip:
        relative, absolute = storage.new_archive_path(camera.pk, moment, ".jpg")
        data = jpeg_bytes(color)
        absolute.write_bytes(data)
        return FootageClip.objects.create(
            camera=camera,
            kind=FootageClip.Kind.PICTURE,
            start=moment,
            end=moment,
            path=relative,
            size_bytes=len(data),
        )

    def test_recordings_are_the_kept_clips(self):
        camera = self.ftp_camera()
        t0 = timezone.now().replace(microsecond=0)
        for seconds in (0, 2, 4, 30):
            self.keep_picture(camera, t0 + timedelta(seconds=seconds))
        response = self.client.get(
            reverse("surveillance-camera-recordings", args=[camera.pk]),
            {"start": (t0 - timedelta(minutes=1)).isoformat(), "end": (t0 + timedelta(minutes=1)).isoformat()},
        )
        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertTrue(response.data["known"])
        self.assertEqual(len(response.data["segments"]), 2)

    def test_kept_pictures_play_back_as_the_usual_mjpeg(self):
        camera = self.ftp_camera()
        t0 = timezone.now().replace(microsecond=0)
        self.keep_picture(camera, t0, "red")
        self.keep_picture(camera, t0 + timedelta(seconds=1), "blue")
        with patch.object(playback, "MAX_PICTURE_WAIT_SECONDS", 0.0):
            response = self.client.get(
                reverse("surveillance-camera-playback", args=[camera.pk]),
                {"start": (t0 - timedelta(seconds=5)).isoformat(), "end": (t0 + timedelta(seconds=5)).isoformat()},
            )
            self.assertEqual(response.status_code, status.HTTP_200_OK)
            body = b"".join(response.streaming_content)
        self.assertEqual(body.count(b"Content-Type: image/jpeg"), 2)
        self.assertIn(f"X-Pointy-Frame-Time: {t0.isoformat()}".encode(), body)

    def test_a_window_with_nothing_kept_is_a_404(self):
        camera = self.ftp_camera()
        t0 = timezone.now()
        response = self.client.get(
            reverse("surveillance-camera-playback", args=[camera.pk]),
            {"start": t0.isoformat(), "end": (t0 + timedelta(seconds=30)).isoformat()},
        )
        self.assertEqual(response.status_code, status.HTTP_404_NOT_FOUND)

    def test_a_still_is_the_nearest_kept_picture(self):
        camera = self.ftp_camera()
        t0 = timezone.now().replace(microsecond=0)
        clip = self.keep_picture(camera, t0)
        response = self.client.get(
            reverse("surveillance-camera-still", args=[camera.pk]),
            {"at": (t0 + timedelta(seconds=3)).isoformat()},
        )
        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(response.content, storage.archive_file(clip.path).read_bytes())

    def test_invoice_footage_puts_the_camera_that_has_it_first(self):
        empty = self.ftp_camera()
        other_recorder = Recorder.objects.get(pk=self.create_ftp(name="ب").data["id"])
        holding = Camera.objects.create(
            recorder=other_recorder, channel=1, source_key="ch:1", covers_checkout=True,
            display_order=5,
        )
        order = Order.objects.create()
        self.keep_picture(holding, order.created_at)
        with patch.object(transcode, "ffmpeg_available", return_value=True):
            response = self.client.get(reverse("surveillance-invoice-footage", args=[order.pk]))
        self.assertEqual(response.status_code, status.HTTP_200_OK)
        ids = [camera["id"] for camera in response.data["cameras"]]
        self.assertEqual(ids[0], holding.pk)
        self.assertIn(empty.pk, ids)
        self.assertTrue(response.data["cameras"][0]["has_footage"])
        self.assertTrue(response.data["playback_available"])

    def test_invoice_footage_is_not_offered_when_nothing_was_kept(self):
        self.ftp_camera()
        order = Order.objects.create()
        with patch.object(transcode, "ffmpeg_available", return_value=True):
            response = self.client.get(reverse("surveillance-invoice-footage", args=[order.pk]))
        self.assertFalse(response.data["playback_available"])

    def test_deleting_a_setup_removes_its_footage(self):
        camera = self.ftp_camera()
        clip = self.keep_picture(camera, timezone.now())
        inbox = storage.inbox_dir(camera.recorder_id)
        with self.captureOnCommitCallbacks(execute=True):
            response = self.client.delete(
                reverse("surveillance-recorder-detail", args=[camera.recorder_id])
            )
        self.assertEqual(response.status_code, status.HTTP_204_NO_CONTENT)
        self.assertFalse(inbox.exists())
        self.assertFalse(storage.archive_root().joinpath(str(camera.pk)).exists())
        self.assertFalse(FootageClip.objects.filter(pk=clip.pk).exists())

    def test_status_reports_whether_the_ftp_service_is_up(self):
        response = self.client.get(reverse("surveillance-status"))
        self.assertFalse(response.data["ftp_server"]["running"])
        ftp_status.publish({"accepting": True, "refusing_reason": "", "recent_unknown_logins": []})
        try:
            response = self.client.get(reverse("surveillance-status"))
            self.assertTrue(response.data["ftp_server"]["running"])
        finally:
            ftp_status.clear()

    def test_a_cashier_cannot_create_a_setup(self):
        user_model = get_user_model()
        cashier = user_model.objects.create_user(username="cashier", password="pass1234")
        cashier.groups.add(*cashier.groups.model.objects.filter(name=CASHIER_GROUP))
        self.client.force_authenticate(cashier)
        response = self.client.post(
            reverse("surveillance-recorder-list"), {"connection": "ftp"}, format="json"
        )
        self.assertEqual(response.status_code, status.HTTP_403_FORBIDDEN)
