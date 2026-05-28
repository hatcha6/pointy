# Modern Design Migration Plan

This plan turns the existing Pointy Flutter frontend into the modern Arabic-first
experience shown in `ui/pos.png`, `ui/catalog.png`, and `ui/payment.png`, while
preserving current workflows and using the responsive foundation in
`frontend/lib/src/shared/responsive/`.

`DESIGN.md` remains the design source of truth. This document is the phased
implementation checklist for applying it safely across the app.

## Goals

- Preserve current POS, catalog, payment, register-session, reporting,
  purchasing, contacts, discounts, users, and settings functionality.
- Move the visual language toward the mockups: calm light surfaces, dark
  cashier/payment headers, strong green primary actions, amber payment accents,
  clear product imagery, compact RTL rows, and rounded bottom sheets.
- Standardize responsive behavior through `AppBreakpoints`, `AdaptiveSpacing`,
  `AdaptiveMaxWidth`, `TwoPaneLayout`, `ResponsiveActionBar`,
  `ResponsiveFormGrid`, and `showAdaptiveModalBottomSheet`.
- Extract reusable widgets and classes before screen-by-screen polish so the
  migration reduces duplication instead of repainting every screen manually.
- Keep all user-facing copy localized in `frontend/lib/l10n/app_ar.arb`.
- Keep the product tax-free unless tax support is explicitly requested later.

## Reference Inputs

- Mockups:
  - `ui/pos.png`: POS shell, product grid, categories, cart, sticky checkout.
  - `ui/catalog.png`: catalog list/table, search, filters, add-product sheet.
  - `ui/payment.png`: focused payment flow, method selection, amount entry,
    quick cash buttons, keypad, receipt toggle.
- Design guide: `DESIGN.md`.
- Responsive foundation:
  - `frontend/lib/src/shared/responsive/app_breakpoints.dart`
  - `frontend/lib/src/shared/responsive/adaptive_spacing.dart`
  - `frontend/lib/src/shared/responsive/adaptive_constraints.dart`
  - `frontend/lib/src/shared/responsive/two_pane_layout.dart`
  - `frontend/lib/src/shared/responsive/responsive_action_bar.dart`
  - `frontend/lib/src/shared/responsive/responsive_form_grid.dart`
  - `frontend/lib/src/shared/responsive/adaptive_modal.dart`
- Current high-impact code:
  - `frontend/lib/src/app.dart`
  - `frontend/lib/src/shared/app_navigation_drawer.dart`
  - `frontend/lib/src/shared/product_tile.dart`
  - `frontend/lib/src/shared/product_query_controls.dart`
  - `frontend/lib/src/features/pos/views/pos_screen.dart`
  - `frontend/lib/src/features/pos/views/pos_catalog_pane.dart`
  - `frontend/lib/src/features/pos/views/pos_cart_pane.dart`
  - `frontend/lib/src/features/catalog/views/catalog_screen.dart`
  - `frontend/lib/src/features/catalog/views/product_list.dart`

## Migration Rules

- Do not rewrite business logic for visual changes. Keep view models,
  repositories, services, authorization guards, analytics, and tests wired the
  same way unless a phase explicitly calls for a small extraction.
- Prefer shared widgets under `frontend/lib/src/shared/` when a pattern appears
  in more than one feature.
- Feature-specific composition stays inside `frontend/lib/src/features/<domain>`.
- Use semantic Flutter layout APIs such as `EdgeInsetsDirectional`,
  `AlignmentDirectional`, `leading`, and `trailing`.
- Any icon-only action needs an Arabic tooltip through `AppLocalizations`.
- Every phase should keep the app shippable at the end of the phase.
- Avoid large mixed-responsibility files. Split reusable UI, payment controls,
  cart panels, and form sections as soon as they become independent concepts.

## Proposed Shared Structure

The exact filenames can change during implementation, but the migration should
aim for this shape:

