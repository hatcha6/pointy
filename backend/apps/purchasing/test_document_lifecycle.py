"""A purchase order as a document.

What these cover is the seam: the lifecycle now decides what may happen to an
order, and the progress field that used to decide it is derived from what
actually arrived. The behaviour that changes is cancellation — a received order
can be retracted where it could not before — so most of this file is about the
edges of that.
"""

from decimal import Decimal

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group, Permission
from django.test import TestCase
from django.urls import reverse
from rest_framework import status
from rest_framework.test import APIClient

from apps.catalog.tests import create_product_with_default_variant
from apps.core.roles import MANAGER_GROUP, ensure_role_groups
from apps.documents import trail
from apps.documents.errors import DocumentBlocked, DocumentFrozen
from apps.documents.models import DocumentEvent
from apps.documents.statuses import DocumentStatus
from apps.inventory.models import StockItem
from apps.purchasing.models import PurchaseOrder, SupplierPayment, Supplier
from apps.purchasing.services import (
    cancel_purchase_order,
    receive_purchase_order,
    submit_purchase_order,
)


class PurchaseOrderLifecycleTests(TestCase):
    def setUp(self):
        ensure_role_groups()
        self.client = APIClient()
        self.user = get_user_model().objects.create_user(
            username="lifecycle-manager", password="pass"
        )
        self.user.groups.add(Group.objects.get(name=MANAGER_GROUP))
        self.client.force_authenticate(user=self.user)
        self.product = create_product_with_default_variant(
            sku="LIFE-1", barcode="", name="Lifecycle beans",
            unit_price=Decimal("10.00"),
        )
        self.variant = self.product.default_variant
        self.supplier = Supplier.objects.create(name="Lifecycle supplier")

    def _draft(self, quantity=4, unit_cost="2.00"):
        order = PurchaseOrder.objects.create(supplier=self.supplier)
        order.lines.create(
            variant=self.variant,
            quantity=quantity,
            unit_cost=Decimal(unit_cost),
        )
        order.recalculate()
        order.save(update_fields=["subtotal", "total", "updated_at"])
        return order

    def _on_hand(self):
        return StockItem.objects.get(variant=self.variant).quantity_on_hand

    def _expected(self):
        return StockItem.objects.get(variant=self.variant).quantity_expected

    # --- the two axes ---------------------------------------------------

    def test_submitting_moves_the_lifecycle_and_the_progress_follows(self):
        order = submit_purchase_order(self._draft(), request=None)
        self.assertEqual(order.doc_status, DocumentStatus.SUBMITTED)
        self.assertEqual(order.status, PurchaseOrder.Status.SUBMITTED)
        self.assertIsNotNone(order.submitted_at)

    def test_progress_is_derived_from_what_arrived_not_assigned(self):
        order = submit_purchase_order(self._draft(quantity=4), request=None)
        receive_purchase_order(
            order,
            request=None,
            lines_data=[
                {
                    "line": order.lines.first(),
                    "accepted_quantity": Decimal("1"),
                    "damaged_quantity": Decimal("0"),
                    "cancelled_quantity": Decimal("0"),
                    "allowed_over_receipt_quantity": 0,
                    "expiry_date": None,
                    "notes": "",
                }
            ],
        )
        order.refresh_from_db()
        self.assertEqual(order.doc_status, DocumentStatus.SUBMITTED)
        self.assertEqual(order.status, PurchaseOrder.Status.PARTIALLY_RECEIVED)

    def test_an_order_created_already_received_gets_the_lifecycle_that_implies(self):
        """The migration-window bridge: a hundred callers still say 'received'
        rather than 'submitted and delivered'."""
        order = PurchaseOrder.objects.create(
            supplier=self.supplier, status=PurchaseOrder.Status.RECEIVED
        )
        self.assertEqual(order.doc_status, DocumentStatus.SUBMITTED)

    # --- the freeze -----------------------------------------------------

    def test_a_submitted_order_refuses_a_rewritten_total(self):
        order = submit_purchase_order(self._draft(), request=None)
        order.total = Decimal("999.00")
        with self.assertRaises(DocumentFrozen):
            order.save(update_fields=["total"])

    def test_a_submitted_orders_progress_columns_are_still_writable(self):
        order = submit_purchase_order(self._draft(), request=None)
        order.cancelled_total = Decimal("1.00")
        order.save(update_fields=["cancelled_total", "updated_at"])
        order.refresh_from_db()
        self.assertEqual(order.cancelled_total, Decimal("1.00"))

    # --- cancellation ---------------------------------------------------

    def test_cancelling_a_submitted_order_gives_back_the_expected_stock(self):
        order = submit_purchase_order(self._draft(quantity=4), request=None)
        self.assertEqual(self._expected(), Decimal("4"))

        cancel_purchase_order(order, request=None, reason="المورد اعتذر")

        order.refresh_from_db()
        self.assertEqual(order.doc_status, DocumentStatus.CANCELLED)
        self.assertEqual(order.status, PurchaseOrder.Status.CANCELLED)
        self.assertEqual(self._expected(), Decimal("0"))

    def test_a_received_order_can_now_be_cancelled_and_the_goods_come_back(self):
        """The capability the old hand-rolled cancel could not offer: a
        delivery recorded against the wrong order used to be unfixable except
        by editing it."""
        order = submit_purchase_order(self._draft(quantity=4), request=None)
        receive_purchase_order(order, request=None)
        order.refresh_from_db()
        self.assertEqual(order.status, PurchaseOrder.Status.RECEIVED)
        self.assertEqual(self._on_hand(), Decimal("4"))

        cancel_purchase_order(order, request=None, reason="سُجّل على أمر خاطئ")

        order.refresh_from_db()
        self.assertEqual(order.doc_status, DocumentStatus.CANCELLED)
        self.assertEqual(self._on_hand(), Decimal("0"))

    def test_money_that_has_settled_blocks_the_cancellation_and_says_what(self):
        order = submit_purchase_order(self._draft(), request=None)
        receive_purchase_order(order, request=None)
        order.refresh_from_db()
        SupplierPayment.objects.create(
            supplier=self.supplier,
            purchase_order=order,
            amount=Decimal("1.00"),
            method=SupplierPayment.Method.CASH,
        )

        with self.assertRaises(DocumentBlocked) as caught:
            cancel_purchase_order(order, request=None, reason="متأخر")

        labels = [row["label"] for row in caught.exception.blockers]
        self.assertIn("دفعات للمورد", labels)
        order.refresh_from_db()
        self.assertEqual(order.doc_status, DocumentStatus.SUBMITTED)
        self.assertEqual(self._on_hand(), Decimal("4"))

    def test_cancelling_a_delivery_needs_the_receiving_permission(self):
        order = submit_purchase_order(self._draft(), request=None)
        receive_purchase_order(order, request=None)
        order.refresh_from_db()

        canceller = get_user_model().objects.create_user(
            username="canceller", password="pass"
        )
        canceller.user_permissions.add(
            Permission.objects.get(codename="cancel_purchaseorder")
        )
        canceller = get_user_model().objects.get(pk=canceller.pk)
        client = APIClient()
        client.force_authenticate(user=canceller)

        response = client.post(
            reverse("purchaseorder-cancel", args=[order.pk]), format="json"
        )

        self.assertEqual(response.status_code, status.HTTP_403_FORBIDDEN)
        order.refresh_from_db()
        self.assertEqual(order.doc_status, DocumentStatus.SUBMITTED)

    def test_goods_that_have_already_been_sold_cannot_be_un_received(self):
        order = submit_purchase_order(self._draft(quantity=4), request=None)
        receive_purchase_order(order, request=None)
        order.refresh_from_db()
        stock_item = StockItem.objects.get(variant=self.variant)
        stock_item.quantity_on_hand = Decimal("1")
        stock_item.save(update_fields=["quantity_on_hand"])

        with self.assertRaises(Exception):
            cancel_purchase_order(order, request=None, reason="بعد البيع")

        order.refresh_from_db()
        self.assertEqual(order.doc_status, DocumentStatus.SUBMITTED)

    # --- the trail ------------------------------------------------------

    def test_the_lifecycle_leaves_a_trail_that_outlives_the_hand_rolled_one(self):
        order = submit_purchase_order(self._draft(), request=None)
        cancel_purchase_order(order, request=None, reason="غير مطلوب")

        actions = list(trail.history(order).values_list("action", flat=True))
        self.assertEqual(
            actions,
            [DocumentEvent.Action.CANCELLED, DocumentEvent.Action.SUBMITTED],
        )
        self.assertEqual(trail.history(order).first().reason, "غير مطلوب")

    def test_correcting_a_submitted_order_records_what_changed(self):
        order = submit_purchase_order(self._draft(quantity=4, unit_cost="2.00"), request=None)
        response = self.client.patch(
            reverse("purchaseorder-detail", args=[order.pk]),
            {
                "supplier": self.supplier.pk,
                "lines": [
                    {
                        "variant": self.variant.pk,
                        "quantity": 4,
                        "unit_cost": "3.00",
                    }
                ],
            },
            format="json",
        )
        self.assertEqual(response.status_code, status.HTTP_200_OK, response.data)

        event = (
            trail.history(order)
            .filter(action=DocumentEvent.Action.CORRECTED)
            .first()
        )
        self.assertIsNotNone(event)
        self.assertEqual(event.details["changes"]["total"], {"from": "8.00", "to": "12.00"})


