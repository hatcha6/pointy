"""Run a migration from a file on the server's own disk, synchronously.

The app is the way to do this: the owner uploads their database and watches it
happen. This is the same pipeline with the upload step replaced by "the file is
already here" — for an operator sitting at the shop's machine with the ``.mdb``
on a USB stick, and for debugging a file without a browser.

    docker compose exec backend python manage.py import_legacy \\
        --file /tmp/db.mdb --mode dry_run
    docker compose exec backend python manage.py import_legacy \\
        --file /tmp/db.mdb --mode import

The file is hard-linked (or copied) into the staging root and then goes through
exactly the same identify → convert → prepare → detect → analyze pipeline as an
upload, so there is one code path and it is the one that gets exercised. The
system is detected, not declared. Preparation is skipped on a second run against
the same file, so dry-run → import does not reconvert gigabytes.
"""

from __future__ import annotations

import threading
from pathlib import Path

from django.core.management.base import BaseCommand, CommandError
from django.db import close_old_connections
from rest_framework.serializers import ValidationError

from apps.migration import services
from apps.migration.entity_plan import all_entity_types
from apps.migration.models import MigrationIssue, MigrationRun, MigrationSource
from apps.migration.preparation.local import adopt_and_prepare
from apps.migration.reconstruct import VALID_STOCK_SOURCES

_POLL_SECONDS = 10


class Command(BaseCommand):
    help = "Migrate a legacy POS database file into Pointy (no Celery needed)."

    def add_arguments(self, parser):
        parser.add_argument(
            "--file",
            required=True,
            help="Path of the legacy database file (.mdb, .accdb, .sqlite).",
        )
        parser.add_argument(
            "--mode",
            choices=[MigrationRun.Mode.DRY_RUN.value, MigrationRun.Mode.IMPORT.value],
            default=MigrationRun.Mode.DRY_RUN.value,
            help="dry_run validates everything and persists nothing (default).",
        )
        parser.add_argument(
            "--stock",
            choices=sorted(VALID_STOCK_SOURCES),
            default="none",
            help="How stock on hand is established (default: none — the shop "
            "does its own stock count afterwards).",
        )
        parser.add_argument(
            "--entities",
            default="",
            help="Comma-separated subset of entity types (default: everything "
            f"the connector supports). Known: {', '.join(all_entity_types())}",
        )
        parser.add_argument(
            "--reprepare",
            action="store_true",
            help="Re-run conversion even if this file was already prepared.",
        )
        parser.add_argument(
            "--keep-file",
            action="store_true",
            help="Do not delete the staged copy after a successful import.",
        )
        parser.add_argument(
            "--take-over",
            action="store_true",
            help="Mark any stuck queued/running run as failed before starting "
            "(e.g. after a previous command was killed).",
        )

    def handle(self, *args, **options):
        path = Path(options["file"]).expanduser().resolve()
        if not path.is_file():
            raise CommandError(f"File not found: {path}")

        if options["take_over"]:
            for run in MigrationRun.objects.filter(
                status__in=[MigrationRun.Status.QUEUED, MigrationRun.Status.RUNNING]
            ):
                run.mark_failed("أُلغيت من سطر الأوامر (--take-over).")

        source = self._source_for(path, reprepare=options["reprepare"])
        if not source.is_ready:
            raise CommandError(source.error_message or "Preparation failed.")

        self.stdout.write(
            f"Detected: {source.system_key} ({source.detected_version or 'unknown version'})"
        )
        self._print_analysis(source)

        entities = [item.strip() for item in options["entities"].split(",") if item.strip()]
        try:
            run = services.queue_migration_run(
                source,
                mode=options["mode"],
                entities=entities or None,
                options={
                    "stock_source": options["stock"],
                    # Operators re-run against the same working copy; deleting it
                    # after the first clean import would mean re-staging it.
                    "keep_file": bool(options["keep_file"]),
                },
                user=None,
                dispatch=False,
            )
        except ValidationError as exc:
            raise CommandError(str(exc.detail)) from exc

        self.stdout.write(
            f"Run #{run.pk}: mode={run.mode} stock={options['stock']} "
            f"entities={', '.join(run.selected_entities)}"
        )

        stop = threading.Event()
        reporter = threading.Thread(target=self._report_progress, args=(run.pk, stop), daemon=True)
        reporter.start()
        try:
            services.run_migration(run.pk)
        finally:
            stop.set()
            reporter.join(timeout=2)

        run.refresh_from_db()
        self._print_outcome(run)
        if run.status == MigrationRun.Status.FAILED:
            raise CommandError(run.error_message or "Migration failed.")

    # --- preparation ------------------------------------------------------
    def _source_for(self, path: Path, *, reprepare: bool) -> MigrationSource:
        return adopt_and_prepare(path, reprepare=reprepare, log=self.stdout.write)

    def _print_analysis(self, source):
        entities = (source.analysis or {}).get("entities") or {}
        if not entities:
            return
        self.stdout.write("Contents:")
        for entity_type, entry in entities.items():
            span = ""
            if entry.get("from") or entry.get("to"):
                span = f"  ({entry.get('from', '?')} → {entry.get('to', '?')})"
            self.stdout.write(f"  {entity_type:>18}: {entry.get('count', 0):,}{span}")

    # --- reporting --------------------------------------------------------
    def _report_progress(self, run_pk, stop):
        last = None
        while not stop.wait(_POLL_SECONDS):
            close_old_connections()
            row = (
                MigrationRun.objects.filter(pk=run_pk)
                .values_list("progress_percent", "progress_message")
                .first()
            )
            if row and row != last:
                last = row
                self.stdout.write(f"  … {row[0]:>3}% {row[1]}")

    def _print_outcome(self, run):
        self.stdout.write("")
        self.stdout.write(f"Status: {run.status} — {run.progress_message}")
        for entity, bucket in (run.summary or {}).items():
            counts = ", ".join(
                f"{key}={value}"
                for key, value in bucket.items()
                if isinstance(value, int) and value
            )
            self.stdout.write(f"  {entity:>18}: {counts or '0'}")

        issues = MigrationIssue.objects.filter(run=run)
        total_issues = issues.count()
        if total_issues:
            self.stdout.write(f"Issues: {total_issues} (top codes)")
            seen: dict[tuple[str, str], int] = {}
            for entity_type, code in issues.values_list("entity_type", "code"):
                seen[(entity_type, code)] = seen.get((entity_type, code), 0) + 1
            for (entity_type, code), count in sorted(seen.items(), key=lambda kv: -kv[1])[:10]:
                self.stdout.write(f"  {count:>7} × {entity_type}/{code}")
            self.stdout.write(
                "  (details: apps.migration.models.MigrationIssue, run_id="
                f"{run.pk} — or the Shop Settings migration screen)"
            )
        if run.status in (MigrationRun.Status.SUCCEEDED, MigrationRun.Status.PARTIAL):
            style = (
                self.style.SUCCESS
                if run.status == MigrationRun.Status.SUCCEEDED
                else self.style.WARNING
            )
            self.stdout.write(style(f"Done ({run.status})."))
