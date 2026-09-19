# Serialized & Batch Inventory (IMEI / Serial / Lot / Expiry) — Architecture Plan

**Date:** 2026-09-10 (Expanded 2026-09-17, Phases A & B shipped 2026-09-17,
Phase C shipped 2026-09-18, A & B reviewed 2026-09-18, C reviewed 2026-09-19)
**Status:** **Phases A, B and C shipped** — the shared allocation core and
ledger, the shop operating both from the client, and the used-goods trade with
consignment carrying a real liability (§15). Phases D–E remain proposed.
Five things in this document were changed by building it, and each is marked
**CORRECTED** or **DEFERRED** in place rather than quietly rewritten: the batch
bin's treatment of a quarantined lot (§5.3), landed-cost re-stamping on
identified stock (§5.5), the till's own knowledge of its warehouse (§15,
Phase B), the shape of invariant 10 (§5.4), and the trade-in's tender (§6.2).
**Four more were changed by *reviewing* it** (§15.2), and they are the ones to
read first, because each is a claim this document made that turned out to be
untrue: the batch split did **not** ship as R1 of §15.1 (§15, Phase A), no
printed receipt ever carried an identifier (§15, Phase B), the GS1 parser's
most valuable test could not fail (§15, Phase B), and selling without picking
is **not** refused (§6.3).
**Reviewing Phase C found thirteen more** (§15.3). Two of them are claims this
document makes that were not true of the code: the voucher whose clause is
stored *"as it was printed"* was never printed at all, and per-unit pricing was
per-*variant* pricing the moment one invoice held two of the same model — which,
for the trade Phase C is about, is the ordinary case and not the edge one. Read
§15.3 before building on any of it.
**Roadmap slot:** Promotes and unifies Gap #13 ("Serial-number tracking", sized M)
and Gap #14 ("Batch & lot tracking with FEFO/expiry", sized M). This plan combines
them because they share 80% of the underlying ledger allocation architecture,
simultaneously unlocking high-value trades (phones, electronics, luxury, consignment)
and date-sensitive trades (pharmacies, cosmetics, food/grocery, tyres, chemicals).
**Mirrors inspected:** ERPNext `develop` (doctype JSON read, not recalled), Odoo's
`stock.lot`, Shopify's absence of both.

The whole plan is written against one constraint, and it is the one to re-read
whenever a decision here looks arbitrary:

> **A shop that sells Coca-Cola must not be able to tell that this shipped.**
> Not one extra field on the product form, not one extra tap at the till, not
> one extra query on checkout. Serialization and batch tracking are *opt-in shapes*
> for the products that need identity or cohort tracking, living inside the same catalog,
> the same ledger, the same receipt and the same reports as everything else.

And against one thesis:

> **A serial number or a batch code is not a text label on a sale. It is a costed, located, dated
> object or cohort with a life.** Everything correct about this feature follows from
> treating it as one; every bug ERPNext has shipped in this area follows from
> the times they didn't.
>
> - A **Serial Number** (`StockUnit`) is an identified article with **quantity = 1**
>   (individual life, condition, price, refurb cost, customer asset, consignment).
> - A **Batch / Lot** (`StockBatch`) is an identified cohort — a lot code, a
>   supplier, an expiry, a recall exposure — and it is **not a quantity and not a
>   place**. How much of it sits where is `StockBatchBalance`, one row per lot per
>   warehouse (§4.7). One lot code means one lot, wherever its goods currently are.
>
> They **compose**: a pharmaceutical pack is a serial *inside* a lot, which is the
> `serial_batch` mode of §4.2 and the shape GS1 healthcare has standardised on.
> Both hang off `ProductVariant` and share the exact same ledger allocation row
> (`StockAllocation`), which names a unit, a batch, or both. Implementing them
> together gives Pointy a general traceability engine for the engineering cost of
> one and a quarter, rather than a phone feature that needs surgery to become a
> pharmacy feature.


---

## 1. The problem, stated precisely

### 1.1 What the prospect actually does today

A used-phone shop we are selling to tracks every handset by its IMEI. Their
current POS has products and sub-barcodes and nothing else, so they worked
around it the only way that system allows: **they create one product per
physical phone.**

```
Product: iPhone 13 Pro 256GB Blue Battery86 IMEI351234567890111
Product: iPhone 13 Pro 256GB Blue Battery92 IMEI351234567890222
Product: iPhone 13 Pro 256GB Blue Battery79 IMEI351234567890333
```

Each is bought exactly once and sold exactly once. They know it is wrong. They
told us so before we told them.

### 1.2 Why that is not merely ugly

It is easy to file this under "untidy catalog". It is not. Every derived number
in a POS is computed *per product*, so a catalog where product ≠ product breaks
each of them in a different direction:

- **Nothing aggregates.** "How many iPhone 13 Pro did we sell last month" has no
  answer, because there is no iPhone 13 Pro — there are 340 products that share
  a prefix. Popularity, most-bought sort, purchase suggestions, RFM targeting,
  the bought-together window, reorder levels: all of them index a thing that
  exists once and is gone.
- **Valuation degenerates.** Every product has a stock history of exactly one
  receipt and one issue. Moving average, FIFO and LIFO are the same number on a
  queue of length one. The valuation engine we shipped on 2026-08-26 is doing
  nothing for this shop — and the moment they buy two identical phones and let
  the names collide, it is doing something *wrong*.
- **The catalog becomes the ledger.** Product count grows with transaction
  count, not with assortment. Fahd's migration taught us what a six-figure
  catalog does to search, to the POS grid, to `products` list latency, and to
  every screen that ever loads a name (`purchases-screen-perf`,
  `product-search-relevance`). This shop is on the same curve, slower.
- **Identity is untyped text.** `IMEI351234567890111` inside a name cannot be
  scanned, cannot be validated, cannot be looked up, cannot answer a warranty
  claim, and cannot be found when the police ask about a stolen handset. Which
  in a phone shop is not a hypothetical.
- **Archiving is a lie.** Every sold phone is a product that must be archived or
  the catalog is unusable; archive it and its sales history leaves the live
  catalog reports.

They are using the products table as an inventory-unit table. It works, in the
sense that a spreadsheet works. It is exactly the failure class our GTM thesis
attacks: *software that runs fine while producing numbers that quietly disagree
with reality* (`libya-gtm-positioning`).

### 1.3 The generalization, which is the actual reason to build it

If we build "IMEI tracking for phones" we will build it again for cars, and
again for generators. The layer that is missing is not phone-shaped. It is:

> **an identified, individually costed, individually located article of stock.**

The same object serves:

| Trade | Identifier | Unit-specific facts & features |
|---|---|---|
| Used phones & tablets | IMEI / Serial | battery health %, grade, storage, icloud/carrier lock, box & charger |
| Cars & motorized vehicles | VIN / chassis / plate | mileage/odometer, year, colour, engine no, keys count, title status |
| Generators, inverters & power | Serial | hours run, capacity/SOH %, output rating, manufacturer warranty |
| Laptops, PCs & workstations | Serial / Service Tag | CPU, RAM, SSD/HDD size, GPU, battery cycles/health, charger included |
| Cameras & photography gear | Serial | shutter count, sensor condition, included lens/cap/battery, grade |
| Gaming consoles & handhelds | Serial | storage capacity, firmware version, controllers count, box included, ban status |
| Luxury watches & fine jewellery | Case/Movement Serial or Cert No | weight (g), metal purity/karat, movement condition, original papers & box |
| Designer handbags & luxury goods | Serial / NFC / Cert ID | grade, hardware wear, dust bag included, authenticity certificate |
| Home appliances, TVs & audio | Serial | panel/lamp hours, screen size, stand/remote included, cosmetic grade |
| Bicycles, E-bikes & scooters | Frame Serial | motor wattage, battery SOH %, odometer KM, frame size, charger included |
| Power tools & equipment | Serial | voltage, brushless (bool), batteries count, charger included |
| Spare parts, tyres | DOT lot **and** casing serial | tread depth (mm), manufacture week/year |
| Consignment stock (any trade) | Serial / Code | consignor ID, agreed payout rate, reserve price |
| Medicine, food | Lot / Batch | expiry date (anonymous or identified lot) |
| Prescription pharmaceuticals | GTIN **+** lot **+** expiry **+** serial, in one GS1 DataMatrix | expiry, lot recall status, per-pack serial for verification |

Pointy already sells into phone repair and car workshops — two of the three
`ShopSettings.ShopType` values that exist for a reason
(`backend/apps/core/models.py:67`). Both of them buy and sell the very things
their workshop side already tracks by IMEI and VIN in `customers.Asset`
(`backend/apps/customers/models.py:255`). We track the customer's phone by IMEI
and cannot track our own. That asymmetry is the gap.

### 1.4 What we already have, and what is genuinely missing

Half of this is paid for, and it is worth being precise about which half.

**Already ours:**

- `Product → ProductVariant` with option values, signatures and per-variant
  price/SKU/barcode (`backend/apps/catalog/models.py:110,689`). The chat's
  "Product → Variant" layers *exist*; nothing needs inventing there.
- A valued, append-only stock ledger with per-warehouse bins, three valuation
  methods and a repost command (`backend/apps/inventory/models.py:408,451`,
  `valuation_service.py`).
- `StockItem(variant, warehouse)` quantity buckets, movements with
  before/after snapshots, reservations, transfers, blind stock count.
- An anonymous expiry cohort, `StockBatch` (`backend/apps/inventory/models.py:174`) —
  a batch in the accounting sense, with no code, no identity, no warehouse, and
  its quantity welded to the row that should be its identity (§4.7 splits them).
- A shop-editable registry of *kinds of identified thing*: `customers.AssetType`
  with `tracks_imei / tracks_vin / tracks_plate_number / tracks_engine_number /
  tracks_odometer / custom_identifier_label` (`backend/apps/customers/models.py:211`).
- Attachments on any owner, structured identity-conflict errors
  (`catalog/identity.py`), document lifecycle with freeze/cancel/blockers,
  a scan-burst guard, label printing, an oracle harness.

**How this must behave toward everything above — every setting, every flag, every subsystem — is §18**, which is an audit of what is actually in the codebase rather than a recollection of it.

**Missing:** three tables and one enum member — `StockUnit`, the balance that
lets `StockBatch` become an identity, `StockAllocation`, and a `tracking_mode`
that lets a serial and a lot describe the same pack — and everything that has to
know about them.

---

## 2. What ERPNext actually does

Read from `erpnext/stock/doctype/*/**.json` on `develop`, not from memory.

### 2.1 The flags live on the Item

```
has_serial_no        Check   depends_on is_stock_item
serial_no_series     Data    depends_on has_serial_no
has_batch_no         Check   depends_on is_stock_item
create_new_batch     Check   depends_on has_batch_no
batch_number_series  Data
has_expiry_date      Check   depends_on has_batch_no
shelf_life_in_days   Int
warranty_period      Data
```

An ERPNext *variant is an Item* (`variant_of` link), so in practice the flags
sit at variant granularity — which is the answer to the last question in the
chat: **serials hang off the variant, not the template.**

### 2.2 `Serial No` is a document, named by the number itself

`autoname: field:serial_no`, so the serial string *is* the primary key and is
globally unique. Fields worth stealing:

```
serial_no, item_code, batch_no, warehouse, purchase_rate, customer,
status (Active | Inactive | Consumed | Delivered | Expired)   read-only
warranty_expiry_date, amc_expiry_date, warranty_period,
maintenance_status (Under Warranty | Out of Warranty | Under AMC | Out of AMC)
asset, asset_status, location, employee, company, work_order,
reference_doctype / reference_name / posting_date        (where it came from)
```

Three things there matter: **the unit carries its own cost** (`purchase_rate`),
**its own customer**, and **its own warranty clock**. `status` is read-only —
derived from the ledger, not typed by anyone.

### 2.3 `Batch` is the same idea with a quantity

```
batch_id (unique, is the name), item, batch_qty, expiry_date,
manufacturing_date, parent_batch, supplier, reference_doctype/name,
use_batchwise_valuation (read-only, set_only_once),
allow_negative_stock_for_batch, disabled
```

`parent_batch` is batch splitting. `use_batchwise_valuation` is a per-batch
latch, set once, that decides whether this batch's own incoming rate is used or
the item's blended rate.

### 2.4 v15's `Serial and Batch Bundle` — the allocation layer

Before v15, a transaction line carried `serial_no` as a **Small Text field with
newline-separated numbers**. Their own migration guide says it plainly: *"The
Small Text field has a data integrity issue with the serial number."* v15
replaced it with a document:

```
Serial and Batch Bundle
  item_code, warehouse, has_serial_no, has_batch_no,
  type_of_transaction  (Inward | Outward | Maintenance | Asset Repair),
  entries  -> Table[Serial and Batch Entry],
  total_qty, avg_rate, total_amount,
  voucher_type, voucher_no, voucher_detail_no, posting_datetime,
  returned_against, is_cancelled, is_packed, is_rejected, amended_from
```

```
Serial and Batch Entry (child)
  serial_no (Link), batch_no (Link), item_code, qty, warehouse,
  incoming_rate, outgoing_rate, stock_value_difference, stock_queue,
  is_outward, delivered_qty,
  reference_for_reservation,
  voucher_type, voucher_no, voucher_detail_no, posting_datetime,
  type_of_transaction, is_cancelled
```

This is the important artefact of the whole study. **Each allocated serial or
batch carries its own `incoming_rate`, `outgoing_rate` and
`stock_value_difference`.** Per-unit costing is not a bolt-on in a real ERP; it
is the entry row.

### 2.5 The settings that reveal the shape

```
enable_serial_and_batch_no_for_item
pick_serial_and_batch_based_on           FIFO | LIFO | Expiry   (default FIFO)
auto_create_serial_and_batch_bundle_for_outward     default 1
use_serial_batch_fields                             default 1
allow_existing_serial_no                            default 1
auto_reserve_serial_and_batch                       default 1
allow_negative_stock_for_batch                      default 0
do_not_use_batchwise_valuation                      default 0
disable_serial_no_and_batch_selector
use_inline_serial_batch_editor                      default 1
```

`allow_existing_serial_no` is the trade-in case: a serial you sold can come
back. `pick_serial_and_batch_based_on` is the auto-allocation rule for outward
movements when the user does not pick by hand.

### 2.6 And their hard rule

**"Allow Negative Stock" is removed for serial/batch items from v15** — even
when the company-wide flag is on. You cannot sell a phone you do not have,
because there is no phone to name.

### 2.7 The other two mirrors, briefly

- **Odoo** unifies both into one model, `stock.lot`, with the product's tracking
  set to `serial` | `lot` | `none`; a serial is a lot whose quantity is one.
  Cleaner conceptually. It also means Odoo's serial UI is a lot UI, and it shows.
- **Shopify** is quantity-only. Phone shops on Shopify install a third-party
  serial app, because a variant with `inventory_quantity: 5` cannot say which
  five. The chat's read on this is correct and it is worth knowing: this is a
  category where the biggest SMB commerce platform simply does not compete.

---

## 3. Where ERPNext fails, and what we do instead

Their bug tracker is the most valuable part of the mirror. Every item below is a
decision we make *because* of what it cost them.

### 3.1 Serials as text on a line — the mistake with the highest price

They shipped it, ran it for a decade, and paid for it with a breaking migration
in v15 that broke every custom print format and every server script that touched
serials. The failure mode of a newline-delimited text column is not that it is
ugly; it is that **nothing can constrain it**: no foreign key, no uniqueness, no
count check against the line quantity, no way to attach a cost.

**We never store an identifier as text on a transaction line.** An allocation is
a row with a foreign key, from day one. This is not a hard rule to hold — it is
only hard to *retrofit*, which is the entire lesson.

### 3.2 The bundle is a separate submitted document, and it rots

Because the bundle is its own doctype with its own lifecycle, it can disagree
with the transaction that owns it. Their open issues are exactly that class:

- **#42997** — `batch_no` empty in Stock Ledger Entry after a Purchase Receipt.
  The allocation exists; the ledger row that reports on it does not know.
- **#43492** — a rejected (damaged) quantity's bundle **overwrites** the
  accepted quantity's bundle on the same receipt line.
- **#35804** — the newly created batch is not shown back to the user.
- Forum consensus after v15: a previously working batch flow became a second
  document users must create and reconcile by hand.

**Ours is not a document.** `StockAllocation` rows hang off the `StockMovement`
we already write, inside the same transaction, in the same service call. There
is no state in which an allocation exists and its movement does not. There is no
bundle to submit, to cancel, to amend, or to leave dangling — and no second
place for a cashier to go.

Corollary, stolen straight from #42997: **the allocation denormalises
`voucher_type` / `voucher_id` / `warehouse` / `posting_at`**, exactly as
`StockMovement.warehouse` and `StockLedgerEntry.voucher_id` already do. A row
that reports on stock must be answerable without a join to the thing that
created it.

And from #43492: **damaged units are units with `status = damaged`**, in the
same table, allocated by the same rows. Not a second bundle with a flag. The
receipt records what arrived; the unit records what state it arrived in.

### 3.3 A picker dialog is not a POS

ERPNext's outward flow is: add the item, open the Serial and Batch selector,
pick, close, save. `disable_serial_no_and_batch_selector` exists because that
dialog is in the way often enough to need an off switch.

**Our primary flow is one scan.** The cashier scans the IMEI — off the handset's
box, or off the label we printed when it arrived — and the line appears, with the
right unit, the right price and the right cost. No dialog, no selection, no
quantity. The picker sheet exists as the fallback for a device whose box is lost,
not as the path.

This is our natural advantage and it is worth stating why: we already resolve
scans through one funnel that knows about variant barcodes, carton barcodes and
scale barcodes (`frontend/lib/src/features/pos/view_models/pos_barcode_actions.dart`),
already guard wedge bursts (`barcode-scan-guard`), and already keep the search
field as resting focus (`pos-search-autofocus`). A serial is a fourth resolution
in a funnel that exists. In ERPNext it would be a fifth dialog.

### 3.4 Batch-wise valuation arrived late and had to be un-shipped

`do_not_use_batchwise_valuation` was a setting that let moving-average items
ignore batch rates; recent releases stopped honouring it for moving average
*because it produced wrong batch rates*. The lesson is that per-unit costing
cannot be an option layered onto a blended engine after the fact.

**For us, `unit_cost` is a valuation method, chosen by the product's tracking
mode, not a global setting.** A serialized variant is costed per unit, always.
There is no configuration under which a serialized item's COGS is a blended
guess, because there is no honest reason to want one.

### 3.5 Their negative-stock special case is a symptom

They had to *remove* negative stock for serial/batch items in v15 because the
company-level flag leaked into a path where it makes no sense. We already
predicted this shape: `apps/inventory/oversell.py` was written before there was a
second warehouse precisely so that "may stock go below zero here" has **one
function and one answer**.

**Serialization is the third input to that same function.** `may_oversell()`
gains a rule ahead of shop and warehouse policy: a serialized variant may never
oversell, whatever anyone has configured. One function, one answer, no leak.

### 3.6 Global uniqueness is the wrong constraint, and so is none

`Serial No` is named by the serial, so it is globally unique forever. That
forbids the trade-in — a phone you sold in March that walks back in in
September — which is why `allow_existing_serial_no` exists as a patch on the
naming rule.

Our `customers.Asset` went the other way and enforces *no* uniqueness, with an
explicit and correct comment: the right answer to "this IMEI is on file" is to
open the device you already know about.

Neither is right for stock. **The constraint is: at most one *in-stock* unit per
identifier.** Expressed as a partial unique index, it permits the full history of
a handset passing through the shop three times while making it impossible for
two of them to be sellable at once. §4.4.

---

## 4. The model

### 4.1 Where the unit hangs

```
ProductCategory
   └── Product              tracking_mode, asset_type, warranty_days
         └── ProductVariant  option values, SKU, barcode, list price
               └── StockUnit  identifier, own cost, own price, own attributes,
                              own location, own status, own warranty
```

**The unit hangs off the variant.** This is the chat's conclusion and it is right,
and in Pointy it costs nothing to adopt because every product already has at
least a default variant (`Product.ensure_default_variant`) and *all* stock, all
ledger entries and all bins are already keyed on the variant. A product with no
options is a product with one variant, and its units hang off that.

So the answer to "do I need variants **and** serials?" is: you already have
variants, and you turn on serials. A used-phone shop defines *iPhone 13 Pro* with
options Storage and Colour — that is four or six variants, the things that are
genuinely interchangeable-in-kind — and every physical handset is a unit under
one of them, carrying the facts that are never shared: IMEI, battery, grade,
what we paid, what we're asking.

The test the chat proposed is the right one and belongs in the product form's
help text, in Arabic:

> If two of them could legitimately share the value, it is a **variant** option
> (colour, storage). If two of them almost never share it, it belongs on the
> **unit** (IMEI, battery health, cost, price, condition).

### 4.2 `Product.tracking_mode`

```python
class TrackingMode(models.TextChoices):
    QUANTITY     = "quantity",     "Quantity only"          # default; today's behaviour
    BATCH        = "batch",        "Batch / lot tracked"    # lots, expiry, FEFO
    SERIAL       = "serial",       "Individually tracked"   # units, IMEI, VIN
    SERIAL_BATCH = "serial_batch", "Serialised within a lot"  # GS1 healthcare: lot AND serial

tracking_mode = models.CharField(max_length=16, default=TrackingMode.QUANTITY, db_index=True)
```

**The fourth mode is the one that decides whether this is a phone feature or a
traceability engine.** `serial | batch` as an exclusive choice is not a
simplification, it is a wrong model of the world, and the world that proves it
is pharmacy. A prescription pack under GS1 healthcare guidance carries, in one
DataMatrix, a GTIN, a batch/lot, an expiry date *and* a unique serial — that is
the shape EU FMD and US DSCSA verification are built on, and it is the shape a
Libyan pharmacy's imported stock already arrives in whether or not we can read
it. The same shape recurs well outside healthcare: a tyre has a DOT week-lot and
a unique casing number, a battery has a production lot and a cell serial, an
appliance has a manufacturing batch and a warranty serial.

`StockUnit.batch` (§4.3) was already nullable, which is the hint that this mode
was always latent in the design. Formalising it now costs one enum member and a
handful of guards. Retrofitting it later means touching the allocation rules,
the valuation branch, the bin definition, the POS resolver and the recall report
at once, on a model whose shipped meaning was "a unit has no lot".

| Mode | Identity objects | Quantity per identity | What the till resolves | Sold example |
|---|---|---|---|---|
| `quantity` | none | N | variant barcode | a can of Coke |
| `batch` | `StockBatch` | N | variant barcode → FEFO lot | Amoxicillin 500mg |
| `serial` | `StockUnit` | 1 | IMEI / serial scan | an iPhone 13 Pro |
| `serial_batch` | `StockUnit` **inside** `StockBatch` | 1 | one GS1 DataMatrix → both | a serialised medicine pack |

`serial_batch` is not a third code path. It is `serial`, with the unit's `batch`
required instead of optional, and it inherits every serialized behaviour
unchanged: quantity 1, per-unit cost, the picker, the concurrency lock, the
identifier on the receipt. What the batch adds is the cohort facts a unit cannot
carry alone — expiry, FEFO ordering, and a recall that can name the lot.

**What decides the cost, so it is decided once.** In `serial_batch` the **unit**
owns the money: `UNIT_COST` governs, and the unit's `incoming_rate` is stamped
from its batch's landed rate at receipt. The batch supplies the number; the unit
holds it. This is not a preference — §5.3 shows what happens if both sides are
allowed to count.

**Two kinds of product can never be tracked at all, and the form must refuse
rather than let it happen.** `is_service` and `is_prepared` products are skipped
wholesale by the stock engine — `record_sale_stock_movements` returns before
allocating anything for them (`backend/apps/sales/services.py:843`) — so a
serialized service would accept a unit at the till, print its identifier on the
receipt and never move it out of stock. §16.6 says a haircut has no IMEI; this
is where that becomes true:

```python
# Serializer AND Product.clean(), both, because the AI tools and the importer
# are callers too (§18.3).
tracking_mode != QUANTITY and (is_service or is_prepared)  →  refused
```

The refusal is symmetric and names whichever side moved: turning on
`is_service` for a tracked product is refused and lists its units, exactly as
`quantity → serial` is refused for a product with stock on hand.

**Changing the mode is guarded, not free.** `quantity → serial` is allowed only
when on-hand is zero, or through an explicit *opening identification* run that
turns N anonymous units into N identified ones (§6.10). `serial → quantity` is
refused while any unit is in stock. The same shape as the valuation-method
guard in `ShopSettingsSerializer`, and for the same reason: it re-labels history.

The two new transitions follow the same rule with one deliberate softening:

- `batch → serial_batch` needs its existing stock identified, because a lot of
  200 anonymous packs cannot become 200 serials by declaration. Opening
  identification (§6.10), scoped to one batch at a time.
- `serial → serial_batch` **grandfathers**: existing units keep `batch = NULL`
  and appear on the missing-identifier worklist, while every new receipt
  requires a lot. Refusing the transition until history is perfect would mean a
  pharmacy that starts with serials can never adopt lots, which is the wrong
  answer to a shop that is trying to get *more* correct.
- `serial_batch → serial` is allowed freely; the lots simply stop being required.
  Nothing is unsaid, and the allocations keep naming the batches they named.

**On the name `quantity`.** The natural fourth-mode reading is `NONE`, and it is
the better word in the abstract. It stays `quantity` because that is the value
already shipping as the column default, because the product form renders it as a
label a shopkeeper reads — *"كمية فقط"* is a description, *"لا شيء"* is an
absence — and because the constraint at the top of this document is that a shop
selling Coca-Cola never learns this feature exists. Renaming the default is the
one change in this plan that every such shop would see.

```python
# What kind of thing this is, for identifier labels and unit attributes.
# Reuses the shop-editable registry the workshop side already maintains.
asset_type = models.ForeignKey("customers.AssetType", null=True, blank=True,
                               on_delete=models.PROTECT, related_name="tracked_products")

# Warranty granted on sale, in days. 0 = none. Stamped onto the unit at sale.
warranty_days = models.PositiveIntegerField(default=0)

# GS1 identity, when the pack carries one. GTIN-14 resolves a scanned
# DataMatrix to this variant before its lot and serial are read (§6.3).
gtin = models.CharField(max_length=14, blank=True, db_index=True)   # on ProductVariant

# Batch & Expiry Policy. Read when tracking_mode is batch or serial_batch —
# and ONLY then. `tracks_expiry` is not a second gate beside this one: it
# becomes a derived property of tracking_mode and its column drops at R3
# (§18.4). Two flags governing one behaviour is how a shop's expiry tracking
# stops without anyone noticing.
shelf_life_days        = models.PositiveIntegerField(default=0)   # 0 = indefinite/none
expiry_warning_days    = models.PositiveIntegerField(default=30)  # days before expiry to alert near-expiry
auto_pick_strategy     = models.CharField(
    max_length=16,
    choices=[("fefo", "First Expiring, First Out"), ("fifo", "First In, First Out"), ("manual", "Manual select")],
    default="fefo",
)
prevent_selling_expired = models.BooleanField(default=True)       # blocks POS checkout of expired batches
```

