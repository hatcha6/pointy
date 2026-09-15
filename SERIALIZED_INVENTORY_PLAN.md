# Serialized Inventory (IMEI / Serial / VIN) — Architecture Plan

**Date:** 2026-09-10
**Status:** Proposed. Nothing built.
**Roadmap slot:** Gap #13 of `ERPNEXT_BENCHMARK_PLAN.md` ("Serial-number tracking",
sized M, ranked *Later*). This plan promotes it, and argues below why the ranking
was wrong: it is not a repair-shop nicety, it is the **only** inventory model
under which a used-goods trader's numbers can be correct at all.
**Mirrors inspected:** ERPNext `develop` (doctype JSON read, not recalled), Odoo's
`stock.lot`, Shopify's absence of one.

The whole plan is written against one constraint, and it is the one to re-read
whenever a decision here looks arbitrary:

> **A shop that sells Coca-Cola must not be able to tell that this shipped.**
> Not one extra field on the product form, not one extra tap at the till, not
> one extra query on checkout. Serialization is an *opt-in shape* for the
> minority of products that have identity, living inside the same catalog,
> the same ledger, the same receipt and the same reports as everything else.

And against one thesis:

> **A serial number is not a label on a sale. It is a costed, located, dated
> object with a life.** Everything correct about this feature follows from
> treating it as one; every bug ERPNext has shipped in this area follows from
> the times they didn't.

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

| Trade | Identifier | Unit-specific facts |
|---|---|---|
| Used phones | IMEI | battery health, grade, colour, box/no box |
| Cars | VIN / chassis / plate | mileage, year, colour, keys |
| Generators, inverters | serial | hours run, warranty start |
| Jewellery | certificate no. | weight, purity |
| Laptops, TVs, appliances | serial | condition, warranty |
| Spare parts, tyres | DOT / batch | manufacture date |
| Medicine, food | lot | expiry (we already do this, anonymously) |

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
  a batch in the accounting sense, with no code and no identity.
- A shop-editable registry of *kinds of identified thing*: `customers.AssetType`
  with `tracks_imei / tracks_vin / tracks_plate_number / tracks_engine_number /
  tracks_odometer / custom_identifier_label` (`backend/apps/customers/models.py:211`).
- Attachments on any owner, structured identity-conflict errors
  (`catalog/identity.py`), document lifecycle with freeze/cancel/blockers,
  a scan-burst guard, label printing, an oracle harness.

**Missing:** one table, and everything that has to know about it.

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
    QUANTITY = "quantity", "Quantity only"     # default; today's behaviour
    SERIAL   = "serial",   "Individually tracked"
    BATCH    = "batch",    "Batch / lot"       # Phase D

tracking_mode = models.CharField(max_length=16, default=TrackingMode.QUANTITY, db_index=True)

# What kind of thing this is, for identifier labels and unit attributes.
# Reuses the shop-editable registry the workshop side already maintains.
asset_type = models.ForeignKey("customers.AssetType", null=True, blank=True,
                               on_delete=models.PROTECT, related_name="tracked_products")

