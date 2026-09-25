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

Screens are reviewed without a backend through dev-only preview harnesses under
`frontend/lib/dev/`, each with its own `make` target. The owner dashboard is
`make frontend-dashboard-preview`
(`?screen=dashboard|board|dark|fx|payments`) — it feeds the real screen fake
repositories, so there is no server, no login, and no shop data involved.

## Device Printers

Each till keeps its own list of printers (Device Settings → الطابعات), and every
print job belongs to exactly one of them: sale receipts (with payment receipts
and the thermal shift report), barcode labels, full-page documents (reports,
purchase orders, the A4 shift report, consignment papers), and each kitchen
station's chits. A shop with a receipt printer and a label printer sets that up
once; labels never go to the receipt roll and nobody flips a setting to print
one. With no documents printer, reports still open the system print dialog and
purchase orders print on the receipt printer, as before.

The list lives in device storage (`device_printers`). The first read migrates the
old single-printer and kitchen-station settings — the old printer keeps receipts
and labels, with every setting and label calibration — and each save mirrors the
receipt and kitchen printers back into the old keys so an older build still
prints. Preview with `make frontend-printers-preview`
(`?screen=settings|board|migrated|empty|add|edit-receipt|edit-labels`).

## Balance Sheet and Zakat

`الميزانية العمومية` (report `balance_sheet`, under الإقفال) states what the shop
owns and owes — لنا, علينا and الصافي — at the close of the day before the chosen
period and at the close of its last day, so a fiscal-year run sets the year's
opening beside today. Every line is read from the module that owns it: the stock
ledger at cost, the money position, receivables and payables aging, payroll and
staff loans, consignment obligations. The difference between the two columns is
bridged: money added from outside or withdrawn by the owner through the treasury
is set aside, and what remains is the period's result.

Under it, zakat is reckoned at the period's end: goods at their current selling
price (consigned goods excluded), plus cash and every debt owed to the shop, less
what the shop owes, at 2.5% when the base is positive. Preview the reports screen
with `make frontend-reports-preview` (`?screen=reports|result|board`, and
`&report=` with any report key — `unit_aging`, `unit_margin`, `unit_ledger` and
`consignment_ledger` are the serialized-stock reports; the unit ledger asks for a
device's serial or IMEI before it runs).

## Opening Balances and Account Adjustments

A customer or supplier can carry a balance no invoice or purchase order could:
an opening balance (`رصيد افتتاحي`, one per account, optionally set in the same
form that creates the contact) and later adjustments (`تسوية رصيد`, a reason
required), each either `عليه لنا` or `له علينا`. They live in `apps.balances`
and are born-submitted documents: numbered, dated, never edited, cancelled with
a reason only while nothing has been settled against them, and refused inside a
closed period.

They are real debts, not annotations. A customer debt becomes a non-sale
`account_entry` order that is collected like any آجل invoice (oldest first) and
counts in aging, statements, credit limits and reminders without counting as
revenue; a credit is spent automatically on what the customer owes, or paid out
in cash from the drawer (`رد المبلغ للعميل`). A supplier debt is paid through
the supplier's `record-payment` (oldest first across purchase orders and
entries); what a supplier owes the shop is a supplier credit, applied to a
purchase order or taken back in cash (`استلام المبلغ من المورد`). The balance
sheet carries both sides and keeps opening balances out of the period's result;
the profit report's cash bridge names what was settled from credit. Preview
with `make frontend-balances-preview`
(`?screen=customer|supplier|entry|refund|create`).

## Learning Module

`التعلّم` is an in-app library of short Arabic guides, one per operation the
shop actually performs — ring up a split payment, take a down payment on a
credit (آجل) invoice, receive a purchase order short, close the drawer, pair a
device for remote access. It answers the support calls that repeat.

The guides are **data, not screens**: `LearningGuide` objects living in
`frontend/lib/src/features/learning/content/`, one file per track, assembled by
`learning_library.dart`. Adding a guide is a content change — no UI work — and
`frontend/test/features/learning/learning_library_test.dart` fails the build on
a duplicate id, a dangling cross-link, or an empty section.

The catalogue carries the same search / filter / sort controls as the products,
invoices and purchase-order lists (`QueryControlBar` + `QueryFilterSheet`), with
one addition: search normalizes Arabic before matching, so `اجل` finds `آجل`,
`فاتوره` finds `فاتورة`, and `٥٨` finds `58`. Every query token must match (AND),
and a title hit outranks a passing mention in a body.

