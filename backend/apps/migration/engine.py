"""The migration engine — orchestrates extract → validate → load.

Walks ``ENTITY_PLAN`` in dependency order. Two execution modes share one set of
loaders:

* **import** — no outer transaction; each record loads in its own savepoint so a
  bad record fails alone (continue-on-error) while good ones commit. Re-running
  is safe: the identity map short-circuits already-imported rows to an update.
* **dry run** — the whole run executes inside a single transaction that is rolled
  back at the end. Real ORM inserts give genuine DB-constraint + FK checks and
  let later entities resolve their parents, but nothing is persisted. Issues and
  the summary are buffered in memory and written *after* the rollback so the
  report survives.

Failures never abort the run: each becomes a counted ``MigrationIssue``. Issue
rows are capped per entity; the overflow is still reflected in the summary
counts.
"""

from __future__ import annotations

from django.db import transaction

from .connectors import get_connector
from .connectors.base import ExtractContext
from .entity_plan import STOCK, ordered_entities
from .exceptions import CompatibilityError, MigrationError
from .identity import IdentityResolver
from .loaders import get_loader
from .loaders.base import ERROR, FAILED
from .models import MigrationIssue, MigrationRun
from .transports import build_transport

MAX_ISSUES_PER_ENTITY = 1000
# Emit a live progress count every this-many records within a single entity.
_PROGRESS_EVERY = 500
_ACTIONS = ("created", "updated", "skipped", "failed")


class _DryRunRollback(Exception):
    """Internal sentinel used to unwind the dry-run transaction."""


def _friendly(exc: Exception) -> str:
    message = str(exc).strip() or exc.__class__.__name__
    return message[:480]


