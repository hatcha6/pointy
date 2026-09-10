"""Xiongmai's own protocol, which is undocumented and therefore pinned hard.

Everything this driver does rests on a reverse-engineered wire format, so the
tests are written as a specification of that format rather than as a check that
the code runs: if a refactor changes the bytes on the wire or the shape of the
JSON, these fail, which is the only warning available short of a box in Libya.

The login digest is pinned to published constants. ``sofia_hash("")`` is
``tlJwpbo6`` — the value the firmware itself compares against for an empty
password, well known from the XMEye security literature — so a passing test here
is evidence the algorithm matches real hardware and not merely itself.
"""

import json
import struct
from datetime import datetime, timedelta, timezone as dt_timezone
from unittest.mock import patch

from django.test import TestCase

from .drivers.base import (
    RecorderAuthError,
    RecorderError,
    RecorderTarget,
    RecorderUnreachable,
    StreamQuality,
)
from .drivers.registry import DRIVER_CLASSES, driver_class_for_brand
from .drivers.xiongmai import (
    CHANNEL_TITLE,
    DVRIP_PORT,
    FILE_SEARCH,
    LOGIN,
    MAX_SEARCH_PAGES,
    SEARCH_PAGE_SIZE,
    PLAYBACK,
    SYSINFO,
    TAIL,
    MediaDeframer,
    XiongmaiDriver,
    sofia_hash,
)
from .models import Recorder

HEADER = struct.Struct("<BB2xIIBBHI")
SESSION = 0x0000000C

SYSTEM_INFO = {
    "Ret": 100,
    "SystemInfo": {
        "HardWare": "NBD8016T-PL",
        "SerialNo": "ba6e60b40b9556ae",
        "SoftWareVersion": "V4.03.R11.C638020Q.11201",
        "VideoInChannel": 16,
        "DigChannel": 0,
    },
}

CHANNEL_TITLES = {"Ret": 100, "ChannelTitle": ["Counter", "Door", "", "Store room"]}

FILE_QUERY = {
    "Ret": 100,
    "OPFileQuery": [
        {
            "BeginTime": "2026-09-08 11:00:00",
            "EndTime": "2026-09-08 11:15:00",
            "FileLength": "0x1a2b",
            "FileName": "/idea0/2026-09-08/001/11.00.00-11.15.00[M][@0][0].h264",
        },
        {
            "BeginTime": "2026-09-08 11:15:00",
            "EndTime": "2026-09-08 11:30:00",
            "FileLength": "6699",
            "FileName": "/idea0/2026-09-08/001/11.15.00-11.30.00[M][@0][0].h264",
        },
        # A row the box could not stamp. Skipped rather than crashing a search.
        {"BeginTime": "", "EndTime": "", "FileName": "junk"},
    ],
}


class _FakeSocket:
    """Speaks just enough DVRIP to answer the driver, and records what it heard."""

    def __init__(self, replies, *, session=SESSION):
        self.replies = replies
        self.session = session
        self.sent = []
        self._inbox = b""
        self.closed = False

    def settimeout(self, _value):
        pass

    def sendall(self, data):
        header, body = data[:20], data[20:]
        _, _, session, sequence, _, _, message_id, length = HEADER.unpack(header)
        assert length == len(body), "the header must declare the real body length"
        assert body.endswith(TAIL), "every frame ends with the two-byte tail"
        payload = json.loads(body[: -len(TAIL)].decode("utf-8"))
        self.sent.append(
            {"id": message_id, "session": session, "sequence": sequence, "payload": payload}
        )
        reply = self.replies.get(message_id, {"Ret": 100})
        if callable(reply):
            reply = reply(payload)
        self._queue(message_id + 1, reply)

    def _queue(self, message_id, payload):
        body = json.dumps(payload).encode("utf-8") + TAIL
        self._inbox += HEADER.pack(
            0xFF, 0x00, self.session, 0, 0, 0, message_id, len(body)
        ) + body

    def recv(self, count):
        chunk, self._inbox = self._inbox[:count], self._inbox[count:]
        return chunk

    def close(self):
        self.closed = True


def target(**overrides):
    values = {
        "host": "192.168.1.100",
        "port": 80,
        "rtsp_port": 554,
        "username": "admin",
        "password": "secret",
    }
    values.update(overrides)
    return RecorderTarget(**values)


