import json
import re
import statistics
import threading
import time
import urllib.error
import urllib.request
from collections import Counter
from concurrent.futures import FIRST_COMPLETED, ThreadPoolExecutor, wait
from http.cookiejar import CookieJar


def run_load_stage(
    *,
    workers,
    duration,
    variants,
    options,
    database_vendor,
    sqlite_concurrency_warning,
    progress_interval=0,
    progress_callback=None,
):
    metrics = LoadMetrics()
    deadline = time.monotonic() + duration
    started_at = time.monotonic()

    with ThreadPoolExecutor(max_workers=workers) as executor:
        futures = {
            executor.submit(
                run_worker,
                worker_id=worker_id,
                username=f"{options['username_prefix']}-{worker_id + 1}",
                password=options["password"],
                base_url=options["base_url"],
                timeout=options["timeout"],
                deadline=deadline,
                variants=variants,
                metrics=metrics,
                think_ms=options["think_ms"],
                close_session=not options["keep_sessions_open"],
            )
            for worker_id in range(workers)
        }
        pending = set(futures)
        next_progress_at = time.monotonic() + progress_interval
        while pending:
            if progress_interval:
                timeout = max(next_progress_at - time.monotonic(), 0)
            else:
                timeout = None
            done, pending = wait(
                pending,
                timeout=timeout,
                return_when=FIRST_COMPLETED,
            )
            for future in done:
                exception = future.exception()
                if exception is not None:
                    metrics.record_failure(
                        operation="worker",
                        status_code=None,
                        elapsed=0,
                        error=str(exception),
                    )
            if progress_interval and progress_callback and time.monotonic() >= next_progress_at:
                progress_callback(
                    metrics.summary(
                        elapsed=time.monotonic() - started_at,
                        database_vendor=database_vendor,
                        sqlite_concurrency_warning=sqlite_concurrency_warning,
                        concurrent_clients=workers,
                    )
                )
                next_progress_at = time.monotonic() + progress_interval

    return metrics.summary(
        elapsed=time.monotonic() - started_at,
        database_vendor=database_vendor,
        sqlite_concurrency_warning=sqlite_concurrency_warning,
        concurrent_clients=workers,
    )


def build_ramp_stages(
    *,
    total_duration,
    step_duration,
    start_workers,
    max_workers,
    step_workers,
):
    stages = []
    remaining = total_duration
    workers = start_workers
    stage_number = 1

    while remaining > 0:
        duration = min(step_duration, remaining)
        stages.append(
            {
                "stage": stage_number,
                "workers": workers,
                "duration": duration,
            }
        )
        remaining -= duration
        workers = min(workers + step_workers, max_workers)
        stage_number += 1

    return stages


def collapse_reasons(
    summary,
    *,
    failure_rate_threshold,
    p95_ms_threshold,
    min_requests,
):
    reasons = []
    total_requests = summary["total_requests"]
    if total_requests == 0:
        return ["no checkout operations completed"]

    if summary["failures"] and total_requests < min_requests and summary["successes"] == 0:
        reasons.append(
            f"all {total_requests} recorded operation(s) failed before the minimum sample size"
        )
    elif (
        summary["failures"]
        and total_requests >= min_requests
        and summary["failure_rate"] >= failure_rate_threshold
    ):
        reasons.append(
            f"failure rate {summary['failure_rate']:.2%} reached "
            f"{failure_rate_threshold:.2%}"
        )

    p95_ms = summary["latency_ms"]["p95"]
    if p95_ms_threshold and p95_ms >= p95_ms_threshold:
        reasons.append(f"p95 latency {p95_ms:.2f}ms reached {p95_ms_threshold:.2f}ms")

    return reasons


def aggregate_stage_summaries(stages, *, elapsed):
    status_codes = Counter()
    errors = Counter()
    total_requests = 0
    successes = 0
    failures = 0

    for stage in stages:
        total_requests += stage["total_requests"]
        successes += stage["successes"]
        failures += stage["failures"]
        status_codes.update(stage["status_codes"])
        errors.update(stage["errors"])

    return {
        "total_requests": total_requests,
        "successes": successes,
        "failures": failures,
        "failure_rate": failures / total_requests if total_requests else 0,
        "throughput_rps": total_requests / elapsed if elapsed else 0,
        "success_rps": successes / elapsed if elapsed else 0,
        "status_codes": dict(sorted(status_codes.items())),
        "errors": dict(errors.most_common(8)),
    }


