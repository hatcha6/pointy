"""Opening balances and adjustments on a customer's account.

What these pin, in the order a shop meets them: an entry is a debt the till
can collect and that nothing mistakes for a sale; it is never edited, only
withdrawn while untouched; and every figure that states what a customer owes —
the screen, the ceiling, the collection — reads it.
"""

from datetime import timedelta
from decimal import Decimal

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group
from django.urls import reverse
from django.utils import timezone
from rest_framework import status
from rest_framework.test import APIClient, APITestCase

from apps.catalog.testing import create_product_with_default_variant
from apps.core.models import ShopSettings
from apps.core.roles import (
    ACCOUNTANT_GROUP,
    AUDITOR_GROUP,
    CASHIER_GROUP,
    MANAGER_GROUP,
    SUPERVISOR_GROUP,
    ensure_role_groups,
)
from apps.customers.models import Customer
from apps.customers.receivables import customer_balance, outstanding_balance
from apps.customers.services import merge_customers
from apps.documents.statuses import DocumentStatus
from apps.inventory.models import StockItem
from apps.payments.models import Payment
from apps.sales.models import Order, RegisterSession

from .customers import create_customer_entry
from .models import BalanceEntry, CustomerBalanceEntry

Kind = BalanceEntry.Kind
Direction = BalanceEntry.Direction


class _CustomerAccountCase(APITestCase):
    """A manager with an open till, a customer, and a product to sell on آجل.

    Widget is 50.00.
    """

    def setUp(self):
        ensure_role_groups()
        ShopSettings.load()
        self.manager = self._user("bal-manager", MANAGER_GROUP)
        self.client = APIClient()
        self.client.force_authenticate(self.manager)
        self.client.post(
            reverse("register-session-start"), {"opening_cash": "0.00"}, format="json"
        )
        self.session = RegisterSession.objects.get(
            owner_key=f"user:{self.manager.pk}", status=RegisterSession.Status.OPEN
        )
        self.customer = Customer.objects.create(full_name="زبون الرصيد")
        product = create_product_with_default_variant(
            sku="BAL-WIDGET", barcode="", name="Widget", unit_price=Decimal("50.00")
        )
        self.variant = product.default_variant
        StockItem.objects.create(variant=self.variant, quantity_on_hand=100)

    def _user(self, username, group):
        user = get_user_model().objects.create_user(username=username, password="p")
        user.groups.add(Group.objects.get(name=group))
        return user

    def _entry(self, *, kind=Kind.OPENING, direction=Direction.THEY_OWE_US, amount="1000.00", **extra):
        payload = {
            "customer": self.customer.pk,
            "kind": kind,
            "direction": direction,
            "amount": amount,
            **extra,
        }
        return self.client.post(
            reverse("customer-balance-entry-list"), payload, format="json"
        )

    def _credit_sale(self, quantity=1, paid=None):
        payload = {
            "lines": [{"variant": self.variant.pk, "quantity": quantity}],
            "sale_type": "credit",
            "customer": self.customer.pk,
            "payments": [],
        }
        if paid:
            payload["payments"] = [{"method": "cash", "amount": paid}]
        response = self.client.post(reverse("order-checkout"), payload, format="json")
        self.assertEqual(response.status_code, status.HTTP_201_CREATED, response.data)
        return Order.objects.get(pk=response.data["id"])

    def _collect(self, amount, method="cash"):
        return self.client.post(
            reverse("customer-record-payment", args=[self.customer.pk]),
            {"method": method, "amount": amount},
            format="json",
        )

    def _summary(self):
        response = self.client.get(
            reverse("customer-sales-summary", args=[self.customer.pk])
        )
        self.assertEqual(response.status_code, status.HTTP_200_OK)
        return response.data


