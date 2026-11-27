"""The real shelf with bundles on it, for trying bundles before the relay
serves them. Dev only, safe to delete.

It passes the live catalog and card art through from a relay (production by
default), adds the bundles below to the catalog, and serves their artwork
from ops/catalog/logos/bundles (render it first: make cards-bundle-art).
Run the preview harness on it, which keeps orders, payment and codes fake:

    python3 cards/tool/bundle_shelf.py            # on :8099
    make cards-preview-live CARDS_RELAY_URL=http://127.0.0.1:8099

then open http://127.0.0.1:8090/?screen=home.
"""

import hashlib
import http.server
import json
import pathlib
import sys
import urllib.error
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parents[2]
ART = ROOT / "ops" / "catalog" / "logos" / "bundles"
UPSTREAM = sys.argv[1] if len(sys.argv) > 1 else "https://my.dftr.ly"
PORT = 8099

# The bundle as the relay would define it. A tier fixes every amount; the
# phone credit part lists one card per network, and the buyer picks theirs.
# Only 5 and 10 dinars are sold on all three networks. The saving comes out
# of the game card's margin; these figures are placeholders.
NETWORKS = ("libyana", "almadar", "ltt")


def credit(value: int) -> list:
    return [f"{net}-{value}lyd" for net in NETWORKS]


def art_refs() -> dict:
    refs = {}
    for net in NETWORKS:
        path = ART / f"pubg-{net}.png"
        if path.exists():
            refs[net] = "sha256:" + hashlib.sha256(path.read_bytes()).hexdigest()
    return refs


ART_BY_SUM = {
    hashlib.sha256(p.read_bytes()).hexdigest(): p for p in ART.glob("*.png")
}

BUNDLES = [
    {
        "key": "gamer",
        "name": "باقة اللاعب",
        "tagline": "شدّات ببجي مع رصيد خطك",
        "rank": 1,
        "art": art_refs(),
        "tiers": [
            {"key": "gamer-60", "saving": "0.750",
             "parts": [["pubg-ww-60uc"], credit(5)]},
            {"key": "gamer-325", "saving": "2.250",
             "parts": [["pubg-ww-325uc"], credit(10)]},
            {"key": "gamer-660", "saving": "4.250",
             "parts": [["pubg-ww-660uc"], credit(10)]},
        ],
    }
]


class Shelf(http.server.BaseHTTPRequestHandler):
    def _cors(self):
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Headers", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, OPTIONS")

    def do_OPTIONS(self):
        self.send_response(204)
        self._cors()
        self.end_headers()

    def _send(self, status: int, body: bytes, content_type: str):
        self.send_response(status)
        self._cors()
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        path = self.path.split("?")[0]
        prefix = "/v1/customers/images/"
        if path.startswith(prefix) and path[len(prefix):] in ART_BY_SUM:
            self._send(200, ART_BY_SUM[path[len(prefix):]].read_bytes(), "image/png")
            return
        try:
            with urllib.request.urlopen(UPSTREAM + self.path, timeout=30) as up:
                body = up.read()
                content_type = up.headers.get("Content-Type", "application/json")
                status = up.status
        except urllib.error.HTTPError as error:
            body, status = error.read(), error.code
            content_type = "application/json"
        if path == "/v1/customers/catalog" and status == 200:
            shelf = json.loads(body)
            shelf["bundles"] = BUNDLES
            # A new version whenever the bundles or their art change, so a
            # phone's saved shelf is read again.
            stamp = hashlib.sha256(json.dumps(BUNDLES).encode()).hexdigest()[:12]
            shelf["version"] = f"{shelf.get('version', '')}+bundles-{stamp}"
            body = json.dumps(shelf, ensure_ascii=False).encode()
        self._send(status, body, content_type)


if __name__ == "__main__":
    print(f"bundle shelf on http://127.0.0.1:{PORT} (from {UPSTREAM})")
    http.server.ThreadingHTTPServer(("127.0.0.1", PORT), Shelf).serve_forever()
