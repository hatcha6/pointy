# Pointy Agent Rules

These rules apply to AI agents working anywhere in this repository.

## Branch scope: `compat/win8`

`compat/win8` is a **frozen** Flutter 3.19 / Dart 3.3 build that exists for one
reason: old Windows 7/8/8.1 cashier machines. Flutter 3.19 is the last release
whose Windows apps run on them; `main` targets Flutter 3.38 and will not.

**Every change to that branch is frontend only, and only what a till touches.**
Those machines talk to a backend built from `main`, so a backend change on
`compat/win8` is not merely unnecessary — it is wrong, because it diverges a
tree nothing deploys. Some older commits on the branch did touch its backend;
do not read them as precedent.

- Never merge `compat/win8` into `main`. Its pinned pubspec and stubs would
  break main's 3.38 build. If the branch ever needs re-syncing, rebase `main`
  *into* it, never the reverse.
- Port with `git cherry-pick -n <sha>`, then strip everything outside
  `frontend/` and outside the POS path before resolving. Main's commits
  routinely bundle unrelated work — expect to drop most of a commit.
- Port in a dedicated `git worktree` for the branch rather than switching
  branches in a main checkout: a stale `frontend/.dart_tool` from the other
  branch makes `dart analyze` spew hundreds of phantom errors in files nobody
  touched.
- Before committing a port, check the added lines for Flutter APIs newer than
  3.19 (`withValues`, `WidgetState*`, `*ThemeData` renames,
  `surfaceContainerHighest`, `onPopInvokedWithResult`) and for Dart 3.4+ syntax
  (wildcard `(_, _)`, null-aware elements `[?x]`). `dart analyze` proves the
  language level via the pubspec floor even on a modern SDK. Leave
  `frontend/pubspec.yaml` alone: a dependency bump there can fail to resolve
  under 3.19 in ways only the compat CI catches.
- A red test on that branch is more often a stale port than a real divergence.
  Diff the test against `main` before concluding the code behaves differently.

Branch detail and the full drift list live in `frontend/COMPAT_WIN8.md` on the
branch itself.

**You are on that branch now.**

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

## UI Preview Harness (Flutter web)

When building or redesigning a screen, preview it visually instead of guessing.
The pattern: a dev-only Flutter **web** entrypoint that renders the real screens
with fake repositories (no backend, no auth, no login), served via `flutter run
-d web-server`, then screenshotted through the preview tooling. The canonical,
working example is `frontend/lib/dev/stock_count_preview.dart` (run it with
`make frontend-preview`, or the `stock-count-preview` config in
`.claude/launch.json`). Copy it as the starting point for any other route.

It supports two complementary modes via a `?screen=` query param:

- **Design board** (`?screen=board`): every screen and state laid out at once in
  fixed device frames (phone + wide side by side) for a single overview
  screenshot. Best for reviewing the whole route quickly and comparing widths.
- **Single surface** (`?screen=sessions`, `counting-item`, `recon`, `variance`,
  …): one screen full-viewport for deep, real-viewport responsive QA — resize the
  browser to 390 / 430 / 768 / 1024 / 1366 and screenshot each.

### How to run and drive it

1. Add a `frontend-<feature>-preview` `make` target and a launch.json config (so
   the preview tool can start it) pointing at `-t lib/dev/<feature>_preview.dart`.
2. Start the server (preview tool `preview_start`, or `make`). **A black/blank
   canvas after start is almost never a slow compile — it's that the preview
   browser loaded the page before the dev server finished serving the built app
   and it does NOT auto-refresh.** Once the server log shows "is being served
   at" (a few seconds), force one reload — `preview_eval` with
   `window.location.reload()`, or just navigate to a `?screen=` URL — and the app
   paints immediately. Do NOT passively wait for `flutter-view`/a frame to
   appear; reload to make it appear. (Compiling is fast; the wait was a browser
   refresh bug.)
3. Navigate between surfaces by setting the URL, not by clicking — Flutter web
   renders to a `<canvas>`, so DOM-based tools (clicks by selector, accessibility
   snapshot, CSS inspect) do **not** see widgets. Use `preview_eval` with
   `window.location.href = origin + '/?screen=counting-item'` (a reload reuses the
   already-compiled bundle, so it is fast). Only **screenshots** are reliable for
   Flutter web.
4. For the board, size the viewport large (e.g. 1500x4000) before screenshotting
   so Flutter paints every frame (it only paints what is inside the viewport).
5. After editing Dart, recompile by stopping and restarting the preview server
   (`flutter run` under the preview tool can't receive a hot-restart keypress),
   then reload the page per step 2. Navigating to a `?screen=` URL reloads (so it
   picks up a finished build and forces a paint) but does not itself recompile.
6. If a screenshot is black/blank or shows a black band (e.g. right after
   `preview_resize`), it's the same paint-nudge issue as step 2 — reload or
   resize once more to force a repaint; it's not a layout bug.

### Cloning the harness for another route

- Wrap everything in a `MaterialApp` that matches `lib/src/app.dart`: `locale:
  Locale('ar')`, the four localization delegates, `theme: PointyTheme.light()`,
  and a `PointyNavigationRailScope` in the `builder`.
- Fake repositories by subclassing the concrete repo and overriding only the
  methods the screen calls: `class _FakeXRepository extends XRepository { _FakeXRepository() : super(PosApiService()); @override ... }`.
  Return `Ok(...)` with hand-built fake models. For screens with a drawer, also
  implement `AppNavigation` (no-op `navigateTo`/`logout`, real `capabilities`/`currentUser`).
- For interactive states a screen only reaches via input (e.g. an item selected
  after a scan), extract the screen body into a pure, parameter-driven public
  widget (see `StockCountCountingBody`) so the preview/tests can render that state
  directly. This also improves testability.
- Device frame for the board: a `SizedBox(width, height)` wrapping a
  `MediaQuery(data: MediaQuery.of(context).copyWith(size: Size(width, height), padding/viewInsets: zero), child: screen)`.
  The `MediaQuery` size override makes `AdaptiveSpacing`/breakpoints behave as if
  the viewport were that size. Keep board frame widths < 1024 for screens that
  switch to a navigation rail, unless you want to preview the rail too.
- Sheets/dialogs: render a host scaffold that calls the public `show…Sheet`
  function in a post-frame callback so the sheet opens on load (no click needed).
- Mark the file dev-only ("safe to delete") — it is a separate entrypoint, never
  imported by `lib/main.dart`, so it does not ship. Do not run `dart format lib`
  on the whole tree to format it (that reflows unrelated files); format just the
  paths you touched.

## Backend

- Keep Django apps grouped by domain: catalog, inventory, sales, payments, and core.
- Use DRF serializers/viewsets for API endpoints unless a workflow clearly needs a custom API view.
- Keep Redis usage explicit for cache, Celery broker/result backend, or short-lived operational state.

## Developer Experience

- Prefer root `make` targets for common workflows.
- Update `Makefile` and `README.md` when adding new setup, run, test, or check commands.
- Do not leave long-running dev servers active unless the user asks for them.