class CustomerDebtEntryTests(_CustomerAccountCase):
    def test_an_opening_debt_is_collectable_and_is_not_a_sale(self):
        response = self._entry(amount="1000.00", note="من الدفتر")

        self.assertEqual(response.status_code, status.HTTP_201_CREATED, response.data)
        entry = CustomerBalanceEntry.objects.get(pk=response.data["id"])
        self.assertTrue(entry.number.startswith("B"))
        self.assertEqual(entry.doc_status, DocumentStatus.SUBMITTED)
        order = entry.order
        # The carrier: a document the till can take a payment against, and
        # nothing else a sale has.
        self.assertEqual(order.sale_type, Order.SaleType.ACCOUNT_ENTRY)
        self.assertEqual(order.status, Order.Status.OPEN)
        self.assertEqual(order.doc_status, DocumentStatus.SUBMITTED)
        self.assertEqual(order.total, Decimal("1000.00"))
        self.assertEqual(order.receipt_number, entry.number)
        self.assertIsNone(order.register_session_id)
        self.assertFalse(order.lines.exists())
        # Never revenue.
        self.assertFalse(Order.objects.committed_sales().filter(pk=order.pk).exists())
        self.assertFalse(Order.objects.transactional().filter(pk=order.pk).exists())

        summary = self._summary()
        self.assertEqual(summary["outstanding_balance"], "1000.00")
        self.assertEqual(summary["net_balance"], "1000.00")
        self.assertEqual(summary["credit_balance"], "0.00")
        self.assertEqual(summary["invoice_count"], 0)
        self.assertEqual(summary["total_invoiced"], "0.00")
        self.assertTrue(summary["has_opening_balance"])

    def test_the_debt_is_collected_through_the_till_into_the_drawer(self):
        self._entry(amount="1000.00")

        partial = self._collect("400.00")
        self.assertEqual(partial.status_code, status.HTTP_200_OK, partial.data)
        self.assertEqual(partial.data["outstanding_balance"], "600.00")
        # A proof of payment can be printed for it.
        self.assertIn("payment", partial.data)

        rest = self._collect("600.00")
        self.assertEqual(rest.status_code, status.HTTP_200_OK, rest.data)
        self.assertEqual(rest.data["outstanding_balance"], "0.00")

        order = CustomerBalanceEntry.objects.get().order
        order.refresh_from_db()
        self.assertEqual(order.status, Order.Status.PAID)
        self.session.refresh_from_db()
        self.assertEqual(self.session.cash_sales_total, Decimal("1000.00"))
        # Settled, and still not a sale.
        self.assertFalse(Order.objects.transactional().filter(pk=order.pk).exists())

    def test_a_collection_cannot_take_more_than_is_owed(self):
        self._entry(amount="100.00")
        response = self._collect("100.01")
        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)

    def test_the_oldest_debt_is_settled_first(self):
        """An opening balance dated before the invoices is what a collection
        pays first — the order a paper ledger would have settled them in."""
        invoice = self._credit_sale()
        self._entry(
            amount="80.00",
            effective_date=(timezone.localdate() - timedelta(days=30)).isoformat(),
        )

        self._collect("80.00")

        carrier = CustomerBalanceEntry.objects.get().order
        carrier.refresh_from_db()
        invoice.refresh_from_db()
        self.assertEqual(carrier.status, Order.Status.PAID)
        self.assertEqual(invoice.balance_due, Decimal("50.00"))

    def test_an_invoice_list_never_shows_the_carrier(self):
        self._entry(amount="100.00")
        self._credit_sale()

        response = self.client.get(reverse("order-list"))

        types = {row["sale_type"] for row in response.data["results"]}
        self.assertNotIn(Order.SaleType.ACCOUNT_ENTRY, types)
        self.assertEqual(len(response.data["results"]), 1)

    def test_the_carrier_cannot_be_voided_as_if_it_were_a_sale(self):
        entry_id = self._entry(amount="100.00").data["id"]
        order = CustomerBalanceEntry.objects.get(pk=entry_id).order
        self._collect("100.00")

        response = self.client.post(
            reverse("order-void", args=[order.pk]), {"reason": "x"}, format="json"
        )

        self.assertEqual(response.status_code, status.HTTP_404_NOT_FOUND)

    def test_checkout_cannot_ring_up_an_account_entry(self):
        response = self.client.post(
            reverse("order-checkout"),
            {
                "lines": [{"variant": self.variant.pk, "quantity": 1}],
                "sale_type": "account_entry",
                "customer": self.customer.pk,
                "payments": [],
            },
            format="json",
        )
        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertFalse(
            Order.objects.filter(sale_type=Order.SaleType.ACCOUNT_ENTRY).exists()
        )

    def test_a_backdated_entry_is_stamped_on_its_own_day(self):
        day = timezone.localdate() - timedelta(days=45)
        entry_id = self._entry(amount="10.00", effective_date=day.isoformat()).data["id"]
        entry = CustomerBalanceEntry.objects.get(pk=entry_id)

        self.assertEqual(entry.effective_date, day)
        self.assertEqual(timezone.localtime(entry.order.created_at).date(), day)


