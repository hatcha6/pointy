# Warehouses & Stock Locations — Architecture Plan

Phase 2 of `ERPNEXT_BENCHMARK_PLAN.md`, and the last gap that plan still marks
**Now**. Written 2026-09-06, after §10.6 settled branch topology on cloud —
which is what makes this phase a schema problem again rather than a distributed
one.

The whole of this plan is written against one constraint, and it is the one to
re-read whenever a decision here looks arbitrary:

> **A shop with one location must not be able to tell that this shipped.**
> Not one extra screen, not one extra field on a form, not one extra query on
> checkout. Most Libyan shops are a single showroom and always will be. The
> second warehouse is an *upsell*, and an upsell that taxes the customers who
> decline it is a bad upsell.

---

## 1. The problem, stated precisely

`StockItem.variant` is a `OneToOneField`. There is exactly one stock bucket per
variant, globally. A shop with a showroom and a store room out the back has no
way to say where anything is, and no way to count the two separately.

Half of the fix is already paid for. `StockValuationBin` has carried a
`warehouse` foreign key since it was created on 2026-08-26, and every
`StockLedgerEntry` has carried one from its first migration — deliberately, so
this phase would add rows and screens rather than re-migrate the history of
every shop's stock. So **value is already warehouse-aware; quantity is not.**

That asymmetry is the actual scope of this plan: bring the quantity side up to
where the value side already is, then build the document that moves stock
between the two.

It is also why this is urgent rather than merely ranked. The unpaid half grows
with trading — every day adds `StockItem` rows and movement history that a later
migration has to touch — while nothing else on the roadmap has a clock like it.

---

## 2. What ERPNext actually does

Read before designing, so that the divergences below are choices.

**`Warehouse`** is a tree. Nested set (`lft`/`rgt`), `is_group` marking interior
nodes, `parent_warehouse` on every leaf. Stock may only be posted to leaves.
Conversion between group and leaf is guarded both ways: a warehouse with
children cannot become a ledger, and one with transactions cannot become a
group. Deletion is blocked by quantity in any bin, by any stock ledger entry,
and by any child warehouse. On deletion it unlinks itself from any Item that
named it as a default.

**`Bin`** is the mutable per-(item, warehouse) cache over the immutable Stock
Ledger Entry. Its fields: `actual_qty`, `ordered_qty`, `reserved_qty`,
`indented_qty`, `planned_qty`, `reserved_qty_for_production`,
`reserved_qty_for_sub_contract`, `reserved_qty_for_production_plan`, and
`projected_qty` derived from all eight. Plus `valuation_rate` and `stock_value`.

The one genuinely excellent idea in it is in `update_qty_from_sle`, which
**recomputes every quantity from the ledger and the open documents rather than
accepting a caller-supplied delta.** A cache that recomputes cannot drift on a
missed callback. Steal this.

**`Stock Entry`** is one doctype with a `purpose` discriminator — Material
Receipt, Material Issue, Material Transfer, Material Transfer for Manufacture,
Manufacture, Repack, Send to Subcontractor. A transfer names `s_warehouse` and
`t_warehouse` per row. Transit is modelled with `add_to_transit`, which parks
stock in an interim warehouse and tracks a `transfer_percentage` until the
receiving end confirms.

---

## 3. Where ERPNext fails, and what we do instead

Every item here is traced to their own issue tracker or their own source, not to
an impression of the product.

### 3.1 The warehouse tree earns a bug class and buys us nothing

Group-versus-leaf is the source of a standing category of ERPNext confusion:
posting to a group warehouse, converting a node that has transactions,
conversion that half-succeeds. Four of the thirteen tests in their
`test_warehouse.py` exist only to hold the tree together
(`test_parent_warehouse`, `test_warehouse_hierarchy`, `test_get_children`,
`test_group_non_group_conversion`).

A tree is the right answer for a multinational with plants, regions and bin
locations inside racks. It is the wrong answer for a shop with a showroom, a
store room and possibly a van.

**We ship flat warehouses.** No `is_group`, no `parent_warehouse`, no nested
set. If a customer ever genuinely needs a hierarchy, that is a schema addition
with a clean migration — and it will have been paid for by a customer rather
than guessed at.

