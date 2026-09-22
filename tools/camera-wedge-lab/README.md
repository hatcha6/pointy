# Camera wedge lab

Can a USB camera on a stand replace the counter's barcode scanner?

```sh
make camera-wedge-lab     # then open http://localhost:8099 in a browser
```

Pick the camera, press Start, hold things under it. Every emitted scan and a
stats snapshot every five seconds are appended to `results.jsonl` beside this
file, so a run can be read while it happens instead of recalled afterwards.

The one number that decides it is **hover → read**: press *Arm timer*, then
place an item. A hardware wedge answers in roughly 100–300 ms and a cashier
does not think about it. Everything else in here exists to explain that number.

## What the knobs are for

| knob | why it is a knob |
|------|------------------|
| `decode at` | zxing reads a downscaled frame fine and cost is quadratic in edge length. The companion page found a 16× win from decoding small and stopping early ([`app.js`](../../backend/apps/companion/web/app.js)). |
| `roi` | A scanner reads a band, not a room. Cropping cuts decode cost and false reads off stray edges. |
| `every` | Attempt rate. "As fast as possible" is the ceiling, not the plan. |
| `tryHarder` | zxing's exhaustive mode: better on bad images, several times slower. |
| `motion gate` | Whether to decode at all when nothing is there. |
| `formats` | A narrow set is faster and produces fewer false reads. |

## Measured so far

A HUE HD Pro (UVC, on its own stand) at 1280×720, decoding an 800×450 region,
on an Apple-silicon Mac in Chrome:

| | |
|---|---|
| decode, `tryHarder` off | **1–3 ms** |
| decode, `tryHarder` on | **4–6 ms** |
| camera delivers | ~70 fps |
| reads | QR **and** EAN-13, both off real objects |

The EAN-13 (`3600523434725`, check digit verified by hand) is the result that
matters: 1-D has none of the alignment help QR carries, and a document camera
reading one at counter height was the thing worth doubting.

**The decoder is nowhere near the constraint.** At 4 ms against a 70 fps
camera there is room for an order of magnitude more work per frame — which is
the budget that pays for rotation tolerance, several exposures, or a retry at
another scale.

### The finding that decides whether this can ship at all

**A camera scan can emit a wrong barcode that passes its own check digit.**
Reading one real EAN-13 repeatedly, `3600523434725` came back as:

    9660323434725      left=966032  right=3434725
    0608713434725      left=060871  right=3434725
    9620723434725      left=962072  right=3434725

**3 wrong values in 24 scans — 12% — and all three pass the EAN-13 check
digit.** The symbology's own error detection does not catch them. At a till
that is the wrong product at the wrong price, with nothing looking amiss on any
screen, and it is the one failure that would make a shop stop trusting the
feature permanently. A hardware scanner has this failure mode too, and far more
rarely.

Note the shape: the right six digits were correct every time and only the
parity-encoded left group was wrong, which is what one blurred, curved or
clipped half of a barcode produces.

The fix is cheap only because the decoder is so fast. The wrong values differ
from each other, so **two independent frames must agree** before a scan is
emitted — at ~80 attempts/s the second read costs about 10 ms. Measured with
the guard on: **408 attempts, 25 hits, 2 emitted, 6 disagreements rejected, 0
misreads emitted.** The traces show it working directly — two hits 156 ms apart
producing no emit, because they disagreed.

**Nothing built on this should ever emit a single unconfirmed read.**

### Rotation: zxing alone is not enough

`tryRotate` covers 90° steps. Between them nothing crosses the bars of a 1-D
code, and a tilted EAN-13 sat unread for **14.7 seconds** — 59 consecutive
failed attempts while perfectly sharp and perfectly still — reading only when
it was nudged.

The rig rotates the frame itself, cycling one angle per attempt rather than
trying all of them per frame: at ~80 attempts/s a 0/30/60° cycle covers every
orientation in **37 ms**, while each decode stays a single cheap pass. Wins are
now recorded at 0°, 30° and 60°, so all three are doing real work.

### The two findings that cost the most time

