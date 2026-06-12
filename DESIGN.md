# Pointy Design Guide

This document is the design source of truth for the Pointy product experience.
It describes the visual system, interaction patterns, Arabic-first language
rules, responsive behavior, and feature-level guidance for the Flutter frontend.

The mockups in `ui/` are reference examples for the current cashier and catalog
direction, but this guide applies to the whole product: POS, catalog, inventory,
purchasing, payments, register sessions, contacts, discounts, dashboard,
reports, users, device settings, and shop settings.

## Product Direction

Pointy is an Arabic-first point-of-sale system for small and medium retail
operations. It should feel fast, practical, trustworthy, and calm under pressure.
The product is not a marketing site; it is a daily work tool for cashiers,
owners, managers, and operators.

Design for:

- Fast checkout and low-friction repeated use.
- Clear product recognition through names, barcodes, prices, and images.
- Dense but readable operational screens.
- Strong Arabic and RTL behavior by default.
- Clear totals, statuses, permissions, and irreversible actions.
- Workflows that recover well from scanning errors, network failures, and
  partial data.

Avoid:

- Decorative layouts that reduce scanability.
- Large hero sections inside the app.
- Hidden critical actions.
- Hardcoded visible copy in widgets.
- Tax UI unless tax support is explicitly requested.

## Core Principles

### Cashier First

Checkout workflows should minimize thinking and typing. Search, barcode scan,
product selection, cart editing, discounts, payment, and receipt actions should
all be reachable with large tap targets and obvious feedback.

### Arabic First

Arabic is the primary product language. The UI must read naturally in Arabic,
not feel like an English layout with translated labels inserted afterward.

### Dense, Not Crowded

Pointy screens should show enough operational information to avoid excessive
navigation. Density is good when spacing, hierarchy, and alignment remain clear.

### State Is Visible

Loading, empty, error, disabled, offline, permission-limited, low-stock,
unsynced, and completed states should be represented clearly in Arabic.

### Stable Layout

Frequent workflows must not jump around. Product cards, keypads, cart rows,
table rows, filter bars, and bottom CTAs should keep stable dimensions across
state changes.

## Language And Localization

- All user-facing Flutter text must be Arabic unless the user explicitly asks
  for another language.
- Add copy to `frontend/lib/l10n/app_ar.arb` and read it through
  `AppLocalizations`.
- Do not hardcode visible widget text, including placeholders, labels, tooltips,
  snackbars, errors, empty states, button labels, and menu items.
- After changing localization files, run `flutter gen-l10n` from `frontend/`.
- Preserve RTL behavior with semantic `leading` and `trailing` positioning.
- Avoid layout assumptions that only work in LTR.
- Currency appears as `ر.س` in current designs. Keep precision and spacing
  consistent across products, totals, payments, reports, and receipts.
- Numeric entry may use western digits where it improves cashier speed, but
  labels and surrounding UI remain Arabic.

Common Arabic terms:

| Concept | Preferred Copy |
| --- | --- |
| Point of sale | `نقطة البيع` |
| Products | `المنتجات` |
| Catalog | `الكتالوج` or `المنتجات` depending context |
| Cart | `السلة` |
| Complete sale | `إتمام البيع` |
| Payment | `الدفع` |
| Confirm payment | `تأكيد الدفع` |
| Amount due | `المبلغ المستحق` |
| Amount paid | `المبلغ المدفوع` |
| Remaining/change | `الباقي` |
| Discount | `خصم` |
| Search placeholder | `بحث عن منتج أو باركود` |
| Scan | `مسح` |
| Filter | `تصفية` |
| Sort | `ترتيب` |
| Add product | `إضافة منتج` |
| Save | `حفظ` |
| Cancel | `إلغاء` |
| Delete/remove | `حذف` |
| Empty cart | `تفريغ السلة` |
| Available | `متوفر` |
| Low stock | `منخفض` |

## Information Architecture

Pointy is organized around operational domains:

