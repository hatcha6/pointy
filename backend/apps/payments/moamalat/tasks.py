"""Celery tasks of the Moamalat verification (registered via ``payments.tasks``)."""

from celery import shared_task


@shared_task(name="payments.moamalat_keepalive", ignore_result=True)
def moamalat_keepalive():
    """The backend's half of the keepalive: beat every few seconds, pokes only
    when the link's own cadence says so (``custody.keepalive_tick``)."""
    from . import custody, matching

    link = custody.load_link()
    due = (
        link.state == link.State.ALIVE
        and (link.next_poke_at is None or link.next_poke_at <= _now())
    )
    if due and matching.pending_payments(link).exists():
        # Something is waiting: the read is the poke, and it may verify it.
        matching.fetch_live(link)
        link.refresh_from_db()
    custody.keepalive_tick()


@shared_task(name="payments.moamalat_fast_poll", ignore_result=True)
def moamalat_fast_poll():
    from . import watch

    return watch.fast_poll()


@shared_task(name="payments.moamalat_sweep", ignore_result=True)
def moamalat_sweep():
    """Read back to the oldest pending payment: after a re-link, and hourly."""
    from . import custody, matching

    link = custody.load_link()
    if link.state != link.State.ALIVE or not matching.pending_payments(link).exists():
        return 0
    return matching.fetch_sweep(link).matched


def _now():
    from django.utils import timezone

    return timezone.now()
