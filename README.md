# Pointy POS

A starter point-of-sale stack with a Django REST Framework backend, Redis-backed cache/task wiring, and an Arabic-first Flutter frontend.

## Layout

- `backend/` - Django API for catalog, sales, payments, inventory, Redis cache, and Celery tasks.
- `frontend/` - Flutter POS client with cashier-first sales, catalog, register-session, printing, and settings screens.
- `relay/` - Standalone Go relay server and on-prem connector for remote Pointy access.

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
python manage.py runserver
```

On a fresh database, start the Flutter frontend and create the first manager
account from the onboarding screen. Pointy no longer creates or prints default
admin credentials during migration.

Run Redis with Docker:

```sh
make redis
```

If Docker Desktop is not running, open it and retry. If Redis is installed locally, use `make dev-local` instead of `make dev`.

Run Celery for background and scheduled jobs:

```sh
make backend-celery
make backend-celery-beat
```

The worker processes Redis-backed tasks. Beat schedules recurring jobs such as
business notification sync, suspected cashier activity detection, and expiry-date
stock alerts.

## Backup and Restore

Managers can configure daily backups from the shop settings screen. Backups run
through Celery, write one dated ZIP file, and include the database fixture plus
uploaded media files. Restore uploads that ZIP through the same screen and runs
as a tracked background job with progress updates.

For Docker deployments, mount the USB flash drive or external SSD into the
backend container, then expose that mount through `POINTY_BACKUP_ALLOWED_ROOTS`.
The backend can only list and write paths visible inside the container.

Example:

```env
POINTY_BACKUP_ALLOWED_ROOTS=/mnt/pointy-backups,/media,/run/media
POINTY_BACKUP_STAGING_ROOT=/tmp/pointy-backup-staging
POINTY_BACKUP_RETENTION_COUNT=7
POINTY_BACKUP_RESTORE_MAX_BYTES=5368709120
```

Pointy stores archives under `pointy-backups/` inside the selected destination
and removes older Pointy backup archives after a successful run according to the
retention count.

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
- `GET /api/products/image-search/?q=...` to search configured internet image
  results for product setup
- `POST /api/products/{id}/image-import/` with an image search `import_token`
  to save a selected internet image as a product image
- `POST /api/shop-settings/logo/` with `file` to store the shop logo used by
  reports, receipts, and invoices
- `POST /api/purchase-orders/{id}/attachments/` for supplier invoice scans
- `GET /api/attachments/{id}/download/` for authenticated downloads
- `content_url` values in attachment API responses include a short-lived signed
  token so product image previews can render in the Flutter web app without
  exposing unrestricted file URLs

Internet product image search is relay-hosted (Serper.dev): the relay holds one
search key for every shop and gates each request on the shop's relay
subscription, so individual deployments never manage a search API key. Set the
key on the relay, not on the backend:

```sh
# relay/.env (or the relay's environment)
POINTY_RELAY_SERPER_API_KEY=your-serper-key
# Optional overrides (defaults shown):
# POINTY_RELAY_SERPER_BASE_URL=https://google.serper.dev/images
# POINTY_RELAY_SERPER_IMAGE_LANGUAGE=ar
# POINTY_RELAY_SERPER_IMAGE_COUNTRY=us
```

The backend forwards `GET /api/products/image-search/` to the relay's
`POST /v1/image-search` endpoint using the shop's relay access token; an empty
key (or a shop without an active relay subscription) simply disables the feature.
The backend still owns the import/download settings:

```sh
POINTY_PRODUCT_IMAGE_IMPORT_MAX_BYTES=10485760
POINTY_ATTACHMENT_CONTENT_TOKEN_MAX_AGE_SECONDS=21600
```

Search responses include short-lived signed import tokens instead of raw image
download URLs. When a user selects a result, Pointy validates the remote host,
downloads the image server-side, and stores it through the attachment API.

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

## Relay Quick Start

The relay is a separate Go project. It keeps the fast remote-access path out of
Django: mobile clients talk to the relay, the on-prem connector keeps one
outbound tunnel open to the relay, and the connector forwards each request to
the local Pointy backend. Django still owns normal cashier/admin
authentication and authorization.

Start the relay data services and apply relay migrations:

```sh
make postgres
make redis
make relay-migrate
```

For local development, put relay control values in `backend/.env` before
starting Django:

```env
POINTY_RELAY_CONTROL_URL=http://127.0.0.1:8091
POINTY_RELAY_PUBLIC_API_URL=http://127.0.0.1:8091
POINTY_RELAY_CONNECTOR_ADDR=127.0.0.1:8092
POINTY_RELAY_ADMIN_TOKEN=local-admin
POINTY_RELAY_ALLOW_INSECURE_CONTROL=true
POINTY_RELAY_CONNECTOR_SETUP_TOKEN=local-connector-setup
```

Start the relay server:

```sh
make relay-run RELAY_ADMIN_TOKEN=local-admin
```

Start Django and the on-prem connector in separate terminals:

```sh
make backend-run
make relay-connector RELAY_CONNECTOR_SETUP_TOKEN=local-connector-setup
```

The connector setup token is consumed once by the backend. After a successful
bootstrap the connector writes its connector token and, for mTLS, its issued
certificate material to `POINTY_RELAY_CONNECTOR_STATE_FILE` or the default
state file under the user's Pointy state directory. Heartbeats use the connector
token, not the setup token, so the setup secret is never needed after first run.

By default, Django exposes a private-network discovery endpoint at
`/api/discovery/service/` and answers UDP discovery probes on port `47777`.
The connector uses that discovery path when `--backend` is omitted, so the
normal local setup does not need a backend URL. Flutter also discovers the LAN
backend before loading the current session. After a cashier or manager signs in
over LAN, the app asks the backend for a short-lived relay ticket and stores the
local API URL plus the relay fallback. Later requests use LAN first and switch
to relay only when the saved local target is unreachable. Relay tickets remain
short lived. The app prefers LAN refresh while the backend is reachable; when
LAN is unavailable, an already-paired device may use its rotating relay refresh
credential to mint the next short-lived ticket remotely. If both the ticket and
refresh credential expire while LAN is unavailable, the app stays offline until
it pairs over LAN again.

Discovery only returns non-secret metadata such as shop name, installation id,
backend URL, relay public URL, and connector heartbeat time. Relay pairing is
authenticated and LAN-only by default. The LAN gate uses the direct remote
address unless `POINTY_DISCOVERY_TRUST_PROXY_HEADERS=true` is explicitly set
for a trusted reverse-proxy deployment. Requests forwarded through the relay are
tagged by the relay and are never accepted as LAN pairing requests, even though
they reach Django through the local connector.

Managers provision the installation through the backend:

```sh
curl \
  -X POST \
  -b cookies.txt \
  -H 'X-CSRFToken: <csrftoken>' \
  -H 'Content-Type: application/json' \
  -d '{}' \
  http://127.0.0.1:8000/api/relay/installation/
