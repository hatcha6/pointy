# Discounts Implementation Log

This log coordinates the discount-system implementation across agents. Each wave should read this file before starting, add concise findings or changes, and avoid duplicating work already recorded here.

## Wave 1 - Repository Discovery

Subagent 1 completed repository discovery with no file edits.

### Architecture Map

- API routing uses DRF routers in `backend/pointy/urls.py` for `orders`, `purchase-orders`, `payments`, `supplier-payments`, catalog, inventory, and printing.
- Sales totals are persisted on `Order.subtotal` and `Order.total`; `Order.recalculate()` currently sums `OrderLine.unit_price * quantity` and sets `total == subtotal`.
- Sales checkout is orchestrated by `checkout_order()` in `backend/apps/sales/services.py`; payment validation in `CheckoutSerializer.validate()` independently recomputes the gross total before saving.
- Sales returns and voids use `adjustment_amount()` in `backend/apps/sales/services.py`, currently refunding `line.unit_price * returned_quantity`.
- Purchase totals are persisted on `PurchaseOrder.subtotal` and `PurchaseOrder.total`; `PurchaseOrder.recalculate()` sums `PurchaseLine.line_total`, adds landed costs, then allocates landed costs.
- Purchase landed costs are allocated in `PurchaseOrder.allocate_landed_costs()` using either line value or quantity weighting.
- Supplier payable balances derive from purchase order total minus supplier payments and supplier credits.
- Inventory stock movements are quantity-only; price/cost changes should not alter stock movement quantities.
- Tax fields were removed from sales and catalog migrations. Do not add tax UI or tax fields unless explicitly requested later.

### Implementation Direction

- Build a shared backend discount engine with `Decimal` money math and deterministic `0.01` rounding.
- Keep the backend authoritative. Frontend estimates/previews can use doubles, but persisted totals and validation must come from the backend.
- Persist immutable applied-discount snapshots on final sale/purchase documents and affected lines so old documents do not depend on mutable discount rules.
- Replace duplicated sales total paths with a shared calculation path to prevent validation/recalculation drift.
- Apply purchase discounts before landed-cost allocation; line-value landed-cost weights should use discounted net line totals.
- Keep existing no-discount behavior unchanged by using zero/default-safe migration fields.

### Risks To Track

- Sales payment validation and order recalculation currently duplicate total math.
- Refunds/voids must refund discounted net amounts, including proportional document-level discounts.
- Purchase adjustment credits/refunds should use discounted purchase-line economics.
- Existing API clients must remain backward compatible when no discount fields are supplied.
- Receipt and detail serializers need discount fields so totals are explainable.

## Wave 2 - Discount Domain Model and Rules Engine

Subagent 2 added the backend discount domain layer only. Sales checkout and purchase save flows are intentionally not integrated yet.

### Design Summary

- Added a native Django app, `apps.discounts`, registered in backend settings and package metadata.
- `DiscountRule` stores mutable rule definitions for sales, purchasing, or both. It supports automatic and coupon-code rules, document-level or line-level scope, percentage/fixed-document/fixed-unit values, priorities, exclusivity, start/end dates, global usage limits, per-customer and per-supplier usage limits, minimum order subtotal, minimum line quantity, and product/customer/supplier constraints.
- Category and location constraints are not persisted yet because the current catalog/inventory model has no category or location table. The engine input includes `category_ids` and `location_id` as forward-compatible context, but Wave 2 does not invent placeholder tables.
- `AppliedDiscount` stores immutable audit snapshots independent of later rule edits. Snapshots record rule name/code/value/scope/priority/exclusivity, source subtotal, discount amount, document generic reference, optional line generic reference, and line allocation metadata.
- `DiscountRedemption` records usage after application, linked to the applied snapshot when one exists. The engine checks these records for global/customer/supplier usage limits.
- `DiscountEngine` in `backend/apps/discounts/services.py` is the reusable calculation entry point for both sales and purchases. It uses `Decimal`, deterministic cent rounding, line allocations, rule priority order, and remaining-line balances so stacked discounts cannot over-discount a line.
- Exclusivity semantics: rules are evaluated by `priority` then `id`; an exclusive rule blocks later rules if it applies. An exclusive rule with lower precedence is skipped once earlier non-exclusive rules have applied.

### Files Changed

- Added `backend/apps/discounts/` with `apps.py`, `models.py`, `services.py`, `admin.py`, `tests.py`, and `migrations/0001_initial.py`.
- Updated `backend/pointy/settings.py` to install `apps.discounts`.
- Updated `backend/pyproject.toml` so editable installs include `apps.discounts` and its migrations.
- Updated this implementation log.

