SHELL := /bin/zsh
.DEFAULT_GOAL := help

BACKEND_DIR := backend
FRONTEND_DIR := frontend
RELAY_DIR := relay
PYTHON ?= python3
VENV := $(BACKEND_DIR)/.venv
PIP := $(VENV)/bin/pip
MANAGE := $(VENV)/bin/python $(BACKEND_DIR)/manage.py
FLUTTER ?= flutter
GO ?= go
GO_CACHE ?= $(RELAY_DIR)/.gocache
GO_MOD_CACHE ?= $(RELAY_DIR)/.gomodcache
WEB_HOST ?= 127.0.0.1
WEB_PORT ?= 8080
API_HOST ?= 127.0.0.1
API_PORT ?= 8000
RELAY_HTTP_ADDR ?= 127.0.0.1:8091
RELAY_ADMIN_HTTP_ADDR ?=
RELAY_CONNECTOR_ADDR ?= 127.0.0.1:8092
RELAY_CONTROL_URL ?= http://$(RELAY_HTTP_ADDR)
RELAY_ALLOW_INSECURE_CONTROL ?= true
RELAY_CONTROL_CA ?=
RELAY_CONTROL_CLIENT_CERT ?=
RELAY_CONTROL_CLIENT_KEY ?=
RELAY_CONTROL_TLS_SERVER_NAME ?=
RELAY_DATABASE_URL ?= postgres://postgres:postgres@127.0.0.1:5432/pointy?sslmode=disable
RELAY_REDIS_URL ?= redis://127.0.0.1:6379/0
RELAY_E2E_DATABASE_URL ?= $(RELAY_DATABASE_URL)
RELAY_E2E_REDIS_URL ?= $(RELAY_REDIS_URL)
RELAY_NODE_ID ?=
RELAY_NODE_INTERNAL_URL ?=
RELAY_NODE_PROXY_TOKEN ?=
RELAY_DRAINING ?= false
RELAY_ALLOW_INSECURE_NODE_PROXY ?= false
RELAY_TICKET_TTL ?= 15m
RELAY_TICKET_REFRESH_TTL ?= 168h
RELAY_STREAM_OPEN_TIMEOUT ?= 5s
RELAY_REQUEST_TIMEOUT ?= 60s
RELAY_MAX_REQUEST_BODY_BYTES ?= 10485760
RELAY_MAX_RESPONSE_BODY_BYTES ?= 52428800
RELAY_MAX_CONCURRENT_REQUESTS ?= 512
RELAY_RATE_LIMIT_WINDOW ?= 1m
RELAY_RATE_LIMIT_RELAY_REQUESTS ?= 600
RELAY_RATE_LIMIT_TICKET_ISSUE ?= 60
RELAY_RATE_LIMIT_TICKET_REFRESH ?= 120
RELAY_ALLOW_INSECURE_HTTP ?= true
RELAY_ALLOW_INSECURE_CONNECTOR ?= true
RELAY_HTTP_TLS_CERT ?=
RELAY_HTTP_TLS_KEY ?=
RELAY_HTTP_TLS_SERVER_NAME ?=
RELAY_HTTP_CLIENT_CA ?=
RELAY_REQUIRE_ADMIN_CLIENT_CERT ?= false
RELAY_PRODUCTION ?= false
RELAY_CONNECTOR_TLS_CERT ?=
RELAY_CONNECTOR_TLS_KEY ?=
RELAY_CONNECTOR_TLS_SERVER_NAME ?=
RELAY_CONNECTOR_CLIENT_CA ?=
RELAY_CONNECTOR_CLIENT_CA_KEY ?=
RELAY_CONNECTOR_CLIENT_CERT_TTL ?= 2160h
RELAY_AUTO_TLS ?= true
RELAY_GENERATED_TLS_CA_TTL ?= 87600h
RELAY_GENERATED_TLS_SERVER_CERT_TTL ?= 9528h
RELAY_GENERATED_TLS_ROTATION_WINDOW ?= 720h
RELAY_TLS_CA ?=
RELAY_TLS_CERT ?=
RELAY_TLS_KEY ?=
RELAY_TLS_SERVER_NAME ?=
RELAY_ADMIN_TOKEN ?=
RELAY_CONNECTOR_TOKEN ?=
RELAY_CONNECTOR_SETUP_TOKEN ?=
RELAY_CONNECTOR_CONFIG_URL ?=
RELAY_CONNECTOR_STATE_FILE ?=
RELAY_BACKEND_URL ?= http://127.0.0.1:8000
RELAY_CONNECTOR_REQUEST_TIMEOUT ?= 30s
RELAY_CONNECTOR_MAX_CONCURRENT_REQUESTS ?= 64
RELAY_CONNECTOR_CLIENT_CERT_ROTATION_WINDOW ?= 336h
RELAY_SUBSCRIPTION_INSTALLATION_ID ?=
RELAY_SUBSCRIPTION_ACTOR ?=
RELAY_SUBSCRIPTION_REASON ?=
RELAY_SUBSCRIPTION_RELAY_ENABLED ?=
RELAY_SUBSCRIPTION_ACTIVE ?=
RELAY_SUBSCRIPTION_AI_ENABLED ?=
RELAY_SUBSCRIPTION_ENDS_AT ?=
RELAY_SUBSCRIPTION_CLEAR_END ?= false
POSTGRES_HOST ?= 127.0.0.1
POSTGRES_PORT ?= 5432
LOAD_BASE_URL ?= http://127.0.0.1:8000/api
LOAD_DURATION ?= 60
LOAD_WORKERS ?= 4
LOAD_EXTRA ?=
STRESS_DURATION ?= 1800
STRESS_WORKERS ?= 16384
STRESS_START_WORKERS ?= 8
STRESS_STEP_WORKERS ?= 128
STRESS_STEP_DURATION ?= 180
STRESS_COLLAPSE_FAILURE_RATE ?= 0.01
STRESS_COLLAPSE_P95_MS ?= 2000
ENDURANCE_DURATION ?= 3600
ENDURANCE_WORKERS ?= 4