# Warranty granted on sale, in days. 0 = none. Stamped onto the unit at sale.
warranty_days = models.PositiveIntegerField(default=0)
```

On `Product`, next to `tracks_expiry`, `is_service` and `is_prepared`
(`backend/apps/catalog/models.py:110`) — those are already the flags that say
"this thing behaves differently in the stock engine", and this is one more.

**Changing the mode is guarded, not free.** `quantity → serial` is allowed only
when on-hand is zero, or through an explicit *opening identification* run that
turns N anonymous units into N identified ones (§6.10). `serial → quantity` is
refused while any unit is in stock. The same shape as the valuation-method
guard in `ShopSettingsSerializer`, and for the same reason: it re-labels history.

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
    secondary_code  = CharField(max_length=120, blank=True)   # dual-SIM IMEI2, engine no.
    supplier_code   = CharField(max_length=120, blank=True)   # what the supplier called it

    status = CharField(max_length=16, choices=Status.choices, default=Status.IN_STOCK, db_index=True)

    # --- money (all base currency, all per base unit) --------------------
    incoming_rate = DecimalField(18, 6, default=0)   # what this unit cost, landed
    refurb_cost   = DecimalField(18, 6, default=0)   # capitalised from repair jobs
    list_price    = DecimalField(10, 2, null=True, blank=True)   # this unit's asking price
    sold_price    = DecimalField(10, 2, null=True, blank=True)   # what it actually fetched

    # --- provenance ------------------------------------------------------
    purchase_line        = FK("purchasing.PurchaseLine", SET_NULL, null=True, blank=True)
    source_receipt_line  = FK("purchasing.PurchaseReceiptLine", SET_NULL, null=True, blank=True)
    supplier             = FK("purchasing.Supplier", SET_NULL, null=True, blank=True)
    acquired_at          = DateTimeField(null=True, blank=True)
    in_stock_since       = DateTimeField(null=True, blank=True)   # resets on return; drives aging

    # --- disposal --------------------------------------------------------
    sold_order_line = FK("sales.OrderLine", SET_NULL, null=True, blank=True, related_name="stock_units")
    sold_at         = DateTimeField(null=True, blank=True)
    customer        = FK("customers.Customer", SET_NULL, null=True, blank=True)
    asset           = FK("customers.Asset", SET_NULL, null=True, blank=True)   # §4.8
    warranty_expires_on = DateField(null=True, blank=True)

    # --- the rest --------------------------------------------------------
    batch      = FK(StockBatch, SET_NULL, null=True, blank=True)   # a serial may sit in a batch
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
```

Constraints:

```python
UniqueConstraint(fields=["code_normalized"],
                 condition=Q(status__in=["expected", "in_stock", "reserved", "in_transit"]),
                 name="stock_unit_live_code_unique")
Index(fields=["code_normalized"])                     # history lookups
Index(fields=["variant", "status", "in_stock_since"]) # the picker's query
Index(fields=["status", "warehouse", "variant"])      # bin reconciliation
GinIndex(fields=["attributes"])                       # attribute filters
```

The partial unique index is the whole design in one line: **one live unit per
identifier, unlimited history per identifier.** A phone sold and traded back in
is two rows with the same `code_normalized`, at most one of them live.

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

Seeded definitions ship with the seeded asset types, so a phone shop that picks
`phone_repair` in the setup wizard gets battery health, grade (A/B/C/D), storage,
box-and-accessories and network-lock without configuring anything — and can
delete or add. A car workshop gets mileage, year, colour, keys, service history.

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

### 4.7 What happens to `StockBatch`

`StockBatch` today is an anonymous expiry cohort keyed to a receipt line, with no
code, consumed FIFO-by-expiry by `consume_expiring_stock_batches`. It is a real
thing and it works; it is simply not *identified*.

Phase D promotes it in place rather than replacing it:

```python
code              = CharField(max_length=120, blank=True)   # supplier's lot number
code_normalized   = CharField(max_length=120, db_index=True)
manufactured_on   = DateField(null=True, blank=True)
supplier          = FK(Supplier, SET_NULL, null=True)
incoming_rate     = DecimalField(18, 6, default=0)          # batch-wise valuation
parent_batch      = FK("self", SET_NULL, null=True)         # splits
attributes        = JSONField(default=dict, blank=True)
# expiry_date becomes nullable: a lot without an expiry is still a lot
```

and `source_receipt_line` loosens from `OneToOneField` to `ForeignKey`, because
one delivery can arrive as three lots.

