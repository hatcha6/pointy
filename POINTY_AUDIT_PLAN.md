# Pointy — Whole-Project Audit & Improvement Plan

A living backlog produced from a five-dimension audit of the codebase (backend
performance, frontend performance, UI/UX consistency, navigation/user-flow, code
health). Sequenced by impact ÷ effort into four waves. Check items off as they
ship.

**Overall health:** the codebase is in good shape — one state-management idiom
throughout, near-spotless localization (0 hardcoded UI strings), 0 raw hex
colors, disciplined RTL, a real and broadly-adopted design system, and strong
backend test coverage on the money paths. The debt is **concentrated**, not
systemic. Five independent investigations kept landing on the same hotspots: the
**dashboard**, the **discount form**, **image loading**, and **in-memory work
that can be lost**.

| Wave | Theme | Status |
|---|---|---|
| 1 | Quick wins — visible polish + cheapest perf | ✅ Shipped |
| 2 | Protect the user's work | ✅ Shipped |
| 3 | Heavy paths — kill freezes & N+1s | ✅ Shipped |
| 4 | Structural / maintainability | ✅ Shipped |

---

## 0. Actual correctness bugs (fix regardless of wave)

- [x] **Dashboard "top categories" over-counts revenue.** Fixed in Wave 3:
  `_top_categories` now allocates each order line's revenue and units evenly
  across its product's categories (uncategorised lines divide by 1), so the
  breakdown reconciles with real sales (+ regression test).
- [x] **Coupon usage-limit race.** Verified closed. The authoritative guard
  already existed: `persist_applied_discounts` →
  `lock_and_validate_usage_limits` takes `SELECT ... FOR UPDATE` on each
  redeemed rule inside the order/PO transaction and re-counts live redemptions
  before writing, so concurrent redemptions of a single-use coupon serialise
  and only one passes (the audit cited the stale `DISCOUNTS_IMPLEMENTATION_LOG`
  note, not the code). Hardened with regression tests that pin both the
  recheck (global + per-customer) and the lock acquisition itself
  (`FOR UPDATE` in the persist SQL), plus code comments explaining why live
  counts beat a denormalised counter (the purchasing revise flow deletes
  redemptions). No schema change.

---

## Wave 1 — Quick wins ✅ Shipped

Low-risk, high-visibility. Makes the app *feel* faster and more finished.
All items below shipped and verified (`flutter analyze` clean, POS VM tests
green, Django `check` clean). Migrations generated but not yet applied — run
`make backend-migrate` (or `python manage.py migrate`) against your DB; on large
Postgres tables consider `AddIndexConcurrently` to avoid a write-lock.

- [x] **Backend: index `created_at`.** Add `db_index=True` to
  `TimeStampedModel.created_at` (`apps/core/models.py:10`) + composite
  `(status, created_at)` on `Order` (and `Payment`/`StockMovement` where cheap).
  Confirmed: no index today and `sales`/`payments` define zero `Meta.indexes`,
  yet nearly every dashboard/report/list filters and orders on `created_at`.
- [x] **Frontend: cache + size-constrain product images.** `pointy_product_image_frame.dart:47`
  and `product_image_thumbnail.dart:30` use raw `Image.network` with no cache —
  ~1000px JPEGs decode into ~170px tiles and re-download on scroll-back (#1 POS
  scroll-jank/memory source). Add `cacheWidth/cacheHeight`; consider
  `cached_network_image` / a backend thumbnail URL as a follow-up.
- [x] **Dark-mode color sweep.** 18 static `PointyColors.{primaryContainer,
  amberContainer,primaryStrong,accentAmber}` (always the *light* value) + 6 raw
  `Colors.*` ledger badges in `expenses_screen.dart:492` + 3 `Colors.white` card
  surfaces → theme-aware tokens. (Just-shipped dark mode currently shows light
  patches.)
- [x] **Add `PointyRadii.pill = 999` token** (`pointy_component_styles.dart`) — DESIGN.md
  promises it but it doesn't exist, so 5 sites hand-roll `circular(999)`. Adopt
  it; convert the stray `circular(28)` to `PointyRadii.sheet`.
- [x] **Empty-state CTAs on primary lists.** Sweep the no-action `PointyEmptyState`s
  on primary entity lists (catalog, contacts, invoices, users, purchasing,
  discounts) to link to their create flow — the component already supports
  `action:`. (Detail/search empties intentionally left.)
- [x] **Destructive-action confirmations (POS/purchasing).** Clear-cart,
  discard-parked-sale, clear-purchase-draft, PO submit/cancel currently fire
  instantly — route through `PointyDestructiveConfirmationDialog`; make POS
  line-delete a SnackBar-with-Undo.
- [x] **Retry on network-mutating failures.** Checkout and purchase-submit
  failures are dismissible SnackBars with no Retry; the cart/draft survive, so a
  `SnackBarAction('Retry')` is safe.

---

## Wave 2 — Protect the user's work ✅ Shipped

The highest-leverage UX work. "I lost my cart" makes a cashier distrust the tool.
All items shipped and verified (`flutter analyze` clean; POS/stock-count/draft
persistence covered by round-trip + save→restore tests; no Wave-2 regressions in
the suite).

- [x] **App-wide unsaved-changes guard.** New shared `PointyUnsavedChangesGuard`
  (always-intercept `PopScope` + "discard changes?" dialog, evaluated live so it
  works with text controllers). Applied to the product form, discount form, and
  stock-count counting screen. The purchase draft is protected by persistence
  instead (dismissing its sheet no longer loses it), so a guard there would
  mislead.
