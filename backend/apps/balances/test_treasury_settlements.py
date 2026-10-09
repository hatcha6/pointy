"""An account settled through the treasury rather than a drawer.

«استلام مبلغ» and «دفع مبلغ» on a customer's, supplier's or employee's account
move real money, and that money does not always pass a cashier's drawer: the
owner pays a supplier out of the cash box, or a customer's credit back by bank
transfer. Whoever may see the treasury may choose it; everyone else settles
through their own drawer, exactly as before. Either way the money position has
to see the money once — never twice, never not at all.
"""

from decimal import Decimal

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group, Permission
from django.urls import reverse
from django.utils import timezone
from rest_framework import status
from rest_framework.test import APIClient, APITestCase

from apps.core.models import ShopSettings
from apps.core.roles import CASHIER_GROUP, MANAGER_GROUP, ensure_role_groups
from apps.customers.models import Customer
from apps.employees.models import Employee
from apps.payments.models import Payment
from apps.purchasing.models import Supplier, SupplierPayment
from apps.sales.models import RegisterCashMovement, RegisterSession
from apps.treasury.models import MoneyAccount
from apps.treasury.movements import account_movements
from apps.treasury.position import routed_account, treasury_position

from .customers import create_customer_entry
from .employees import create_employee_entry
from .models import (
    BalanceEntry,
    CustomerBalanceEntry,
    EmployeeBalanceEntry,
    SupplierBalanceEntry,
)
from .suppliers import create_supplier_entry

Kind = BalanceEntry.Kind
Direction = BalanceEntry.Direction


class _TreasuryCase(APITestCase):
    def setUp(self):
        ensure_role_groups()
        ShopSettings.load()
        self.manager = self._user("treasury-owner", MANAGER_GROUP)
        self.client = APIClient()
        self.client.force_authenticate(self.manager)

    def _user(self, username, group):
        user = get_user_model().objects.create_user(username=username, password="p")
        user.groups.add(Group.objects.get(name=group))
        return user

    def _open_drawer(self, client=None):
        client = client or self.client
        client.post(
            reverse("register-session-start"), {"opening_cash": "500.00"}, format="json"
        )
        return RegisterSession.objects.filter(status=RegisterSession.Status.OPEN).last()

    def _totals(self):
        return treasury_position()["totals"]


