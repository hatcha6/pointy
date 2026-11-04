"""Fold imported alias variants into one variant with several barcodes.

    docker compose exec backend python manage.py flatten_imported_variants
    docker compose exec backend python manage.py flatten_imported_variants --apply

Without ``--apply`` it writes nothing and prints what it would do. Take a backup
first: the on-prem updater's snapshot, or ``make``'s backup target. Safe while the
shop trades: each product is its own short transaction, and running it twice
finishes what an interrupted run left.
"""

from __future__ import annotations

import json
from collections import Counter
from pathlib import Path

from django.core.management.base import BaseCommand, CommandError
from django.utils import timezone

from apps.migration import flatten


class Command(BaseCommand):
    help = "Fold imported alias variants into their product's single variant."

    def add_arguments(self, parser):
        parser.add_argument("--apply", action="store_true", help="Write the changes.")
        parser.add_argument(
            "--include",
            action="append",
            default=[],
            choices=sorted(flatten.OVERRULABLE),
            help="Also merge aliases held back for this reason.",
        )
        parser.add_argument(
            "--product", action="append", type=int, default=[], help="Only this product."
        )
        parser.add_argument("--report", help="Write the full report here as JSON.")

    def handle(self, *args, **options):
        run_key = timezone.now().strftime("%Y%m%dT%H%M%S")
        report = flatten.run(
            apply=options["apply"],
            include_reasons=options["include"],
            only_product_ids=set(options["product"]) or None,
            run_key=run_key,
        )
        write = self.stdout.write
        verb = "دُمج" if options["apply"] else "سيُدمج"
        products = {candidate.product_id for candidate in report.automatic}
        write(f"{verb}: {len(report.automatic)} صنفًا فرعيًا في {len(products)} منتجًا")
        reasons = Counter(
            reason for candidate in report.review for reason in candidate.reasons
        )
        write(f"للمراجعة: {len(report.review)} — {dict(reasons)}")
        if not options["apply"]:
            write(f"فرق قيمة المخزون المتوقع: {report.value_restated}")
            write(f"أصناف ستصبح تكلفتها أعلى من سعرها: {len(report.newly_below_cost)}")
        if options["apply"]:
            write(
                f"تم: {report.merged_variants} صنفًا في {report.merged_products} منتجًا، "
                f"التقاط متأخر: {report.swept}, مرفوض: {len(report.refused)}"
            )
            write(f"فرق قيمة المخزون بعد الدمج: {report.value_restated}")
            for outcome in report.refused[:50]:
                write(f"  ! {outcome.product_id} {outcome.product_name}: {outcome.refused} {outcome.detail}")

        moved = [
            key
            for key, value in report.before.items()
            if key != "ledger_value" and value != report.after[key]
        ]
        for key, value in report.before.items():
            write(f"  {key}: {value} -> {report.after[key]}")
        if options["report"]:
            Path(options["report"]).write_text(
                json.dumps(
                    {
                        "run_key": run_key,
                        "automatic": [vars(c) for c in report.automatic],
                        "review": [vars(c) for c in report.review],
                        "refused": [vars(o) for o in report.refused],
                        "value_restated": str(report.value_restated),
                        "newly_below_cost": report.newly_below_cost,
                        "before": {k: str(v) for k, v in report.before.items()},
                        "after": {k: str(v) for k, v in report.after.items()},
                    },
                    ensure_ascii=False,
                    indent=1,
                ),
                encoding="utf-8",
            )
        # Shop-wide totals can move only if a till sold during the run.
        if moved and options["apply"]:
            write(self.style.WARNING(f"تغيّرت أرقام أثناء التشغيل: {moved}"))
        if report.refused:
            raise CommandError(f"{len(report.refused)} منتجًا لم يُدمج.")
