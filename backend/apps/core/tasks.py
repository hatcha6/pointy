import logging

from celery import shared_task
from django.conf import settings
from django.core.exceptions import ImproperlyConfigured

from .backup import queue_due_scheduled_backup, run_backup, run_restore
from .models import RelayInstallation
from .relay import RelayControlError, sync_relay_installation

logger = logging.getLogger(__name__)


@shared_task(
    name="core.run_backup_job",
    soft_time_limit=settings.POINTY_BACKUP_TASK_SOFT_TIME_LIMIT,
    time_limit=settings.POINTY_BACKUP_TASK_TIME_LIMIT,
)
def run_backup_job(job_id):
    run_backup(job_id)


@shared_task(
    name="core.run_restore_job",
    soft_time_limit=settings.POINTY_BACKUP_TASK_SOFT_TIME_LIMIT,
    time_limit=settings.POINTY_BACKUP_TASK_TIME_LIMIT,
)
def run_restore_job(job_id):
    run_restore(job_id)


@shared_task(name="core.run_due_scheduled_backup")
def run_due_scheduled_backup():
    job = queue_due_scheduled_backup()
    return job.pk if job is not None else None


@shared_task(name="core.sync_relay_installation")
def sync_relay_installation_task():
    """Best-effort periodic reconcile with the relay.

    Pulls entitlement changes (so a shop the operator just activated notices its
    subscription within the interval, not only on a manual sync) and pushes the
    shop name if it drifted while offline. This is the automatic "on reconnect"
    path: it no-ops when there's no relay installation or the shop is offline, and
    the next tick retries — so a shop that rarely connects syncs whenever it next
    reaches the internet.
    """
    installation = RelayInstallation.load()
    if installation is None:
        return "no relay installation"
    try:
        sync_relay_installation(installation)
    except (ImproperlyConfigured, RelayControlError) as exc:
        logger.info("relay installation sync skipped (offline or unconfigured): %s", exc)
        return "relay unavailable"
    return "synced"