```text
frontend/lib/src/shared/design/
  pointy_colors.dart
  pointy_theme.dart
  pointy_theme_extensions.dart
  pointy_component_styles.dart

frontend/lib/src/shared/shell/
  pointy_scaffold.dart
  pointy_app_bar.dart
  pointy_screen_header.dart
  pointy_navigation_surface.dart

frontend/lib/src/shared/components/
  pointy_empty_state.dart
  pointy_error_state.dart
  pointy_loading_area.dart
  pointy_status_pill.dart
  pointy_section_header.dart
  pointy_metric_tile.dart
  pointy_segmented_choice.dart
  pointy_keypad.dart
  pointy_amount_display.dart
  pointy_quantity_stepper.dart

frontend/lib/src/shared/catalog/
  pointy_product_card.dart
  pointy_product_table.dart
  pointy_product_image_frame.dart
  pointy_category_strip.dart

frontend/lib/src/shared/order/
  pointy_order_panel.dart
  pointy_order_line_tile.dart
  pointy_totals_panel.dart
  pointy_sticky_action_footer.dart
```

Keep existing shared widgets when they already fit the purpose. For example,
`ProductQueryControls`, `QueryControlBar`, `ProductImageThumbnail`,
`ProductStatusPill`, `OrderLineTile`, and `CartTotals` can be upgraded or
wrapped instead of replaced immediately.

## Phase 0 - Baseline And Guardrails

### Objective

Make the current behavior measurable before visual migration starts.

### Work

- Capture current routes, modals, and critical actions for:
  - POS register gate, catalog lookup, cart editing, discounts, checkout.
  - Payment dialog and split tender.
  - Catalog list, barcode lookup, product details, add/edit product.
  - Purchasing create flow, order list, receive/payment dialogs.
  - Register sessions, reports, contacts, discounts, users, settings.
- Record viewport targets for design QA:
  - Phone: 390 x 844.
  - Large phone: 430 x 932.
  - Tablet: 768 x 1024.
  - Desktop/POS: 1366 x 768.
- Identify strings that are still hardcoded in widgets and move them into
  `frontend/lib/l10n/app_ar.arb` before or during the phase that touches them.
- Add or update widget tests only where behavior is currently unprotected.
  Prioritize tests that use stable keys/tooltips instead of brittle layout
  assumptions.
- Decide whether visual regression will be handled with Flutter golden tests or
  manual screenshots during this migration. If using goldens, start with shared
  components rather than whole screens.

### Deliverables

- A route/screen inventory with owner phase noted in this document or a small
  follow-up checklist.
- A short list of missing behavior tests.
- Agreement that visual migration starts with POS, payment, and catalog because
  they match the mockups and carry the most repeated UI patterns.

### Acceptance Gate

- `flutter test` passes before UI work begins.
- Existing E2E pilot-day flow still describes the core checkout behavior that
  must remain intact.

## Phase 1 - Design Tokens And Global Theme

### Objective

Create one modern Pointy theme so screens inherit the new look without
duplicating colors, shape, typography, and component styles.

### Work

- Add `frontend/lib/src/shared/design/` with:
  - Color tokens for primary green, dark top bar, amber accent, danger,
    warning, success, page, surface, line, ink, and muted ink.
  - `ThemeExtension` classes for app-specific semantic colors that do not fit
    cleanly into `ColorScheme`.
  - Reusable radii and component dimensions, keeping card radius around 8 px.
  - Button, input, chip, icon button, bottom sheet, dialog, navigation drawer,
    and app bar theme helpers.
- Update `PointyApp` in `frontend/lib/src/app.dart` to use the new theme.
- Keep spacing responsive by consuming `AdaptiveSpacing`; do not create a second
  spacing system that conflicts with it.
- Add small theme tests for token availability and basic component style
  expectations if practical.

### Reusable Widgets/Classes

- `PointyTheme`
- `PointyColors`
- `PointySemanticColors`
- `PointyComponentStyles`

### Acceptance Gate

- Existing screens compile and remain usable with the new theme.
- No visible copy is introduced outside localization.
- `dart format lib test`, `flutter analyze`, and `flutter test` pass from
  `frontend/`.

## Phase 2 - Shell, Layout, And State Components

### Objective

Create reusable app scaffolding and state surfaces before migrating individual
screens.

### Work

- Introduce a shared scaffold wrapper for feature screens:
  - Drawer wiring remains permission-aware through `AppNavigationDrawer`.
  - High-focus screens can request a dark header style.
  - Management screens can request a light dense header style.
  - Title, leading, trailing actions, loading indicator, and active register
    chip remain stable when optional actions appear.
