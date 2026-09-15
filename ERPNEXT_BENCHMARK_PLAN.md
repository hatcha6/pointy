# Pointy vs. ERPNext — Benchmark, Gap Register, and Improvement Plan

**Date:** 2026-08-26. **Last reconciled against the tree: 2026-09-13.**
**Mirror project:** [frappe/erpnext](https://github.com/frappe/erpnext) (+ the Frappe framework underneath it)
**Purpose:** use the most-scrutinised open ERP in the world as a checklist against our own model, decide
what is genuinely missing, and sequence the work. This is a *selective adoption* plan, not a
"catch up to ERPNext" plan — see §8 Anti-goals.

> **Status, 2026-09-13.** Phases 1a, 2 and most of 3 have shipped since this was written, and the
> document had drifted far enough that it was describing gaps that no longer exist. Every row below
> was re-verified against the tree on that date, not against this document's own memory of itself.
> What that reconciliation changed is summarised in §0; the three things it *found* — a gap Phase 2
> created, a deferral whose own revisit condition has fired, and the one item that gets more expensive
> every month — are in §5 and §10.

---

## 0. Where we actually are (reconciled 2026-09-13)

| Plan item | Verdict | Evidence |
|---|---|---|
| **0** Valuation method ratified | **Done** 2026-08-26 | Owner-visible choice, API-guarded |
| **0** Oracle taught the new invariants | **Done** | Models the ledger event by event |
| **0** Published data-model reference | **Not started** | There is still no `docs/` directory |
| **1a** Document lifecycle | **Done** 2026-09-06 | `apps/documents`, **10 registered types** — sale, payment, purchase_order, purchase_receipt, supplier_payment, expense, payroll_run, stock_count, stock_transfer, stock_transfer_receipt |
| **1b** Naming series | **Not started** | `sales/models.py` still builds `f"R{created_at:%Y%m%d}{id:06d}"` inline. No prefix setting, no series table, no branch discriminator |
| **1c** Valued stock ledger | **Done** 2026-08-26 | `StockLedgerEntry`, `StockValuationBin`, `repost_valuation` |
| **1d** COGS from the ledger | **Done** 2026-08-26 | `OrderLine.unit_cost` restamped at issue |
| **2** Multi-location | **Done** 2026-09-06 | `Warehouse` (flat, 4 kinds incl. transit), `StockItem` now FK + unique on (variant, warehouse), `StockTransfer` → `StockTransferReceipt` two-step, `RegisterProfile` per device, Flutter surfaces for all of it |
| **3** Money control | **~80%** | Credit limits + per-customer policy, payment terms and due dates, receivables/payables aging, customer/supplier statements, overdue reminders via `apps/crm`. **Open: user-directed allocation** — collections allocate oldest-first automatically (`sales/serializers.py`), and there is no advance / on-account concept |
| **4** Shadow ledger | **Planned** — reversed 2026-09-13 | Declined 08-28, un-declined 09-13 on a rationale in neither of its own triggers: Libyan courts treat a **stamped paper ledger** as authoritative, and a دفتر الأستاذ cannot be printed without accounts. Re-sized ≈5 → **13–18 weeks** (§7 Phase 4, §10.3) |
| **5** Document flow | **Not started** | No `SalesOrder`, `DeliveryNote`, `MaterialRequest`, supplier quotation or purchase invoice anywhere |
| **6** Extensibility | **Not started** | No custom fields, no generic workflow (still operations-only), no row-level scoping. 19 hard-coded report types, no schedule/pin |

Two things shipped that this plan never asked for and should be recorded here so the next reconciliation
does not mistake them for gaps: **multi-currency** (Track A, 2026-08-31 — `apps/fx`, relay-fed
parallel-market rates, per-product pricing currency) and **period locking**, which arrived early with the
accountant reports overhaul rather than with Phase 4 as sequenced. That second one matters more than it
looked: **Phase 4 now inherits half of its own exit criterion** before it starts.

**One verdict changed after this table was written.** Phase 4 was *deferred* when §0 was drafted and is
*planned* by the end of the same reconciliation — reversed once the ERPNext accounting surface was
actually measured (§7) and the stamped-ledger rationale surfaced from the GTM dossier (§10.3). It is
recorded as a reversal rather than edited into looking like a plan that always said so.

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

Pointy, at first writing (2026-08-26):

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

Pointy, re-read 2026-09-13 (the same method: models and services, not memory):

- **34 backend apps, ~145 models, 3,549 backend test functions, 37 frontend feature modules.**
- Of the four findings above, **three have been closed** and one stands:
  - ~~One stock bucket~~ — `StockItem` is now `ForeignKey` + `UniqueConstraint(variant, warehouse)`.
  - ~~Last-cost valuation~~ — closed by 1c/1d.
  - ~~No credit limit / terms / statements~~ — all three shipped.
  - **Still true: no ledger.** No `Account`, `GLEntry` or `JournalEntry` exists. This is now a
    *decision* (§10.3) rather than an omission — but see the note there about its expiry condition.
- **Still true and unchanged:** no tax model of any kind; no serial-number tracking (`StockBatch` is
  still the only identity below the variant); no custom fields; no naming series; no generic workflow
  outside `apps/operations`; no row/field-level permission scoping.
- **New since:** `apps/fx` (multi-currency), `apps/treasury` (derived money position), `apps/documents`
  (lifecycle primitive), `apps/surveillance`, `apps/companion`, `apps/scales`, `apps/invoice_intake`.
- Report types grew 9 → **19**, all still hard-coded, none schedulable or pinnable.

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
| **Selling flow** | Quotation → Sales Order → Delivery Note → Sales Invoice, partial delivery/billing | Invoice + quotation + credit invoice; no order/delivery split | **Behind** (unchanged 09-13) |
| **Discounts/pricing** | Pricing Rule, Promotional Scheme, Price List per party | Rich engine: tiered/multi-buy/BXGY, RFM-targeted, O(1) preview | **We win** |
| **Stock ledger & valuation** | Stock Ledger Entry, Bin, FIFO/moving-avg, Stock Reconciliation, repost, stock closing balance | Valued ledger entries + bins + repost, moving average/FIFO/LIFO (2026-08-26). No backdated auto-repost, no period closing balance | **Par (was structural)** |
| **Serialized stock** | Serial No with its own status, warranty and movement history | `StockBatch` only (expiry-driven). No identity below the variant | **Behind** — and the only gap with a named prospect (§5.1) |
| **Multi-location** | Warehouse tree, Bin, transfers, putaway, pick lists | `Warehouse` (flat, 4 kinds), per-warehouse stock rows, two-step transfer through transit, per-device register profile (2026-09-06). No tree, no putaway, no pick lists — all refused, not missed | **Par (was structural)** |
| **Accounting** | Full double entry across **191 doctypes / 52 reports**: COA, GL Entry, Journal/Payment Entry, cost centers, dimensions, budgets, fiscal year, period close, bank rec | No ledger, no trial balance. `apps/treasury` derives cash/bank position, period lock shipped, one-definition-per-figure statically enforced | **Behind — structural. Now scheduled:** Phase 4 reversed 2026-09-13, sized 13–18 weeks, targeting par-for-our-buyer on ~8 spine doctypes and 5 reports while refusing ~150 |
| **Receivables control** | Credit limit + hold, payment terms/schedule, dunning, statements, payment reconciliation, advances | Credit limits with per-customer policy, payment terms + due dates, receivables/payables aging, customer/supplier statements, AI-drafted overdue reminders. Missing: user-directed allocation and advances | **Par** |
| **Tax** | Item tax templates, tax categories/rules, withholding, inclusive/exclusive | None. `catalog/0002_remove_product_tax_rate` deleted the last trace | **Behind (low urgency here)** |
| **Document lifecycle** | `docstatus` draft/submitted/cancelled + amend, versioning, immutability | `apps/documents` across 10 types: immutability at the model layer, cancel writes reversals, period-lock guard, declarative registry. **Amend is declared but not yet used** — the PO still corrects in place | **Par (was structural)** |
| **Approvals** | Generic Workflow engine (states × roles × transitions) on any doc | Ad-hoc; `WorkflowTemplate`/`WorkflowStage` exist but only for operations jobs | **Behind** |
| **Permissions** | Role × doctype × verb, field-level perm levels, row-level user permissions | 8 roles + additive per-user permission codes, escalation guard | **Behind — and newly so.** Par was the right call when there was one stock bucket; Phase 2 created places to scope *to* and nothing scopes to them (§5.2) |
| **Reporting** | Report Builder, query/script reports, dashboards, number cards — no developer needed | 19 hard-coded report types (up from 9) + CSV/PDF + AI assistant. Still none schedulable or pinnable | **Behind on self-service; AI is our answer** |
| **Extensibility** | Custom fields, custom doctypes, naming series, print format builder, webhooks, app marketplace | Code changes required for all of it | **Behind (deliberately, for now)** |
| **Manufacturing** | BOM (multi-level), Work Order, Job Card, Routing, Workstation, Production Plan/MRP | `BillOfMaterials`/`BomLine` recipes, made-to-order, kitchen stations | **Behind (mostly irrelevant to us)** |
| **Projects / Assets / Quality / Support** | All present | Operations (repair jobs) ≈ support/maintenance; nothing else | **Behind (mostly irrelevant to us)** |
| **Multi-company / multi-currency** | Yes, with exchange revaluation | Multi-currency shipped 2026-08-31 (`apps/fx`, relay-fed parallel-market rates, per-product pricing currency). Multi-company still refused | **Par on currency; refused on company** |

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

*Status 2026-09-13: scheduled.* Declined 08-28, reversed 09-13, sized **13–18 weeks** in §7 Phase 4. Two
things learned from reading their implementation rather than their doctype list. First, the sentence
above needs amending: users never see an account code **at all**, not "unless they ask" — §8.1 now names
an account-tree screen as the drift signal. Second, a GL is not self-proving: ERPNext devotes **19
doctypes and reports** to finding and repairing ledger inconsistency, so the oracle work (4d) is the
primitive's other half, not its polish.

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

*Status 2026-09-13:* per-register profiles shipped **narrowly** — warehouse only (§10.8). Naming series
and custom fields are both untouched, and of the three, naming series is the one with a deadline (§5.3).

### P6 — Scoping, which we did not list and now need
Not in the original five, and it belongs there: ERPNext scopes permissions to *rows* — a user permission
on a warehouse means you do not see stock you have no business seeing. We ranked this as field-level
polish because we had one warehouse and the row dimension did not exist. Phase 2 created it. §5.2.

---

## 5. Feature gaps ranked by Libyan-market ROI

**Re-ranked 2026-09-13.** The original ranking was written when Phases 1–3 were all ahead of us; ten of
its sixteen rows are now shipped or resolved. What follows is the list as it stands, and the first three
entries are the reconciliation's actual findings rather than a reshuffle of the old ones.

**Amended later the same day:** the shadow GL moved from #10/*Later* to #4/*near-term* once the ERPNext
accounting surface was measured rather than estimated and the reason to build it turned out not to be the
one it had been declined against. §5.6 states that reversal plainly; §10.3 carries the argument.

### 5.1 — Serialized inventory is mis-ranked, and it is the only gap with a customer attached

It sat at **#13, "Later"**, described as a repair-shop nicety. That was wrong, and
[SERIALIZED_INVENTORY_PLAN.md](SERIALIZED_INVENTORY_PLAN.md) (2026-09-10) makes the argument at length:
for a used-goods trader, a serial number is not a label on a sale, it is a costed, located, dated object,
and **no other inventory model makes their numbers correct at all**. Every remaining item on this list is
demand we have inferred. This one is a named prospect — a used-phone shop tracking every handset by IMEI,
working around a POS that has only products and sub-barcodes.

The plan is written and nothing is built. **It should be the next thing built.**

### 5.2 — Phase 2 created a permission gap, and the fix is filed under "Later"

`RegisterProfile` answers *which warehouse does this till sell out of*. Nothing answers *which warehouses
may this user see, count, or move stock between* — because until 2026-09-06 there was one bucket and the
question could not be asked. A shop that opens a store room now has a control surface it did not have
last month and no way to control it.

Row-level scoping is Phase 6, ranked *Later*, on a ranking written before the thing it scopes existed.
This is the general hazard of a phased plan: **a phase can create the gap that a later phase was sized to
close, and the ranking does not notice.** The narrow version — scope stock transfer and stock count to a
user's permitted warehouses — is small, and is worth doing before the general mechanism.

### 5.3 — Naming series is the only item that gets more expensive by waiting

Everything else on this list costs the same in six months. Numbering does not: retrofitting a series means
renumbering documents a shop has already printed and handed to customers. It is sized **S**, it has been
"remaining in Phase 1" across the completion of two other phases, and today's numbers are an inline
f-string — `R{date}{id:06d}` — with no prefix setting and no branch discriminator, which §10.6 says the
column needs from the start.

It is the cheapest unshipped item on the list and the only one carrying a deadline. Do it alongside 5.1.

### 5.4 — The full register

| # | Gap | Why it matters here | Cost | Priority |
|---|---|---|---|---|
| 1 | **Serialized inventory (IMEI/serial/VIN)** | §5.1. The only gap with a named prospect. Plan written, nothing built. | L | **Now** |
| 2 | **Warehouse-scoped permissions** | §5.2. A gap Phase 2 opened; the narrow version is cheap. | S→M | **Now** |
| 3 | **Naming series** | §5.3. The only item with a deadline. | S | **Now** |
| 4 | **Shadow GL + stamped Arabic ledger** | **Moved up 2026-09-13 from #10/Later.** Not for the trial balance — for the دفتر اليومية / الأستاذ a Libyan court treats as authoritative, which cannot be printed without accounts. §10.3, sized in §7 Phase 4. | **XL (13–18 wks)** | **Near-term** |
| 5 | **Payment allocation to specific invoices + advances** | Finishes Phase 3. Collections allocate oldest-first today, which is right by default and wrong when a customer pays *this* invoice. Also a prerequisite the ledger will want. | M | Next |
| 6 | **Amend as a real transition** | The lifecycle primitive declares `Correction.AMEND` and nothing uses it; the PO still corrects in place. The registry comment already names this as next. | S | Next |
| 7 | **Material Request (store → shop requisition)** | Strictly cheaper than when it was ranked: the transfer document it feeds now exists. | S | Next |
| 8 | **Sales Order → Delivery Note split** | "Order today, deliver tomorrow" wholesale/appliance flow we still cannot model. | M | Next |
| 9 | **Backdated auto-repost + stock closing balance** | The two pieces of Phase 1c we scoped out. `repost_valuation` is manual; nothing triggers it on a backdated correction. The ledger will make this matter more, not less. | M | Next |
| 10 | **Published data-model reference** | Phase 0's one unfinished item. There is no `docs/` directory — and Phase 4 is exactly the phase that will wish it existed. | S | Next |
| 11 | **Self-service reporting** | 19 report types now, none schedulable or pinnable. Export/schedule/pin was the condition under which AI leapfrogs a report builder; only export shipped. | M | Later |
| 12 | **Custom fields + generic workflow** | Removes us from the critical path of every customer's small ask. | M | Later |
| 13 | **Line-level tax (inclusive/exclusive)** | Still zero urgency in Libya; still a hard blocker for any second market. Cheaper once a ledger exists to post it to. | S | Later |
| 14 | Supplier quotation comparison, partial purchase invoicing | Nice-to-have for purchasing agents. | M | Later |
| 15 | **Bank reconciliation** | Not previously listed. 18 doctypes + 3 reports in ERPNext, refused here — but the **most plausible future ask of the whole refused set** once a shop banks seriously. Cash dominance and no e-invoicing mandate keep it safely ignorable for now. | L | Watch |
| 16 | Fixed assets + depreciation, projects, quality inspection, MRP, multi-company | No customer demand identified. | XL | **Not planned** |

**Shipped since the first ranking**, kept here so the next reconciliation can see what moved: valued stock
ledger (#3, 08-26), customer credit limits (#1, 09-05), warehouses and transfers (#2, 09-06), immutable
documents (#4, 09-06), payment terms / statements / aging (#6, 09-06 area), period close and lock (#9,
arrived early with the accountant reports overhaul).

### 5.5 — Not on this list, and deliberately

Two other plans are written and unbuilt, and neither is an ERPNext gap:
[FX_FORECAST_PLAN.md](FX_FORECAST_PLAN.md) (margin protection against rate drift — a subtraction we can
already make exactly, not the forecast that was asked for) and
[LEARNING_MODULE_PLAN.md](LEARNING_MODULE_PLAN.md) (training staff inside the real app against a sandbox
shop). They compete for the same weeks as everything above, and ERPNext has no opinion about either —
which is a point in their favour, not against them.

### 5.6 — The shadow GL was declined against the wrong question

Recorded separately from §5.4 because a reversal inside one working day deserves to be legible rather
than quietly absorbed into a table.

It was declined on 2026-08-28 against the question *"does a customer's accountant want statements?"* The
answer was no and still is — the evidence in §10.3 is a competitor's live install with a full
double-entry module and zero accounts ever created. Nothing about that has changed.

What changed is that this was never the only question. **Libyan courts treat stamped paper ledgers as
authoritative over electronic records**, and the highest-value unbuilt feature in the GTM dossier is an
Arabic print-ready stampable دفتر اليومية / دفتر الأستاذ. A daybook can be faked from money events; a
دفتر الأستاذ cannot exist without accounts. So the ledger is not an accountant's instrument nobody
requested — it is the engine under a document a shop can hold, in a market where the paper notebook is
the incumbent and our brand is literally دفتر.

Three things this does **not** license, stated here because they are how this goes wrong:

- **It is not compliance.** Small traders are legally exempt from keeping books. This sells as control,
  and the specific buyer is a shop with real آجل exposure — the disputes that reach a court.
- **It does not reopen §8.1.** No chart of accounts is shown to anyone. See the anti-goal, which now
  names the account-tree screen as the drift signal.
- **It is XL, not a side quest.** 13–18 weeks, measured rather than guessed, against ≈5 in the original
  plan. §7 Phase 4 carries the decomposition and the eleven posting rules that are the real work.

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
- ~~Extend the business-simulation oracle with the invariants the later phases must satisfy~~
  **Done.** The oracle models the ledger event by event and independently predicts every line cost.
  The debits-equal-credits invariant is moot while §10.3 holds.
- **Still open (2026-09-13): generate an ER/model reference doc for the backend.** There is no `docs/`
  directory. This is the last unfinished Phase 0 item and the cheapest thing on the whole plan.

**Exit:** the oracle fails loudly on the invariants we are about to build toward. **Met, except the
model reference.**

### Phase 1 — Correctness spine (≈6–8 weeks) — **shipped except 1b**
- **1a** ~~Document lifecycle~~ **Done 2026-09-06.** `apps/documents` carries the primitive and
  `registrations.py` declares every document type in one readable file. Ten types adopted — the eight
  planned plus `StockTransfer` and `StockTransferReceipt`, which Phase 2 got for free by landing after
  it. Immutability is enforced at the model layer, cancel writes reversals, and the period lock is a
  guard on the transition rather than a check each domain remembers.
  **One piece deliberately unbuilt:** `Correction.AMEND` is declared and nothing uses it. The PO still
  corrects in place — the affordance we built on purpose — and the registry says why: adding an amend
  route nothing calls would be exactly the untested cancel path the design exists to avoid. Converting
  the in-place route into a true amendment is #5 in §5.4.
- **1b** Naming series per document type (generalise `invoice_number` / `customer_number`). Carries a
  branch discriminator from the start — a *column*, the way ERPNext scopes a series to a company, not a
  per-deployment constant (§10.6). Cheap to design in, and retrofitting one means renumbering documents a
  shop has already printed and handed to customers.
  **Still not started as of 2026-09-13**, and the sentence above is the reason it should stop being
  deferred: it is the one item on this plan whose cost rises with every month of trading. See §5.3.
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
models the ledger event by event and independently predicts every line cost. ~~Remaining in Phase 1:
**1a** (document lifecycle) and~~ **1a shipped 2026-09-06. Remaining in Phase 1: 1b alone.**

### Phase 2 — Multi-location (≈6 weeks) — **shipped 2026-09-06**
Because Phase 1c already stamped a warehouse on every ledger row, this phase added surfaces and data, not
a re-migration of history. That bet paid: the expensive part had already been bought.

- ~~`Warehouse`, `Bin` replacing the `OneToOne` `StockItem`~~ **Done.** `Warehouse` is **flat, not a
  tree** — ERPNext's nested set with non-posting group nodes costs four of its thirteen warehouse tests
  just to hold together, and a shop with a showroom, a store room and possibly a van does not need a
  hierarchy. `StockItem` is now `ForeignKey` + `UniqueConstraint(variant, warehouse)`, and the word
  `Bin` stayed spoken for by `StockValuationBin`, which is the same idea for value.
- ~~Stock transfer with optional in-transit~~ **Done**, and the transit step is not optional: a
  `TRANSIT` warehouse kind that nothing sells from, a `StockTransfer` that dispatches into it and a
  `StockTransferReceipt` that draws out of it, both of them lifecycle documents.
- ~~Register/device profile~~ **Done, narrowly.** `RegisterProfile` is keyed on `device_id` and today
  answers exactly one question — which place this till sells out of — because the warehouse is a
  property of where the till stands, not of who stands at it. Payment modes, price list and discount
  permissions are *not* carved out of `ShopSettings` yet; they were not needed to make locations work
  and nothing has asked.
- ~~POS, purchasing, reports, price checker warehouse-aware~~ **Done.** A shop that never opens a second
  warehouse never gets a profile row and sees no change anywhere.
- **What this phase created and did not close:** places to scope permissions *to*, with nothing scoping
  to them. See §5.2.

**Exit:** a shop can run a back store and a shop floor, move stock between them, and the ledger still
ties. **Met.**

**Note on branches vs. warehouses.** Multiple warehouses inside one shop is a schema problem and is solved
here. Multiple *branches* was an architecture problem; §10.6 settled it on 2026-09-06 in favour of a hosted
instance with branches as rows, which collapses it back into this one. An inter-branch transfer *is* an
inter-warehouse transfer: one database, one transaction, nothing reconciled across a link that may be down.

Build the transfer two-step through a transit location anyway — for a physical reason rather than an
architectural one. Goods in a van are somewhere, and a transfer that debits the source and credits the
destination in a single step values them in neither place while they are on the road. SAP, Oracle and Odoo
all model a transit location inside a single instance for exactly that reason, and it is the shape the
document lifecycle already knows how to hold: a dispatch is a submitted document, cancelling it reverses,
and the receipt is a separate document that references it.

Nothing in this phase is relay-mediated, and the on-prem single-shop deployment is untouched by any of it.

### Phase 3 — Money control (≈5 weeks) — **~80% shipped**
- ~~Customer credit limit + configurable block/warn at POS~~ **Done 2026-09-05**, and the block/warn
  question dissolved once the ceiling became per-customer — see §10.4.
- ~~Payment terms and due-date schedules on credit invoices and POs~~ **Done.** `Customer.payment_terms`,
  a shop default, and `Order.due_date` with its own index.
- ~~Customer/supplier statements (كشف حساب) and a real aging report~~ **Done.** Four of the nineteen
  report types: receivables aging, payables aging, customer statement, supplier statement — JSON, PDF
  and CSV.
- **Open: payment allocation against specific invoices (on-account vs. advance).** Collections allocate
  **oldest-first, automatically**. That is the right default and the wrong answer when a customer pays
  *this* invoice and means it, and there is no representation for money received against no invoice at
  all. This is the one substantive piece of Phase 3 still missing — #4 in §5.4.
- ~~Dunning-lite: overdue reminders, AI-drafted, human-approved~~ **Done** via `apps/crm` transactional
  messaging; due-today, overdue and undated all remind, future-dated are held back.

**Exit:** an owner can answer "who owes me what, since when, and did the reminder go out?" in one screen.
**Met** — the missing allocation work is about directing money, not about seeing the debt.

### Phase 4 — Shadow ledger (**re-sized 2026-09-13: 13–18 weeks**) — planned, not deferred

**This phase was declined on 2026-08-28 and un-declined on 2026-09-13.** §10.3 carries the full
reasoning, including the uncomfortable part: it was reversed on a rationale that appeared in neither of
its own revisit triggers. Read that before building, because *why* it is being built decides what it
looks like.

The original sizing of ≈5 weeks was wrong. It sized the **ledger** and not the **posting rules**, which
are the bulk of the work and all of the risk.

#### What is actually on the other side (fetched 2026-09-13, not recalled)

ERPNext's `accounts/` module is **191 doctypes and 52 reports**. The ten core files alone:

| File | Lines |
|---|---|
| `accounts/doctype/payment_entry/payment_entry.py` | 3,364 |
| `accounts/utils.py` | 2,908 |
| `controllers/accounts_controller.py` | 1,823 |
| `accounts/doctype/journal_entry/journal_entry.py` | 1,311 |
| `accounts/report/financial_statements.py` | 1,036 |
| `accounts/doctype/period_closing_voucher/period_closing_voucher.py` | 950 |
| `accounts/report/trial_balance/trial_balance.py` | 805 |
| `accounts/doctype/account/account.py` | 743 |
| `accounts/general_ledger.py` | 739 |
| `accounts/doctype/gl_entry/gl_entry.py` | 523 |

**That number is not the number we have to match.** Sorting the 191:

- **~8 are the spine.** Account (21 fields), GL Entry (47 fields), Journal Entry + child, Fiscal Year,
  Accounting Period, Period Closing Voucher.
- **~25 we already have under another name.** POS Profile → `RegisterProfile`. POS Opening/Closing Entry
  → register sessions and the Z-report. Payment Term / Terms Template / Payment Schedule →
  `customers/payment_terms.py` + due dates. Mode of Payment → payment methods. Bank / Bank Account →
  `MoneyAccount`. Pricing Rule + Promotional Scheme → our discount engine, which is better. Dunning +
  Dunning Type → CRM overdue reminders. Process Statement of Accounts → our statement reports. Currency
  Exchange Settings → `apps/fx`. Accounts Receivable/Payable reports → our aging.
- **5 of the 52 reports matter here:** trial balance, P&L, balance sheet, general-ledger drill-down,
  account balance. The rest are dimensions, consolidation, TDS, shares, deferred revenue, depreciation.
- **~150 are refused** — dimensions, cost centers, budgets, finance books, shareholders and share
  ledgers, subscriptions, tax withholding, deferred accounting, consolidation, multi-company, loyalty,
  invoice discounting, bank guarantees.

#### The finding that should shape our design

**Nineteen doctypes and reports in `accounts/` exist solely to find and repair ledger inconsistency:**
`ledger_health`, `ledger_health_monitor` (+ company child), `ledger_merge` (+ accounts child),
`bisect_accounting_statements`, `bisect_nodes`, the four `repost_accounting_ledger` /
`repost_payment_ledger` families, `unreconcile_payment` (+ entries child), and the reports
`invalid_ledger_entries`, `general_and_payment_ledger_comparison`, `voucher_wise_balance`,
`cheques_and_deposits_incorrectly_cleared`, `calculated_discount_mismatch`.

A tenth of the module is devoted to the ledger having gone wrong in production, under a mature team.
Two conclusions, and the second is ours:

1. A GL drifts under real load. Building one does not by itself make numbers correct — it creates a
   second thing that can disagree with the first.
2. **Their answer is repair tooling after the fact; ours is the oracle asserting the invariant
   continuously.** That is the same argument that declined this phase in August, now pointed at the
   ledger itself, and it is why 4d is not optional polish.

#### 4a — The spine

- `Account` + a **preset chart per `shop_type`**, seeded and never user-edited (§8.1 stands). Flat-ish
  parent/child rather than their nested set with `lft`/`rgt`; no account categories, no finance books.
  *~400 lines + fixtures.*
- `GLEntry`, append-only. Their row is 47 fields; ours needs ~16 — posting date, account, debit, credit,
  party type/party, voucher type/no/line, against, remarks, is_opening, is_cancelled, and the currency
  columns `apps/fx` implies. No dimensions, no cost center, no finance book. *~200 lines.*
- **The posting engine**, ported in spirit from `general_ledger.py`. Drop dimension offsetting,
  cost-center allocation and budget validation — that is most of their 739 lines. **Port faithfully:**
  entry merging, the negative-toggle, the debit/credit difference check with a round-off entry rather
  than a swallowed remainder, and reverse-on-cancel. Each of those exists because somebody's numbers came
  out wrong without it. *~350 lines.*
- Fiscal year and an opening-balance entry, so a shop already trading starts from figures it recognises
  rather than a replay of history nobody trusts — the same move the 1c opening migration made.

#### 4b — Posting rules: the real work

**Eleven money models**, one posting function each, matching `apps/core/money_dates.MONEY_DATE_FIELDS`
exactly so the two registries cannot drift: `payments.Payment`, `sales.Order`, `sales.OrderAdjustment`,
`sales.RegisterCashMovement`, `sales.RegisterSession`, `expenses.Expense`,
`purchasing.SupplierPayment`, `purchasing.PurchaseOrder`, `employees.PayrollRun`,
`treasury.MoneyTransfer`, `treasury.MoneyCount`.

This is where every bug will live. The edge cases that make a naive rule book a wrong number, each of
which needs its own oracle assertion: returns and exchanges, voids, refunds against a closed register,
landed costs, per-pack UoM cost normalisation, priced modifiers, pooled whole-unit discount allocation,
and partial payment against a credit invoice.

**The hardest single rule is FX, and it is new since this plan was written.** A purchase order carries a
frozen rate, the goods arrive later, the supplier is paid later again at a different rate — and the
difference has to post *somewhere*. ERPNext has an entire `exchange_rate_revaluation` doctype for this.
Multi-currency shipped 2026-08-31, so we inherit the problem on the day we have a ledger; it does not
get to be a later phase.

**What the document primitive does and does not give us here.** It gives an enumerated list of every
document that moves money, the cancel-writes-reversals contract already enforced at the model layer, and
a round-trip test that will fail the moment a `gl` effect does not reverse. It does **not** post
anything: `submit_effects` is documentation plus that test's checklist, not an execution hook, and each
domain still writes its own entries. Useful head start; not free posting.

#### 4c — Reports, and the one that is the actual reason

- Trial balance (~200 lines against their 805 — no dimensions, no finance books, no party TB).
- P&L and balance-sheet-lite (~350 against their 1,036 shared — no consolidation).
- General-ledger drill-down (~200).
- Period close (~250 against their 950). **The period *lock* already shipped** with the accountant
  reports overhaul, so this phase inherits half of its own exit criterion.
- **The stampable Arabic دفتر اليومية / دفتر الأستاذ.** ERPNext cannot produce this and is not trying to.
  It is the reason this phase exists — see §10.3 — and it is the one deliverable here that a Libyan shop
  can hold. Note the honest limit: the *daybook* half could be approximated from money events today; the
  **الأستاذ half cannot exist without accounts**, which is precisely what makes the ledger load-bearing
  rather than ornamental.

#### 4d — Proof, not repair

Teach the oracle: Σ debits = Σ credits on every run; every money event posts exactly once; a cancelled
document's reversals net its original to zero; stock value from the valuation ledger ties to the
inventory account balance; receivables tie to Σ unpaid invoices. *~300 test lines,* on machinery we
already own. This is what we build **instead of** their nineteen repair tools, and it is the difference
between a ledger that is *repairable* and one that is *provable*.

**Exit:** trial balance is zero on every oracle run; P&L ties to the sales and expense reports we already
ship; a shop can print a stamped Arabic ledger a court will accept. **Sizing: 13–18 weeks** — 10–14 to
par-for-our-buyer, 3–4 more for the three things in §10.3 that make it better than theirs.

**Anti-goal check.** Nothing above puts a chart of accounts in front of a shopkeeper. The accounts are
seeded per shop type, never edited, and never shown; what the owner sees is a printable ledger and the
reports that already exist. §8.1 is unchanged, and if this phase starts to require an account-tree
screen, that is the signal it has drifted.

### Phase 5 — Document flow completeness (≈4 weeks) — not started
- Sales Order → Delivery Note split with partial delivery and partial invoicing.
- Material Request (store → shop requisition) feeding Phase 2 transfers. **Cheaper than when it was
  sized**: the transfer document it feeds now exists, so this is a request that resolves into one.
- Supplier quotation comparison; partial purchase invoicing.

Both of the first two now sit on primitives that shipped, so this phase is smaller than 4 weeks if
taken after §5.4's first three.

### Phase 6 — Extensibility without a developer (≈4–5 weeks) — not started
- Generic workflow/approval engine, generalised from `WorkflowTemplate`/`WorkflowStage`.
- Custom fields on core entities (schema registry + JSON storage + form rendering).
- **Row-level permission scoping (by warehouse / register / channel)** and field-level masking for cost
  prices. **This item should not wait for this phase.** Phase 2 shipped the warehouses it scopes to, so
  the narrow version — scope stock transfer and stock count to a user's permitted warehouses — is now a
  live gap rather than a future nicety, and is promoted to §5.4 #2. The general mechanism can still land
  here.
- Self-service reporting: either a saved-query builder, or — preferred — AI-generated reports that can be
  exported, scheduled, and pinned to the dashboard. **Of export / schedule / pin, only export shipped**
  (CSV and PDF, with the streaming export path). Schedule and pin were the half that made AI a
  *replacement* for a report builder rather than a supplement to one.

### Opportunistic backlog
Line-level tax engine, ~~serial numbers~~ (**promoted out of this list 2026-09-13 — §5.1**), fixed assets,
lead/opportunity pipeline, recurring/subscription invoices, customer portal, a `regional/` isolation layer
before any second country.

---

## 8. Anti-goals — what we deliberately will not copy

1. **A user-facing chart of accounts.** Shopkeepers will not maintain one — the evidence in §10.3 is a
   live competitor install with a full accounting module and *zero* accounts ever created. **This stands
   unchanged now that Phase 4 is planned**, and the distinction is the one to hold onto: the chart is
   seeded per `shop_type`, never edited and never displayed; what a shop sees is a **printable stamped
   ledger** and the reports it already has. An account-tree screen appearing in Phase 4 is the signal
   that the phase has drifted, not a feature.
2. **A metadata/doctype engine.** Frappe's whole product is that engine; rebuilding it would consume a
   year and give us a worse Django. Targeted custom fields only.
3. ~~**Multi-company / multi-currency**~~ **Split 2026-09-06.** Multi-currency shipped (Track A, from
   2026-08-31): the `apps.fx` spine, relay-fed parallel-market rates, and a `pricing_currency` per
   product. **Multi-company stays refused** until a signed customer needs it — and when it arrives it is
   the branches-as-rows shape of §10.6, not a second instance.
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
  *Read more closely 2026-09-13, and the lesson inverts.* Their `accounts/` module carries **19 doctypes
  and reports whose only job is to find and repair ledger drift** — `ledger_health`, `ledger_merge`,
  `bisect_accounting_statements`, four `repost_*` families, `invalid_ledger_entries`,
  `general_and_payment_ledger_comparison`, and more. A tenth of the module exists because the ledger goes
  wrong in production under a mature team. Take the *rebuild* command, which is genuinely good practice;
  do **not** take the surrounding diagnostic estate as the model. The cheaper answer is the one we
  already own — assert the invariant continuously and never let the drift accumulate. **Repairable
  versus provable is the whole difference**, and it is the case for Phase 4d.
- **Period locking** as a general mechanism, not just for accounting.
- **A regional isolation layer** for country-specific rules, created *before* the second country.
- **Published data-model documentation** — they publish doctype references; ours lives only in code.
  *Still true 2026-09-13: there is no `docs/` directory.* This was also Phase 0's third bullet, which
  means it has now been the cheapest unfinished item on the plan for eighteen days across two completed
  phases — the reliable signature of a task nobody owns.
- **A declarative registry for cross-cutting behaviour.** Not stolen from them; discovered here.
  `apps/documents/registrations.py` puts every document type in one file you can read top to bottom, so
  that adding one is visibly a decision rather than a scattered edit. It is the pattern to reach for the
  next time a concern spans domains — and the reason Phase 2's transfer documents got the lifecycle for
  free.

---

## 10. Open decisions (need your call)

1. ~~**Is multi-branch on the near roadmap for a real customer?**~~ **Resolved 2026-08-26:** multi-branch
   is on the product map but not near-term. Consequence: Phase 1 keeps its slot ahead of Phase 2, but
   1c carries the `warehouse` column from the start so we never migrate stock history twice. Opens §10.6.
2. ~~**Valuation method:**~~ **Resolved 2026-08-26:** all three are offered (moving average default,
   FIFO, LIFO), chosen at setup and guarded afterwards. Moving average is the default because the shop
   already running predates the setting, and it is the method closest to what it was getting.
3. ~~**Does any current or pipeline customer have an accountant who wants formal statements?**~~
   ~~**Resolved 2026-08-28: Phase 4 is deferred, and the ledger is not being built yet.**~~
   **Reversed 2026-09-13: the ledger is being built. Phase 4 is planned, re-sized to 13–18 weeks.**

   Both halves are kept below, because the August evidence did not become wrong — it became answerable
   to a different question — and it is still what decides the *shape* of what gets built.

   **What was decided in August, and why it was right then.** The question asked was whether a customer's
   accountant wanted formal statements. The answer was no, from the competitor dumps we already hold.
   Aboghris ships a full double-entry module — chart of accounts, `QYODAT` journal entries, trial
   balance, `ميزانية`, bank transfers, a dedicated `حسابات` user group — and the live shop running it has
   **889 sales, 195 purchases, 7 configured banks, and zero accounts, zero journal entries, zero
   balances**. The accounting surface is a sales checkbox nobody touches; the *bank list* is maintained.
   Fahd's shop (751,901 sales) carries no receivable records either. A GL would have prevented 2 of the 4
   money bugs we have actually fixed (`e2f8827f`, `6b9e86ce`); the other two were below its granularity
   and were caught by the oracle, which is cheaper and already ours.

   What was built instead (2026-08-28) covered the three holes a ledger would have closed: `apps/treasury`
   (derived cash/bank balances, transfers, counts — no posting, no accounts tree), shrinkage and
   cost-basis stock value surfaced from the valuation ledger, and one definition per money figure
   enforced by `apps/core/test_money_definitions.py`.

   **What reversed it, and the uncomfortable part.** The deferral wrote itself two revisit triggers: a
   named accountant asking for a trial balance, or multi-warehouse landing. **Neither is why this
   flipped.** The second one did fire — multi-warehouse landed 2026-09-06 and a transfer moves value
   between places — but on its own it justified an oracle invariant, not a ledger.

   What actually reversed it was a fact that was in the GTM dossier the whole time and in neither
   trigger: **Libyan courts treat stamped paper ledgers as authoritative over electronic records.** The
   highest-value unbuilt feature in that dossier is an Arabic print-ready stampable دفتر اليومية /
   دفتر الأستاذ — which makes us the system that *produces* the legally authoritative notebook, in a
   market where the paper notebook is the real incumbent and our brand is literally دفتر.

   You cannot print a دفتر الأستاذ without accounts. The daybook half could be faked from money events;
   the ledger half cannot. So the GL stops being an accountant's instrument nobody asked for and becomes
   the engine under a document a shop can hold — **which is a demand we can point at, rather than one we
   inferred.**

   Three notes that keep this honest:

   - **This does not sell as compliance.** Small traders in Libya are legally *exempt* from keeping
     books. It sells as **control** — specifically, it is the آجل credit dispute that reaches a court,
     so the buyer for this is a shop with real credit exposure, not every shop. Do not pitch it as a
     legal requirement; it is not one.
   - **The August evidence still shapes the build.** Nobody touches a chart of accounts, so nobody is
     shown one. Preset per `shop_type`, seeded, never edited, never displayed. §8.1 is unchanged and
     Phase 4 carries its own anti-goal check.
   - **The triggers were watching for the wrong thing.** Two conditions were written, one fired, and the
     reason the decision actually changed was in a document nobody re-read. That is the same failure as
     §10.9's third case, one level up: a conditional deferral is only as good as the conditions somebody
     thought to write. Cross-read the GTM dossier at the next reconciliation, not just this plan.

4. ~~**Credit limits: block or warn by default?**~~ **Resolved 2026-09-05: neither, by default.** The
   question dissolved once the ceiling became per-customer. `ShopSettings.enforce_customer_credit_limits`
   is **off** out of the box, so nothing is capped until a shop asks for it; with it on, an over-limit
   آجل sale is **blocked** — `credit_limit_exceeded`, carrying the limit, outstanding and projected
   figures so the counter can see why. The safety-versus-friction tension moved into
   `Customer.credit_limit_policy`: `SHOP_DEFAULT`, `UNLIMITED` for the wholesale buyer who must not be
   capped by a default written for walk-ins, or `CUSTOM`. A shop can therefore tighten its appetite for
   risk without editing every contact.
5. **Self-service reports: build a query builder, or invest that budget in making the AI assistant the
   reporting surface?** The second is more differentiated and cheaper, but harder to make deterministic.
6. ~~**Branch topology (new, from §10.1):**~~ **Resolved 2026-09-06: cloud.** When multi-branch arrives it
   is one hosted instance with branches as rows — not federated LAN-local backends paired through the relay.

   The federated design was worked through in full before it was declined, so that declining it was a
   choice rather than an omission: business-scoped relay tickets extending the per-installation ones we
   already issue, an owner keypair each branch verifies offline against a monotonic revocation epoch,
   inter-branch transfers as two documents reconciled by reference rather than by transaction, and
   consolidated dashboards built from cached per-branch summaries each carrying its own "as of". It is
   sound. It is also months of work for zero current customers, and it puts a distributed-systems problem
   at the centre of a product whose whole advantage is that it does not have one.

   What decided it: every customer today is a single shop on-prem, so the offline promise holds for the
   product actually being sold and nothing about their deployment changes. A chain that opts into the
   cloud tier is buying a different product and can weigh its own uplink — availability there is the
   chain's problem, not ours to engineer around. Multi-branch is a small minority and not near-term
   (§10.1), so federation would have been building for a hypothetical.

   The market was checked in both directions rather than assumed. Cloud is ~70% of ERP deployments and
   ~79% of new ones, with on-premise growing ~2% a year against 13–20% — but retail runs the other way at
   store level, where 65% of retail CIOs made edge computing a 2025 priority and every major POS vendor
   ships an offline mode (Toast designates a local hub device on the store LAN; ours is a whole backend,
   which is strictly stronger). So: keep the store-level edge architecture, which is the genuinely
   contrarian and genuinely load-bearing part, and decline the federation layered on top of it.

   Consequences are recorded against **1b** and **Phase 2**. Do not re-open without a named chain customer
   and economics that have changed.

7. **Serialized inventory: promote it over the rest of the register?** (new, 2026-09-13) The plan is
   written, the prospect is named, and §5.1 argues its original *Later* ranking was a category error.
   The counter-argument is that it is sized **L** and would consume the same weeks as items 2, 3 and 4
   of §5.4 combined — three cheap things with no customer waiting on them, one of which (naming series)
   has a deadline. **Recommendation: do 5.3 (naming series, S) alongside it rather than after it**, and
   let 5.2 follow, because serialization is the only item where waiting costs a deal rather than an
   afternoon of migration.

8. **Does the register profile finish, or stay narrow?** (new, 2026-09-13) `RegisterProfile` was carved
   out for exactly one field because that was what locations needed. ERPNext's POS Profile also carries
   payment modes, price list and discount permissions, all of which are global `ShopSettings` here.
   Nothing has asked for them. The decision is whether to complete the shape now, while the model is
   new and empty, or to keep adding fields to it one customer request at a time — which is what
   `ShopSettings` itself is, and is why it needed carving.

### 10.9 — A note on how this document failed between reconciliations

Recorded because the failure mode will recur. Between 2026-08-26 and 2026-09-13 this plan went stale in
three distinct ways, and only the first is the obvious one:

1. **Shipped work not marked shipped.** Phases 1a, 2 and most of 3 completed without the doc changing.
   Annoying, easily fixed, and the least interesting.
2. **A ranking that could not see its own consequences.** Phase 2 shipped and *created* the gap at §5.2,
   which was sized and scheduled in Phase 6 by a ranking written before the thing existed. A phased plan
   cannot notice this on its own: each phase is checked against the plan, never the plan against the
   phase.
3. **A deferral whose expiry condition passed silently.** §10.3 wrote its own revisit trigger and nothing
   watched it. The condition fired on 2026-09-06 and was noticed a week later only because someone read
   the whole document top to bottom.

The cheap mitigation for (2) and (3) is the same: **every phase completion re-reads §5 and §10, not just
its own section.** A conditional deferral with no watcher is a decision that expires into an omission.
