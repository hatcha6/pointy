import hashlib
import json
import logging
import os
import shutil
import tempfile
import uuid
import zipfile
import zlib
from dataclasses import dataclass
from datetime import datetime, timedelta
from pathlib import Path, PurePosixPath

from django.apps import apps
from django.conf import settings
from django.core.management.color import no_style
from django.core.management import call_command
from django.db import DEFAULT_DB_ALIAS, connections, transaction
from django.utils import timezone
from django.utils.text import get_valid_filename

from . import backup_database
from .backup_database import (
    COPY_FORMAT,
    DATABASE_DIR_NAME,
    DATABASE_INDEX_NAME,
    FIXTURE_FORMAT,
)
from .dispatch import enqueue_or_raise
from .models import SystemBackupSchedule, SystemMaintenanceJob

logger = logging.getLogger(__name__)

ARCHIVE_ROOT = "pointy-backup"
BACKUP_FILE_PREFIX = "pointy-backup-"
BACKUP_FILE_SUFFIX = ".zip"
DATABASE_DUMP_NAME = "database.json"
MANIFEST_NAME = "manifest.json"
MEDIA_DIR_NAME = "media"
DATA_DUMP_EXCLUDES = [
    "admin.logentry",
    "auth.permission",
    "core.systemmaintenancejob",
    "contenttypes",
    "sessions.session",
]
# Space the destination must have free beyond what the archive is expected to
# need. A USB stick that fills mid-write costs the shop the previous archives
# too, because retention has already been pruned against a backup that then
# turns out to be truncated.
MINIMUM_FREE_BYTES = 128 * 1024 * 1024


class BackupVerificationError(Exception):
    pass


class BackupValidationError(Exception):
    pass


@dataclass(frozen=True)
class BackupDestination:
    label: str
    path: str
    backup_path: str
    is_available: bool
    is_writable: bool
    total_bytes: int
    free_bytes: int


def backup_destination_options():
    destinations = []
    seen = set()
    for root in _configured_backup_roots():
        if root in seen:
            continue
        seen.add(root)
        destinations.append(_describe_destination(root))
        if not root.exists() or not root.is_dir():
            continue
        try:
            children = sorted(
                child
                for child in root.iterdir()
                if child.is_dir() and not child.is_symlink()
            )
        except OSError:
            continue
        for child in children:
            resolved_child = _real_path(child)
            if resolved_child in seen:
                continue
            seen.add(resolved_child)
            destinations.append(_describe_destination(resolved_child))
    return destinations


def validate_backup_destination(raw_path):
    if not raw_path:
        raise BackupValidationError("Backup destination is required.")

    candidate = _real_path(raw_path)
    if not any(_path_is_relative_to(candidate, root) for root in _configured_backup_roots()):
        raise BackupValidationError("Backup destination is outside the allowed roots.")

    if candidate.exists() and not candidate.is_dir():
        raise BackupValidationError("Backup destination must be a folder.")

    writable_target = candidate if candidate.exists() else _nearest_existing_parent(candidate)
    if writable_target is None or not writable_target.is_dir():
        raise BackupValidationError("Backup destination parent does not exist.")
    if not os.access(writable_target, os.W_OK):
        raise BackupValidationError("Backup destination is not writable.")

    return candidate


def next_scheduled_backup_at(schedule, now=None):
    if not schedule.enabled or not schedule.destination_path:
        return None
    local_now = timezone.localtime(now or timezone.now())
    current_tz = timezone.get_current_timezone()
    scheduled = timezone.make_aware(
        datetime.combine(local_now.date(), schedule.scheduled_time),
        current_tz,
    )
    if scheduled <= local_now or schedule.last_scheduled_backup_date == local_now.date():
        # Today is spoken for -- but if today's attempt failed and a retry is
        # still owed, that retry is the next backup, not tomorrow's slot. Saying
        # "tomorrow" while the system intends to try again in half an hour is the
        # kind of small dishonesty that teaches people to stop reading the screen.
        retry_at = _next_retry_at(local_now.date(), local_now)
        if retry_at is not None:
            return retry_at
        scheduled += timedelta(days=1)
    return scheduled


