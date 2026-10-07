from decimal import Decimal

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group, Permission
from django.db import connection
from django.test import TestCase
from django.test.utils import CaptureQueriesContext
from django.urls import reverse
from django.utils import timezone
from django.utils.dateparse import parse_datetime
from rest_framework import status
from rest_framework.test import APIClient

from apps.documents.statuses import DocumentStatus
from apps.core.roles import (
    CASHIER_GROUP,
    MANAGER_GROUP,
    ensure_role_groups,
)
from apps.employees.models import PayrollRun
from apps.payments.models import Payment
from apps.purchasing.models import (
    PurchaseOrder,
    PurchaseOrderAuditEvent,
    Supplier,
    SupplierPayment,
)
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


class ExpenseLedgerAttributionTests(ExpensesTestMixin, TestCase):
    """Every row says who put the money out, when, and what it came from — the
    shift a drawer pay-out left, the order a purchase is — so the expenses
    screen can name them and open them."""

    def _rows(self):
        response = self.manager_client.get(reverse("expense-ledger"))
        self.assertEqual(response.status_code, status.HTTP_200_OK)
        return response.data["rows"]

    def _only(self, source):
        rows = [row for row in self._rows() if row["source"] == source]
        self.assertEqual(len(rows), 1, rows)
        return rows[0]

    def test_a_drawer_paid_expense_names_its_recorder_time_and_shift(self):
        self.manager.first_name = "سالم"
        self.manager.last_name = "الورفلي"
        self.manager.save()
        session = self.open_session(self.manager)
        expense = create_expense(
            user=self.manager,
            pay_from_register=True,
            category=self.category,
            description="كهرباء",
            amount=Decimal("30.00"),
            payment_method=Expense.PaymentMethod.CASH,
        )

        row = self._only("expense")

        self.assertEqual(row["recorded_by"], self.manager.pk)
        self.assertEqual(row["recorded_by_name"], "سالم الورفلي")
        self.assertEqual(parse_datetime(row["recorded_at"]), expense.created_at)
        self.assertEqual(row["register_session"], session.pk)
        self.assertEqual(row["register_session_number"], session.session_number)

    def test_an_expense_paid_by_bank_names_no_shift(self):
        create_expense(
            user=self.manager,
            category=self.category,
            description="إيجار",
            amount=Decimal("900.00"),
            payment_method=Expense.PaymentMethod.TRANSFER,
        )

        row = self._only("expense")

        self.assertIsNone(row["register_session"])
        self.assertEqual(row["register_session_number"], "")
        self.assertEqual(row["recorded_by"], self.manager.pk)

    def test_a_till_pay_out_names_the_cashier_and_the_shift(self):
        session = self.open_session(self.cashier)
        movement = RegisterCashMovement.objects.create(
            register_session=session,
            movement_type=RegisterCashMovement.MovementType.PAY_OUT,
            amount=Decimal("15.00"),
            reason="أكياس",
            created_by=self.cashier,
        )

        row = self._only("register_payout")

        # No full name on the account: the username stands in for it.
        self.assertEqual(row["recorded_by_name"], "exp-cashier")
        self.assertEqual(row["recorded_by"], self.cashier.pk)
        self.assertEqual(parse_datetime(row["recorded_at"]), movement.created_at)
        self.assertEqual(row["register_session"], session.pk)
        # The movement stays the row's own id; the shift is beside it.
        self.assertEqual(row["related_id"], movement.pk)

    def test_a_purchase_names_who_opened_it_and_the_drawer_that_paid(self):
        supplier = Supplier.objects.create(name="المورد")
        order = PurchaseOrder.objects.create(
            supplier=supplier,
            status=PurchaseOrder.Status.SUBMITTED,
            total=Decimal("200.00"),
        )
        PurchaseOrderAuditEvent.objects.create(
            purchase_order=order,
            order_number=order.order_number,
            action=PurchaseOrderAuditEvent.Action.CREATED,
            created_by=self.cashier,
        )
        session = self.open_session(self.cashier)
        SupplierPayment.objects.create(
            supplier=supplier,
            purchase_order=order,
            amount=Decimal("200.00"),
            method=SupplierPayment.Method.CASH,
            register_session=session,
            created_by=self.cashier,
        )

        row = self._only("purchase")

        self.assertEqual(row["related_id"], order.pk)
        self.assertEqual(row["document_number"], order.order_number)
        self.assertEqual(row["recorded_by"], self.cashier.pk)
        self.assertEqual(row["register_session"], session.pk)

    def test_a_purchase_without_an_audit_trail_falls_back_to_its_submitter(self):
        supplier = Supplier.objects.create(name="المورد")
        PurchaseOrder.objects.create(
            supplier=supplier,
            status=PurchaseOrder.Status.SUBMITTED,
            total=Decimal("80.00"),
            submitted_by=self.manager,
        )

        row = self._only("purchase")

        self.assertEqual(row["recorded_by"], self.manager.pk)
        self.assertIsNone(row["register_session"])

    def test_payroll_names_who_paid_it(self):
        today = timezone.localdate()
        paid_at = timezone.now()
        run = PayrollRun.objects.create(
            period_start=today.replace(day=1),
            period_end=today,
            status=PayrollRun.Status.PAID,
            payment_date=today,
            net_total=Decimal("500.00"),
            paid_by=self.manager,
            paid_at=paid_at,
        )

        row = self._only("payroll")

        self.assertEqual(row["related_id"], run.pk)
        self.assertEqual(row["recorded_by"], self.manager.pk)
        self.assertEqual(parse_datetime(row["recorded_at"]), paid_at)
        self.assertEqual(row["document_number"], run.run_number)

    def test_naming_recorders_costs_no_query_per_row(self):
        # A different recorder on every row: a page by one person hides an N+1.
        User = get_user_model()
        supplier = Supplier.objects.create(name="المورد")

        def seed(count):
            for _ in range(count):
                person = User.objects.create_user(
                    username=f"exp-person-{User.objects.count()}", password="pass"
                )
                session = self.open_session(person)
                Expense.objects.create(
                    category=self.category,
                    description="قرطاسية",
                    amount=Decimal("5.00"),
                    created_by=person,
                    register_session=session,
                )
                RegisterCashMovement.objects.create(
                    register_session=session,
                    movement_type=RegisterCashMovement.MovementType.PAY_OUT,
                    amount=Decimal("2.00"),
                    reason="نثرية",
                    created_by=person,
                )
                order = PurchaseOrder.objects.create(
                    supplier=supplier,
                    status=PurchaseOrder.Status.SUBMITTED,
                    total=Decimal("10.00"),
                )
                PurchaseOrderAuditEvent.objects.create(
                    purchase_order=order,
                    order_number=order.order_number,
                    action=PurchaseOrderAuditEvent.Action.CREATED,
                    created_by=person,
                )
                session.status = RegisterSession.Status.CLOSED
                session.save(update_fields=["status"])

        def queries():
            with CaptureQueriesContext(connection) as captured:
                self._rows()
            return len(captured)

        seed(1)
        # The first request also loads the caller's permissions; only later
        # requests compare like with like.
        queries()
        few = queries()
        seed(4)
        many = queries()

        self.assertEqual(many, few)


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


