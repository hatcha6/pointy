"""Listening to a camera.

Sound is a second stream beside the MJPEG one, with a different authorisation
shape — a signed ticket, because platform audio players cannot send headers —
so the things worth pinning here are the ones that shape would get wrong: a
ticket that works on the wrong camera, a listen that never gives the recorder
its session back, and a listen button offered for a channel with no microphone.

Nothing here talks to a recorder or starts ffmpeg; the argv is asserted rather
than run, and the pipe is a BytesIO.
"""

import io
from unittest.mock import patch

from django.contrib.auth import get_user_model
from django.test import TestCase, override_settings
from django.urls import reverse
from rest_framework import status
from rest_framework.test import APIClient

from apps.core.roles import MANAGER_GROUP, ensure_role_groups

from . import budget, services, transcode
from . import views as views_module
from .models import Camera, Recorder

# A trimmed `ffmpeg -encoders` table. The leading flag column is what marks an
# audio encoder, and the video rows are here so a regex that ignores it fails.
ENCODER_TABLE = """Encoders:
 V..... = Video
 A..... = Audio
 ------
 V....D libx264              libx264 H.264
 V....D mpeg4                MPEG-4 part 2
 A....D aac                  AAC (Advanced Audio Coding)
 A....D libmp3lame           libmp3lame MP3 (MPEG audio layer 3)
"""

VIDEO_ONLY_TABLE = """Encoders:
 ------
 V....D libx264              libx264 H.264
"""


class _Completed:
    """Enough of ``subprocess.CompletedProcess`` for these tests."""

    def __init__(self, stdout=b"", stderr=b"", returncode=0):
        self.stdout = stdout
        self.stderr = stderr
        self.returncode = returncode


class AudioEncoderDetectionTests(TestCase):
    """Which encoder this build has is measured, like ``supports_readrate``."""

    def setUp(self):
        transcode.reset_probe_cache()
        self.addCleanup(transcode.reset_probe_cache)

    def test_native_aac_is_preferred_over_the_external_library(self):
        with patch.object(
            transcode.subprocess, "run", return_value=_Completed(ENCODER_TABLE.encode())
        ):
            self.assertEqual(
                transcode._detect_audio_encoder("/usr/bin/ffmpeg"), ("aac", "adts")
            )

    def test_mp3_is_the_fallback_when_aac_is_missing(self):
        table = ENCODER_TABLE.replace(" A....D aac                  AAC", "")
        with patch.object(
            transcode.subprocess, "run", return_value=_Completed(table.encode())
        ):
            self.assertEqual(
                transcode._detect_audio_encoder("/usr/bin/ffmpeg"),
                ("libmp3lame", "mp3"),
            )

    def test_a_build_with_no_audio_encoder_reports_none(self):
        with patch.object(
            transcode.subprocess,
            "run",
            return_value=_Completed(VIDEO_ONLY_TABLE.encode()),
        ):
            self.assertEqual(transcode._detect_audio_encoder("/usr/bin/ffmpeg"), ("", ""))

    def test_a_failed_probe_degrades_rather_than_raising(self):
        with patch.object(transcode.subprocess, "run", side_effect=OSError("boom")):
            self.assertEqual(transcode._detect_audio_encoder("/usr/bin/ffmpeg"), ("", ""))


class AudioTrackProbeTests(TestCase):
    """"No microphone" is a successful probe with empty output, not an error."""

    def setUp(self):
        transcode.reset_probe_cache()
        self.addCleanup(transcode.reset_probe_cache)

    def _probe(self, completed):
        with patch.object(transcode, "ffprobe_path", return_value="/usr/bin/ffprobe"):
            with patch.object(
                transcode.subprocess, "run", return_value=completed
            ) as run:
                return transcode.audio_track("rtsp://box/ch1"), run

    def test_a_channel_with_sound_reports_its_codec(self):
        codec, _run = self._probe(_Completed(b"aac\n"))
        self.assertEqual(codec, "aac")

    def test_a_channel_with_no_microphone_reports_empty(self):
        codec, _run = self._probe(_Completed(b"\n"))
        self.assertEqual(codec, "")

    def test_the_probe_does_not_ask_for_audio_only(self):
        """The opposite of the stream, and deliberately so.

        A server asked for audio-only on a channel with no audio refuses the
        session instead of answering — which is the one answer this call
        exists to get. Measured against the rig: 501 with the filter, a clean
        empty answer without it. See `test_rig.py`.
        """
        _codec, run = self._probe(_Completed(b"aac\n"))
        self.assertNotIn("-allowed_media_types", run.call_args.args[0])

    def test_a_broken_stream_raises_with_the_password_redacted(self):
        with patch.object(transcode, "ffprobe_path", return_value="/usr/bin/ffprobe"):
            with patch.object(
                transcode.subprocess,
                "run",
                return_value=_Completed(
                    stderr=b"rtsp://admin:hunter2@10.0.0.9/ch1: Server error",
                    returncode=1,
                ),
            ):
                with self.assertRaises(transcode.TranscodeUnavailable) as caught:
                    transcode.audio_track("rtsp://admin:hunter2@10.0.0.9/ch1")
        self.assertNotIn("hunter2", str(caught.exception))

    @override_settings(POINTY_FFMPEG_PATH="/definitely/not/here")
    def test_without_ffprobe_the_error_says_so(self):
        with patch.object(transcode.shutil, "which", return_value=None):
            with self.assertRaises(transcode.TranscodeUnavailable) as caught:
                transcode.audio_track("rtsp://box/ch1")
        self.assertIn("ffprobe", str(caught.exception))


