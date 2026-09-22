"""Orchestration entrypoints for the data-migration feature.

Two things get queued here, both to a Celery worker and both with the same "mark
it failed if the broker is unreachable" guard ``apps.core.backup`` uses:

* **preparation** — converting, reconstructing and identifying an uploaded file.
  Runs once per upload, and is why a source is not importable the instant its
  last byte arrives.
* **runs** — a dry run or an import against a prepared file.
* **collapse plans** — reading a one-product-per-handset catalogue into the
  proposal of §12, which is a full pass over the file and so is never done on a
  request thread.

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
from .entity_plan import ENTITY_PLAN_BY_TYPE, PRODUCT, resolve_selection
from .exceptions import CompatibilityError, MigrationError
from .models import CollapseCandidate, CollapsePlan, MigrationRun, MigrationSource
from .preparation import pipeline
from .scopes import apply_scope, stock_filter_conflict


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
    source, *, mode, entities=None, options=None, scope=None, user=None, dispatch=True
) -> MigrationRun:
    if not source.is_ready:
        raise ValidationError({"detail": "هذا الملف غير جاهز للنقل بعد."})
    connector = get_connector(source.system_key)
    if connector is None:
        raise ValidationError({"detail": f"Unknown source system: {source.system_key}."})

    supported = set(connector.supported_entities)
    # A named scope answers both questions at once — what to bring, and the
    # options that make it mean what it says (``scopes``). An explicit selection
    # or option the caller also sent still wins, so "this scope, but…" stays
    # expressible; ``custom`` (or no scope at all) is the free selection.
    entities, options = apply_scope(
        scope, entities=entities, options=options, available=sorted(supported)
    )
    requested = [entity for entity in (entities or []) if entity in ENTITY_PLAN_BY_TYPE]
    unsupported = [entity for entity in requested if entity not in supported]
    if unsupported:
        raise ValidationError({"detail": f"This system cannot transfer: {', '.join(unsupported)}."})
    # Stored dependency-closed: the row is what the run will actually do, not
    # what someone happened to tick. A selection that is quietly incoherent is
    # worse than one that is refused — it produces an import that looks like it
    # worked.
    selected = list(resolve_selection(requested or None, available=supported).entities)

    options = dict(options or {})
    if options.get("only_stocked_products") and not connector.supports_stock_filter:
        raise ValidationError(
            {"detail": "هذا النظام لا يسجّل كمية لكل صنف، فلا يمكن الاقتصار على الأصناف المتوفرة."}
        )
    conflicting = stock_filter_conflict(options, selected)
    if conflicting:
        # Refused rather than warned: the run would "succeed" with a warning per
        # line for every product the shop stopped stocking years ago.
        raise ValidationError(
            {
                "detail": (
                    "لا يمكن نقل سجل الفواتير مع الاقتصار على الأصناف المتوفرة — "
                    "الفواتير القديمة تشير إلى أصناف لن تُنقل."
                ),
                "entities": list(conflicting),
            }
        )
    plan = _resolve_collapse_plan(source, options)
    if plan is not None and PRODUCT in supported:
        # Without the catalogue pass nothing redirects a legacy key, so every
        # sale would resolve to a product that was never created.
        selected = list(
            resolve_selection({*selected, PRODUCT}, available=supported).entities
        )

    _ensure_no_active_run()
    run = MigrationRun.objects.create(
        source=source,
        mode=mode,
        selected_entities=selected,
        options=options,
        progress_message="تمت جدولة العملية.",
        **_initiator_fields(user),
    )
    record_migration_event(
        name="migration.run.queued",
        user=user,
        entity_id=source.pk,
        attributes={
            "mode": mode,
            "run_id": run.pk,
            "entities": selected,
            "scope": scope or "custom",
            "collapse_plan": plan.pk if plan else None,
        },
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

    _finalize_collapse(run)
    _finalize_source(run)
    _record_outcome(run, failed=False)


def _resolve_collapse_plan(source, options):
    """The approved plan this run names, if any. Refuses anything else."""
    plan_id = options.get("collapse_plan")
    if not plan_id:
        return None
    plan = CollapsePlan.objects.filter(pk=plan_id, source=source).first()
    if plan is None:
        raise ValidationError({"detail": "لم نعثر على اقتراح الدمج لهذا الملف."})
    if plan.status not in CollapsePlan.USABLE:
        raise ValidationError(
            {"detail": "يجب اعتماد اقتراح الدمج قبل استخدامه في النقل."}
        )
    return plan


def _finalize_collapse(run: MigrationRun) -> None:
    """Record that the plan was used, and let the shop see what it just gained.

    Turning ``enable_serialized_inventory`` on is part of applying a collapse,
    not a separate errand: the flag gates the *surfaces* (§10), so a migration
    that created four hundred identified handsets and left it off would have
    produced a units register nobody in the shop can open.
    """
    from apps.core.models import ShopSettings

    plan_id = (run.options or {}).get("collapse_plan")
    if not plan_id or run.mode != MigrationRun.Mode.IMPORT:
        return
    # A phase that rolled back on the invariants did not apply anything, and
    # turning the surfaces on for a units register that is empty would be
    # telling the shop it has something it does not.
    bucket = (run.summary or {}).get("collapse") or {}
    if not (bucket.get("created") or bucket.get("updated")):
        return
    plan = CollapsePlan.objects.filter(pk=plan_id, source_id=run.source_id).first()
    if plan is None:
        return
    plan.status = CollapsePlan.Status.APPLIED
    plan.applied_run = run
    plan.save(update_fields=["status", "applied_run", "updated_at"])
    settings_row = ShopSettings.load()
    if not settings_row.enable_serialized_inventory:
        settings_row.enable_serialized_inventory = True
        settings_row.save(update_fields=["enable_serialized_inventory", "updated_at"])
    record_migration_event(
        name="migration.collapse.applied",
        user=None,
        entity_id=run.source_id,
        attributes={"plan_id": plan.pk, "run_id": run.pk},
        metrics={
            key: value
            for key, value in (run.summary or {}).get("collapse", {}).items()
            if isinstance(value, (int, float))
        },
    )


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


# --- the collapse (§12) ------------------------------------------------------


def queue_collapse_plan(source: MigrationSource, *, user=None, dispatch=True) -> CollapsePlan:
    """Read this file's catalogue and propose what it would collapse into.

    Building is a full pass over products, purchases and sales, so it is a job
    rather than a request. Any earlier plan for the same file that nobody
    applied is superseded — two live proposals for one catalogue is two answers
    to "what will this import do".
    """
    if not source.is_ready:
        raise ValidationError({"detail": "هذا الملف غير جاهز للفحص بعد."})
    CollapsePlan.objects.filter(source=source).exclude(
        status__in=[CollapsePlan.Status.APPLIED, CollapsePlan.Status.SUPERSEDED]
    ).update(status=CollapsePlan.Status.SUPERSEDED)
    plan = CollapsePlan.objects.create(source=source)
    record_migration_event(
        name="migration.collapse.queued",
        user=user,
        entity_id=source.pk,
        attributes={"plan_id": plan.pk},
    )
    if dispatch:
        _dispatch_collapse(plan)
    return plan


def _dispatch_collapse(plan: CollapsePlan) -> None:
    try:
        from .tasks import build_collapse_plan_task

        enqueue_or_raise(build_collapse_plan_task, plan.pk)
    except Exception as exc:  # noqa: BLE001 - broker unreachable etc.
        plan.status = CollapsePlan.Status.FAILED
        plan.error_message = "تعذر إرسال الفحص إلى عامل الخلفية."
        plan.save(update_fields=["status", "error_message", "updated_at"])
        raise ValidationError({"detail": str(exc)}) from exc


def build_collapse_plan(plan_id: int) -> None:
    """Worker entrypoint: read the file and fill the plan."""
    from .collapse import build_plan

    plan = CollapsePlan.objects.select_related("source").filter(pk=plan_id).first()
    if plan is None or not plan.is_active:
        return
    plan.status = CollapsePlan.Status.RUNNING
    plan.error_message = ""
    plan.save(update_fields=["status", "error_message", "updated_at"])
    try:
        build_plan(plan)
    except Exception as exc:  # noqa: BLE001 - never leave a plan stuck "running"
        plan.status = CollapsePlan.Status.FAILED
        plan.error_message = str(exc)[:480]
        plan.save(update_fields=["status", "error_message", "updated_at"])
        record_migration_event(
            name="migration.collapse.failed",
            user=None,
            entity_id=plan.source_id,
            attributes={"plan_id": plan.pk, "error": plan.error_message},
            severity=AnalyticsEvent.Severity.WARNING,
        )
        return
    record_migration_event(
        name="migration.collapse.built",
        user=None,
        entity_id=plan.source_id,
        attributes={"plan_id": plan.pk},
        metrics={
            key: value
            for key, value in (plan.stats or {}).items()
            if isinstance(value, (int, float))
        },
    )


def approve_collapse_plan(plan: CollapsePlan, *, user=None) -> CollapsePlan:
    """The owner says yes. Nothing was written before this, and nothing is now.

    Approval freezes the proposal: a later edit would make the import disagree
    with the screen somebody looked at, so the rows stop being editable here and
    an import run may name this plan from here.
    """
    if plan.status != CollapsePlan.Status.READY:
        raise ValidationError({"detail": "هذا الاقتراح غير جاهز للاعتماد."})
    if not plan.candidates.filter(decision=CollapseCandidate.Decision.COLLAPSE).exists():
        raise ValidationError(
            {"detail": "لا يوجد صنف واحد سيتحول إلى وحدة معرّفة — لا شيء لاعتماده."}
        )
    plan.status = CollapsePlan.Status.APPROVED
    plan.approved_at = timezone.now()
    if getattr(user, "is_authenticated", False):
        plan.approved_by_user_id = user.pk
        plan.approved_by_username = user.get_username()
    plan.save(
        update_fields=[
            "status",
            "approved_at",
            "approved_by_user_id",
            "approved_by_username",
            "updated_at",
        ]
    )
    record_migration_event(
        name="migration.collapse.approved",
        user=user,
        entity_id=plan.source_id,
        attributes={"plan_id": plan.pk},
        metrics={
            key: value
            for key, value in (plan.stats or {}).items()
            if isinstance(value, (int, float))
        },
    )
    return plan


def rename_collapse_cluster(plan: CollapsePlan, *, stem_key: str, stem: str) -> int:
    """Rename a proposed product — which is also how two of them are merged.

    Clusters are grouped on the name rather than stored, so typing an existing
    product's name onto this one is the merge. There is no second operation and
    no second table that could disagree with the first.
    """
    from .collapse.extract import cluster_key
    from .collapse.planner import recompute_stats

    if not plan.is_editable:
        raise ValidationError({"detail": "لا يمكن تعديل اقتراح تم اعتماده."})
    stem = (stem or "").strip()
    if not stem:
        raise ValidationError({"stem": "الاسم مطلوب."})
    updated = plan.candidates.filter(
        stem_key=stem_key, decision=CollapseCandidate.Decision.COLLAPSE
    ).update(stem=stem[:255], stem_key=cluster_key(stem)[:255], edited=True)
    recompute_stats(plan)
    return updated
