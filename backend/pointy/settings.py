from datetime import timedelta
from pathlib import Path

from celery.schedules import crontab
from corsheaders.defaults import default_headers
import environ

BASE_DIR = Path(__file__).resolve().parent.parent

env = environ.Env(
    DJANGO_DEBUG=(bool, False),
    DJANGO_ALLOWED_HOSTS=(list, ["localhost", "127.0.0.1"]),
    CORS_ALLOWED_ORIGINS=(list, []),
    CSRF_TRUSTED_ORIGINS=(list, ["http://localhost:8080", "http://127.0.0.1:8080"]),
    POINTY_ANALYTICS_BACKEND_PERFORMANCE_ENABLED=(bool, True),
    POINTY_ANALYTICS_BACKEND_SLOW_REQUEST_MS=(int, 750),
    POINTY_ATTACHMENT_MAX_UPLOAD_BYTES=(int, 100 * 1024 * 1024),
    POINTY_ATTACHMENT_CONTENT_TOKEN_MAX_AGE_SECONDS=(int, 60 * 60 * 6),
    POINTY_PRODUCT_IMAGE_IMPORT_MAX_BYTES=(int, 10 * 1024 * 1024),
    POINTY_IMAGE_FETCH_TIMEOUT_SECONDS=(int, 8),
    POINTY_IMAGE_IMPORT_TOKEN_MAX_AGE_SECONDS=(int, 60 * 60),
    POINTY_RELAY_REQUEST_TIMEOUT_SECONDS=(int, 5),
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
    DATABASE_CONN_MAX_AGE=(int, 60),
    DJANGO_SECURE_SSL_REDIRECT=(bool, False),
    DJANGO_SESSION_COOKIE_SECURE=(bool, False),
    DJANGO_CSRF_COOKIE_SECURE=(bool, False),
    POINTY_EXPIRY_ALERT_WINDOW_DAYS=(int, 30),
    POINTY_NOTIFICATION_SYNC_INTERVAL_MINUTES=(int, 15),
    POINTY_FRAUD_DETECTION_INTERVAL_MINUTES=(int, 15),
    POINTY_FRAUD_DETECTION_LOOKBACK_DAYS=(int, 30),
    POINTY_BACKUP_RETENTION_COUNT=(int, 7),
    POINTY_BACKUP_RESTORE_MAX_BYTES=(int, 5 * 1024 * 1024 * 1024),
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
    "apps.channels",
    "apps.operations",
    "apps.analytics",
    "apps.catalog",
    "apps.inventory",
    "apps.sales",
    "apps.fraud",
    "apps.customers",
    "apps.purchasing",
    "apps.discounts",
    "apps.payments",
    "apps.printing",
    "apps.reports",
    "apps.notifications",
    "apps.messaging",
    "apps.crm",
    "apps.attachments",
    "apps.employees",
    "apps.attendance",
    "apps.expenses",
    "apps.price_checker",
    "apps.ai",
    "apps.migration",
    "apps.holidays",
    "apps.clients",
]

MIDDLEWARE = [
    "corsheaders.middleware.CorsMiddleware",
    "django.middleware.security.SecurityMiddleware",
    "django.contrib.sessions.middleware.SessionMiddleware",
    "django.middleware.common.CommonMiddleware",
    "django.middleware.csrf.CsrfViewMiddleware",
    "django.contrib.auth.middleware.AuthenticationMiddleware",
    "apps.channels.middleware.SalesChannelMiddleware",
    "apps.analytics.middleware.BackendPerformanceAnalyticsMiddleware",
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

DATABASES = {
    "default": env.db("DATABASE_URL", default=f"sqlite:///{BASE_DIR / 'db.sqlite3'}"),
}
DATABASES["default"]["CONN_MAX_AGE"] = env("DATABASE_CONN_MAX_AGE")

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

AUTH_PASSWORD_VALIDATORS = [
    {"NAME": "django.contrib.auth.password_validation.UserAttributeSimilarityValidator"},
    {"NAME": "django.contrib.auth.password_validation.MinimumLengthValidator"},
    {"NAME": "django.contrib.auth.password_validation.CommonPasswordValidator"},
    {"NAME": "django.contrib.auth.password_validation.NumericPasswordValidator"},
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

CACHES = {
    "default": {
        "BACKEND": "django_redis.cache.RedisCache",
        "LOCATION": REDIS_URL,
        "OPTIONS": {"CLIENT_CLASS": "django_redis.client.DefaultClient"},
    }
}

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
POINTY_BACKUP_RESTORE_MAX_BYTES = env("POINTY_BACKUP_RESTORE_MAX_BYTES")
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
CELERY_BEAT_SCHEDULE = {
    "notifications.sync-business-notifications": {
        "task": "notifications.sync_business_notifications",
        "schedule": timedelta(minutes=POINTY_NOTIFICATION_SYNC_INTERVAL_MINUTES),
    },
    "fraud.sync-suspected-fraud-findings": {
        "task": "fraud.sync_suspected_fraud_findings",
        "schedule": timedelta(minutes=POINTY_FRAUD_DETECTION_INTERVAL_MINUTES),
    },
    "employees.draft-monthly-payroll": {
        "task": "employees.draft_monthly_payroll",
        "schedule": crontab(minute=10, hour=0, day_of_month="1"),
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
# checkout POST never leaves the browser). Idempotency-Key guards every money
# mutation (checkout, returns, voids); X-Pointy-Relay-Token rides relay setups.
CORS_ALLOW_HEADERS = (
    *default_headers,
    "idempotency-key",
    "x-pointy-relay-token",
)
# Let the browser read the idempotency replay marker on the response.
CORS_EXPOSE_HEADERS = ["Idempotency-Replayed"]
CSRF_TRUSTED_ORIGINS = env("CSRF_TRUSTED_ORIGINS")
POINTY_ANALYTICS_BACKEND_PERFORMANCE_ENABLED = env("POINTY_ANALYTICS_BACKEND_PERFORMANCE_ENABLED")
POINTY_ANALYTICS_BACKEND_SLOW_REQUEST_MS = env("POINTY_ANALYTICS_BACKEND_SLOW_REQUEST_MS")
POINTY_ANALYTICS_BACKEND_PERFORMANCE_PATHS = ("/api/",)
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
    ],
)
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
    # Scoped rates for sensitive auth endpoints only. Authenticated POS traffic
    # is intentionally left unthrottled; these scopes are applied per-view.
    "DEFAULT_THROTTLE_RATES": {
        "login": env("DJANGO_THROTTLE_LOGIN", default="30/min"),
        "login_username": env("DJANGO_THROTTLE_LOGIN_USERNAME", default="6/min"),
        "setup": env("DJANGO_THROTTLE_SETUP", default="5/hour"),
        "password_change": env("DJANGO_THROTTLE_PASSWORD_CHANGE", default="10/min"),
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