**Why not unify batch and unit into one table now?** Odoo does, and it is
defensible. Two reasons not to: the serialized side needs per-unit price,
photos, warranty and a customer, none of which a lot ever has, so a unified table
is mostly-null for the majority row type; and `StockBatch` is on the checkout
path today (`consume_expiring_stock_batches` runs inside
`record_sale_stock_movements`). Destabilising that path twice — once for serials,
once for a table merge — buys elegance and risks the till. Two tables, one
allocation row type, one set of hooks. ERPNext's split, without their bundle.

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
answer *"what did the queue give up?"*. A serialized issue does not consult a
queue: the cost of the phone that left is the cost of **that phone**.

```python
class ValuationMethod(...):
    MOVING_AVERAGE, FIFO, LIFO,   # existing
    UNIT_COST = "unit_cost", "Per-unit (serialized)"
```

`current_method()` gains one branch: a serialized variant is `UNIT_COST`
regardless of `ShopSettings.inventory_valuation_method`. The shop's method still
governs everything else it owns. There is no setting, and no way to ask for a
blended cost on an item where a true cost exists — §3.4.

### 5.2 What each posting does

- **Receipt.** `unit.incoming_rate = receipt line's effective_unit_cost / unit_factor`
  — landed-cost inclusive, normalised to base units. That division is not
  optional and not obvious: pack costs are stored per pack, and dividing by
  `unit_factor` at every base-unit read is the invariant that
  `uom-cost-normalization` exists to enforce. Ledger entry: `quantity_change=+1`,
  `valuation_rate = incoming_rate`, one `StockAllocation(direction=in)`.
- **Issue.** `valuation_rate = unit.incoming_rate + unit.refurb_cost`,
  `value_change = -(that)`. One allocation per unit. `OrderLine.unit_cost` is
  stamped from it by the existing `_stamp_ledger_cost_on_lines`
  (`backend/apps/sales/services.py:952`) — which already exists to make gross
  profit true, and which now becomes *exactly* true rather than approximately.
- **Return from customer.** The unit returns at the rate it left at. Not the
  current bin rate — a return valued at today's blended rate manufactures profit
  or loss out of nothing, which is precisely the class of silent wrongness we
  sell against.
- **Write-off / damage.** Issue at the unit's own rate, `voucher_type=adjustment`.

### 5.3 The bin stays, and stays consistent

`StockValuationBin` is not bypassed. For a serialized variant it becomes a
**derived cache with a checkable definition**:

```
bin.quantity      == COUNT(units WHERE status IN (in_stock, reserved) AND warehouse = w)
bin.stock_value   == SUM(incoming_rate + refurb_cost) over those units
bin.valuation_rate == stock_value / quantity            (0 when quantity is 0)
bin.method        == "unit_cost"
bin.state         == []      # there is no queue; the units are the state
```

Keeping the bin honest is what lets **every existing report keep working
untouched**: stock value, margin, the loss guard, the accountant reports, the
dashboard. Not one of them learns the word "serial".

### 5.4 Invariants, stated so they can be tested

For every serialized variant and every warehouse:

1. `StockItem.quantity_on_hand == COUNT(units in_stock ∪ reserved)`
2. `StockItem.quantity_committed == COUNT(units reserved)`
3. `StockItem.quantity_expected == COUNT(units expected)`
4. `bin.stock_value == Σ(incoming_rate + refurb_cost)` over in-stock units
5. Every ledger entry on a serialized variant has allocations whose
   `Σ quantity == |quantity_change|`
6. No unit is allocated `out` twice without an intervening `in`
7. `code_normalized` is unique among live units
8. A unit's status agrees with the sign of its last allocation

These go into `apps/inventory/test_inventory_integrity.py` next to the existing
ones, and into the oracle (§14.3). Invariant 4 is the one that catches a wrong
refurb capitalisation; invariant 5 is the one that catches an ERPNext #42997.

### 5.5 Landed cost lands after the fact

`PurchaseOrderLandedCostEntry` allocates freight and clearing across lines
*after* receipt. For serialized lines this must re-stamp each unit's
`incoming_rate` and repost — otherwise the phone's cost is the invoice price and
the freight vanishes into a bin the units no longer feed.