### 3.2 Negative stock is a per-company flag, and it leaks

Their issue #12651 is a standing feature request for *"negative stock for one
warehouse only"*, closed by nobody, because the flag is global. Meanwhile
#45414 reports sales invoices submitting with negative inventory **while the
setting is off**, because an item-level flag interacts with the global one and
one of the two paths does not check.

That is the shape of the bug: **two flags that must agree, and more than one
place that enforces them.** We already have the doctrine for this from
`apps/documents/guards.py` — enforce at every place a write can actually happen,
provide exactly one escape hatch, and enumerate its callers in a test.

Our `ShopSettings.allow_overselling` is today a single global boolean with a
single enforcement point, which is already better. Warehouses make it a real
question: a shop may well want the showroom to refuse a sale it cannot fulfil
while the store room is allowed to go negative during a count. **The setting
becomes per-warehouse with the shop default as its fallback**, resolved by one
function, in the shape `Customer.credit_limit_policy` already uses
(`SHOP_DEFAULT` / explicit) — a shape this codebase has shipped once and can
therefore reason about.

### 3.3 Negative stock plus perpetual valuation corrupts COGS

Their own users put it plainly: a sale from negative stock has no valuation rate
to cost against, so FIFO with perpetual inventory and negative stock "makes very
little sense." We have valuation and we have no GL to absorb the error, so a
sale out of an empty warehouse would land a cost of zero and overstate gross
profit — silently, which is the failure mode this product exists to prevent.

Our loss-sale guard (`order_loss_lines` / `validate_order_loss_sales_allowed`)
already refuses a line sold below cost. It must learn the warehouse dimension at
the same time as everything else, or it will assess a line against a blended
global cost that no longer exists.

### 3.4 `Bin` has no locking

Their `update_qty_from_sle` carries a comment acknowledging that *"actual qty is
not up to date in case of backdated transactions or when cancellations are the
most recent SLE"*, and the remedy is reposting after the fact rather than
locking during. That is a defensible choice for a batch-oriented ERP and an
indefensible one for a till.

We already lock. `lock_stock_items()` takes a whole document's rows in one
`SELECT ... FOR UPDATE` ordered by `variant_id` — ascending specifically so two
concurrent carts sharing a product cannot deadlock, and using an explicit
`order_by` so `StockItem.Meta.ordering` does not drag the catalog tables into
the lock.

**That ordering property is the single most delicate thing this migration
touches.** The lock key becomes `(variant_id, warehouse_id)` and the ordering
must extend to the pair, or the deadlock guarantee silently weakens the day a
shop opens its second warehouse. It gets its own test.

### 3.5 One doctype with seven purposes

`Stock Entry` is Material Receipt, Issue, Transfer, Transfer for Manufacture,
Manufacture, Repack and Subcontract, discriminated by a string, with
purpose-specific validation dispatched at runtime. We refuse manufacturing and
subcontracting outright (§8 of the benchmark plan), so five of the seven are
dead weight for us.

We ship **one document that does one thing**: a stock transfer, on the document
lifecycle that shipped this week. Receipt already exists (`PurchaseReceipt`) and
issue already exists (a sale).

---

## 4. The model

### 4.1 `Warehouse` — flat, and one of them by default

```python
class Warehouse(TimeStampedModel):
    name = models.CharField(max_length=120)
    code = models.SlugField(max_length=32, unique=True)
    kind = models.CharField(choices=Kind.choices, default=Kind.SHOP_FLOOR)
    is_default = models.BooleanField(default=False, db_index=True)
    is_active = models.BooleanField(default=True)
    allow_overselling = models.CharField(choices=OversellPolicy.choices,
                                         default=OversellPolicy.SHOP_DEFAULT)
```

`Kind` is `SHOP_FLOOR` / `STORE_ROOM` / `VAN` / `TRANSIT`. It is not a tree and
it is not permissions; it exists so the UI can say المعرض rather than
"Warehouse 1", and so the transfer document can refuse to dispatch *into* a
transit location by accident.