- POS: sell products, manage cart, apply discounts, take payment, issue receipt.
- Catalog: manage products, variants, categories, barcodes, prices, and images.
- Inventory: inspect stock, stock movements, receiving, adjustments.
- Purchasing: suppliers, purchase orders, receiving, cost history.
- Payments: tender methods, split tender, refunds, settlement visibility.
- Register sessions: open/close drawer, pay in/out, session history.
- Contacts: customers and suppliers.
- Discounts: rules, eligibility, usage, active/inactive states.
- Dashboard: operational overview, alerts, trends, and recent activity.
- Reports: printable/exportable business summaries and audit-friendly detail.
- Users and permissions: roles, access, authorization feedback.
- Device settings: printers, scanners, local device behavior.
- Shop settings: store profile and business-level configuration.

Navigation should make POS the fastest path while keeping management workflows
discoverable through the existing app drawer and feature destinations.

## Visual System

### Color

Use a light operational palette with green as the primary action color, amber as
the payment/receipt accent, and clear danger/warning/success states.

| Token | Suggested Value | Usage |
| --- | --- | --- |
| `primary` | `#0F766E` | Main CTAs, selected filters, positive emphasis. |
| `primaryStrong` | `#006C53` | Pressed/strong CTA states. |
| `primaryDark` | `#064E3B` | Dark green depth and gradients. |
| `darkTopBar` | `#0B111C` | POS and high-focus app bars. |
| `accentAmber` | `#C98A3B` | Payment method, receipt, highlighted tender states. |
| `danger` | `#B42318` | Delete, clear, destructive actions, errors. |
| `warning` | `#B65F2A` | Low stock and caution states. |
| `success` | `#0E6B4E` | Available, completed, successful states. |
| `ink` | `#101828` | Primary text. |
| `mutedInk` | `#667085` | Secondary labels and metadata. |
| `line` | `#E5E0D8` | Borders and dividers. |
| `lineStrong` | `#D5CFC4` | Emphasized hairlines and stronger separation. |
| `surface` | `#FFFFFF` | Cards, sheets, inputs, dialogs. |
| `surfaceSunken` | `#F1EFEA` | Recessed wells and grouped backgrounds. |
| `page` | `#F8F7F4` | App background. |

Avoid one-note palettes. Green is the brand/action color, but the app should be
balanced by neutral surfaces, product imagery, amber payment accents, and
distinct warning/danger states.

### Typography

The app typeface is **IBM Plex Sans Arabic**, bundled in
`frontend/assets/fonts/` (weights 400/500/600/700) and applied globally through
`PointyTypography` in `frontend/lib/src/shared/design/pointy_typography.dart`.
Rules the type ramp already enforces — do not undo them locally:

- `letterSpacing: 0` everywhere. Positive tracking visually breaks connected
  Arabic script; never add letter spacing to Arabic text.
- Line height ~1.5 for body/label styles and ~1.3 for titles so Arabic
  ascenders and diacritics do not clip. Avoid hard-coded tight `height` values
  in fixed-height rows.
- Amounts, quantities, and barcodes use tabular figures via
  `PointyTypography.numeric(style)` so digits align in columns and do not
  jitter when values change.

Typography should prioritize legibility and numeric clarity.

| Role | Approx Size | Weight | Usage |
| --- | ---: | ---: | --- |
| Screen title | 28-34 | 700 | Main app bars and page titles. |
| Section title | 22-26 | 700 | Cart, summary, form sections. |
| Card title | 18-22 | 600 | Product cards and repeated items. |
| Body | 16-18 | 400-500 | Rows, labels, descriptions. |
| Button label | 18-22 | 600-700 | Primary actions. |
| Large amount | 44-58 | 500-700 | Payment amount and key totals. |
| Metadata | 13-15 | 400 | Barcode, stock count, helper text. |

Do not scale font size directly from viewport width. Use responsive layout,
line limits, and overflow behavior instead.

### Spacing, Shape, And Elevation

