#!/usr/bin/env python3
"""An ONVIF device that misbehaves the way the cheap ones actually misbehave.

``test_generic_drivers.py`` names three failures as the ones that break an ONVIF
integration in the field. All three are answered with hand-written XML in that
file, which pins the parsing but never proves the driver survives them over a
real socket, against real SOAP, with a real RTSP URL at the end. This device
does all three at once, by default, because that is the box a Libyan shop has:

* **It lies about its own address.** ``GetCapabilities`` answers with the IP in
  its config file — here a deliberately unroutable one — not the address you
  reached it on. A driver that follows the returned host sends every later call
  into a black hole; ours keeps the host and takes only the path.
* **It sells Profile S without Profile G.** No replay, no recording search. A
  driver that reports playback anyway puts a button in the client that can only
  fail. Pass ``--profile-g`` to watch the capability appear.
* **It publishes one profile per encoder.** Main and sub for every channel, so a
  4-channel box answers ``GetProfiles`` with 8 entries. Read naively, every
  camera shows up twice.

``GetStreamUri`` hands back the MediaMTX address, so a client that gets through
all three traps is rewarded with real H.264 — the ONVIF path proves itself end
to end rather than stopping at "the XML parsed".

    python3 fake_onvif.py --port 8000 --rtsp rtsp://mediamtx:8554/shop
"""

from __future__ import annotations

import argparse
import re
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

NS = (
    'xmlns:s="http://www.w3.org/2003/05/soap-envelope" '
    'xmlns:tds="http://www.onvif.org/ver10/device/wsdl" '
    'xmlns:trt="http://www.onvif.org/ver10/media/wsdl" '
    'xmlns:trp="http://www.onvif.org/ver10/replay/wsdl" '
    'xmlns:tse="http://www.onvif.org/ver10/search/wsdl" '
    'xmlns:tt="http://www.onvif.org/ver10/schema"'
)

DEVICE_PATH = "/onvif/device_service"
MEDIA_PATH = "/onvif/media_service"

#: The address the device recites instead of the one you reached it on. Chosen
#: from TEST-NET-1 (RFC 5737) so that a driver which wrongly follows it fails by
#: timing out on a documented dead address rather than reaching something real.
LIE_HOST = "192.0.2.77"


def envelope(body: str) -> bytes:
    return (
        f'<?xml version="1.0" encoding="UTF-8"?>'
        f"<s:Envelope {NS}><s:Body>{body}</s:Body></s:Envelope>"
    ).encode()