class DrawerPaidExpenseEditTests(ExpensesTestMixin, TestCase):
    """A drawer-paid expense and its ``PAY_OUT`` are one fact recorded twice: the
    expense says how much money left the shop, the movement says how much left
    the till. An edit that changes one and not the other makes the drawer
    disagree with the books, and the cashier wears the difference at close.
    """

    def _drawer_paid_expense(self, amount=Decimal("30.00"), opening=Decimal("500.00")):
        session = self.open_session(self.manager, opening_cash=opening)
        expense = create_expense(
            user=self.manager,
            pay_from_register=True,
            category=self.category,
            description="كهرباء",
            amount=amount,
            payment_method=Expense.PaymentMethod.CASH,
        )
        self.assertIsNotNone(expense.cash_movement_id)
        return session, expense

    def _patch(self, expense, payload):
        return self.manager_client.patch(
            reverse("expense-detail", args=[expense.pk]),
            payload,
            format="json",
        )

    def test_correcting_the_amount_re_books_the_linked_pay_out(self):
        # A manager fixes a mistyped 30 that was really 300. The till gave up
        # 300, so the drawer must expect 500 - 300, not 500 - 30.
        session, expense = self._drawer_paid_expense()

        response = self._patch(expense, {"amount": "300.00"})
        self.assertEqual(response.status_code, status.HTTP_200_OK)

        expense.refresh_from_db()
        session.refresh_from_db()
        self.assertEqual(expense.amount, Decimal("300.00"))
        self.assertEqual(expense.cash_movement.amount, Decimal("300.00"))
        self.assertEqual(session.pay_out_total, Decimal("300.00"))
        self.assertEqual(session.expected_cash, Decimal("200.00"))

    def test_the_pay_out_reason_follows_the_corrected_description(self):
        _, expense = self._drawer_paid_expense()

        self.assertEqual(
            self._patch(expense, {"description": "فاتورة كهرباء يوليو"}).status_code,
            status.HTTP_200_OK,
        )

        expense.refresh_from_db()
        self.assertIn("فاتورة كهرباء يوليو", expense.cash_movement.reason)

    def test_switching_off_cash_gives_the_drawer_its_money_back(self):
        # Recorded as cash by mistake; it was a bank transfer. Nothing left the
        # till, so no pay-out may remain against it.
        session, expense = self._drawer_paid_expense()

        response = self._patch(expense, {"payment_method": "transfer"})
        self.assertEqual(response.status_code, status.HTTP_200_OK)

        expense.refresh_from_db()
        session.refresh_from_db()
        self.assertIsNone(expense.cash_movement_id)
        self.assertIsNone(expense.register_session_id)
        self.assertEqual(RegisterCashMovement.objects.count(), 0)
        self.assertEqual(session.expected_cash, Decimal("500.00"))

    def test_ledger_never_reports_more_cash_out_than_the_drawer_gave(self):
        # The ledger hides an expense's own pay-out to avoid double counting, so
        # a stale movement would be invisible there while still shorting the
        # till. Both surfaces have to agree on the corrected figure.
        session, expense = self._drawer_paid_expense()
        self._patch(expense, {"amount": "300.00"})

        session.refresh_from_db()
        data = self.manager_client.get(reverse("expense-ledger")).data
        self.assertEqual(data["totals"]["expense"], "300.00")
        self.assertEqual(data["totals"]["register_payout"], "0.00")
        self.assertEqual(session.pay_out_total, Decimal("300.00"))

    def test_amount_and_method_are_frozen_once_the_session_is_closed(self):
        session, expense = self._drawer_paid_expense()
        session.closing_cash = session.expected_cash
        session.status = RegisterSession.Status.CLOSED
        session.closed_at = timezone.now()
        session.save(update_fields=["closing_cash", "status", "closed_at"])

        amount_response = self._patch(expense, {"amount": "300.00"})
        self.assertEqual(amount_response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertIn("amount", amount_response.data)

        method_response = self._patch(expense, {"payment_method": "transfer"})
        self.assertEqual(method_response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertIn("payment_method", method_response.data)

        expense.refresh_from_db()
        session.refresh_from_db()
        self.assertEqual(expense.amount, Decimal("30.00"))
        self.assertEqual(expense.cash_movement.amount, Decimal("30.00"))
        # The counted till is untouched: 500 opening - 30 paid out.
        self.assertEqual(session.expected_cash, Decimal("470.00"))

    def test_a_closed_session_still_allows_the_descriptive_fields(self):
        session, expense = self._drawer_paid_expense()
        session.status = RegisterSession.Status.CLOSED
        session.closed_at = timezone.now()
        session.save(update_fields=["status", "closed_at"])

        response = self._patch(expense, {"description": "كهرباء المخزن", "notes": "ن"})
        self.assertEqual(response.status_code, status.HTTP_200_OK)
        expense.refresh_from_db()
        self.assertEqual(expense.description, "كهرباء المخزن")

    def test_resending_the_same_amount_on_a_closed_session_is_not_an_edit(self):
        session, expense = self._drawer_paid_expense()
        session.status = RegisterSession.Status.CLOSED
        session.closed_at = timezone.now()
        session.save(update_fields=["status", "closed_at"])

        response = self._patch(expense, {"amount": "30.00", "description": "كهرباء ٢"})
        self.assertEqual(response.status_code, status.HTTP_200_OK)

    def test_an_expense_with_no_drawer_link_is_freely_editable(self):
        response = self.manager_client.post(
            reverse("expense-list"),
            {
                "category": self.category.pk,
                "description": "إنترنت",
                "amount": "45.00",
                "payment_method": "transfer",
            },
            format="json",
        )
        expense = Expense.objects.get(pk=response.data["id"])

        self.assertEqual(
            self._patch(expense, {"amount": "50.00"}).status_code,
            status.HTTP_200_OK,
        )
        expense.refresh_from_db()
        self.assertEqual(expense.amount, Decimal("50.00"))
        self.assertEqual(RegisterCashMovement.objects.count(), 0)

    def test_cancelling_a_drawer_paid_expense_puts_the_cash_back(self):
        # This used to be a delete, and a delete left the pay-out behind with
        # nothing to explain it: the drawer still expected 470 and the ledger
        # showed an anonymous 30 leaving the till. Retracting the expense says
        # what actually happened instead — the money is expected back in the
        # drawer, and neither row is lost.
        session, expense = self._drawer_paid_expense()

        response = self.manager_client.post(
            reverse("expense-cancel", args=[expense.pk]),
            {"reason": "سُجّل مرتين"},
            format="json",
        )
        self.assertEqual(response.status_code, status.HTTP_200_OK, response.data)

        session.refresh_from_db()
        self.assertEqual(session.expected_cash, Decimal("500.00"))

        data = self.manager_client.get(reverse("expense-ledger")).data
        self.assertEqual(data["totals"]["expense"], "0.00")
        self.assertEqual(data["totals"]["register_payout"], "0.00")
        self.assertEqual(data["summary"]["total"], "0.00")

    def test_the_old_delete_verb_is_gone_and_changes_nothing(self):
        """0.5.2 retired the deprecated alias.

        The refusal is 403 rather than 405 because DRF runs permissions before
        it resolves the verb, and ``HasPointyPermission`` denies any action it
        has no entry for. That deny-by-default is what actually closes the door
        here, so it is asserted rather than tidied into a 405: an expense a
        client tried to DELETE is left exactly as it was, still counting, with
        the drawer untouched.
        """
        session, expense = self._drawer_paid_expense()

        response = self.manager_client.delete(
            reverse("expense-detail", args=[expense.pk])
        )

        self.assertEqual(response.status_code, status.HTTP_403_FORBIDDEN)
        expense.refresh_from_db()
        session.refresh_from_db()
        self.assertEqual(expense.doc_status, DocumentStatus.SUBMITTED)
        self.assertEqual(session.expected_cash, Decimal("470.00"))
