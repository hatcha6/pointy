import json
import re
import statistics
import threading
import time
import urllib.error
import urllib.request
from collections import Counter
from concurrent.futures import ThreadPoolExecutor, as_completed
from decimal import Decimal
from http.cookiejar import CookieJar

from django.contrib.auth import get_user_model
from django.core.management.base import BaseCommand, CommandError
from django.db import connection, transaction

from apps.catalog.models import Product, ProductCategory, ProductVariant
from apps.core.roles import CASHIER_GROUP, ensure_role_groups
from apps.inventory.models import StockItem


class Command(BaseCommand):
    help = (
        "Prepare deterministic checkout data and drive HTTP checkout load against a "
        "running Pointy API server."
    )

    def add_arguments(self, parser):
        parser.add_argument("--base-url", default="http://127.0.0.1:8000/api")
        parser.add_argument("--duration", type=int, default=60)
        parser.add_argument("--workers", type=int, default=4)
        parser.add_argument("--variant-count", type=int, default=12)
        parser.add_argument("--stock-per-variant", type=int, default=100000)
        parser.add_argument("--username-prefix", default="load-cashier")
        parser.add_argument("--password", default="pointy-load-pass")
        parser.add_argument("--timeout", type=float, default=10)
        parser.add_argument("--think-ms", type=int, default=0)
        parser.add_argument("--skip-prepare", action="store_true")
        parser.add_argument("--keep-sessions-open", action="store_true")
        parser.add_argument("--json", action="store_true", dest="json_output")
        parser.add_argument(
            "--fail-on-error",
            action="store_true",
            help="Return a non-zero exit code when any checkout request fails.",
        )

    def handle(self, *args, **options):
        duration = max(options["duration"], 1)
        workers = max(options["workers"], 1)
        variant_count = max(options["variant_count"], 1)

        if not options["skip_prepare"]:
            self._prepare_data(
                workers=workers,
                variant_count=variant_count,
                stock_per_variant=options["stock_per_variant"],
                username_prefix=options["username_prefix"],
                password=options["password"],
            )

        variants = self._load_variants(variant_count)
        if not variants:
            raise CommandError("No load-test variants exist. Run without --skip-prepare first.")

        database_vendor = connection.vendor
        sqlite_concurrency_warning = database_vendor == "sqlite" and workers > 1
        metrics = _LoadMetrics()
        deadline = time.monotonic() + duration
        started_at = time.monotonic()

        if not options["json_output"]:
            self._write_environment_note(
                database_vendor=database_vendor,
                sqlite_concurrency_warning=sqlite_concurrency_warning,
            )
            self.stdout.write(
                "Starting checkout load: "
                f"workers={workers}, duration={duration}s, variants={len(variants)}, "
                f"base_url={options['base_url']}"
            )

        with ThreadPoolExecutor(max_workers=workers) as executor:
            futures = [
                executor.submit(
                    _run_worker,
                    worker_id=worker_id,
                    username=f"{options['username_prefix']}-{worker_id + 1}",
                    password=options["password"],
                    base_url=options["base_url"],
                    timeout=options["timeout"],
                    deadline=deadline,
                    variants=variants,
                    metrics=metrics,
                    think_ms=max(options["think_ms"], 0),
                    close_session=not options["keep_sessions_open"],
                )
                for worker_id in range(workers)
            ]
            for future in as_completed(futures):
                exception = future.exception()
                if exception is not None:
                    metrics.record_failure(
                        operation="worker",
                        status_code=None,
                        elapsed=0,
                        error=str(exception),
                    )

        summary = metrics.summary(
            elapsed=time.monotonic() - started_at,
            database_vendor=database_vendor,
            sqlite_concurrency_warning=sqlite_concurrency_warning,
        )
        if options["json_output"]:
            self.stdout.write(json.dumps(summary, ensure_ascii=False, indent=2))
        else:
            self._write_summary(summary)

        if options["fail_on_error"] and summary["failures"] > 0:
            raise CommandError(f"{summary['failures']} load-test request(s) failed.")

    @transaction.atomic
    def _prepare_data(
        self,
        *,
        workers,
        variant_count,
        stock_per_variant,
        username_prefix,
        password,
    ):
        groups = ensure_role_groups()
        cashier_group = groups[CASHIER_GROUP]
        User = get_user_model()

        for index in range(workers):
            username = f"{username_prefix}-{index + 1}"
            user, _ = User.objects.get_or_create(
                username=username,
                defaults={"email": f"{username}@pointy.local"},
            )
            user.set_password(password)
            user.is_active = True
            user.save(update_fields=["password", "is_active"])
            user.groups.add(cashier_group)

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