- Introduce reusable state components:
  - Empty state with icon, title/body, and optional action.
  - Error state with retry action.
  - Loading area/skeleton that preserves layout dimensions.
  - Section header and metric/summary tile.
- Upgrade modal usage to `showAdaptiveModalBottomSheet` where screens already
  use custom constrained bottom sheets.
- Standardize sticky action footers for save, checkout, payment, and report
  actions.
- Add responsive widget tests for the new shell and state components at phone,
  tablet, and wide POS widths.

### Reusable Widgets/Classes

- `PointyScaffold`
- `PointyAppBar`
- `PointyScreenHeader`
- `PointyEmptyState`
- `PointyErrorState`
- `PointyLoadingArea`
- `PointySectionHeader`
- `PointyStickyActionFooter`

### Acceptance Gate

- POS and catalog can opt into the shared shell without losing drawer actions,
  authorization behavior, analytics, or register controls.
- Modal sheets use responsive max-width/height behavior consistently.
- Responsive tests cover shell breakpoints.

## Phase 3 - POS Workspace Redesign

### Objective

Apply the mockup-inspired POS design to the highest-frequency cashier workflow
while keeping barcode scanning, cart behavior, discounts, and checkout intact.

### Work

- Keep `PosScreen` as the route owner but split presentation into focused
  widgets:
  - POS app bar/header.
  - Product lookup controls.
  - Category/filter strip.
  - Product grid.
  - Cart/order panel.
  - Sticky checkout footer.
- Continue using `TwoPaneLayout`:
  - Phone and large-phone widths stack catalog and cart in a stable order.
  - Tablet and desktop widths show catalog and cart side by side.
  - Wide POS widths use `AppPaneWidths.trailingPaneForWidth` for the cart.
- Upgrade product cards toward `ui/pos.png`:
  - Larger image area.
  - Clear product name and price.
  - Stable fixed extent.
  - Missing image fallback that still feels intentional.
- Upgrade cart rows:
  - Thumbnail, name, unit price, quantity stepper, remove action.
  - Stable row height and RTL order.
  - Distinct clear-cart danger action.
- Replace local hardcoded spacing with `AdaptiveSpacing.of(context)`.
- Keep barcode scan status, coupon field, customer selection, discount preview,
  oversell warning, invoice print toggle, and checkout error handling.

### Reusable Widgets/Classes

- `PointyProductCard`
- `PointyCategoryStrip`
- `PointyOrderPanel`
- `PointyOrderLineTile`
- `PointyQuantityStepper`
- `PointyTotalsPanel`
- `PointyStickyActionFooter`

### Acceptance Gate

- Existing POS widget tests still pass, including barcode scanning, split
  tender, oversell warning, invoice printing, and register-session behavior.
- Manual QA at phone, tablet, and 1366 px confirms no overlap in product cards,
  cart rows, totals, coupon errors, or checkout CTA.
- The POS screen remains usable with empty catalog, loading catalog, failed
  catalog, long Arabic product names, missing images, and disabled checkout.

## Phase 4 - Payment Flow Redesign

### Objective

Replace the current generic payment dialog with a focused adaptive payment
experience inspired by `ui/payment.png`.

### Work

- Extract payment UI out of `pos_cart_pane.dart` into dedicated files under
  `frontend/lib/src/features/pos/views/payment/`.
- Use an adaptive modal:
  - Full-height bottom sheet on phone.
  - Constrained centered dialog or side panel on tablet/desktop.
- Preserve the existing `SplitTenderPaymentCalculator` and checkout submission
  contract.
- Add payment method segmented controls for cash, card, wallet/transfer, and
  split tender when enabled.
- Add amount due, paid, remaining/change displays using a reusable amount
  component.
- Add quick cash amount buttons and numeric keypad for cash entry.
- Keep split tender add/remove/rebalance behavior.
- Keep receipt/print preference visible but not required for payment validity.
- Disable confirm when no method is enabled or tender is incomplete.

### Reusable Widgets/Classes

- `PaymentSheet`
- `PaymentMethodSegmentedControl`
- `PointyAmountDisplay`
- `PointyKeypad`
- `QuickAmountBar`
- `TenderLineEditor`
- `ReceiptToggleRow`

