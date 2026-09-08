import json
import tempfile
from pathlib import Path

from django.test import TestCase, override_settings
from django.urls import reverse
from rest_framework import status
from rest_framework.test import APIClient


class ClientDownloadTests(TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.root = Path(self._tmp.name)
        self.apk_name = "pointy-1.4.0-android-universal.apk"
        self.linux_name = "pointy-1.4.0-linux-x64.tar.gz"
        self.deb_name = "pointy-1.4.0-linux-x64.deb"
        self.compat_name = "pointy-1.3.9-compat-windows-x64-setup.exe"
        (self.root / self.apk_name).write_bytes(b"FAKE-APK-BYTES")
        (self.root / self.linux_name).write_bytes(b"FAKE-TARBALL-BYTES")
        (self.root / self.deb_name).write_bytes(b"FAKE-DEB-BYTES")
        (self.root / self.compat_name).write_bytes(b"FAKE-COMPAT-SETUP")
        (self.root / "manifest.json").write_text(
            json.dumps(
                {
                    "version": "1.4.0",
                    "android": {"file": self.apk_name, "sha256": "abc", "size": 14},
                    "windows": None,
                    "linux": {"file": self.linux_name, "sha256": "def", "size": 18},
                    "downloads": {
                        "linux_deb": {
                            "file": self.deb_name,
                            "sha256": "ghi",
                            "size": 14,
                        },
                        "windows_compat": {
                            "file": self.compat_name,
                            "sha256": "jkl",
                            "size": 17,
                            "version": "1.3.9-compat",
                        },
                    },
                }
            )
        )
        self._override = override_settings(CLIENTS_ROOT=str(self.root))
        self._override.enable()
        self.addCleanup(self._override.disable)
        self.client = APIClient()

    def test_manifest_returns_enriched_entries(self):
        response = self.client.get(reverse("clients-manifest"), REMOTE_ADDR="192.168.1.10")
        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(response.data["version"], "1.4.0")
        android = response.data["clients"]["android"]
        self.assertEqual(android["file"], self.apk_name)
        self.assertEqual(android["url"], f"/clients/files/{self.apk_name}")
        self.assertNotIn("windows", response.data["clients"])
        linux = response.data["clients"]["linux"]
        self.assertEqual(linux["file"], self.linux_name)
        self.assertEqual(linux["url"], f"/clients/files/{self.linux_name}")

    def test_downloads_are_listed_but_are_never_update_targets(self):
        # The whole point of the split: a till polling for its own platform must
        # not be offered the .deb (it cannot replace a running /opt install) or
        # the compat build (it is for the machines this one is not).
        response = self.client.get(reverse("clients-manifest"), REMOTE_ADDR="192.168.1.10")
        clients = response.data["clients"]
        downloads = response.data["downloads"]
        self.assertEqual(set(clients), {"android", "linux"})
        self.assertEqual(set(downloads), {"linux_deb", "windows_compat"})
        self.assertEqual(
            downloads["linux_deb"]["url"], f"/clients/files/{self.deb_name}"
        )
        # An entry without its own version inherits the bundle's; the compat
        # build ships from its own release and keeps its own.
        self.assertEqual(downloads["linux_deb"]["version"], "1.4.0")
        self.assertEqual(downloads["windows_compat"]["version"], "1.3.9-compat")

    def test_download_only_files_are_servable(self):
        # Files are served only if the manifest names them, and the compat
        # installer is named nowhere but under "downloads".
        for name, content_type, payload in (
            (self.deb_name, "application/vnd.debian.binary-package", b"FAKE-DEB-BYTES"),
            (self.compat_name, "application/octet-stream", b"FAKE-COMPAT-SETUP"),
        ):
            with self.subTest(name=name):
                response = self.client.get(
                    reverse("clients-file", args=[name]),
                    REMOTE_ADDR="192.168.1.10",
                )
                self.assertEqual(response.status_code, status.HTTP_200_OK)
                self.assertEqual(response["Content-Type"], content_type)
                self.assertEqual(b"".join(response.streaming_content), payload)

    def test_file_download_has_apk_content_type(self):
        response = self.client.get(
            reverse("clients-file", args=[self.apk_name]),
            REMOTE_ADDR="192.168.1.10",
        )
        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(
            response["Content-Type"], "application/vnd.android.package-archive"
        )
        self.assertIn("attachment", response["Content-Disposition"])
        self.assertEqual(b"".join(response.streaming_content), b"FAKE-APK-BYTES")

    def test_linux_download_has_gzip_content_type(self):
        response = self.client.get(
            reverse("clients-file", args=[self.linux_name]),
            REMOTE_ADDR="192.168.1.10",
        )
        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(response["Content-Type"], "application/gzip")
        self.assertIn("attachment", response["Content-Disposition"])
        self.assertEqual(b"".join(response.streaming_content), b"FAKE-TARBALL-BYTES")

    async def test_asgi_download_streams_an_async_iterator(self):
        # Under ASGI (uvicorn in production) a sync file iterator would be
        # buffered wholesale — the entire installer in memory per download —
        # so the view must hand Django an async iterator there, carrying the
        # headers FileResponse would have set.
        response = await self.async_client.get(
            reverse("clients-file", args=[self.apk_name])
        )
        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertTrue(response.streaming)
        self.assertTrue(response.is_async)
        self.assertEqual(
            response["Content-Type"], "application/vnd.android.package-archive"
        )
        self.assertEqual(response["Content-Length"], "14")
        self.assertIn("attachment", response["Content-Disposition"])
        self.assertIn(self.apk_name, response["Content-Disposition"])
        body = b"".join([chunk async for chunk in response.streaming_content])
        self.assertEqual(body, b"FAKE-APK-BYTES")

    def test_download_is_not_gzipped(self):
        # Dart's HttpClient sends Accept-Encoding: gzip by default;
        # recompressing an APK wastes CPU and drops Content-Length
        # (download progress).
        response = self.client.get(
            reverse("clients-file", args=[self.apk_name]),
            REMOTE_ADDR="192.168.1.10",
            HTTP_ACCEPT_ENCODING="gzip",
        )
        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertIsNone(response.get("Content-Encoding"))
        self.assertEqual(response["Content-Length"], "14")

    def test_unknown_file_is_404(self):
        response = self.client.get(
            reverse("clients-file", args=["pointy-evil.apk"]),
            REMOTE_ADDR="192.168.1.10",
        )
        self.assertEqual(response.status_code, status.HTTP_404_NOT_FOUND)

    def test_relayed_request_is_blocked(self):
        response = self.client.get(
            reverse("clients-manifest"),
            REMOTE_ADDR="192.168.1.10",
            HTTP_X_POINTY_RELAYED_REQUEST="1",
        )
        self.assertEqual(response.status_code, status.HTTP_404_NOT_FOUND)

    def test_public_network_is_blocked(self):
        response = self.client.get(reverse("clients-manifest"), REMOTE_ADDR="8.8.8.8")
        self.assertEqual(response.status_code, status.HTTP_404_NOT_FOUND)

    def test_landing_page_links_every_bundled_installer(self):
        response = self.client.get(reverse("clients-landing"), REMOTE_ADDR="192.168.1.10")
        self.assertEqual(response.status_code, status.HTTP_200_OK)
        body = response.content.decode()
        for name in (self.apk_name, self.linux_name, self.deb_name, self.compat_name):
            self.assertIn(f"/clients/files/{name}", body)
        # Nothing for the platform the bundle has no installer for.
        self.assertNotIn("ويندوز 10 أو 11", body)
        # A person at the till picks by machine, so the compat build has to say
        # which machines it is for, and carry its own version rather than the
        # bundle's.
        self.assertIn("ويندوز 7 أو 8 أو 8.1", body)
        self.assertIn("1.3.9-compat", body)

    def test_landing_page_isolates_each_latin_fragment(self):
        # One <bdi> around the whole meta line is auto-detected as Arabic and
        # then reorders the Latin pieces inside it: "31 MB" renders "MB 31" and
        # "1.3.9-compat" splits in half with the size wedged into the gap.
        response = self.client.get(reverse("clients-landing"), REMOTE_ADDR="192.168.1.10")
        body = response.content.decode()
        self.assertIn("<bdi>1.3.9-compat</bdi>", body)
        self.assertNotIn('<span class="meta"><bdi>', body)

    def test_landing_page_orders_installers_by_machine(self):
        response = self.client.get(reverse("clients-landing"), REMOTE_ADDR="192.168.1.10")
        body = response.content.decode()
        order = [body.index(f"/clients/files/{name}") for name in
                 (self.apk_name, self.compat_name, self.deb_name, self.linux_name)]
        self.assertEqual(order, sorted(order))

    def test_missing_manifest_yields_empty_clients(self):
        (self.root / "manifest.json").unlink()
        response = self.client.get(reverse("clients-manifest"), REMOTE_ADDR="192.168.1.10")
        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(response.data["clients"], {})
        self.assertEqual(response.data["downloads"], {})
