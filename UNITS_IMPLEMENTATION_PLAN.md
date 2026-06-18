# Units of Measure — Implementation Plan

Status: in progress. This document is the architecture spec and the running
checklist for the multi-unit / conversion / per-unit-pricing feature.

## Goal

Today a product has a single base unit (`Product.unit` ∈ piece/kg/g/l/ml) and a
single price (`ProductVariant.unit_price`). We want a product to be **sold and
purchased in several units** — piece, dozen, box, carton, wholesale pack, kg, g…
— with:

- **predictable, editable conversions** between each unit and the product's base
  (stock) unit,
- a **default sale unit and default purchase unit** per product,
- **optional custom price per unit** (else derived from the base price × factor),
- **fast unit switching** in the POS and purchasing screens,
- **good defaults seeded** so an empty shop already has sensible units,
- everything **auditable** (the conversion factor is snapshotted on every line),
- units printed on the **receipt, invoice, and purchase order**.

## Prior art (how the big systems do it)

- **Odoo** — `uom.category` groups units that can convert among each other; each
  category has one *reference* unit (`factor = 1`) and the others store a
  `factor` / `factor_inv` to it. A product has a stock UoM plus a separate
  *purchase* UoM, both constrained to the same category. You cannot convert
  across categories (kg ↔ L is rejected).
- **ERPNext** — a global `UOM` master, plus a per-item **UOM Conversion Detail**
  table mapping each sellable/purchasable unit to the item's **stock UOM**. Sale
  & purchase lines carry `uom`, `conversion_factor`, `stock_uom`, and
  `stock_qty = qty × conversion_factor`. Price can be set per UOM.
- **Square / Shopify** — support measurement units and weight-based items but do
  **not** natively model pack/case selling; it needs add-ons. We are building the
  ERPNext/Odoo-style model, which is the robust one.

**Consensus invariants we honor:**
1. Stock is stored in exactly **one base unit** per product. Everything else
   converts to it.
2. Conversions for **physical measures** (weight/volume) are global & predictable
   (kg = 1000 g). Conversions for **packaging** (box, carton, pack) are
   **per-product** (a box of pens ≠ a box of sacks) and user-editable.
3. A transaction line **snapshots the conversion factor** it used, so history is
   auditable even after the product's units are edited later.
4. You cannot convert across dimensions.
5. Price is **per transacted unit**; quantity is stored in the transacted unit;
   stock math uses `quantity × factor`.

## Data model

### `catalog.UnitOfMeasure` (new — global registry, editable)

The managed list of units a shop can use. Seeded with sensible defaults;
managers can add/edit/deactivate.

| field | type | notes |
|---|---|---|
| `code` | slug, unique | join key, e.g. `piece`, `kg`, `box`. Existing `Product.unit` values are codes. |
| `name` | char | Arabic display name. |
| `abbreviation` | char | short label for receipts (`كجم`). |
| `dimension` | choice | `count` / `weight` / `volume` / `length`. Gates cross-dimension conversion + fractional rule. |
| `reference_factor` | decimal(18,6) null | for physical units: amount of the dimension's reference unit in 1 of this (g→0.001 kg). Null for packaging. Powers *suggested* factors only. |
| `allows_fractional` | bool | derived default from dimension (weight/volume = true). Controls whole-number guard. |
| `is_system` | bool | seeded defaults; protected from deletion. |
| `is_active` | bool | |
| `display_order` | int | |

### `catalog.ProductUnit` (new — per-product transactable units)

Each **additional** unit a product can be sold/bought in, beyond its base unit.
The base unit itself is implicit (factor 1, price = `variant.unit_price`).

| field | type | notes |
|---|---|---|
| `product` | FK Product | |
| `unit` | FK UnitOfMeasure | |
| `factor_to_base` | decimal(18,6) > 0 | **how many base units = 1 of this unit** for this product (box → 12). User editable. |
| `price` | decimal(10,2) null | custom sale price for 1 of this unit. Null → derived = `variant.unit_price × factor`. |
| `is_sellable` | bool | show in POS. |
| `is_purchasable` | bool | show in purchasing. |
| `display_order` | int | |

Constraints: unique `(product, unit)`; `factor_to_base > 0`; `price >= 0`.

