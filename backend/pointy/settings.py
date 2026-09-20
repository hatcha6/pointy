import os
import sys
from datetime import timedelta
from pathlib import Path

from celery.schedules import crontab
from corsheaders.defaults import default_headers
import environ

BASE_DIR = Path(__file__).resolve().parent.parent

# True under `manage.py test` / pytest. Cross-request caches of DB state key off
# this: test transactions roll back without firing signals, so a cache warmed in
# one test would leak stale rows into the next (worst on pk=1 singletons).
TESTING = "test" in sys.argv or "PYTEST_CURRENT_TEST" in os.environ

env = environ.Env(
    DJANGO_DEBUG=(bool, False),
    DJANGO_ALLOWED_HOSTS=(list, ["localhost", "127.0.0.1"]),
    CORS_ALLOWED_ORIGINS=(list, []),
    CSRF_TRUSTED_ORIGINS=(list, ["http://localhost:8080", "http://127.0.0.1:8080"]),
    POINTY_ANALYTICS_BACKEND_PERFORMANCE_ENABLED=(bool, True),
    POINTY_ANALYTICS_BACKEND_SLOW_REQUEST_MS=(int, 750),
    POINTY_ANALYTICS_BUFFER_SIZE=(int, 50),
    POINTY_ANALYTICS_EXPORT_PARALLEL_WORKERS=(int, 2),
    POINTY_ANALYTICS_BUFFER_MAX_AGE_SECONDS=(int, 5),
    POINTY_ATTACHMENT_MAX_UPLOAD_BYTES=(int, 100 * 1024 * 1024),
    POINTY_ATTACHMENT_CONTENT_TOKEN_MAX_AGE_SECONDS=(int, 60 * 60 * 6),
    POINTY_PRODUCT_IMAGE_IMPORT_MAX_BYTES=(int, 10 * 1024 * 1024),
    POINTY_IMAGE_FETCH_TIMEOUT_SECONDS=(int, 8),
    POINTY_IMAGE_IMPORT_TOKEN_MAX_AGE_SECONDS=(int, 60 * 60),
    POINTY_RELAY_REQUEST_TIMEOUT_SECONDS=(int, 5),
    POINTY_RELAY_PAIRING_BUDGET_SECONDS=(int, 8),
    POINTY_RELAY_UNAVAILABLE_COOLDOWN_SECONDS=(int, 300),
    POINTY_RELAY_AI_REQUEST_TIMEOUT_SECONDS=(int, 120),
    POINTY_RELAY_IMAGE_SEARCH_TIMEOUT_SECONDS=(int, 15),
    POINTY_RELAY_ALLOW_INSECURE_CONTROL=(bool, False),
    POINTY_DISCOVERY_ENABLED=(bool, True),
    POINTY_DISCOVERY_PRIVATE_ONLY=(bool, True),
    POINTY_DISCOVERY_UDP_ENABLED=(bool, True),
    POINTY_DISCOVERY_UDP_PORT=(int, 47777),
    POINTY_DISCOVERY_API_PORT=(int, 8000),
    POINTY_DISCOVERY_TRUST_PROXY_HEADERS=(bool, False),
    POINTY_ALLOW_PRIVATE_HOSTS=(bool, False),
    POINTY_REQUIRE_LICENSE=(bool, False),
    POINTY_ENABLE_DJANGO_ADMIN=(bool, False),
    POINTY_ENABLE_API_DOCS=(bool, False),
    POINTY_PRICE_CHECKER_AUTOSTART=(bool, False),
    POINTY_PRICE_CHECKER_TCP_ENABLED=(bool, True),
    POINTY_PRICE_CHECKER_TCP_PORT=(int, 9101),
    POINTY_PRICE_CHECKER_UDP_ENABLED=(bool, True),
    POINTY_PRICE_CHECKER_UDP_PORT=(int, 9100),
    POINTY_PRICE_CHECKER_DISCOVERY_ENABLED=(bool, True),
    POINTY_PRICE_CHECKER_SCAN_PORTS=(str, "9101,9100"),
    POINTY_PRICE_CHECKER_SCAN_TIMEOUT=(float, 0.4),
    POINTY_CURRENCY_SUFFIX=(str, "د.ل"),
    POINTY_CURRENCY_LATIN=(str, "LYD"),
    # 0 = close the DB connection after each request/task instead of holding it
    # open. On-prem runs behind PgBouncer (transaction pooling), which owns
    # reuse; a non-zero value here would defeat pooling and let connections pile
    # up (the root cause of the max_connections exhaustion).
    DATABASE_CONN_MAX_AGE=(int, 0),
    DJANGO_SECURE_SSL_REDIRECT=(bool, False),
    DJANGO_SESSION_COOKIE_SECURE=(bool, False),
    DJANGO_CSRF_COOKIE_SECURE=(bool, False),
    POINTY_EXPIRY_ALERT_WINDOW_DAYS=(int, 30),
    POINTY_NOTIFICATION_SYNC_INTERVAL_MINUTES=(int, 15),
    POINTY_DASHBOARD_WARM_INTERVAL_MINUTES=(int, 5),
    POINTY_FRAUD_DETECTION_INTERVAL_MINUTES=(int, 15),
    POINTY_FRAUD_DETECTION_LOOKBACK_DAYS=(int, 30),
    POINTY_PASSWORD_MIN_LENGTH=(int, 4),
    POINTY_BACKUP_RETENTION_COUNT=(int, 7),
    POINTY_BACKUP_RESTORE_MAX_BYTES=(int, 5 * 1024 * 1024 * 1024),
    POINTY_SURVEILLANCE_TELEMETRY=(bool, True),
    POINTY_SURVEILLANCE_LINGER_SECONDS=(float, 30.0),
    POINTY_SURVEILLANCE_MAX_FFMPEG=(int, 12),
    POINTY_SURVEILLANCE_STILL_FPS=(int, 2),
    POINTY_SURVEILLANCE_STILL_WIDTH=(int, 640),
)
environ.Env.read_env(BASE_DIR / ".env")

SECRET_KEY = env("DJANGO_SECRET_KEY", default="dev-only-change-me")
DEBUG = env("DJANGO_DEBUG")
ALLOWED_HOSTS = env("DJANGO_ALLOWED_HOSTS")

# On-prem LAN appliances get their IP from DHCP and rely on UDP discovery so
# cashier tills find the backend with zero configuration. Pinning ALLOWED_HOSTS
# to a fixed IP would defeat that. When POINTY_ALLOW_PRIVATE_HOSTS is on we open
# Django's built-in check to "*" and let PrivateNetworkHostMiddleware enforce the
# real policy: accept any private/loopback/link-local Host (any LAN address the
# server might have) plus the explicitly listed names, and reject public hosts.
POINTY_ALLOW_PRIVATE_HOSTS = env("POINTY_ALLOW_PRIVATE_HOSTS")
# On-prem only: refuse to serve the API until the installation is licensed
# (enrolled). Off by default, so development and tests are unaffected.
POINTY_REQUIRE_LICENSE = env("POINTY_REQUIRE_LICENSE")

# The Django admin is a browsable map of every model and field plus a bulk data
# export, and on-prem it would sit on the shop LAN. Off unless explicitly asked
# for: developers enable it in backend/.env, deployments leave it off.
# Same reasoning for the generated API schema/Swagger UI.
POINTY_ENABLE_DJANGO_ADMIN = env("POINTY_ENABLE_DJANGO_ADMIN")
POINTY_ENABLE_API_DOCS = env("POINTY_ENABLE_API_DOCS")
if POINTY_ALLOW_PRIVATE_HOSTS:
    POINTY_LAN_ALLOWED_HOST_NAMES = sorted(
        {host.lower() for host in ALLOWED_HOSTS} | {"localhost", "127.0.0.1", "backend"}
    )
    ALLOWED_HOSTS = ["*"]

INSTALLED_APPS = [
    "django.contrib.admin",
    "django.contrib.auth",
    "django.contrib.contenttypes",
    "django.contrib.sessions",
    "django.contrib.messages",
    "django.contrib.staticfiles",
    "corsheaders",
    "django_filters",
    "drf_spectacular",
    "rest_framework",
    "apps.core",
    # The document lifecycle primitive: sits above core (it reads the period
    # lock and the money-date registry) and below every domain that registers a
    # document type with it.
    "apps.documents",
    "apps.channels",
    "apps.operations",
    "apps.analytics",
    "apps.catalog",
    "apps.inventory",
    "apps.sales",
    "apps.fraud",
    "apps.customers",
    "apps.purchasing",
    "apps.invoice_intake",
    "apps.discounts",
    "apps.payments",
    "apps.printing",
    "apps.reports",
    "apps.notifications",
    "apps.messaging",
    "apps.integrations",
    "apps.crm",
    "apps.attachments",
    "apps.employees",
    "apps.attendance",
    "apps.expenses",
    "apps.treasury",
    "apps.price_checker",
    "apps.ai",
    "apps.migration",
    "apps.holidays",
    "apps.fx",
    "apps.clients",
    "apps.companion",
    "apps.surveillance",
    "apps.scales",
]