- Base spacing unit: 8 px.
- Standard screen padding on mobile: 16-24 px.
- Dense row gap: 8-12 px.
- Section gap: 20-24 px.
- Product grid gap: 12-16 px.
- Cards: 8 px radius unless existing components require otherwise.
- Inputs and segmented controls: 8-12 px radius.
- Bottom sheets: rounded top corners around 24-28 px and a drag handle.
- Icon buttons: at least 48 x 48 px tap target.
- Primary CTA: 64-80 px height depending screen density.
- Elevation should be subtle. Raised surfaces keep their 1 px `line` border
  and add `PointyShadows.raised` (a whisper-soft two-layer ink shadow);
  floating overlays (dialogs, side panels, menus) use `PointyShadows.overlay`.
  Both live in `frontend/lib/src/shared/design/pointy_elevations.dart`. Never
  invent ad-hoc `BoxShadow` values.
- Motion uses `PointyMotion` tokens (`fast` 150 ms, `standard` 200 ms,
  `emphasized` 250 ms, `easeOutCubic`). Transitions confirm state changes;
  they never decorate. Do not hard-code durations.
- Hover, focus, and pressed feedback comes from the theme
  (`PointyComponentStyles.inkOverlay` / `onPrimaryOverlay`). Desktop POS
  terminals have mice — interactive surfaces must respond to hover.

Cards are for repeated items, modals, and genuinely framed tools. Do not nest
cards inside cards.

### Icons

Use Flutter Material icons consistently unless a project-wide icon system is
introduced.

Recommended mappings:

- Navigation menu: `Icons.menu`
- Search: `Icons.search`
- Barcode/scanner: `Icons.document_scanner_outlined`
- Filter: `Icons.filter_alt_outlined`
- Sort: `Icons.sort`
- Cart/bag: `Icons.shopping_bag_outlined`
- Add: `Icons.add`
- Edit: `Icons.edit_outlined`
- Delete: `Icons.delete_outline`
- Discount: `Icons.local_offer_outlined`
- Payment card: `Icons.credit_card`
- Cash: `Icons.payments_outlined`
- Wallet: `Icons.account_balance_wallet_outlined`
- Receipt: `Icons.receipt_long_outlined`
- Print: `Icons.print_outlined`
- Reports: `Icons.summarize_outlined`
- Settings: `Icons.settings_outlined`

Every icon-only button needs an Arabic tooltip from localization.

### Imagery

Use product images when they help recognition. Images should be clear, centered,
and object-focused. Do not crop important product shapes. If an image is
missing, use a simple localized placeholder that does not look broken.

## Layout And Responsiveness

Pointy should work on phones, tablets, desktop web, and POS terminals.

### Master-Detail And Form Surfaces

Two conventions govern how management screens use wide viewports:

- **Master-detail**: list screens (catalog, invoices, contacts, discounts,
  register sessions) use `MasterDetailLayout` from
  `frontend/lib/src/shared/responsive/master_detail_layout.dart`. At content
  widths >= `AppBreakpoints.masterDetailMin` (900 px of *pane* width, not
  viewport), the list becomes a fixed-width leading pane and the detail
  renders inline; below that, row taps keep their push navigation. Selection
  state lives in the screen, never in the primitive. Detail panes get a
  `ValueKey` per selection so the swap animation runs.
- **Forms vs pickers**: create/edit forms open through
  `showAdaptiveFormSurface` (bottom sheet below desktop width, centered
  dialog or end-anchored side panel at desktop). Transient pickers, filter
  sheets, and informational detail sheets stay on
  `showAdaptiveModalBottomSheet`. If it has a save button, it is a form.

Suggested breakpoints:

- Compact under 600 px: single-column mobile flows.
- Medium 600-959 px: denser grids and larger work areas.
- Expanded 960 px and up: side-by-side operational panes where useful.
- Large 1280 px and up: increase useful columns, not card stretch.

Rules:

- Preserve `SafeArea` around app bars, bottom CTAs, and sheets.
- Use semantic leading/trailing placement.
- Keep product cards, keypads, totals, and cart rows stable.
- Avoid text overlap at every breakpoint.
- Use constrained widths for forms and reports on wide screens.
- Keep sticky bottom actions visible without hiding required fields.
- During responsive QA, check the concrete viewport widths `390`, `430`,
  `768`, `1024`, and `1366` px.

