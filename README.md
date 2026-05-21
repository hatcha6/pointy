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

Run the full local stack:

```sh
make dev
```

Useful variants:

```sh
make dev-local     # Use a local redis-server instead of Docker
make dev-no-redis  # Start only Django and Flutter
make redis-ping    # Check Redis connectivity
```
