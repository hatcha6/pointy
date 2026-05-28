# Modern Design Phase 0 Baseline

Date: 2026-05-28
Branch: `codex-modern-design-phase-0`

This document implements Phase 0 from `MODERN_DESIGN_MIGRATION_PLAN.md`.
It records the current app behavior that the modern design migration must
preserve before any visual refactor begins.

## Baseline Scope

Phase 0 does not redesign widgets. Its job is to make the existing product
surface explicit enough that later phases can change layout, theme, and shared
components without accidentally changing business workflows.

## Route And Destination Inventory

Routes are owned by `frontend/lib/src/authenticated_home.dart` and are guarded
with `AuthorizationCapabilities`.

| Screen key | Widget | Current entry behavior | Migration owner phase |
| --- | --- | --- | --- |
| `dashboard` | `DashboardScreen` | Manager default authenticated home. | Phase 7 |
| `pos` | `PosScreen` | Cashier default home, manager drawer destination. Reloads POS catalog after returning from catalog management. | Phase 3 |
| `catalog` | `CatalogScreen` | Drawer destination and POS management link. | Phase 5 |
| `categories` | `CategoryManagementScreen` | Catalog/category management destination. | Phase 5 |
| `purchase_orders` | `PurchaseOrderListScreen` | Purchasing drawer destination. Opens list and create/details flows. | Phase 6 |
| `purchase_create` | `PurchasingScreen` | Purchase order creation route with back button. | Phase 6 |
| `purchase_order_details` | `PurchaseOrderDetailsScreen` | Pushed from purchase order list. Reloads order list on return. | Phase 6 |
| `contacts` | `ContactManagementScreen` | Customer and supplier management destination. | Phase 6 |
| `register_sessions` | `RegisterSessionHistoryScreen` | Register session history, session orders, sale details. | Phase 6 |
| `discounts` | `DiscountManagementScreen` | Discount rule management destination. | Phase 6 |
| `reports` | `ReportsScreen` | Report generation, preview, print, and export destination. | Phase 6 |
| `device_settings` | `DeviceSettingsScreen` | Local device and printer settings destination. | Phase 7 |
| `users` | `UserManagementScreen` | Manager-only user management destination. | Phase 7 |
| `user_details` | `UserDetailsScreen` | Pushed from user management. | Phase 7 |
| `shop_settings` | `ShopSettingsScreen` | Manager-only shop settings destination; POS reloads checkout settings after return. | Phase 7 |
| `report_pdf_preview` | `ReportPdfPreviewScreen` | Pushed from reports after report generation succeeds. | Phase 6 |

Navigation behavior to preserve:

- Managers start at the dashboard when `canViewDashboard` is true.
- Cashiers without dashboard access start at POS.
- Drawer destinations remain permission-aware.
- `openDashboard` returns to the first route.
- `openPos` pops to first route for cashier-only users, pushes POS from the
  dashboard root for managers, and replaces nested management routes otherwise.
- Logout pops to the first route and calls `authViewModel.logout()`.
- Screen analytics continue to call `setCurrentScreen` and
  `frontendScreenViewed` with the screen key and role.

## Modal, Sheet, And Dialog Inventory

### Shared Workflows

| Workflow | Current surface | Source | Must preserve |
| --- | --- | --- | --- |
| Product query filters | Bottom sheet | `shared/product_query_controls.dart` | Search, ordering, category, availability filters where enabled. |
| Camera barcode scanning | Bottom sheet | `shared/barcode/camera_barcode_scanner_sheet.dart` | Single/multiple scan modes, quantity mode, lookup feedback. |
| Customer/supplier picker | Bottom sheets | `shared/contact_picker_sheet.dart` | Search, selection, quick-create customer/supplier. |
| Async multi-select | Bottom sheet | `shared/async_selection/async_multi_select_picker.dart` | Multi-selection and selected value return. |

### POS And Payment