## Shared Components And Patterns

### Modern Shared Surfaces

Prefer the shared Pointy widgets before adding a feature-local card, row, dialog,
or scaffold wrapper.

Use:

- `PointyScaffold` for top-level app screens so safe-area and background
  handling stay consistent.
- `PointyAppBar` for standard app bars with stable loading slots and localized
  icon-button tooltips.
- `PointyNavigationSurface` inside `AppNavigationDrawer`; preserve permission
  filtering and logout behavior there instead of duplicating drawer layouts.
- `PointyDetailSection` for titled card-like sections in detail, dashboard,
  settings, and report surfaces. Use its `minHeight` when a dashboard/report
  card needs stable chart space.
- `PointyDetailRow` for compact label/value rows inside detail sections.
- `PointyDataList` and `PointyDataRow` for reusable loading, error, empty,
  paginated, and action-row list states.
- `PointyMetricTile` for numeric summaries and dashboard/user activity
  metrics.
- `PointyMetricGrid` for responsive groups of `PointyMetricTile` summaries.
  Prefer it over feature-local width math.
- `PointyInlineMessage` for compact success, warning, and error feedback rows
  inside forms, panels, and dashboards.
- `PointySettingsSection` and `PointySettingsTile` for settings indexes and
  grouped configuration entry points.
- `PointyPermissionDeniedView` through authorization guards for blocked routes
  and permission-limited screens.
- `PointyDestructiveConfirmationDialog` for irreversible or high-impact
  confirmations.
- `PointyStickyActionFooter` for persistent save/checkout/submit actions.

Use `AdaptiveMaxWidth`, `AdaptiveSpacing`, `ResponsiveFormGrid`,
`ResponsiveActionBar`, `TwoPaneLayout`, and adaptive modal helpers instead of
feature-local width math whenever the layout is not inherently domain-specific.

### App Bars

Use dark app bars for high-focus cashier flows such as POS and payment. Use
lighter bars for management screens where table/list content is primary.

App bars should include:

- Centered Arabic title where possible.
- Semantic leading navigation/menu action.
- Semantic trailing operational actions.
- Tooltips for icon-only actions.
- No title shift when optional actions appear.

### Navigation Drawer

The drawer should remain the main cross-feature navigation pattern. It should:

- Highlight the active destination.
- Respect user permissions.
- Show unavailable destinations only when that helps explain access.
- Use Arabic labels from localization.
- Keep logout and account actions visually separate from work destinations.

### Search And Query Controls

Search is central to POS, catalog, contacts, purchasing, reports, and users.

Patterns:

- Large single-line input for primary search.
- Placeholder describes searchable fields, such as product name or barcode.
- Debounce text search.
- Pair search with scan/filter controls when relevant.
- Show active filters visibly and make them easy to clear.
- Keep loading, no-results, and error states localized.

### Filters, Sorts, And Chips

- Selected filters use primary fill or strong border.
- Unselected chips use neutral surfaces.
- Filter sheets should be localized, focused, and easy to apply/reset.
- Sort labels must state direction clearly when direction matters.
- Horizontal chip rows should scroll naturally in RTL.

### Lists And Tables

Management screens should favor scanable rows with consistent columns.

Rules:

- Use RTL semantic order.
- Put primary entity information at the semantic trailing side.
- Put row actions at the semantic leading side.
- Keep destructive actions visually distinct.
- Use status text plus color, never color alone.
- Support empty, loading, pagination, and error states.

### Product Cards

Product cards should support fast visual recognition.

Anatomy:

- Product image or placeholder.
- Product name.
- Price.
- Optional stock/status indicator when useful.

Behavior:

- POS tap adds product or opens variant picker.
- Catalog tap opens details or edit flow depending screen context.
- Disabled products retain layout and explain why they cannot be selected.

### Cart And Order Panels

Cart and order panels are operational summaries, not decorative cards.