# Documents that exist only to prove the lifecycle primitive, including the
# routes no shipped document uses yet. A real app with real tables, so the
# test database migrates and flushes them like any other; never installed in
# production. See apps/documents/testkit/models.py for why it is an app rather
# than a few tables conjured by a schema editor.
if TESTING or os.environ.get("POINTY_ENABLE_TESTKIT"):
    INSTALLED_APPS.append("apps.documents.testkit")

MIDDLEWARE = [
    "corsheaders.middleware.CorsMiddleware",
    "django.middleware.security.SecurityMiddleware",
    # Compresses JSON payloads (skips SSE + images — see apps.core.gzip).
    # Native tills talk straight to uvicorn, so this is the only gzip layer
    # they ever get; it matters most on relay-tunnel connections.
    "apps.core.gzip.SelectiveGZipMiddleware",
    "django.contrib.sessions.middleware.SessionMiddleware",
    "django.middleware.common.CommonMiddleware",
    "django.middleware.csrf.CsrfViewMiddleware",
    "django.contrib.auth.middleware.AuthenticationMiddleware",
    "apps.channels.middleware.SalesChannelMiddleware",
    "apps.analytics.middleware.BackendPerformanceAnalyticsMiddleware",
    # Bounds unauthenticated /api/ traffic. Sits inside the analytics
    # middleware so a refusal is still measured, and ahead of routing and the
    # view so a runaway costs a cache read. DRF throttles cannot cover this:
    # they run after permission checks, so a request destined to 401 never
    # reaches one.
    "apps.core.anonymous_throttle.AnonymousBurstCeilingMiddleware",
    # Pushes the state-version vector to clients on every API response so
    # their caches and loaded screens revalidate deterministically
    # (apps.core.state_version). Also stamps the two legacy single-value
    # headers older clients know, from the same read.
    "apps.core.state_middleware.StateVersionHeaderMiddleware",
    "django.contrib.messages.middleware.MessageMiddleware",
    "django.middleware.clickjacking.XFrameOptionsMiddleware",
]

if POINTY_ALLOW_PRIVATE_HOSTS:
    # Enforce the private-host policy that ALLOWED_HOSTS = ["*"] above intentionally
    # relaxed. Runs right after SecurityMiddleware so a disallowed Host is rejected
    # before any view or session work.
    _security_mw = "django.middleware.security.SecurityMiddleware"
    _insert_at = MIDDLEWARE.index(_security_mw) + 1 if _security_mw in MIDDLEWARE else 0
    MIDDLEWARE.insert(_insert_at, "apps.core.host_validation.PrivateNetworkHostMiddleware")

if POINTY_REQUIRE_LICENSE:
    # Gate the API behind a valid license (enrollment). Inserted right after
    # CommonMiddleware so request.path is resolved while auth/CSRF work is skipped
    # for the 503. Off by default — only on-prem deployments set this.
    _common_mw = "django.middleware.common.CommonMiddleware"
    _license_at = (
        MIDDLEWARE.index(_common_mw) + 1 if _common_mw in MIDDLEWARE else len(MIDDLEWARE)
    )
    MIDDLEWARE.insert(_license_at, "apps.core.license_gate.LicenseGateMiddleware")

ROOT_URLCONF = "pointy.urls"

TEMPLATES = [
    {
        "BACKEND": "django.template.backends.django.DjangoTemplates",
        "DIRS": [],
        "APP_DIRS": True,
        "OPTIONS": {
            "context_processors": [
                "django.template.context_processors.request",
                "django.contrib.auth.context_processors.auth",
                "django.contrib.messages.context_processors.messages",
            ],
        },
    }
]

WSGI_APPLICATION = "pointy.wsgi.application"

# Names the engine every test run is actually on. A git worktree has no `.env`
# (it is untracked) and `.env.example` points at sqlite, so a worktree silently
# tests on sqlite while the primary checkout tests on Postgres -- and the
# Postgres-only guards skip instead of failing, so the run looks green. Set
# POINTY_REQUIRE_POSTGRES=1 to make that an error rather than a warning.
TEST_RUNNER = "apps.core.test_runner.PointyTestRunner"

DATABASES = {
    "default": env.db("DATABASE_URL", default=f"sqlite:///{BASE_DIR / 'db.sqlite3'}"),
}
DATABASES["default"]["CONN_MAX_AGE"] = env("DATABASE_CONN_MAX_AGE")
# A persistent connection can be alive on our side and long dead on the server's:
# Postgres or PgBouncer restarting after a power blip, or the LAN resetting an idle
# socket, leaves every worker holding a handle that only fails on its next query.
# Without a health check Django hands that handle to the view, so the first request
# on each pooled connection 500s (and /readyz/ reports a perfectly healthy database
# as down) even though a reconnect would have worked. Django defers the ping to the
# first query of a request and skips it on a freshly opened connection, so this
# costs nothing when CONN_MAX_AGE is 0 and one round trip per request otherwise.
DATABASES["default"]["CONN_HEALTH_CHECKS"] = True
# How long a money write (checkout, return, void, register operation) may wait on
# a row lock before giving up. Postgres defaults to 0 = wait forever, so a till
# meeting a lock held by a bulk reprice, a stock-count apply, an import — or a
# session left idle in transaction by a worker that died mid-flight — hangs until
# the client's own 60s deadline expires, which cannot say whether the sale
# committed. Applied per-transaction via SET LOCAL (see apps/core/db_locks.py),
# so background work, migrations and reports keep waiting as long as they need.
# 0 disables the bound.
POINTY_DB_LOCK_WAIT_TIMEOUT_SECONDS = env.float(
    "POINTY_DB_LOCK_WAIT_TIMEOUT_SECONDS", default=10.0
)
# On-prem serves through PgBouncer in transaction-pooling mode, where server-side
# prepared statements cannot be shared across pooled backends. Turn off psycopg3's
# auto-prepare so pooled connections never hit "prepared statement ... does not
# exist". Harmless (tiny per-query cost) when connecting straight to Postgres.
if str(DATABASES["default"].get("ENGINE", "")).endswith("postgresql"):
    DATABASES["default"].setdefault("OPTIONS", {}).setdefault("prepare_threshold", None)
    # Named (server-side) cursors can't survive transaction pooling either: the
    # DECLARE lands on one PgBouncer backend and the FETCH/CLOSE on another, so
    # Postgres periodically logs `cursor "_django_curs_..._sync_N" does not exist`
    # (or "already exists" when a recycled name collides on a backend that still
    # holds a prior cursor). Disable them so QuerySet.iterator() streams rows
    # client-side. At single-shop scale the extra client-side buffering is cheap.
    DATABASES["default"]["DISABLE_SERVER_SIDE_CURSORS"] = True

SECURE_SSL_REDIRECT = env("DJANGO_SECURE_SSL_REDIRECT")
SESSION_COOKIE_SECURE = env("DJANGO_SESSION_COOKIE_SECURE")
CSRF_COOKIE_SECURE = env("DJANGO_CSRF_COOKIE_SECURE")
_secure_proxy_ssl_header = env("DJANGO_SECURE_PROXY_SSL_HEADER", default="")
if _secure_proxy_ssl_header:
    _secure_proxy_ssl_header_parts = [
        part.strip() for part in _secure_proxy_ssl_header.split(",", 1)
    ]
    if len(_secure_proxy_ssl_header_parts) == 2:
        SECURE_PROXY_SSL_HEADER = tuple(_secure_proxy_ssl_header_parts)

# Deliberately permissive. Shop staff here sign in on a shared POS terminal many
# times a shift and overwhelmingly choose a short numeric PIN; Django's stock
# policy (8 chars, not common, not numeric, not like your name) would reject
# essentially every password a real cashier picks. A rule that cannot be obeyed
# is not obeyed — it gets worked around, written on a sticky note by the till, or
# it blocks onboarding outright.
#
# So only a length floor is *enforced*. The stronger rules still ship, as advice:
# apps.core.password_policy serves them to the client, which shows them as
# suggestions next to the field. Raise POINTY_PASSWORD_MIN_LENGTH per deployment
# to tighten the floor.
POINTY_PASSWORD_MIN_LENGTH = env("POINTY_PASSWORD_MIN_LENGTH")

AUTH_PASSWORD_VALIDATORS = [
    {
        "NAME": "django.contrib.auth.password_validation.MinimumLengthValidator",
        "OPTIONS": {"min_length": POINTY_PASSWORD_MIN_LENGTH},
    },
]