| Workflow | Current surface | Source | Must preserve |
| --- | --- | --- | --- |
| Register session open gate | Inline POS gate | `pos/views/register_session_gate.dart` | Opening cash validation and optional blank opening cash. |
| Cash movement | Bottom sheet | `pos/views/pos_screen.dart`, `register_cash_movement_sheet.dart` | Pay in/pay out, amount validation, required reason, success snackbar. |
| Close register session | Bottom sheet | `pos/views/pos_screen.dart`, `register_session_close_sheet.dart` | Closing cash, denomination counts, submit/cancel states. |
| Variant selection during sale | Bottom sheet | `pos/views/pos_variant_picker_sheet.dart` | Choose variant before adding to cart. |
| Oversell warning | Dialog | `pos/views/pos_cart_pane.dart` | Continue only when overselling is allowed; block when rejected by backend. |
| Payment and split tender | Dialog | `pos/views/pos_cart_pane.dart` | Enabled payment methods, split tender add/remove, rebalance, paid/remaining/change totals, validation. |
| Invoice print preference | Inline checkout footer | `pos/views/pos_cart_pane.dart` | Auto-print setting and cashier-selected print invoice checkbox. |

### Catalog And Inventory

| Workflow | Current surface | Source | Must preserve |
| --- | --- | --- | --- |
| Add product | Bottom sheet | `catalog/views/catalog_screen.dart` | Multi-step product form and created callback. |
| Edit product | Bottom sheet | `catalog/views/product_details_screen.dart` | Product fields, save callback, details refresh. |
| Edit parent product | Bottom sheet | `catalog/views/product_details_screen.dart` | Parent product changes for variant products. |
| Stock movement | Bottom sheet | `catalog/views/product_details_screen.dart`, `stock_movement_form.dart` | Adjustment input, movement history refresh. |
| Add/edit variant | Bottom sheets | `product_variant_details_screen.dart`, `product_variant_form_sheet.dart` | Variant price, SKU/barcode, active state, option values. |
| Generate variants | Bottom sheet | `product_variant_generation_sheet.dart` | Option selection, generated combinations. |
| Product image search/import | Bottom sheet | `product_image_picker.dart` | Search paging, selection, upload/import behavior. |
| Variant option/value creation | Dialogs | `variant_option_creation_dialogs.dart` | Create option/value without losing the parent form state. |
| Barcode label copies | Dialog | `product_variant_details_screen.dart` | Copy count validation and print submission. |
| Category creation | Bottom sheet | `category_management_screen.dart` | Parent category context and lazy category tree refresh. |

### Purchasing

| Workflow | Current surface | Source | Must preserve |
| --- | --- | --- | --- |
| Purchase order filters | Bottom sheet | `purchase_order_query_controls.dart` | Search, status filters, reset/apply. |
| Quick product creation | Adaptive bottom sheet | `purchase_quick_product_sheet.dart` | Missing barcode product creation and variant return. |
| Supplier payment | Dialog | `purchase_order_supplier_payment_dialog.dart` | Amount/method/reference validation and action result. |
| Receive purchase order | Dialog | `purchase_order_receive_dialog.dart` | Receive quantities and result action. |
| Purchase adjustment | Dialog | `purchase_order_adjustment_dialogs.dart` | Return/damage inputs and stock failure handling. |
| Purchase exchange | Dialog | `purchase_order_adjustment_dialogs.dart` | Outbound and replacement line submission. |

### Register Sessions And Sales

| Workflow | Current surface | Source | Must preserve |
| --- | --- | --- | --- |
| Sale details | Bottom sheet | `register_sessions/views/sale_order_details_sheet.dart` | Sale summary, receipt reprint, void, returns/exchanges. |
| Void sale | Dialog | `sale_order_details_sheet.dart` | Reason input and confirmation. |
| Return sale | Dialog | `sale_order_details_sheet.dart` | Return quantities, replacement/refund handling. |

### Management, Reports, And Settings

