from celery import shared_task

from .services import sync_holidays


@shared_task(
    bind=True,
    name="holidays.sync_holidays",
    autoretry_for=(Exception,),
    retry_backoff=True,
    retry_jitter=True,
    retry_kwargs={"max_retries": 3},
)
def sync_holidays_task(self):
    return sync_holidays()
