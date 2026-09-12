import io
import ipaddress
import tempfile
from contextlib import ExitStack, contextmanager
from decimal import Decimal
from email.message import Message
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch
from urllib.error import HTTPError

from asgiref.sync import sync_to_async
from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group
from django.core.files.uploadedfile import SimpleUploadedFile
from django.core.management import call_command
from django.test import TestCase, override_settings
from django.urls import reverse
from PIL import Image
from rest_framework import status
from rest_framework.test import APIClient

from apps.catalog.testing import create_product_with_default_variant
from apps.core.relay import RelayControlError
from apps.core.roles import MANAGER_GROUP, TECHNICIAN_GROUP, ensure_role_groups
from apps.purchasing.models import PurchaseOrder, Supplier

from .image_normalization import MAX_DIMENSION, normalize_image_bytes
from .image_search import (
    ProductImageSearchNotEntitled,
    ProductImageSearchResult,
    ProductImageSearchUnavailable,
    RemoteImageUpload,
    search_product_images,
    sign_image_import_payload,
)
from .models import Attachment
from .services import open_attachment, store_uploaded_attachment


class AttachmentApiTests(TestCase):
    def setUp(self):
        self.storage_root = tempfile.TemporaryDirectory()
        self.volume_one = Path(self.storage_root.name) / "volume-a"
        self.volume_two = Path(self.storage_root.name) / "volume-b"
        self.volume_one.mkdir()
        self.volume_two.mkdir()
        self.settings_override = override_settings(
            POINTY_ATTACHMENT_STORAGE_ROOT=self.storage_root.name,
            POINTY_ATTACHMENT_ALLOWED_CONTENT_TYPES=[],
            POINTY_ATTACHMENT_MAX_UPLOAD_BYTES=1024 * 1024,
        )
        self.settings_override.enable()
        self.addCleanup(self.settings_override.disable)
        self.addCleanup(self.storage_root.cleanup)

        ensure_role_groups()
        self.client = APIClient()
        self.user = get_user_model().objects.create_user(
            username="attachment-manager",
            password="pass",
        )
        self.user.groups.add(Group.objects.get(name=MANAGER_GROUP))
        self.client.force_authenticate(user=self.user)
        self.product = create_product_with_default_variant(
            sku="ATTACH-COFFEE",
            name="قهوة مرفقات",
            unit_price=Decimal("4.00"),
        )

    def test_uploads_round_robin_across_volumes_and_download_original_bytes(self):
        first_payload = self.pdf_payload(b"A")
        second_payload = self.pdf_payload(b"B")

        first_response = self.upload_attachment(first_payload, "first.pdf")
        second_response = self.upload_attachment(second_payload, "second.pdf")

        self.assertEqual(first_response.status_code, status.HTTP_201_CREATED)
        self.assertEqual(second_response.status_code, status.HTTP_201_CREATED)

        attachments = list(Attachment.objects.order_by("id"))
        self.assertEqual(
            [attachment.storage_volume.path for attachment in attachments],
            [
                str(self.volume_one.resolve(strict=False)),
                str(self.volume_two.resolve(strict=False)),
            ],
        )
        self.assertEqual(attachments[0].storage_encoding, Attachment.StorageEncoding.GZIP)
        self.assertLess(attachments[0].stored_size, attachments[0].original_size)
        self.assertTrue(attachments[0].absolute_path.exists())

        download_response = self.client.get(
            reverse("attachment-download", args=[attachments[0].pk])
        )
        self.assertEqual(download_response.status_code, status.HTTP_200_OK)
        self.assertEqual(
            b"".join(download_response.streaming_content),
            first_payload,
        )

    def test_storage_volume_creation_rejects_path_outside_allowed_roots(self):
        outside = tempfile.TemporaryDirectory()
        self.addCleanup(outside.cleanup)

        response = self.client.post(
            reverse("storagevolume-list"),
            {"name": "rogue", "path": outside.name},
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertIn("path", response.data)

    def test_storage_volume_creation_allows_path_within_storage_root(self):
        inside = Path(self.storage_root.name) / "volume-c"
        inside.mkdir()

        response = self.client.post(
            reverse("storagevolume-list"),
            {"name": "volume-c", "path": str(inside)},
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_201_CREATED)

    def test_symlinked_storage_child_is_not_discovered(self):
        from .services import discovered_storage_paths

        outside = tempfile.TemporaryDirectory()
        self.addCleanup(outside.cleanup)
        link = Path(self.storage_root.name) / "evil-link"
        link.symlink_to(outside.name)

        discovered = discovered_storage_paths()

        resolved_target = str(Path(outside.name).resolve(strict=False))
        self.assertNotIn(resolved_target, discovered)
        self.assertNotIn(str(link), discovered)
        # The real volume directories are still discovered.
        self.assertIn(str(self.volume_one.resolve(strict=False)), discovered)

    def test_product_attachment_action_defaults_images_and_exposes_primary_image(self):
        response = self.client.post(
            reverse("product-attachments", args=[self.product.pk]),
            {
                "file": SimpleUploadedFile(
                    "product.jpg",
                    _encoded_image("JPEG"),
                    content_type="image/jpeg",
                ),
            },
            format="multipart",
        )

        self.assertEqual(response.status_code, status.HTTP_201_CREATED)
        self.assertEqual(response.data["role"], Attachment.Role.PRODUCT_IMAGE)
        self.assertTrue(response.data["is_primary"])

        product_response = self.client.get(reverse("product-detail", args=[self.product.pk]))
        self.assertEqual(product_response.status_code, status.HTTP_200_OK)
        self.assertEqual(product_response.data["primary_image"]["id"], response.data["id"])
        self.assertEqual(len(product_response.data["image_attachments"]), 1)

    def _upload_product_image(self, data, filename, content_type):
        return self.client.post(
            reverse("product-attachments", args=[self.product.pk]),
            {"file": SimpleUploadedFile(filename, data, content_type=content_type)},
            format="multipart",
        )

    def test_product_image_upload_reencodes_a_format_clients_cannot_decode(self):
        # A TIFF picked from disk stores happily and then renders as nothing on
        # the client -- the direct-upload half of the invisible-image report.
        response = self._upload_product_image(
            _encoded_image("TIFF"), "product.tiff", "image/tiff"
        )

        self.assertEqual(response.status_code, status.HTTP_201_CREATED)
        self.assertEqual(response.data["content_type"], "image/jpeg")
        self.assertTrue(response.data["original_filename"].endswith(".jpg"))
        self.assertEqual(self._stored_image_format(response.data["id"]), "JPEG")

    def test_product_image_upload_reencodes_a_heic_photo(self):
        # The picker labels an unrecognized extension image/jpeg, so an iPhone
        # HEIC arrives mislabeled; decoding the bytes re-encodes it to JPEG.
        buffer = io.BytesIO()
        try:
            Image.new("RGB", (48, 32), (10, 120, 200)).save(buffer, format="HEIF")
        except (OSError, KeyError, ValueError):
            self.skipTest("This Pillow build cannot encode HEIC.")

        response = self._upload_product_image(
            buffer.getvalue(), "IMG_0421.heic", "image/jpeg"
        )

        self.assertEqual(response.status_code, status.HTTP_201_CREATED)
        self.assertEqual(response.data["content_type"], "image/jpeg")
        self.assertEqual(self._stored_image_format(response.data["id"]), "JPEG")

    def test_product_image_upload_keeps_renderable_bytes_untouched(self):
        original = _encoded_image("PNG")

        response = self._upload_product_image(original, "product.png", "image/png")

        self.assertEqual(response.status_code, status.HTTP_201_CREATED)
        self.assertEqual(response.data["content_type"], "image/png")
        # Already renderable and in budget: re-encoding would only lose quality.
        self.assertEqual(self._stored_bytes(response.data["id"]), original)

    def test_product_image_upload_rejects_a_file_that_is_not_an_image(self):
        # The picker's content type is not trusted: bytes that no client can
        # decode are refused rather than stored as an invisible product photo.
        response = self._upload_product_image(
            b"not an image at all", "product.jpg", "image/jpeg"
        )

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertIn("file", response.data)
        self.assertFalse(
            Attachment.objects.filter(role=Attachment.Role.PRODUCT_IMAGE).exists()
        )

    def test_product_image_search_returns_signed_import_tokens(self):
        with patch(
            "apps.catalog.views.search_product_images",
            return_value=[
                ProductImageSearchResult(
                    title="Coffee bag",
                    thumbnail_url="https://images.example.com/thumb.jpg",
                    image_url="https://images.example.com/full.jpg",
                    source_url="https://shop.example.com/coffee",
                    source_name="Example Shop",
                    width=800,
                    height=600,
                )
            ],
        ):
            response = self.client.get(
                reverse("product-image-search"),
                {"q": "قهوة", "page_size": 12},
            )

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        result = response.data["results"][0]
        self.assertEqual(result["thumbnail_url"], "https://images.example.com/thumb.jpg")
        self.assertEqual(result["source_name"], "Example Shop")
        self.assertIn("import_token", result)
        self.assertNotIn("image_url", result)

    def test_an_unpaid_shop_is_told_so_rather_than_told_to_wait(self):
        """402 from the relay is an answer, not an outage.

        The shop sees a different sentence and a different status, because the
        two ask for opposite things: one means try again later, this means the
        subscription does not cover it.
        """

        with (
            patch(
                "apps.attachments.image_search.RelayInstallation"
            ) as mock_installation,
            patch(
                "apps.attachments.image_search.RelayControlClient"
            ) as mock_client,
        ):
            mock_installation.load.return_value = SimpleNamespace(
                access_token="ptr1.inst.secret"
            )
            mock_client.return_value.search_product_images.side_effect = (
                RelayControlError(
                    "relay control returned 402: subscription inactive",
                    status_code=402,
                )
            )
            with self.assertRaises(ProductImageSearchNotEntitled):
                search_product_images(query="قهوة")

    def test_the_endpoint_answers_an_unpaid_shop_with_403(self):
        with patch(
            "apps.catalog.views.search_product_images",
            side_effect=ProductImageSearchNotEntitled(
                "Product image search is not included in this shop's subscription."
            ),
        ):
            response = self.client.get(reverse("product-image-search"), {"q": "قهوة"})

        self.assertEqual(response.status_code, status.HTTP_403_FORBIDDEN)
        self.assertIn("subscription", response.data["detail"])

    def test_a_relay_outage_is_still_a_503(self):
        # Anything that is not an entitlement refusal keeps the old answer, so a
        # shop that IS paying still sees "try again" when the relay is down.
        with (
            patch(
                "apps.attachments.image_search.RelayInstallation"
            ) as mock_installation,
            patch(
                "apps.attachments.image_search.RelayControlClient"
            ) as mock_client,
        ):
            mock_installation.load.return_value = SimpleNamespace(
                access_token="ptr1.inst.secret"
            )
            mock_client.return_value.search_product_images.side_effect = (
                RelayControlError("relay control request failed: timed out")
            )
            with self.assertRaises(ProductImageSearchUnavailable):
                search_product_images(query="قهوة")

    def test_product_image_search_maps_relay_results(self):
        relay_payload = {
            "results": [
                {
                    "title": "Coffee bag",
                    "image_url": "https://images.example.com/coffee.jpg",
                    "thumbnail_url": "https://images.example.com/thumb.jpg",
                    "source_url": "https://shop.example.com/coffee",
                    "source_name": "shop.example.com",
                    "width": 900,
                    "height": 700,
                },
                # Same image URL as the first result: deduped away.
                {
                    "title": "Coffee bag copy",
                    "image_url": "https://images.example.com/coffee.jpg",
                    "thumbnail_url": "https://images.example.com/thumb-copy.jpg",
                    "source_url": "https://shop.example.com/coffee-copy",
                    "source_name": "shop.example.com",
                },
                # No image URL: dropped.
                {
                    "title": "No image",
                    "thumbnail_url": "https://images.example.com/x.jpg",
                },
            ]
        }
        with (
            patch(
                "apps.attachments.image_search.RelayInstallation"
            ) as mock_installation,
            patch(
                "apps.attachments.image_search.RelayControlClient"
            ) as mock_client,
        ):
            mock_installation.load.return_value = SimpleNamespace(
                access_token="ptr1.inst.secret"
            )
            mock_client.return_value.search_product_images.return_value = relay_payload
            results = search_product_images(query="قهوة", page=2, page_size=12)

        self.assertEqual(len(results), 1)
        self.assertEqual(results[0].provider, "serper")
        self.assertEqual(results[0].image_url, "https://images.example.com/coffee.jpg")
        self.assertEqual(results[0].source_name, "shop.example.com")
        self.assertEqual(results[0].width, 900)
        call_kwargs = mock_client.return_value.search_product_images.call_args.kwargs
        self.assertEqual(call_kwargs["access_token"], "ptr1.inst.secret")
        self.assertEqual(call_kwargs["query"], "قهوة")
        self.assertEqual(call_kwargs["page"], 2)
        self.assertEqual(call_kwargs["page_size"], 12)

    def test_product_image_search_unavailable_without_relay_installation(self):
        with patch(
            "apps.attachments.image_search.RelayInstallation"
        ) as mock_installation:
            mock_installation.load.return_value = None
            with self.assertRaises(ProductImageSearchUnavailable):
                search_product_images(query="قهوة")

    def test_product_image_search_unavailable_when_relay_errors(self):
        with (
            patch(
                "apps.attachments.image_search.RelayInstallation"
            ) as mock_installation,
            patch(
                "apps.attachments.image_search.RelayControlClient"
            ) as mock_client,
        ):
            mock_installation.load.return_value = SimpleNamespace(
                access_token="ptr1.inst.secret"
            )
            mock_client.return_value.search_product_images.side_effect = (
                RelayControlError("relay AI returned 402: relay subscription inactive")
            )
            with self.assertRaises(ProductImageSearchUnavailable):
                search_product_images(query="قهوة")

    def test_product_image_import_downloads_and_stores_primary_image(self):
        token = sign_image_import_payload(
            {
                "image_url": "https://images.example.com/full.jpg",
                "thumbnail_url": "https://images.example.com/thumb.jpg",
                "source_url": "https://shop.example.com/coffee",
                "source_name": "Example Shop",
                "title": "Coffee bag",
                "provider": "serper",
            }
        )

        with patch(
            "apps.attachments.image_search.fetch_remote_image_upload",
            return_value=RemoteImageUpload(
                name="coffee.jpg",
                content_type="image/jpeg",
                data=b"imported coffee image",
            ),
        ):
            response = self.client.post(
                reverse("product-image-import", args=[self.product.pk]),
                {"import_token": token},
                format="json",
            )

        self.assertEqual(response.status_code, status.HTTP_201_CREATED)
        self.assertEqual(response.data["role"], Attachment.Role.PRODUCT_IMAGE)
        self.assertTrue(response.data["is_primary"])
        self.assertEqual(response.data["metadata"]["imported_from"], "internet_search")
        self.assertEqual(response.data["metadata"]["source_name"], "Example Shop")

        content_response = self.client.get(
            reverse("attachment-content", args=[response.data["id"]])
        )
        self.assertEqual(content_response.status_code, status.HTTP_200_OK)
        self.assertEqual(
            b"".join(content_response.streaming_content),
            b"imported coffee image",
        )

    def test_product_image_import_falls_back_to_the_thumbnail_the_user_saw(self):
        # The picker only ever previews thumbnail_url, but the import fetches
        # image_url on the publisher's own host -- and publishers routinely 403
        # a hotlinked fetch. Without the fallback this is the "I can see it but
        # I can't save it" report from the field.
        token = self._import_token()
        transport = _FakeImageTransport(
            {
                "https://images.example.com/full.jpg": _http_error(403),
                "https://images.example.com/thumb.jpg": _image_response(
                    _encoded_image("JPEG"), "image/jpeg"
                ),
            }
        )

        with transport.patched():
            response = self._post_import(token)

        self.assertEqual(response.status_code, status.HTTP_201_CREATED)
        self.assertEqual(
            transport.requested_urls,
            [
                "https://images.example.com/full.jpg",
                "https://images.example.com/thumb.jpg",
            ],
        )
        metadata = response.data["metadata"]
        self.assertEqual(metadata["imported_url"], "https://images.example.com/thumb.jpg")
        self.assertTrue(metadata["imported_fallback_thumbnail"])

    def test_product_image_import_prefers_the_full_size_original(self):
        token = self._import_token()
        transport = _FakeImageTransport(
            {
                "https://images.example.com/full.jpg": _image_response(
                    _encoded_image("JPEG"), "image/jpeg"
                ),
                "https://images.example.com/thumb.jpg": _image_response(
                    _encoded_image("JPEG"), "image/jpeg"
                ),
            }
        )

        with transport.patched():
            response = self._post_import(token)

        self.assertEqual(response.status_code, status.HTTP_201_CREATED)
        # The thumbnail is a fallback, not a shortcut: it is never fetched when
        # the original is reachable.
        self.assertEqual(
            transport.requested_urls, ["https://images.example.com/full.jpg"]
        )
        self.assertFalse(response.data["metadata"]["imported_fallback_thumbnail"])

    def test_product_image_import_sends_hotlink_friendly_request_headers(self):
        token = self._import_token()
        transport = _FakeImageTransport(
            {
                "https://images.example.com/full.jpg": _image_response(
                    _encoded_image("JPEG"), "image/jpeg"
                ),
            }
        )

        with transport.patched():
            self._post_import(token)

        headers = transport.requested_headers[0]
        # Referer-based hotlink rules look for the page the image sits on.
        self.assertEqual(headers.get("Referer"), "https://shop.example.com/coffee")
        self.assertIn("Mozilla/5.0", headers.get("User-agent", ""))
        # Negotiating AVIF/SVG would hand back bytes no Pointy client can decode.
        self.assertNotIn("avif", headers.get("Accept", ""))
        self.assertNotIn("svg", headers.get("Accept", ""))

    def test_product_image_import_reencodes_formats_clients_cannot_decode(self):
        # A TIFF stores happily and then renders as nothing on the client. This
        # is the "they saved it and it doesn't show up" half of the report.
        token = self._import_token()
        transport = _FakeImageTransport(
            {
                "https://images.example.com/full.jpg": _image_response(
                    _encoded_image("TIFF"), "image/tiff"
                ),
            }
        )

        with transport.patched():
            response = self._post_import(token)

        self.assertEqual(response.status_code, status.HTTP_201_CREATED)
        self.assertEqual(response.data["content_type"], "image/jpeg")
        self.assertTrue(response.data["original_filename"].endswith(".jpg"))
        self.assertEqual(self._stored_image_format(response.data["id"]), "JPEG")

    def test_product_image_import_keeps_renderable_bytes_untouched(self):
        original = _encoded_image("PNG")
        token = self._import_token()
        transport = _FakeImageTransport(
            {
                "https://images.example.com/full.jpg": _image_response(
                    original, "image/png"
                ),
            }
        )

        with transport.patched():
            response = self._post_import(token)

        self.assertEqual(response.status_code, status.HTTP_201_CREATED)
        self.assertEqual(response.data["content_type"], "image/png")
        # Already renderable and in budget, so re-encoding would only lose
        # quality for nothing: the exact bytes survive.
        content_response = self.client.get(
            reverse("attachment-content", args=[response.data["id"]])
        )
        self.assertEqual(b"".join(content_response.streaming_content), original)

    def test_product_image_import_rejects_an_error_page_served_as_an_image(self):
        # Hotlink-blocking hosts serve an HTML "no hotlinking" page under an
        # image/* content type. Trusting the header would store the error page
        # as the product photo.
        token = self._import_token()
        html = b"<html><body>Hotlinking is not allowed</body></html>"
        transport = _FakeImageTransport(
            {
                "https://images.example.com/full.jpg": _image_response(html, "image/jpeg"),
                "https://images.example.com/thumb.jpg": _image_response(html, "image/jpeg"),
            }
        )

        with transport.patched():
            response = self._post_import(token)

        self.assertEqual(response.status_code, status.HTTP_502_BAD_GATEWAY)
        self.assertFalse(
            Attachment.objects.filter(role=Attachment.Role.PRODUCT_IMAGE).exists()
        )

    def test_product_image_import_downscales_an_oversized_original(self):
        token = self._import_token()
        transport = _FakeImageTransport(
            {
                "https://images.example.com/full.jpg": _image_response(
                    _encoded_image("JPEG", size=(4000, 3000)), "image/jpeg"
                ),
            }
        )

        with transport.patched():
            response = self._post_import(token)

        self.assertEqual(response.status_code, status.HTTP_201_CREATED)
        with Image.open(io.BytesIO(self._stored_bytes(response.data["id"]))) as stored:
            self.assertEqual(max(stored.size), MAX_DIMENSION)

    def test_product_image_import_still_blocks_private_hosts_on_the_fallback(self):
        # The fallback must not become an SSRF hole: a token whose thumbnail
        # points at the metadata service is refused like any other candidate.
        token = sign_image_import_payload(
            {
                "image_url": "https://images.example.com/full.jpg",
                "thumbnail_url": "http://169.254.169.254/latest/meta-data/",
                "source_url": "https://shop.example.com/coffee",
                "source_name": "Example Shop",
                "title": "Coffee bag",
                "provider": "serper",
            }
        )
        transport = _FakeImageTransport(
            {"https://images.example.com/full.jpg": _http_error(404)}
        )

        with transport.patched():
            response = self._post_import(token)

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        # Refused before any connection was opened.
        self.assertNotIn("http://169.254.169.254/latest/meta-data/", transport.requested_urls)

    def _import_token(self):
        return sign_image_import_payload(
            {
                "image_url": "https://images.example.com/full.jpg",
                "thumbnail_url": "https://images.example.com/thumb.jpg",
                "source_url": "https://shop.example.com/coffee",
                "source_name": "Example Shop",
                "title": "Coffee bag",
                "provider": "serper",
            }
        )

    def _post_import(self, token):
        return self.client.post(
            reverse("product-image-import", args=[self.product.pk]),
            {"import_token": token},
            format="json",
        )

    def _stored_bytes(self, attachment_id):
        response = self.client.get(reverse("attachment-content", args=[attachment_id]))
        return b"".join(response.streaming_content)

    def _stored_image_format(self, attachment_id):
        with Image.open(io.BytesIO(self._stored_bytes(attachment_id))) as image:
            return image.format

    def test_signed_content_url_can_render_without_authenticated_api_session(self):
        preview = _encoded_image("JPEG")
        upload_response = self.client.post(
            reverse("product-attachments", args=[self.product.pk]),
            {
                "file": SimpleUploadedFile(
                    "preview.jpg",
                    preview,
                    content_type="image/jpeg",
                ),
            },
            format="multipart",
        )
        self.assertEqual(upload_response.status_code, status.HTTP_201_CREATED)

        anonymous = APIClient()
        content_response = anonymous.get(upload_response.data["content_url"])

        self.assertEqual(content_response.status_code, status.HTTP_200_OK)
        self.assertEqual(
            b"".join(content_response.streaming_content),
            preview,
        )

    def test_content_response_carries_cache_validators(self):
        upload_response = self.upload_attachment(self.pdf_payload(b"E"), "etag.pdf")
        self.assertEqual(upload_response.status_code, status.HTTP_201_CREATED)

        content_response = self.client.get(
            reverse("attachment-content", args=[upload_response.data["id"]])
        )

        self.assertEqual(content_response.status_code, status.HTTP_200_OK)
        self.assertEqual(
            content_response["ETag"],
            f'"{upload_response.data["checksum_sha256"]}"',
        )
        self.assertIn("max-age=86400", content_response["Cache-Control"])
        self.assertIn("private", content_response["Cache-Control"])
        self.assertTrue(content_response["Last-Modified"])

    def test_matching_if_none_match_returns_304_without_a_body(self):
        upload_response = self.upload_attachment(self.pdf_payload(b"F"), "cond.pdf")
        url = reverse("attachment-content", args=[upload_response.data["id"]])
        etag = self.client.get(url)["ETag"]

        revalidation = self.client.get(url, HTTP_IF_NONE_MATCH=etag)

        self.assertEqual(revalidation.status_code, status.HTTP_304_NOT_MODIFIED)
        self.assertFalse(revalidation.content)
        # The 304 must re-state the validators so clients extend their cache.
        self.assertEqual(revalidation["ETag"], etag)
        self.assertIn("max-age=86400", revalidation["Cache-Control"])

    def test_stale_if_none_match_serves_the_full_body(self):
        upload_response = self.upload_attachment(self.pdf_payload(b"G"), "stale.pdf")
        url = reverse("attachment-content", args=[upload_response.data["id"]])

        response = self.client.get(url, HTTP_IF_NONE_MATCH='"different-etag"')

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertTrue(b"".join(response.streaming_content))

    async def test_asgi_content_streams_an_async_iterator(self):
        # Under ASGI (uvicorn in production) Django buffers FileResponse's
        # sync file iterator wholesale — the entire attachment in memory
        # before the first byte — so the view must hand Django an async
        # iterator carrying the headers FileResponse would have set. This
        # payload compresses, so it's stored gzip-encoded: the stream must
        # pass through the decompressing handle and Content-Length must be
        # the original (decompressed) size.
        payload = self.pdf_payload(b"H")
        upload = await sync_to_async(self.upload_attachment)(payload, "asgi.pdf")
        self.assertEqual(upload.status_code, status.HTTP_201_CREATED)
        self.assertEqual(
            upload.data["storage_encoding"], Attachment.StorageEncoding.GZIP
        )

        response = await self.async_client.get(upload.data["content_url"])

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertTrue(response.streaming)
        self.assertTrue(response.is_async)
        self.assertEqual(response["Content-Type"], "application/pdf")
        self.assertEqual(response["Content-Length"], str(len(payload)))
        self.assertIn("inline", response["Content-Disposition"])
        self.assertIn("asgi.pdf", response["Content-Disposition"])
        self.assertEqual(response["ETag"], f'"{upload.data["checksum_sha256"]}"')
        self.assertIn("max-age=86400", response["Cache-Control"])
        body = b"".join([chunk async for chunk in response.streaming_content])
        self.assertEqual(body, payload)

    async def test_asgi_download_streams_with_attachment_disposition(self):
        payload = self.pdf_payload(b"I")
        upload = await sync_to_async(self.upload_attachment)(payload, "asgi-dl.pdf")
        self.assertEqual(upload.status_code, status.HTTP_201_CREATED)
        # The download action needs a real authenticated session — DRF's
        # force_authenticate only rides the sync APIClient.
        await sync_to_async(self.async_client.force_login)(self.user)

        response = await self.async_client.get(
            reverse("attachment-download", args=[upload.data["id"]])
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertTrue(response.streaming)
        self.assertTrue(response.is_async)
        self.assertEqual(response["Content-Length"], str(len(payload)))
        self.assertIn("attachment", response["Content-Disposition"])
        self.assertIn("asgi-dl.pdf", response["Content-Disposition"])
        body = b"".join([chunk async for chunk in response.streaming_content])
        self.assertEqual(body, payload)

    def test_unsigned_content_url_still_requires_authentication(self):
        upload_response = self.client.post(
            reverse("product-attachments", args=[self.product.pk]),
            {
                "file": SimpleUploadedFile(
                    "private.jpg",
                    _encoded_image("JPEG"),
                    content_type="image/jpeg",
                ),
            },
            format="multipart",
        )
        self.assertEqual(upload_response.status_code, status.HTTP_201_CREATED)

        anonymous = APIClient()
        content_response = anonymous.get(
            reverse("attachment-content", args=[upload_response.data["id"]])
        )

        self.assertEqual(content_response.status_code, status.HTTP_401_UNAUTHORIZED)

    def test_purchase_order_attachment_action_exposes_supplier_invoice_scans(self):
        supplier = Supplier.objects.create(name="Invoice supplier")
        purchase_order = PurchaseOrder.objects.create(supplier=supplier)

        response = self.client.post(
            reverse("purchaseorder-attachments", args=[purchase_order.pk]),
            {
                "file": SimpleUploadedFile(
                    "supplier-invoice.pdf",
                    self.pdf_payload(b"C"),
                    content_type="application/pdf",
                ),
            },
            format="multipart",
        )

        self.assertEqual(response.status_code, status.HTTP_201_CREATED)
        self.assertEqual(response.data["role"], Attachment.Role.SUPPLIER_INVOICE_SCAN)

        order_response = self.client.get(reverse("purchaseorder-detail", args=[purchase_order.pk]))
        self.assertEqual(order_response.status_code, status.HTTP_200_OK)
        self.assertEqual(
            order_response.data["supplier_invoice_attachments"][0]["id"],
            response.data["id"],
        )

    def _technician_client(self):
        """A technician: the only stock role holding ``attachments.view_attachment``
        and none of the purchasing permissions."""
        technician = get_user_model().objects.create_user(
            username="attachment-technician",
            password="pass",
        )
        technician.groups.add(Group.objects.get(name=TECHNICIAN_GROUP))
        self.assertFalse(technician.has_perm("purchasing.view_purchaseorder"))
        self.assertTrue(technician.has_perm("attachments.view_attachment"))
        client = APIClient()
        client.force_authenticate(user=technician)
        return client

    def _supplier_invoice_attachment(self):
        supplier = Supplier.objects.create(name="Confidential supplier")
        purchase_order = PurchaseOrder.objects.create(supplier=supplier)
        response = self.client.post(
            reverse("purchaseorder-attachments", args=[purchase_order.pk]),
            {
                "file": SimpleUploadedFile(
                    "supplier-invoice.pdf",
                    self.pdf_payload(b"S"),
                    content_type="application/pdf",
                ),
            },
            format="multipart",
        )
        self.assertEqual(response.status_code, status.HTTP_201_CREATED)
        return response.data["id"]

    def test_attachment_list_hides_owners_the_user_may_not_view(self):
        """The purchase order's own ``attachments`` action requires BOTH
        ``purchasing.view_purchaseorder`` and ``attachments.view_attachment``.
        The generic attachment endpoint must not serve the same rows on half
        that gate."""
        attachment_id = self._supplier_invoice_attachment()
        client = self._technician_client()

        # The properly gated path is closed to a technician...
        listed = client.get(reverse("attachment-list"))
        self.assertEqual(listed.status_code, status.HTTP_200_OK)
        returned = {row["id"] for row in listed.data["results"]}
        self.assertNotIn(attachment_id, returned)

    def test_attachment_detail_and_download_deny_an_unviewable_owner(self):
        attachment_id = self._supplier_invoice_attachment()
        client = self._technician_client()

        for view_name in ("attachment-detail", "attachment-download"):
            response = client.get(reverse(view_name, args=[attachment_id]))
            self.assertEqual(
                response.status_code,
                status.HTTP_404_NOT_FOUND,
                msg=f"{view_name} exposed a supplier invoice scan to a technician",
            )

    def test_attachment_list_still_serves_owners_the_user_may_view(self):
        """A technician holds ``catalog.view_product``, so product images stay
        visible — the scope narrows to the owner, it does not blanket-deny."""
        upload = self.upload_attachment(self.pdf_payload(b"P"), "product.pdf")
        self.assertEqual(upload.status_code, status.HTTP_201_CREATED)
        client = self._technician_client()

        listed = client.get(reverse("attachment-list"))
        self.assertEqual(listed.status_code, status.HTTP_200_OK)
        self.assertIn(upload.data["id"], {row["id"] for row in listed.data["results"]})

    def test_signed_content_token_still_serves_an_unauthenticated_kiosk(self):
        """Price-checker kiosks and the POS render product images through the
        signed ``content`` URL with no session at all; owner scoping must not
        break that path (the token already binds to one attachment)."""
        upload = self.upload_attachment(self.pdf_payload(b"K"), "kiosk.pdf")
        self.assertEqual(upload.status_code, status.HTTP_201_CREATED)
        content_url = upload.data["content_url"]

        anonymous = APIClient()
        response = anonymous.get(content_url)
        self.assertEqual(response.status_code, status.HTTP_200_OK)

    def test_an_expired_link_says_so_and_says_it_is_recoverable(self):
        """63 identical 403s on one attachment over two days is what a single
        undifferentiated refusal looks like from the outside. A stale six-hour
        URL is fixed by re-reading the owner; a forged one never is, and the
        client can only tell them apart if we say which happened."""
        upload = self.upload_attachment(self.pdf_payload(b"E"), "expired.pdf")
        content_url = upload.data["content_url"]

        anonymous = APIClient()
        # Every token in existence is older than a zero-second window.
        with override_settings(POINTY_ATTACHMENT_CONTENT_TOKEN_MAX_AGE_SECONDS=0):
            response = anonymous.get(content_url)

        self.assertEqual(response.status_code, status.HTTP_403_FORBIDDEN)
        self.assertEqual(response.data["code"], "attachment_token_expired")
        self.assertTrue(response.data["recoverable"])

    def test_a_forged_token_is_refused_as_permanent(self):
        upload = self.upload_attachment(self.pdf_payload(b"F"), "forged.pdf")
        attachment_id = upload.data["id"]

        anonymous = APIClient()
        response = anonymous.get(
            reverse("attachment-content", args=[attachment_id]),
            {"token": "not-a-real-token"},
        )

        self.assertEqual(response.status_code, status.HTTP_403_FORBIDDEN)
        self.assertEqual(response.data["code"], "attachment_token_invalid")
        self.assertFalse(response.data["recoverable"])

    def test_a_token_for_replaced_bytes_is_recoverable(self):
        """The link was signed for content that has since changed — re-reading
        the owner hands out one that matches."""
        upload = self.upload_attachment(self.pdf_payload(b"S"), "stale.pdf")
        content_url = upload.data["content_url"]
        attachment = Attachment.objects.get(pk=upload.data["id"])
        attachment.checksum_sha256 = "0" * 64
        attachment.save(update_fields=["checksum_sha256"])

        response = APIClient().get(content_url)

        self.assertEqual(response.status_code, status.HTTP_403_FORBIDDEN)
        self.assertEqual(response.data["code"], "attachment_token_stale")
        self.assertTrue(response.data["recoverable"])

    def upload_attachment(self, payload, filename):
        return self.client.post(
            reverse("attachment-list"),
            {
                "owner_type": "catalog.product",
                "owner_id": self.product.pk,
                "role": Attachment.Role.PRODUCT_IMAGE,
                "file": SimpleUploadedFile(
                    filename,
                    payload,
                    content_type="application/pdf",
                ),
            },
            format="multipart",
        )

    def pdf_payload(self, repeated_byte):
        return b"%PDF-1.4\n" + repeated_byte * 4096 + b"\n%%EOF"


def _encoded_image(image_format, *, size=(40, 30), color=(200, 60, 60)):
    buffer = io.BytesIO()
    Image.new("RGB", size, color).save(buffer, format=image_format)
    return buffer.getvalue()


def _image_response(data, content_type, *, url=None):
    """A stand-in for the urllib response the opener hands back."""
    return SimpleNamespace(data=data, content_type=content_type, url=url)


def _http_error(code):
    return HTTPError("https://images.example.com/full.jpg", code, "Forbidden", {}, None)


class _FakeResponse:
    def __init__(self, data, content_type, url):
        self._buffer = io.BytesIO(data)
        self._url = url
        self.headers = Message()
        self.headers["Content-Type"] = content_type
        self.headers["Content-Length"] = str(len(data))

    def read(self, size=-1):
        return self._buffer.read(size)

    def geturl(self):
        return self._url

    def __enter__(self):
        return self

    def __exit__(self, *exc_info):
        self._buffer.close()
        return False


class _FakeImageTransport:
    """Serves canned bytes per URL, standing in for the remote image hosts.

    Also stubs DNS: the download path resolves each host to check it is not a
    private address, which would otherwise make these tests hit the network.
    """

    def __init__(self, responses):
        self._responses = responses
        self.requested_urls = []
        self.requested_headers = []

    def _open(self, request, timeout=None):
        url = request.full_url
        self.requested_urls.append(url)
        self.requested_headers.append(dict(request.headers))
        outcome = self._responses.get(url)
        if outcome is None:
            raise HTTPError(url, 404, "Not Found", {}, None)
        if isinstance(outcome, Exception):
            raise outcome
        return _FakeResponse(outcome.data, outcome.content_type, outcome.url or url)

    def _getaddrinfo(self, host, port, *args, **kwargs):
        # Faithful to the real resolver on the one point these tests turn on: an
        # IP literal resolves to itself, so the SSRF guard still sees the
        # address it is meant to reject. Names resolve to a routable public
        # address instead of hitting DNS.
        try:
            ipaddress.ip_address(host)
        except ValueError:
            resolved = "93.184.216.34"
        else:
            resolved = host
        return [(2, 1, 6, "", (resolved, port or 443))]

    @contextmanager
    def patched(self):
        opener = SimpleNamespace(open=self._open)
        with ExitStack() as stack:
            stack.enter_context(
                patch(
                    "apps.attachments.image_search.build_opener",
                    return_value=opener,
                )
            )
            stack.enter_context(
                patch(
                    "apps.attachments.image_search.socket.getaddrinfo",
                    side_effect=self._getaddrinfo,
                )
            )
            yield self


class ImageNormalizationTests(TestCase):
    def test_rejects_payloads_that_are_not_images(self):
        for label, payload in (
            ("html error page", b"<html><body>nope</body></html>"),
            ("empty", b""),
            ("truncated jpeg", _encoded_image("JPEG")[:20]),
            # Flutter cannot render SVG, and neither can Pillow decode it, so an
            # SVG hit is refused rather than stored as an invisible image.
            ("svg", b'<svg xmlns="http://www.w3.org/2000/svg"><rect/></svg>'),
        ):
            with self.subTest(label):
                self.assertIsNone(normalize_image_bytes(payload))

    def test_rejects_a_decompression_bomb_instead_of_raising(self):
        # Pillow's DecompressionBombError derives straight from Exception, so it
        # escapes an OSError/ValueError handler and would 500 the import.
        with patch(
            "apps.attachments.image_normalization.Image.open",
            side_effect=Image.DecompressionBombError("too big"),
        ):
            self.assertIsNone(normalize_image_bytes(_encoded_image("JPEG")))

    def test_passes_through_renderable_formats_byte_for_byte(self):
        for image_format, content_type in (
            ("JPEG", "image/jpeg"),
            ("PNG", "image/png"),
            ("WEBP", "image/webp"),
            ("GIF", "image/gif"),
        ):
            with self.subTest(image_format):
                original = _encoded_image(image_format)
                normalized = normalize_image_bytes(original)
                self.assertIsNotNone(normalized)
                self.assertEqual(normalized.data, original)
                self.assertEqual(normalized.content_type, content_type)

    def test_reencodes_a_format_clients_cannot_decode(self):
        normalized = normalize_image_bytes(_encoded_image("TIFF"))

        self.assertIsNotNone(normalized)
        self.assertEqual(normalized.content_type, "image/jpeg")
        self.assertEqual(normalized.extension, ".jpg")
        with Image.open(io.BytesIO(normalized.data)) as image:
            self.assertEqual(image.format, "JPEG")

    def test_reencodes_avif_when_the_pillow_build_can_read_it(self):
        # Pillow only bundles AVIF from 11.3; on an older build the format is
        # simply undecodable, and the import falls back to the thumbnail.
        buffer = io.BytesIO()
        try:
            Image.new("RGB", (40, 30), (10, 20, 30)).save(buffer, format="AVIF")
        except (OSError, KeyError, ValueError):
            self.skipTest("This Pillow build cannot encode AVIF.")

        normalized = normalize_image_bytes(buffer.getvalue())

        self.assertIsNotNone(normalized)
        self.assertEqual(normalized.content_type, "image/jpeg")

    def test_keeps_transparency_as_png_rather_than_flattening_to_black(self):
        buffer = io.BytesIO()
        Image.new("RGBA", (40, 30), (255, 0, 0, 0)).save(buffer, format="TIFF")

        normalized = normalize_image_bytes(buffer.getvalue())

        self.assertIsNotNone(normalized)
        self.assertEqual(normalized.content_type, "image/png")
        with Image.open(io.BytesIO(normalized.data)) as image:
            self.assertEqual(image.mode, "RGBA")

    def test_downscales_an_oversized_image(self):
        normalized = normalize_image_bytes(
            _encoded_image("TIFF", size=(5000, 2500))
        )

        self.assertIsNotNone(normalized)
        with Image.open(io.BytesIO(normalized.data)) as image:
            self.assertEqual(image.size, (MAX_DIMENSION, MAX_DIMENSION // 2))

    def test_keeps_an_animated_gif_animated(self):
        # Re-encoding would silently flatten the animation to one frame.
        buffer = io.BytesIO()
        frames = [Image.new("RGB", (4000, 10), (i, i, i)) for i in range(3)]
        frames[0].save(buffer, format="GIF", save_all=True, append_images=frames[1:])
        original = buffer.getvalue()

        normalized = normalize_image_bytes(original)

        self.assertIsNotNone(normalized)
        self.assertEqual(normalized.data, original)
        self.assertEqual(normalized.content_type, "image/gif")


class NormalizeStoredImagesCommandTests(TestCase):
    def setUp(self):
        self.storage_root = tempfile.TemporaryDirectory()
        (Path(self.storage_root.name) / "volume-a").mkdir()
        self.settings_override = override_settings(
            POINTY_ATTACHMENT_STORAGE_ROOT=self.storage_root.name,
            POINTY_ATTACHMENT_ALLOWED_CONTENT_TYPES=[],
            POINTY_ATTACHMENT_MAX_UPLOAD_BYTES=8 * 1024 * 1024,
        )
        self.settings_override.enable()
        self.addCleanup(self.settings_override.disable)
        self.addCleanup(self.storage_root.cleanup)
        self.product = create_product_with_default_variant(
            sku="BACKFILL-COFFEE",
            name="قهوة",
            unit_price=Decimal("4.00"),
        )

    def _store(self, data, filename, content_type):
        return store_uploaded_attachment(
            uploaded_file=SimpleUploadedFile(filename, data, content_type=content_type),
            owner=self.product,
            role=Attachment.Role.PRODUCT_IMAGE,
            is_primary=True,
        )

    def test_reencodes_an_unrenderable_stored_image_in_place(self):
        attachment = self._store(_encoded_image("TIFF"), "coffee.tiff", "image/tiff")
        original_path = attachment.absolute_path

        call_command("normalize_stored_images", stdout=io.StringIO())

        attachment.refresh_from_db()
        # Same row: everything already pointing at this attachment still works.
        self.assertEqual(attachment.content_type, "image/jpeg")
        self.assertTrue(attachment.is_primary)
        self.assertTrue(attachment.original_filename.endswith(".jpg"))
        with open_attachment(attachment) as handle:
            with Image.open(io.BytesIO(handle.read())) as image:
                self.assertEqual(image.format, "JPEG")
        # The superseded file is cleaned up rather than left behind.
        self.assertFalse(original_path.exists())
        self.assertTrue(attachment.absolute_path.exists())

    def test_leaves_already_renderable_images_untouched(self):
        attachment = self._store(_encoded_image("JPEG"), "coffee.jpg", "image/jpeg")
        original_path = attachment.absolute_path
        original_checksum = attachment.checksum_sha256

        call_command("normalize_stored_images", stdout=io.StringIO())

        attachment.refresh_from_db()
        self.assertEqual(attachment.checksum_sha256, original_checksum)
        self.assertEqual(attachment.absolute_path, original_path)

    def test_dry_run_reports_without_writing(self):
        attachment = self._store(_encoded_image("TIFF"), "coffee.tiff", "image/tiff")
        original_checksum = attachment.checksum_sha256
        stdout = io.StringIO()

        call_command("normalize_stored_images", "--dry-run", stdout=stdout)

        attachment.refresh_from_db()
        self.assertEqual(attachment.checksum_sha256, original_checksum)
        self.assertEqual(attachment.content_type, "image/tiff")
        self.assertIn('"reencoded": 1', stdout.getvalue())

    def test_survives_an_attachment_whose_bytes_are_not_an_image(self):
        # A stored non-image must be reported, not crash the whole sweep.
        broken = self._store(b"not an image at all", "broken.jpg", "image/jpeg")
        fixable = self._store(_encoded_image("TIFF"), "coffee.tiff", "image/tiff")
        fixable.is_primary = False
        fixable.save(update_fields=["is_primary"])
        stderr = io.StringIO()

        call_command("normalize_stored_images", stdout=io.StringIO(), stderr=stderr)

        broken.refresh_from_db()
        fixable.refresh_from_db()
        self.assertEqual(broken.content_type, "image/jpeg")
        self.assertIn(f"attachment {broken.pk}", stderr.getvalue())
        # The sweep carried on past the bad row.
        self.assertEqual(fixable.content_type, "image/jpeg")
