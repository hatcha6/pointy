from celery import shared_task
from django.core.cache import cache


@shared_task
def warm_pos_caches() -> str:
    cache.set("pos:last_cache_warm", "ok", timeout=3600)
    return "warmed"
