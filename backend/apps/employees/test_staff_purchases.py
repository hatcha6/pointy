"""Staff purchases: an employee buys on their own account, payroll takes it back.

End to end where it matters — the account is made when the user is, the till
rings the sale up on آجل against it, and the payroll run is drafted, approved,
paid and voided through the same services the API calls — because the feature
is the chain, and each link has already been seen to hold alone.
"""

from datetime import date
from decimal import Decimal
from importlib import import_module

from django.apps import apps as django_apps
from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group
from django.test import TestCase
from django.urls import reverse
from django.utils import timezone
from rest_framework import serializers, status
from rest_framework.test import APIClient

from apps.catalog.testing import create_product_with_default_variant
from apps.core.models import ShopSettings
from apps.core.roles import CASHIER_GROUP, MANAGER_GROUP, ensure_role_groups
from apps.customers.models import Customer
from apps.documents.statuses import DocumentStatus
from apps.inventory.models import StockItem
from apps.payments.models import Payment
from apps.payments.services import cancel_payment
from apps.sales.models import Order, RegisterSession
from apps.sales.services import return_order_items

from .models import CompensationPlan, Employee, PayrollAdjustment, PayrollRun
from .reporting import payroll_cost, wages_payable
from .services import (
    approve_payroll_run,
    draft_monthly_payroll_run,
    mark_payroll_run_paid,
    void_payroll_run,
)
from .staff_purchases import ensure_staff_customer

JUNE = (date(2026, 6, 1), date(2026, 6, 30))
JULY = (date(2026, 7, 1), date(2026, 7, 31))


def _staff_purchases(run):
    return PayrollAdjustment.objects.filter(
        payroll_line__payroll_run=run,
        adjustment_type=PayrollAdjustment.AdjustmentType.STAFF_PURCHASE,
    ).order_by("id")