class PurchaseReceiptLifecycleTests(PurchaseOrderLifecycleTests):
    """A delivery is its own document, cancelled with the order it belongs to."""

    def test_a_delivery_is_a_document_from_the_moment_it_exists(self):
        order = submit_purchase_order(self._draft(), request=None)
        receive_purchase_order(order, request=None)
        receipt = order.receipts.first()
        self.assertEqual(receipt.doc_status, DocumentStatus.SUBMITTED)

    def test_a_recorded_delivery_cannot_be_quietly_re_pointed(self):
        order = submit_purchase_order(self._draft(), request=None)
        receive_purchase_order(order, request=None)
        other = PurchaseOrder.objects.create(supplier=self.supplier)
        receipt = order.receipts.first()
        receipt.purchase_order = other
        with self.assertRaises(DocumentFrozen):
            receipt.save(update_fields=["purchase_order"])

    def test_cancelling_the_order_cancels_the_delivery_with_it(self):
        order = submit_purchase_order(self._draft(quantity=4), request=None)
        receive_purchase_order(order, request=None)
        order.refresh_from_db()
        receipt = order.receipts.first()

        cancel_purchase_order(order, request=None, reason="أمر خاطئ")

        receipt.refresh_from_db()
        self.assertEqual(receipt.doc_status, DocumentStatus.CANCELLED)
        self.assertEqual(
            trail.history(receipt).first().action, DocumentEvent.Action.CANCELLED
        )

    def test_neither_the_goods_nor_the_expectation_are_left_behind(self):
        """The half that is easy to miss: arriving stock stops being *expected*
        and starts being *on hand*, so undoing it has to put the expectation
        back — and then the order's own reversal takes it away again. Both
        counters have to land on zero."""
        order = submit_purchase_order(self._draft(quantity=4), request=None)
        self.assertEqual(self._expected(), Decimal("4"))
        receive_purchase_order(order, request=None)
        self.assertEqual(self._expected(), Decimal("0"))
        self.assertEqual(self._on_hand(), Decimal("4"))

        cancel_purchase_order(order, request=None, reason="أمر خاطئ")

        self.assertEqual(self._on_hand(), Decimal("0"))
        self.assertEqual(self._expected(), Decimal("0"))

    def test_a_part_delivered_order_lands_on_zero_too(self):
        order = submit_purchase_order(self._draft(quantity=4), request=None)
        receive_purchase_order(
            order,
            request=None,
            lines_data=[
                {
                    "line": order.lines.first(),
                    "accepted_quantity": Decimal("1"),
                    "damaged_quantity": Decimal("0"),
                    "cancelled_quantity": Decimal("0"),
                    "allowed_over_receipt_quantity": 0,
                    "expiry_date": None,
                    "notes": "",
                }
            ],
        )
        order.refresh_from_db()
        self.assertEqual(self._on_hand(), Decimal("1"))
        self.assertEqual(self._expected(), Decimal("3"))

        cancel_purchase_order(order, request=None, reason="ألغى المورد الباقي")

        self.assertEqual(self._on_hand(), Decimal("0"))
        self.assertEqual(self._expected(), Decimal("0"))