.PHONY: help setup install docker-check postgres postgres-stop postgres-logs postgres-ping redis redis-local redis-stop redis-logs redis-ping \
	backend-venv backend-install backend-env backend-migrate backend-migrations backend-dev-migrate backend-run \
	backend-load-test backend-stress-test backend-endurance-test \
	backend-shell backend-superuser backend-test backend-check backend-celery backend-celery-beat \
	frontend-install frontend-l10n frontend-run frontend-web frontend-test frontend-e2e frontend-analyze frontend-format \
	relay-install relay-format relay-check relay-test relay-production-test relay-run relay-connector relay-migrate relay-provision relay-subscription-update \
	format check test e2e dev dev-local dev-no-redis dev-ai ai-enable postgres-ready clean

help: ## Show available commands.
	@awk 'BEGIN {FS = ":.*##"; printf "\nPointy POS commands\n\n"} /^[a-zA-Z0-9_-]+:.*##/ {printf "  %-22s %s\n", $$1, $$2}' $(MAKEFILE_LIST)

setup: backend-env backend-install frontend-install relay-install ## Prepare backend, frontend, and relay dependencies.

install: setup ## Alias for setup.

docker-check: ## Check that Docker is reachable.
	@docker info >/dev/null 2>&1 || { \
		printf "\nDocker is not reachable.\n"; \
		printf "Open Docker Desktop, then retry this command.\n"; \
		printf "If you have redis-server installed locally, use: make dev-local\n\n"; \
		exit 1; \
	}

postgres: docker-check ## Start PostgreSQL in the background with Docker Compose.
	docker compose up -d postgres

postgres-stop: ## Stop PostgreSQL.
	docker compose stop postgres

postgres-logs: ## Tail PostgreSQL logs.
	docker compose logs -f postgres

