from celery import shared_task
from django.core.cache import cache

from apps.sales import services


@shared_task
def warm_pos_caches() -> str:
    cache.set("pos:last_cache_warm", "ok", timeout=3600)
    return "warmed"


@shared_task(name="sales.release_expired_quote_reservations")
def release_expired_quote_reservations() -> int:
    """Free stock held by quotations whose validity date has passed.

    Scheduled daily (see ``CELERY_BEAT_SCHEDULE``) so an expired quotation's hold
    is released automatically the day after it lapses — without anyone converting
    or manually cancelling it. Returns the number of quotations released.
    """
    return services.release_expired_quote_reservations()
