from celery import shared_task


@shared_task(
    bind=True,
    name="integrations.reconcile_providers",
    autoretry_for=(Exception,),
    retry_backoff=True,
    retry_jitter=True,
    retry_kwargs={"max_retries": 2},
)
def reconcile_providers_task(self):
    """Nightly: prove that what Pointy sold, the provider actually did.

    Retries are shallow on purpose — a provider that is down at 02:00 is very
    likely down at 02:05, and tomorrow's sweep covers the same window anyway.
    """
    from .reconciliation import reconcile_all

    return reconcile_all()
