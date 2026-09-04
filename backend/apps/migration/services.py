"""Orchestration entrypoints for the data-migration feature.

Two things get queued here, both to a Celery worker and both with the same "mark
it failed if the broker is unreachable" guard ``apps.core.backup`` uses:

* **preparation** — converting, reconstructing and identifying an uploaded file.
  Runs once per upload, and is why a source is not importable the instant its
  last byte arrives.
* **runs** — a dry run or an import against a prepared file.

Nothing here opens a network connection to anything. The source of a migration is
a file on disk.
"""

from __future__ import annotations

from django.utils import timezone
from rest_framework.serializers import ValidationError

from apps.analytics.models import AnalyticsEvent
from apps.analytics.services import record_domain_event
from apps.core.dispatch import enqueue_or_raise

from .connectors import get_connector
from .engine import MigrationEngine
from .entity_plan import ENTITY_PLAN_BY_TYPE
from .exceptions import CompatibilityError, MigrationError
from .models import MigrationRun, MigrationSource
from .preparation import pipeline


def record_migration_event(*, name, user, entity_id, attributes=None, metrics=None, severity=None):
    record_domain_event(
        name=name,
        event_type=AnalyticsEvent.EventType.AUDIT,
        severity=severity or AnalyticsEvent.Severity.INFO,
        user=_event_user(user),
        entity_type="migration_source",
        entity_id=entity_id,
        attributes=attributes or {},
        metrics=metrics or {},
    )


def _event_user(user):
    if user is not None and not getattr(user, "is_authenticated", False):
        return None
    return user


def _initiator_fields(user):
    if not getattr(user, "is_authenticated", False):
        return {}
    return {
        "initiated_by_user_id": user.pk,
        "initiated_by_username": user.get_username(),
    }


def queue_preparation(source: MigrationSource, *, user=None, dispatch=True) -> MigrationSource:
    """Hand a fully-received upload to the preparation pipeline."""
    if source.upload_state == MigrationSource.UploadState.PURGED:
        raise ValidationError({"detail": "تم حذف هذا الملف من الخادم."})
    if source.upload_state == MigrationSource.UploadState.UPLOADING:
        raise ValidationError({"detail": "لم يكتمل رفع الملف بعد."})

    source.upload_state = MigrationSource.UploadState.UPLOADED
    source.error_message = ""
    source.stages = []
    source.save(update_fields=["upload_state", "error_message", "stages", "updated_at"])
    record_migration_event(
        name="migration.upload.prepare_queued",
        user=user,
        entity_id=source.pk,
        attributes={"filename": source.original_filename},
        metrics={"size_bytes": source.declared_size_bytes},
    )
    if dispatch:
        _dispatch_preparation(source)
    return source


def _dispatch_preparation(source: MigrationSource) -> None:
    try:
        from .tasks import prepare_migration_source

        enqueue_or_raise(prepare_migration_source, source.pk)
    except Exception as exc:  # noqa: BLE001 - broker unreachable etc.
        source.upload_state = MigrationSource.UploadState.FAILED
        source.error_message = "تعذر إرسال الملف إلى عامل الخلفية."
        source.save(update_fields=["upload_state", "error_message", "updated_at"])
        raise ValidationError({"detail": str(exc)}) from exc


def prepare_source(source_id: int) -> None:
    """Worker entrypoint for preparation."""
    source = MigrationSource.objects.filter(pk=source_id).first()
    if source is None or source.is_purged:
        return
    pipeline.prepare_source(source)
    record_migration_event(
        name="migration.upload.prepared",
        user=None,
        entity_id=source.pk,
        attributes={
            "state": source.upload_state,
            "system_key": source.system_key,
            "detected_version": source.detected_version,
        },
        severity=(
            AnalyticsEvent.Severity.WARNING
            if source.upload_state == MigrationSource.UploadState.FAILED
            else AnalyticsEvent.Severity.INFO
        ),
    )


def discard_source(source: MigrationSource, *, user=None) -> int:
    """Delete a source's files on request. Returns bytes freed."""
    freed = pipeline.purge(source, reason="discarded")
    record_migration_event(
        name="migration.upload.discarded",
        user=user,
        entity_id=source.pk,
        metrics={"freed_bytes": freed},
    )
    return freed


