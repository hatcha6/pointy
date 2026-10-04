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
| Linux | V4L2, memory-mapped streaming (`src/platform/linux/`) | shipped |
| Android, iOS, macOS, web | — | the app uses `mobile_scanner` there |

Everything but the capture backend — decoding, confirmation, recovery, the
port, the device choice and the ranking of a camera's modes — is one code
base on both desktops.

## How it works

```
 camera ──► backend thread ────────────────► FrameMailbox ──► decoder thread ──► port ──► Dart
            (Media Foundation's worker, or   (newest frame   (one zxing pass,
             the V4L2 poll loop: copy the     only, no queue)  confirm, report)
             grey plane — decoding MJPEG
             first on Linux — ask for more)
                        ▲
 capture thread ────────┘  opens the camera, watches it, and when it fails —
                           unplugged, busy, refused, gone quiet — closes it,
                           says why, waits, and tries again on its own
```

* **Capture on Windows** (`src/platform/windows/mf_backend.cpp`): the Source
  Reader in asynchronous mode. The camera's own mode is chosen explicitly —
  about 1280x720, 30 fps, uncompressed when the camera can manage that and
  MJPEG decoded by Windows when it cannot — then a grey-readable output type is
  set. Autofocus is switched on if the camera has it.
* **Capture on Linux** (`src/platform/linux/v4l2_backend.cpp`): V4L2 straight
  from the kernel — no libv4l, no GStreamer. Cameras are the `/dev/video*`
  nodes that capture and offer a format the wedge reads (a UVC camera's
  metadata node is not one). The mode is chosen by the same ranking as on
  Windows (`src/capture/mode_score.h`), from what `VIDIOC_ENUM_FRAMESIZES` and
  `VIDIOC_ENUM_FRAMEINTERVALS` report; the best eight are tried in turn, and a
  USB bus with no bandwidth left for one (`ENOSPC`) moves on to the next.
  Frames arrive in four memory-mapped buffers on a thread waiting in `poll()`
  on the camera and an eventfd — the eventfd is how a session stops it at
  once, whatever the driver is doing. Frames the driver marks damaged are
  handed back unread. Autofocus is switched on if the camera has it, and the
  capture thread runs below normal priority.
* **MJPEG on Linux** (`src/capture/jpeg_decoder.cpp`): V4L2 hands MJPEG over as
  the camera sent it, and at 720p30 most USB 2 webcams send nothing else, so
  this is the usual path. stb_image decodes it straight to grey. Measured on
  webcam-like 720p frames against libjpeg-turbo (Apple M-series, grey output):
  1.4 ms against 0.7 ms on a typical 75 KB frame, 4.6 against 3.3 on a noisy
  470 KB one, never more than one grey level apart — and stb_image is one
  header, where libjpeg is a system library under two incompatible sonames
  whose absence would stop the whole library loading. Two things a camera
  needs that stb_image does not do: UVC cameras leave the Huffman tables out
  of every frame (stb_image decodes that into garbage without an error;
  measured), so the standard tables are spliced in, and a frame cut short by
  a USB hiccup decodes as zeros (also without an error), so a frame without
  its end marker is dropped.
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
  never stops it. The decoder runs below normal priority (on Linux, nice 10).
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

On Windows a device id is the Media Foundation symbolic link. The app shows
and stores it as `"<label> <<link>>"` — the shape `camera_windows` used — so a
camera a shop picked before this library is still the one picked after it.
The library reads the link back out of either form (`NormalizeDeviceId`). A
picked camera that is missing is replaced only when exactly one other camera
exists.

On Linux `/dev/videoN` follows plug-in order, so the id is a udev link
(`StableIds` in `src/platform/linux/v4l2_rules.h`): the `/dev/v4l/by-id` link
when the camera's USB serial number makes it unique — it then follows the
camera to any port — and otherwise the `/dev/v4l/by-path` link. Many cheap
webcams have no serial, or one every unit shares; two of them would claim one
by-id link, udev would give it to whichever came last, and the till could
quietly read off the cashier's webcam. Tied to the port, it is never the wrong
camera. Without udev (a container) the id is the node itself.

### What a refusal means

