"""The migration engine — orchestrates extract → validate → load.

Walks ``ENTITY_PLAN`` in dependency order. Two execution modes share one set of
loaders:

* **import** — records commit in small batches (``_CommitBatch``), each record
  in its own savepoint so a bad record fails alone (continue-on-error) while
  good ones commit. Re-running is safe: the identity map short-circuits
  already-imported rows to an update.
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

import contextvars
import queue
import threading
import time
from decimal import Decimal

from django.conf import settings
from django.db import connection, connections, transaction

from apps.catalog.cache import deferred_catalog_bumps
from apps.catalog.sku_series import (
    next_variant_sku,
    release_variant_skus,
    reserve_variant_skus,
)
from apps.core.state_version import held_bumps

from .collapse.apply import CollapseSession
from .connectors import get_connector
from .connectors.base import ExtractContext
from .entity_plan import (
    PRODUCT,
    PRODUCT_UNIT,
    PURCHASE_ORDER,
    SALE,
    STOCK,
    VARIANT,
    ENTITY_PLAN_BY_TYPE,
    resolve_selection,
)
from .exceptions import CompatibilityError, MigrationError
from . import live_progress
from .identity import IdentityResolver
from .loaders import get_loader
from .loaders.base import ERROR, FAILED
from .models import MigrationIssue, MigrationRun
from .planning import PLANNED, document_planner, plan_catalog, renumber_placeholders
from .preparation.stages import DONE, SKIPPED, Stage, StageTracker
from .reconstruct import (
    STOCK_SOURCE_NONE,
    STOCK_SOURCE_RECONSTRUCT,
    STOCK_SOURCE_SNAPSHOT,
    StockReconstructor,
    resolve_carry_costs,
    resolve_stock_source,
)
from .scopes import (
    attach_selection,
    attaches_to_catalogue,
    resolve_party_balance_basis,
    with_party_balances,
)
from .transports import build_transport

#: Stage key for the collapse's unit phase — not an ENTITY_PLAN entity, because
#: nothing extracts it from the file: it is built from the approved plan, after
#: everything the units need to point at has been imported.
COLLAPSE = "collapse"

MAX_ISSUES_PER_ENTITY = 1000
# Emit a live progress count every this-many records within a single entity.
_PROGRESS_EVERY = 500
_ACTIONS = ("created", "updated", "skipped", "failed")
#: Catalogue entities: dealt to workers one product per worker.
_CATALOGUE = frozenset({PRODUCT, VARIANT, PRODUCT_UNIT, STOCK})
#: Entities an import loads on worker threads.
_PARALLEL = _CATALOGUE | {SALE, PURCHASE_ORDER}
#: Records read ahead per worker — enough to keep it busy, few enough that a
#: long history never sits in memory.
_LANE_DEPTH = 256
#: Records the document planner settles per database round trip.
_PLAN_CHUNK = 500
_END = object()


def _check_deferred_constraints():
    """Check the record's foreign keys now, inside its savepoint.

    Django creates them ``DEFERRABLE INITIALLY DEFERRED``, so Postgres checks
    them at commit. With a commit per record that was the record's own
    problem; inside a batch it would fail every record in it, and inside a dry
    run — which never commits — it was never checked at all, so a preview
    could pass what the import then refused. Switching to IMMEDIATE checks
    everything outstanding at once; switching back keeps the loaders' own
    within-record ordering free.
    """
    connection = transaction.get_connection()
    if connection.vendor != "postgresql":
        return
    with connection.cursor() as cursor:
        cursor.execute("SET CONSTRAINTS ALL IMMEDIATE; SET CONSTRAINTS ALL DEFERRED")


class _CommitBatch:
    """Commit an import's records a few dozen at a time, not one by one.

    Each record still loads in its own savepoint, so a bad one fails alone;
    what changes is how often the database has to flush to disk. A commit per
    record was most of an import's time on a shop's own server. Kept small so
    the savepoints of one batch stay inside Postgres's per-transaction
    subtransaction cache (64), and short so a till never waits long on a row
    the import holds. A crash loses at most the open batch — and the identity
    map commits with its rows, so re-running picks up exactly there.
    """

    RECORDS = 20
    SECONDS = 0.5

    def __init__(self, resolver, *, enabled: bool):
        self.resolver = resolver
        self.enabled = enabled
        self._atomic = None
        self._count = 0
        self._started = 0.0

    def open(self):
        if not self.enabled or self._atomic is not None:
            return
        self._atomic = transaction.atomic()
        self._atomic.__enter__()
        self.resolver.buffering = True
        self._count = 0
        self._started = time.monotonic()

    def tick(self):
        if self._atomic is None:
            return
        self._count += 1
        if self._count >= self.RECORDS or time.monotonic() - self._started >= self.SECONDS:
            self.close()

    def close(self):
        if self._atomic is None:
            return
        atomic, self._atomic = self._atomic, None
        self.resolver.buffering = False
        try:
            # The batch's mappings go in with its rows, in the same commit.
            self.resolver.flush()
        except BaseException as exc:
            atomic.__exit__(type(exc), exc, exc.__traceback__)
            raise
        atomic.__exit__(None, None, None)


class _DryRunRollback(Exception):
    """Internal sentinel used to unwind the dry-run transaction."""


def _friendly(exc: Exception) -> str:
    message = str(exc).strip() or exc.__class__.__name__
    return message[:480]


class _ShapedStock:
    """The stock loader, told which half of a stock record this run wants.

    A stock record carries two facts: how many the shop holds, and what one of
    them cost. They are asked for separately (``stock_source`` and
    ``carry_costs``), so this wrapper drops whichever half was declined before
    the one stock loader sees it — one loader, one meaning. It also keeps the
    tally the review screen shows: how many products came across *with* a cost,
    and how many the old system itself had no cost for.
    """

    def __init__(self, inner, *, keep_quantity: bool, keep_cost: bool):
        self._inner = inner
        self._keep_quantity = keep_quantity
        self._keep_cost = keep_cost
        self.costed = 0
        self.uncosted = 0

    @property
    def entity_type(self):
        return self._inner.entity_type

    def load(self, record, resolver, *, dry_run):
        if not self._keep_quantity:
            # None, not zero: "leave the quantity alone". Zero would wipe the
            # counts of a live shop re-running the import for its costs.
            record.quantity_on_hand = None
        if not self._keep_cost:
            record.unit_cost = None
        elif record.unit_cost is not None and Decimal(str(record.unit_cost)) > 0:
            self.costed += 1
        else:
            self.uncosted += 1
        return self._inner.load(record, resolver, dry_run=dry_run)


class MigrationEngine:
    def __init__(self, run: MigrationRun):
        self.run = run
        self.source = run.source
        self.dry_run = run.mode == MigrationRun.Mode.DRY_RUN
        self._summary: dict[str, dict] = {}
        self._issues: list[MigrationIssue] = []
        self._issue_counts: dict[str, int] = {}
        # How stock on-hand is established: snapshot (import stored quantities),
        # none (no quantities), or reconstruct (compute from purchases − sales).
        self._stock_source = resolve_stock_source(run.options)
        # Whether each product's cost comes across. Its own decision, not a
        # side effect of the quantity one (see ``resolve_carry_costs``).
        self._carry_costs = resolve_carry_costs(run.options)
        self._reconstructor: StockReconstructor | None = None
        # An approved §12 plan, when this run was launched with one. It
        # redirects the catalogue loaders and builds the units at the end.
        self._collapse = CollapseSession.for_run(run)
        self._tracker: StageTracker | None = None
        # Set by _specs_to_run, before anything extracts.
        self._selection = None
        self._balance_basis = ""
        # The catalogue records the planning pass read, by entity, waiting to
        # be loaded (``_plan_catalog``), and the SKU block it claimed.
        self._planned: dict[str, list] = {}
        self._sku_claim = None
        self._issue_lock = threading.Lock()
        self._workers = 1
        self._variant_products: dict[str, str] = {}

    # --- public entrypoint ----------------------------------------------
    def execute(self) -> dict:
        connector = get_connector(self.source.system_key)
        if connector is None:
            raise MigrationError(f"Unknown source system: {self.source.system_key!r}.")

        transport = build_transport(connector.required_transport, self.source.connection_dict())
        specs = self._specs_to_run(connector)
        # One stage per entity. An import that walks 900,000 sale lines spends
        # most of its life inside a single entity, so "Sales: 412,000" is the
        # only progress report that means anything.
        self._tracker = StageTracker(
            self.run,
            [Stage(spec.entity_type, spec.label) for spec in specs]
            + ([Stage(STOCK, "احتساب الكميات")] if self._stock_source == STOCK_SOURCE_RECONSTRUCT else [])
            + ([Stage(COLLAPSE, "إنشاء الوحدات المعرّفة")] if self._collapse else []),
            # A dry run's writes are rolled back, so its stage timeline is kept
            # in memory and persisted with the rest of the report afterwards;
            # meanwhile it is published live outside the transaction.
            persist=not self.dry_run,
            publish=self._publish_live if self.dry_run else None,
        )
        # Connectors are told the scope, not just the options. Some records
        # only have a meaning relative to what else is being imported — a
        # party's balance most of all (``scopes.resolve_party_balance_basis``).
        self._balance_basis = resolve_party_balance_basis(
            self.run.options, self._selection.entities
        )
        self._persist_resolved_scope()
        context = ExtractContext(
            source=self.source,
            run_options=dict(self.run.options or {}),
            selected_entities=frozenset(self._selection.entities),
            party_balance_basis=self._balance_basis,
            only_stocked_products=(
                bool((self.run.options or {}).get("only_stocked_products"))
                and connector.supports_stock_filter
            ),
        )
        resolver = IdentityResolver(self.source, self.run, dry_run=self.dry_run)
        if self._collapse is not None:
            self._collapse.resolver = resolver
        if self._stock_source == STOCK_SOURCE_RECONSTRUCT:
            self._reconstructor = StockReconstructor(resolver)

        # One bump per counter for the whole run, not one per saved row; none
        # for a dry run, whose writes never happened.
        announce = not self.dry_run
        with (
            transport,
            deferred_catalog_bumps(announce=announce),
            held_bumps(announce=announce),
        ):
            report = connector.check_compatibility(transport)
            self._persist_compat(report)
            if not report.compatible:
                raise CompatibilityError(report)

            try:
                self._plan_catalog(connector, transport, context, resolver, specs)
                if self.dry_run:
                    self.run.update_progress(5, "جارٍ فحص البيانات…")
                    self._run_dry(connector, transport, context, resolver, specs)
                else:
                    self._run_import(connector, transport, context, resolver, specs)
            finally:
                if self._sku_claim is not None:
                    release_variant_skus(self._sku_claim)

        self._flush_issues()
        self._finalize_status()
        if self.dry_run:
            # The row now holds the full report; a run that dies instead is
            # marked failed, and the overlay ignores a run that is not active.
            live_progress.clear(self.run)
        return self.run.summary

    # --- planning ----------------------------------------------------------
    def _plan_catalog(self, connector, transport, context, resolver, specs):
        """Read the catalogue entities and settle their codes (``planning``).

        Skipped under a §12 collapse plan, which redirects the catalogue's keys
        itself — that run stays serial, as it always was.
        """
        if self._collapse is not None:
            return
        if not self.dry_run and connection.vendor == "postgresql":
            self._workers = max(int(settings.POINTY_MIGRATION_IMPORT_WORKERS), 1)
        selected = {spec.entity_type for spec in specs}
        for entity_type in PLANNED:
            if entity_type not in selected:
                continue
            try:
                self._planned[entity_type] = list(
                    connector.extract(entity_type, transport, context)
                )
            except Exception:  # noqa: BLE001 - reported where the entity loads
                self._planned.pop(entity_type, None)
        if not self._planned:
            return
        plan = plan_catalog(self._planned, resolver)
        for entity_type, issue in plan.issues:
            self._add_issue(
                entity_type, issue.source_key, issue.severity, issue.code, issue.message
            )
        if plan.numbered:
            if self.dry_run:
                # Nothing is written, so nothing to claim — only to count from.
                start = max(int(next_variant_sku()), (plan.floor or 0) + 1)
            else:
                self._sku_claim, start = reserve_variant_skus(
                    len(plan.numbered), floor=plan.floor
                )
            plan.number_from(start)
        self._variant_products = {
            str(record.source_key): str(record.product_source_key)
            for record in self._planned.get(VARIANT, ())
        }

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
        if self._reconstructor is not None:
            self._tracker.start(STOCK)
            self.run.update_progress(96, "احتساب الكميات من الحركات…", current_entity=STOCK)
            self._feed_reconstruction_snapshot(connector, transport, context, resolver)
            self._reconstruct_stock()
            self._persist_summary()
        if self._collapse is not None:
            self._tracker.start(COLLAPSE)
            self.run.update_progress(98, "إنشاء الوحدات المعرّفة…", current_entity=COLLAPSE)
            self._apply_collapse()
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
                # Reconstruct inside the transaction so its StockItem writes get
                # the same real FK/constraint checks before being rolled back;
                # its diagnostics are buffered and survive (like every issue).
                if self._reconstructor is not None:
                    self._feed_reconstruction_snapshot(connector, transport, context, resolver)
                self._reconstruct_stock()
                if self._collapse is not None:
                    self._apply_collapse()
                raise _DryRunRollback
        except _DryRunRollback:
            pass
        self._persist_summary()

    def _publish_live(self, stages):
        # A 5–95 bar: 5 is where the dry run starts, the rest is finishing.
        # The headline stays generic; the client names the running stage
        # in Arabic from its key (the labels here are English).
        finished = sum(1 for stage in stages if stage["status"] in (DONE, SKIPPED))
        percent = 5 + int(finished / max(len(stages), 1) * 90)
        live_progress.publish(
            self.run, percent=percent, message="جارٍ فحص البيانات…", stages=stages
        )

    # --- per-entity / per-record ----------------------------------------
    def _make_loader(self, entity_type):
        """(loader, the stock shaper or None). Each worker thread gets its own."""
        loader = get_loader(entity_type)
        if loader is not None and self._collapse is not None:
            loader = self._collapse.wrap(loader, entity_type)
        shaped = None
        if loader is not None and entity_type == STOCK:
            loader = shaped = _ShapedStock(
                loader,
                keep_quantity=self._stock_source == STOCK_SOURCE_SNAPSHOT,
                keep_cost=self._carry_costs,
            )
        return loader, shaped

    def _process_parallel(self, spec, records, resolver, counts):
        """Load one entity on ``self._workers`` threads.

        This thread reads the source and deals the records out through bounded
        queues, so a history of a million invoice lines streams through rather
        than sitting in memory. Every record of one product goes to the same
        worker (``_lane``), so the rows two workers write never overlap: a
        product's variants, units and stock are only ever touched by the worker
        that owns the product, and the planning pass gave every code to exactly
        one product. Documents touch nothing another document writes once their
        numbers are settled (``planning.DocumentPlanner``), so they are simply
        dealt in turn. Each worker has its own connection, commit batches and
        loader; they share the resolver's map, which earlier entities — already
        committed — filled in.
        """
        entity_type = spec.entity_type
        lanes = [queue.Queue(maxsize=_LANE_DEPTH) for _ in range(self._workers)]
        owners: dict[str, int] = {}
        dealt = 0
        progress = {"processed": 0}
        progress_lock = threading.Lock()
        results: list[dict] = []
        failures: list[BaseException] = []

        def lane_for(record) -> int:
            nonlocal dealt
            dealt += 1
            if entity_type in _CATALOGUE:
                key = self._product_key(entity_type, record)
                return owners.setdefault(key, len(owners) % self._workers)
            return dealt % self._workers

        def work(lane):
            loader, shaped = self._make_loader(entity_type)
            view = resolver.worker_view()
            local = {action: 0 for action in _ACTIONS}
            batch = _CommitBatch(view, enabled=not self.dry_run)
            broken = False
            try:
                while (record := lane.get()) is not _END:
                    if broken:
                        continue  # keep the queue moving so the reader never blocks
                    try:
                        batch.open()
                        self._load_one(spec, loader, record, view, local)
                        batch.tick()
                    except BaseException as exc:  # noqa: BLE001 - surfaced on the reader
                        failures.append(exc)
                        broken = True
                        try:
                            batch.close()  # keep what loaded before it broke
                        except BaseException:  # noqa: BLE001 - the first failure is the story
                            pass
                        continue
                    with progress_lock:
                        progress["processed"] += 1
                if not broken:
                    batch.close()
            except BaseException as exc:  # noqa: BLE001 - surfaced on the reader
                failures.append(exc)
            finally:
                connections.close_all()  # this thread's own connection
                results.append(
                    {
                        "counts": local,
                        "costed": getattr(shaped, "costed", 0),
                        "uncosted": getattr(shaped, "uncosted", 0),
                    }
                )

        def report():
            if self._tracker is not None:
                with progress_lock:
                    done = progress["processed"]
                self._tracker.progress(entity_type, detail=f"{done:,} سجل")

        # The run's held-back catalogue and state bumps live in context
        # variables, which a new thread does not inherit; each worker runs in
        # a copy that shares the same collections.
        threads = [
            threading.Thread(
                target=contextvars.copy_context().run,
                args=(work, lane),
                name=f"migration-{entity_type}-{index}",
                daemon=True,
            )
            for index, lane in enumerate(lanes)
        ]
        for thread in threads:
            thread.start()

        source_error = None
        try:
            for record in records:
                if failures:
                    break
                # Stock follows the source's movements, not Pointy's import
                # success — and the reconstructor is not thread-safe, so it is
                # fed here, in file order.
                if self._reconstructor is not None and entity_type in (SALE, PURCHASE_ORDER):
                    self._reconstructor.observe(entity_type, record)
                lane = lanes[lane_for(record)]
                while True:
                    try:
                        lane.put(record, timeout=1.0)
                        break
                    except queue.Full:
                        report()
                        if failures:
                            break
        except Exception as exc:  # noqa: BLE001 - extract/transport failure for the whole entity
            source_error = exc
        finally:
            for lane in lanes:
                lane.put(_END)
        while any(thread.is_alive() for thread in threads):
            for thread in threads:
                thread.join(timeout=1.0)
            report()

        for result in results:
            for action, value in result["counts"].items():
                counts[action] = counts.get(action, 0) + value
        problem = source_error or (failures[0] if failures else None)
        if problem is not None:
            # What loaded before it broke stays loaded, as it does serially.
            self._add_issue(entity_type, "", ERROR, "extract_failed", _friendly(problem))
            if self._tracker is not None:
                self._tracker.fail(entity_type, _friendly(problem))
            return
        if entity_type == STOCK and self._carry_costs:
            counts["costed"] = sum(result["costed"] for result in results)
            counts["uncosted"] = sum(result["uncosted"] for result in results)
        if self._tracker is not None:
            self._tracker.done(
                entity_type,
                detail=self._entity_detail(counts),
                counts=dict(counts),
            )

    def _product_key(self, entity_type, record) -> str:
        """The product a catalogue record belongs to — what picks its worker."""
        if entity_type == PRODUCT:
            return str(record.source_key)
        if entity_type == STOCK:
            # A product's default variant is keyed by the product's own key.
            return self._variant_products.get(
                str(record.variant_source_key), str(record.variant_source_key)
            )
        return str(record.product_source_key)


    def _process_entity(self, spec, connector, transport, context, resolver):
        counts = {action: 0 for action in _ACTIONS}
        self._summary[spec.entity_type] = counts
        if self._tracker is not None:
            self._tracker.start(spec.entity_type)
        loader, shaped = self._make_loader(spec.entity_type)
        if loader is None:
            self._add_issue(
                spec.entity_type, "", ERROR, "no_loader", "لا يوجد مُحمِّل لهذا النوع من السجلات."
            )
            if self._tracker is not None:
                self._tracker.skip(spec.entity_type, "لا يوجد مُحمِّل لهذا النوع")
            return
        planned = self._planned.pop(spec.entity_type, None)
        records = (
            planned
            if planned is not None
            else connector.extract(spec.entity_type, transport, context)
        )
        planner = (
            document_planner(spec.entity_type, resolver, self.run)
            if self._collapse is None
            else None
        )
        if planner is not None:
            records = self._prepared(records, planner)
        try:
            if self._workers > 1 and spec.entity_type in _PARALLEL and self._collapse is None:
                self._process_parallel(spec, records, resolver, counts)
            else:
                self._process_serial(spec, loader, shaped, records, resolver, counts)
        finally:
            if planner is not None:
                # Whatever was written gets its number, even if the source
                # broke part-way: the run's last word on its own documents.
                renumber_placeholders(spec.entity_type)

    def _prepared(self, records, planner):
        """``records`` with their document numbers settled, a chunk at a time."""
        chunk = []
        for record in records:
            chunk.append(record)
            if len(chunk) >= _PLAN_CHUNK:
                yield from self._settle(planner, chunk)
                chunk = []
        if chunk:
            yield from self._settle(planner, chunk)

    def _settle(self, planner, chunk):
        for entity_type, issue in planner.prepare(chunk):
            self._add_issue(
                entity_type, issue.source_key, issue.severity, issue.code, issue.message
            )
        return chunk

    def _process_serial(self, spec, loader, shaped, records, resolver, counts):
        processed = 0
        batch = _CommitBatch(resolver, enabled=not self.dry_run)
        try:
            for record in records:
                batch.open()
                self._load_one(spec, loader, record, resolver, counts)
                batch.tick()
                # Feed the stock reconstructor (if active) regardless of whether
                # the order/PO row itself loaded — stock follows the source's
                # movements, not Pointy's import success.
                if self._reconstructor is not None and spec.entity_type in (SALE, PURCHASE_ORDER):
                    self._reconstructor.observe(spec.entity_type, record)
                processed += 1
                # Live count for big entities. A dry run's goes out through the
                # tracker's live publish; a row write would be rolled back.
                if processed % _PROGRESS_EVERY == 0:
                    if self._tracker is not None:
                        self._tracker.progress(
                            spec.entity_type,
                            detail=f"{processed:,} سجل",
                            counts=dict(counts),
                        )
                    if not self.dry_run:
                        self.run.update_progress(
                            self.run.progress_percent,
                            f"{spec.label}: {processed}",
                            current_entity=spec.entity_type,
                        )
        except Exception as exc:  # noqa: BLE001 - extract/transport failure for the whole entity
            # What loaded before the source broke stays loaded, as it did when
            # every record committed on its own.
            batch.close()
            self._add_issue(spec.entity_type, "", ERROR, "extract_failed", _friendly(exc))
            if self._tracker is not None:
                self._tracker.fail(spec.entity_type, _friendly(exc))
            return
        batch.close()
        if shaped is not None and self._carry_costs:
            counts["costed"] = shaped.costed
            counts["uncosted"] = shaped.uncosted
        if self._tracker is not None:
            self._tracker.done(
                spec.entity_type,
                detail=self._entity_detail(counts),
                counts=dict(counts),
            )

    def _load_one(self, spec, loader, record, resolver, counts):
        source_key = str(getattr(record, "source_key", "") or "")
        mark = resolver.mark()
        try:
            with transaction.atomic():  # per-record savepoint -> continue-on-error
                outcome = loader.load(record, resolver, dry_run=self.dry_run)
                _check_deferred_constraints()
        except Exception as exc:  # noqa: BLE001 - LoaderError, IntegrityError, ValidationError…
            # The savepoint took the record's rows back; take back what the
            # resolver learned from them too, or a later record would point
            # at a row that no longer exists.
            resolver.rollback_to(mark)
            counts[FAILED] += 1
            code = getattr(exc, "code", None) or exc.__class__.__name__
            detail = getattr(exc, "detail", None) or {}
            self._add_issue(spec.entity_type, source_key, ERROR, code, _friendly(exc), detail)
            return
        resolver.keep(mark)
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

    def _feed_reconstruction_snapshot(self, connector, transport, context, resolver):
        """Best-effort read of the source's *stored* stock — without importing it
        — so reconstruction can report how far the old system's own numbers were
        from what its invoices imply. Never fatal: a failure just drops the
        comparison hints, leaving the reconstruction itself intact.
        """
        if self._reconstructor is None or STOCK not in set(connector.supported_entities):
            return
        try:
            for record in connector.extract(STOCK, transport, context):
                self._reconstructor.observe_snapshot(record, resolver)
        except Exception as exc:  # noqa: BLE001 - comparison is optional, not fatal
            self._add_issue(STOCK, "", ERROR, "snapshot_read_failed", _friendly(exc))

    def _reconstruct_stock(self):
        """Net the observed purchase/sale movements into on-hand + diagnose.

        Writes the result under the ``stock`` summary bucket (so it shows up in
        the same place as a snapshot stock import) with an extra
        ``reconstruction`` sub-dict of stats, and records each warning (negative
        stock, etc.) as a regular issue.
        """
        if self._reconstructor is None:
            return
        if self._collapse is not None:
            # A collapsed variant's on-hand is the count of its units and
            # nothing else (§12.5). Netting invoices into the same bin would
            # give one number two authorities.
            self._reconstructor.ignore(self._collapse.variant_ids)
        result = self._reconstructor.flush(dry_run=self.dry_run)
        if self._tracker is not None:
            self._tracker.done(STOCK, counts=dict(result.counts))
        bucket = dict(result.counts)
        if result.stats:
            bucket["reconstruction"] = result.stats
        self._summary[STOCK] = bucket
        for issue in result.issues:
            self._add_issue(
                STOCK, issue.source_key, issue.severity, issue.code, issue.message, issue.detail
            )

    def _apply_collapse(self):
        """Build the identified articles the approved plan proposed.

        Reported under its own ``collapse`` bucket rather than folded into
        ``product``: an owner who approved "340 units" is owed a line that says
        340 units were created, or says why they were not.
        """
        result = self._collapse.apply_units()
        bucket = dict(result.counts)
        if result.stats:
            bucket["units"] = result.stats
        self._summary[COLLAPSE] = bucket
        for issue in result.issues:
            self._add_issue(
                COLLAPSE, issue.source_key, issue.severity, issue.code,
                issue.message, issue.detail,
            )
        if self._tracker is not None:
            self._tracker.done(COLLAPSE, self._entity_detail(result.counts),
                               counts=dict(result.counts))

    @staticmethod
    def _entity_detail(counts):
        parts = []
        if counts.get("created"):
            parts.append(f"{counts['created']:,} جديد")
        if counts.get("updated"):
            parts.append(f"{counts['updated']:,} تحديث")
        if counts.get("costed"):
            parts.append(f"{counts['costed']:,} بتكلفة")
        if counts.get("uncosted"):
            parts.append(f"{counts['uncosted']:,} بلا تكلفة")
        if counts.get("failed"):
            parts.append(f"{counts['failed']:,} فشل")
        return " · ".join(parts) or "لا توجد سجلات"

    # --- issues + summary ------------------------------------------------
    def _add_issue(self, entity_type, source_key, severity, code, message, detail=None):
        with self._issue_lock:  # worker threads report here too
            self._add_issue_locked(entity_type, source_key, severity, code, message, detail)

    def _add_issue_locked(self, entity_type, source_key, severity, code, message, detail):
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

        fields = ["summary", "updated_at"]
        if self._tracker is not None and not self._tracker.persist:
            # Dry run: the tracker never wrote (its writes would be rolled back
            # with everything else), so the timeline goes out with the summary.
            self.run.stages = self._tracker.as_list()
            fields.insert(1, "stages")
        self.run.save(update_fields=fields)

    def _persist_resolved_scope(self):
        """Record what this run decided about itself, next to what was asked.

        Both answers change what the numbers *mean*, and someone reading the
        report a month later has no other way to recover them: which entities
        actually ran (including the ones dependency closure had to add), and
        which of the source's two party figures was carried. Written once, at
        the start, so a run that fails halfway still says what it was doing.
        """
        if self._selection is None:
            return
        options = dict(self.run.options or {})
        options["resolved"] = dict(
            self._selection.as_dict(),
            party_balance_basis=self._balance_basis,
            stock_source=self._stock_source,
            carry_costs=self._carry_costs,
        )
        self.run.options = options
        self.run.save(update_fields=["options", "updated_at"])

    # --- finalisation ----------------------------------------------------
    def _specs_to_run(self, connector):
        """What this run actually walks, and in what order.

        Several things narrow or widen the operator's tick-boxes, and all of
        them have to happen before anything extracts, because the connectors are
        told the answer (an entity's meaning can depend on what else is in the
        run — see ``scopes``).
        """
        supported = set(connector.supported_entities)
        if attaches_to_catalogue(self.run.options):
            self._selection = attach_selection(supported)
            return [ENTITY_PLAN_BY_TYPE[entity] for entity in self._selection.entities]
        selected = set(self.run.selected_entities or []) or set(supported)
        # The stock entity carries two facts — quantity and cost — and runs
        # whenever this run wants either of them:
        #   snapshot    → quantities (and costs, unless declined)
        #   none        → no quantities; STOCK still runs for the costs when
        #                 they are carried and there is a catalogue to cost
        #   reconstruct → drop STOCK and compute on-hand from the purchase + sale
        #                 history instead, which therefore must be part of the run
        #                 (auto-included here even if the operator didn't tick it).
        #                 The costs arrive on those purchase lines.
        if self._stock_source in (STOCK_SOURCE_NONE, STOCK_SOURCE_RECONSTRUCT):
            selected.discard(STOCK)
        if (
            self._stock_source == STOCK_SOURCE_NONE
            and self._carry_costs
            and PRODUCT in selected
        ):
            selected |= {STOCK} & supported
        if self._stock_source == STOCK_SOURCE_RECONSTRUCT:
            selected |= {SALE, PURCHASE_ORDER} & supported
        if self._collapse is not None:
            # The catalogue pass is where a legacy key learns what it became;
            # without it every sale would resolve to nothing.
            selected |= {PRODUCT} & supported
        # Close over dependencies last, so anything the three rules above added
        # drags its own prerequisites in with it. Without this, "sales only"
        # means every sale line failing to resolve a variant — quietly, one
        # warning at a time, 900,000 times.
        self._selection = resolve_selection(selected, available=supported)
        # And the history brings the balances it walks forward from, which no
        # dependency can say without dragging the other kind of party along.
        self._selection = with_party_balances(self._selection, supported)
        return [ENTITY_PLAN_BY_TYPE[entity] for entity in self._selection.entities]

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
