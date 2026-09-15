"""Tests that need the camera rig, and say so when it is not there.

``tests.py`` pins the demuxer against fixtures this repository wrote. That is
worth having and it is not the same as knowing the feature works: a fixture
encodes what we *think* a recorder sends. These tests drive
``tools/camera-rig``, which serves what one actually sent.

Two halves, because the risks are different:

* **Real video** (MediaMTX over RTSP, real H.264, real ffmpeg) proves the
  transcode spine end to end — that frames arrive, decode, and are pictures.
* **The trap** (``fake_dvr``) proves the JPEG demuxer, which the real half
  provably *cannot*: our own ffmpeg never writes a quantization table holding
  ``FF D9``, measured across 630 encoder configurations. Only a recorder's
  encoder does, which is why the grey pixels reached the field at all.

Skipped, not failed, when the rig is down — this file must not turn a laptop
without docker into a red build:

    docker compose -f tools/camera-rig/docker-compose.yml up -d --build
    python manage.py test apps.surveillance.test_rig
"""

from __future__ import annotations

import io
import json
import os
import subprocess
import unittest
import urllib.error
import urllib.request

from django.test import SimpleTestCase

from . import transcode
from .streaming import _jpeg_frame_end, _jpeg_frames

DVR = os.environ.get("POINTY_RIG_DVR", "http://127.0.0.1:8090")
RTSP = os.environ.get("POINTY_RIG_RTSP", "rtsp://127.0.0.1:8554/shop")

#: Below this standard deviation of luma a frame has no picture in it. A flat
#: grey fill lands near 0; the rig's test pattern is above 50. The gap is wide
#: enough that the threshold never needs tuning.
NOT_GREY = 10.0


def rig_health():
    try:
        with urllib.request.urlopen(f"{DVR}/health", timeout=2) as response:
            return json.load(response)
    except (urllib.error.URLError, OSError, ValueError):
        return None


def fetch(path: str) -> bytes:
    with urllib.request.urlopen(f"{DVR}{path}", timeout=5) as response:
        return response.read()


def luma_spread(jpeg: bytes) -> float:
    """How much picture is in this frame. Near zero means flat — the symptom.

    Decoding is the assertion: a frame that cannot be decoded at all raises, and
    the callers treat that as grey too, because to a shop the two are one thing.
    """
    from PIL import Image, ImageStat

    image = Image.open(io.BytesIO(jpeg))
    image.load()  # force the decode; Image.open is lazy and would defer the error
    return ImageStat.Stat(image.convert("L")).stddev[0]


def naive_frame_end(buffer: bytes) -> int:
    """The demuxer as it was before the fix: scan for FFD9 from byte zero.

    Kept here so the trap has something to catch. A test that only proves the
    current code works cannot tell you whether it is still being tested — this
    one asserts the old algorithm *fails*, so the day the rig stops reproducing
    the bug, the test says so instead of going quietly green.
    """
    index = buffer.find(b"\xff\xd9")
    return index + 2 if index != -1 else -1


class RigTestCase(SimpleTestCase):
    """Skips with a usable sentence when the rig is not running."""

    @classmethod
    def setUpClass(cls):
        super().setUpClass()
        cls.health = rig_health()
        if cls.health is None:
            raise unittest.SkipTest(
                "camera rig is not running — "
                "docker compose -f tools/camera-rig/docker-compose.yml up -d"
            )


