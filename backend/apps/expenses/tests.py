from decimal import Decimal

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group, Permission
from django.test import TestCase
from django.urls import reverse
from django.utils import timezone
from rest_framework import status
from rest_framework.test import APIClient

from apps.core.roles import (
    CASHIER_GROUP,
    MANAGER_GROUP,
    ensure_role_groups,
)
from apps.employees.models import PayrollRun
from apps.payments.models import Payment
from apps.purchasing.models import PurchaseOrder, Supplier
from apps.reports.models import ReportRun
from apps.reports.services import generate_report_payload
from apps.sales.models import Order, RegisterCashMovement, RegisterSession

from .models import Expense, ExpenseCategory
from .services import create_expense


class ExpensesTestMixin:
    def setUp(self):
        ensure_role_groups()
        User = get_user_model()
        self.cashier = User.objects.create_user(username="exp-cashier", password="pass")
        self.manager = User.objects.create_user(username="exp-manager", password="pass")
        self.limited = User.objects.create_user(username="exp-limited", password="pass")
        self.cashier.groups.add(Group.objects.get(name=CASHIER_GROUP))
        self.manager.groups.add(Group.objects.get(name=MANAGER_GROUP))
        # The limited user can read expenses but nothing else — used to prove the
        # ledger hides sources the caller may not see.
        self.limited.user_permissions.add(
            Permission.objects.get(
                content_type__app_label="expenses",
                codename="view_expense",
            )
        )

        self.cashier_client = APIClient()
        self.cashier_client.force_authenticate(user=self.cashier)
        self.manager_client = APIClient()
        self.manager_client.force_authenticate(user=self.manager)
        self.limited_client = APIClient()
        self.limited_client.force_authenticate(user=self.limited)

        self.category = ExpenseCategory.objects.create(name="اختبار", display_order=99)

    def open_session(self, user, opening_cash=Decimal("100.00")):
        return RegisterSession.objects.create(
            owner_key=f"user:{user.pk}",
            status=RegisterSession.Status.OPEN,
            opening_cash=opening_cash,
        )


class ExpensePermissionTests(ExpensesTestMixin, TestCase):
    def test_cashier_is_denied_expense_access(self):
        self.assertEqual(
            self.cashier_client.get(reverse("expense-list")).status_code,
            status.HTTP_403_FORBIDDEN,
        )
        self.assertEqual(
            self.cashier_client.get(reverse("expense-ledger")).status_code,
            status.HTTP_403_FORBIDDEN,
        )
        create_response = self.cashier_client.post(
            reverse("expense-list"),
            {
                "category": self.category.pk,
                "description": "x",
                "amount": "10.00",
                "payment_method": "cash",
            },
            format="json",
        )
        self.assertEqual(create_response.status_code, status.HTTP_403_FORBIDDEN)

    def test_manager_can_manage_categories(self):
        response = self.manager_client.post(
            reverse("expensecategory-list"),
            {"name": "إيجار المعرض", "display_order": 1},
            format="json",
        )
        self.assertEqual(response.status_code, status.HTTP_201_CREATED)
        self.assertTrue(
            ExpenseCategory.objects.filter(name="إيجار المعرض").exists()
        )

    def test_default_categories_are_seeded(self):
        # The seed migration runs for the test database.
        self.assertTrue(ExpenseCategory.objects.filter(name="إيجار").exists())


class ExpenseCreateTests(ExpensesTestMixin, TestCase):
    def test_standalone_expense_has_no_cash_movement(self):
        response = self.manager_client.post(
            reverse("expense-list"),
            {
                "category": self.category.pk,
                "description": "فاتورة إنترنت",
                "amount": "45.00",
                "payment_method": "transfer",
            },
            format="json",
        )
        self.assertEqual(response.status_code, status.HTTP_201_CREATED)
        self.assertFalse(response.data["paid_from_register"])
        self.assertIsNone(response.data["cash_movement"])
        self.assertEqual(RegisterCashMovement.objects.count(), 0)

    def test_cash_expense_pays_from_open_register(self):
        session = self.open_session(self.manager)
        response = self.manager_client.post(
            reverse("expense-list"),
            {
                "category": self.category.pk,
                "description": "مواد تنظيف",
                "amount": "30.00",
                "payment_method": "cash",
                "pay_from_register": True,
            },
            format="json",
        )
        self.assertEqual(response.status_code, status.HTTP_201_CREATED)
        self.assertTrue(response.data["paid_from_register"])

        movement = RegisterCashMovement.objects.get()
        self.assertEqual(movement.movement_type, RegisterCashMovement.MovementType.PAY_OUT)
        self.assertEqual(movement.amount, Decimal("30.00"))
        self.assertEqual(movement.register_session_id, session.pk)

        session.refresh_from_db()
        # opening 100 - 30 pay-out
        self.assertEqual(session.expected_cash, Decimal("70.00"))

    def test_pay_from_register_ignored_without_open_session(self):
        response = self.manager_client.post(
            reverse("expense-list"),
            {
                "category": self.category.pk,
                "description": "أجرة",
                "amount": "20.00",
                "payment_method": "cash",
                "pay_from_register": True,
            },
            format="json",
        )
        self.assertEqual(response.status_code, status.HTTP_201_CREATED)
        self.assertFalse(response.data["paid_from_register"])
        self.assertEqual(RegisterCashMovement.objects.count(), 0)


