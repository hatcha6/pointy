# Pointy Agent Rules

These rules apply to AI agents working anywhere in this repository.

## Product Language

- The Pointy frontend is Arabic-first.
- All user-facing Flutter text must be Arabic unless the user explicitly asks for another language.
- Do not hardcode visible UI copy directly inside widgets. Add strings to Flutter localization files under `frontend/lib/l10n/` and read them through `AppLocalizations`.
- Preserve right-to-left behavior. Keep Arabic screens tested in RTL and avoid layout assumptions that only work in LTR.
- Use Arabic labels for POS workflows, including catalog, cart, totals, payment actions, tooltips, empty states, and errors.
- Do not add tax fields, tax totals, or tax UI unless the user explicitly asks for tax support.

## Flutter

- After changing localization files, run `flutter gen-l10n` from `frontend/`.
- Run `dart format lib test`, `flutter analyze`, and `flutter test` after meaningful frontend changes.
- Keep UI dense, practical, and cashier-friendly. This is a POS app, not a marketing site.
- Prefer the existing MVVM-style shape: services, repositories, view models, then views.
- Keep widgets small and purposeful. Look for existing reusable code before adding new code.
- Prefer simple, DRY implementations over large files, duplicated UI, or clever abstractions.
- Avoid large files and mixed-responsibility files. Split unrelated behavior into focused files, and extract reusable widgets, helpers, models, or view-model actions when a file starts to bundle multiple concepts.
- When using the Flutter `pdf` package for RTL tables, keep visual column metadata in the same order as rendered cells: if headers/rows are reversed for correct RTL visual order, reverse the matching column widths and alignments at that same render boundary, or use a shared helper that does all of them together.

## Backend

- Keep Django apps grouped by domain: catalog, inventory, sales, payments, and core.
- Use DRF serializers/viewsets for API endpoints unless a workflow clearly needs a custom API view.
- Keep Redis usage explicit for cache, Celery broker/result backend, or short-lived operational state.

## Developer Experience

- Prefer root `make` targets for common workflows.
- Update `Makefile` and `README.md` when adding new setup, run, test, or check commands.
- Do not leave long-running dev servers active unless the user asks for them.