Include:

- Item count.
- Clear/remove actions.
- Line item names, quantity controls, unit prices, and thumbnails where useful.
- Discount row if discounts are enabled.
- Total row with strong emphasis.
- Sticky checkout/payment CTA.

Totals must update immediately after cart mutations.

### Payment Controls

Payment screens should be focused and resilient.

Patterns:

- Show immutable order summary.
- Show amount due prominently.
- Use segmented payment method selection.
- Show paid amount and remaining/change clearly.
- Use a stable keypad for cash entry.
- Use quick amount buttons for common denominations.
- Show receipt toggle without making it required for payment validity.
- Disable confirmation when tender is invalid or incomplete.

### Forms

Forms should be compact, clear, and forgiving.

Rules:

- Labels and placeholders are localized.
- Required fields are visually clear.
- Numeric fields use appropriate keyboards and formatters.
- Currency fields keep `ر.س` visible.
- Barcode fields should pair with scan actions where useful.
- Save buttons keep stable size during loading.
- Validation stays near the relevant field.
- Failed saves keep user input intact.

### Bottom Sheets And Dialogs

Use bottom sheets for mobile task flows such as add/edit product, filters,
variant picking, register cash movement, and session close. Use dialogs for
small confirmations and destructive decisions.

Rules:

- Bottom sheets are scroll-controlled and safe-area-aware.
- Include a clear title and dismiss/cancel path.
- Trap focus while open and restore focus when closed.
- Avoid long mixed-responsibility sheets; split complex flows.

### Feedback

Use feedback consistently:

- Snackbars for transient operation results.
- Inline validation for form errors.
- Empty states for missing data.
- Retry actions for recoverable failures.
- Permission-denied views for blocked destinations.
- Progress indicators that do not resize controls.

## Feature Guidance

### POS

The POS screen is the highest-frequency workflow.

It should support:

- Product search by name, SKU, and barcode.
- Hardware and camera barcode scanning.
- Category filtering.
- Product grid with clear images and prices.
- Fast cart quantity changes.
- Discount entry or selection.
- Total review.
- Sticky `إتمام البيع` action.
- Register-session gating when no drawer is open.

### Catalog And Inventory

Catalog screens should make product maintenance fast without feeling like a
spreadsheet clone on small screens.

They should support:

- Search, scan lookup, filters, and sort.
- Product/variant details.
- Category assignment.
- Price and barcode editing.
- Stock state visibility.
- Stock movement history where relevant.
- Low-stock and unavailable states.
- Add/edit forms in localized bottom sheets or focused pages.

Do not hide stock-critical information behind images only.

### Purchasing

Purchasing workflows should make supplier, cost, receiving, and margin impact
clear.

They should support:

- Supplier selection.
- Variant-first product picking.
- Quantity and cost entry.
- Receiving state.
- Last-cost and cost-history visibility.
- Clear status labels for draft, ordered, partially received, received, and
  canceled states.

### Register Sessions

Register-session screens should emphasize accountability.

They should support:

- Opening cash amount.
- Active session indicator.
- Pay in/pay out flows.
- Closing cash counts.
- Variance visibility.
- Session history and related orders.
- Permission-aware actions.

### Payments And Refunds

Payment workflows should make tender state impossible to misunderstand.

They should support:

- Cash, card, wallet, and split tender when available.
- Amount due, paid, remaining, and change.
- Receipt and print state.
- Failure handling without losing the sale.
- Refund flows with clear original order context and authorization checks.

### Contacts

Contacts include customers and suppliers.

They should support:

- Searchable lists.
- Contact type/status.
- Balance or recent activity when relevant.
- Quick selection from sale/purchase flows.
- Detail screens for deeper management.

### Discounts

Discount screens should distinguish rule setup from sale-time application.

They should support:

- Active/inactive state.
- Scope and eligibility.
- Value type and amount.
- Usage visibility.
- Clear errors for invalid combinations.

### Dashboard

The dashboard should be an operational overview, not a decorative landing page.

It should prioritize:

