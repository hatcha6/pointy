"""What a payroll run means to the document lifecycle.

A run is *submitted* when it is paid — that is the moment money leaves the shop
and the moment its figures stop being a proposal. Approval comes before that and
is a gate on submitting, not a state of the document; it stays a payroll concept
until there is a general approval engine to hand it to.
"""

from decimal import Decimal


def progress_status(payroll_run) -> str:
    from apps.documents.statuses import DocumentStatus
    from apps.employees.models import PayrollRun

    if payroll_run.doc_status == DocumentStatus.CANCELLED:
        return PayrollRun.Status.VOID
    if payroll_run.doc_status == DocumentStatus.SUBMITTED:
        return PayrollRun.Status.PAID
    return (
        PayrollRun.Status.APPROVED
        if payroll_run.approved_at
        else PayrollRun.Status.DRAFT
    )


def recompute_progress(payroll_run) -> None:
    status = progress_status(payroll_run)
    changed = []
    if payroll_run.status != status:
        payroll_run.status = status
        changed.append("status")
    # The legacy pair, mirrored rather than written beside the lifecycle's own.
    if payroll_run.voided_at != payroll_run.cancelled_at:
        payroll_run.voided_at = payroll_run.cancelled_at
        changed.append("voided_at")
    if payroll_run.voided_by_id != payroll_run.cancelled_by_id:
        payroll_run.voided_by_id = payroll_run.cancelled_by_id
        changed.append("voided_by")
    if changed:
        payroll_run.save(update_fields=[*changed, "updated_at"])


def reverse(payroll_run, *, at, actor, reason="", context=None):
    """Undo a paid run.

    Voiding one used to be impossible once it was paid, so a run paid by
    mistake was permanent — the same shape as a supplier payment that could
    never be cancelled. What has to come back is what paying it did beyond
    recording the money: every loan instalment it collected. The run's own
    money effect needs nothing here, because the money position reads paid runs
    and a retracted run is no longer one.
    """
    from apps.employees.models import EmployeeLoan, EmployeeLoanPayment

    instalments = list(
        EmployeeLoanPayment.objects.select_related("loan").filter(
            payroll_line__payroll_run=payroll_run
        )
    )
    for instalment in instalments:
        loan = EmployeeLoan.objects.select_for_update().get(pk=instalment.loan_id)
        loan.outstanding_balance = (
            Decimal(loan.outstanding_balance or "0.00") + instalment.amount
        ).quantize(Decimal("0.01"))
        update_fields = ["outstanding_balance", "updated_at"]
        if loan.outstanding_balance > Decimal("0.00") and (
            loan.status == EmployeeLoan.Status.PAID
        ):
            # It is owed again, so it is not settled any more.
            loan.status = EmployeeLoan.Status.APPROVED
            loan.paid_at = None
            update_fields.extend(["status", "paid_at"])
        loan.save(update_fields=update_fields)

    # The instalment rows are the run's own allocation of what it deducted, not
    # documents in their own right: with the run retracted they record a
    # collection that did not happen.
    EmployeeLoanPayment.objects.filter(
        payroll_line__payroll_run=payroll_run
    ).delete()
    return None


__all__ = ["progress_status", "recompute_progress", "reverse"]