LANGUAGE_CODE = "en-us"
TIME_ZONE = "UTC"
USE_I18N = True
USE_TZ = True

# The shop's local timezone, used only to resolve which calendar date an event
# falls on for the holidays calendar (see apps.core.timeutils). It deliberately
# does NOT change Django's UTC TIME_ZONE or app-wide timezone.localdate().
POINTY_BUSINESS_TIMEZONE = env("POINTY_BUSINESS_TIMEZONE", default="Africa/Tripoli")

STATIC_URL = "static/"
STATIC_ROOT = Path(env("DJANGO_STATIC_ROOT", default=str(BASE_DIR / "staticfiles")))
MEDIA_URL = "media/"
MEDIA_ROOT = Path(env("DJANGO_MEDIA_ROOT", default=str(BASE_DIR / "media")))
# Directory of bundled client installers (Android APK + Windows installer) served
# on the LAN by apps.clients. Populated by the on-prem install/update flow.
CLIENTS_ROOT = Path(env("DJANGO_CLIENTS_ROOT", default=str(BASE_DIR / "clients")))
DEFAULT_AUTO_FIELD = "django.db.models.BigAutoField"

REDIS_URL = env("REDIS_URL", default="redis://localhost:6379/0")

# Every cache call must be BOUNDED. redis-py defaults both socket timeouts to
# None, which means "block forever": a Redis that *refuses* connections fails
# fast (ECONNREFUSED) and the fail-open guards in apps.core.caching absorb it,
# but a Redis that accepts the TCP connection and then stops answering — a box
# that is swapping, a container wedged mid-restart, a LAN link that drops
# packets after the handshake — hangs the read with no timeout at all. Sessions,
# the user row and the permission set are read from Redis on every authenticated
# request, so that hang is every till in the shop freezing mid-sale with no
# error and no way forward. Bounded, the same outage is a sub-second stumble
# that falls through to Postgres. Redis is on the same host or the shop LAN, so
# a healthy round-trip is sub-millisecond; the defaults leave three orders of
# magnitude of headroom and are still short enough that a wedged Redis costs a
# request a fraction of a second rather than its life.
POINTY_REDIS_SOCKET_TIMEOUT = env.float("POINTY_REDIS_SOCKET_TIMEOUT", default=1.0)
POINTY_REDIS_SOCKET_CONNECT_TIMEOUT = env.float(
    "POINTY_REDIS_SOCKET_CONNECT_TIMEOUT", default=1.0
)

CACHES = {
    "default": {
        "BACKEND": "django_redis.cache.RedisCache",
        "LOCATION": REDIS_URL,
        "OPTIONS": {
            "CLIENT_CLASS": "django_redis.client.DefaultClient",
            "SOCKET_TIMEOUT": POINTY_REDIS_SOCKET_TIMEOUT,
            "SOCKET_CONNECT_TIMEOUT": POINTY_REDIS_SOCKET_CONNECT_TIMEOUT,
        },
    }
}

# Sessions: read from Redis, write through to Postgres — a Redis restart never
# logs anyone out, but steady-state requests skip the session-table SELECT.
# apps.core.sessions is cached_db with the cache side made fail-open (stock
# cached_db 500s on save if Redis is down).
SESSION_ENGINE = "apps.core.sessions"

# ModelBackend with the resolved permission set memoised in Redis (fail-open,
# invalidated by the perm-version signals in apps.core.signals). Deliberately
# the ONLY backend: a second one would make every DENIED permission check fall
# through to live queries and break login()'s single-backend inference. The
# trade-off is one-time: sessions minted before this backend existed store the
# old dotted path and get logged out on update — devices just re-login once.
AUTHENTICATION_BACKENDS = ["apps.core.auth_backends.CachedPermissionsBackend"]