class TrapFrameTests(RigTestCase):
    """The recorder's JPEG, the one that painted every tile grey."""

    def test_the_rig_is_actually_armed(self):
        """A rig that has stopped reproducing the bug must fail, not pass.

        Everything else in this class is only meaningful if the frames really do
        carry an end-of-image marker inside a header segment. If a future ffmpeg
        or a changed rig quietly stops producing that, the other tests would
        still pass — on frames with no trap in them. This is the guard.
        """
        self.assertTrue(
            self.health["trap_armed"],
            "the rig served frames with no FFD9 inside a header segment; "
            "the grey-pixel tests below would pass without testing anything",
        )
        self.assertGreater(self.health["bytes_lost_to_naive_scan"], 0)

    def test_the_old_demuxer_still_loses_the_picture(self):
        """Proof the trap has teeth: the pre-fix scan truncates this frame."""
        frame = fetch("/trap/snapshot.jpg?i=0")

        cut = naive_frame_end(frame)
        self.assertNotEqual(cut, -1, "the frame contains no FFD9 at all")
        self.assertLess(
            cut,
            len(frame),
            "a scan-based demuxer no longer truncates this frame — the rig is "
            "no longer reproducing the field failure",
        )
        # And what is left is not a picture: either it refuses to decode or it
        # decodes flat. Both are the grey box a shop reported.
        try:
            spread = luma_spread(frame[:cut])
        except Exception:
            spread = 0.0
        self.assertLess(spread, NOT_GREY, "the truncated remains still decoded")

    def test_the_demuxer_returns_the_whole_frame(self):
        frame = fetch("/trap/snapshot.jpg?i=0")

        self.assertEqual(_jpeg_frame_end(bytearray(frame)), len(frame))

    def test_trapped_frames_decode_to_pictures_not_grey(self):
        """The end-to-end claim: real demuxer, recorder-style frames, a picture.

        Frames are concatenated exactly as ffmpeg's MJPEG pipe delivers them and
        read back through the real ``_jpeg_frames``, over a real pipe, so the
        chunk boundaries fall wherever the OS puts them rather than where a
        fixture chose.
        """
        frames = [fetch(f"/trap/snapshot.jpg?i={i}") for i in range(6)]
        stream = b"".join(frames)

        process = subprocess.Popen(
            ["cat"], stdin=subprocess.PIPE, stdout=subprocess.PIPE
        )
        try:
            process.stdin.write(stream)
            process.stdin.close()
            emitted = list(
                _jpeg_frames(
                    process,
                    lambda: False,
                    seconds_per_frame=0.125,
                    anchor=None,
                )
            )
        finally:
            process.stdout.close()
            process.wait(timeout=5)

        self.assertEqual(len(emitted), len(frames))
        for index, (got, expected) in enumerate(zip(emitted, frames)):
            with self.subTest(frame=index):
                self.assertEqual(got.data, expected, "frame came back altered")
                self.assertGreater(
                    luma_spread(got.data),
                    NOT_GREY,
                    "frame decoded flat — this is the grey-pixel bug",
                )


@unittest.skipUnless(transcode.ffmpeg_available(), "needs ffmpeg")
class RealVideoTests(RigTestCase):
    """Real H.264 over real RTSP, through the real pipeline."""

    def test_rtsp_becomes_jpeg_frames_that_are_pictures(self):
        process, slot = transcode.open_mjpeg_stream(RTSP, fps=4, quality=6)
        try:
            frames = []
            for frame in _jpeg_frames(
                process, lambda: len(frames) >= 4, seconds_per_frame=0.25, anchor=None
            ):
                frames.append(frame)
                if len(frames) >= 4:
                    break
        finally:
            transcode.stop(process, slot)

        self.assertGreaterEqual(len(frames), 4, "no video came back from the rig")
        for index, frame in enumerate(frames):
            with self.subTest(frame=index):
                self.assertTrue(frame.data.startswith(b"\xff\xd8"))
                self.assertEqual(_jpeg_frame_end(bytearray(frame.data)), len(frame.data))
                self.assertGreater(luma_spread(frame.data), NOT_GREY)

    def test_the_real_path_cannot_catch_the_grey_pixel_bug(self):
        """Why the trap exists at all, pinned as a fact rather than a comment.

        Every JPEG on this path is written by our own ffmpeg, and its MJPEG
        encoder does not produce a quantization table containing FFD9. So the
        pre-fix demuxer handles this stream perfectly — which is exactly why a
        MediaMTX-only rig would have shipped the grey pixels.
        """
        process, slot = transcode.open_mjpeg_stream(RTSP, fps=4, quality=6)
        try:
            frame = next(
                iter(
                    _jpeg_frames(
                        process, lambda: False, seconds_per_frame=0.25, anchor=None
                    )
                )
            )
        finally:
            transcode.stop(process, slot)

        self.assertEqual(
            naive_frame_end(frame.data),
            len(frame.data),
            "ffmpeg has started emitting FFD9 inside a header segment; the real "
            "video path can now catch this bug and the trap could be retired",
        )
