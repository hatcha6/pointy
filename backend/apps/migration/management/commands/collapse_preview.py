"""What a one-product-per-handset catalogue would collapse into — on real data.

§12's last line is the reason this command exists: *run it on their real export
before the meeting.* A screen that shows a shop its own catalogue folding from
340 rows to 12 is a better demo than any feature list, and the only way to know
it will is to have already done it.

    docker compose exec backend python manage.py collapse_preview --file /tmp/shop.mdb
    docker compose exec backend python manage.py collapse_preview --file /tmp/shop.mdb \\
        --review 40 --csv /tmp/collapse.csv

Reads the file and writes nothing to the shop: the plan it builds is the same
row the app's review screen reads, so what this prints is what the owner will
see. ``--approve`` marks it approved from here, for an operator who is going on
to run ``import_legacy`` against the same file.
"""

from __future__ import annotations

import csv
from collections import Counter
from pathlib import Path

from django.core.management.base import BaseCommand, CommandError

from apps.migration import services
from apps.migration.collapse.planner import clusters_for
from apps.migration.models import CollapseCandidate, CollapsePlan
from apps.migration.preparation.local import adopt_and_prepare


class Command(BaseCommand):
    help = "Preview the §12 collapse of a legacy catalogue (no Celery needed)."

    def add_arguments(self, parser):
        parser.add_argument(
            "--file",
            required=True,
            help="Path of the legacy database file (.mdb, .accdb, .sqlite).",
        )
        parser.add_argument(
            "--clusters",
            type=int,
            default=20,
            help="How many proposed products to print (default: 20; 0 for all).",
        )
        parser.add_argument(
            "--review",
            type=int,
            default=15,
            help="How many least-confident rows to print (default: 15).",
        )
        parser.add_argument(
            "--csv",
            default="",
            help="Write every candidate row to this CSV — the sheet to go through with the shop.",
        )
        parser.add_argument(
            "--approve",
            action="store_true",
            help="Mark the plan approved, so import_legacy can use it.",
        )
        parser.add_argument(
            "--reprepare",
            action="store_true",
            help="Re-run conversion even if this file was already prepared.",
        )

    def handle(self, *args, **options):
        path = Path(options["file"]).expanduser().resolve()
        if not path.is_file():
            raise CommandError(f"File not found: {path}")

        source = adopt_and_prepare(path, reprepare=options["reprepare"], log=self.stdout.write)
        if not source.is_ready:
            raise CommandError(source.error_message or "Preparation failed.")
        self.stdout.write(
            f"Detected: {source.system_key} ({source.detected_version or 'unknown version'})"
        )

        plan = services.queue_collapse_plan(source, user=None, dispatch=False)
        self.stdout.write("Reading the catalogue, its purchases and its sales…")
        services.build_collapse_plan(plan.pk)
        plan.refresh_from_db()
        if plan.status == CollapsePlan.Status.FAILED:
            raise CommandError(plan.error_message or "Collapse failed.")

        self._print_headline(plan)
        self._print_clusters(plan, limit=options["clusters"])
        self._print_reasons(plan)
        self._print_review(plan, limit=options["review"])
        if options["csv"]:
            self._write_csv(plan, Path(options["csv"]).expanduser())
        if options["approve"]:
            services.approve_collapse_plan(plan, user=None)
            self.stdout.write(
                self.style.SUCCESS(
                    f"Approved. Run: manage.py import_legacy --file {path} "
                    f"--mode dry_run  (plan #{plan.pk} is picked up via "
                    "options={'collapse_plan': %d})" % plan.pk
                )
            )
        else:
            self.stdout.write(f"Plan #{plan.pk} is ready for review (nothing written).")

    # --- printing ---------------------------------------------------------
    def _print_headline(self, plan):
        stats = plan.stats or {}
        self.stdout.write("")
        self.stdout.write(
            self.style.SUCCESS(
                f"{stats.get('source_products', 0):,} products → "
                f"{stats.get('products', 0):,} products, "
                f"{stats.get('variants', 0):,} variants, "
                f"{stats.get('units', 0):,} units"
            )
        )
        self.stdout.write(
            f"  on hand {stats.get('units_in_stock', 0):,} · "
            f"sold {stats.get('units_sold', 0):,} · "
            f"left as products {stats.get('kept', 0):,} · "
            f"needs a look {stats.get('needs_review', 0):,}"
        )

    def _print_clusters(self, plan, *, limit):
        clusters = clusters_for(plan)
        if not clusters:
            self.stdout.write("Nothing in this file looks like one product per article.")
            return
        shown = clusters if limit <= 0 else clusters[:limit]
        self.stdout.write("")
        self.stdout.write(f"Proposed products ({len(clusters):,}):")
        for cluster in shown:
            options = " · ".join(
                f"{axis}: {', '.join(values)}"
                for axis, values in (cluster["option_values"] or {}).items()
            )
            self.stdout.write(
                f"  {cluster['units']:>5} units  {cluster['variants']:>3} variants  "
                f"{cluster['stem']}"
            )
            if options:
                self.stdout.write(f"          {options}")
        if limit > 0 and len(clusters) > limit:
            self.stdout.write(f"  … and {len(clusters) - limit:,} more")

    def _print_reasons(self, plan):
        counts = Counter()
        for reasons in plan.candidates.values_list("reasons", flat=True):
            counts.update(reasons or [])
        if not counts:
            return
        self.stdout.write("")
        self.stdout.write("Why rows are uncertain (or were left alone):")
        for reason, count in counts.most_common(12):
            self.stdout.write(f"  {count:>6} × {reason}")

    def _print_review(self, plan, *, limit):
        if limit <= 0:
            return
        rows = plan.candidates.filter(decision=CollapseCandidate.Decision.COLLAPSE).order_by(
            "confidence", "id"
        )[:limit]
        if not rows:
            return
        self.stdout.write("")
        self.stdout.write("Least confident first — the rows worth a person's time:")
        for row in rows:
            self.stdout.write(f"  {row.confidence}  {row.source_name}")
            self.stdout.write(
                f"        → {row.stem} / {row.identifier} "
                f"{row.options or ''} {row.attributes or ''} "
                f"[{', '.join(row.reasons or [])}]"
            )

    def _write_csv(self, plan, destination: Path):
        destination.parent.mkdir(parents=True, exist_ok=True)
        fields = [
            "source_key",
            "source_name",
            "decision",
            "stem",
            "identifier",
            "identifier_kind",
            "storage",
            "colour",
            "battery_health",
            "condition_grade",
            "unit_status",
            "unit_cost",
            "list_price",
            "sold_price",
            "acquired_at",
            "sold_at",
            "confidence",
            "reasons",
        ]
        with destination.open("w", newline="", encoding="utf-8-sig") as handle:
            writer = csv.DictWriter(handle, fieldnames=fields)
            writer.writeheader()
            for row in plan.candidates.all().order_by("confidence", "id").iterator():
                options = row.options or {}
                attributes = row.attributes or {}
                writer.writerow(
                    {
                        "source_key": row.source_key,
                        "source_name": row.source_name,
                        "decision": row.decision,
                        "stem": row.stem,
                        "identifier": row.identifier,
                        "identifier_kind": row.identifier_kind,
                        "storage": options.get("storage", ""),
                        "colour": options.get("colour", ""),
                        "battery_health": attributes.get("battery_health", ""),
                        "condition_grade": attributes.get("condition_grade", ""),
                        "unit_status": row.unit_status,
                        "unit_cost": row.unit_cost,
                        "list_price": row.list_price if row.list_price is not None else "",
                        "sold_price": row.sold_price if row.sold_price is not None else "",
                        "acquired_at": row.acquired_at.isoformat() if row.acquired_at else "",
                        "sold_at": row.sold_at.isoformat() if row.sold_at else "",
                        "confidence": row.confidence,
                        "reasons": " ".join(row.reasons or []),
                    }
                )
        self.stdout.write(f"Wrote {destination}")
