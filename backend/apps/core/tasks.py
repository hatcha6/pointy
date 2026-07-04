import logging

from celery import shared_task
from django.conf import settings
from django.core.exceptions import ImproperlyConfigured

from .backup import queue_due_scheduled_backup, run_backup, run_restore
from .models import RelayInstallation
from .relay import (
    RelayControlError,
    ensure_relay_installation,
    relay_config,
    sync_relay_installation,
)

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


@shared_task(name="core.ensure_relay_enrollment")
def ensure_relay_enrollment_task():
    """Best-effort periodic license redemption for shops that installed offline.

    A shop ships with a single-use license key (POINTY_RELAY_ENROLLMENT_TOKEN)
    but may not have internet on day one. This task keeps retrying the
    redemption so the moment the shop reaches the internet its installation
    enrolls and its subscriptions activate — independent of
    POINTY_REQUIRE_LICENSE, which only controls whether an unlicensed backend
    *blocks* the API. Deliberately limited to self-service credentials (license
    key or pre-provisioned tokens): it never falls through to admin-token
    provisioning, so a dev/operator environment doesn't enroll itself by
    accident.
    """
    if RelayInstallation.load() is not None:
        return "already enrolled"
    try:
        config = relay_config()
    except ImproperlyConfigured:
        return "relay not configured"
    self_service = bool(
        config.enrollment_token or (config.access_token and config.installation_id)
    )
    if not self_service:
        return "no license key configured"
    try:
        installation, created = ensure_relay_installation(config=config)
    except (ImproperlyConfigured, RelayControlError) as exc:
        logger.info("relay enrollment retry skipped (offline or unconfigured): %s", exc)
        return "relay unavailable"
    # Pull entitlements right away so an active subscription unlocks without
    # waiting for the hourly sync tick.
    try:
        sync_relay_installation(installation)
    except (ImproperlyConfigured, RelayControlError) as exc:
        logger.info("post-enrollment sync skipped: %s", exc)
    return "enrolled" if created else "adopted existing installation"


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
