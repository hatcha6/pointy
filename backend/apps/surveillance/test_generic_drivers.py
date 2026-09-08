"""The two drivers that exist for the boxes nobody chose on purpose.

Between them, ONVIF and Direct RTSP are what a Libyan shop's DVR usually is: a
Xiongmai or an OEM relabel that speaks neither vendor dialect. The risks here
are different from the named brands', so these tests are about those:

* ONVIF **lies about its own address** — it answers ``GetCapabilities`` with
  whatever IP its config file holds, which after a NAT, a second NIC or a clone
  is not the one that just worked. Following it silently breaks every later call.
* ONVIF **is sold in profiles**, and the cheap boxes ship Profile S without
  Profile G. Reporting playback that does not exist puts a button in the client
  that can only fail.
* ONVIF **publishes one profile per encoder**, so a 16-channel NVR lists 32 of
  them. Read naively, every camera appears twice.
* Direct RTSP **cannot be probed at all**, so everything rests on a template a
  person typed — and a typo must fail where it was typed, not inside ffmpeg.
"""

from unittest.mock import patch

from django.test import TestCase

from .drivers.base import (
    RecorderAuthError,
    RecorderError,
    RecorderTarget,
    RecorderUnreachable,
    StreamQuality,
)
from .drivers.generic_rtsp import TEMPLATE_PRESETS, GenericRtspDriver
from .drivers.onvif import OnvifDriver, _service_path, _with_credentials
from .drivers.registry import DRIVERS_BY_BRAND, DRIVER_CLASSES, driver_class_for_brand
from .models import Recorder

DEVICE_INFO = """<?xml version="1.0"?>
<s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope">
 <s:Body><tds:GetDeviceInformationResponse xmlns:tds="http://www.onvif.org/ver10/device/wsdl">
  <tds:Manufacturer>Xiongmai</tds:Manufacturer>
  <tds:Model>NBD8016</tds:Model>
  <tds:FirmwareVersion>V4.03.R11</tds:FirmwareVersion>
  <tds:SerialNumber>ba6e60b40b9556ae</tds:SerialNumber>
 </tds:GetDeviceInformationResponse></s:Body></s:Envelope>"""

DATE_TIME = """<?xml version="1.0"?>
<s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope">
 <s:Body><tds:GetSystemDateAndTimeResponse xmlns:tds="http://www.onvif.org/ver10/device/wsdl">
  <tds:SystemDateAndTime><tt:LocalDateTime xmlns:tt="http://www.onvif.org/ver10/schema">
   <tt:Date><tt:Year>2026</tt:Year><tt:Month>9</tt:Month><tt:Day>8</tt:Day></tt:Date>
   <tt:Time><tt:Hour>11</tt:Hour><tt:Minute>30</tt:Minute><tt:Second>0</tt:Second></tt:Time>
  </tt:LocalDateTime></tds:SystemDateAndTime>
 </tds:GetSystemDateAndTimeResponse></s:Body></s:Envelope>"""

# The address inside is deliberately NOT the one we connected on. See the module
# docstring: this is the single most common way an ONVIF integration breaks.
CAPABILITIES_LIVE_ONLY = """<?xml version="1.0"?>
<s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope">
 <s:Body><tds:GetCapabilitiesResponse xmlns:tds="http://www.onvif.org/ver10/device/wsdl">
  <tds:Capabilities xmlns:tt="http://www.onvif.org/ver10/schema">
   <tt:Media><tt:XAddr>http://10.10.10.7:8899/onvif/media_service</tt:XAddr></tt:Media>
  </tds:Capabilities></tds:GetCapabilitiesResponse></s:Body></s:Envelope>"""

