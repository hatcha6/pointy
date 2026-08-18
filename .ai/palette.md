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
