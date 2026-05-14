SHELL := /bin/zsh
.DEFAULT_GOAL := help

BACKEND_DIR := backend
FRONTEND_DIR := frontend
PYTHON ?= python3
VENV := $(BACKEND_DIR)/.venv
PIP := $(VENV)/bin/pip
MANAGE := $(VENV)/bin/python $(BACKEND_DIR)/manage.py
FLUTTER ?= flutter
WEB_HOST ?= 127.0.0.1
WEB_PORT ?= 8080
API_HOST ?= 127.0.0.1
API_PORT ?= 8000

.PHONY: help setup install redis redis-stop redis-logs \
	backend-venv backend-install backend-env backend-migrate backend-migrations backend-run \
	backend-shell backend-superuser backend-test backend-check backend-celery \
	frontend-install frontend-run frontend-web frontend-test frontend-analyze frontend-format \
	format check test dev clean

help: ## Show available commands.
	@awk 'BEGIN {FS = ":.*##"; printf "\nPointy POS commands\n\n"} /^[a-zA-Z0-9_-]+:.*##/ {printf "  %-22s %s\n", $$1, $$2}' $(MAKEFILE_LIST)

setup: backend-env backend-install frontend-install ## Prepare backend and frontend dependencies.

install: setup ## Alias for setup.

redis: ## Start Redis in the background with Docker Compose.
	docker compose up -d redis

redis-stop: ## Stop Redis.
	docker compose stop redis

redis-logs: ## Tail Redis logs.
	docker compose logs -f redis

backend-venv: ## Create the backend virtual environment.
	@test -d "$(VENV)" || $(PYTHON) -m venv "$(VENV)"

$(VENV)/.installed: $(BACKEND_DIR)/pyproject.toml | backend-venv
	$(PIP) install -e "$(BACKEND_DIR)"
	@touch "$@"

backend-install: $(VENV)/.installed ## Install backend dependencies into backend/.venv.

backend-env: ## Create backend/.env from the example when missing.
	@test -f "$(BACKEND_DIR)/.env" || cp "$(BACKEND_DIR)/.env.example" "$(BACKEND_DIR)/.env"

backend-migrate: backend-env backend-install ## Apply Django migrations.
	$(MANAGE) migrate

backend-migrations: backend-env backend-install ## Generate Django migrations.
	$(MANAGE) makemigrations

backend-run: backend-env backend-install ## Run the Django API server.
	$(MANAGE) runserver $(API_HOST):$(API_PORT)

backend-shell: backend-env backend-install ## Open the Django shell.
	$(MANAGE) shell

backend-superuser: backend-env backend-install ## Create a Django superuser.
	$(MANAGE) createsuperuser

backend-test: backend-env backend-install ## Run backend tests.
	cd "$(BACKEND_DIR)" && .venv/bin/python -m pytest

backend-check: backend-env backend-install ## Run Django system checks.
	$(MANAGE) check

backend-celery: backend-env backend-install ## Run a Celery worker.
	cd "$(BACKEND_DIR)" && .venv/bin/celery -A pointy worker -l info

frontend-install: ## Install Flutter dependencies.
	cd "$(FRONTEND_DIR)" && $(FLUTTER) pub get

frontend-run: frontend-install ## Run the Flutter app on the default selected device.
	cd "$(FRONTEND_DIR)" && $(FLUTTER) run

frontend-web: frontend-install ## Run the Flutter app as a local web server.
	cd "$(FRONTEND_DIR)" && $(FLUTTER) run -d web-server --web-hostname $(WEB_HOST) --web-port $(WEB_PORT)

frontend-test: frontend-install ## Run Flutter tests.
	cd "$(FRONTEND_DIR)" && $(FLUTTER) test

frontend-analyze: frontend-install ## Run Flutter analyzer.
	cd "$(FRONTEND_DIR)" && $(FLUTTER) analyze

frontend-format: ## Format Flutter source and tests.
	cd "$(FRONTEND_DIR)" && dart format lib test

format: frontend-format ## Format all currently scaffolded code.

check: backend-check frontend-analyze ## Run non-mutating project checks.

test: backend-test frontend-test ## Run backend and frontend tests.

dev: redis backend-migrate ## Run Redis, Django, and Flutter web together.
	$(MAKE) -j2 backend-run frontend-web

clean: ## Remove generated local caches and build output.
	find "$(BACKEND_DIR)" -type d -name __pycache__ -prune -exec rm -rf {} +
	rm -rf "$(VENV)/.installed" "$(FRONTEND_DIR)/build" "$(FRONTEND_DIR)/.dart_tool"