On `Product`, next to `is_service` and `is_prepared`
(`backend/apps/catalog/models.py:110`) — those are already the flags that say
"this thing behaves differently in the stock engine", and these govern cohort
lifecycle. `tracks_expiry` used to be one of them and is absorbed here:

```python
@property
def tracks_expiry(self) -> bool:
    """Kept for every existing reader; the column drops at R3 (§18.4)."""
    return self.tracking_mode in (TrackingMode.BATCH, TrackingMode.SERIAL_BATCH)
```

The R1 migration sets `tracking_mode = batch` on every product that had
`tracks_expiry = True`, and turns its existing cohorts into identities with
`code_is_generated = True` plus one balance each. Nothing the shop sees changes
on that release — the same goods are still consumed earliest-expiry-first — but
from then on there is one control on the product form instead of two, and a
cohort that can carry a lot number the day someone types one. `gtin` is the exception: it belongs on `ProductVariant`, because a
GTIN identifies a trade item at the level Pointy already calls a variant — the
500mg box, not the drug.

### 4.3 `inventory.StockUnit`

Named for the neighbourhood it lives in — `StockItem`, `StockMovement`,
`StockBatch`, `StockLedgerEntry` — and deliberately *not* `InventoryUnit`, which
would sit one letter from `ProductUnit` (the carton/box unit of measure) in
autocomplete and in every future reader's head.

```python
class StockUnit(TimeStampedModel):
    """One physical, individually identified article of stock.

    ERPNext calls this ``Serial No`` and names the row after the number, which
    forbids the same handset ever coming back. Odoo calls it ``stock.lot`` and
    lets a lot hold many. This is the middle: an identified article with its own
    cost, its own price, its own place and its own life, whose identifier is
    unique only among the units currently in stock.
    """

    class Status(models.TextChoices):
        EXPECTED    = "expected",    "On order"        # PO placed, not arrived
        IN_STOCK    = "in_stock",    "In stock"
        RESERVED    = "reserved",    "Reserved"        # held by a quotation
        IN_TRANSIT  = "in_transit",  "In transit"      # left source warehouse
        SOLD        = "sold",        "Sold"
        RETURNED    = "returned",    "Returned to supplier"
        DAMAGED     = "damaged",     "Damaged"
        WRITTEN_OFF = "written_off", "Written off"     # lost, stolen, scrapped
        CANCELLED   = "cancelled",   "Cancelled"       # its receipt was cancelled

    variant   = FK(ProductVariant, PROTECT, related_name="stock_units")
    warehouse = FK(Warehouse, PROTECT, related_name="stock_units")   # last known place

    # --- identity -------------------------------------------------------
    code            = CharField(max_length=120)          # as typed / scanned
    code_normalized = CharField(max_length=120, db_index=True, editable=False)
    identifier_kind = CharField(max_length=16, default="serial")  # imei|serial|vin|plate|custom
    secondary_code            = CharField(max_length=120, blank=True)   # dual-SIM IMEI2, engine no, MAC, frame no.
    secondary_code_normalized = CharField(max_length=120, db_index=True, editable=False, blank=True)
    supplier_code             = CharField(max_length=120, blank=True)   # what the supplier called it

    status = CharField(max_length=16, choices=Status.choices, default=Status.IN_STOCK, db_index=True)

    # --- money & consignment (all base currency, all per base unit) -----
    incoming_rate  = DecimalField(18, 6, default=0)   # what this unit cost, landed
    refurb_cost    = DecimalField(18, 6, default=0)   # capitalised from repair jobs
    list_price     = DecimalField(10, 2, null=True, blank=True)   # this unit's asking price
    sold_price     = DecimalField(10, 2, null=True, blank=True)   # what it actually fetched

    # Consignment (الأمانات). Terms live on the agreement (§5.8); everything
    # below is either a per-unit override (null = inherit) or a fact only this
    # article can carry.
    is_consignment           = BooleanField(default=False)      # sold on behalf of customer
    agreement                = FK("inventory.ConsignmentAgreement", PROTECT, null=True, blank=True, related_name="units")
    consignor                = FK("customers.Customer", SET_NULL, null=True, blank=True, related_name="consignment_units")
    declared_value           = DecimalField(10, 2, null=True, blank=True)   # agreed worth for custody & claims
    consignor_payout_mode    = CharField(max_length=16, choices=["fixed", "commission"], null=True, blank=True)
    consignor_payout_rate    = DecimalField(10, 2, null=True, blank=True)   # fixed payout (e.g. 1000.00 LYD)
    consignor_commission_pct = DecimalField(5, 2, null=True, blank=True)   # commission % (e.g. 15.00%)
    consignor_reserve_price  = DecimalField(10, 2, null=True, blank=True)   # floor price below which till cannot sell
    consignor_paid_at        = DateTimeField(null=True, blank=True)          # when payout was disbursed
    consignor_payment_ref    = CharField(max_length=64, blank=True)          # register pay-out voucher reference

    # --- provenance ------------------------------------------------------
    purchase_line        = FK("purchasing.PurchaseLine", SET_NULL, null=True, blank=True)
    source_receipt_line  = FK("purchasing.PurchaseReceiptLine", SET_NULL, null=True, blank=True)
    supplier             = FK("purchasing.Supplier", SET_NULL, null=True, blank=True)
    acquired_at          = DateTimeField(null=True, blank=True)
    in_stock_since       = DateTimeField(null=True, blank=True)   # resets on return; drives aging
    supplier_warranty_expires_on = DateField(null=True, blank=True) # inward factory/supplier warranty

    # --- disposal --------------------------------------------------------
    sold_order_line     = FK("sales.OrderLine", SET_NULL, null=True, blank=True, related_name="stock_units")
    sold_at             = DateTimeField(null=True, blank=True)
    customer            = FK("customers.Customer", SET_NULL, null=True, blank=True)
    asset               = FK("customers.Asset", SET_NULL, null=True, blank=True)   # §4.8
    warranty_expires_on = DateField(null=True, blank=True) # outward shop customer warranty


    # --- the rest --------------------------------------------------------
    # The lot this article was born in. Optional under `serial`, **required**
    # under `serial_batch` (§4.2) — a serialised medicine pack is a unit inside
    # a cohort, and both facts travel on the same allocation row.
    batch      = FK(StockBatch, PROTECT, null=True, blank=True, related_name="units")
    attributes = JSONField(default=dict, blank=True)               # §4.5
    notes      = TextField(blank=True)
    attachments = GenericRelation("attachments.Attachment", ...)   # photos, condition report
```

Two absences are deliberate:

- **No `quantity`.** A unit is one. Fractional serialized stock is not a thing,
  and a column that can hold 0.5 is a column someone will eventually put 0.5 in.
- **No free-text status.** Status is written only by the services that move
  stock, never by a form. ERPNext marks theirs `read_only` for the same reason.

### 4.4 Identity: normalise, then constrain what is live

```python
code_normalized = strip whitespace, dashes, dots; upper-case; NFKC
secondary_code_normalized = strip whitespace, dashes, dots; upper-case; NFKC (when present)
```

Constraints:

```python
UniqueConstraint(fields=["code_normalized"],
                 condition=Q(status__in=["expected", "in_stock", "reserved", "in_transit"]),
                 name="stock_unit_live_code_unique")
Index(fields=["code_normalized"])                     # history lookups (primary identifier)
Index(fields=["secondary_code_normalized"])           # dual-SIM IMEI2, MAC address, engine no. lookups
Index(fields=["variant", "status", "in_stock_since"]) # the picker's query
Index(fields=["status", "warehouse", "variant"])      # bin reconciliation
GinIndex(fields=["attributes"])                       # attribute filters
```

The partial unique index is the whole design in one line: **one live unit per
primary identifier, unlimited history per identifier.** A phone sold and traded back in
is two rows with the same `code_normalized`, at most one of them live. Barcode resolution
(`resolveBarcode`) searches both `code_normalized` and `secondary_code_normalized`.

**Validation by identifier kind**, offered as a warning rather than a wall — the
same posture as `purchase-cost-guard`, and for the same reason: a guard that
blocks a legitimate oddity gets disabled, and a disabled guard catches nothing.

- `imei` — 15 digits, Luhn check digit. A failed Luhn is *almost always* a
  keying error, and catching it at receipt is worth more than catching it at the
  warranty claim two years later. 14-digit IMEI and 16-digit IMEISV accepted.
- `vin` — 17 characters, no I/O/Q, ISO 3779 check digit at position 9.
- `serial`, `plate`, `custom` — length and charset only.

**Conflicts are structured, never 500s.** When a scan hits a code that is already
live, the API answers with the same shape `catalog/identity.py` established for
duplicate SKU/barcode (`catalog-identity-conflicts`): field, value, the offending
row's id and a human label, so the client can offer *"open the device that
already exists"* instead of a red toast. When the code matches a **historical**
unit, that is not a conflict at all — it is the trade-in, and the receipt screen
should say so: *"هذا الجهاز بيع من هذا المحل في 12/03 — هل هو نفسه؟"*

### 4.5 Unit attributes without building a doctype engine

The chat's instinct — "you don't want 500 columns" — is right, and its proposal
(a generic `attribute_name / attribute_value` table) is the standard next
mistake: an EAV join per attribute, untyped values, and no way to ask "battery
above 85%".

We already refused the general case: anti-goal §8.2 of the benchmark plan is
*no metadata engine*. So the design is deliberately narrow:

**Definitions** — a small table hung off the `AssetType` a shop already
maintains for its workshop:

```python
class UnitAttributeDefinition(TimeStampedModel):
    asset_type   = FK("customers.AssetType", CASCADE, related_name="unit_attributes")
    key          = SlugField(max_length=48)        # "battery_health"
    label        = CharField(max_length=80)        # "صحة البطارية"
    data_type    = CharField(choices=["text","number","percent","money","date","choice","bool"])
    choices      = JSONField(default=list, blank=True)   # for choice: [{value,label}]
    suffix       = CharField(max_length=16, blank=True)  # "%", "km", "g"
    is_required  = BooleanField(default=False)
    show_in_picker  = BooleanField(default=True)   # visible in the POS unit picker
    show_on_label   = BooleanField(default=False)  # printed on the shelf label
    show_on_receipt = BooleanField(default=False)  # printed on the invoice
    is_filterable   = BooleanField(default=False)  # gets a chip in the units list
    display_order   = PositiveIntegerField(default=0)
    class Meta: UniqueConstraint(["asset_type", "key"])
```

**Values** — `StockUnit.attributes` JSONB, validated against the definitions on
write, GIN-indexed. Not EAV rows: one row per unit, one read, no join, and
Postgres containment/range operators for the filters. Numbers are stored as
numbers so `attributes->>'battery_health' >= 85` sorts and compares correctly.

**Seeded Attribute Templates by Asset Type**:

Seeded definitions ship out-of-the-box with the setup wizard, so any merchant entering any used/serialized trade gets sensible condition, feature, and accessory fields pre-configured without defining schema by hand:

- **Phones & Tablets (`phone_repair` / `mobile_trader`)**:
  `battery_health` (percent), `condition_grade` (choice: A+ / A / B / C / For Parts), `icloud_carrier_lock` (choice: Unlocked / Locked), `box_and_accessories` (choice: Full Box / Phone Only / Charger Included).
- **Computers & Laptops (`laptops_computers`)**:
  `processor_cpu` (text), `ram_size_gb` (number), `storage_capacity` (text), `battery_cycle_count` (number), `gpu_graphics` (text), `charger_included` (bool), `condition_grade` (choice: Excellent / Good / Fair).
- **Cameras & Photography (`cameras_photo`)**:
  `shutter_count` (number), `sensor_condition` (choice: Clean / Minor Dust / Needs Service), `lens_included` (text/bool), `battery_charger_included` (bool), `cosmetic_grade` (choice: Mint / Near Mint / Used / Battered).
- **Gaming Consoles (`gaming_consoles`)**:
  `storage_gb` (number), `firmware_version` (text), `controller_count` (number), `original_box` (bool), `online_ban_status` (choice: Clean / Banned).
- **Luxury Watches (`luxury_watches`)**:
  `movement_condition` (choice: Running (+/- s/day) / Needs Service), `papers_certificate` (bool), `original_box` (bool), `manufacture_year` (number), `metal_purity` (text), `extra_links` (number).
- **Fine Jewellery (`jewelry_precious`)**:
  `certificate_number` (text), `metal_type` (choice: Gold / Silver / Platinum), `purity_karat` (choice: 18K / 21K / 22K / 24K / 925), `weight_grams` (number, suffix "g"), `stone_details` (text).
- **Designer Goods & Handbags (`luxury_handbags`)**:
  `authenticity_card` (bool), `dust_bag_included` (bool), `hardware_condition` (choice: Like New / Minor Scratches / Tarnished), `cosmetic_grade` (choice: Pristine / Very Good / Good / Fair).
- **Home Appliances & TVs (`appliances_tv`)**:
  `screen_size_inches` (number), `panel_lamp_hours` (number), `stand_remote_included` (bool), `cosmetic_condition` (choice: Like New / Minor Scratches / Dented).
- **Bicycles & E-Bikes (`bicycles_ebikes`)**:
  `frame_size` (choice: S / M / L / XL), `motor_wattage` (number, suffix "W"), `battery_soh_percent` (percent), `odometer_km` (number, suffix "km"), `charger_included` (bool).
- **Power Tools (`power_tools`)**:
  `voltage` (number, suffix "V"), `brushless` (bool), `batteries_included` (number), `charger_included` (bool).
- **Cars & Vehicles (`car_workshop`)**:
  `mileage` (number, suffix "km"), `year` (number), `colour` (text), `keys_count` (number), `title_status` (choice: Clean / Rebuilt).
- **Generators & Power (`generators_power`)**:
  `hours_run` (number, suffix "hrs"), `capacity_kva` (number, suffix "kVA"), `battery_soh` (percent).

This *is* a slice of gap #11 (custom fields), delivered where it is genuinely
needed and nowhere else. Say so in the roadmap; do not let it become the excuse
to build the engine.


### 4.6 `inventory.StockAllocation` — the ledger join

The single most important table after the unit itself, and the one ERPNext got
structurally right and operationally wrong (§3.2).

```python
class StockAllocation(TimeStampedModel):
    """Which identified article a stock movement actually moved, and what it
    was worth. ERPNext's ``Serial and Batch Entry``, with two changes: it hangs
    off the movement instead of a separate submitted document, and it carries
    its voucher denormalised so a report never has to join back to learn what
    it was."""

    movement     = FK(StockMovement, CASCADE, related_name="allocations")
    ledger_entry = FK(StockLedgerEntry, CASCADE, null=True, blank=True, related_name="allocations")

    unit  = FK(StockUnit, PROTECT, null=True, blank=True, related_name="allocations")
    batch = FK(StockBatch, PROTECT, null=True, blank=True, related_name="allocations")

    variant   = FK(ProductVariant, PROTECT)      # denormalised
    warehouse = FK(Warehouse, PROTECT)           # denormalised
    direction = CharField(choices=["in", "out"])
    quantity  = DecimalField(12, 3)              # always 1 for a unit
    rate          = DecimalField(18, 6)          # incoming for in, outgoing for out
    value_change  = DecimalField(18, 6)          # signed
    voucher_type  = CharField(max_length=24, db_index=True)   # mirrors SLE
    voucher_id    = PositiveBigIntegerField(null=True, db_index=True)
    posting_at    = DateTimeField(db_index=True)

    class Meta:
        constraints = [
            CheckConstraint(Q(unit__isnull=False) | Q(batch__isnull=False),
                            name="stock_allocation_names_something"),
            CheckConstraint(Q(unit__isnull=True) | Q(quantity=1),
                            name="stock_allocation_unit_quantity_is_one"),
        ]
        indexes = [Index(["unit", "posting_at"]), Index(["voucher_type", "voucher_id"])]
```

Append-only, like the ledger it belongs to. A unit's whole life is
`SELECT * FROM stock_allocation WHERE unit_id = ? ORDER BY posting_at` — which
is the "where has this IMEI been" screen, in one query.

**The four modes, and what an allocation may name.** The table above needs no
new column to carry `serial_batch`: two nullable FKs and a quantity were already
the right shape, and the fourth mode is the case they were shaped for. What each
mode requires is a rule, and rules that span three tables are stated once and
enforced where they can be:

```
quantity      → neither unit nor batch  (no allocation row exists at all)
batch         → batch only,   quantity = N
serial        → unit only,    quantity = 1
serial_batch  → unit AND batch, quantity = 1     ← one row, both identities
```

The last line is the point. A serialised pack moving is **one** physical event
and gets **one** allocation row, from which both bookkeepings follow: the unit's
status flips and its batch's balance in that warehouse decrements. Two rows
would be two movements, and they would eventually disagree.

Two of the four rules the database holds by itself — the existing
`stock_allocation_names_something` and `stock_allocation_unit_quantity_is_one`
constraints already forbid an empty allocation and a unit with quantity ≠ 1.
The other two reach through the allocation to the variant to the product's
`tracking_mode`, which no check constraint can see. Denormalising the mode onto
every allocation row to make it visible was considered and rejected: it is a
column on the largest table in the feature, held for a rule that changes when a
product's mode changes. So they are held the way §13 holds the rest — a service
that is the only writer, and a guard test named after the failure it prevents:
**a `serial_batch` unit written without a batch, or a `batch` allocation on a
serialized variant.**

### 4.7 What happens to `StockBatch`: identity, and balance, are two tables

`StockBatch` today is an anonymous expiry cohort keyed one-to-one to a receipt
line, with no code and no warehouse, consumed FIFO-by-expiry by
`consume_expiring_stock_batches` (`backend/apps/inventory/services.py:297`). It
is a real thing and it works; it is simply not *identified*, not *placed*, and —
the part that matters most — **not separable from its own quantity.**

That last one is the structural decision this section exists to make. Lot A
arrives, 100 units, and ends up spread across three places:

```
Lot A — 100 units
  Main store         60
  Showroom           25
  Branch #2          15
```

A warehouse-scoped batch table has to answer that with **three rows that all
call themselves Lot A**, and from that moment the shop owns three lots, not one.
Every downstream question gets worse: a recall must find and lock all three and
has a window where the second branch is still selling; a transfer has to destroy
quantity in one identity and create it in another, so the lot's history forks;
the traceability report unions rows by string-matching a code; and genealogy —
"where did Lot A go" — is a question about a thing that no longer exists as a
single thing. The expiry date, the manufacturer, the GTIN and the recall status
are all facts about **the lot**, and copying them per warehouse is copying facts
that can then disagree.

So the batch is the identity, and the balance is the where and the how much:

```python
class StockBatch(TimeStampedModel):
    """The lot itself: what was made, by whom, when, and when it stops being good.

    Never a quantity and never a place. ERPNext calls this ``Batch``; Odoo calls
    it ``stock.lot``. One lot code means one lot, for the life of the shop,
    wherever its goods currently sit.
    """

    class Status(models.TextChoices):
        ACTIVE      = "active",      "Active"
        QUARANTINED = "quarantined", "Quarantined"   # emergency recall / stop-sale
        EXPIRED     = "expired",     "Expired"       # passed expiry date

    variant = FK(ProductVariant, PROTECT, related_name="stock_batches")

    # --- identity & dates -----------------------------------------------
    code            = CharField(max_length=120)          # supplier's lot number or internal lot
    code_normalized = CharField(max_length=120, db_index=True, editable=False)
    code_is_generated = BooleanField(default=False)      # we invented it (migration, unlabelled goods)
    gtin            = CharField(max_length=14, blank=True)   # as scanned, when the pack carries GS1 AI 01
    barcode         = CharField(max_length=120, blank=True, db_index=True)   # GS1-128 / lot barcode
    expiry_date     = DateField(null=True, blank=True, db_index=True)   # nullable: non-expiring lots exist
    manufactured_on = DateField(null=True, blank=True)

    status    = CharField(max_length=16, choices=Status.choices, default=Status.ACTIVE, db_index=True)
    is_locked = BooleanField(default=False)              # immediate recall stop-sale flag

    # --- provenance & genealogy -----------------------------------------
    supplier     = FK("purchasing.Supplier", SET_NULL, null=True, blank=True)
    parent_batch = FK("self", SET_NULL, null=True, blank=True, related_name="sub_batches")

    attributes = JSONField(default=dict, blank=True)     # potency %, DOT code, tile shade/dye lot
    notes      = TextField(blank=True)

    class Meta:
        ordering = ["expiry_date", "created_at", "id"]
        constraints = [
            UniqueConstraint(fields=["variant", "code_normalized"],
                             name="stock_batch_code_unique_per_variant"),
        ]
        indexes = [Index(["code_normalized"]), Index(["barcode"]), Index(["variant", "expiry_date"])]


class StockBatchBalance(TimeStampedModel):
    """How much of one lot is sitting in one place.

    One row per (batch, warehouse), created on first arrival and kept for its
    history afterwards — a depleted balance is not deleted, because "Lot A was
    in Branch #2 and is not any more" is exactly the sentence a recall needs.
    """

    batch     = FK(StockBatch, PROTECT, related_name="balances")
    warehouse = FK(Warehouse, PROTECT, related_name="batch_balances")
    variant   = FK(ProductVariant, PROTECT)       # denormalised, always == batch.variant

    received_quantity  = DecimalField(12, 3, default=0)   # cumulative into this place
    remaining_quantity = DecimalField(12, 3, default=0)
    incoming_rate      = DecimalField(18, 6, default=0)   # batch-wise landed cost, in this place

    first_received_at  = DateTimeField(null=True, blank=True)   # FIFO tiebreak within a warehouse

    # Denormalised from the batch so FEFO is one indexed scan and never a join.
    # Written only by the batch's own save; see "the one denormalisation" below.
    expiry_date = DateField(null=True, blank=True)
    is_sellable = BooleanField(default=True)       # batch.status == active and not is_locked

    class Meta:
        constraints = [
            UniqueConstraint(fields=["batch", "warehouse"], name="stock_batch_balance_unique"),
            CheckConstraint(condition=Q(remaining_quantity__gte=0), name="batch_balance_non_negative"),
            CheckConstraint(condition=Q(remaining_quantity__lte=F("received_quantity")),
                            name="batch_balance_remaining_lte_received"),
        ]
        indexes = [
            # The FEFO query, entire: variant + warehouse + sellable, ordered by expiry.
            Index(fields=["variant", "warehouse", "is_sellable", "expiry_date", "remaining_quantity"],
                  name="batch_balance_fefo_idx"),
            Index(fields=["batch", "remaining_quantity"]),   # "where is Lot A now"
        ]
```

**One lot code always means one lot.** `UniqueConstraint(variant,
code_normalized)` is the whole property, and it is the deliberate *opposite* of
the serialized rule in §4.4. A serial's uniqueness is scoped to what is live,
because the same handset legitimately comes back as a different article of
stock. A lot's identity is permanent, because a second delivery of Lot A **is
Lot A** — same factory run, same expiry, same recall exposure. So receiving a
lot code that already exists is not a conflict: it finds the identity and adds
to a balance. Receiving it with a *different expiry date* is a conflict, and it
gets the structured 400 that `catalog/identity.py` established
(`catalog-identity-conflicts`), because one of the two labels is wrong and a
receiver holding the box can say which.

**Status belongs to the lot; emptiness belongs to the place.** `QUARANTINED` and
`EXPIRED` are facts about the lot everywhere at once, so they live on the
identity and a recall is **one UPDATE**, not one per warehouse with a window
between them where a branch is still selling. `DEPLETED` leaves the enum
entirely: it was never a lifecycle state, only the observation that a number
reached zero, and it is now `remaining_quantity == 0` on a balance — per place,
derived, and unable to go stale.

**Cost sits with the quantity.** `incoming_rate` is on the balance, because
value is `quantity × rate` and quantity is here. In the ordinary case — one lot,
one delivery, one warehouse — it is simply the landed cost and reads identically
to a rate on the identity. It earns its place in the two cases that break a
single rate: a lot delivered twice at different landed costs (the balance moves
to the weighted average *within that lot and warehouse*, the same arithmetic the
moving-average bin already does), and a transfer, which moves quantity out of
one balance at its rate and into another. For reporting, "what did Lot A cost"
is the value-weighted average across its balances — one definition, registered
in the money guard like the rest.

**`source_receipt_line` is removed, not loosened.** Today it is a `OneToOneField`
and the earlier draft of this plan widened it to a `ForeignKey`. Both are wrong
for the same reason §3.2 gives: a lot arriving in three deliveries has three
provenances, and a column that can hold one of them is a column that will be
read as though it held all of them. Provenance is the `in` allocations, which
already carry voucher type, voucher id, warehouse, quantity and rate, and which
the recall report already reads. The forward migration writes one `in`
allocation per existing batch from the receipt line it points at, and then the
column goes.

**The one denormalisation, and the guard that holds it.** `expiry_date` and
`is_sellable` are copied onto the balance so the FEFO lookup at the till is a
single indexed scan of one table. This is a real cost — two columns that can
diverge — and it is paid deliberately, because the alternative is a join on the
checkout path and §11 makes a promise about that path that this plan does not
get to quietly break. It is held the way this codebase holds such things:

- `StockBatch.save` propagates both columns to its balances in one `UPDATE
  ... WHERE batch_id = ?`, inside the same transaction. A lot has a handful of
  balances, never thousands.
- Quarantine and expiry sweeps go through that same path, so there is one way to
  change them.
- A guard test file (the shape `lifecycle-query-scaling` established) fails when
  a new call site writes `status`, `is_locked` or `expiry_date` without the
  propagation, and an integrity invariant (§5.4) asserts no balance disagrees
  with its batch.

**What this buys, stated as the operations it makes trivial:**

| Operation | With one warehouse-scoped table | With identity + balance |
|---|---|---|
| Transfer 25 to the showroom | destroy in one "Lot A", create another | move a number between two balances; the lot is untouched |
| Recall Lot A | find every row with that code, lock each | one `status` write, all branches at once |
| "Where is Lot A?" | union rows by string-matching a code | `batch.balances.all()` |
| Genealogy / sub-lots | parent links between warehouse rows | `parent_batch` on the identity, where it means something |
| Expiry sweep | N rows per lot to update | one row per lot |
| Same lot delivered twice | a second row, or a silent merge | one identity, one balance, a weighted rate |

**Migration from today's table.** Each existing `StockBatch` row becomes one
identity plus one balance in the shop's default warehouse (which is the only
warehouse most shops have, and is exactly where that stock already implicitly
was). `code` is backfilled as a deterministic internal string with
`code_is_generated = True`, so the unique constraint is satisfiable and the UI
can honestly render *«بدون رقم دفعة»* rather than a number nobody printed.
`expiry_date` widens from `NOT NULL` to nullable, which is a safe direction.
`consume_expiring_stock_batches` is rewritten against balances and gains the
warehouse argument it always should have had — today it consumes a lot in Branch
#2 to satisfy a sale in the main store, which is a bug the current model cannot
express its way out of.

