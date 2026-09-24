# pointy_camera_wedge

A camera over the counter as a barcode wedge — run entirely in native code.

The camera's video stream, the zxing-cpp decode and the rule that decides
whether a read is trustworthy all run on native threads. Dart hands the library
a port and receives **finished scans** on it, the way it receives keystrokes
from a USB scanner. Nothing else crosses the boundary unless the app asks for
preview frames (the F8 panel, settings).

It replaced a wedge built on `camera_windows` + `flutter_zxing`, which could
only take a *photo* about once a second, save it as a JPEG in the user's
Pictures folder and decode that in Dart. A 1-D barcode needs two agreeing
looks, so reads took seconds, and the photo loop is what made the till lag.

## Platforms

| platform | capture | status |
|---|---|---|
| Windows 7+ | Media Foundation Source Reader (`src/platform/windows/`) | shipped |
| Linux | V4L2 — not written yet | see [Adding Linux](#adding-linux) |
| Android, iOS, macOS, web | — | the app uses `mobile_scanner` there |

## How it works

```
 camera ──► Media Foundation worker thread ──► FrameMailbox ──► decoder thread ──► port ──► Dart
            (copy the grey plane, ask for        (newest frame   (one zxing pass,
             the next frame; ~1 ms)               only, no queue)  confirm, report)
                        ▲
 capture thread ────────┘  opens the camera, watches it, and when it fails —
                           unplugged, busy, privacy-blocked, gone quiet — closes
                           it, says why, waits, and tries again on its own
```

* **Capture** (`src/platform/windows/mf_backend.cpp`): the Source Reader in
  asynchronous mode. The camera's own mode is chosen explicitly — about
  1280x720, at least 15 fps, uncompressed when the camera can manage that and
  MJPEG decoded by Windows when it cannot — then a grey-readable output type is
  set. Autofocus is switched on if the camera has it.
* **Frames** go through a triple buffer (`src/engine/frame_mailbox.h`): the
  decoder always takes the newest frame, so a slow machine skips frames instead
  of falling behind the counter.
* **Decoding** (`src/vision/barcode_reader.cpp`): zxing-cpp 3.1.1, the same
  engine as the backend (`apps/companion/decoding.py`) and the camera lab. Each
  frame gets one pass from a cycle of 0°, 30°, 60° and inverted
  (`src/engine/decode_scheduler.h`); with zxing's own 90° steps every tilt is
  covered in four frames. Each pass reads the frame as zxing would, and 1-D
  codes again from a locally thresholded copy (`AdaptiveBinarize`) — zxing
  thresholds a 1-D scan line with one value for the whole line, which fails on
  a slightly soft barcode on a big grey counter.
* **Misreads** are stopped in the reader before the policy sees them. A drawn
  sweep (EAN-13, UPC-A, UPC-E and QR at small sizes, blur, noise, every 9°)
  found valid-checksum misreads, and three rules came out of it:
  a 1-D value needs 4 agreeing scan lines (zxing's default is 2, which with
  every row scanned means two neighbouring rows of near-identical pixels) and
  a UPC-E 8; when two different 1-D values lie over the same bars in one pass
  the one more lines agree on wins; and QR means Model 2 only, because
  zxing-cpp 3's QR family includes Micro QR, which it found *inside* an
  ordinary QR — and a 2-D code is believed on one read. On 4,380 drawn scenes
  that took misreads from 88 to none. What it reads less often is the small
  and badly blurred code (7% fewer EAN-13 reads per decode cycle, all of them
  at 2 px a module with blur or 3 px with heavy blur); a sharp code reads as
  before. Check `found` *and* `wrong` on the same grid before loosening any of
  the three.
* **Confirmation** (`src/policy/confirmation_policy.cpp`): a 2-D code (Reed-
  Solomon corrected) is believed on one read; EAN/UPC/Code 128/Code 93 need two
  agreeing reads within 600 ms; Codabar, Code 39, ITF and anything unknown need
  three. Each scanned value is held off while it stays in view. This is the
  same rule as the app's `camera_wedge_policy.dart` (used with
  `mobile_scanner`); the two test suites are case for case.
* **Pace**: an idle wedge decodes about five frames a second; any motion or
  read switches it to every frame for a few seconds. Motion only speeds it up,
  never stops it. The decoder runs below normal priority.
