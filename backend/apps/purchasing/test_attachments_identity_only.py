"""Regression test: the PO attachments tab must not load the document tree.

``PurchaseOrderViewSet.queryset`` prefetches twenty relations for the details
screen, and ``get_object()`` runs that queryset for *every* detail route — so
opening the supplier-invoice attachments tab, which serializes nothing but
``purchase_order.attachments``, paid for the whole tree and discarded it. The
test forces the tree back on and compares, so it measures the saving rather
than asserting a fixture-specific number, and checks the payload either way.
"""

from decimal import Decimal
from unittest.mock import patch

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group
from django.contrib.contenttypes.models import ContentType
from django.db import connection
from django.test import TestCase, override_settings
from django.test.utils import CaptureQueriesContext
from django.urls import reverse
from rest_framework.test import APIClient

from apps.attachments.models import Attachment, StorageVolume
from apps.catalog.testing import create_product_with_default_variant
from apps.core.roles import MANAGER_GROUP, ensure_role_groups
from apps.inventory.models import StockItem

from .models import PurchaseOrder, Supplier
from .views import PurchaseOrderViewSet


def _without_rotating_tokens(payload):
    """``content_url`` re-signs per serialization, so two identical payloads
    never compare equal until the token is stripped."""
    if isinstance(payload, list):
        return [_without_rotating_tokens(item) for item in payload]
    if isinstance(payload, dict):
        return {key: _without_rotating_tokens(value) for key, value in payload.items()}
    if isinstance(payload, str) and "token=" in payload:
        return payload.split("token=")[0]
    return payload


@override_settings(
    CACHES={"default": {"BACKEND": "django.core.cache.backends.locmem.LocMemCache"}}
)
class PurchaseOrderAttachmentsQueryTests(TestCase):
    def setUp(self):
        ensure_role_groups()
        self.client = APIClient()
        self.user = get_user_model().objects.create_user(username="buyer", password="p")
        self.user.groups.add(Group.objects.get(name=MANAGER_GROUP))
        self.client.force_authenticate(user=self.user)
        self.supplier = Supplier.objects.create(name="Attachment supplier")

        variants = []
        for index in range(4):
            product = create_product_with_default_variant(
                sku=f"ATT-{index}",
                barcode="",
                name=f"Attachment product {index}",
                unit_price=Decimal("2.00"),
            )
            StockItem.objects.create(variant=product.default_variant, quantity_on_hand=0)
            variants.append(product.default_variant)

        create = self.client.post(
            reverse("purchaseorder-list"),
            {
                "supplier": self.supplier.pk,
                "lines": [
                    {"variant": variant.pk, "quantity": 2, "unit_cost": "1.25"}
                    for variant in variants
                ],
            },
            format="json",
        )
        self.assertEqual(create.status_code, 201, create.data)
        self.order_id = create.data["id"]
        self.assertEqual(
            self.client.post(
                reverse("purchaseorder-submit", args=[self.order_id]), format="json"
            ).status_code,
            200,
        )
        # Receive it so the receipt/audit/stock trees the prefetch list covers
        # actually have rows — an unpopulated relation hides the waste.
        self.assertEqual(
            self.client.post(
                reverse("purchaseorder-receive", args=[self.order_id]), format="json"
            ).status_code,
            200,
        )

        volume = StorageVolume.objects.create(name="vol", path="/tmp/vol")
        Attachment.objects.create(
            owner_content_type=ContentType.objects.get_for_model(PurchaseOrder),
            owner_object_id=self.order_id,
            role=Attachment.Role.SUPPLIER_INVOICE_SCAN,
            storage_volume=volume,
            relative_path="po/invoice.jpg",
            original_filename="invoice.jpg",
            original_size=10,
            stored_size=10,
            checksum_sha256="x",
            is_primary=True,
            created_by=self.user,
        )

    def _measure(self, url):
        self.client.get(url)  # warm permission/content-type caches
        with CaptureQueriesContext(connection) as ctx:
            response = self.client.get(url)
        self.assertEqual(response.status_code, 200)
        return len(ctx.captured_queries), _without_rotating_tokens(response.json())

    def test_attachments_tab_skips_the_purchase_order_document_tree(self):
        url = reverse("purchaseorder-attachments", args=[self.order_id])
        # ``create=True`` so this reads as a clean assertion failure -- not an
        # AttributeError -- on a tree where the optimization is absent.
        with patch.object(
            PurchaseOrderViewSet, "_identity_only_actions", (), create=True
        ):
            heavy_queries, heavy_body = self._measure(url)
        lean_queries, lean_body = self._measure(url)

        self.assertEqual(len(lean_body), 1)
        self.assertEqual(
            lean_body, heavy_body, "dropping the prefetch tree changed the payload"
        )
        self.assertLessEqual(
            lean_queries,
            heavy_queries - 8,
            "the attachments tab still loads the whole order: "
            f"{heavy_queries} queries with the tree, {lean_queries} without",
        )

    def test_the_detail_payload_keeps_the_document_tree(self):
        """The guard on the other side: ``retrieve`` serializes the full order,
        so adding it to the identity-only set would trade twenty prefetches for
        an N+1 per line."""
        url = reverse("purchaseorder-detail", args=[self.order_id])
        with patch.object(
            PurchaseOrderViewSet, "_identity_only_actions", (), create=True
        ):
            heavy_queries, heavy_body = self._measure(url)
        lean_queries, lean_body = self._measure(url)
        self.assertEqual(lean_body, heavy_body)
        self.assertEqual(
            lean_queries,
            heavy_queries,
            "purchaseorder-detail no longer prefetches the document tree",
        )
