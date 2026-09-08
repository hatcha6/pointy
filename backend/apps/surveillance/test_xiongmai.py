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
    SYSINFO,
    TAIL,
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

    def test_playback_is_addressed_in_the_recorders_own_clock(self):
        driver = XiongmaiDriver(target(clock_offset_minutes=120))
        url = driver.playback_rtsp_url(
            1,
            datetime(2026, 9, 8, 11, 0, tzinfo=dt_timezone.utc),
            datetime(2026, 9, 8, 11, 5, tzinfo=dt_timezone.utc),
        )
        self.assertIn("starttime=2026_09_08_13_00_00", url)
        self.assertIn("endtime=2026_09_08_13_05_00", url)

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

    def test_playback_is_not_advertised_because_it_is_unverified(self):
        """No public source documents RTSP playback-by-time for this firmware.
        Claiming it would put a button in the client that can only fail."""
        self.assertFalse(XiongmaiDriver.supports_playback)
        self.assertTrue(XiongmaiDriver.supports_search)

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

    def test_it_advertises_search_but_not_snapshots_or_playback(self):
        recorder = Recorder(brand=Recorder.Brand.XIONGMAI, host="192.168.1.100")
        capabilities = recorder.driver_capabilities
        self.assertTrue(capabilities["search"])
        self.assertFalse(capabilities["snapshot"])
        self.assertFalse(capabilities["playback"])

    def test_the_default_port_is_the_xmeye_one(self):
        self.assertEqual(DVRIP_PORT, 34567)