CAPABILITIES_WITH_PLAYBACK = """<?xml version="1.0"?>
<s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope">
 <s:Body><tds:GetCapabilitiesResponse xmlns:tds="http://www.onvif.org/ver10/device/wsdl">
  <tds:Capabilities xmlns:tt="http://www.onvif.org/ver10/schema">
   <tt:Media><tt:XAddr>http://10.10.10.7/onvif/media_service</tt:XAddr></tt:Media>
   <tt:Replay><tt:XAddr>http://10.10.10.7/onvif/replay_service</tt:XAddr></tt:Replay>
   <tt:Search><tt:XAddr>http://10.10.10.7/onvif/search_service</tt:XAddr></tt:Search>
  </tds:Capabilities></tds:GetCapabilitiesResponse></s:Body></s:Envelope>"""

# Two cameras, two encoders each — the shape that makes a 16-channel box list 32
# profiles. VideoSource_1 is deliberately listed sub-first so the grouping
# cannot pass by accident of ordering.
PROFILES = """<?xml version="1.0"?>
<s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope">
 <s:Body><trt:GetProfilesResponse xmlns:trt="http://www.onvif.org/ver10/media/wsdl"
   xmlns:tt="http://www.onvif.org/ver10/schema">
  <trt:Profiles token="prof_1_sub"><tt:Name>Counter sub</tt:Name>
   <tt:VideoSourceConfiguration><tt:SourceToken>VideoSource_1</tt:SourceToken>
   </tt:VideoSourceConfiguration>
   <tt:VideoEncoderConfiguration><tt:Resolution>
     <tt:Width>352</tt:Width><tt:Height>288</tt:Height>
   </tt:Resolution></tt:VideoEncoderConfiguration></trt:Profiles>
  <trt:Profiles token="prof_1_main"><tt:Name>Counter</tt:Name>
   <tt:VideoSourceConfiguration><tt:SourceToken>VideoSource_1</tt:SourceToken>
   </tt:VideoSourceConfiguration>
   <tt:VideoEncoderConfiguration><tt:Resolution>
     <tt:Width>1920</tt:Width><tt:Height>1080</tt:Height>
   </tt:Resolution></tt:VideoEncoderConfiguration></trt:Profiles>
  <trt:Profiles token="prof_2_main"><tt:Name>Store room</tt:Name>
   <tt:VideoSourceConfiguration><tt:SourceToken>VideoSource_2</tt:SourceToken>
   </tt:VideoSourceConfiguration>
   <tt:VideoEncoderConfiguration><tt:Resolution>
     <tt:Width>1280</tt:Width><tt:Height>720</tt:Height>
   </tt:Resolution></tt:VideoEncoderConfiguration></trt:Profiles>
  <trt:Profiles token="prof_2_sub"><tt:Name>Store room sub</tt:Name>
   <tt:VideoSourceConfiguration><tt:SourceToken>VideoSource_2</tt:SourceToken>
   </tt:VideoSourceConfiguration>
   <tt:VideoEncoderConfiguration><tt:Resolution>
     <tt:Width>352</tt:Width><tt:Height>288</tt:Height>
   </tt:Resolution></tt:VideoEncoderConfiguration></trt:Profiles>
 </trt:GetProfilesResponse></s:Body></s:Envelope>"""

STREAM_URI = """<?xml version="1.0"?>
<s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope">
 <s:Body><trt:GetStreamUriResponse xmlns:trt="http://www.onvif.org/ver10/media/wsdl"
   xmlns:tt="http://www.onvif.org/ver10/schema">
  <trt:MediaUri><tt:Uri>rtsp://10.10.10.7:554/cam/realmonitor?channel=1</tt:Uri>
  </trt:MediaUri></trt:GetStreamUriResponse></s:Body></s:Envelope>"""

AUTH_FAULT = """<?xml version="1.0"?>
<s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope">
 <s:Body><s:Fault><s:Code><s:Value>s:Sender</s:Value>
  <s:Subcode><s:Value>ter:NotAuthorized</s:Value></s:Subcode></s:Code>
  <s:Reason><s:Text>Sender not authorized</s:Text></s:Reason>
 </s:Fault></s:Body></s:Envelope>"""


