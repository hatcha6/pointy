from celery import shared_task
from django.conf import settings

from .services import run_migration


@shared_task(
    name="migration.run_migration_run",
    # A full import can run long; share the maintenance task budget used by
    # backup/restore rather than the default 25-minute request limit.
    soft_time_limit=settings.POINTY_BACKUP_TASK_SOFT_TIME_LIMIT,
    time_limit=settings.POINTY_BACKUP_TASK_TIME_LIMIT,
)
def run_migration_run(run_id):
    run_migration(run_id)