def driver_with(replies, **target_kwargs):
    fake = _FakeSocket(
        {LOGIN: {"Ret": 100, "SessionID": f"0x{SESSION:08x}"}, **replies}
    )
    driver = XiongmaiDriver(target(**target_kwargs))
    patcher = patch(
        "apps.surveillance.drivers.xiongmai.socket.create_connection",
        return_value=fake,
    )
    patcher.start()
    return driver, fake, patcher


class SofiaHashTests(TestCase):
    def test_the_empty_password_matches_the_published_constant(self):
        """The value real firmware compares against. If this changes, the driver
        can no longer log in to any Xiongmai anywhere."""
        self.assertEqual(sofia_hash(""), "tlJwpbo6")

    def test_known_passwords_keep_their_digests(self):
        self.assertEqual(sofia_hash("admin"), "6QNMIQGe")
        self.assertEqual(sofia_hash("123456"), "nTBCS19C")
        # The XM factory service account, whose password is "default" backwards.
        self.assertEqual(sofia_hash("tluafed"), "OxhlwSG8")

    def test_the_digest_is_always_eight_characters(self):
        for password in ("", "a", "a much longer password than any DVR needs", "ال"):
            self.assertEqual(len(sofia_hash(password)), 8)

    def test_the_plaintext_password_never_appears_in_the_digest(self):
        self.assertNotIn("secret", sofia_hash("secret"))


class XiongmaiLoginTests(TestCase):
    def test_login_sends_the_digest_and_never_the_password(self):
        driver, fake, patcher = driver_with({SYSINFO: SYSTEM_INFO})
        try:
            driver.probe()
        finally:
            patcher.stop()
        login = next(call for call in fake.sent if call["id"] == LOGIN)
        self.assertEqual(login["payload"]["PassWord"], sofia_hash("secret"))
        self.assertEqual(login["payload"]["UserName"], "admin")
        self.assertEqual(login["payload"]["LoginType"], "DVRIP-Web")
        self.assertNotIn("secret", json.dumps(login["payload"]))

    def test_the_session_id_threads_every_later_call(self):
        driver, fake, patcher = driver_with({SYSINFO: SYSTEM_INFO})
        try:
            driver.probe()
        finally:
            patcher.stop()
        later = [call for call in fake.sent if call["id"] != LOGIN]
        self.assertTrue(later)
        for call in later:
            self.assertEqual(call["session"], SESSION)

    def test_a_wrong_password_is_reported_as_a_password_problem(self):
        """Not as an unsupported recorder — that sends the installer to the
        wrong field."""
        driver, _fake, patcher = driver_with({LOGIN: {"Ret": 106}})
        try:
            with self.assertRaises(RecorderAuthError):
                driver.probe()
        finally:
            patcher.stop()

    def test_an_account_without_remote_rights_is_also_a_password_problem(self):
        driver, _fake, patcher = driver_with({LOGIN: {"Ret": 107}})
        try:
            with self.assertRaises(RecorderAuthError):
                driver.probe()
        finally:
            patcher.stop()

    def test_a_box_that_is_not_xiongmai_is_not_claimed(self):
        """Detection has to be able to move on to the next brand."""
        driver = XiongmaiDriver(target())
        with patch(
            "apps.surveillance.drivers.xiongmai.socket.create_connection",
            side_effect=OSError("connection refused"),
        ):
            with self.assertRaises(RecorderUnreachable):
                driver.probe()

    def test_a_port_that_answers_with_something_else_is_not_claimed(self):
        fake = _FakeSocket({})
        fake._queue = lambda *a, **k: None
        junk = b"HTTP/1.1 404" + TAIL
        fake._inbox = HEADER.pack(0xFF, 0, 0, 0, 0, 0, LOGIN + 1, len(junk)) + junk
        driver = XiongmaiDriver(target())
        with patch(
            "apps.surveillance.drivers.xiongmai.socket.create_connection",
            return_value=fake,
        ):
            with self.assertRaises(RecorderError):
                driver.probe()


