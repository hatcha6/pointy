from celery import shared_task

from .services import sync_business_notifications


@shared_task(
    bind=True,
    name="notifications.sync_business_notifications",
    autoretry_for=(Exception,),
    retry_backoff=True,
    retry_jitter=True,
    retry_kwargs={"max_retries": 3},
)
def sync_business_notifications_task(self):
    return sync_business_notifications()