**1. A motion gate is the wrong question, twice over.** The first version gated
on frame-to-frame difference: an item stops moving the instant you place it, so
it decoded **2 frames in 31 seconds** of an item sitting in view. Rewritten to
compare against a baseline "empty counter", it then *ate the item* — one frame
dips below threshold, the baseline blends toward it, the difference drops
further, and the item is permanently redefined as empty. That showed up as
**2.4 attempts/s against a 70 fps camera, ~97% of frames discarded with an item
in view**, and 5% of attempts hitting, i.e. one read every eight seconds. Both
are the same mistake: treating "has the picture changed" as a proxy for "is
there something to read".

**2. `tryHarder: false` makes 1-D barcodes orientation-sensitive.** With it off
a tilted EAN-13 does not read at all — the linear scanner sweeps a few rows
along one axis and nothing crosses the bars. A cashier puts an item down
however it lands, and a hardware scanner does not care, so on a counter this is
the difference between a scanner and a nuisance. It costs 4 ms instead of 2.

## The finding this rig already produced

The first version gated each decode on **frame-to-frame** difference, which is
the obvious motion gate and is wrong in the way that matters: an item stops
moving the instant you place it under the camera, which is exactly when it
needs decoding. Measured: **2 decode attempts in 31 seconds** of an item
sitting in view.

The gate now asks "does the scene differ from an empty counter?" against a
baseline that drifts slowly towards whatever the scene settles at — so an item
in view keeps being decoded, a burst window covers a hand settling into place,
and shop lighting changing across a day is absorbed instead of triggering it.
The `scene vs empty` readout is that difference, live.

## Why this is a web page and not a Flutter screen

The tills are Windows, and that is where every obvious option falls down. All
of this was read out of the packages, not recalled:

| package | platforms | the catch |
|---------|-----------|-----------|
| `mobile_scanner` 7.2.0 (already in Pointy) | android, ios, macos, web | **no Windows, no Linux** |
| `camera` 0.12.1 | android, ios, web | — |
| `camera_windows` 0.2.6+5 | windows | `throw UnimplementedError('Streaming is not currently supported on Windows')` — `takePicture()` only, which re-inits and writes a file per frame |
| `camera_linux` 0.0.8 | linux | third party, v0.0.x |
| `flutter_webrtc` 1.6.2 | android, ios, macos, **windows**, linux, web | the one API that spans everything; `captureFrame()` writes a PNG to disk and reads it back per frame |
| `flutter_zxing` 3.0.1 | android, ios, macos, windows, linux | decode only, no capture |

So **`getUserMedia` is the only camera API that is genuinely identical on every
platform and works with any UVC camera** — which is what "platform-agnostic and
camera-agnostic" has to mean in practice. Measuring in a browser is therefore
not a shortcut around the real thing; it *is* the portable path, and the same
page can be copied to a Windows till and run there unchanged.

Two constraints that follow, and both are already known in this codebase:

- `getUserMedia` needs a secure context. A shop LAN `http://192.168.x.x` is not
  one; `http://localhost` is. That is why `serve.py` serves from the machine the
  camera is plugged into. The companion page hit the same wall from the other
  side and answered it differently — it uses a file input and the OS camera,
  because a *phone* has no localhost to reach.
- The decoder is **zxing-wasm**, which is zxing-cpp compiled to WebAssembly:
  the same engine as [`apps/companion/decoding.py`](../../backend/apps/companion/decoding.py).
  Read rates measured here therefore transfer to any zxing-cpp decode path. It
  is fetched from a CDN, so a till with no internet falls back to the platform
  `BarcodeDetector` — which Chrome does **not** implement on Windows, so that
  fallback is a comparison point, never the plan.

## Where a scan would go

Nothing here needs inventing. A scan from a non-wedge source already has a
proven route into every screen that can be scanned into:
[`CompanionScanListener`](../../frontend/lib/src/features/companion/companion_scan_listener.dart)
hands a phone's scan to the exact callback the USB wedge feeds, with the same
enabled and route gating. A camera is a third source on the same seam.
