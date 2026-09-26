"""A payment given back, or taken again another way.

A cash sale is settled at the counter. Cancelling its payment used to leave it
``open``, which is in none of the recognized-sale definitions: the sale left
the Z-report, the dashboard, every report and the customer's history while its
goods stayed gone, and neither a void nor a return would take it any more. A
cancellation that would leave one unpaid is refused now. The goods go back by a
void or a return, and a payment taken through the wrong tender is replaced.

Separately, and for every kind of sale: a payment cannot be given back twice.
A return already refunds through the tenders the sale was paid with, and
cancelling the payment afterwards used to hand the same money over again.
"""

from decimal import Decimal
from unittest import mock

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group, Permission
from django.test import TestCase
from django.urls import reverse
from rest_framework import serializers, status
from rest_framework.test import APIClient

from apps.catalog.testing import create_product_with_default_variant
from apps.core.roles import MANAGER_GROUP, ensure_role_groups
from apps.customers.models import Customer
from apps.documents import trail
from apps.documents.models import DocumentEvent
from apps.documents.statuses import DocumentStatus
from apps.inventory.models import StockItem
from apps.sales.models import Order, RegisterSession
from apps.sales.services import checkout_order, return_order_items

from .models import Payment
from .services import cancel_payment, replace_payment


class _PaymentCase(TestCase):
    def setUp(self):
        ensure_role_groups()
        self.user = get_user_model().objects.create_user(
            username="till-manager", password="pass"
        )
        self.user.groups.add(Group.objects.get(name=MANAGER_GROUP))
        self.client = APIClient()
        self.client.force_authenticate(user=self.user)
        product = create_product_with_default_variant(
            name="Counter widget", sku="CW1", barcode="", unit_price=Decimal("5.00")
        )
        self.variant = product.default_variant
        StockItem.objects.create(variant=self.variant, quantity_on_hand=Decimal("50"))
        self.session = RegisterSession.objects.create(
            owner=self.user,
            owner_key=f"user:{self.user.pk}",
            opening_cash=Decimal("0.00"),
        )
        self.customer = Customer.objects.create(full_name="زبون الآجل")

    def _sale(self, quantity=2, tenders=None, sale_type=Order.SaleType.STANDARD):
        if tenders is None:
            tenders = [("cash", Decimal("5.00") * Decimal(quantity))]
        return checkout_order(
            register_session=self.session,
            lines_data=[{"variant": self.variant, "quantity": Decimal(quantity)}],
            payments_data=[
                {"method": method, "amount": Decimal(amount)} for method, amount in tenders
            ],
            sale_type=sale_type,
            customer=self.customer if sale_type == Order.SaleType.CREDIT else None,
        )

    def _return(self, order, quantity):
        return_order_items(
            order=order,
            lines=[(order.lines.get(), Decimal(quantity))],
            reason="مرتجع",
            register_session=self.session,
        )

    def _refused(self, call):
        """The refusal's code, having checked that it was refused."""
        with self.assertRaises(serializers.ValidationError) as caught:
            call()
        return caught.exception.detail.get("code")

    def _cancel(self, payment):
        return cancel_payment(payment, reason="خطأ", register_session=self.session)

    def _replace(self, payment, *tenders, **kwargs):
        kwargs.setdefault("register_session", self.session)
        return replace_payment(
            payment,
            tenders=[
                {"method": method, "amount": Decimal(amount)} for method, amount in tenders
            ],
            reason="دُفعت بطريقة أخرى",
            **kwargs,
        )


