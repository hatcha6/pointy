#!/usr/bin/env python3
"""A recorder that serves the frame the field sent us, on purpose.

MediaMTX gives the rig real H.264 over real RTSP, which proves the transcode
spine. It cannot prove the demuxer, and this is why: every JPEG in that path is
encoded by *our own* ffmpeg, and ffmpeg's MJPEG encoder never writes a
quantization table containing ``FF D9``. Measured, not assumed — 630 encoder
configurations (seven frame sizes x three pixel formats x every ``-q:v`` from 2
to 31) produced not one. A naive ``FFD9`` scan passes that rig perfectly.

The grey pixels came from the *recorder's* encoder, not ours. DVR firmware
writes its own quantization tables, and a table holding 255 next to 217 carries
a literal end-of-image marker in the middle of the header. Scanning for ``FFD9``
from byte zero cut the frame there: in the field, a 677-byte frame cut at byte
46, and the remains paint flat grey.

So this server serves what that box served. Frames are **real video** — ffmpeg
encodes an actual moving picture — and then two adjacent high-frequency entries
of the first quantization table are rewritten to ``FF D9``. The picture still
decodes, pixel-identical to the clean frame; only the header is now the header a
DVR sent us. That is the whole trap, and it is the one thing MediaMTX cannot do.

``/health`` reports whether the trap frames really do contain the adversarial
bytes. A rig that has quietly stopped reproducing the bug is worse than no rig,
so the tests read that field and refuse to pass on a trap that is not armed.

    python3 fake_dvr.py --port 8080
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

BOUNDARY = "pointyrigframe"

#: Which entry of the first quantization table to overwrite. Deliberately high
#: frequency: the 64 entries run low to high in zigzag order, so altering one
#: near the end changes how the finest detail is scaled and leaves the picture
#: plainly recognisable. Rewriting a low-frequency entry would produce a frame
#: so mangled that "did it decode" stops being a fair question.
TRAP_ENTRY = 60


def encode_frames(count: int, size: str, fps: int, quality: int) -> list[bytes]:
    """Real video: an actual moving picture out of ffmpeg's MJPEG encoder."""
    raw = subprocess.run(
        [
            "ffmpeg", "-hide_banner", "-loglevel", "error",
            "-f", "lavfi", "-i", f"testsrc2=size={size}:rate={fps}",
            "-frames:v", str(count), "-pix_fmt", "yuvj420p",
            "-f", "mjpeg", "-q:v", str(quality), "-",
        ],
        capture_output=True,
    ).stdout
    if not raw.startswith(b"\xff\xd8"):
        raise SystemExit("ffmpeg produced no JPEG; is ffmpeg installed?")
    frames, start = [], 0
    while True:
        nxt = raw.find(b"\xff\xd8", start + 2)
        frames.append(raw[start:] if nxt == -1 else raw[start:nxt])
        if nxt == -1:
            break
        start = nxt
    return frames


def patch_quant_table(frame: bytes) -> bytes:
    """Rewrite two adjacent quantization entries to 0xFF, 0xD9.

    Walks to the first DQT properly rather than searching for the bytes, so the
    trap lands inside a *table* — the place a scan-based demuxer has no reason
    to expect a marker and every reason to be fooled by one.
    """
    buf = bytearray(frame)
    i, n = 2, len(buf)
    while i + 1 < n:
        if buf[i] != 0xFF:
            break
        marker = buf[i + 1]
        i += 2
        if marker in (0xD9, 0xDA):
            break
        if i + 2 > n:
            break
        length = (buf[i] << 8) | buf[i + 1]
        if marker == 0xDB:
            base = i + 2 + 1  # past the length and the Pq/Tq byte
            if base + TRAP_ENTRY + 1 >= i + length:
                raise SystemExit("DQT too short to hold the trap")
            buf[base + TRAP_ENTRY] = 0xFF
            buf[base + TRAP_ENTRY + 1] = 0xD9
            return bytes(buf)
        i += length
    raise SystemExit("no quantization table in this frame")


def header_carries_eoi(frame: bytes) -> bool:
    """Is the trap actually armed — FFD9 inside a header segment, not entropy?"""
    i, n = 2, len(frame)
    while i + 1 < n:
        if frame[i] != 0xFF:
            return False
        marker = frame[i + 1]
        i += 2
        if marker in (0xD9, 0xDA):
            return False
        if i + 2 > n:
            return False
        length = (frame[i] << 8) | frame[i + 1]
        if b"\xff\xd9" in frame[i + 2 : i + length]:
            return True
        i += length
    return False


