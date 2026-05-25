import tempfile
from decimal import Decimal
from pathlib import Path
from unittest.mock import patch

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group
from django.core.files.uploadedfile import SimpleUploadedFile
from django.test import TestCase, override_settings
from django.urls import reverse
from rest_framework import status
from rest_framework.test import APIClient

from apps.catalog.testing import create_product_with_default_variant
from apps.core.roles import MANAGER_GROUP, ensure_role_groups
from apps.purchasing.models import PurchaseOrder, Supplier

from .image_search import (
    ProductImageSearchResult,
    ProductImageSearchUnavailable,
    RemoteImageUpload,
    search_product_images,
    search_serper_images,
    sign_image_import_payload,
)
from .models import Attachment


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

    def test_product_attachment_action_defaults_images_and_exposes_primary_image(self):
        response = self.client.post(
            reverse("product-attachments", args=[self.product.pk]),
            {
                "file": SimpleUploadedFile(
                    "product.txt",
                    b"product image placeholder" * 100,
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

    def test_product_image_search_uses_next_provider_when_first_is_unavailable(self):
        calls = []

        def unavailable_provider(*, query, page, page_size):
            calls.append(("serper", query, page, page_size))
            raise ProductImageSearchUnavailable("quota exhausted")

        def available_provider(*, query, page, page_size):
            calls.append(("serpapi", query, page, page_size))
            return [
                ProductImageSearchResult(
                    title="Fallback coffee bag",
                    thumbnail_url="https://images.example.com/fallback-thumb.jpg",
                    image_url="https://images.example.com/fallback-full.jpg",
                    source_url="https://shop.example.com/fallback-coffee",
                    source_name="Example Shop",
                    provider="serpapi",
                )
            ]

        with override_settings(POINTY_IMAGE_SEARCH_PROVIDERS="serper,serpapi"):
            with (
                patch(
                    "apps.attachments.image_search.search_serper_images",
                    side_effect=unavailable_provider,
                ),
                patch(
                    "apps.attachments.image_search.search_serpapi_images",
                    side_effect=available_provider,
                ),
            ):
                results = search_product_images(query="قهوة", page=1, page_size=10)

        self.assertEqual(results[0].provider, "serpapi")
        self.assertEqual(
            calls,
            [
                ("serper", "قهوة", 1, 10),
                ("serpapi", "قهوة", 1, 10),
            ],
        )

    def test_product_image_search_accumulates_unique_results_across_providers(self):
        def serper_provider(*, query, page, page_size):
            return [
                ProductImageSearchResult(
                    title="Coffee one",
                    thumbnail_url="https://images.example.com/one-thumb.jpg",
                    image_url="https://images.example.com/one-full.jpg",
                    source_url="https://shop.example.com/coffee-one",
                    source_name="Example Shop",
                    provider="serper",
                ),
                ProductImageSearchResult(
                    title="Coffee two",
                    thumbnail_url="https://images.example.com/two-thumb.jpg",
                    image_url="https://images.example.com/two-full.jpg",
                    source_url="https://shop.example.com/coffee-two",
                    source_name="Example Shop",
                    provider="serper",
                ),
            ]

        def serpapi_provider(*, query, page, page_size):
            return [
                ProductImageSearchResult(
                    title="Coffee two duplicate",
                    thumbnail_url="https://images.example.com/two-thumb-copy.jpg",
                    image_url="https://images.example.com/two-full.jpg",
                    source_url="https://shop.example.com/coffee-two-copy",
                    source_name="Example Shop",
                    provider="serpapi",
                ),
                ProductImageSearchResult(
                    title="Coffee three",
                    thumbnail_url="https://images.example.com/three-thumb.jpg",
                    image_url="https://images.example.com/three-full.jpg",
                    source_url="https://shop.example.com/coffee-three",
                    source_name="Example Shop",
                    provider="serpapi",
                ),
            ]

        with override_settings(POINTY_IMAGE_SEARCH_PROVIDERS="serper,serpapi"):
            with (
                patch(
                    "apps.attachments.image_search.search_serper_images",
                    side_effect=serper_provider,
                ),
                patch(
                    "apps.attachments.image_search.search_serpapi_images",
                    side_effect=serpapi_provider,
                ),
            ):
                results = search_product_images(query="قهوة", page=1, page_size=3)

        self.assertEqual(
            [result.image_url for result in results],
            [
                "https://images.example.com/one-full.jpg",
                "https://images.example.com/two-full.jpg",
                "https://images.example.com/three-full.jpg",
            ],
        )

    def test_serper_image_search_maps_api_response(self):
        with override_settings(
            POINTY_SERPER_API_KEY="serper-key",
            POINTY_SERPER_ENDPOINT="https://serper.example.com/images",
        ):
            with patch(
                "apps.attachments.image_search.fetch_json",
                return_value={
                    "images": [
                        {
                            "title": "Coffee bag",
                            "imageUrl": "https://images.example.com/coffee.jpg",
                            "thumbnailUrl": "https://images.example.com/thumb.jpg",
                            "link": "https://shop.example.com/coffee",
                            "domain": "shop.example.com",
                            "imageWidth": 900,
                            "imageHeight": 700,
                        }
                    ]
                },
            ) as fetch_json:
                results = search_serper_images(query="قهوة", page=2, page_size=12)

        self.assertEqual(len(results), 1)
        self.assertEqual(results[0].provider, "serper")
        self.assertEqual(results[0].source_name, "shop.example.com")
        self.assertEqual(results[0].width, 900)
        self.assertEqual(fetch_json.call_args.kwargs["method"], "POST")
        self.assertEqual(fetch_json.call_args.kwargs["body"]["page"], 2)
        self.assertEqual(fetch_json.call_args.kwargs["body"]["num"], 12)
        self.assertEqual(fetch_json.call_args.kwargs["headers"]["X-API-KEY"], "serper-key")

    def test_product_image_import_downloads_and_stores_primary_image(self):
        token = sign_image_import_payload(
            {
                "image_url": "https://images.example.com/full.jpg",
                "thumbnail_url": "https://images.example.com/thumb.jpg",
                "source_url": "https://shop.example.com/coffee",
                "source_name": "Example Shop",
                "title": "Coffee bag",
                "provider": "serpapi",
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

    def test_signed_content_url_can_render_without_authenticated_api_session(self):
        upload_response = self.client.post(
            reverse("product-attachments", args=[self.product.pk]),
            {
                "file": SimpleUploadedFile(
                    "preview.jpg",
                    b"authenticated preview",
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
            b"authenticated preview",
        )

    def test_unsigned_content_url_still_requires_authentication(self):
        upload_response = self.client.post(
            reverse("product-attachments", args=[self.product.pk]),
            {
                "file": SimpleUploadedFile(
                    "private.jpg",
                    b"private preview",
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
