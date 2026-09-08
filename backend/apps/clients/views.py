"""Serve the bundled client installers on the shop LAN.

A new shop's on-prem build ships the client installers; the local backend serves
them (plus a version manifest the apps poll for self-update) so onboarding a device
is just scanning a QR. Everything here is LAN-only: it reuses
``request_discovery_allowed`` (same gate as service discovery), which rejects
relayed requests and non-private callers, so installers are never exposed over the
relay/internet.

The bundle carries two kinds of installer and the difference matters:

* **clients** — android/windows/linux, keyed by the ``ClientPlatform`` enum name
  the apps use. These are self-update targets: an app polls the manifest, finds a
  newer version for its own platform, and installs it.
* **downloads** — installers a *person* picks off the landing page and installs by
  hand. The Linux ``.deb`` is one (a package cannot replace a running app that
  lives under ``/opt``), and the Windows 7/8/8.1 compat build is another (it comes
  from its own frozen release, at its own version, for machines the modern
  installer refuses to run on). Keeping them out of ``clients`` is what stops a
  till offering itself an update it cannot apply.
"""

import json
import mimetypes
from pathlib import Path

from django.conf import settings
from django.core.handlers.asgi import ASGIRequest
from django.http import FileResponse, Http404, HttpResponse, StreamingHttpResponse
from django.utils.html import escape
from django.utils.http import content_disposition_header
from rest_framework import status, views
from rest_framework.permissions import AllowAny
from rest_framework.response import Response

from apps.core.discovery import request_discovery_allowed
from apps.core.streaming import aiter_file

#: Keys the apps self-update from. Enum names in ``ClientPlatform`` (Dart).
_PLATFORMS = ("android", "windows", "linux")
#: Keys served and listed, but never offered to an app as an update.
_DOWNLOADS = ("linux_deb", "windows_compat")
_CONTENT_TYPES = {
    ".apk": "application/vnd.android.package-archive",
    ".exe": "application/octet-stream",
    ".deb": "application/vnd.debian.binary-package",
    # Path.suffix of the Linux .tar.gz archive.
    ".gz": "application/gzip",
}

#: Landing-page order and wording. The second half of each pair says *which
#: machine* — the whole point of the page is that someone standing at a till
#: picks the right file without being told which one.
_LANDING_ORDER = (
    ("android", "أندرويد", "هاتف أو جهاز لوحي"),
    ("windows", "ويندوز", "ويندوز 10 أو 11"),
    ("windows_compat", "ويندوز القديم", "ويندوز 7 أو 8 أو 8.1"),
    ("linux_deb", "لينكس", "أوبونتو أو منت — ملف تثبيت"),
    ("linux", "لينكس — نسخة محمولة", "توزيعات أخرى"),
)


def _clients_root() -> Path:
    return Path(settings.CLIENTS_ROOT)


def _load_manifest():
    try:
        with (_clients_root() / "manifest.json").open() as handle:
            data = json.load(handle)
    except (OSError, ValueError):
        return {}
    return data if isinstance(data, dict) else {}


def _raw_entries(data):
    """Yield ``(section, key, entry)`` for every installer the bundle carries."""
    for key in _PLATFORMS:
        entry = data.get(key)
        if isinstance(entry, dict) and entry.get("file"):
            yield "clients", key, entry
    downloads = data.get("downloads")
    if isinstance(downloads, dict):
        for key in _DOWNLOADS:
            entry = downloads.get(key)
            if isinstance(entry, dict) and entry.get("file"):
                yield "downloads", key, entry


def public_manifest():
    """The manifest the clients poll: per-platform file, hash, size, download URL."""
    data = _load_manifest()
    version = str(data.get("version") or "").strip()
    manifest = {"version": version, "clients": {}, "downloads": {}}
    for section, key, entry in _raw_entries(data):
        filename = str(entry["file"]).strip()
        if not filename:
            continue
        manifest[section][key] = {
            # An entry may carry its own version — the compat build releases on
            # its own tags and is not the bundle's version.
            "version": str(entry.get("version") or version),
            "file": filename,
            "sha256": str(entry.get("sha256") or ""),
            "size": entry.get("size"),
            "url": f"/clients/files/{filename}",
        }
    return manifest


def _manifest_filenames():
    return {
        str(entry["file"]).strip()
        for _section, _key, entry in _raw_entries(_load_manifest())
        if str(entry["file"]).strip()
    }


class ClientManifestView(views.APIView):
    permission_classes = [AllowAny]
    authentication_classes = []

    def get(self, request):
        if not request_discovery_allowed(request):
            return Response(
                {"detail": "client downloads are only available on the shop network"},
                status=status.HTTP_404_NOT_FOUND,
            )
        return Response(public_manifest())