CELERY_BROKER_URL = REDIS_URL
CELERY_RESULT_BACKEND = REDIS_URL
CELERY_TASK_ALWAYS_EAGER = False
CELERY_TIMEZONE = TIME_ZONE
# Only accept JSON-serialized messages so a compromised broker cannot deliver a
# pickle payload that executes arbitrary code on the worker.
CELERY_ACCEPT_CONTENT = ["json"]
CELERY_TASK_SERIALIZER = "json"
CELERY_RESULT_SERIALIZER = "json"
# Bound ordinary periodic tasks (notification sync, fraud scan, expiry alerts,
# payroll) so a hung task cannot pin a worker forever. The soft limit raises
# SoftTimeLimitExceeded for graceful cleanup before the hard kill. Backup and
# restore are long-running and override these with their own higher limits.
CELERY_TASK_SOFT_TIME_LIMIT = env.int("CELERY_TASK_SOFT_TIME_LIMIT", default=25 * 60)
CELERY_TASK_TIME_LIMIT = env.int("CELERY_TASK_TIME_LIMIT", default=30 * 60)
# Backup/restore can legitimately run for a long time on large archives, so
# they are exempted from the short default limits above.
POINTY_BACKUP_TASK_SOFT_TIME_LIMIT = env.int(
    "POINTY_BACKUP_TASK_SOFT_TIME_LIMIT", default=6 * 60 * 60
)
POINTY_BACKUP_TASK_TIME_LIMIT = env.int(
    "POINTY_BACKUP_TASK_TIME_LIMIT", default=6 * 60 * 60 + 5 * 60
)
POINTY_EXPIRY_ALERT_WINDOW_DAYS = env("POINTY_EXPIRY_ALERT_WINDOW_DAYS")
POINTY_NOTIFICATION_SYNC_INTERVAL_MINUTES = max(
    env("POINTY_NOTIFICATION_SYNC_INTERVAL_MINUTES"),
    1,
)
POINTY_DASHBOARD_WARM_INTERVAL_MINUTES = max(
    env("POINTY_DASHBOARD_WARM_INTERVAL_MINUTES"),
    1,
)
POINTY_FRAUD_DETECTION_LOOKBACK_DAYS = max(
    env("POINTY_FRAUD_DETECTION_LOOKBACK_DAYS"),
    1,
)
POINTY_FRAUD_DETECTION_INTERVAL_MINUTES = max(
    env("POINTY_FRAUD_DETECTION_INTERVAL_MINUTES"),
    1,
)
POINTY_BACKUP_RETENTION_COUNT = max(env("POINTY_BACKUP_RETENTION_COUNT"), 1)
POINTY_BACKUP_ALLOWED_ROOTS = env.list(
    "POINTY_BACKUP_ALLOWED_ROOTS",
    default=[
        str(BASE_DIR / "backups"),
        "/mnt",
        "/media",
        "/run/media",
        "/Volumes",
    ],
)
POINTY_BACKUP_STAGING_ROOT = Path(
    env("POINTY_BACKUP_STAGING_ROOT", default="/tmp/pointy-backup-staging")
)
# Ceiling on unauthenticated API requests per device (or per peer address when
# the client sends no device id), per window. Real anonymous use is a few calls a
# minute — sign-in, first-run setup, price-checker lookups, discovery — so this
# sits an order of magnitude above it and only ever bites a runaway client.
# 0 disables the ceiling.
# Disabled under tests, which hammer endpoints far faster than any human and
# authenticate through DRF's force_authenticate — which sets no session cookie,
# so this middleware (running ahead of DRF) would read them as anonymous. The
# authenticated ceiling is switched off for the same reason.
# A purchase cost that is obviously a typo must not become the cost of record.
# Both ratios compare BASE-UNIT figures (a 162-per-carton egg line is 0.45 an
# egg), and both are read at two levels: the warning level asks the buyer to
# confirm on the purchasing screen, the blocking level refuses outright on the
# POS cash-purchase path, where the operator is a cashier with no override. The
# blocking level is deliberately looser so a genuinely thin-margin cash purchase
# still goes through. Calibrated against the field data rather than picked round:
# every actual typo in the client's dump was 5x or worse (bread 138x, stock cube
# 84x, ice cream 50x, bottled water 10x), while the items genuinely sold below
# cost sat at 1.1-1.8x. Anything under 3x is a thin margin, not a mistake, and
# warning about it would only teach people to click through. See
# apps.purchasing.cost_guard.
POINTY_PURCHASE_COST_WARN_PRICE_RATIO = env.float(
    "POINTY_PURCHASE_COST_WARN_PRICE_RATIO", default=3.0
)
POINTY_PURCHASE_COST_WARN_SPIKE_RATIO = env.float(
    "POINTY_PURCHASE_COST_WARN_SPIKE_RATIO", default=5.0
)
POINTY_PURCHASE_COST_BLOCK_PRICE_RATIO = env.float(
    "POINTY_PURCHASE_COST_BLOCK_PRICE_RATIO", default=5.0
)
POINTY_PURCHASE_COST_BLOCK_SPIKE_RATIO = env.float(
    "POINTY_PURCHASE_COST_BLOCK_SPIKE_RATIO", default=10.0
)
# The receipt queue is an outbox for print agents. It exists so a receipt
# survives an agent being briefly unreachable — not so it can accumulate for an
# agent that never existed, which is what a shop printing straight from the till
# did to the tune of 24,264 unread rows. A job is only created when an agent has
# polled within this window (0 disables the check and always creates).
POINTY_PRINT_AGENT_LIVENESS_WINDOW_MINUTES = env.int(
    "POINTY_PRINT_AGENT_LIVENESS_WINDOW_MINUTES", default=60
)
# Backstop for the other direction: rows created while an agent WAS alive and
# then abandoned when it went away. A receipt still unclaimed this long after
# the sale will not be handed to that customer, and printing it then would be
# worse than not printing it. It stays reprintable from the order. 0 disables.
POINTY_PRINT_JOB_QUEUE_RETENTION_HOURS = env.int(
    "POINTY_PRINT_JOB_QUEUE_RETENTION_HOURS", default=12
)
POINTY_PRINT_JOB_QUEUE_SWEEP_MINUTES = max(
    env.int("POINTY_PRINT_JOB_QUEUE_SWEEP_MINUTES", default=60), 1
)
# How many telemetry uploads one worker may process at once. A rate limit still
# admits a burst inside its window, and the burst is what buried the box: three
# uvicorn workers against 37 requests a second of nested-serializer validation
# left product-list taking 104 seconds and the till unable to sell. Over this,
# callers are refused immediately rather than queueing for a worker the POS
# needs; the events stay on the device. Per worker process, so the real ceiling
# is this times POINTY_ASGI_WORKERS. 0 disables the limit.
POINTY_ANALYTICS_INGEST_CONCURRENCY = env.int(
    "POINTY_ANALYTICS_INGEST_CONCURRENCY", default=2
)
POINTY_ANONYMOUS_BURST_LIMIT = (
    0 if TESTING else env.int("POINTY_ANONYMOUS_BURST_LIMIT", default=120)
)
POINTY_ANONYMOUS_BURST_WINDOW_SECONDS = env.int(
    "POINTY_ANONYMOUS_BURST_WINDOW_SECONDS", default=60
)
POINTY_BACKUP_RESTORE_MAX_BYTES = env("POINTY_BACKUP_RESTORE_MAX_BYTES")
# A scheduled backup that fails gets this many goes before the day is written
# off, spaced this far apart. The common field failures -- the USB drive not
# plugged in yet, a container restarting mid-run -- clear within the hour, and
# without a retry a single one of them cost a shop 24 hours of backups.
POINTY_BACKUP_MAX_ATTEMPTS_PER_DAY = max(
    env.int("POINTY_BACKUP_MAX_ATTEMPTS_PER_DAY", default=3), 1
)
POINTY_BACKUP_RETRY_INTERVAL_MINUTES = max(
    env.int("POINTY_BACKUP_RETRY_INTERVAL_MINUTES", default=30), 1
)
# How long the shop may go without a verified backup before the notification
# feed escalates. Two days covers a single missed night plus its retries.
POINTY_BACKUP_STALE_AFTER_HOURS = max(
    env.int("POINTY_BACKUP_STALE_AFTER_HOURS", default=48), 1
)
# Tables left out of the archive: telemetry and machine exhaust, not business
# records. Excluding a table is only safe while nothing that IS kept references
# it, which apps.core.backup_database enforces at dump time.
POINTY_BACKUP_EXCLUDED_TABLES = env.list(
    "POINTY_BACKUP_EXCLUDED_TABLES",
    default=[
        "analytics_analyticsevent",
        "core_idempotencyrecord",
        "printing_printjobevent",
        "django_session",
    ],
)
# --- Data migration (apps.migration) ----------------------------------------
# A migration starts with a file the owner uploads: their old POS database.
# These files are big (Fahd's Access database was 1.5 GB) and they are the
# shop's entire trading history, so they live on their own volume with a short
# life: the raw upload is deleted the moment it has been converted, the
# converted copy the moment the import lands, and anything abandoned is swept
# after the TTL below.
#
# NOT under /tmp — the container mounts a 64 MB tmpfs there.
POINTY_MIGRATION_STAGING_ROOT = Path(
    env("POINTY_MIGRATION_STAGING_ROOT", default=str(BASE_DIR / "migration-staging"))
)
# Ceiling on one uploaded database. Generous: the largest real one so far was
# 1.5 GB, and an Access file that has never been compacted can be several times
# the size of the data inside it.
POINTY_MIGRATION_MAX_UPLOAD_BYTES = env.int(
    "POINTY_MIGRATION_MAX_UPLOAD_BYTES", default=8 * 1024 * 1024 * 1024
)
# Upload chunk size. Small enough to make a resume after a dropped connection
# cheap; large enough that a 1.5 GB file is ~96 requests, not thousands.
#
# Hard-capped, because this number and the browser front door's
# `client_max_body_size` (100m, deploy/onprem/web/nginx.conf) are set in two
# different places and would otherwise drift. Raising the env var past that cap
# breaks uploads from the browser with a bare nginx 413 while native tills —
# which reach `edge` directly, where the body size is uncapped — keep working:
# a failure that depends on how you opened the app is the worst kind to debug.
# The server advertises this value to clients, so clamping it here is what makes
# it impossible to ask for a chunk the path cannot carry.
POINTY_MIGRATION_MAX_CHUNK_BYTES = 64 * 1024 * 1024
POINTY_MIGRATION_CHUNK_BYTES = min(
    max(env.int("POINTY_MIGRATION_CHUNK_BYTES", default=16 * 1024 * 1024), 64 * 1024),
    POINTY_MIGRATION_MAX_CHUNK_BYTES,
)
# How long an upload nobody finished importing is kept before the sweep deletes
# it. Long enough to survive "I'll do it tomorrow morning", short enough that a
# shop's whole history is not sitting on disk indefinitely.
POINTY_MIGRATION_UPLOAD_TTL_HOURS = max(
    env.int("POINTY_MIGRATION_UPLOAD_TTL_HOURS", default=48), 1
)
# Wall-clock ceiling on one mdbtools table export. A huge table (Fahd's 4.6M-row
# `control` log) takes minutes; anything past this is a wedged subprocess.
POINTY_MIGRATION_CONVERT_TABLE_TIMEOUT_SECONDS = env.int(
    "POINTY_MIGRATION_CONVERT_TABLE_TIMEOUT_SECONDS", default=60 * 60
)

POINTY_SMS_DEBT_REMINDERS_ENABLED = env.bool(
    "POINTY_SMS_DEBT_REMINDERS_ENABLED", default=False
)
# When on, creating a discount auto-drafts a marketing campaign for it (still
# awaiting human approval). Off by default so no shop gets surprise drafts.
POINTY_SMS_AUTO_CAMPAIGN_ON_DISCOUNT = env.bool(
    "POINTY_SMS_AUTO_CAMPAIGN_ON_DISCOUNT", default=False
)
# When on (and AI is entitled), a nightly task drafts a win-back campaign for
# slipping cohorts. Opt-in; always a draft awaiting human approval, never sent.
POINTY_SMS_AI_SUGGESTIONS_ENABLED = env.bool(
    "POINTY_SMS_AI_SUGGESTIONS_ENABLED", default=False
)
# Explicit base URL the SMS Gate phone should POST webhooks to (e.g.
# http://192.168.1.20:8000). Blank = derive from the activation request's Host
# (the LAN address the admin reached the backend on).
POINTY_MESSAGING_WEBHOOK_BASE_URL = env(
    "POINTY_MESSAGING_WEBHOOK_BASE_URL", default=""
)
# How long an idempotency record can still match a retry. Clients retry within
# seconds; two days is generous.
POINTY_IDEMPOTENCY_RETENTION_HOURS = int(
    os.getenv("POINTY_IDEMPOTENCY_RETENTION_HOURS", "48")
)

