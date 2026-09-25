"""A balance someone is owed, settled with cash.

A credit that can only ever be spent against the next invoice is half a
balance: a customer the shop owes money can ask for it, and a supplier who owes
the shop can pay it back. Each refund has to move three things at once — the
account, the drawer, and the money position — and leave the expenses ledger
alone, because settling a debt is not spending money.
"""

from datetime import timedelta
from decimal import Decimal

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group
from django.urls import reverse
from django.utils import timezone
from rest_framework import status
from rest_framework.test import APIClient, APITestCase

from apps.core.models import ShopSettings
from apps.core.roles import MANAGER_GROUP, ensure_role_groups
from apps.customers.models import Customer
from apps.customers.receivables import customer_balance
from apps.purchasing.models import (
    PurchaseOrder,
    Supplier,
    SupplierCredit,
    SupplierPayment,
)
from apps.reports.models import ReportRun
from apps.reports.services import generate_report_payload
from apps.sales.models import Order, RegisterCashMovement, RegisterSession
from apps.sales.testing import issue
from apps.treasury.position import treasury_position

from .customers import create_customer_entry
from .models import BalanceEntry, CustomerBalanceEntry, SupplierBalanceEntry
from .suppliers import create_supplier_entry

Kind = BalanceEntry.Kind
Direction = BalanceEntry.Direction


class _RefundCase(APITestCase):
    def setUp(self):
        ensure_role_groups()
        ShopSettings.load()
        self.manager = get_user_model().objects.create_user(
            username="refund-manager", password="p"
        )
        self.manager.groups.add(Group.objects.get(name=MANAGER_GROUP))
        self.client = APIClient()
        self.client.force_authenticate(self.manager)
        self.today = timezone.localdate()

    def _open_drawer(self):
        self.client.post(
            reverse("register-session-start"), {"opening_cash": "500.00"}, format="json"
        )
        return RegisterSession.objects.get(
            owner_key=f"user:{self.manager.pk}", status=RegisterSession.Status.OPEN
        )

    def _cash_position(self):
        return treasury_position()["totals"]["cash"]