Filters are track, level, kind (steps / explanation / reference), progress, and
`ما تسمح به صلاحياتي` — which narrows the catalogue to what this user's
permissions actually reach. It is opt-in rather than automatic: an owner
training a new hire has to be able to read the cashier's guides.

### Practice lessons (the sandbox)

A guide tells you; a lesson lets you do it. A lesson runs **the real app** —
same screens, same widgets, same Arabic — against an in-memory practice shop, so
stock really decrements and the drawer really accumulates while nothing touches
the shop's database.

The seam is the one `PointyApp(apiService:)` already exposes, but the fake is
cut one level deeper than the existing e2e test: `SandboxClient` is an
`http.Client`, not a stubbed `PosApiService`, so requests still go through the
real repositories, view models and serializers. A lesson therefore breaks when
the API contract breaks. Unimplemented routes answer a loud `501` — never an
empty list, never a silent success.

Lessons are data (`lib/src/features/learning/lessons/`) with two consumers:

- **the learner** — `LessonRunnerScreen` hosts the sandboxed app beside a coach
  panel, behind a full-width non-dismissible training banner. It never performs
  a step for you; it narrates, rings the control, and waits.
- **CI** — `test/learning/lessons_test.dart` *performs* every step through the
  real screens and asserts each expectation plus the final outcome against the
  sandbox shop.

Lessons point at widgets through `TutorAnchor`, a closed enum, never through
text or position — anchoring a tutorial to copy means it silently rots the first
time someone rewords a button. `TutorTarget` marks a widget; outside a lesson it
is a pass-through with no state and no listeners. Pass an instance `id` wherever
an anchor repeats (a product tile, a cart line, a tender): without one the ring
lands on whichever instance mounted first, and the step completes on something
the learner was never told to touch.

#### How a lesson rots, and what catches it

`test/learning/` is built around the four failure modes, because a tutorial that
is quietly wrong is worse than none:

| Rot | Caught by |
|---|---|
| The anchor stops mounting (screen redesigned) | `lessons_test.dart`, per step, naming the anchor |
| The anchor becomes ambiguous (one control became a list) | `lessons_test.dart` — a step with no `anchorId` must match exactly one widget |
| The step becomes free (something else already satisfies it, so it self-skips and the narration falls a step behind) | `lessons_test.dart` — a step's expectation must be *false* before the act |
| The shop never moved (every step passed, no sale happened) | `lessons_test.dart` — the outcome, asserted against the sandbox ledger, and required to be false at the start |
| A `TutorTarget` was deleted but its enum value survives | `lesson_staleness_test.dart` — scans `lib/src` for the wrapper |
| An anchor no lesson uses any more | `lesson_staleness_test.dart` — dead anchors are deleted, not kept "just in case" |
| A guide was renamed, so its practice button silently vanished | `lesson_staleness_test.dart` — every `guideId` must resolve |
| A back-office lesson seeded with a cashier (opens on a permissions message) | `lesson_staleness_test.dart` — the seed's practice user must hold the lesson's capability |
| A route the practice shop does not implement | the sandbox answers `501` and the run fails naming it |

**The harness has one honest blind spot.** CI types with `enterText`, which sets
the controller directly, so it cannot see a keystroke being stolen before it
reaches the field — which is how the payment sheet's bare `1/2/3` method hotkeys
survived until a cashier tried to type a split-tender amount. Keyboard handling
needs its own `sendKeyEvent` test; there is one in
`test/features/pos/views/payment/payment_sheet_test.dart`.

Preview it with `make frontend-learning-preview`
(`?screen=board|catalogue|search|filtered|cashier|guide|concept|remote|empty|filters|lesson`,
and `?screen=lesson&id=<lesson id>` for a specific lesson).

Phase 1 ships 16 lessons across the till, the drawer, the catalogue, purchasing
and the money that moves without a sale. The written library is still an order
of magnitude broader, which is the intended shape: breadth is content, and the
spine under it is built once.

The sandbox implements **only what a lesson reaches** — everything else answers
`501` and says so in Arabic. So returns, exchanges and stock counts are not in
the practice shop yet: they need a lesson first, and the lesson needs an
instance id on the shared `PointyQuantityStepper` (the return dialog's quantity
lives inside it, and the same gap is why no lesson edits a cart line's
quantity).

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