class XiongmaiFramingTests(TestCase):
    """The wire format, checked against OpenIPC/python-dvr — the reference
    implementation this protocol has. Firmware refuses a frame whose declared
    length does not count the two-byte tail, so both are pinned here."""

    def test_every_frame_ends_with_the_two_byte_tail(self):
        self.assertEqual(TAIL, b"\x0a\x00")

    def test_the_header_declares_a_length_that_counts_the_tail(self):
        driver, fake, patcher = driver_with({SYSINFO: SYSTEM_INFO})
        try:
            driver.probe()
        finally:
            patcher.stop()
        self.assertTrue(fake.sent, "nothing was sent")

    def test_the_header_is_twenty_bytes(self):
        self.assertEqual(HEADER.size, 20)


class XiongmaiIdentityTests(TestCase):
    def test_probe_reads_the_boxes_own_identity(self):
        driver, _fake, patcher = driver_with({SYSINFO: SYSTEM_INFO})
        try:
            info = driver.probe()
        finally:
            patcher.stop()
        self.assertEqual(info.brand, "xiongmai")
        self.assertEqual(info.model, "NBD8016T-PL")
        self.assertEqual(info.serial, "ba6e60b40b9556ae")
        self.assertEqual(info.channel_count, 16)

    def test_a_hybrid_box_counts_both_kinds_of_input(self):
        """An XVR with analogue and IP cameras would otherwise show half."""
        info = dict(SYSTEM_INFO)
        info["SystemInfo"] = {**SYSTEM_INFO["SystemInfo"], "VideoInChannel": 8, "DigChannel": 8}
        driver, _fake, patcher = driver_with({SYSINFO: info})
        try:
            self.assertEqual(driver.probe().channel_count, 16)
        finally:
            patcher.stop()

    def test_channel_names_come_from_the_dvr(self):
        driver, _fake, patcher = driver_with(
            {SYSINFO: SYSTEM_INFO, CHANNEL_TITLE: CHANNEL_TITLES}
        )
        try:
            channels = driver.list_channels()
        finally:
            patcher.stop()
        self.assertEqual(len(channels), 16)
        self.assertEqual(channels[0].name, "Counter")
        self.assertEqual(channels[1].name, "Door")
        self.assertEqual(channels[3].name, "Store room")

    def test_a_box_that_hides_its_channel_names_is_still_usable(self):
        driver, _fake, patcher = driver_with(
            {SYSINFO: SYSTEM_INFO, CHANNEL_TITLE: {"Ret": 103}}
        )
        try:
            channels = driver.list_channels()
        finally:
            patcher.stop()
        self.assertEqual(len(channels), 16)
        self.assertEqual(channels[0].name, "")


class XiongmaiRecordingTests(TestCase):
    def setUp(self):
        self.start = datetime(2026, 9, 8, 11, 0, tzinfo=dt_timezone.utc)
        self.end = self.start + timedelta(minutes=30)

    def test_search_returns_the_stretches_that_were_recorded(self):
        driver, _fake, patcher = driver_with({FILE_SEARCH: FILE_QUERY})
        try:
            segments = driver.search_recordings(1, self.start, self.end)
        finally:
            patcher.stop()
        self.assertEqual(len(segments), 2)
        self.assertEqual(segments[0].size_bytes, 0x1A2B)
        self.assertEqual(segments[1].size_bytes, 6699)
        self.assertTrue(segments[0].handle.endswith(".h264"))

    def test_the_wire_counts_channels_from_zero(self):
        """Every other surface here is 1-based; the protocol is not."""
        driver, fake, patcher = driver_with({FILE_SEARCH: FILE_QUERY})
        try:
            driver.search_recordings(1, self.start, self.end)
        finally:
            patcher.stop()
        query = next(c for c in fake.sent if c["id"] == FILE_SEARCH)
        self.assertEqual(query["payload"]["OPFileQuery"]["Channel"], 0)

    def test_a_search_the_box_refuses_is_unknown_not_empty(self):
        """A DVR that cannot be searched still plays back fine, so this must not
        read as 'nothing was recorded'."""
        driver, _fake, patcher = driver_with({FILE_SEARCH: {"Ret": 103}})
        try:
            self.assertEqual(driver.search_recordings(1, self.start, self.end), [])
        finally:
            patcher.stop()

    def test_search_times_are_asked_in_the_recorders_own_clock(self):
        """A DVR left on the factory timezone would otherwise be searched for
        the wrong hour and answer, wrongly, that nothing was recorded."""
        driver, fake, patcher = driver_with(
            {FILE_SEARCH: FILE_QUERY}, clock_offset_minutes=120
        )
        try:
            driver.search_recordings(1, self.start, self.end)
        finally:
            patcher.stop()
        query = next(c for c in fake.sent if c["id"] == FILE_SEARCH)
        self.assertEqual(query["payload"]["OPFileQuery"]["BeginTime"], "2026-09-08 13:00:00")


