"""Opening balances and adjustments on a supplier's account.

A balance the shop owes is an open item that supplier payments settle by name;
a balance the supplier owes the shop is a supplier credit note, spent the way
return credit always has been. Both have to agree, to the dinar, with the
supplier's own balance and with the list and the report that state it.
"""

from datetime import timedelta
from decimal import Decimal

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group
from django.db import IntegrityError, transaction
from django.urls import reverse
from django.utils import timezone
from rest_framework import status
from rest_framework.test import APIClient, APITestCase

from apps.core.models import ShopSettings
from apps.core.roles import (
    MANAGER_GROUP,
    PURCHASING_AGENT_GROUP,
    ensure_role_groups,
)
from apps.documents.statuses import DocumentStatus
from apps.purchasing.models import (
    PurchaseOrder,
    Supplier,
    SupplierCredit,
    SupplierPayment,
    prime_supplier_balances,
)

from .models import BalanceEntry, SupplierBalanceEntry
from .suppliers import create_supplier_entry, entry_outstanding

Kind = BalanceEntry.Kind
Direction = BalanceEntry.Direction


class _SupplierAccountCase(APITestCase):
    def setUp(self):
        ensure_role_groups()
        ShopSettings.load()
        self.manager = self._user("sup-manager", MANAGER_GROUP)
        self.client = APIClient()
        self.client.force_authenticate(self.manager)
        self.supplier = Supplier.objects.create(name="مورد الرصيد")

    def _user(self, username, group):
        user = get_user_model().objects.create_user(username=username, password="p")
        user.groups.add(Group.objects.get(name=group))
        return user

    def _entry(self, *, kind=Kind.OPENING, direction=Direction.WE_OWE_THEM, amount="5000.00", **extra):
        return self.client.post(
            reverse("supplier-balance-entry-list"),
            {
                "supplier": self.supplier.pk,
                "kind": kind,
                "direction": direction,
                "amount": amount,
                **extra,
            },
            format="json",
        )

    def _order(self, total, *, days_ago=0):
        order = PurchaseOrder.objects.create(
            supplier=self.supplier,
            status=PurchaseOrder.Status.RECEIVED,
            subtotal=Decimal(total),
            total=Decimal(total),
        )
        if days_ago:
            PurchaseOrder.objects.filter(pk=order.pk).update(
                created_at=timezone.now() - timedelta(days=days_ago)
            )
        return order

    def _pay(self, amount, method="cash"):
        return self.client.post(
            reverse("supplier-record-payment", args=[self.supplier.pk]),
            {"method": method, "amount": amount},
            format="json",
        )

    def _supplier(self):
        response = self.client.get(reverse("supplier-detail", args=[self.supplier.pk]))
        self.assertEqual(response.status_code, status.HTTP_200_OK)
        return response.data