**The default is exactly one warehouse, and it is the shop floor.** The row that
exists today is `code="main"`, `name="المخزن الرئيسي"` — "the main store room" —
which was the right neutral name while nothing displayed it and is the wrong
name the moment something does. Most Libyan shops are one showroom with no back
store at all; naming their only location "the store room" describes a place they
do not have.

It is renamed to **المعرض** (the showroom) with `kind=SHOP_FLOOR` and
`code="main"` kept, because `code` is referenced and `name` is not. This is free
today and stops being free the first time a screen renders it.

A store room is something a shop *adds*. Nothing creates one for them.

### 4.2 `StockItem` gains a warehouse and keeps its name

```python
variant   = models.ForeignKey(...)          # was OneToOneField
warehouse = models.ForeignKey(Warehouse, on_delete=models.PROTECT)
# UniqueConstraint(variant, warehouse)
```

Not renamed to `Bin`, for two reasons: `StockValuationBin` already holds that
word in this codebase, and a rename would churn 95 files for no behaviour.

`PROTECT` rather than `CASCADE` on the warehouse is deliberate and is ERPNext's
rule too — deleting a location must never be a way to delete the stock in it.

### 4.3 The accessor is the whole migration risk, and it is smaller than it looks

`ProductVariant.stock` is a reverse one-to-one accessor used in about forty
places. Making it a manager breaks all of them. But almost all of those are
tests, and **production reads go through one property**:

```python
@property
def quantity_on_hand(self):
    try:
        return self.stock.quantity_on_hand
    except ProductVariant.stock.RelatedObjectDoesNotExist:
        return 0
```

So the seam is a single method, and the rule is:

* `variant.quantity_on_hand` **keeps its name and becomes the sum across
  warehouses.** With one warehouse that is the same number it returns today, so
  every existing caller and every existing test stays correct by construction.
* `variant.quantity_on_hand_at(warehouse)` is new, and is what the POS, the
  stock count and the transfer use.
* `variant.stock` is **deleted**, not redirected. A property that silently
  answered about one warehouse when the caller meant all of them is exactly the
  ambiguity that makes ERPNext's reports have to guess, and a compile-time break
  in forty known places is cheaper than a wrong number in one unknown one.

---

## 5. The transfer document

One document, two submitted halves, a transit location between them — the shape
SAP, Oracle and Odoo all converged on, and for the physical reason rather than
the architectural one: goods in a van are somewhere, and a single-step move
values them in neither place while they are on the road.

* **Dispatch** — a submitted document. Stock leaves the source and lands in
  `TRANSIT`. Cancelling it puts the goods back, through the lifecycle's
  `reverse` hook.
* **Receipt** — a separate submitted document referencing the dispatch. Stock
  leaves transit and lands at the destination.

Both are `apps.documents` types, registered in `registrations.py` like the other
eight, so freeze, cancel, trail, period lock and permissions come for free
rather than being re-implemented. A dispatch with an un-cancelled receipt
against it is a `blocks_cancel` entry.

A same-shop transfer between two warehouses in one database *could* be atomic.
It is still two documents, because the paperwork is what the driver carries and
because a shop that later runs a van needs the in-transit state to be real.

---

## 6. Enforcement

Same doctrine as the document freeze, for the same reason.

1. **One resolver for "may this warehouse go negative"**, consulted by every
   sale, transfer and adjustment. Never a second flag that must agree with the
   first (§3.2).
2. **Lock ordering extends to `(variant_id, warehouse_id)`** and stays
   ascending (§3.4).
3. **Quantities are recomputed, not accumulated**, wherever a recompute is
   affordable — ERPNext's one good idea (§2).
4. **`PROTECT` on every warehouse foreign key**, plus explicit deletion guards
   porting theirs: refuse while any quantity is non-zero, refuse while any
   ledger entry references it, refuse for the default warehouse at all.

---

## 7. What we deliberately do not build

- **A warehouse tree.** §3.1.
- **Bin locations / racks / putaway rules.** A Libyan shop does not have a
  putaway strategy.
- **Per-item default warehouse.** ERPNext has it and its own deletion path has
  to unlink it. Revisit if a customer asks.
- **`Material Request` (store → shop requisition).** Ranked #8 and a natural
  companion, but a separate piece of work with its own approval semantics.
