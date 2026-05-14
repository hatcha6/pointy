# Pointy POS

A starter point-of-sale stack with a Django REST Framework backend, Redis-backed cache/task wiring, and a Flutter frontend.

## Layout

- `backend/` - Django API for catalog, sales, payments, inventory, Redis cache, and Celery tasks.
- `frontend/` - Flutter POS client with a cashier-first sales screen scaffold.

## Backend Quick Start

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
docker compose up redis
```

Run a Celery worker:

```sh
celery -A pointy worker -l info
```

## Frontend Quick Start

```sh
cd frontend
flutter pub get
flutter run
```

The Flutter app currently uses a sample in-memory catalog while the data layer is scaffolded for the API.