class CustomerCreditRefundTests(_RefundCase):
    def setUp(self):
        super().setUp()
        self.customer = Customer.objects.create(full_name="زبون له رصيد")
        create_customer_entry(
            customer=self.customer,
            kind=Kind.OPENING,
            direction=Direction.WE_OWE_THEM,
            amount=Decimal("300.00"),
            actor=self.manager,
        )

    def _refund(self, amount, **extra):
        return self.client.post(
            reverse("customer-balance-entry-refund"),
            {"customer": self.customer.pk, "amount": amount, **extra},
            format="json",
        )

    def test_the_credit_is_paid_out_of_the_drawer(self):
        session = self._open_drawer()
        cash_before = self._cash_position()

        response = self._refund("120.00", note="طلب استرداد")

        self.assertEqual(response.status_code, status.HTTP_201_CREATED, response.data)
        entry = CustomerBalanceEntry.objects.get(pk=response.data["id"])
        self.assertEqual(entry.kind, Kind.REFUND)
        self.assertEqual(entry.direction, Direction.THEY_OWE_US)
        # The account: a debt of 120 written and settled from the credit.
        self.assertEqual(entry.order.status, Order.Status.PAID)
        balance = customer_balance(self.customer)
        self.assertEqual(balance.unapplied_credit, Decimal("180.00"))
        self.assertEqual(balance.open_debts, Decimal("0.00"))
        # The drawer: the cash left through a pay-out it counts.
        movement = entry.cash_movement
        self.assertEqual(movement.movement_type, RegisterCashMovement.MovementType.PAY_OUT)
        self.assertEqual(movement.register_session_id, session.pk)
        session.refresh_from_db()
        self.assertEqual(session.pay_out_total, Decimal("120.00"))
        self.assertEqual(session.expected_cash, Decimal("380.00"))
        # The money position: the cash box is 120 lighter.
        self.assertEqual(self._cash_position(), cash_before - Decimal("120.00"))
        # Not a sale, and not revenue.
        self.assertFalse(Order.objects.transactional().filter(pk=entry.order_id).exists())

    def test_the_refund_is_not_an_expense(self):
        self._open_drawer()
        self._refund("120.00")

        response = self.client.get(reverse("expense-ledger"))

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(response.data["totals"]["register_payout"], "0.00")

    def test_the_statement_shows_the_refund_and_closes_on_what_is_still_owed(self):
        self._open_drawer()
        self._refund("120.00")

        payload = generate_report_payload(
            report_type=ReportRun.ReportType.CUSTOMER_STATEMENT,
            params={
                "customer_id": self.customer.pk,
                "start_date": (self.today - timedelta(days=5)).isoformat(),
                "end_date": self.today.isoformat(),
            },
            user=self.manager,
        )

        rows = next(
            s for s in payload["sections"] if s["key"] == "statement_entries"
        )["rows"]
        self.assertEqual(
            [row["kind"] for row in rows], ["opening_balance", "balance_refund"]
        )
        self.assertEqual(payload["summary"]["closing_balance"], "-180.00")

    def test_paying_out_credit_does_not_change_what_the_shop_is_worth(self):
        self._open_drawer()
        self._refund("120.00")

        payload = generate_report_payload(
            report_type=ReportRun.ReportType.BALANCE_SHEET,
            params={
                "start_date": self.today.isoformat(),
                "end_date": self.today.isoformat(),
            },
            user=self.manager,
        )

        movement = {
            row["line"]: row
            for row in next(
                s for s in payload["sections"] if s["key"] == "net_position_movement"
            )["rows"]
        }
        liabilities = {
            row["line"]: row
            for row in next(
                s for s in payload["sections"] if s["key"] == "balance_liabilities"
            )["rows"]
        }
        self.assertEqual(liabilities["customer_credits"]["closing_balance"], "180.00")
        # The opening balance is the position the shop started from; the
        # refund swapped cash for a debt of the same size. Neither is a result.
        self.assertEqual(movement["period_result"]["amount"], "0.00")

    def test_a_customer_is_paid_no_more_than_they_are_owed(self):
        self._open_drawer()
        response = self._refund("300.01")
        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertEqual(response.data["code"], "refund_exceeds_credit")
        self.assertFalse(RegisterCashMovement.objects.exists())

    def test_their_debts_take_the_credit_first(self):
        session = self._open_drawer()
        invoice = Order.objects.create(
            register_session=session,
            customer=self.customer,
            sale_type=Order.SaleType.CREDIT,
            status=Order.Status.OPEN,
            subtotal=Decimal("100.00"),
            total=Decimal("100.00"),
        )
        issue(invoice, status=Order.Status.OPEN)

        refused = self._refund("250.00")
        allowed = self._refund("200.00")

        self.assertEqual(refused.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertEqual(refused.data["available"], "200.00")
        self.assertEqual(allowed.status_code, status.HTTP_201_CREATED, allowed.data)
        invoice.refresh_from_db()
        self.assertEqual(invoice.status, Order.Status.PAID)
        self.assertEqual(customer_balance(self.customer).net, Decimal("0.00"))

    def test_cash_moves_through_an_open_drawer_or_not_at_all(self):
        response = self._refund("50.00")
        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertEqual(response.data["code"], "register_session_required")
        self.assertEqual(
            CustomerBalanceEntry.objects.filter(kind=Kind.REFUND).count(), 0
        )

    def test_a_refund_is_final(self):
        self._open_drawer()
        entry_id = self._refund("50.00").data["id"]

        listed = self.client.get(
            reverse("customer-balance-entry-detail", args=[entry_id])
        )
        cancelled = self.client.post(
            reverse("customer-balance-entry-cancel", args=[entry_id]),
            {"reason": "خطأ"},
            format="json",
        )

        self.assertFalse(listed.data["can_cancel"])
        self.assertEqual(cancelled.status_code, status.HTTP_400_BAD_REQUEST)

    def test_the_entry_form_cannot_claim_cash_changed_hands(self):
        response = self.client.post(
            reverse("customer-balance-entry-list"),
            {
                "customer": self.customer.pk,
                "kind": "refund",
                "direction": "they_owe_us",
                "amount": "10.00",
                "note": "x",
            },
            format="json",
        )
        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)


