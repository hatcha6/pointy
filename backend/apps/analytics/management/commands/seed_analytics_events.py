"""Generate a realistic mountain of telemetry, for testing the export at scale.

An export that is fine at ten thousand rows and hopeless at fifty million is
not something you can find out about from a dev database, and waiting a month
for a real shop to fill one up is not a test loop. This builds the haystack
directly in Postgres — ``INSERT ... SELECT generate_series`` — so tens of
millions of rows land in minutes rather than the hours an ORM loop would take,
with the same column mix, JSON payload sizes and name/severity distribution the
real ingest produces.

    python manage.py seed_analytics_events --count 20000000 --days 30
"""

import time
from datetime import timedelta

from django.core.management.base import BaseCommand, CommandError
from django.db import connection, transaction
from django.utils import timezone

from apps.analytics.models import AnalyticsEvent


# Rows per INSERT. Big enough that per-statement overhead disappears, small
# enough that each statement's WAL and memory stay bounded on a small box.
_CHUNK = 500_000

# The event mix a trading shop actually generates: mostly request timing and
# frontend telemetry, a thin tail of errors and audit rows.
_SEED_SQL = """
INSERT INTO {table} (
    client_event_id, event_type, name, severity, source, occurred_at,
    received_by_id, session_id, device_id, installation_id, app_version,
    platform, request_path, ip_address, user_agent, trace_id, entity_type,
    entity_id, risk_score, attributes, metrics, created_at, updated_at
)
SELECT
    gen_random_uuid(),
    (ARRAY['usage','performance','error','audit','security'])[1 + mod(n, 40) / 8],
    (ARRAY[
        'backend.request','frontend.http_request','frontend.screen_viewed',
        'frontend.interaction','pos.cart.line.added','sales.checkout.completed',
        'frontend.operation','app.lifecycle_changed'
    ])[1 + mod(n, 8)],
    (ARRAY['info','info','info','warning','error'])[1 + mod(n, 5)],
    (ARRAY['frontend','backend','print_agent'])[1 + mod(n, 3)],
    %(start)s::timestamptz + mod(n, %(span)s) * interval '1 microsecond',
    NULL,
    'session-' || mod(n, 5000),
    'till-' || mod(n, 12),
    'inst-simulation',
    '1.4.' || mod(n, 6),
    (ARRAY['windows','android','linux','web'])[1 + mod(n, 4)],
    (ARRAY['/api/products/','/api/sales/orders/','/api/analytics-events/ingest/',
           '/api/discounts/preview/','/api/customers/'])[1 + mod(n, 5)],
    ('192.168.1.' || (1 + mod(n, 250)))::inet,
    'Dart/3.9 (dart:io) pointy/1.4 (windows; till-' || mod(n, 12) || ')',
    'trace-' || md5(n::text),
    (ARRAY['sale_order','product','customer','register_session'])[1 + mod(n, 4)],
    mod(n, 100000)::text,
    CASE WHEN mod(n, 97) = 0 THEN mod(n, 100)::int ELSE NULL END,
    jsonb_build_object(
        'path', '/api/products/',
        'method', (ARRAY['GET','POST','PATCH'])[1 + mod(n, 3)],
        'view_name', 'product-list',
        'status_family', (ARRAY['2xx','2xx','2xx','4xx','5xx'])[1 + mod(n, 5)],
        'user_authenticated', mod(n, 2) = 0,
        'query_string_present', mod(n, 3) = 0
    ),
    jsonb_build_object(
        'duration_ms', round((mod(n, 4000) / 10.0)::numeric, 2),
        'db_time_ms', round((mod(n, 900) / 10.0)::numeric, 2),
        'db_query_count', mod(n, 25),
        'status_code', (ARRAY[200,200,201,400,500])[1 + mod(n, 5)],
        'response_size_bytes', 200 + mod(n, 9000)
    ),
    now(),
    now()
FROM generate_series(%(first)s, %(last)s) AS n
"""


class Command(BaseCommand):
    help = "Seed AnalyticsEvent rows in bulk, for load-testing the export path."

    def add_arguments(self, parser):
        parser.add_argument(
            "--count",
            type=int,
            default=1_000_000,
            help="How many events to insert (default: 1000000).",
        )
        parser.add_argument(
            "--days",
            type=int,
            default=30,
            help="Spread occurred_at over this many days, ending now.",
        )
        parser.add_argument(
            "--chunk",
            type=int,
            default=_CHUNK,
            help=f"Rows per INSERT statement (default: {_CHUNK}).",
        )
        parser.add_argument(
            "--truncate",
            action="store_true",
            help="Delete every existing analytics event first.",
        )
        parser.add_argument(
            "--no-analyze",
            action="store_true",
            help="Skip the ANALYZE afterwards (the export's row estimate needs it).",
        )

    def handle(self, *args, **options):
        if connection.vendor != "postgresql":
            raise CommandError("seed_analytics_events requires PostgreSQL.")

        count = options["count"]
        chunk = max(1, options["chunk"])
        table = connection.ops.quote_name(AnalyticsEvent._meta.db_table)

        if options["truncate"]:
            self.stdout.write("Truncating analytics events…")
            with connection.cursor() as cursor:
                cursor.execute(f"TRUNCATE {table} RESTART IDENTITY")

        span_microseconds = max(1, options["days"] * 86_400 * 1_000_000)
        start = timezone.now() - timedelta(days=options["days"])
        statement = _SEED_SQL.format(table=table)
        started = time.monotonic()
        inserted = 0

        while inserted < count:
            batch = min(chunk, count - inserted)
            # Each chunk is its own transaction: a seed of this size should
            # never hold one long-running transaction open (it would pin
            # vacuum and balloon WAL on a small box).
            with transaction.atomic(), connection.cursor() as cursor:
                cursor.execute(
                    statement,
                    {
                        "first": inserted + 1,
                        "last": inserted + batch,
                        "span": span_microseconds,
                        "start": start,
                    },
                )
            inserted += batch
            elapsed = time.monotonic() - started
            self.stdout.write(
                f"  {inserted:,}/{count:,} rows  "
                f"({inserted / max(elapsed, 1e-9):,.0f} rows/s)"
            )

        if not options["no_analyze"]:
            self.stdout.write("Running ANALYZE (the export's row estimate reads it)…")
            with connection.cursor() as cursor:
                cursor.execute(f"ANALYZE {table}")

        elapsed = time.monotonic() - started
        self.stdout.write(
            self.style.SUCCESS(
                f"Seeded {inserted:,} analytics events in {elapsed:,.1f}s."
            )
        )