Rule: **re-stamp units of any receipt line whose `allocated_landed_cost`
changed, then `repost_variant`.** Units already sold are re-stamped too and the
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

### 5.7 Per-unit price, and the engines downstream

`StockUnit.list_price` is nullable and is the unit's own asking price, in the
shop's base currency — the same invariant `ProductVariant.unit_price` holds, so
FX, discounts, loss guard and reports need no change. Resolution order at the
till:

```
line price = unit.list_price  ?? variant unit price (incl. unit/carton pricing)
```

The discount engine sees the resolved price and needs no knowledge of units. The
one place that does need care is the **discount preview cache** — its key must
include the unit id when a serialized line is present, or two different handsets
of the same variant would share a cached preview (`discount-engine-perf`).

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

### 6.2 Buying over the counter, and trade-ins

This is *the* used-phone-shop workflow and it deserves to be first-class, not a
purchase order with one line.

- **Counter purchase.** The POS cash-purchase flow (`pos-cash-purchases`) already
  creates a received-and-paid PO with a linked register pay-out. Serialized, it
  becomes: pick or create the model → scan the IMEI → grade it → enter what we
  paid → the drawer opens. One sheet, one unit, one pay-out, correct ledger.
- **Trade-in.** Customer buys a phone and gives one in part-payment. That is a
  purchase and a sale in one transaction. `OrderExchange`
  (`backend/apps/sales/models.py:1089`) is already the atomic
  return-and-replace primitive; the trade-in is its sibling: create the incoming
  unit at the agreed value, apply that value as a tender line, sell the outgoing
  unit, one document, one register entry. Phase C.
- **Ownership follows.** A traded-in handset's `Asset` gets its ownership row
  closed (the customer no longer owns it) and reopened when we sell it on.

### 6.3 POS

**The scan is the flow.** `resolveBarcode` gains a fourth resolution after
variant barcode, unit (carton) barcode and scale barcode: a live `StockUnit`
`code_normalized` match returns `(variant, unit)` and the line is added with
quantity 1, the unit's own price, and the identifier as the line subtitle. One
endpoint call, one indexed lookup, no dialog.

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
GET    /api/purchasing/receipts/missing-identifiers/ the worklist

GET    /api/catalog/asset-types/{id}/unit-attributes/
CRUD   /api/inventory/unit-attribute-definitions/

# extended, not new:
POST   /api/sales/checkout/          line gains  stock_unit  (id) — required when serialized
GET    /api/catalog/resolve-barcode/ resolution gains  {"kind": "stock_unit", "unit": {...}}
GET    /api/price-checker/lookup/    a scanned identifier returns that unit's own price
POST   /api/inventory/stock-counts/{id}/scan-unit/
POST   /api/inventory/transfers/{id}/units/
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
below is gated on `ShopSettings.enable_serialized_inventory` **and** on the
product's own tracking mode, so a grocery never renders one pixel of it.

### 8.1 New surfaces

| Where | What |
|---|---|
| `features/inventory/views/stock_units_screen.dart` | The units list: search by identifier, filter chips (status, warehouse, attribute, age bucket), multi-select bulk reprice / transfer / write-off. Follows `bulk-operations`. |
| `features/inventory/views/stock_unit_detail_screen.dart` | `PointyDetailHero` + `PointySummaryList` + attributes + photos + the life timeline. Actions: reprice, edit attributes, write off, print label, open invoice, open asset. |
| `features/inventory/views/unit_capture_sheet.dart` | The scan-and-fill loop, shared by receiving, counter purchase, opening identification and stock count. **One widget, four callers** — this is the piece to build well. |
| `features/pos/views/pos_unit_picker_sheet.dart` | In-stock units for a variant: identifier, picker attributes, price, days in stock. |
| `features/settings/views/unit_attributes_screen.dart` | Attribute definitions per asset type. |

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
- `features/returns_exchange` — identifier shown, unit-aware refusals.
- `features/stock_count` — serialized count mode and the two-list variance view.
- `features/price_checker` — identifier lookup returns the unit's own price
  (kiosk mode included; permissioned per `price-checker-settings`).