| Workflow | Current surface | Source | Must preserve |
| --- | --- | --- | --- |
| Add/edit discount rule | Bottom sheets | `discount_management_screen.dart` | Create/edit form, catalog/contact selection, archive confirmation. |
| Discount rule filters | Bottom sheet | `discount_rule_query_controls.dart` | Query, filters, reset/apply. |
| Archive discount rule | Dialog | `discount_management_screen.dart` | Destructive confirmation. |
| Add user | Bottom sheet | `user_management_screen.dart` | User creation and role validation. |
| Report PDF preview | Route | `authenticated_home.dart`, `report_pdf_preview_screen.dart` | Generate before preview, print, share/export, error feedback. |
| Shop settings integer pickers | Dialogs | `shop_settings_screen.dart` | Numeric option selection and save behavior. |
| Printing settings panels | Nested routes | `shop_settings_screen.dart` | Printer and device configuration flows. |
| Contact detail routes | Routes | `contact_management_screen.dart`, `supplier_details_screen.dart` | Customer/supplier details and activity views. |

## Critical Behavior Guardrails

### POS

- Register-session gate blocks POS work until a session is active.
- Hardware scanner input adds matching variants when lookup field is not
  focused.
- Search field submission can add a product by barcode.
- Camera scanner supports quantity scanning.
- Product selection either adds directly, opens variant picker, or shows an
  unavailable/error message.
- Customer selection keeps checkout body customer-aware.
- Coupon code preview blocks checkout when preview fails or coupon is invalid.
- Oversell warning is shown before checkout when local stock is short.
- Backend stock rejection keeps cart intact.
- Checkout sends cart lines, selected customer, payments, and invoice print
  preference.
- Successful checkout clears cart and shows receipt/print feedback.

### Payment

- Payment method availability comes from shop settings.
- Split tender can add a second tender, rebalance the adjacent tender, and
  remove a tender without changing total math.
- Cash overpayment may produce change; non-cash overpayment is rejected by
  `SplitTenderPaymentCalculator`.
- Confirm is blocked when no payment method is enabled or paid amount is too
  low.

### Catalog And Inventory

- Catalog search/filter/order controls remain shared with POS query controls.
- Barcode lookup opens product details when found and shows localized failure
  feedback when not found.
- Add product keeps the multi-step form behavior.
- Product and variant edit flows refresh details/list data after save.
- Product image search can load additional pages while scrolling.
- Stock movement creation remains available from details.
- Barcode label printing asks for a copy count before printing.

### Purchasing

- Purchase list search/filter remains available.
- Create purchase order requires supplier selection before submission.
- Missing barcode in purchasing opens quick product creation.
- Purchase details support receive, supplier payment, return, damage, and
  exchange actions.
- Stock adjustment failures show clear Arabic feedback.

### Remaining Management Screens

- Drawer visibility stays role-aware for manager and cashier.
- Contacts preserve customer/supplier tabs and detail routes.
- Discounts preserve create/edit/archive flows.
- Reports preserve preview, print, export, progress locking, and error states.
- Register sessions preserve sale details, reprint, void, return, and load-more
  behavior.
- Shop settings, users, and device settings preserve validation and permission
  boundaries.

## Responsive QA Viewports

These are the required manual and automated design QA targets for the migration:

| Target | Size | Expected breakpoint |
| --- | --- | --- |
| Phone | 390 x 844 | `AppBreakpoint.phone` |
| Large phone | 430 x 932 | `AppBreakpoint.phone` |
| Tablet | 768 x 1024 | `AppBreakpoint.tablet` |
| Desktop | 1024 x 768 | `AppBreakpoint.desktop` |
| Wide POS | 1366 x 768 | `AppBreakpoint.widePos` |

`frontend/test/shared/responsive/responsive_test.dart` contains a guardrail test
for these target widths so the migration cannot silently move the baseline
breakpoint expectations.

## Localization Baseline