class ClientFileView(views.APIView):
    permission_classes = [AllowAny]
    authentication_classes = []

    def get(self, request, name):
        if not request_discovery_allowed(request):
            raise Http404("client downloads are only available on the shop network")
        # Only serve files named in the manifest: prevents path traversal and
        # arbitrary reads from the clients directory.
        if name not in _manifest_filenames():
            raise Http404("unknown client file")
        path = (_clients_root() / name).resolve()
        if _clients_root().resolve() not in path.parents or not path.is_file():
            raise Http404("unknown client file")
        content_type = (
            _CONTENT_TYPES.get(path.suffix.lower())
            or mimetypes.guess_type(str(path))[0]
            or "application/octet-stream"
        )
        django_request = getattr(request, "_request", request)
        if isinstance(django_request, ASGIRequest):
            # Served over ASGI (uvicorn in production), Django buffers
            # FileResponse's sync file iterator wholesale — the entire
            # installer in memory before the first byte, per download. Hand it
            # an async iterator instead, setting by hand the headers
            # FileResponse would have derived from the file handle. WSGI
            # (runserver, tests) keeps native sync streaming.
            response = StreamingHttpResponse(
                aiter_file(path), content_type=content_type
            )
            response["Content-Length"] = path.stat().st_size
            response["Content-Disposition"] = content_disposition_header(
                as_attachment=True, filename=name
            )
            return response
        return FileResponse(
            path.open("rb"),
            as_attachment=True,
            filename=name,
            content_type=content_type,
        )


def _size_label(size):
    if not isinstance(size, (int, float)) or size <= 0:
        return ""
    return f"{size / (1024 * 1024):.0f} MB"


def _landing_buttons(manifest):
    """One button per installer the bundle actually carries, in a fixed order."""
    buttons = []
    for key, title, machine in _LANDING_ORDER:
        entry = manifest["clients"].get(key) or manifest["downloads"].get(key)
        if not entry:
            continue
        # Each Latin fragment gets its OWN <bdi>. Isolating the whole line
        # instead auto-detects it as Arabic and then reorders the Latin pieces
        # inside it: "85 MB" comes out "MB 85", and "0.4.6-compat" splits in
        # half with the size wedged into the gap.
        meta = [escape(machine)]
        if entry["version"] and entry["version"] != manifest["version"]:
            meta.append(f"<bdi>{escape(entry['version'])}</bdi>")
        size = _size_label(entry.get("size"))
        if size:
            meta.append(f"<bdi>{escape(size)}</bdi>")
        details = " · ".join(meta)
        buttons.append(
            f'<a class="btn" href="{escape(entry["url"])}">'
            f'<span class="name">{escape(title)}</span>'
            f'<span class="meta">{details}</span>'
            "</a>"
        )
    return buttons


class ClientLandingView(views.APIView):
    """A tiny download page — the target a fresh device opens from the QR/link."""

    permission_classes = [AllowAny]
    authentication_classes = []

    def get(self, request):
        if not request_discovery_allowed(request):
            raise Http404("client downloads are only available on the shop network")
        manifest = public_manifest()
        buttons = _landing_buttons(manifest)
        body = (
            "".join(buttons)
            if buttons
            else '<p class="empty">لا توجد ملفات تثبيت على هذا الخادم بعد.</p>'
        )
        version = escape(manifest["version"]) or "—"
        html = f"""<!doctype html>
<html lang="ar" dir="rtl">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>تطبيقات دفتر</title>
<style>
  body {{ font-family: system-ui, sans-serif; margin: 0; padding: 2rem 1.25rem;
         display: flex; flex-direction: column; align-items: center; gap: 0.75rem;
         background: #0b6b64; color: #fff; min-height: 100vh; box-sizing: border-box; }}
  h1 {{ margin: 0.5rem 0 0; font-size: 1.5rem; }}
  p {{ opacity: 0.85; margin: 0 0 0.5rem; }}
  .btn {{ display: flex; flex-direction: column; gap: 0.15rem;
          width: 100%; max-width: 360px; text-align: center;
          background: #fff; color: #0b6b64; text-decoration: none;
          padding: 0.9rem 1.25rem; border-radius: 12px; }}
  .btn .name {{ font-weight: 600; }}
  .btn .meta {{ font-size: 0.8rem; opacity: 0.7; }}
  .empty {{ max-width: 360px; text-align: center; }}
</style>
</head>
<body>
  <h1>دفتر</h1>
  <p>الإصدار <bdi>{version}</bdi></p>
  {body}
</body>
</html>"""
        return HttpResponse(html)
