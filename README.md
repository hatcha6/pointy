# Pointy POS

A starter point-of-sale stack with a Django REST Framework backend, Redis-backed cache/task wiring, and an Arabic-first Flutter frontend.

## Layout

- `backend/` - Django API for catalog, sales, payments, inventory, Redis cache, and Celery tasks.
- `frontend/` - Flutter POS client with cashier-first sales, catalog, register-session, printing, and settings screens.

## Backend Quick Start

With Make:

```sh
make setup
make redis
make backend-migrate
make backend-seed-variants
make backend-run
```

Or manually:

```sh
cd backend
python -m venv .venv
source .venv/bin/activate
pip install -e .
cp .env.example .env
python manage.py migrate
python manage.py seed_variant_options
python manage.py createsuperuser
python manage.py runserver
```

Run Redis with Docker:

```sh
make redis
```

If Docker Desktop is not running, open it and retry. If Redis is installed locally, use `make dev-local` instead of `make dev`.

Run a Celery worker:

```sh
celery -A pointy worker -l info
```

## Attachment Storage

Pointy stores uploads through one shared attachment API for product images,
supplier invoice scans, and other supported records. Files are compressed on
disk with gzip when that reduces size, while downloads return the original bytes
and content type.

By default, attachments use `backend/media` as a watched storage parent. Every
direct child folder inside it is treated as a separate storage volume, so JPaaS
extra storage instances can be mounted as folders there:

```sh
backend/media/storage-a
backend/media/storage-b
```

The backend automatically records discovered folders as storage volumes, checks
that active volumes are writable, and round-robins new uploads across them. If
the parent folder is empty, Pointy creates `backend/media/default` for local
development. To use a different parent folder, set:

```sh
POINTY_ATTACHMENT_STORAGE_ROOT=/mnt/pointy-media
```

Volumes can be inspected or paused through `/api/attachment-storage-volumes/`.

Common upload entry points:

- `POST /api/attachments/` with `owner_type`, `owner_id`, `role`, and `file`
- `POST /api/products/{id}/attachments/` for product images
- `POST /api/purchase-orders/{id}/attachments/` for supplier invoice scans
- `GET /api/attachments/{id}/download/` for authenticated downloads

## Variant API Notes

Catalog products expose variants as the sellable stock unit. Create product option
schemas on the product, then assign one value per option to each variant:

```json
{
  "name": "قميص",
  "variant_options": [1, 2],
  "default_variant": {
    "sku": "SHIRT-RED-L",
    "unit_price": "12.00",
    "option_values": [10, 24]
  }
}
```

Variant option combinations are unique per product. Purchase cost lookups are
variant-first; use `GET /api/purchase-orders/variant-last-cost/?variant=42`,
`GET /api/purchase-orders/variant-cost-history/?variant=42`, and
`GET /api/purchase-orders/variant-margin-impact/?variant=42`. The older
product-named cost URLs remain as compatibility aliases.

## Frontend Quick Start

With Make:

```sh
make frontend-web
```

Or manually:

```sh
cd frontend
flutter pub get
flutter run
```

The Flutter app reads from the Django API. The POS catalog keeps a small Arabic sample fallback only for local development when the API is unavailable.

## Quality Gates

Fast checks stay on the normal targets:

```sh
make check
make test
```

The pilot-day POS flow is automated as an opt-in Flutter E2E test. It runs the
Arabic app shell with a deterministic fake API and covers opening a register,
choosing a customer, split-tender checkout, fake receipt printing, a cash
movement, closing the register, and opening reports:

```sh
make e2e
```

Checkout load, stress, and endurance tests are opt-in because they create
load-test users/products/stock records and intentionally run for longer. Start
the API first in another terminal:

```sh
make backend-run
```

Then run one of:

```sh
make backend-load-test
make backend-stress-test
make backend-endurance-test
```

`backend-load-test` runs a fixed number of checkout clients. `backend-stress-test`
runs a 30-minute ramp by default: 4 concurrent checkout clients, then +4 every
180 seconds, up to 64 clients or until collapse is detected. A ramp stage is
marked collapsed when failures reach 1% or p95 checkout latency reaches 2000ms.
The summary reports the highest passing concurrent-client count, checkout
throughput, per-stage p95/p99 latency, failures, status codes, and top errors.
Human-readable runs also print live progress every 10 seconds during each stage.
JSON output disables progress lines so the output remains parseable.

Useful knobs:

```sh
make backend-load-test LOAD_DURATION=120 LOAD_WORKERS=6
make backend-stress-test STRESS_DURATION=1800 STRESS_START_WORKERS=4 STRESS_WORKERS=64
make backend-stress-test STRESS_STEP_DURATION=120 STRESS_STEP_WORKERS=8
make backend-stress-test STRESS_COLLAPSE_FAILURE_RATE=0.005 STRESS_COLLAPSE_P95_MS=1500
make backend-endurance-test ENDURANCE_DURATION=7200 ENDURANCE_WORKERS=4
make backend-load-test LOAD_EXTRA="--json --fail-on-error"
make backend-stress-test LOAD_EXTRA="--progress-interval 5"
make backend-stress-test LOAD_EXTRA="--json --no-stop-on-collapse"
```

These tests report throughput, success/failure counts, status codes, and
latency min/avg/p50/p95/p99/max for the checkout path. Ramp stress also reports
concurrent clients and the first collapsed stage. Treat the numbers as limits
for the current machine, database, server command, and settings rather than
universal production capacity. The concurrent-client count represents active
load-test checkout clients and register sessions; database and web-server
connection limits still depend on how the API server and database are deployed.

The default local database is SQLite. Concurrent checkout stress on SQLite will
usually find SQLite's single-writer ceiling first and may report
`OperationalError: database is locked`. That is still a useful local signal, but
it is not the production checkout limit. For a SQLite baseline, run:

```sh
make backend-load-test LOAD_WORKERS=1
```

For real stress/endurance capacity, run the backend against the same database
engine and deployment shape you plan to use in production, then increase
`LOAD_WORKERS`, `STRESS_WORKERS`, or `ENDURANCE_WORKERS` gradually until error
rate or latency crosses your threshold.

For a local PostgreSQL-backed run, point `backend/.env` at your local database
and migrate before starting the API:

```sh
DATABASE_URL=postgres://postgres:postgres@127.0.0.1:5432/pointy
make backend-migrate
make backend-run
make backend-load-test
```

Run the full local stack:

```sh
make dev
```

The `dev`, `dev-local`, and `dev-no-redis` targets generate Django migrations
and apply them before starting the API and Flutter web app.

Useful variants:

```sh
make dev-local     # Use a local redis-server instead of Docker
make dev-no-redis  # Start only Django and Flutter
make redis-ping    # Check Redis connectivity
```