def _next_retry_at(day, local_now):
    """When (if ever) today's scheduled backup gets another attempt.

    ``None`` means today is finished with: it succeeded, or it has used up its
    attempts. A job still queued or running is also ``None`` -- the caller
    already refuses to start a second one while the first is alive.
    """
    todays_jobs = scheduled_backup_jobs_for(day)
    if todays_jobs.filter(status=SystemMaintenanceJob.Status.SUCCEEDED).exists():
        return None
    if todays_jobs.count() >= settings.POINTY_BACKUP_MAX_ATTEMPTS_PER_DAY:
        return None
    latest_attempt = todays_jobs.order_by("-created_at").first()
    if latest_attempt is None:
        # The schedule says today is done but no attempt is on record. Absent
        # evidence that a backup happened, assume it did not.
        return local_now
    if latest_attempt.status != SystemMaintenanceJob.Status.FAILED:
        return None
    return max(
        latest_attempt.created_at
        + timedelta(minutes=settings.POINTY_BACKUP_RETRY_INTERVAL_MINUTES),
        local_now,
    )


def latest_maintenance_job(operation=None):
    queryset = SystemMaintenanceJob.objects.all()
    if operation is not None:
        queryset = queryset.filter(operation=operation)
    return queryset.order_by("-created_at").first()


def latest_verified_backup():
    """The newest backup that was written *and* read back successfully.

    Deliberately not "the newest succeeded job": before verification existed a
    job reported success on the strength of having written some bytes, which is
    the claim that let a shop accumulate a year of history behind eighteen
    backups and no way back. An upgraded install therefore reads as having no
    verified backup until the next one runs, which is the truth.
    """
    return (
        SystemMaintenanceJob.objects.filter(
            operation=SystemMaintenanceJob.Operation.BACKUP,
            status=SystemMaintenanceJob.Status.SUCCEEDED,
            metadata__verified=True,
        )
        .order_by("-completed_at")
        .first()
    )


def backup_health(now=None):
    """Everything the notification feed and the settings screen need to judge
    whether this shop actually has a way back."""
    now = now or timezone.now()
    schedule = SystemBackupSchedule.load()
    verified = latest_verified_backup()
    last_job = latest_maintenance_job(SystemMaintenanceJob.Operation.BACKUP)
    stale_after = timedelta(hours=settings.POINTY_BACKUP_STALE_AFTER_HOURS)
    age = None
    if verified is not None and verified.completed_at is not None:
        age = now - verified.completed_at
    return {
        "enabled": bool(schedule.enabled and schedule.destination_path),
        "latest_verified_at": verified.completed_at if verified else None,
        "latest_verified_age": age,
        "is_stale": age is None or age > stale_after,
        "stale_after_hours": settings.POINTY_BACKUP_STALE_AFTER_HOURS,
        "last_error": (
            last_job.error_message
            if last_job is not None
            and last_job.status == SystemMaintenanceJob.Status.FAILED
            else ""
        ),
        "last_attempt_at": last_job.created_at if last_job is not None else None,
    }


def reap_abandoned_maintenance_jobs(now=None):
    """Fail maintenance jobs whose worker died without unwinding.

    ``run_backup``/``run_restore`` only mark a job failed from their ``except``
    block, so anything that kills the process outright — a power cut, a container
    restart, an OOM kill, celery's hard ``time_limit`` — leaves the row in
    ``running`` for good. A ``queued`` job is lost the same way when the broker
    restarts empty and the task is never delivered. Either way the row keeps
    ``active_maintenance_job()`` truthy, which silently disables every future
    backup: the scheduled one no-ops each minute and the manual one 400s with
    "another job is already running", with no way out of the UI. On this
    deployment — on-prem, unreliable mains — that is the shop losing its backups
    to the exact outage backups exist for.

    Celery hard-kills a maintenance task at ``POINTY_BACKUP_TASK_TIME_LIMIT``, so
    a job that has not checked in since then provably cannot still be running;
    ``updated_at`` is the heartbeat, refreshed by every ``update_progress`` call.
    Failing it explicitly (rather than just ignoring it) also replaces the UI's
    permanent "backup running" spinner with an honest outcome.
    """
    cutoff = (now or timezone.now()) - timedelta(
        seconds=settings.POINTY_BACKUP_TASK_TIME_LIMIT
    )
    abandoned = SystemMaintenanceJob.objects.filter(
        status__in=[
            SystemMaintenanceJob.Status.QUEUED,
            SystemMaintenanceJob.Status.RUNNING,
        ],
        updated_at__lte=cutoff,
    )
    for job in abandoned:
        job.mark_failed("توقفت العملية قبل أن تكتمل (توقف الخادم أثناء التنفيذ).")


def active_maintenance_job():
    reap_abandoned_maintenance_jobs()
    return (
        SystemMaintenanceJob.objects.filter(
            status__in=[
                SystemMaintenanceJob.Status.QUEUED,
                SystemMaintenanceJob.Status.RUNNING,
            ]
        )
        .order_by("-created_at")
        .first()
    )