def capacity_summary(stages):
    passing_stages = [stage for stage in stages if not stage["collapsed"]]
    if not passing_stages:
        return None

    best_stage = max(
        passing_stages,
        key=lambda stage: (stage["concurrent_clients"], stage["success_rps"]),
    )
    return {
        "stage": best_stage["stage"],
        "concurrent_clients": best_stage["concurrent_clients"],
        "operations": best_stage["total_requests"],
        "success_rps": best_stage["success_rps"],
        "failure_rate": best_stage["failure_rate"],
        "p95_ms": best_stage["latency_ms"]["p95"],
        "p99_ms": best_stage["latency_ms"]["p99"],
    }


def compact_stage_summary(stage):
    if stage is None:
        return None
    return {
        "stage": stage["stage"],
        "concurrent_clients": stage["concurrent_clients"],
        "operations": stage["total_requests"],
        "success_rps": stage["success_rps"],
        "failure_rate": stage["failure_rate"],
        "p95_ms": stage["latency_ms"]["p95"],
        "p99_ms": stage["latency_ms"]["p99"],
        "collapse_reasons": stage["collapse_reasons"],
    }


def run_worker(
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
    client = HttpClient(base_url=base_url, timeout=timeout)
    login = client.post("auth/login/", {"username": username, "password": password}, csrf=False)
    if not is_success(login.status_code):
        metrics.record_failure(
            operation="login",
            status_code=login.status_code,
            elapsed=login.elapsed,
            error=login.error_summary,
        )
        return
    client.csrf_token = login.body.get("csrf_token") if isinstance(login.body, dict) else None

    session = client.post("register-sessions/start/", {"opening_cash": "0.00"})
    if not is_success(session.status_code):
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
        if is_success(result.status_code):
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
        if not is_success(result.status_code):
            metrics.record_failure(
                operation="register_close",
                status_code=result.status_code,
                elapsed=result.elapsed,
                error=result.error_summary,
            )


def is_success(status_code):
    return 200 <= status_code < 300


class HttpClient:
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
                return HttpResult(
                    status_code=response.status,
                    body=decode_json(raw_body),
                    elapsed=time.perf_counter() - started_at,
                    raw_body=raw_body,
                )
        except urllib.error.HTTPError as error:
            raw_body = error.read().decode("utf-8", errors="replace")
            return HttpResult(
                status_code=error.code,
                body=decode_json(raw_body),
                elapsed=time.perf_counter() - started_at,
                raw_body=raw_body,
            )
        except OSError as error:
            return HttpResult(
                status_code=0,
                body={},
                elapsed=time.perf_counter() - started_at,
                raw_body=str(error),
            )


class HttpResult:
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
        html_summary = html_error_summary(self.raw_body)
        if html_summary:
            return html_summary[:240]
        return (self.raw_body or "request failed")[:240]


class LoadMetrics:
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

    def summary(
        self,
        *,
        elapsed,
        database_vendor,
        sqlite_concurrency_warning,
        concurrent_clients,
    ):
        with self.lock:
            successes = self.successes
            failures = self.failures
            latencies = sorted(self.latencies)
            status_codes = dict(sorted(self.status_codes.items()))
            errors = dict(self.errors.most_common(8))
        total = successes + failures
        return {
            "database_vendor": database_vendor,
            "sqlite_concurrency_warning": sqlite_concurrency_warning,
            "concurrent_clients": concurrent_clients,
            "elapsed_seconds": elapsed,
            "total_requests": total,
            "successes": successes,
            "failures": failures,
            "failure_rate": failures / total if total else 0,
            "throughput_rps": total / elapsed if elapsed else 0,
            "success_rps": successes / elapsed if elapsed else 0,
            "latency_ms": latency_summary(latencies),
            "status_codes": status_codes,
            "errors": errors,
        }


def decode_json(raw_body):
    if not raw_body:
        return {}
    try:
        return json.loads(raw_body)
    except json.JSONDecodeError:
        return {}


def html_error_summary(raw_body):
    if "database is locked" in raw_body:
        return "OperationalError: database is locked"
    title = re.search(r"<title>(.*?)</title>", raw_body, flags=re.IGNORECASE | re.DOTALL)
    if title is None:
        return ""
    return re.sub(r"\s+", " ", title.group(1)).strip()


def latency_summary(latencies):
    if not latencies:
        return {"min": 0, "avg": 0, "p50": 0, "p95": 0, "p99": 0, "max": 0}
    return {
        "min": min(latencies),
        "avg": statistics.fmean(latencies),
        "p50": percentile(latencies, 50),
        "p95": percentile(latencies, 95),
        "p99": percentile(latencies, 99),
        "max": max(latencies),
    }


def percentile(sorted_values, percentile_value):
    if not sorted_values:
        return 0
    if len(sorted_values) == 1:
        return sorted_values[0]
    index = (len(sorted_values) - 1) * percentile_value / 100
    lower = int(index)
    upper = min(lower + 1, len(sorted_values) - 1)
    weight = index - lower
    return sorted_values[lower] * (1 - weight) + sorted_values[upper] * weight