**Why not unify batch and unit into one table?** Odoo does, and it is
defensible. Two reasons not to: the serialized side needs per-unit price,
photos, warranty, customer asset bridge, and consignment payouts, none of which a
lot ever has, so a unified table is mostly-null for the majority row type; and
`StockBatch` is on the checkout path today (`consume_expiring_stock_batches` runs
inside `record_sale_stock_movements`). Destabilising that path twice — once for
serials, once for a table merge — buys elegance and risks the till. Two identity
tables, one balance table, one allocation row type (`StockAllocation`), one set
of hooks. ERPNext's split, without their bundle.

And with `serial_batch` (§4.2), the two identity tables **compose** rather than
compete: the unit is the article, the batch is the cohort it was born in, and
the allocation row names both. Which is the answer to the question the unified
table was trying to answer, without the nulls.

### 4.8 The bridge nobody else has: unit → `customers.Asset`

This is the part of the design that is ours and not ERPNext's, and it is the
reason to build the feature on *this* codebase rather than a generic one.

ERPNext puts a `customer` link and warranty dates on `Serial No` and stops.
Pointy already has a **customer asset registry** with ownership history
(`customers.Asset` + `AssetOwnership`, `backend/apps/customers/models.py:255,341`)
that the repair side uses to answer *"we've seen this car before"*. And it is
keyed on exactly the same identifiers.

So: **selling a serialized unit creates or links its `Asset`, and opens an
`AssetOwnership` row for the buyer.** The consequences fall out for free:

- A handset we sold, brought back for repair, opens an intake that already knows
  the model, the IMEI, the sale date, the price, and whether it is in warranty.
- A handset someone else sold, brought in for repair, and later traded in to us,
  is one asset with two owners and a purchase in the middle.
- The warranty question at the counter is a single lookup, and it answers with
  *our own invoice*, not the customer's memory.
- `AssetOwnership`'s existing constraint (one open owner per asset) means the
  chain cannot fork.

Guardrails: the asset is created only for identified sales to a **named
customer** (a walk-in cash sale with no customer creates no asset, and the unit
still records the sale); the asset's `asset_type` comes from the product's; and
the Asset's deliberate non-uniqueness stays untouched — the unit is what is
constrained, not the registry.

---

## 5. Valuation — the part that has to be right

This is the section to review hardest. Everything else is UI.

### 5.1 A fourth method, chosen by the product, not by the shop

`apps/inventory/valuation.py` has moving average, FIFO and LIFO, all of which
answer *"what did the queue give up?"*. Neither a serialized unit nor an identified batch
consults a queue: the cost is the cost of **that specific unit or cohort**.

```python
class ValuationMethod(...):
    MOVING_AVERAGE, FIFO, LIFO,   # existing
    UNIT_COST  = "unit_cost",  "Per-unit (serialized)"
    BATCH_COST = "batch_cost", "Batch-wise (lot cohort)"
```

`current_method()` gains two branches, and the fourth mode resolves to one of
them rather than adding a third:
- `serial` → `UNIT_COST`
- `batch` → `BATCH_COST`
- `serial_batch` → **`UNIT_COST`**, because the article is the thing that moved.
  Its batch supplies the rate at receipt and then the unit carries it. There is
  no `serial_batch` valuation method and there must not be one: two costed
  identities for one physical object is how a variant ends up counted twice.

All three hold regardless of `ShopSettings.inventory_valuation_method`. The shop's
default method still governs everything else it owns. There is no configuration
under which serialized or batch items use a blended guess — §3.4.

### 5.2 What each posting does

**For Serialized Goods (`UNIT_COST`):**
- **Receipt.** `unit.incoming_rate = receipt line's effective_unit_cost / unit_factor`
  — landed-cost inclusive, normalised to base units (`uom-cost-normalization`).
  Ledger entry: `quantity_change=+1`, `valuation_rate = incoming_rate`, one `StockAllocation(direction=in, unit=unit)`.
- **Issue.** `valuation_rate = unit.incoming_rate + unit.refurb_cost`,
  `value_change = -(that)`. One allocation per unit. `OrderLine.unit_cost` is
  stamped from it by `_stamp_ledger_cost_on_lines`.
- **Return from customer.** The unit returns at the rate it left at.
- **Write-off / damage.** Issue at the unit's own rate, `voucher_type=adjustment`.

**For Batch Goods (`BATCH_COST`):** every rate below is the **balance's**, never
the identity's — the lot has no cost, the lot-in-this-warehouse does (§4.7).

- **Receipt.** The lot identity is found or created; the balance for
  `(batch, warehouse)` is found or created; `balance.incoming_rate` is set to the
  line's `effective_unit_cost / unit_factor`, or moved to the weighted average of
  the old and new quantities when the lot has arrived here before.
  Ledger entry: `quantity_change = +received`, `valuation_rate = balance.incoming_rate`,
  one `StockAllocation(direction=in, batch=batch, quantity=received)` — the
  allocation names the identity and carries the warehouse it already denormalises.
- **Issue.** Allocated from the chosen balance (FEFO/manual).
  `valuation_rate = balance.incoming_rate`,
  `value_change = -(quantity * balance.incoming_rate)`.
  `balance.remaining_quantity -= quantity`.
- **Transfer.** The identity is untouched. Quantity leaves the source balance at
  its rate and arrives at the destination balance, which re-weights its own rate
  by the value that landed. This is the operation the old model could not express
  without forking the lot.
- **Return from customer.** Restocks to the original lot's balance in the
  returning warehouse, at that balance's rate.
- **Write-off / scrap (expired).** Issues from the expired balance at its own
  rate, `voucher_type=adjustment`, to zero. Note *balance*: an expired lot is
  scrapped in each place it sits, and each scrap is its own movement, because
  each is a real event someone performed in a real room.

**For Serialised-in-a-lot Goods (`serial_batch`, valued `UNIT_COST`):**
- **Receipt.** The lot and its balance are created exactly as above, then each
  unit is created with `unit.batch` set and
  `unit.incoming_rate = balance.incoming_rate`. One allocation per unit, naming
  **both**, quantity 1.
- **Issue.** The serialized rule, unchanged: `valuation_rate = unit.incoming_rate
  + unit.refurb_cost`. The allocation names both, so the lot's balance decrements
  by 1 from the same row.
- Everything else — returns, write-off, transfer, refurb — follows the serialized
  path in the first list, with the batch riding along on the allocation.

### 5.3 The bin stays, and stays consistent

`StockValuationBin` is not bypassed. For serialized and batch variants it becomes a
**derived cache with a checkable definition**:

```
# Serialized variant bin (serial):
bin.quantity       == COUNT(units WHERE status IN (in_stock, reserved) AND warehouse = w)
bin.stock_value    == SUM(incoming_rate + refurb_cost) over those units
bin.valuation_rate == stock_value / quantity            (0 when quantity is 0)
bin.method         == "unit_cost"

# Batch variant bin (batch) — over BALANCES in this warehouse, not lots:
bin.quantity       == SUM(balance.remaining_quantity WHERE balance.warehouse = w)
bin.stock_value    == SUM(balance.remaining_quantity * balance.incoming_rate)
bin.valuation_rate == stock_value / quantity            (0 when quantity is 0)
bin.method         == "batch_cost"

# Serialised-in-a-lot variant bin (serial_batch) — the SERIALIZED bin, exactly.
# The units are counted. The balances are NOT added to them.
bin.quantity       == COUNT(units WHERE status IN (in_stock, reserved) AND warehouse = w)
bin.stock_value    == SUM(incoming_rate + refurb_cost) over those units
bin.method         == "unit_cost"
```

**CORRECTED 2026-09-17 — a quarantined lot is still stock.** The second block
first read `AND balance.batch.status = active`, and that clause cannot be right
alongside §6.8.1, which says scrapping a recalled or expired lot is **its own
movement**, in each place it sits. Both cannot hold: under the original wording,
raising a recall would drop the shop's stock quantity and stock value with no
movement to account for it, and the bin would disagree with its own ledger the
moment anyone asked. Quarantine is a **stop-sale**, not a write-off — the goods
are on the shelf and they are the shop's until somebody throws them away, and
that act is the movement. Sellability gates *picking* (`is_sellable` on the
balance, read by FEFO); it does not gate *counting*. Found by the oracle of
§14.3 on its sixteenth operation, which is the argument for the oracle in one
sentence.

**The trap in the third block, stated so nobody has to find it in production.**
Under `serial_batch` the same physical pack is represented twice — once as a
`StockUnit`, once inside a `StockBatchBalance.remaining_quantity` — and a bin
that adds both reports double the stock, double the value, and a shop that
appears to be holding twice the medicine it has. So the rule is absolute:

> For a `serial_batch` variant, **the units are the count** and
> `StockBatchBalance.remaining_quantity` is a *derived mirror* of them:
> `balance.remaining_quantity == COUNT(live units WHERE batch = b AND warehouse = w)`.
> It is maintained because FEFO and the recall report read it, and it is never an
> independent number.

That equality goes into §5.4 as an invariant and into the oracle, because it is
the kind of thing that stays true for a year and then quietly stops on the one
code path that decremented a balance without moving a unit.

Keeping the bin honest is what lets **every existing report keep working
untouched**: stock value, margin, the loss guard, the accountant reports, the
dashboard. Not one of them learns the words "serial" or "batch".

### 5.4 Invariants, stated so they can be tested

For every serialized/batch variant and every warehouse:

1. `StockItem.quantity_on_hand == COUNT(units in_stock ∪ reserved)` (serial and
   serial_batch) OR `Σ(balance.remaining_quantity)` in that warehouse (batch) —
   never both for the same variant
2. `StockItem.quantity_committed == COUNT(units reserved)`
3. `StockItem.quantity_expected == COUNT(units expected)`
4. `bin.stock_value == Σ(unit value)` OR `Σ(batch remaining_quantity * incoming_rate)`
5. Every ledger entry on a tracked variant has allocations whose `Σ quantity == |quantity_change|`
6. No unit is allocated `out` twice without an intervening `in`; no batch quantity goes negative
7. `code_normalized` is unique among live units / batches in the same warehouse
8. A unit's or batch's status agrees with the sign of its last allocation
9. `bin.stock_value` is blind to consignment and `bin.quantity` is not: a
   consigned unit counts in quantity, contributes 0 to value, and is excluded
   from the divisor of `valuation_rate` — §5.8
10. Every consignment sale posts a `consignment_cost` entry whose `value_change`
    equals the issue it precedes, so cumulative ledger value on a consigned
    variant never goes negative — §5.8.
    **CORRECTED 2026-09-18:** checked entirely inside the ledger — the entry is
    followed by the issue it pays for, of exactly the opposite value — rather
    than against the units' current state. The first wording compared the posted
    entries against the payouts on units that are *currently* sold, and a
    customer return makes a correct ledger fail it: the unit stops being sold,
    the entry stays posted, and the two stop agreeing for a reason that is not a
    bug
11. For a `serial_batch` variant,
    `balance.remaining_quantity == COUNT(live units WHERE batch = b AND warehouse = w)`.
    The pack is counted once — §5.3
12. Every `StockBatchBalance` agrees with its batch on `expiry_date` and
    `is_sellable`. The denormalisation of §4.7 never drifts
13. A lot's identity is unique per variant, and the sum of its balances'
    `remaining_quantity` equals its net allocated quantity across all warehouses —
    one lot, one history, wherever it sits
14. Allocation shape matches the product's mode: `batch` names a batch only,
    `serial` a unit only, `serial_batch` both with quantity 1 — §4.6

These go into `apps/inventory/test_inventory_integrity.py` next to the existing
ones, and into the oracle (§14.3). Invariant 4 is the one that catches a wrong
refurb capitalisation; invariant 5 is the one that catches an ERPNext #42997.

### 5.5 Landed cost lands after the fact

`PurchaseOrderLandedCostEntry` allocates freight and clearing across lines
*after* receipt. For serialized lines this must re-stamp each unit's
`incoming_rate` and repost — otherwise the phone's cost is the invoice price and
the freight vanishes into a bin the units no longer feed.

**DEFERRED 2026-09-17 — Phase A refuses instead.** Editing a received order in
this codebase un-records the whole delivery and re-records it
(`_reverse_received_stock` → `_rerecord_receiving`), which is exactly right for a
quantity in a bin and exactly wrong for forty handsets: the identifiers were
captured at the receiving bay, they are not in an edit payload, and the
re-record would either refuse for want of them or invent a second set. So Phase
A **refuses** a cost-basis edit on an order holding identified stock, with a
structured error naming the units, and the correction that still works is a
purchase return — which moves the articles it names. The rule below is what
replaces that refusal, and it needs the receipt-line→unit linkage to survive the
reverse/re-record rather than being rebuilt through it.

Rule: **re-stamp the units, and the balances, of any receipt line whose
`allocated_landed_cost` changed, then `repost_variant`.** For a lot this means
the balance that receipt landed in — freight paid on a delivery into the main
store does not re-cost the same lot's stock that was transferred to a branch
before the invoice arrived; that stock left at the rate it left at, and the
transfer's own allocation says so. Units already sold are re-stamped too and the
repost corrects their COGS — which is what a repost is for. Units sold in a
**locked period** (`ShopSettings.books_locked_through`) are refused with the
existing period-lock error rather than silently re-costed.

### 5.6 Refurbishment capitalises

A used-goods trader buys at 1200, spends 150 on a screen, and must not sell at
1300. Today the 150 is a job cost that lands nowhere near the handset.

`operations.Job` gains an optional `stock_unit` target (alongside its existing
customer-asset target). When such a job completes, its materials + labour add to
`unit.refurb_cost`, with a `StockUnitEvent` recording the source. `prevent_selling_at_loss`
(already on by default) then compares the asking price against
`incoming_rate + refurb_cost` — the truth — and the loss guard becomes a real
guard for the trade where it matters most.

This is a genuine ERP behaviour (cost of refurbishment capitalises into the
article) and neither Shopify nor a spreadsheet can do it.

> **CORRECTED 2026-09-19 — "add to `unit.refurb_cost`" is half the write.**
> As shipped, capitalising wrote the column and nothing else, and
> `StockValuationBin` is a cache of the **ledger** rather than a projection of
> the units — its own docstring says so. So the article said 1,350 and the shelf
> said 1,200, invariant 4 failed the moment any screen was fitted, and the sale
> then issued 1,350 of value out of a bin that had only ever taken 1,200 in,
> walking a variant's cumulative value downward with every handset the shop
> repaired. Exactly the drift §5.8 diagnoses for consignment, one function over,
> and it survived because none of the four refurbishment tests asserted the
> invariants that every other test in this phase asserts. Capitalising now posts
> the same shape a consignment sale posts — a quantity-zero, value-only
> `REFURBISHMENT` entry — and releasing posts its mirror.

### 5.7 Per-unit price, and the engines downstream

`StockUnit.list_price` is nullable and is the unit's own asking price, in the
shop's base currency — the same invariant `ProductVariant.unit_price` holds, so
FX, discounts, loss guard and reports need no change. Resolution order at the
till:

```
line price = unit.list_price  ?? variant unit price (incl. unit/carton pricing)
```

The discount engine sees the resolved price and needs no knowledge of units. Two
places do need care.

The **discount preview cache** — its key must include the unit id when a
serialized line is present, or two different handsets of the same variant would
share a cached preview (`discount-engine-perf`).

And the **pooled promotions**. Multi-buy, tiered and buy-X-get-Y gather whole
units across every line a rule matches (`discounts/services.py:582`), so three
one-unit handset lines do form a pool of three and "buy 2 get 1" works without
any change — verified, not assumed. What is undefined once units carry their own
prices is *which* unit the allocation lands on: giving away the 1,400 handset is
a materially different transaction from giving away the 1,200. Rule: **the
allocation lands on the cheapest units first**, which is what a customer expects
of a free-item promotion and what a shop would choose anyway, and the loss guard
(§5.6) is re-evaluated per unit *after* allocation rather than against the line's
pre-discount price. Deterministic, defensible at the counter, and testable.

### 5.8 Consignment: `incoming_rate = 0` is right, and it is one third of the truth

§6.2.1 gives a consigned unit `incoming_rate = 0` at intake, and that is correct:
the shop did not buy the watch, so the watch is worth nothing *to the shop*, and
a bin that said otherwise would inflate stock value with other people's
property. But three things become true the moment the customer hands it over,
and a zero models only one of them.

| What is true at intake | Modelled today | Where it belongs |
|---|---|---|
| The item is physically here, and sellable | `StockUnit.status = in_stock` | custody |
| It adds nothing to stock value | `incoming_rate = 0` | valuation |
| We owe its owner the item, or its money | **nothing at all** | liability |

The third is not "nothing until it sells". Before the sale it is an obligation
to *return the thing*; after the sale it is an obligation to *pay a number*.
Only the form changes — the obligation runs unbroken from the moment the voucher
is signed. A shop holding forty consigned watches is carrying an exposure that
appears nowhere in Pointy, and the first time anyone asks how much of the money
in the drawer is actually theirs, the honest answer today is that we cannot say.

**We have no general ledger, and we still do not need one.**
`apps/treasury/position.py` derives the shop's money position from the events
that already exist rather than posting to accounts, and `Job.settlement_state`
(`backend/apps/operations/models.py:267`) derives where a repair stands with
money rather than storing it. Consignor liability follows the same rule:
**derived, never posted.** A payable computed from the unit's own sale and its
own payout row cannot drift from them, which is the entire failure mode of a
posted balance. This is the `money-position-treasury` posture, and it is the
reason this section adds two small documents and no accounts.

**The agreement becomes a document, because we already print one.** §6.2.1 prints
a formal *سند استلام أمانة* that both parties sign. A thing we print, number and
sign should be a row with a lifecycle, not six columns on the object it covers —
and a consignor who walks in with eight handbags signs one agreement, not eight.

```python
class ConsignmentAgreement(DocumentMixin, TimeStampedModel):
    """The shop's promise about goods it holds but does not own.

    Registered in ``apps.documents`` (draft → submitted → cancelled, freeze and
    reversal per ``document-lifecycle``) with a gapless number from
    ``documents/numbering.py``. Submitting it is what starts custody; cancelling
    it is refused once any of its units has moved.
    """

    consignor        = FK("customers.Customer", PROTECT, related_name="consignment_agreements")
    number           = CharField(max_length=32, unique=True)   # سند استلام أمانة رقم …
    signed_at        = DateTimeField()
    expires_on       = DateField(null=True, blank=True)   # goods to be collected by
    notes            = TextField(blank=True)
    attachments      = GenericRelation("attachments.Attachment", ...)  # the signed page, ID photo

    # --- default terms, overridable per unit ---------------------------
    payout_mode      = CharField(max_length=16, choices=["fixed", "commission"], default="fixed")
    payout_rate      = DecimalField(10, 2, null=True, blank=True)
    commission_pct   = DecimalField(5, 2, null=True, blank=True)
    reserve_price    = DecimalField(10, 2, null=True, blank=True)

    # --- custody policy, printed on the voucher whichever it is --------
    # Ordered by ascending shop exposure. The default is the first, which is
    # what Libyan vouchers already say (§17.7).
    class Liability(models.TextChoices):
        OWNER_RISK            = "owner_risk",            "الأمانة على مسؤولية صاحبها"
        SHOP_LIABLE_EXCEPT_FM = "shop_liable_except_fm", "المحل ضامن ما عدا الظروف القاهرة"
        SHOP_LIABLE           = "shop_liable",           "المحل ضامن"

    liability_policy = CharField(max_length=24, choices=Liability.choices, default=Liability.OWNER_RISK)
    liability_cap    = DecimalField(10, 2, null=True, blank=True)   # bounds any claim; null = declared value

    # The clause as it was PRINTED AND SIGNED, copied from the shop's editable
    # per-policy sentence at submit (§10) and never re-read afterwards. A shop
    # that rewords its voucher next year has not reworded the agreements it
    # already signed, and this column is the difference between a contract and
    # a template.
    liability_clause = TextField(blank=True)
```

`StockUnit` keeps its consignment fields as **per-unit overrides** (`null` means
inherit the agreement) and gains `agreement = FK(ConsignmentAgreement, PROTECT)`
plus `declared_value` — the agreed worth of *this* article, printed on the
voucher, and the number the custody exposure and any claim are measured against.
`consignor` stays denormalised onto the unit and is checked equal to
`agreement.consignor`, so the payables screen and the POS picker never join.

**The four figures, each with exactly one definition.** The statement the owner
must be able to read for the worked example — a Rolex consigned at a 10,000
fixed payout, sold for 12,000, not yet paid out — is this:

```
المخزون (قيمة البضاعة)        0        stock value: consigned goods never enter the bin
النقد المحصّل             12,000      cash collected: an ordinary Payment row, already there
مستحقات الأمانات         10,000      consignor payable: derived, owed and unpaid
عمولة المحل               2,000      the shop's earning on the deal — gross profit, unchanged
```

Four figures, four definitions, registered in the existing static guard
(`money-definitions-guard`, `apps/core/test_money_definitions.py`) so the fifth
surface that wants them has to import rather than retype:

```python
consignment_stock_value(warehouse)      # ≡ 0. Consigned units are excluded from bin value by construction.
consignor_payout_due(unit)              # fixed: payout_rate;  commission: sold_price * (1 - pct/100)
consignor_payable(as_of, consignor=None)# Σ payout_due over units sold, not yet paid, not settled by claim
consignor_claims_open(as_of)            # Σ assessed_value over unresolved incidents (§6.2.2)
shop_consignment_commission(period)     # Σ (sold_price - payout_due) over units sold in the period
```

Note what is *not* new: the fourth figure. Because §6.2.1 already stamps the
payout as the unit's cost at sale, gross profit on a consignment line already
equals the shop's commission, and every existing margin report is already right.
The work this section adds is the payable and the custody obligation — the two
numbers nothing computes today.

**The ledger has to balance, and as written it does not.** This is the one
correctness bug in §6.2.1, and it is the kind that is invisible until a year of
consignment sales has quietly driven a variant's cumulative stock value
negative. The unit enters the ledger at intake as `+1 @ 0` and, on sale, leaves
it as `-1 @ 10,000` once `incoming_rate` is stamped with the payout. Ten
thousand dinars of value leaves a ledger it never entered. `StockValuationBin`
self-heals because §5.3 defines it as derived, but `StockLedgerEntry` is
append-only and does not, so the bin and the ledger's own running value stop
agreeing and the stock-value history goes wrong.

The fix is one extra entry inside the same transaction, posted immediately
before the issue:

```
VoucherType.CONSIGNMENT_COST   quantity_change = 0,  value_change = +payout_due
VoucherType.SALE               quantity_change = -1, value_change = -payout_due
```

Net quantity zero, net value zero, COGS correct, cumulative value never
negative. Invariant 5 needs one word of slack to allow it — a zero-quantity
entry carries zero allocations, and `Σ quantity == |quantity_change|` already
says so, but the guard test must not assume every entry has at least one. A value-only entry is not a new idea here — it is exactly what landed
cost does in §5.5 — and the audit trail it leaves reads like what actually
happened: *at the instant we sold it, we acquired it for 10,000.* A consignment
sale is a purchase and a sale in one transaction, which is how §6.2 already
frames the trade-in it is a sibling of. The alternative — keeping consigned
units out of the stock ledger altogether — loses the quantity, and the shop very
much needs the quantity: the watch is on the shelf, it gets counted at stock
count, and it has to be sellable.

**The bin, precisely.** Consigned units count in quantity and contribute zero to
value, so §5.3's serialized bin definition needs one clause it does not have:

```
bin.quantity       == COUNT(units WHERE status IN (in_stock, reserved))          # consigned included
bin.stock_value    == SUM(incoming_rate + refurb_cost) WHERE is_consignment = False
bin.valuation_rate == stock_value / COUNT(owned units)     # NOT / quantity — zeros must not dilute the rate
```

The third line is the trap. A variant with three owned handsets at 1,200 and
seven consigned ones would otherwise report a valuation rate of 360, and every
report that multiplies a rate by a quantity would be wrong by a factor of three.
This goes into §5.4 as invariant 9: **`bin.stock_value` is blind to
consignment, `bin.quantity` is not.**

**The loss guard has to read the payout, not the cost.** `prevent_selling_at_loss`
compares the asking price against `incoming_rate + refurb_cost`, which for a
consigned unit is 0 until the moment of sale — so the guard that exists to stop
a shop losing money is, on precisely the goods where losing money is easiest,
switched off. A fixed-payout bag with a 1,200 payout sold at 900 collects 900
and owes 1,200, and nothing in §6.2.1 stops it unless someone remembered to set
a reserve price, which is nullable.

Rule: for a consigned unit the guard reads `expected_payout(unit)`, and **for
fixed-payout agreements the floor is `max(reserve_price or 0, payout_rate)` and
is not optional.** Commission mode needs no arithmetic floor — the payout scales
with the price — so the reserve there protects the consignor rather than the
shop, and stays advisory-with-override as §6.2.1 has it. The same rule binds the
discount engine: a percentage discount on a fixed-payout consignment line eats
the commission first and the shop's own money second, and the floor is what
stops it. Enforced server-side at checkout, not only at the till, because the
till is not the only caller.

**Treasury shows the claim, and does not move the balance.** The cash in the
drawer is really there; what is untrue is that all of it is the shop's.
`position.py` warns in its own docstring about double counting, so the payable
is added as a **derived overlay, not a component**: `/api/treasury/position/`
grows an `obligations` block (`consignor_payable`, `consignor_claims_open`) that
the money-position screen renders beneath the total as *منها مستحقات أمانات*,
never subtracted from it. Two rules keep it honest:

1. **A consignor payout is its own document type** — not an `Expense`, not a
   `SupplierPayment`. Both of those already have exclusion rules in
   `position.py` for the drawer pay-outs they generate, and reusing one would
   put consignment money in the wrong component and misreport the category it
   landed in. It registers in `apps/documents` with
   `submit_effects = ("consignor_liability", "money_position", "register_payout")`,
   mirroring `_register_supplier_payment`, and `position.py` gains one component
   code, `COMPONENT_CONSIGNOR_PAYOUT`, under the same standalone-pay-out rule
   the expenses flow already follows.
2. **Nothing about the payable is stored.** It is `consignor_payable()` over
   rows, evaluated on read, ETagged like the rest.

**A consignment sale on آجل owes cash before it collects any.** The payout falls
due the moment the watch is sold; the receivable does not. A shop that sells a
consigned Rolex on credit has handed over someone else's goods, owes them 10,000
in cash on demand, and holds an invoice instead of the money — funding another
person's stock out of its own drawer, on a customer's payment terms. This is not
a hypothetical trade-off; it is the single fastest way a consignment module can
empty a till.

