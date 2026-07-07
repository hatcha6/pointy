from celery import shared_task

from .popularity import recompute_product_popularity


@shared_task(
    bind=True,
    name="catalog.recompute_product_popularity",
    autoretry_for=(Exception,),
    retry_backoff=True,
    retry_jitter=True,
    retry_kwargs={"max_retries": 3},
)
def recompute_product_popularity_task(self):
    """Nightly rolling-90-day recompute of every product's "most bought" score.

    Thin Celery wrapper so the heavy lifting in ``popularity`` stays plain,
    importable and unit-testable without a broker.
    """
    return recompute_product_popularity()
