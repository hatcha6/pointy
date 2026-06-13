from celery import shared_task

from .models import BioTimeConnection
from .services import sync_biotime


@shared_task(name="attendance.sync_biotime")
def sync_biotime_task():
    """Periodic BioTime pull; schedule via celery beat when desired."""
    connection = BioTimeConnection.load()
    if not connection.is_enabled or not connection.is_configured:
        return {"skipped": True}
    return sync_biotime(connection=connection)