The visible-copy scan used this command:

```sh
rg -n "Text\('([^']*[A-Za-z\\u0600-\\u06FF][^']*)'|SnackBar\(content: Text\('([^']*)'|labelText: '([^']*)'|hintText: '([^']*)'|tooltip: '([^']*)'|title: Text\('([^']*)'" frontend/lib/src
```

Result: no obvious hardcoded visible Arabic or English copy was found. The
remaining matches were dynamic values such as quantities, formatted money,
stock counts, or composed labels. Later phases must still check touched files
manually because a regex cannot prove full localization coverage.

## Existing Test Coverage Map

Current tests already protect these migration-critical behaviors:

- Responsive primitives:
  - Breakpoint classification.
  - Form-grid column math.
  - Pane/modal sizing.
  - Two-pane stacking/splitting.
  - Responsive action bar compact behavior.
- POS and payment:
  - Checkout request body and cart clearing.
  - Customer selection.
  - Split tender add/rebalance/remove.
  - Auto-print and cashier-selected print invoice.
  - Checkout failure keeps cart.
  - Oversell warning.
  - Register-session gate.
  - Cash movement validation.
  - Hardware/scanner barcode behavior.
- Catalog:
  - Product creation form.
  - Category lazy paging.
  - Shared search/filter/order controls.
  - Barcode lookup.
  - Product and variant edit.
  - Stock movement.
  - Barcode label copy prompt.
  - Product image search paging.
- Purchasing:
  - Searchable order list and create flow.
  - Quick-create missing barcode product.
  - Details actions and supplier payment.
  - Exchange, return, damage, and stock-failure feedback.
- Management:
  - Drawer destinations and cashier hiding.
  - Contacts tabs/details.
  - Users.
  - Discounts.
  - Shop settings.
  - Reports action progress/error.
  - Register session history, linked sales, reprint, void, return, load more.

## Missing Or Thin Test Coverage Before Visual Refactor

These do not block Phase 1, but they should be considered when touching the
related surfaces:

- Payment UI layout is mostly covered through behavior tests, not focused widget
  tests for method selection, receipt toggle visibility, disabled confirmation,
  keypad, or quick amounts. Add these in Phase 4 when payment UI is extracted.
- POS layout at phone widths is not covered by a screen-level test. Add focused
  layout tests or screenshot QA when Phase 3 changes stacking and sticky
  actions.
- Catalog desktop table/list layout is not covered because it does not exist
  yet. Add adaptive row/card tests in Phase 5.
- Shared empty/error/loading components do not exist yet. Add component tests in
  Phase 2 when they are introduced.
- Manual screenshot QA is still needed for long Arabic product names, missing
  images, dense cart rows, and modal keyboard insets.

## Visual Regression Decision

Use manual screenshot QA for Phase 1 and Phase 2 while the shared theme and
shell are still moving. Do not start with whole-screen golden files because the
first phases intentionally change broad visual surfaces.

Start golden tests only for stable reusable components after they settle:

- `PointyProductCard`
- `PointyQuantityStepper`
- `PointyAmountDisplay`
- `PointyKeypad`
- `PointyEmptyState`
- `PointyStickyActionFooter`

Whole-screen goldens can be considered after POS, payment, and catalog have
finished their first redesign pass.

## Phase 0 Acceptance Status

- Route/screen inventory: complete.
- Modal/dialog/bottom-sheet inventory: complete.
- Critical behavior guardrails: complete.
- Responsive viewport targets: recorded and covered by a test.
- Localization baseline scan: complete.
- Missing behavior tests: documented.
- Visual regression decision: manual screenshot QA first, component goldens
  later.

## Validation Run

Commands run from `frontend/` on 2026-05-28:

- `dart format test/shared/responsive/responsive_test.dart`: passed.
- `flutter test test/shared/responsive/responsive_test.dart`: passed.
- `flutter test`: passed.
- `flutter analyze`: passed.
