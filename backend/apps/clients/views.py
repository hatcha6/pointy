"""Serve the bundled Android/Windows client installers on the shop LAN.

A new shop's on-prem build ships the client installers; the local backend serves
them (plus a version manifest the apps poll for self-update) so onboarding a device
is just scanning a QR. Everything here is LAN-only: it reuses
``request_discovery_allowed`` (same gate as service discovery), which rejects
relayed requests and non-private callers, so installers are never exposed over the
relay/internet.
"""

import json
import mimetypes
from pathlib import Path

from django.conf import settings
from django.http import FileResponse, Http404, HttpResponse
from django.utils.html import escape
from rest_framework import status, views
from rest_framework.permissions import AllowAny
from rest_framework.response import Response

from apps.core.discovery import request_discovery_allowed

_PLATFORMS = ("android", "windows")
_CONTENT_TYPES = {
    ".apk": "application/vnd.android.package-archive",
    ".exe": "application/octet-stream",
}
_PLATFORM_LABELS = {"android": "Android", "windows": "Windows"}


def _clients_root() -> Path:
    return Path(settings.CLIENTS_ROOT)


def _load_manifest():
    try:
        with (_clients_root() / "manifest.json").open() as handle:
            data = json.load(handle)
    except (OSError, ValueError):
        return {}
    return data if isinstance(data, dict) else {}


def public_manifest():
    """The manifest the clients poll: per-platform file, hash, size, download URL."""
    data = _load_manifest()
    version = str(data.get("version") or "").strip()
    clients = {}
    for platform in _PLATFORMS:
        entry = data.get(platform)
        if not isinstance(entry, dict):
            continue
        filename = str(entry.get("file") or "").strip()
        if not filename:
            continue
        clients[platform] = {
            "version": version,
            "file": filename,
            "sha256": str(entry.get("sha256") or ""),
            "size": entry.get("size"),
            "url": f"/clients/files/{filename}",
        }
    return {"version": version, "clients": clients}


def _manifest_filenames():
    data = _load_manifest()
    names = set()
    for platform in _PLATFORMS:
        entry = data.get(platform)
        if isinstance(entry, dict) and entry.get("file"):
            names.add(str(entry["file"]))
    return names


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
        return FileResponse(
            path.open("rb"),
            as_attachment=True,
            filename=name,
            content_type=content_type,
        )


class ClientLandingView(views.APIView):
    """A tiny download page — the target a fresh device opens from the QR/link."""

    permission_classes = [AllowAny]
    authentication_classes = []

    def get(self, request):
        if not request_discovery_allowed(request):
            raise Http404("client downloads are only available on the shop network")
        manifest = public_manifest()
        buttons = []
        for platform in _PLATFORMS:
            entry = manifest["clients"].get(platform)
            if not entry:
                continue
            buttons.append(
                f'<a class="btn" href="{escape(entry["url"])}">'
                f'Download for {escape(_PLATFORM_LABELS[platform])}</a>'
            )
        if not buttons:
            body = "<p>No client installers are available on this server yet.</p>"
        else:
            body = "".join(buttons)
        version = escape(manifest["version"]) or "—"
        html = f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>تطبيقات دفتر</title>
<style>
  body {{ font-family: system-ui, sans-serif; margin: 0; padding: 2rem;
         display: flex; flex-direction: column; align-items: center; gap: 1rem;
         background: #0b6b64; color: #fff; min-height: 100vh; box-sizing: border-box; }}
  h1 {{ margin: 0.5rem 0 0; font-size: 1.5rem; }}
  p {{ opacity: 0.85; margin: 0; }}
  .btn {{ display: block; width: 100%; max-width: 360px; text-align: center;
          background: #fff; color: #0b6b64; text-decoration: none; font-weight: 600;
          padding: 1rem 1.25rem; border-radius: 12px; }}
</style>
</head>
<body>
  <h1>دفتر</h1>
  <p>Version {version}</p>
  {body}
</body>
</html>"""
        return HttpResponse(html)