class ExpenseLedgerTests(ExpensesTestMixin, TestCase):
    def _seed_all_sources(self):
        today = timezone.localdate()
        session = self.open_session(self.manager)
        # A drawer-paid expense (creates a linked pay-out).
        create_expense(
            user=self.manager,
            pay_from_register=True,
            category=self.category,
            description="كهرباء",
            amount=Decimal("30.00"),
            payment_method=Expense.PaymentMethod.CASH,
        )
        # A standalone pay-out (not an expense) — should show as register_payout.
        RegisterCashMovement.objects.create(
            register_session=session,
            movement_type=RegisterCashMovement.MovementType.PAY_OUT,
            amount=Decimal("15.00"),
            reason="سلفة موظف",
            created_by=self.manager,
        )
        # Paid payroll.
        PayrollRun.objects.create(
            period_start=today.replace(day=1),
            period_end=today,
            status=PayrollRun.Status.PAID,
            payment_date=today,
            net_total=Decimal("500.00"),
        )
        # A purchase order.
        supplier = Supplier.objects.create(name="المورد")
        PurchaseOrder.objects.create(
            supplier=supplier,
            status=PurchaseOrder.Status.SUBMITTED,
            total=Decimal("200.00"),
        )
        # A card payment with commission.
        order = Order.objects.create(status=Order.Status.PAID, total=Decimal("100.00"))
        Payment.objects.create(
            order=order,
            method=Payment.Method.CARD,
            amount=Decimal("100.00"),
            commission_amount=Decimal("3.00"),
        )

    def test_ledger_unions_sources_without_double_counting(self):
        self._seed_all_sources()
        response = self.manager_client.get(reverse("expense-ledger"))
        self.assertEqual(response.status_code, status.HTTP_200_OK)
        data = response.data

        self.assertEqual(data["totals"]["expense"], "30.00")
        self.assertEqual(data["totals"]["register_payout"], "15.00")
        self.assertEqual(data["totals"]["payroll"], "500.00")
        self.assertEqual(data["totals"]["purchase"], "200.00")
        self.assertEqual(data["totals"]["commission"], "3.00")
        self.assertEqual(data["summary"]["total"], "748.00")

        payout_rows = [r for r in data["rows"] if r["source"] == "register_payout"]
        self.assertEqual(len(payout_rows), 1)
        # The drawer-paid expense's pay-out (30) must NOT reappear as a pay-out.
        self.assertEqual(payout_rows[0]["amount"], "15.00")

    def test_ledger_hides_sources_the_caller_cannot_see(self):
        self._seed_all_sources()
        response = self.limited_client.get(reverse("expense-ledger"))
        self.assertEqual(response.status_code, status.HTTP_200_OK)
        data = response.data

        sources = {row["source"] for row in data["rows"]}
        self.assertEqual(sources, {"expense"})
        self.assertEqual(data["totals"]["payroll"], "0.00")
        self.assertEqual(data["totals"]["purchase"], "0.00")
        self.assertEqual(data["totals"]["commission"], "0.00")
        self.assertEqual(data["totals"]["register_payout"], "0.00")
        self.assertEqual(data["summary"]["total"], "30.00")

    def test_ledger_filters_by_source(self):
        self._seed_all_sources()
        response = self.manager_client.get(
            reverse("expense-ledger"), {"source": "payroll"}
        )
        self.assertEqual(response.status_code, status.HTTP_200_OK)
        sources = {row["source"] for row in response.data["rows"]}
        self.assertEqual(sources, {"payroll"})


class ExpenseReportingTests(ExpensesTestMixin, TestCase):
    def test_dashboard_includes_ad_hoc_expense_total(self):
        Expense.objects.create(
            category=self.category,
            description="صيانة",
            amount=Decimal("80.00"),
            payment_method=Expense.PaymentMethod.TRANSFER,
            spent_at=timezone.localdate(),
        )
        response = self.manager_client.get(reverse("dashboard"))
        self.assertEqual(response.status_code, status.HTTP_200_OK)
        summary = response.data["sections"]["profitability"]["summary"]
        self.assertEqual(summary["ad_hoc_expense_total"], "80.00")
        self.assertIn("operating_expense_total", summary)

    def test_profit_costs_report_includes_ad_hoc_expense(self):
        Expense.objects.create(
            category=self.category,
            description="تسويق",
            amount=Decimal("60.00"),
            payment_method=Expense.PaymentMethod.CARD,
            spent_at=timezone.localdate(),
        )
        payload = generate_report_payload(
            report_type=ReportRun.ReportType.PROFIT_COSTS,
            params={},
            user=self.manager,
        )
        self.assertEqual(payload["summary"]["ad_hoc_expense_total"], "60.00")