class StaffAccountTests(TestCase):
    """Every member of staff has an account to buy on, without anyone making it."""

    def setUp(self):
        ensure_role_groups()
        ShopSettings.load()
        User = get_user_model()
        self.manager = User.objects.create_user(username="owner", password="pass")
        self.manager.groups.add(Group.objects.get(name=MANAGER_GROUP))
        self.client = APIClient()
        self.client.force_authenticate(user=self.manager)

    def test_creating_a_user_makes_their_employee_and_their_staff_account(self):
        response = self.client.post(
            reverse("pos-user-list"),
            {
                "username": "salma",
                "password": "a-long-pass",
                "first_name": "سلمى",
                "role": "cashier",
            },
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_201_CREATED, response.data)
        employee = Employee.objects.get(user__username="salma")
        self.assertIsNotNone(employee.customer)
        self.assertEqual(employee.customer.full_name, "سلمى")
        self.assertFalse(employee.customer.is_auto_created)

    def test_an_employee_made_by_hand_gets_a_staff_account_too(self):
        response = self.client.post(
            reverse("employee-list"),
            {"full_name": "فني بلا حساب", "phone": "0910000000"},
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_201_CREATED, response.data)
        employee = Employee.objects.get(pk=response.data["id"])
        self.assertEqual(employee.customer.full_name, "فني بلا حساب")
        self.assertEqual(employee.customer.phone, "0910000000")
        self.assertEqual(response.data["customer"], employee.customer_id)

    def test_the_till_finds_the_cashiers_own_account(self):
        cashier = get_user_model().objects.create_user(username="till", password="p")
        cashier.groups.add(Group.objects.get(name=CASHIER_GROUP))
        client = APIClient()
        client.force_authenticate(user=cashier)
        # Customer look-up switched off for cashiers: "me" still works, because
        # it reads nobody else's record.
        ShopSettings.objects.filter(pk=1).update(allow_cashier_customer_access=False)

        first = client.get(reverse("customer-staff-account"))
        second = client.get(reverse("customer-staff-account"))

        self.assertEqual(first.status_code, status.HTTP_200_OK, first.data)
        self.assertEqual(first.data["id"], second.data["id"])
        employee = Employee.objects.get(user=cashier)
        self.assertEqual(first.data["id"], employee.customer_id)
        self.assertEqual(first.data["staff_employee"], employee.pk)

    def test_the_customer_list_says_which_accounts_are_staff(self):
        staff = Employee.objects.create(full_name="موظف")
        ensure_staff_customer(staff)
        Customer.objects.create(full_name="زبون")

        rows = self.client.get(reverse("customer-list")).data["results"]

        by_name = {row["full_name"]: row["staff_employee"] for row in rows}
        self.assertEqual(by_name["موظف"], staff.pk)
        self.assertIsNone(by_name["زبون"])

    def test_merging_a_staff_account_away_keeps_the_employee_on_the_survivor(self):
        staff = Employee.objects.create(full_name="موظف")
        account = ensure_staff_customer(staff)
        duplicate = Customer.objects.create(full_name="موظف (قديم)")

        response = self.client.post(
            reverse("customer-merge", args=[duplicate.pk]),
            {"source_id": account.pk},
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK, response.data)
        staff.refresh_from_db()
        self.assertEqual(staff.customer_id, duplicate.pk)

    def test_two_employees_accounts_cannot_be_merged(self):
        first = ensure_staff_customer(Employee.objects.create(full_name="الأول"))
        second = ensure_staff_customer(Employee.objects.create(full_name="الثاني"))

        response = self.client.post(
            reverse("customer-merge", args=[first.pk]),
            {"source_id": second.pk},
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertTrue(Customer.objects.filter(pk=second.pk).exists())

    def test_the_upgrade_gives_current_staff_an_account(self):
        backfill = import_module(
            "apps.employees.migrations.0014_backfill_staff_customers"
        ).backfill
        active = Employee.objects.create(full_name="على رأس العمل")
        gone = Employee.objects.create(
            full_name="غادر",
            status=Employee.Status.TERMINATED,
            termination_date=date(2026, 1, 1),
        )

        # Logins older than automatic employee creation have no employee row.
        User = get_user_model()
        old_till = User.objects.create_user(
            username="till1", password="p", first_name="سالم"
        )
        disabled = User.objects.create_user(
            username="left", password="p", is_active=False
        )

        backfill(django_apps, None)

        active.refresh_from_db()
        gone.refresh_from_db()
        self.assertEqual(active.customer.full_name, "على رأس العمل")
        self.assertTrue(active.customer.customer_number.startswith("C"))
        self.assertIsNone(gone.customer_id)
        # The old login got the employee it never had, and an account with it.
        till_employee = Employee.objects.get(user=old_till)
        self.assertEqual(till_employee.full_name, "سالم")
        self.assertTrue(till_employee.employee_number.startswith("E"))
        self.assertEqual(till_employee.customer.full_name, "سالم")
        # The owner's own login is staff too.
        self.assertIsNotNone(Employee.objects.get(user=self.manager).customer_id)
        # A disabled login is not on the payroll.
        self.assertFalse(Employee.objects.filter(user=disabled).exists())


class StaffPurchasePayrollTests(TestCase):
    """A cashier on 1000/month buys on their staff account; payroll takes it."""

    def setUp(self):
        ensure_role_groups()
        ShopSettings.load()
        User = get_user_model()
        self.cashier = User.objects.create_user(username="cashier", password="p")
        self.cashier.groups.add(Group.objects.get(name=CASHIER_GROUP))
        self.client = APIClient()
        self.client.force_authenticate(user=self.cashier)
        self.client.post(
            reverse("register-session-start"), {"opening_cash": "0.00"}, format="json"
        )
        self.account = self.client.get(reverse("customer-staff-account")).data
        self.employee = Employee.objects.get(user=self.cashier)
        self.plan = CompensationPlan.objects.create(
            employee=self.employee,
            pay_type=CompensationPlan.PayType.MONTHLY_SALARY,
            salary_type=CompensationPlan.SalaryType.MONTHLY_FIXED,
            amount=Decimal("1000.00"),
            effective_from=date(2026, 1, 1),
        )
        product = create_product_with_default_variant(
            sku="KETTLE", barcode="", name="Kettle", unit_price=Decimal("50.00")
        )
        self.variant = product.default_variant
        StockItem.objects.create(variant=self.variant, quantity_on_hand=500)

    def _buy(self, quantity, **overrides):
        payload = {
            "lines": [{"variant": self.variant.pk, "quantity": quantity}],
            "sale_type": "credit",
            "customer": self.account["id"],
            "payments": [],
        }
        payload.update(overrides)
        response = self.client.post(reverse("order-checkout"), payload, format="json")
        self.assertEqual(response.status_code, status.HTTP_201_CREATED, response.data)
        return Order.objects.get(pk=response.data["id"])

    def _draft(self, period=JUNE):
        run, _created = draft_monthly_payroll_run(
            period_start=period[0], period_end=period[1]
        )
        return run

    def test_the_next_run_deducts_what_the_employee_bought(self):
        first = self._buy(2)
        second = self._buy(1)

        run = self._draft()

        deductions = list(_staff_purchases(run))
        self.assertEqual(
            [(row.order_id, row.amount) for row in deductions],
            [(first.pk, Decimal("100.00")), (second.pk, Decimal("50.00"))],
        )
        line = run.lines.get()
        self.assertEqual(line.gross_amount, Decimal("1000.00"))
        self.assertEqual(line.net_amount, Decimal("850.00"))
        self.assertEqual(run.net_total, Decimal("850.00"))
        payload = self._api_run(run)
        rows = payload["lines"][0]["adjustments"]
        self.assertEqual(
            [row["order_receipt_number"] for row in rows],
            [first.receipt_number, second.receipt_number],
        )

    def test_paying_the_run_settles_the_invoices_without_touching_the_drawer(self):
        invoice = self._buy(2)
        run = approve_payroll_run(self._draft())

        run = mark_payroll_run_paid(run)

        invoice.refresh_from_db()
        self.assertEqual(invoice.status, Order.Status.PAID)
        self.assertEqual(invoice.balance_due, Decimal("0.00"))
        settlement = Payment.objects.get(order=invoice)
        self.assertEqual(settlement.method, Payment.Method.SALARY_DEDUCTION)
        self.assertEqual(settlement.amount, Decimal("100.00"))
        self.assertIsNone(settlement.register_session_id)
        self.assertEqual(settlement.external_reference, f"payroll:{run.run_number}")
        self.assertEqual(_staff_purchases(run).get().settlement_payment, settlement)
        self.assertEqual(run.net_total, Decimal("900.00"))
        session = RegisterSession.objects.get(owner=self.cashier)
        self.assertEqual(session.cash_sales_total, Decimal("0.00"))
        self.assertFalse(Payment.objects.money_received().filter(order=invoice).exists())

    def test_what_the_pay_cannot_cover_waits_for_the_next_run(self):
        older = self._buy(15)  # 750
        newer = self._buy(8)  # 400

        june = mark_payroll_run_paid(approve_payroll_run(self._draft()))

        self.assertEqual(
            [(row.order_id, row.amount) for row in _staff_purchases(june)],
            [(older.pk, Decimal("750.00")), (newer.pk, Decimal("250.00"))],
        )
        self.assertEqual(june.net_total, Decimal("0.00"))
        newer.refresh_from_db()
        self.assertEqual(newer.status, Order.Status.OPEN)
        self.assertEqual(newer.balance_due, Decimal("150.00"))

        july = self._draft(JULY)
        self.assertEqual(
            [(row.order_id, row.amount) for row in _staff_purchases(july)],
            [(newer.pk, Decimal("150.00"))],
        )

    def test_approving_takes_what_is_owed_then_not_when_drafted(self):
        paid_since = self._buy(2)
        run = self._draft()
        # Settled at the till after the draft, and a new purchase after it.
        paid_since.payments.create(
            method=Payment.Method.CASH,
            amount=Decimal("100.00"),
            register_session=RegisterSession.objects.get(owner=self.cashier),
        )
        from apps.sales import documents as sales_documents

        sales_documents.recompute_progress(paid_since)
        bought_since = self._buy(1)

        run = approve_payroll_run(run)

        self.assertEqual(
            [(row.order_id, row.amount) for row in _staff_purchases(run)],
            [(bought_since.pk, Decimal("50.00"))],
        )
        self.assertEqual(run.net_total, Decimal("950.00"))

    def test_an_invoice_paid_off_after_approval_is_not_taken_from_wages(self):
        invoice = self._buy(2)
        run = approve_payroll_run(self._draft())
        invoice.payments.create(
            method=Payment.Method.CASH,
            amount=Decimal("100.00"),
            register_session=RegisterSession.objects.get(owner=self.cashier),
        )

        run = mark_payroll_run_paid(run)

        self.assertFalse(_staff_purchases(run).exists())
        self.assertEqual(run.net_total, Decimal("1000.00"))
        self.assertFalse(
            Payment.objects.filter(method=Payment.Method.SALARY_DEDUCTION).exists()
        )

    def test_two_open_runs_never_take_the_same_invoice(self):
        self._buy(2)
        june = self._draft()
        july = self._draft(JULY)

        self.assertEqual(_staff_purchases(june).get().amount, Decimal("100.00"))
        self.assertFalse(_staff_purchases(july).exists())

    def test_an_absence_shrinks_the_purchases_instead_of_failing(self):
        self._buy(20)  # 1000: the whole wage
        run = self._draft()
        line = run.lines.get()
        manager = get_user_model().objects.create_user(username="boss", password="p")
        manager.groups.add(Group.objects.get(name=MANAGER_GROUP))
        client = APIClient()
        client.force_authenticate(user=manager)

        response = client.patch(
            reverse("payroll-run-update-line-adjustments", args=[run.pk, line.pk]),
            {"absence_days": "3.00"},
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK, response.data)
        line.refresh_from_db()
        self.assertEqual(line.absence_deduction_amount, Decimal("99.99"))
        self.assertEqual(line.net_amount, Decimal("0.00"))
        self.assertEqual(_staff_purchases(run).get().amount, Decimal("900.01"))

    def test_staff_purchases_cannot_be_typed_in_by_hand(self):
        run = self._draft()
        manager = get_user_model().objects.create_user(username="boss", password="p")
        manager.groups.add(Group.objects.get(name=MANAGER_GROUP))
        client = APIClient()
        client.force_authenticate(user=manager)

        response = client.post(
            reverse("payroll-run-bulk-adjustments", args=[run.pk]),
            {
                "line_ids": [run.lines.get().pk],
                "direction": "deduction",
                "adjustment_type": "staff_purchase",
                "amount": "10.00",
            },
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)

    def test_voiding_a_paid_run_makes_the_invoices_owed_again(self):
        invoice = self._buy(2)
        run = mark_payroll_run_paid(approve_payroll_run(self._draft()))
        settlement = _staff_purchases(run).get().settlement_payment

        void_payroll_run(run)

        settlement.refresh_from_db()
        self.assertEqual(settlement.doc_status, DocumentStatus.CANCELLED)
        invoice.refresh_from_db()
        self.assertEqual(invoice.status, Order.Status.OPEN)
        self.assertEqual(invoice.balance_due, Decimal("100.00"))
        july = self._draft(JULY)
        self.assertEqual(_staff_purchases(july).get().order_id, invoice.pk)

    def test_a_salary_deduction_is_not_cancelled_on_its_own(self):
        invoice = self._buy(2)
        mark_payroll_run_paid(approve_payroll_run(self._draft()))

        with self.assertRaises(serializers.ValidationError) as caught:
            cancel_payment(Payment.objects.get(order=invoice), reason="oops")

        self.assertEqual(
            caught.exception.detail["code"], "salary_deduction_owned_by_payroll"
        )

    def test_returning_a_payroll_settled_purchase_refunds_cash(self):
        invoice = self._buy(2)
        run = mark_payroll_run_paid(approve_payroll_run(self._draft()))
        line = invoice.lines.get()

        adjustment = return_order_items(
            order=invoice,
            lines=[(line, Decimal("1"))],
            reason="changed mind",
            register_session=RegisterSession.objects.get(owner=self.cashier),
        )

        self.assertEqual(adjustment.refund_method, Payment.Method.CASH)
        self.assertEqual(adjustment.cash_amount, Decimal("50.00"))
        refund = Payment.objects.get(order=invoice, amount__lt=0)
        self.assertEqual(refund.method, Payment.Method.CASH)
        # And the run that settled it can no longer be retracted: the goods came
        # back and the refund was already handed over.
        with self.assertRaises(serializers.ValidationError) as caught:
            void_payroll_run(run)
        self.assertEqual(caught.exception.detail["code"], "staff_purchase_returned")
        run.refresh_from_db()
        self.assertEqual(run.status, PayrollRun.Status.PAID)

    def test_a_till_cannot_tender_a_salary_deduction(self):
        response = self.client.post(
            reverse("order-checkout"),
            {
                "lines": [{"variant": self.variant.pk, "quantity": 1}],
                "customer": self.account["id"],
                "payments": [{"method": "salary_deduction", "amount": "50.00"}],
            },
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)

    def test_sales_commission_ignores_the_cashiers_own_shopping(self):
        self.plan.salary_type = (
            CompensationPlan.SalaryType.MONTHLY_FIXED_PLUS_SALES_COMMISSION
        )
        self.plan.commission_percent = Decimal("10.00")
        self.plan.save()
        self._buy(2)  # 100 to themselves
        response = self.client.post(
            reverse("order-checkout"),
            {
                "lines": [{"variant": self.variant.pk, "quantity": 1}],
                "amount_received": "50.00",
            },
            format="json",
        )
        self.assertEqual(response.status_code, status.HTTP_201_CREATED, response.data)
        today = timezone.localdate()
        this_month = (today.replace(day=1), today)

        run = self._draft(this_month)

        commission = run.lines.get().adjustments.get(
            adjustment_type=PayrollAdjustment.AdjustmentType.COMMISSION
        )
        self.assertEqual(commission.amount, Decimal("5.00"))

    def test_labour_cost_counts_the_whole_wage(self):
        self._buy(2)
        mark_payroll_run_paid(approve_payroll_run(self._draft()))

        self.assertEqual(payroll_cost(*JUNE), Decimal("1000.00"))

    def test_wages_owed_stay_whole_until_the_run_that_settles_them_is_paid(self):
        """An approved run keeps 100.00 back for the kettles, but the invoice
        is still a receivable until pay day — so the balance sheet owes the
        staff the whole 1000.00, or the 100.00 would vanish from both sides."""
        self._buy(2)
        run = approve_payroll_run(self._draft())
        today = timezone.localdate()

        self.assertEqual(run.net_total, Decimal("900.00"))
        self.assertEqual(wages_payable(today), Decimal("1000.00"))

        mark_payroll_run_paid(run)
        self.assertEqual(wages_payable(today), Decimal("0.00"))

    def _api_run(self, run):
        manager = get_user_model().objects.create_user(
            username=f"viewer-{run.pk}", password="p"
        )
        manager.groups.add(Group.objects.get(name=MANAGER_GROUP))
        client = APIClient()
        client.force_authenticate(user=manager)
        return client.get(reverse("payroll-run-detail", args=[run.pk])).data