```

New installations are intentionally safe by default: remote relay access is not
enabled and the relay subscription is not active. A phone or register that is
already authenticated to the local backend asks the backend for pairing:

```sh
curl \
  -X POST \
  -b cookies.txt \
  -H 'X-CSRFToken: <csrftoken>' \
  -H 'Content-Type: application/json' \
  -d '{"device_id":"phone-1","device_name":"manager phone"}' \
  http://127.0.0.1:8000/api/relay/pairing/
```

When the relay entitlement and subscription are active, the backend exchanges
its stored long-lived access token for a short-lived `ptt1...` relay ticket and
returns the relay URL, shop name, installation id, ticket, rotating
`ptrf1...` refresh credential, and expiries to the phone. Long-lived `ptr1...`
access tokens are not meant to be stored on phones.
The relay accepts `/r/<relay-ticket>/api/...` only for short-lived ticket tokens;
long-lived access tokens and refresh credentials must stay out of URL paths.
Refresh credentials are hash-stored in Redis, consumed atomically on use, and
rotated every time the relay issues a refreshed ticket.

Relay subscriptions are managed by our company through the separate Go relay
cloud service, not through the customer Pointy Flutter or Django UI. Operators
use the relay admin API, `/admin` console, or `pointy-relay subscription update`
with relay admin auth, actor, and reason metadata. Each change writes a relay
admin audit event and the customer backend later observes the new entitlement
state through its normal relay sync path.

Production relay deployments should run the public phone listener and connector
listener with TLS, and should expose relay admin/control routes only on a
separate private listener with `RELAY_ADMIN_HTTP_ADDR`. Set
`RELAY_PRODUCTION=true` to make the relay refuse unsafe startup config:
cleartext listeners, open admin access, missing admin mTLS, missing connector
mTLS, or unsafe node-to-node routing. The Makefile defaults to explicit
insecure relay listeners only for local development. To issue connector client
certificates automatically, configure the relay with `RELAY_CONNECTOR_CLIENT_CA`
and `RELAY_CONNECTOR_CLIENT_CA_KEY`; the connector generates its private key
locally and sends only a CSR through the backend bootstrap path.

The relay uses PostgreSQL for durable installation state: token hashes,
subscription flags, AI entitlement flags, and connector heartbeat metadata.
Redis is used for hot installation cache entries and short-lived connector
presence/relay-node ownership. Redis also stores short-lived relay ticket
metadata plus rotating refresh-token metadata and token hashes. Live request
bodies and tunnel bytes stay on the connector TCP session and are never stored
in Redis.

For multi-node relay deployments, each relay node can advertise a private
`RELAY_NODE_INTERNAL_URL` and require a shared `RELAY_NODE_PROXY_TOKEN` for
node-to-node routing. This lets a phone request that lands on node A route to
node B when Redis presence shows that node B owns the connector session. The
internal URL is HTTPS-only by default and should point at the private
admin/control listener when listeners are split; `RELAY_ALLOW_INSECURE_NODE_PROXY`
is for local development.

Operators can drain a relay node with `RELAY_DRAINING=true`: `/readyz` returns
unavailable, `/v1/status` reports the drain state, and new connector sessions
are rejected while existing bounded requests finish.

The production relay path has explicit guardrails for request size, response
size, stream-open timeout, total relay timeout, concurrent remote requests, and
Redis-backed rate limits for relayed requests, ticket issuance, and ticket
refreshes. The connector also caps concurrent backend-forwarded requests and
applies a backend request timeout. These are configured with the `RELAY_*`
Makefile variables or the matching `POINTY_RELAY_*` environment variables
documented in `relay/README.md`.

Relay support endpoints are available at `/v1/status`, `/v1/metrics`, and
`/v1/installations/<installation-id>/status`. They require relay admin auth and
return aggregate counters plus sanitized per-installation support state without
exposing connector/access token hashes or bearer credentials. In production,
serve them from the private admin/control listener, not the public phone
listener.

Remote relay access is denied when an installation's relay entitlement is
disabled, the subscription flag is inactive, or its subscription end time has
passed. Local LAN access to the on-prem backend is unaffected.

## AI Assistant

The relay also hosts a streaming, multi-model AI assistant. The Flutter app
talks to the on-prem Django backend (`POST /api/ai/chat/`, normal session auth),
Django brokers the call to the relay (`POST /v1/ai/chat`) using the
installation's access token, and the relay calls OpenRouter and streams the
reply back as Server-Sent Events. The OpenRouter key and the Fast/Smart/Frontier
model catalog live only on the relay; Django owns conversation history on-prem.
The relay also auto-routes by prompt difficulty, accepts image/file attachments
(routing them to a vision model), and meters per-shop usage with rolling 5-hour
and weekly limits surfaced in-app as a usage ring. The assistant can also **query
the shop's own data** (sales, products, inventory, expenses…) through read-only
tools: Django runs an agentic tool loop that dispatches each query through the
real DRF viewsets **as the current user**, so the existing permission stack
(role gating, per-user row scoping, manager-only fields) is reused and never
bypassed. The app shows what it queried as a live "querying sales…" chip.

AI is a per-shop entitlement, independent of remote access: it needs an active
subscription plus the `ai_enabled` flag (set by our company through the relay
admin, e.g. `pointy-relay subscription update --ai-enabled=true`). The app shows
the assistant only when the shop's AI entitlement is active. Configure the relay
with `POINTY_RELAY_OPENROUTER_API_KEY` and the `POINTY_RELAY_AI_*` model/tier
variables — see `relay/README.md` ("Relay-Hosted AI") for the full list.

### Run the AI stack locally

One command brings up the whole AI stack — PostgreSQL, Redis, the relay, Django,
and the Flutter web app — and enables the AI entitlement for a local shop:

```sh
make dev-ai
```

Before running it once, add your OpenRouter key to `relay/.env`
(`cp relay/.env.example relay/.env`, then set `POINTY_RELAY_OPENROUTER_API_KEY`).
`make dev-ai` then starts the services and, once the relay and backend are
healthy, automatically creates a local manager (`admin` / `admin12345`),
provisions the relay installation, flips the AI entitlement on, and syncs Django.
When it prints "AI is enabled locally", open <http://127.0.0.1:8080>, sign in,
and open "المساعد الذكي". Stop everything with Ctrl+C.

The AI-enable step is also available on its own (handy if the stack is already
running) and is safe to re-run:

```sh
make ai-enable
```

For Django to reach the relay, `backend/.env` needs the relay control settings
(`POINTY_RELAY_CONTROL_URL`, `POINTY_RELAY_ADMIN_TOKEN=local-admin`, etc.); see
`backend/.env.example`. The `admin` token must match `relay/.env`.

## Quality Gates

Fast checks stay on the normal targets:

```sh
make check
make test
```

These include the backend, frontend, and relay checks.

`make test` runs the backend suite on whatever `backend/.env` points at, which
is sqlite in a fresh checkout. Several suites are Postgres-only and **skip**
there — the query-scaling guards, the PgBouncer settings tests, dead-connection
recovery and trigram search — so a green run does not prove a change on its own.
Every run prints the engine it used:

```
[pointy] test database: postgresql 'test_pointy'
```

To pin it to Postgres and fail rather than fall back:

```sh
make backend-test-pg
```

Relay-only checks are:

```sh
make relay-check
make relay-test
```

Relay production E2E is opt-in because it requires PostgreSQL and Redis. It
runs relay migrations, exercises Redis-backed tickets/presence/rate limits, and
verifies a two-node relay request preserves Django session cookies and CSRF:

```sh
make postgres redis
make relay-production-test
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
make postgres-ping # Check PostgreSQL connectivity
make redis-ping    # Check Redis connectivity
```

## Releases (GitHub Actions)

`.github/workflows/release.yml` builds and publishes the customer-facing
artifacts. It runs automatically when a **GitHub Release is published** (tag like
`v1.2.3`), and can also be run from the Actions tab (**Run workflow**) to produce
test artifacts without cutting a release. Four build jobs run in parallel and
attach their output to the release:

| Job             | Artifact                                  | Notes |
| --------------- | ----------------------------------------- | ----- |
| `build-android` | `pointy-<ver>-android-universal.apk`      | One universal APK (all ABIs, `minSdk 23` / Android 6.0) for sideloading to till devices. |
| `build-windows` | `pointy-<ver>-windows-x64-setup.exe` (+ portable `.zip`) | **Inno Setup installer** (Start Menu + desktop shortcuts, uninstaller) for easy one-click setup — recommended. A portable extract-and-run `.zip` ships alongside for locked-down deployments. The Visual C++ runtime is bundled in both, so the app runs on old/minimal Windows 10+ PCs with no extra install. |
| `build-linux`   | `pointy-<ver>-linux-x64.tar.gz`           | Portable extract-and-run bundle for Linux till PCs (needs GTK 3, preinstalled on desktop distros): `tar xzf`, then run `./pointy_frontend`. Not part of the LAN client self-update system (Android + Windows only). |
| `build-onprem`  | `pointy-onprem-<ver>.zip`                 | Fully offline server bundle: backend + relay + **web (Flutter web + nginx)** + Postgres + Redis images saved as `docker load` tarballs, the Compose file (`restart: always`), `.env.example`, installers, and a boot/crash **watchdog** that self-heals the stack so the till has no outages. Browser users open `http://<server-ip>/`. See [`deploy/onprem/INSTALL.md`](deploy/onprem/INSTALL.md). |

