import logging

from celery import shared_task

from .services import expire_stale_queued_print_jobs

logger = logging.getLogger(__name__)


@shared_task(name="printing.expire_stale_print_jobs")
def expire_stale_print_jobs_task():
    """Retire receipt jobs that no agent claimed in time.

    The queue only accepts work when an agent is reading it, but an agent can
    go away after a job is created — that is exactly what happened in the field
    over 2026-07-20..22, when every claim failed and the rows were left behind.
    Without this the table only grows.
    """
    expired = expire_stale_queued_print_jobs()
    if expired:
        logger.info("Expired %s stale queued print jobs.", expired)
    return expired
