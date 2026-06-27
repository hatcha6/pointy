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
        (self.root / self.apk_name).write_bytes(b"FAKE-APK-BYTES")
        (self.root / "manifest.json").write_text(
            json.dumps(
                {
                    "version": "1.4.0",
                    "android": {"file": self.apk_name, "sha256": "abc", "size": 14},
                    "windows": None,
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

    def test_landing_page_renders_download_button(self):
        response = self.client.get(reverse("clients-landing"), REMOTE_ADDR="192.168.1.10")
        self.assertEqual(response.status_code, status.HTTP_200_OK)
        body = response.content.decode()
        self.assertIn("Download for Android", body)
        self.assertIn(f"/clients/files/{self.apk_name}", body)

    def test_missing_manifest_yields_empty_clients(self):
        (self.root / "manifest.json").unlink()
        response = self.client.get(reverse("clients-manifest"), REMOTE_ADDR="192.168.1.10")
        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(response.data["clients"], {})