class AudioStreamArgvTests(TestCase):
    def setUp(self):
        transcode.reset_probe_cache()
        self.addCleanup(transcode.reset_probe_cache)

    def _open(self):
        captured = {}

        def fake_spawn(args, slot, **kwargs):
            captured["argv"] = args
            return object(), slot

        with patch.object(transcode, "ffmpeg_path", return_value="/usr/bin/ffmpeg"):
            with patch.object(
                transcode,
                "probe",
                return_value={
                    "available": True,
                    "path": "/usr/bin/ffmpeg",
                    "version": "6.0",
                    "supports_readrate": True,
                    "supports_fps_mode": True,
                    "audio_encoder": "aac",
                    "audio_format": "adts",
                },
            ):
                with patch.object(transcode, "_spawn", side_effect=fake_spawn):
                    _process, slot = transcode.open_audio_stream("rtsp://box/ch1")
        slot.release()
        return captured["argv"]

    def test_the_recorder_is_asked_for_audio_only(self):
        """The saving that makes a listen cheap: with this the DVR never sends
        the video at all, so a listen costs a few KB/s rather than a second
        video session."""
        argv = self._open()
        self.assertIn("-allowed_media_types", argv)
        self.assertEqual(argv[argv.index("-allowed_media_types") + 1], "audio")

    def test_video_is_dropped_even_if_the_firmware_ignores_the_filter(self):
        self.assertIn("-vn", self._open())

    def test_output_is_flushed_per_packet(self):
        """Without this the muxer holds seconds of sound back waiting to fill a
        buffer, which reads as a camera that is late rather than live."""
        argv = self._open()
        self.assertIn("-flush_packets", argv)
        self.assertEqual(argv[argv.index("-flush_packets") + 1], "1")

    def test_the_detected_encoder_and_container_are_used(self):
        argv = self._open()
        self.assertEqual(argv[argv.index("-c:a") + 1], "aac")
        self.assertEqual(argv[argv.index("-f") + 1], "adts")

    def test_a_build_with_no_audio_encoder_refuses_readably(self):
        with patch.object(transcode, "ffmpeg_path", return_value="/usr/bin/ffmpeg"):
            with patch.object(
                transcode,
                "probe",
                return_value={
                    "available": True,
                    "path": "/usr/bin/ffmpeg",
                    "version": "6.0",
                    "supports_readrate": True,
                    "supports_fps_mode": True,
                    "audio_encoder": "",
                    "audio_format": "",
                },
            ):
                with self.assertRaises(transcode.TranscodeUnavailable) as caught:
                    transcode.open_audio_stream("rtsp://box/ch1")
        self.assertIn("audio encoder", str(caught.exception))


class _FakeDriver:
    def __init__(self, url="rtsp://10.0.0.9/ch1"):
        self.url = url
        self.closed = False

    def live_rtsp_url(self, channel, quality="sub"):
        return self.url

    def close(self):
        self.closed = True


class _FakeProcess:
    def __init__(self, output=b""):
        self.stdout = io.BytesIO(output)

    def poll(self):
        return 0


AUDIO_PROBE = {
    "available": True,
    "path": "/usr/bin/ffmpeg",
    "version": "6.0",
    "supports_readrate": True,
    "supports_fps_mode": True,
    "audio_encoder": "aac",
    "audio_format": "adts",
}


