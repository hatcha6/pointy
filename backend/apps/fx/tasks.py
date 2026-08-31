from celery import shared_task

from .services import sync_exchange_rates


@shared_task(
    bind=True,
    name="fx.sync_exchange_rates",
    autoretry_for=(Exception,),
    retry_backoff=True,
    retry_jitter=True,
    retry_kwargs={"max_retries": 3},
)
def sync_exchange_rates_task(self):
    return sync_exchange_rates()
