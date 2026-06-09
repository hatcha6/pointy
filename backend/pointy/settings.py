from datetime import timedelta
from pathlib import Path

from celery.schedules import crontab
import environ

BASE_DIR = Path(__file__).resolve().parent.parent

env = environ.Env(
    DJANGO_DEBUG=(bool, False),
    DJANGO_ALLOWED_HOSTS=(list, ["localhost", "127.0.0.1"]),
    CORS_ALLOWED_ORIGINS=(list, []),
    CSRF_TRUSTED_ORIGINS=(list, ["http://localhost:8080", "http://127.0.0.1:8080"]),
    POINTY_BOOTSTRAP_ADMIN_ENABLED=(bool, True),
    POINTY_ANALYTICS_BACKEND_PERFORMANCE_ENABLED=(bool, True),
    POINTY_ANALYTICS_BACKEND_SLOW_REQUEST_MS=(int, 750),
    POINTY_ATTACHMENT_MAX_UPLOAD_BYTES=(int, 100 * 1024 * 1024),
    POINTY_ATTACHMENT_CONTENT_TOKEN_MAX_AGE_SECONDS=(int, 60 * 60 * 6),
    POINTY_PRODUCT_IMAGE_IMPORT_MAX_BYTES=(int, 10 * 1024 * 1024),
    POINTY_IMAGE_FETCH_TIMEOUT_SECONDS=(int, 8),
    POINTY_IMAGE_IMPORT_TOKEN_MAX_AGE_SECONDS=(int, 60 * 60),
    POINTY_RELAY_REQUEST_TIMEOUT_SECONDS=(int, 5),
    POINTY_RELAY_ALLOW_INSECURE_CONTROL=(bool, False),
    POINTY_DISCOVERY_ENABLED=(bool, True),
    POINTY_DISCOVERY_PRIVATE_ONLY=(bool, True),
    POINTY_DISCOVERY_UDP_ENABLED=(bool, True),
    POINTY_DISCOVERY_UDP_PORT=(int, 47777),
    POINTY_DISCOVERY_API_PORT=(int, 8000),
    POINTY_DISCOVERY_TRUST_PROXY_HEADERS=(bool, False),
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
    "apps.attachments",
    "apps.employees",
]

MIDDLEWARE = [
    "corsheaders.middleware.CorsMiddleware",
    "django.middleware.security.SecurityMiddleware",
    "django.contrib.sessions.middleware.SessionMiddleware",
    "django.middleware.common.CommonMiddleware",
    "django.middleware.csrf.CsrfViewMiddleware",
    "django.contrib.auth.middleware.AuthenticationMiddleware",
    "apps.analytics.middleware.BackendPerformanceAnalyticsMiddleware",
    "django.contrib.messages.middleware.MessageMiddleware",
    "django.middleware.clickjacking.XFrameOptionsMiddleware",
]

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

STATIC_URL = "static/"
MEDIA_URL = "media/"
MEDIA_ROOT = BASE_DIR / "media"
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
}

CORS_ALLOWED_ORIGINS = env("CORS_ALLOWED_ORIGINS")
CORS_ALLOW_CREDENTIALS = True
CSRF_TRUSTED_ORIGINS = env("CSRF_TRUSTED_ORIGINS")
POINTY_BOOTSTRAP_ADMIN_ENABLED = env("POINTY_BOOTSTRAP_ADMIN_ENABLED")
POINTY_BOOTSTRAP_ADMIN_USERNAME = env("POINTY_BOOTSTRAP_ADMIN_USERNAME", default="admin")
POINTY_BOOTSTRAP_ADMIN_EMAIL = env("POINTY_BOOTSTRAP_ADMIN_EMAIL", default="")
POINTY_BOOTSTRAP_ADMIN_PASSWORD = env("POINTY_BOOTSTRAP_ADMIN_PASSWORD", default=None)
POINTY_ANALYTICS_BACKEND_PERFORMANCE_ENABLED = env("POINTY_ANALYTICS_BACKEND_PERFORMANCE_ENABLED")
POINTY_ANALYTICS_BACKEND_SLOW_REQUEST_MS = env("POINTY_ANALYTICS_BACKEND_SLOW_REQUEST_MS")
POINTY_ANALYTICS_BACKEND_PERFORMANCE_PATHS = ("/api/",)
POINTY_ATTACHMENT_STORAGE_ROOT = env(
    "POINTY_ATTACHMENT_STORAGE_ROOT",
    default=str(MEDIA_ROOT),
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
    ],
)
POINTY_PRODUCT_IMAGE_IMPORT_MAX_BYTES = env("POINTY_PRODUCT_IMAGE_IMPORT_MAX_BYTES")
POINTY_IMAGE_SEARCH_PROVIDER = env("POINTY_IMAGE_SEARCH_PROVIDER", default="")
POINTY_IMAGE_SEARCH_PROVIDERS = env("POINTY_IMAGE_SEARCH_PROVIDERS", default="")
POINTY_SERPER_API_KEY = env("POINTY_SERPER_API_KEY", default="")
POINTY_SERPER_ENDPOINT = env(
    "POINTY_SERPER_ENDPOINT",
    default="https://google.serper.dev/images",
)
POINTY_SERPAPI_API_KEY = env("POINTY_SERPAPI_API_KEY", default="")
POINTY_SERPAPI_ENDPOINT = env(
    "POINTY_SERPAPI_ENDPOINT",
    default="https://serpapi.com/search.json",
)
POINTY_IMAGE_SEARCH_SAFE = env("POINTY_IMAGE_SEARCH_SAFE", default="active")
POINTY_IMAGE_SEARCH_LANGUAGE = env("POINTY_IMAGE_SEARCH_LANGUAGE", default="ar")
POINTY_IMAGE_SEARCH_COUNTRY = env("POINTY_IMAGE_SEARCH_COUNTRY", default="us")
POINTY_IMAGE_FETCH_TIMEOUT_SECONDS = env("POINTY_IMAGE_FETCH_TIMEOUT_SECONDS")
POINTY_IMAGE_IMPORT_TOKEN_MAX_AGE_SECONDS = env("POINTY_IMAGE_IMPORT_TOKEN_MAX_AGE_SECONDS")
POINTY_RELAY_CONTROL_URL = env("POINTY_RELAY_CONTROL_URL", default="")
POINTY_RELAY_PUBLIC_API_URL = env("POINTY_RELAY_PUBLIC_API_URL", default="")
POINTY_RELAY_CONNECTOR_ADDR = env("POINTY_RELAY_CONNECTOR_ADDR", default="")
POINTY_RELAY_ADMIN_TOKEN = env("POINTY_RELAY_ADMIN_TOKEN", default="")
POINTY_RELAY_BUSINESS_ID = env("POINTY_RELAY_BUSINESS_ID", default="")
POINTY_RELAY_REQUEST_TIMEOUT_SECONDS = env("POINTY_RELAY_REQUEST_TIMEOUT_SECONDS")
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
}

SPECTACULAR_SETTINGS = {
    "TITLE": "Pointy POS API",
    "DESCRIPTION": "Catalog, inventory, sales, and payment API for a point-of-sale system.",
    "VERSION": "0.1.0",
}