def queue_backup_job(*, user=None, source="manual", dispatch=True):
    schedule = SystemBackupSchedule.load()
    destination = validate_backup_destination(schedule.destination_path)
    _ensure_no_active_job()
    job = SystemMaintenanceJob.objects.create(
        operation=SystemMaintenanceJob.Operation.BACKUP,
        destination_path=str(destination),
        progress_message="تمت جدولة النسخ الاحتياطي.",
        **_initiator_fields(user),
        metadata={"source": source},
    )
    if dispatch:
        _dispatch_backup_job(job)
    return job


def queue_restore_job(uploaded_file, *, user=None, dispatch=True):
    if uploaded_file is None:
        raise BackupValidationError("Restore file is required.")
    if uploaded_file.size > settings.POINTY_BACKUP_RESTORE_MAX_BYTES:
        raise BackupValidationError("Restore file is larger than the allowed limit.")

    _ensure_no_active_job()
    staging_path = _save_restore_upload(uploaded_file)
    job = SystemMaintenanceJob.objects.create(
        operation=SystemMaintenanceJob.Operation.RESTORE,
        backup_file_name=get_valid_filename(uploaded_file.name or "pointy-backup.zip"),
        backup_file_path=str(staging_path),
        archive_size_bytes=staging_path.stat().st_size,
        progress_message="تمت جدولة الاستعادة.",
        **_initiator_fields(user),
        metadata={"source": "manual_upload"},
    )
    if dispatch:
        _dispatch_restore_job(job)
    return job


def run_backup(job_id):
    job = SystemMaintenanceJob.objects.get(pk=job_id)
    archive_is_trustworthy = False
    try:
        job.mark_running("بدأ تجهيز النسخة الاحتياطية.")
        schedule = SystemBackupSchedule.load()
        destination = validate_backup_destination(job.destination_path)
        backup_dir = destination / "pointy-backups"
        backup_dir.mkdir(parents=True, exist_ok=True)

        created_at = timezone.localtime()
        filename = f"{BACKUP_FILE_PREFIX}{created_at:%Y%m%d-%H%M%S}{BACKUP_FILE_SUFFIX}"
        archive_path = backup_dir / filename
        temp_archive_path = backup_dir / f".{filename}.tmp"

        _purge_stale_temp_artifacts(backup_dir)
        _assert_destination_has_room(backup_dir)

        with tempfile.TemporaryDirectory(
            prefix="pointy-backup-",
            dir=str(_staging_root()),
        ) as temp_dir_name:
            temp_dir = Path(temp_dir_name)
            job.update_progress(8, "جار تصدير قاعدة البيانات.")
            media_files = list(_iter_media_files(Path(settings.MEDIA_ROOT), backup_dir))
            manifest = {
                "format": "pointy-backup-v1",
                "created_at": created_at.isoformat(),
                "database_format": (
                    COPY_FORMAT if backup_database.database_is_postgres() else FIXTURE_FORMAT
                ),
                "database_engine": settings.DATABASES["default"]["ENGINE"],
                "media_file_count": len(media_files),
            }
            _write_backup_archive(
                archive_path=temp_archive_path,
                temp_dir=temp_dir,
                media_files=media_files,
                media_root=Path(settings.MEDIA_ROOT),
                manifest=manifest,
                job=job,
            )

        os.replace(temp_archive_path, archive_path)
        # The archive's bytes were forced to the platter inside
        # _write_backup_archive; this makes the rename itself durable, so a power
        # cut can never leave the final name pointing at nothing. Both have to
        # happen before _delete_old_backups below: retention unlinks the previous
        # (good) archives, and unlinks are journaled metadata that survive a cut
        # the new archive's data would not have.
        _fsync_directory(backup_dir)
        archive_size = archive_path.stat().st_size
        checksum = _sha256_file(archive_path)

        # Read the finished archive back before anything relies on it. Until this
        # passes, the previous archives are the shop's only copy, so verification
        # has to happen before retention prunes them -- and a failure here has to
        # fail the job, because "wrote some bytes" is exactly the claim that left
        # this shop with 18 recorded backups and nothing to restore.
        job.update_progress(94, "جار التحقق من سلامة النسخة.")
        verification = _verify_backup_archive(archive_path, manifest=manifest)
        # From here the archive has been read back and matches. Anything that
        # fails after this point -- the metadata save, a database hiccup -- must
        # leave it alone: retention has already pruned the older copies, so
        # deleting this one on the way out would destroy the shop's only backup
        # over a bookkeeping error.
        archive_is_trustworthy = True

        deleted_count = _delete_old_backups(
            backup_dir,
            keep_count=schedule.retention_count or settings.POINTY_BACKUP_RETENTION_COUNT,
        )
        job.backup_file_name = filename
        job.backup_file_path = str(archive_path)
        job.archive_size_bytes = archive_size
        job.metadata = {
            **job.metadata,
            "sha256": checksum,
            "deleted_old_backup_count": deleted_count,
            "verified": True,
            "verified_at": timezone.now().isoformat(),
            "database_format": manifest["database_format"],
            "table_count": verification["table_count"],
            "row_count": verification["row_count"],
            "media_file_count": manifest["media_file_count"],
        }
        job.save(
            update_fields=[
                "backup_file_name",
                "backup_file_path",
                "archive_size_bytes",
                "metadata",
                "updated_at",
            ]
        )
        job.mark_succeeded("اكتمل النسخ الاحتياطي.")
    except Exception as exception:
        if "temp_archive_path" in locals() and temp_archive_path.exists():
            temp_archive_path.unlink(missing_ok=True)
        # Verification runs after the rename, so a failure there leaves a
        # published filename over bytes we could not vouch for. Remove it: an
        # archive offered in the restore picker is a promise, and a half-written
        # one is worse than an absent one because it looks like a way back.
        if (
            not archive_is_trustworthy
            and "archive_path" in locals()
            and archive_path.exists()
        ):
            archive_path.unlink(missing_ok=True)
        job.mark_failed(exception)
        raise


