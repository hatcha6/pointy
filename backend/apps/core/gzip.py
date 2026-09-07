"""Response compression for the API.

Stock ``GZipMiddleware`` compresses every response over 200 bytes, which is
wrong for two of ours:

- ``text/event-stream`` — the AI chat SSE stream must reach the client token
  by token; a compression layer invites buffering at every hop (the exact
  class of bug the ASGI streaming bridge exists to prevent).
- ``multipart/x-mixed-replace`` — the camera MJPEG streams, for both reasons at
  once: every part is an already-compressed JPEG, and a live video that
  buffers is a video that does not play.
- already-compressed binaries (product images, audio) — re-gzipping a JPEG
  costs CPU per request for ~0 gain.

Everything else — most importantly the catalog list, the largest payload the
LAN carries — shrinks several-fold, which matters most for relay-tunnel
clients. Django's gzip implementation carries the BREACH mitigation (random
filename padding), and the catalog ETags are already weak so the middleware's
weak-ETag rule changes nothing.
"""

from django.middleware.gzip import GZipMiddleware

_UNCOMPRESSIBLE_PREFIXES = (
    "text/event-stream",
    "multipart/x-mixed-replace",
    "image/",
    "video/",
    "audio/",
    # Already-compressed archives/binaries — chiefly the client installers
    # (APK/exe/tar.gz), which Dart's HttpClient requests with
    # Accept-Encoding: gzip by default. Re-gzipping them wastes CPU per
    # download for ~0 gain, and on a streaming response the gzip wrapper
    # drops Content-Length, killing download progress.
    "application/zip",
    "application/gzip",
    "application/vnd.android.package-archive",
    "application/octet-stream",
)


class SelectiveGZipMiddleware(GZipMiddleware):
    def process_response(self, request, response):
        content_type = response.get("Content-Type", "")
        if content_type.startswith(_UNCOMPRESSIBLE_PREFIXES):
            return response
        return super().process_response(request, response)