postgres-ping: ## Check PostgreSQL connectivity.
	@command -v pg_isready >/dev/null 2>&1 || { \
		printf "\npg_isready was not found on PATH.\n"; \
		exit 1; \
	}
	pg_isready -h "$(POSTGRES_HOST)" -p "$(POSTGRES_PORT)"

redis: docker-check ## Start Redis in the background with Docker Compose.
	docker compose up -d redis

redis-local: ## Run Redis locally without Docker.
	@command -v redis-server >/dev/null 2>&1 || { \
		printf "\nredis-server was not found on PATH.\n"; \
		printf "Install Redis locally, or open Docker Desktop and use: make redis\n\n"; \
		exit 1; \
	}
	redis-server --port 6379

redis-stop: ## Stop Redis.
	docker compose stop redis

redis-logs: ## Tail Redis logs.
	docker compose logs -f redis

redis-ping: ## Check Redis connectivity on localhost:6379.
	@command -v redis-cli >/dev/null 2>&1 || { \
		printf "\nredis-cli was not found on PATH.\n"; \
		exit 1; \
	}
	redis-cli -h 127.0.0.1 -p 6379 ping

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

backend-dev-migrate: backend-env backend-install
	$(MANAGE) makemigrations
	$(MANAGE) migrate

backend-run: backend-env backend-install ## Run the Django API server.
	POINTY_DISCOVERY_API_PORT="$(API_PORT)" $(MANAGE) runserver $(API_HOST):$(API_PORT)

backend-shell: backend-env backend-install ## Open the Django shell.
	$(MANAGE) shell

backend-superuser: backend-env backend-install ## Create a Django superuser.
	$(MANAGE) createsuperuser

backend-load-test: backend-env backend-install ## Run opt-in checkout load test against a running API server.
	$(MANAGE) checkout_load --base-url "$(LOAD_BASE_URL)" --duration "$(LOAD_DURATION)" --workers "$(LOAD_WORKERS)" $(LOAD_EXTRA)

backend-stress-test: backend-env backend-install ## Run an automatic ramping checkout stress test against a running API server.
	$(MANAGE) checkout_load --ramp \
		--base-url "$(LOAD_BASE_URL)" \
		--duration "$(STRESS_DURATION)" \
		--start-workers "$(STRESS_START_WORKERS)" \
		--max-workers "$(STRESS_WORKERS)" \
		--step-workers "$(STRESS_STEP_WORKERS)" \
		--step-duration "$(STRESS_STEP_DURATION)" \
		--collapse-failure-rate "$(STRESS_COLLAPSE_FAILURE_RATE)" \
		--collapse-p95-ms "$(STRESS_COLLAPSE_P95_MS)" \
		$(LOAD_EXTRA)

backend-endurance-test: backend-env backend-install ## Run a long checkout endurance test against a running API server.
	$(MANAGE) checkout_load --base-url "$(LOAD_BASE_URL)" --duration "$(ENDURANCE_DURATION)" --workers "$(ENDURANCE_WORKERS)" $(LOAD_EXTRA)

backend-test: backend-env backend-install ## Run backend tests.
	$(MANAGE) test apps

backend-check: backend-env backend-install ## Run Django system checks.
	$(MANAGE) check

backend-celery: backend-env backend-install ## Run a Celery worker.
	cd "$(BACKEND_DIR)" && .venv/bin/celery -A pointy worker -l info

backend-celery-beat: backend-env backend-install ## Run the Celery Beat scheduler.
	cd "$(BACKEND_DIR)" && .venv/bin/celery -A pointy beat -l info

frontend-install: ## Install Flutter dependencies.
	cd "$(FRONTEND_DIR)" && $(FLUTTER) pub get

frontend-l10n: frontend-install ## Generate Flutter localization files.
	cd "$(FRONTEND_DIR)" && $(FLUTTER) gen-l10n

