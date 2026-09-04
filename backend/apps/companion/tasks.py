"""Housekeeping for the companion channel."""

from celery import shared_task

from .services import purge_expired


@shared_task(name="companion.purge_expired")
def purge_expired_task():
    """Retire aged-out events, pairings, capture requests and devices.

    The event table is a replay buffer, not an archive: without this it would
    grow by one row per scan forever, and a busy shop scans all day.
    """
    return purge_expired()
