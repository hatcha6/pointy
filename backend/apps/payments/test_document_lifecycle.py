"""A payment as a document.

Two holes closed here. A ``PATCH`` could rewrite the amount of a payment that
had already been counted into a shift, and a ``DELETE`` could make a settled
invoice unpaid again leaving nothing behind that said it had ever been paid.
"""

from decimal import Decimal

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group
from django.test import TestCase
from django.urls import reverse
from rest_framework import status
from rest_framework.test import APIClient

from apps.catalog.testing import create_product_with_default_variant
from apps.core.roles import MANAGER_GROUP, ensure_role_groups
from apps.documents import trail
from apps.documents.errors import DocumentFrozen
from apps.documents.models import DocumentEvent
from apps.documents.statuses import DocumentStatus
from apps.inventory.models import StockItem
from apps.sales.models import Order, RegisterSession
from apps.sales.services import checkout_order, void_order

from .models import Payment
from .services import cancel_payment


class PaymentLifecycleTests(TestCase):
    def setUp(self):
        ensure_role_groups()
        self.user = get_user_model().objects.create_user(
            username="till-manager", password="pass"
        )
        self.user.groups.add(Group.objects.get(name=MANAGER_GROUP))
        self.client = APIClient()
        self.client.force_authenticate(user=self.user)
        product = create_product_with_default_variant(
            name="Payment widget", sku="PW1", barcode="", unit_price=Decimal("5.00")
        )
        self.variant = product.default_variant
        StockItem.objects.create(variant=self.variant, quantity_on_hand=Decimal("50"))
        self.session = RegisterSession.objects.create(
            owner=self.user,
            owner_key=f"user:{self.user.pk}",
            opening_cash=Decimal("0.00"),
        )

    def _sale(self, quantity=2, method="cash"):
        return checkout_order(
            register_session=self.session,
            lines_data=[{"variant": self.variant, "quantity": Decimal(quantity)}],
            payments_data=[
                {"method": method, "amount": Decimal("5.00") * Decimal(quantity)}
            ],
        )

    def _payment(self, order):
        return order.payments.order_by("id").first()

    # --- born, and frozen from birth ------------------------------------

    def test_a_payment_is_a_document_from_the_moment_it_exists(self):
        payment = self._payment(self._sale())
        self.assertEqual(payment.doc_status, DocumentStatus.SUBMITTED)

    def test_the_amount_a_customer_paid_is_not_revisable(self):
        payment = self._payment(self._sale())
        payment.amount = Decimal("1.00")
        with self.assertRaises(DocumentFrozen):
            payment.save(update_fields=["amount"])

    def test_nor_through_a_queryset(self):
        self._sale()
        with self.assertRaises(DocumentFrozen):
            Payment.objects.all().update(amount=Decimal("0.00"))

    def test_the_receipt_a_terminal_produces_afterwards_still_attaches(self):
        """The card-receipt flow validates evidence after the payment exists.
        It moves no money, so it stays allowed — ERPNext's ``allow_on_submit``,
        earned rather than assumed."""
        payment = self._payment(self._sale(method="card"))
        payment.card_receipt_data = {"masked_pan": "1234"}
        payment.external_reference = "MOAMALAT-1"
        payment.save(update_fields=["card_receipt_data", "external_reference"])
        payment.refresh_from_db()
        self.assertEqual(payment.card_receipt_data, {"masked_pan": "1234"})

    # --- undoing one ----------------------------------------------------

    def test_cancelling_gives_the_money_back_as_an_opposing_payment(self):
        order = self._sale(quantity=2)
        payment = self._payment(order)

        cancel_payment(payment, reason="حُصِّلت مرتين", register_session=self.session)

        payment.refresh_from_db()
        order.refresh_from_db()
        self.assertEqual(payment.doc_status, DocumentStatus.CANCELLED)
        self.assertEqual(order.payments.count(), 2)
        self.assertEqual(order.amount_paid, Decimal("0.00"))
        # The invoice is owed again, which is the honest consequence.
        self.assertEqual(order.status, Order.Status.OPEN)

    def test_the_refund_leaves_the_drawer_that_is_open_now(self):
        order = self._sale(quantity=1)
        payment = self._payment(order)
        later = RegisterSession.objects.create(
            owner=self.user,
            owner_key=f"user:{self.user.pk}:2",
            opening_cash=Decimal("0.00"),
        )

        cancel_payment(payment, reason="اليوم التالي", register_session=later)

        counter = order.payments.order_by("-id").first()
        self.assertEqual(counter.amount, Decimal("-5.00"))
        self.assertEqual(counter.register_session_id, later.pk)

    def test_cash_needs_an_open_drawer_to_go_back_into(self):
        order = self._sale(quantity=1)
        payment = self._payment(order)
        self.session.status = RegisterSession.Status.CLOSED
        self.session.save(update_fields=["status"])

        class _Request:
            user = self.user

        with self.assertRaises(Exception) as caught:
            cancel_payment(payment, reason="لا يوجد درج", request=_Request())
        self.assertIn("drawer", str(caught.exception))

    def test_a_refund_row_is_not_cancelled_it_is_charged_again(self):
        order = self._sale(quantity=1)
        void_order(order=order, reason="إلغاء", register_session=self.session)
        refund = order.payments.order_by("-id").first()
        self.assertLess(refund.amount, Decimal("0.00"))

        with self.assertRaises(Exception):
            cancel_payment(refund, reason="لا", register_session=self.session)

    def test_a_voided_invoices_payments_were_already_given_back(self):
        order = self._sale(quantity=1)
        payment = self._payment(order)
        void_order(order=order, reason="إلغاء", register_session=self.session)

        with self.assertRaises(Exception):
            cancel_payment(payment, reason="مرة أخرى", register_session=self.session)

    def test_the_cancellation_is_recorded(self):
        order = self._sale(quantity=1)
        payment = self._payment(order)
        cancel_payment(payment, reason="خطأ إدخال", register_session=self.session)
        event = trail.history(payment).first()
        self.assertEqual(event.action, DocumentEvent.Action.CANCELLED)
        self.assertEqual(event.reason, "خطأ إدخال")

    # --- the endpoint ---------------------------------------------------

    def test_the_delete_verb_is_gone(self):
        payment = self._payment(self._sale())
        response = self.client.delete(reverse("payment-detail", args=[payment.pk]))
        self.assertIn(
            response.status_code,
            (status.HTTP_403_FORBIDDEN, status.HTTP_405_METHOD_NOT_ALLOWED),
        )
        self.assertTrue(Payment.objects.filter(pk=payment.pk).exists())

    def test_the_cancel_action_replaces_it(self):
        order = self._sale(quantity=1)
        payment = self._payment(order)
        response = self.client.post(
            reverse("payment-cancel", args=[payment.pk]),
            {"reason": "خطأ"},
            format="json",
        )
        self.assertEqual(response.status_code, status.HTTP_200_OK, response.data)
        payment.refresh_from_db()
        self.assertEqual(payment.doc_status, DocumentStatus.CANCELLED)