frontend-run: frontend-install ## Run the Flutter app on the default selected device.
	cd "$(FRONTEND_DIR)" && $(FLUTTER) run

frontend-web: frontend-install ## Run the Flutter app as a local web server.
	cd "$(FRONTEND_DIR)" && $(FLUTTER) run -d web-server --web-hostname $(WEB_HOST) --web-port $(WEB_PORT)

frontend-preview: frontend-install ## Run the stock-count UI preview harness as a local web server.
	cd "$(FRONTEND_DIR)" && $(FLUTTER) run -d web-server --web-hostname $(WEB_HOST) --web-port $(WEB_PORT) -t lib/dev/stock_count_preview.dart

frontend-operations-preview: frontend-install ## Run the operations UI preview harness as a local web server.
	cd "$(FRONTEND_DIR)" && $(FLUTTER) run -d web-server --web-hostname $(WEB_HOST) --web-port $(WEB_PORT) -t lib/dev/operations_preview.dart

frontend-categories-preview: frontend-install ## Run the categories UI preview harness as a local web server.
	cd "$(FRONTEND_DIR)" && $(FLUTTER) run -d web-server --web-hostname $(WEB_HOST) --web-port $(WEB_PORT) -t lib/dev/categories_preview.dart

frontend-discounts-preview: frontend-install ## Run the discounts UI preview harness as a local web server.
	cd "$(FRONTEND_DIR)" && $(FLUTTER) run -d web-server --web-hostname $(WEB_HOST) --web-port $(WEB_PORT) -t lib/dev/discounts_preview.dart

frontend-pos-preview: frontend-install ## Run the POS/purchasing catalog UI preview harness as a local web server.
	cd "$(FRONTEND_DIR)" && $(FLUTTER) run -d web-server --web-hostname $(WEB_HOST) --web-port $(WEB_PORT) -t lib/dev/pos_preview.dart

frontend-units-preview: frontend-install ## Run the units-of-measure management UI preview harness as a local web server.
	cd "$(FRONTEND_DIR)" && $(FLUTTER) run -d web-server --web-hostname $(WEB_HOST) --web-port $(WEB_PORT) -t lib/dev/units_preview.dart

frontend-command-palette-preview: frontend-install ## Run the global command palette UI preview harness as a local web server.
	cd "$(FRONTEND_DIR)" && $(FLUTTER) run -d web-server --web-hostname $(WEB_HOST) --web-port $(WEB_PORT) -t lib/dev/command_palette_preview.dart

frontend-price-checker-preview: frontend-install ## Run the price-checker settings UI preview harness as a local web server.
	cd "$(FRONTEND_DIR)" && $(FLUTTER) run -d web-server --web-hostname $(WEB_HOST) --web-port $(WEB_PORT) -t lib/dev/price_checker_preview.dart

frontend-ai-preview: frontend-install ## Run the AI assistant UI preview harness as a local web server.
	cd "$(FRONTEND_DIR)" && $(FLUTTER) run -d web-server --web-hostname $(WEB_HOST) --web-port $(WEB_PORT) -t lib/dev/ai_chat_preview.dart

frontend-theme-preview: frontend-install ## Run the light/dark theme gallery preview harness as a local web server.
	cd "$(FRONTEND_DIR)" && $(FLUTTER) run -d web-server --web-hostname $(WEB_HOST) --web-port $(WEB_PORT) -t lib/dev/theme_preview.dart

frontend-shop-setup-preview: frontend-install ## Run the first-run shop-setup wizard preview harness as a local web server.
	cd "$(FRONTEND_DIR)" && $(FLUTTER) run -d web-server --web-hostname $(WEB_HOST) --web-port $(WEB_PORT) -t lib/dev/shop_setup_preview.dart

frontend-test: frontend-install ## Run Flutter tests.
	cd "$(FRONTEND_DIR)" && $(FLUTTER) test

frontend-e2e: frontend-install ## Run Flutter end-to-end pilot flow tests.
	cd "$(FRONTEND_DIR)" && $(FLUTTER) test test/e2e

