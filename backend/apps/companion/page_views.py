"""Serve the companion page itself on the shop LAN.

Served by Django rather than baked into the web front door's nginx image, so
there is one copy of the page and it ships and updates with the backend. Both
doors reach it: ``http://<ip>/c/`` through the web front door, and
``http://<ip>:8000/c/`` straight off the LAN port every till already uses.

Gated by ``request_discovery_allowed`` — the same check that keeps the client
installers off the internet — so the page exists only for peers on this shop's
own network, never through the relay.
"""

import hashlib
import mimetypes
from pathlib import Path

from django.http import Http404, HttpResponse, HttpResponseNotModified
from django.views.decorators.http import require_safe

from apps.core.discovery import request_discovery_allowed

WEB_ROOT = Path(__file__).resolve().parent / "web"
INDEX = "index.html"

# The whole bundle is a few hundred kilobytes and never changes between
# restarts, so it is read once and served from memory: a phone opening the page
# should not wait on a disk read, and there is nothing here worth a file
# descriptor per request.
_cache: dict[str, tuple[bytes, str, str]] = {}


def _load(name: str) -> tuple[bytes, str, str]:
    """Return ``(body, content_type, etag)`` for one bundle file."""
    if name in _cache:
        return _cache[name]

    # Resolve inside the bundle directory and refuse anything that escapes it,
    # so a crafted path can never read outside ``web/``.
    candidate = (WEB_ROOT / name).resolve()
    if WEB_ROOT.resolve() not in candidate.parents or not candidate.is_file():
        raise Http404("unknown companion asset")

    body = candidate.read_bytes()
    content_type = mimetypes.guess_type(candidate.name)[0] or "application/octet-stream"
    if candidate.suffix == ".js":
        content_type = "text/javascript"
    if candidate.suffix in {".html", ".css", ".js"}:
        content_type += "; charset=utf-8"
    etag = '"%s"' % hashlib.sha256(body).hexdigest()[:32]
    _cache[name] = (body, content_type, etag)
    return _cache[name]


def _etag_matches(header: str, etag: str) -> bool:
    """Compare an ``If-None-Match`` header against our tag, weakness aside.

    The gzip middleware compresses this page and, correctly, downgrades the tag
    to a weak one (``W/"..."``) on the way out — the bytes are no longer
    byte-identical, only semantically equivalent. The browser then sends that
    weak tag back. A literal string comparison therefore never matched, so every
    reload re-sent the whole bundle and the 304 path was dead code.
    """
    if not header:
        return False
    for candidate in header.split(","):
        candidate = candidate.strip()
        if candidate == "*":
            return True
        if candidate.removeprefix("W/") == etag.removeprefix("W/"):
            return True
    return False


@require_safe
def companion_page(request, path: str = ""):
    if not request_discovery_allowed(request):
        raise Http404("the companion camera is only available on the shop network")

    name = (path or "").strip("/") or INDEX
    body, content_type, etag = _load(name)

    if _etag_matches(request.META.get("HTTP_IF_NONE_MATCH", ""), etag):
        response = HttpResponseNotModified()
    else:
        response = HttpResponse(body, content_type=content_type)
        if request.method == "HEAD":
            response.content = b""

    response["ETag"] = etag
    # Revalidate every load rather than cache by age: on a LAN a 304 costs
    # nothing, and it means a phone can never be stuck on a stale bundle after
    # the shop updates.
    response["Cache-Control"] = "no-cache"
    response["Referrer-Policy"] = "no-referrer"
    response["X-Content-Type-Options"] = "nosniff"
    return response