## Integrations (resale providers)

Shops that resell somebody else's product — TV subscriptions, internet, airtime
— otherwise do that work on the provider's own website, where the money never
reaches the books. `apps.integrations` is the spine for pulling it back in, and
Shop Settings → Integrations is its face.

The provider list in `apps/integrations/catalog.py` is deliberately static and
always rendered whole, so an owner sees what is coming as well as what works:

| Provider | State | Notes |
| --- | --- | --- |
| HD Box | available | DigiCrypt CAS. Session login, JSON endpoints behind the UI. |
| LNET | available | Stored-value billing portal; two-step write, one phone can hold many lines. |
| Qareeb | available | Prepaid cards (Libyana, Almadar, games, bills…) sold as system products on the till's shelf. |

A provider declares which credentials it needs and the Flutter form renders
them, so teaching Pointy a new service is a catalog entry plus a driver in
`apps/integrations/providers/` — no client release. Credentials are encrypted
at rest (`apps.core.secret_box`) and never serialized back out; the API returns
only `has_password`.

Two things the HD Box driver exists to survive, both verified against a live
agency account: **failure arrives as HTTP 200** (a bad card renders an HTML
error page, an expired session renders the login form), and the JSON endpoints
answer with `Content-Type: text/html`. Neither the status code nor the content
type can be trusted — on a money path, "200 means it worked" books a sale for a
recharge that never happened. Nothing in that API is idempotent either, so the
driver is read-only until the write path has an at-most-once design.

Provider floats are **LYD**, whatever glyph the provider's own screen prints
next to them.

Preview the screen with `make frontend-integrations-preview`
(`?screen=catalog|connected|failed|unconfigured|error|board`).

### Capturing a provider's API to build its driver

HD Box and LNET were reverse-engineered from a captured agency session. Qareeb's
agency console is a **Flutter iPhone app**, and Flutter ignores the iOS system
proxy — so a Charles/Proxyman-style Wi-Fi proxy captures nothing. `tools/qareeb-capture`
intercepts below the app with **mitmproxy's WireGuard mode** (all device traffic
tunnels through mitmproxy regardless of proxy-awareness) and turns the result
into a redacted API contract.

```
make qareeb-capture-setup     # once: brew install mitmproxy
make qareeb-capture           # capture the logged-in surface
make qareeb-capture-auth      # capture the login / OTP flow
make qareeb-analyze HOST=qareeb   # newest capture → redacted Markdown contract
```

Raw captures hold live OTPs, tokens and cookies — they are gitignored, kept
local, and deleted once the contract is written. See `tools/qareeb-capture/README.md`
for the iPhone setup and the certificate-pinning caveat.

### Selling a top-up at the till

POS catalog header → **شحن اشتراك** → look a subscriber up → card state, the
provider's live price ladder, and a paginated history of what has been bought
for that card before (including, by name, the competing agencies that sold it)
→ pick a duration → cart.

A recharge is rung up as an **ordinary service-product line**. Every `OrderLine`
needs a real `ProductVariant`, so `apps/integrations/provisioning.py` creates one
product per provider (`INTEG-<KEY>`, `is_service=True`) the first time it is
needed; discounts, returns, receipts and the profit report then need to learn
nothing about recharges. The provider-specific part rides alongside in
`CartLineIntegration` (client) and `IntegrationFulfillment` (server, one-to-one
on the line).

`apps.sales` never trusts a price from a till, so pricing is server-side.
Real shops do not mark up by one rule — HD Box's 25/65/125/220 cost ladder is
sold at a recommended 30/80/140/240, which is neither a flat amount nor a flat
percentage — so prices are **per option**, resolved shop price → the provider's
recommended retail → the account's fallback markup → cost, and floored at cost.

The option list is *learned*: the ladder only exists inside a per-card renew
form, so every real lookup records what it was quoted and Shop Settings prices
what has actually been seen. The recommended retail is seeded as reference data
(`ProviderSpec.suggested_retail`), so a newly connected shop arrives knowing the
card rather than reselling at cost, and a row nobody has touched keeps following
it if the provider reprints. The lookup returns **both** `cost`
and `price` per option so the cart cannot show a different number from the
invoice, and `OrderLine.unit_cost` carries the provider's quote, which makes the
margin on a top-up real rather than assumed.