frontend-analyze: frontend-install ## Run Flutter analyzer.
	cd "$(FRONTEND_DIR)" && $(FLUTTER) analyze

frontend-format: ## Format Flutter source and tests.
	cd "$(FRONTEND_DIR)" && dart format lib test

relay-install: ## Download relay Go modules.
	cd "$(RELAY_DIR)" && GOCACHE="$(abspath $(GO_CACHE))" GOMODCACHE="$(abspath $(GO_MOD_CACHE))" $(GO) mod download

relay-format: ## Format relay source.
	cd "$(RELAY_DIR)" && GOCACHE="$(abspath $(GO_CACHE))" GOMODCACHE="$(abspath $(GO_MOD_CACHE))" $(GO) fmt ./...

relay-check: ## Run relay static checks.
	cd "$(RELAY_DIR)" && GOCACHE="$(abspath $(GO_CACHE))" GOMODCACHE="$(abspath $(GO_MOD_CACHE))" $(GO) vet ./...

relay-test: ## Run relay tests.
	cd "$(RELAY_DIR)" && GOCACHE="$(abspath $(GO_CACHE))" GOMODCACHE="$(abspath $(GO_MOD_CACHE))" $(GO) test ./...

relay-production-test: ## Run opt-in relay production E2E tests against PostgreSQL and Redis.
	cd "$(RELAY_DIR)" && GOCACHE="$(abspath $(GO_CACHE))" GOMODCACHE="$(abspath $(GO_MOD_CACHE))" \
		POINTY_RELAY_PRODUCTION_E2E=1 \
		POINTY_RELAY_E2E_DATABASE_URL="$(RELAY_E2E_DATABASE_URL)" \
		POINTY_RELAY_E2E_REDIS_URL="$(RELAY_E2E_REDIS_URL)" \
		$(GO) test -count=1 ./internal/e2e