def _run_worker(
    *,
    worker_id,
    username,
    password,
    base_url,
    timeout,
    deadline,
    variants,
    metrics,
    think_ms,
    close_session,
):
    client = _HttpClient(base_url=base_url, timeout=timeout)
    login = client.post("auth/login/", {"username": username, "password": password}, csrf=False)
    if not _is_success(login.status_code):
        metrics.record_failure(
            operation="login",
            status_code=login.status_code,
            elapsed=login.elapsed,
            error=login.error_summary,
        )
        return
    client.csrf_token = login.body.get("csrf_token") if isinstance(login.body, dict) else None

    session = client.post("register-sessions/start/", {"opening_cash": "0.00"})
    if not _is_success(session.status_code):
        metrics.record_failure(
            operation="register_start",
            status_code=session.status_code,
            elapsed=session.elapsed,
            error=session.error_summary,
        )
        return
    session_id = session.body.get("id") if isinstance(session.body, dict) else None

    iteration = 0
    while time.monotonic() < deadline:
        variant = variants[(worker_id + iteration) % len(variants)]
        payload = {
            "lines": [{"variant": variant["id"], "quantity": 1}],
            "payments": [{"method": "cash", "amount": variant["unit_price"]}],
        }
        result = client.post("orders/checkout/", payload)
        if _is_success(result.status_code):
            metrics.record_success(result.elapsed, result.status_code)
        else:
            metrics.record_failure(
                operation="checkout",
                status_code=result.status_code,
                elapsed=result.elapsed,
                error=result.error_summary,
            )
        iteration += 1
        if think_ms:
            time.sleep(think_ms / 1000)

    if close_session and session_id is not None:
        result = client.post(
            f"register-sessions/{session_id}/close/",
            {
                "closing_cash": "0.00",
                "count_025": 0,
                "count_050": 0,
                "count_075": 0,
                "count_100": 0,
            },
        )
        if not _is_success(result.status_code):
            metrics.record_failure(
                operation="register_close",
                status_code=result.status_code,
                elapsed=result.elapsed,
                error=result.error_summary,
            )


def _is_success(status_code):
    return 200 <= status_code < 300


class _HttpClient:
    def __init__(self, *, base_url, timeout):
        self.base_url = base_url.rstrip("/")
        self.timeout = timeout
        self.cookie_jar = CookieJar()
        self.opener = urllib.request.build_opener(
            urllib.request.HTTPCookieProcessor(self.cookie_jar)
        )
        self.csrf_token = None

    def post(self, path, payload, *, csrf=True):
        body = json.dumps(payload).encode("utf-8")
        headers = {
            "Accept": "application/json",
            "Content-Type": "application/json",
        }
        if csrf and self.csrf_token:
            headers["X-CSRFToken"] = self.csrf_token
        request = urllib.request.Request(
            f"{self.base_url}/{path.lstrip('/')}",
            data=body,
            headers=headers,
            method="POST",
        )
        started_at = time.perf_counter()
        try:
            with self.opener.open(request, timeout=self.timeout) as response:
                raw_body = response.read().decode("utf-8")
                return _HttpResult(
                    status_code=response.status,
                    body=_decode_json(raw_body),
                    elapsed=time.perf_counter() - started_at,
                    raw_body=raw_body,
                )
        except urllib.error.HTTPError as error:
            raw_body = error.read().decode("utf-8", errors="replace")
            return _HttpResult(
                status_code=error.code,
                body=_decode_json(raw_body),
                elapsed=time.perf_counter() - started_at,
                raw_body=raw_body,
            )
        except OSError as error:
            return _HttpResult(
                status_code=0,
                body={},
                elapsed=time.perf_counter() - started_at,
                raw_body=str(error),
            )


