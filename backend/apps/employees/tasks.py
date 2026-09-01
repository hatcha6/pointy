from celery import shared_task

from .services import draft_monthly_payroll_run


@shared_task(
    bind=True,
    name="employees.draft_monthly_payroll",
    autoretry_for=(Exception,),
    retry_backoff=True,
    retry_jitter=True,
    retry_kwargs={"max_retries": 3},
)
def draft_monthly_payroll_task(self):
    payroll_run, created = draft_monthly_payroll_run()
    attendance_applied = 0
    if payroll_run is not None:
        if created:
            attendance_applied = _apply_attendance_if_available(payroll_run)
        from apps.notifications.services import sync_business_notifications

        sync_business_notifications()
    return {
        "created": created,
        "payroll_run_id": payroll_run.pk if payroll_run is not None else None,
        "attendance_lines_applied": attendance_applied,
    }


def _apply_attendance_if_available(payroll_run):
    """Cost the fresh draft off BioTime attendance when the period is covered.

    The monthly draft is the run nobody assembles by hand, so it is the one
    that most needs absences and overtime filled in. Best-effort: a shop with
    no BioTime, a disabled integration, or a period the sync has not reached
    keeps the plain salary draft rather than failing the nightly task.
    """
    from rest_framework.serializers import ValidationError

    from apps.attendance.models import BioTimeConnection
    from apps.attendance.services import apply_attendance_to_run

    connection = BioTimeConnection.load()
    if not connection.is_enabled or not connection.is_configured:
        return 0
    try:
        result = apply_attendance_to_run(payroll_run)
    except ValidationError:
        # Period not covered by imported punches, or the run left draft between
        # the two steps. Never guess absences from data that is not there.
        return 0
    return len(result["applied_lines"])