### `catalog.Product` additions

- Keep `unit` as the **base/stock unit code** (unchanged values, no rigid
  `choices` so new units work; validated against active `UnitOfMeasure`).
- `default_sale_unit` — char code, blank = base unit.
- `default_purchase_unit` — char code, blank = base unit.

### Transaction-line additions (auditable snapshots)

- `sales.OrderLine`: add `unit` (code) + `unit_factor` (decimal snapshot).
  `quantity` stays in the transacted unit. `base_quantity = quantity × unit_factor`
  (property) feeds stock. `unit_price`/`unit_cost` are per transacted unit.
- `purchasing.PurchaseLine`: add `unit` (code) + `unit_factor`. `quantity` stays
  **integer** (you buy whole packs — v1 scope; fractional purchasing is a future
  extension). `unit_cost` is per transacted unit; cost feeding the sales
  cost-lookup is normalised to per-base (`unit_cost / unit_factor`).
- `PurchaseReceiptLine` quantities stay integer (transacted unit); converted to
  base via the line's `unit_factor` at the stock boundary.

## Conversion + pricing engine (`catalog/units.py`)

Pure functions, shared by sales & purchasing:
- `base_factor(product, code)` → Decimal (1 for base/blank; else ProductUnit factor).
- `to_base_quantity(qty, factor)` → `(qty × factor).quantize(0.001)`.
- `unit_sale_price(variant, product_unit)` → custom price or `variant.unit_price × factor`, 2dp.
- `unit_cost(base_cost, factor)` → `base_cost × factor`, 2dp.
- `allows_fractional(product, code)` → from the unit's dimension.
- Validation helpers: a code must resolve to the base unit or an active
  sellable/purchasable `ProductUnit` of that product.

## Backend integration points (from research)

- **Sales** `CheckoutLineSerializer.validate` — accept `unit`, resolve factor,
  set `effective_unit_price` = unit price (+ modifier delta). Whole-number guard
  uses the *selected* unit's `allows_fractional`. `create_order_with_lines`
  persists `unit` + `unit_factor`, scales `unit_cost` by factor.
  `prepare_sale_stock_adjustments` / `record_sale_stock_movements` convert to base
  with `unit_factor` before the availability check and deduction.
- **Purchasing** `PurchaseLineSerializer` — accept `unit` + factor; receiving
  (`apply_receipt_stock_changes`, `submit_purchase_order`, cancel) convert to base.
  `latest_variant_unit_cost` / `latest_sale_unit_cost` divide by `unit_factor`
  to stay per-base.
- **Print** — `printing/services.py receipt_line_payload` adds a `unit` label;
  invoice + PO PDFs add an RTL-safe unit column (grow `columnFlex` to 5 together);
  `PurchaseOrderLine` gains a `unit` field end-to-end.
- **Settings/roles** — cashier role gains `catalog.view_unitofmeasure` /
  `view_productunit`; managers inherit via the catalog domain. Seed migration +
  initial-setup data check updated.

## Frontend integration points

- Models: `UnitOfMeasure`, `ProductUnit`, extend `Product`, `CartLine`
  (selectedUnit + factor + resolved price; unit folded into the merge key),
  `PurchaseDraftLine`, `PurchaseOrderLine`.
- POS: `showUnitSheet` chip picker (default preselected, per-unit price shown),
  cart-line unit chip + switch, weight/quantity sheet respects the selected unit.
- Purchasing: per-line unit selector.
- Product form: a "Units & conversions" section (manage ProductUnit rows: unit,
  factor, optional price, sellable/purchasable, defaults).
- Invoice/PO/receipt rendering: unit column/label.
- l10n: new Arabic strings. Preview harness updated.

## Decisions & rationale

- **Per-unit price lives on the Product unit (not per variant).** Packaging/
  wholesale is overwhelmingly single-variant; for multi-variant products a custom
  pack price applies flatly and the derived `variant_price × factor` is used when
  no custom price is set. Keeps the UI sane; documented edge case.
- **Purchase quantity stays integer for v1.** You buy whole packs; this preserves
  the current behavior exactly and avoids a high-risk decimal migration across
  receipts/adjustments. Base conversion is decimal. Fractional purchasing = later.