Toolchain versions are pinned in the workflow `env:` to match local development
(Flutter 3.38.6 / Dart 3.10.7, JDK 17; Go 1.25 + Python 3.12 come from the Docker
images). Bump them there when the project upgrades.

### Android signing

The APK is **debug-signed by default** so the workflow works out of the box. To
ship production-signed builds, add these repository secrets — the build then
signs with your upload key automatically (see
`frontend/android/app/build.gradle.kts`):

| Secret                        | Value |
| ----------------------------- | ----- |
| `ANDROID_KEYSTORE_BASE64`     | `base64 -w0 upload-keystore.jks` |
| `ANDROID_KEYSTORE_PASSWORD`   | Keystore password |
| `ANDROID_KEY_ALIAS`           | Key alias |
| `ANDROID_KEY_PASSWORD`        | Key password |

> The default `applicationId`/`namespace` is still `com.example.frontend`. Change
> it to a real, owned id before publishing to the Play Store (sideloaded APKs are
> unaffected).

### Windows installer signing

The installer (`frontend/windows/installer/pointy.iss`, compiled with Inno Setup)
works unsigned, but Windows SmartScreen then warns "unknown publisher" on first
run. To Authenticode-sign the app and the installer automatically, add these
secrets — the build signs both when they are present:

| Secret                           | Value |
| -------------------------------- | ----- |
| `WINDOWS_SIGNING_CERT_BASE64`    | Code-signing cert as base64 PFX (`base64 -w0 cert.pfx`) |
| `WINDOWS_SIGNING_CERT_PASSWORD`  | PFX password |