class XiongmaiUrlTests(TestCase):
    def test_the_live_url_is_the_shape_this_firmware_serves(self):
        driver = XiongmaiDriver(target())
        self.assertEqual(
            driver.live_rtsp_url(3, quality=StreamQuality.SUB),
            "rtsp://admin:secret@192.168.1.100:554"
            "/user=admin&password=secret&channel=3&stream=1.sdp?",
        )

    def test_main_and_sub_pick_different_streams(self):
        driver = XiongmaiDriver(target())
        self.assertIn("stream=0", driver.live_rtsp_url(1, quality=StreamQuality.MAIN))
        self.assertIn("stream=1", driver.live_rtsp_url(1, quality=StreamQuality.SUB))

    def test_a_url_is_refused_with_an_explanation(self):
        with self.assertRaises(RecorderError):
            XiongmaiDriver(target()).playback_rtsp_url(1, None, None)

    def test_an_oem_variant_can_override_the_stream_path(self):
        """OEMs vary the suffix and the port. Control still comes from the
        native protocol, so channel names and search keep working while only the
        stream path changes."""
        driver = XiongmaiDriver(
            target(
                rtsp_port=5544,
                extra={"rtsp_path_template": "/user={username}&password={password}"
                       "&channel={channel}&stream={stream}.sdp?real_stream"},
            )
        )
        self.assertEqual(
            driver.live_rtsp_url(2, quality=StreamQuality.MAIN),
            "rtsp://admin:secret@192.168.1.100:5544"
            "/user=admin&password=secret&channel=2&stream=0.sdp?real_stream",
        )

    def test_playback_is_advertised_but_not_as_a_url(self):
        """Recordings come over the native protocol, so the driver produces
        bytes and the frame path pipes them into ffmpeg. Anything reaching for a
        URL gets a sentence rather than an AttributeError."""
        self.assertTrue(XiongmaiDriver.supports_playback)
        self.assertTrue(XiongmaiDriver.playback_is_streamed)
        with self.assertRaises(RecorderError):
            XiongmaiDriver(target()).playback_rtsp_url(1, None, None)

    def test_snapshot_is_refused_rather_than_returning_a_broken_image(self):
        with self.assertRaises(RecorderError):
            XiongmaiDriver(target()).snapshot(1)


class XiongmaiRegistrationTests(TestCase):
    def test_the_brand_is_choosable_and_detectable(self):
        self.assertIs(driver_class_for_brand("xiongmai"), XiongmaiDriver)
        self.assertIn(XiongmaiDriver, DRIVER_CLASSES)

    def test_it_is_tried_before_the_generic_onvif_fallback(self):
        """A Xiongmai also speaks ONVIF, but only its own protocol gives channel
        names and recording search."""
        names = [cls.brand for cls in DRIVER_CLASSES]
        self.assertLess(names.index("xiongmai"), names.index("onvif"))

    def test_it_advertises_search_and_playback_but_not_snapshots(self):
        recorder = Recorder(brand=Recorder.Brand.XIONGMAI, host="192.168.1.100")
        capabilities = recorder.driver_capabilities
        self.assertTrue(capabilities["search"])
        self.assertTrue(capabilities["playback"])
        self.assertFalse(capabilities["snapshot"])

    def test_the_default_port_is_the_xmeye_one(self):
        self.assertEqual(DVRIP_PORT, 34567)