class MigrationEngine:
    def __init__(self, run: MigrationRun):
        self.run = run
        self.source = run.source
        self.dry_run = run.mode == MigrationRun.Mode.DRY_RUN
        self._summary: dict[str, dict] = {}
        self._issues: list[MigrationIssue] = []
        self._issue_counts: dict[str, int] = {}

    # --- public entrypoint ----------------------------------------------
    def execute(self) -> dict:
        connector = get_connector(self.source.system_key)
        if connector is None:
            raise MigrationError(f"Unknown source system: {self.source.system_key!r}.")

        transport = build_transport(self.source.transport_kind, self.source.connection_dict())
        specs = self._specs_to_run(connector)
        context = ExtractContext(
            source=self.source,
            options=dict(self.source.extra_options or {}),
            run_options=dict(self.run.options or {}),
        )
        resolver = IdentityResolver(self.source, self.run, dry_run=self.dry_run)

        with transport:
            report = connector.check_compatibility(transport)
            self._persist_compat(report)
            if not report.compatible:
                raise CompatibilityError(report)

            if self.dry_run:
                self.run.update_progress(5, "جارٍ فحص البيانات…")
                self._run_dry(connector, transport, context, resolver, specs)
            else:
                self._run_import(connector, transport, context, resolver, specs)

        self._flush_issues()
        self._finalize_status()
        return self.run.summary

    # --- mode runners ----------------------------------------------------
    def _run_import(self, connector, transport, context, resolver, specs):
        total = max(len(specs), 1)
        for index, spec in enumerate(specs):
            self.run.update_progress(
                int(index / total * 100),
                f"جارٍ نقل: {spec.label}",
                current_entity=spec.entity_type,
            )
            self._process_entity(spec, connector, transport, context, resolver)
            self._persist_summary()

    def _run_dry(self, connector, transport, context, resolver, specs):
        # Single transaction across all entities (so children resolve their
        # parents), rolled back at the end. Progress is not persisted mid-run
        # because those writes would be rolled back too; the report is written
        # afterwards from the in-memory buffers.
        try:
            with transaction.atomic():
                for spec in specs:
                    self._process_entity(spec, connector, transport, context, resolver)
                raise _DryRunRollback
        except _DryRunRollback:
            pass
        self._persist_summary()

    # --- per-entity / per-record ----------------------------------------
    def _process_entity(self, spec, connector, transport, context, resolver):
        counts = {action: 0 for action in _ACTIONS}
        self._summary[spec.entity_type] = counts
        loader = get_loader(spec.entity_type)
        if loader is None:
            self._add_issue(
                spec.entity_type, "", ERROR, "no_loader", "No loader is registered for this entity."
            )
            return
        processed = 0
        try:
            for record in connector.extract(spec.entity_type, transport, context):
                self._load_one(spec, loader, record, resolver, counts)
                processed += 1
                # Live count for big entities. Skipped during a dry run because
                # those writes would be rolled back with the rest of the run.
                if not self.dry_run and processed % _PROGRESS_EVERY == 0:
                    self.run.update_progress(
                        self.run.progress_percent,
                        f"{spec.label}: {processed}",
                        current_entity=spec.entity_type,
                    )
        except Exception as exc:  # noqa: BLE001 - extract/transport failure for the whole entity
            self._add_issue(spec.entity_type, "", ERROR, "extract_failed", _friendly(exc))

    def _load_one(self, spec, loader, record, resolver, counts):
        source_key = str(getattr(record, "source_key", "") or "")
        try:
            with transaction.atomic():  # per-record savepoint -> continue-on-error
                outcome = loader.load(record, resolver, dry_run=self.dry_run)
        except Exception as exc:  # noqa: BLE001 - LoaderError, IntegrityError, ValidationError…
            counts[FAILED] += 1
            code = getattr(exc, "code", None) or exc.__class__.__name__
            detail = getattr(exc, "detail", None) or {}
            self._add_issue(spec.entity_type, source_key, ERROR, code, _friendly(exc), detail)
            return
        counts[outcome.action] = counts.get(outcome.action, 0) + 1
        for issue in outcome.issues:
            self._add_issue(
                spec.entity_type,
                issue.source_key or source_key,
                issue.severity,
                issue.code,
                issue.message,
                issue.detail,
            )

    # --- issues + summary ------------------------------------------------
    def _add_issue(self, entity_type, source_key, severity, code, message, detail=None):
        persisted = self._issue_counts.get(entity_type, 0)
        if persisted < MAX_ISSUES_PER_ENTITY:
            self._issues.append(
                MigrationIssue(
                    run=self.run,
                    entity_type=entity_type,
                    source_key=str(source_key or "")[:255],
                    severity=severity,
                    code=str(code)[:48],
                    message=str(message),
                    detail=detail or {},
                )
            )
            self._issue_counts[entity_type] = persisted + 1
        else:
            bucket = self._summary.setdefault(entity_type, {action: 0 for action in _ACTIONS})
            bucket["issues_truncated"] = True

    def _flush_issues(self):
        if self._issues:
            MigrationIssue.objects.bulk_create(self._issues, batch_size=500)
            self._issues = []

    def _persist_summary(self):
        self.run.summary = self._summary
        self.run.save(update_fields=["summary", "updated_at"])

    # --- finalisation ----------------------------------------------------
    def _specs_to_run(self, connector):
        supported = set(connector.supported_entities)
        selected = set(self.run.selected_entities or []) or supported
        # Generic, connector-agnostic option: bring products with no stock on
        # hand by simply not running the stock entity.
        if (self.run.options or {}).get("products_without_quantities"):
            selected.discard(STOCK)
        return [
            spec
            for spec in ordered_entities()
            if spec.entity_type in selected and spec.entity_type in supported
        ]

    def _persist_compat(self, report):
        self.source.detected_version = report.detected_version or ""
        self.source.last_compat_status = (
            self.source.CompatStatus.COMPATIBLE
            if report.compatible
            else self.source.CompatStatus.INCOMPATIBLE
        )
        self.source.last_compat_report = report.as_dict()
        self.source.save(
            update_fields=[
                "detected_version",
                "last_compat_status",
                "last_compat_report",
                "updated_at",
            ]
        )

    def _finalize_status(self):
        self._persist_summary()
        total_failed = sum(bucket.get("failed", 0) for bucket in self._summary.values())
        if self.dry_run:
            self.run.mark_succeeded(self._completion_message(total_failed))
        elif total_failed:
            self.run.mark_partial(self._completion_message(total_failed))
        else:
            self.run.mark_succeeded(self._completion_message(total_failed))

    def _completion_message(self, total_failed):
        created = sum(bucket.get("created", 0) for bucket in self._summary.values())
        updated = sum(bucket.get("updated", 0) for bucket in self._summary.values())
        if self.dry_run:
            return f"اكتملت المعاينة: {created} جديد، {updated} تحديث، {total_failed} مشكلة."
        return f"اكتمل النقل: {created} جديد، {updated} تحديث، {total_failed} فشل."
