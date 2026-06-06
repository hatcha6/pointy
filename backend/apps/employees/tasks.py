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
    if payroll_run is not None:
        from apps.notifications.services import sync_business_notifications

        sync_business_notifications()
    return {
        "created": created,
        "payroll_run_id": payroll_run.pk if payroll_run is not None else None,
    }