CELERY_BEAT_SCHEDULE = {
    # Card receipts whose issuer has to be asked are proved after the sale, not
    # during it. This finds the ones that never got an answer -- the broker was
    # down at checkout, or the shop was offline long enough to burn the retries
    # -- so no card payment stays permanently unchecked.
    "payments.sweep-unverified-card-receipts": {
        "task": "payments.sweep_unverified_card_receipts",
        "schedule": crontab(minute="*/20"),
    },
    "notifications.sync-business-notifications": {
        "task": "notifications.sync_business_notifications",
        "schedule": timedelta(minutes=POINTY_NOTIFICATION_SYNC_INTERVAL_MINUTES),
    },
    "core.warm-dashboard-cache": {
        "task": "core.warm_dashboard_cache",
        "schedule": timedelta(minutes=POINTY_DASHBOARD_WARM_INTERVAL_MINUTES),
    },
    # The companion inbox is a replay buffer for a dropped stream, so it is
    # pruned rather than kept: a busy shop scans all day and every scan is a row.
    # Uploaded legacy databases are the shop's entire history sitting on disk.
    # Nothing else deletes one that was uploaded and then abandoned, so this
    # does — see POINTY_MIGRATION_UPLOAD_TTL_HOURS.
    "migration.purge-expired-uploads": {
        "task": "migration.purge_expired_uploads",
        "schedule": crontab(minute=43),
    },
    "companion.purge-expired": {
        "task": "companion.purge_expired",
        "schedule": crontab(minute=17),
    },
    "fraud.sync-suspected-fraud-findings": {
        "task": "fraud.sync_suspected_fraud_findings",
        "schedule": timedelta(minutes=POINTY_FRAUD_DETECTION_INTERVAL_MINUTES),
    },
    # Pull the fingerprint terminals' punches off the BioTime server. The task
    # existed but was never scheduled, so attendance only ever moved when a
    # manager opened the settings screen and pressed Sync -- and the monthly
    # payroll draft below therefore costed absences off whatever had last been
    # imported by hand. Hourly: punches upload from the devices through the day,
    # and each run only reads forward from its cursor.
    "attendance.sync-biotime": {
        "task": "attendance.sync_biotime",
        "schedule": crontab(minute=25),
    },
    # Snapshot the closed month early on the shop's chosen day. The task checks
    # the day itself (it is configurable per shop), so the schedule only has to
    # give it one chance a day.
    "reports.snapshot-month-end": {
        "task": "reports.snapshot_month_end",
        "schedule": crontab(minute=5, hour=1),
    },
    # Nightly, after the day's trading: match what Pointy sold against what
    # the provider's own log says it performed. See apps.integrations.
    # reconciliation for why the three failure modes are kept apart.
    "integrations.reconcile-providers": {
        "task": "integrations.reconcile_providers",
        "schedule": crontab(minute=20, hour=2),
    },
    "employees.draft-monthly-payroll": {
        "task": "employees.draft_monthly_payroll",
        "schedule": crontab(minute=10, hour=0, day_of_month="1"),
    },
    # Retire receipt jobs nothing claimed — see printing.expire_stale_print_jobs.
    "printing.expire-stale-print-jobs": {
        "task": "printing.expire_stale_print_jobs",
        "schedule": timedelta(minutes=POINTY_PRINT_JOB_QUEUE_SWEEP_MINUTES),
    },
    # Idempotency records outlive their usefulness in hours, but nothing ever
    # deleted them: 28,406 rows and zero replays in the field.
    "core.purge-expired-idempotency-records": {
        "task": "core.purge_expired_idempotency_records",
        "schedule": crontab(minute=45, hour=3),
    },
    "core.run-due-scheduled-backup": {
        "task": "core.run_due_scheduled_backup",
        "schedule": timedelta(minutes=1),
    },
    # Free stock held by quotations (فاتورة عرض) once their validity date passes,
    # so expired reservations don't stay locked until someone converts or cancels.
    "sales.release-expired-quote-reservations": {
        "task": "sales.release_expired_quote_reservations",
        "schedule": crontab(minute=15, hour=0),
    },
    # Pull published exchange rates from the relay. Hourly rather than daily
    # because parallel-market rates move several times a day, and a shop that
    # prices imports off a nine-hour-old rate is carrying a real error. The
    # relay pushes new rates over the connector tunnel as they arrive; this is
    # the backstop that heals a shop which was offline when one was published.
    "fx.sync-exchange-rates": {
        "task": "fx.sync_exchange_rates",
        "schedule": crontab(minute=7),
    },
    # Pull the relay's holiday calendar (Eids entered per year, local events,
    # central corrections) into the local table once a day.
    "holidays.sync-holidays": {
        "task": "holidays.sync_holidays",
        "schedule": crontab(minute=30, hour=0),
    },
    # Best-effort hourly reconcile with the relay: pull entitlement changes and
    # push the shop name if it drifted while offline. Short cadence so a shop with
    # no subscription — usually offline — syncs whenever it next reaches the
    # internet, not only when a manager opens the Subscription status screen.
    "core.sync-relay-installation": {
        "task": "core.sync_relay_installation",
        "schedule": crontab(minute=0),
    },
    # Keep retrying license-key redemption until it lands (an offline install
    # enrolls the moment the shop first reaches the internet, activating its
    # subscriptions). No-op once enrolled or when no self-service credentials
    # are configured; independent of POINTY_REQUIRE_LICENSE, which only decides
    # whether an unlicensed backend blocks the API.
    "core.ensure-relay-enrollment": {
        "task": "core.ensure_relay_enrollment",
        "schedule": crontab(minute="*/10"),
    },
    # Re-score every customer's RFM rank overnight, after the day's sales have
    # settled. Runs once daily; the ranks only shift on a daily granularity
    # (recency is measured in days) so anything more frequent is wasted work.
    "customers.recompute-customer-segments": {
        "task": "customers.recompute_customer_segments",
        "schedule": crontab(minute=45, hour=2),
    },
    # Re-score every product's rolling-90-day "most bought" popularity overnight,
    # after the day's sales settle. Daily granularity is enough (the window moves
    # one day at a time) and read-time sorting uses the denormalized column.
    "catalog.recompute-product-popularity": {
        "task": "catalog.recompute_product_popularity",
        "schedule": crontab(minute=50, hour=2),
    },
    # Rebuild the purchase-suggestion tables (what each supplier's orders
    # habitually contain, and in what quantities) after the day's purchasing has
    # settled. Per-supplier refreshes already fire on every submit/receipt; this
    # nightly pass is what applies recency decay across the board and prunes
    # suppliers that fell out of the evidence window.
    "purchasing.rebuild-purchase-suggestions": {
        "task": "purchasing.rebuild_purchase_suggestions",
        "schedule": crontab(minute=55, hour=2),
    },
    # Pace the outbound message queue: drain due messages up to each gateway's
    # per-minute throttle / daily cap, holding marketing during quiet hours.
    "messaging.dispatch-outbound": {
        "task": "messaging.dispatch_outbound",
        "schedule": timedelta(seconds=10),
    },
    # Reconcile messages wedged in "sending" and expire stale ones.
    "messaging.sweep-stuck": {
        "task": "messaging.sweep_stuck",
        "schedule": timedelta(minutes=5),
    },
    # Daily debt reminders for open-credit (آجل) invoices — opt-in via
    # POINTY_SMS_DEBT_REMINDERS_ENABLED; the task no-ops when disabled.
    "crm.debt-reminder-sweep": {
        "task": "crm.debt_reminder_sweep",
        "schedule": crontab(minute=0, hour=10),
    },
    # Drain sending campaigns into the outbound queue (the gateway limiter paces
    # the actual sends).
    "crm.pump-sending-campaigns": {
        "task": "crm.pump_sending_campaigns",
        "schedule": timedelta(minutes=1),
    },
    # Nightly proactive AI campaign drafts (opt-in; always drafts).
    "crm.generate-ai-suggestions": {
        "task": "crm.generate_ai_suggestions",
        "schedule": crontab(minute=30, hour=3),
    },
}