class CustomerTreasuryTests(_TreasuryCase):
    def setUp(self):
        super().setUp()
        self.customer = Customer.objects.create(full_name="زبون")

    def _owed_to_customer(self, amount):
        create_customer_entry(
            customer=self.customer,
            kind=Kind.OPENING,
            direction=Direction.WE_OWE_THEM,
            amount=Decimal(amount),
            actor=self.manager,
        )

    def _refund(self, client=None, **data):
        return (client or self.client).post(
            reverse("customer-balance-entry-refund"),
            {"customer": self.customer.pk, **data},
            format="json",
        )

    def test_credit_is_paid_from_the_cash_box_with_no_drawer_open(self):
        self._owed_to_customer("300.00")
        cash_before = self._totals()["cash"]

        response = self._refund(amount="120.00", source="treasury")

        self.assertEqual(response.status_code, status.HTTP_201_CREATED, response.data)
        self.assertEqual(response.data["settled_through"], "cash_box")
        entry = CustomerBalanceEntry.objects.get(pk=response.data["id"])
        self.assertIsNone(entry.cash_movement)
        self.assertEqual(entry.money_account.kind, MoneyAccount.Kind.CASH)
        self.assertFalse(RegisterCashMovement.objects.exists())
        self.assertEqual(self._totals()["cash"], cash_before - Decimal("120.00"))

    def test_credit_is_paid_by_transfer_from_the_bank(self):
        self._owed_to_customer("300.00")
        totals_before = self._totals()

        response = self._refund(amount="80.00", method="transfer", source="treasury")

        self.assertEqual(response.status_code, status.HTTP_201_CREATED, response.data)
        self.assertEqual(response.data["settled_through"], "bank")
        totals = self._totals()
        self.assertEqual(totals["bank"], totals_before["bank"] - Decimal("80.00"))
        self.assertEqual(totals["cash"], totals_before["cash"])

    def test_the_treasury_drill_down_names_the_payout(self):
        self._owed_to_customer("300.00")
        self._refund(amount="120.00", source="treasury")
        today = timezone.localdate()

        rows = account_movements(
            routed_account(MoneyAccount.Kind.CASH), start=today, end=today
        )["rows"]

        payout = next(row for row in rows if row["source"] == "account_payouts")
        self.assertEqual(payout["amount"], Decimal("-120.00"))
        self.assertEqual(payout["description"], str(self.customer))

    def test_a_cashier_cannot_reach_the_treasury(self):
        self._owed_to_customer("300.00")
        cashier = APIClient()
        cashier_user = self._user("till", CASHIER_GROUP)
        cashier_user.user_permissions.add(
            *Permission.objects.filter(codename="add_customerbalanceentry")
        )
        cashier.force_authenticate(cashier_user)

        response = self._refund(client=cashier, amount="50.00", source="treasury")

        self.assertEqual(response.status_code, status.HTTP_403_FORBIDDEN)
        self.assertFalse(CustomerBalanceEntry.objects.filter(kind=Kind.REFUND).exists())

    def test_a_collection_goes_straight_into_the_cash_box(self):
        create_customer_entry(
            customer=self.customer,
            kind=Kind.OPENING,
            direction=Direction.THEY_OWE_US,
            amount=Decimal("200.00"),
            actor=self.manager,
        )
        cash_before = self._totals()["cash"]

        response = self.client.post(
            reverse("customer-record-payment", args=[self.customer.pk]),
            {"method": "cash", "amount": "150.00", "source": "treasury"},
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK, response.data)
        payment = Payment.objects.get(method=Payment.Method.CASH)
        self.assertIsNone(payment.register_session_id)
        self.assertEqual(self._totals()["cash"], cash_before + Decimal("150.00"))

    def test_a_collection_still_refuses_more_than_is_owed(self):
        create_customer_entry(
            customer=self.customer,
            kind=Kind.OPENING,
            direction=Direction.THEY_OWE_US,
            amount=Decimal("200.00"),
            actor=self.manager,
        )

        response = self.client.post(
            reverse("customer-record-payment", args=[self.customer.pk]),
            {"method": "cash", "amount": "250.00", "source": "treasury"},
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertFalse(Payment.objects.exists())

    def test_without_the_treasury_a_collection_still_needs_a_drawer(self):
        response = self.client.post(
            reverse("customer-record-payment", args=[self.customer.pk]),
            {"method": "cash", "amount": "10.00"},
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)


class SupplierTreasuryTests(_TreasuryCase):
    def setUp(self):
        super().setUp()
        self.supplier = Supplier.objects.create(name="مورد")

    def test_what_the_supplier_owes_comes_into_the_cash_box(self):
        create_supplier_entry(
            supplier=self.supplier,
            kind=Kind.OPENING,
            direction=Direction.THEY_OWE_US,
            amount=Decimal("700.00"),
            actor=self.manager,
        )
        cash_before = self._totals()["cash"]

        response = self.client.post(
            reverse("supplier-balance-entry-refund"),
            {"supplier": self.supplier.pk, "amount": "300.00", "source": "treasury"},
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_201_CREATED, response.data)
        entry = SupplierBalanceEntry.objects.get(pk=response.data["id"])
        self.assertIsNone(entry.cash_movement)
        self.assertEqual(self._totals()["cash"], cash_before + Decimal("300.00"))

    def test_an_account_payment_can_leave_the_drawer(self):
        create_supplier_entry(
            supplier=self.supplier,
            kind=Kind.OPENING,
            direction=Direction.WE_OWE_THEM,
            amount=Decimal("400.00"),
            actor=self.manager,
        )
        session = self._open_drawer()
        cash_before = self._totals()["cash"]

        response = self.client.post(
            reverse("supplier-record-payment", args=[self.supplier.pk]),
            {"method": "cash", "amount": "250.00", "source": "drawer"},
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_201_CREATED, response.data)
        payment = SupplierPayment.objects.get()
        self.assertEqual(payment.register_session_id, session.pk)
        self.assertEqual(payment.cash_movement.amount, Decimal("250.00"))
        session.refresh_from_db()
        self.assertEqual(session.pay_out_total, Decimal("250.00"))
        # Once: as the supplier payment, not again as a drawer pay-out.
        self.assertEqual(self._totals()["cash"], cash_before - Decimal("250.00"))

    def test_an_account_payment_still_defaults_to_the_cash_box(self):
        create_supplier_entry(
            supplier=self.supplier,
            kind=Kind.OPENING,
            direction=Direction.WE_OWE_THEM,
            amount=Decimal("400.00"),
            actor=self.manager,
        )

        response = self.client.post(
            reverse("supplier-record-payment", args=[self.supplier.pk]),
            {"method": "cash", "amount": "100.00"},
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_201_CREATED, response.data)
        payment = SupplierPayment.objects.get()
        self.assertIsNone(payment.cash_movement)


class EmployeeTreasuryTests(_TreasuryCase):
    def test_dues_are_paid_from_the_cash_box(self):
        employee = Employee.objects.create(full_name="سالم")
        create_employee_entry(
            employee=employee,
            kind=Kind.ADJUSTMENT,
            direction=Direction.WE_OWE_THEM,
            amount=Decimal("90.00"),
            note="مستحقات",
            actor=self.manager,
        )
        cash_before = self._totals()["cash"]

        response = self.client.post(
            reverse("employee-balance-entry-refund"),
            {
                "employee": employee.pk,
                "amount": "90.00",
                "settles": Direction.WE_OWE_THEM,
                "source": "treasury",
            },
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_201_CREATED, response.data)
        entry = EmployeeBalanceEntry.objects.get(pk=response.data["id"])
        self.assertIsNone(entry.cash_movement)
        self.assertEqual(self._totals()["cash"], cash_before - Decimal("90.00"))