- `features/operations` — job can target a stock unit; refurb cost shown on the
  unit.
- `features/dashboard` — a units card: in stock, value, aging, missing
  identifiers. Masonry rules per `dashboard-masonry-layout` (Row + stretch
  throws; use start).
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

All CSV-exportable through the existing streaming export path
(`analytics-export-streaming`), all subject to the period lock.

---

## 10. Permissions, settings, presets

**Settings** — `ShopSettings.enable_serialized_inventory` (default **False**),
`serialized_capture_later_allowed` (default False),
`serialized_require_customer_for_asset` (default True). Presets: `phone_repair`
and `car_workshop` turn serialization on; a new `electronics` type is worth
adding. Setup wizard gains one question, asked only for those types:
*"هل تتابع أجهزتك برقم تسلسلي / IMEI؟"*

**Permissions**, added to `apps/core/permission_catalog.py` under the existing
`inventory` group so the per-user editor picks them up automatically:

```
inventory.view_stockunit          عرض الأجهزة المسلسلة
inventory.add_stockunit           تسجيل أجهزة جديدة (receiving, counter purchase)
inventory.change_stockunit        تعديل بيانات الجهاز (attributes, notes)
inventory.reprice_stockunit       تعديل سعر الجهاز
inventory.write_off_stockunit     شطب جهاز (فقد / تلف)
inventory.view_stockunit_cost     عرض تكلفة الجهاز
```

Role defaults: cashier gets view + sell (no cost, no reprice); inventory clerk
gets view/add/change; purchasing agent gets add at receipt; manager gets all.
`view_stockunit_cost` is the first field-level cost mask in the codebase — a
small, contained instance of benchmark-plan Phase 6, and a real need: a used-goods
shop does not show the counter staff what it paid the walk-in seller.

---

## 11. The performance budget

Non-negotiable, per anti-goal §8.6 and the existing query-count guards.

1. **A cart with no serialized line pays zero extra queries.** Every hook is
   behind `variant.product.tracking_mode != quantity`, resolved from the bulk
   preload the checkout already does (`preload_line_variants`). Add
   `tracking_mode` to that select so it costs nothing.
2. **A cart with serialized lines pays one extra statement**: the batched
   `SELECT ... FOR UPDATE` over its unit ids, alongside the existing
   `lock_stock_items`. Not one per line.
3. **Allocations are bulk-created**, one statement per checkout, mirroring
   `create_stock_movements`.
4. **Identifier resolution is one indexed lookup** on `code_normalized`.
5. **The picker is paginated and warehouse-scoped**, ordered by
   `in_stock_since`, served by the composite index in §4.4. A shop with 3,000
   units in one model still opens it in constant time.
6. **The units list is keyset-paginated**, not offset — the lesson of
   `purchases-screen-perf`.
7. New tests in `test_checkout_query_scaling.py` assert (1) and (2) as numbers,
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

- **Database.** Partial unique on live `code_normalized`; check that an
  allocation names a unit or a batch; check that a unit allocation has quantity
  1; `PROTECT` on unit from allocations (history is never deleted by deleting a
  unit).
- **`may_oversell()`** gains the serialized rule ahead of every other input, so
  no path can sell a phantom handset — §3.5.