### Migration Summary

- New tables: `discounts_discountrule`, `discounts_applieddiscount`, `discounts_discountredemption`, plus M2M tables for rule product/customer/supplier constraints.
- Uses nullable/default-safe fields; no existing sales, purchasing, catalog, customer, or supplier documents are modified.
- Coupon codes are normalized to uppercase on model save and constrained unique when non-blank.

### Tests Run

- `backend/.venv/bin/python backend/manage.py test apps.discounts` - passed, 7 tests.
- `make backend-check` - passed.
- `make backend-test` - passed, 152 tests.

### Notes For Wave 3 Integration

- Sales checkout should build `DiscountContext(channel="sales", lines=...)` from the pending cart, including `customer_id` and coupon codes, then persist `AppliedDiscount`/`DiscountRedemption` with `persist_applied_discounts()` after the order and lines exist.
- Purchase save/recalculate should build `DiscountContext(channel="purchasing", lines=...)` using line unit costs and `supplier_id`. Apply purchase discounts before landed-cost allocation, and use discounted net line totals for line-value landed-cost weights.
- Replace duplicated gross-total validation paths with one backend discount-aware calculation path before accepting payments.
- Returns, voids, and purchase adjustments need to refund/credit discounted net amounts. Use stored applied-discount allocations instead of re-reading mutable rules.
- Serializer/API/receipt work should expose subtotal, discount total, total, coupon code/application details, and line allocations so totals are explainable while keeping no-discount clients backward compatible.

### Main-Agent Review Amendments

- Added immutable `AppliedDiscount.source`, using `automatic` or `coupon_code`, so applied snapshots do not infer source from mutable rules.
- Changed default stacking behavior to conservative: `DiscountRule.exclusive` now defaults to `True`; set it to `False` only when a rule is explicitly stackable.
- Added line-level `fixed_price` discount support. It reduces eligible line units down to the configured fixed unit price when that price is lower than the current remaining line value.
- `persist_applied_discounts()` now enriches allocation snapshots with persisted line object ids and product ids when line objects are provided.
- Re-ran `backend/.venv/bin/python backend/manage.py test apps.discounts` - passed, 9 tests.
- Re-ran `backend/.venv/bin/python backend/manage.py makemigrations --check --dry-run` - passed, no changes detected.

## Wave 3 - Sales and Purchase Integration

Subagents 3 and 4 integrated the shared discount engine into sales and purchasing. The main agent reviewed both patches together and made one purchase valuation fix.

### Sales Integration

- Sales checkout/order creation now builds `DiscountContext(channel=sales)` from pending lines, optional customer, and `coupon_code`/`coupon_codes`.
- Automatic and coupon-code sales discounts are applied through the shared engine.
- Applied discount snapshots/redemptions are persisted after `OrderLine` rows exist.
- Added default-safe sales fields for `Order.discount_total`, `OrderLine.discount_total`, and `OrderAdjustmentLine.discount_total`.
- Returns and voids refund stored discounted net amounts without re-reading mutable discount rules.
- Sales serializers expose `discount_total`, `line_subtotal`, net `line_total`, and `applied_discounts`.
- Receipt payloads now include order discount totals, line discount totals, and applied discount snapshots.

### Purchase Integration

- Purchase order creation/update now applies `DiscountContext(channel=purchasing)` from draft lines, supplier, and `discount_codes`.
- Added purchase order/line discount persistence: `PurchaseOrder.discount_codes`, `PurchaseOrder.discount_total`, `PurchaseLine.discount_amount`, `PurchaseLine.net_line_total`, and `PurchaseLine.net_unit_cost`.
- Purchase applied discount snapshots/redemptions are persisted after `PurchaseLine` rows exist, and safely replaced on draft edits/deletes.
- Landed-cost value allocation uses discounted net line totals as weights.
- Effective inventory valuation uses net unit cost plus landed unit cost.
- Purchase adjustments/returns/refunds/exchanges use stored discounted net amounts for settlement, supplier credits, and supplier payments.

### Main-Agent Integration Fix

- Fixed `PurchaseLine.save()` so a discounted line with no landed costs keeps `effective_unit_cost == net_unit_cost` instead of resetting to gross `unit_cost`.
- Added a purchasing test assertion covering this zero-landed-cost valuation case.

### Tests Run

- `backend/.venv/bin/python backend/manage.py test apps.sales apps.purchasing apps.printing apps.discounts` - passed, 130 tests.
- `backend/.venv/bin/python backend/manage.py makemigrations --check --dry-run` - passed, no changes detected.
- `make backend-test` - passed, 167 tests.