class _HttpResult:
    def __init__(self, *, status_code, body, elapsed, raw_body):
        self.status_code = status_code
        self.body = body
        self.elapsed = elapsed
        self.raw_body = raw_body

    @property
    def error_summary(self):
        if isinstance(self.body, dict):
            detail = self.body.get("detail")
            if detail:
                return str(detail)
            if self.body:
                return json.dumps(self.body, ensure_ascii=False)[:240]
        html_summary = _html_error_summary(self.raw_body)
        if html_summary:
            return html_summary[:240]
        return (self.raw_body or "request failed")[:240]


class _LoadMetrics:
    def __init__(self):
        self.lock = threading.Lock()
        self.latencies = []
        self.successes = 0
        self.failures = 0
        self.status_codes = Counter()
        self.errors = Counter()

    def record_success(self, elapsed, status_code):
        with self.lock:
            self.successes += 1
            self.latencies.append(elapsed * 1000)
            self.status_codes[str(status_code)] += 1

    def record_failure(self, *, operation, status_code, elapsed, error):
        with self.lock:
            self.failures += 1
            if elapsed:
                self.latencies.append(elapsed * 1000)
            self.status_codes[str(status_code or "network")] += 1
            self.errors[f"{operation}: {error}"] += 1

    def summary(self, *, elapsed, database_vendor, sqlite_concurrency_warning):
        total = self.successes + self.failures
        latencies = sorted(self.latencies)
        return {
            "database_vendor": database_vendor,
            "sqlite_concurrency_warning": sqlite_concurrency_warning,
            "elapsed_seconds": elapsed,
            "total_requests": total,
            "successes": self.successes,
            "failures": self.failures,
            "throughput_rps": total / elapsed if elapsed else 0,
            "success_rps": self.successes / elapsed if elapsed else 0,
            "latency_ms": _latency_summary(latencies),
            "status_codes": dict(sorted(self.status_codes.items())),
            "errors": dict(self.errors.most_common(8)),
        }


def _decode_json(raw_body):
    if not raw_body:
        return {}
    try:
        return json.loads(raw_body)
    except json.JSONDecodeError:
        return {}


def _html_error_summary(raw_body):
    if "database is locked" in raw_body:
        return "OperationalError: database is locked"
    title = re.search(r"<title>(.*?)</title>", raw_body, flags=re.IGNORECASE | re.DOTALL)
    if title is None:
        return ""
    return re.sub(r"\s+", " ", title.group(1)).strip()


def _latency_summary(latencies):
    if not latencies:
        return {"min": 0, "avg": 0, "p50": 0, "p95": 0, "p99": 0, "max": 0}
    return {
        "min": min(latencies),
        "avg": statistics.fmean(latencies),
        "p50": _percentile(latencies, 50),
        "p95": _percentile(latencies, 95),
        "p99": _percentile(latencies, 99),
        "max": max(latencies),
    }


def _percentile(sorted_values, percentile):
    if not sorted_values:
        return 0
    if len(sorted_values) == 1:
        return sorted_values[0]
    index = (len(sorted_values) - 1) * percentile / 100
    lower = int(index)
    upper = min(lower + 1, len(sorted_values) - 1)
    weight = index - lower
    return sorted_values[lower] * (1 - weight) + sorted_values[upper] * weight