### Acceptance Gate

- Existing split-tender tests pass.
- Add focused widget tests for keypad entry, quick amount buttons, disabled
  confirm state, receipt toggle, and payment method availability.
- Manual QA confirms the payment sheet fits at 390 x 844 and 1366 x 768 without
  hidden confirmation actions.

## Phase 5 - Catalog And Product Management Redesign

### Objective

Move catalog management toward `ui/catalog.png`: scanable product table/list,
prominent search/scan/filter controls, and a modern add/edit product sheet.

### Work

- Keep `CatalogScreen` route behavior, authorization guards, barcode lookup,
  product detail navigation, image search, stock movement, and label printing.
- Replace the floating action button with a header or action-bar button where it
  matches the mockup, while keeping phone usability.
- Use `ResponsiveActionBar` for search/scan/filter/add actions.
- Introduce a shared product table/list that adapts:
  - Phone: compact card/row list.
  - Tablet/desktop: table-like rows with product, stock, price, barcode, edit.
- Keep product image thumbnails in rows and preserve text status alongside
  status color.
- Convert product add/edit modals to `showAdaptiveModalBottomSheet`.
- Use `ResponsiveFormGrid` in product forms for name/category/price/stock/
  barcode fields.
- Extract shared form sections for identity, pricing, barcode, image, variants,
  and stock behavior.

### Reusable Widgets/Classes

- `PointyProductTable`
- `PointyProductRow`
- `PointyProductImageFrame`
- `ProductFormSection`
- `BarcodeInputRow`
- `StockStatusLabel`

### Acceptance Gate

- Catalog widget tests still pass for search, filters, barcode lookup, product
  creation, details, stock movement, image search, and label count prompts.
- Manual QA confirms rows remain readable with long product names, long
  barcodes, low stock, unavailable products, and missing images.
- No catalog management string is hardcoded in widgets.

## Phase 6 - Purchasing, Register Sessions, Contacts, Discounts, And Reports

### Objective

Apply the same reusable management patterns to the rest of the operational
screens without changing their domain workflows.

### Work

- Migrate each screen group one at a time:
  - Purchasing order list, create purchase, receive dialogs, supplier payment.
  - Register session history, session orders, close-session sheets.
  - Contacts list/details and contact picker sheets.
  - Discount rules list and form.
  - Reports filters, report preview actions, export/print feedback.
- Reuse the shared shell, action bars, product table/list, form grid, status
  pills, empty/error/loading states, and adaptive modals.
- Keep rows dense and operational rather than decorative.
- Use `AdaptiveMaxWidth` for details, reports, settings, and forms on wide
  screens.
- Preserve permission-specific hiding/disabling behavior.

### Reusable Widgets/Classes

- `PointyDataList`
- `PointyDataRow`
- `PointyDetailSection`
- `PointyStatusPill`
- `PointyMetricTile`
- `PointyFilterSummaryBar`

### Acceptance Gate

- Existing widget tests for purchasing, sessions, contacts, discounts, reports,
  and permissions pass.
- Each migrated screen has loading, empty, error, unauthorized, and long-text
  behavior checked at phone and desktop widths.

## Phase 7 - Dashboard, Settings, Users, And Navigation Polish

### Objective

Finish the lower-frequency screens and make the whole app feel coherent.

### Work

- Apply the shared shell and theme to dashboard, users, device settings, shop
  settings, and login/auth surfaces.
- Keep dashboard operational and number-first, not a decorative landing page.
- Tune `AppNavigationDrawer` styling to match the new theme while preserving
  destination filtering and logout behavior.
- Standardize destructive confirmations and permission-denied views.
- Review all icon-only buttons for localized tooltips.
- Audit page backgrounds, borders, chip states, input states, and button
  hierarchy for consistency.

### Reusable Widgets/Classes

- `PointyNavigationSurface`
- `PointyPermissionDeniedView`
- `PointyDestructiveConfirmationDialog`
- `PointySettingsSection`

### Acceptance Gate

- Manager and cashier navigation tests pass.
- Login, dashboard, settings, users, and permission-denied states are visually
  aligned with the rest of the app.

