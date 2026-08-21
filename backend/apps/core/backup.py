import hashlib
import json
import logging
import os
import shutil
import tempfile
import uuid
import zipfile
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
        scheduled += timedelta(days=1)
    return scheduled


def latest_maintenance_job(operation=None):
    queryset = SystemMaintenanceJob.objects.all()
    if operation is not None:
        queryset = queryset.filter(operation=operation)
    return queryset.order_by("-created_at").first()


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

        with tempfile.TemporaryDirectory(
            prefix="pointy-backup-",
            dir=str(_staging_root()),
        ) as temp_dir_name:
            temp_dir = Path(temp_dir_name)
            database_dump_path = temp_dir / DATABASE_DUMP_NAME
            job.update_progress(8, "جار تصدير قاعدة البيانات.")
            _write_database_dump(database_dump_path)

            job.update_progress(20, "جار ضغط الملفات.")
            media_files = list(_iter_media_files(Path(settings.MEDIA_ROOT), backup_dir))
            manifest = {
                "format": "pointy-backup-v1",
                "created_at": created_at.isoformat(),
                "database_format": "django-fixture-json",
                "database_engine": settings.DATABASES["default"]["ENGINE"],
                "media_file_count": len(media_files),
            }
            _write_backup_archive(
                archive_path=temp_archive_path,
                database_dump_path=database_dump_path,
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
                archive.extractall(temp_dir)

            payload_root = temp_dir / ARCHIVE_ROOT
            database_dump_path = payload_root / DATABASE_DUMP_NAME
            media_source = payload_root / MEDIA_DIR_NAME
            if not database_dump_path.exists():
                raise BackupValidationError("Restore archive has no database dump.")

            job.update_progress(35, "جار تهيئة قاعدة البيانات.")
            _flush_restorable_data()
            job.update_progress(58, "جار استعادة قاعدة البيانات.")
            call_command("loaddata", str(database_dump_path), verbosity=0)
            job.update_progress(84, "جار استعادة الملفات والصور.")
            _replace_media_root(media_source)

        job.mark_succeeded("اكتملت الاستعادة.")
    except Exception as exception:
        job.mark_failed(exception)
        raise
    finally:
        archive_path.unlink(missing_ok=True)


def queue_due_scheduled_backup(now=None):
    local_now = timezone.localtime(now or timezone.now())
    with transaction.atomic():
        SystemBackupSchedule.load()
        schedule = SystemBackupSchedule.objects.select_for_update().get(pk=1)
        if (
            not schedule.enabled
            or not schedule.destination_path
            or schedule.last_scheduled_backup_date == local_now.date()
            or local_now.time() < schedule.scheduled_time
            or active_maintenance_job() is not None
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
    with database_dump_path.open("w", encoding="utf-8") as output:
        call_command(
            "dumpdata",
            exclude=DATA_DUMP_EXCLUDES,
            use_natural_foreign_keys=True,
            verbosity=0,
            stdout=output,
        )


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
    database_dump_path,
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
            archive.write(database_dump_path, f"{ARCHIVE_ROOT}/{DATABASE_DUMP_NAME}")
            total_media_files = max(len(media_files), 1)
            for index, media_file in enumerate(media_files, start=1):
                relative_path = media_file.relative_to(media_root).as_posix()
                archive.write(
                    media_file, f"{ARCHIVE_ROOT}/{MEDIA_DIR_NAME}/{relative_path}"
                )
                if index == len(media_files) or index % 20 == 0:
                    percent = 20 + round((index / total_media_files) * 72)
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
        if info.filename == f"{ARCHIVE_ROOT}/{DATABASE_DUMP_NAME}":
            has_database = True
    if not has_manifest or not has_database:
        raise BackupValidationError("Restore archive is not a Pointy backup.")


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