None of the providers' APIs is idempotent, so the charge is **at most once**
(`apps/integrations/recharge.py`): the fulfillment is claimed `pending →
submitted` in its own committed transaction, the provider is called outside any
transaction, and the answer is recorded in a second one. A lost answer leaves
the row `submitted` — "sent, outcome unknown" — and only reconciliation against
the provider's own purchase log moves it on. Nothing retries a charge.

The button appears only when the shop has actually connected a provider —
`ShopSettings.has_integrations`, derived server-side and carried on the settings
payload every till already loads, so gating it costs no extra call.

The screen opens on the searches that worked before rather than an empty box:
`IntegrationSearch` keeps one row per distinct search (a repeat moves it back to
the top and counts it), served newest first and cursor-paged at
`GET /api/integrations/<key>/searches/?search=`. Typing narrows the list after a
pause; only the search key or button asks the provider, since a lookup costs
seconds against somebody else's portal.

Preview with `make frontend-recharge-preview`
(`?screen=expired|active|expiring|empty-history|notfound|idle|first-use`, and for
LNET `lnet-lines|lnet-single|lnet-expired|lnet-low-float|lnet-notfound|lnet-idle`).

### LNET: top-ups done on the provider's website

LNET keeps one account-wide payments report — every payment the agency made,
from the till or from billing.lnet.ly — printed **ten rows a page over the
agency's whole life**. `apps/integrations/payment_report.py` mirrors it into
`ProviderPayment` (half-hourly, `integrations.sync-payment-reports`, deepening a
young mirror towards three months) and records how far the copy is known to be
whole, so a screen can say "every payment of the day" only when it is true.
The till's history for an LNET line reads that mirror; read live it only ever
reached about a day back, which is why it was always empty.

When the till cannot sell a top-up and a cashier does it on the website instead,
a manager records it afterwards from **Register sessions → شحنات موقع LNET**
(`apps/integrations/portal_sales.py`, permission
`integrations.record_portal_payment` + `sales.add_order`): pick the payment, the
register session whose drawer took the cash (open, or already closed — that is
where an afternoon of website top-ups ends up), and how the customer paid (cash,
card, transfer, or آجل with a customer). It issues the invoice the till would
have issued, through the same checkout, and:

- **sends nothing to LNET** — the fulfillment is born `confirmed`, so the
  at-most-once guard has nothing it could ever charge;
- **re-reads LNET live first** and refuses a payment that is no longer
  verified or no longer printed;
- records **one sale per payment**, under a row lock shared with
  reconciliation, and refuses a payment a till sale already accounts for;
- **draws the LNET float exactly once**, dated when LNET drew it, so the
  treasury's LNET balance and the float-drift warning agree with LNET's own;
- refuses a closed session that was counted before the payment existed, and a
  period the books are closed through;
- when a Pointy sale is still waiting for that very top-up, offers to **link**
  the payment to it instead of counting the customer twice.

`GET /api/integrations/<key>/portal-payments/?date=`, `POST
.../portal-payments/<serial>/record/` and `.../link/`. Preview with
`make frontend-portal-payments-preview` (`?screen=list|sheet|pending|history`).

### Qareeb: cards on the till's shelf

Qareeb sells prepaid cards, not top-ups against a subscriber, so it has **no
top-up button**. Each brand is a **system product** in the POS catalog and each
denomination a variant: search "ليبيانا", tap it, pick the card. The shelf is
built and kept by `apps/integrations/vouchers.py`:

- **Served locally, refreshed in the background.** The till reads the catalog
  from Pointy's own database like any other product — no provider call on a tap.
  Celery beat sweeps every 5 minutes (`integrations.sync-voucher-catalogs`),
  writing only rows that changed, so an idle sweep never bumps the catalog
  version or invalidates a till's cache.
- **Availability comes from Qareeb.** A brand Qareeb stops listing is taken off
  the shelf (`is_active=False`), and a sold-out card disappears. Opening a
  brand's picker also asks Qareeb for that brand's live stock in the background
  (single-flight, at most once per 40 s), so a card that sold out since the last
  sweep vanishes while the cashier is still choosing; checkout re-checks it
  before any money moves.
- **Nobody edits a system product** — not a manager, not the owner. The
  catalog, variant, stock, bulk and attachment endpoints refuse with code
  `system_product` (`apps/catalog/system_products.py`). The price is the
  provider's suggested retail (for a local card, its face value), or the
  account's fallback markup on cost when it gives none; the cost is the
  provider's.
