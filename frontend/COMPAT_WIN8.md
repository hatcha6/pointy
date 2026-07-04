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

## Status: foundation laid, NOT yet resolved

The toolchain and the SDK-constraint/dependency downgrades are in place, but the
exact version set and the code adaptations below **have not been validated** —
that needs a real Flutter 3.19 `pub get`, which can only be done in an
environment that has Flutter 3.19 (the compat CI, or FVM locally — see below).
Treat the pubspec pins as a starting point, not a guarantee.

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

## Dependency downgrades (in `pubspec.yaml`)

Each package below capped its floor above Dart 3.3 in a recent major; the branch
pins the last Flutter-3.19-era line. Ranges are best-effort — confirm with
`fvm flutter pub get`.

| Package | main | compat pin | Code impact |
|---|---|---|---|
| `mobile_scanner` | ^7.2.0 | `>=4.0.0 <5.0.0` | **API rewrite** — see below |
| `record` | ^6.2.1 | `>=5.0.0 <6.0.0` | **API rewrite** — see below |
| `file_picker` | ^11.0.2 | `>=6.1.1 <7.0.0` | API deltas (4 files) |
| `printing` | ^5.14.3 | `>=5.11.0 <5.13.0` | usually source-compatible |
| `flutter_tts` | ^4.2.5 | `>=3.8.0 <4.0.0` | API stable, likely no change |
| `gpt_markdown` | ^1.1.7 | `>=1.0.0 <1.1.0` | check `GptMarkdown` widget args |
| `wakelock_plus` | ^1.3.3 | `>=1.2.5 <1.3.0` | API stable, no change |

## Code that still needs adapting on this branch

These call the newer package APIs and will not compile until reworked. The
pragmatic recommendation for a **desktop Windows-8 till** is to *disable* the
camera and voice features (a till uses a wedge/USB scanner, not a camera; voice
messages are an AI extra), which sidesteps the two hardest downgrades entirely.

**`mobile_scanner` (camera scanning) — recommend disabling on compat:**
- `lib/src/features/price_checker/views/price_checker_kiosk_screen.dart`
  (uses `MobileScannerController(cameraResolution:, autoZoom:, detectionTimeoutMs:)`,
  `BarcodeFormat.itf14`, `TorchState`, `MobileScanner`) — gut the camera path,
  keep the wedge-scanner + manual-entry paths (they don't need the package).
- `lib/src/shared/barcode/camera_barcode_scanner_sheet.dart`
- `lib/src/shared/barcode/camera_text_barcode_scanner_sheet.dart`
  Replace both with signature-preserving stubs
  (`showCameraBarcodeScannerSheet` / `showCameraTextBarcodeScannerSheet`
  return `null`) and make `priceCheckerCameraScanningSupported`
  (`lib/src/features/price_checker/price_checker_mode_actions.dart`) return
  `false` on this branch. Callers already handle "no camera".

**`record` (AI voice messages) — recommend disabling on compat:**
- `lib/src/features/ai/voice_recording.dart` (`RecordVoiceRecorder`) — either
  port to the record 5.x API or stub the recorder so the composer falls back to
  text-only.

**`file_picker` (v6 API) — keep, adapt:**
- `features/settings/views/shop_settings_screen.dart`,
  `features/catalog/views/product_image_picker.dart`,
  `features/ai/ai_attachment_picker.dart`,
  `data/services/order_document_service.dart` — check `FilePicker.platform`
  argument names against v6.

**`gpt_markdown` — keep, verify:**
- `features/ai/views/ai_assistant_screen.dart` — confirm the widget constructor
  matches the 1.0.x API.

Once `fvm flutter pub get` resolves and `fvm flutter build windows` succeeds,
this file's "needs adapting" list should be empty.