Nothing here refuses the sale — a shop's regular buying a watch on آجل is
ordinary business and this plan does not get to overrule it. What it does is
make the shape visible at the moment it is chosen:

- Choosing آجل on a cart holding a consignment line raises a confirmation that
  names **the payout amount and when it becomes due**, not a generic warning.
  The cashier is told what the shop is about to owe, in dinars.
- Those units are flagged on the consignment payables screen (§8.1) as *مباعة
  آجل* with the invoice's balance alongside the payout owed, so the person
  disbursing knows the money has not arrived.
- `consignment_payable()` is unchanged and still counts them — the shop owes the
  consignor whether or not the customer has paid, and a payable that quietly
  waited on someone else's invoice would be the wrong number.

It interacts with the credit machinery already in place rather than duplicating
it: `require_customer_for_credit` still applies, `enforce_customer_credit_limits`
and the customer's own ceiling still bind (`customer-credit-limits`), and a
consignment line does not change any of that arithmetic. The only new thing is
that the cashier is told the second number.

**Returns, when the payout has already gone out.** A customer returns the Rolex
three days after the consignor collected 10,000. The item is on the shelf again
and the money is gone, and this is common enough in high-value used trade that
leaving it undefined means each shop invents an answer. The return screen asks
once, and the two answers are both defensible:

- **Buy it in** (default): the unit converts to owned stock at
  `incoming_rate = payout_paid`. The shop owns a Rolex it paid 10,000 for, which
  is exactly what happened, and the consignment is closed.
- **Reopen the consignment**: the unit returns to consigned stock at
  `incoming_rate = 0` and a **consignor receivable** opens for the amount paid —
  the mirror of the payable, settled against the next sale or collected back.

If the payout has *not* yet been disbursed, neither question arises: the payable
simply closes with the sale that created it, and the unit goes back to consigned
stock.

---

## 6. The flows

### 6.1 Purchasing: order → receive → identify

`PurchaseLine` for a serialized product carries a **count**; it does not carry
identifiers. Identifiers are captured where the goods physically are: at receipt.

The receiving screen gains, per serialized line, a **scan loop** — deliberately
the same interaction as blind stock count (`stock-count`), because the staff
doing it are the same staff and the muscle memory should transfer:

```
iPhone 13 Pro 256GB Blue — accepted 5
  [ scan or type an IMEI ]                     3 / 5 captured
  ✓ 351234567890111   battery 86%   grade B    cost 1200.00
  ✓ 351234567890222   battery 92%   grade A    cost 1350.00
  ✓ 351234567890333   —                        cost 1200.00
```

Rules:

- **The receipt cannot be confirmed until captured == accepted**, unless the
  shop opts into *capture later*. That option exists because a truck arrives at
  six in the evening and nobody is going to scan forty boxes before closing. It
  creates `expected`-status placeholder units and puts the line on a **"missing
  identifiers" worklist** on the inventory dashboard — visible, counted, and
  chase-able. A placeholder unit cannot be sold.
- **Damaged units are units.** `damaged_quantity` on the receipt line produces
  units with `status=damaged`, in the same table, allocated by the same rows.
  This is ERPNext #43492, refused by construction.
- **Per-unit cost split.** The line has a total; used goods have individual
  costs. The capture sheet lets each unit take its own cost, constrained to sum
  to the line's net total (the residual is shown live and must reach zero). When
  untouched, every unit takes the line rate. *Neither ERPNext nor Shopify does
  this gracefully, and for a used-goods trader it is the difference between a
  cost figure and a fiction.*
- **Attributes at capture.** The `UnitAttributeDefinition` set for the product's
  asset type renders as the capture form. Required ones block the line.
- **Duplicate handling.** A live duplicate is a structured conflict with an
  "open the existing device" action. A historical duplicate is surfaced as
  provenance, not an error (§4.4).
- **Cancelling the receipt** voids its units (`status=cancelled`, never deleted)
  and reverses their allocations. If any of them has been sold, the cancellation
  is **blocked** with the existing `DocumentBlocked` shape naming each sold unit
  and its invoice — the same idiom as `Warehouse.deletion_blockers`.

### 6.1.1 Purchasing & Receiving Batches (Multi-Lot Intake & Labels)

For goods with `tracking_mode` of `batch` or `serial_batch` (pharmacy, packaged food, cosmetics, chemicals, tyres):

- **PO Line carries count, not lot**: A purchase order specifies variant and quantity (e.g. 100 boxes of Amoxicillin). The supplier lot numbers and expiry dates are unknown until the physical boxes land on the loading dock.
- **Capture at receiving**: The receiving sheet prompts the receiver for:
  - Lot / Batch Code (`code`)
  - Expiry Date (`expiry_date`, with quick-date shortcuts: +6M, +1Y, +2Y, +3Y)
  - Manufacture Date (`manufactured_on`, optional)
  - Quantity received for this lot
- **Multi-Lot split on a single line**: Deliveries frequently bundle multiple production lots under one PO line. The capture sheet allows adding multiple batch rows for the same PO line:
  ```
  Amoxicillin 500mg (100 boxes expected)
    ✓ Lot A-2026-01   exp 06/2027   qty 60   cost 14.50
    ✓ Lot B-2026-04   exp 09/2027   qty 40   cost 14.50
    Total captured: 100 / 100  (Ready to confirm)
  ```
  The receipt line cannot be confirmed until `Σ(batch quantity) == accepted_quantity`.
- **A lot code that already exists is not an error**: receiving `Lot A-2026-01` again finds the existing identity and adds to its balance in this warehouse — same factory run, same lot, one row in the catalog of lots (§4.7). The receiver sees *«دفعة معروفة — سيتم الإضافة للرصيد»* with the lot's current locations and quantities. A **different expiry date on a known lot code** is the one conflict here, and it gets a structured 400 naming both dates, because the receiver is holding the box and can say which label is right.
- **Batch-wise landed cost**: Each **balance** is stamped with `incoming_rate = line's effective_unit_cost / unit_factor`, weighted-averaged into whatever that lot already had in this warehouse. When landed freight or clearance is allocated later (§5.5), balance rates re-stamp and repost identically to serialized units.
- **`serial_batch` receiving is one sheet, not two**: the lot header (code, expiry, manufacture date) is captured once, then the scan loop reads each pack's serial beneath it — or reads a GS1 DataMatrix per pack and fills both at once (§6.3). Each unit is created with its `batch` set and its rate stamped from the balance. The line confirms when `Σ(units captured) == accepted_quantity`, the same residual counter as the serialized sheet, because it *is* the serialized sheet with a lot header on top.
- **Carton & shelf label printing**: Directly from the receiving screen, clicking "Print Batch Labels" generates PDF barcode labels (GS1-128 / Code 128) showing:
  - Product Name & Variant
  - Batch Number (`code`)
  - Expiry Date (`تاريخ الصلاحية: MM/YYYY`)
  - Scannable lot barcode (or standard product barcode)
  Labels adhere to shelf fronts or individual cartons, allowing the till to scan lot barcodes directly.


### 6.2 Buying over the counter, and trade-ins

This is *the* used-phone-shop workflow and it deserves to be first-class, not a
purchase order with one line.

- **Counter purchase.** The POS cash-purchase flow (`pos-cash-purchases`) already
  creates a received-and-paid PO with a linked register pay-out. Serialized, it
  becomes: pick or create the model → scan/type primary code (IMEI/Serial/VIN/Cert) → complete condition & accessory checklist → enter agreed buy price → the drawer opens. One sheet, one unit, one pay-out, correct ledger.
- **Condition & Included Accessories Checklist.** Intake across any domain (laptops, cameras, watches, bikes, tools) renders the asset type's `UnitAttributeDefinition` form. Cashiers fill required condition metrics (e.g., battery health, shutter count, cosmetic grade) and check included accessories (box, charger, cables, certificate of authenticity). This checklist is saved into `unit.attributes`, printed on the intake receipt, and displayed on the POS unit picker sheet.
- **Trade-in.** Customer buys a phone/laptop/watch and gives one in part-payment. That is a
  purchase and a sale in one transaction. `OrderExchange`
  (`backend/apps/sales/models.py:1089`) is already the atomic
  return-and-replace primitive; the trade-in is its sibling: create the incoming
  unit at the agreed value, apply that value as a tender line, sell the outgoing
  unit, one document, one register entry. Phase C.
- **Ownership follows.** A traded-in or sold item's `Asset` gets its ownership row
  closed (the customer no longer owns it) and reopened when we sell it on.

### 6.2.1 Consignment (الأمانات): Intake, Instant Sale SMS & Payout Disbursement

Consignment is the backbone of high-value used trades (watches, luxury bags, cameras, high-end laptops, cars). A customer entrusts an item to the shop to sell on their behalf. The shop does not front the capital, and the consignor expects immediate notification and prompt payment once sold.

1. **Intake & Agreement (`سند استلام أمانة`)**:
   - Customer is selected/created (`consignor = Customer`) with an active phone number.
   - Payout terms are agreed:
     - **Fixed Payout**: `consignor_payout_rate = 1200.00 LYD` (the shop keeps any markup above this).
     - **Commission Percentage**: `consignor_commission_pct = 15.00%` (customer gets 85% of actual sold price).
     - **Minimum Reserve Price**: `consignor_reserve_price = 1400.00 LYD` (POS enforces this floor).
   - Condition & accessories checklist is completed.
   - Declared value is agreed and recorded — the number custody exposure and any future claim are measured against (§5.8).
   - Prints a formal **Consignment Intake Voucher** in Arabic stating item description, identifier/serial, condition, agreed payout terms, declared value, and the **liability clause printed verbatim** — the shop's own sentence for whichever of the three policies applies (§10), not a label generated from an enum. This line is the contract, and a shop with a lawyer must be able to paste its own words into it.
   - All of the above is one submitted `ConsignmentAgreement` document (§5.8), numbered and signed, covering one unit or eight.
   - Stock unit is created with `status = in_stock`, `is_consignment = True`, `incoming_rate = 0`. No money leaves the cash register at intake. The liability that *does* open at this moment is custody, and §5.8 is where it is modelled.