- **Anything with `reserved_qty_for_production`.** No MRP, ever, per §8.

---

## 8. Tests

### 8.1 Ported from ERPNext

Their thirteen warehouse tests reduce to three that mean anything here — four
are tree-only and six are perpetual-inventory GL account tests, and we have
neither a tree nor a GL. What ports:

| ERPNext test | Our equivalent |
|---|---|
| `test_naming` | warehouse `code` is unique and slugified |
| `test_unlinking_warehouse_from_item_defaults` | deletion is refused rather than unlinking silently |
| `on_trash` guards | refuse deletion with quantity, with ledger entries, or if default |

From `test_stock_entry.py`, translated to our transfer document:

| ERPNext test | Our equivalent |
|---|---|
| `test_stock_entry_qty` | a transfer of zero or negative quantity is refused |
| `test_add_to_transit_entry` | dispatch parks stock in transit; receipt clears it |
| `test_transfer_qty_validation` | transfer respects unit conversion (we have UoM) |
| `test_future_negative_sle` | a transfer cannot drive a warehouse negative |
| `test_negative_stock_reco` | a stock count cannot reduce below committed |
| `test_stock_entry_for_same_posting_date_and_time` | ledger ordering is stable within a timestamp |
| `test_reposting_for_depedent_warehouse` | `repost_valuation` cascades per warehouse |
| `test_fifo` | already covered; extended per warehouse |
| cancellation reverts | already covered by the lifecycle; extended per warehouse |

### 8.2 Ours, that they do not have

- **The invisibility guarantee.** A single-warehouse shop's checkout query count
  is *identical* before and after this phase. A scaling test, in the shape of
  `apps/documents/test_query_scaling.py`.
- **Lock ordering.** Two concurrent carts touching the same variant in two
  warehouses do not deadlock (§3.4).
- **The oracle.** `apps/sales/business_simulation.py` learns warehouses and
  independently predicts per-warehouse quantity and value. This is the test that
  actually catches what a unit test will not, and it is the mechanism §10.3
  credited with catching two of the four real money bugs a GL would have missed.
- **Sum equals parts.** Total on-hand across warehouses equals the single number
  the pre-migration schema held, for every variant, across a simulated month.
- **Transit is never nowhere.** At every point in a transfer, quantity in
  source + transit + destination is conserved.

---

## 9. Phasing

**2a — The spine.** `Warehouse` gains `kind` and its oversell policy; the
default row is renamed to المعرض; `StockItem` becomes (variant, warehouse);
`ProductVariant.stock` is deleted and `quantity_on_hand` becomes a sum;
`lock_stock_items` extends its key and ordering. Migration lands every existing
row in the default warehouse. **Exit: the whole suite passes unchanged and the
checkout query count is identical.**

**2b — Surfaces for a second warehouse.** Warehouse CRUD, per-warehouse reorder
levels, stock count per warehouse, stock value and shrinkage reports gaining a
warehouse dimension. **Exit: a shop can create a store room and count it.**

**2c — The transfer.** Dispatch and receipt on the document lifecycle, transit,
the blocking rules, the oracle taught to move stock between locations.
**Exit: a shop can move stock between two locations and the ledger still ties.**

**2d — Register/device profile.** Which warehouse a till sells from, carved out
of global `ShopSettings` — ERPNext's POS Profile, and one of the five primitives
§4 of the benchmark plan marked worth stealing. **Exit: two tills in one shop
can sell from different locations.**

2a is the only stage with a migration clock on it. 2b–2d can wait for a
customer; 2a should not.

---

## 10. Open decisions

1. **Does a real customer have a back store?** The ROI table asserts *"shop +
   back store is the default"*, written 2026-08-26 and not traced to a named
   customer. 2a is justified by the migration clock regardless. 2b–2d are not —
   they want a customer first, and Sufian and Fahd are the two to ask.
2. **Does the price checker become warehouse-aware?** It answers "what does this
   cost", not "where is it", so probably not — but a shop with a store room may
   expect the kiosk to say whether the showroom actually has one.
3. **Do transfers need an approval step?** Ranked #10 (generic approval
   workflow) is *Later*. Until then a transfer is submitted by whoever holds the
   permission, with the trail recording who.