## Wave 4 - Discount Configuration, Coupons, Preview, and UI/API Polish

Subagent 5 added the management API/admin validation layer and the first frontend discount surfaces on top of the Wave 1-3 backend engine/integration.

### Backend API and Validation

- Added `DiscountRuleSerializer` and `DiscountRuleViewSet`, routed at `/api/discount-rules/`.
- Managers can list/retrieve/create/update discount rules with standard Django model permissions; manager role bootstrapping now includes the `discounts` app permission domain.
- Added `enable` and `disable` actions. API `DELETE` now soft-archives rules by setting `is_active=false` and recording `metadata.archived_at`; it does not hard-delete historical configuration.
- Added rule validation for ambiguous/unsafe configurations: coupon rules require a code, automatic rules cannot carry a coupon code, percentages cannot exceed 100, fixed unit/fixed price rules must be line-level, maximum discount caps must be positive, customer-only constraints cannot be purchasing-only, and supplier-only constraints cannot be sales-only.
- Added `/api/orders/discount-preview/` so POS can ask the backend for authoritative automatic/coupon discounts before tendering.
- Purchase order serializers now expose `applied_discounts` snapshots alongside `discount_total` and `discount_codes`.

### Frontend Polish

- POS cart now has localized Arabic coupon-code entry, backend discount preview refresh, applied automatic/coupon discount rows, invalid-coupon feedback, and discounted tender totals.
- POS checkout sends `coupon_code` and refreshes the backend preview before opening the payment dialog so automatic discounts do not create overpayment validation failures.
- Sale order details now show subtotal, discount total, applied discount snapshots, and line-level discounts.
- Purchase draft now captures a supplier discount code and sends it as `discount_codes`.
- Purchase order details now show discount codes, order-level discount totals, applied discount snapshots, line discount amounts, and net unit costs.
- Added Arabic l10n strings and regenerated Flutter localization output.

### Files Changed By Wave 4

- Backend: `backend/apps/discounts/models.py`, `backend/apps/discounts/serializers.py`, `backend/apps/discounts/views.py`, `backend/apps/discounts/tests.py`, `backend/apps/core/roles.py`, `backend/apps/sales/serializers.py`, `backend/apps/sales/views.py`, `backend/apps/purchasing/serializers.py`, `backend/pointy/urls.py`.
- Frontend: `frontend/lib/src/data/models/sale_order.dart`, `frontend/lib/src/data/models/purchase_submission.dart`, `frontend/lib/src/data/repositories/sale_repository.dart`, `frontend/lib/src/data/repositories/purchase_repository.dart`, `frontend/lib/src/data/services/pos_api_service.dart`, `frontend/lib/src/data/services/sales_api_client.dart`, POS view models/views, purchasing view model/views, sale/purchase detail views, `frontend/lib/l10n/app_ar.arb`, generated l10n files.

### Tests Run

- `backend/.venv/bin/python backend/manage.py test apps.discounts` - passed, 14 tests.
- `backend/.venv/bin/python backend/manage.py test apps.discounts apps.sales apps.purchasing apps.printing` - passed, 135 tests.
- `backend/.venv/bin/python backend/manage.py makemigrations --check --dry-run` - passed, no changes detected.
- `make backend-check` - passed.
- `flutter gen-l10n` from `frontend/` - passed.
- `dart format lib test` from `frontend/` - completed.
- `flutter analyze` from `frontend/` - passed.
- `flutter test test/features/pos/view_models/pos_view_model_test.dart` - passed.
- `flutter test` from `frontend/` - passed, 56 tests.

### Known Limitations / Deferred Cases

- There is no dedicated Flutter discount-management screen yet; management is available through the new API and Django admin.
- Sales preview is implemented because checkout payment validation needs backend-authoritative totals before tendering. Purchasing captures coupon codes and displays saved backend results, but draft-time purchasing preview is deferred.
- Frontend discount previews intentionally do not duplicate rule math; the backend remains authoritative.

## Wave 5 - Testing, QA, Migration Safety, and Documentation

Subagent 6 performed the final discount-system pass. No broad rewrites were made.

### Test Coverage Added

- Strengthened discount-engine tests for minimum subtotal gates, maximum caps, deterministic cent allocation, disabled/future/expired automatic rules, and immutable snapshot persistence after rule edits.
- Strengthened sales integration tests for no-discount defaults, no active tax response fields, coupon usage limits after redemption, customer/product/minimum-subtotal coupon restrictions, discounted returns, and discounted void remainders.
- Strengthened purchasing integration tests for no-discount defaults, no active tax response fields, draft discount update cleanup, draft delete cleanup, supplier usage limits, and discounted refund/exchange adjustment economics.
- Existing sales, purchasing, discount API, and printing receipt discount tests continue to cover automatic and coupon-code discounts, line/document discounts, stackable/non-stackable priority, invalid/expired/disabled coupons, landed-cost allocation, applied discount payloads, and receipt snapshots.