class CustomerCreditEntryTests(_CustomerAccountCase):
    def test_credit_the_shop_owes_is_shown_as_such(self):
        response = self._entry(direction=Direction.WE_OWE_THEM, amount="300.00")

        self.assertEqual(response.status_code, status.HTTP_201_CREATED, response.data)
        entry = CustomerBalanceEntry.objects.get(pk=response.data["id"])
        self.assertIsNone(entry.order_id)
        summary = self._summary()
        self.assertEqual(summary["outstanding_balance"], "0.00")
        self.assertEqual(summary["credit_balance"], "300.00")
        self.assertEqual(summary["net_balance"], "-300.00")

    def test_a_collection_spends_the_credit_first(self):
        self._entry(direction=Direction.WE_OWE_THEM, amount="30.00")
        invoice = self._credit_sale()  # 50.00, credit NOT applied at the till

        # Checkout leaves the credit alone (see apps.balances.customers), so the
        # customer is asked for what they owe net of it.
        summary = self._summary()
        self.assertEqual(summary["open_debts_total"], "50.00")
        self.assertEqual(summary["unapplied_credit"], "30.00")
        self.assertEqual(summary["outstanding_balance"], "20.00")

        response = self._collect("20.00")

        self.assertEqual(response.status_code, status.HTTP_200_OK, response.data)
        invoice.refresh_from_db()
        self.assertEqual(invoice.status, Order.Status.PAID)
        methods = sorted(
            (payment.method, payment.amount) for payment in invoice.payments.all()
        )
        self.assertEqual(
            methods,
            [
                (Payment.Method.ACCOUNT_CREDIT, Decimal("30.00")),
                (Payment.Method.CASH, Decimal("20.00")),
            ],
        )
        # Only the cash reached the drawer, and only the cash is money received.
        self.session.refresh_from_db()
        self.assertEqual(self.session.cash_sales_total, Decimal("20.00"))
        received = sum(
            Payment.objects.filter(order=invoice).money_received().values_list(
                "amount", flat=True
            ),
            Decimal("0.00"),
        )
        self.assertEqual(received, Decimal("20.00"))
        summary = self._summary()
        self.assertEqual(summary["net_balance"], "0.00")
        self.assertEqual(summary["unapplied_credit"], "0.00")

    def test_a_collection_asks_for_nothing_when_credit_covers_the_debt(self):
        self._entry(direction=Direction.WE_OWE_THEM, amount="80.00")
        self._credit_sale()

        response = self._collect("0.01")

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)

    def test_writing_credit_onto_an_account_that_owes_settles_it_at_once(self):
        invoice = self._credit_sale()

        self._entry(
            kind=Kind.ADJUSTMENT,
            direction=Direction.WE_OWE_THEM,
            amount="20.00",
            note="تعويض",
        )

        invoice.refresh_from_db()
        self.assertEqual(invoice.balance_due, Decimal("30.00"))
        balance = customer_balance(self.customer)
        self.assertEqual(balance.open_debts, Decimal("30.00"))
        self.assertEqual(balance.unapplied_credit, Decimal("0.00"))

    def test_writing_a_debt_onto_an_account_in_credit_spends_the_credit(self):
        self._entry(direction=Direction.WE_OWE_THEM, amount="100.00")

        self._entry(
            kind=Kind.ADJUSTMENT,
            direction=Direction.THEY_OWE_US,
            amount="60.00",
            note="خدمة خارج النظام",
        )

        balance = customer_balance(self.customer)
        self.assertEqual(balance.open_debts, Decimal("0.00"))
        self.assertEqual(balance.unapplied_credit, Decimal("40.00"))
        self.assertEqual(balance.net, Decimal("-40.00"))

    def test_the_owner_can_apply_credit_without_collecting(self):
        self._entry(direction=Direction.WE_OWE_THEM, amount="30.00")
        invoice = self._credit_sale()

        response = self.client.post(
            reverse("customer-apply-credit", args=[self.customer.pk]), {}, format="json"
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK, response.data)
        self.assertEqual(response.data["open_debts_total"], "20.00")
        self.assertEqual(response.data["unapplied_credit"], "0.00")
        invoice.refresh_from_db()
        self.assertEqual(invoice.balance_due, Decimal("20.00"))

    def test_a_credit_payment_cannot_be_cancelled_on_its_own(self):
        self._entry(direction=Direction.WE_OWE_THEM, amount="30.00")
        self._credit_sale()
        self.client.post(reverse("customer-apply-credit", args=[self.customer.pk]))
        payment = Payment.objects.get(method=Payment.Method.ACCOUNT_CREDIT)

        response = self.client.post(
            reverse("payment-cancel", args=[payment.pk]),
            {"reason": "خطأ"},
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertEqual(response.data["code"], "account_credit_owned_by_balance")

    def test_returning_goods_bought_with_credit_refunds_them_in_cash(self):
        """The credit was money the shop owed; spent on goods that came back,
        it goes back as money — through the drawer that pays it out."""
        self._entry(direction=Direction.WE_OWE_THEM, amount="50.00")
        invoice = self._credit_sale()
        self.client.post(reverse("customer-apply-credit", args=[self.customer.pk]))
        invoice.refresh_from_db()
        self.assertEqual(invoice.status, Order.Status.PAID)

        response = self.client.post(
            reverse("order-void", args=[invoice.pk]),
            {"reason": "مرتجع"},
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK, response.data)
        refunds = invoice.payments.filter(amount__lt=0)
        self.assertEqual(
            list(refunds.values_list("method", "amount")),
            [(Payment.Method.CASH, Decimal("-50.00"))],
        )
        self.session.refresh_from_db()
        self.assertEqual(self.session.cash_refund_total, Decimal("50.00"))


class CustomerCreditLimitTests(_CustomerAccountCase):
    def _limit(self, amount):
        ShopSettings.objects.filter(pk=1).update(
            enforce_customer_credit_limits=True,
            default_customer_credit_limit=Decimal(amount),
        )

    def test_an_opening_debt_counts_against_the_ceiling(self):
        self._limit("1020.00")
        self._entry(amount="1000.00")

        response = self.client.post(
            reverse("order-checkout"),
            {
                "lines": [{"variant": self.variant.pk, "quantity": 1}],
                "sale_type": "credit",
                "customer": self.customer.pk,
                "payments": [],
            },
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertEqual(response.data["code"], "credit_limit_exceeded")
        self.assertEqual(response.data["credit"]["outstanding"], "1000.00")

    def test_credit_the_shop_owes_widens_what_may_be_owed(self):
        """A "cash only" customer the shop owes 100 may take 50 on account:
        the next collection spends the credit, and nothing is left owed."""
        self._limit("0.00")
        self._entry(direction=Direction.WE_OWE_THEM, amount="100.00")

        self._credit_sale()

        self.assertEqual(outstanding_balance(self.customer), Decimal("0.00"))


class CustomerEntryRulesTests(_CustomerAccountCase):
    def test_an_account_opens_once(self):
        first = self._entry(amount="10.00")
        second = self._entry(amount="20.00")

        self.assertEqual(second.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertEqual(second.data["code"], "opening_balance_exists")

        self.client.post(
            reverse("customer-balance-entry-cancel", args=[first.data["id"]]),
            {"reason": "أدخلته خطأ"},
            format="json",
        )
        again = self._entry(amount="20.00")
        self.assertEqual(again.status_code, status.HTTP_201_CREATED, again.data)

    def test_an_adjustment_says_what_it_is_for(self):
        response = self._entry(kind=Kind.ADJUSTMENT, amount="10.00")
        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertIn("note", response.data)

    def test_a_balance_cannot_start_in_the_future(self):
        tomorrow = timezone.localdate() + timedelta(days=2)
        response = self._entry(amount="10.00", effective_date=tomorrow.isoformat())
        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertIn("effective_date", response.data)

    def test_the_amount_must_be_positive(self):
        for amount in ("0.00", "-5.00"):
            with self.subTest(amount=amount):
                response = self._entry(amount=amount)
                self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)

    def test_a_closed_period_refuses_a_backdated_balance(self):
        locked = timezone.localdate() - timedelta(days=10)
        ShopSettings.objects.filter(pk=1).update(books_locked_through=locked)
        accountant = self._user("bal-accountant", ACCOUNTANT_GROUP)
        self.client.force_authenticate(accountant)

        response = self._entry(
            amount="10.00", effective_date=(locked - timedelta(days=1)).isoformat()
        )

        self.assertEqual(response.status_code, status.HTTP_403_FORBIDDEN)
        self.assertFalse(CustomerBalanceEntry.objects.exists())

    def test_an_entry_is_never_edited(self):
        entry_id = self._entry(amount="10.00").data["id"]
        url = reverse("customer-balance-entry-detail", args=[entry_id])
        refused = (status.HTTP_403_FORBIDDEN, status.HTTP_405_METHOD_NOT_ALLOWED)
        self.assertIn(
            self.client.patch(url, {"amount": "99.00"}, format="json").status_code,
            refused,
        )
        self.assertIn(self.client.delete(url).status_code, refused)
        entry = CustomerBalanceEntry.objects.get(pk=entry_id)
        self.assertEqual(entry.amount, Decimal("10.00"))
        self.assertEqual(entry.doc_status, DocumentStatus.SUBMITTED)


class CustomerEntryCancelTests(_CustomerAccountCase):
    def _cancel(self, entry_id, reason="أدخلته خطأ"):
        return self.client.post(
            reverse("customer-balance-entry-cancel", args=[entry_id]),
            {"reason": reason},
            format="json",
        )

    def test_an_untouched_debt_is_withdrawn_with_its_carrier(self):
        entry_id = self._entry(amount="100.00").data["id"]

        response = self._cancel(entry_id)

        self.assertEqual(response.status_code, status.HTTP_200_OK, response.data)
        self.assertEqual(response.data["doc_status"], DocumentStatus.CANCELLED)
        self.assertEqual(response.data["cancel_reason"], "أدخلته خطأ")
        entry = CustomerBalanceEntry.objects.get(pk=entry_id)
        self.assertEqual(entry.order.status, Order.Status.VOID)
        self.assertEqual(entry.order.doc_status, DocumentStatus.CANCELLED)
        self.assertEqual(outstanding_balance(self.customer), Decimal("0.00"))

    def test_a_reason_is_required(self):
        entry_id = self._entry(amount="100.00").data["id"]
        response = self._cancel(entry_id, reason="  ")
        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)

    def test_a_debt_that_has_been_collected_from_stays(self):
        entry_id = self._entry(amount="100.00").data["id"]
        self._collect("10.00")

        response = self._cancel(entry_id)

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertEqual(response.data["code"], "document_blocked")
        self.assertEqual(
            CustomerBalanceEntry.objects.get(pk=entry_id).doc_status,
            DocumentStatus.SUBMITTED,
        )

    def test_credit_that_has_been_spent_stays(self):
        self._credit_sale()
        entry_id = self._entry(
            kind=Kind.ADJUSTMENT,
            direction=Direction.WE_OWE_THEM,
            amount="10.00",
            note="تعويض",
        ).data["id"]

        response = self._cancel(entry_id)

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertEqual(response.data["code"], "document_blocked")

    def test_the_listing_says_what_is_left_and_whether_it_can_go(self):
        entry_id = self._entry(amount="100.00").data["id"]
        self._collect("40.00")

        response = self.client.get(
            reverse("customer-balance-entry-list"), {"customer": self.customer.pk}
        )

        row = next(row for row in response.data["results"] if row["id"] == entry_id)
        self.assertEqual(row["settled_amount"], "40.00")
        self.assertEqual(row["remaining_amount"], "60.00")
        self.assertFalse(row["can_cancel"])


class CustomerEntryPermissionTests(_CustomerAccountCase):
    def test_a_cashier_cannot_write_a_balance(self):
        self.client.force_authenticate(self._user("bal-cashier", CASHIER_GROUP))
        self.assertEqual(self._entry(amount="10.00").status_code, status.HTTP_403_FORBIDDEN)

    def test_an_auditor_reads_but_does_not_write(self):
        self._entry(amount="10.00")
        self.client.force_authenticate(self._user("bal-auditor", AUDITOR_GROUP))

        listed = self.client.get(reverse("customer-balance-entry-list"))
        written = self._entry(kind=Kind.ADJUSTMENT, amount="5.00", note="x")

        self.assertEqual(listed.status_code, status.HTTP_200_OK)
        self.assertEqual(written.status_code, status.HTTP_403_FORBIDDEN)

    def test_an_accountant_carries_balances_in(self):
        self.client.force_authenticate(self._user("bal-acct", ACCOUNTANT_GROUP))
        self.assertEqual(
            self._entry(amount="10.00").status_code, status.HTTP_201_CREATED
        )


class CustomerCreateWithOpeningBalanceTests(_CustomerAccountCase):
    def _create(self, **extra):
        return self.client.post(
            reverse("customer-list"),
            {"full_name": "زبون جديد", **extra},
            format="json",
        )

    def test_a_customer_arrives_with_the_balance_they_carry(self):
        response = self._create(
            opening_balance={"direction": "they_owe_us", "amount": "250.00"}
        )

        self.assertEqual(response.status_code, status.HTTP_201_CREATED, response.data)
        customer = Customer.objects.get(pk=response.data["id"])
        entry = customer.balance_entries.get()
        self.assertEqual(entry.kind, Kind.OPENING)
        self.assertEqual(outstanding_balance(customer), Decimal("250.00"))
        self.assertNotIn("opening_balance", response.data)

    def test_no_opening_balance_is_the_ordinary_create(self):
        response = self._create()
        self.assertEqual(response.status_code, status.HTTP_201_CREATED, response.data)
        self.assertFalse(CustomerBalanceEntry.objects.exists())

    def test_without_the_right_nothing_is_created(self):
        clerk = self._user("bal-supervisor", SUPERVISOR_GROUP)
        self.client.force_authenticate(clerk)

        response = self._create(
            opening_balance={"direction": "they_owe_us", "amount": "250.00"}
        )

        self.assertEqual(response.status_code, status.HTTP_403_FORBIDDEN)
        self.assertFalse(Customer.objects.filter(full_name="زبون جديد").exists())

    def test_a_refused_balance_refuses_the_customer_too(self):
        future = (timezone.localdate() + timedelta(days=3)).isoformat()
        response = self._create(
            opening_balance={
                "direction": "they_owe_us",
                "amount": "250.00",
                "effective_date": future,
            }
        )

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertIn("opening_balance", response.data)
        self.assertFalse(Customer.objects.filter(full_name="زبون جديد").exists())

    def test_an_edit_cannot_carry_an_opening_balance(self):
        response = self.client.patch(
            reverse("customer-detail", args=[self.customer.pk]),
            {"opening_balance": {"direction": "they_owe_us", "amount": "5.00"}},
            format="json",
        )
        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertFalse(CustomerBalanceEntry.objects.exists())


class CustomerMergeTests(_CustomerAccountCase):
    def test_a_merge_carries_the_balances_to_the_surviving_customer(self):
        duplicate = Customer.objects.create(full_name="نسخة")
        create_customer_entry(
            customer=duplicate,
            kind=Kind.OPENING,
            direction=Direction.THEY_OWE_US,
            amount=Decimal("70.00"),
            actor=self.manager,
        )

        merge_customers(source=duplicate, target=self.customer)

        entry = CustomerBalanceEntry.objects.get()
        self.assertEqual(entry.customer_id, self.customer.pk)
        self.assertEqual(entry.order.customer_id, self.customer.pk)
        self.assertEqual(outstanding_balance(self.customer), Decimal("70.00"))
