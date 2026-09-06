"""A sale as a document.

The sales viewset has said for a long time that *"orders are append-only: they
may be created and then only adjusted through the audited void and return_items
actions … so a sale can never be silently edited or erased, including by a
manager"*, and enforced it at the HTTP layer only. These tests are that promise
made true of the model, plus the two things the lifecycle fixes on the way: a
void that never checked the period lock, and a status field that meant two
different things depending on the sale type.
"""

from datetime import timedelta
from decimal import Decimal

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group
from django.test import TestCase
from django.utils import timezone

from apps.catalog.testing import create_product_with_default_variant
from apps.core.models import ShopSettings
from apps.core.period_lock import PeriodLocked
from apps.core.roles import CASHIER_GROUP, MANAGER_GROUP, ensure_role_groups
from apps.customers.models import Customer
from apps.documents import trail
from apps.documents.errors import DocumentFrozen
from apps.documents.models import DocumentEvent
from apps.documents.statuses import DocumentStatus
from apps.inventory.models import StockItem

from .models import Order, RegisterSession
from .services import (
    checkout_order,
    convert_quotation_to_sale,
    return_order_items,
    void_order,
)


class SaleLifecycleTests(TestCase):
    def setUp(self):
        ensure_role_groups()
        self.user = get_user_model().objects.create_user(username="till", password="p")
        self.user.groups.add(Group.objects.get(name=MANAGER_GROUP))
        product = create_product_with_default_variant(
            name="Lifecycle widget", sku="LW1", barcode="", unit_price=Decimal("5.00")
        )
        self.variant = product.default_variant
        StockItem.objects.create(variant=self.variant, quantity_on_hand=Decimal("100"))
        self.session = RegisterSession.objects.create(
            owner=self.user,
            owner_key=f"user:{self.user.pk}",
            opening_cash=Decimal("10.00"),
        )
        self.customer = Customer.objects.create(full_name="سالم")

    def _sale(self, quantity=2, sale_type=Order.SaleType.STANDARD, paid=True, **kwargs):
        lines = [{"variant": self.variant, "quantity": Decimal(quantity)}]
        amount = Decimal("5.00") * Decimal(quantity)
        payments = [{"method": "cash", "amount": amount}] if paid else []
        return checkout_order(
            register_session=self.session,
            lines_data=lines,
            payments_data=payments,
            sale_type=sale_type,
            **kwargs,
        )

    # --- the two meanings come apart ------------------------------------

    def test_a_paid_sale_is_a_submitted_document(self):
        order = self._sale()
        self.assertEqual(order.doc_status, DocumentStatus.SUBMITTED)
        self.assertEqual(order.status, Order.Status.PAID)
        self.assertIsNotNone(order.submitted_at)

    def test_an_unpaid_credit_invoice_is_issued_not_a_draft(self):
        """The ambiguity that made ``recognized_sale_q`` necessary: ``open``
        means "still being rung up" for a standard sale and "issued, delivered,
        unpaid" for a credit one. Only the first is a draft."""
        order = self._sale(
            sale_type=Order.SaleType.CREDIT, paid=False, customer=self.customer
        )
        self.assertEqual(order.doc_status, DocumentStatus.SUBMITTED)
        self.assertEqual(order.status, Order.Status.OPEN)

    def test_a_quotation_is_issued_too(self):
        order = self._sale(sale_type=Order.SaleType.QUOTATION, paid=False)
        self.assertEqual(order.doc_status, DocumentStatus.SUBMITTED)
        self.assertEqual(order.status, Order.Status.OPEN)

    # --- the freeze -----------------------------------------------------

    def test_a_sale_cannot_be_silently_rewritten(self):
        order = self._sale()
        order.total = Decimal("1.00")
        with self.assertRaises(DocumentFrozen):
            order.save(update_fields=["total"])

    def test_a_sale_cannot_be_rewritten_through_a_queryset_either(self):
        self._sale()
        with self.assertRaises(DocumentFrozen):
            Order.objects.all().update(total=Decimal("0.00"))

    def test_who_the_sale_was_to_can_still_be_fixed(self):
        """The returns desk's one legitimate post-submit edit, and the reason
        ERPNext has ``allow_on_submit`` at all."""
        order = self._sale(
            sale_type=Order.SaleType.CREDIT, paid=False, customer=None
        )
        order.customer = self.customer
        order.save(update_fields=["customer", "updated_at"])
        order.refresh_from_db()
        self.assertEqual(order.customer_id, self.customer.pk)

    # --- voiding --------------------------------------------------------

    def test_voiding_cancels_the_document_and_refunds(self):
        order = self._sale(quantity=2)
        adjustment = void_order(order=order, reason="ضغط خطأ", register_session=self.session)

        order.refresh_from_db()
        self.assertEqual(order.doc_status, DocumentStatus.CANCELLED)
        self.assertEqual(order.status, Order.Status.VOID)
        self.assertEqual(adjustment.amount, Decimal("10.00"))
        self.assertEqual(
            StockItem.objects.get(variant=self.variant).quantity_on_hand,
            Decimal("100"),
        )

    def test_a_refund_leaves_the_drawer_that_is_open_now(self):
        """A sale voided in a later shift is that shift's cash out, not a
        retroactive hole in the shift that took the money."""
        order = self._sale(quantity=1)
        later = RegisterSession.objects.create(
            owner=self.user,
            owner_key=f"user:{self.user.pk}:2",
            opening_cash=Decimal("0.00"),
        )
        adjustment = void_order(order=order, reason="اليوم التالي", register_session=later)
        self.assertEqual(adjustment.register_session_id, later.pk)

    def test_voiding_into_a_closed_period_needs_an_override(self):
        """``void_order`` has never checked the period lock, and closing that
        is the scenario ``apps.core.period_lock`` opens its own docstring with:
        a cashier voiding a September sale on 4 October."""
        order = self._sale()
        Order.objects.filter(pk=order.pk).update(
            created_at=timezone.now() - timedelta(days=60)
        )
        order.refresh_from_db()
        settings_row = ShopSettings.load()
        settings_row.books_locked_through = timezone.localdate() - timedelta(days=30)
        settings_row.save(update_fields=["books_locked_through"])

        # A returns-desk operator, not a manager: managers hold
        # ``reports.override_period_lock`` and would (audibly, audited) push
        # the void through, which is the point of the override existing.
        cashier = get_user_model().objects.create_user(username="c", password="p")
        cashier.groups.add(Group.objects.get(name=CASHIER_GROUP))
        cashier = get_user_model().objects.get(pk=cashier.pk)

        class _Request:
            user = cashier

        with self.assertRaises(PeriodLocked):
            void_order(
                order=order,
                reason="متأخر",
                request=_Request(),
                register_session=self.session,
                allow_window_override=True,
            )

        order.refresh_from_db()
        self.assertEqual(order.doc_status, DocumentStatus.SUBMITTED)

    # --- returns derive the progress ------------------------------------

    def test_a_part_returned_sale_is_still_a_paid_sale(self):
        order = self._sale(quantity=4)
        return_order_items(
            order=order,
            lines=[(order.lines.first(), Decimal("1"))],
            reason="عيب",
            register_session=self.session,
        )
        order.refresh_from_db()
        self.assertEqual(order.doc_status, DocumentStatus.SUBMITTED)
        self.assertEqual(order.status, Order.Status.PAID)

    def test_a_fully_returned_sale_is_spent(self):
        order = self._sale(quantity=2)
        return_order_items(
            order=order,
            lines=[(order.lines.first(), Decimal("2"))],
            reason="مرتجع كامل",
            register_session=self.session,
        )
        order.refresh_from_db()
        self.assertEqual(order.status, Order.Status.VOID)
        # It was a real sale that was given back — not a document that never
        # happened, which is what cancelling would have said.
        self.assertEqual(order.doc_status, DocumentStatus.SUBMITTED)

    # --- supersession ----------------------------------------------------

    def test_an_accepted_quotation_is_superseded_by_the_sale(self):
        quotation = self._sale(sale_type=Order.SaleType.QUOTATION, paid=False)
        sale = convert_quotation_to_sale(
            quotation,
            sale_type=Order.SaleType.STANDARD,
            register_session=self.session,
            payments_data=[{"method": "cash", "amount": Decimal("10.00")}],
        )

        quotation.refresh_from_db()
        self.assertEqual(quotation.doc_status, DocumentStatus.CANCELLED)
        self.assertEqual(quotation.superseded_by_id, sale.pk)
        # The older name for the same forward pointer, kept in step.
        self.assertEqual(quotation.converted_to_id, sale.pk)
        self.assertFalse(quotation.is_current)
        self.assertEqual(
            trail.history(quotation).first().action, DocumentEvent.Action.SUPERSEDED
        )

    # --- the trail -------------------------------------------------------

    def test_every_sale_leaves_a_trail(self):
        order = self._sale()
        void_order(order=order, reason="اختبار", register_session=self.session)
        actions = list(trail.history(order).values_list("action", flat=True))
        self.assertEqual(
            actions,
            [DocumentEvent.Action.CANCELLED, DocumentEvent.Action.SUBMITTED],
        )
        self.assertEqual(trail.history(order).first().reason, "اختبار")