class _Response:
    def __init__(self, text, status_code=200):
        self.content = text.encode("utf-8")
        self.status_code = status_code


class StubOnvif(OnvifDriver):
    """Answer SOAP from a table, keyed by the operation in the request body.

    Stubbed at the transport, not at ``_call``, so the envelope building, the
    WS-Security header and the fault handling are all really exercised.
    """

    def __init__(self, target, responses, *, device_paths=("/onvif/device_service",)):
        super().__init__(target)
        self.responses = responses
        self.device_paths = device_paths
        self.calls = []

    def request(self, path, *, method="GET", read_timeout=None, **kwargs):
        body = kwargs.get("data", b"").decode("utf-8")
        self.calls.append((path, body))
        if path.startswith("/onvif") and path not in self.device_paths and (
            "GetSystemDateAndTime" in body or "GetDeviceInformation" in body
        ):
            return _Response("<html>404</html>", status_code=404)
        for operation, payload in self.responses.items():
            if operation in body:
                return _Response(payload)
        return _Response("<html>not found</html>", status_code=404)

    def get_bytes(self, path, **kwargs):
        self.calls.append((path, "GET"))
        return b"\xff\xd8jpeg\xff\xd9"


def target(**overrides):
    values = {
        "host": "192.168.1.100",
        "port": 80,
        "rtsp_port": 554,
        "username": "admin",
        "password": "p@ss/word",
    }
    values.update(overrides)
    return RecorderTarget(**values)


LIVE_ONLY = {
    "GetSystemDateAndTime": DATE_TIME,
    "GetDeviceInformation": DEVICE_INFO,
    "GetCapabilities": CAPABILITIES_LIVE_ONLY,
    "GetProfiles": PROFILES,
    "GetStreamUri": STREAM_URI,
}