def run_restore(job_id):
    job = SystemMaintenanceJob.objects.get(pk=job_id)
    archive_path = Path(job.backup_file_path)
    try:
        job.mark_running("بدأ فحص ملف الاستعادة.")
        if not archive_path.exists():
            raise BackupValidationError("Restore archive was not found.")

        with tempfile.TemporaryDirectory(
            prefix="pointy-restore-",
            dir=str(_staging_root()),
        ) as temp_dir_name:
            temp_dir = Path(temp_dir_name)
            job.update_progress(12, "جار فحص محتويات النسخة.")
            with zipfile.ZipFile(archive_path) as archive:
                _validate_restore_archive(archive)
                # Prove the whole archive reads before touching the live
                # database: a CRC failure discovered half way through a restore
                # would already have truncated the shop's real data.
                corrupt_entry = archive.testzip()
                if corrupt_entry is not None:
                    raise BackupValidationError(
                        f"Restore archive is corrupt at {corrupt_entry}."
                    )
                manifest = json.loads(archive.read(f"{ARCHIVE_ROOT}/{MANIFEST_NAME}"))
                if manifest.get("database_format") == COPY_FORMAT:
                    index = json.loads(
                        archive.read(
                            f"{ARCHIVE_ROOT}/{DATABASE_DIR_NAME}/{DATABASE_INDEX_NAME}"
                        )
                    )
                    problems = backup_database.verify_database_export(archive, index)
                    if problems:
                        raise BackupValidationError(
                            "Restore archive failed verification: "
                            + "; ".join(problems[:5])
                        )
                    job.update_progress(35, "جار استعادة قاعدة البيانات.")
                    backup_database.restore_database_export(
                        archive,
                        index,
                        progress=lambda fraction: job.update_progress(
                            35 + round(fraction * 45), "جار استعادة قاعدة البيانات."
                        ),
                    )
                    job.update_progress(82, "جار استعادة الملفات والصور.")
                    _extract_media(archive, temp_dir)
                else:
                    archive.extractall(temp_dir)
                    database_dump_path = temp_dir / ARCHIVE_ROOT / DATABASE_DUMP_NAME
                    if not database_dump_path.exists():
                        raise BackupValidationError(
                            "Restore archive has no database dump."
                        )
                    job.update_progress(35, "جار تهيئة قاعدة البيانات.")
                    _flush_restorable_data()
                    job.update_progress(58, "جار استعادة قاعدة البيانات.")
                    call_command("loaddata", str(database_dump_path), verbosity=0)
                    job.update_progress(84, "جار استعادة الملفات والصور.")

            _replace_media_root(temp_dir / ARCHIVE_ROOT / MEDIA_DIR_NAME)

        job.mark_succeeded("اكتملت الاستعادة.")
    except Exception as exception:
        job.mark_failed(exception)
        raise
    finally:
        archive_path.unlink(missing_ok=True)


