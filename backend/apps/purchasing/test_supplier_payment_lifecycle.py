"""A payment to a supplier as a document.

Until now this was the most one-way record in the system: the endpoint offered
create and read, nothing else. A mistyped payment was permanent — and because a
payment blocks its purchase order from being cancelled, one typo could lock an
order shut for good.
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
from apps.sales.models import RegisterCashMovement, RegisterSession

from .models import (
    PurchaseOrder,
    PurchaseOrderAdjustment,
    Supplier,
    SupplierCredit,
    SupplierPayment,
)
from .services import (
    cancel_supplier_payment,
    create_supplier_payment,
    receive_purchase_order,
    submit_purchase_order,
    supplier_available_credit,
)


class SupplierPaymentLifecycleTests(TestCase):
    def setUp(self):
        ensure_role_groups()
        self.user = get_user_model().objects.create_user(
            username="buyer-manager", password="pass"
        )
        self.user.groups.add(Group.objects.get(name=MANAGER_GROUP))
        self.client = APIClient()
        self.client.force_authenticate(user=self.user)
        product = create_product_with_default_variant(
            name="Supplier widget", sku="SW1", barcode="", unit_price=Decimal("9.00")
        )
        self.variant = product.default_variant
        self.supplier = Supplier.objects.create(name="Lifecycle supplier")

    def _received_order(self, quantity=4, unit_cost="2.00"):
        order = PurchaseOrder.objects.create(supplier=self.supplier)
        order.lines.create(
            variant=self.variant, quantity=quantity, unit_cost=Decimal(unit_cost)
        )
        order.recalculate()
        order.save(update_fields=["subtotal", "total", "updated_at"])
        submit_purchase_order(order, request=None)
        receive_purchase_order(order, request=None)
        order.refresh_from_db()
        return order

    def _pay(self, order, amount="8.00", **kwargs):
        return create_supplier_payment(
            supplier=self.supplier,
            purchase_order=order,
            amount=Decimal(amount),
            method=kwargs.pop("method", SupplierPayment.Method.CASH),
            **kwargs,
        )

    # --- born, and frozen from birth ------------------------------------

    def test_a_supplier_payment_is_a_document_from_the_moment_it_exists(self):
        payment = self._pay(self._received_order())
        self.assertEqual(payment.doc_status, DocumentStatus.SUBMITTED)

    def test_the_amount_is_frozen(self):
        payment = self._pay(self._received_order())
        payment.amount = Decimal("1.00")
        with self.assertRaises(DocumentFrozen):
            payment.save(update_fields=["amount"])

    def test_the_banks_own_reference_can_still_arrive_later(self):
        payment = self._pay(self._received_order())
        payment.reference = "TRF-99"
        payment.save(update_fields=["reference", "updated_at"])
        payment.refresh_from_db()
        self.assertEqual(payment.reference, "TRF-99")

    # --- undoing one ----------------------------------------------------

    def test_cancelling_stops_it_counting_towards_what_was_paid(self):
        order = self._received_order()
        payment = self._pay(order, amount="8.00")
        order.refresh_from_db()
        self.assertEqual(order.paid_total, Decimal("8.00"))

        cancel_supplier_payment(payment, reason="دفعنا للمورد الخطأ")

        order.refresh_from_db()
        payment.refresh_from_db()
        self.assertEqual(payment.doc_status, DocumentStatus.CANCELLED)
        self.assertEqual(order.paid_total, Decimal("0.00"))
        self.assertEqual(order.balance_due, order.total)

    def test_a_cancelled_payment_stops_blocking_the_order_it_locked(self):
        """The consequence that matters: a typo used to lock a purchase order
        shut forever, because a payment against it can never be cancelled and a
        payment against it forbids cancelling the order."""
        from apps.documents.errors import DocumentBlocked

        from .services import cancel_purchase_order

        order = self._received_order()
        payment = self._pay(order)
        with self.assertRaises(DocumentBlocked):
            cancel_purchase_order(order, request=None, reason="خطأ")

        cancel_supplier_payment(payment, reason="خطأ في الدفع")
        order.refresh_from_db()
        cancel_purchase_order(order, request=None, reason="خطأ")

        order.refresh_from_db()
        self.assertEqual(order.doc_status, DocumentStatus.CANCELLED)

    def test_the_supplier_balance_forgets_a_cancelled_unallocated_payment(self):
        """A payment on account, not against any one order: the supplier-level
        balance has its own query, and it has to forget the payment too."""
        order = self._received_order()
        owed = self.supplier.payable_balance
        payment = create_supplier_payment(
            supplier=self.supplier,
            purchase_order=None,
            amount=Decimal("5.00"),
            method=SupplierPayment.Method.CASH,
        )
        self.supplier.refresh_from_db()
        self.assertEqual(self.supplier.payable_balance, owed - Decimal("5.00"))

        cancel_supplier_payment(payment, reason="خطأ")

        self.supplier.refresh_from_db()
        self.assertEqual(self.supplier.payable_balance, owed)
        self.assertEqual(order.supplier_id, self.supplier.pk)

    def test_credit_drawn_down_by_a_cancelled_payment_goes_back_on_the_note(self):
        order = self._received_order()
        adjustment = PurchaseOrderAdjustment.objects.create(
            purchase_order=order,
            adjustment_type=PurchaseOrderAdjustment.AdjustmentType.RETURN,
            amount=Decimal("6.00"),
        )
        SupplierCredit.objects.create(
            supplier=self.supplier,
            purchase_order=order,
            adjustment=adjustment,
            amount=Decimal("6.00"),
            remaining_amount=Decimal("6.00"),
        )
        self.assertEqual(supplier_available_credit(self.supplier), Decimal("6.00"))

        payment = self._pay(
            order, amount="6.00", method=SupplierPayment.Method.SUPPLIER_CREDIT
        )
        self.assertEqual(supplier_available_credit(self.supplier), Decimal("0.00"))

        cancel_supplier_payment(payment, reason="طُبِّق على الأمر الخطأ")

        self.assertEqual(supplier_available_credit(self.supplier), Decimal("6.00"))

    def test_cash_that_left_a_drawer_comes_back_into_the_open_one(self):
        order = self._received_order()
        session = RegisterSession.objects.create(
            owner=self.user,
            owner_key=f"user:{self.user.pk}",
            opening_cash=Decimal("0.00"),
        )
        movement = RegisterCashMovement.objects.create(
            register_session=session,
            movement_type=RegisterCashMovement.MovementType.PAY_OUT,
            amount=Decimal("8.00"),
            reason="شراء نقدي",
        )
        payment = self._pay(
            order, amount="8.00", register_session=session, cash_movement=movement
        )

        cancel_supplier_payment(payment, reason="خطأ", register_session=session)

        pay_ins = session.cash_movements.filter(
            movement_type=RegisterCashMovement.MovementType.PAY_IN
        )
        self.assertEqual(pay_ins.count(), 1)
        self.assertEqual(pay_ins.first().amount, Decimal("8.00"))

    def test_a_drawer_payment_needs_an_open_drawer_to_come_back_into(self):
        order = self._received_order()
        session = RegisterSession.objects.create(
            owner=self.user,
            owner_key=f"user:{self.user.pk}",
            opening_cash=Decimal("0.00"),
            status=RegisterSession.Status.CLOSED,
        )
        movement = RegisterCashMovement.objects.create(
            register_session=session,
            movement_type=RegisterCashMovement.MovementType.PAY_OUT,
            amount=Decimal("8.00"),
            reason="شراء نقدي",
        )
        payment = self._pay(
            order, amount="8.00", register_session=session, cash_movement=movement
        )

        class _Request:
            user = self.user

        with self.assertRaises(Exception) as caught:
            cancel_supplier_payment(payment, reason="خطأ", request=_Request())
        self.assertIn("register session", str(caught.exception))

    def test_the_cancellation_is_recorded(self):
        payment = self._pay(self._received_order())
        cancel_supplier_payment(payment, reason="خطأ إدخال")
        event = trail.history(payment).first()
        self.assertEqual(event.action, DocumentEvent.Action.CANCELLED)
        self.assertEqual(event.reason, "خطأ إدخال")

    # --- the endpoint ---------------------------------------------------

    def test_the_endpoint_cancels(self):
        payment = self._pay(self._received_order())
        response = self.client.post(
            reverse("supplierpayment-cancel", args=[payment.pk]),
            {"reason": "خطأ"},
            format="json",
        )
        self.assertEqual(response.status_code, status.HTTP_200_OK, response.data)
        payment.refresh_from_db()
        self.assertEqual(payment.doc_status, DocumentStatus.CANCELLED)

    def test_the_batched_balance_agrees_with_the_one_it_replaces(self):
        """``prime_supplier_balances`` exists to make the property cheap for a
        page of suppliers; the two must never disagree, cancellations included."""
        from .models import prime_supplier_balances

        order = self._received_order()
        payment = self._pay(order, amount="8.00")
        cancel_supplier_payment(payment, reason="خطأ")

        cold = Supplier.objects.get(pk=self.supplier.pk).payable_balance
        primed = prime_supplier_balances(
            [Supplier.objects.get(pk=self.supplier.pk)]
        )[0].payable_balance
        self.assertEqual(cold, primed)
        self.assertEqual(cold, order.total)
