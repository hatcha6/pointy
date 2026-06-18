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
| 2 | Protect the user's work | ⬜ Planned |
| 3 | Heavy paths — kill freezes & N+1s | ⬜ Planned |
| 4 | Structural / maintainability | ⬜ Planned |

---

## 0. Actual correctness bugs (fix regardless of wave)

- [ ] **Dashboard "top categories" over-counts revenue.** `apps/core/dashboard.py:984`
  groups `OrderLine` by `variant__product__categories__name` (a many-to-many),
  so a product in 3 categories counts 3×. Allocate per category or document it.
- [ ] **Coupon usage-limit race.** `DISCOUNTS_IMPLEMENTATION_LOG.md:201` — usage
  limits enforced in app logic with no DB-level counter/lock; concurrent
  redemptions can both pass. Needs `select_for_update` counter.

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

## Wave 2 — Protect the user's work

The highest-leverage UX work. "I lost my cart" makes a cashier distrust the tool.

- [ ] **App-wide unsaved-changes guard.** Confirmed **zero** `PopScope`/`WillPopScope`
  in the codebase. Product form, purchase draft, stock-count screen, discount
  form all discard work on back/swipe/scrim. Add a shared `PointyUnsavedChangesGuard`.
- [ ] **Persist work-in-progress.** POS cart (`pos_view_model.dart:464`), purchase
  draft, and in-progress stock-count scans are in-memory only — lost on
  crash/restart. Auto-save locally, restore on entry.
- [ ] **Cold-start guidance.** After the setup wizard a new shop sees four blank
  no-CTA screens. Add a dashboard "Get started" checklist (add product → add
  customer → first sale).
- [ ] **Actionable permission-denied wall.** `PointyPermissionDeniedView` shows a
  lock with no "ask a manager to grant X" or "back to home." Make it actionable.

---

## Wave 3 — Heavy paths (kill freezes & N+1s)

- [ ] **Move PDF generation off the UI isolate.** `order_document_service.dart:198`
  — `pw.Document.build()` runs synchronously at checkout. `Isolate.run`.
- [ ] **Move ESC/POS encoding + logo raster off the UI isolate, cache the logo.**
  `esc_pos_receipt_encoder.dart:63` / `:442`.
- [ ] **Dashboard: cache all sections + collapse multi-`.count()` into single
  conditional `aggregate()`.** Infra (`_cached_dashboard_section`) already exists
  but wraps only 4 of ~11 sections.
- [ ] **`OrderSerializer` N+1** (`apps/sales/serializers.py:320`) — prefetch
  `lines__adjustment_lines` + `AppliedDiscount`, cache `ShopSettings` in context.
  ~200 queries/page → ~5.
- [ ] **`SupplierSerializer` N+1** (`apps/purchasing/serializers.py:43`) — annotate
  balances on the queryset instead of Python-looping POs per row.
- [ ] **Reports double-run aggregates** (`apps/reports/services.py`) — compute once,
  reuse in `summary` + `sections`. Slim list serializer for Order/PO viewsets.
- [ ] **Lazy lists** — operations board (`jobs_screen.dart:196`) and POS cart
  (`pos_cart_pane.dart:572`) wrap a `Column` of all rows in a `ListView`; use
  `ListView.builder`.
- [ ] **Debounce + scope the discount-form live summary** (`discount_rule_form.dart:199`).
- [ ] **Dashboard frontend**: hoist `NumberFormat` to `static final`, precompute
  chart series in the view model.

---

## Wave 4 — Structural / maintainability

- [ ] **Parameterize `formatMoney` / currency.** `shared/formatters.dart:1` hardcodes
  `د.ل` across 262 call sites; the shop-setup wizard already hints multi-currency.
- [ ] **Standardize the `Result<T>` contract.** Uneven adoption — `printing_repository.dart`
  17/39 methods; some view-models `throw` (`purchase_view_model.dart:204`).
- [ ] **Split the worst monoliths** — `dashboard_screen.dart` (2095),
  `purchase_submission.dart` (1856), `discount_rule_form.dart` (1814),
  `core/dashboard.py` (1339).
- [ ] **Shared utilities** — `parseDecimal()` (replaces ~25 hand-rolled
  comma→dot parses) and an error→l10n mapper.
- [ ] **Test gaps** — backend `inventory`/`reports`/`fraud` thin vs size; frontend
  `expenses` has zero tests, `operations` ~1.
- [ ] **Update stale `OPERATIONS_FRAMEWORK_PLAN.md`** ("proposed — not yet
  implemented", but operations is fully built).

---

## Audit method

Generated 2026-06-18 from a parallel five-agent read of `backend/apps/` (370 .py)
and `frontend/lib/src/` (526 .dart). Findings cross-validated by re-grepping the
load-bearing claims (index absence, image cache absence, zero `PopScope`, color
leaks, `formatMoney` blast radius). Severity = likelihood × blast radius.