CORS_ALLOWED_ORIGINS = env("CORS_ALLOWED_ORIGINS")
CORS_ALLOW_CREDENTIALS = True
# The POS sends custom request headers the browser lists in its CORS preflight;
# they must be allowed or the browser silently blocks the real request (the
# checkout POST never leaves the browser). Every non-safelisted header
# ``ApiSession`` attaches has to appear here — a header added on the client and
# forgotten here breaks the web build ENTIRELY, because the client sends the
# device trio on every request, login included. ``test_cors_preflight`` drives a
# real preflight with the whole set so the next one cannot be forgotten.
#
# Idempotency-Key guards every money mutation (checkout, returns, voids);
# X-Pointy-Relay-Token rides relay setups; the X-Pointy-Device-Id/Platform/
# App-Version trio identifies the device for throttling and telemetry; and
# If-None-Match carries the catalog ETag (not CORS-safelisted, so it preflights
# like the rest).
CORS_ALLOW_HEADERS = (
    *default_headers,
    "idempotency-key",
    "if-none-match",
    # Sent on EVERY request by PosApiSession, so a missing entry here does not
    # break one endpoint — it breaks the whole app cross-origin, and it does it
    # in the most confusing way available: the preflight answers 200, the
    # browser compares this list against what it asked for, finds a gap, and
    # silently never sends the real request. The server log then shows a run of
    # OPTIONS with no POST after them and no error anywhere.
    "x-request-id",
    "x-pointy-app-version",
    "x-pointy-device-id",
    "x-pointy-platform",
    # Only sent while a register session is open — so leaving it out breaks the
    # till after login rather than at it, which is worse to diagnose.
    "x-pointy-register-session",
    "x-pointy-relay-token",
)
# The mirror image of CORS_ALLOW_HEADERS, and just as easy to forget: on a
# CROSS-origin request a browser hides every non-safelisted response header from
# JavaScript unless it is named here. Silently, too — the header arrives on the
# wire and simply is not there when the client reads it.
#
# A served web build is same-origin (nginx serves the Flutter build and proxies
# /api), so this does not bite in production. It bites everywhere the two are
# split: `flutter run -d web-server` against a separate backend, and any
# deployment that serves the app from another origin. Without these entries the
# version headers are invisible there, and the client silently falls back to
# revalidating on its poll alone — the catalog-version push has been inert in
# that setup since it was added.
CORS_EXPOSE_HEADERS = [
    "Idempotency-Replayed",
    "X-Pointy-State",
    "X-Pointy-Catalog-Version",
    "X-Pointy-Discounts-Version",
]
CSRF_TRUSTED_ORIGINS = env("CSRF_TRUSTED_ORIGINS")
POINTY_ANALYTICS_BACKEND_PERFORMANCE_ENABLED = env("POINTY_ANALYTICS_BACKEND_PERFORMANCE_ENABLED")
POINTY_ANALYTICS_BACKEND_SLOW_REQUEST_MS = env("POINTY_ANALYTICS_BACKEND_SLOW_REQUEST_MS")
POINTY_ANALYTICS_BACKEND_PERFORMANCE_PATHS = ("/api/",)
# backend.request telemetry rows are bulk-inserted in batches of this size
# instead of one INSERT per request (see analytics/buffer.py). 0 = synchronous;
# forced synchronous under tests so assertions can see the row immediately.
POINTY_ANALYTICS_BUFFER_SIZE = 0 if TESTING else env("POINTY_ANALYTICS_BUFFER_SIZE")
POINTY_ANALYTICS_BUFFER_MAX_AGE_SECONDS = env("POINTY_ANALYTICS_BUFFER_MAX_AGE_SECONDS")
# Extra Postgres workers the analytics export's COPY may fan out across. The
# per-row work (three timestamp formats + two jsonb reads) is CPU-bound and
# parallelises cleanly, but every worker is a Postgres process competing with
# the POS while the shop trades — so this is a bounded, operator-tunable knob,
# not "as many as possible". 0 keeps the export single-threaded. On-prem caps
# Postgres CPU, so raise this only to match the cores actually allotted to it.
POINTY_ANALYTICS_EXPORT_PARALLEL_WORKERS = env(
    "POINTY_ANALYTICS_EXPORT_PARALLEL_WORKERS"
)
# --- Cameras -----------------------------------------------------------------
# Three knobs that were module constants until 0.5.2, which meant changing any of
# them needed a release. Each is something a shop might genuinely have to change
# from the outside, so each is now readable from .env.
#
# The kill switch first, and it is the reason this section exists: camera
# telemetry writes one row per viewing session, but telemetry has taken this
# product down twice — 5.1M rejected ingest calls, and a self-inflicted outage
# from worker starvation — so being able to switch it off on a shop's box at
# 2am, without cutting a release, is worth more than the tidiness of a constant.
POINTY_SURVEILLANCE_TELEMETRY = env("POINTY_SURVEILLANCE_TELEMETRY")
# How long a camera stream keeps running with nobody watching. Raising it makes
# scrolling a wall cheaper; lowering it is the pressure valve on a weak box,
# where every lingering stream is an ffmpeg still burning CPU.
POINTY_SURVEILLANCE_LINGER_SECONDS = env("POINTY_SURVEILLANCE_LINGER_SECONDS")
# Concurrent ffmpeg pipelines. The comment on the constant always described this
# as "a setting rather than a constant"; until now it was not actually settable.
POINTY_SURVEILLANCE_MAX_FFMPEG = env("POINTY_SURVEILLANCE_MAX_FFMPEG")
# The rate the sampled-stills live path runs at, on recorders that have no
# still-image endpoint of their own. It is the server's number rather than the
# client's so that every dashboard tile on every till shares one pipeline per
# camera; raising it costs one more JPEG encode per second per camera, not one
# more decode.
POINTY_SURVEILLANCE_STILL_FPS = env("POINTY_SURVEILLANCE_STILL_FPS")
# And the width it renders at. One number for every viewer, for the same reason
# as the rate: keeping each tile's own width would split a camera across an
# ffmpeg per distinct tile size. It only ever shrinks — a sub-stream narrower
# than this is passed through as it is. 0 means "whatever the stream is".
POINTY_SURVEILLANCE_STILL_WIDTH = env("POINTY_SURVEILLANCE_STILL_WIDTH")

POINTY_ATTACHMENT_STORAGE_ROOT = env(
    "POINTY_ATTACHMENT_STORAGE_ROOT",
    default=str(MEDIA_ROOT),
)
# Storage volumes (auto-discovered or created via the API) must live under the
# attachment storage root or one of these additional roots, so a privileged
# user cannot point a volume at an arbitrary host directory such as /etc. The
# storage root is always allowed; set this only when volumes are mounted
# elsewhere (e.g. an external drive at a fixed path).
POINTY_ATTACHMENT_ALLOWED_VOLUME_ROOTS = env.list(
    "POINTY_ATTACHMENT_ALLOWED_VOLUME_ROOTS",
    default=[],
)
POINTY_ATTACHMENT_MAX_UPLOAD_BYTES = env("POINTY_ATTACHMENT_MAX_UPLOAD_BYTES")
POINTY_ATTACHMENT_CONTENT_TOKEN_MAX_AGE_SECONDS = env(
    "POINTY_ATTACHMENT_CONTENT_TOKEN_MAX_AGE_SECONDS"
)
POINTY_ATTACHMENT_ALLOWED_CONTENT_TYPES = env.list(
    "POINTY_ATTACHMENT_ALLOWED_CONTENT_TYPES",
    default=[],
)
POINTY_ATTACHMENT_ALLOWED_TARGETS = env.list(
    "POINTY_ATTACHMENT_ALLOWED_TARGETS",
    default=[
        "catalog.product",
        "catalog.productvariant",
        "purchasing.purchaseorder",
        "purchasing.supplier",
        "sales.order",
        "customers.customer",
        "payments.payment",
        "inventory.stockitem",
        "inventory.stockmovement",
        "reports.reportrun",
        "core.shopsettings",
        "operations.job",
        "customers.asset",
        # A free capture from a paired phone is parked on the device that took
        # it until the till files it somewhere; the device is its owner.
        "companion.companiondevice",
        "companion.companioncapturerequest",
    ],
)
# --- Companion camera -------------------------------------------------------
# A phone paired to a till over the shop LAN: it scans 2-D codes the shop's
# laser scanners cannot read, and photographs products and invoices straight
# into the till. See apps.companion and COMPANION_CAMERA_PLAN.md.
#
# Short enough that a QR photographed off the till screen is useless by the time
# anyone could act on it, long enough to walk over and scan it.
POINTY_COMPANION_PAIRING_TTL_SECONDS = env.int(
    "POINTY_COMPANION_PAIRING_TTL_SECONDS", default=120
)
# A paired phone is a tool for a shift. It also dies when the pairing user's
# register session closes; 0 disables the idle half.
POINTY_COMPANION_IDLE_EXPIRY_HOURS = env.int(
    "POINTY_COMPANION_IDLE_EXPIRY_HOURS", default=24
)
POINTY_COMPANION_CAPTURE_TTL_SECONDS = env.int(
    "POINTY_COMPANION_CAPTURE_TTL_SECONDS", default=600
)
# The inbox is a replay buffer for a dropped stream, not an archive.
POINTY_COMPANION_EVENT_RETENTION_HOURS = env.int(
    "POINTY_COMPANION_EVENT_RETENTION_HOURS", default=48
)
POINTY_COMPANION_MAX_SCAN_LENGTH = env.int(
    "POINTY_COMPANION_MAX_SCAN_LENGTH", default=4096
)
# Stream pacing. The poll interval is what a cashier feels as scan latency; the
# max age bounds how long any one connection, thread or socket can live.
POINTY_COMPANION_STREAM_POLL_SECONDS = env.float(
    "POINTY_COMPANION_STREAM_POLL_SECONDS", default=0.25
)
POINTY_COMPANION_STREAM_HEARTBEAT_SECONDS = env.float(
    "POINTY_COMPANION_STREAM_HEARTBEAT_SECONDS", default=15.0
)
POINTY_COMPANION_STREAM_MAX_AGE_SECONDS = env.float(
    "POINTY_COMPANION_STREAM_MAX_AGE_SECONDS", default=3600.0
)
# However stale or wrong the Redis hint is, read the table at least this often.
# The hint is a latency optimisation; correctness comes from Postgres, and this
# is what guarantees a cache in any state cannot make a till go deaf.
POINTY_COMPANION_STREAM_RECONCILE_SECONDS = env.float(
    "POINTY_COMPANION_STREAM_RECONCILE_SECONDS", default=5.0
)
# Overrides the origin encoded in the pairing QR. Empty (the default) means
# "whatever address the till itself just reached us on", which is the one
# address proven reachable at the moment the QR is drawn.
POINTY_COMPANION_PUBLIC_ORIGIN = env("POINTY_COMPANION_PUBLIC_ORIGIN", default="")