class Feed:
    """The frames this recorder will serve, clean and trapped."""

    def __init__(self, count: int, size: str, fps: int, quality: int):
        self.fps = fps
        self.clean = encode_frames(count, size, fps, quality)
        self.trap = [patch_quant_table(f) for f in self.clean]
        self.armed = all(header_carries_eoi(f) for f in self.trap)
        # Where a scan-based demuxer would cut the first trapped frame. Reported
        # so a failing test can say how much of the picture was lost, which is
        # the number that made the original bug legible.
        first = self.trap[0]
        self.naive_cut = first.find(b"\xff\xd9") + 2
        self.trap_bytes = len(first)

    def variant(self, name: str) -> list[bytes]:
        return self.trap if name == "trap" else self.clean


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    feed: Feed = None  # type: ignore[assignment]

    def log_message(self, *args):  # quiet: the rig runs under docker compose
        pass

    def do_GET(self):
        path, _, query = self.path.partition("?")
        params = dict(
            p.split("=", 1) for p in query.split("&") if "=" in p
        )
        if path == "/health":
            return self._json(
                {
                    "status": "ok",
                    # The tests refuse to pass unless this is true.
                    "trap_armed": self.feed.armed,
                    "frames": len(self.feed.clean),
                    "trap_bytes": self.feed.trap_bytes,
                    "naive_cut_at": self.feed.naive_cut,
                    "bytes_lost_to_naive_scan": self.feed.trap_bytes
                    - self.feed.naive_cut,
                }
            )
        if path == "/broken/snapshot.jpg":
            # The frame as the old demuxer left it: cut at the quantization
            # table's fake end-of-image. Serving it lets the preview harness put
            # the bug on screen next to the fix, which is the only way a person
            # ever recognises "grey pixels" as this and not a dead camera.
            index = int(params.get("i", 0)) % len(self.feed.clean)
            frame = self.feed.trap[index]
            return self._jpeg(frame[: frame.find(b"\xff\xd9") + 2])
        for variant in ("trap", "clean"):
            if path == f"/{variant}/mjpeg":
                return self._mjpeg(self.feed.variant(variant))
            if path == f"/{variant}/snapshot.jpg":
                index = int(params.get("i", 0)) % len(self.feed.clean)
                return self._jpeg(self.feed.variant(variant)[index])
        self.send_error(404, "no such camera path")

    def _cors(self):
        """The preview harness is Flutter web on another port, so every
        response needs this or the browser drops it before the decoder ever
        sees a byte. A rig is a rig; there is nothing here worth guarding."""
        self.send_header("Access-Control-Allow-Origin", "*")

    def do_OPTIONS(self):
        self.send_response(204)
        self._cors()
        self.send_header("Access-Control-Allow-Headers", "*")
        self.send_header("Content-Length", "0")
        self.end_headers()

    def _json(self, payload):
        body = json.dumps(payload, indent=2).encode()
        self.send_response(200)
        self._cors()
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _jpeg(self, frame: bytes):
        self.send_response(200)
        self._cors()
        self.send_header("Content-Type", "image/jpeg")
        self.send_header("Content-Length", str(len(frame)))
        self.end_headers()
        self.wfile.write(frame)

    def _mjpeg(self, frames: list[bytes]):
        """``multipart/x-mixed-replace``, the way a DVR serves it."""
        self.send_response(200)
        self._cors()
        self.send_header(
            "Content-Type", f"multipart/x-mixed-replace; boundary={BOUNDARY}"
        )
        self.end_headers()
        interval = 1.0 / max(self.feed.fps, 1)
        index = 0
        try:
            while True:
                frame = frames[index % len(frames)]
                index += 1
                self.wfile.write(
                    f"--{BOUNDARY}\r\nContent-Type: image/jpeg\r\n"
                    f"Content-Length: {len(frame)}\r\n\r\n".encode()
                )
                self.wfile.write(frame)
                self.wfile.write(b"\r\n")
                self.wfile.flush()
                time.sleep(interval)
        except (BrokenPipeError, ConnectionResetError):
            return  # the client closed the tile; normal


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", type=int, default=8080)
    parser.add_argument("--frames", type=int, default=48)
    parser.add_argument("--size", default="704x576")
    parser.add_argument("--fps", type=int, default=8)
    parser.add_argument("--quality", type=int, default=6)
    args = parser.parse_args()

    feed = Feed(args.frames, args.size, args.fps, args.quality)
    Handler.feed = feed
    if not feed.armed:
        # Fail at boot, not silently at test time.
        raise SystemExit("trap is NOT armed: patched frames carry no header FFD9")
    print(
        f"fake DVR on :{args.port} — {len(feed.clean)} frames, trap armed; "
        f"a scan-based demuxer cuts frame 0 at byte {feed.naive_cut} of "
        f"{feed.trap_bytes}, losing {feed.trap_bytes - feed.naive_cut}.",
        flush=True,
    )
    ThreadingHTTPServer(("0.0.0.0", args.port), Handler).serve_forever()


if __name__ == "__main__":
    main()