`PCW_ERROR_ACCESS_DENIED` is the Windows camera privacy switch on Windows, and
on Linux `EACCES` on `/dev/video*`: the user is not in the `video` group (or
not the active seat's session). The app words them differently, and only
Windows gets a settings button. `EBUSY` is another program streaming, `ENODEV`
an unplug.

## Building and testing

The app's Windows and Linux builds compile this package through
`windows/CMakeLists.txt` and `linux/CMakeLists.txt` (it is an FFI plugin);
nothing is fetched at build time.

The native tests draw real barcodes with zxing's own writer and feed them
through the whole engine on a synthetic camera — MJPEG included, decoded as
the Linux backend decodes it — so they run anywhere:

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
`-fsanitize=address,undefined` and `-fsanitize=thread`; its corrupt-MJPEG
test (1,500 damaged frames) is the one the sanitizers matter most for.

Synthetic cameras are recipes in the device id, e.g.
`synthetic:ean13=3600523434725;angle=30;pixel=yuy2`,
`synthetic:qr=x;pixel=mjpeg_nodht`, `synthetic:fail=access_denied`,
`synthetic:qr=x;lose_after=20` — see
`src/platform/synthetic/synthetic_backend.cpp`.

### The Linux backend on a real kernel

The V4L2 code is tested against real kernel drivers, not a model of them:
vivid (the kernel's own virtual camera, used for V4L2 compliance testing) and
v4l2loopback (a real V4L2 camera fed by `v4l2_loopback_feed`, which writes a
drawn barcode into it). `src/tools/v4l2_scenarios.sh` lists and streams vivid,
pulls its simulated USB plug and expects the wedge back on its own, scans a
barcode sent as YUYV and as MJPEG without Huffman tables, lets a camera go
quiet for the stall watchdog, and runs the probe as a user who may not open
the cameras.

CI runs it on its runner's kernel (`.github/workflows/camera-wedge.yml`).
From any machine with Docker — a Mac included, whose Docker kernel has no
V4L2 at all — the same scenarios boot Ubuntu 24.04's kernel under QEMU
(`src/tools/linux_rig/`):

```sh
make frontend-camera-wedge-linux
```

It leaves nothing behind. The rig's image (Ubuntu's kernel, its modules and
QEMU, about 1.4 GB) is made with `docker commit` rather than a Dockerfile,
because a build also keeps every layer in Docker's build cache, where
deleting the image does not reach it; and the image is removed after the run.
`CAMERA_WEDGE_LINUX_RIG_KEEP=1` keeps it for the next run, and
`make frontend-camera-wedge-linux-clean` removes it then.

### One library for every distro

Releases are built on Ubuntu 24.04; Mint 21 tills run 22.04, and a library
that references one symbol newer than the till's glibc or libstdc++ does not
load at all. So the Linux build links libstdc++ in (nothing C++ crosses the C
ABI), keeps out the glibc symbols a new build machine compiles in unasked
(`src/api/glibc_compat.c`: C23 `strtol`, `arc4random`), and exports nothing
but `pcw_*` (`src/api/exports.map`). `src/tools/check_linux_library.sh` checks
all three and CI fails without them: built on 24.04, the library needs glibc
2.34 and nothing else newer than 22.04 has.

### On a real till: `camera_wedge_probe`

The engine on its own, in a console, for checking a camera without installing
the app:

```sh
cmake -S src -B build/probe -DPCW_BUILD_PROBE=ON
cmake --build build/probe --config Release
camera_wedge_probe --list
camera_wedge_probe --device 1 --seconds 120 --snapshot frame.pgm
camera_wedge_probe --device 1 --seconds 30 --expect 3600523434725
```

It prints every confirmed scan as it happens, a stats line every second
(frames, decode time, rejected misreads), and `--snapshot` saves what the
camera sees as a greyscale PGM for checking aim and focus; `--expect` answers
"does this camera read this code" with an exit status. CI uploads it for both
platforms (`camera-wedge-probe-windows`, `camera-wedge-probe-linux`). The
Windows one also cross-compiles from macOS with
[llvm-mingw](https://github.com/mstorsjo/llvm-mingw).

## Third party

* `src/third_party/zxing-cpp/` — zxing-cpp 3.1.1, Apache-2.0. See its
  `VENDORED.md` for exactly what was taken.
* `src/third_party/stb/` — `stb_image.h` 2.30 (MJPEG decoding, in the product)
  and `stb_image_write.h` 1.16 (test frames only), MIT or public domain. See
  its `VENDORED.md`.
* `src/third_party/dart_api/` — the Dart SDK's `dart_api_dl` headers, BSD-3,
  copied from Dart 3.10.7 (`DART_API_DL_MAJOR_VERSION` 2).
