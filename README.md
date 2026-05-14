# Pointy POS

A starter point-of-sale stack with a Django REST Framework backend, Redis-backed cache/task wiring, and a Flutter frontend.

## Layout

- `backend/` - Django API for catalog, sales, payments, inventory, Redis cache, and Celery tasks.
- `frontend/` - Flutter POS client with a cashier-first sales screen scaffold.

## Backend Quick Start

With Make:

```sh
make setup
make redis
make backend-migrate
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

The Flutter app currently uses a sample in-memory catalog while the data layer is scaffolded for the API.

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