POINTY_PRODUCT_IMAGE_IMPORT_MAX_BYTES = env("POINTY_PRODUCT_IMAGE_IMPORT_MAX_BYTES")
# Product image search is relay-hosted: the relay holds the Serper.dev key and
# gates on the shop's remote-access entitlement, so no per-shop search key or
# provider config lives here. See apps.attachments.image_search.
POINTY_IMAGE_FETCH_TIMEOUT_SECONDS = env("POINTY_IMAGE_FETCH_TIMEOUT_SECONDS")
POINTY_IMAGE_IMPORT_TOKEN_MAX_AGE_SECONDS = env("POINTY_IMAGE_IMPORT_TOKEN_MAX_AGE_SECONDS")
POINTY_RELAY_CONTROL_URL = env("POINTY_RELAY_CONTROL_URL", default="")
POINTY_RELAY_PUBLIC_API_URL = env("POINTY_RELAY_PUBLIC_API_URL", default="")
POINTY_RELAY_CONNECTOR_ADDR = env("POINTY_RELAY_CONNECTOR_ADDR", default="")
POINTY_RELAY_ADMIN_TOKEN = env("POINTY_RELAY_ADMIN_TOKEN", default="")
# Scoped per-installation credentials handed out at central provisioning. When the
# access token + installation id are set, the backend authenticates relay calls
# with them and never needs the company-wide admin token — this is the on-prem
# default. POINTY_RELAY_CONNECTOR_TOKEN is the matching secret the local connector
# presents for heartbeat/renewal.
POINTY_RELAY_ACCESS_TOKEN = env("POINTY_RELAY_ACCESS_TOKEN", default="")
POINTY_RELAY_INSTALLATION_ID = env("POINTY_RELAY_INSTALLATION_ID", default="")
POINTY_RELAY_CONNECTOR_TOKEN = env("POINTY_RELAY_CONNECTOR_TOKEN", default="")
# Single-use license key the shop ships with its install (a "license.key" file).
# Redeemed once on first boot to self-enroll: the relay returns the scoped
# access/connector tokens, the backend persists them, and the key is spent. The
# backend serves nothing until enrolled (see apps.core.license_gate).
POINTY_RELAY_ENROLLMENT_TOKEN = env("POINTY_RELAY_ENROLLMENT_TOKEN", default="")
POINTY_RELAY_BUSINESS_ID = env("POINTY_RELAY_BUSINESS_ID", default="")
POINTY_RELAY_REQUEST_TIMEOUT_SECONDS = env("POINTY_RELAY_REQUEST_TIMEOUT_SECONDS")
# Device pairing (every sign-in) chains two relay calls; this caps the chain as
# a whole so a slow uplink cannot hold a worker for a multiple of the timeout.
POINTY_RELAY_PAIRING_BUDGET_SECONDS = env("POINTY_RELAY_PAIRING_BUDGET_SECONDS")
# After a relay transport failure (timeout/unreachable), opportunistic callers
# answer "relay unavailable" from memory for this long. 0 disables.
POINTY_RELAY_UNAVAILABLE_COOLDOWN_SECONDS = env("POINTY_RELAY_UNAVAILABLE_COOLDOWN_SECONDS")
POINTY_RELAY_AI_REQUEST_TIMEOUT_SECONDS = env("POINTY_RELAY_AI_REQUEST_TIMEOUT_SECONDS")
POINTY_RELAY_IMAGE_SEARCH_TIMEOUT_SECONDS = env("POINTY_RELAY_IMAGE_SEARCH_TIMEOUT_SECONDS")

# AI chat carries base64 image/file attachments in the JSON body, so allow a
# larger request than Django's 2.5 MB default.
DATA_UPLOAD_MAX_MEMORY_SIZE = env.int(
    "POINTY_DATA_UPLOAD_MAX_MEMORY_SIZE", default=20 * 1024 * 1024
)
POINTY_RELAY_ALLOW_INSECURE_CONTROL = env("POINTY_RELAY_ALLOW_INSECURE_CONTROL")
POINTY_RELAY_CONTROL_CA_FILE = env("POINTY_RELAY_CONTROL_CA_FILE", default="")
POINTY_RELAY_CONTROL_CLIENT_CERT_FILE = env(
    "POINTY_RELAY_CONTROL_CLIENT_CERT_FILE",
    default="",
)
POINTY_RELAY_CONTROL_CLIENT_KEY_FILE = env(
    "POINTY_RELAY_CONTROL_CLIENT_KEY_FILE",
    default="",
)
POINTY_RELAY_CONNECTOR_SETUP_TOKEN = env(
    "POINTY_RELAY_CONNECTOR_SETUP_TOKEN",
    default="",
)
POINTY_RELAY_CONNECTOR_TLS_SERVER_NAME = env(
    "POINTY_RELAY_CONNECTOR_TLS_SERVER_NAME",
    default="",
)
POINTY_DISCOVERY_ENABLED = env("POINTY_DISCOVERY_ENABLED")
POINTY_DISCOVERY_PRIVATE_ONLY = env("POINTY_DISCOVERY_PRIVATE_ONLY")
POINTY_DISCOVERY_UDP_ENABLED = env("POINTY_DISCOVERY_UDP_ENABLED")
POINTY_DISCOVERY_UDP_PORT = env("POINTY_DISCOVERY_UDP_PORT")
POINTY_DISCOVERY_API_PORT = env("POINTY_DISCOVERY_API_PORT")
POINTY_DISCOVERY_API_BASE_URL = env("POINTY_DISCOVERY_API_BASE_URL", default="")
POINTY_DISCOVERY_TRUST_PROXY_HEADERS = env("POINTY_DISCOVERY_TRUST_PROXY_HEADERS")