- [x] **Persist work-in-progress.** New generic `ScopedJsonStorage`
  (per-user-scoped). POS cart/sale-sessions persist on change and restore on
  launch (clear on checkout); the purchase draft persists/restores/clears on
  submit; the stock-count un-submitted keypad entry persists (counted lines were
  already server-side via `recordLine`). Added full-fidelity `toCartJson`/
  `fromJson` to the cart/variant/customer/supplier/draft-line models.
- [x] **Cold-start guidance.** Dashboard "Get started" checklist (add product →
  add customer → first sale) shown only to a genuinely empty shop, each step
  deep-linking via the existing nav and self-hiding by capability.
- [x] **Actionable permission-denied wall.** `PointyPermissionDeniedView` now
  shows an "ask a manager to grant access" hint and a "Back to home" action.

---

## Wave 3 — Heavy paths (kill freezes & N+1s) ✅ Shipped

Shipped across two commits (backend + frontend). Verified: backend `manage.py
check` clean + 656 tests pass (incl. a new top-categories allocation test and a
constant-query orders-list guard); frontend `flutter analyze` clean + 304 tests
pass. The PDF/ESC-POS tests run on the Dart VM, so they exercise the real
`compute()` isolate and prove the payloads are sendable.

- [x] **PDF generation off the UI isolate.** `order_document_service.dart` renders
  via `compute()` on native (inline on web — no isolates). Fonts are bundled
  (IBM Plex Sans Arabic) and passed as raw `ByteData`, so PDFs also render
  offline. Typeface changed Noto Naskh → IBM Plex; revert via the loader assets.
- [x] **ESC/POS encoding + logo raster off the UI isolate, cache the logo.**
  `encodePayload` runs via `compute()` on native; the `CapabilityProfile` is
  loaded on the caller isolate and passed across; decoded logos are memoised.
- [x] **Dashboard: cache all sections + collapse multi-`.count()`.** All 7
  remaining sections now use `_cached_dashboard_section`; inventory/payroll/
  profitability count+sum fan-outs collapsed into single conditional aggregates.
- [x] **`OrderSerializer` N+1.** GenericRelation + prefetch for applied discounts,
  `lines__adjustment_lines`, and variant option values; context-cached
  ShopSettings + manager flag; prefetch-aware `returned_*`. Orders list is now a
  constant query count regardless of page size (guard test).
- [x] **`SupplierSerializer` N+1.** `total_bought`/`purchase_count` annotated on
  the queryset; `payable_balance` batched into one aggregate (+ fixed a latent
  GROUP-BY ordering-leak that could duplicate multi-order suppliers).
- [x] **Reports double-run aggregates.** Each summary aggregate computed once and
  reused in the metric section. Slim `PurchaseOrderListSerializer` for the PO list
  (drops the receipt/adjustment/audit/attachment trees the detail re-fetches).
  *(Orders list keeps the full serializer — the UI reads `lines`; its N+1 was
  fixed by prefetch instead.)*
- [x] **Lazy lists.** POS cart → `ListView.separated`; operations filtered list →
  `ListView.builder`. *(Deferred: the grouped operations BOARD view — its varied
  template/stage spacing in the redesigned UI needs visual QA, and board job
  counts are bounded.)*
- [x] **Debounce the discount-form live summary** (250ms).
- [x] **Dashboard frontend:** `NumberFormat` hoisted to top-level finals.
  *(Deferred: precomputing chart series in the view model — marginal; the charts
  rebuild on data-load, not in a tight loop.)*

---

## Wave 4 — Structural / maintainability ✅ Shipped

Shipped across several commits. Verified: `flutter analyze` clean + 326 frontend
tests pass; `manage.py check` clean + 669 backend tests pass.

- [x] **Parameterize `formatMoney` / currency.** `ShopSettings.currency_code` +
  `currency_symbol` (backend field + serializer + receipt payload, migration
  0018); `formatMoney` renders a module-global symbol set once from the loaded
  settings, so all ~262 call sites follow with no per-site change. The invoice/
  report PDFs and barcode labels read the symbol on the main isolate; the ESC/POS
  encoder reads it from its payload (it runs in a background isolate). Defaults
  stay د.ل / LYD.
- [x] **Standardize the `Result<T>` contract.** Fixed the one genuine
  anti-pattern (`findVariantByBarcode` threw on `Result.Error` → graceful null).
  The rest of the "uneven adoption" is an intentional domain split — `Result<T>`
  for fallible API calls, raw values for reliable local-storage reads,
  `PrintTransportResult` for device ops — so it's left as-is.
- [x] **Split the worst monoliths** — `dashboard_screen.dart` → 3 Dart `part`
  files; `purchase_submission.dart` → 3; `discount_rule_form.dart` → main + a
  widgets part; `core/dashboard.py` → a `dashboard/` package (view + helpers +
  `__init__`). All behaviour-preserving (verified by the full suites).
- [x] **Shared utilities** — `core/parsing.dart` `parseDecimal()` (Arabic-Indic
  digit + comma/Arabic-separator aware) adopted at ~17 number-field parse sites;
  `core/error_messages.dart` `errorMessageFor()` for safe localized error text
  (light adoption — the app already has mature per-feature error localization).
- [x] **Test gaps** — +21 tests: backend inventory services (stock-count review,
  movement guards) + the untested payment-methods/stock-movements/purchasing
  report builders; frontend expenses (zero→4) and operations (4) view models.
- [x] **Update stale `OPERATIONS_FRAMEWORK_PLAN.md`** — status now reflects that
  Phases 1–2 are shipped.

---

## Audit method

Generated 2026-06-18 from a parallel five-agent read of `backend/apps/` (370 .py)
and `frontend/lib/src/` (526 .dart). Findings cross-validated by re-grepping the
load-bearing claims (index absence, image cache absence, zero `PopScope`, color
leaks, `formatMoney` blast radius). Severity = likelihood × blast radius.
