# Multi-Currency & Exchange Rates — Architecture Plan

**Date:** 2026-08-30 (Track A implemented 2026-08-31)
**Status:** **Track A shipped.** Phases 0, 1, 3 and the display slice of 5 are
built and tested end to end — the currency spine, the relay-fed fulus.ly feed
(webhook + polling backstop), per-product pricing currency, and the POS/settings
surfaces. Track B (phases 2 and 4 — foreign-currency *transactions*) remains
deliberately unbuilt; see §11. This document stays the architecture spec.
**Mirror project:** [frappe/erpnext](https://github.com/frappe/erpnext) — multi-currency
is one of the five primitives [ERPNEXT_BENCHMARK_PLAN.md](ERPNEXT_BENCHMARK_PLAN.md) flagged
as worth porting. That plan currently defers it (§8, anti-goal 3: *"until a signed customer
needs it"*). This document exists to price the work so that deferral is a decision rather
than an assumption.

---

## 1. Goal

Let a Libyan shop that thinks in more than one currency keep books it can trust:

- a **shop base currency** (LYD) that every report, total and balance is stated in;
- **live parallel-market rates**, fed from `fulus.ly` through our relay, behind the
  relay subscription — plus **manual rates** the owner can type and pin;
- **per-product pricing currency**, so an importer's dollar price sheet stays a dollar
  price sheet and converts at the till;
- optionally, **true foreign-currency transactions** — taking payment in USD, holding a
  USD cash box, carrying a USD receivable — with the exchange gain or loss made visible
  rather than swallowed.

The guiding rule, same as every other plan in this repo: **reuse the rails Pointy already
has.** The rate feed is the holidays sync. The entitlement is the AI entitlement. The
"one definition per figure" guard is `money_dates.py`. Nothing new gets invented that an
existing pattern already answers.

---

## 2. Where we start from

An audit of the money layer (2026-08-30):

| Surface | Today |
|---|---|
| `ShopSettings.currency_code` / `currency_symbol` | Display strings. Nothing reads them arithmetically. |
| Money columns | **273 `DecimalField`s** across 13 apps, none carrying a currency. |
| Aggregation | **154 `Sum()`** calls that assume every row is commensurable. |
| Frontend | `formatMoney(double)` against a **global mutable symbol**; **391 call sites / 78 files**. |
| Backend receipts | `POINTY_CURRENCY_SUFFIX` / `POINTY_CURRENCY_LATIN` settings, injected as a string. |
| Price lists | **Do not exist.** There is no price-list concept to hang a currency on. |
| Valuation | FIFO / LIFO / moving-average, single currency by construction. |
| Oracle | `business_simulation.py`, **5,088 lines**, proves every money value — in one currency. |
| Tests | 2,204 backend, 1,033 frontend. |

This is a **clean** single-currency system, not a half-finished multi-currency one. That is
worth a lot: there are no partial conversions to unpick, and the conversion boundary can be
placed deliberately instead of discovered.

Two existing patterns do most of the architectural work for us:

- **`apps.holidays`** — relay-managed reference data, synced into Django on a schedule,
  reconciled by stable key, local rows outrank relay rows, and an unreachable relay is a
  **soft no-op**. That is exactly the shape of a rate feed.
- **`apps/core/money_dates.py`** — one statement of which column means "when the money
  moved", with `test_money_definitions` failing any surface that hand-rolls its own answer.
  Multi-currency needs the identical discipline for *which currency a figure is in*.

---

## 3. Prior art

### 3.1 ERPNext — the one idea to steal

ERPNext's entire multi-currency model reduces to **store both amounts, freeze the rate on
the document**:

- `Company.default_currency` is the base. Immutable once transactions exist.
- Every transaction (Sales Invoice, PO, Payment Entry) carries `currency` +
  `conversion_rate`, and **every** money field has a `base_*` twin — `rate`/`base_rate`,
  `amount`/`base_amount`, `grand_total`/`base_grand_total` — computed once at submit and
  **stored**, not derived on read.
- `GL Entry` carries `account_currency` plus both `debit` and `debit_in_account_currency`.
- **Stock valuation is always company currency.** A foreign purchase converts once, at
  receipt, using the document's frozen rate.
- `Currency Exchange` is the manual rate table: `(from, to, date, rate, for_buying,
  for_selling)`. Lookup is **on-or-before the transaction date** — never "latest".
- `Currency Exchange Settings` defines a rate provider by **URL template + JSON key path**,
  so the external service is configuration, not code.
- Exchange gain/loss is booked when a payment settles an invoice at a different rate, and
  `Exchange Rate Revaluation` restates open foreign balances at period end.

The dual-amount trick is the lever that decides our entire cost. If every existing column
keeps meaning *base currency*, then all 154 `Sum()`s, the treasury position, the valuation
engine, payroll, the discount engine and the oracle stay **correct without being touched**.
Multi-currency becomes a conversion boundary at document entry and at display — not a
rewrite of every money path in the product.

### 3.2 ERPNext — the idea to refuse

**Per-item currency does not exist in ERPNext, deliberately.** Currency lives on the
**Price List**; an `Item Price` belongs to a price list, so "this item costs $12" is really
"this item costs 12 on the USD price list". That is the more general answer and it is the
right one for a company running six customer-specific pricing tiers.

We have no price-list concept at all. Building one is a feature in its own right, and it
answers a question Libyan shops are not asking. What they *are* asking is narrower and
real: *"my supplier's sheet is in dollars, I sell in dinars at today's rate."*

So: **`Product.pricing_currency`** — a **pricing** attribute that resolves to a base-currency
price at cart time. Not a per-line ledger currency. 80% of the value at roughly 5% of the
cost, and it does not foreclose price lists later.

### 3.3 Odoo, for contrast

Odoo attaches currency to the *journal* and the *pricelist*, and revalues automatically at
period close. Same conclusion: nobody puts currency on the product record. We are choosing
to, for a specific market reason, and we should be explicit that it is a deviation.

---

## 4. The rate source: fulus.ly

Verified against their live docs (2026-08-30):

| | |
|---|---|
| Base URL | `https://fulus.ly/api/v1` |
| Auth | Bearer token, per-account, from their dashboard |
| Gating | `403` when the **subscription is inactive** |
| Rate limit | Daily quota, resets **midnight UTC+2** |
| Endpoints | `GET /rates/current`, `GET /rates/history`, `GET /currencies`, `GET /rates/banks` |
| Pairs | 8 against LYD — USD, EUR, GBP, TRY, EGP, TND, SAR, AED |
| Rate series | **`cash`** and **`bank`** (13 named Libyan banks) — **both parallel-market**; see below |
| Webhooks | `rate.created`, POST to our URL, **HMAC-SHA256** in `X-Webhook-Signature` |

Three things follow directly from that table:

1. **Their quota is daily and their subscription is per-account.** N shops each polling
   fulus directly is both expensive and rate-limit-fragile. One relay-held subscription,
   fanned out, is the only sane topology — and it is precisely why this belongs behind
   *our* subscription.
2. **Webhooks mean the *relay* does not poll fulus on a tight loop.** The relay registers
   one endpoint and verifies the HMAC, so a published rate reaches the relay within seconds
   without spending their daily quota. (A poller sweeps as a backstop — a webhook is one
   delivery attempt, and a lost push would otherwise be invisible.)

   **The relay→shop leg is a PULL, not a push.** Shops call `GET /v1/exchange-rates?since=…`
   on a schedule; nothing is pushed down the connector tunnel. That is a deliberate
   simplification — the tunnel exists for shop-initiated traffic and a push path would be a
   second delivery mechanism to keep correct — but it does mean a shop's rates are as fresh
   as its sync interval, not as fresh as the webhook.
3. **Every rate fulus publishes is a parallel-market rate — the bank series included.**
   The `bank` rates are *not* the official CBL rate. They are the parallel rate you get
   when you settle **through a bank** — a transfer, a letter of credit, a certificate —
   instead of handing over physical cash, and they are published per bank because that
   price differs by bank. The distinction is therefore the **settlement instrument**, not
   official-versus-parallel, and the question setup asks the owner is *how do you actually
   pay for your goods?* A shop that wires money but prices off the cash series carries the
   cash/transfer spread as a silent error on every import. We never carry an official rate
   at all: if one is ever wanted it is a different source with a different meaning, not
   another value of this field.

---

## 5. Architecture

### 5.1 The core decision, in one line

> **Every existing money column keeps meaning "base currency". Foreign amounts arrive as
> additional columns alongside a rate frozen on the document.**

```
        FOREIGN                      BOUNDARY                    BASE (LYD)
    ┌─────────────┐          ┌──────────────────────┐      ┌──────────────────┐
    │ amount      │          │  rate frozen ON the  │      │ every existing   │
    │ currency    │  ──────▶ │  document at the     │ ────▶│ DecimalField     │
    │             │          │  moment of truth     │      │ (273 of them)    │
    └─────────────┘          └──────────────────────┘      └──────────────────┘
      what the user             stored, never                reports · treasury
      typed / the price         recomputed on read           valuation · payroll
      sheet says                                             oracle · discounts
                                                             ── all UNCHANGED ──
```

Everything downstream of the boundary is already correct and already tested. That is the
whole trick, and it is why this is a 3-week feature or a 10-week feature depending on
where we choose to put the boundary — not a 30-week one.

### 5.2 Rate feed topology

```
   ┌──────────┐   webhook: rate.created            ┌───────────────────────┐
   │ fulus.ly │ ─────────────────────────────────▶ │      pointy-relay     │
   │          │   HMAC-SHA256 verified             │                       │
   │  /rates  │ ◀───── nightly reconcile ───────── │  · fulus client       │
   │  /current│         (quota-budgeted)           │  · rate store         │
   │  /history│                                    │  · fx_enabled gate    │
   └──────────┘                                    │  · admin override/pin │
   ONE subscription, held by us                    └───────────┬───────────┘
                                                               │
                                    push over connector tunnel │  (+ pull on boot,
                                                               │   like holidays)
                    ┌──────────────────────┬─────────────────────────┐
                    ▼                      ▼                         ▼
              ┌───────────┐          ┌───────────┐             ┌───────────┐
              │  shop A   │          │  shop B   │             │  shop C   │
              │ apps.fx   │          │ apps.fx   │             │ apps.fx   │
              │ ExchangeRate rows    │           │             │  (offline)│
              │ source=relay         │           │             │ last-known│
              │ source=manual ← wins │           │             │ + stale   │
              └───────────┘          └───────────┘             │   badge   │
                                                               └───────────┘
```

Reconciliation rules, lifted wholesale from `apps.holidays.services`:

- Upsert by `(base, quote, instrument, bank_code, effective_at)`.
- The relay is authoritative for rows it owns (`source="relay"`).
- **A manually entered rate (`source="manual"`) always wins** and is never
  auto-overwritten — the owner's typed number is the owner's number.
- **The relay being unreachable is a soft no-op.** Last-known rates persist, stamped with
  their age. A sale never waits on a network call.

### 5.3 Where conversion happens — and when the rate freezes

The rate must be pinned at one identifiable moment, or a cart priced at 10:00 and paid at
10:30 produces a receipt that does not reconcile. Parallel rates in Libya move hourly.

```
  POS                                                        PURCHASING
  ───                                                        ──────────
  cart opened ──▶ rate LOCKED on the cart                    PO drafted ──▶ rate quoted
       │          (shown to the cashier)                          │
       │                                                          │
  lines added ──▶ each foreign-priced product                submitted ──▶ rate LOCKED
       │          converts at the LOCKED rate                     │        on the PO
       │                                                          │
  checkout ─────▶ rate SNAPSHOTTED onto the Order            received ────▶ cost converts
       │          + every line                                    │        ONCE at the
       │                                                          │        PO's rate
  receipt ──────▶ prints the rate it used                    valuation ──▶ base currency,
                                                                           always
  ───────────────────────────────────────────────────────────────────────────────────
  Rule: a document's rate is written once and never recomputed. Re-reading a rate on
  display is the bug that silently rewrites yesterday's margin.
```

That last line is the correctness thesis applied to FX, and it is the single most
important sentence in this document — see §8.2.

### 5.4 Per-product pricing currency

```
  Product.pricing_currency = USD          ShopSettings.base_currency = LYD
  ProductVariant.unit_price = 12.00       ShopSettings.fx_instrument = cash
                    │
                    ▼
        rate_on(cart.locked_at, USD→LYD, cash) = 6.85
                    │
                    ▼
  POS shows:   ‏12.00 $  ≈  82.20 د.ل        ← both, always, never just one
  Cart line:   unit_price = 82.20 (base, as today)
               price_currency = USD, price_amount = 12.00, price_rate = 6.85
  Receipt:     82.20 د.ل   (12.00 $ @ 6.85)
```

`ProductUnit.price` and `ProductVariant.unit_price` inherit the product's pricing currency.
Null `pricing_currency` means base — so **every existing product is untouched and every
existing test keeps passing**.

One consequence to catch early: the **purchase-cost guard** compares an entered cost against
the sale price and the previous cost. Under mixed currencies it will fire constant false
positives unless both sides are normalised to base first. This is structurally the same
trap as the UoM phantom-loss bug class — a foreign-scale number meeting a base-scale
number — and it gets the same fix: one accessor, used everywhere.

### 5.5 Schema

```
core_currency                       ← seeded, not user-CRUD initially
  code (PK, ISO 4217)               USD, EUR, LYD, TRY, ...
  symbol_ar, symbol_en              ‏$ / د.ل
  decimals                          2
  rounding                          smallest transactable unit
  is_enabled

fx_exchangerate
  base_code, quote_code             LYD ← USD
  instrument                        cash | bank   ← BOTH parallel-market. How the
                                    shop settles, not official-vs-parallel.
  bank_code                         "" unless instrument=bank; the per-bank series
  effective_at                      timestamptz
  rate                              numeric(18,8)
  source                            relay | manual | builtin
  relay_id, fetched_at
  UNIQUE (base, quote, instrument, bank_code, effective_at)
  INDEX  (base, quote, instrument, bank_code, effective_at DESC)  ← on-or-before lookup

core_shopsettings  (+)
  base_currency            FK → core_currency, default LYD
  fx_enabled               bool
  fx_instrument            cash | bank   ← how this shop pays for foreign goods
  fx_bank_code             ""  unless fx_instrument=bank
  fx_manual_only           bool      ← shop opts out of the feed entirely
  fx_staleness_hours       int       ← warn the cashier past this age

catalog_product  (+)
  pricing_currency         FK → core_currency, NULL = base

--- Phase 2 only (true foreign-currency transactions) ---
<every transactional document>  (+)
  currency                 FK → core_currency
  exchange_rate            numeric(18,8)      ← frozen, never recomputed
  <field>_in_currency      numeric            ← the twin, per money field
  rate_source              relay | manual
  rate_effective_at        timestamptz

  applies to: sales.Order, sales.OrderLine, sales.OrderAdjustment,
              purchasing.PurchaseOrder, purchasing.PurchaseLine,
              purchasing.SupplierPayment, payments.Payment,
              expenses.Expense, treasury.MoneyTransfer, treasury.MoneyCount,
              treasury.MoneyAccount (currency only — an account IS one currency)
```

### 5.6 The guard

`money_dates.py` exists because the profit report once filtered sales on `created_at` and
payroll on `payment_date` inside one period, and produced a number that included the wage
and excluded the sale that paid it. The FX equivalent of that bug is a report that sums a
base-currency column and a foreign-currency column into one total.

So: **`apps/core/money_currency.py`** — one registry naming, for every money column in the
product, which currency it is denominated in, with `test_money_definitions`-style
enforcement that a new money column cannot be added without declaring it. Adding a money
field means adding a line. A surface that sums across currencies fails the suite.

This is non-negotiable and it is cheap. It is also the artefact that makes the *marketing*
claim in §8.2 defensible rather than aspirational.

---

## 6. Phasing

| Phase | Scope | Effort | Status |
|---|---|---|---|
| **0 — Currency spine** | `Currency` registry; `ExchangeRate` + on-or-before resolver; `Money` value type (Python + Dart); the `money_currency` guard; backfill migration stamping every existing row LYD @ 1.0 | ~1 wk | ✅ shipped |
| **1 — Rate feed** | **Relay (Go):** fulus client with quota budget + cache, rate store, `/v1/exchange-rates/{current,history}`, HMAC webhook receiver, connector fan-out, `fx_enabled` entitlement mirroring `ai_enabled`, admin override/pin UI. **Django:** `apps.fx` sync service + Celery beat, soft no-op offline, manual-wins reconciliation. **Flutter:** rates screen in Settings — list, staleness badge, manual entry, rate-type picker | ~1.5 wk | ✅ shipped |
| **2 — Transaction currency** | `currency` / `exchange_rate` / `*_in_currency` twins across ~12 models; cart rate-lock; conversion boundary at checkout, PO receipt, payment recording; valuation pinned to base at the receipt boundary; serializers expose both; **extend the 5,088-line oracle to prove FX arithmetic** | ~3 wk | ⬜ Track B |
| **3 — Per-product pricing currency** | `Product.pricing_currency`; resolution at catalog read; POS dual display; price-checker kiosk + barcode labels; normalise the purchase-cost guard | ~1 wk | ✅ shipped |
| **4 — Settlement & position** | Realized FX gain/loss on آجل settlement, surfaced as its **own named component** in the treasury breakdown; `MoneyAccount.currency`; per-currency money position; revaluation at a chosen rate; report breakdowns | ~2 wk | ⬜ Track B |
| **5 — Presentation** | `formatMoney` → `Money` across **391 call sites**; dual rendering on ESC/POS receipts, PDF invoices, POs, Z-report, labels; ar/en l10n for 8 currencies; AI tools currency-aware | ~1.5 wk | ◐ display slice shipped |

**Full scope: ~10 weeks** (range 9–11), plus an estimated 250–350 new tests to hold the
current bar.

### 6.1 Two tracks

```
  TRACK A — "prices in dollars, money in dinars"        TRACK B — "money in dollars too"
  ══════════════════════════════════════════           ═══════════════════════════════
  Phase 0  currency spine                              Phase 2  transaction currency
  Phase 1  relay + fulus feed                          Phase 4  settlement & position
  Phase 3  per-product pricing currency                Phase 5  remainder
  Phase 5  display slice (POS/receipt only)

  ≈ 3–3.5 weeks                                        ≈ +6.5–7.5 weeks
  Ledger stays strictly single-currency.               Ledger becomes multi-currency.
  No dual-amount columns. No FX gain/loss.             FX gain/loss becomes a real
  No oracle changes. No treasury changes.              concept the owner must understand.
  Every existing test passes untouched.                Oracle + treasury must be extended.

  Covers: importers, wholesalers, auto-parts,          Covers: shops that physically take
  electronics, pharmacy — anyone whose COST            and hold foreign cash, or extend
  is foreign and whose PRICE is local.                 credit denominated in foreign
                                                       currency.
```

**Track A is the recommendation.** It is where the demand is, it carries almost no
correctness risk, and it leaves Track B fully available.

---

## 7. What this buys us — functionality

1. **An importer's price sheet stops being retyped.** Today a shop importing from Turkey or
   China maintains dollar costs in a notebook and re-keys dinar prices every time the rate
   moves. `pricing_currency` + a live feed makes that a background fact instead of a weekly
   chore. This is the single most-requested thing that no Libyan POS does properly.
2. **Margins stop lying.** A shop buying in USD and selling in LYD currently records cost at
   whatever dinar figure was typed on purchase day. Six weeks and a 10% currency move later,
   the gross-profit report is confidently wrong. With the rate frozen per document and
   valuation pinned to base, margin is computed against what the goods actually cost.
3. **Repricing becomes a decision, not an emergency.** Because we hold rate *history*, we can
   show "these 340 products are priced off a rate that is 9 days and 6% stale" and offer a
   one-tap reprice with a preview. Nobody else in the market can do this, because nobody
   else has the history.
4. **The AI assistant gets something worth saying.** "The dollar moved 3% this week. 40% of
   your stock is dollar-priced. Your margin on these 12 lines is now negative." That is a
   proactive hint with obvious money attached — far stronger than the generic engagement
   hints we have today.
5. **The purchase-cost guard gets sharper, not noisier.** Once both sides normalise to base,
   the guard can distinguish "you typed the dollar price into the dinar box" — a very common
   real error — from a legitimate price change.
6. **Track B, when it lands, closes آجل exposure.** A dollar-denominated receivable settled
   weeks later at a different rate is real money gained or lost. Today that is invisible.
   Making it a named line in the treasury breakdown is consistent with that module's stated
   doctrine of never hiding a guess.

---

## 8. What this buys us — market and competition

### 8.1 The competitive picture

From the Aug-2026 vendor scan:

| Vendor | Currency story |
|---|---|
| **Aboghris** (أبوغريس) | Single currency. Best legacy data model in the field — real UoM, per-unit barcodes, moving-average cost — but no FX. |
| **Al Medad** (المداد) | Full suite on paper; no evidence of any FX handling. |
| **مستند / منظومة التاجر** | **The only rival advertising FX repricing.** Manual rates, entered by the shop. No feed, no history, no rate-type distinction. |
| **Fahd** (فهد) | Technically weakest in the field; deletes its own sales history at year-end. No FX. |
| **IFW Soft** | The only local rival with a real double-entry GL — so structurally the most *capable* of multi-currency — but a one-person shop, cloud-only, offline-incapable. |
| **Phenix** (فينيكس) | Not Libyan. Mature ERP, multi-currency present, but Gulf-oriented and sold here through one reseller. |

So the honest read: **one rival claims the feature, manually. Nobody in Libya has a live
parallel-market rate feed.** Multi-currency moves us from "missing a checkbox التاجر ticks"
to "the only system in the country where the rate arrives by itself."

### 8.2 The positioning — FX as an instance of the truth wedge

Our thesis is that every Libyan legacy system produces numbers shops cannot trust, and that
our single-authoritative-backend architecture is the thing rivals cannot copy without a
rewrite. FX is that argument's best demo, because the failure is arithmetic and visible:

> A system that stores one dinar figure per line and reprices with today's rate has
> **rewritten yesterday's margin**. It will tell you that you made 200 dinars on a sale
> where you actually made 40 — and it will tell you that *differently tomorrow*.

Freezing the rate on the document, and being able to *print the rate the sale used on the
receipt*, is a claim that can be demonstrated in ninety seconds in front of a shop owner.
It is the same betrayal-event mechanic that converts on the anti-theft pitch, applied to
currency. And §5.6's static guard is what lets us make the claim without hedging.

Note the discipline this implies: **the rate on the receipt is a feature, not clutter.**

### 8.3 The commercial angle — a renewable in a market with no subscriptions

The hard constraint from the market study: Libyan shops pay **once**, around 1,000 LYD,
"support forever". Zero subscriptions across 45 surveyed listings. There is no
recurring-billing rail — no card-on-file, Sadad caps at 1,500 LYD per transaction.

A live exchange-rate feed is one of the very few things in the product whose value
**visibly expires**. Nobody argues that last month's dollar rate is still worth paying for.
That makes it structurally the best renewal hook we have besides AI and remote access — and
it slots into the relay subscription that already exists, with an `fx_enabled` flag beside
`ai_enabled` and `relay_enabled`, no new billing machinery at all.

The economics are favourable in the other direction too: **we hold one fulus.ly
subscription and fan it out over the connector tunnel.** Marginal cost per shop is
approximately zero; their daily quota is consumed once, by us, not N times by N shops.
Price it in **LYD**, annually, collected in cash at renewal like everything else.

### 8.4 Segment unlock

Currency exposure sorts the market by willingness to pay, and it sorts it in our favour:

- **Importers and wholesalers** — cost in USD/EUR/TRY, price in LYD. Highest pain, highest
  ACV, and the segment least served by the paper notebook.
- **Auto parts** — a natural adjacency we already have proven migration intel for (Fahd's
  25-year auto-parts system), and a category where dollar price sheets are universal.
- **Electronics and mobile phones** — dollar-quoted stock, fast-moving rates, thin margins
  that a stale rate erases entirely.
- **Pharmacy** — imported stock, and Aboghris's flagship vertical. FX is a wedge into their
  strongest position.

These are all above the corner-grocery ceiling of 1,000–1,500 LYD/yr and sit nearer the
3,000–6,500 mid-supermarket band.

### 8.5 What this does *not* change

Per the GTM play sequence: **do not lead with FX.** Reliability remains the wedge and
protection remains the pitch. FX is (a) a **closer** for the import-exposed segment, (b) a
**renewal hook**, and (c) a **checkbox neutraliser** against التاجر. It is not the headline,
and building it does not change the priority of the accounting spine or the stampable
paper-ledger export, both of which outrank it for the core market.

---

## 9. Anti-goals

1. **No price lists.** Currency on the product, not on a pricing tier. If per-customer
   pricing is ever needed it gets designed then, on its own merits.
2. **No general ledger, still.** FX gain/loss surfaces as a named component in the treasury
   position — derived, like every other balance in that module — not as journal entries.
3. **No currency on the POS tender by default.** Track A ships with the till taking base
   currency only. Mixed-tender foreign cash is Phase 4 and only if a shop asks.
4. **No automatic revaluation of stock.** Inventory is valued in base currency at the rate
   frozen on receipt, permanently. Restating stock value when the rate moves is an
   accounting decision no Libyan shopkeeper has asked us to make for them.
5. **No blocking on the network, ever.** A missing or stale rate degrades to last-known with
   a visible badge. It never stops a sale. Power cuts and generator restarts are the
   operating environment, not the exception.
6. **No second base currency.** The shop has exactly one, chosen at setup, immutable once
   money exists — same rule ERPNext enforces, for the same reason.
7. **No tax interaction.** Per `AGENTS.md`, tax stays out until explicitly asked for.

---

## 10. Risks

| Risk | Mitigation |
|---|---|
| **Hourly rate movement breaks receipt reconciliation** | Explicit rate-lock at cart open; the rate is written once to the document and printed on the receipt. |
| **Costing off the wrong settlement instrument** | Both fulus series are parallel-market; the cash/bank spread is a real difference in what foreign goods cost this shop. `fx_instrument` is a required setup choice, displayed in POS, snapshotted per document. |
| **Foreign cost meeting base price** — the UoM phantom-loss bug class, repeated | Convert once at the receipt boundary; route every read through one accessor, exactly as `base_unit_cost` did. |
| **Oracle guarantees silently weaken** | Track A requires no oracle change. Track B treats extending the oracle as in-scope, not optional. |
| **fulus.ly quota / outage / vendor risk** | Relay caches and fans out one subscription; provider is configured by URL template + key path (ERPNext's pattern), so a second source is configuration. Manual rates always work. |
| **Webhook spoofing** | HMAC-SHA256 verified at the relay; shops never accept rate data from anywhere but the connector tunnel. |
| **391 `formatMoney` sites regress silently** | The `Money` type makes the old call signature a compile error, not a runtime surprise. |
| **Migration on live installations** | Expand/contract, per the zero-downtime update rules: add nullable columns + backfill LYD @ 1.0, then tighten. |

---

## 10a. What shipped (2026-08-31)

Track A, end to end. The pieces, and where they live:

**Backend — the spine**
- `apps/fx/money.py` — `Money`, `CurrencySpec`, `convert`; pure, Django-free.
  One rounding boundary, 2dp half-up, matching `catalog.units.quantize_money`.
- `apps/fx/currencies.py` — the nine-currency seed and the settlement-instrument
  vocabulary. No Django imports, so `core.models` reads it without a cycle.
- `apps/fx/models.py` — `Currency` (PK = ISO code) and `ExchangeRate`
  (`from`/`to`/`instrument`/`bank_code`/`effective_at`), append-only.
- `apps/fx/rates.py` — the on-or-before resolver, the fallback ladder, the
  staleness answer, and the only conversion entry point.
- `apps/core/money_currency.py` + `apps/fx/test_money_currency.py` — the guard.
  Mutation-tested: unregistering a foreign column, importing `convert` outside
  `apps/fx`, or hand-rolling a rate query each fail it.

**Backend — the feed and the pricing**
- `apps/fx/services.py` — seeding, manual rates, and the relay sync (holidays'
  reconciliation rules, with manual rows never overwritten).
- `apps/fx/{serializers,views}.py` + routes — currencies, rates, `current`,
  `manual`, `sync`, and the two-step repricing endpoints.
- `apps/catalog/pricing.py` — `set_foreign_price`, `reprice_preview`,
  `apply_reprice`. One rate lookup per currency, not per row.
- `ShopSettings.fx_*`, `Product.pricing_currency`, and the frozen
  `price_amount`/`price_rate`/`price_rate_at` trio on variants and units.

**Relay**
- `FXEnabled` entitlement (independent of remote access, like AI), on both
  stores, in the admin form, and in migration 11 alongside
  `relay_exchange_rates`.
- `internal/relay/fulus.go` — the client and the HMAC webhook verifier.
- `internal/relay/fulus_poller.go` — **the backstop**. Webhooks are one delivery
  attempt over a network we do not control; a push lost to a restart or a
  dropped retry would leave the fleet pricing off a stale rate with nothing to
  notice it. The poller sweeps on an interval, collapses into the same rows via
  the natural identity, and parks until the quota resets on a 429.

**Frontend**
- Models, API client, repository, and the currency-aware formatters (with bidi
  isolates, so an Arabic paragraph cannot reorder the halves of a dual price).
- The exchange-rates settings page: current rates with provenance, staleness and
  substitution warnings, manual entry, and the repricing list.
- Dual pricing on POS catalog cards for foreign-priced products.
- **The product form's pricing-currency picker** (`pricing_currency_field.dart`)
  — a currency dropdown that stays hidden on a shop with no other currencies
  enabled, plus a live preview showing what the typed price becomes and at what
  rate. The client never computes the stored price: it sends `price_amount` and
  the server derives, so the conversion happens in exactly one place.

Closing the product form surfaced a real gap in the write path: the nested
`default_variant` and generated-`variants` payloads bypass
`ProductVariantSerializer` entirely (they write through
`ensure_default_variant` / a direct `objects.create`), so a foreign price sent
when *creating* a product would have been stored without ever deriving a base
one. Both paths now derive explicitly. A second bug the tests caught:
`pricing_currency` had been added only to the catalogue *summary* serializer, so
it was silently unwritable through the product API.

**Tests: 2,368 backend, 36 new frontend, and the full relay suite.**

Two things deliberately left for when they are needed: the `/rates/current`
response envelope is parsed tolerantly because the published fulus docs do not
pin its field names down (the *webhook* shape is verified), and no shop can take
payment in a foreign currency — that is Track B.

---

## 10a-bis. The buy side (2026-08-31)

`Product.pricing_currency` fixed the *sell* price. It did nothing for cost: a
purchase order had no currency, `unit_cost` was a bare dinar figure, and an
importer had to convert the supplier's invoice by hand with no record of the
rate used. Margin is `price − cost`, so half of "margins stop lying" was
undelivered.

**What was added.** `PurchaseOrder.currency` + a frozen
`exchange_rate`/`rate_effective_at`/`rate_source`, and
`PurchaseLine.unit_cost_in_currency` — what the supplier invoiced.
`unit_cost` stays base currency and is *derived* from it, which is why the whole
chain below it needed no change:

```
unit_cost → net_unit_cost → effective_unit_cost → effective_base_unit_cost
          → StockMovement → valuation engine → COGS → margin
```

**Three rules worth keeping:**

1. **The rate is read as of the SUPPLIER'S INVOICE DATE**, not the day of data
   entry, falling back to today when the order has no invoice date. An invoice
   billed on Tuesday and typed in on Sunday was priced at Tuesday's rate;
   costing it at Sunday's misstates the basis by however far the dinar moved —
   which is the exact error the feature exists to remove. The end of the
   invoiced day is used, not its midnight, so a rate published during that day
   counts.
2. **The conversion runs in serializer `validate()`, before the cost guard.**
   The guard compares a line's cost against the variant's selling price;
   leaving the line at 12 USD against an 82.20 LYD price would flag every
   foreign line as a catastrophic loss. Converting first meant the guard needed
   no changes at all — and it still catches a genuinely absurd foreign cost.
3. **A POS cash purchase refuses a foreign currency.** The drawer holds the
   shop's own cash; recording a converted figure against a pay-out that never
   happened in that currency would make the register reconcile against a number
   nobody counted. Foreign buying belongs on the purchasing screen.

**Deliberately still base currency:** landed costs and the order-level extra
discount. For a Libyan importer these are customs, clearing and local haulage,
paid in dinars on a foreign shipment — the common case, not a compromise.

**Still Track B:** supplier *payments* are unaware of currency. They settle a
dinar balance that was converted at order time, so a rate move between ordering
and paying is not recorded anywhere. That difference is realized FX gain/loss.

## 10b. Should the till reprice reactively? (studied 2026-08-31)

The question: when a rate moves, should a sale ring up at the new rate rather
than at the stored price? **Recommendation: no — and the current design should
not be softened toward it.** The reasoning, grounded in this codebase rather
than in principle:

### What a price is committed to, outside the database

A stored price is not the only place a number has been promised. Three surfaces
commit to it *before* the customer reaches the till, and none of them can be
retroactively corrected:

1. **Printed shelf and barcode labels.** `BarcodeLabel` carries `unitPrice`, and
   labels are physically stuck to shelves and stock. A reactive till would make
   every label in the shop wrong the moment a rate ticked — and in Libya the
   parallel rate moves several times a day.
2. **The price-checker kiosk.** `price_checker/pricing.py` reads
   `variant.unit_price` — the *same stored column*. Reactive pricing would let
   the kiosk and the till disagree between a customer checking a price and
   carrying the item to the counter. That is the single most damaging thing a
   POS can do to a shop's credibility with its own customers.
3. **What the cashier told the customer.** Verbal quotes are how most of these
   shops work.

### What it would cost internally

* **Latency on the critical path.** Checkout would gain a rate resolution per
  foreign-priced line. The plan's own anti-goal 6 — nothing slows the POS — was
  written for exactly this.
* **The oracle stops proving anything.** `business_simulation.py` recomputes
  every sale independently. A price that depends on wall-clock rate arrival is
  not reproducible, so the oracle could no longer assert a sale's total.
* **Reports become unstable.** Margin on a past sale would move whenever the
  rate history was re-read. That is the failure this whole design attacks.

### The argument *for* it, taken seriously

The honest case: with a hard-frozen price, a shop that does not reprice is
selling at yesterday's rate and eating the difference. In a currency falling ~28%
in nine months that is real money, and the shopkeeper we are selling to is
exactly the person least likely to run a repricing chore.

That case is about **staleness**, not about pricing at the till. It is answered
by making repricing effortless and visible, not by making the price a moving
target. What we have: the drift list, select-all, one confirm.

### The middle grounds, and where the line is

| Option | Verdict |
|---|---|
| Reprice at the till, per sale | **No.** Breaks labels, kiosk, quotes, oracle, reports. |
| Auto-reprice on a schedule (nightly) | **Defensible, opt-in.** A price that changes once a day, overnight, is a shelf price — labels can be reprinted with the day. Would need a printed-label staleness warning. |
| Auto-reprice on rate arrival | **No.** Same label/kiosk breakage as the till, just less often. |
| Nudge only — current behaviour | **Yes.** Drift is surfaced, the decision stays human. |
| Block the sale on a very stale rate | **No.** Never stop a sale; Libya runs on generators and intermittent links. |

If staleness proves to be a real field problem, the next step is the **nightly
opt-in auto-reprice**, gated on a shop setting, with the same preview available
after the fact — not reactive pricing at the till.

---

## 11. Recommendation

Build **Track A** — Phases 0, 1, 3 and the display slice of 5, about **3–3.5 weeks**.

That delivers relay-fed fulus.ly parallel-market rates behind the subscription, manual
rates that outrank the feed, and per-product foreign pricing that always settles in dinars.
The money layer stays strictly single-currency: no dual-amount columns, no FX gain/loss, no
treasury changes, no oracle changes, every existing test untouched.

Hold **Track B** (Phases 2 and 4 — foreign-currency *transactions*, foreign cash boxes,
foreign receivables) until a signed customer needs it. That is where the remaining ~7 weeks
and essentially all of the correctness risk live, and it is a faithful reading of the
existing anti-goal in `ERPNEXT_BENCHMARK_PLAN.md` §8.3 rather than a reversal of it.

The distinction worth holding on to: **Phase 3 is what shops are actually asking for.
Phase 2 is what they say when they mean Phase 3.**