2. **Sale at POS & True Costing**:
   - Scanned and sold at the till just like owned stock.
   - Price floor guard: cashier cannot discount below `consignor_reserve_price` without manager override. For **fixed-payout** agreements the floor is `max(reserve_price or 0, payout_rate)` and is **not** overridable — selling below the payout loses the shop its own money, not just its commission (§5.8).
   - On checkout commit:
     - Calculated payout is determined: fixed amount or `sold_price * (1 - commission_pct / 100)`.
     - Unit's `incoming_rate` is dynamically stamped with this calculated payout.
     - A `consignment_cost` ledger entry (`quantity_change = 0`, `value_change = +payout`) is posted immediately before the issue, so the value leaving the ledger is value that entered it — §5.8.
     - COGS = payout amount; Gross profit = `sold_price - payout_amount` (the shop's commission earnings).
     - Unit status moves to `sold`. The consignor payable for it is now *derived* — `consignor_payout_due(unit)`, owed until `consignor_paid_at` is stamped. Nothing is posted (§5.8).

3. **Instant Automated Customer Notification (SMS / Messaging)**:
   - Immediately post-commit in `apps/sales/services.py`, if `unit.is_consignment` and `unit.consignor.phone` exists:
   - Calls `apps.messaging.services.enqueue_message`:
     - **Gateway**: `MessagingGateway.default_gateway()` (SMS Gate / provider).
     - **Channel**: SMS (or WhatsApp where supported).
     - **Recipient**: `unit.consignor.phone`.
     - **Dedup Key**: `consignment_sold_{unit.id}_{order.id}` (ensures idempotency; zero risk of duplicate SMS).
     - **Source**: `source_type = "consignment_sale"`, `source_id = order.id`.
     - **Consent Class**: `TRANSACTIONAL`.
     - **Message Copy (Arabic)**:
       ```
       مرحباً {consignor_name}،
       تم بحمد الله بيع أمانتكم ({product_name} - رقم: {code}) بالفاتورة رقم #{invoice_number}.
       المبلغ الصافي المستحق لكم: {payout_amount} د.ل.
       نرجو التفضل بزيارة المحل لاستلام المبلغ.
       شكراً لثقتكم بنا.
       ```
     - If messaging is offline or SMS gateway is unreachable, the message remains queued in `OutboundMessage` with retry backoff, and cashier screen shows an indicator. A manual "Resend SMS" action is available on the unit detail screen.

4. **Disbursement / Collecting Payout at the Counter**:
   - When the customer arrives at the shop to collect their money:
   - Cashier navigates to **Consignment Payables** (`مستحقات الأمانات`):
     - Displays all sold consignment units awaiting payout. Searchable by customer name, phone, or serial number.
     - Lists: item name, identifier, sold date, invoice number, customer name, net payout due.
   - Cashier taps **"Disburse Payout" (`صرف المستحقات`)**:
     - System prompts for payout method (Cash from register / Bank transfer).
     - If cash: pops cash drawer and logs register cash pay-out movement (`pos-cash-purchases`).
     - Stamps `unit.consignor_paid_at = now()` and `unit.consignor_payment_ref = voucher_id`.
     - Prints **Consignment Payout Receipt** (`سند صرف أمانة`) signed by both customer and cashier.
     - Automatically queues confirmation SMS:
       `"تم تسليمكم مبلغ {payout_amount} د.ل سند رقم {voucher_id} مقابل بيع {product_name}. سعدنا بالتعامل معكم."`

5. **Return of Unsold Goods (`استرجاع أمانة`)**:
   - If the item does not sell and the owner wishes to take it back:
   - Cashier clicks "Return to Consignor" on the unit detail screen.
   - Unit status transitions to `returned`, leaves active stock, custody row is closed, no ledger or payout is generated. The agreement closes when its last unit leaves.
   - A **customer** return of an already-sold consigned item is the harder case, and §5.8 defines the two answers the return screen offers.

### 6.2.2 Custody: when it breaks, goes missing or is stolen in our care

§6.2.1 covers the two happy paths — it sells, or the owner takes it back. The
path a consignment module is actually judged on is the third one, and today the
plan has nothing to say about it: the camera is dropped, the bag is stolen with
the window, the laptop is handed to the wrong cousin. The shop's reputation, and
sometimes a court, turns on whether it can produce a record made *at the time*
rather than an argument made afterwards.

The governing idea is the one `repair-settlement-custody` already established
for the workshop: **money state and custody state are different facts and must
be different rows.** A damaged consigned unit is a custody event that *may* also
be a money event; which of the two it is, is a judgement someone makes later,
and the record of the event must not wait for that judgement.

```python
class ConsignmentIncident(DocumentMixin, TimeStampedModel):
    """Something happened to goods we were holding for someone else."""

    class Kind(models.TextChoices):
        DAMAGED   = "damaged",   "تلف"
        LOST      = "lost",      "فقدان"
        STOLEN    = "stolen",    "سرقة"
        DESTROYED = "destroyed", "إتلاف كامل"
        DISPUTE   = "dispute",   "خلاف على الحالة"   # owner says it came back worse

    class Responsibility(models.TextChoices):
        SHOP          = "shop",          "المحل"
        CONSIGNOR     = "consignor",     "صاحب الأمانة"    # pre-existing fault, or it failed on its own
        THIRD_PARTY   = "third_party",   "طرف ثالث"        # courier, burglar, another customer
        FORCE_MAJEURE = "force_majeure", "ظرف قاهر"        # fire, flood, armed robbery, unrest
        UNDETERMINED  = "undetermined",  "غير محدد"

    class Resolution(models.TextChoices):
        PENDING     = "pending",     "قيد التسوية"
        PAID        = "paid",        "سُدّد نقداً"
        REPLACED    = "replaced",    "استُبدل"
        WAIVED      = "waived",      "تنازل صاحبها"
        INSURED     = "insured",     "غطّاه التأمين"
        NO_CLAIM    = "no_claim",    "لا مطالبة"

    unit            = FK(StockUnit, PROTECT, related_name="incidents")
    agreement       = FK(ConsignmentAgreement, PROTECT, related_name="incidents")
    kind            = CharField(max_length=16, choices=Kind.choices)
    occurred_on     = DateField(null=True, blank=True)   # may be unknown; discovered_at never is
    discovered_at   = DateTimeField()
    reported_by     = FK(User, PROTECT)                  # who said so, not who is blamed
    narrative       = TextField()                        # in the reporter's words
    attachments     = GenericRelation("attachments.Attachment", ...)  # photos, police report

    responsibility  = CharField(max_length=16, choices=Responsibility.choices,
                                default=Responsibility.UNDETERMINED)
    assessed_value  = DecimalField(10, 2, default=0)     # what we accept we owe. 0 is a valid answer.
    resolution      = CharField(max_length=16, choices=Resolution.choices, default=Resolution.PENDING)
    resolved_at     = DateTimeField(null=True, blank=True)
    settlement_ref  = CharField(max_length=64, blank=True)   # payout voucher, replacement unit, waiver
```

The five things this has to be able to say, and where each one says it:

- **Incident record** — the row itself, created the moment someone notices,
  with photos and the finder's own words. It exists whatever the outcome, and
  it is never deleted; `PROTECT` on the unit, cancellation through the
  `apps.documents` reversal contract rather than a delete.
- **Responsibility** — a field with five answers including *undetermined*,
  which is the honest state on day one and must be representable. Nothing
  downstream may require it to be resolved before the record can be written.
  `force_majeure` is a member rather than a flag beside one, for the same reason
  `undetermined` is: both are answers to "who is responsible" that name no
  party, and two fields that interact would be worse than one enum that reads.
- **Consignor liability** — `assessed_value`, defaulted by the agreement's
  policy crossed with the incident's responsibility, then bounded by
  `agreement.liability_cap ?? unit.declared_value`. This matrix is the reason
  `liability_policy` is a field and not a sentence on a printout:

  | responsibility ↓ / policy → | `owner_risk` (default) | `shop_liable_except_fm` | `shop_liable` |
  |---|---|---|---|
  | `shop` — we dropped it, we lost it | 0 | **declared value** | **declared value** |
  | `third_party` — burglar, courier | 0 | **declared value** | **declared value** |
  | `force_majeure` — fire, flood, unrest | 0 | **0** | **declared value** |
  | `consignor` — it was already broken | 0 | 0 | 0 |
  | `undetermined` | 0, unassessed | 0, unassessed | 0, unassessed |

  The matrix is read from `agreement.liability_policy`, which is the policy the
  consignor signed — not the shop's current default. Changing the setting
  changes the next voucher, never a claim on an agreement already in force.

  Two rows carry the argument. **`third_party` pays under both liable
  policies**: from the consignor's side of the counter a burglary is the shop
  failing to keep their watch safe, and whether the shop then recovers from
  police or insurance is the shop's business, not a reason to hand the customer
  a loss. And **`force_majeure` is the entire difference between the two liable
  policies** — a fire, a flood, an armed robbery, a period of unrest. That is
  not a hypothetical distinction here; it is the one a Libyan shop would
  actually invoke, which is why it gets a policy value rather than an argument
  after the fact.

  The choice between `third_party` and `force_majeure` on a given incident is a
  judgement someone makes and signs — a routine break-in through a weak lock is
  arguably the first, an armed robbery the second — and the whole design is that
  the judgement is *recorded* rather than reached in an argument.

  Zero is a legitimate assessment and it is still a row. `undetermined` defaults
  to 0 but is **not** the same zero: the incident stays `pending`, appears in
  the claims report as *unassessed*, and the treasury overlay carries it as a
  count (*«N مطالبة قيد التقدير»*) rather than folding a number nobody has
  decided into a total.
- **Outstanding claim** — `consignor_claims_open()` from §5.8 sums every
  unresolved incident's `assessed_value`. It sits beside the payable in the
  treasury obligations overlay, because from the owner's side of the counter
  the two are the same question: *how much of this drawer is not mine?*
- **Settlement** — paying a claim is the **same disbursement primitive** as
  paying a payout: one register pay-out, one numbered voucher, one SMS, one
  `consignor_paid_at`-style stamp. §6.2.1 step 4 already built it; this reuses
  it with a different `source_type` and prints *سند تسوية أمانة* instead.
  A replacement instead of cash resolves to `REPLACED` and names the substitute
  unit. Nothing new is invented to move the money.

**What an incident does to the ledger: nothing, and that is the point.** The
unit's inventory value is zero, so writing it off costs the shop no stock value.
Its status moves to `damaged` / `written_off`, quantity leaves the bin, and
`value_change` is 0 — while the money, if there is any, moves as a claim
settlement that has no relationship to inventory at all. This is the
`repair-settlement-custody` separation stated in the ledger: **status is
custody, the claim is money, and neither is derived from the other.** A
consigned unit may therefore never be written off through the ordinary
`write-off` endpoint; the API refuses it and names the incident endpoint
instead, so a claim can never be silently skipped by choosing the wrong button.

**Custody exposure, before anything goes wrong.** The number that makes the
insurance conversation possible, and the one an owner holding forty watches
should see on the dashboard:

```python
consignment_custody_exposure(warehouse)   # Σ over in-stock consigned units of
                                          # declared_value ?? reserve_price ?? payout_rate ?? 0
```

One definition, registered like the rest. It is not a liability — the shop owes
nothing while the goods are safe — so it renders as its own dashboard figure
(*أمانات في العهدة*, count and value), never inside the money position.

It is reported under every liability policy, including `owner_risk`. The
shop's *financial* exposure on goods held at the owner's risk is zero, and the
figure is not measuring that: it is measuring what the shop is holding that
belongs to other people, which is the number an insurance conversation, a
security decision and a stocktake all start from. A shop that is not liable for
forty watches is still keeping forty watches in a safe.

**Unclaimed payouts age, and the money is not ours.** The consignor who never
comes back is the normal case, not the edge: a sale SMS goes out, nobody
appears, and 10,000 dinars sits in a drawer belonging to someone else. That is
an aging report (30/60/90+ since sale), a reminder SMS on the same
`apps.messaging` path and dedup discipline as §6.2.1, and a line in the
consignment statement. What it is **not** is income. Nothing in this system ever
converts an unclaimed payout into the shop's money on a timer — see §17.

**Goods that overstay.** `agreement.expires_on` is the date the owner agreed to
collect by. Past it, the unit surfaces on the same worklist with the shop's
options — return, extend, or dispose per the printed policy — and a reminder
SMS. The unit does not change status on its own; a date passing is not a
decision, and the whole point of this section is that decisions about other
people's property leave records.

### 6.3 POS

**The scan is the flow.** `resolveBarcode` gains a fourth resolution after
variant barcode, unit (carton) barcode and scale barcode: a live `StockUnit`
`code_normalized` match returns `(variant, unit)` and the line is added with
quantity 1, the unit's own price, and the identifier as the line subtitle. One
endpoint call, one indexed lookup, no dialog.

**And a fifth: the GS1 DataMatrix, which resolves everything at once.** A
pharmaceutical pack does not carry a bare serial; it carries a symbol encoding
GTIN + lot + expiry + serial as Application Identifiers, which is what makes
`serial_batch` scannable at a till rather than a data-entry chore. A parser in
`apps/catalog` — small, pure, unit-tested against real label strings — reads the
AIs and hands the resolver a structured result:

```
01 → GTIN-14        fixed 14   → the ProductVariant (variant.gtin)
17 → expiry         fixed 6    → YYMMDD, checked against the lot; a mismatch is a
                                 structured conflict, not a silent overwrite
10 → batch / lot    variable   → the StockBatch, found or refused if unknown
21 → serial         variable   → the StockUnit within that batch
11 → production date fixed 6   → stamped at receipt when present
```

Two details decide whether this works on real hardware. Variable-length AIs
terminate at `GS` (ASCII 29) or the end of the string, fixed-length ones do not
carry a separator at all — so the parser is driven by an AI length table, never
by splitting on a character. And many scanners are configured to strip `GS`,
which turns `10` + `17` into one unreadable run; the parser detects the
ambiguity and the receiving sheet says *"أعد ضبط القارئ"* with the fix, rather
than importing a lot number with a date glued to it. This is the same class of
problem the scale-label work already solved for embedded-price barcodes
(`weighing-scales-integration`), and it gets the same treatment: a table, a
parser, and tests over real strings.

At the till, one DataMatrix scan therefore adds a line with the variant, the
unit, the lot and the expiry already resolved — no picker, no dialog, one
lookup. It is the fastest path in the whole feature and it is the one a pharmacy
uses a thousand times a day.

**And the shop that has no 2D scanner already owns one.** Most Libyan shops run
1D laser scanners, which cannot read a DataMatrix at all — so the feature above
would, for them, be a reason to buy hardware before they can try it. It is not:
`apps/companion` already turns a phone on the LAN into a till camera, over
HTTPS, with a decode ladder tuned against *real photographs* rather than clean
renders — `companion-camera-decode-lessons` records that the naive path loses on
real images and that the tuned ladder is sixteen times better and sub-second.
Pointing that at a DataMatrix is a decoder swap inside a pipeline that already
exists, not a new capability.

So the receiving sheet and the POS both offer **"امسح بالهاتف"**, which opens
the companion on a paired phone and returns the same parsed
`{variant, batch, unit, expiry}` structure a hardware scanner would. A pharmacy
can run the whole of §6.1.1 on the day it installs, and buy a 2D scanner later
because it wants to be faster, not because it cannot start.

Everything else is fallback and guard rails:

- **Tapping the tile** for a serialized product opens a **unit picker sheet**
  modelled on `pos_variant_picker_sheet.dart`: in-stock units for that variant in
  this till's warehouse, showing identifier, the attributes flagged
  `show_in_picker`, the unit price, and **days in stock** (so the cashier moves
  the old one). Search focused, scan filters the list, Enter takes the top match.
- **Quantity is locked to 1.** Adding a second of the same model creates a
  second line with its own unit. `_mergeableLineFor` must never merge a
  serialized line — the merge key includes the unit id — and the `+`/`−` cart
  hotkeys are disabled on those lines (they currently ride the scan listener,
  `pos-keyboard-shortcuts`).
- **Selling without picking is refused**, always, whatever `allow_overselling`
  says (§3.5). The error names the product in Arabic and offers the picker.
  **DEFERRED 2026-09-18 — not implemented.** `_plan_unit_issue` silently takes
  the oldest sellable article instead, so the invoice, the printed warranty
  document and `StockUnit.sold_order_line` can all name a handset still in the
  drawer. Refusing outright needs `OrderLine.stock_unit` first: an order created
  and settled later (آجل, `/api/orders/` + `/api/payments/`) has no column to
  carry a selection, so a blanket refusal would make آجل sales of serialized
  goods impossible. The POS half is fixed — both routes into a serialized
  product now open the picker, where before a product with more than one variant
  went straight to the cart with no unit. §15.2.
- **Concurrency is the interesting case.** Two tills, one phone, same second.
  Checkout locks the cart's units with `SELECT ... FOR UPDATE` in a single
  batched statement alongside the existing `lock_stock_items`
  (`backend/apps/sales/services.py:833`), re-checks `status` and `warehouse`
  inside the lock, and answers a loser with a structured 400 the client renders
  as *"هذا الجهاز بيع للتو على صندوق آخر"* plus a one-tap "choose another".
  Silent success on a phone that is already gone is the one outcome this must
  never produce.
- **Quotations reserve the unit, not a number.** `StockReservation`
  (`backend/apps/sales/models.py:1145`) gains a nullable `stock_unit`; a
  reserved unit flips to `status=reserved` and disappears from other tills'
  pickers. Expiry release (`release_expired_quote_reservations`) flips it back.
  A quoted handset that someone else sells out from under the quote is a
  customer-facing failure, and quotations are how phone shops hold a device for
  the cousin who is coming at six.
- **Receipt and invoice print the identifier per line**, because that is the
  warranty document. RTL care per `pdf-invoice-rtl-currency`; on 58mm the
  identifier wraps to its own line rather than truncating.

### 6.3.1 POS Sales for Batches (FEFO Auto-Allocation, Line Splitting & Expiry Guard)

In high-throughput environments like pharmacies and supermarkets, cashiers cannot be forced to pick a batch from a popup dialog for every scan. The POS batch workflow is designed for zero cashier friction:

1. **FEFO Auto-Allocation (Default Zero-Tap Path)**:
   - When a cashier scans a product barcode or taps a product tile whose `tracking_mode` is `batch`:
   - The engine selects the **balance** in that till's warehouse with the earliest `expiry_date` (`remaining_quantity > 0`, `is_sellable`, not expired) — one indexed scan of `batch_balance_fefo_idx`, no join to the lot (§4.7). Stock of the same lot sitting in another branch is invisible here, which is the correct answer and one the pre-split model could not give.
   - The cart line renders instantly with a small badge: `[دفعة B204 | ينتهي 12/2026]`.
   - Cashier scans and rings up items at normal speed; the till does not stop or show a modal.

2. **Automatic Multi-Batch Line Splitting**:
   - When a customer buys 10 packs of an item, but the oldest batch only has 3 units remaining:
   - The checkout engine splits the line across batches:
     - 3 units from Lot A (expiring 10/2026)
     - 7 units from Lot B (expiring 02/2027)
   - Both allocations are stamped onto the sale line and written to `StockAllocation` inside the single checkout database transaction, each naming its lot identity and decrementing its own balance.

3. **Expired Batch Guard (`prevent_selling_expired_batches`)**:
   - Any batch with `expiry_date < today` is strictly disqualified from allocation.
   - If a cashier attempts to sell an item where all remaining stock is expired, the till blocks the addition with a clear Arabic notification:
     *"جميع الكميات المتوفرة من هذا الصنف منتهية الصلاحية (دفعة X انتهت في Y)"*.
   - A manager override (`inventory.override_expired_batch_sale`) is required to unlock expired sales (e.g. for authorized returns or disposal).

4. **`serial_batch` sells like a serial, ordered like a batch**:
   - The unit is what is sold, so quantity is 1 and the concurrency lock of §6.3 applies unchanged.
   - What changes is the *default pick*: the unit picker orders by its batch's `expiry_date` first and `in_stock_since` second, so zero-tap FEFO reaches the right pack without the cashier thinking about lots.
   - A GS1 DataMatrix scan pins variant, lot and unit in one action and skips the picker entirely.
   - The expiry guard below applies to the unit's batch, so an expired pack is refused even though it has a serial of its own.

5. **Manual Batch Override & Batch Picker Sheet**:
   - If a customer specifically requests a longer expiry date, or the cashier scans a specific Lot Barcode printed on the box:
   - **Direct Scan**: Scanning a lot barcode directly pins that exact batch to the cart line.
   - **Picker Sheet**: Tapping the batch badge on the cart line opens **`pos_batch_picker_sheet.dart`**:
     - Lists all available batches in the current warehouse.
     - Displays Lot Code, Expiry Date, Days Remaining (color-coded: red = <30 days, amber = <90 days, green = fresh), and Available Quantity.
     - Selecting a batch manually pins it to the cart line.

6. **Receipt & Invoice**:
   - Printed invoices and thermal receipts show the batch code and expiry date next to the item name:
     `أمكسيسيلين 500 ملغ (دفعة: B401 - ص: 08/2027)`
   - Required by health regulations in pharmacies and gives customers peace of mind.

### 6.4 Returns, exchange, warranty


- A return of a serialized line returns **that unit**: status back to
  `in_stock`, `in_stock_since` reset (so aging restarts honestly), allocation
  `in` at the rate it left at (§5.2), `Asset` ownership row closed.
- The refund/exchange screens must show the identifier and refuse a return of a
  unit that is already back in stock — the double-return, which today is only
  prevented by quantity arithmetic.
- **Warranty.** On sale, `warranty_expires_on = sale date + product.warranty_days`,
  stamped on the unit and on the created `Asset`. A counter lookup by IMEI
  answers: bought from us on X, sold on Y to Z for W, warranty valid until V,
  repaired twice. ERPNext's `maintenance_status` is derived here, not stored.

### 6.5 Transfers

`StockTransferLine` gains unit selection. Units go `in_transit` on dispatch and
`in_stock` at the destination on receipt, with `warehouse` flipping only at
receipt — so a unit in transit is nowhere sellable, which is the truth.
`StockTransferReceipt` reconciles by identifier and surfaces *"sent 5, arrived
4, missing 351...333"*, which is a shrinkage report a phone shop will actually
read.

**A lot transfer moves a number, and the lot does not move at all.** This is the
operation the identity/balance split was made for (§4.7): quantity leaves the
source `StockBatchBalance` at its rate, and arrives at the destination balance —
created if this lot has never been to that branch before — which re-weights its
own rate by the value that landed. The `StockBatch` row is not read, not copied
and not written. Lot A in the showroom is Lot A, with the same expiry, the same
supplier, the same recall exposure and the same history, because it is the same
row. Under the warehouse-scoped model this transfer had to destroy quantity in
one "Lot A" and create it in another, forking the lot's history at every branch
boundary and leaving a recall to find the pieces by string-matching a code.

In-transit lot stock is held the same way units are: quantity leaves the source
balance on dispatch and lands at the destination on receipt, so goods in a van
are sellable nowhere. A short-landed transfer (*sent 60, arrived 58*) reconciles
against the same variance path, and the missing two are a write-off proposal
against the source, at the source's rate.

### 6.6 Stock count becomes scan-the-shelf

For a serialized variant, counting a number is meaningless. The count becomes:
**scan every unit present.** The delta is then two lists, both actionable:

- expected but not scanned → **missing** (lost or stolen; write-off proposal)
- scanned but not expected → **found** (never received, or returned and never
  restocked; opening-identification proposal)

Apply writes per-unit status changes and ledger entries at each unit's own rate.

For high-value pocketable stock this is the single most valuable operational
feature in the plan, and it falls out of the model almost for free because
`StockCount` already has the blind scan→count loop, the manager-applies split
and the variance threshold.

For a batch variant the count is per **balance**, which is what a counter
actually does: they are standing in one room counting the packs of one lot on
one shelf. Variance is `counted − balance.remaining_quantity` in that warehouse,
and the lot's stock elsewhere is neither shown nor touched. A lot found in a
warehouse that has no balance for it opens one — that is how stock that walked
between branches without paperwork gets found, and it is a finding worth
surfacing by name rather than absorbing into a number.

### 6.7 Repairs and operations

`Job` gains a `stock_unit` target so a shop can work on its own inventory, and
the completed job's cost capitalises (§5.6). The existing settlement/custody
gate (`repair-settlement-custody`) is untouched — that governs *customer*
devices leaving, which a shop-owned unit is not.

### 6.8 Write-off, damage, loss

One action, one permission (`inventory.write_off_stockunit`), a required reason,
an event row, an issue at the unit's own rate. Reported monthly by reason. This
is where a stolen handset goes, and the report is what tells an owner it is
happening.

**Except when the handset was not ours.** A consigned unit is refused here and
sent to §6.2.2: its own rate is zero, so this action would move no money and
record no claim, and a shop that lost someone else's camera would have written
off a liability by filling in a reason box. Losing our own stock costs stock
value; losing someone else's costs cash we have not yet been asked for. Two
different events, two different screens.

### 6.8.1 Batch Recall, Quarantine & Consumer Alerting

In regulated trades (pharmacy, packaged foods, cosmetics), a manufacturer, distributor, or health authority may issue an urgent batch recall due to contamination, labeling errors, or defects.

1. **One-Tap Quarantine (`حجر الدفعة`)**:
   - Authorized manager (`inventory.quarantine_batch`) clicks "Quarantine" on the batch detail screen.
   - Sets `batch.status = QUARANTINED` and `batch.is_locked = True` — **one write, on the lot identity** (§4.7), which propagates `is_sellable = False` to every balance in the same transaction.
   - Takes effect immediately across all POS registers, online stores, and warehouses: any attempt to add or checkout from this batch fails with an emergency recall warning. There is no window in which one branch is quarantined and another is still selling, because there is no second row to forget. Under a warehouse-scoped batch table this was N writes with N chances to miss one, on the operation where missing one is the whole problem.
2. **Traceability & Recall Audit (`تقرير تتبع الدفعة`)**:
   - The system instantly queries all `StockAllocation` records for this batch.
   - Generates the complete audit trail:
     - **Inward provenance**: Supplier name, delivery date, PO number, receiving invoice, received quantity.
     - **Current remaining stock**: `batch.balances.all()` — every warehouse holding this lot and how much, in one query against one lot, awaiting return/disposal.
     - **Outward sales**: Every sale invoice, date, and customer profile who purchased from this batch. Under `serial_batch` this narrows to the exact packs: the recall names **individual serials**, which is what saleable-return verification under DSCSA/FMD-style rules actually needs, and what lets a pharmacy tell a customer whether *their* box is the recalled one.
     - **Genealogy**: `parent_batch` sub-lots created by repacking, each with its own balances, swept in the same report.
3. **Consumer Safety SMS Alert**:
   - One-tap button on the recall report: **"Notify Affected Customers" (`إرسال تنبيه للمشترين`)**.
   - Triggers `apps.messaging` to send transactional recall alerts to every customer on file who bought from this batch:
     ```
     تنبيه هام من {shop_name}:
     نرجو التوقف عن استخدام المنتج {product_name} (دفعة رقم {batch_code}) ومراجعة أقرب فرع فوراً للاسترجاع واسترداد كامل القيمة.
     للاستفسار: {shop_phone}.
     ```
   - Dedup key prevents double-messaging; delivery receipts track which customers received the safety alert.


### 6.9 Price and attribute edits are audited

```python
class StockUnitEvent(TimeStampedModel):
    unit, kind, actor, at, from_value, to_value, note, reference_type, reference_id
```

for the changes that move no stock: repriced, attribute edited, identifier
corrected, reserved, released, refurb cost added, written off, note added.
A unit's history screen is `allocations ∪ events` ordered by time. *"Who dropped
this phone's price from 1600 to 1450 and when"* is a question every used-goods
owner asks, and it should have an answer.

### 6.10 Opening identification — turning existing stock into units

A shop with 40 anonymous iPhones on hand cannot flip the switch and lose them.
`quantity → serial` offers a guided run: for each variant with stock, scan N
identifiers; each becomes a unit whose `incoming_rate` is the current bin rate
and whose `in_stock_since` is the migration date; the bin is unchanged by
construction. Refuse to finish while any unit is unaccounted for, and allow
"identify later" only with the same visible worklist as §6.1.

---

## 7. API surface

Additive, versionless, and shaped like what is already there.

```
GET    /api/inventory/stock-units/            filters: variant, product, status,
                                              warehouse, code, attr.<key>, age_days,
                                              supplier, ordering=in_stock_since|price
GET    /api/inventory/stock-units/{id}/
GET    /api/inventory/stock-units/{id}/history/      allocations ∪ events
POST   /api/inventory/stock-units/lookup/            {code} → unit + variant + status + sale
PATCH  /api/inventory/stock-units/{id}/              price, attributes, notes  (permissioned)
POST   /api/inventory/stock-units/bulk-reprice/      {ids[], price | percent}
POST   /api/inventory/stock-units/{id}/write-off/    {reason}
GET    /api/inventory/stock-units/summary/           counts by status, aging buckets

POST   /api/purchasing/receipts/{id}/capture-units/  per-line codes+attrs+costs
POST   /api/purchasing/receipts/{id}/capture-batches/ multi-lot codes+expiries+quantities (into this receipt's warehouse)
POST   /api/purchasing/receipts/{id}/capture-serial-batch/ lot header + serial scan loop, one call (§6.1.1)
GET    /api/purchasing/receipts/missing-identifiers/ the worklist

# consignment (الأمانات):
GET    /api/inventory/stock-units/consignment-payables/   sold units awaiting customer payout
POST   /api/inventory/stock-units/{id}/disburse-payout/   record register pay-out & close payable
POST   /api/inventory/stock-units/{id}/resend-consignor-sms/ trigger/retry customer sale SMS
POST   /api/inventory/stock-units/{id}/return-to-consignor/ return unsold unit to consignor
CRUD   /api/inventory/consignment-agreements/             the signed سند; submit starts custody
GET    /api/inventory/consignment-agreements/{id}/statement/ one consignor: in, sold, paid, claimed, net
GET    /api/inventory/consignment-position/               the four figures of §5.8, as of a date
GET    /api/inventory/consignment-incidents/              filters: unit, kind, responsibility, resolution
POST   /api/inventory/consignment-incidents/              record loss/damage/theft (§6.2.2)
POST   /api/inventory/consignment-incidents/{id}/settle/  pay, replace, waive or close with no claim

# batches & lots (الدفعات وتواريخ الصلاحية) — the LOT is the resource:
GET    /api/inventory/stock-batches/                      filters: variant, status, is_expired, is_near_expiry,
                                                          warehouse (= "has a balance there", not a scope)
GET    /api/inventory/stock-batches/{id}/                 the lot, with its balances inlined
GET    /api/inventory/stock-batches/{id}/balances/        where this lot is, and how much of it
GET    /api/inventory/stock-batches/{id}/history/         lot movements & allocations, all warehouses
GET    /api/inventory/stock-batch-balances/               filters: variant, warehouse, is_sellable, expiry before/after
                                                          — the per-place list the FEFO index serves
POST   /api/inventory/stock-batches/lookup/               {variant, code} → the lot, or a 404 that offers to create it
POST   /api/inventory/stock-batches/{id}/quarantine/      emergency recall / stop-sale
POST   /api/inventory/stock-batches/{id}/release-quarantine/
GET    /api/inventory/stock-batches/{id}/recall-report/   traceability: customers, invoices, remaining stock
POST   /api/inventory/stock-batches/{id}/notify-recall/   broadcast safety recall SMS to buyers
GET    /api/inventory/stock-batches/expiry-watchlist/     batches expiring within N days

# extended for consignment obligations:
GET    /api/treasury/position/       response gains  obligations{consignor_payable, consignor_claims_open}
                                     — an overlay on the total, never subtracted from it (§5.8)

GET    /api/catalog/asset-types/{id}/unit-attributes/
CRUD   /api/inventory/unit-attribute-definitions/

# extended, not new:
POST   /api/sales/checkout/          line gains  stock_unit  or  stock_batch  (auto-allocated FEFO)
GET    /api/catalog/resolve-barcode/ resolution gains  stock_unit  and  stock_batch  lookups,
                                     and parses a GS1 DataMatrix into
                                     {variant, batch, unit, expiry} in one call (§6.3)
GET    /api/price-checker/lookup/    a scanned identifier returns that unit/batch price & expiry.
                                     UNAUTHENTICATED on the LAN in kiosk mode, so it answers from a
                                     narrower serializer that carries no cost, no consignment terms
                                     and no supplier — by construction, not by permission (§13)
POST   /api/inventory/stock-counts/{id}/scan-unit/
POST   /api/inventory/stock-counts/{id}/scan-batch/
POST   /api/inventory/transfers/{id}/units/
POST   /api/inventory/transfers/{id}/batches/
```

Error shapes reuse what exists: identity conflicts like `catalog/identity.py`,
lifecycle refusals like `documents/errors.py`, stock refusals like the
`{"detail": ..., "stock": [...]}` shape `prepare_sale_stock_adjustments` already
raises. Nothing here invents a new error dialect.

Caching: the units list gets an ETag off a Redis unit-version counter, the same
mechanism as `catalog-version-etag-price-cache`, and the client dedupe must be
cleared on unit writes (`caching-initiative-2026-07` — the bug that memory
records is exactly this).

---

## 8. Frontend

Arabic-first, RTL, no hardcoded strings, MVVM, dense (AGENTS.md). Everything
below is gated on `ShopSettings.enable_serialized_inventory` / `enable_batch_tracking` **and** on the
product's own tracking mode, so a grocery never renders one pixel of it.

### 8.1 New surfaces

| Where | What |
|---|---|
| `features/inventory/views/stock_units_screen.dart` | The units list: search by identifier, filter chips (status, warehouse, attribute, age bucket), multi-select bulk reprice / transfer / write-off. Follows `bulk-operations`. |
| `features/inventory/views/stock_unit_detail_screen.dart` | `PointyDetailHero` + `PointySummaryList` + attributes + photos + the life timeline. Actions: reprice, edit attributes, write off, print label, open invoice, open asset, **watch the sale**. Consignment badge, consignor details, and manual SMS resend trigger. |
| `features/inventory/views/unit_capture_sheet.dart` | The scan-and-fill loop, shared by receiving, counter purchase, consignment intake, opening identification and stock count. **One widget, five callers** — this is the piece to build well. It is a `ScanWedgeTarget`: see the note under this table, which is not optional. |
| `features/inventory/views/consignment_payables_screen.dart` | Sold consignment units awaiting customer payout: consignor details, phone, item, invoice number, payout amount due, aging bucket for the owner who never came back, and one-tap register disbursement. |
| `features/inventory/views/consignment_agreement_screen.dart` | The signed سند: consignor, units covered, payout terms, declared values, liability policy, expiry, signature attachment. Intake writes it; the statement reads it. |
| `features/inventory/views/consignment_position_card.dart` | The four figures of §5.8 — stock value 0, cash collected, consignor payable, shop commission — plus custody exposure (count and value of goods held). Dashboard and the consignment screen share it. |
| `features/inventory/views/consignment_incident_sheet.dart` | Record loss/damage/theft on a consigned unit: kind, narrative, photos, responsibility, assessed value. Low permission to open, manager permission to settle. |
| `features/pos/views/pos_unit_picker_sheet.dart` | In-stock units for a variant: identifier, picker attributes, price, days in stock, consignment badge. |
| `features/inventory/views/stock_batches_screen.dart` | Batches list: filter by status (active/quarantined/expired), warehouse, near-expiry alert chips, search by lot code. |
| `features/inventory/views/stock_batch_detail_screen.dart` | The lot: code, GTIN, expiry, manufacturer, supplier, quarantine toggle, genealogy, recall audit — plus a **"where it is" panel** listing every warehouse balance with quantity and rate, which is the screen the identity/balance split exists to make possible. Under `serial_batch`, the units in the lot. |
| `features/inventory/views/batch_capture_sheet.dart` | Multi-lot receiving capture sheet: lot code, expiry date, manufacture date, quantity per lot, residual counter. |
| `features/pos/views/pos_batch_picker_sheet.dart` | Available balances for a variant **in this till's warehouse**: lot code, expiry date, days remaining (color-coded), available quantity. Stock of the same lot in another branch is deliberately absent. |
| `features/inventory/views/batch_recall_screen.dart` | Recall audit dashboard: list of sold invoices, customers, and one-tap SMS safety broadcast. |
| `features/settings/views/unit_attributes_screen.dart` | Attribute definitions per asset type. |

**Every surface in this table that a scanner points at must declare itself a
`ScanWedgeTarget`.** `ScanBurstGuard`
(`frontend/lib/src/shared/barcode/scan_burst_guard.dart`) exists to stop a
wedge's digits becoming a line quantity, and it does that by rolling back any
digit run typed faster than a human can type — which is exactly what an IMEI
scanned into a capture field looks like. Opt out and the guard swallows the
scan; the capture loop then appears to simply not work, intermittently, on
whichever pane happens to hold focus. `pos_cart_pane.dart` and
`purchase_draft_pane.dart` already carry the opt-out and are the pattern to
copy. This applies to the unit capture sheet, the batch capture sheet, both
picker sheets, the units and batches lists' search fields, and the stock-count
scan loop.


### 8.2 Modified surfaces

- `features/catalog` product form — tracking mode segmented control, asset type
  picker, warranty days, and the variant-vs-unit help text from §4.1. Guarded
  transitions with an explanatory dialog, never a silent flip.
- `features/pos` — `CartLine` gains `stockUnitId` / `stockUnitCode`
  (`frontend/lib/src/data/models/cart_line.dart`); merge key includes it;
  `pos_barcode_actions.dart` handles the new resolution; `cart_line_tile.dart`
  renders the identifier; `unit_quantity_sheet` is suppressed for serialized
  lines; checkout payload carries the unit.
- `features/purchasing` — receiving screen capture step, per-unit cost split
  sheet with a live residual, missing-identifier worklist card.
- `features/returns_exchange` — identifier shown, unit-aware refusals, and the
  buy-it-in / reopen-the-consignment choice of §5.8 when a paid-out consigned
  item comes back.
- `features/stock_count` — serialized count mode and the two-list variance view.
- `features/price_checker` — identifier lookup returns the unit's own price and,
  for a lot, its expiry. Kiosk mode included, and it is the surface with the
  sharpest rule in this plan: **the kiosk never sees cost.** Staff-mode lookup is
  permissioned per `price-checker-settings`; kiosk mode answers from the
  cost-free serializer of §13 whatever the settings say.
- `features/operations` — job can target a stock unit; refurb cost shown on the
  unit.
- `features/dashboard` — a units card: in stock, value, aging, missing
  identifiers. Where consignment is on, a second card: goods held in custody
  (count and declared value), payouts owed, claims open. Masonry rules per
  `dashboard-masonry-layout` (Row + stretch throws; use start).
- `shared/navigation/navigation_catalog.dart` — one destination, which gets the
  command palette entry for free (`command-palette`).

### 8.3 Printing

- **Shelf/box label** via the existing PDF label toolkit: model, variant,
  identifier as **Code 128** (dot-snapped per `barcode-label-pdf-printing`),
  price, and any attribute flagged `show_on_label`. Printing the label at
  receipt is what closes the loop — the box gets scanned at the till like any
  barcode. Where the manufacturer's box already carries a scannable IMEI
  barcode, the label is optional and the flow is identical.
- **Receipt and A4 invoice** print the identifier per line; RTL-safe.

**Watch the sale (free, because it is already built).** `apps.surveillance`
already links recorded footage to an invoice by timestamp, with the recorder's
clock offset measured so the clip lands on the right moment
(`dvr-camera-integration`). A serialized unit knows the invoice it left on, so
its life timeline gets a **"شاهد لحظة البيع"** action that opens that invoice's
clip at the sale, with the shop's existing pre/post roll. No new integration —
one deep link from a row that already holds the invoice id — and the highest-
value goods in the shop are exactly the sale anyone ever wants to re-watch: a
warranty dispute, an insurance claim, a police question, or an owner asking who
was at the counter when a 12,000-dinar handset went out. Gated on
`enable_surveillance`, absent entirely when it is off.

The same link runs the other way for consignment: an incident (§6.2.2) records
`discovered_at`, so the incident screen offers the footage around that moment,
which is the difference between a claim and an argument.

### 8.4 AI

- Two assistant tools: `lookup_stock_unit(code)` and `list_stock_units(filter)`,
  answering *"أين الجهاز 3512…؟"* and *"كم جهاز عندنا أكثر من ٩٠ يوم؟"* with a
  `pointy://` deep link into the unit detail.
- One generative-UI catalog item — a unit card (identifier, attributes, price,
  age) built from existing shared components, no styling props, then
  `make frontend-export-ai-catalog` or the backend test fails.
- Invoice intake: a supplier invoice photo that lists IMEIs should extract them
  into the capture sheet (`invoice-intake-pipeline` already does line
  extraction).

### 8.5 Localisation and preview

All strings into `frontend/lib/l10n/app_ar.arb`, then `flutter gen-l10n`. A
preview harness `frontend/lib/dev/serialized_inventory_preview.dart` cloned from
`stock_count_preview.dart` with a `make frontend-serialized-preview` target and
a launch.json config, board mode plus single surfaces. Reload after start —
black canvas is the refresh bug, not a slow compile (`preview-reload-not-wait`).

---

## 9. Reporting

New report types in `apps/reports` (which already carries 19):

1. **Unit ledger** — one identifier's whole life. The screen a warranty claim,
   an insurance claim or a police question is answered from.
2. **Aging / dead stock** — units by days held, bucketed, with capital tied up
   per bucket and per model. For a used-goods trader this is the single most
   important report in the system: depreciation is real and unpriced.
3. **Per-unit margin** — realised profit per device, because each has its own
   cost and its own price. Roll up by model, by grade, by supplier, by cashier.
4. **Purchase provenance** — what we paid whom for which identifiers, and what
   each fetched.
5. **Shrinkage** — written off and missing-at-count, by reason and by month.
6. **Warranty exposure** — units still in warranty, by expiry month.
7. **Consignment ledger & payables** — units on consignment, units sold awaiting
   payout, payouts disbursed, and shop commission earnings. Carries the four
   figures of §5.8 and a **per-consignor statement** — everything in, everything
   sold, everything paid, everything claimed, net owed — which is the page a
   consignor is handed across the counter when they ask.
8. **Custody exposure & unclaimed payouts** — goods held for other people by
   count and declared value, with an aging of payouts owed but never collected
   (30/60/90+) and of agreements past their `expires_on`. The report that makes
   both the insurance conversation and the phone-call list possible (§6.2.2).
9. **Consignment incidents & claims** — every loss, damage and theft on
   consigned goods, by kind, responsibility and resolution, with claims
   outstanding and claims settled. Small, and the first thing anyone asks for
   after the first incident.
10. **Lot traceability & recall audit** — end-to-end genealogy of one lot:
    supplier and inward receipts, every warehouse it passed through and what is
    left in each, its sub-lots, and every customer invoice it reached. One lot
    row, one report, no code string-matching — which is the operational payoff
    of §4.7. Under `serial_batch` it descends to the individual serials.
11. **Where is this lot** — the lot's balances across warehouses, with quantity,
    rate and value per place. Small, and it is the report a branch manager and a
    recall both open first.
12. **Expiry watchlist & markdown suggestions** — balances expiring in 30/60/90
    days, per warehouse and with capital at risk, and suggested promotional
    discounts to clear stock. Per warehouse because the markdown decision is
    made by whoever is standing in front of the shelf.
13. **Batch profitability** — realised profit and gross margin per lot, landed
    cost against selling price, netted across every warehouse it sold from.

All CSV-exportable through the existing streaming export path
(`analytics-export-streaming`), all subject to the period lock.

---

## 10. Permissions, settings, presets

**Settings** — `ShopSettings.enable_serialized_inventory` (default **False**),
`enable_batch_tracking` (default **False**),
`serialized_capture_later_allowed` (default False),
`serialized_require_customer_for_asset` (default True),
`consignment_auto_sms_on_sale` (default **True**),
`consignment_default_liability_policy` (choices: `owner_risk`, `shop_liable_except_fm`, `shop_liable`; default **`owner_risk`** — §17.7),
`consignment_liability_clause_<policy>` (three editable Arabic sentences, one per policy, seeded with defaults and printed verbatim on the voucher — the enum value is structural, the printed words are the shop's),
`consignment_require_declared_value` (default **True**; custody exposure and every claim are measured against it),
`consignment_unclaimed_payout_reminder_days` (default 30; 0 disables the reminder),
`consignment_sale_sms_template` (Arabic customizable template with `{consignor_name}`, `{product_name}`, `{code}`, `{invoice_number}`, `{payout_amount}`),
`prevent_selling_expired_batches` (default **True**),
`batch_auto_pick_strategy` (choices: `fefo`, `fifo`; default `fefo`),
`default_expiry_warning_days` (default 30).

Presets:
- **Serialized trades**: `phone_repair`, `mobile_trader`, `car_workshop`, `laptops_computers`, `cameras_photo`, `gaming_consoles`, `luxury_watches`, `luxury_handbags`, `jewelry_precious`, `appliances_tv`, `bicycles_ebikes`, `power_tools` turn serialization on.
- **Batch trades**: `pharmacy`, `cosmetics`, `grocery_fmcg`, `tires_automotive` turn batch tracking on with FEFO auto-allocation.
- **Both at once** (`serial_batch`): a pharmacy's GS1-coded imported lines, and
  tyres, which carry a DOT lot and a casing serial. The mode is set per product,
  never per shop, so the same pharmacy sells serialised imports and anonymous
  local stock from one catalog — which is what its shelves actually look like.
Setup wizard gains questions tailored to the chosen trade:
*"هل تتابع منتجاتك برقم تسلسلي / IMEI / رقم الشاسي؟"* أو *"هل تتابع الأصناف برقم الدفعة وتاريخ الصلاحية (FEFO)؟"*


**Permissions**, added to `apps/core/permission_catalog.py` under the existing
`inventory` group so the per-user editor picks them up automatically:

```
inventory.view_stockunit              عرض الأجهزة المسلسلة
inventory.add_stockunit               تسجيل أجهزة جديدة (receiving, counter purchase)
inventory.change_stockunit            تعديل بيانات الجهاز (attributes, notes)
inventory.reprice_stockunit           تعديل سعر الجهاز
inventory.write_off_stockunit         شطب جهاز (فقد / تلف)
inventory.view_stockunit_cost         عرض تكلفة الجهاز
inventory.disburse_consignment_payout صرف مستحقات الأمانات (register payout)
inventory.view_consignmentagreement   عرض سندات الأمانات
inventory.manage_consignmentagreement تحرير سندات الأمانات وشروط العمولة
inventory.record_consignment_incident تسجيل تلف / فقدان أمانة
inventory.settle_consignment_claim    تسوية مطالبة أمانة (صرف تعويض)
inventory.view_consignment_liability  عرض مستحقات ومطالبات الأمانات

inventory.view_stockbatch             عرض الدفعات وتواريخ الصلاحية
inventory.manage_batches              إدارة الدفعات وتعديل بياناتها
inventory.adjust_batch_balance        تعديل رصيد دفعة في مستودع
inventory.quarantine_batch            حجر الدفعة وتفعيل أمر الاستدعاء
inventory.override_expired_batch_sale تجاوز حظر بيع الدفعات منتهية الصلاحية
```

Role defaults: cashier gets view + sell (no cost, no reprice, FEFO auto-allocation); inventory clerk
gets view/add/change batches & units; purchasing agent gets add at receipt; manager gets all including quarantine & override.
The consignment pair is deliberately asymmetric: **`record_consignment_incident`
goes to everyone who touches stock, `settle_consignment_claim` to managers
only.** Whoever finds the broken camera must be able to say so on the spot — a
permission wall in front of *reporting* a problem is a permission wall in front
of ever hearing about it — while deciding what the shop owes for it is a
judgement that moves money. The same split as stock count's staff-count /
manager-apply (`stock-count`), for the same reason.
`view_stockunit_cost` is the first field-level cost mask in the codebase — a
small, contained instance of benchmark-plan Phase 6, and a real need: a used-goods
shop does not show the counter staff what it paid the walk-in seller.

---

## 11. The performance budget

Non-negotiable, per anti-goal §8.6 and the existing query-count guards.

1. **A cart with no tracked line pays zero extra queries.** Every hook is
   behind `variant.product.tracking_mode != quantity`, resolved from the bulk
   preload the checkout already does (`preload_line_variants`). Add
   `tracking_mode` to that select so it costs nothing.
2. **A cart with serialized lines pays one extra statement**: the batched
   `SELECT ... FOR UPDATE` over its unit ids, alongside the existing
   `lock_stock_items`. Not one per line.
3. **Allocations are bulk-created**, one statement per checkout, mirroring
   `create_stock_movements`.
4. **Identifier resolution is one indexed lookup** on `code_normalized`. A GS1
   DataMatrix is parsed in-process and resolves in the same single call — the
   AIs give the variant, the lot and the serial, so nothing is looked up twice.
5. **FEFO is one indexed scan of one table.** `batch_balance_fefo_idx` covers
   `(variant, warehouse, is_sellable, expiry_date, remaining_quantity)`, and the
   lot is never joined on the checkout path. This is what the §4.7
   denormalisation is bought with, and the query-count test asserts it as a
   number rather than a hope.
6. **The picker is paginated and warehouse-scoped**, ordered by
   `in_stock_since`, served by the composite index in §4.4. A shop with 3,000
   units in one model still opens it in constant time.
7. **The units list is keyset-paginated**, not offset — the lesson of
   `purchases-screen-perf`. The consignment payables list is the same shape and
   the same rule.
8. **The treasury obligations overlay costs one aggregate, not a walk.**
   `consignor_payable()` and `consignor_claims_open()` are each a single
   annotated aggregate over indexed columns, computed beside the position rather
   than per account, and skipped entirely when the shop has no consigned units —
   the money position is a screen an owner opens twenty times a day and it must
   not learn a new join for a feature most shops never turn on.
9. New tests in `test_checkout_query_scaling.py` assert (1) and (2) as numbers,
   because that is the only form of this promise that survives a year.

---

## 12. Migrating the prospect off "one product per phone"

This is a deliverable, not an afterthought: it is what converts the conversation
into a sale. Their objection will not be the price; it will be *"we have four
years of history in there"*.

Pointy's migration pipeline is file-based (upload → convert → detect → import →
delete, `data-migration-system`) and has already done harder name-archaeology
than this (`fahd-uom-backfill` classified pack codes from sale evidence;
`fahd-mdb-migration` reconstructed invoices from a control log at 98% print-validated
accuracy).

A **"collapse serialized products"** step:

1. **Cluster.** Group products whose names share a stem after stripping trailing
   identifier-ish and condition-ish tokens. Cluster key = the stem.
2. **Extract.** Pull IMEI/serial (15-digit runs, `IMEI` prefixes), storage
   (`\d+ ?(GB|TB)`), colour (against a colour lexicon, Arabic and English),
   battery (`\d{2,3} ?%`), grade (A/B/C/+).
3. **Propose.** Product = stem; variant options = storage × colour; unit =
   identifier + battery + grade; cost = that product's single purchase; price =
   its single sale or its list price; dates = its receipt and its invoice.
4. **Preview and approve.** A screen showing *"340 products → 12 products, 31
   variants, 340 units"*, with the low-confidence rows listed first and
   individually editable. Nothing is written until the owner approves. Anything
   unparseable stays a product; the migration is allowed to be partial.
5. **Import.** Units are created with `status` derived from history (sold ones
   sold, on-hand ones in stock), and their allocations backfilled so the ledger
   and the bins agree — verified by the §5.4 invariants before the run commits.

Run it on their real export before the meeting. A screen that shows their own
catalog collapsing from 340 rows to 12 is a better demo than any feature list.

---

## 13. Enforcement

Where the rules live, so they cannot be forgotten by the next caller:

- **Database.** Partial unique on live `code_normalized` (units); **full unique
  on `(variant, code_normalized)` for lots**, because a lot's identity is
  permanent where a serial's is only live (§4.7); unique `(batch, warehouse)` on
  balances; check that an allocation names a unit or a batch; check that a unit
  allocation has quantity 1; check that a balance is non-negative and never
  exceeds what it received; `PROTECT` on unit and batch from allocations
  (history is never deleted by deleting a unit or a lot).
- **Archiving a product with live units is refused and names them.**
  `archived_at` hides a product from the catalog (`product-archive`), and a
  hidden product whose forty handsets still sit in a bin is a stock report
  nobody can explain. Allowed once every unit is `sold`, `written_off` or
  `returned`; the refusal lists the units and offers the units list filtered to
  them, in the shape `catalog/identity.py` established. The same guard covers
  `is_active = False`, and a lot with a non-zero balance anywhere.
- **Tracked service and prepared products are refused at both ends** — §4.2.
  The serializer and `Product.clean()`, not one of the two, because the AI
  tools and the file importer write products without passing through a form.
- **Cost never leaves the price-checker kiosk.** The kiosk lookup is
  unauthenticated on the LAN (`price-checker-kiosk-mode`), so there is no user
  for `view_stockunit_cost` to mask and a permission check is the wrong
  mechanism. The kiosk serializer is a **separate, narrower serializer** that
  has no cost fields on it at all — not a filtered view of the authenticated
  one, because a filtered view is one careless `fields = "__all__"` away from
  publishing what a shop paid for every phone on its shelf to anyone on the
  wifi. A guard test asserts the kiosk response's key set, by name.
- **The two rules the database cannot hold, and where they live instead.**
  Allocation shape per `tracking_mode` (§4.6) and `serial_batch` requiring
  `unit.batch` both reach from the allocation through the variant to the
  product, which no check constraint can see. They are held by a single writing
  service plus a guard test named after each failure. Denormalising
  `tracking_mode` onto every unit and allocation to make them checkable was
  considered and rejected: a column on the largest tables in the feature, to
  hold a rule whose value changes when a product's mode does.
- **The denormalisation guard.** `StockBatchBalance.expiry_date` and
  `is_sellable` are written only by `StockBatch.save`'s propagation. A guard test
  fails when any other call site writes `status`, `is_locked` or `expiry_date`
  on a lot, and invariant 12 asserts no balance disagrees with its lot. This is
  the price of keeping FEFO a single indexed scan (§11), paid openly.
- **`may_oversell()`** gains the serialized rule ahead of every other input, so
  no path can sell a phantom handset — §3.5.
- **`StockUnit.save`** normalises the code and refuses a status transition that
  is not in the allowed set (a small explicit transition table, like
  `documents/policy.py`'s).
- **A guard test file** — the shape `lifecycle-query-scaling` established — that
  fails when a new call site writes a `StockMovement` on a serialized variant
  without allocations. This is the ERPNext #42997 tripwire, and it is the single
  most valuable test in the plan because the failure it prevents is silent.
- **Money-definitions guard.** `unit cost`, `refurb cost`, `landed unit cost`,
  `unit list price`, `consignor payout due`, `consignor payable`,
  `consignor claims open`, `shop consignment commission` and
  `consignment custody exposure` each get exactly one definition, registered in
  the existing static guard (`money-definitions-guard`).
- **Consignment custody.** A consigned unit cannot be written off through the
  ordinary write-off endpoint — the API refuses and names the incident endpoint,
  so a claim is never skipped by choosing the wrong button (§6.2.2).
  `PROTECT` from incidents and from the agreement, a partial unique index that
  makes a second disbursement against one unit impossible, `assessed_value`
  bounded by the agreement's cap in `clean()`, and the fixed-payout price floor
  checked in `prepare_sale_stock_adjustments` rather than only at the till
  (§5.8). Payouts and claim settlements obey the period lock like every other
  money document.

---

## 14. Tests

### 14.1 Ported from ERPNext's bug list

Each of these is a test named after the failure it prevents:

- Receipt with accepted **and** damaged quantity produces two disjoint unit sets;
  neither overwrites the other. *(#43492)*
- Every serialized ledger entry has allocations, and their identifiers are
  readable from the entry without a join. *(#42997)*
- A newly created unit is returned in the receipt response and visible in the
  list immediately. *(#35804)*
- Serialized stock cannot go negative even with `allow_overselling=True`.
  *(their v15 removal)*
- An identifier sold previously can be received again. *(`allow_existing_serial_no`)*

### 14.2 Ours, that they do not have

- Two concurrent checkouts of one unit: exactly one succeeds, the loser gets the
  structured error, on-hand ends at zero, one ledger entry exists.
- Return restores the unit at the rate it left at, not the current bin rate.
- Landed cost allocated after receipt re-stamps units and reposts; sold units'
  COGS corrects; a locked period refuses.
- Refurb cost capitalises and the loss guard blocks a sale below it.
- Per-unit cost split must sum to the line total.
- Quotation reserve/expire round-trips the unit's status and the bin.
- Transfer: units are sellable in neither place while in transit.
- Stock count produces missing and found lists and applies both correctly.
- Selling a serialized unit to a named customer creates the asset and the
  ownership row; to a walk-in, creates neither and still records the sale.
- Cancelling a receipt whose unit is sold is blocked and names the invoice.
- IMEI Luhn and VIN check-digit warnings fire, and can be overridden.
- Selling a consignment unit enqueues an instant transactional SMS via `apps.messaging` to the consignor with invoice number and payout amount; idempotent `dedup_key` prevents double-send.
- Consignment unit price floor guard blocks POS sales below `consignor_reserve_price` without manager authorization.
- Disbursing consignment payout opens the cash drawer, records a register cash pay-out movement, stamps `consignor_paid_at`, and closes the payable. A second disbursement against the same unit is refused.
- A consignment sale posts a `consignment_cost` entry equal and opposite to its issue: cumulative ledger value on the variant is unchanged, the bin never goes negative, and COGS equals the payout. *(the §5.8 balance bug)*
- A variant holding three owned units at 1,200 and seven consigned ones reports `stock_value = 3,600` and `valuation_rate = 1,200` — consignment dilutes the quantity, never the rate.
- The worked statement: one unit consigned at a 10,000 fixed payout and sold for 12,000 reports stock value 0, cash collected 12,000, consignor payable 10,000 and shop commission 2,000 — before disbursement; payable 0 and the drawer 10,000 lighter after.
- A fixed-payout consigned unit cannot be sold below its payout rate, with or without manager override, and a percentage discount that would cross the floor is refused with the same error.
- The treasury position's `obligations` block reports the payable without changing any account balance, and a disbursed payout is counted exactly once — never twice via an `Expense` or a `SupplierPayment`.
- Recording an incident needs only `record_consignment_incident`; settling one needs `settle_consignment_claim`, and a cashier's settle attempt is refused.
- The liability matrix, as a table-driven test over all fifteen cells of policy × responsibility (§6.2.2). The three that carry it: under `shop_liable_except_fm` a `force_majeure` incident assesses 0 while a `third_party` one assesses the declared value; under `shop_liable` both assess the declared value.
- An incident with `responsibility = consignor`, or any incident under an `owner_risk` agreement, assesses 0, still writes the row, and never appears in `consignor_claims_open`.
- An `undetermined` incident assesses 0 but stays `pending`, is reported as unassessed, and is carried by the treasury overlay as a count rather than folded into the payable total.
- The voucher prints the shop's edited clause for the agreement's policy, verbatim, and an agreement created before a shop edited its clause keeps printing what it was signed under.
- `assessed_value` above the agreement's `liability_cap` is refused; writing off a consigned unit through the ordinary endpoint is refused and names the incident endpoint.
- Writing off a consigned unit moves zero stock value and settling its claim moves cash — the two are independent, and neither infers the other.
- A customer return of a consigned item that has already been paid out offers both answers, and each leaves the books consistent: bought in at the payout paid, or reopened with a consignor receivable.
- FEFO auto-allocation selects the earliest expiring sellable **balance** in that warehouse; the composite index serves it with no join to the lot; a nearer-expiry balance of the same lot in another warehouse is not selected.
- Sale quantity exceeding a single batch splits into multiple batch allocations on the same line.
- Selling an expired batch (`expiry_date < today`) is blocked at POS; manager override permission unlocks.
- Quarantining a batch (`is_locked=True`) immediately blocks checkout across all registers.
- Recall report returns the exact inward PO receipt, remaining stock in **every** warehouse holding the lot, and every customer sale invoice — from one lot row, with no code string-matching.
- **Identity vs balance.** One lot received into three warehouses is one `StockBatch` and three `StockBatchBalance` rows; its code is unique per variant; receiving the same code again adds to a balance instead of creating a second lot; receiving it with a different expiry is a structured 400 naming both dates.
- Transferring 25 of a lot to another warehouse moves quantity between balances, creates the destination balance if absent, re-weights the destination rate, and leaves the `StockBatch` row byte-identical.
- Quarantining a lot is one write and flips `is_sellable` on every balance in the same transaction; a till in a second warehouse is blocked on its very next checkout with no second write.
- A balance whose lot's expiry or status changes never disagrees with it — the §4.7 propagation guard, asserted after every batch write in the oracle.
- **`serial_batch` counts once.** A variant with 40 serialised packs in one lot reports `bin.quantity == 40`, not 80; `balance.remaining_quantity` equals the count of live units in that lot and warehouse after every movement, including returns, transfers and write-offs.
- A `serial_batch` sale writes **one** allocation naming both unit and batch, quantity 1, and it both flips the unit's status and decrements the lot's balance.
- Creating a `serial_batch` unit without a batch is refused by the service and caught by the guard test; a `batch`-only allocation on a serialized variant likewise.
- `serial → serial_batch` grandfathers existing units with `batch = NULL` onto the worklist and requires a lot on every new receipt; `batch → serial_batch` with stock on hand is refused except through opening identification.
- **GS1 DataMatrix.** A real pharmaceutical label string parses to variant, lot, expiry and serial; fixed-length AIs parse without a separator; a variable-length AI run with the `GS` stripped is detected and reported as a scanner-configuration error rather than imported as a lot number with a date attached.
- One DataMatrix scan at the till adds a line with variant, unit, lot and expiry resolved, in one endpoint call, opening no picker.
- An expired lot is refused under `serial_batch` even though the pack carries its own serial.

**The six §18 defects, each a test named after the failure:**

- A product that tracked expiry before the upgrade still consumes earliest-expiry-first after it — run by the rehearsal harness against a populated shop, not against a fixture the new code created. `tracks_expiry` reads correctly as a derived property throughout.
- Setting a `tracking_mode` on an `is_service` or `is_prepared` product is refused by the serializer *and* by `Product.clean()`; setting `is_service` on a product that has units is refused and names them.
- Archiving a product with a unit in stock is refused and lists the units; archiving succeeds once they are all sold or written off; the same holds for a lot with a non-zero balance.
- Every capture and picker surface declares itself a `ScanWedgeTarget`: a widget test types an IMEI at scanner speed into each and asserts it arrives whole. This is the one that fails silently in the field if it is missing.
- The kiosk price-checker response's key set is asserted **by name** and contains no cost, consignment or supplier field; a scanned identifier still returns the unit's price and the lot's expiry.
- Choosing آجل with a consignment line raises a confirmation naming the payout amount; the unit is flagged *مباعة آجل* on the payables screen; `consignment_payable()` counts it regardless of the invoice's balance.

**And the two wins:**

- A sold unit's timeline offers the sale's footage when `enable_surveillance` is on, resolves the recorder clock offset, and shows nothing at all when it is off.
- The companion camera returns the same parsed `{variant, batch, unit, expiry}` structure as a hardware 2D scanner for the same DataMatrix, and the receiving sheet accepts either without knowing which it got.
- Pooled promotions allocate to the cheapest units first, and the loss guard is evaluated per unit after allocation.

### 14.3 The oracle

`apps/sales/business_simulation.py` learns serialized products: the independent
oracle tracks each unit's identity, cost, location and status, and proves after
every run that all fourteen §5.4 invariants hold. It runs all four tracking
modes, and its lot bookkeeping is deliberately shaped the way §4.7 says the
model should be — one lot object holding a map of warehouse to quantity — so a
plan that ever drifts back toward one row per lot per place fails against an
oracle that never believed in it. It learns consignment too, and
tracks a second set of books for it — for every consignor, what came in, what
sold, what was paid and what is still owed — then proves the four figures of
§5.8 against them. A payable that only the code computing it agrees with is a
payable nobody has checked, and this is the money a shop is holding for someone
else. This is the harness that proved
the valuation engine (`oracle-correctness-harness`); a valuation *method* that
does not go through it is a method nobody has checked.

### 14.4 Scaling and upgrade

- Query-count guards per §11.
- `test_list_query_scaling` for the units list, batches list, and pickers.
- The upgrade-rehearsal harness (`upgrade-rehearsal-harness`) runs a populated
  shop across the migration and proves no money moved: stock value, COGS on
  every past sale, and every bin identical before and after. §15.1 adds three
  more it must prove before the contract release, and a populated **pharmacy**
  fixture — lots across warehouses, some expired, some sold — to prove them on.
- Run on Postgres (`make backend-test-pg`); the partial unique index, the GIN
  index and the scaling guards all skip on sqlite and the run still reports
  success (AGENTS.md).

---

## 15. Phasing

Each phase ships behind the flag, with the oracle extended, and is independently
useful. Serials and Batches share 80% of the underlying allocation and ledger architecture,
so co-implementing them in Phases A–B delivers both features for a fraction of the cost of separate projects.

**Phase A — the shared allocation core & ledger (≈2.5 weeks). SHIPPED 2026-09-17.**
`tracking_mode` (`quantity`/`batch`/`serial`/`serial_batch`), `StockUnit`,
`StockBatch` split into **lot identity + `StockBatchBalance`** with the migration
off today's table and the rewrite of `consume_expiring_stock_batches` onto
warehouse-aware balances, `StockAllocation` and its per-mode rules,
`UNIT_COST` and `BATCH_COST` valuation, bin consistency for all four modes
including the `serial_batch` count-once rule, the fourteen integrity invariants,
receipt capture (backend for serials, multi-lot batches and lot+serial),
permissions, settings, admin. No client. Ends with the oracle green on
serialized, batch and serialised-in-a-lot runs.

Phase A is **R1 of §15.1**, not the whole batch split: it creates and backfills
`StockBatchBalance` and dual-writes the legacy columns, leaving them the source
of truth. Reads flip in Phase B (R2) and the columns drop only once the fleet's
minimum version is past it (R3). A shop that does not use `tracks_expiry` today
sees none of this and takes Phase A as one ordinary live update.

> **CORRECTED 2026-09-18 — the paragraph above was not what shipped, and now
> is.** As first written, all three releases went out as one:
> `0026_split_batch_identity_and_balance` created and backfilled the balances
> and `0027_drop_legacy_batch_columns` removed `received_quantity`,
> `remaining_quantity` and `source_receipt_line` in the *same* release, with no
> dual-write and no fleet gate. For a shop already using `tracks_expiry` that is
> a `ProgrammingError` on every sale during the flip minute, and no clean
> rollback. **Repaired before it reached a shop:** 0027 now *loosens* those
> columns instead of dropping them, `tracking.mirror_legacy_batch_totals` keeps
> them current, and `apps/inventory/test_legacy_batch_columns.py` runs the
> previous release's own two queries against this schema so the mistake cannot
> come back silently. `received_quantity` is mirrored as a **high-water mark**,
> never as the sum of the balances' own received column — a transfer receives
> into the destination and issues from the source, and summing that would book
> 125 received for 100 goods that arrived once. **The contract release still has
> to happen:** drop the three columns and `mirror_legacy_batch_totals` together,
> gated on the fleet's minimum version being past this one.

The split and the fourth mode are both here, in the first phase, on purpose:
they are the two decisions that are cheap now and structural surgery later. A
warehouse-scoped batch table would have to be un-shipped with live lot data on
it, and `serial | batch` as an exclusive choice would have to be widened through
the allocation rules, the valuation branch, the bin, the POS resolver and the
recall report at once.

*What actually landed, and where it differs from the paragraph above.*

- Everything listed is in, plus two things that were not listed and turned out to
  be load-bearing: the **mode-transition guard** (§4.2 — `apps/catalog/tracking_modes.py`,
  including the `serial → serial_batch` grandfathering) and the **issue side of
  the sale path**, without which neither `BATCH_COST` valuation nor half the
  invariants can be exercised at all.
- The invariants live in `apps/inventory/integrity.py` as runnable checks rather
  than as prose, so the oracle asserts them after every simulated operation and a
  support engineer can point them at a real shop's database. *(CORRECTED
  2026-09-18: only through a Django shell. `integrity.py` is imported by the
  tests and the simulation and by nothing else — no management command, no
  Celery task, no endpoint — so the fourteen invariants have never run against a
  real shop. Every defect in §15.2 was found by calling them by hand.)*
- The oracle is `apps/inventory/tracking_simulation.py` — a dedicated randomized
  harness for identified stock, shaped as §14.3 prescribes (one lot object
  holding a map of warehouse to quantity, so a design that drifts back toward one
  row per lot per place fails against a model that never believed in one). It is
  **not** an extension of `apps/sales/business_simulation.py`; folding four
  tracking modes into that 5,200-line general simulation is its own piece of
  work, and the two should be merged when Phase B gives the till something to
  simulate.
- **Capture-later placeholders are `in_stock` and unidentified**, not
  `expected`. §4.3 defines `expected` as "PO placed, not arrived", and a
  placeholder is the opposite: arrived, on the shelf, and owing a number. Giving
  it `expected` would have broken invariant 1 (on-hand counts units) for goods
  that are physically present. `StockUnit.is_identified` carries the worklist,
  and the till refuses to sell a unit that has not got its number yet.
- Invariant 3 is therefore implemented as `COUNT(expected units) <= quantity_expected`
  rather than as equality: a purchase order raises `quantity_expected` without
  inventing identifiers for goods nobody has seen, because §6.1's first line says
  identifiers are captured where the goods physically are.

**Phase B — the shop operates both (≈2 weeks). SHIPPED 2026-09-17.**
Units list + Batches list & detail, receiving capture sheet (IMEI scan loop & multi-lot split),
POS barcode resolution **and the GS1 DataMatrix parser — confirmed core, not
conditional (§17.9): Libyan pharmacy stock carries these codes widely, and the
parser pays for itself at receiving before it does at the till**, FEFO auto-allocation
over balances, unit & batch picker sheets, checkout unit locking & balance decrement,
receipt/invoice identifier printing (IMEI & Lot/Expiry),
carton & shelf label printing, and **the companion camera as a DataMatrix
scanner** (§6.3) — which is what lets a pharmacy with only 1D lasers use any of
this on the day it installs rather than after it buys hardware.
**This phase closes both the phone-shop deal and the pharmacy/grocery deal.**

*What actually landed, and where it differs from the paragraph above.*

- **The GS1 parser is `apps/catalog/gs1.py`**, pure and driven by an AI length
  table rather than by splitting on a character — and its most valuable test is
  the one about a reader that strips `GS`, which a parser that split would have
  imported as a lot number with a date glued to its tail. *(CORRECTED
  2026-09-18: that test could not fail. It fed `"10" + "A" * 30`, over-long by
  construction, and the detector only fired when a fused value exceeded the AI's
  maximum — which for a lot needs twenty characters. A real pharmacy pack came
  back with the serial glued to a short lot and **no warning at all**. The
  detector now recognises a fused run by finding a well-formed element string
  inside the value, which is what a missing separator actually looks like. The
  AI table was also missing the fixed-length `310n`–`369n` measurement block and
  `8018`, and an unknown AI was assumed variable — so a net weight silently ate
  the lot number.)*
- **One scan, one answer, on the miss path.** `GET /api/resolve-barcode/` is
  reached only when the till's own catalog had nothing — a plain barcode, a
  carton barcode and a weighing-scale label still resolve locally on the first
  try, so a shop that sells Coca-Cola never sends the request at all.
- **CORRECTED — the till does not know its own warehouse.** §6.3.1 says the
  picker lists what is in "this till's warehouse", and the client has no idea
  which that is: the register profile does, and the backend already resolves it
  for every checkout. So the pickers send `for_sale=1` and the server scopes
  them, rather than the client guessing and offering goods from another branch.
- **Quantity is locked to 1 in the cart itself**, not only in the widget: the
  `+`/`−` hotkeys ride the scan listener, so a refusal that lived only in the
  tile would be one the keyboard walked straight past.
- **Receipt identifiers come off rows the sale already wrote** — the units it
  stamped and the allocations the ledger wrote — so a printed warranty document
  cannot drift from what actually left the shop. *(CORRECTED 2026-09-18: true of
  the REST order payload, and of nothing that ever reached paper. `identifiers`
  was added to `OrderLineSerializer`, but receipts print from the job payload
  `apps/printing/services.receipt_line_payload` builds, which had no such key —
  so the ESC/POS encoder's reader returned empty on every line of every receipt,
  and the A4 invoice and the PDF rolls never mentioned identifiers at all. Both
  now carry them. The one test passed by handing the key straight to the
  encoder, which is why nobody noticed.)*
- **DEFERRED, and honestly out:** the shelf/carton label PDF for lots, the unit
  and batch *detail* screens (a list row opens the life timeline instead), the
  companion camera as a DataMatrix scanner, and the price-checker's identifier
  lookup. All four are additive surfaces over an API that already exists; none
  is load-bearing for the two deals this phase is about. *(The unit detail
  screen landed in Phase C, where the consignment badge and the payout resend
  gave it a job; the other three are still out.)*

**Phase C — the used-goods trade & consignment (≈2.5 weeks). SHIPPED
2026-09-18, reviewed 2026-09-19 (§15.3).**
Per-unit pricing everywhere, per-unit cost split, counter purchase and trade-in,
`ConsignmentAgreement` intake and voucher, the `consignment_cost` ledger entry
and the fixed-payout floor (§5.8 — both are correctness, not polish, and belong
with the first consignment sale rather than after it), the derived payable and
the treasury obligations overlay, automated customer sale SMS notification via
`apps.messaging`, consignor payables screen and counter disbursement,
attribute definitions and the attribute UI, aging and per-unit margin reports,
refurb capitalisation, returns and warranty lookup.

*What actually landed, and where it differs from the paragraph above.*

- **The valuation engine learned what it does not own.** `IdentifiedValuation`
  now carries an *unowned* quantity beside its quantity and value, and keeps it
  out of the rate's divisor. Without it a variant holding three owned handsets
  at 1,200 beside seven consigned watches reports every handset as worth 360,
  and every report that multiplies a rate by a quantity is wrong by a factor of
  three. The state row grows a third element to say so, and a state written by
  any other engine reads back exactly as it always did.
- **`consignment_cost` is posted by the valuation pass, not by the sale.** The
  sale stamps each consigned unit's payout and hands the total to the plan; the
  pass posts the quantity-zero entry immediately before the issue it pays for.
  That is the only place that knows the ledger entry is about to be written, and
  writing it anywhere else would be writing it *near* the issue rather than
  before it.
- **CORRECTED — invariant 10 is a statement about the ledger, not about the
  units.** It was first written as "Σ consignment_cost equals Σ payout over sold
  consigned units", which is true until the first customer return: the unit
  stops being sold, the entry stays posted, and a correct ledger starts failing
  its own invariant. It now reads entirely inside the ledger — each
  `consignment_cost` entry is followed by the issue it pays for, of exactly the
  opposite value, and no running balance is negative — which survives returns,
  buy-ins and reopened consignments because all three are themselves entries.
- **CORRECTED — a trade-in needs no new tender.** §6.2 asks for "one document,
  one register entry", and the tempting reading is a new payment method. It is
  not needed: a counter purchase already pays out of the drawer and a sale
  already pays into it, and `RegisterSession.expected_cash` nets the two — so a
  1,400 sale against a 500 trade-in leaves the till expecting 900 more than it
  started with, arrived at from two documents that are each true on their own. A
  `TradeIn` row links them, exactly as `OrderExchange` links a return to its
  replacement. A trade-in worth *more* than the sale is refused rather than
  handled: paying a customer the difference in cash for goods the shop has not
  resold is how a till is emptied by somebody bringing in stolen handsets, and
  it belongs in a counter purchase the shop makes deliberately.
- **The cheapest-unit rule needed no code.** §5.7 rules that a pooled
  promotion's free item lands on the cheapest unit. `_pooled_units` has been
  most-expensive-first since promotions shipped and `_buy_x_get_y_allocations`
  already rewards the tail, so once each serialized line carries its own price
  the rule holds by construction. What landed is the test that says so, which is
  what stops it quietly changing.
- **The oracle took the goods in too.** §14.3's randomized model now runs
  consignment intake, sale and return-to-owner alongside the four modes, and
  says for itself that the shelf counts them and the stock value does not. That
  is the check with teeth: the simulated shop and the model of it are built from
  different code, and the rate-dilution bug of invariant 9 is exactly the shape
  the oracle catches and a hand-written test agrees with by accident.
- **A return of a sale that predates tracking comes back as a placeholder.**
  A product can hold anonymous quantity, reach zero, and then be switched to
  serial — and a customer can still walk back in with something sold before the
  switch. Refusing the refund is wrong and letting the quantity rise with no
  article behind it breaks invariant 1, so the goods return as *unidentified*
  units: counted, on the missing-identifier worklist, and refused by the till
  until somebody scans them. Exactly the shape *capture later* already uses,
  which is the argument for having built it that way.
- **Phase A's settings were columns nothing could edit.**
  `enable_serialized_inventory` and the six beside it shipped on the model and
  were never put on the settings API, so a shop could only get them through a
  shop-type preset. They are exposed now, along with the consignment block —
  and the three liability clauses in particular have to be editable, because
  §10's whole point is that the printed words are the shop's and not ours.
- **What a sold article cost is its own definition.** `StockUnit.stock_value`
  answers *"what does this add to the shelf"* and returns zero for a
  consignment; `StockUnit.acquisition_cost` answers *"what did this cost the
  shop"* and, for a sold consignment, is the payout. Both are on the model and
  registered in the money-definitions guard, with three new patterns — the
  commission payout, the shop's commission and the price floor — so the fourth
  surface that wants one has to import it.
- **CORRECTED 2026-09-19 — "`ConsignmentAgreement` intake and voucher" shipped
  the agreement and not the voucher.** Nothing printed either of §6.2.1's two
  documents: not the *سند استلام أمانة* both parties sign, not the *سند صرف
  أمانة* signed when money crosses the counter. The clause this plan insists on
  storing *as it was printed* was stored and never printed, which is Phase B's
  receipt-identifier failure repeated exactly (§15.2). Both are built now, and
  what they say is decided in one place a test can ask.
- **CORRECTED 2026-09-19 — per-unit pricing was per *variant* pricing whenever
  one invoice held two of the same model**, which for this trade is the ordinary
  case. Five consequences, one of them a sale the till refused outright; §15.3.
- **DEFERRED, and honestly out:** per-unit photos (§17.2 is still open, and the
  answer changes the capture sheet's shape), the per-consignor statement *screen*
  (the endpoint is built and the report carries it), the consignment position
  dashboard card (the figures render on the payables screen), unit attribute
  *editing* from the client (definitions are seeded, validated and exposed; the
  editor screen is not), and a per-unit warranty date override (§17.3 —
  `warranty_days` on the product is what shipped). None is load-bearing for the
  trade this phase is about.

**Phase D — safety, recall & warehouse operations (≈2 weeks).**
**Two items are now prerequisites rather than scope, both added by the 2026-09-18
review (§15.2).** First, **transfers, stock count, manual adjustment and
job-material issue must learn to allocate** — the tripwire in
`post_movement_valuations` refuses a tracked movement that names nothing, so on a
tracked product those four paths *raise* until they are taught. That is the right
failure, and it means this phase gates enabling the feature in a real shop rather
than following it. Second, **the contract release for the batch split** — drop
`received_quantity`, `remaining_quantity` and `source_receipt_line`, delete
`mirror_legacy_batch_totals` and `test_legacy_batch_columns.py`, once the relay
reports the fleet's minimum version past the release that loosened them.
Everything below is the original list.
`ConsignmentIncident`, claims and settlement, the unclaimed-payout aging
(§6.2.2) and the per-consignor statement *screen*,
emergency batch quarantine (`is_locked`), traceability recall audit & consumer SMS safety broadcast,
expiry watchlist & markdown discount suggestions, batch-aware and serialized transfers,
stock count (serialized scan-the-shelf and batch variance count),
opening identification for both serials and batches, price-checker lookup (with
the cost-free kiosk serializer of §13), the surveillance link from a unit's
timeline and an incident to the footage of the moment (§8.3), AI tools and
dashboard cards.
*Phase C took two bites out of this list: custody exposure is derived and shown
(`consignment.custody_exposure`, on the payables screen and in the treasury
overlay), and the write-off flow landed with the unit detail screen. What is
left of the consignment side is the incident — the path a consignment module is
actually judged on — and the statement as a page rather than an endpoint.*

**Phase E — migration (≈1 week, runs in parallel with C).**
The collapse tool of §12, against the prospect's real export.

Roughly nine to ten weeks of focused work for A–D, delivering a general
traceability engine rather than a serial feature: four tracking modes that
compose, lots whose identity survives every warehouse they pass through,
consignment carrying a real liability and custody model rather than a zero in a
cost column, and one GS1 scan that resolves all of it at a till.


### 15.1 Shipping this to shops that are already trading

**Almost all of it is an ordinary live update. One part is not, and it is the
batch split.**

The constraint is the one `zero-downtime-updates` sets and
`inventory/migrations/0023_warehouse_required.py` states better than this plan
can: the edge nginx flips backends, and *"a live update runs the previous
release against the new schema for about a minute, and that release knew nothing
about warehouses"*. Everything below is measured against that minute.

**What is a plain live update — the overwhelming majority.**

- **Every new table** — `StockUnit`, `StockAllocation`, `StockBatchBalance`,
  `ConsignmentAgreement`, `ConsignmentIncident`, `UnitAttributeDefinition`. The
  previous release cannot see a table it does not know about.
- **Every new column**, added nullable or with a default:
  `Product.tracking_mode`, `asset_type`, `warranty_days`,
  `ProductVariant.gtin`, the `ShopSettings` flags,
  `StockReservation.stock_unit`, `operations.Job.stock_unit`. The 0018–0022
  lesson applies unchanged: **nullable now, required in a later release**, never
  `NOT NULL` in the release that adds the column.
- **Every new endpoint and report.** Additive by §7's own rule.
- **New document types and their counter rows** (`gapless-document-numbering`).

**Indexes, which are the quiet trap.** This plan adds several on tables that are
large and hot — `batch_balance_fefo_idx`, the unit composite, the GIN on
attributes. Each must be `AddIndexConcurrently` with `atomic = False`, the shape
`catalog/migrations/0020_search_trigram_indexes.py` already uses, and **each must
run on a direct connection rather than through PgBouncer**: `CREATE INDEX
CONCURRENTLY` cannot run inside a transaction, and the pooler is in transaction
mode (`pgbouncer-pooling`). The unique index on `(variant, code_normalized)`
takes the two-step form — `CREATE UNIQUE INDEX CONCURRENTLY`, then `ADD
CONSTRAINT ... USING INDEX` — and the backfill that invents `code_is_generated`
values must be proven unique before either.

**The exception: `StockBatch` loses columns that the old release writes.**

§4.7 moves `received_quantity`, `remaining_quantity` and `source_receipt_line`
off `StockBatch`. The previous release writes the first two on the checkout
path — `consume_expiring_stock_batches` runs inside
`record_sale_stock_movements` — so dropping them in the same release that adds
balances would make the old backend 500 on every affected sale during the flip
minute, and leave the two representations disagreeing for however long before
that. This is the warehouse phase again, and it gets the same answer: **spread
across three releases.**

| | What ships | Old release still correct because |
|---|---|---|
| **R1 — expand** | `StockBatchBalance` created and backfilled one balance per existing row in the shop's default warehouse; new code **dual-writes** both the balance and the legacy columns; reads still come from the legacy columns | the legacy columns are still the source of truth and still maintained |
| **R2 — flip reads** | reads move to balances; dual-write continues; a verification job asserts the two agree on every batch, shop by shop | the legacy columns are still written, so a rollback to R1 is clean |
| **R3 — contract** | dual-write stops; `received_quantity`, `remaining_quantity`, `source_receipt_line` dropped; the `in`-allocation backfill that replaces provenance runs | nothing older than R2 is left in the fleet |

**R3 is gated on the fleet, not on one shop.** `relay-remote-update` lets shops
sit pinned, paused or on a canary, so the contract release cannot ship until the
fleet's *minimum* version is past R2 — a floor the relay can already report.
Shipping R3 while one pinned pharmacy is still on R1 is how a shop loses its
expiry tracking, and the rollout tooling exists precisely so that this is a
query rather than a hope.

**The blast radius is smaller than it looks.** `consume_expiring_stock_batches`
returns immediately unless `variant.product.tracks_expiry`, so the whole R1–R3
dance only concerns shops that **already** track expiry today. For every other
shop — which is most of them — the batch split touches no row that exists and
the entire plan is a single live update. Which shops those are is answerable
before any of this ships, from the relay (`relay-remote-diagnostics`), and it
should be answered rather than assumed.

Two smaller behaviours inside the same window, both benign and both worth
knowing:

- **`expiry_date` widening to nullable** is a catalog-only `DROP NOT NULL`. The
  old release's `order_by("expiry_date")` puts Postgres's NULLs last in ASC, so
  a null-expiry lot created by the new release sorts to the back of the old
  release's FIFO rather than breaking it. Degradation, not failure.
- **`consume_expiring_stock_batches` gains a warehouse argument**, which changes
  *which* lot a sale consumes, not whether one is consumed. During the flip
  minute two backends may pick differently for identical carts. Both decrement
  real stock and both leave the invariants true; the allocation choice is simply
  non-deterministic for that minute, and no report reads it as though it were.

**The client-version gate, which is the finding that is easy to miss.** §6.3
refuses a serialized sale with no unit picked, *always*, whatever
`allow_overselling` says. A till running a pre-serialization client cannot pick
a unit, so if a shop enables `enable_serialized_inventory` while one of its
tills is on an old build, that till gets a hard 400 it has no UI to recover
from — on a product it sold fine yesterday. Clients self-update from the local
backend but on their own schedule (`client-self-update`), so this is a real
state, not a hypothetical.

Rule: **the settings toggle requires a minimum client version across the shop's
registered devices**, not merely a permission. The settings screen names the
tills that are behind and offers the update, and the flag stays off until they
are current. The same gate covers `enable_batch_tracking`, whose expired-batch
refusal has the same shape.

**The rehearsal is the gate, not the reassurance.** `upgrade-rehearsal-harness`
migrates a populated shop between tags and proves no money moved. This plan
gives it three new things to prove, and none of them are optional before R3:
stock value and every past sale's COGS identical across R1→R2→R3; every balance
equal to the legacy column it replaced at the moment dual-write stops; and the
fourteen §5.4 invariants green on the migrated data, not merely on data the new
code created. A populated pharmacy fixture — lots across warehouses, some
expired, some sold — belongs in that harness before R1 ships.

### 15.2 What reviewing Phases A and B found (2026-09-18)

Fifteen findings, eleven fixed, one already handled by Phase C, two deliberately
not applied. Ten were reproduced by running them before the fix and again after,
each asserted against `apps/inventory/integrity.py` rather than against a
hand-written expectation — which is the only reason a list this size is
trustworthy, and also the reason it exists at all: the invariants were written in
Phase A and then never pointed at anything.

**One sentence covers most of them: a stock path that was never taught about
tracking.** So the deep fix is at the choke point every movement already passes
through. `post_movement_valuations` checked that a plan which *exists* adds up
and said nothing about one that is *absent* — and absence is the silent half,
because ERPNext #42997 is not a wrong serial, it is no serial at all. It now
refuses a movement of a tracked variant that names nothing. The valuation method
is already resolved on that line, so it costs no query. **Expect the consequence:
transfers, stock counts, manual adjustments and job-material issues of identified
stock now raise until Phase D teaches them to allocate.** That is the better of
the two failures — the alternative is a pharmacy discovering months later that
its bin says forty and thirty-seven packs exist.

Three balance bugs were one bug. `lock_balance` returns a **fresh instance per
call**, and both writers computed `remaining - n` from whatever they were handed,
so every reference but the last was discarded: a `serial_batch` line locks a
balance per unit, so selling two packs of a lot took *one* off it; a receipt line
that splits into an expected and an overage movement plans each half separately,
so receiving twelve against an order of ten put two on the lot and left ten on
the shelf that no lot claimed. Both writers now re-read the row first — it is
already locked, and a transaction sees its own writes.

The rest, briefly. One handset could be **sold twice**: two cart lines naming the
same unit concatenate to `[7, 7]`, and `lock_units` de-duplicates the lock but
returns a map, so re-reading it per id handed back the same article twice and the
count check agreed. **Un-receiving a delivery left the lot on the shelf** —
`discard_expiring_stock_batches` only matches generated `RL-<pk>` codes, which
the tracked receipt path never writes — so there is now a receipt reversal in the
module that owns identified stock, cancelling through the transition table rather
than around it with a bulk update that could write `in_transit → cancelled`, a
move the table forbids. The **§5.5 cost-edit refusal queried `StockUnit` only**,
and a batch-tracked order has none, so ten packs at five dinars became twenty
packs and a hundred dinars of stock value with every invariant still green; it
now names lots too. **Zero is a real rate** — `IdentifiedValuation` read a zero
outgoing rate as "nobody allocated" and substituted the shelf average, which
Phase C would have made universal since every consigned article enters at zero;
the absence of an allocation is now stated rather than inferred. The **lot
receipt had no cost reconciliation**, so a fifty-dinar purchase line received as
two lots each declaring fifty booked five hundred; the serialized path has
refused exactly this since Phase A and the lot path now does too. And
**receiving tracked stock in cartons was impossible**: the capture sheets were
seeded with the purchase-unit count while the backend counts base units, so a box
of three handsets asked for one IMEI and was refused for three, with no way out
of the sheet.

One is not applied and says so: the auto-pick refusal (§6.3 — needs
`OrderLine.stock_unit`). The R1/R3 migration collapse was the other, and it was
**repaired on 2026-09-18** once it was confirmed that `00048fc0` had not reached
a shop: 0027 loosens the legacy columns instead of dropping them, the balance
writers mirror them, and a regression file runs the previous release's queries
against the new schema. The contract release — drop the columns, delete the
mirror — is now a real item on Phase D's list rather than a thing that already
happened by accident.

**The backlog behind the findings was cleared on 2026-09-18 too**, and three of
those items were worse than the cap made them look. `consume_expiring_stock_batches`
and `may_oversell` both grew an argument naming *where* or *what* and then kept a
default, so four of five and three of four callers never passed one — a stock
count in Branch #2 drew its shrink out of the main store's lot, and the "identified
stock can never go negative" refusal only ever fired at the till. Both arguments
are required now, and a transfer, which moves many variants under one policy
decision, asks `may_oversell_document`: one identified line forbids going negative
for the whole document. **Quarantining a lot made the drug unsellable outright**,
because the picker returned the oldest pack regardless of its lot and the sale then
refused on that pack — `available_units` filters lot sellability in SQL now, and
when nothing sellable is left the planner re-asks without the filter so the refusal
still names the recall rather than reporting "no stock". **A quotation held a
number rather than an article**, so invariant 2 failed for every quote of a
serialized product, the held handset stayed in every other till's picker, and
converting sold whichever unit was oldest; `StockReservation.stock_unit` fixes all
three. And an IMEI typed in **Arabic-Indic digits** normalised to itself and passed
the Luhn check — `int()` accepts those digits — so the one check whose job is
catching a keying error created a second live unit for one handset. Every decimal
digit folds to ASCII now.

Also closed: the identifiers N+1 on the checkout response and on both tracked
lists; the units list showing page one only, with no index behind its ordering;
`effective_base_unit_cost` rounding to money before the ledger multiplied it, which
booked 99.96 against 100.00 paid on a carton of twelve; GS1's century window, which
was a fixed 49/50 cut rather than GS1's sliding one; `identify`'s check-then-write
race; and both capture sheets keying rows by list position, which stranded a
deleted row's text over the row that shifted up.

**Two remain, and both are features rather than defects.** The §15.1
client-version gate needs a device registry the shop does not have — only
telemetry carries `app_version` — and its purpose was to stop an old till hitting
a hard 400 it cannot recover from, which is mostly moot while §6.3's refusal is
deferred and the settings flags now gate the surfaces. And `tracks_expiry` still
coexists with `tracking_mode` rather than becoming the derived property of §18.4;
folding it in would move every expiry-tracking shop onto the lot path, changing
what receiving asks for and what checkout refuses, so it belongs with the contract
release and a decision rather than with a bug sweep.

**The standing lesson for Phase D.** Every one of these was invisible to the test
suite, which was green throughout, and visible in seconds to the invariants. That
is now fixed at the root: `manage.py check_stock_integrity` runs them read-only
against a real shop and exits non-zero on a violation, `make backend-stock-integrity`
and `make backend-tracked-simulation` expose it and the oracle, and both are in the
README. Run them before building anything else on this foundation.


### 15.3 What reviewing Phase C found (2026-09-19)

Thirteen findings, all fixed, plus one gap that is not a defect — the trade-in
shipped with no test at all. Every finding was reproduced by running it before
the fix and again after, and the largest of them was found by asking the question
§15.2 ended on: *what does a real shop do that no test does?* Here it is putting
**two of the same model on one invoice**, which for a used-phone shop is an
ordinary Tuesday and which nothing in Phase C had ever exercised.

**One finding is five, and it is the one to read.** A sale plans its issue **per
variant** — `prepare_sale_stock_adjustments` aggregates the cart by variant, so
two handsets of one model share one plan and two allocations. Everything after
that which needed to know *which line* an article left on re-derived it from
`lines_by_variant`, which returns the variant's **first** line. That was true
enough in Phase B, where the question was "which sale took this IMEI" and both
lines belong to the same sale. Phase C changed the question, and the same
mapping then answered five of them wrongly:

- the second article recorded the **first one's price** — `sold_price`, and with
  it the per-unit margin report;
- both articles pointed at the **first line**, so the receipt's per-line
  identifiers, the printed warranty document and `StockUnit.sold_order_line` all
  named the wrong handset;
- **returning the cheaper handset put the expensive one back on the shelf**, and
  left a sold article that is physically in the customer's hands marked as stock
  nobody can find. `units_sold_by_line` reads the units off the line, and both
  were on it;
- both lines took the movement's **blended cost**, so a 1,200 handset and an
  800 one sold together each reported 1,000 and per-line gross profit averaged
  two articles that have nothing to do with each other;
- under a **commission** agreement the second consignor's payout was computed
  from the first one's price — and when that made the line look like a loss,
  `prevent_selling_at_loss` **refused the sale outright at the payment step**. A
  shop could not sell two consigned watches of one model at two prices at all.

The fix is where the information actually exists: `Allocation` grows a
`source_key`, `attribute_allocations` tags every unit allocation with the cart
line that named it (or, for an auto-picked article, the earliest line with room),
and `finish_sold_units`, `stamp_consignment_payouts` and
`_stamp_ledger_cost_on_lines` resolve per allocation instead of per variant. Lot
allocations are deliberately left untagged: one FEFO pick can span two lines of
one drug, and splitting it would invent a precision the pick does not have.

**Phase B's paper failure, repeated exactly.** §15.2 records that `identifiers`
reached `OrderLineSerializer` and never reached a receipt. Phase C stores
`ConsignmentAgreement.liability_clause` *"as it was **printed** and signed"* —
and **nothing printed it**. There was no voucher, no payout receipt, no PDF, no
print action, on either surface; §6.2.1's *سند استلام أمانة* and *سند صرف أمانة*
existed only as sentences in this document. Both are built now
(`features/inventory/pdf/`), with the content decided in one place
(`ConsignmentDocumentContent`) that the renderer has no second source for —
because rendering itself cannot be asserted: an embedded Arabic font writes glyph
indices, so a byte search of the PDF for «الأمانة» finds nothing whatever the
page says. The payout receipt could not have named its articles either; the
serializer had no lines on it.

**The debt that runs the other way.** `reopen_consignment` — the answer the
returns desk offers when a customer brings back goods whose owner has already
collected — zeroed `incoming_rate`, which was the **only record of what the shop
had paid**, and its own docstring claimed *"the payables screen reads it and
shows a negative line"*. Nothing read it and nothing showed it. A shop could hand
a consignor ten thousand dinars, take the watch back into consignment, and have
no screen, figure or report anywhere say it was owed the money. That is §5.8's
own failure, pointed the other way, so it gets §5.8's own answer: derived, never
posted. `consignment.consignor_receivable` is the definition, the treasury
obligations overlay carries it beside the payable and **never nets it into one
figure** — a shop that owes one consignor 10,000 and is owed 3,000 by another
owes 10,000.

**A past money position carried today's obligations.**
`/api/treasury/position/?as_of=` answers with the cash that was in the accounts
on a past day; `consignor_payable(as_of=)` bounded the *sale* by that date and
read the *payment* as of now. A watch sold in August and settled in September was
missing from August's figure, so the drawer and the obligation printed beside it
described different days.

**The rest, briefly.** Searching either consignment list **500s** —
`consignor__name`, where the model's field is `full_name`, on a list §6.2.1
requires to be searchable by name; the failure is not a wrong result but a
`FieldError` the moment anybody types. The **payables list sent every row** with
no pagination and then filtered *in the client*, which on a paged list answers
«سالم has nothing owing» for a consignor whose row is further down — the worst
available wrong answer on a screen about money owed to people; it is paged now
and the search is a query. Paging it exposed **two queries per row** hiding
behind innocent property reads — `variant.full_name` fetches option values and
an invoice's `balance_due` sums its payments in Python — so both lists take a
prefetch and a scaling test, the shape `test_list_query_scaling` already uses.
`shop_consignment_commission` **walked every consignment sale the shop had ever
made** in Python on every read of the position screen, and is one aggregate now.
`refuse_trade_in_above_sale` was asked only of the payload's own arithmetic,
before the purchasing and discount engines had settled the real totals, and is
now asked again of both documents inside the transaction that unwinds them. And
`close_agreement_if_empty` was a predicate called as a statement, which is now
named as the question it is.

**Capitalising a repair wrote the article and not the shelf.** §5.6 says a
fitted screen adds to `unit.refurb_cost`, and that is what it did — with no
ledger entry and no bin behind it. `StockValuationBin` is a *cache of the
ledger*, not a projection of the units, so after any refurbishment the article
said 1,350 and the shelf said 1,200; **invariant 4 failed immediately**, and the
sale that followed issued 1,350 of value out of a bin that had only ever taken
1,200 in. It is the same drift §5.8 diagnoses at length for consignment, one
function over, and it survived for the reason §15.2 already named: none of the
four refurbishment tests asserted the invariants that every other test in this
phase asserts. There is a `REFURBISHMENT` voucher type now, posted the way
`consignment_cost` is — quantity zero, value only, bin and entry written
together — and released in mirror when a job is reopened. The migration is a
`choices` change and nothing else, so it is an ordinary live update (§15.1).

**A repost destroyed the half of the ledger that has no quantity.**
`repost_variant` rebuilds a variant's valuation by replaying its entries, and it
asked each one a single question: did this add stock, or remove it? A
`consignment_cost` entry does neither — quantity zero, value only — so it fell
into the removal branch, removed nothing, and had its **stored value overwritten
with zero**. The sale immediately after it then replayed at minus the payout
against a ledger that no longer had it, so a repost re-created, in one pass,
exactly the negative drift §5.8 was written to prevent. The same replay also
lost the *unowned* count — it lives on the allocations and nowhere on the entry
— so after a repost seven consigned watches counted as owned stock worth
nothing and three 1,200 handsets beside them reported 360 apiece, which is
invariant 9 verbatim. Neither is hypothetical: a landed-cost re-stamp (§5.5), a
method change and `manage.py repost_valuation` all reach it. The replay now
reads a value-only entry's stored value rather than recomputing it, and
re-derives the unowned count from the allocations.

**The trade-in had no test at all.** Not one, in either tree — §6.2's whole
claim, that a trade-in needs no new tender because `expected_cash` nets a
counter purchase against a sale, was unasserted. It is true, and five tests now
say so, including the two that matter: the drawer expects exactly the difference,
and a refused sale takes its purchase down with it.

**What the tools did and did not find, precisely.** §15.2 ended on the lesson
that the invariants find in seconds what the suite cannot see, and this review
is the boundary of that claim rather than a contradiction of it.

- **Eleven of the thirteen were invisible to both.** The oracle ran 2,000
  operations across five seeds and stayed green; the invariants were asserted
  after every new consignment path and never fired. They could not have: each of
  those eleven is a place where a **document, a screen or a person** was told the
  wrong thing while identified stock and the ledger agreed perfectly. An
  invariant over the ledger is the wrong instrument for "which line is this
  handset printed on". What worked was reading each claim this plan makes and
  asking what actually reads it.
- **The refurbishment one was found by the invariants, the instant anything
  pointed them at it.** `assert_tracking_invariants()` appears in every Phase C
  test except the four about refurbishment; adding one line to the first of them
  failed immediately with invariant 4. That is §15.2's lesson holding exactly,
  and the standing instruction it implies is narrower and more useful than
  "run the invariants": **a test of a path that moves stock or value asserts
  them, or it is not a test of that path.**
- **The repost one was found by reading.** Building the value-only poster raised
  the question of what replays a zero-quantity entry, and the answer was
  nothing.

**One edge is left open, and says so.** §5.8 says a reopened consignment's
receivable is *"settled against the next sale or collected back"*. Settling
against the next sale is what the rows already do — `consignor_paid_at` stays
stamped, so the re-sale opens no new payable and the two obligations cancel —
and under a **fixed** payout, which is the default and the common case, they
cancel exactly. Under **commission** at a different second price they do not:
the shop is owed what it paid and owes a share of a new number, and the
difference goes unrecorded. Closing it properly means a settlement row rather
than an inference, which is `ConsignmentIncident`'s neighbourhood and belongs
with Phase D's claims work rather than with a bug sweep.

---

## 16. What we deliberately do not build

1. **A separate submitted allocation document.** ERPNext's bundle, and its bug
   list. Allocations belong to the movement — §3.2.
2. **A general custom-field engine.** Attributes are scoped to units, defined
   per asset type, and go no further. Anti-goal §8.2 stands.
3. **Serial genealogy / manufacturing traceability** (parent-child serials
   through assembly). No demand; our recipes cover kitchens and workshops. *Lot*
   genealogy is built — `parent_batch` covers repacking and splitting, which a
   pharmacy and a chemical trader both do — and it is cheap precisely because
   the lot is an identity rather than a per-warehouse balance (§4.7).
4. **Fixed-asset depreciation on units.** ERPNext links `Serial No → Asset` for
   its own fixed-asset module. Ours links to the *customer* asset registry,
   which is a different and more useful idea for this market.
5. **Global serial uniqueness.** §3.6. Note the deliberate asymmetry with lots,
   whose codes *are* unique per variant and permanently so (§4.7): a serial
   names an article that can leave and come back as a different article of
   stock, while a lot code names a factory run that is the same factory run
   forever.
6. **Serialized service or prepared products.** A haircut has no IMEI.
7. **Per-unit multi-currency pricing.** `list_price` is base currency, exactly
   like `ProductVariant.unit_price`. FX stays a product-level pricing concern.
8. **Anything on the checkout path for non-serialized shops.** §11.1, and it is
   the constraint at the top of this document.
9. **A general ledger, or accounts, for consignor liability.** The payable and
   the claim are derived from the rows that already exist, exactly as
   `apps/treasury` derives the money position and `Job.settlement_state` derives
   where a repair stands — §5.8. The stamped Arabic ledger stays where the
   benchmark plan put it, and nothing in this section waits for it.
10. **Automatic escheat of unclaimed payouts.** Money owed to a consignor who
    never returns stays owed, on a timer that only ever raises a reminder — §17.

---

## 17. Open decisions

1. **Does the prospect's export exist, and can we have it?** §12 is the
   difference between a feature and a migration, and it needs their data. Ask
   for it before Phase A starts, not after Phase B ships.
2. **Do they want per-unit photos?** Attachments make it nearly free and used-goods
   traders usually want a condition record. Confirm before Phase C; it changes
   the capture sheet's shape and the sync payload's size.
3. **Warranty: days from sale, or a date typed per unit?** Days-from-sale is
   simpler and covers phones. Cars and generators sometimes carry a
   manufacturer date that is not ours to compute. Recommendation: `warranty_days`
   on the product with a per-unit override field, decided in Phase C.
4. **Should `AssetType` move out of `apps.customers`?** It is about to serve both
   the stock side and the customer side, and its home no longer describes it.
   Recommendation: **leave it.** A cross-app FK is normal here; renaming a
   shipped model costs migrations, imports and reader memory, and buys tidiness.
   Revisit only if a third consumer appears.
5. **Batch codes now or later?** Phase E is written as separable. If a pharmacy
   is in the pipeline, it moves ahead of D. Nothing in A–C forecloses it.
   What is *not* deferrable is the identity/balance split and the fourth
   tracking mode — both land in Phase A whether or not a pharmacy signs, because
   both are cheap before there is lot data and expensive after (§15).
6. **Cost masking default.** Should `view_stockunit_cost` be off for cashiers by
   default? Recommendation yes — it is a used-goods norm, and it is easier to
   grant than to claw back.
7. **RESOLVED 2026-09-17 — three policies, defaulting to `owner_risk`.** The
   question was posed as a choice between two poles and the answer was that the
   interesting policy is the one between them. `shop_liable_except_fm` — the
   shop stands behind its own negligence and a burglary, but not a fire, a flood
   or unrest — is what most shops here *mean* whichever extreme their voucher
   prints, and it is now the middle value of a three-member enum ordered by
   ascending shop exposure (§5.8), with `force_majeure` added to the incident's
   responsibility so the policy can actually fire (§6.2.2).

   The **default is `owner_risk`**, because that is what Libyan consignment
   vouchers already say and a system should ship reading the paper the shop
   already prints rather than the paper we think it should print. A shop that
   wants to stand behind its custody says so at setup, and then the matrix in
   §6.2.2 does the rest. The same shops will often still pay under
   `owner_risk` — reputation being what it does in a market this size — and that
   is exactly what the incident record is for: a claim can be settled generously
   without pretending the agreement said something it did not.

   **One thread stays open, and it is the wording, not the model.** The three
   Arabic clauses are the contract, and *«المحل ضامن ما عدا الظروف القاهرة»* is
   a literal rendering rather than the phrase Libyan shops actually print. This
   is why §10 makes the clause an editable per-policy sentence instead of a
   label derived from the enum. Worth collecting the real wording from two or
   three shops' existing vouchers before Phase C ships.
8. **Unclaimed payouts: does the money ever become the shop's?** After a year,
   two, five, with the consignor unreachable. This is a legal question and not a
   product one, so the system's answer is deliberately *no, never automatically*
   — it ages, it reminds, it stays owed and visible. Revisit only with an
   answer from someone qualified to give one; until then, a figure the owner can
   see and act on beats a rule we invented.
9. **RESOLVED 2026-09-17 — Libyan pharmacy stock carries GS1 DataMatrix
   widely.** Confirmed from the field: many products on Libyan pharmacy shelves
   are DataMatrix-coded. The parser (§6.3) is therefore **core Phase B work, not
   conditional**, and it earns its place at receiving before it earns it at the
   till: one scan fills GTIN, lot and expiry, which is the tedious, error-prone
   part of pharmacy intake that today is typed by hand off a foil edge.

   One sub-question remains, and it is narrower than the original: **do those
   codes carry AI `21` (serial), or only `01`/`17`/`10`?** Serialisation is
   mandated by the market a pack was manufactured for — EU FMD and US DSCSA
   require it, and Gulf regimes such as Saudi's RSD and UAE's Tatmeen now do
   too, so stock arriving via those channels usually carries a serial, while
   packs made for markets with no track-and-trace mandate carry lot and expiry
   only. This decides the *mix*, not the model: `batch` mode plus the parser
   covers everything, and `serial_batch` adds per-pack verification on the
   subset that has it. Answerable by reading three real codes and looking for a
   `21` segment — the parser's own test fixtures should be those strings.
10. **Does the prospect actually run consignment today, and on what terms?**
   Fixed payout and commission are both built, but which one they use decides
   whether the §5.8 price floor is a hard wall they will hit daily or a guard
   that never fires. Worth one question in the same meeting as §17.1.

---

## 18. What Pointy already has, and how this must behave toward it

Everything above describes what gets built. This section is the other half: the
52 settings, the product flags and the two dozen subsystems that are **already
running in shops**, each of which this feature either has to respect, adapt, or
deliberately refuse. It was written by reading them, not by recalling them.

Most rows below are integrations — a sentence of behaviour, decided once so it
is not decided differently in three places. Six were defects rather than
integrations: this audit found them, and each is now **fixed in the section that
owns it** rather than living on as a warning at the end of a document. They are
listed here with where the rule went, because an audit whose findings only exist
in the audit is a list of things nobody will read at the moment they matter.

| Found | Fixed in |
|---|---|
| `tracks_expiry` and `tracking_mode` both exist, and nothing said how they relate — left alone, a shop's expiry tracking silently stops | **§4.2** (derived property + R1 migration), §18.4 (the argument), §15.1 (R3 drops the column) |
| `is_service` / `is_prepared` products could be given a `tracking_mode`, and the stock engine skips those products entirely — a serialized haircut that never allocates | **§4.2** (the refusal, symmetric), §13 (both ends, because the AI and importer are callers) |
| Archiving a product with live units had no defined behaviour, and `archived_at` already hides products from the catalog | **§13** (refused and names the units; same guard for `is_active` and for a lot with a balance) |
| `ScanBurstGuard` would eat identifier scans in the new capture sheets | **§8.1** (every scan surface declares `ScanWedgeTarget`, with the existing panes named as the pattern) |
| The price-checker kiosk is unauthenticated, so `view_stockunit_cost` protects nothing there | **§13** (a separate cost-free serializer, not a filtered view), §7, §8.2 |
| A consignment sale on آجل owes cash before it collects any | **§5.8** (confirmation naming the payout, flagged on the payables screen, payable unchanged) |

Two **free wins** the audit turned up are now planned work rather than
observations: the surveillance link from a unit's timeline to the footage of its
sale (§8.3, Phase D), and the companion camera as a DataMatrix scanner for shops
with only 1D lasers (§6.3, Phase B). A third loose end found while checking a
defect that turned out not to be one — which unit a pooled promotion discounts
when units carry their own prices — is resolved in §5.7.

### 18.1 Settings that change how this must behave

`ShopSettings` carries 52 fields (`backend/apps/core/models.py:71`). These are
the ones that touch tracked stock:

| Setting | What it does today | How tracked stock reacts |
|---|---|---|
| `allow_overselling` | lets stock go negative | **Overridden, never consulted, for serialized variants** — §3.5. A phantom handset is not a business decision. |
| `prevent_selling_at_loss` | blocks sales under cost | Reads `incoming_rate + refurb_cost` per unit (§5.6), and `expected_payout` for consignment (§5.8) — not the bin rate. |
| `inventory_valuation_method` | the shop's costing method | **Not consulted** for tracked variants; `UNIT_COST` / `BATCH_COST` are chosen by the product — §5.1. |
| `books_locked_through` | closes a period | Applies unchanged to re-stamps (§5.5), payouts and claim settlements (§5.8). |
| `warn_low_stock_before_sale` | prompts when a line exceeds stock | **Suppressed on serialized lines.** Quantity is locked to 1 and the unit either exists or it does not; the dialog can only ever be noise, once per handset. |
| `low_stock_threshold` | the low-stock signal | Works untouched, because the bins stay honest (§5.3). For batch variants the *useful* signal is near-expiry rather than low quantity — §9.12 is where that lives, and the two must not be conflated in one notification. |
| `stock_count_variance_min_units` / `_percent` | which counted lines need review | **Not applied to a serialized count.** §6.6 produces named lists, not a number: a missing IMEI is always worth surfacing, and a shop that raises `min_units` for its grocery lines must not thereby silence one missing phone. |
| `cashier_return_window_hours` | how long a cashier may take returns | Applies to returns. A **warranty claim is not a return** and is not bounded by it — §6.4, and the unit's `warranty_expires_on` is the window that governs there. |
| `require_customer_for_credit` | آجل needs a customer | Unchanged, and load-bearing for the row below. |
| `enforce_customer_credit_limits`, `default_customer_credit_limit` | آجل ceilings | Unchanged — a serialized sale is an ordinary sale to the receivable, and the existing ceilings bind exactly as they do today. **A consignment sale on آجل is the exception** and is handled in §5.8: the payout falls due at the sale while the money arrives later, so the till confirms with the payout named and the payables screen flags those units *مباعة آجل*. Nothing is refused; the second number is simply shown. |
| `pos_cash_purchase_limit` | caps a POS cash purchase | **Applies to counter purchase and trade-in** (§6.2) — a used car will exceed it, and it must take the same override path rather than a second, quieter cap. |
| `enable_cash_payments` / `_card_` / `_transfer_` | which tenders exist | Consignor payouts and claim settlements offer only the enabled ones (§5.8, §6.2.2). |
| `card_commission_percent` | the shop's card fee | **The fee comes out of the shop's commission, not the consignor's payout**, because the payout is computed from `sold_price`. Stated because it is a real counter argument, not because it is hard. |
| `auto_print_receipts`, `auto_print_min_line_count`, `auto_print_min_total` | the auto-print floor | A one-line handset sale clears the floor on total. **Consignment intake vouchers, payout receipts and claim settlements are exempt from the floor entirely**, like آجل and quotations — they are the signed record of someone else's property, not a slip for a loaf of bread (`auto-print-floor`). |
| `enable_repair_operations` | the workshop module | **Required for §5.6.** Refurb capitalisation has no source of cost without it, and the unit detail screen hides the refurb row when it is off. |
| `enable_surveillance`, `surveillance_pre_roll_seconds`, `surveillance_post_roll_seconds` | invoice-linked DVR footage | Free win, and worth taking: the unit detail screen links to the footage of the moment that unit was sold. High-value serialized goods are exactly the sale anyone ever wants to re-watch. |
| `enable_purchase_suggestions` | per-supplier next-product chips | Unchanged for batch. For serialized, suggests the *model*, never a unit. |
| `fx_enabled`, `fx_instrument`, `Product.pricing_currency` | multi-currency pricing | §16.7 bans per-unit currency, but `pricing_currency` exists on the product and this plan never said what happens. **Rule: `StockUnit.list_price` and `StockBatchBalance.incoming_rate` are always base currency**, exactly like `ProductVariant.unit_price`; a tracked product may carry a `pricing_currency` and the conversion happens where it already happens, above the unit. |
| `shop_type` | the vertical, from the wizard | Drives the presets of §10. |
| `require_opening_cash`, `month_end_*`, `fiscal_year_start_month`, `receipt_header/footer`, `require_card_payment_receipt`, `trusted_card_terminal_ids`, `allow_cashier_customer_access`, `enable_online_invoices`, `enable_job_tracking`, `kitchen_auto_complete`, `auto_print_kitchen_tickets`, `enable_production_operations` | — | No interaction. Listed so the next reader knows they were considered. |

### 18.2 Product and variant flags

| Flag | Rule |
|---|---|
| `is_service`, `is_prepared` (fixed §4.2) | **`tracking_mode` is refused on both**, at the serializer and in `clean()`. §16.6 says a haircut has no IMEI, but nothing enforces it, and `record_sale_stock_movements` already skips these products entirely (`sales/services.py:843`) — so a serialized service would accept a unit at the till and never allocate it. The refusal is symmetric: turning `is_service` on for a tracked product is refused too. |
| `archived_at`, `is_active` (fixed §13) | **Archiving a product with live units is refused and names them**, the same shape as the existing archive guards. A product hidden from the catalog whose forty handsets are still in a bin is a stock report nobody can explain (`product-archive`). Archiving is allowed once every unit is `sold`, `written_off` or `returned`. |
| `tracks_expiry` | Absorbed into `tracking_mode` as a derived property — §4.2, and §18.4 for why. |
| `unit`, `default_sale_unit`, `default_purchase_unit`, `ProductUnit` | **A serialized product is single-unit by definition** — a carton of ten phones is ten units, not one line of ten — so `tracking_mode = serial` refuses a product with `ProductUnit` conversions, and vice versa. **Batch is the opposite**: multi-unit is normal (a carton of 24, sold as singles) and every rate is per base unit, normalised by `unit_factor` at every read, per `uom-cost-normalization`. That memory records a whole class of phantom losses from getting this wrong once. |
| `modifier_groups` | Priced modifiers work unchanged on a tracked line: the unit resolves the *base* price (§5.7) and `effective_unit_price` adds the modifiers on top, server-side. One line, one unit, its own modifiers. |
| `ProductVariant.gtin` | New, and the key the GS1 DataMatrix's AI `01` resolves against (§6.3). Uniqueness is per shop and advisory — a wrong GTIN should be correctable, not a wall. |
| `popularity`, `variant_options`, `option_signature` | No interaction. The catalog relevance filter and most-bought sort read the variant, which is unchanged. |

### 18.3 Subsystems on the path

| Subsystem | How this must behave |
|---|---|
| `ScanBurstGuard` / `ScanWedgeTarget` (fixed §8.1) | The guard rolls back digits typed at scanner speed so a wedge cannot become a line quantity (`frontend/lib/src/shared/barcode/scan_burst_guard.dart`). **The unit capture sheet, the unit picker and the batch capture sheet are scan targets and must declare themselves as such**, or every identifier scanned into them is swallowed as a burst. `pos_cart_pane.dart` and `purchase_draft_pane.dart` already show the pattern. |
| Price checker, kiosk mode (fixed §13) | Kiosk lookup is **unauthenticated on the LAN** (`price-checker-kiosk-mode`), so there is no user for `view_stockunit_cost` to mask. The kiosk endpoint must not return `incoming_rate`, `refurb_cost`, consignment terms or supplier at all — refused by construction, not by permission — while a scanned identifier may return that unit's price and, for batch, its expiry. |
| Discounts: pooled promotions | Verified against `discounts/services.py:582`: multi-buy, tiered and buy-X-get-Y pool whole units **across every matching line**, so three separate one-unit handset lines do form a pool of three. What is undefined is *which* unit an allocation lands on when units have different `list_price`, and the loss guard must be re-evaluated per unit after allocation — a "buy 2 get 1" that gives away the 1,400 handset is a different transaction from one that gives away the 1,200. |
| Discounts: preview cache | Key must include unit ids — already §5.7, restated here because `discount-engine-perf` records that the cache is fail-open and a wrong key is silent. |
| Catalog version / ETag / price cache | A unit reprice, a lot quarantine and an expiry change all change what a till should show. **Each bumps the catalog version counter**, or the price-checker cache and the 304s serve yesterday's answer (`catalog-version-etag-price-cache`). |
| State versions & revalidation | Tracked stock is a new domain and needs its own counter, bumped `on_commit`, so open screens refresh (`state-version-revalidation`). The consignment payables screen is the one that will be watched. |
| Stock count | `stock_count_needs_review` (`inventory/services.py:407`) is a quantity heuristic — see §18.1. The serialized count path produces lists and bypasses it. |
| Register session & Z-Report | Consignor payouts and claim settlements are drawer pay-outs and **must appear on the Z-Report** like every other one (`register-session-zreport`), or a session reconciles short by the payout. |
| Purchase cost guard | `purchase-cost-guard` warns on purchasing and hard-blocks POS cash purchases. It applies per unit on a per-unit cost split, and the counter-purchase flow of §6.2 inherits the hard block — which is right: a typo when buying a phone over the counter is cash out of the drawer. |
| Fraud engine | `fraud/metrics.py` scores cashiers on void, return, discount and pay-out rates. Two new signals fall out of this work almost free and are worth adding once the data exists: **units written off per cashier**, and **unit reprice frequency**. Not in scope, noted so it is not re-derived. |
| Companion camera | The phone-as-till-camera (`apps/companion`) is a camera on the LAN with a decode ladder already tuned for real photographs (`companion-camera-decode-lessons`). It is the obvious **DataMatrix scanner for receiving** on a shop with no 2D scanner — a real Phase B option rather than a new build. |
| Scales | `ScalePLU` pushes PLUs to weighing scales. A serialized product has no PLU and must never be pushed; a batch product sold by weight can be, and its lot is chosen by FEFO at the till exactly as a scanned one is. |
| AI tools | `create_sale` (`ai/tools.py:2920`) must refuse a serialized product rather than sell a phantom one, and the generic `create_resource` / `update_resource` must not be able to write a `StockUnit`, a balance or an allocation — those are service-owned tables, and §13's "one writer" rule is only true if the AI is not a second one. |
| Learning module | 98 Arabic guides and 16 practice lessons run against a sandbox shop, and **CI fails when a lesson rots** (`learning-module`). Changing the POS scan flow and the receiving sheet will rot lessons; new lessons for unit capture and lot receiving are part of the phase that ships them, not a follow-up. |
| Backup / COPY export | The new tables join the Postgres `COPY` export and its verification (`backup-verification-and-copy-export`). An archive that restores a shop without its units is not a backup. |
| Notifications | Near-expiry alerts are a new notification source, and `perf-audit-2026-06` records that notifications already recompute on every GET. The expiry watchlist is a scheduled sweep writing rows, never a computation on the notification read path. |
| Analytics / telemetry | New screens are tracked through `TrackedScreen` and the burst coalescer, not by hand (`screen-attribution-tracker`, `telemetry-burst-coalescing`). A scan loop that emits an event per scan is exactly the pattern that produced a 5.1M-call ingest storm once. |
| Documents lifecycle | `ConsignmentAgreement`, `ConsignmentIncident` and the payout register in `apps.documents` with the freeze/cancel/reversal contract, and their queries use `with_lifecycle_relations()` — `lifecycle-query-scaling` records that the N+1 stays hidden until rows are actually cancelled. |
| Treasury | §5.8. The obligations overlay, and one new component code. |
| Invoice intake | Supplier invoice photos already extract lines; IMEIs and lot codes extend the same pipeline (`invoice-intake-pipeline`). |

### 18.4 `tracks_expiry` and `tracking_mode` cannot both be the answer

`Product.tracks_expiry` exists today and is the gate on
`consume_expiring_stock_batches`: no flag, no cohort consumption. This plan adds
`tracking_mode`, and §4.2 mentions the old flag only in passing — *"used when
`tracking_mode` is batch or `serial_batch`, or when `tracks_expiry` is True"* —
which leaves two flags governing one behaviour and four combinations, two of
them meaningless.

That is not a tidiness problem. `consume_expiring_stock_batches` is rewritten in
Phase A against warehouse-aware balances (§15.1), and its first line is the
`tracks_expiry` check. A product whose owner set `tracks_expiry` years ago and
which nobody migrates to `tracking_mode = batch` either keeps the old code path
alive forever or **silently stops having its expiry tracked** on the release
that removes it.

The resolution, and it belongs in the R1 migration rather than a later decision:

- **Every product with `tracks_expiry = True` becomes `tracking_mode = batch`**,
  and its existing cohorts become identities with `code_is_generated = True`
  plus one balance each (§4.7). Nothing about the shop's behaviour changes on
  that release: the same goods are consumed earliest-expiry-first, they just
  now have a row that can carry a lot number when someone types one.
- **`tracks_expiry` becomes derived** — `tracking_mode in (batch, serial_batch)`
  — kept as a property for every existing reader, and the column drops in the
  contract release (R3) alongside the batch columns, under the same fleet gate.
- **The product form stops showing it.** One control, `tracking_mode`, decides
  this; a second checkbox that means a subset of the first is how a shop ends up
  with an expiry-tracked product that has no lots.

The test is the one named after the failure: *a product that tracked expiry
before the upgrade still consumes earliest-expiry-first after it*, run by the
rehearsal harness against a populated shop, not by a unit test against a fixture
created by the new code.
