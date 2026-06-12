# Operations Framework Plan (Job Engine)

**Status:** proposed — not yet implemented.
**Goal:** let Pointy serve phone repair shops, bakeries, restaurants, and light
manufacturing without building three separate modules. One job engine, one
workflow engine, one asset registry, one BOM engine — each industry is a
configuration, not a fork.

The guiding rule for every section below: **reuse the rails Pointy already
has** (inventory services, payments/orders, permissions, idempotency, audit
events, attachments, printing outbox, public tokens, sales channels) instead
of inventing parallel ones. A job that ends in money changing hands must end
in a normal `sales.Order`, so reconciliation, blind close, fraud sweeps, and
reporting keep working unchanged.

---

## 1. The shape: everything is a Job

```
Customer request → Job → materials consumed → labor → status tracking → delivery/sale → invoice
```

| Business     | Job type            | Number  |
|--------------|---------------------|---------|
| Phone repair | Repair order        | REP-1001|
| Bakery       | Production batch    | BAK-3001|
| Restaurant   | Kitchen order       | RST-4001|
| Manufacturing| Work order          | MFG-2001|

New Django app: **`apps.operations`** (jobs, workflow, materials).
BOM lives in **`apps.catalog`** (it describes products).
Customer assets live in **`apps.customers`** (they are customer property and
power the customer-history view).

---

## 2. Core schema

### 2.1 Workflow engine (DB-driven, no code per industry)

```
operations_workflowtemplate
  id, name, job_type (repair|production|kitchen|work_order|custom),
  is_active, is_default_for_type

operations_workflowstage
  id, template FK, code, name, display_order,
  is_initial, is_terminal,
  requires_customer_approval   # gate: quote must be approved to pass
  consumes_materials           # stock is decremented when entering this stage
  produces_output              # finished goods received when entering (production)
  notifies_customer            # future: portal/WhatsApp ping
```

Stages are an ordered list. Transitions are *recorded*, not hard-coded:

```
operations_jobstageevent
  id, job FK, from_stage FK null, to_stage FK, changed_by FK user,
  note, created_at
```

Rules enforced in a service (`apps/operations/services.py`), mirroring how
`sales/services.py` guards order adjustments:

- forward moves: anyone with `operations.change_job`;
- backward moves and skips: manager only (audited with WARNING severity);
- terminal stages lock the job (same append-only philosophy as orders);
- every transition emits `record_domain_event("operations.job.stage_changed", …)`.

Default templates are **seed data** (like the POS sales channel and default
variant options): one template per job type, editable in shop settings. The
initial-setup check in `core/roles.py` must treat seeded templates the same
way it treats the seeded POS channel.

### 2.2 Jobs

```
operations_job
  id, job_number          # "REP-20260612-000123" — same generation pattern as receipt_number
  job_type                # denormalized from template for filtering
  workflow_template FK (PROTECT)
  current_stage FK (PROTECT)
  customer FK null (customers.Customer, SET_NULL)
  assigned_to FK null (auth.User, SET_NULL)      # technician/baker/cook
  priority (low|normal|high|urgent)
  due_at, completed_at
  symptoms, diagnosis, technician_notes (Text)
  quoted_price, approved_price (Decimal, null)
  warranty_days (int, default 0)
  sales_channel FK null (channels.SalesChannel, PROTECT)   # stamped server-side, same rule as orders
  order FK null (sales.Order, PROTECT)                     # set at invoicing
  public_token (unique, null)                              # portal tracking, generated like Order.public_token
  created_by FK null
```

Key integrations:

- **Channel stamping:** `resolve_sales_channel(request)` at creation — a
  kitchen order arriving from a delivery app later is just a job whose
  channel came from that app's API key. Zero new auth code.
- **Idempotency:** job creation and stage transitions wrap in
  `run_idempotent_request` exactly like checkout.
- **Attachments (photos):** add `operations.job` and `customers.asset` to
  `POINTY_ATTACHMENT_ALLOWED_TARGETS`. Intake photos, diagnosis photos, and
  signatures are attachments — no new media plumbing.
- **Printing:** job intake ticket / claim ticket = a print job through the
  existing outbox (`apps.printing`), like receipts.

### 2.3 Assets (customer property; crucial for repair)

```
customers_asset
  id, customer FK (PROTECT), asset_type (phone|laptop|console|appliance|other),
  brand, model, serial_number, imei, color, notes, is_active

operations_jobasset
  job FK, asset FK            # almost always one, schema allows many
```

Device history = `asset.jobs` ordered by date. Surfaced on the customer
details screen (the contacts feature already shows per-customer sales
history; this adds a repairs tab).

### 2.4 Materials consumption

```
operations_jobmaterial
  id, job FK, variant FK (catalog.ProductVariant, PROTECT),
  quantity, unit_cost,            # cost captured via latest_sale_unit_cost, like OrderLine
  stock_movement FK null (inventory.StockMovement, PROTECT)
  consumed_at null
```

Consumption goes through the **existing inventory services** —
`lock_stock_item`, `save_stock_item_quantities`, `create_stock_movement`,
`consume_expiring_stock_batches` — the exact functions checkout uses today.
Movement note: `"مهمة REP-1001"`. Reversal on job cancellation mirrors the
return flow (INCREASE movement, audited).

Two consumption modes per workflow:
- **on-stage** (`consumes_materials` stage flag): bakery/restaurant — stock
  moves when the batch enters Mixing / the kitchen marks Preparing;
- **explicit** (technician adds parts as used): repair.

Overselling and `prevent_selling_at_loss` settings apply the same way they
do at checkout.

### 2.5 Invoicing — jobs end in normal Orders