- **`StockUnit.save`** normalises the code and refuses a status transition that
  is not in the allowed set (a small explicit transition table, like
  `documents/policy.py`'s).
- **A guard test file** — the shape `lifecycle-query-scaling` established — that
  fails when a new call site writes a `StockMovement` on a serialized variant
  without allocations. This is the ERPNext #42997 tripwire, and it is the single
  most valuable test in the plan because the failure it prevents is silent.
- **Money-definitions guard.** `unit cost`, `refurb cost`, `landed unit cost`
  and `unit list price` each get exactly one definition, registered in the
  existing static guard (`money-definitions-guard`).

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

### 14.3 The oracle

`apps/sales/business_simulation.py` learns serialized products: the independent
oracle tracks each unit's identity, cost, location and status, and proves after
every run that all eight §5.4 invariants hold. This is the harness that proved
the valuation engine (`oracle-correctness-harness`); a valuation *method* that
does not go through it is a method nobody has checked.

### 14.4 Scaling and upgrade

- Query-count guards per §11.
- `test_list_query_scaling` for the units list and the picker.
- The upgrade-rehearsal harness (`upgrade-rehearsal-harness`) runs a populated
  shop across the migration and proves no money moved: stock value, COGS on
  every past sale, and every bin identical before and after.
- Run on Postgres (`make backend-test-pg`); the partial unique index, the GIN
  index and the scaling guards all skip on sqlite and the run still reports
  success (AGENTS.md).

---

## 15. Phasing

Each phase ships behind the flag, with the oracle extended, and is independently
useful. No phase leaves the tree in a state where a serialized variant exists
without a correct ledger.

**Phase A — the object and its ledger (≈1.5 weeks).**
`tracking_mode`, `StockUnit`, `StockAllocation`, `UNIT_COST` valuation, bin
consistency, the eight invariants, receipt capture (backend), permissions,
settings, admin. No client. Ends with the oracle green on serialized runs.

**Phase B — the shop can operate it (≈2 weeks).**
Units list + detail + history, receiving capture sheet, POS scan resolution,
picker, checkout unit binding and locking, receipt/invoice identifier printing,
labels. **This is the phase that closes the phone-shop deal.**

**Phase C — the used-goods trade (≈1.5 weeks).**
Per-unit pricing everywhere, per-unit cost split, counter purchase and trade-in,
attribute definitions and the attribute UI, aging and per-unit margin reports,
refurb capitalisation, returns and warranty lookup.

**Phase D — the rest of the estate (≈1.5 weeks).**
Transfers, serialized stock count, write-off flow and shrinkage report,
opening identification, price-checker lookup, AI tools and genui card,
dashboard card, missing-identifier worklist.

**Phase E — batches grow up (≈1 week, optional and separable).**
`StockBatch` gains code, supplier lot, manufacture date, batch-wise valuation
and splits; expiry keeps working exactly as it does now; scan-a-lot at receipt
and at sale. Pharmacy and grocery become the second market for this engine.

**Phase F — migration (≈1 week, runs in parallel with C).**
The collapse tool of §12, against the prospect's real export.

Roughly seven to eight weeks of focused work for A–D, which is what actually
matters; E and F are separable and demand-driven.

---

## 16. What we deliberately do not build

1. **A separate submitted allocation document.** ERPNext's bundle, and its bug
   list. Allocations belong to the movement — §3.2.
2. **A general custom-field engine.** Attributes are scoped to units, defined
   per asset type, and go no further. Anti-goal §8.2 stands.
3. **Serial genealogy / manufacturing traceability** (parent-child serials
   through assembly). No demand; our recipes cover kitchens and workshops.
4. **Fixed-asset depreciation on units.** ERPNext links `Serial No → Asset` for
   its own fixed-asset module. Ours links to the *customer* asset registry,
   which is a different and more useful idea for this market.
5. **Global serial uniqueness.** §3.6.
6. **Serialized service or prepared products.** A haircut has no IMEI.
7. **Per-unit multi-currency pricing.** `list_price` is base currency, exactly
   like `ProductVariant.unit_price`. FX stays a product-level pricing concern.
8. **Anything on the checkout path for non-serialized shops.** §11.1, and it is
   the constraint at the top of this document.

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
6. **Cost masking default.** Should `view_stockunit_cost` be off for cashiers by
   default? Recommendation yes — it is a used-goods norm, and it is easier to
   grant than to claw back.