- **`Product.unit` stays a string code.** Lowest-risk migration — every existing
  `product.unit == 'piece'` guard keeps working; `UnitOfMeasure` is keyed by code.

## Checklist

Backend — DONE (231 catalog/sales/purchasing + 227 downstream tests green)
- [x] `UnitOfMeasure` + `ProductUnit` models, constraints, querysets, admin
- [x] `unit_defaults.py` seed constants + data migration (0013 schema, 0014 seed)
- [x] `Product.default_sale_unit` / `default_purchase_unit`; relaxed `unit` choices
- [x] `catalog/units.py` conversion + pricing engine (+ tests)
- [x] Serializers: `UnitOfMeasureSerializer`, `ProductUnitSerializer`, nested on both product serializers
- [x] `UnitOfMeasureViewSet` + routing (`units-of-measure`); ProductUnit nested write on product
- [x] Sales: OrderLine `unit`/`unit_factor` + migration; checkout pricing; stock + returns conversion; loss-guard
- [x] Purchasing: PurchaseLine `unit`/`unit_factor` + migration; serializer; submit/receive/cancel/adjust conversion; cost normalisation
- [x] Print: receipt payload `unit`/`unit_label`; order-line serializer reports transacted unit
- [x] Roles (`catalog.view_unitofmeasure`) + initial-setup data check
- [x] Backend tests (engine, serializer, checkout, purchasing lifecycle)

Frontend — DONE (full `lib` analyzes clean; model + POS + document tests green)
- [x] Dart models: UnitOfMeasure, ProductUnit, Product, CartLine, purchase + order lines
- [x] `UnitOfMeasureApiClient` + `CatalogRepository.loadAllUnits`
- [x] Repos/VMs: unit threaded through checkout + purchase payloads + cart merge key (`setCartLineUnit`, `updateLineUnit`)
- [x] POS adds at the product's default unit (no dialog); cart-line shows a tappable unit **pill** that opens `unit_quantity_sheet.dart` to switch unit/qty (`defaultSaleUnitOption`, `setCartLineUnit`, `shared/unit_options.dart`)
- [x] Purchasing per-line unit selector + base-equivalent hint + default purchase unit preselect
- [x] Product form "Units & conversions" editor (`product_units_editor.dart`) — rows, factors, custom price, sellable/purchasable, default sale/purchase unit, suggested same-dimension factors
- [x] Invoice + PO quantity cells show the unit (RTL-safe fold); receipt + PO thermal show `unit_label`
- [x] l10n strings (+ `flutter gen-l10n`)
- [x] Preview: `?screen=unit-sheet` + seeded pack cart line; visually verified

## Units management screen — DONE
Full CRUD over the global `UnitOfMeasure` registry, reachable from the catalog
screen's app-bar (a straighten-icon action → pushed `UnitsManagementScreen`).
Deliberately self-contained (no drawer/palette destination) to avoid touching the
shared nav files (`authenticated_home.dart` etc.) while the command palette is in
flight — promoting it to a drawer destination later is a ~4-line change.
- Backend: `product_count` annotation/field on `UnitOfMeasureSerializer` (usage);
  viewset already guards system-unit delete/code-change and in-use delete. Tests
  in `catalog/test_units.py::UnitsManagementApiTests`.
- Frontend: `UnitOfMeasureDraft` + API client/repo create/update/delete/reorder;
  `units_management_view_model.dart` (flat `_mutate` pattern); `units_management_screen.dart`
  (dimension-grouped sections, system/inactive/in-use badges, reference-factor
  summaries, overflow action menu, full editor dialog with system-lock handling,
  protected-delete dialogs). Preview: `make frontend-units-preview` (`?screen=editor`).

## Known boundaries / future work
- Purchase quantities stay integer (whole packs); fractional purchasing is a future migration.
- Per-unit custom price is per-product; for multi-variant products it applies flatly (derived price used otherwise).
- A unit's rounding is a boolean (`allows_fractional`); Odoo-style rounding multiples are a future refinement.
- Units management is reached from the catalog app-bar, not the drawer/command palette (deferred to avoid colliding with in-flight nav work).
