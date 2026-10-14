# Presto Sales Channel — Design

Status: **design, not built** (2026-10-14). Read §0 and §13 first: some of this
design waits on answers from Presto, and the design says exactly which parts.

Presto (بريستو) is a Libyan delivery app. It publishes a **Vendor Integration
API** (`https://integration.presto.app/docs/vendor-integration-api/getting-started`,
API host `https://api.presto.ly`). This plan connects a shop's Presto store to
Pointy (دفتر) as a sales channel. Orders arrive and move through their states in
Pointy. They become invoices, they settle against Presto's payouts, and the
shop's catalog and stock drive what Presto shows.

---

## 0. Summary

| Area | Decision |
|---|---|
| Inbound orders | Presto → **relay** webhook (one public URL per shop binding) → **durable relay inbox** → connector tunnel → shop's own inbox. |
| Trust | **A webhook is a nudge, never data.** The shop re-fetches every order from Presto with its *own* token and checks `vendor.id`. Same rule as the Dafa wallet webhook. |
| Isolation | **Three independent locks** (relay binding, shop binding check, Presto's per-vendor token). A misdelivery needs all three to fail at once. |
| Outbound calls | Accept/reject/ready and catalog sync go **shop → Presto directly**. The relay never holds a vendor's Presto credentials. |
| Order states | A `ChannelOrder` mirrors Presto's lifecycle. Its status only moves forward. It is separate from the sales `Order` (the invoice). |
| Invoice timing | The invoice is issued at **handover** (picked up by the driver or collected by the customer), because that is when the goods leave the shop's custody. Accept is a promise; a cancel before handover is waste, never a voided sale. Moves to delivery only if Presto's terms leave transit risk with the shop (§7.2). |
| Money | The invoice names the **real end customer** (one per Presto `customer_id`, auto-created like payment-card placeholders). It is **paid at handover by a `channel` payment held in a Presto clearing account**: Presto owes the shop, the customer owes nothing. A `ChannelSettlement` (the `CardSettlement` pattern) moves clearing → bank, with commission as the difference. |
| Catalog | An explicit **listing table** (variant ↔ Presto item) with a stable `external_ref` that is **adopted, never renamed**. Matching is a reviewed proposal, never a silent auto-merge. Publishing is opt-in per product. |
| Rollout | **Mirror** (Presto tablet stays primary) → **Primary** (act from Pointy) → **Catalog sync**. Each phase is usable on its own. |

---

## 1. What Presto gives us — facts and gaps

### Facts (from the published docs)
- **Auth (outbound):** `POST /api/developer/v1/auth/token` `{email, password, token_name, token_expiration_date}` → `data.token.value`. Bearer token. Tokens expire and must be renewed before they lapse.
- **Webhooks (inbound):** `POST` to our `serviceUrl` with envelope `{event, body}`. Headers documented: `Authorization: Bearer {API_KEY}`, `X-Origin: product`. Events:
  `order_created`, `order_accepted`, `order_ready`, `order_cancelled`, `order_updated`, `driver_arrived_at_vendor`, `order_picked_up`, `order_returned`, `order_completed`.
- **`order_created` body:** `order_reference`, `items[{id, order_item_id, quantity, price}]`, `service_charge`, `delivery_charge`, `subtotal`, `total`, `customer_id`, `delivery_method` (1 delivery / 2 pickup), `payment_method` (`cash` | `wallet`), `vendor_id`.
- **Order actions:** `POST /orders/{id}/accept` (no body except virtual orders) · `POST /orders/{id}/reject` (`cancel_reason_id` from `GET /cancel-reasons`, optional `items`) · `POST /orders/{id}/ready` · `GET /orders/{id}`.
- **`GET /orders/{id}`** is the rich record. It holds `status.key`, `customer.name`, `print_order_number`, `items[].product.{id, vendor_reference_id, barcode, …}`, `items[].customizations`, `payment_method`, `delivery_method`, `is_pickup`, `can_mark_as_ready`, `pickup_otp`/`return_otp`, `vendor.id`, and charges.
- **Catalog:** `POST /items` is a bulk upsert **keyed by `vendor_reference_id`** (≤100 items, ≤10 variants each, ≤1000 variants total). `GET /items?page=` lists 100 per page, **parents only**. `POST /items/availability` is a bulk `{vendor_reference_id, is_available, is_active, stock?{manage, quantity}}`. Categories, brands and attribute values are read-only lookups.

### Gaps that shape this design
1. **No event ID, no documented signature.** The security section mentions a signature, but no header is listed. **→ Every webhook is a nudge (§2).** **Decided 2026-10-14:** ignore the signature until it is documented or observed. Build a ready-to-enable verifier slot plus header discovery, so turning it on is configuration, not a release (§4.2 step 3).
2. **No list-orders endpoint (confirmed by the owner, 2026-10-14).** **→ The relay keeps its own permanent order index per shop, and the shop reconciles against it (§4.8).** Relay ingest must be durable *before* it answers 2xx (§4).
3. **`order_created` items carry no reference to our catalog.** **→ The shop always fetches `GET /orders/{id}` before it can show or invoice an order.**
4. **`serviceUrl` scope is unspecified.** **Design assumption (decided 2026-10-14):** the `serviceUrl` is an arbitrary HTTPS URL we hand to Presto per vendor at onboarding, so it carries a per-shop secret path token (§4.2).
5. **Acceptance timeout (owner's field knowledge, 2026-10-14): ~5 minutes at best, then Presto auto-cancels.** This sets a hard latency budget (§5.5) and drives the alert/escalation design (§6.1). **Still unknown:** the full status-key list (designed around, §6.1), retry policy, settlement/commission data, and the `customizations` schema. Also unknown: whether an existing dashboard item can get a `vendor_reference_id`. **→ §13 lists them. Each affected section says what it assumes.**

---

## 2. Non-negotiable principles

1. **A webhook is a nudge.** It tells the shop *which* order to look at. What the order *is* comes only from `GET /orders/{id}` made with the shop's own token. A forged, duplicated, reordered or misrouted webhook can at most cause one harmless fetch.
2. **Never lose an order.** A webhook is stored durably before we acknowledge it. Delivery to the shop is retried until acknowledged. A shop being offline can never fail Presto's request.
3. **Never deliver an order to the wrong shop.** Tenant isolation is enforced three times, independently (§4.4).
4. **The relay is a mailbox, not a broker.** It routes and stores. It never holds vendor credentials, never calls Presto for a shop, and never interprets an order.
5. **Status only moves forward.** Out-of-order events cannot drag an order backwards (§6.2).
6. **Presto prices are the invoice prices; Presto's fees are not the shop's revenue.** Delivery and service charges are recorded for reconciliation, never as sales.
7. **External references are adopted, never renamed.** Presto's upsert is keyed on `vendor_reference_id`, so renaming a ref creates a duplicate item. This is the same rule as "never auto-change a saved SKU".
8. **Arabic-first UI.** RTL tested, all copy through `AppLocalizations`.

---

## 3. Architecture

```
                         ┌──────────────── RELAY (multi-node, Postgres, Redis presence) ───────────────┐
 Presto ── POST ───────► │ /v1/hooks/presto/{endpoint_token}                                            │
  webhooks               │   1 auth (bearer secret, IP allow-list)                                      │
                         │   2 resolve binding  → (installation, vendor_id)                             │
                         │   3 validate envelope, vendor_id == binding.vendor_id   ─✗─► quarantine      │
                         │   4 INSERT channel_inbox (dedupe)  → 200                                     │
                         │                                                                              │
                         │ delivery worker (node holding the connector, via presence)                   │
                         │   SELECT … FOR UPDATE SKIP LOCKED → tunnel POST → mark delivered             │
                         └───────────────────────────────┬──────────────────────────────────────────────┘
                                                         │ connector tunnel (reserved /__pointy_support__ path)
                         ┌───────────────────────────────▼──────────────── SHOP BACKEND (Django) ───────┐
                         │ ChannelInbox (unique relay_inbox_id) ── 200 back to relay                    │
                         │   Celery: GET /orders/{id} with OWN token → check vendor.id → apply          │
                         │ ChannelOrder state machine ─► sales Order at handover ─► ChannelSettlement   │
                         │ Outbound: accept / reject / ready / items / availability ──► api.presto.ly   │
                         └───────────────────────────────┬──────────────────────────────────────────────┘
                                                         │ state version `channel_orders` + /api/state/
                                                   Tills: «طلبات التوصيل» board, alerts, printing
```

Existing building blocks reused:
- `apps/channels.SalesChannel`: the Presto channel is one row with `channel_type=delivery`. `Order.sales_channel` and the `sales_channel` list filter already exist.
- Relay `Hub.OpenStream` + Redis presence + node proxying, as `public_invoice.go` and diagnostics use them. The reserved `/__pointy_support__/` tunnel prefix, where the connector injects its own token and the public proxy can never reach.
- Relay Postgres store and migrations, and the integration kill switch (`relay_integration_switches`).
- `IntegrationAccount`'s `SecretStorageMixin` for credentials. `provider_for()` for the driver, so the kill switch applies.
- `apps/core/state_version.py` for till freshness.
- The `CardSettlement` / clearing-account pattern for settlement.
- The kitchen printer role, modifiers snapshot, and the returns desk.

---

## 4. Relay — webhook ingress and tenant routing (the pressure point)

### 4.1 The binding

New relay table `channel_bindings`:

| column | notes |
|---|---|
| `id` | uuid |
| `provider` | `presto` |
| `installation_id` | FK installations |
| `branch_key` | optional, for a multi-branch installation |
| `external_account_id` | Presto `vendor_id` (text) |
| `endpoint_token_hash` | sha256 of the 32-byte random token in the URL path |
| `webhook_secret_hash` | sha256 of the bearer secret we give Presto (optional layer) |
| `signature_scheme` | `none` (default) or a configured scheme (§4.2 step 3) |
| `signature_secret_enc` | the signing secret, encrypted (HMAC needs the raw secret, not a hash) |
| `seen_header_names` | header **names** observed on this binding's webhooks (discovery, §4.2 step 3) |
| `status` | `pending` → `active` → `suspended` / `revoked` |
| `verified_at`, `verified_by` | operator passkey approval (§4.5) |
| `created_at`, `revoked_at`, `revoked_reason` | |

Constraints:
- **Partial unique index on `(provider, external_account_id) WHERE status IN ('pending','active','suspended')`.** Two live bindings can never claim the same Presto vendor. This is the database-level guarantee behind "no order goes to the wrong shop".
- Unique `endpoint_token_hash`.
- The endpoint token is **not** the installation id, and nothing about it is guessable.

### 4.2 Ingress handler — `POST /v1/hooks/presto/{endpoint_token}`

**Each binding gets its own URL** (assumption, §1 gap 4): `https://<relay>/v1/hooks/presto/<endpoint_token>`, where the token is 32 random bytes, base64url. We hand that URL to Presto for that vendor at onboarding.
- **The path token is the routing key and a secret.** Only its hash is stored. It is shown once at binding creation, and an operator can re-issue it (revoke + new binding, with the URL re-sent to Presto).
- No integrator-wide endpoint is built. If Presto later turns out to accept only one URL per integrator, routing by `body.vendor_id` through the unique index is the fallback design. It is not built unless that happens.

Steps, in order. Each failure is answered **without** touching any shop:

1. **Size and shape:** body ≤ 256 KB, `Content-Type: application/json`, rate limit per token (relay `ratelimit` package). Over the limit → 413/429.
2. **Optional IP allow-list:** Presto's published egress IPs, if they give us a list (the docs mention whitelisting).
3. **Authenticate:** the path token already proves the caller knows this binding's secret URL. On top of that:
   - if Presto sends a per-vendor `Authorization: Bearer …` key we set, it is compared in constant time against `webhook_secret_hash`;
   - if Presto adds an HMAC signature, it is verified here too.

   Each extra layer is **enforced once observed**: a binding that has received an authenticated request refuses unauthenticated ones afterwards, so it can never be quietly downgraded. Failure → **401**, logged and counted, never stored.

   **Signature: a placeholder, off until Presto documents it (decided 2026-10-14).**
   - **The slot.** A relay `WebhookVerifier` interface, `Verify(req, rawBody, binding) → ok | reject | not_configured`, called at this step for every request. It ships with two implementations:
     - `none`: the default; returns `not_configured`, so requests pass.
     - `hmac`: generic and **configured, not coded**, covering the common schemes: header name; algorithm (`sha256` / `sha1` / `sha512`); encoding (`hex` / `base64`); optional prefix (e.g. `sha256=`); signed payload (`raw body` or `{timestamp}.{body}` with a timestamp header and tolerance window).

     Enabling it for a binding is a console/CLI action (`pointy-relay channels signature set <binding> --scheme hmac --header … --secret …`). No release is needed for any standard HMAC.
   - **The raw body is kept as received.** The handler reads the exact bytes **before** JSON parsing, and stores a hash of them. Re-serialized JSON would never verify.
   - **Discovery.** For every webhook, the relay records the request's header **names** (never values) into `seen_header_names`, and alerts once when a name appears that looks like a signature (`*signature*`, `*hmac*`, `x-hub-*`, `x-*-sig*`) on a binding still at `none`. If Presto is already sending a signature, we learn its header name without asking.
   - **Tests** pin the slot: a fixture binding configured with each scheme variant accepts a correctly signed body and rejects a tampered one, so the day it is needed only the parameters are new.
   - **Retries need nothing.** Whatever Presto's retry policy turns out to be, the durable insert + dedupe (steps 7–8) absorb duplicates, and the nudge rule makes order irrelevant. The policy only matters for how long an outage can last before an order is lost (§13 Q3).
4. **Resolve the binding** by token hash. Unknown, or `revoked` → **404**. `suspended` → **store and hold** (step 6) but do not deliver.
5. **Validate the envelope:** `event` is a string, `body` is an object, `body.vendor_id` is present and `body.order_reference` is present. An unknown event name is still stored, flagged `unknown_event`, never delivered, and raises an operator alert (Presto added something).
6. **Cross-check:** `body.vendor_id == binding.external_account_id`. A mismatch → write to **`channel_quarantine`**, alert the operator, answer **202**, never deliver. (202 rather than 4xx: we have recorded it durably, and a 4xx may cause a retry storm.)
7. **Durable insert** into `channel_inbox`:
   `id, binding_id, installation_id, event, order_reference, body jsonb, dedupe_key, received_at, state='pending', attempts=0, next_attempt_at=now()`.
   `dedupe_key = sha256(binding_id ‖ event ‖ canonical_json(body))` with a unique index (rows kept ≥ 7 days). Same event and same body again → `ON CONFLICT DO NOTHING`, answer 200.
8. **Answer 200 only after the commit.** If the database is unavailable, answer **503** so Presto retries. The handler **never** calls the shop synchronously.

Logging: event, order_reference, binding id, outcome and latency. **Never** the customer name or body contents (PII stays in the inbox row only).

### 4.3 Delivery to the shop

- **Who delivers:** the node that holds the installation's connector (Redis presence). Any node can claim work, using the existing remote-node proxy when the connector sits elsewhere.
- **Claiming:** `SELECT … FROM channel_inbox WHERE installation_id=$1 AND state='pending' AND next_attempt_at<=now() ORDER BY received_at FOR UPDATE SKIP LOCKED LIMIT 50`. Two nodes cannot deliver the same row at once.
- **Triggers:** (a) right after insert, if the connector is online; (b) **on connector connect**, flushing the backlog; (c) a periodic sweep every 5 s as a safety net.
- **Transport:** a tunnel request to the reserved path `/__pointy_support__/api/channels/inbox/`. The connector injects its connector token. This is the same mechanism as diagnostics, and the public proxy can never reach the path. Payload: `relay_inbox_id, binding_id, provider, external_account_id, event, body, received_at`.
- **Shop acknowledgement:** the backend inserts into its own `ChannelInbox` (unique `relay_inbox_id`, so a redelivery is a no-op) and answers 200 **after commit**. Only then does the relay mark the row `delivered`.
- **Retries:** exponential backoff capped at 30 s while the connector is online. While it is offline, rows simply wait for the connect trigger.
- **Order of delivery:** FIFO per installation is best effort. Correctness does **not** depend on it, because the shop re-fetches (§5.2) and status only moves forward (§6.2).
- **Retention:** delivered rows are kept 7 days (dedupe window, audit). Rows still undelivered after **7 days** become `dead` with an operator alert. They are never silently dropped.

### 4.4 The three locks (tenant isolation)

| Lock | Where | What it checks | What it alone prevents |
|---|---|---|---|
| 1. Binding | relay | the secret URL path token (+ bearer key / signature when Presto provides them) selects exactly one binding, and `vendor_id` must equal the binding's | routing by guessable ids; a vendor's events reaching any other binding |
| 2. Shop binding check | shop backend | `binding_id` **and** `external_account_id` in the delivery must equal this shop's `ChannelAccount.relay_binding_id` and `vendor_id`. Otherwise **409** → relay quarantines | a relay bug or bad data sending a row down the wrong tunnel |
| 3. Source of truth | shop backend → Presto | `GET /orders/{id}` with **this shop's** token must succeed **and** return `vendor.id ==` this shop's vendor | a forged or misrouted nudge creating anything. Another vendor's order is unreadable with this token (**assumed: Presto's own isolation is Presto's responsibility**, §13 Q9), and `vendor.id` is checked anyway, so even a Presto-side leak is refused here |

Tests must prove each lock **alone** stops a cross-tenant event (§12).

### 4.5 Binding lifecycle and proof of ownership

A shop must never be able to claim another shop's `vendor_id` by typing it in.

1. **Shop requests a binding** through the installation-scoped relay route (the installation's own `X-Pointy-Relay-Token`, never the admin token). Pattern: `POST /v1/installations/{id}/channel-bindings {provider, vendor_id, branch_key}`. If another live binding holds that vendor, the request is refused.
2. The relay creates it as **`pending`** and returns, **once**, the endpoint URL + webhook secret. The shop stores the secret encrypted, for re-display to the owner. Deliveries are **held** while the binding is pending.
3. **Proof:**
   - **Operator approval** in the relay console (passkey, a single tap), against what the Presto partner manager confirmed at onboarding. Onboarding goes through Presto anyway.
   - **Automatic confirmation:** the shop's own token fetches the first order and `vendor.id` matches. A mismatch **suspends** the binding automatically and alerts.
   - If Presto gives us a vendor-identity endpoint (§13 Q10), it replaces the operator step.
4. **Active:** held rows are delivered.
5. **Moving servers** ([[server-move-export-import]]): same installation id → no change. **Moving the vendor to a different installation** is an operator action: revoke the old binding, then create the new one. Never two live bindings.
6. **Revoking** stops delivery immediately. Undelivered rows stay for audit.

### 4.6 Failure modes

| Failure | Behaviour | Shop impact |
|---|---|---|
| Shop offline (power, internet) | Rows wait; flushed on reconnect. In **primary mode**, after an order has waited **60 s** undelivered (the accept window is ~5 min, so 3 min would leave almost nothing), the relay texts the owner via Resala: «دفتر: طلب بريستو بانتظار القبول ونظامك غير متصل — اقبله من جهاز بريستو». **On by default in primary mode, off in mirror mode, owner can switch it off.** At most **one SMS per outage** (rate limit 1 per 30 min per binding), charged per part from the wallet. Also shown on the relay console. | The shop works the order on the Presto tablet. Pointy catches up on reconnect and invoices on handover. |
| Relay node dies mid-request | The insert either committed (200 sent or not; Presto retry dedupes) or did not (Presto retries). | none |
| Whole relay unreachable | Presto retries (policy unknown, §13 Q2). An order whose every webhook is lost is not in the index. | Recovered by any later event, by the settlement statement, or by manual import by number (§4.8). The Presto tablet covers live service. |
| Shop lost data (restore, move, processing bug) | — | The reconcile job rebuilds every order from the relay index (§4.8). |
| Relay DB down | 503 → Presto retries. | none, if Presto retries |
| Duplicate webhook | dedupe_key → 200, no row. | none |
| Out-of-order events | delivered as they come; the shop re-fetches the truth. | none |
| Forged webhook | fails at lock 1 (secret); at worst lock 3 finds no order. | none |
| Wrong vendor_id in body | quarantined at lock 1, refused at lock 2. | none |
| Presto API down when the shop re-fetches | the inbox row stays `pending_fetch`, retried with backoff. The board shows a «بانتظار تفاصيل الطلب» placeholder from the nudge. | delayed detail |
| Token expired | refresh with stored credentials. If that fails → banner «انتهت صلاحية ربط بريستو» + owner notification. | blocks actions until fixed |

### 4.7 Observability and the kill switch

- **Relay console page per binding:** status, last webhook received, inbox depth (pending / held / dead), quarantine count, auth failures (24 h), last delivered.
- **Alerts (ntfy):** any quarantine; dead rows; pending rows older than 60 s while the connector is online (a delivery bug); auth-failure spike; unknown event names.
- **Kill switch:** `pointy-relay integrations disable presto` (existing switch). The shop's driver from `provider_for()` refuses outbound calls. The **relay keeps ingesting and storing**, so no order is lost while the switch is off. The runbook says: work on the Presto tablet.

### 4.8 The relay order index: Pointy's list of every Presto order

Presto has no list-orders endpoint. The relay is the one place that sees every order reference a shop is sent, so **it keeps the list** (owner's design, 2026-10-14).

**Table `channel_order_index`** (relay Postgres):

| column | notes |
|---|---|
| `binding_id`, `order_reference` | primary key |
| `seq` | bigserial: a monotonic cursor |
| `first_seen_at`, `first_event` | usually `order_created`, but **any** event teaches us the ref |
| `last_event`, `last_event_at`, `event_count` | |

- **Upserted in the same transaction as the inbox insert** (§4.2 step 7). An order can never be in the inbox but missing from the index. Every event moves `seq` forward, so "changed since my cursor" catches status changes too.
- **Holds no personal data:** refs, event names and timestamps only. That is why it can be kept **long: 400 days**, which covers a full year's audit and settlement disputes. Inbox bodies (which carry customer names) still expire at 7 days.
- Kept after a binding is revoked (audit). Readable only by that binding's installation, and by the operator.

**Shop API** (installation-scoped token, like the other self-service routes; never the admin token):
`GET /v1/installations/{id}/channel-bindings/{binding}/orders?after_seq=…&limit=500` → `{orders:[{order_reference, first_seen_at, last_event, last_event_at, seq}], next_seq}`. A binding owned by another installation answers 404.

**Shop reconciliation job** (`channels.reconcile_order_index`):
- **When:** on every connector reconnect; every 10 min; nightly; and after a backup restore or server move (§ below).
- **What:** walk the index from the stored cursor. For each ref, compare against the local `ChannelOrder`:
  - **missing locally** → fetch from Presto and apply (the normal §5.2 path, so locks 2–3 apply);
  - **present, but the relay's `last_event_at` is newer than our last applied event** → re-fetch and apply.
- **Pacing:** backfill fetches are paced (≤ 2/s) so a long outage never floods Presto.
- **The completeness metric:** *orders the relay knows that the shop does not* should always be **0**. The health panel shows it, and the relay console alerts when it stays above 0 for more than 15 minutes while the shop is online.

**Restore and move.** A shop restored from yesterday's backup has lost today's channel orders. Reconcile with `after_seq` = the cursor saved in the backup (or `0` for the last 400 days) rebuilds them from Presto. Side effects of states already passed are replayed with the **event's own time**: an invoice for a handover at 14:05 is dated 14:05, not "now". If that falls in a closed period, it is flagged for the owner instead of written.

**What the index cannot know: orders whose webhook never reached the relay** (relay unreachable past Presto's retries, or Presto never sending). Backstops, in order:
1. **Relay availability first:** the webhook path depends only on the relay's Postgres (no Redis, no shop, no tunnel), runs on every node, and is load-balanced, so it is up whenever any node is.
2. **Any later event recovers it.** A missed `order_created` followed by `order_accepted`/`order_picked_up`… puts the ref in the index anyway.
3. **Settlement closes the books.** Presto's statement lists the orders it pays for. Any statement ref not in Pointy is fetched by ID and imported (§7.3). Nothing paid can stay unrecorded.
4. **Manual import by number.** «إضافة طلب برقمه» on the board fetches any Presto order number off the tablet.

---

## 5. Shop backend

### 5.1 Models (in `apps/channels`, provider code under `apps/channels/presto/`)

- **`ChannelAccount`**: one per connected store.
  - `sales_channel` (1:1 with `SalesChannel`), `provider`, `external_account_id` (vendor_id), `branch`, `relay_binding_id`.
  - Encrypted secrets (API email + password, current token + expiry, webhook secret for display).
  - `mode` (`mirror` | `primary`), `accept_window` (default 5 min), `auto_accept` (+ conditions), `settlement_mode` (§7.4), `clearing_account` (FK MoneyAccount, kind CLEARING), `commission_rate` (expected, %, **default 25%**: the rate Presto is understood to charge shops; confirm per contract, §13 Q7), `default_price_mode`, `availability_buffer`.
  - `status` (`connecting` / `live` / `paused` / `error`) and `last_error`.
- **`ChannelInbox`**: `relay_inbox_id` (unique), `account`, `event`, `order_reference`, `body`, `received_at`, `state` (`received` → `fetched` → `applied` | `rejected_binding` | `failed`), `attempts`, `last_error`.
- **`ChannelOrder`**: the external order and the board's unit.
  - `account`, `external_id` (unique per account), `print_order_number`.
  - `status` (§6), `status_rank`, `presto_status_key`, `delivery_method`, `is_pickup`, `payment_method`, `customer_name` (display only, no CRM record), `pickup_otp`/`return_otp`.
  - `subtotal`, `delivery_charge`, `service_charge`, `total`, `cash_amount`, `wallet_amount`.
  - Timestamps per state: `received_at`, `accepted_at`, `ready_at`, `driver_arrived_at`, `picked_up_at`, `completed_at`, `cancelled_at`.
  - `accepted_by`, `pending_action` (+ attempt bookkeeping), `needs_attention` (+ reason codes), `sales_order` (1:1, nullable), `raw_snapshot` (the last GET).
- **`ChannelOrderLine`**: `external_item_id`, `order_item_id`, `presto_product_id`, `vendor_reference_id`, `name`, `quantity`, `unit_price`, `customizations` (raw + rendered text), `variant` (FK, nullable until mapped), `listing` (FK).
- **`ChannelOrderEvent`**: an append-only trail (event, source = webhook | our_action | refetch, from → to, at, by). It feeds the document-trail sheet.
- **`ChannelCustomer`**: `account`, `external_customer_id` (unique per account), `customer` (FK, re-pointed on merge), `last_seen_name`, `first_order_at`, `last_order_at` (§7.2).
- **`ChannelListing`** (§8).
- **`ChannelCategoryMap`**.
- **`ChannelSettlement`** + **`ChannelSettlementLine`** (§7).

Every non-nullable column added to an existing table uses `db_default` (zero-downtime update rule).

### 5.2 Processing an inbox row (Celery, per account, serialized)

1. **Lock 2:** binding and vendor match, or `rejected_binding` + 409 back to the relay.
2. `GET /orders/{order_reference}` with the account's token. **Lock 3:** `vendor.id` matches, or mark `failed` + alert (never apply).
3. Upsert the `ChannelOrder` and lines from the **fetched** record, and resolve each line's variant (§8.6).
4. Compute the target status from **both** the fetched `status.key` and the event name (§6.1). Apply it only if its rank is higher (§6.2). Record a `ChannelOrderEvent`.
5. Run the side effects of the state entered (alert, print, invoice, waste prompt…), each idempotent and keyed on the order and the state.
6. Bump state version `channel_orders`.

### 5.3 Outbound actions (accept / reject / ready)

Unlike HD Box, Presto's actions are **guarded by Presto's own state**. A second accept answers 400 "cannot be accepted in its current state". So retries are safe, as long as we reconcile by re-fetching:

1. The request takes `select_for_update` on the `ChannelOrder`. It checks the precondition (e.g. status `received` for accept) and that no `pending_action` is set, then records `pending_action=accept` and commits. Two cashiers tapping at once: the second gets «تم القبول من جهاز آخر».
2. Call Presto with a 10 s timeout.
   - **200** → apply the target status.
   - **400 / timeout / 5xx** → `GET /orders/{id}`. If Presto already shows the action → success. Otherwise retry in the background with short backoff (1 s, 2 s, 4 s…) **only until the accept window closes**, and show «جارٍ الإرسال…». If the window has under 60 s left and the accept is still unconfirmed, raise a red «لم يتأكد القبول — اقبله من جهاز بريستو» on every device.
3. Clear `pending_action` and bump the state version.

**Reject** asks for a reason from `GET /cancel-reasons` (cached daily, shown in Arabic as Presto provides them).

**Reject is always whole-order. `items` names the culprits.** The design reads Presto's `items` on reject the way Uber Eats defines the same shape: its Deny Order rejects the **whole** order, with optional `out_of_stock_items` / `invalid_items` arrays that **name the items causing it**. Partial fulfilment is a separate flow there (Resolve Fulfillment Issue), and on Deliveroo (amendments), never a reject. So:
- When the chosen reason is stock-related, the reject sheet asks «ما الأصناف غير المتوفرة؟». It preselects the lines Pointy already sees as short, and sends them as `items[{id}]`.
- **Pointy itself marks those listings unavailable** (86) and pushes availability (§8.7). The next customer cannot order them again, **whatever Presto does with the list**, so nothing depends on Presto's undocumented semantics.
- We **never** treat a reject as a partial fulfilment. If Presto later documents an amend/partial flow, it becomes its own action, not a variant of reject.

### 5.4 Credentials

- The owner enters the **API email and password Presto issued**. We mint a token named `daftar-<installation>` with expiry at the maximum Presto allows, and renew it at two-thirds of its life. The password is kept encrypted only because renewal needs it. If Presto offers long-lived tokens (§13 Q11), we drop the password.
- **Calls go shop → `api.presto.ly` directly.** The token never leaves the shop. If Presto requires *our* egress IPs to be allow-listed, on-prem shops with dynamic IPs would break. In that case the outbound calls go through a relay egress proxy that **forwards without storing** the token. Decided by §13 Q8.

### 5.5 Freshness at the till

New state-version domain **`channel_orders`**. Tills already poll `/api/state/` while idle, so a new order shows within seconds. While the board is open, or the account is in `primary` mode, the till polls the state endpoint at 2–3 s.

**Latency budget.** With ~5 minutes to accept before Presto auto-cancels, every second of pipeline delay is taken from the cashier.
- **Target:** Presto's webhook → visible, ringing card on the till in **≤ 15 s at p95**. That covers relay insert, tunnel delivery, Presto fetch, state bump and the till poll.
- Each `ChannelOrder` records the gap `received_at(relay) → fetched_at → first_seen_by_till_at`.
- The health panel shows the p95. Over **30 s**, it alerts the operator: a slow pipeline is a lost-orders bug, not a performance nicety. SSE (`apps/core/streaming.py`) is the upgrade path if polling proves slow. The till always re-fetches through the normal permission-checked endpoint (versions only, never payloads).

---

## 6. Order workflow

### 6.1 States

| Pointy status | Arabic label | Entered by | Rank | Side effects |
|---|---|---|---|---|
| `received` | طلب جديد | `order_created` (+ fetch) | 10 | Loud repeating chime + banner on every till with permission. **Countdown from Presto's `created_at`** (not our receipt time) against the account's `accept_window` (default **5:00**). Amber under 2:00, red under 1:00. **Escalation:** unaccepted after 2:00 → chime on *every* device of the shop (manager/owner apps too) + push notification. Auto-accept check (§6.4). |
| `accepted` | قيد التحضير | our accept, or `order_accepted` (accepted on the tablet) | 20 | Print the kitchen chit (kitchen printer role) and a packing slip. Start the prep timer. Reserve stock (§8.7). The ticket shows «عميل متكرر — الطلب رقم N» when the Presto customer has ordered before. |
| `ready` | جاهز للاستلام | our ready, or `order_ready` | 30 | Chime on the board. For a pickup order: «بانتظار العميل». |
| `driver_arrived` | وصل السائق | `driver_arrived_at_vendor` | 40 | Chime. Show the driver/pickup OTP if present. |
| `out_for_delivery` | خرج للتوصيل | `order_picked_up` | 50 | **Handover → issue the invoice (§7.2).** Stock leaves. Reservation released. |
| `delivered` | تم التوصيل | `order_completed` | 60 | Terminal. Record `cash_amount`/`wallet_amount` for settlement. |
| `collected` | تم التسليم | pickup order: `order_completed`, or the cashier's «تم التسليم» after OTP check | 60 | Terminal. Issue the invoice if not already issued. |
| `rejected` | مرفوض | our reject | 90 | Terminal. No invoice. |
| `cancelled` | ملغى | `order_cancelled` | 90 | Terminal. See §6.3. |
| `returned` | مُرتجع | `order_returned` | 95 | Terminal. See §6.3. |

"Preparing" and "accepted" are one state, because Presto has nothing between accept and ready. **«تم التحضير» on the board is the ready action** and calls `POST /orders/{id}/ready`. The ready button only shows when the fetched `can_mark_as_ready` is true.

**The full status-key list is unknown, and the design does not need it.** The webhook **events** name every state we act on (accepted, ready, driver arrived, picked up, completed, cancelled, returned), so **events drive the state machine**. `status.key` from the fetched order is used only to confirm and reconcile (e.g. after a missed event).
- Every distinct `status.key` ever seen is recorded with a sample order, the same discovery idea as the webhook header names.
- A new key raises one operator alert, so the map in `presto/status_map.py` is completed from real traffic.
- An unmapped key never moves the status.

**Timed out = a missed order, and that is a metric.** An `order_cancelled` arriving while the order is still `received` (we never accepted) is recorded as **`missed`** («فائت — انتهت مهلة القبول»), a distinct cancel reason. The board's day summary and the dashboard show **missed orders: count and value per day**. That number tells the owner what slow acceptance costs, and it is the strongest argument for auto-accept (§6.4).

### 6.2 Forward-only rule

An update applies only when `new_rank > current_rank`. Terminal states (ranks 60/90/95) can replace each other only in one direction: `delivered` → `returned`.

Effect: `order_ready` arriving after `order_picked_up` is ignored. A late `order_created` cannot reopen a delivered order. A duplicate event is ignored.

### 6.3 Cancellations and returns by stage

| When | What Pointy does |
|---|---|
| Before accept (customer, support, timeout) | Close the ticket. Nothing to undo. |
| After accept, before handover | Close the ticket and release the reservation. Ask «هل تم تحضير الطلب؟»: **yes** → record a waste/loss stock adjustment for the lines (recipes explode to ingredients); **no** → nothing. No invoice ever existed, so revenue is untouched. |
| After handover (`order_returned`) | The invoice exists. Open the returns-desk flow pre-filled: goods back to stock (packaged) **or** write-off (food). The refund goes back through the `channel` method into the clearing account (§7.3), so the next settlement nets it. Whether Presto still pays for a failed delivery is a settlement question (§13 Q7). |
| `order_updated` before handover | Re-fetch and replace the lines. If it was already printed: print a «تعديل طلب» chit and flag `needs_attention`. Adjust the reservation. |

### 6.4 Auto-accept (primary mode only, off by default)

Accepts automatically only when **all** of these hold:
- every line is mapped to a variant;
- every line is available after reservations;
- the shop is within its opening hours;
- the account is not paused.

Any failing condition leaves the order for a human, with the reason shown («صنف غير مربوط», «الكمية غير متوفرة»). **Never auto-reject.**

### 6.5 Mirror vs primary mode

- **Mirror:** the Presto tablet stays the place staff accept and mark ready. Pointy shows the board read-only, follows events, prints on accept, invoices at handover and settles. This is the safe first rollout: the relay pipeline proves itself while the tablet remains a fallback.
- **Primary:** actions are enabled in Pointy, plus alerts and optional auto-accept. The tablet stays as a backup.

---

## 7. Money: invoices and settlement

### 7.1 Who owes what

For a Presto order the shop is paid **by Presto**, not by the customer. Presto collects cash or wallet money from the customer and keeps the delivery charge, the service charge and its commission. So:
- **Shop revenue = items at the prices Presto charged** (`ChannelOrderLine.unit_price`). These may differ from POS prices, by design (§8.5).
- `delivery_charge` / `service_charge` are recorded on the `ChannelOrder` for reconciliation and are **never** invoiced as shop revenue.
- **Presto owes the shop** the invoice total, less commission and adjustments, on Presto's payout cycle.

### 7.2 The invoice (at handover)

**Why handover is the correct moment.** A sale happens when the goods leave the shop's custody, and that is the handover:
- **Accepting is a promise, not a sale.** Nothing has left the shop. An order cancelled after accept never was a sale. Recording it as a sale and then voiding it would put a sale in the books that never happened, and a void that undoes it.
- **Food prepared for a cancelled order is waste.** It is not a returned sale, so it is booked as waste (§6.3).
- **Stock really leaves at handover.** The driver or customer takes custody. Between accept and handover the goods are *promised* but still on the shelf, and the reservation (§8.7) records exactly that: it keeps the counter and Presto from selling the same last unit twice.
- **After handover, failure is a return.** If a delivery fails and comes back (`order_returned`), goods that left and came back are a return of a real sale, booked through the returns desk.

**One condition, from Presto's terms (§13 Q7):** handover is correct because the shop's part ends there. Presto's driver takes custody, and Presto carries the delivery. If Presto's contract instead makes the **shop** carry the risk until the customer receives the order (no payment for failed deliveries, for reasons outside the shop's control), the correct revenue moment becomes **delivery** (`order_completed`). Stock would still leave at handover, as goods in transit. Confirm with Presto before phase 2; the trigger is one constant in the state-entry side effects.

Two separate questions, answered separately:
- **Who bought it** → the invoice's `customer` is the **real end customer**, so purchase history, RFM segments and "top customers" keep working.
- **Who owes the money** → **Presto**. The invoice is paid at handover by a payment held in a Presto clearing account (§7.3), so the customer's balance stays clean.

**The customer.** Presto gives a stable `customer_id` and a name, but no phone or address.
- `ChannelCustomer` maps `(account, customer_id)` → a Pointy `Customer`. The first order from a new Presto customer creates one with `is_auto_created=True` and Presto's name. This is the **same placeholder mechanism payment cards already use**: hidden from the contacts list until a person names (claims) it or merges it into an existing customer.
- **Merging** re-points the `ChannelCustomer` row, so future Presto orders from that person land on the merged customer. This is how the owner joins «أحمد on Presto» to the Ahmed who also walks in.
- **Never auto-merge.** Without a phone there is nothing reliable to match on, and two «محمد» are two people.
- The name is refreshed from each order (`last_seen_name`) while the customer is still a placeholder. Once a human has edited the name, it is never overwritten.
- No phone → no SMS marketing to these customers. The CRM already skips customers with no phone. If Presto ever exposes a phone (it is personal data they may not share), it slots in here.
- A customer can be both: a walk-in who also orders on Presto shows **one history across both channels** after a merge, with each invoice badged by channel.

`issue_channel_invoice(channel_order)`:
- A **standard sale** to that customer, paid in full by one `Payment` with new method **`channel`** («عبر قناة بيع») into the account's **Presto clearing account**. It is never a drawer payment, and `ShopSettings.payment_method_enabled` does not offer it at the till (like `salary_deduction`).
- `sales_channel` = the Presto channel, **stamped by the service**, never from client input. `register_session` = none: no drawer cash moved. This is the one deliberate exception to "every sale names a drawer session". The invoice names the user who accepted the order (or «تلقائي»).
- Prices come from Presto's fetched order, a server-side trusted source. The discount engine is not applied (Presto's price is final). Cost and stock are the normal path, so margin reports work unchanged.
- **Idempotent:** `ChannelOrder.sales_order` is 1:1. A second handover event finds it already set.
- **Unmapped lines** use a per-provider fallback service product (`CHAN-PRESTO`, same idea as `INTEG-<KEY>` in integrations), so the invoice can always be issued. The order is flagged «صنف غير مربوط». Mapping it later re-points future orders. That invoice's stock is fixed through the normal correction route.

### 7.3 The Presto clearing account and `ChannelSettlement`

**Clearing account.** On connect, the shop gets a `MoneyAccount` of kind `CLEARING` («مستحق من بريستو»), tied to the `ChannelAccount` and settling into the bank Presto pays. Its claim rule is **`method = channel AND money_account = this clearing`**. Channel payments are always tagged explicitly, so the card rule's untagged/window logic does not apply. `claim_q` grows a channel branch; the card branch is unchanged. The treasury shows its balance as money owed by Presto. As with card clearing, transfers out of it are refused: only a settlement moves money out.

**`ChannelSettlement`** is a document, born submitted, cancelled by exclusion, with custom permission `channels.cancel_channelsettlement`.
- Header: `account`, `period_from/to`, `statement_reference`, `received_into` (a bank `MoneyAccount`, or the treasury cash box), `amount_received`, `received_at`, attachment (Presto's statement).
- Lines: one per settled channel **payment**: `payment`, `order`, `gross` (payment amount), `commission`, `adjustment` (+ reason), `is_live`. **Partial unique index on `(payment) WHERE is_live`**: a payment can never be settled twice.
- **Money on submit:**
  - the bank gains `amount_received`;
  - the clearing account loses `Σ gross`;
  - the difference `Σ gross − amount_received` is booked as **`channel_commission_total`**, broken into commission and adjustments.
- The customer and the invoice are untouched by settlement. The invoice was already paid at handover.
- `channel_commission_total` is registered in the money-definitions guard as the **one definition** read by profit/costs, the dashboard and the expense ledger, like `settlement_fee_total`. **Decided 2026-10-14: commission is a selling expense** («عمولة بريستو»). Gross sales are reported in full and never netted.
- **Estimated until settled.** At ~25% the commission is too big to appear only on payout day. Otherwise every month's profit would look 25% too good on Presto sales until Presto pays, and the month Presto pays would look bad. So the figure is **derived, not stored**:
  - *settled* channel payments → the **actual** commission from their settlement lines;
  - *unsettled* channel payments → **estimated** commission = `gross × commission_rate`, shown with the label «تقديري».

  When a settlement is submitted, its payments move from estimated to actual on their own: nothing to reverse, no accrual entry to forget. The gap (actual − estimate) is visible on the settlement as «فرق العمولة». A rate change only affects the estimate for still-unsettled payments, never a settled month.
- Invariants (randomized invariant test, oracle ops for submit/cancel):
  1. `amount_received + Σ commission + Σ adjustment == Σ gross`, exact to the cent.
  2. Each channel payment is settled at most once while live.
  3. Cancelling puts every payment back into the clearing account and removes the bank entry exactly.
  4. Delivery and service charges never appear in revenue.
  5. Clearing balance == Σ unsettled live channel payments, and no customer balance ever moves because of a Presto order.

**Returns after handover** (`order_returned`): the returns desk refunds through the same `channel` method into the clearing account. The refund is a negative held payment, so the next settlement nets it automatically and the customer is never shown owing anything.

**Settlement screen:** pick a period → Pointy lists delivered, unsettled Presto invoices, each with its *expected* net (`gross × (1 − commission_rate)`). The owner enters the amount received (or imports Presto's statement once its format is known, §13 Q7). Mismatches are shown per order: «في كشف بريستو وليس في دفتر» (one tap fetches it by number and imports it: the last backstop of §4.8) / «في دفتر وليس في الكشف».

### 7.4 Settlement modes (per account; confirm with Presto, §13 Q7)
- **`presto_remits`** (default): as above.
- **`driver_pays_at_pickup`**: if Presto drivers pay the vendor cash at pickup, the handover invoice is instead paid **in cash into the open drawer** of the device that marks the handover. It still names the same end customer. The Z-report counts it. Only commission settles later, as a payable to Presto.

---

## 8. Catalog mapping and sync

### 8.1 `ChannelListing`: the link table

| field | notes |
|---|---|
| `account`, `variant` | unique together (a variant is listed at most once per account) |
| `external_ref` | the `vendor_reference_id` on Presto. **Unique per account. Set once, never changed.** |
| `presto_item_id` | Presto's integer id, from list/orders |
| `link_state` | `linked` (we can write) · `linked_read_only` (matched, but Presto's item has no ref we can write to, §8.4) · `published` (created by us) · `unpublished` |
| `owns_name`, `owns_description`, `owns_image`, `owns_price`, `owns_availability` | which side is master per field (§8.5) |
| `price_mode` | `same` · `markup_pct` · `fixed`, with `price_value` |
| `unit` | the UoM sold on Presto (prices × factor, stock ÷ factor; divide by `unit_factor` at every read) |
| `dirty_content`, `dirty_availability`, `last_synced_at`, `last_error` | sync bookkeeping |
| `snapshot` | last known Presto values, for drift detection |

**`external_ref` format** for items we publish: `d-` + 10 random base32 characters. It is **not** the variant pk (pks change on re-migration) and **not** the SKU (owners edit SKUs, and duplicates exist). If an item already carries a ref from a previous system, we **adopt** it verbatim.

**`ChannelCategoryMap`:** Pointy category → Presto `category_ids`. Required, because Presto requires categories on create. Brands are optional.

### 8.2 Connect wizard — the four catalog situations

The wizard first pulls Presto's whole catalog (`GET /items`, all pages) and classifies.

**A. Presto catalog is empty (the easy case).**
Publish wizard → pick what to sell (§8.3) → map categories → preflight → push in batches of 100 → per-item result. Done.

**B. Presto has a catalog. Run the matching pipeline (§8.4) → review screen with five buckets:**

| bucket | meaning | owner's options |
|---|---|---|
| مربوط | confident 1:1 link | confirm all (default) / unlink |
| مقترح | likely match, needs a human | accept / pick another / reject |
| تعارض | one side matches several | resolve manually |
| في بريستو فقط | Presto items with no Pointy counterpart | **link manually** · **import into دفتر** (creates a product from Presto's name/price/barcode/image) · **leave unmanaged** |
| في دفتر فقط | Pointy items not on Presto | **publish** · **keep off Presto** (default) |

**C. Pointy has fewer items than Presto.** The surplus lands in «في بريستو فقط».
- *Import* is right when Pointy should own them from now on (stock, cost, reports).
- *Leave unmanaged* is right for things the shop never stocks (e.g. combos built only on Presto). Orders containing an unmanaged item invoice via the fallback product and are flagged, so nothing blocks.
- Deactivating on Presto needs a writable ref. Otherwise the owner hides the item in Presto's dashboard; the review screen says so.

**D. Pointy has more items than Presto.** This is normal: a grocery with 5,000 SKUs, or a restaurant whose ingredients are products. **Publishing is opt-in.** Nothing goes to Presto unless chosen. Bulk selection by category, in stock, has image, has price. A later «منتجات جديدة غير منشورة» nudge offers newly created products.

Mixed reality (some matched, some on each side) is just all buckets at once. The wizard can be re-run any time as **«مطابقة الكتالوج»**, and existing links are kept.

### 8.3 Preflight before any push
Per item:
- Arabic name present;
- price > 0;
- category mapped;
- image reachable at a public URL (§8.8);
- variants ≤ 10 per item and ≤ 1000 total, or else split them into separate listings;
- sold-by-weight items need a fixed pack unit chosen (Presto quantities are integers).

Failures are listed with the fix inline, never silently skipped.

### 8.4 Matching pipeline (deterministic first, suggestions last)

1. **Our refs:** a Presto `vendor_reference_id` already in our listing table → linked.
2. **Foreign refs** (set by a previous POS): try them against Pointy SKU / barcode / variant codes → **suggested**. On confirm, adopt the ref as `external_ref`.
3. **Barcode, exact:** normalize (digits only, GTIN-12↔13 leading zero, check digit valid). Must be **1:1 on both sides**. Otherwise → conflict.
4. **SKU, exact** (trimmed, case-insensitive). 1:1, else conflict.
5. **Name similarity:** Arabic normalization (alef forms, ta marbuta/ha, ya/alef maqsura, diacritics, tatweel) + trigram, reusing the product-search normalizer, with price proximity as a tiebreak. **Suggestions only, never auto-linked.**

Steps 3–4 auto-link only if the names also pass a loose similarity floor. A wrong barcode on one side must not silently join a juice to a phone charger; below the floor it is demoted to «مقترح».

**Writing to a matched item that has no ref** is the one hard gap. Presto's upsert and availability calls are keyed by `vendor_reference_id`, so we cannot address an existing dashboard item by its Presto id. In order of preference:
1. **Presto lets us set `vendor_reference_id` by Presto id** (§13 Q5). Then everything links fully.
2. **Presto applies a mapping file** we export (Presto id → our ref) once, at onboarding.
3. **Replace:** publish ours as new items and the owner hides the old ones in Presto's dashboard. This loses ratings, ordering and Presto-side photos, and the UI says so plainly.

Until 1 or 2 happens, such pairs are **`linked_read_only`**. Orders still map them (by Presto product id), so invoicing and stock work. Only price and availability pushes are blocked, shown as «مرتبط — للقراءة فقط».

### 8.5 Field ownership and prices
- **Availability and price: Pointy is master by default.**
- **Name, description and image are chosen per item. Decided 2026-10-14:**
  - items that **already exist on Presto** (matched) default to **Presto's** name, description and photo. Restaurants hand-craft marketing names there, and the till name is a short receipt name.
  - items **we publish fresh** use **Pointy's**.
  - the owner can flip any item later («اسم بريستو» / «اسم دفتر»).
- **Channel price:** `same` as POS, `+x%`, or a fixed override per listing. Delivery apps commonly price above the counter. The account default applies to newly published items.
- **«حافظ على هامشي» helper:** for the shop to net its counter price after a commission rate `r`, the Presto price must be `counter ÷ (1 − r)`. At 25% that is **+33.3%, not +25%**: a +25% markup still loses 6.25% of the counter price. The account's markup default offers this computed value, and the product form shows the net-after-commission next to the Presto price («صافي بعد العمولة»). It is a suggestion; the owner sets the price.
- **Drift:** the nightly reconcile compares `GET /items` against the snapshot. Fields changed on Presto that Pointy owns → listed as «تغيّر في بريستو» with *keep ours* (re-push) or *adopt theirs*. **Never fight silently**, never flip-flop.

### 8.6 Order line → variant resolution
In order:
1. `product.vendor_reference_id` → listing;
2. `presto_product_id` → listing;
3. barcode → unique variant (suggest, do not auto-link);
4. otherwise unmapped → fallback product + «اربط هذا الصنف» on the ticket. Linking from the ticket creates the listing for every future order.

`customizations` are stored raw and rendered as the line's note text on the chit and invoice until Presto documents the schema (§13 Q6). They are **not** mapped to Pointy modifiers yet.

### 8.7 Stock → availability
- `sellable = on_hand − reserved − buffer`, where `reserved` = lines of accepted, not-yet-handed-over channel orders (and quotation reservations if the shop uses them). `is_available = sellable ≥ 1` in the listing's unit.
- `stock.manage` + `quantity` is sent **only if** the owner opts in. Some shops do not want to expose counts. The default sends availability only.
- **Made-to-order / service / recipe items** have no stock to drive this. They are manual: «إيقاف مؤقت» (86) from the board or the product. Ingredient-driven availability is a later phase.
- **Triggers:** stock ledger writes mark listings `dirty_availability` on commit (cheap, no network). A worker every 20 s pushes **only transitions** in batches of 100. A full reconcile runs nightly. Presto failures back off and never block a sale.

### 8.8 Images
Presto wants a public `image_url`, and on-prem images are not public. On publish, the shop uploads the image to the relay's **public, content-addressed media store** (`/v1/public/channel-media/<sha256>`, unguessable, immutable, cacheable). That URL is sent to Presto. If Presto copies images on ingest (§13 Q12), we can expire them later.

---

## 9. Pointy surfaces (Arabic-first, RTL)

- **«طلبات التوصيل» board** (new route; Primary/Mirror badge):
  - Columns: جديد · قيد التحضير · جاهز · خرج للتوصيل. Done today is collapsed.
  - Cards: Presto order number, elapsed time / countdown, items + customizations, customer first name, توصيل/استلام badge, payment, OTP, attention flags.
  - Actions by state: قبول / رفض · تم التحضير · تم التسليم (pickup) · إيقاف صنف.
  - Dense, cashier-friendly, works at 1024×768.
- **«كل طلبات بريستو» list:** every order the shop ever received, searchable by Presto number, with status, totals, invoice link and the missed/cancel reason. It is complete because it is reconciled against the relay index (§4.8); the header shows «مطابق للمرحّل ✓» or the count still syncing. «إضافة طلب برقمه» imports any order by its number.
- **Global new-order alert:** a repeating chime + banner on every till with `channels.act_on_channel_orders`, until someone opens the order.
- **Invoices list:** channel filter chips (نقطة البيع · بريستو · …). The backend filter already exists. A channel badge on rows. «الطلب في بريستو» link on the invoice detail.
- **Reports:** sales by channel; Presto commission on profit and the expense ledger; «مستحق من بريستو» on the dashboard.
- **Shop settings → قنوات البيع → بريستو:**
  - connect wizard (credentials → binding → catalog matching → publish → go live);
  - health panel (binding, last order received, delivery lag, token expiry, last sync, errors);
  - options (mode, auto-accept, price defaults, buffer, settlement mode, expected commission).
- **Product form:** a «بريستو» section: listed?, channel price, owned fields, last sync state.
- **Settlement sheet:** a twin of the card-settlement sheet.
- Every screen gets a preview harness (`make frontend-presto-preview`, `?screen=board|new-order|matching|settlement|health|…`) per AGENTS.md.
- compat/win8: the board, alerts and filter are a later **frontend-only** port. That branch's backend is never touched.

## 10. Permissions
New, in the permission catalog (every checked permission listed):
- `channels.view_channel_orders`: cashier default.
- `channels.act_on_channel_orders` (accept/reject/ready/handover/86): cashier default.
- `channels.manage_channel_listings` (matching, publish, prices): owner/manager.
- `channels.manage_channel_account` (connect, credentials, modes): owner.
- `channels.view_channelsettlement`, `channels.add_channelsettlement`: reporting roles only.
- `channels.cancel_channelsettlement`: custom; owner.

---

## 11. Rollout

| Phase | Ships | Gate to next |
|---|---|---|
| **0. Presto onboarding** | contract, API credentials, per-vendor `serviceUrl` hand-off, sandbox access if offered. **No blocking questions remain**: §13 is ask-in-passing | pilot shop's credentials work against `api.presto.ly` |
| **1. Relay ingress + binding** | bindings, ingress, inbox, delivery, quarantine, console page, alerts, kill-switch wiring | chaos tests green (§12); 1 week receiving a pilot shop's live webhooks with zero misroutes / losses |
| **2. Mirror mode** | ChannelAccount, inbox processing, ChannelOrder + board (read-only), printing, handover invoices, channel filter, line mapping + fallback | 2 weeks: every delivered Presto order has exactly one invoice; totals match Presto |
| **3. Settlement** | ChannelSettlement, commission definition, reports | first real Presto payout reconciled to the cent |
| **4. Primary mode** | accept/reject/ready from Pointy, alerts, auto-accept | pilot runs a full week without the tablet |
| **5. Catalog** | matching wizard, publish, availability sync (availability first: highest value, lowest risk), drift reconcile, images | — |

---

## 12. Testing

- **Relay:**
  - property test: *no inbox row is ever delivered to an installation whose active binding does not own its vendor_id*, over randomized bindings, revocations, rebinding and multi-node claims;
  - each of the three locks tested **alone** with the other two disabled;
  - index/inbox atomicity: no inbox row without its index row, under concurrent duplicate webhooks;
  - index API scoping: another installation's binding answers 404;
  - duplicate/replay, out-of-order, oversized, bad auth, unknown event, DB-down (503), connector flapping, node death mid-claim (`SKIP LOCKED` lease);
  - Postgres-backed tests.
- **Shop:**
  - state machine table tests for every (state × event) pair, including forward-only;
  - outbound action reconciliation (timeout → refetch);
  - two cashiers accepting at once;
  - reconciliation: a dropped delivery, a lost processing step, a restore to an older backup, and a server move each converge to "relay knows = shop knows". Replayed invoices carry the event's own time, and closed periods are flagged rather than written;
  - idempotent invoice issue;
  - every cancellation stage.
- **Money:** randomized invariant test for `ChannelSettlement` (mutation-checked, like `HeldCardInvariantTests`); oracle operations for handover invoice, settle and cancel-settlement; query-scaling guards on the board and invoices list.
- **Catalog:** the matching pipeline on fixtures for all four situations (empty, fewer, more, mixed), Arabic normalization cases, barcode-collision demotion, preflight.
- **Fake Presto:** a small fake server (in-process for Django tests, standalone for relay e2e) implementing the documented endpoints and webhook sender, so CI never needs Presto's sandbox.
- Backend on **Postgres** (`make backend-test-pg`). Frontend widget tests in RTL + preview screenshots.

---

## 13. Questions for Presto

**Phase 1–2 (all resolved by design decisions on 2026-10-14; ask in passing):**
1. ~~serviceUrl scope~~ **Assumed (not blocking):** a per-vendor URL of our choosing, with a path token. *Confirm in passing:* that Presto stores the URL verbatim, including the path; and whether we can set the webhook `Authorization` key per vendor (an extra layer, not required).
2. ~~Webhook signature~~ **Not blocking (decided 2026-10-14):** ignored until documented or observed. The verifier slot + header discovery are built (§4.2 step 3). *Ask in passing:* the signature header, algorithm and secret, if any; the retry policy, timeout and attempt count.
3. ~~Recovery~~ **Not blocking (2026-10-14):** there is no list endpoint. The relay order index + shop reconciliation replace it (§4.8). *Ask in passing:* a `GET /orders?since=` would close the last gap (webhooks that never reached the relay), but the design does not wait for it.
4. ~~Statuses~~ **Not blocking (2026-10-14):** the timeout is ~5 min with auto-cancel (owner's knowledge; the account's `accept_window` is configurable). Events drive the state machine, and `status.key`s are discovered from traffic. Reject `items` is read as Uber's pattern: whole-order reject naming the culprit items (§5.3). *Confirm in passing:* the exact window, the full status list, and what Presto does with reject `items`.
9. ~~Isolation~~ **Assumed (2026-10-14):** a vendor's token cannot read other vendors' orders; that is Presto's job. Our `vendor.id` equality check (lock 3) refuses a leaked order regardless.

**Needed for settlement (phase 3):**
7. Payout cycle; statement format (API? CSV? PDF?); **confirm the 25% commission and its basis** (item subtotal? incl. charges? before or after vendor discounts? does it vary by category or contract?); who keeps delivery/service charges; how cash collected by drivers reaches the vendor (remitted vs paid at pickup); vendor-funded vs Presto-funded discounts; whether failed deliveries (`order_returned`) are paid.

**Needed for catalog (phase 5):**
5. Can we set `vendor_reference_id` on an existing item by its Presto id? If not, will Presto apply a mapping file at onboarding?
6. The `customizations` schema on orders. Can modifiers/options be created via the API?
12. Is `image_url` copied on ingest or hot-linked?

**Operational:**
8. Do *we* need allow-listed egress IPs to call the API? (On-prem shops have dynamic IPs.) What are Presto's webhook source IPs?
10. Is there a vendor-identity endpoint (`GET /me`) to prove `vendor_id` at binding time?
11. Maximum token lifetime; can a token be issued without us storing the password?
13. Rate limits; sandbox/test environment; store open/closed or "busy" control via the API.

---

## 14. Decisions for the owner

1. ~~Invoice at handover vs at accept~~ **Decided 2026-10-14: handover**, on correctness: that is when the goods leave the shop's custody (§7.2). It moves to delivery only if Presto's terms leave the transit risk with the shop (§13 Q7).
2. ~~Presto as an آجل party~~ **Decided 2026-10-14:** the invoice names the real end customer (auto-created per Presto `customer_id`, mergeable), paid by a `channel` payment held in a Presto clearing account. A Presto party would have erased customer tracking.
3. ~~Commission as an expense vs netted~~ **Decided 2026-10-14: expense**, default expected rate 25%, estimated on unsettled payments and replaced by actuals at settlement (§7.3).
4. ~~Default field ownership~~ **Decided 2026-10-14:** Pointy owns price and availability; matched existing items keep Presto's name and photo; freshly published items use Pointy's (§8.5).
5. ~~Owner SMS when offline~~ **Decided 2026-10-14:** on by default in primary mode only, one SMS per outage, owner can switch it off (§4.6).
6. **Pilot shop** for phases 1–4.