When a repair is delivered or a kitchen order is paid, the service creates a
standard `sales.Order` (+ `OrderLine`s for parts/labor/menu items) through
`create_order_with_lines` / `checkout_order`, linked back via `job.order`.

Why this matters: payments, register sessions, **blind close**, refunds,
fraud sweeps, dashboards, and the new sales-channel stamping all continue to
work with zero changes. Labor is a service product (a `Product` flagged
non-stock — small catalog addition: `Product.is_service`, skips stock
checks), so labor revenue appears in profit reporting automatically.

---

## 3. Phase 2 — BOM / recipes (catalog)

```
catalog_billofmaterials
  id, variant FK (the output, PROTECT), name, output_quantity, is_active

catalog_bomline
  id, bom FK, component_variant FK (PROTECT), quantity, waste_percent
```

- **Bakery / manufacturing:** a production job references a BOM and a target
  quantity; the engine explodes lines into `job_materials` (target ×
  per-unit qty × (1+waste)). A stage flagged `produces_output` performs the
  **finished-goods receipt**: INCREASE stock movement for the output variant
  with unit cost = consumed component cost / output quantity. (Open
  decision: feed this cost into `purchasing.latest_variant_unit_cost` so
  margins on produced goods are honest — recommended.)
- **Restaurant:** same BOM, but the sale order line itself triggers recipe
  consumption at kitchen-complete; no finished-goods inventory. This is a
  per-template flag, not a new system.
- Routing (Mix → Bake → Cool → Package) is **already covered by workflow
  stages** — no separate routing tables until capacity planning (Phase 3+).

---

## 4. Permissions, roles, and the cash-trust boundary

- Standard Django perms per model, enforced through `HasPointyPermission`
  `permission_map`s like every other viewset.
- `MANAGER_PERMISSION_DOMAINS` += `"operations"` (and the new catalog/customers
  models ride along automatically).
- New **technician** role group: view/change jobs, add job materials, view
  catalog and own assignments — but *not* `reports.view_reportrun`, so the
  blind-close rule extends naturally: a technician sees their queue, never
  shop revenue.
- Custom perms where Django's CRUD verbs aren't enough, following the
  employees-app precedent (`approve_employeeloan`):
  `operations.approve_job_quote`, `operations.reopen_job`,
  `operations.assign_job`.

---

## 5. Customer portal (Phase 4)

Reuses the public-invoice machinery verbatim:

- `job.public_token` (`secrets.token_urlsafe`, generated like
  `Order.public_token`);
- `GET /api/public-jobs/<token>/` modeled on `PublicInvoiceView`: relay-gated
  (`request_is_relayed`), behind a new `ShopSettings.enable_job_tracking`
  toggle, exposing only stage name, ETA, and approved price — never internal
  notes;
- printed intake ticket carries `pointy.ly/track/REP-1001` as QR (printing
  templates already support QR for invoices).

WhatsApp/SMS notifications hang off `notifies_customer` stage flags through
the existing notifications app + Celery beat.

---

## 6. API surface (Phase 1)

```
/api/jobs/                       CRUD + filters (job_type, stage, assigned_to, customer, asset)
/api/jobs/{id}/transition/       POST {to_stage, note}        (idempotent)
/api/jobs/{id}/materials/        GET/POST consume / reverse   (idempotent)
/api/jobs/{id}/invoice/          POST → creates Order via checkout machinery
/api/assets/                     CRUD, filter by customer
/api/workflow-templates/         manager-only CRUD (settings page)
```

Flutter: a **Jobs board** feature (`features/operations/`) — Kanban-by-stage
on wide screens / list on phones, job details with stage timeline + parts +
photos, an intake flow (customer → asset → job) launched from POS or
contacts, and a workflow-template editor section in shop settings. All
screens use the centralized `AppNavigation` (new `operations` destination +
capability mapping) — the drawer refactor was a prerequisite for adding a
destination this large cleanly.

---

## 7. Delivery phases

| Phase | Scope | Backend | Frontend |
|-------|-------|---------|----------|
| **1 — Repair vertical** | workflow engine, jobs, assets, manual materials, technician role, invoicing into Orders, intake printing | `apps.operations`, `customers.Asset`, seed templates, `Product.is_service` | jobs board, intake flow, job details, customer asset history |
| **2 — Production** | BOM/recipes, production batches, finished-goods receipt, restaurant recipe-consumption flag | `catalog` BOM tables, explode/consume/receive services | BOM editor, batch screen, "produce" action |
| **3 — Planning** | reorder suggestions from BOM demand, batch scheduling, quality-check stages | MRP-lite services on existing reorder levels | planning screen |
| **4 — Customer-facing** | portal, QR tracking, WhatsApp pings, e-signatures on approval | public job endpoint, notification hooks | portal web page (relay), signature capture |

Each phase ships behind a shop-settings toggle ("Operations: repair /
production / kitchen"), so a pure retail shop sees nothing new.

---

## 8. Decisions to confirm before Phase 1

1. **Technician role** — new group as proposed, or fold into cashier?
   (Recommended: new group; cashiers do intake, technicians do work.)
2. **Stock reservation** — Phase 1 consumes immediately (matches current POS
   behavior); reservations (`committed` quantities exist on StockItem) can
   come later for "waiting parts".
3. **Produced-goods costing** — feed finished-goods receipts into the unit
   cost used by margin reports (recommended yes, slightly more work).
4. **Labor as service products** — confirm `Product.is_service` approach vs.
   free-form labor lines (service products keep reporting unified —
   recommended).
5. **Job editing rules** — orders are append-only; jobs need editing while
   open. Proposal: editable until a terminal stage, then locked, with all
   edits audited.
```
