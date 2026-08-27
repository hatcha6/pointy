# Pointy vs. ERPNext — Benchmark, Gap Register, and Improvement Plan

**Date:** 2026-08-26
**Mirror project:** [frappe/erpnext](https://github.com/frappe/erpnext) (+ the Frappe framework underneath it)
**Purpose:** use the most-scrutinised open ERP in the world as a checklist against our own model, decide
what is genuinely missing, and sequence the work. This is a *selective adoption* plan, not a
"catch up to ERPNext" plan — see §8 Anti-goals.

---

## 1. Why ERPNext is the right mirror — and where it misleads

ERPNext is worth studying because it has been beaten on by tens of thousands of real businesses for
15 years. Every one of its "boring" concepts (submitted documents, stock ledger entries, GL entries,
warehouses, credit limits, period locks) exists because somebody's numbers came out wrong without it.
That is the exact failure class our GTM thesis attacks in Libya: rivals whose fat clients write
straight to the DB produce accounting that quietly disagrees with reality.

Where the comparison misleads:

- **Different centre of gravity.** ERPNext is an *accounting system that grew operations around it*.
  Pointy is an *operations system with no ledger underneath it*. Copying its module list would bury a
  Libyan shopkeeper in configuration they will never do.
- **Different deployment reality.** ERPNext assumes a server admin, a chart of accounts, and a
  finance person. Our buyer is a shop owner with a generator, no billing rail, and a paper ledger that
  is the legally authoritative record.
- **Different client story.** ERPNext is a web app; its POS and its hardware/offline story are its
  two weakest areas — which happen to be our two strongest. Do not import their weaknesses.

**Thesis of this document:** steal ERPNext's *invariants and primitives*, not its *breadth*.

---

## 2. What was actually inspected (grounding)

Pointy, current `main`-ish tree:

- 25 backend Django apps (`backend/apps/*`), ~120 models, 1,953 backend test functions.
- 31 frontend feature modules (`frontend/lib/src/features/*`).
- Verified by reading models/services, not from memory:
  - No `Account` / `GLEntry` / `JournalEntry` / chart of accounts / fiscal year / cost center anywhere.
  - No `Warehouse` / `Location` / `Branch` model. `StockItem` is `OneToOneField(ProductVariant)` —
    **one stock bucket per variant, globally.**
  - No customer credit limit, no payment terms, no due-date schedule, no statements.
  - No tax model of any kind. Single currency (`ShopSettings.currency_code`, default LYD).
  - Costing: `OrderLine.unit_cost` is snapshotted from `latest_sale_unit_costs()` — i.e.
    **last purchase cost**, not FIFO and not moving average. Stock value = qty × last cost.
  - Stock history is `StockMovement` with denormalised `on_hand_before/after` — an audit trail, but
    not a valued ledger (no rate, no running value, no backdated reposting).
  - 9 fixed report types (`ReportRun.ReportType`); no user-definable reports.
  - Batches exist (`StockBatch`, expiry-driven); no serial-number tracking for stock.

ERPNext, `develop` branch (fetched, not recalled): modules `accounts, assets, buying, crm, edi,
maintenance, manufacturing, projects, quality_management, regional, selling, setup, stock,
subcontracting, support, telephony, utilities`. Doctype inventories pulled for `accounts/`, `stock/`,
`selling/`, `manufacturing/`.

---

## 3. Scorecard — where we are vs. where they are

| Domain | ERPNext | Pointy today | Verdict |
|---|---|---|---|
| **POS / cashier UX** | POS Profile, POS Invoice, opening/closing entry. Offline mode weak. | Full native POS: hotkeys, scan-first, modifiers, register sessions + Z-report, exchanges, kiosk price checker, thermal/label printing | **We win, decisively** |
| **Hardware & printing** | Browser print, no device layer | ESC/POS + TSPL + ZPL, USB/serial/network transports, label calibration, kitchen routing, print-hang guards | **We win** |
| **Deployment / ops** | Frappe Cloud (SaaS) or DIY bench | On-prem one-command, zero-config LAN discovery, fleet remote update + rollback, remote diagnostics, licensing/enrolment | **We win** |
| **Localisation (Arabic/RTL)** | Translations exist; RTL print is DIY | Arabic-first UI + Arabic PDF/receipt shaping, LYD money formatting | **We win** |
| **AI** | None in core | Agentic assistant, vision, voice, deep links, PO-from-invoice | **We win** |
| **Inventory basics** | Item, variants, UoM conversion, barcodes, reorder | Same, plus multi-unit/carton barcodes, cost normalisation, blind stock count | **Par** |
| **Purchasing** | MR → RFQ → SQ → PO → PR → PI, landed cost, subcontracting | PO → Receipt, landed cost entries, adjustments, POS cash-PO | **Behind (partial flow)** |
| **Selling flow** | Quotation → Sales Order → Delivery Note → Sales Invoice, partial delivery/billing | Invoice + quotation + credit invoice; no order/delivery split | **Behind** |
| **Discounts/pricing** | Pricing Rule, Promotional Scheme, Price List per party | Rich engine: tiered/multi-buy/BXGY, RFM-targeted, O(1) preview | **We win** |
| **Stock ledger & valuation** | Stock Ledger Entry, Bin, FIFO/moving-avg, Stock Reconciliation, repost, stock closing balance | Valued ledger entries + bins + repost, moving average/FIFO/LIFO (2026-08-26). No backdated auto-repost, no period closing balance | **Par (was structural)** |
| **Multi-location** | Warehouse tree, Bin, transfers, putaway, pick lists | None (single bucket) | **Behind — structural** |
| **Accounting** | Full double entry: COA, GL Entry, Journal/Payment Entry, cost centers, dimensions, budgets, fiscal year, period close, bank rec | Bespoke rollups per domain; no ledger, no trial balance, no P&L that ties | **Behind — structural** |
| **Receivables control** | Credit limit + hold, payment terms/schedule, dunning, statements, payment reconciliation, advances | Credit invoices + payments, partial aging | **Behind** |
| **Tax** | Item tax templates, tax categories/rules, withholding, inclusive/exclusive | None | **Behind (low urgency here)** |
| **Document lifecycle** | `docstatus` draft/submitted/cancelled + amend, versioning, immutability | Per-domain ad-hoc statuses; PO reopen/re-apply logic hand-rolled | **Behind — structural** |
| **Approvals** | Generic Workflow engine (states × roles × transitions) on any doc | Ad-hoc; `WorkflowTemplate`/`WorkflowStage` exist but only for operations jobs | **Behind** |
| **Permissions** | Role × doctype × verb, field-level perm levels, row-level user permissions | 8 roles + additive per-user permission codes, escalation guard | **Par (we lack row/field scoping)** |
| **Reporting** | Report Builder, query/script reports, dashboards, number cards — no developer needed | 9 hard-coded report types + AI assistant | **Behind on self-service; AI is our answer** |
| **Extensibility** | Custom fields, custom doctypes, naming series, print format builder, webhooks, app marketplace | Code changes required for all of it | **Behind (deliberately, for now)** |
| **Manufacturing** | BOM (multi-level), Work Order, Job Card, Routing, Workstation, Production Plan/MRP | `BillOfMaterials`/`BomLine` recipes, made-to-order, kitchen stations | **Behind (mostly irrelevant to us)** |
| **Projects / Assets / Quality / Support** | All present | Operations (repair jobs) ≈ support/maintenance; nothing else | **Behind (mostly irrelevant to us)** |
| **Multi-company / multi-currency** | Yes, with exchange revaluation | Single company, single currency | **Behind (not needed yet)** |

---

## 4. The five primitives worth stealing

These are the things that make ERPNext's numbers hold together. Each one is a small, generic
mechanism that pays off across every module we already have. This is the highest-value section of
this document.

### P1 — Immutable submitted documents (`docstatus` + cancel + amend)
Every ERPNext transaction is Draft (0) → Submitted (1) → Cancelled (2). Submitted rows are immutable;
cancelling **writes reversing entries** rather than deleting; correcting means *amending* into a new
linked document. Deletions of history are impossible by construction.

Why we want it: it is the mechanical form of our "correct numbers" promise, it makes audit trivial,
and it replaces every ad-hoc "can this still be edited?" branch we hand-roll (PO draft editing,
returns windows, register reopen).

### P2 — A double-entry ledger underneath the operations
One append-only `gl_entry` table (account, debit, credit, party, voucher type, voucher no, posting
date) that every document posts to. Trial balance must be zero at all times; P&L and balance sheet
become queries instead of bespoke rollups.

Why we want it: today gross profit, expenses, payroll, supplier credit, and register cash are five
independent rollups that can silently disagree. A ledger makes disagreement *impossible to hide* —
and our simulation oracle can assert it continuously. **Ship it as a shadow ledger first**: no chart
of accounts UX, a preset COA per `shop_type`, users never see an account code unless they ask.

### P3 — Valued stock ledger entries + Bin
One append-only row per stock event carrying `qty_change`, `valuation_rate`, `balance_qty`,
`balance_value`, `warehouse`, `voucher`. Stock value and COGS are derived from the ledger, not from
"whatever the last purchase cost was". Add the ability to *repost* after a backdated correction.

Why we want it: our current last-cost model means the value of goods on hand is not the money that was
actually spent on them. That is the phantom-loss bug class we already fought once with UoM cost
normalisation — the ledger closes it permanently.

### P4 — A generic workflow/approval engine
States, transitions, and role gates declared as data and applied to *any* document, instead of
per-feature approval code. We already have `WorkflowTemplate`/`WorkflowStage` for operations jobs —
generalise them.

### P5 — Configuration surfaces where we currently require a code change
Three cheap ones, in order: **naming series** per document type; **custom fields** on core entities;
**per-register profiles** (ERPNext's POS Profile) so a device gets its own warehouse, payment modes,
price list and permissions instead of one global `ShopSettings`.

---

## 5. Feature gaps ranked by Libyan-market ROI

| # | Gap | Why it matters here | Cost | Priority |
|---|---|---|---|---|
| 1 | **Customer credit limit + overdue block at POS** | آجل is universal; the owner's #1 fear is unrecoverable credit. Pairs with our SMS/WhatsApp messaging for reminders — ERPNext can't do that. | S | **Now** |
| 2 | **Warehouses / store room (مخزن) + transfers** | Shop + back store is the default; multi-branch is the natural upsell. Every month we wait, the migration gets bigger. | L | **Now** |
| 3 | ~~**Valued stock ledger + reposting**~~ | **Shipped 2026-08-26.** Correct COGS and correct stock value = the wedge. | L | **Done** |
| 4 | **Immutable documents + cancel/amend** | Audit, disputes, cashier fraud, and it simplifies existing code. | M | **Now** |
| 5 | **Shadow GL + trial balance + P&L** | Proof of correctness; unlocks the accountant persona. | L | Next |
| 6 | **Payment terms, due dates, statements, aging** | Wholesale customers ask for a statement (كشف حساب) by name. | M | Next |
| 7 | **Sales Order → Delivery Note split** | "Order today, deliver tomorrow" wholesale/appliance flow we can't model. | M | Next |
| 8 | **Material Request (store → shop requisition)** | Natural companion to warehouses. | S | Next |
| 9 | **Period close / accounting-period lock** | Stops last month's numbers moving after they were reported. | S | Next |
| 10 | **Generic approval workflow** | Discount above X, PO above Y, payroll run — all currently ad-hoc. | M | Later |
| 11 | **Custom fields + naming series** | Removes us from the critical path of every customer's small ask. | M | Later |
| 12 | **Self-service reporting** | Every customer wants one more report. Our AI assistant can leapfrog the report builder if we add export/schedule/pin. | M | Later |
| 13 | **Serial-number tracking** | Phones, appliances, warranty claims — our repair-shop customers. | M | Later |
| 14 | **Line-level tax (inclusive/exclusive)** | Low urgency in Libya, but blocks any second market and B2B tax invoices. | S | Later |
| 15 | Supplier quotation comparison, partial purchase invoicing | Nice-to-have for purchasing agents. | M | Later |
| 16 | Fixed assets + depreciation, projects, quality inspection, MRP, multi-company | No customer demand identified. | XL | **Not planned** |

---

## 6. What we do that ERPNext does not — protect and press

Do not let breadth work erode these; they are why we win deals.

1. LAN-local, generator-proof, single-backend deployment (their POS offline story is famously weak).
2. Hardware depth: thermal, labels, USB/serial, scan-wedge guard, cash drawer, price-checker kiosk.
3. Arabic-first RTL across UI, receipts and PDFs.
4. Cashier ergonomics and speed on a native client.
5. Fleet operations: zero-config discovery, remote update with auto-rollback, remote diagnostics, licensing.
6. AI assistant with real tools — the answer to "I need another report" without a report builder.
7. Domain features they lack or bury: modifiers, kitchen routing, RFM-targeted discounts, fraud findings,
   BioTime attendance, commissions, legacy-system migration connectors.

---

## 7. Roadmap

Sizing assumes the current pace and that each phase ships behind a flag with the simulation oracle
extended to assert the new invariants.

### Phase 0 — Decide and instrument (≈1 week)
- ~~Ratify the valuation method we *intend*~~ **Done 2026-08-26.** The method is now an explicit,
  owner-visible choice — moving average (default), FIFO or LIFO — asked during first-run setup and
  changeable afterwards only behind a confirmation the API enforces, not just the UI. The engine is a
  port of ERPNext's `stock/valuation.py` plus the moving-average arithmetic from `stock_ledger.py`,
  with their `test_valuation.py` cases ported alongside it. **Still pending: the engine is not yet the
  source of truth for COGS** — see 1c/1d below. Until then the last-cost path still decides
  `OrderLine.unit_cost`; the setting records intent and the Phase 1 wiring is what makes it bite.
- Extend the business-simulation oracle with the invariants the later phases must satisfy
  (stock value = Σ ledger balance value; Σ debits = Σ credits; receivables = Σ unpaid invoices).
- Generate an ER/model reference doc for the backend (ERPNext publishes theirs; we should too).

**Exit:** the oracle fails loudly on the invariants we are about to build toward.

### Phase 1 — Correctness spine (≈6–8 weeks)
- **1a** Document lifecycle: draft/submitted/cancelled/amended on `Order`, `PurchaseOrder`,
  `PurchaseReceipt`, `Payment`, `SupplierPayment`, `Expense`, `PayrollRun`, `StockCount`.
  Immutability enforced at the model layer; cancel writes reversals; amend links to the amended doc.
  Retire the hand-rolled PO reopen/re-apply logic onto this primitive.
- **1b** Naming series per document type (generalise `invoice_number` / `customer_number`).
- **1c** ~~Valued stock ledger entries~~ **Done 2026-08-26.** `StockLedgerEntry` (append-only, valued),
  `StockValuationBin` (the live cache, rebuildable), and a minimal `Warehouse` whose default "Main" row
  every ledger entry carries from its first migration — so Phase 2 adds screens, not a second migration
  of stock history. `repost_valuation` replays the ledger for a backdated correction, a method change,
  or any doubt about the cache. An opening-balance migration values existing stock at the last purchase
  cost, so the shop already trading starts from what it was already assuming.
  The hook is the **on-hand delta a movement records, not its type**, so every current and future stock
  path is valued automatically rather than via a list of movement types that can drift.
- **1d** ~~COGS derived from the ledger~~ **Done 2026-08-26.** A cart line carries a provisional cost
  while it is open; when the stock is actually issued, `OrderLine.unit_cost` is restamped with what the
  valuation engine says it cost. Every report already reads that column, so gross profit became true
  without a single report changing. Returns re-enter stock at the cost they left at, rather than at
  today's rate, so undoing a sale books no profit.
  Two deliberate behaviour changes came with it: receipts are now valued **net of discounts and landed
  costs** (`effective_base_unit_cost`) rather than at the raw invoice price, and the cost of a sale is
  the cost of the goods that actually left rather than the price on the newest invoice.

**Exit (1c/1d met):** stock value, COGS and gross profit all derive from one append-only table. The
business-simulation oracle was taught the new costing rule and proves the wiring end to end — it now
models the ledger event by event and independently predicts every line cost. Remaining in Phase 1:
**1a** (document lifecycle) and **1b** (numbering series).

### Phase 2 — Multi-location (≈6 weeks)
Because Phase 1c already stamps a warehouse on every ledger row, this phase adds surfaces and data, not
a re-migration of history.

- `Warehouse` (shop floor / store room / van), `Bin` (variant × warehouse) replacing the `OneToOne`
  `StockItem`, with a migration that lands every existing quantity in the implicit "Main" warehouse.
- Stock transfer document with optional in-transit; per-warehouse reorder levels; stock count per warehouse.
- **Register/device profile** (ERPNext's POS Profile): default warehouse, allowed payment modes,
  price list, discount permissions per register — carved out of global `ShopSettings`.
- POS, purchasing, reports, price checker all become warehouse-aware; single-warehouse shops see no change.

**Exit:** a shop can run a back store and a shop floor, move stock between them, and the ledger still ties.

**Note on branches vs. warehouses.** Multiple warehouses inside one shop is a schema problem and is solved
here. Multiple *branches* is an architecture problem and is not: Pointy is deliberately one LAN-local
backend per site, because offline sync between peers is precisely the bug class our competitors ship. A
second branch means a second backend, so cross-branch stock, pricing and reporting have to be
relay-mediated, and every cross-branch read must be allowed to be stale or unavailable without breaking
the till. That decision (§10.6) should be made before Phase 2 designs its transfer document, so that an
inter-warehouse transfer and a future inter-branch transfer are the same shape.

### Phase 3 — Money control (≈5 weeks)
- Customer credit limit + configurable block/warn at POS; supplier equivalent.
- Payment terms and due-date schedules on credit invoices and POs.
- Customer/supplier statements (كشف حساب) and a real aging report, printable and PDF-able.
- Payment allocation against specific invoices (on-account vs. advance), and reconciliation of the two.
- Dunning-lite: overdue reminders through the existing messaging gateway, AI-drafted, human-approved.

**Exit:** an owner can answer "who owes me what, since when, and did the reminder go out?" in one screen.

### Phase 4 — Shadow ledger (≈5 weeks)
- Preset chart of accounts per `shop_type`; `gl_entry` append-only table; posting rules per document.
- Trial balance, P&L and balance-sheet-lite reports; accounting-period lock and period close.
- Accountant-only UI; nothing in the cashier or owner path changes.

**Exit:** trial balance is zero on every oracle run; P&L ties to the sales/expenses reports we already ship.

### Phase 5 — Document flow completeness (≈4 weeks)
- Sales Order → Delivery Note split with partial delivery and partial invoicing.
- Material Request (store → shop requisition) feeding Phase 2 transfers.
- Supplier quotation comparison; partial purchase invoicing.

### Phase 6 — Extensibility without a developer (≈4–5 weeks)
- Generic workflow/approval engine, generalised from `WorkflowTemplate`/`WorkflowStage`.
- Custom fields on core entities (schema registry + JSON storage + form rendering).
- Row-level permission scoping (by warehouse / register / channel) and field-level masking for cost prices.
- Self-service reporting: either a saved-query builder, or — preferred — AI-generated reports that can be
  exported, scheduled, and pinned to the dashboard.

### Opportunistic backlog
Line-level tax engine, serial numbers, fixed assets, lead/opportunity pipeline, recurring/subscription
invoices, customer portal, a `regional/` isolation layer before any second country.

---

## 8. Anti-goals — what we deliberately will not copy

1. **A user-facing chart of accounts.** Shopkeepers will not maintain one. The ledger stays internal
   until an accountant asks for it.
2. **A metadata/doctype engine.** Frappe's whole product is that engine; rebuilding it would consume a
   year and give us a worse Django. Targeted custom fields only.
3. **Multi-company / multi-currency** until a signed customer needs it.
4. **Manufacturing planning (MRP, work orders, routings, workstations).** Our recipes plus operations
   jobs already cover kitchens and workshops.
5. **Projects, fixed assets, quality inspection, subcontracting.** No demand.
6. **Anything that slows the POS.** Checkout latency is a hard constraint; every phase above must keep
   the cashier path unchanged in query count.

---

## 9. Engineering practices worth stealing (not features)

- **A shared transaction-document base class.** ERPNext's buying/selling controllers share totals,
  rounding, party and tax logic. Our `Order` and `PurchaseOrder` paths have drifted into parallel
  implementations of the same arithmetic — a shared base would have caught more than one bug we fixed twice.
- **Reposting/rebuild tooling as a first-class command.** They can recompute valuation and GL for a
  period. We should be able to rebuild every derived value (stock balances, popularity, RFM, ledger)
  on demand, and prove it changes nothing.
- **Period locking** as a general mechanism, not just for accounting.
- **A regional isolation layer** for country-specific rules, created *before* the second country.
- **Published data-model documentation** — they publish doctype references; ours lives only in code.

---

## 10. Open decisions (need your call)

1. ~~**Is multi-branch on the near roadmap for a real customer?**~~ **Resolved 2026-08-26:** multi-branch
   is on the product map but not near-term. Consequence: Phase 1 keeps its slot ahead of Phase 2, but
   1c carries the `warehouse` column from the start so we never migrate stock history twice. Opens §10.6.
2. ~~**Valuation method:**~~ **Resolved 2026-08-26:** all three are offered (moving average default,
   FIFO, LIFO), chosen at setup and guarded afterwards. Moving average is the default because the shop
   already running predates the setting, and it is the method closest to what it was getting.
3. **Does any current or pipeline customer have an accountant who wants formal statements?** That decides
   whether Phase 4 is real work or a correctness-only shadow ledger.
4. **Credit limits: block or warn by default?** Blocking is safer for the owner, riskier at the counter.
5. **Self-service reports: build a query builder, or invest that budget in making the AI assistant the
   reporting surface?** The second is more differentiated and cheaper, but harder to make deterministic.
6. **Branch topology (new, from §10.1):** when multi-branch arrives, is a branch its own LAN-local backend
   that the relay federates, or do satellite branches run thin against a single backend? The first keeps
   our generator-proof guarantee and matches the relay we already operate; the second is simpler but makes
   a branch stop selling when its link drops. This shapes Phase 2's transfer document, so it wants an
   answer before Phase 2 starts — not before Phase 1.