def scheduled_backup_jobs_for(day):
    return SystemMaintenanceJob.objects.filter(
        operation=SystemMaintenanceJob.Operation.BACKUP,
        metadata__source="schedule",
        metadata__scheduled_for=day.isoformat(),
    )


def _should_retry_today(day, local_now):
    """Whether a failed scheduled backup gets another go before tomorrow.

    Marking the day done at queue time meant one failure cost the shop a whole
    day of backups, silently -- and the failures that matter here (a USB stick
    not plugged in yet, the database busy, a container restarting mid-run) are
    exactly the kind that clear on their own within the hour. Retry a bounded
    number of times, spaced out, so a permanently broken destination still can't
    turn into a queue storm.
    """
    retry_at = _next_retry_at(day, local_now)
    return retry_at is not None and local_now >= retry_at


def queue_due_scheduled_backup(now=None):
    local_now = timezone.localtime(now or timezone.now())
    with transaction.atomic():
        SystemBackupSchedule.load()
        schedule = SystemBackupSchedule.objects.select_for_update().get(pk=1)
        if (
            not schedule.enabled
            or not schedule.destination_path
            or local_now.time() < schedule.scheduled_time
            or active_maintenance_job() is not None
        ):
            return None
        if schedule.last_scheduled_backup_date == local_now.date() and not (
            _should_retry_today(local_now.date(), local_now)
        ):
            return None

        validate_backup_destination(schedule.destination_path)
        job = SystemMaintenanceJob.objects.create(
            operation=SystemMaintenanceJob.Operation.BACKUP,
            destination_path=schedule.destination_path,
            progress_message="تمت جدولة النسخ الاحتياطي التلقائي.",
            metadata={
                "source": "schedule",
                "scheduled_for": local_now.date().isoformat(),
            },
        )
        schedule.last_scheduled_backup_date = local_now.date()
        schedule.save(update_fields=["last_scheduled_backup_date", "updated_at"])

    _dispatch_backup_job(job)
    return job


def _dispatch_backup_job(job):
    try:
        from .tasks import run_backup_job

        enqueue_or_raise(run_backup_job, job.pk)
    except Exception as exception:
        job.mark_failed("تعذر إرسال النسخ الاحتياطي إلى عامل الخلفية.")
        raise BackupValidationError(str(exception)) from exception


def _dispatch_restore_job(job):
    try:
        from .tasks import run_restore_job

        enqueue_or_raise(run_restore_job, job.pk)
    except Exception as exception:
        job.mark_failed("تعذر إرسال الاستعادة إلى عامل الخلفية.")
        raise BackupValidationError(str(exception)) from exception


def _ensure_no_active_job():
    active_job = active_maintenance_job()
    if active_job is not None:
        raise BackupValidationError("Another backup or restore job is already running.")


def _initiator_fields(user):
    if not getattr(user, "is_authenticated", False):
        return {}
    return {
        "initiated_by_user_id": user.pk,
        "initiated_by_username": user.get_username(),
    }


def _write_database_dump(database_dump_path):
    backup_database.write_fixture_export(
        database_dump_path,
        excludes=DATA_DUMP_EXCLUDES,
    )


def _purge_stale_temp_artifacts(backup_dir):
    """Clear the debris a killed backup leaves on the destination.

    A worker that dies mid-write -- the power cut this whole feature exists for
    -- never reaches the ``except`` that unlinks its partial archive, and its
    staging directory outlives the ``TemporaryDirectory`` that was supposed to
    remove it. On a USB stick that is a growing pile of half-archives, each the
    size of a real one, quietly eating the room the next backup needs. Anything
    older than the hard task time limit provably belongs to a dead run.
    """
    cutoff = timezone.now().timestamp() - settings.POINTY_BACKUP_TASK_TIME_LIMIT
    for leftover in backup_dir.glob(f".{BACKUP_FILE_PREFIX}*{BACKUP_FILE_SUFFIX}.tmp"):
        try:
            if leftover.is_file() and leftover.stat().st_mtime < cutoff:
                leftover.unlink(missing_ok=True)
        except OSError:
            logger.warning("Could not remove stale backup temp file %s.", leftover)

    staging_root = _staging_root()
    for leftover in staging_root.glob("pointy-backup-*"):
        try:
            if leftover.is_dir() and leftover.stat().st_mtime < cutoff:
                shutil.rmtree(leftover, ignore_errors=True)
        except OSError:
            logger.warning("Could not remove stale backup staging dir %s.", leftover)


