# Frontend performance sweep

Drives the **real app** (real screens, view models, JSON parsing) through every
screen and dialog and measures what each frame costs, so a screen that would
jank on a shop PC is caught on the desk.

## Why two kinds of numbers

The field problem was raster-bound jank on hardware we do not have. Timing a
frame on an M-series Mac says little about a Celeron with an integrated GPU,
so the sweep measures **structure** first — numbers that are identical on any
hardware because they describe what the frame *asked* the GPU to do:

| metric | what it means | budget |
|---|---|---|
| **pictures re-recorded / frame** | how many display lists the engine rebuilt. **The load-bearing metric** — it cannot over-report: a picture counts only when a `PictureLayer` appears that did not exist last frame. | idle ≈ 0; scroll ≤ 4 (warn) / 8 (fail); typing ≤ 3 (warn) / 6 (fail) |
| rebuilds / frame | widgets rebuilt (`debugOnRebuildDirtyWidget`) | idle ≤ 5, scroll ≤ 250 (warn) / 600 (fail) |
| saveLayers | `Opacity<1`, `ShaderMask`, `BackdropFilter`, `ImageFilter`, `ColorFilter`, `ClipPath`, `Clip.antiAliasWithSaveLayer` layers in the tree | 0 at rest |
| paints / frame | render objects visited during paint | reported only |
| repainted area | area of the re-recorded pictures, attributed to the widget that owns each one | reported only |

**Two of these over-report, which is why they no longer decide verdicts.**
Painted render objects counts `paintChild` calls, and a *clean* child behind a
repaint boundary is still visited to re-add its existing layer — so a screen
that correctly repaints nothing still shows a high count. Repainted area uses
each picture's cull rect, which for a scrolling viewport is the whole viewport
however small the actual damage. Both stay in the report because they say
*where* the cost is; only the picture count says *whether* there is one.

Then, in a profile build on macOS, it also records real `FrameTiming`
build/raster durations (p50 / p95 / max per phase). Treat those as a proxy:
anything already over ~4 ms of raster here is a dropped frame in the field.

Every screen is measured in phases: `transition` (the route animation),
`load` (spinner/skeleton on screen), `idle` (nothing happening — must draw
nothing), `scroll` (fling the main list down and back), and whatever the
script opens on it: `open:<x>` / `idle:<x>` / `scroll:<x>` / `close:<x>` for
dialogs, sheets and details screens, `typing` for search fields.

## Running

```bash
make frontend-perf-sweep                       # hermetic, structural metrics, ~1 min
PERF_SURFACES=invoices,catalog make frontend-perf-sweep
PERF_STRICT=1 make frontend-perf-sweep         # fail on any FAIL verdict
make frontend-perf-profile                     # macOS profile build: real ms
```

Reports land in `frontend/build/perf/sweep_report.md` (+ `.json`). The
Markdown lists every phase with a verdict, and for flagged phases *which*
widgets rebuilt, painted, and owned the repainted area — that section is the
diagnosis; read it before opening the screen's source.

## Fixtures

The hermetic run replays recorded backend responses from
`test/perf/fixtures/*.json` (all files merged). Anything not recorded gets a
404 and is listed under "Fixture misses" in the report — a screen or dialog
that shows an error state because its endpoint is missing is not measured
meaningfully, so record it:

```bash
# backend running on :8000 with superuser perf/perfperf (see below)
make frontend-perf-record AREA=sales SURFACES=invoices,invoice_details
```

This runs the sweep for those surfaces in a real macOS debug build against
the backend, and appends only the *newly* recorded responses to
`test/perf/fixtures/<AREA>.json`. Recording is serialised through a lock
(`build/perf_record.lock`) because runs share one Xcode build tree — a second
recorder waits. Re-recording an identical answer is a no-op.

Backend prerequisites, once:

```bash
cd backend && .venv/bin/python manage.py shell -c "
from django.contrib.auth import get_user_model
U=get_user_model(); u,_=U.objects.get_or_create(username='perf'); u.is_superuser=u.is_staff=u.is_active=True; u.set_password('perfperf'); u.save()"
POINTY_ANONYMOUS_BURST_LIMIT=0 .venv/bin/python manage.py simulate_business --operations 2000 --seed 20260901 --commit
```

## Adding a surface

Scripts live in `lib/dev/perf/surfaces/<group>.dart`, one file per navigation
group. A top-level screen is `screen('invoices')`; everything reachable from
it goes in `extras`:

```dart
screen('invoices', extras: (d) async {
  // A dialog or sheet: open it, rest on it, scroll it, close it.
  await d.openAndClose('filters', open: () => d.tapTooltip('تصفية'), scroll: true);
  // Typing into the search field, one keystroke at a time.
  await d.typeSearch(find.byType(DebouncedSearchField), 'INV');
  // A details screen: reached by tapping a row; measured like a screen.
  await d.openAndClose(
    'invoice_details',
    open: () => d.tap(find.byType(PointyDataRow).first),
    scroll: true,
    inside: () async {
      await d.openAndClose('void', open: () => d.tapText('إلغاء الفاتورة'));
    },
  );
}),
```

Driver helpers: `tap`, `tapText`, `tapTooltip`, `tapIcon`, `tapKey`,
`enterText`, `typeSearch`, `scrollMain`, `openAndClose`, `closeTop`,
`measurePhase`, `frames`, `settle`, `navigator`. Finders are the normal
`flutter_test` ones. A missing widget is recorded as a note, never a crash.
Steps must work under both `flutter test` (a `WidgetTester`) and a live
build (`LiveWidgetController`): no `pumpAndSettle`, no `enterText` on the
tester — use the driver's.

Keep each phase honest: name dialogs after what a cashier would call them,
and measure each dialog once (opening the same sheet twice doubles nothing
but the run time).

## What the numbers have caught so far

- A clipped `Material` (`clipBehavior: Clip.antiAlias` + `borderRadius`) is
  a `PhysicalShape`, which is a `ClipPath` layer: a saveLayer on every list
  screen (the shared search field) and one per row (`PointyDataRow`).
- A scrollable with no repaint boundary of its own re-records its whole route
  picture on every scroll frame — fixed in `InfiniteScrollView` (so every list
  built on `PointyDataList` benefits) and in the expenses ledger.
- An ink ripple on a navigation-rail tile dirtied the nearest boundary, which
  was the window: `PointyScaffold` now gives the rail and the body their own.
- Route transitions rebuild 1,500–2,200 widgets in one frame — expected for a
  full-page swap, reported but not budgeted.
- Still open: the login form re-records ~12 pictures per keystroke.
