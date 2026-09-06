"""A payroll run as a document.

Three meanings shared one field here — approval, payment, and whether the
document is live — and a run that had been paid could never be undone. Both are
what this changes: the lifecycle carries the document's own state, ``status``
is derived from it plus the approval stamp, and a run paid by mistake can be
retracted with everything it collected on the way.
"""

from datetime import date
from decimal import Decimal

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group
from django.test import TestCase
from django.utils import timezone

from apps.core.roles import ACCOUNTANT_GROUP, MANAGER_GROUP, ensure_role_groups
from apps.documents import trail
from apps.documents.errors import DocumentFrozen
from apps.documents.models import DocumentEvent
from apps.documents.statuses import DocumentStatus

from .models import (
    CompensationPlan,
    Employee,
    EmployeeLoan,
    EmployeeLoanPayment,
    PayrollRun,
)
from .services import (
    approve_payroll_run,
    draft_monthly_payroll_run,
    mark_payroll_run_paid,
    void_payroll_run,
)


class PayrollRunLifecycleTests(TestCase):
    def setUp(self):
        ensure_role_groups()
        User = get_user_model()
        self.manager = User.objects.create_user(username="pay-manager", password="p")
        self.manager.groups.add(Group.objects.get(name=MANAGER_GROUP))
        self.accountant = User.objects.create_user(username="pay-acc", password="p")
        self.accountant.groups.add(Group.objects.get(name=ACCOUNTANT_GROUP))
        self.employee = Employee.objects.create(full_name="موظف الرواتب")
        CompensationPlan.objects.create(
            employee=self.employee,
            pay_type=CompensationPlan.PayType.MONTHLY_SALARY,
            salary_type=CompensationPlan.SalaryType.MONTHLY_FIXED,
            amount=Decimal("500.00"),
            effective_from=date(2026, 6, 1),
        )

    def _run(self):
        run, _created = draft_monthly_payroll_run(
            period_start=date(2026, 6, 1), period_end=date(2026, 6, 30)
        )
        return run

    def _loan(self, outstanding="120.00", deduction="50.00"):
        return EmployeeLoan.objects.create(
            employee=self.employee,
            requested_by=self.manager,
            reviewed_by=self.accountant,
            status=EmployeeLoan.Status.APPROVED,
            amount=Decimal("120.00"),
            monthly_deduction=Decimal(deduction),
            outstanding_balance=Decimal(outstanding),
            reviewed_at=timezone.now(),
        )

    # --- the three meanings come apart ----------------------------------

    def test_an_approved_run_is_still_a_draft(self):
        """Approval gates paying; it is not a state of the document. Nothing has
        left the shop yet."""
        run = approve_payroll_run(self._run())
        self.assertEqual(run.doc_status, DocumentStatus.DRAFT)
        self.assertEqual(run.status, PayrollRun.Status.APPROVED)

    def test_paying_is_what_submits_it(self):
        run = mark_payroll_run_paid(approve_payroll_run(self._run()))
        self.assertEqual(run.doc_status, DocumentStatus.SUBMITTED)
        self.assertEqual(run.status, PayrollRun.Status.PAID)
        self.assertIsNotNone(run.submitted_at)

    def test_a_paid_run_is_frozen(self):
        run = mark_payroll_run_paid(approve_payroll_run(self._run()))
        run.net_total = Decimal("1.00")
        with self.assertRaises(DocumentFrozen):
            run.save(update_fields=["net_total"])

    # --- undoing one ----------------------------------------------------

    def test_a_draft_run_is_simply_retracted(self):
        run = void_payroll_run(self._run(), reason="أُعدّ بالخطأ")
        self.assertEqual(run.doc_status, DocumentStatus.CANCELLED)
        self.assertEqual(run.status, PayrollRun.Status.VOID)

    def test_a_paid_run_can_be_retracted_and_gives_back_what_it_collected(self):
        loan = self._loan(outstanding="120.00", deduction="50.00")
        run = mark_payroll_run_paid(approve_payroll_run(self._run()))
        loan.refresh_from_db()
        self.assertEqual(loan.outstanding_balance, Decimal("70.00"))
        self.assertEqual(EmployeeLoanPayment.objects.filter(loan=loan).count(), 1)

        void_payroll_run(run, reason="دُفع لمسيّر خاطئ")

        loan.refresh_from_db()
        run.refresh_from_db()
        self.assertEqual(run.status, PayrollRun.Status.VOID)
        self.assertEqual(loan.outstanding_balance, Decimal("120.00"))
        self.assertEqual(EmployeeLoanPayment.objects.filter(loan=loan).count(), 0)

    def test_a_loan_the_run_had_settled_is_owed_again(self):
        loan = self._loan(outstanding="50.00", deduction="50.00")
        run = mark_payroll_run_paid(approve_payroll_run(self._run()))
        loan.refresh_from_db()
        self.assertEqual(loan.status, EmployeeLoan.Status.PAID)
        self.assertEqual(loan.outstanding_balance, Decimal("0.00"))

        void_payroll_run(run, reason="خطأ")

        loan.refresh_from_db()
        self.assertEqual(loan.status, EmployeeLoan.Status.APPROVED)
        self.assertEqual(loan.outstanding_balance, Decimal("50.00"))
        self.assertIsNone(loan.paid_at)

    def test_a_retracted_run_stops_being_wages_the_shop_paid(self):
        from apps.employees.services import payroll_expense_between

        run = mark_payroll_run_paid(approve_payroll_run(self._run()))
        period = (date(2026, 6, 1), date(2026, 6, 30))
        paid_before = payroll_expense_between(*period)
        self.assertGreater(paid_before, Decimal("0.00"))

        void_payroll_run(run, reason="خطأ")

        self.assertEqual(payroll_expense_between(*period), Decimal("0.00"))

    def test_the_legacy_void_stamps_follow_the_lifecycle(self):
        run = mark_payroll_run_paid(approve_payroll_run(self._run()))
        void_payroll_run(run, reason="خطأ")
        run.refresh_from_db()
        self.assertIsNotNone(run.voided_at)
        self.assertEqual(run.voided_at, run.cancelled_at)

    def test_the_retraction_is_recorded(self):
        run = mark_payroll_run_paid(approve_payroll_run(self._run()))
        void_payroll_run(run, reason="مسيّر مكرر")
        event = trail.history(run).first()
        self.assertEqual(event.action, DocumentEvent.Action.CANCELLED)
        self.assertEqual(event.reason, "مسيّر مكرر")
