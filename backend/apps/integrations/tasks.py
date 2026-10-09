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
    """Every few hours: find the provider's new and retired cards.

    Live stock is read when a cashier opens the picker, not here. Not retried:
    the next sweep reads the same shelf. The company's own shelf has its own,
    far more frequent sweep (``sync_relay_vouchers_task``).
    """
    from .vouchers import sync_all

    return _one_at_a_time(_SWEEP_LOCK, lambda: sync_all(relay_hosted=False))


#: The company's shelf sweeps under its own lock: a slow six-hourly sweep of
#: somebody else's shelf must not hold it up. Settling lost purchases has one
#: of its own too.
_RELAY_SWEEP_LOCK = "pointy:integrations:vouchers:relay-sweep"
_RELAY_SETTLE_LOCK = "pointy:integrations:vouchers:relay-settle"


@shared_task(bind=True, name="integrations.sync_relay_vouchers")
def sync_relay_vouchers_task(self):
    """Every five minutes: the company's own shelf («كروت دفتر»).

    One conditional read of the whole shelf; an unchanged one (``304``) writes
    nothing, so the tills' cached catalogs stay warm between real changes —
    a promotion starting, a card running out at the wholesaler. Not retried:
    the next sweep is five minutes away.
    """
    from .vouchers import sync_all

    return _one_at_a_time(_RELAY_SWEEP_LOCK, lambda: sync_all(relay_hosted=True))


#: The services directory sweeps under a lock of its own too: a slow card sweep
#: must not hold it up, nor the reverse.
_RELAY_SERVICES_LOCK = "pointy:integrations:services:relay-sweep"


@shared_task(bind=True, name="integrations.sync_relay_services")
def sync_relay_services_task(self):
    """Every five minutes: the company's direct top-up and bill-payment directory.

    The countries, and the networks and billers in each, mirrored from the relay
    in one conditional read; an unchanged directory (``304``) writes nothing, so
    the tills' caches stay warm. Flags arrive a few dozen per sweep. Not retried:
    the next sweep is five minutes away.
    """
    from .services_sync import sync_all

    return _one_at_a_time(_RELAY_SERVICES_LOCK, sync_all)


@shared_task(bind=True, name="integrations.settle_relay_vouchers")
def settle_relay_vouchers_task(self):
    """Every two minutes: settle the relay purchases whose answer was lost.

    A customer who paid for a card is waiting on its code, so this does not
    wait for the nightly reconciliation. One query when there is nothing to do;
    one run at a time, so a slow relay never has two runs reading one purchase.
    """
    from .reconciliation import settle_relay_attempts

    return _one_at_a_time(_RELAY_SETTLE_LOCK, settle_relay_attempts)


def _one_at_a_time(lock, sweep):
    """Run ``sweep`` unless another run holds ``lock``."""
    from django.core.cache import cache

    try:
        if not cache.add(lock, 1, _SWEEP_LOCK_SECONDS):
            return {"skipped": "a sweep is already running"}
    except Exception:  # noqa: BLE001 - no Redis: run, overlap is only wasteful
        pass
    try:
        return sweep()
    finally:
        try:
            cache.delete(lock)
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
    shop's till has its cards within seconds rather than over the next hour —
    and then every brand's logo, once the cards are already on sale.
    """
    from . import switches
    from .models import IntegrationAccount
    from .services import probe_account
    from .services_sync import sells_services
    from .vouchers import is_relay_hosted, sells_vouchers, sync_account

    account = IntegrationAccount.objects.filter(pk=account_id, is_active=True).first()
    if account is None or not sells_vouchers(account) or not account.is_configured:
        return {"skipped": True}
    if switches.is_switched_off(account.provider):
        return {"skipped": True}
    if is_relay_hosted(account):
        # Nothing to log in to: read the voucher balance now, so the owner
        # who just switched it on sees it rather than waiting for the hour.
        probe_account(account)
    report = sync_account(account, refresh_limit=1000, logo_limit=1000).as_dict()
    if is_relay_hosted(account) and sells_services(account):
        # Its direct top-up and bill payments too, so they are on the till with
        # the cards. A failure there is its own report, never the cards'.
        report["services"] = _sync_services_now(account)
    return report


def _sync_services_now(account) -> dict:
    from .services_sync import sync_account as sync_services

    try:
        return sync_services(account, flag_limit=1000).as_dict()
    except Exception:  # noqa: BLE001 - the cards are already in; see the docstring above
        return {"provider": account.provider, "ok": False}
