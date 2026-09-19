from celery import shared_task
from django.conf import settings

from .services import build_collapse_plan, prepare_source, run_migration

# Preparing a 1.5 GB Access file — converting sixty tables, then replaying a
# 4.6-million-row audit log — is measured in tens of minutes, so both tasks share
# the maintenance budget that backup/restore uses rather than the default
# 25-minute request limit.
_LONG_JOB_LIMITS = {
    "soft_time_limit": settings.POINTY_BACKUP_TASK_SOFT_TIME_LIMIT,
    "time_limit": settings.POINTY_BACKUP_TASK_TIME_LIMIT,
}


@shared_task(name="migration.prepare_source", **_LONG_JOB_LIMITS)
def prepare_migration_source(source_id):
    prepare_source(source_id)


@shared_task(name="migration.run_migration_run", **_LONG_JOB_LIMITS)
def run_migration_run(run_id):
    run_migration(run_id)


@shared_task(name="migration.build_collapse_plan", **_LONG_JOB_LIMITS)
def build_collapse_plan_task(plan_id):
    """Read a whole catalogue, its purchases and its sales into one proposal.

    Shares the long-job budget for the same reason the import does: the file it
    reads is the same file, and a shop with 900,000 invoices does not get a
    smaller one because this is only a preview.
    """
    build_collapse_plan(plan_id)


@shared_task(name="migration.purge_expired_uploads")
def purge_expired_uploads():
    """Delete uploads nobody finished importing.

    Nothing else deletes one: a successful import purges its own file, and an
    owner who discards a file purges it explicitly, but an upload that was
    started and then abandoned would otherwise sit on the volume forever holding
    a full copy of the shop's history.
    """
    from .preparation.pipeline import purge_expired

    return purge_expired()