class CashSaleIsSettledAtTheCounterTests(_PaymentCase):
    def test_its_payment_is_not_cancelled_out_from_under_it(self):
        order = self._sale()
        payment = order.payments.get()

        code = self._refused(lambda: self._cancel(payment))

        self.assertEqual(code, "cash_sale_payment_not_cancellable")
        payment.refresh_from_db()
        order.refresh_from_db()
        self.assertEqual(payment.doc_status, DocumentStatus.SUBMITTED)
        self.assertEqual(order.payments.count(), 1)
        self.assertEqual(order.status, Order.Status.PAID)
        self.assertTrue(Order.objects.committed_sales().filter(pk=order.pk).exists())

    def test_nor_one_tender_of_a_split_payment(self):
        order = self._sale(tenders=[("cash", "6.00"), ("card", "4.00")])

        code = self._refused(lambda: self._cancel(order.payments.get(method="card")))

        self.assertEqual(code, "cash_sale_payment_not_cancellable")

    def test_the_endpoint_says_why(self):
        payment = self._sale().payments.get()

        response = self.client.post(
            reverse("payment-cancel", args=[payment.pk]), {"reason": "خطأ"}, format="json"
        )

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertEqual(response.data["code"], "cash_sale_payment_not_cancellable")

    def test_a_payment_it_did_not_need_can_still_be_given_back(self):
        """Only leaving the sale unpaid is refused. A row taken on top of a
        settled sale (nothing at the till can take one any more, but data from
        before that guard can hold one) goes back without the sale moving."""
        order = self._sale()
        extra = Payment.objects.create(
            order=order,
            method=Payment.Method.CASH,
            amount=Decimal("5.00"),
            register_session=self.session,
        )

        self._cancel(extra)

        extra.refresh_from_db()
        order.refresh_from_db()
        self.assertEqual(extra.doc_status, DocumentStatus.CANCELLED)
        self.assertEqual(order.status, Order.Status.PAID)
        self.assertEqual(order.amount_paid, Decimal("10.00"))

    def test_a_credit_invoice_is_owed_again_as_it_always_was(self):
        order = self._sale(tenders=[("cash", "4.00")], sale_type=Order.SaleType.CREDIT)

        self._cancel(order.payments.get())

        order.refresh_from_db()
        self.assertEqual(order.status, Order.Status.OPEN)
        self.assertEqual(order.balance_due, Decimal("10.00"))
        self.assertTrue(Order.objects.open_credit().filter(pk=order.pk).exists())


class GivenBackOnlyOnceTests(_PaymentCase):
    def test_a_returned_sale_s_payment_is_not_given_back_again(self):
        order = self._sale(quantity=1)
        payment = order.payments.get()
        self._return(order, 1)

        code = self._refused(lambda: self._cancel(payment))

        self.assertEqual(code, "payment_already_given_back")
        # The payment and the return's refund. No third row paying it again.
        self.assertEqual(order.payments.count(), 2)

    def test_nor_a_credit_invoice_s_once_a_return_refunded_part_of_it(self):
        order = self._sale(quantity=2, sale_type=Order.SaleType.CREDIT)
        payment = order.payments.get()
        self._return(order, 1)

        code = self._refused(lambda: self._cancel(payment))

        self.assertEqual(code, "payment_already_given_back")
        order.refresh_from_db()
        self.assertEqual(order.status, Order.Status.PAID)


