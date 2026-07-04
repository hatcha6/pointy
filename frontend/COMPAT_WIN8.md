# Windows 8 compatibility branch (`compat/win8`)

This branch produces a Windows till client that runs on **Windows 7 / 8 / 8.1**.

## Why it exists

Flutter **3.19** (Dart 3.3) is the *last* Flutter release whose Windows apps run
on Windows 7/8/8.1. Flutter 3.20+ requires Windows 10. `main` is developed
against Flutter 3.38 / Dart 3.10 and uses packages that need a modern SDK, so it
cannot target Windows 8. This branch pins the toolchain back to 3.19 and carries
the dependency downgrades that go with it.

Keep this branch as a thin delta on top of the release you want to ship: merge
`main` into it per release, resolve, tag `vX.Y-compat`, done.

## How it ships

`.github/workflows/release-compat.yml` builds this branch with Flutter 3.19.6
and publishes a Windows-only artifact to any release tagged `…-compat`
(e.g. `v0.2-compat`). The main pipeline (`release.yml`) skips `-compat` tags.
**Both workflow files already live on `main`** — they must, because GitHub only
runs `release`-event workflows from the default branch — so no merge is needed;
this branch carries only the code downgrade.

**Release flow:** tag this branch `v0.2-compat` → publish a GitHub Release from
that tag → the workflow (from `main`) checks out the tagged commit (this
branch), builds it with Flutter 3.19.6, and attaches the Windows build.

Keep this branch's pubspec downgrade **off `main`** — merging it would break
`main`'s Flutter 3.38 build. Rebase `main` *into* this branch each release
cycle, never the reverse.

## Status: fully validated against real Flutter 3.19.6 (pub get + gen-l10n + analyze)

The downgrade + port is done and validated against an **actual Flutter 3.19.6
toolchain** (not just a language-version analyze). Everything CI runs before the
Windows-native compile has been reproduced locally and passes:

| CI step | local result (real Flutter 3.19.6, Dart 3.3.4) |
|---|---|
| `flutter pub get` | ✅ exit 0 — full tree resolves |
| `flutter gen-l10n` | ✅ with `synthetic-package: false` (see below) |
| `dart analyze lib` | ✅ **0 errors / 0 warnings** |
| `flutter build bundle` | ✅ exit 0 — **full Dart kernel compile** (`io` conditionals, same as Windows); proves the whole graph compiles, not just analyzes |
| `flutter build windows` | Windows-only C++ link — the only step CI must prove |

The heavy camera/AI-only features were **dropped** (not downgraded) and stubbed
behind their existing signatures — a Windows-8 till uses a wedge/USB scanner and
printer only, so nothing user-facing on that hardware is lost.

### Validating locally against the real 3.19 SDK (no global change)

A language-version `dart analyze` (below) catches Dart-3.3 *syntax* violations,
but it can NOT see two whole classes of failure that only the real 3.19 SDK
surfaces: (1) transitive **version conflicts** (e.g. pdf↔vector_math), and
(2) Flutter **framework** API drift (`Color.withValues`, `WidgetState`, …). To
catch those, download Flutter 3.19.6 into a throwaway dir — this touches nothing
global (no PATH change, no FVM, no global Flutter modified):

```bash
cd "$SCRATCH"                 # any temp dir
curl -sSL -o f319.zip \
  https://storage.googleapis.com/flutter_infra_release/releases/stable/macos/flutter_macos_arm64_3.19.6-stable.zip
unzip -q f319.zip             # -> ./flutter  (Dart 3.3.4 bundled)
FL=$PWD/flutter/bin/flutter
cd <repo>/frontend
$FL pub get && $FL gen-l10n && $FL/../dart analyze lib   # the real CI gate
```

`$FL pub get` is the oracle for resolution; `dart analyze lib` (run via the
isolated SDK, so it type-checks against the *3.19* package + framework APIs) is
the oracle for code. This is exactly how the framework-API port below was found.

### How a plain (global-Flutter) analyze still helps

