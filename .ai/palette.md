# Palette's Journal 🎨

Critical UX/accessibility learnings for Pointy. Not a work log.

## 2026-08-18 - Auditing icon-only buttons has two shapes in this codebase

**Learning:** In Flutter, `IconButton(tooltip: ...)` sets both the hover/long-press
tooltip *and* the Semantics label — that's the a11y fix, not just polish. But this
repo uses two forms: most call sites pass `tooltip:` directly, while the navigation
rail/drawer (`app_navigation_drawer.dart`, `pointy_navigation_surface.dart`) wrap the
button in a `Tooltip(message: ...)` widget instead. A naive grep for missing `tooltip:`
flags those as gaps when they are already labelled.

**Action:** When auditing icon-only buttons, match `IconButton(` with balanced parens
and treat an enclosing `Tooltip(` as covered. Skip `lib/dev/*_preview.dart` — dev-only
harnesses that never ship. Reuse existing l10n keys before adding new ones: steppers
already have `addOneTooltip` / `removeOneTooltip` (used by the POS cart, purchase
draft, and quantity adjustment dialog); new tooltips must go in `lib/l10n/app_ar.arb`
in Arabic, followed by `flutter gen-l10n`.

## 2026-08-18 - `dart format` reflows unrelated code

**Learning:** Running `dart format` on a touched file reformats *whole* file to the
current formatter's style, which can rewrite unrelated function signatures written
under an older version — noise that buries a small UX diff in review.

**Action:** After formatting, always `git diff` the touched files and hand-revert
hunks you did not intend. AGENTS.md already warns against `dart format lib`; the same
risk applies per-file.

## 2026-08-18 - Scheduled runs cannot verify Flutter UI visually

**Learning:** `preview_start` refuses to run in an unattended scheduled-task session
("nobody is present to approve the command"), so the whole `lib/dev/*_preview.dart`
harness — the repo's documented way to eyeball a screen — is off the table on these
runs, even though the harness and its `make`/launch.json targets already exist for
most routes (login, pos, purchasing, users, discounts, …).

**Action:** Plan the UX change so a **widget test** is the proof, not a screenshot.
Assert the behaviour that would otherwise be checked by eye — that an `IconButton`'s
`tooltip` tracks state, that `EditableText.obscureText` flips, that `onPressed` is
null while disabled — via `tester.widget<T>(find.byType(T))`. Pump with `locale:
Locale('ar')` + `AppLocalizations.localizationsDelegates` + `Directionality.rtl`
(copy `_pumpSurface` in `test/shared/components/pointy_components_test.dart`).
Say plainly in the PR that visual QA was not possible, rather than implying it was.

## 2026-08-18 - Establish the test baseline before claiming a run is green

**Learning:** `flutter analyze` and `flutter test` were already red at `main`:
an automated "Potential fix for pull request finding" commit (f4c82178) deleted the
closing `});` of the first test in `test/shared/components/pointy_password_field_test.dart`
— a file a *previous Palette PR* added — so the whole suite failed to compile. There is
also a genuinely failing assertion at `test/widget_test.dart:148`
(`BarcodeLabelPrinterLanguage` expected `auto`, gets `escPos`). Running only the tests
you just wrote hides both, and stating "tests pass" would have been wrong.

**Action:** On every run, `git stash -u` and run the full suite *before* touching
anything, so you know which failures you inherited. Report inherited failures explicitly
in the PR instead of implying a clean suite. Both of these turned out to be stale *tests*
rather than broken behaviour — the second asserted that `'esc_pos'` parses to
`BarcodeLabelPrinterLanguage.auto`, written before `bb1e2dc0` added the `escPos` value
and never updated, so it was asserting the exact ZPL-fallback bug that commit fixed.
Read the enum and its git history before assuming a red assertion means the product is
wrong; a feature commit that adds an enum value and skips the parser test is the common
shape here.

## 2026-08-18 - `PointyEmptyState.action` existed but nothing used it

**Learning:** `PointyEmptyState` has always supported an `action` widget, yet every
call site in the app passed only `icon`/`title`. The worst case is the POS and
purchasing catalogs: the grid goes blank on a typo'd search or a pinned quick-access
category and shows the same generic "لا توجد منتجات" as a genuinely empty shop, with
no way out. Dead-end empty states are the app's most common UX gap, not missing labels.

**Action:** When a list can be filtered, its empty state must distinguish *empty* from
*filtered-to-nothing* and offer a one-tap escape. `CatalogEmptyState`
(`lib/src/shared/catalog/catalog_empty_state.dart`) is the pattern to copy: take the
query object, branch on it, and call back into `viewModel.applyQuery(query.copyWith(...))`
to clear. `DebouncedSearchField` syncs its text from `widget.value`, so clearing the
query also clears the visible search box — no extra reset signal needed.