relay-run: ## Run the relay server.
	cd "$(RELAY_DIR)" && GOCACHE="$(abspath $(GO_CACHE))" GOMODCACHE="$(abspath $(GO_MOD_CACHE))" \
		POINTY_RELAY_ADMIN_TOKEN="$(RELAY_ADMIN_TOKEN)" \
		POINTY_RELAY_ADMIN_HTTP_ADDR="$(RELAY_ADMIN_HTTP_ADDR)" \
		POINTY_RELAY_DATABASE_URL="$(RELAY_DATABASE_URL)" \
		POINTY_RELAY_REDIS_URL="$(RELAY_REDIS_URL)" \
		POINTY_RELAY_NODE_ID="$(RELAY_NODE_ID)" \
		POINTY_RELAY_NODE_INTERNAL_URL="$(RELAY_NODE_INTERNAL_URL)" \
		POINTY_RELAY_NODE_PROXY_TOKEN="$(RELAY_NODE_PROXY_TOKEN)" \
		POINTY_RELAY_DRAINING="$(RELAY_DRAINING)" \
		POINTY_RELAY_ALLOW_INSECURE_NODE_PROXY="$(RELAY_ALLOW_INSECURE_NODE_PROXY)" \
		POINTY_RELAY_TICKET_TTL="$(RELAY_TICKET_TTL)" \
		POINTY_RELAY_TICKET_REFRESH_TTL="$(RELAY_TICKET_REFRESH_TTL)" \
		POINTY_RELAY_STREAM_OPEN_TIMEOUT="$(RELAY_STREAM_OPEN_TIMEOUT)" \
		POINTY_RELAY_REQUEST_TIMEOUT="$(RELAY_REQUEST_TIMEOUT)" \
		POINTY_RELAY_MAX_REQUEST_BODY_BYTES="$(RELAY_MAX_REQUEST_BODY_BYTES)" \
		POINTY_RELAY_MAX_RESPONSE_BODY_BYTES="$(RELAY_MAX_RESPONSE_BODY_BYTES)" \
		POINTY_RELAY_MAX_CONCURRENT_REQUESTS="$(RELAY_MAX_CONCURRENT_REQUESTS)" \
		POINTY_RELAY_RATE_LIMIT_WINDOW="$(RELAY_RATE_LIMIT_WINDOW)" \
		POINTY_RELAY_RATE_LIMIT_RELAY_REQUESTS="$(RELAY_RATE_LIMIT_RELAY_REQUESTS)" \
		POINTY_RELAY_RATE_LIMIT_TICKET_ISSUE="$(RELAY_RATE_LIMIT_TICKET_ISSUE)" \
		POINTY_RELAY_RATE_LIMIT_TICKET_REFRESH="$(RELAY_RATE_LIMIT_TICKET_REFRESH)" \
		POINTY_RELAY_OPENROUTER_API_KEY="$(RELAY_OPENROUTER_API_KEY)" \
		POINTY_RELAY_OPENROUTER_BASE_URL="$(RELAY_OPENROUTER_BASE_URL)" \
		POINTY_RELAY_AI_MODEL_FAST="$(RELAY_AI_MODEL_FAST)" \
		POINTY_RELAY_AI_MODEL_SMART="$(RELAY_AI_MODEL_SMART)" \
		POINTY_RELAY_AI_MODEL_FRONTIER="$(RELAY_AI_MODEL_FRONTIER)" \
		POINTY_RELAY_AI_DEFAULT_TIER="$(RELAY_AI_DEFAULT_TIER)" \
		POINTY_RELAY_AI_REQUEST_TIMEOUT="$(RELAY_AI_REQUEST_TIMEOUT)" \
		POINTY_RELAY_AI_RATE_LIMIT="$(RELAY_AI_RATE_LIMIT)" \
		POINTY_RELAY_AI_VISION_MODEL="$(RELAY_AI_VISION_MODEL)" \
		POINTY_RELAY_AI_LIMIT_5H="$(RELAY_AI_LIMIT_5H)" \
		POINTY_RELAY_AI_LIMIT_5H_WINDOW="$(RELAY_AI_LIMIT_5H_WINDOW)" \
		POINTY_RELAY_AI_LIMIT_WEEKLY="$(RELAY_AI_LIMIT_WEEKLY)" \
		POINTY_RELAY_AI_LIMIT_WEEKLY_WINDOW="$(RELAY_AI_LIMIT_WEEKLY_WINDOW)" \
		POINTY_RELAY_AI_MAX_IMAGES="$(RELAY_AI_MAX_IMAGES)" \
		POINTY_RELAY_AI_MAX_REQUEST_BYTES="$(RELAY_AI_MAX_REQUEST_BYTES)" \
		POINTY_RELAY_ALLOW_INSECURE_HTTP="$(RELAY_ALLOW_INSECURE_HTTP)" \
		POINTY_RELAY_ALLOW_INSECURE_CONNECTOR="$(RELAY_ALLOW_INSECURE_CONNECTOR)" \
		POINTY_RELAY_HTTP_TLS_CERT="$(RELAY_HTTP_TLS_CERT)" \
		POINTY_RELAY_HTTP_TLS_KEY="$(RELAY_HTTP_TLS_KEY)" \
		POINTY_RELAY_HTTP_TLS_SERVER_NAME="$(RELAY_HTTP_TLS_SERVER_NAME)" \
		POINTY_RELAY_HTTP_CLIENT_CA="$(RELAY_HTTP_CLIENT_CA)" \
		POINTY_RELAY_REQUIRE_ADMIN_CLIENT_CERT="$(RELAY_REQUIRE_ADMIN_CLIENT_CERT)" \
		POINTY_RELAY_PRODUCTION="$(RELAY_PRODUCTION)" \
		POINTY_RELAY_CONNECTOR_TLS_CERT="$(RELAY_CONNECTOR_TLS_CERT)" \
		POINTY_RELAY_CONNECTOR_TLS_KEY="$(RELAY_CONNECTOR_TLS_KEY)" \
		POINTY_RELAY_CONNECTOR_TLS_SERVER_NAME="$(RELAY_CONNECTOR_TLS_SERVER_NAME)" \
		POINTY_RELAY_CONNECTOR_CLIENT_CA="$(RELAY_CONNECTOR_CLIENT_CA)" \
		POINTY_RELAY_CONNECTOR_CLIENT_CA_KEY="$(RELAY_CONNECTOR_CLIENT_CA_KEY)" \
		POINTY_RELAY_CONNECTOR_CLIENT_CERT_TTL="$(RELAY_CONNECTOR_CLIENT_CERT_TTL)" \
		POINTY_RELAY_AUTO_TLS="$(RELAY_AUTO_TLS)" \
		POINTY_RELAY_GENERATED_TLS_CA_TTL="$(RELAY_GENERATED_TLS_CA_TTL)" \
		POINTY_RELAY_GENERATED_TLS_SERVER_CERT_TTL="$(RELAY_GENERATED_TLS_SERVER_CERT_TTL)" \
		POINTY_RELAY_GENERATED_TLS_ROTATION_WINDOW="$(RELAY_GENERATED_TLS_ROTATION_WINDOW)" \
		$(GO) run ./cmd/pointy-relay server \
		--http "$(RELAY_HTTP_ADDR)" \
		--connector "$(RELAY_CONNECTOR_ADDR)"