class OnvifDriverTests(TestCase):
    def test_a_16_channel_box_is_not_listed_twice(self):
        """Profiles are grouped by video source, so two encoders are one camera."""
        driver = StubOnvif(target(), LIVE_ONLY)
        channels = driver.list_channels()
        self.assertEqual([c.channel for c in channels], [1, 2])
        self.assertEqual([c.name for c in channels], ["Counter", "Store room"])

    def test_main_and_sub_come_from_the_same_camera(self):
        driver = StubOnvif(target(), LIVE_ONLY)
        driver.list_channels()
        self.assertEqual(driver._profile_token(1, StreamQuality.MAIN), "prof_1_main")
        self.assertEqual(driver._profile_token(1, StreamQuality.SUB), "prof_1_sub")
        self.assertEqual(driver._profile_token(2, StreamQuality.MAIN), "prof_2_main")
        self.assertEqual(driver._profile_token(2, StreamQuality.SUB), "prof_2_sub")

    def test_the_device_reported_service_host_is_ignored(self):
        """The box says 10.10.10.7; we reached it at 192.168.1.100.

        Only the path may be believed — see the module docstring.
        """
        driver = StubOnvif(target(), LIVE_ONLY)
        driver.list_channels()
        media_calls = [path for path, body in driver.calls if "GetProfiles" in body]
        self.assertEqual(media_calls, ["/onvif/media_service"])

    def test_playback_is_refused_when_the_device_has_no_profile_g(self):
        driver = StubOnvif(target(), LIVE_ONLY)
        driver._load_capabilities()
        self.assertFalse(driver.supports_playback)
        self.assertFalse(driver.supports_search)
        with self.assertRaises(RecorderError):
            driver.playback_rtsp_url(1, None, None)

    def test_playback_is_offered_when_the_device_does_have_it(self):
        driver = StubOnvif(
            target(), {**LIVE_ONLY, "GetCapabilities": CAPABILITIES_WITH_PLAYBACK}
        )
        driver._load_capabilities()
        self.assertTrue(driver.supports_playback)
        self.assertTrue(driver.supports_search)

    def test_the_stream_url_carries_escaped_credentials(self):
        """ffmpeg gets one argv element, so the login has to be in the URL —
        and a ``/`` in the password must not redraw the path."""
        driver = StubOnvif(target(), LIVE_ONLY)
        url = driver.live_rtsp_url(1, quality=StreamQuality.MAIN)
        self.assertIn("admin:p%40ss%2Fword@", url)
        self.assertNotIn("p@ss/word", url)

    def test_a_rejected_password_is_reported_as_a_password_problem(self):
        """ONVIF faults arrive as HTTP 400. Without reading the subcode, every
        wrong password would be reported as an unsupported recorder."""
        driver = StubOnvif(
            target(), {"GetSystemDateAndTime": DATE_TIME, "GetDeviceInformation": AUTH_FAULT}
        )
        with self.assertRaises(RecorderAuthError):
            driver.probe()

    def test_probe_reports_what_the_box_calls_itself(self):
        driver = StubOnvif(target(), LIVE_ONLY)
        info = driver.probe()
        self.assertEqual(info.brand, "onvif")
        self.assertEqual(info.model, "Xiongmai NBD8016")
        self.assertEqual(info.serial, "ba6e60b40b9556ae")
        self.assertEqual(info.channel_count, 2)

    def test_a_box_on_an_oem_service_path_is_still_found(self):
        driver = StubOnvif(target(), LIVE_ONLY, device_paths=("/onvif/services",))
        self.assertEqual(driver._find_device_service(), "/onvif/services")

    def test_a_box_that_speaks_no_onvif_is_not_claimed(self):
        driver = StubOnvif(target(), {})
        with self.assertRaises(RecorderError):
            driver.probe()

    def test_an_unreachable_host_stops_after_the_first_path(self):
        """Four connect timeouts on a dead box is four times the wait for an
        installer who mistyped an IP."""
        driver = StubOnvif(target(), LIVE_ONLY)
        with patch.object(
            StubOnvif, "request", side_effect=RecorderUnreachable("no route")
        ):
            with self.assertRaises(RecorderUnreachable):
                driver._find_device_service()

    def test_service_path_keeps_only_the_path(self):
        self.assertEqual(
            _service_path("http://10.0.0.9:8899/onvif/media", "/x"), "/onvif/media"
        )
        self.assertEqual(_service_path("", "/fallback"), "/fallback")

    def test_credentials_are_not_added_to_an_anonymous_stream(self):
        self.assertEqual(
            _with_credentials("rtsp://1.2.3.4/live", "", ""), "rtsp://1.2.3.4/live"
        )


