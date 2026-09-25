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


#: One sweep at a time. A sweep that overruns — a slow provider — must not
#: have the next one start beside it and race it over the same rows.
_SWEEP_LOCK = "pointy:integrations:vouchers:sweep"
_SWEEP_LOCK_SECONDS = 240


@shared_task(bind=True, name="integrations.sync_voucher_catalogs")
def sync_voucher_catalogs_task(self):
    """Every few minutes: the cards on the till are the cards the provider has.

    Not retried: the next sweep is minutes away and reads the same shelf.
    """
    from django.core.cache import cache

    from .vouchers import sync_all

    try:
        if not cache.add(_SWEEP_LOCK, 1, _SWEEP_LOCK_SECONDS):
            return {"skipped": "a sweep is already running"}
    except Exception:  # noqa: BLE001 - no Redis: run, overlap is only wasteful
        pass
    try:
        return sync_all()
    finally:
        try:
            cache.delete(_SWEEP_LOCK)
        except Exception:  # noqa: BLE001
            pass


@shared_task(bind=True, name="integrations.sync_payment_reports")
def sync_payment_reports_task(self):
    """Half-hourly: keep each provider's payments report mirrored.

    What the till's history for an LNET line and a manager's "payments made on
    the website" both read. Not retried: the next run is half an hour away and
    walks the same report; each account keeps to itself under its own lock.
    """
    from .payment_report import sweep_all

    return sweep_all()


@shared_task(bind=True, name="integrations.sync_voucher_catalog")
def sync_voucher_catalog_task(self, account_id):
    """A whole shelf, now — for an account that was just connected or verified.

    Reads every collapsed brand instead of the sweep's stalest dozen, so a new
    shop's till has its cards within seconds rather than over the next hour.
    """
    from .models import IntegrationAccount
    from .vouchers import sells_vouchers, sync_account

    account = IntegrationAccount.objects.filter(pk=account_id, is_active=True).first()
    if account is None or not sells_vouchers(account) or not account.is_configured:
        return {"skipped": True}
    return sync_account(account, refresh_limit=1000).as_dict()
