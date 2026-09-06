"""The trail over HTTP.

A document's history is as sensitive as the document, so the endpoint asks for
the same permission the document does — and refuses to answer at all without a
document to answer about.
"""

from decimal import Decimal

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group
from django.test import TestCase
from django.urls import reverse
from rest_framework import status
from rest_framework.test import APIClient

from apps.catalog.testing import create_product_with_default_variant
from apps.core.roles import CASHIER_GROUP, MANAGER_GROUP, ensure_role_groups
from apps.documents.models import DocumentEvent
from apps.purchasing.models import PurchaseOrder, Supplier
from apps.purchasing.services import cancel_purchase_order, submit_purchase_order


class DocumentTrailApiTests(TestCase):
    def setUp(self):
        ensure_role_groups()
        User = get_user_model()
        self.manager = User.objects.create_user(username="trail-manager", password="p")
        self.manager.groups.add(Group.objects.get(name=MANAGER_GROUP))
        self.cashier = User.objects.create_user(username="trail-cashier", password="p")
        self.cashier.groups.add(Group.objects.get(name=CASHIER_GROUP))
        self.client = APIClient()
        self.client.force_authenticate(user=self.manager)

        product = create_product_with_default_variant(
            name="Trail widget", sku="TW1", barcode="", unit_price=Decimal("4.00")
        )
        self.supplier = Supplier.objects.create(name="Trail supplier")
        self.order = PurchaseOrder.objects.create(supplier=self.supplier)
        self.order.lines.create(
            variant=product.default_variant, quantity=2, unit_cost=Decimal("1.00")
        )
        self.order.recalculate()
        self.order.save(update_fields=["subtotal", "total", "updated_at"])
        submit_purchase_order(self.order, request=None)

    def _url(self, **params):
        query = "&".join(f"{key}={value}" for key, value in params.items())
        return f"{reverse('document-event-list')}?{query}"

    def test_it_returns_what_happened_to_one_document(self):
        cancel_purchase_order(self.order, request=None, reason="ألغى المورد")

        response = self.client.get(
            self._url(document_type="purchase_order", object_id=self.order.pk)
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        rows = response.data["results"] if "results" in response.data else response.data
        actions = [row["action"] for row in rows]
        self.assertEqual(actions, ["cancelled", "submitted"])
        self.assertEqual(rows[0]["reason"], "ألغى المورد")
        self.assertEqual(rows[0]["document_number"], self.order.order_number)

    def test_it_refuses_to_answer_without_a_document(self):
        response = self.client.get(self._url(document_type="purchase_order"))
        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)

    def test_it_refuses_a_type_it_does_not_know(self):
        response = self.client.get(self._url(document_type="wishes", object_id=1))
        self.assertIn(
            response.status_code,
            (status.HTTP_400_BAD_REQUEST, status.HTTP_403_FORBIDDEN),
        )

    def test_a_purchase_orders_trail_needs_permission_to_see_purchase_orders(self):
        """A cashier can see sales, not purchasing — and the trail follows the
        document rather than having a permission of its own."""
        cashier_client = APIClient()
        cashier_client.force_authenticate(user=self.cashier)
        response = cashier_client.get(
            self._url(document_type="purchase_order", object_id=self.order.pk)
        )
        self.assertEqual(response.status_code, status.HTTP_403_FORBIDDEN)

    def test_one_documents_trail_never_leaks_another_documents(self):
        other = PurchaseOrder.objects.create(supplier=self.supplier)
        DocumentEvent.objects.create(
            document_type="purchase_order",
            object_id=other.pk,
            document_number=other.order_number,
            action=DocumentEvent.Action.SUBMITTED,
        )
        response = self.client.get(
            self._url(document_type="purchase_order", object_id=self.order.pk)
        )
        rows = response.data["results"] if "results" in response.data else response.data
        self.assertTrue(all(row["object_id"] == self.order.pk for row in rows))


class LifecycleOnTheWireTests(TestCase):
    """The retraction has to reach the screen that shows the document, or the
    person looking at a cancelled order has no way to know why."""

    def setUp(self):
        ensure_role_groups()
        self.user = get_user_model().objects.create_user(
            username="wire-manager", password="p"
        )
        self.user.groups.add(Group.objects.get(name=MANAGER_GROUP))
        self.client = APIClient()
        self.client.force_authenticate(user=self.user)
        product = create_product_with_default_variant(
            name="Wire widget", sku="WW1", barcode="", unit_price=Decimal("4.00")
        )
        self.supplier = Supplier.objects.create(name="Wire supplier")
        self.order = PurchaseOrder.objects.create(supplier=self.supplier)
        self.order.lines.create(
            variant=product.default_variant, quantity=1, unit_cost=Decimal("2.00")
        )
        self.order.recalculate()
        self.order.save(update_fields=["subtotal", "total", "updated_at"])
        submit_purchase_order(self.order, request=None)

    def test_a_purchase_order_carries_its_lifecycle(self):
        cancel_purchase_order(self.order, request=None, reason="سعر خاطئ")
        response = self.client.get(
            reverse("purchaseorder-detail", args=[self.order.pk])
        )
        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(response.data["doc_status"], "cancelled")
        self.assertEqual(response.data["cancel_reason"], "سعر خاطئ")
        self.assertIsNotNone(response.data["cancelled_at"])
        self.assertEqual(response.data["amendment_index"], 0)

    def test_and_the_lifecycle_is_not_writable_from_outside(self):
        response = self.client.patch(
            reverse("purchaseorder-detail", args=[self.order.pk]),
            {"doc_status": "cancelled"},
            format="json",
        )
        self.order.refresh_from_db()
        self.assertNotEqual(self.order.doc_status, "cancelled")
        self.assertIn(
            response.status_code,
            (status.HTTP_200_OK, status.HTTP_400_BAD_REQUEST),
        )