class Device:
    def __init__(self, args):
        self.rtsp = args.rtsp
        self.channels = args.channels
        self.profile_g = args.profile_g
        self.duplicate_profiles = not args.single_profile
        self.lie = not args.honest_xaddr
        self.advertised = LIE_HOST if self.lie else None

    def xaddr(self, host: str, path: str) -> str:
        return f"http://{self.advertised or host}{path}"

    def profiles(self) -> str:
        """One profile per encoder, which is what an NVR really answers."""
        out = []
        qualities = ("main", "sub") if self.duplicate_profiles else ("main",)
        for channel in range(1, self.channels + 1):
            for quality in qualities:
                token = f"ch{channel}_{quality}"
                width, height = (704, 576) if quality == "main" else (352, 288)
                out.append(
                    f"<trt:Profiles token='{token}' fixed='true'>"
                    f"<tt:Name>Camera {channel} {quality}</tt:Name>"
                    f"<tt:VideoEncoderConfiguration token='enc_{token}'>"
                    f"<tt:Encoding>H264</tt:Encoding>"
                    f"<tt:Resolution><tt:Width>{width}</tt:Width>"
                    f"<tt:Height>{height}</tt:Height></tt:Resolution>"
                    f"</tt:VideoEncoderConfiguration>"
                    f"</trt:Profiles>"
                )
        return "".join(out)

    def capabilities(self, host: str) -> str:
        media = (
            f"<tt:Media><tt:XAddr>{self.xaddr(host, MEDIA_PATH)}</tt:XAddr></tt:Media>"
        )
        # Profile G is what carries replay and recording search. Withheld by
        # default: the cheap boxes simply do not have it.
        extra = ""
        if self.profile_g:
            extra = (
                f"<tt:Extension>"
                f"<tt:Replay><tt:XAddr>{self.xaddr(host, '/onvif/replay')}"
                f"</tt:XAddr></tt:Replay>"
                f"<tt:Search><tt:XAddr>{self.xaddr(host, '/onvif/search')}"
                f"</tt:XAddr></tt:Search>"
                f"</tt:Extension>"
            )
        return (
            f"<tds:GetCapabilitiesResponse><tds:Capabilities>"
            f"{media}{extra}</tds:Capabilities></tds:GetCapabilitiesResponse>"
        )


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    device: Device = None  # type: ignore[assignment]

    def log_message(self, *args):
        pass

    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length).decode("utf-8", "replace")
        host = (self.headers.get("Host") or "localhost").split(":")[0]
        action = self._action(body)
        handler = getattr(self, f"_on_{action}", None) if action else None
        if handler is None:
            return self._fault("ActionNotSupported", action or "unknown")
        self._send(handler(host, body))

    def do_GET(self):
        if self.path == "/health":
            body = b'{"status": "ok"}'
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            return self.wfile.write(body)
        self.send_error(404, "ONVIF speaks POST")

    @staticmethod
    def _action(body: str) -> str:
        match = re.search(r"<(?:\w+:)?(Get\w+)", body)
        return match.group(1) if match else ""

    # -- the calls the driver actually makes -------------------------------

    def _on_GetSystemDateAndTime(self, host, body):
        # Required to work unauthenticated, which is why the driver probes with
        # it: a wrong password must not look like a wrong path.
        now = datetime.now(timezone.utc)
        return (
            f"<tds:GetSystemDateAndTimeResponse><tds:SystemDateAndTime>"
            f"<tt:UTCDateTime>"
            f"<tt:Date><tt:Year>{now.year}</tt:Year><tt:Month>{now.month}</tt:Month>"
            f"<tt:Day>{now.day}</tt:Day></tt:Date>"
            f"<tt:Time><tt:Hour>{now.hour}</tt:Hour>"
            f"<tt:Minute>{now.minute}</tt:Minute>"
            f"<tt:Second>{now.second}</tt:Second></tt:Time>"
            f"</tt:UTCDateTime></tds:SystemDateAndTime>"
            f"</tds:GetSystemDateAndTimeResponse>"
        )

    def _on_GetCapabilities(self, host, body):
        return self.device.capabilities(host)

    def _on_GetServices(self, host, body):
        services = [("device/wsdl", DEVICE_PATH), ("media/wsdl", MEDIA_PATH)]
        if self.device.profile_g:
            services += [("replay/wsdl", "/onvif/replay"),
                         ("search/wsdl", "/onvif/search")]
        return "<tds:GetServicesResponse>" + "".join(
            f"<tds:Service>"
            f"<tds:Namespace>http://www.onvif.org/ver10/{ns}</tds:Namespace>"
            f"<tds:XAddr>{self.device.xaddr(host, path)}</tds:XAddr>"
            f"</tds:Service>"
            for ns, path in services
        ) + "</tds:GetServicesResponse>"

    def _on_GetDeviceInformation(self, host, body):
        return (
            "<tds:GetDeviceInformationResponse>"
            "<tds:Manufacturer>Pointy Rig</tds:Manufacturer>"
            "<tds:Model>FAKE-ONVIF-4</tds:Model>"
            "<tds:FirmwareVersion>V4.03.R11</tds:FirmwareVersion>"
            "<tds:SerialNumber>rig000000000001</tds:SerialNumber>"
            "</tds:GetDeviceInformationResponse>"
        )

    def _on_GetProfiles(self, host, body):
        return f"<trt:GetProfilesResponse>{self.device.profiles()}</trt:GetProfilesResponse>"

    def _on_GetStreamUri(self, host, body):
        # Real RTSP, straight at MediaMTX: get through the traps, get video.
        return (
            f"<trt:GetStreamUriResponse><trt:MediaUri>"
            f"<tt:Uri>{self.device.rtsp}</tt:Uri>"
            f"</trt:MediaUri></trt:GetStreamUriResponse>"
        )

    def _on_GetSnapshotUri(self, host, body):
        return (
            f"<trt:GetSnapshotUriResponse><trt:MediaUri>"
            f"<tt:Uri>http://{host}:8080/clean/snapshot.jpg</tt:Uri>"
            f"</trt:MediaUri></trt:GetSnapshotUriResponse>"
        )

    # -- plumbing ----------------------------------------------------------

    def _send(self, body: str, status: int = 200):
        payload = envelope(body)
        self.send_response(status)
        self.send_header("Content-Type", "application/soap+xml; charset=utf-8")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def _fault(self, subcode: str, detail: str):
        self._send(
            f"<s:Fault><s:Code><s:Value>s:Receiver</s:Value>"
            f"<s:Subcode><s:Value>ter:{subcode}</s:Value></s:Subcode></s:Code>"
            f"<s:Reason><s:Text>{detail}</s:Text></s:Reason></s:Fault>",
            status=400,
        )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", type=int, default=8000)
    parser.add_argument("--rtsp", default="rtsp://mediamtx:8554/shop")
    parser.add_argument("--channels", type=int, default=4)
    parser.add_argument("--profile-g", action="store_true",
                        help="Advertise replay/search (most cheap boxes do not).")
    parser.add_argument("--single-profile", action="store_true",
                        help="One profile per channel instead of per encoder.")
    parser.add_argument("--honest-xaddr", action="store_true",
                        help="Report the address you actually reached it on.")
    args = parser.parse_args()

    Handler.device = Device(args)
    traps = []
    if not args.honest_xaddr:
        traps.append(f"lies about its address (says {LIE_HOST})")
    if not args.profile_g:
        traps.append("Profile S only, no replay/search")
    if not args.single_profile:
        traps.append(f"{args.channels * 2} profiles for {args.channels} cameras")
    print(
        f"fake ONVIF on :{args.port} -> {args.rtsp}\n  traps: "
        + "; ".join(traps or ["none (honest device)"]),
        flush=True,
    )
    ThreadingHTTPServer(("0.0.0.0", args.port), Handler).serve_forever()


if __name__ == "__main__":
    main()
