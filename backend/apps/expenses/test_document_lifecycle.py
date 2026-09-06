"""An expense as a document.

An expense used to be editable and deletable forever, guarded only by the
period lock — so a number that had been reported, and a drawer that had been
counted, could both be rewritten from a screen with no record of it. What
changes here is not what a shop can do; it is that what it does is written down.
"""

from decimal import Decimal

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group
from django.test import TestCase
from django.utils import timezone

from apps.core.roles import MANAGER_GROUP, ensure_role_groups
from apps.documents import trail
from apps.documents.errors import DocumentFrozen
from apps.documents.models import DocumentEvent
from apps.documents.statuses import DocumentStatus
from apps.sales.models import RegisterCashMovement, RegisterSession

from .models import Expense, ExpenseCategory
from .services import cancel_expense, create_expense, update_expense


class ExpenseLifecycleTests(TestCase):
    def setUp(self):
        ensure_role_groups()
        self.user = get_user_model().objects.create_user(
            username="expense-manager", password="pass"
        )
        self.user.groups.add(Group.objects.get(name=MANAGER_GROUP))
        self.category = ExpenseCategory.objects.create(name="كهرباء")

    def _expense(self, amount="30.00", method=Expense.PaymentMethod.TRANSFER, **kwargs):
        return create_expense(
            user=self.user,
            category=self.category,
            description="فاتورة الكهرباء",
            amount=Decimal(amount),
            payment_method=method,
            **kwargs,
        )

    def _open_session(self, opening="500.00"):
        return RegisterSession.objects.create(
            owner=self.user,
            owner_key=f"user:{self.user.pk}",
            opening_cash=Decimal(opening),
        )

    # --- born, and frozen from birth ------------------------------------

    def test_an_expense_is_a_document_from_the_moment_it_exists(self):
        self.assertEqual(self._expense().doc_status, DocumentStatus.SUBMITTED)

    def test_the_amount_cannot_be_rewritten_behind_the_lifecycles_back(self):
        expense = self._expense()
        expense.amount = Decimal("999.00")
        with self.assertRaises(DocumentFrozen):
            expense.save(update_fields=["amount"])

    def test_the_words_around_it_stay_editable(self):
        expense = self._expense()
        update_expense(expense, {"description": "كهرباء الشهر", "notes": "تصحيح"})
        expense.refresh_from_db()
        self.assertEqual(expense.description, "كهرباء الشهر")

    def test_correcting_the_amount_is_recorded_with_what_changed(self):
        expense = self._expense(amount="30.00")
        update_expense(expense, {"amount": Decimal("300.00")})

        expense.refresh_from_db()
        self.assertEqual(expense.amount, Decimal("300.00"))
        event = trail.history(expense).first()
        self.assertEqual(event.action, DocumentEvent.Action.CORRECTED)
        self.assertEqual(
            event.details["changes"]["amount"], {"from": "30.00", "to": "300.00"}
        )

    # --- undoing one ----------------------------------------------------

    def test_a_cancelled_expense_stops_counting(self):
        expense = self._expense(amount="40.00")
        today = timezone.localdate()
        self.assertEqual(
            Expense.objects.live().filter(spent_at=today).count(), 1
        )

        cancel_expense(expense, reason="سُجّل مرتين")

        expense.refresh_from_db()
        self.assertEqual(expense.doc_status, DocumentStatus.CANCELLED)
        self.assertEqual(Expense.objects.live().filter(spent_at=today).count(), 0)
        # The row survives, which is the whole difference from deleting it.
        self.assertTrue(Expense.objects.filter(pk=expense.pk).exists())

    def test_cash_paid_out_of_a_drawer_comes_back_into_the_open_one(self):
        session = self._open_session()
        expense = self._expense(
            amount="30.00",
            method=Expense.PaymentMethod.CASH,
            pay_from_register=True,
        )
        session.refresh_from_db()
        self.assertEqual(session.expected_cash, Decimal("470.00"))

        cancel_expense(expense, reason="خطأ", register_session=session)

        session.refresh_from_db()
        self.assertEqual(session.expected_cash, Decimal("500.00"))
        self.assertEqual(
            session.cash_movements.filter(
                movement_type=RegisterCashMovement.MovementType.PAY_IN
            ).count(),
            1,
        )

    def test_a_drawer_expense_needs_an_open_drawer_to_come_back_into(self):
        session = self._open_session()
        expense = self._expense(
            amount="30.00",
            method=Expense.PaymentMethod.CASH,
            pay_from_register=True,
        )
        session.status = RegisterSession.Status.CLOSED
        session.save(update_fields=["status"])

        class _Request:
            user = self.user

        with self.assertRaises(Exception) as caught:
            cancel_expense(expense, reason="خطأ", request=_Request())
        self.assertIn("register session", str(caught.exception))

    def test_the_cancellation_is_recorded(self):
        expense = self._expense()
        cancel_expense(expense, reason="غير صحيح")
        event = trail.history(expense).first()
        self.assertEqual(event.action, DocumentEvent.Action.CANCELLED)
        self.assertEqual(event.reason, "غير صحيح")
