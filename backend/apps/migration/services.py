"""Orchestration entrypoints for the data-migration feature.

Mirrors ``apps.core.backup``: the API layer calls ``test_connection`` /
``run_compatibility`` synchronously, and ``queue_migration_run`` creates a
``MigrationRun`` then hands it to a Celery worker via ``_dispatch_run`` (with the
same "mark the job failed if the broker is unreachable" guard). The worker calls
``run_migration``.
"""

from __future__ import annotations

from django.utils import timezone
from rest_framework.serializers import ValidationError

from apps.analytics.models import AnalyticsEvent
from apps.analytics.services import record_domain_event

from .connectors import get_connector
from .engine import MigrationEngine
from .entity_plan import ENTITY_PLAN_BY_TYPE
from .exceptions import CompatibilityError, MigrationError
from .models import MigrationRun, MigrationSource
from .transports import build_transport


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


def test_connection(source: MigrationSource) -> dict:
    """Open the source and list its tables — a fast "can we even connect?" probe."""
    transport = build_transport(source.transport_kind, source.connection_dict())
    try:
        with transport:
            tables = transport.list_tables()
    except MigrationError as exc:
        raise ValidationError({"detail": str(exc)}) from exc
    return {"ok": True, "table_count": len(tables), "tables": sorted(tables)[:100]}


def run_compatibility(source: MigrationSource, *, user=None) -> dict:
    """Introspect the live schema and persist a compatibility report."""
    connector = get_connector(source.system_key)
    if connector is None:
        raise ValidationError({"detail": f"Unknown source system: {source.system_key}."})
    transport = build_transport(source.transport_kind, source.connection_dict())
    try:
        with transport:
            report = connector.check_compatibility(transport)
    except MigrationError as exc:
        raise ValidationError({"detail": str(exc)}) from exc

    source.detected_version = report.detected_version or ""
    source.last_compat_status = (
        MigrationSource.CompatStatus.COMPATIBLE
        if report.compatible
        else MigrationSource.CompatStatus.INCOMPATIBLE
    )
    source.last_compat_report = report.as_dict()
    source.save(
        update_fields=[
            "detected_version",
            "last_compat_status",
            "last_compat_report",
            "updated_at",
        ]
    )
    record_migration_event(
        name="migration.source.compatibility_checked",
        user=user,
        entity_id=source.pk,
        attributes={"compatible": report.compatible, "detected_version": report.detected_version},
    )
    return report.as_dict()


def _ensure_no_active_run() -> None:
    active = MigrationRun.objects.filter(
        status__in=[MigrationRun.Status.QUEUED, MigrationRun.Status.RUNNING]
    ).exists()
    if active:
        raise ValidationError({"detail": "A migration run is already in progress."})


def queue_migration_run(source, *, mode, entities=None, user=None, dispatch=True) -> MigrationRun:
    if source.is_archived:
        raise ValidationError({"detail": "This source is archived."})
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

        run_migration_run.delay(run.pk)
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
    source = run.source
    source.last_run_at = timezone.now()
    update_fields = ["last_run_at", "updated_at"]
    # Clear the stored password only after a clean import (migration is one-time).
    # A partial import keeps it so the owner can fix issues and re-run.
    if (
        run.mode == MigrationRun.Mode.IMPORT
        and run.status == MigrationRun.Status.SUCCEEDED
        and source.password
    ):
        source.password = ""
        source.credentials_cleared = True
        update_fields += ["password", "credentials_cleared"]
    source.save(update_fields=update_fields)


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
