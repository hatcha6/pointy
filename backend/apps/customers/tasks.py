from celery import shared_task

from .segmentation import recompute_customer_segments


@shared_task(
    bind=True,
    name="customers.recompute_customer_segments",
    autoretry_for=(Exception,),
    retry_backoff=True,
    retry_jitter=True,
    retry_kwargs={"max_retries": 3},
)
def recompute_customer_segments_task(self):
    """Nightly RFM re-segmentation of the whole customer base.

    Thin Celery wrapper so the heavy lifting in ``segmentation`` stays plain,
    importable and unit-testable without a broker.
    """
    return recompute_customer_segments()
