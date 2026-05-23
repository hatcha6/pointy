import json
import time
from decimal import Decimal

from django.contrib.auth import get_user_model
from django.core.management.base import BaseCommand, CommandError
from django.db import connection, transaction

from apps.catalog.models import Product, ProductCategory, ProductVariant
from apps.core.roles import CASHIER_GROUP, ensure_role_groups
from apps.inventory.models import StockItem
from apps.sales.load_testing import (
    aggregate_stage_summaries,
    build_ramp_stages,
    capacity_summary,
    collapse_reasons,
    compact_stage_summary,
    run_load_stage,
)


class Command(BaseCommand):
    help = (
        "Prepare deterministic checkout data and drive HTTP checkout load against a "
        "running Pointy API server."
    )

    def add_arguments(self, parser):
        parser.add_argument("--base-url", default="http://127.0.0.1:8000/api")
        parser.add_argument("--duration", type=int, default=60)
        parser.add_argument(
            "--workers",
            type=int,
            default=4,
            help="Concurrent checkout clients for fixed load, or max clients in ramp mode.",
        )
        parser.add_argument(
            "--ramp",
            action="store_true",
            help="Increase checkout clients in stages until duration ends or collapse is detected.",
        )
        parser.add_argument("--start-workers", type=int, default=1)
        parser.add_argument("--max-workers", type=int)
        parser.add_argument("--step-workers", type=int, default=4)
        parser.add_argument("--step-duration", type=int, default=180)
        parser.add_argument(
            "--collapse-failure-rate",
            type=float,
            default=0.01,
            help="Mark a ramp stage collapsed when failures reach this fraction.",
        )
        parser.add_argument(
            "--collapse-p95-ms",
            type=float,
            default=2000,
            help="Mark a ramp stage collapsed when p95 checkout latency reaches this value.",
        )
        parser.add_argument(
            "--min-collapse-requests",
            type=int,
            default=20,
            help="Minimum operations before failure-rate collapse is evaluated.",
        )
        parser.add_argument(
            "--no-stop-on-collapse",
            action="store_false",
            dest="stop_on_collapse",
            help="Continue later ramp stages after the first collapsed stage.",
        )
        parser.add_argument("--variant-count", type=int, default=12)
        parser.add_argument("--stock-per-variant", type=int, default=100000)
        parser.add_argument("--username-prefix", default="load-cashier")
        parser.add_argument("--password", default="pointy-load-pass")
        parser.add_argument("--timeout", type=float, default=10)
        parser.add_argument("--think-ms", type=int, default=0)
        parser.add_argument(
            "--progress-interval",
            type=float,
            default=10,
            help="Seconds between live progress lines. Use 0 to disable.",
        )
        parser.add_argument("--skip-prepare", action="store_true")
        parser.add_argument("--keep-sessions-open", action="store_true")
        parser.add_argument("--json", action="store_true", dest="json_output")
        parser.add_argument(
            "--fail-on-error",
            action="store_true",
            help="Return a non-zero exit code when any checkout request fails.",
        )
        parser.set_defaults(stop_on_collapse=True)

    def handle(self, *args, **options):
        duration = max(options["duration"], 1)
        workers = max(options["workers"], 1)
        variant_count = max(options["variant_count"], 1)
        ramp_enabled = options["ramp"]
        max_workers = max(options["max_workers"] or workers, 1)
        start_workers = max(options["start_workers"], 1)
        step_workers = max(options["step_workers"], 1)
        step_duration = max(options["step_duration"], 1)
        options["duration"] = duration
        options["workers"] = workers
        options["start_workers"] = start_workers
        options["step_workers"] = step_workers
        options["step_duration"] = step_duration
        options["think_ms"] = max(options["think_ms"], 0)
        options["progress_interval"] = max(options["progress_interval"], 0)
        options["collapse_failure_rate"] = max(options["collapse_failure_rate"], 0)
        options["collapse_p95_ms"] = max(options["collapse_p95_ms"], 0)
        options["min_collapse_requests"] = max(options["min_collapse_requests"], 1)

        if ramp_enabled and start_workers > max_workers:
            raise CommandError("--start-workers cannot exceed --max-workers.")

        stages = []
        if ramp_enabled:
            stages = build_ramp_stages(
                total_duration=duration,
                step_duration=step_duration,
                start_workers=start_workers,
                max_workers=max_workers,
                step_workers=step_workers,
            )

        prepare_workers = start_workers if ramp_enabled else workers

        if not options["skip_prepare"]:
            if not options["json_output"]:
                self.stdout.write(
                    "Preparing checkout load data: "
                    f"workers={prepare_workers}, variants={variant_count}"
                )
                self.stdout.flush()
            self._prepare_users(
                workers=prepare_workers,
                username_prefix=options["username_prefix"],
                password=options["password"],
            )
            self._prepare_catalog_data(
                variant_count=variant_count,
                stock_per_variant=options["stock_per_variant"],
            )

        variants = self._load_variants(variant_count)
        if not variants:
            raise CommandError("No load-test variants exist. Run without --skip-prepare first.")

        database_vendor = connection.vendor
        sqlite_concurrency_warning = database_vendor == "sqlite" and prepare_workers > 1

        if not options["json_output"]:
            self._write_environment_note(
                database_vendor=database_vendor,
                sqlite_concurrency_warning=sqlite_concurrency_warning,
            )

        if ramp_enabled:
            summary = self._run_ramp(
                stages=stages,
                variants=variants,
                options=options,
                database_vendor=database_vendor,
                sqlite_concurrency_warning=sqlite_concurrency_warning,
            )
        else:
            if not options["json_output"]:
                self.stdout.write(
                    "Starting checkout load: "
                    f"workers={workers}, duration={duration}s, variants={len(variants)}, "
                    f"base_url={options['base_url']}"
                )
            summary = run_load_stage(
                workers=workers,
                duration=duration,
                variants=variants,
                options=options,
                database_vendor=database_vendor,
                sqlite_concurrency_warning=sqlite_concurrency_warning,
                progress_interval=self._progress_interval(options),
                progress_callback=self._write_fixed_progress,
            )
            summary["mode"] = "fixed"

        if options["json_output"]:
            self.stdout.write(json.dumps(summary, ensure_ascii=False, indent=2))
        elif ramp_enabled:
            self._write_ramp_summary(summary)
        else:
            self._write_summary(summary)

        if options["fail_on_error"] and summary["failures"] > 0:
            raise CommandError(f"{summary['failures']} load-test request(s) failed.")

    def _run_ramp(
        self,
        *,
        stages,
        variants,
        options,
        database_vendor,
        sqlite_concurrency_warning,
    ):
        started_at = time.monotonic()
        stage_summaries = []
        collapse_stage = None

        if not options["json_output"]:
            last_stage = stages[-1]
            self.stdout.write(
                "Starting checkout stress ramp: "
                f"duration={sum(stage['duration'] for stage in stages)}s, "
                f"stage_duration={options['step_duration']}s, "
                f"workers={stages[0]['workers']}..{last_stage['workers']}, "
                f"step={options['step_workers']}, variants={len(variants)}, "
                f"base_url={options['base_url']}"
            )

        for stage in stages:
            if not options["skip_prepare"]:
                if not options["json_output"]:
                    self.stdout.write(
                        "Preparing ramp stage users: "
                        f"workers={stage['workers']}"
                    )
                    self.stdout.flush()
                self._prepare_users(
                    workers=stage["workers"],
                    username_prefix=options["username_prefix"],
                    password=options["password"],
                )

            if not options["json_output"]:
                self.stdout.write(
                    "\n"
                    f"Ramp stage {stage['stage']}/{len(stages)}: "
                    f"workers={stage['workers']}, duration={stage['duration']}s"
                )

            summary = run_load_stage(
                workers=stage["workers"],
                duration=stage["duration"],
                variants=variants,
                options=options,
                database_vendor=database_vendor,
                sqlite_concurrency_warning=sqlite_concurrency_warning,
                progress_interval=self._progress_interval(options),
                progress_callback=self._stage_progress_writer(stage),
            )
            summary.update(
                {
                    "stage": stage["stage"],
                    "mode": "ramp_stage",
                    "target_duration_seconds": stage["duration"],
                }
            )
            stage_collapse_reasons = collapse_reasons(
                summary,
                failure_rate_threshold=options["collapse_failure_rate"],
                p95_ms_threshold=options["collapse_p95_ms"],
                min_requests=max(options["min_collapse_requests"], 1),
            )
            summary["collapsed"] = bool(stage_collapse_reasons)
            summary["collapse_reasons"] = stage_collapse_reasons
            stage_summaries.append(summary)

            if not options["json_output"]:
                self._write_ramp_stage_result(summary)

            if stage_collapse_reasons and collapse_stage is None:
                collapse_stage = summary
                if options["stop_on_collapse"]:
                    break

        elapsed = time.monotonic() - started_at
        totals = aggregate_stage_summaries(stage_summaries, elapsed=elapsed)
        capacity = capacity_summary(stage_summaries)
        return {
            "mode": "ramp",
            "database_vendor": database_vendor,
            "sqlite_concurrency_warning": sqlite_concurrency_warning,
            "elapsed_seconds": elapsed,
            "configured_duration_seconds": sum(stage["duration"] for stage in stages),
            "stage_count": len(stage_summaries),
            "planned_stage_count": len(stages),
            "stop_on_collapse": options["stop_on_collapse"],
            "collapse_thresholds": {
                "failure_rate": options["collapse_failure_rate"],
                "p95_ms": options["collapse_p95_ms"],
                "min_requests": max(options["min_collapse_requests"], 1),
            },
            "collapse_detected": collapse_stage is not None,
            "collapse_stage": compact_stage_summary(collapse_stage),
            "capacity_before_collapse": capacity,
            "stages": stage_summaries,
            **totals,
        }

    def _progress_interval(self, options):
        if options["json_output"]:
            return 0
        return options["progress_interval"]

    def _stage_progress_writer(self, stage):
        def write_progress(summary):
            self._write_progress(
                prefix=(
                    f"  progress stage={stage['stage']} "
                    f"workers={stage['workers']}"
                ),
                summary=summary,
            )

        return write_progress

    def _write_fixed_progress(self, summary):
        self._write_progress(prefix="  progress", summary=summary)

    def _write_progress(self, *, prefix, summary):
        self.stdout.write(
            f"{prefix} "
            f"elapsed={summary['elapsed_seconds']:.0f}s "
            f"operations={summary['total_requests']} "
            f"success_rps={summary['success_rps']:.2f} "
            f"failures={summary['failures']} "
            f"p95={summary['latency_ms']['p95']:.2f}ms"
        )
        self.stdout.flush()

    def _write_ramp_stage_result(self, summary):
        self.stdout.write(
            "  result: "
            f"operations={summary['total_requests']}, "
            f"success_rps={summary['success_rps']:.2f}, "
            f"failures={summary['failures']} ({summary['failure_rate']:.2%}), "
            f"p95={summary['latency_ms']['p95']:.2f}ms, "
            f"p99={summary['latency_ms']['p99']:.2f}ms"
        )
        if summary["collapse_reasons"]:
            self.stdout.write(
                self.style.WARNING(
                    "  collapse: " + "; ".join(summary["collapse_reasons"])
                )
            )
        if summary["errors"]:
            self.stdout.write("  top errors:")
            for error, count in list(summary["errors"].items())[:3]:
                self.stdout.write(f"    {count}x {error}")

    def _write_ramp_summary(self, summary):
        self.stdout.write("")
        self.stdout.write(self.style.SUCCESS("Checkout stress ramp summary"))
        self.stdout.write(f"  database:          {summary['database_vendor']}")
        self.stdout.write(f"  elapsed_seconds:  {summary['elapsed_seconds']:.2f}")
        self.stdout.write(
            f"  stages_run:       {summary['stage_count']}/{summary['planned_stage_count']}"
        )
        self.stdout.write(f"  total_operations: {summary['total_requests']}")
        self.stdout.write(f"  successes:        {summary['successes']}")
        self.stdout.write(f"  failures:         {summary['failures']}")
        self.stdout.write(f"  avg_success_rps:  {summary['success_rps']:.2f}")
        if summary["status_codes"]:
            self.stdout.write(f"  status_codes:     {summary['status_codes']}")
        if summary["errors"]:
            self.stdout.write("  top_errors:")
            for error, count in summary["errors"].items():
                self.stdout.write(f"    {count}x {error}")

        capacity = summary["capacity_before_collapse"]
        if capacity is None:
            self.stdout.write(
                self.style.WARNING("  capacity:         no passing ramp stage recorded")
            )
        else:
            self.stdout.write(
                "  capacity:         "
                f"{capacity['concurrent_clients']} concurrent clients, "
                f"{capacity['success_rps']:.2f} checkouts/s, "
                f"p95={capacity['p95_ms']:.2f}ms"
            )

        collapse_stage = summary["collapse_stage"]
        if collapse_stage is None:
            self.stdout.write("  collapse:         not detected")
        else:
            self.stdout.write(
                self.style.WARNING(
                    "  collapse:         "
                    f"stage {collapse_stage['stage']} at "
                    f"{collapse_stage['concurrent_clients']} concurrent clients"
                )
            )
            for reason in collapse_stage["collapse_reasons"]:
                self.stdout.write(f"    - {reason}")

        self.stdout.write("  stages:")
        for stage in summary["stages"]:
            status_label = "collapsed" if stage["collapsed"] else "ok"
            self.stdout.write(
                f"    {stage['stage']:>2}. "
                f"workers={stage['concurrent_clients']:<4} "
                f"ops={stage['total_requests']:<7} "
                f"rps={stage['success_rps']:<7.2f} "
                f"p95={stage['latency_ms']['p95']:<8.2f} "
                f"p99={stage['latency_ms']['p99']:<8.2f} "
                f"fail={stage['failure_rate']:<7.2%} "
                f"{status_label}"
            )

    @transaction.atomic
    def _prepare_users(
        self,
        *,
        workers,
        username_prefix,
        password,
    ):
        groups = ensure_role_groups()
        cashier_group = groups[CASHIER_GROUP]
        User = get_user_model()

        for index in range(workers):
            username = f"{username_prefix}-{index + 1}"
            user, created = User.objects.get_or_create(
                username=username,
                defaults={"email": f"{username}@pointy.local"},
            )
            update_fields = []
            if created or not user.has_usable_password():
                user.set_password(password)
                update_fields.append("password")
            if not user.is_active:
                user.is_active = True
                update_fields.append("is_active")
            if update_fields:
                user.save(update_fields=update_fields)
            user.groups.add(cashier_group)

    @transaction.atomic
    def _prepare_catalog_data(
        self,
        *,
        variant_count,
        stock_per_variant,
    ):
        category, _ = ProductCategory.objects.get_or_create(
            name="اختبار الضغط",
            defaults={"description": "بيانات مخصصة لاختبارات التحمل."},
        )

        for index in range(variant_count):
            number = index + 1
            product, _ = Product.objects.get_or_create(
                name=f"منتج اختبار الضغط {number}",
                defaults={"description": "يباع آليًا أثناء اختبارات الضغط."},
            )
            product.categories.add(category)
            product.is_active = True
            product.save(update_fields=["is_active", "updated_at"])

            sku = f"LOAD-{number:04d}"
            variant = ProductVariant.objects.filter(sku=sku).first()
            if variant is None:
                variant = ProductVariant(product=product, sku=sku)

            variant.product = product
            variant.name = ""
            variant.barcode = f"990000{number:06d}"
            variant.unit_price = Decimal("3.50") + Decimal(index % 5)
            variant.is_active = True
            variant.is_default = not product.variants.exclude(pk=variant.pk).filter(
                is_default=True
            ).exists()
            variant.save()

            StockItem.objects.update_or_create(
                variant=variant,
                defaults={
                    "quantity_on_hand": stock_per_variant,
                    "quantity_committed": 0,
                    "quantity_expected": 0,
                    "reorder_level": 5,
                },
            )

    def _load_variants(self, variant_count):
        queryset = (
            ProductVariant.objects.filter(sku__startswith="LOAD-")
            .select_related("product")
            .order_by("sku")[:variant_count]
        )
        return [
            {
                "id": variant.pk,
                "sku": variant.sku,
                "unit_price": f"{variant.unit_price:.2f}",
            }
            for variant in queryset
        ]

    def _write_summary(self, summary):
        self.stdout.write("")
        self.stdout.write(self.style.SUCCESS("Checkout load summary"))
        self.stdout.write(f"  database:         {summary['database_vendor']}")
        self.stdout.write(f"  elapsed_seconds: {summary['elapsed_seconds']:.2f}")
        self.stdout.write(f"  concurrent_clients: {summary['concurrent_clients']}")
        self.stdout.write(f"  total_requests:  {summary['total_requests']}")
        self.stdout.write(f"  successes:       {summary['successes']}")
        self.stdout.write(f"  failures:        {summary['failures']}")
        self.stdout.write(f"  throughput_rps:  {summary['throughput_rps']:.2f}")
        self.stdout.write(f"  success_rps:     {summary['success_rps']:.2f}")
        self.stdout.write("  latency_ms:")
        for key in ("min", "avg", "p50", "p95", "p99", "max"):
            self.stdout.write(f"    {key}: {summary['latency_ms'][key]:.2f}")
        if summary["status_codes"]:
            self.stdout.write(f"  status_codes:    {summary['status_codes']}")
        if summary["errors"]:
            self.stdout.write("  errors:")
            for error, count in summary["errors"].items():
                self.stdout.write(f"    {count}x {error}")

    def _write_environment_note(self, *, database_vendor, sqlite_concurrency_warning):
        self.stdout.write(f"Database backend: {database_vendor}")
        if sqlite_concurrency_warning:
            self.stdout.write(
                self.style.WARNING(
                    "SQLite allows only one writer at a time, so concurrent checkout "
                    "load is likely to hit 'database is locked'. Use LOAD_WORKERS=1 "
                    "for a local SQLite baseline, or run stress/endurance tests on "
                    "PostgreSQL/MySQL for production-like capacity."
                )
            )
            self.stdout.write("")