`dart analyze` reads the **language version from the pubspec lower bound**
(`sdk: '>=3.3.0'`), not the SDK running it, so even the global Flutter rejects
Dart 3.4+ *syntax* (wildcards, null-aware elements, public-field promotion). It
does NOT see 3.19 framework APIs or transitive resolution — use the isolated
SDK above for those.

## Validate locally WITHOUT disturbing your global Flutter

Use [FVM](https://fvm.app), which installs Flutter versions **side by side** —
your global `flutter` (3.38) is never touched. `.fvmrc` here already pins
3.19.6.

```bash
dart pub global activate fvm      # once, if you don't have FVM
cd frontend
fvm install                       # downloads 3.19.6 next to your global Flutter
fvm flutter pub get               # THE resolver — surfaces the real version set
fvm flutter gen-l10n
fvm flutter build windows --release
```

`fvm flutter pub get` is the oracle: it will either resolve or tell you exactly
which package/transitive still floors above Dart 3.3, so you can pin it down.

## What changed vs. `main`

### Dropped entirely (camera / AI-only — a till never uses them)

These packages floor above Dart 3.3 in every version that carries the features
`main` uses, so instead of a lossy downgrade they were **removed** from
`pubspec.yaml` and their call sites replaced with signature-preserving stubs.
Callers already handle the "not supported here" path, so no caller changed.

| Package | main | On compat | Stub |
|---|---|---|---|
| `mobile_scanner` | ^7.2.0 | **dropped** | camera scanner sheets return `null`; kiosk keeps wedge + manual entry |
| `record` | ^6.2.1 | **dropped** | `RecordVoiceRecorder.hasPermission()` → `false`, `start()` throws; composer stays text-only |
| `gpt_markdown` | ^1.1.7 | **dropped** | AI replies render via `SelectableText` instead of Markdown |
| `fl_chart` | (main) | **dropped** | dashboard trend/hourly/payment charts render a placeholder |
| `web` | ^1.1.1 | **dropped** | only used by the web-platform PDF-share path; its Dart-3.3 line (≤0.5.1) clashes with the Flutter SDK's own `web` pin, and a Windows till never runs on web |

Stubbed files: `lib/src/features/ai/voice_recording.dart`,
`lib/src/features/ai/views/ai_assistant_screen.dart`,
`lib/src/features/dashboard/views/dashboard_screen_widgets.dart` (+ `dashboard_screen.dart`),
`lib/src/shared/barcode/camera_barcode_scanner_sheet.dart`,
`lib/src/shared/barcode/camera_text_barcode_scanner_sheet.dart`,
`lib/src/features/price_checker/views/price_checker_kiosk_screen.dart`,
`lib/src/data/services/order_document_web_delivery_web.dart` (now re-exports the
no-op stub; the conditional `if (dart.library.html)` export still resolves).

### Downgraded (kept — the till needs these)

Pinned to the last Flutter-3.19-era line. Verified: the compat CI's Flutter
3.19.6 ships Dart **3.3.4**, and each pin below admits a version whose SDK
constraint includes 3.3.4 (checked against the pub.dev version metadata).

| Package | main | compat pin | resolves to | Code impact |
|---|---|---|---|---|
| `file_picker` | ^11.0.2 | `>=6.1.1 <7.0.0` | 6.2.1 | `FilePicker.platform.*`; `saveFile` has no `bytes:` — we write the PDF via `dart:io` |
| `printing` | ^5.14.3 | `>=5.11.0 <5.13.0` | 5.12.0 | source-compatible |
| `flutter_tts` | ^4.2.5 | `>=3.8.0 <4.0.0` | 3.9.x | no change |
| `wakelock_plus` | ^1.3.3 | `>=1.2.5 <1.3.0` | 1.2.8 | no change |
| `image_picker` | ^1.2.2 | `>=1.1.0 <1.2.0` | 1.1.2 | 1.2.0 floors at Dart 3.6; same `ImagePicker`/`pickImage`/`XFile` API |
| `shared_preferences` | ^2.5.5 | `>=2.2.0 <2.3.2` | 2.3.1 | 2.3.2 floors at Dart 3.4; classic `getInstance()` only |
| `multicast_dns` | ^0.3.3 | `>=0.3.2 <0.3.3` | 0.3.2+7 | 0.3.3 floors at Dart 3.4 |
| `qr` | ^3.0.2 | `>=3.0.0 <3.0.2` | 3.0.1 | 3.0.2 floors at Dart 3.4; same `QrCode`/`QrImage` API |
| `http_parser` | ^4.1.2 | `>=4.0.0 <4.1.0` | 4.0.2 | 4.1.0 floors at Dart 3.4; keeps `MediaType` |
| `pdf` | ^3.12.0 | `>=3.11.0 <3.12.0` | 3.11.3 | **not** an SDK floor — pdf 3.12 needs `vector_math ^2.2.0`, but Flutter 3.19's `flutter_test` pins `vector_math 2.1.4` exactly; pdf 3.11 uses `^2.1.0` |
| `flutter_lints` (dev) | ^6.0.0 | `^3.0.0` | 3.0.x | 6.x needs Dart 3.8 |

The `pdf` row is the important lesson: a Dart-3.3-compatible package can still be
**unresolvable** because of a *transitive version conflict* with an SDK-pinned
package (here `vector_math`). Only the real 3.19 `pub get` finds these — the
pub.dev-metadata audit that catches SDK floors does not.

Direct deps whose existing caret pin *already* admits a Dart-3.3-safe version
(so pub auto-picks it, no change needed): `cupertino_icons` (1.0.8), `http`
(1.2.2), `url_launcher` (6.3.1), `path_provider` (2.1.4), `package_info_plus`
(8.x). Transitive Flutter-SDK packages (`collection`, `meta`, `async`,
`vector_math`, …) are pinned by Flutter 3.19 itself; federated plugin
platform-impls (`image_picker_android`, `win32`, …) follow their capped
top-level plugin.

### Language port (Dart 3.7/3.8 → 3.3)

`main` uses newer Dart syntax pervasively; all of it was rewritten to 3.3:

- **wildcards** (Dart 3.7): `(_, _)` → `(_, __)`, etc.
- **null-aware elements** (Dart 3.8): `[?x]`, `{?x}`, `key: ?v` →
  collection-`if` forms.
- **public-field promotion**: Dart 3.3 will not promote a nullable *public*
  final field after a null check, so `if (x != null) x` inside a collection
  literal needs `x!` (e.g. `trailing`, `leading`, `selectedMethod`).

This was all found and fixed via local `dart analyze lib` — see the note above
on why that catches 3.3 violations without Flutter 3.19 installed.

### Framework API port (Flutter 3.38 → 3.19)

`main` calls Flutter framework APIs newer than 3.19. These are invisible to a
global-Flutter analyze (the framework *is* newer there) — only the isolated
3.19 SDK surfaces them. All rewritten to their 3.19 equivalents:

| 3.38 API (used on main) | 3.19 equivalent | added in | sites |
|---|---|---|---|
| `Color.withValues(alpha: x)` | `Color.withOpacity(x)` | 3.27 | 127 |
| `WidgetState` / `WidgetStateProperty` | `MaterialState` / `MaterialStateProperty` | 3.22 | 18 |
| `{AppBar,Card,Dialog,InputDecoration}ThemeData` | drop the `Data` suffix | 3.22 | 8 |
| `ColorScheme.surfaceContainerHighest` | `surfaceVariant` | 3.22 | 1 |
| `DropdownButtonFormField(initialValue:)` | `value:` | 3.22 | 37 |
| `PopScope(onPopInvokedWithResult:)` | `onPopInvoked:` (single-arg) | 3.22 | 1 |

`BottomSheetThemeData` and `ChipThemeData` already exist in 3.19 (they always
carried the `Data` suffix) — left untouched.

### l10n: pin `synthetic-package: false`

Flutter 3.19's `gen-l10n` defaults `synthetic-package` to **true** — it deletes
`lib/l10n/generated/*.dart` and emits to `.dart_tool/flutter_gen/` under
`package:flutter_gen/...`. But the app imports
`package:pointy_frontend/l10n/generated/...`, so the CI build breaks right after
its `flutter gen-l10n` step. `l10n.yaml` now pins `synthetic-package: false`
(the default from 3.22 on, so harmless on `main`), keeping output in
`output-dir`. The committed generated files are the 3.19 form.

### Android embedding-v2 false positive → `android/build.gradle` marker

`flutter pub get` on 3.19 failed with *"The plugin `X` requires your app to be
migrated to the Android embedding v2"* — on plugin after plugin — even though
`android/app/src/main/AndroidManifest.xml` correctly declares
`<meta-data android:name="flutterEmbedding" android:value="2"/>`.

Root cause (from the 3.19 `flutter_tools/lib/src/project.dart` source):
`AndroidProject.isUsingGradle` only tests for a **Groovy** `android/build.gradle`;
our Android project is **Kotlin-DSL** (`build.gradle.kts`) only. With
`isUsingGradle == false`, `appManifestFile` resolves to `android/AndroidManifest.xml`
(which doesn't exist) instead of `android/app/src/main/AndroidManifest.xml`, so
`computeEmbeddingVersion()` never sees the marker and returns v1. Every v2 plugin
then hard-fails `pub get` (exit 1). Main (3.38) understands `.kts` here.

Fix: a comment-only Groovy **`android/build.gradle`** marker so 3.19's check is
true and reads the right manifest. This is a Windows-only build — Gradle never
runs, so the marker is inert and the real config stays in `build.gradle.kts`.
(`flutter_bluetooth_classic_serial` was also dropped — it was the first plugin to
trip the check and a USB-printer till never uses Bluetooth.)

This class of failure — opaque Flutter tooling errors — is fastest to solve by
**reading the isolated SDK's own `flutter_tools` source** (`$SCRATCH/flutter/
packages/flutter_tools/lib/src/…`), which is exactly how this was pinned down.

### Windows CI: Visual Studio detection (the native build step)

The one step that can't be validated off-Windows. The native build failed at
CMake with *"Generator Visual Studio 16 2019 could not find any instance of
Visual Studio."*

Root cause (`flutter_tools/lib/src/windows/visual_studio.dart`): 3.19's
`cmakeGenerator` returns **"Visual Studio 16 2019"** as its default whenever it
can't positively identify a newer VS (`switch (_majorVersion) { case 17: …;
case 16: default: 'Visual Studio 16 2019'; }`). `windows-latest` now maps to
**windows-2025**, whose VS 2022 (17.12+) is newer than 3.19's vswhere-based
detection understands, so it falls back to the 2019 generator — but the runner
has no VS 2019, so CMake aborts. Main's Windows build works only because
Flutter 3.38's detection reads the current VS.

Fix in `.github/workflows/release-compat.yml` (build-windows-compat job), two
independent paths to green:
- `runs-on: windows-2022` — an older VS 2022 that 3.19 *can* detect → the
  "Visual Studio 17 2022" generator, which CMake resolves; and
- `choco install visualstudio2019buildtools visualstudio2019-workload-vctools`
  — a deterministic backstop: if Flutter still emits "Visual Studio 16 2019",
  CMake finds the freshly installed VS 2019 itself.

The workflow lives on **both** `main` and `compat/win8` and must stay identical
(GitHub may resolve a `workflow_dispatch` run's workflow file from either ref).

## Re-validating after a `main` merge

A global-Flutter `dart analyze lib` (0 errors) is necessary but **not
sufficient** — it misses 3.19 framework APIs and transitive resolution. The real
gate is the isolated 3.19 SDK (see "Validating locally against the real 3.19
SDK" above):

```bash
FL=$SCRATCH/flutter/bin/flutter          # the downloaded 3.19.6
cd frontend
$FL pub get                              # transitive resolution (SDK floors + version conflicts)
$FL gen-l10n                             # regenerates lib/l10n/generated (synthetic-package: false)
$SCRATCH/flutter/bin/dart analyze lib    # 0 errors against 3.19 framework + package APIs
```

`flutter build windows` compiles only the reachable `lib/` graph and fails only
on **errors**; the three commands above reproduce every CI step except the
Windows-native compile. `test/` still references the dropped packages and will
not analyze/run on this branch — that is expected and does not affect the
release build.