def _assert_destination_has_room(backup_dir):
    """Fail before writing rather than half way through.

    Filling the destination mid-write is the worst outcome available: the new
    archive is truncated and, without this, retention has already deleted the
    good ones. The last archive's size is the best available estimate of the next
    one's; with no history, insist on the floor.
    """
    try:
        usage = shutil.disk_usage(backup_dir)
    except OSError as exception:
        raise BackupValidationError(
            "Backup destination is not reachable."
        ) from exception

    previous = [
        path.stat().st_size
        for path in backup_dir.glob(f"{BACKUP_FILE_PREFIX}*{BACKUP_FILE_SUFFIX}")
        if path.is_file()
    ]
    # Room for the new archive alongside the ones already there: retention only
    # prunes after this one is written and verified.
    needed = max(previous, default=0) + MINIMUM_FREE_BYTES
    if usage.free < needed:
        raise BackupValidationError(
            f"Backup destination has {usage.free // (1024 * 1024)} MB free; "
            f"about {needed // (1024 * 1024)} MB is needed."
        )


def _verify_backup_archive(archive_path, *, manifest):
    """Prove the archive on disk is readable, complete and internally consistent.

    Three layers, cheapest first: every entry's CRC (catches truncation and bit
    rot), the manifest and index parsing at all, and then the per-table row
    counts and digests recorded while writing.
    """
    with zipfile.ZipFile(archive_path) as archive:
        try:
            corrupt_entry = archive.testzip()
        except (zlib.error, zipfile.BadZipFile) as exception:
            # testzip() NAMES the first bad entry when a CRC mismatches, but a
            # malformed deflate stream raises out of it instead. Same corruption,
            # two different exits — and only the named one was handled, so a
            # mangled archive escaped as a raw zlib.error and skipped the "fail
            # the job, spare the old backups" path this function exists to take.
            raise BackupVerificationError(
                "Backup archive is corrupt and could not be decompressed."
            ) from exception
        if corrupt_entry is not None:
            raise BackupVerificationError(
                f"Backup archive is corrupt at {corrupt_entry}."
            )

        names = set(archive.namelist())
        manifest_name = f"{ARCHIVE_ROOT}/{MANIFEST_NAME}"
        if manifest_name not in names:
            raise BackupVerificationError("Backup archive has no manifest.")
        try:
            stored_manifest = json.loads(archive.read(manifest_name))
        except ValueError as exception:
            raise BackupVerificationError(
                "Backup archive manifest is not readable."
            ) from exception

        media_count = sum(
            1
            for name in names
            if name.startswith(f"{ARCHIVE_ROOT}/{MEDIA_DIR_NAME}/") and not name.endswith("/")
        )
        if media_count != stored_manifest.get("media_file_count"):
            raise BackupVerificationError(
                f"Backup archive holds {media_count} media files, "
                f"{stored_manifest.get('media_file_count')} expected."
            )

        if stored_manifest.get("database_format") == COPY_FORMAT:
            index_name = f"{ARCHIVE_ROOT}/{DATABASE_DIR_NAME}/{DATABASE_INDEX_NAME}"
            if index_name not in names:
                raise BackupVerificationError("Backup archive has no database index.")
            index = json.loads(archive.read(index_name))
            problems = backup_database.verify_database_export(archive, index)
            if problems:
                raise BackupVerificationError(
                    "Backup archive failed verification: " + "; ".join(problems[:5])
                )
            return {
                "table_count": len(index.get("tables", [])),
                "row_count": sum(entry["rows"] for entry in index.get("tables", [])),
            }

        if f"{ARCHIVE_ROOT}/{DATABASE_DUMP_NAME}" not in names:
            raise BackupVerificationError("Backup archive has no database dump.")
        with archive.open(f"{ARCHIVE_ROOT}/{DATABASE_DUMP_NAME}") as handle:
            try:
                payload = json.load(handle)
            except ValueError as exception:
                raise BackupVerificationError(
                    "Backup archive database dump is not valid JSON."
                ) from exception
        return {"table_count": 0, "row_count": len(payload)}


def _flush_restorable_data():
    connection = connections[DEFAULT_DB_ALIAS]
    preserved_tables = {
        SystemMaintenanceJob._meta.db_table,
        "auth_permission",
        "django_content_type",
    }
    tables = sorted(
        {
            model._meta.db_table
            for model in apps.get_models(include_auto_created=True)
            if model._meta.managed and model._meta.db_table not in preserved_tables
        }
    )
    sql_statements = connection.ops.sql_flush(
        no_style(),
        tables,
        reset_sequences=True,
        allow_cascade=True,
    )
    with connection.constraint_checks_disabled(), connection.cursor() as cursor:
        for sql in sql_statements:
            cursor.execute(sql)