def _ensure_no_active_run() -> None:
    active = MigrationRun.objects.filter(
        status__in=[MigrationRun.Status.QUEUED, MigrationRun.Status.RUNNING]
    ).exists()
    if active:
        raise ValidationError({"detail": "A migration run is already in progress."})


def queue_migration_run(
    source, *, mode, entities=None, options=None, user=None, dispatch=True
) -> MigrationRun:
    if not source.is_ready:
        raise ValidationError({"detail": "هذا الملف غير جاهز للنقل بعد."})
    connector = get_connector(source.system_key)
    if connector is None:
        raise ValidationError({"detail": f"Unknown source system: {source.system_key}."})

    supported = set(connector.supported_entities)
    requested = [entity for entity in (entities or []) if entity in ENTITY_PLAN_BY_TYPE]
    unsupported = [entity for entity in requested if entity not in supported]
    if unsupported:
        raise ValidationError({"detail": f"This system cannot transfer: {', '.join(unsupported)}."})
    selected = requested or list(supported)

    _ensure_no_active_run()
    run = MigrationRun.objects.create(
        source=source,
        mode=mode,
        selected_entities=selected,
        options=dict(options or {}),
        progress_message="تمت جدولة العملية.",
        **_initiator_fields(user),
    )
    record_migration_event(
        name="migration.run.queued",
        user=user,
        entity_id=source.pk,
        attributes={"mode": mode, "run_id": run.pk, "entities": selected},
    )
    if dispatch:
        _dispatch_run(run)
    return run


def _dispatch_run(run: MigrationRun) -> None:
    try:
        from .tasks import run_migration_run

        enqueue_or_raise(run_migration_run, run.pk)
    except Exception as exc:  # noqa: BLE001 - broker unreachable etc.
        run.mark_failed("تعذر إرسال العملية إلى عامل الخلفية.")
        raise ValidationError({"detail": str(exc)}) from exc


def run_migration(run_id: int) -> None:
    """Worker entrypoint: execute the engine for one run (idempotent)."""
    run = MigrationRun.objects.select_related("source").filter(pk=run_id).first()
    if run is None or not run.is_active:
        return

    run.mark_running("بدأت العملية…")
    try:
        MigrationEngine(run).execute()
    except CompatibilityError as exc:
        run.mark_failed(str(exc))
        _record_outcome(run, failed=True)
        return
    except MigrationError as exc:
        run.mark_failed(str(exc))
        _record_outcome(run, failed=True)
        return
    except Exception as exc:  # noqa: BLE001 - never leave a run stuck "running"
        run.mark_failed(str(exc)[:480])
        _record_outcome(run, failed=True)
        return

    _finalize_source(run)
    _record_outcome(run, failed=False)


def _finalize_source(run: MigrationRun) -> None:
    """Record the run, and delete the file once it has done its job.

    The shop's entire trading history is sitting on this disk. It is here to be
    imported, and after a clean import there is no reason for it to still exist —
    the identity map on the source row is what a re-import needs, not the bytes.
    A *partial* import keeps the file: the owner may fix something and re-run,
    and making them re-upload a gigabyte to do that would be its own cruelty.
    """
    source = run.source
    source.last_run_at = timezone.now()
    source.save(update_fields=["last_run_at", "updated_at"])
    if (
        run.mode == MigrationRun.Mode.IMPORT
        and run.status == MigrationRun.Status.SUCCEEDED
        and not (run.options or {}).get("keep_file")
    ):
        freed = pipeline.purge(source, reason="imported")
        record_migration_event(
            name="migration.upload.purged",
            user=None,
            entity_id=source.pk,
            attributes={"reason": "imported"},
            metrics={"freed_bytes": freed},
        )


def _record_outcome(run: MigrationRun, *, failed: bool) -> None:
    record_migration_event(
        name="migration.run.completed",
        user=None,
        entity_id=run.source_id,
        attributes={"mode": run.mode, "status": run.status, "run_id": run.pk},
        metrics={
            "created": sum(b.get("created", 0) for b in (run.summary or {}).values()),
            "updated": sum(b.get("updated", 0) for b in (run.summary or {}).values()),
            "failed": sum(b.get("failed", 0) for b in (run.summary or {}).values()),
        },
        severity=(AnalyticsEvent.Severity.WARNING if failed else AnalyticsEvent.Severity.INFO),
    )