- **One card per line.** A card's quantity is fixed at 1 and identical cards are
  separate lines, because each line is one purchase with its own PIN.

The session: Qareeb's JWT lives 28 days (refresh 100), so a till almost never
logs in. A login from a machine Qareeb has not seen is refused until the owner
confirms it once with an SMS code behind an image captcha (Settings →
Integrations → Qareeb → confirm this device). One login can act for several
profiles (a person and the shops they work for); the owner chooses which one
Pointy buys as, and the till refuses to buy while the login is acting as a
different one rather than paying from the wrong wallet.

Qareeb's cart is shared per agency account (their app and every till use the
same one), so a purchase takes a Redis turn, clears anything foreign from the
cart, and checks out against the cart's live hash. **Firebase App Check is not
enforced on api.qareb.ly today** — no captured request carries a token — and the
driver reports `attestation_required` if that ever changes, rather than an
unexplained 401.

### One receipt for the whole sale

A sale with provider lines prints **once, after the providers have answered**,
with each provider's result beneath its own line: a card's PIN (emphasized) and
serial, an HD Box card's new term, an LNET line's serial. A line whose charge was
not confirmed says so and prints no PIN. The same rows are drawn on the thermal
slip (standard and compact), the A4 PDF and the roll-width PDF
(`frontend/lib/src/data/services/receipt_integration_rows.dart`). If the printer
fails, the till shows the PINs on screen.

### Screenshots without a browser

`frontend/test/screens/` renders real screens to PNG headlessly, with the app's
Arabic font and the Material icon font loaded:

```
POINTY_CAPTURE_SCREENS=1 flutter test test/screens --update-goldens
```

Output lands in `test/screens/goldens/`. An ordinary `flutter test` **skips**
every case there, so it is a way to look at a screen — not a golden gate that
fails CI on a deliberate design change.

## Counter camera as a barcode scanner

A USB camera on a stand over the counter can scan like a wedge scanner:
**Device settings → الكاميرا كقارئ باركود**, per machine. On the Windows tills
the whole thing — the camera's video stream (Media Foundation), zxing-cpp and
the rule that a 1-D read needs two agreeing looks before it reaches a cart —
runs in native code in `frontend/packages/pointy_camera_wedge`; Dart only
receives finished scans. Android, iOS and macOS use `mobile_scanner` instead.

- **F8** anywhere in the app shows what the camera sees, whether it is
  reading, and the last thing it read (a small floating panel; F8 again
  closes it). Device settings shows the same picture for aiming.
- The camera recovers on its own when it is unplugged and plugged back in,
  released by another program, or allowed through Windows' camera privacy
  setting; settings says which of those is happening and, for the privacy
  setting, opens the right Windows page.

```sh
make frontend-camera-wedge-test     # native engine tests + FFI tests (needs CMake)
make frontend-camera-wedge-preview  # the F8 panel and settings states (?screen=board|panel|settings)
```

To check a camera on a real till without installing the app, build the
package's `camera_wedge_probe` console tool — see
[`frontend/packages/pointy_camera_wedge/README.md`](frontend/packages/pointy_camera_wedge/README.md),
which also describes the design and how to add Linux.

## Cameras (DVR/NVR)

Pointy talks to the shop's own Hikvision or Dahua recorder on the LAN and puts
two things in the app that no DVR ships: a live camera wall, and **the footage
from the moment an invoice was rung up, on that invoice's page** — no channel
number, no time to type, no proprietary Windows client.

The backend holds the recorder's credentials and every byte of video passes
through it (`apps/surveillance`). Tills never learn the DVR password, and the
same endpoints work over the relay tunnel when the owner is not in the shop.
Live and playback share one wire format — `multipart/x-mixed-replace` carrying
JPEG frames — so the app has a single player and needs no video codec.

- **Live** streams the recorder's sub-stream through ffmpeg at up to 60fps, so a
  camera that shoots 30 arrives at 30 — nine at a time. Where ffmpeg is absent
  it falls back to JPEG snapshot polling, capped at 8fps because that path costs
  an HTTP round trip per frame.
- **Playback, export and stills** run ffmpeg (`-c copy` for exports, so a clip
  is a byte-for-byte copy of what the recorder stored). ffmpeg is detected at
  runtime and reported to the app, which hides what it cannot do; the shipped
  image installs it.
- **One upstream pull per camera**, whatever the number of viewers: a frame
  broker fans out to every subscriber so four tills watching the wall do not
  hit the recorder four times.
