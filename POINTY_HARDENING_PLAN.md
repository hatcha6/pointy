# Pointy hardening — pain-point sweep

Making Pointy a sharp, fast tool for shop owners. Six workstreams, tackled
**feel-first** (low-risk delight first, heavy features after). Optimistic-update
cleanup is folded into each phase as those view models are touched.

| # | Workstream | Status |
|---|-----------|--------|
| 1 | Dark mode | ✅ Shipped |
| 2 | Skeleton loaders | ✅ Shipped |
| 3 | POS keyboard-first speed | ✅ Shipped |
| 4 | Bulk operations (products) | ✅ Shipped |
| 5 | First-run shop-setup wizard | ✅ Shipped |
| 6 | Optimistic-update consistency | 🔁 folded into 2–5 |

---

## 1. Dark mode — ✅ Shipped

Per-device light/dark/system theme. The architecture was already dark-ready
(308+ widgets read `context.pointyColors`, `lerp()` implemented), so the theme
was made **palette-driven** and light mode stays byte-for-byte identical.

- `PointyColorsDark` — dark palette mirroring `PointyColors` token-for-token.
- `PointySemanticColors.dark()` + new `primary` / `primaryContainer` /
  `amberContainer` tokens, so the theme builder is fully palette-driven.
- `PointyComponentStyles.*` now take a `PointySemanticColors`; `PointyTheme`
  has one private `_build(colors, brightness)` that `light()`/`dark()` delegate
  to. `darkAppBarTheme` (high-focus POS bar) stays a fixed dark, intentionally.
- `ThemeController` (per-device, persisted via `DeviceSettingsStorageService`
  SharedPreferences) + `ThemeControllerScope` (InheritedNotifier). Wired into
  `app_dependencies` (loaded first in `start()`) and `app.dart`
  (`darkTheme` + `themeMode` under a `ListenableBuilder`).
- Toggles: drawer + rail row, collapsed-rail icon, ⌘K command-palette action,
  and a 3-way selector in Device Settings → Appearance.
- Preview: `make frontend-theme-preview` (`?screen=dark|light`). Verified both
  modes render correctly with no console errors.

## 2. Skeleton loaders — ✅ Shipped

`PointySkeleton` (shimmer via `AnimationController` + `ShaderMask`, no new
dependency) + `PointySkeletonBox` / `PointySkeletonListTile` / `PointySkeletonCard`
in `shared/components/pointy_skeleton.dart`. Shimmer colours derive from the
palette, so it adapts to dark mode.

Wired centrally so screens upgrade together:
- `PointyDataList` now defaults its initial-load state to a framed list-tile
  skeleton — upgrades ~16 screens at once (invoices, purchase orders, contacts,
  users, register sessions, stock count, employees, discounts, activity log…).
- `InfiniteScrollView/Grid/List` take an optional `skeletonItemBuilder` +
  `skeletonItemCount`, laid out in the real sliver shape.
- Catalog product table (keeps its header + shimmers rows), POS catalog grid and
  purchasing catalog grid (`PointySkeletonCard`), dashboard (metric-tile grid).
- Spinners kept for button/inline busy states and load-more.

Verified light + dark via `make frontend-theme-preview` (skeleton showcase at top).
Remaining candidate: operations/jobs kanban board (custom layout).

## 3. POS keyboard-first speed — ✅ Shipped

Modern hotkey scheme (chosen by the user):
- **Ctrl/⌘+Enter → checkout** anywhere on the POS. The cart pane publishes its
  checkout closure to a `PosCheckoutController`; the workspace `CallbackShortcuts`
  invokes it, so it runs the exact same flow (stock/loss guards, payment sheet)
  as the footer button.
- **Payment sheet**: `1/2/3` pick cash/card/transfer, `Enter` confirms, `Esc`
  cancels (`CallbackShortcuts` + autofocus; fires only when a text field isn't
  consuming the key, so editing a tender amount still works).
- **Focused cart line**: tap a line to focus it (highlighted) — `+`/`−` step the
  quantity, type digits to set an exact quantity (live banner, `Enter` applies,
  `Backspace` edits, `Esc` clears). Tapping a line blurs the barcode search, so
  plain typing keeps scanning. Modified combos bubble through; a structural cart
  change clears any half-typed quantity.

Verified: full analyze clean, no runtime errors, POS renders with no regression.
Note: Flutter-web preview can't inject canvas key events, so the key *behaviors*
are verified by construction + static analysis — worth a 2-minute manual smoke
test on a real terminal.

## 4. Bulk operations — ✅ Shipped (products)

Multi-select on the products list → bulk **archive/restore**, **re-price**,
**re-categorize**, and **toggle flags** (active / tracks-expiry / service /
prepared).

- **Backend** (`apps/catalog`): four `@action`s on `ProductViewSet` —
  `bulk-archive`, `bulk-reprice`, `bulk-categorize`, `bulk-set-flags` — each
  with a serializer, `transaction.atomic` + `select_for_update`, permission-
  gated (reprice/categorize/flags need `change_product`; archive also needs
  `delete_product`). Reprice supports set / ±% / ±amount on the default
  variant, rounded and clamped ≥ 0. Modelled on payroll `bulk_adjustments`.
  Django `check` passes; tests in `apps/catalog/tests.py`
  (`ProductBulkActionTests`) — couldn't run here (Docker/Postgres unavailable),
  run with `make backend-test` once the DB is up.
- **Frontend**: selection state in `CatalogViewModel` (`selectionMode`,
  `selectedIds`, toggle/select-all/clear, four `bulk*` methods that refetch on
  success); `PointyProductTable` shows per-row checkboxes in selection mode; a
  `_BulkSelectionBar` (count, select-all, action buttons) replaces the search
  bar; reprice/categorize/flags dialogs in `product_bulk_actions.dart`.
  Full `flutter analyze` clean.

Note: the catalog management screen has no preview harness (needs auth +
catalog data), so the bulk UI is verified by static analysis + established
patterns — worth a smoke test in the real app.

Deferred: purchasing-list bulk actions; invoices are append-only (bulk
print/export only) and out of scope for this pass.

## 5. First-run shop-setup wizard — ✅ Shipped

A one-time wizard shown right after the initial admin is created.

- **Backend** (`apps/core`): new `ShopSettings.shop_type` (+ migration 0016) with a
  `ShopType` enum and `SHOP_TYPE_PRESETS` (general / restaurant / grocery /
  pharmacy / phone-repair / bakery / retail). `apply_shop_type_preset()` flips
  feature defaults non-destructively. `POST /api/shop-settings/setup/`
  (`ShopSetupView` + `ShopSetupSerializer`) applies the preset then the user's
  explicit choices, records an audit event, returns the settings. Django `check`
  passes; tests in `core/tests.py::ShopSetupTests`.
- **Frontend**: `ShopSettingsRepository.setupShop()` (→ service → api client).
  `AuthViewModel.requiresShopSetup` flips on right after `createInitialAdmin`;
  `app.dart` shows `ShopSetupWizard` until `completeShopSetup()`. Two-step wizard
  (pick vertical → tune shop name / overselling / opening-cash / receipt-print,
  with a disabled LYD currency field hinting future multi-currency). Presets apply
  as **editable defaults** — everything stays changeable in Settings after.
  Verified in light + dark via `make frontend-shop-setup-preview`.

## 6. Optimistic-update consistency

Addressed in-place: bulk actions and the shop-setup flow refetch-on-success;
the POS cart stays fully optimistic; skeletons mask the remaining round-trips so
the app reads as fast as it is. No separate sweep needed.