* **Scans are typed like a scanner types them**: zxing-cpp 3 reports UPC-A and
  UPC-E in their 13-digit EAN form; this library reports the 12 and 8 digits a
  USB scanner sends, because the catalog matches barcodes exactly.

### Why a port and not a callback

`NativeCallable.listener` reads more naturally, but invoking one after Dart has
closed it is a fatal VM error (`Callback invoked after it has been deleted.`,
`runtime/vm/runtime_entry.cc`) — which is exactly what a camera thread does
when the app exits or hot-restarts mid-frame. Posting to a closed port just
returns false; the library reads that as "nobody is listening" and stops,
releasing the camera. A wedge orphaned that way is reaped before the next one
starts, so it never holds the camera against its successor.

The message layouts are in `src/include/pointy_camera_wedge.h` and mirrored by
`lib/src/native_wedge_events.dart`.

### Device ids

A device id is the Media Foundation symbolic link. The app shows and stores it
as `"<label> <<link>>"` — the shape `camera_windows` used — so a camera a shop
picked before this library is still the one picked after it. The library reads
the link back out of either form (`NormalizeDeviceId`). A picked camera that is
missing is replaced only when exactly one other camera exists.

## Building and testing

The app's Windows build compiles this package through `windows/CMakeLists.txt`
(it is an FFI plugin); nothing is fetched at build time.

The native tests draw real barcodes with zxing's own writer and feed them
through the whole engine on a synthetic camera, so they run anywhere:

```sh
make frontend-camera-wedge-test
```

which is, spelled out:

```sh
cmake -S src -B build/native-tests -DPCW_BUILD_TESTS=ON -DCMAKE_BUILD_TYPE=Release
cmake --build build/native-tests
build/native-tests/pcw_tests
POINTY_CAMERA_WEDGE_LIBRARY=$PWD/build/native-tests/libpointy_camera_wedge.dylib flutter test
```

The last line runs the Dart tests through the real FFI boundary against the
synthetic-camera build (`.so` on Linux). `pcw_tests` also runs clean under
`-fsanitize=address,undefined` and `-fsanitize=thread`.

Synthetic cameras are recipes in the device id, e.g.
`synthetic:ean13=3600523434725;angle=30;pixel=yuy2`,
`synthetic:fail=access_denied`, `synthetic:qr=x;lose_after=20` — see
`src/platform/synthetic/synthetic_backend.cpp`.

### On a real till: `camera_wedge_probe`

The engine on its own, in a console, for checking a camera without installing
the app:

```sh
cmake -S src -B build/probe -DPCW_BUILD_PROBE=ON
cmake --build build/probe --config Release
camera_wedge_probe --list
camera_wedge_probe --device 1 --seconds 120 --snapshot frame.pgm
```

It prints every confirmed scan as it happens, a stats line every second
(frames, decode time, rejected misreads), and `--snapshot` saves what the
camera sees as a greyscale PGM for checking aim and focus. It also cross-
compiles from macOS with [llvm-mingw](https://github.com/mstorsjo/llvm-mingw).

## Adding Linux

1. Write `src/platform/linux/v4l2_backend.cpp` implementing `CaptureBackend`
   (`src/capture/capture_backend.h`): list `/dev/video*` capture devices,
   open one, pick a mode with the same preferences as `Score` in the Windows
   backend, stream with `mmap` buffers on a thread, and hand each frame to the
   `FrameSink` as a `PixelBuffer` (YUYV maps to `kYUY2`, GREY to `kGray8`).
   MJPEG-only cameras need a JPEG decoder (libjpeg-turbo). Everything after
   `OnFrame` — decoding, confirmation, recovery, the port — is shared.
2. In `src/CMakeLists.txt`, select it under `elseif(UNIX AND NOT APPLE)` in
   place of `platform/unsupported/`.
3. Add `linux/CMakeLists.txt` (a copy of `windows/CMakeLists.txt`) and
   `linux: ffiPlugin: true` to `pubspec.yaml`.

The Dart side already opens `libpointy_camera_wedge.so` on Linux, and the app
turns the feature on wherever the library loads and reports a backend.

## Third party

* `src/third_party/zxing-cpp/` — zxing-cpp 3.1.1, Apache-2.0. See its
  `VENDORED.md` for exactly what was taken.
* `src/third_party/dart_api/` — the Dart SDK's `dart_api_dl` headers, BSD-3,
  copied from Dart 3.10.7 (`DART_API_DL_MAJOR_VERSION` 2).