relay-connector: ## Run the on-prem relay connector beside a local backend.
	cd "$(RELAY_DIR)" && GOCACHE="$(abspath $(GO_CACHE))" GOMODCACHE="$(abspath $(GO_MOD_CACHE))" \
		POINTY_RELAY_CONNECTOR_TOKEN="$(RELAY_CONNECTOR_TOKEN)" \
		POINTY_RELAY_CONNECTOR_SETUP_TOKEN="$(RELAY_CONNECTOR_SETUP_TOKEN)" \
		POINTY_RELAY_CONNECTOR_CONFIG_URL="$(RELAY_CONNECTOR_CONFIG_URL)" \
		POINTY_RELAY_CONNECTOR_STATE_FILE="$(RELAY_CONNECTOR_STATE_FILE)" \
		POINTY_RELAY_ALLOW_INSECURE_CONNECTOR="$(RELAY_ALLOW_INSECURE_CONNECTOR)" \
		POINTY_RELAY_TLS_CA="$(RELAY_TLS_CA)" \
		POINTY_RELAY_TLS_CERT="$(RELAY_TLS_CERT)" \
		POINTY_RELAY_TLS_KEY="$(RELAY_TLS_KEY)" \
		POINTY_RELAY_TLS_SERVER_NAME="$(RELAY_TLS_SERVER_NAME)" \
		POINTY_RELAY_CONNECTOR_REQUEST_TIMEOUT="$(RELAY_CONNECTOR_REQUEST_TIMEOUT)" \
		POINTY_RELAY_CONNECTOR_MAX_CONCURRENT_REQUESTS="$(RELAY_CONNECTOR_MAX_CONCURRENT_REQUESTS)" \
		POINTY_RELAY_CONNECTOR_CLIENT_CERT_ROTATION_WINDOW="$(RELAY_CONNECTOR_CLIENT_CERT_ROTATION_WINDOW)" \
		$(GO) run ./cmd/pointy-relay connector \
		--relay "$(RELAY_CONNECTOR_ADDR)" \
		--backend "$(RELAY_BACKEND_URL)"

relay-migrate: ## Apply relay PostgreSQL migrations.
	cd "$(RELAY_DIR)" && GOCACHE="$(abspath $(GO_CACHE))" GOMODCACHE="$(abspath $(GO_MOD_CACHE))" \
		$(GO) run ./cmd/pointy-relay migrate --database-url "$(RELAY_DATABASE_URL)"

