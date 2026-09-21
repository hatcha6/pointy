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


@shared_task(
    bind=True,
    name="integrations.refresh_float_balances",
    autoretry_for=(Exception,),
    retry_backoff=True,
    retry_jitter=True,
    retry_kwargs={"max_retries": 1},
)
def refresh_float_balances_task(self):
    """Hourly: keep the float figure current enough to warn on.

    Shallow retries, like the nightly sweep: a provider that is unreachable
    now is very likely unreachable in a minute, the failure is already written
    to the account, and the next hour's run covers it anyway.
    """
    from .services import refresh_float_balances

    return refresh_float_balances()