- **The wall scrolls and only what is on screen streams.** Tile size is a
  setting; the column count falls out of the viewport, so it is one column on a
  phone and four on a monitor without a breakpoint anywhere.
- **A live band on the dashboard.** Up to three cameras under the headline
  numbers, chosen automatically (checkout cameras first) until someone picks
  their own per device. It refreshes stills at 2fps off the recorder's snapshot
  endpoint rather than streaming — a dashboard left open all day must not hold a
  transcode per camera open — and a tap opens the full player.
- **One full-screen player** for live and playback, with auto-hiding controls, a
  timeline that paints the recorder's own recorded segments, and export as a
  *mode*: the bar becomes a range selector, playback loops inside the selection,
  and what you are watching is exactly the clip you will save.

Set it up in **Shop settings → الكاميرات وجهاز التسجيل**. The form opens by
**sweeping the network for recorders** and listing what it found — most people
configuring this have never typed an IP address, so picking their DVR off a list
fills the address, port, brand and username for them, leaving only the password.
The sweep runs on the client (the backend's container has no route onto the
shop's broadcast domain) and needs no credentials: both brands answer their
identity endpoint with an authentication challenge, and which endpoint
challenges is what names the brand. Manual fields sit below for installers who
already know the address. A successful connection turns the feature on, and
every camera surface stays hidden until then. Camera names are the shop's own and are stored here, not
pushed to the DVR. Mark the cameras that watch the counter as *covering
checkout* to have them offered on invoices.

Permissions are three, because shops ask for the distinction: watching live
(`surveillance.view_live`), reviewing recordings (`surveillance.view_playback`),
and taking a copy away (`surveillance.export_footage`). Managers hold all three;
supervisors get the first two.

Preview the screens with `make frontend-cameras-preview`
(`?screen=board|wall|playback|live-player|settings|recorder-form|dashboard-band|invoice`) — the
harness synthesises frames, so no recorder is needed. Design notes and the
protocol details live in `SURVEILLANCE_PLAN.md`.

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

### Making a run faster

Two flags, both opt-in, neither of them what `backend-test` does by default:

```sh
make backend-test-keepdb TEST_LABELS=apps.surveillance   # reuse the test database
make backend-test-slowest TEST_LABELS=apps.sales         # print the slowest tests
```

`--keepdb` skips building the database and replaying every migration. It is
**only useful on Postgres** — Django's sqlite test database is always
`:memory:` whatever `DATABASE_URL` says, so there is nothing to keep and the
flag does nothing. It is not the default on purpose either: a kept database is
only as correct as the last time it was built, and a migration edited in place
leaves a schema that no longer matches the tree while the run still goes green.
Iterate with it, prove with `make backend-test-pg`.

### Identified stock: the oracle and the invariants

Serialized and batch stock has two checks beyond the suite, and both are worth
knowing about because the test suite is green in cases where neither is.

```bash
make backend-tracked-simulation                        # 500 random operations
make backend-tracked-simulation SIM_SEED=7 SIM_OPERATIONS=20000
make backend-stock-integrity                           # the invariants, on real data
make backend-contract-gate CONTRACT_FLOOR=2.12.0       # is the fleet past it?
```

The simulation drives receipts, sales, transfers and recalls at random against
an independent model of what the shop should hold, and any disagreement prints
the operation and reproduces from `SIM_SEED`. It opens two warehouses, so a
transfer leg that values the goods correctly at the source and wrongly at the
far end is visible to it. `backend-stock-integrity` is the other half: it runs
the fourteen §5.4 invariants (`apps/inventory/integrity.py`) against whatever
is actually in the database, is read-only, and exits non-zero when one does not
hold — so it is safe on a live shop and belongs on a schedule. Every defect the
Phase A/B review found was found by those checks and missed by the suite.

`backend-contract-gate` answers one question and only when asked: whether
every installation in the fleet is past a given version. That is the
precondition for any **contract** migration — one that removes something the
previous release still writes — because the edge nginx runs that release
against the new schema for about a minute (`zero-downtime-updates`) and
`relay-remote-update` lets shops sit pinned, paused or on a canary. It refuses
on a silent installation, on an empty fleet and on an unreachable relay: not
knowing is not the same as being ready.

`--durations` is the profiler. Anything an order of magnitude above its
neighbours is usually a real `sleep` or an expensive fixture rather than the
work under test — which is how the surveillance suite turned out to be spending
six of its twelve seconds waiting for a producer thread to wake up between
frames at 1fps.

### Where the rest of the time goes

About **16–23 seconds of every `manage.py test` invocation** is Django rendering
historical model classes out of this project's 283 migrations — `ModelState.render`,
29,184 calls, before a single test runs. It is paid once per process, so `make
backend-test` pays it once and splitting a run across eight `manage.py test`
invocations pays it eight times. `--keepdb` does not touch it: the cost is
Python rebuilding model state, not DDL.

The only real fix is squashing migrations, which is a decision rather than a
tidy-up — this project ships expand/contract migrations for zero-downtime
updates, so a squash has to preserve that. `MIGRATION_MODULES = None` (the
"nomigrations" trick) would remove the cost and is **not safe here**: it would
skip the trigram extension, the data migrations, and the `post_migrate` role
setup the suite depends on.

Password hashing during tests is handled for you: `PointyTestRunner` puts MD5 in
front of the real hashers for the duration of the run. PBKDF2 at Django's work
factor costs about 100 ms per `create_user(password=...)`, this suite has 238
such call sites and most are in a `setUp`, so the default settings spend minutes
on hashes no assertion reads. Measured on the suites that run without Redis:
`apps.employees` 11.5s → 1.1s, `apps.fx` 9.3s → 1.6s, `apps.documents` 4.4s →
1.5s.

**`--parallel` is not safe here yet.** Each worker gets its own database, but
they all share one Redis, and about ten test modules exercise the cache
directly — `test_caching`, `test_state_version`, the price-checker and
discount-preview cache tests. One worker's `cache.clear()` lands in another
worker's test. Making it safe means giving each worker its own cache key prefix
in `init_worker`; until that exists and has been proven on a box with Redis and
Postgres, parallel runs will fail intermittently and for reasons that have
nothing to do with the change under test.

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
test artifacts without cutting a release. The build jobs run in parallel and
attach their output to the release:

| Job             | Artifact                                  | Notes |
| --------------- | ----------------------------------------- | ----- |
| `build-android` | `pointy-<ver>-android-universal.apk`      | One APK for every till device (`minSdk 23` / Android 6.0), carrying both ARM ABIs. x86_64 is deliberately excluded — no shipping cashier tablet uses it (that means Chromebooks and Intel-host emulators). Measured on v0.5.0, this took the APK from 120.4 MB to 79.5 MB; it did **not** measurably speed the build up. |
| `build-windows` | `pointy-<ver>-windows-x64-setup.exe` (+ portable `.zip`) | **Inno Setup installer** (Start Menu + desktop shortcuts, uninstaller) for easy one-click setup — recommended. A portable extract-and-run `.zip` ships alongside for locked-down deployments. The Visual C++ runtime is bundled in both, so the app runs on old/minimal Windows 10+ PCs with no extra install. |
| `build-linux`   | `pointy-<ver>-linux-x64.deb` (+ portable `.tar.gz`) | **Debian package** (Ubuntu/Mint) — the Linux counterpart of the Windows installer: installs to `/opt/pointy`, registers the menu entry and the hicolor icons, and puts a `pointy` launcher on `PATH`. That is what makes the app show its own icon in the menu and the task list, which an extracted folder and a hand-made shortcut cannot do. The portable `.tar.gz` ships alongside for non-Debian distros, and is what the app's own self-update swaps in (a package under `/opt` cannot replace itself). Both need GTK 3, preinstalled on desktop distros. |
| `build-onprem-images` | _(intermediate)_                    | The server half of the bundle — images, WSL rootfs, Compose — built alongside the client jobs rather than after them, which is what keeps the release wall-clock near the longest client build instead of the sum. |
| `build-onprem`  | `pointy-onprem-<ver>.zip`                 | Fully offline server bundle: backend + relay + **web (Flutter web + nginx)** + Postgres + Redis images saved as `docker load` tarballs, the Compose file (`restart: always`), `.env.example`, installers, and a boot/crash **watchdog** that self-heals the stack so the till has no outages. Browser users open `http://<server-ip>/`. It also carries every client installer under `clients/` — including the **Windows 7/8/8.1 build** pulled from the newest `-compat` release — so a site installs both kinds of till from this one zip, with no second download. See [`deploy/onprem/INSTALL.md`](deploy/onprem/INSTALL.md). |

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