class SupplierRefundTests(_RefundCase):
    def setUp(self):
        super().setUp()
        self.supplier = Supplier.objects.create(name="مورد مدين")
        create_supplier_entry(
            supplier=self.supplier,
            kind=Kind.OPENING,
            direction=Direction.THEY_OWE_US,
            amount=Decimal("700.00"),
            actor=self.manager,
        )

    def _refund(self, amount):
        return self.client.post(
            reverse("supplier-balance-entry-refund"),
            {"supplier": self.supplier.pk, "amount": amount},
            format="json",
        )

    def test_what_the_supplier_owes_is_taken_into_the_drawer(self):
        session = self._open_drawer()
        cash_before = self._cash_position()

        response = self._refund("300.00")

        self.assertEqual(response.status_code, status.HTTP_201_CREATED, response.data)
        entry = SupplierBalanceEntry.objects.get(pk=response.data["id"])
        self.assertEqual(entry.kind, Kind.REFUND)
        # The account: settled from the supplier's credit note.
        payment = SupplierPayment.objects.get(balance_entry=entry)
        self.assertEqual(payment.method, SupplierPayment.Method.SUPPLIER_CREDIT)
        self.assertEqual(
            SupplierCredit.objects.get().remaining_amount, Decimal("400.00")
        )
        supplier = Supplier.objects.get(pk=self.supplier.pk)
        self.assertEqual(supplier.payable_balance, Decimal("0.00"))
        self.assertEqual(supplier.net_balance, Decimal("-400.00"))
        # The drawer and the money position both received the cash.
        session.refresh_from_db()
        self.assertEqual(session.pay_in_total, Decimal("300.00"))
        self.assertEqual(self._cash_position(), cash_before + Decimal("300.00"))

    def test_the_statement_closes_on_what_the_supplier_still_owes(self):
        self._open_drawer()
        self._refund("300.00")

        payload = generate_report_payload(
            report_type=ReportRun.ReportType.SUPPLIER_STATEMENT,
            params={
                "supplier_id": self.supplier.pk,
                "start_date": (self.today - timedelta(days=5)).isoformat(),
                "end_date": self.today.isoformat(),
            },
            user=self.manager,
        )

        self.assertEqual(payload["summary"]["closing_balance"], "-400.00")

    def test_no_more_than_is_owed(self):
        self._open_drawer()
        response = self._refund("700.01")
        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertEqual(response.data["code"], "refund_exceeds_credit")

    def test_the_settlement_cannot_be_undone_on_its_own(self):
        self._open_drawer()
        entry_id = self._refund("300.00").data["id"]
        payment = SupplierPayment.objects.get(balance_entry_id=entry_id)

        payment_cancel = self.client.post(
            reverse("supplierpayment-cancel", args=[payment.pk]),
            {"reason": "خطأ"},
            format="json",
        )
        entry_cancel = self.client.post(
            reverse("supplier-balance-entry-cancel", args=[entry_id]),
            {"reason": "خطأ"},
            format="json",
        )

        self.assertEqual(payment_cancel.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertEqual(payment_cancel.data["code"], "refund_is_final")
        self.assertEqual(entry_cancel.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertEqual(
            SupplierCredit.objects.get().remaining_amount, Decimal("400.00")
        )


class DashboardDueTotalTests(_RefundCase):
    def test_what_is_owed_on_a_suppliers_account_is_due(self):
        supplier = Supplier.objects.create(name="مورد")
        create_supplier_entry(
            supplier=supplier,
            kind=Kind.OPENING,
            direction=Direction.WE_OWE_THEM,
            amount=Decimal("450.00"),
            actor=self.manager,
        )
        PurchaseOrder.objects.create(
            supplier=supplier,
            status=PurchaseOrder.Status.RECEIVED,
            subtotal=Decimal("50.00"),
            total=Decimal("50.00"),
        )

        response = self.client.get(reverse("dashboard"))

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        purchasing = response.data["sections"]["purchasing"]["summary"]
        self.assertEqual(purchasing["due_total"], "500.00")