class CameraAudioApiTests(TestCase):
    def setUp(self):
        ensure_role_groups()
        budget.reset()
        self.addCleanup(budget.reset)
        transcode.reset_probe_cache()
        self.addCleanup(transcode.reset_probe_cache)
        self.client = APIClient()
        user_model = get_user_model()
        self.manager = user_model.objects.create_user(
            username="manager", password="pass1234"
        )
        self.manager.groups.add(
            *self.manager.groups.model.objects.filter(name=MANAGER_GROUP)
        )
        self.recorder = Recorder.objects.create(
            host="10.0.0.9",
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

    def ticket_url(self, camera=None):
        return reverse(
            "surveillance-camera-audio-ticket", args=[(camera or self.camera).pk]
        )

    def stream_url(self, camera=None):
        return reverse("surveillance-camera-audio", args=[(camera or self.camera).pk])

    # -- minting -----------------------------------------------------------

    def test_a_ticket_needs_a_login(self):
        response = self.client.post(self.ticket_url())
        self.assertIn(
            response.status_code,
            (status.HTTP_401_UNAUTHORIZED, status.HTTP_403_FORBIDDEN),
        )

    def test_the_microphone_is_measured_once_and_remembered(self):
        self.client.force_authenticate(self.manager)
        with patch.object(transcode, "probe", return_value=AUDIO_PROBE):
            with patch.object(services, "open_driver", return_value=_FakeDriver()):
                with patch.object(
                    transcode, "audio_track", return_value="aac"
                ) as track:
                    first = self.client.post(self.ticket_url())
                    second = self.client.post(self.ticket_url())
        self.assertEqual(first.status_code, status.HTTP_200_OK)
        self.assertEqual(second.status_code, status.HTTP_200_OK)
        self.assertTrue(first.data["ticket"])
        # The expensive part — an RTSP session — happens on the first ask only.
        self.assertEqual(track.call_count, 1)
        self.camera.refresh_from_db()
        self.assertIs(self.camera.has_audio, True)
        self.assertIsNotNone(self.camera.audio_checked_at)

    def test_a_channel_with_no_microphone_is_refused_with_a_sentence(self):
        self.client.force_authenticate(self.manager)
        with patch.object(transcode, "probe", return_value=AUDIO_PROBE):
            with patch.object(services, "open_driver", return_value=_FakeDriver()):
                with patch.object(transcode, "audio_track", return_value=""):
                    response = self.client.post(self.ticket_url())
        self.assertEqual(response.status_code, status.HTTP_409_CONFLICT)
        self.assertEqual(response.data["code"], "camera_has_no_audio")
        self.camera.refresh_from_db()
        self.assertIs(self.camera.has_audio, False)

    def test_a_server_without_an_audio_encoder_says_so_before_probing(self):
        self.client.force_authenticate(self.manager)
        silent = dict(AUDIO_PROBE, audio_encoder="", audio_format="")
        with patch.object(transcode, "probe", return_value=silent):
            with patch.object(services, "open_driver") as open_driver:
                response = self.client.post(self.ticket_url())
        self.assertEqual(response.status_code, status.HTTP_503_SERVICE_UNAVAILABLE)
        open_driver.assert_not_called()

    def test_the_driver_is_closed_even_when_the_probe_fails(self):
        self.client.force_authenticate(self.manager)
        driver = _FakeDriver()
        with patch.object(transcode, "probe", return_value=AUDIO_PROBE):
            with patch.object(services, "open_driver", return_value=driver):
                with patch.object(
                    transcode,
                    "audio_track",
                    side_effect=transcode.TranscodeUnavailable("no"),
                ):
                    response = self.client.post(self.ticket_url())
        self.assertEqual(response.status_code, status.HTTP_503_SERVICE_UNAVAILABLE)
        self.assertTrue(driver.closed)

    # -- the ticket is the authorisation -----------------------------------

    def test_streaming_without_a_ticket_is_refused(self):
        response = self.client.get(self.stream_url())
        self.assertEqual(response.status_code, status.HTTP_403_FORBIDDEN)

    def test_a_forged_ticket_is_refused(self):
        response = self.client.get(self.stream_url(), {"ticket": "1:fake:signature"})
        self.assertEqual(response.status_code, status.HTTP_403_FORBIDDEN)

    def test_a_ticket_for_one_camera_does_not_open_another(self):
        """The camera id lives inside the signature, so a ticket for the yard
        cannot be pointed at the office."""
        ticket = views_module._mint_audio_ticket(self.camera)
        response = self.client.get(
            self.stream_url(self.other_camera), {"ticket": ticket}
        )
        self.assertEqual(response.status_code, status.HTTP_403_FORBIDDEN)

    def test_an_expired_ticket_is_refused(self):
        ticket = views_module._mint_audio_ticket(self.camera)
        with patch.object(views_module, "AUDIO_TICKET_MAX_AGE", -1):
            response = self.client.get(self.stream_url(), {"ticket": ticket})
        self.assertEqual(response.status_code, status.HTTP_403_FORBIDDEN)

    # -- streaming ---------------------------------------------------------

    def _listen(self, output=b"\xff\xf1audio", camera=None):
        camera = camera or self.camera
        ticket = views_module._mint_audio_ticket(camera)
        process = _FakeProcess(output)
        slot = object()
        with patch.object(transcode, "probe", return_value=AUDIO_PROBE):
            with patch.object(services, "open_driver", return_value=_FakeDriver()):
                with patch.object(
                    transcode, "open_audio_stream", return_value=(process, slot)
                ):
                    with patch.object(transcode, "stop") as stop:
                        with patch.object(transcode, "drain_error", return_value=""):
                            response = self.client.get(
                                self.stream_url(camera), {"ticket": ticket}
                            )
                            body = b""
                            if response.status_code == status.HTTP_200_OK:
                                body = b"".join(response.streaming_content)
        return response, body, stop

    def test_a_valid_ticket_streams_the_sound(self):
        Camera.objects.filter(pk=self.camera.pk).update(has_audio=True)
        response, body, _stop = self._listen(b"\xff\xf1hello world")
        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(response["Content-Type"], "audio/aac")
        # Including the bytes that were pulled before the response started.
        self.assertEqual(body, b"\xff\xf1hello world")

    def test_proxies_are_told_not_to_buffer(self):
        """The same trap as the video streams: a buffering proxy turns a live
        stream into one that arrives when it ends, which for live is never."""
        Camera.objects.filter(pk=self.camera.pk).update(has_audio=True)
        response, _body, _stop = self._listen()
        self.assertEqual(response["X-Accel-Buffering"], "no")

    def test_the_recorder_gets_its_session_back_when_the_listener_leaves(self):
        """A listen nobody is hearing has to actually stop: a DVR has a hard cap
        on concurrent sessions and a leaked one is a tile that cannot open."""
        Camera.objects.filter(pk=self.camera.pk).update(has_audio=True)
        _response, _body, stop = self._listen()
        self.assertEqual(budget.in_flight(self.recorder.pk), 0)
        stop.assert_called()

    def test_a_silent_pipeline_is_an_http_error_not_an_empty_stream(self):
        """Fail where it can still be a sentence. A 200 that carries no bytes
        is a player that connects and stays silent forever."""
        Camera.objects.filter(pk=self.camera.pk).update(has_audio=True)
        response, _body, _stop = self._listen(b"")
        self.assertEqual(response.status_code, status.HTTP_502_BAD_GATEWAY)
        self.assertEqual(budget.in_flight(self.recorder.pk), 0)

    def test_a_camera_measured_silent_is_refused_before_ffmpeg_starts(self):
        Camera.objects.filter(pk=self.camera.pk).update(has_audio=False)
        ticket = views_module._mint_audio_ticket(self.camera)
        with patch.object(transcode, "open_audio_stream") as opener:
            response = self.client.get(self.stream_url(), {"ticket": ticket})
        self.assertEqual(response.status_code, status.HTTP_409_CONFLICT)
        opener.assert_not_called()

    def test_a_disabled_camera_cannot_be_listened_to(self):
        Camera.objects.filter(pk=self.camera.pk).update(
            has_audio=True, is_enabled=False
        )
        ticket = views_module._mint_audio_ticket(self.camera)
        response = self.client.get(self.stream_url(), {"ticket": ticket})
        self.assertEqual(response.status_code, status.HTTP_404_NOT_FOUND)

    # -- what the client is told -------------------------------------------

    def test_the_camera_list_carries_the_tri_state(self):
        """Null is "not asked yet", which is a listen button worth offering;
        false is measured silence, which is not."""
        self.client.force_authenticate(self.manager)
        Camera.objects.filter(pk=self.camera.pk).update(has_audio=True)
        response = self.client.get(reverse("surveillance-camera-list"))
        self.assertEqual(response.status_code, status.HTTP_200_OK)
        rows = response.data
        if isinstance(rows, dict):
            rows = rows["results"]
        by_id = {row["id"]: row for row in rows}
        self.assertIs(by_id[self.camera.pk]["has_audio"], True)
        self.assertIsNone(by_id[self.other_camera.pk]["has_audio"])

    def test_has_audio_cannot_be_set_by_a_client(self):
        """It is a measurement, not a preference."""
        self.client.force_authenticate(self.manager)
        response = self.client.patch(
            reverse("surveillance-camera-detail", args=[self.camera.pk]),
            {"has_audio": True},
            format="json",
        )
        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.camera.refresh_from_db()
        self.assertIsNone(self.camera.has_audio)

    def test_listening_needs_the_live_permission(self):
        user_model = get_user_model()
        nobody = user_model.objects.create_user(username="nobody", password="pass1234")
        self.client.force_authenticate(nobody)
        response = self.client.post(self.ticket_url())
        self.assertEqual(response.status_code, status.HTTP_403_FORBIDDEN)
