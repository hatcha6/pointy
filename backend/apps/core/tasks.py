from celery import shared_task
from django.conf import settings

from .backup import queue_due_scheduled_backup, run_backup, run_restore


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
