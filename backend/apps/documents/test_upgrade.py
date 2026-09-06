"""What a live update leaves behind, and what the new backend does about it.

Every release has about a minute where the old backend is still serving against
the new schema (``deploy/onprem/README.md``). Two things have to hold across it:
the old code must still be able to write — a till that cannot ring up a sale
mid-update is exactly the outage the design exists to prevent — and whatever it
writes must be put right afterwards.
"""

from decimal import Decimal

from django.db import connection
from django.test import TestCase

from apps.documents.reconciliation import reconcile_lifecycles
from apps.documents.statuses import DocumentStatus
from apps.expenses.models import Expense, ExpenseCategory
from apps.inventory.models import StockCount
from apps.purchasing.models import PurchaseOrder, Supplier
from apps.sales.models import Order, RegisterSession


class OldCodeCanStillWriteTests(TestCase):
    """The lifecycle columns carry a *database* default, not just a Python one.

    Django backfills existing rows with the Python default and then drops the
    database default, which leaves a NOT NULL column with nothing to fall back
    on — and the old backend's INSERT names no such column. These assert the
    columns keep a default the database itself will apply.
    """

    def test_every_lifecycle_column_has_a_database_default(self):
        tables = {
            "sales_order",
            "payments_payment",
            "purchasing_purchaseorder",
            "purchasing_supplierpayment",
            "purchasing_purchasereceipt",
            "expenses_expense",
            "employees_payrollrun",
            "inventory_stockcount",
        }
        columns = ("doc_status", "cancel_reason", "amendment_index")
        with connection.cursor() as cursor:
            for table in sorted(tables):
                for column in columns:
                    default = self._column_default(cursor, table, column)
                    self.assertIsNotNone(
                        default,
                        f"{table}.{column} has no database default: an older "
                        f"backend's INSERT would fail during a live update.",
                    )

    def _column_default(self, cursor, table, column):
        if connection.vendor == "postgresql":
            cursor.execute(
                "SELECT column_default FROM information_schema.columns "
                "WHERE table_name = %s AND column_name = %s",
                [table, column],
            )
            row = cursor.fetchone()
            return row[0] if row else None
        # SQLite keeps the default in the table definition.
        cursor.execute(f"PRAGMA table_info('{table}')")
        for row in cursor.fetchall():
            if row[1] == column:
                return row[4]
        return None


class ReconcilingWhatTheOldBackendWroteTests(TestCase):
    """A row inserted by the old backend arrives with the column's default —
    a draft lifecycle on a document its own progress says is finished."""

    def setUp(self):
        self.supplier = Supplier.objects.create(name="مورد")
        self.category = ExpenseCategory.objects.create(name="كهرباء")

    def _as_old_backend_would(self, model, **fields):
        """Insert without the lifecycle, the way code that predates it does."""
        row = model.objects.create(**fields)
        model.objects.filter(pk=row.pk).update(doc_status=DocumentStatus.DRAFT)
        row.refresh_from_db()
        return row

    def test_a_sale_rung_up_mid_update_becomes_a_submitted_document(self):
        session = RegisterSession.objects.create(owner_key="user:1")
        order = self._as_old_backend_would(
            Order,
            register_session=session,
            status=Order.Status.PAID,
            total=Decimal("10.00"),
        )
        self.assertEqual(order.doc_status, DocumentStatus.DRAFT)

        moved = reconcile_lifecycles()

        order.refresh_from_db()
        self.assertEqual(order.doc_status, DocumentStatus.SUBMITTED)
        self.assertGreaterEqual(moved, 1)

    def test_and_one_voided_mid_update_becomes_a_cancelled_one(self):
        session = RegisterSession.objects.create(owner_key="user:2")
        order = self._as_old_backend_would(
            Order,
            register_session=session,
            status=Order.Status.VOID,
            total=Decimal("10.00"),
        )
        reconcile_lifecycles()
        order.refresh_from_db()
        self.assertEqual(order.doc_status, DocumentStatus.CANCELLED)

    def test_a_document_that_is_never_a_draft_is_promoted_whatever_it_says(self):
        expense = self._as_old_backend_would(
            Expense,
            category=self.category,
            description="كهرباء",
            amount=Decimal("5.00"),
            payment_method=Expense.PaymentMethod.CASH,
        )
        reconcile_lifecycles()
        expense.refresh_from_db()
        self.assertEqual(expense.doc_status, DocumentStatus.SUBMITTED)

    def test_a_genuine_draft_is_left_exactly_where_it_is(self):
        order_draft = PurchaseOrder.objects.create(
            supplier=self.supplier, status=PurchaseOrder.Status.DRAFT
        )
        counting = StockCount.objects.create(
            owner_key="user:3", status=StockCount.Status.IN_PROGRESS
        )
        cart = RegisterSession.objects.create(owner_key="user:4")
        open_order = Order.objects.create(
            register_session=cart, status=Order.Status.OPEN, total=Decimal("0.00")
        )

        reconcile_lifecycles()

        for row in (order_draft, counting, open_order):
            row.refresh_from_db()
            self.assertEqual(row.doc_status, DocumentStatus.DRAFT)

    def test_running_it_twice_moves_nothing_the_second_time(self):
        session = RegisterSession.objects.create(owner_key="user:5")
        self._as_old_backend_would(
            Order,
            register_session=session,
            status=Order.Status.PAID,
            total=Decimal("10.00"),
        )
        self.assertGreaterEqual(reconcile_lifecycles(), 1)
        self.assertEqual(reconcile_lifecycles(), 0)