# ---------------------------------------------------------------------------
# Playback: the de-framer and the download sequence.
#
# This is the part with no hardware behind it. The login and the recording
# search have both been confirmed against a real box; playback has not, so the
# byte layouts below are written out literally from the reference implementation
# and asserted rather than exercised. If firmware disagrees, these tests are the
# record of what we believed and where to look.
# ---------------------------------------------------------------------------
def i_frame(payload: bytes, *, fps=25, width=704, height=576) -> bytes:
    """0x1FC: a 16-byte header, then the H.264 payload."""
    return (
        b"\x00\x00\x01\xfc"
        + struct.pack("<BBBBII", 2, fps, width // 8, height // 8, 0, len(payload))
        + payload
    )


def p_frame(payload: bytes) -> bytes:
    """0x1FD: an 8-byte header, then the payload."""
    return b"\x00\x00\x01\xfd" + struct.pack("<I", len(payload)) + payload


def audio_frame(payload: bytes) -> bytes:
    """0x1FA: 8 bytes, and the payload must be skipped, not emitted."""
    return b"\x00\x00\x01\xfa" + struct.pack("<BBH", 0xE, 8, len(payload)) + payload


def info_frame(payload: bytes) -> bytes:
    return b"\x00\x00\x01\xf9" + struct.pack("<BBH", 1, 0, len(payload)) + payload


class MediaDeframerTests(TestCase):
    def test_video_payloads_come_out_and_headers_do_not(self):
        deframer = MediaDeframer()
        out = deframer.feed(i_frame(b"KEYFRAME") + p_frame(b"DELTA"))
        self.assertEqual(out, b"KEYFRAMEDELTA")

    def test_audio_and_metadata_are_skipped_without_desynchronising(self):
        """Their payloads must be consumed exactly, or every following frame
        header is read at the wrong offset and the stream turns to noise."""
        deframer = MediaDeframer()
        out = deframer.feed(
            i_frame(b"AAAA") + audio_frame(b"soundsound") + info_frame(b"meta") + p_frame(b"BBBB")
        )
        self.assertEqual(out, b"AAAABBBB")

    def test_a_frame_split_across_reads_is_reassembled(self):
        """A frame's payload spans several DVRIP packets, so the parser has to
        carry the remaining length across feeds."""
        blob = i_frame(b"0123456789")
        deframer = MediaDeframer()
        collected = b"".join(deframer.feed(blob[i : i + 3]) for i in range(0, len(blob), 3))
        self.assertEqual(collected + deframer.flush(), b"0123456789")

    def test_a_header_split_across_reads_is_reassembled(self):
        deframer = MediaDeframer()
        blob = p_frame(b"PAYLOAD")
        first = deframer.feed(blob[:6])
        self.assertEqual(first, b"")
        self.assertEqual(first + deframer.feed(blob[6:]), b"PAYLOAD")

    def test_an_unframed_stream_is_passed_straight_through(self):
        """The reference reads downloads with a raw chunk loop, which suggests
        they arrive already unwrapped — but nobody has confirmed that against
        this firmware, so the first bytes decide instead of an assumption."""
        deframer = MediaDeframer()
        annexb = b"\x00\x00\x00\x01\x67SPS\x00\x00\x00\x01\x65IDR"
        self.assertEqual(deframer.feed(annexb), annexb)
        self.assertFalse(deframer.framed)

    def test_a_framed_stream_is_recognised_as_framed(self):
        deframer = MediaDeframer()
        deframer.feed(i_frame(b"X"))
        self.assertTrue(deframer.framed)

    def test_a_marker_cannot_be_confused_with_the_video_inside_it(self):
        """Markers are 0xF9-0xFE; an H.264 NAL header always has its top bit
        clear. That non-overlap is what makes this framing separable at all."""
        payload = b"\x00\x00\x01\x65IDR\x00\x00\x01\x41SLICE"
        deframer = MediaDeframer()
        self.assertEqual(deframer.feed(i_frame(payload)), payload)

    def test_garbage_where_a_header_belongs_stops_rather_than_guesses(self):
        deframer = MediaDeframer()
        deframer.feed(i_frame(b"AA"))
        with self.assertRaises(RecorderError):
            deframer.feed(b"\x00\x00\x01\x11nonsense")

    def test_a_recording_that_ends_mid_frame_still_yields_what_arrived(self):
        """Bytes are emitted as they arrive, so a truncated final NAL passes
        through; ffmpeg decodes what it can. Withholding it would mean buffering
        every frame whole, which defeats streaming."""
        deframer = MediaDeframer()
        self.assertEqual(deframer.feed(i_frame(b"COMPLETE")), b"COMPLETE")
        # The header promises 99 bytes and the recording stops after 5. Those 5
        # leave on the feed that carried them, not on the flush — holding them
        # back until the frame completed would be buffering, not streaming.
        truncated = b"\x00\x00\x01\xfd" + struct.pack("<I", 99) + b"short"
        self.assertEqual(deframer.feed(truncated), b"short")
        self.assertEqual(deframer.flush(), b"")

    def test_nothing_is_emitted_before_the_type_is_known(self):
        deframer = MediaDeframer()
        self.assertEqual(deframer.feed(b"\x00\x00"), b"")
        self.assertIsNone(deframer.framed)


ONE_RECORDING = {"Ret": 100, "OPFileQuery": [FILE_QUERY["OPFileQuery"][0]]}


class _DownloadSocket(_FakeSocket):
    """A box that answers a download: JSON for control, binary for video.

    ``DownloadStart`` is deliberately given no JSON reply, because the driver
    does not read one — from that point the socket carries video, and a JSON
    read there would swallow the first frames.
    """

    def __init__(self, replies, *, videos=(), packets=1, session=SESSION):
        super().__init__(replies, session=session)
        # One entry per download, so a window spanning two recordings can be
        # told apart from one recording served twice.
        self.videos = list(videos)
        self.packets = packets
        self.actions = []
        self.downloads = 0

    def sendall(self, data):
        header, body = data[:20], data[20:]
        message_id = HEADER.unpack(header)[6]
        payload = json.loads(body[: -len(TAIL)].decode("utf-8"))
        self.sent.append({"id": message_id, "payload": payload})
        if message_id == PLAYBACK:
            action = payload["OPPlayBack"]["Action"]
            self.actions.append(action)
            if action == "Claim":
                self._queue(message_id + 1, {"Ret": 100})
            elif action == "DownloadStart":
                self._queue_video()
            return
        reply = self.replies.get(message_id, {"Ret": 100})
        self._queue(message_id + 1, reply)

    def _queue_video(self):
        video = self.videos[min(self.downloads, len(self.videos) - 1)]
        self.downloads += 1
        step = max(len(video) // self.packets, 1)
        for index in range(0, len(video), step):
            chunk = video[index : index + step]
            self._inbox += HEADER.pack(
                0xFF, 0x00, self.session, 0, 0, 0, PLAYBACK + 1, len(chunk)
            ) + chunk
        # A header declaring zero bytes is how this protocol says "that is all".
        self._inbox += HEADER.pack(0xFF, 0x00, self.session, 0, 0, 0, PLAYBACK + 1, 0)


class XiongmaiPlaybackTests(TestCase):
    def setUp(self):
        self.start = datetime(2026, 9, 8, 11, 0, tzinfo=dt_timezone.utc)
        self.end = self.start + timedelta(minutes=30)

    def driver_for(self, *videos, packets=1, search=None, **target_kwargs):
        fake = _DownloadSocket(
            {
                LOGIN: {"Ret": 100, "SessionID": f"0x{SESSION:08x}"},
                FILE_SEARCH: search or ONE_RECORDING,
            },
            videos=videos,
            packets=packets,
        )
        driver = XiongmaiDriver(target(**target_kwargs))
        patcher = patch(
            "apps.surveillance.drivers.xiongmai.socket.create_connection",
            return_value=fake,
        )
        patcher.start()
        self.addCleanup(patcher.stop)
        return driver, fake

    def test_a_window_plays_back_as_a_plain_h264_stream(self):
        video = i_frame(b"KEY") + audio_frame(b"noise") + p_frame(b"DELTA")
        driver, _fake = self.driver_for(video)  # one recording in the window
        out = b"".join(driver.playback_stream(1, self.start, self.end))
        self.assertEqual(out, b"KEYDELTA")

    def test_the_recording_is_claimed_before_it_is_started_and_stopped_after(self):
        driver, fake = self.driver_for(i_frame(b"X"))
        list(driver.playback_stream(1, self.start, self.end))
        # Two recordings overlap the window in the fixture, so the sequence
        # repeats; what matters is the order within each.
        self.assertEqual(fake.actions[:3], ["Claim", "DownloadStart", "DownloadStop"])

    def test_it_asks_for_the_file_the_search_named(self):
        """This is why playback rests on the search: ByName wants exactly the
        filename OPFileQuery returns."""
        driver, fake = self.driver_for(i_frame(b"X"))
        list(driver.playback_stream(1, self.start, self.end))
        claim = next(c for c in fake.sent if c["id"] == PLAYBACK)
        parameter = claim["payload"]["OPPlayBack"]["Parameter"]
        self.assertEqual(parameter["PlayMode"], "ByName")
        self.assertEqual(parameter["FileName"], FILE_QUERY["OPFileQuery"][0]["FileName"])

    def test_the_window_is_expressed_in_the_recorders_own_clock(self):
        """A DVR left on the factory timezone would otherwise be asked for the
        wrong hour and answer, wrongly, that it has nothing."""
        driver, fake = self.driver_for(i_frame(b"X"), clock_offset_minutes=120)
        list(driver.playback_stream(1, self.start, self.end))
        claim = next(c for c in fake.sent if c["id"] == PLAYBACK)
        self.assertEqual(claim["payload"]["OPPlayBack"]["StartTime"], "2026-09-08 13:00:00")

    def test_video_split_across_packets_is_reassembled(self):
        video = i_frame(b"ABCDEFGHIJKLMNOP")
        driver, _fake = self.driver_for(video, packets=7)
        out = b"".join(driver.playback_stream(1, self.start, self.end))
        self.assertEqual(out, b"ABCDEFGHIJKLMNOP")

    def test_a_window_spanning_two_recordings_plays_both_in_order(self):
        """A sale near the boundary of the DVR's file rotation must not lose the
        half of its window that lives in the next file."""
        driver, fake = self.driver_for(
            i_frame(b"FIRST"), i_frame(b"SECOND"), search=FILE_QUERY
        )
        out = b"".join(driver.playback_stream(1, self.start, self.end))
        self.assertEqual(out, b"FIRSTSECOND")
        self.assertEqual(fake.downloads, 2)

    def test_walking_away_mid_recording_still_stops_the_download(self):
        """A download the recorder believes is running holds one of the handful
        of sessions it will grant. Leaking those is how a DVR stops answering."""
        driver, fake = self.driver_for(i_frame(b"A" * 64), packets=8)
        stream = driver.playback_stream(1, self.start, self.end)
        next(stream)
        stream.close()
        self.assertIn("DownloadStop", fake.actions)

    def test_a_window_with_no_footage_says_so(self):
        fake = _DownloadSocket(
            {
                LOGIN: {"Ret": 100, "SessionID": f"0x{SESSION:08x}"},
                FILE_SEARCH: {"Ret": 100, "OPFileQuery": []},
            }
        )
        driver = XiongmaiDriver(target())
        with patch(
            "apps.surveillance.drivers.xiongmai.socket.create_connection",
            return_value=fake,
        ):
            with self.assertRaises(RecorderError) as caught:
                list(driver.playback_stream(1, self.start, self.end))
        self.assertIn("no footage", str(caught.exception).lower())


class MediaDeframerStatsTests(TestCase):
    """The codec and geometry a recorder is really sending.

    Free to collect — the I-frame header has to be parsed to skip it anyway —
    and invisible everywhere else, because nothing downstream of the driver ever
    sees the source stream. A box quietly sending H.265 to a pipeline expecting
    H.264 shows up as "the picture looks wrong" and nothing more.
    """

    def test_the_first_keyframe_reveals_codec_and_geometry(self):
        deframer = MediaDeframer()
        deframer.feed(i_frame(b"KEY", fps=12, width=704, height=576))
        self.assertEqual(deframer.stats["codec"], "h264")
        self.assertEqual(deframer.stats["source_fps"], 12.0)
        self.assertEqual(deframer.stats["source_width"], 704)
        self.assertEqual(deframer.stats["source_height"], 576)

    def test_the_stats_dict_is_never_rebound(self):
        """The driver hands this dict to the streaming layer before a single
        frame has been read. Rebinding it would leave that holding an empty one
        for the life of the stream."""
        deframer = MediaDeframer()
        captured = deframer.stats
        deframer.feed(i_frame(b"KEY"))
        self.assertIs(captured, deframer.stats)
        self.assertEqual(captured["codec"], "h264")

    def test_an_unframed_stream_reveals_nothing_and_claims_nothing(self):
        deframer = MediaDeframer()
        deframer.feed(b"\x00\x00\x00\x01\x67SPS")
        self.assertEqual(deframer.stats, {})


class XiongmaiSearchPaginationTests(TestCase):
    """``OPFileQuery`` answers at most 64 rows and then reports success.

    A single query therefore truncates a busy day silently, and the caller
    cannot tell a short answer from a complete one — which for invoice-linked
    footage means telling a shop "nothing was recorded then" about a sale the
    recorder has perfectly good video of.
    """

    def setUp(self):
        self.start = datetime(2026, 9, 8, 8, 0, tzinfo=dt_timezone.utc)
        self.end = self.start + timedelta(hours=12)

    @staticmethod
    def page(first_minute: int, count: int) -> dict:
        """``count`` consecutive one-minute recordings, oldest first."""
        rows = []
        for index in range(count):
            minute = first_minute + index
            begins = datetime(2026, 9, 8, 8, 0) + timedelta(minutes=minute)
            ends = begins + timedelta(minutes=1)
            rows.append(
                {
                    "BeginTime": begins.strftime("%Y-%m-%d %H:%M:%S"),
                    "EndTime": ends.strftime("%Y-%m-%d %H:%M:%S"),
                    "FileLength": "1024",
                    "FileName": f"/idea0/clip-{minute:04d}.h264",
                }
            )
        return {"Ret": 100, "OPFileQuery": rows}

    def test_a_full_page_is_followed_up_until_the_box_runs_out(self):
        pages = [
            self.page(0, SEARCH_PAGE_SIZE),
            self.page(SEARCH_PAGE_SIZE, SEARCH_PAGE_SIZE),
            self.page(SEARCH_PAGE_SIZE * 2, 5),
        ]
        served = []

        def answer(_payload):
            served.append(len(served))
            return pages[min(len(served) - 1, len(pages) - 1)]

        driver, fake, patcher = driver_with({FILE_SEARCH: answer})
        try:
            segments = driver.search_recordings(1, self.start, self.end)
        finally:
            patcher.stop()

        self.assertEqual(len(segments), SEARCH_PAGE_SIZE * 2 + 5)
        # Every page after the first must have moved BeginTime forward.
        queries = [c for c in fake.sent if c["id"] == FILE_SEARCH]
        self.assertEqual(len(queries), 3)
        begins = [q["payload"]["OPFileQuery"]["BeginTime"] for q in queries]
        self.assertEqual(begins, sorted(begins))
        self.assertNotEqual(begins[0], begins[1])

    def test_a_short_first_page_asks_only_once(self):
        driver, fake, patcher = driver_with({FILE_SEARCH: self.page(0, 3)})
        try:
            segments = driver.search_recordings(1, self.start, self.end)
        finally:
            patcher.stop()

        self.assertEqual(len(segments), 3)
        self.assertEqual(len([c for c in fake.sent if c["id"] == FILE_SEARCH]), 1)

    def test_a_box_that_ignores_begintime_cannot_spin_forever(self):
        """Some firmware returns the same full page whatever it is asked.

        Two independent guards catch it — the page adds nothing new, and the
        page count is capped — because an unbounded search loop against a DVR is
        how this feature would take a recorder down instead of reading from it.
        """
        driver, fake, patcher = driver_with(
            {FILE_SEARCH: self.page(0, SEARCH_PAGE_SIZE)}
        )
        try:
            segments = driver.search_recordings(1, self.start, self.end)
        finally:
            patcher.stop()

        self.assertEqual(len(segments), SEARCH_PAGE_SIZE, "de-duplicated")
        queries = [c for c in fake.sent if c["id"] == FILE_SEARCH]
        self.assertLessEqual(len(queries), MAX_SEARCH_PAGES)
        self.assertLessEqual(len(queries), 2, "and it notices on the second page")

    def test_segments_come_back_in_time_order(self):
        pages = [self.page(10, SEARCH_PAGE_SIZE), self.page(0, 2)]
        served = []

        def answer(_payload):
            served.append(len(served))
            return pages[min(len(served) - 1, len(pages) - 1)]

        driver, _fake, patcher = driver_with({FILE_SEARCH: answer})
        try:
            segments = driver.search_recordings(1, self.start, self.end)
        finally:
            patcher.stop()

        self.assertEqual(
            [segment.start for segment in segments],
            sorted(segment.start for segment in segments),
        )