def _write_backup_archive(
    *,
    archive_path,
    temp_dir,
    media_files,
    media_root,
    manifest,
    job,
):
    with archive_path.open("wb") as archive_file:
        with zipfile.ZipFile(
            archive_file,
            mode="w",
            compression=zipfile.ZIP_DEFLATED,
            compresslevel=6,
        ) as archive:
            archive.writestr(
                f"{ARCHIVE_ROOT}/{MANIFEST_NAME}",
                json.dumps(manifest, ensure_ascii=False, indent=2),
            )
            if manifest["database_format"] == COPY_FORMAT:
                index = backup_database.write_database_export(
                    archive,
                    archive_root=ARCHIVE_ROOT,
                    # Tables stream straight into the archive, so the export owns
                    # the first stretch of the bar rather than finishing invisibly
                    # at 8% the way the fixture dump used to.
                    progress=lambda fraction: job.update_progress(
                        8 + round(fraction * 34), "جار تصدير قاعدة البيانات."
                    ),
                )
                archive.writestr(
                    f"{ARCHIVE_ROOT}/{DATABASE_DIR_NAME}/{DATABASE_INDEX_NAME}",
                    json.dumps(index, ensure_ascii=False),
                )
            else:
                database_dump_path = temp_dir / DATABASE_DUMP_NAME
                _write_database_dump(database_dump_path)
                archive.write(
                    database_dump_path, f"{ARCHIVE_ROOT}/{DATABASE_DUMP_NAME}"
                )

            job.update_progress(45, "جار ضغط الملفات.")
            total_media_files = max(len(media_files), 1)
            for index_position, media_file in enumerate(media_files, start=1):
                relative_path = media_file.relative_to(media_root).as_posix()
                archive.write(
                    media_file, f"{ARCHIVE_ROOT}/{MEDIA_DIR_NAME}/{relative_path}"
                )
                if index_position == len(media_files) or index_position % 20 == 0:
                    percent = 45 + round((index_position / total_media_files) * 47)
                    job.update_progress(percent, "جار ضغط الملفات.")
        # Closing the ZipFile only hands the bytes to the OS page cache. Shops
        # back up to USB sticks on unreliable mains power, so force them to the
        # device before the caller renames this into place and prunes the older
        # archives. A failure here fails the backup: an archive we cannot promise
        # is on disk must not be reported as one.
        archive_file.flush()
        os.fsync(archive_file.fileno())


def _iter_media_files(media_root, backup_dir):
    if not media_root.exists():
        return
    resolved_backup_dir = _real_path(backup_dir)
    for file_path in media_root.rglob("*"):
        if not file_path.is_file() or file_path.is_symlink():
            continue
        resolved_file = _real_path(file_path)
        if _path_is_relative_to(resolved_file, resolved_backup_dir):
            continue
        yield file_path


def _validate_restore_archive(archive):
    total_size = 0
    has_manifest = False
    has_database = False
    for info in archive.infolist():
        path = PurePosixPath(info.filename)
        parts = path.parts
        if info.file_size < 0:
            raise BackupValidationError("Restore archive has an invalid file entry.")
        total_size += info.file_size
        if total_size > settings.POINTY_BACKUP_RESTORE_MAX_BYTES:
            raise BackupValidationError("Restore archive is larger than the allowed limit.")
        if (
            not parts
            or parts[0] != ARCHIVE_ROOT
            or path.is_absolute()
            or any(part in {"", ".", ".."} for part in parts)
        ):
            raise BackupValidationError("Restore archive has unsafe file paths.")
        if info.filename == f"{ARCHIVE_ROOT}/{MANIFEST_NAME}":
            has_manifest = True
        if info.filename in {
            f"{ARCHIVE_ROOT}/{DATABASE_DUMP_NAME}",
            f"{ARCHIVE_ROOT}/{DATABASE_DIR_NAME}/{DATABASE_INDEX_NAME}",
        }:
            has_database = True
    if not has_manifest or not has_database:
        raise BackupValidationError("Restore archive is not a Pointy backup.")


def _extract_media(archive, temp_dir):
    """Unpack only the media half of an archive.

    The COPY restore streams the database straight out of the zip, so extracting
    everything would double-write the largest part of the archive to the staging
    disk for no reason.
    """
    prefix = f"{ARCHIVE_ROOT}/{MEDIA_DIR_NAME}/"
    members = [name for name in archive.namelist() if name.startswith(prefix)]
    (temp_dir / ARCHIVE_ROOT / MEDIA_DIR_NAME).mkdir(parents=True, exist_ok=True)
    if members:
        archive.extractall(temp_dir, members=members)