- Net sales and order count.
- Payment mix.
- Register status.
- Low stock and inventory alerts.
- Recent orders or exceptions.
- Time range controls.

Use charts sparingly and make the numbers scannable first.

### Reports

Reports should be printable, exportable, and audit-friendly.

They should support:

- Date range selection.
- Report type and granularity.
- Preview before print/export.
- Arabic PDF output.
- Prepared-by and audit trail options where relevant.
- Clear loading and generation-failure states.

### Users, Permissions, And Settings

Admin screens should feel quieter than cashier screens.

They should support:

- Role and permission visibility.
- Clear disabled states for unauthorized actions.
- Device setup for printers/scanners.
- Shop settings with validation and confirmation where changes affect sales.

## Data And State Behavior

### Loading

Prefer skeletons or progress indicators that preserve layout. Do not make
primary actions jump when loading starts.

### Empty States

Empty states should explain what is missing and provide the next useful action
when one exists.

Examples:

- No products found: clear search or adjust filters.
- Empty cart: add products by search, scan, or category.
- No reports: choose a different period or report type.

### Errors

Errors should be Arabic, specific where possible, and recoverable.

Use:

- Inline errors for field validation.
- Snackbars for failed transient actions.
- Full-state errors for failed initial page loads.
- Retry actions for network or server failures.

### Permissions

Permission-limited UI should avoid dead ends.

- Hide actions when the user should not know they exist.
- Disable with explanation when the action is visible for context.
- Use localized access-denied views for blocked destinations.

### Destructive Actions

Destructive actions include deleting, clearing cart, canceling orders,
discarding form changes, and closing sessions with variance.

Rules:

- Use danger color and clear Arabic copy.
- Confirm irreversible or high-impact actions.
- Keep non-destructive alternatives visible.

## Accessibility

- Minimum tap target: 48 x 48 px.
- Provide semantic labels/tooltips for icon-only buttons.
- Keep text contrast strong.
- Do not communicate state with color alone.
- Respect text scaling without overlap.
- Keep focus order consistent with RTL visual order.
- Keypad buttons need clear screen-reader labels.
- Product images should have semantic fallback through product names.
- Bottom sheets and dialogs should manage focus correctly.

## Implementation Notes

- Follow the existing MVVM-style shape: services, repositories, view models,
  then views.
- Reuse shared widgets before creating new ones.
- Keep widgets small and purposeful.
- Extract reusable components when a screen starts mixing multiple concepts.
- Keep feature code inside the relevant domain under `frontend/lib/src/features`.
- Shared controls belong under `frontend/lib/src/shared`.
- Add Arabic strings to `frontend/lib/l10n/app_ar.arb`.
- After localization changes, run `flutter gen-l10n` from `frontend/`.
- After meaningful frontend changes, run:
  - `dart format lib test`
  - `flutter analyze`
  - `flutter test`
- Prefer root `make` targets for common workflows.

Useful existing areas:

- `frontend/lib/src/shared/query_controls/`
- `frontend/lib/src/shared/product_query_controls.dart`
- `frontend/lib/src/shared/product_tile.dart`
- `frontend/lib/src/shared/order_line_tile.dart`
- `frontend/lib/src/features/pos/`
- `frontend/lib/src/features/catalog/`
- `frontend/lib/src/features/reports/`

## Design QA Checklist

Use this checklist before considering a UI change complete.

- Visible copy is Arabic and comes from `AppLocalizations`.
- RTL layout uses semantic leading/trailing.
- Text does not overlap or overflow awkwardly at `390`, `430`, `768`, `1024`,
  and `1366` px widths.
- Primary workflow actions are visible and large enough to tap.
- Loading, empty, error, disabled, and permission states are handled.
- Destructive actions are visually distinct and confirmed when appropriate.
- Product, cart, payment, table, and form layouts keep stable dimensions.
- Statuses include text, not color alone.
- No tax UI was added unless explicitly requested.
- The screen works with realistic data lengths, missing images, and slow API
  responses.
- Meaningful frontend changes have been formatted, analyzed, and tested.