class ReplacePaymentTests(_PaymentCase):
    def test_cash_that_was_really_card_is_put_right_without_the_sale_ever_being_unpaid(self):
        order = self._sale()
        cash = order.payments.get()

        with mock.patch("apps.sales.services.mark_order_paid") as marked_paid:
            replacements = self._replace(cash, ("card", "10.00"))

        # It never became paid again, because it never stopped being paid: no
        # second receipt print, no second "paid" event.
        marked_paid.assert_not_called()
        order.refresh_from_db()
        cash.refresh_from_db()
        self.assertEqual(order.status, Order.Status.PAID)
        self.assertEqual(cash.doc_status, DocumentStatus.CANCELLED)
        self.assertEqual([payment.method for payment in replacements], ["card"])
        self.assertEqual(order.amount_paid, Decimal("10.00"))
        self.assertEqual(
            sorted(order.payments.values_list("method", "amount")),
            [
                ("card", Decimal("10.00")),
                ("cash", Decimal("-10.00")),
                ("cash", Decimal("10.00")),
            ],
        )
        self.assertTrue(Order.objects.committed_sales().filter(pk=order.pk).exists())
        # The drawer never held that cash, and now it does not expect it.
        session = RegisterSession.objects.get(pk=self.session.pk)
        self.assertEqual(session.cash_sales_total, Decimal("0.00"))
        self.assertEqual(session.expected_cash, Decimal("0.00"))

    def test_the_trail_says_why(self):
        cash = self._sale().payments.get()

        self._replace(cash, ("card", "10.00"))

        event = trail.history(cash).first()
        self.assertEqual(event.action, DocumentEvent.Action.CANCELLED)
        self.assertEqual(event.reason, "دُفعت بطريقة أخرى")

    def test_one_payment_can_become_several_tenders(self):
        order = self._sale()

        replacements = self._replace(
            order.payments.get(), ("card", "6.00"), ("transfer", "4.00")
        )

        order.refresh_from_db()
        self.assertEqual(
            sorted(payment.method for payment in replacements), ["card", "transfer"]
        )
        self.assertEqual(order.status, Order.Status.PAID)
        self.assertEqual(order.amount_paid, Decimal("10.00"))

    def test_a_credit_invoice_s_collection_can_be_replaced_too(self):
        order = self._sale(tenders=[("cash", "4.00")], sale_type=Order.SaleType.CREDIT)

        self._replace(order.payments.get(), ("transfer", "4.00"))

        order.refresh_from_db()
        self.assertEqual(order.status, Order.Status.OPEN)
        self.assertEqual(order.balance_due, Decimal("6.00"))

    def test_the_replacement_adds_up_to_the_payment(self):
        order = self._sale()
        cash = order.payments.get()

        self._refused(lambda: self._replace(cash, ("card", "8.00")))

        cash.refresh_from_db()
        self.assertEqual(cash.doc_status, DocumentStatus.SUBMITTED)
        self.assertEqual(order.payments.count(), 1)

    def test_it_is_taken_at_the_till(self):
        cash = self._sale().payments.get()

        self._refused(lambda: self._replace(cash, ("salary_deduction", "10.00")))

    def test_a_payment_a_return_already_gave_back_is_not_replaced(self):
        order = self._sale(quantity=1)
        cash = order.payments.get()
        self._return(order, 1)

        code = self._refused(lambda: self._replace(cash, ("card", "5.00")))

        self.assertEqual(code, "payment_already_given_back")

    def test_cash_taken_in_needs_an_open_drawer(self):
        card = self._sale(tenders=[("card", "10.00")]).payments.get()
        self.session.status = RegisterSession.Status.CLOSED
        self.session.save(update_fields=["status"])

        class _Request:
            user = self.user

        with self.assertRaises(serializers.ValidationError) as caught:
            self._replace(card, ("cash", "10.00"), register_session=None, request=_Request())
        self.assertIn("drawer", str(caught.exception))


class ReplaceEndpointTests(_PaymentCase):
    def _post(self, client, payment):
        return client.post(
            reverse("payment-replace", args=[payment.pk]),
            {"reason": "بطاقة", "payments": [{"method": "card", "amount": "10.00"}]},
            format="json",
        )

    def test_the_replace_action(self):
        cash = self._sale().payments.get()

        response = self._post(self.client, cash)

        self.assertEqual(response.status_code, status.HTTP_200_OK, response.data)
        self.assertEqual(response.data["replaced"]["id"], cash.pk)
        self.assertEqual(
            [row["method"] for row in response.data["payments"]], ["card"]
        )
        cash.refresh_from_db()
        self.assertEqual(cash.doc_status, DocumentStatus.CANCELLED)

    def test_it_needs_the_right_to_give_back_and_to_take(self):
        clerk = get_user_model().objects.create_user(username="clerk", password="pass")
        clerk.user_permissions.add(
            Permission.objects.get(
                content_type__app_label="payments", codename="delete_payment"
            )
        )
        client = APIClient()
        client.force_authenticate(user=clerk)
        cash = self._sale().payments.get()

        response = self._post(client, cash)

        self.assertEqual(response.status_code, status.HTTP_403_FORBIDDEN)
        cash.refresh_from_db()
        self.assertEqual(cash.doc_status, DocumentStatus.SUBMITTED)
