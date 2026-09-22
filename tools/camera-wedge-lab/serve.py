"""Serve the lab and keep what it measures.

Two jobs, and the second is the reason this is not ``python -m http.server``:

* ``getUserMedia`` needs a secure context, and a plain ``http://`` LAN address
  is not one — ``http://localhost`` is. So the lab is served from here, on the
  machine the camera is plugged into, and the browser is happy.
* A measurement nobody wrote down is a story. Every emitted scan and every
  stats snapshot is POSTed to ``/report`` and appended to ``results.jsonl``,
  so a run can be read afterwards (or from another window, while it happens)
  instead of recalled from the screen.

    make camera-wedge-lab      # then open http://localhost:8099
"""

from __future__ import annotations

import http.server
import json
import pathlib
import socketserver
import sys
import time

ROOT = pathlib.Path(__file__).parent
RESULTS = ROOT / "results.jsonl"
PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8099


class Handler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=str(ROOT), **kwargs)

    def do_POST(self):  # noqa: N802 - stdlib naming
        if self.path != "/report":
            self.send_error(404)
            return
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length)
        try:
            payload = json.loads(raw or b"{}")
        except json.JSONDecodeError:
            self.send_error(400, "not JSON")
            return
        payload["server_time"] = time.strftime("%Y-%m-%dT%H:%M:%S")
        with RESULTS.open("a", encoding="utf-8") as handle:
            handle.write(json.dumps(payload, ensure_ascii=False) + "\n")
        self.send_response(204)
        self.end_headers()

    def end_headers(self):
        # The lab is a measuring instrument that is edited between runs; a
        # cached copy of it measures the previous version.
        self.send_header("Cache-Control", "no-store")
        super().end_headers()

    def log_message(self, fmt, *args):
        # One line per report would drown the console the reports are read
        # next to. Static GETs are noise here too.
        return


class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


if __name__ == "__main__":
    print(f"camera-wedge-lab on http://localhost:{PORT}  ->  {RESULTS}", flush=True)
    with Server(("127.0.0.1", PORT), Handler) as httpd:
        httpd.serve_forever()
