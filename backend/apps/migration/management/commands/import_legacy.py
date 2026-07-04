"""Run a data migration synchronously from the command line.

The migration feature is normally driven from the app (REST API + Celery
worker), but for on-site onboarding it's easier to run one-shot from a shell —
e.g. inside the Docker deployment:

    docker compose exec backend python manage.py import_legacy \
        --database /tmp/legacy-import.sqlite --mode dry_run
    docker compose exec backend python manage.py import_legacy \
        --database /tmp/legacy-import.sqlite --mode import

Defaults are tuned for the file-based Fahd flow (``fahd_sqlite`` connector,
``--stock none`` because the shop recounts on the new system), but any
registered connector/transport works. The command reuses the same
``MigrationSource`` for the same file path, so dry-run → import → re-import
all share one identity map and stay idempotent.
"""

from __future__ import annotations

import threading
from pathlib import Path

from django.core.management.base import BaseCommand, CommandError
from django.db import close_old_connections
from rest_framework.serializers import ValidationError

from apps.migration import services
from apps.migration.connectors import get_connector, list_connectors
from apps.migration.entity_plan import all_entity_types
from apps.migration.models import MigrationIssue, MigrationRun, MigrationSource
from apps.migration.reconstruct import VALID_STOCK_SOURCES

_POLL_SECONDS = 10


class Command(BaseCommand):
    help = "Run a legacy-POS data migration synchronously (no Celery needed)."

    def add_arguments(self, parser):
        parser.add_argument(
            "--database",
            required=True,
            help="Path of the source database (absolute path of the SQLite file).",
        )
        parser.add_argument(
            "--system",
            default="fahd_sqlite",
            help="Connector key (default: fahd_sqlite). Known: %s"
            % ", ".join(sorted(connector.system_key for connector in list_connectors())),
        )
        parser.add_argument("--name", default="", help="Display name for the saved source.")
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
            "--take-over",
            action="store_true",
            help="Mark any stuck queued/running run as failed before starting "
            "(e.g. after a previous command was killed).",
        )

    def handle(self, *args, **options):
        connector = get_connector(options["system"])
        if connector is None:
            raise CommandError(f"Unknown system {options['system']!r}.")

        database = Path(options["database"])
        if connector.required_transport == "sqlite" and not database.is_file():
            raise CommandError(f"Source database not found: {database}")

        if options["take_over"]:
            stale = MigrationRun.objects.filter(
                status__in=[MigrationRun.Status.QUEUED, MigrationRun.Status.RUNNING]
            )
            for run in stale:
                run.mark_failed("أُلغيت من سطر الأوامر (--take-over).")

        source, created = MigrationSource.objects.get_or_create(
            system_key=connector.system_key,
            transport_kind=connector.required_transport,
            database_name=str(database),
            defaults={"name": options["name"] or f"{connector.display_name} — CLI"},
        )
        self.stdout.write(
            f"Source #{source.pk} ({'new' if created else 'existing — identity map reused'})"
        )

        entities = [item.strip() for item in options["entities"].split(",") if item.strip()]
        try:
            run = services.queue_migration_run(
                source,
                mode=options["mode"],
                entities=entities or None,
                options={"stock_source": options["stock"]},
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