# Price checker (self-service barcode price verifiers). The HTTP/web-kiosk
# family works through the normal API; the TCP/UDP socket family (e.g. Scantech
# Shuttle) is served by the optional asyncio daemon (see apps.price_checker).
POINTY_PRICE_CHECKER_AUTOSTART = env("POINTY_PRICE_CHECKER_AUTOSTART")
POINTY_PRICE_CHECKER_TCP_ENABLED = env("POINTY_PRICE_CHECKER_TCP_ENABLED")
POINTY_PRICE_CHECKER_TCP_PORT = env("POINTY_PRICE_CHECKER_TCP_PORT")
POINTY_PRICE_CHECKER_UDP_ENABLED = env("POINTY_PRICE_CHECKER_UDP_ENABLED")
POINTY_PRICE_CHECKER_UDP_PORT = env("POINTY_PRICE_CHECKER_UDP_PORT")
POINTY_PRICE_CHECKER_DISCOVERY_ENABLED = env("POINTY_PRICE_CHECKER_DISCOVERY_ENABLED")
POINTY_PRICE_CHECKER_SCAN_PORTS = env("POINTY_PRICE_CHECKER_SCAN_PORTS")
POINTY_PRICE_CHECKER_SCAN_TIMEOUT = env("POINTY_PRICE_CHECKER_SCAN_TIMEOUT")
# How long (seconds) a POS discount-preview result is cached in Redis. Bounds how
# stale a preview can be vs a just-edited/expired rule; checkout is always live.
POINTY_DISCOUNT_PREVIEW_CACHE_TTL = env.int("POINTY_DISCOUNT_PREVIEW_CACHE_TTL", default=15)
# Cross-request Redis caches of DB state (apps.core.caching). Invalidation is
# signal-driven, so the TTLs only bound out-of-band edits (raw SQL). 0 disables;
# forced off under tests — rollbacks don't fire signals (see TESTING above).
POINTY_SHOP_SETTINGS_CACHE_TTL = (
    0 if TESTING else env.int("POINTY_SHOP_SETTINGS_CACHE_TTL", default=60)
)
POINTY_PERMISSION_CACHE_TTL = (
    0 if TESTING else env.int("POINTY_PERMISSION_CACHE_TTL", default=300)
)
# The auth-middleware User row (apps.core.auth_backends.get_user) — the last
# per-request SELECT once sessions + permissions are cached. Short TTL: it
# bounds how long a raw-SQL password change/deactivation could lag (signalled
# saves invalidate instantly).
POINTY_USER_CACHE_TTL = 0 if TESTING else env.int("POINTY_USER_CACHE_TTL", default=60)
# SalesChannel.api_key_last_used_at is written at most once per window instead
# of on every keyed request (0 = every request, forced under tests).
POINTY_CHANNEL_LAST_USED_WRITE_SECONDS = (
    0 if TESTING else env.int("POINTY_CHANNEL_LAST_USED_WRITE_SECONDS", default=60)
)
# The RelayInstallation singleton (loaded on /me, discovery, every AI request).
# Signal-invalidated; the TTL bounds raw-SQL edits.
POINTY_RELAY_INSTALLATION_CACHE_TTL = (
    0 if TESTING else env.int("POINTY_RELAY_INSTALLATION_CACHE_TTL", default=60)
)
# The AI usage ring: one relay round-trip per window for the whole fleet's
# polls instead of one per poll (0 disables, forced under tests).
POINTY_AI_USAGE_CACHE_TTL = (
    0 if TESTING else env.int("POINTY_AI_USAGE_CACHE_TTL", default=60)
)
# Register-session summary / Z-Report (view + thermal + PDF hit it back to
# back). Short: closed sessions can still change via a from-history void.
POINTY_REGISTER_SUMMARY_CACHE_TTL = (
    0 if TESTING else env.int("POINTY_REGISTER_SUMMARY_CACHE_TTL", default=30)
)
# A burst of risky actions queues ONE targeted fraud sweep per window instead
# of one per action (0 = enqueue every time, forced under tests).
POINTY_FRAUD_SWEEP_DEBOUNCE_SECONDS = (
    0 if TESTING else env.int("POINTY_FRAUD_SWEEP_DEBOUNCE_SECONDS", default=120)
)
# Active-product-id list for the unfiltered POS catalog (ProductViewSet).
# Invalidated by the viewset's own writes, so the TTL bounds staleness from
# direct-ORM writes (imports, admin) — and must be 0 under tests, where DB
# rollbacks leave stale ids in Redis while Postgres sequences keep advancing.
POINTY_ACTIVE_PRODUCT_CACHE_TTL = (
    0 if TESTING else env.int("POINTY_ACTIVE_PRODUCT_CACHE_TTL", default=60)
)
# Catalog version stamp (apps.catalog.cache): drives the list-endpoint ETags
# (304 on unchanged polls) and invalidates the price-checker lookup cache.
POINTY_CATALOG_CACHE_ENABLED = (
    False if TESTING else env.bool("POINTY_CATALOG_CACHE_ENABLED", default=True)
)
# State-version vector (apps.core.state_version): the "what changed" counters
# published on every API response and polled by idle clients, so a till's caches
# and loaded screens revalidate the moment an admin edits anything. Forced off
# under tests for the same reason as the catalog stamp — test rollbacks do not
# fire signals, so a version bumped in one test would leak into the next; the
# dedicated tests opt back in with override_settings.
POINTY_STATE_VERSION_ENABLED = (
    False if TESTING else env.bool("POINTY_STATE_VERSION_ENABLED", default=True)
)
# How often clients poll /api/state/ while in the foreground. Served in the
# response body, so raising it slows every till down without a client release.
POINTY_STATE_POLL_INTERVAL_SECONDS = env.int(
    "POINTY_STATE_POLL_INTERVAL_SECONDS", default=15
)
# Price-checker barcode lookups (seconds; 0 disables). Version-keyed against
# catalog + discount edits; the TTL only bounds discount time-window boundaries.
POINTY_PRICE_LOOKUP_CACHE_TTL = (
    0 if TESTING else env.int("POINTY_PRICE_LOOKUP_CACHE_TTL", default=30)
)
# Notifications feed version stamps (apps.notifications.cache): drive the
# bell/badge list ETag. The max-age bucket bounds every indirect staleness
# path (snooze expiry, admin edits) without per-poll DB work.
POINTY_NOTIFICATIONS_CACHE_ENABLED = (
    False if TESTING else env.bool("POINTY_NOTIFICATIONS_CACHE_ENABLED", default=True)
)
POINTY_NOTIFICATIONS_ETAG_MAX_AGE_SECONDS = env.int(
    "POINTY_NOTIFICATIONS_ETAG_MAX_AGE_SECONDS", default=300
)
POINTY_CURRENCY_SUFFIX = env("POINTY_CURRENCY_SUFFIX")
POINTY_CURRENCY_LATIN = env("POINTY_CURRENCY_LATIN")

REST_FRAMEWORK = {
    "DEFAULT_SCHEMA_CLASS": "drf_spectacular.openapi.AutoSchema",
    "DEFAULT_AUTHENTICATION_CLASSES": [
        "rest_framework.authentication.BasicAuthentication",
        "rest_framework.authentication.SessionAuthentication",
    ],
    "DEFAULT_PERMISSION_CLASSES": [
        "rest_framework.permissions.IsAuthenticated",
    ],
    "DEFAULT_FILTER_BACKENDS": [
        "django_filters.rest_framework.DjangoFilterBackend",
        "rest_framework.filters.SearchFilter",
        "rest_framework.filters.OrderingFilter",
    ],
    "DEFAULT_PAGINATION_CLASS": "rest_framework.pagination.PageNumberPagination",
    "PAGE_SIZE": 50,
    # Number of trusted reverse proxies in front of the backend. Used when
    # deriving the client IP for throttling. 0 keys on REMOTE_ADDR so a client
    # cannot bypass throttles by spoofing X-Forwarded-For; set this to the real
    # proxy hop count (e.g. relay + nginx) to throttle on the true client IP.
    "NUM_PROXIES": env.int("DJANGO_NUM_PROXIES", default=0),
    # A wide per-user ceiling on ALL authenticated traffic (fail-open,
    # anonymous requests pass through — see AuthenticatedBurstCeilingThrottle).
    # Normal POS use never approaches it; it exists so one runaway client
    # can't flood PgBouncer. Disabled under tests, which hammer endpoints
    # far faster than any human.
    "DEFAULT_THROTTLE_CLASSES": [
        "apps.core.throttling.AuthenticatedBurstCeilingThrottle",
    ],
    # Scoped rates for sensitive auth endpoints. Applied per-view; a view's
    # own throttle_classes replace the default ceiling above.
    "DEFAULT_THROTTLE_RATES": {
        "login": env("DJANGO_THROTTLE_LOGIN", default="30/min"),
        "login_username": env("DJANGO_THROTTLE_LOGIN_USERNAME", default="6/min"),
        # See SetupRateThrottle: the initial-admin endpoint closes itself after
        # one success, so this bounds abuse rather than guarding a secret. Kept
        # wide enough that a fumbled first-run wizard cannot lock an owner out
        # of a brand-new installation.
        "setup": env("DJANGO_THROTTLE_SETUP", default="20/hour"),
        "password_change": env("DJANGO_THROTTLE_PASSWORD_CHANGE", default="10/min"),
        # Telemetry has its own bucket so a backlog flush can only ever refuse
        # telemetry. Steady-state ingest across the whole fleet is a handful of
        # requests a minute; this sits far above that and far below the 2,242 a
        # minute that stopped sales on 2026-08-17.
        "analytics_ingest": (
            None
            if TESTING
            else env("POINTY_ANALYTICS_INGEST_THROTTLE_RATE", default="120/min")
        ),
        # The pairing code is guessable-shaped (10 chars, typable), so its
        # claim endpoint gets a tight per-IP bucket. Uploads get a separate,
        # generous one keyed per phone: a shop photographing a delivery is
        # normal, a phone in a retry loop filling the disk is not.
        "companion_pair": (
            None if TESTING else env("POINTY_COMPANION_PAIR_THROTTLE_RATE", default="10/min")
        ),
        "companion_upload": (
            None if TESTING else env("POINTY_COMPANION_UPLOAD_THROTTLE_RATE", default="120/min")
        ),
        "authenticated_ceiling": (
            None
            if TESTING
            else env("POINTY_AUTHENTICATED_THROTTLE_RATE", default="1000/min")
        ),
    },
}

# Build version, injected at image build time from the git tag (see backend
# Dockerfile ARG POINTY_VERSION). "0.0.0-dev" for local/unbuilt runs. Surfaced in
# the diagnostics export header and the remote-update fleet view.
POINTY_VERSION = env("POINTY_VERSION", default="0.0.0-dev")

SPECTACULAR_SETTINGS = {
    "TITLE": "Pointy POS API",
    "DESCRIPTION": "Catalog, inventory, sales, and payment API for a point-of-sale system.",
    "VERSION": POINTY_VERSION,
}