relay-provision: ## Provision a local relay installation and print one-time tokens.
	cd "$(RELAY_DIR)" && GOCACHE="$(abspath $(GO_CACHE))" GOMODCACHE="$(abspath $(GO_MOD_CACHE))" \
		$(GO) run ./cmd/pointy-relay provision --database-url "$(RELAY_DATABASE_URL)"

relay-subscription-update: ## Update company-owned relay subscription state through the relay admin API.
	cd "$(RELAY_DIR)" && GOCACHE="$(abspath $(GO_CACHE))" GOMODCACHE="$(abspath $(GO_MOD_CACHE))" \
		$(GO) run ./cmd/pointy-relay subscription update \
		--control-url "$(RELAY_CONTROL_URL)" \
		--admin-token "$(RELAY_ADMIN_TOKEN)" \
		--allow-insecure-control="$(RELAY_ALLOW_INSECURE_CONTROL)" \
		--control-ca "$(RELAY_CONTROL_CA)" \
		--control-client-cert "$(RELAY_CONTROL_CLIENT_CERT)" \
		--control-client-key "$(RELAY_CONTROL_CLIENT_KEY)" \
		--control-tls-server-name "$(RELAY_CONTROL_TLS_SERVER_NAME)" \
		--installation-id "$(RELAY_SUBSCRIPTION_INSTALLATION_ID)" \
		--actor "$(RELAY_SUBSCRIPTION_ACTOR)" \
		--reason "$(RELAY_SUBSCRIPTION_REASON)" \
		--relay-enabled "$(RELAY_SUBSCRIPTION_RELAY_ENABLED)" \
		--subscription-active "$(RELAY_SUBSCRIPTION_ACTIVE)" \
		--ai-enabled "$(RELAY_SUBSCRIPTION_AI_ENABLED)" \
		--subscription-ends-at "$(RELAY_SUBSCRIPTION_ENDS_AT)" \
		--clear-subscription-end="$(RELAY_SUBSCRIPTION_CLEAR_END)"

format: frontend-l10n frontend-format relay-format ## Format all currently scaffolded code.

check: backend-check frontend-analyze relay-check ## Run non-mutating project checks.

test: backend-test frontend-test relay-test ## Run backend, frontend, and relay tests.

e2e: frontend-e2e ## Run opt-in end-to-end tests.

dev: redis backend-dev-migrate ## Run Redis, Django, and Flutter web together.
	$(MAKE) -j2 backend-run frontend-web

dev-local: backend-dev-migrate ## Run local Redis, Django, and Flutter web together without Docker.
	$(MAKE) -j3 redis-local backend-run frontend-web

dev-no-redis: backend-dev-migrate ## Run Django and Flutter web without starting Redis.
	$(MAKE) -j2 backend-run frontend-web

postgres-ready: docker-check ## Wait until PostgreSQL accepts connections.
	@printf 'Waiting for PostgreSQL'
	@for i in $$(seq 1 60); do \
		if docker compose exec -T postgres pg_isready -U postgres >/dev/null 2>&1; then \
			echo ' ready.'; exit 0; \
		fi; \
		printf '.'; sleep 1; \
	done; \
	echo ' not ready after 60s.'; exit 1

ai-enable: ## Provision the relay installation, enable AI, and sync Django (waits for the relay + backend).
	@bash deploy/enable-local-ai.sh

dev-ai: postgres redis postgres-ready relay-migrate backend-dev-migrate frontend-install ## Run the full AI stack (Postgres, Redis, relay, Django, Flutter) and enable AI.
	$(MAKE) -j4 relay-run backend-run frontend-web ai-enable

clean: ## Remove generated local caches and build output.
	find "$(BACKEND_DIR)" -type d -name __pycache__ -prune -exec rm -rf {} +
	rm -rf "$(VENV)/.installed" "$(FRONTEND_DIR)/build" "$(FRONTEND_DIR)/.dart_tool" "$(GO_CACHE)" "$(GO_MOD_CACHE)"