### Documentation Added

- Added `backend/apps/discounts/README.md` explaining the discount model, calculation flow through sales and purchases, snapshot/redemption persistence, how to add a new discount value type, and the current no-tax constraint.

### QA and Migration Notes

- Reviewed discount-related backend apps, sales/purchasing/printing integrations, migrations, and frontend POS/purchasing discount surfaces.
- Confirmed the new migrations are additive/default-safe. The purchasing data backfill uses `RunPython.noop` on reverse, consistent with existing purchasing backfill migrations.
- Confirmed no active backend API or frontend discount surface adds tax fields or tax UI. Historical migrations still contain removed tax fields by design.

### Tests Run

- `backend/.venv/bin/python backend/manage.py test apps.discounts apps.sales apps.purchasing apps.printing` - passed, 144 tests.
- `backend/.venv/bin/python backend/manage.py makemigrations --check --dry-run` - passed, no changes detected.
- `make backend-check` - passed.
- `make backend-test` - passed, 181 tests.
- `flutter analyze` from `frontend/` - passed.
- `flutter test` from `frontend/` - passed, 56 tests.
- `git diff --check` - passed.

### Known Limitations / Deferred Cases

- Purchasing still has no draft-time discount preview; it validates and persists discounts on save.
- Discount usage limits are enforced both at calculation time (an unlocked pre-check that hides exhausted coupons from the buyer) and, authoritatively, at persistence time. `persist_applied_discounts` calls `lock_and_validate_usage_limits`, which takes `SELECT ... FOR UPDATE` on each redeemed rule inside the caller's order/PO transaction and re-counts live redemptions before writing — so two requests that both priced the same single-use coupon while it looked available cannot both redeem it (the loser blocks on the lock, re-counts the winner's redemption, and is rejected). Live redemption rows are counted rather than a denormalised counter so the purchasing revise flow's clear-and-reapply stays correct. Covered by `apps/discounts/tests.py` (`test_persist_rechecks_usage_limits_under_rule_lock`, `test_concurrent_stale_results_cannot_both_redeem_single_use_coupon`, `test_concurrent_stale_results_respect_per_customer_limit`, `test_persist_locks_discount_rules_for_update`).
- No tax support was added; discount documentation and tests intentionally preserve the current no-tax product surface.

## Follow-up - Flutter Discount Management Screen

Implemented the dedicated Arabic Flutter management surface that was deferred in Wave 5.

### Frontend Management UX

- Added a new drawer destination: `الخصومات`.
- Wired discount navigation through the authenticated route builders so the drawer entry is available from POS, catalog, contacts, register sessions, purchasing, device settings, user management, shop settings, and the discount screen itself.
- Added granular frontend capabilities for `view`, `add`, `change`, and `delete` discount rules. The drawer uses view permission; create/edit/enable/disable/archive controls use the matching action permissions.
- Added a paginated `DiscountManagementViewModel` and data layer for `/api/discount-rules/`.
- The rule list uses the existing shared `InfiniteScrollList` widget.
- Added Arabic search, filters, ordering, status chips, usage/application summaries, and action buttons for edit, enable/disable, and archive.
- Added a bottom-sheet discount rule form for automatic and coupon-code rules, sales/purchasing/both channels, line/document scope, percentage/fixed/fixed-unit/fixed-price value types, priority, exclusivity, date range, minimums, usage limits, and product/customer/supplier constraints.
- Replaced raw product/customer/supplier ID entry with searchable multi-select picker fields. The pickers use the existing catalog/contact repositories and shared `InfiniteScrollList`, while the API contract still submits selected IDs.
- Existing rules still load from stored IDs; selected chips hydrate to friendly names when matching records appear in picker results.
- Added client-side validation for required fields, positive values, percentage bounds, line-only value types, date ranges, and channel-specific customer/supplier constraints.

### Tests Run

- `flutter gen-l10n` from `frontend/` - passed.
- `dart format lib test` from `frontend/` - completed.
- `flutter analyze` from `frontend/` - passed.
- `flutter test test/widget_test.dart --plain-name 'manager can open and create discount rules'` - passed.
- `flutter test` from `frontend/` - passed, 58 tests.
- `git diff --check` - passed.

## Follow-up - Purchasing Preview and Atomic Usage Limits