class GenericRtspDriverTests(TestCase):
    def make(self, template=None, channels=4, **overrides):
        return GenericRtspDriver(
            target(
                extra={
                    "rtsp_path_template": (
                        TEMPLATE_PRESETS["xmeye"] if template is None else template
                    ),
                    "channel_count": channels,
                },
                **overrides,
            )
        )

    def test_the_xmeye_preset_builds_the_url_that_box_serves(self):
        url = self.make().live_rtsp_url(3, quality=StreamQuality.SUB)
        self.assertEqual(
            url,
            "rtsp://admin:p%40ss%2Fword@192.168.1.100:554"
            "/user=admin&password=p@ss/word&channel=3&stream=1.sdp?",
        )

    def test_main_and_sub_select_different_streams(self):
        driver = self.make(template="/ch{channel}/{stream}")
        self.assertTrue(driver.live_rtsp_url(2, quality=StreamQuality.MAIN).endswith("/ch2/0"))
        self.assertTrue(driver.live_rtsp_url(2, quality=StreamQuality.SUB).endswith("/ch2/1"))

    def test_zero_based_firmwares_are_expressible(self):
        driver = self.make(template="/live/ch{channel0}_{stream}")
        self.assertTrue(driver.live_rtsp_url(1).endswith("/live/ch0_1"))

    def test_a_template_missing_its_leading_slash_still_works(self):
        driver = self.make(template="ch{channel}")
        self.assertIn("/ch1", driver.live_rtsp_url(1))

    def test_a_typo_in_the_template_fails_where_it_was_typed(self):
        """Not inside ffmpeg, where the message would be about a stream rather
        than about the field someone just filled in."""
        driver = self.make(template="/ch{chanel}")
        with self.assertRaises(RecorderError) as caught:
            driver.live_rtsp_url(1)
        self.assertIn("template", str(caught.exception))

    def test_channels_come_from_the_count_a_person_typed(self):
        self.assertEqual([c.channel for c in self.make(channels=4).list_channels()], [1, 2, 3, 4])

    def test_without_a_channel_count_it_says_so_rather_than_showing_nothing(self):
        with self.assertRaises(RecorderError):
            self.make(channels=0).list_channels()

    def test_without_a_template_the_probe_refuses(self):
        with self.assertRaises(RecorderError):
            self.make(template="").probe()

    def test_the_probe_is_a_real_connection_test(self):
        with patch(
            "apps.surveillance.drivers.generic_rtsp.socket.create_connection",
            side_effect=OSError("refused"),
        ):
            with self.assertRaises(RecorderUnreachable):
                self.make().probe()

    def test_a_reachable_port_identifies_the_recorder(self):
        with patch("apps.surveillance.drivers.generic_rtsp.socket.create_connection"):
            info = self.make(channels=8).probe()
        self.assertEqual(info.brand, "generic_rtsp")
        self.assertEqual(info.channel_count, 8)

    def test_snapshot_is_refused_rather_than_returning_a_broken_image(self):
        with self.assertRaises(RecorderError):
            self.make().snapshot(1)

    def test_playback_is_refused(self):
        with self.assertRaises(RecorderError):
            self.make().playback_rtsp_url(1, None, None)


class RegistryTests(TestCase):
    def test_direct_rtsp_can_be_chosen_but_never_detected(self):
        """It has no identity endpoint. In an ordered search it would always
        win, and every box in the fleet would become a generic one."""
        self.assertNotIn(GenericRtspDriver, DRIVER_CLASSES)
        self.assertIs(driver_class_for_brand("generic_rtsp"), GenericRtspDriver)

    def test_onvif_is_tried_last(self):
        """A Hikvision also speaks ONVIF; detecting it as ONVIF would trade its
        recording search away for nothing."""
        self.assertIs(DRIVER_CLASSES[-1], OnvifDriver)

    def test_every_brand_choice_has_a_driver(self):
        for value, _label in Recorder.Brand.choices:
            if value == Recorder.Brand.AUTO:
                continue
            self.assertIn(value, DRIVERS_BY_BRAND, f"no driver for brand {value!r}")


class CapabilityTests(TestCase):
    def test_a_direct_rtsp_recorder_advertises_live_only(self):
        recorder = Recorder(brand=Recorder.Brand.DIRECT_RTSP, host="192.168.1.100")
        self.assertEqual(
            recorder.driver_capabilities,
            {"playback": False, "search": False, "snapshot": False},
        )

    def test_a_dahua_still_advertises_everything(self):
        recorder = Recorder(brand=Recorder.Brand.DAHUA, host="192.168.1.64")
        self.assertEqual(
            recorder.driver_capabilities,
            {"playback": True, "search": True, "snapshot": True},
        )

    def test_the_detected_brand_wins_over_the_chosen_one(self):
        recorder = Recorder(
            brand=Recorder.Brand.DIRECT_RTSP,
            detected_brand=Recorder.Brand.DAHUA,
            host="192.168.1.64",
        )
        self.assertTrue(recorder.driver_capabilities["playback"])

    def test_brand_settings_reach_the_driver(self):
        recorder = Recorder(
            brand=Recorder.Brand.DIRECT_RTSP,
            host="192.168.1.100",
            rtsp_path_template="/ch{channel}/{stream}",
            channel_count=6,
        )
        extra = recorder.as_target().extra
        self.assertEqual(extra["rtsp_path_template"], "/ch{channel}/{stream}")
        self.assertEqual(extra["channel_count"], 6)