## Phase 8 - Final QA, Cleanup, And Documentation

### Objective

Remove migration leftovers and make the design system sustainable.

### Work

- Delete dead widgets, obsolete private helpers, duplicate style constants, and
  unused imports.
- Consolidate duplicate strings in `app_ar.arb`.
- Update `DESIGN.md` only if implementation discovered new reusable conventions
  that should become source-of-truth guidance.
- Update `README.md` or `Makefile` only if new design QA, golden, or screenshot
  commands are added.
- Run the full quality gates.
- Do a final responsive QA pass on:
  - POS.
  - Payment.
  - Catalog.
  - Purchasing.
  - Register sessions.
  - Reports.
  - Settings/users.

### Acceptance Gate

- From `frontend/`:
  - `flutter gen-l10n` if localization changed.
  - `dart format lib test`
  - `flutter analyze`
  - `flutter test`
- From the repo root when backend was untouched:
  - `make frontend-test`
  - `make frontend-analyze`
- From the repo root for final release confidence:
  - `make check`
  - `make test`
  - `make e2e` when the environment supports it.

## Reuse Checklist For Every Phase

Before creating a new widget, answer:

- Does a shared widget already exist under `frontend/lib/src/shared/`?
- Does the pattern appear in more than one feature?
- Can this be implemented by extending the theme or a `ThemeExtension` instead
  of passing colors around?
- Can the layout be expressed with the responsive foundation instead of local
  width math?
- Is this truly domain-specific enough to stay in `features/<domain>/views/`?
- Are all labels, placeholders, tooltips, snackbars, errors, and empty states
  localized?
- Does the widget preserve RTL order and semantic leading/trailing behavior?

## Screen Migration Checklist

Use this checklist before closing any screen migration:

- The screen preserves its old behavior and route wiring.
- Authorization guards still hide or disable the same actions.
- Analytics events still fire for the same critical user interactions.
- Loading, empty, error, disabled, unauthorized, and success states are present.
- Product images, thumbnails, and fallback states render correctly.
- Long Arabic labels and product names do not overlap controls.
- Buttons and icon buttons keep at least 48 x 48 px tap targets.
- Sticky footers do not hide required fields or totals.
- The screen works at 390, 430, 768, 1024, and 1366 px wide.
- No tax field, tax total, or tax copy was added.
- Tests were added or updated where behavior changed.

## Suggested Implementation Order Within Each Phase

1. Extract or introduce the reusable component first.
2. Add a small focused widget test for the component when it has behavior or
   responsive branching.
3. Migrate one screen to the component.
4. Run the relevant focused tests.
5. Migrate sibling screens only after the first screen proves the API feels
   right.
6. Remove the old local helper after all call sites move.
7. Run format, analyze, and tests for the frontend phase.

## Risks And Mitigations

| Risk | Mitigation |
| --- | --- |
| Visual work breaks checkout behavior | Keep view models and repositories unchanged; rely on existing POS tests and pilot-day E2E. |
| The new design creates duplicate widgets | Extract shared components before migrating sibling screens; block phase completion if duplicate private widgets remain. |
| Responsive behavior diverges by screen | Route every layout decision through the shared responsive foundation or add a missing primitive there. |
| Arabic text overflows in dense controls | Test long Arabic labels and product names at phone and desktop widths; use stable dimensions and `TextOverflow.ellipsis` where appropriate. |
| Payment redesign changes tender math | Keep `SplitTenderPaymentCalculator` as the source of truth and add keypad/quick-amount tests around it. |
| Catalog table becomes hard to use on phone | Use adaptive row/card presentation instead of forcing desktop columns onto compact widths. |
| Theme changes cause broad visual regressions | Land tokens and component themes early, then migrate screens incrementally with focused screenshots. |

## Definition Of Done

The migration is complete when:

- POS, payment, and catalog visually align with the supplied mockups while
  keeping all current workflows.
- The remaining screens use the same shell, colors, typography, spacing,
  modals, state views, action bars, and responsive behavior.
- Shared components cover repeated patterns instead of duplicating layout and
  style in feature files.
- Arabic localization and RTL behavior are preserved throughout.
- The frontend passes formatting, analysis, tests, and the pilot-day E2E flow.