Closed the two remaining discount-system hardening items.

### Backend

- Added `/api/purchase-orders/discount-preview/` for draft-time purchasing discount previews. It uses the shared `DiscountEngine`, supplier context, draft line costs, discount codes, landed costs, and the current landed-cost allocation method, without persisting orders, snapshots, or redemptions.
- Purchase preview returns backend-authoritative `subtotal`, `discount_total`, `landed_cost_total`, `total`, applied discount details, unapplied discount codes, and draft line economics.
- Added a final usage-limit guard in `persist_applied_discounts()`: affected `DiscountRule` rows are locked with `select_for_update()` inside the save transaction, usage counts are rechecked, and stale coupon applications are rejected before snapshots/redemptions are inserted.
- Sales and purchasing translate that final stale-usage rejection into the existing coupon/discount-code validation fields so callers receive a normal 400 response.

### Frontend

- Purchase draft totals now call the new purchasing preview endpoint through the service/repository/view-model layers.
- Draft totals show backend previewed discounts and applied coupon rows before landed costs and final total.
- Purchase submission refreshes the preview first and blocks locally on preview errors or unapplied discount codes; the backend remains the final authority on save.

### Tests Run

- `backend/.venv/bin/python backend/manage.py test apps.discounts apps.purchasing` - passed, 83 tests.
- `flutter analyze` from `frontend/` - passed.
- `flutter test` from `frontend/` - passed, 58 tests.
- `make backend-check` - passed.
- `make backend-test` - passed, 184 tests.
- `backend/.venv/bin/python backend/manage.py makemigrations --check --dry-run` - passed, no changes detected.
- `git diff --check` - passed.

## Follow-up - Quantity Promotions (multi-buy, tiered, buy-X-get-Y)

Added three line-scoped, **pooled** value types that price a pool of whole units
gathered across every line a rule matches (mix-and-match). Only whole units take
part — a fractional remainder on a weighed line keeps full price.

### Backend
- `DiscountRule.ValueType` += `multi_buy`, `tiered`, `buy_x_get_y`;
  `POOLED_VALUE_TYPES`; `BuyGetReward` (free/percentage/fixed_price). New fields
  `group_size`, `buy_quantity`, `get_quantity`, `reward_type`; new child model
  `DiscountTier(rule, min_quantity, unit_price)`. Migration
  `0008_discount_quantity_promotions` (additive/default-safe).
- `DiscountRule._clean_quantity_promotion`: pooled types are line-only, reject
  `min_line_quantity`, validate per-type params, and clear stale params on retype.
- Engine (`DiscountEngine._pooled_allocations` + helpers): multi-buy charges the
  **most-expensive** N-unit groups (self-stacks); tiered reprices **all** whole
  units at the highest met tier; buy-X-get-Y rewards the **cheapest** units.
  `_allocate_capped` caps each line at its remaining balance so stacking can't
  over-discount. `eligible_rules` prefetches `tiers`.
- `DiscountRuleSerializer`: nested writable `tiers`, `value` optional (derived =
  cheapest tier price for tiered), new fields; create/update replace tier rows.
  Viewset prefetches `tiers`; admin gains a `DiscountTier` inline.
- AI: `describe_resource` auto-exposes the new fields + nested tiers + choices
  through the live serializer (no tool code change); `relay_stream` system prompt
  documents the three promos.
- Tests: `QuantityPromotionEngineTests` (23) cover every type incl. pooling,
  fractional lines, caps, stacking, validation; new API + AI create tests; two
  real checkout integration tests (multi-buy, BOGO). Full backend suite green.

### Frontend
- `discount_rule.dart`: `DiscountValueType` += three types (+`isQuantityPromotion`);
  `DiscountBuyGetReward`; `DiscountTier` model; new `DiscountRule`/`DiscountRuleDraft`
  fields + nested `tiers` (toJson sends null value for tiered, 100 for free reward).
- Form: type-specific inputs (group size+price / dynamic tier-row editor / buy+get+
  reward selector), auto line scope, live summary + chips, validators; min-line-qty
  hidden for promos. Presenter + details "how it works" render the new types/tiers;
  preview harness gains one example rule per type.
- l10n keys added to `app_ar.arb` (regenerated). Model serialization tests added
  (`test/models/discount_rule_quantity_promotions_test.dart`); existing form
  widget test still green. `flutter analyze` clean.

### Known limitation
- Per-line/pool grouping uses the line's `unit_amount`; stacking a pooled promo on
  an already-discounted line caps at the remaining balance (rare; pooled promos are
  exclusive by default). Rounding composes but is unusual for these types.
