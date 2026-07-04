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

## Status: ported and analyzer-clean — one CI resolve away from green

The full downgrade is done. `dart analyze lib` is **clean (0 errors,
0 warnings)** under the pubspec's Dart 3.3 lower-bound language version, so all
the Dart 3.7/3.8 syntax and the newer-package APIs have been ported. The heavy,
camera/AI-only features were **dropped** (not downgraded) and stubbed behind
their existing signatures — a Windows-8 till uses a wedge/USB scanner and
printer only, so nothing user-facing on that hardware is lost.

The one thing that still can't be validated on this dev machine is the real
Flutter 3.19 `pub get` — the transitive tree may force a few more patch pins.
That resolve happens in the compat CI (or via FVM locally, below). Everything
that a local Dart 3.3-language-version analyze can prove, is proven.

### How the local analyze proves Dart 3.3 compatibility without Flutter 3.19

`dart analyze` reads the **language version from the pubspec lower bound**
(`sdk: '>=3.3.0'`), not from the SDK running it. So running it under this
machine's global Flutter still rejects any Dart 3.4+ syntax — which is exactly
how the wildcard / null-aware-element / public-field-promotion errors were
found and fixed. It does *not* prove the transitive package tree resolves under
Flutter 3.19; only the compat CI does that.

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
| `flutter_lints` (dev) | ^6.0.0 | `^3.0.0` | 3.0.x | 6.x needs Dart 3.8 |

Direct deps whose existing caret pin *already* admits a Dart-3.3-safe version
(so pub auto-picks it, no change needed): `cupertino_icons` (1.0.8), `http`
(1.2.2), `pdf` (3.12.0), `url_launcher` (6.3.1), `path_provider` (2.1.4),
`package_info_plus` (8.x). Transitive Flutter-SDK packages (`collection`,
`meta`, `async`, …) are pinned by Flutter 3.19 itself; federated plugin
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

## Re-validating after a `main` merge

`flutter build windows` compiles only the reachable `lib/` graph and fails only
on **errors**, so the gate for a green build is:

```bash
cd frontend
dart analyze lib        # must be 0 errors (warnings/infos don't block the build)
```

If a future `main` merge reintroduces newer syntax or a dropped package's
symbols, that command flags it. `test/` still references the dropped packages
and will not analyze/run on this branch — that is expected and does not affect
the release build.
