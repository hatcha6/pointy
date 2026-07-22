"""Tests for SelectiveGZipMiddleware: JSON compresses, SSE and images don't."""

from django.contrib.auth.models import Group
from django.contrib.auth import get_user_model
from django.core.files.uploadedfile import SimpleUploadedFile
from django.test import TestCase
from django.urls import reverse
from rest_framework import status
from rest_framework.test import APIClient

from apps.core.roles import MANAGER_GROUP


class SelectiveGzipTests(TestCase):
    def setUp(self):
        user = get_user_model().objects.create_user(username="manager", password="x")
        user.groups.add(Group.objects.get(name=MANAGER_GROUP))
        self.client_api = APIClient()
        self.client_api.force_authenticate(user=user)

    def test_json_list_responses_compress(self):
        # A payload comfortably over gzip's 200-byte floor.
        from apps.catalog.testing import create_product_with_default_variant

        for index in range(3):
            create_product_with_default_variant(
                name=f"منتج تجريبي {index}",
                sku=f"GZ-{index}",
                unit_price="10.00",
                barcode=f"77000{index}",
            )
        response = self.client_api.get(
            "/api/products/", HTTP_ACCEPT_ENCODING="gzip"
        )
        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(response.get("Content-Encoding"), "gzip")

    def test_attachment_content_is_not_recompressed(self):
        import io

        from PIL import Image

        from apps.catalog.testing import create_product_with_default_variant

        product = create_product_with_default_variant(
            name="Widget", sku="GZ-IMG", unit_price="10.00", barcode="880001"
        )
        # The upload endpoint decodes the bytes (normalize_uploaded_image), so
        # the fixture must be a real JPEG, not just jpeg-labelled bytes.
        buffer = io.BytesIO()
        Image.new("RGB", (64, 48), (200, 60, 60)).save(buffer, format="JPEG")
        jpeg_bytes = buffer.getvalue()
        self.assertGreater(len(jpeg_bytes), 200)  # so only the type skips gzip
        upload = self.client_api.post(
            reverse("product-attachments", args=[product.pk]),
            {
                "file": SimpleUploadedFile(
                    "photo.jpg", jpeg_bytes, content_type="image/jpeg"
                ),
            },
            format="multipart",
        )
        self.assertEqual(upload.status_code, status.HTTP_201_CREATED)
        response = self.client_api.get(
            reverse("attachment-content", args=[upload.data["id"]]),
            HTTP_ACCEPT_ENCODING="gzip",
        )
        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertIsNone(response.get("Content-Encoding"))

    def test_event_streams_are_never_compressed(self):
        from django.http import StreamingHttpResponse
        from django.test import RequestFactory

        from apps.core.gzip import SelectiveGZipMiddleware

        middleware = SelectiveGZipMiddleware(lambda request: None)
        request = RequestFactory().get("/api/ai/chat/", HTTP_ACCEPT_ENCODING="gzip")
        response = StreamingHttpResponse(
            iter([b"data: token\n\n" * 40]),
            content_type="text/event-stream",
        )
        processed = middleware.process_response(request, response)
        self.assertIsNone(processed.get("Content-Encoding"))

    def test_installer_archives_are_not_recompressed(self):
        # The client installers (APK/exe/tar.gz) are already compressed;
        # gzipping them again would waste CPU and, on the streamed ASGI path,
        # drop Content-Length.
        from django.http import HttpResponse
        from django.test import RequestFactory

        from apps.core.gzip import SelectiveGZipMiddleware

        middleware = SelectiveGZipMiddleware(lambda request: None)
        request = RequestFactory().get(
            "/clients/files/pointy.apk", HTTP_ACCEPT_ENCODING="gzip"
        )
        for content_type in (
            "application/vnd.android.package-archive",
            "application/gzip",
            "application/zip",
            "application/octet-stream",
        ):
            with self.subTest(content_type=content_type):
                response = HttpResponse(b"x" * 4096, content_type=content_type)
                processed = middleware.process_response(request, response)
                self.assertIsNone(processed.get("Content-Encoding"))