class SupplierPayableEntryTests(_SupplierAccountCase):
    def test_an_opening_payable_is_owed(self):
        response = self._entry(amount="5000.00")

        self.assertEqual(response.status_code, status.HTTP_201_CREATED, response.data)
        data = self._supplier()
        self.assertEqual(data["payable_balance"], "5000.00")
        self.assertEqual(data["credit_balance"], "0.00")
        self.assertEqual(data["net_balance"], "5000.00")
        # Nothing was bought.
        self.assertEqual(data["total_bought"], "0.00")
        self.assertEqual(data["purchase_count"], 0)

    def test_it_is_paid_off_on_account(self):
        self._entry(amount="5000.00")

        first = self._pay("2000.00")
        self.assertEqual(first.status_code, status.HTTP_201_CREATED, first.data)
        self.assertEqual(first.data["supplier"]["payable_balance"], "3000.00")
        payment = SupplierPayment.objects.get()
        entry = SupplierBalanceEntry.objects.get()
        self.assertEqual(payment.balance_entry_id, entry.pk)
        self.assertIsNone(payment.purchase_order_id)
        self.assertEqual(first.data["payments"][0]["balance_entry_number"], entry.number)

        self._pay("3000.00")
        self.assertEqual(entry_outstanding(entry), Decimal("0.00"))
        self.assertEqual(self._supplier()["payable_balance"], "0.00")

    def test_an_account_payment_settles_the_oldest_debt_first(self):
        self._entry(
            amount="100.00",
            effective_date=(timezone.localdate() - timedelta(days=60)).isoformat(),
        )
        order = self._order("300.00", days_ago=10)

        response = self._pay("250.00")

        self.assertEqual(response.status_code, status.HTTP_201_CREATED, response.data)
        entry = SupplierBalanceEntry.objects.get()
        self.assertEqual(entry_outstanding(entry), Decimal("0.00"))
        order.refresh_from_db()
        self.assertEqual(order.balance_due, Decimal("150.00"))
        self.assertEqual(self._supplier()["payable_balance"], "150.00")

    def test_an_account_payment_cannot_pay_more_than_is_owed(self):
        self._entry(amount="100.00")
        response = self._pay("100.01")
        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertFalse(SupplierPayment.objects.exists())

    def test_a_paid_entry_cannot_be_withdrawn(self):
        entry_id = self._entry(amount="100.00").data["id"]
        self._pay("10.00")

        response = self.client.post(
            reverse("supplier-balance-entry-cancel", args=[entry_id]),
            {"reason": "خطأ"},
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertEqual(response.data["code"], "document_blocked")

    def test_cancelling_the_payment_reopens_the_entry_and_frees_it(self):
        entry_id = self._entry(amount="100.00").data["id"]
        self._pay("100.00")
        payment = SupplierPayment.objects.get()

        self.client.post(
            reverse("supplierpayment-cancel", args=[payment.pk]),
            {"reason": "دفعة مكررة"},
            format="json",
        )

        entry = SupplierBalanceEntry.objects.get(pk=entry_id)
        self.assertEqual(entry_outstanding(entry), Decimal("100.00"))
        response = self.client.post(
            reverse("supplier-balance-entry-cancel", args=[entry_id]),
            {"reason": "خطأ"},
            format="json",
        )
        self.assertEqual(response.status_code, status.HTTP_200_OK, response.data)
        self.assertEqual(self._supplier()["payable_balance"], "0.00")


class SupplierCreditEntryTests(_SupplierAccountCase):
    def test_a_supplier_who_owes_the_shop_holds_a_credit_note(self):
        response = self._entry(direction=Direction.THEY_OWE_US, amount="700.00")

        self.assertEqual(response.status_code, status.HTTP_201_CREATED, response.data)
        credit = SupplierCredit.objects.get()
        self.assertEqual(credit.balance_entry_id, response.data["id"])
        self.assertIsNone(credit.purchase_order_id)
        self.assertEqual(credit.remaining_amount, Decimal("700.00"))
        data = self._supplier()
        self.assertEqual(data["credit_balance"], "700.00")
        self.assertEqual(data["net_balance"], "-700.00")

    def test_the_credit_is_spent_on_an_order_like_any_other(self):
        self._entry(direction=Direction.THEY_OWE_US, amount="700.00")
        order = self._order("2000.00")

        response = self.client.post(
            reverse("supplierpayment-list"),
            {
                "supplier": self.supplier.pk,
                "purchase_order": order.pk,
                "amount": "700.00",
                "method": "supplier_credit",
            },
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_201_CREATED, response.data)
        order.refresh_from_db()
        self.assertEqual(order.balance_due, Decimal("1300.00"))
        data = self._supplier()
        self.assertEqual(data["credit_balance"], "0.00")
        self.assertEqual(data["net_balance"], "1300.00")

    def test_credit_is_spent_against_an_opening_balance_on_account(self):
        self._entry(amount="1000.00")
        self._entry(
            kind=Kind.ADJUSTMENT,
            direction=Direction.THEY_OWE_US,
            amount="300.00",
            note="بضاعة أعيدت خارج النظام",
        )

        response = self._pay("300.00", method="supplier_credit")

        self.assertEqual(response.status_code, status.HTTP_201_CREATED, response.data)
        data = response.data["supplier"]
        self.assertEqual(data["payable_balance"], "700.00")
        self.assertEqual(data["credit_balance"], "0.00")
        self.assertEqual(data["net_balance"], "700.00")

    def test_an_untouched_credit_is_withdrawn_with_its_note(self):
        entry_id = self._entry(direction=Direction.THEY_OWE_US, amount="50.00").data["id"]

        response = self.client.post(
            reverse("supplier-balance-entry-cancel", args=[entry_id]),
            {"reason": "خطأ"},
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK, response.data)
        self.assertFalse(SupplierCredit.objects.exists())
        self.assertEqual(self._supplier()["credit_balance"], "0.00")

    def test_a_spent_credit_cannot_be_withdrawn(self):
        entry_id = self._entry(direction=Direction.THEY_OWE_US, amount="50.00").data["id"]
        order = self._order("80.00")
        self.client.post(
            reverse("supplierpayment-list"),
            {
                "supplier": self.supplier.pk,
                "purchase_order": order.pk,
                "amount": "20.00",
                "method": "supplier_credit",
            },
            format="json",
        )

        response = self.client.post(
            reverse("supplier-balance-entry-cancel", args=[entry_id]),
            {"reason": "خطأ"},
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertEqual(response.data["code"], "document_blocked")
        self.assertTrue(SupplierCredit.objects.exists())


class SupplierPaymentLinkTests(_SupplierAccountCase):
    def test_a_payment_names_one_thing_it_settles(self):
        entry = create_supplier_entry(
            supplier=self.supplier,
            kind=Kind.OPENING,
            direction=Direction.WE_OWE_THEM,
            amount=Decimal("10.00"),
        )
        order = self._order("10.00")

        response = self.client.post(
            reverse("supplierpayment-list"),
            {
                "supplier": self.supplier.pk,
                "purchase_order": order.pk,
                "balance_entry": entry.pk,
                "amount": "5.00",
                "method": "cash",
            },
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        with self.assertRaises(IntegrityError), transaction.atomic():
            SupplierPayment.objects.create(
                supplier=self.supplier,
                purchase_order=order,
                balance_entry=entry,
                amount=Decimal("1.00"),
                method="cash",
            )

    def test_another_suppliers_balance_cannot_be_paid(self):
        other = Supplier.objects.create(name="آخر")
        entry = create_supplier_entry(
            supplier=other,
            kind=Kind.OPENING,
            direction=Direction.WE_OWE_THEM,
            amount=Decimal("10.00"),
        )

        response = self.client.post(
            reverse("supplierpayment-list"),
            {
                "supplier": self.supplier.pk,
                "balance_entry": entry.pk,
                "amount": "5.00",
                "method": "cash",
            },
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertIn("balance_entry", response.data)

    def test_a_credit_owed_to_the_shop_cannot_be_paid_as_a_debt(self):
        entry = create_supplier_entry(
            supplier=self.supplier,
            kind=Kind.OPENING,
            direction=Direction.THEY_OWE_US,
            amount=Decimal("10.00"),
        )

        response = self.client.post(
            reverse("supplierpayment-list"),
            {
                "supplier": self.supplier.pk,
                "balance_entry": entry.pk,
                "amount": "5.00",
                "method": "cash",
            },
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)


class SupplierBalanceDefinitionTests(_SupplierAccountCase):
    def test_a_primed_supplier_agrees_with_a_cold_one(self):
        self._order("400.00")
        self._entry(amount="250.00")
        self._entry(
            kind=Kind.ADJUSTMENT,
            direction=Direction.THEY_OWE_US,
            amount="40.00",
            note="خصم متفق عليه",
        )
        self._pay("100.00")

        cold = Supplier.objects.get(pk=self.supplier.pk)
        primed = prime_supplier_balances([Supplier.objects.get(pk=self.supplier.pk)])[0]

        self.assertEqual(cold.payable_balance, primed.payable_balance)
        self.assertEqual(cold.credit_balance, primed.credit_balance)
        self.assertEqual(cold.net_balance, Decimal("510.00"))

    def test_the_supplier_list_states_the_same_balance(self):
        self._entry(amount="250.00")
        response = self.client.get(reverse("supplier-list"))
        row = next(r for r in response.data["results"] if r["id"] == self.supplier.pk)
        self.assertEqual(row["payable_balance"], "250.00")


class SupplierCreateWithOpeningBalanceTests(_SupplierAccountCase):
    def test_a_supplier_arrives_with_what_the_shop_owes_them(self):
        response = self.client.post(
            reverse("supplier-list"),
            {
                "name": "مورد جديد",
                "opening_balance": {"direction": "we_owe_them", "amount": "900.00"},
            },
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_201_CREATED, response.data)
        self.assertEqual(response.data["payable_balance"], "900.00")
        supplier = Supplier.objects.get(pk=response.data["id"])
        self.assertEqual(supplier.balance_entries.get().kind, Kind.OPENING)

    def test_a_buyer_cannot_declare_one(self):
        self.client.force_authenticate(self._user("sup-buyer", PURCHASING_AGENT_GROUP))
        response = self.client.post(
            reverse("supplier-list"),
            {
                "name": "مورد جديد",
                "opening_balance": {"direction": "we_owe_them", "amount": "900.00"},
            },
            format="json",
        )
        self.assertEqual(response.status_code, status.HTTP_403_FORBIDDEN)
        self.assertFalse(Supplier.objects.filter(name="مورد جديد").exists())

    def test_a_buyer_reads_the_balances_but_does_not_write_them(self):
        self._entry(amount="10.00")
        self.client.force_authenticate(self._user("sup-buyer2", PURCHASING_AGENT_GROUP))

        listed = self.client.get(
            reverse("supplier-balance-entry-list"), {"supplier": self.supplier.pk}
        )

        self.assertEqual(listed.status_code, status.HTTP_200_OK)
        self.assertEqual(len(listed.data["results"]), 1)
        self.assertEqual(
            self._entry(kind=Kind.ADJUSTMENT, amount="1.00", note="x").status_code,
            status.HTTP_403_FORBIDDEN,
        )

    def test_the_lifecycle_is_recorded(self):
        entry_id = self._entry(amount="10.00").data["id"]
        self.client.post(
            reverse("supplier-balance-entry-cancel", args=[entry_id]),
            {"reason": "خطأ في المبلغ"},
            format="json",
        )

        response = self.client.get(
            reverse("document-event-list"),
            {"document_type": "supplier_balance_entry", "object_id": entry_id},
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK, response.data)
        actions = [row["action"] for row in response.data["results"]]
        self.assertEqual(sorted(actions), ["cancelled", "submitted"])
        entry = SupplierBalanceEntry.objects.get(pk=entry_id)
        self.assertEqual(entry.doc_status, DocumentStatus.CANCELLED)
        self.assertEqual(entry.cancelled_by, self.manager)