def _replace_media_root(media_source):
    media_root = Path(settings.MEDIA_ROOT)
    media_root.parent.mkdir(parents=True, exist_ok=True)
    staging_root = _staging_root()
    old_media_holder = Path(
        tempfile.mkdtemp(prefix="pointy-old-media-", dir=str(staging_root))
    )
    old_media_path = old_media_holder / "media"
    try:
        if media_root.exists():
            shutil.move(str(media_root), str(old_media_path))
        if media_source.exists():
            shutil.copytree(media_source, media_root)
        else:
            media_root.mkdir(parents=True, exist_ok=True)
    except Exception:
        if media_root.exists():
            shutil.rmtree(media_root, ignore_errors=True)
        if old_media_path.exists():
            shutil.move(str(old_media_path), str(media_root))
        raise
    finally:
        shutil.rmtree(old_media_holder, ignore_errors=True)


def _fsync_directory(path):
    """Persist a directory entry (the rename) as well as the file's contents.

    Windows cannot open a directory as a file and journals renames itself, and
    some removable filesystems reject fsync on directories. Neither is a reason
    to fail a backup whose bytes are already durable, so those are logged and
    tolerated.
    """
    if os.name == "nt":
        return
    try:
        directory_fd = os.open(str(path), os.O_RDONLY)
    except OSError:
        logger.warning("Could not open %s to flush the backup directory entry.", path)
        return
    try:
        os.fsync(directory_fd)
    except OSError:
        logger.warning("Filesystem at %s does not support flushing directories.", path)
    finally:
        os.close(directory_fd)


def _delete_old_backups(backup_dir, *, keep_count):
    backups = sorted(
        [
            file_path
            for file_path in backup_dir.glob(f"{BACKUP_FILE_PREFIX}*{BACKUP_FILE_SUFFIX}")
            if file_path.is_file()
        ],
        key=lambda file_path: file_path.stat().st_mtime,
        reverse=True,
    )
    deleted_count = 0
    for file_path in backups[keep_count:]:
        file_path.unlink(missing_ok=True)
        deleted_count += 1
    return deleted_count


def _save_restore_upload(uploaded_file):
    staging_root = _staging_root()
    filename = get_valid_filename(uploaded_file.name or "pointy-backup.zip")
    suffix = Path(filename).suffix or BACKUP_FILE_SUFFIX
    staging_path = staging_root / f"restore-{uuid.uuid4().hex}{suffix}"
    with staging_path.open("wb") as output:
        for chunk in uploaded_file.chunks():
            output.write(chunk)
    return staging_path


def _describe_destination(path):
    nearest = path if path.exists() else _nearest_existing_parent(path)
    total_bytes = 0
    free_bytes = 0
    if nearest is not None:
        try:
            usage = shutil.disk_usage(nearest)
            total_bytes = usage.total
            free_bytes = usage.free
        except OSError:
            pass
    is_available = path.exists() or nearest is not None
    writable_target = path if path.exists() else nearest
    is_writable = bool(
        is_available and writable_target is not None and os.access(writable_target, os.W_OK)
    )
    return BackupDestination(
        label=path.name or str(path),
        path=str(path),
        backup_path=str(path / "pointy-backups"),
        is_available=is_available,
        is_writable=is_writable,
        total_bytes=total_bytes,
        free_bytes=free_bytes,
    )


def _configured_backup_roots():
    roots = []
    for raw_root in getattr(settings, "POINTY_BACKUP_ALLOWED_ROOTS", []):
        raw_root = str(raw_root).strip()
        if not raw_root:
            continue
        roots.append(_real_path(raw_root))
    return roots


def _staging_root():
    staging_root = Path(settings.POINTY_BACKUP_STAGING_ROOT)
    staging_root.mkdir(parents=True, exist_ok=True)
    return staging_root


def _nearest_existing_parent(path):
    current = Path(path)
    while current != current.parent:
        if current.exists():
            return current
        current = current.parent
    return current if current.exists() else None


def _path_is_relative_to(path, parent):
    path = _real_path(path)
    parent = _real_path(parent)
    return path == parent or parent in path.parents


def _real_path(path):
    return Path(os.path.realpath(Path(path).expanduser()))


def _sha256_file(path):
    digest = hashlib.sha256()
    with Path(path).open("rb") as input_file:
        for chunk in iter(lambda: input_file.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()
