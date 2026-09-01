import logging

from celery import shared_task

from .models import BioTimeConnection
from .services import claim_sync_slot, sync_biotime

logger = logging.getLogger(__name__)


@shared_task(name="attendance.sync_biotime")
def sync_biotime_task(*, claimed=False):
    """Pull BioTime punches on a worker.

    Runs both from celery beat (hourly) and from the settings screen's Sync
    button. A backfill against a real server takes minutes, which is longer than
    the relay's request timeout, so the button dispatches here rather than
    holding the HTTP request open.

    ``claimed`` is set by the view, which takes the run lock synchronously so it
    can answer "already running" instead of queueing a second pull that would
    only duplicate the first one's load on a slow device.
    """
    connection = BioTimeConnection.load()
    if not connection.is_enabled or not connection.is_configured:
        _release(connection, claimed)
        return {"skipped": True}
    if not claimed and not claim_sync_slot(connection):
        return {"skipped": True, "reason": "already_running"}
    return sync_biotime(connection=connection, claim=False)


def _release(connection, claimed):
    """Drop a lock the caller took for work this task then declined to do.

    Claiming overwrote the previous status, so restore the one the row's own
    history implies rather than reporting a shop that has synced before as
    never-synced.
    """
    if not claimed or not connection.is_syncing:
        return
    connection.last_sync_status = (
        BioTimeConnection.SyncStatus.OK
        if connection.last_synced_at is not None
        else BioTimeConnection.SyncStatus.NEVER
    )
    connection.sync_started_at = None
    connection.save(
        update_fields=["last_sync_status", "sync_started_at", "updated_at"]
    )
