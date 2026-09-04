# Companion Camera — turning any phone into a Pointy camera

## Why

Pointy cannot ship on the App Store or Play Store, and most Libyan shop staff
carry iPhones. Every image-shaped feature we have is therefore gated behind a
device that cannot install the app:

- **Payment-terminal receipts are unscannable.** Every shop has a *laser* wedge
  scanner, which cannot read the 2-D QR the Moamalat terminal prints. The
  card-receipt validation dialog (`card_receipt_validation_dialog.dart`) already
  offers a camera path, but only on a device running our app — so on a Windows
  till it is dead, and the cashier types the URL by hand or skips validation.
- **Product photos** require the picture to reach the till: photograph on a
  phone, transfer by cable/WhatsApp, then browse to it in the product form.
- **AI vision** (invoice intake, "what is this product", PO-from-invoice) is the
  most image-hungry feature we have and the hardest to feed from a desktop till.

A phone is already in every pocket, already on the shop WiFi, and already has a
better camera than anything else in the building. The gap is only that it has no
way to *become* part of the till.

## What we build

A pairing handshake and a tiny web page. The till shows a QR; a phone scans it
with its stock camera app; the phone opens a page on the shop LAN that is a
camera for the till. Scans and photos land in the till in under a second.

Three usage modes, in decreasing order of how often they will fire:

1. **Live scan (push).** The phone is a wireless barcode/QR scanner. Whatever it
   reads is delivered to the till exactly as if a wedge scanner had typed it —
   into the POS cart, the purchasing draft, the stock count, the card-receipt
   dialog. This is what unblocks payment receipts.
2. **Requested capture (pull).** The till asks for a specific photo ("صوّر: علبة
   تونة 400غ"). The phone's page switches to that prompt; the photo attaches
   itself to the right product/PO/job with no further picking on either side.
3. **Free capture.** The phone sends a photo to the till's AI composer or to a
   general inbox, for invoice intake and vision questions.

## Where it is served: the Django backend, not the Flutter app

The backend, for four reasons that are each individually decisive:

- **It is the only always-on, single, well-known address on the LAN.** Tills
  sleep, get closed, get moved, and there are several of them. A phone must not
  have to know which till it is pointed at, or find it again after a reboot.
- **Serving from Flutter means embedding an HTTP server in the desktop app**:
  per-platform socket binding, a Windows Firewall prompt on every till (a known
  disaster in shops), a different port per till, and a separate TLS identity per
  till. It also dies the moment the app closes.
- **The LAN plumbing already exists and is already correct.** `request_is_lan_local`
  (`apps/core/discovery.py`) is the audited gate that rejects relayed requests —
  the same one that keeps client installers off the internet. The `web` nginx
  already serves the shop LAN on :80 with same-origin `/api`. `edge` on :8000
  already streams (SSE, no buffering) and already survives a live update.
- **Attachment storage, image normalization and the AI pipeline are all backend
  side already.** A photo that arrives at the backend is one step from being an
  `Attachment`; a photo that arrives at a till has to be uploaded again.

The *pairing* is still initiated from the till, because the till is what needs
the result. The till POSTs for a pairing, gets a URL back, and renders the QR
locally with the existing `PointyQrImage`.

The page is served by **Django** at `/c/` (a static bundle inside the backend
image, like `apps/clients` serves installers), and `web` nginx proxies `/c/`
through so both `http://<ip>/c/…` and `http://<ip>:8000/c/…` work. One source of
truth, no duplication into the nginx image, and the QR can safely encode the
`:8000` origin the till itself is already talking to — an address that is proven
reachable at the moment the QR is drawn.

## The constraint that shapes everything: secure context

`getUserMedia` — live video, continuous scanning — is **only available in a
secure context**: HTTPS, `file://`, or `localhost`. A page on
`http://192.168.1.50:8000` cannot open a video stream on iOS Safari or Android
Chrome. There is no flag, no exception for private IPs, and this has not moved.

What *does* work over plain HTTP is `<input type="file" accept="image/*">`. On
iOS that raises the system sheet with "Take Photo"; on Android, with
`capture="environment"`, it opens the camera directly. This is not a web API
being granted a capability — it is the OS camera handing back a file — so no
secure context is required.

That gives us a **two-tier ladder**, and the important realisation is that the
lower tier already covers almost the whole brief:

| Need | Still-photo tier (plain HTTP, zero setup) | Live tier (HTTPS) |
|---|---|---|
| Photograph a product | ✅ | ✅ |
| Photograph an invoice for the AI | ✅ | ✅ |
| Scan the payment-terminal QR | ✅ — the receipt is static, one photo decodes it | ✅ |
| Scan one product barcode | ✅ ~2–3 s | ✅ instant |
| Scan fifty barcodes in a row | ✗ painful | ✅ |

So we ship the still-photo tier as the floor: it needs no certificate, no DNS,
no internet, and no setup on the phone at all — which is exactly the property
Libya's power and connectivity reality demands. HTTPS is then a pure *speed*
upgrade for repeated scanning, not a prerequisite for the feature to exist.

Decoding happens **in the page**, not on the server: a bundled `zxing-wasm`
reads the barcode off the captured still on-device. A scan is therefore a ~40
byte POST rather than a 4 MB upload, and it works with no internet.

## Components

### 1. `apps/companion` (Django)

Models:

- `CompanionPairing` — short-lived, single-use handshake. 8-char code, 120 s TTL,
  bound to the creating user and a channel id. Consumed on first claim.
- `CompanionDevice` — a paired phone. `token_hash` (sha256; the raw token is
  never stored), label, paired_by, register_session, last_seen_at, revoked_at,
  user_agent, address.
- `CompanionCaptureRequest` — a till-initiated ask: owner_type/owner_id/role,
  a human prompt, status, expires_at.
- `CompanionEvent` — the durable inbox. Every scan and capture is persisted with
  a monotonic cursor before it is published, so a till whose stream dropped
  replays instead of losing the scan.

Till-side endpoints (normal authenticated session):

    POST   /api/companion/pairings/          -> {code, url, expires_at, channel}
    GET    /api/companion/stream/            -> SSE of this till's events
    GET    /api/companion/events/?since=     -> polling fallback
    GET    /api/companion/devices/           -> paired phones
    DELETE /api/companion/devices/<id>/      -> revoke
    POST   /api/companion/capture-requests/  -> ask the phone for a specific photo

Phone-side endpoints (companion token, LAN-only, no Django session):

    POST /api/companion/pair/       -> exchange pairing code for a device token
    GET  /api/companion/context/    -> what the till wants right now
    POST /api/companion/scans/      -> {value, format}
    POST /api/companion/captures/   -> multipart image -> Attachment + event

Transport: Redis pub/sub, one channel per till (`companion:chan:<id>`), with the
event row written first so the pub/sub message is only ever a *hint* to go read.
Losing Redis degrades to polling; it never loses a scan.

### 2. The page (`apps/companion/web/`)

No framework. `index.html` + `app.js` + `zxing-wasm`, Arabic RTL, brand palette,
served with long-lived cache headers on the hashed assets and `no-store` on the
shell. Target: first paint well under a second on shop WiFi.

- Token comes in on the URL fragment, moves immediately to `localStorage`, and
  the fragment is stripped — so the address bar, history and any screenshot of
  the phone stop carrying a credential after the first load.
- Photos are downscaled and re-encoded in a canvas (long edge 1600 px, JPEG
  q0.8) before upload. A 4 MB iPhone HEIC becomes ~200 KB, which is the
  difference between a snappy LAN round-trip and a stall.
- Barcodes decode locally; the page beeps and vibrates the moment it reads one,
  so the operator gets feedback without waiting for the network.
- The page shows what the till is asking for, and what it last sent, so the
  operator can see their scan landed.

### 3. Flutter till side

- `CompanionBridge` — owns the SSE subscription (reusing the AI chat's proven
  streaming client), exposes `Stream<CompanionEvent>`, falls back to polling.
- Companion scans are delivered **into the existing scan path**, i.e. the same
  `onBarcodeScanned` callbacks `BarcodeScanListener` already feeds. POS,
  purchasing, stock count and the card-receipt dialog therefore gain phone
  scanning without any of them learning what a companion is.
- A "phone camera" affordance on the product image picker, the AI composer, the
  card-receipt dialog and supplier-invoice intake.
- A pairing sheet (`PointyQrImage`) and a paired-devices list in settings.

### 4. Security

- **Pairing code**: single-use, 120 s, rate-limited per user and per address. A
  QR photographed off the till screen is worthless once claimed or expired.
- **Device token**: 32 random bytes, stored hashed, sent as
  `Authorization: Companion <token>`. In the URL exactly once, in the fragment
  (never sent to the server in a request line, never logged by nginx).
- **Scope**: a companion token is *not* a login. A dedicated authentication
  class sets `request.companion_device` and leaves `request.user` anonymous, so
  `HasPointyPermission` can never be satisfied by a phone. A companion can post
  a scan and a photo to its own channel. It cannot read the catalog, see money,
  or list customers. This matters because phones get lost.
- **LAN-only**: `request_is_lan_local` on every companion endpoint, so the
  relay/internet path is closed by construction, not by configuration.
- **Lifetime**: alive until revoked, until the paired register session closes,
  or after a configurable idle window (default 24 h), renewed on use.
- **Uploads**: image content-types only, sniffed not trusted, size-capped, with
  a per-device hourly quota so a wedged phone cannot fill the disk.

## What shipped (phase 1)

Backend `apps/companion`: the four models above, the till and phone endpoints,
the Redis-cursor stream, the server-side decoder, per-IP pairing and per-device
upload throttles, a nightly purge task, and 51 tests covering pairing, single-use
codes, the isolation boundary, scan delivery, targeted and free captures, stream
replay, decoding photographed barcodes, and the page's own LAN gate.

Page `apps/companion/web/`: 27 KB of hand-written Arabic RTL HTML/CSS/JS plus a
vendored jsQR, served by Django at `/c/` and proxied by the web front door.

Flutter: `CompanionBridge` (SSE with backoff, polling fallback, cursor replay,
nothing held open when no phone is paired — 10 tests), a `CompanionScope` so no
screen needs a new constructor parameter, the pairing sheet, the status button,
the capture sheet, and wiring into POS, purchasing, stock count, the
card-receipt dialog, the product image picker and the AI composer.

### Decoding: what a real phone actually needed

The first build decoded only in the browser, and on a real iPhone it read
neither a photographed EAN-13 nor a photographed receipt QR. Two separate
causes, both fixed:

**It was far too slow.** The ladder ran worst-size-first (1000 -> 1600 -> 640),
tried both polarities at every size, and kept going after a hit: 782 ms measured
on a desktop for a 12 MP frame, several seconds on a phone. Cheapest-first with
an early exit reads the same frame in 98 ms.

**jsQR was not good enough.** It is QR-only — so on iOS, which has no
`BarcodeDetector`, no 1-D barcode could ever decode — and it is a clean-image
decoder that also failed on a real handheld photo of a QR. A miss now uploads
one downscaled frame to `POST /api/companion/decode/`, where zxing-cpp reads it
(~145 ms on a full 12 MP frame; manylinux + macOS wheels for cp310-cp314, no
system libraries). On the field test that path resolved both codes.

Because zxing wins on iOS anyway, the in-page ladder is now a single 480-pixel
pass: it costs ~50 ms and wins outright on a clean code with no round trip,
while anything harder goes straight to the decoder that will actually read it.

## Live scanning — considered and ruled out (2026-09-04)

Continuous "point it and it beeps" scanning would need `getUserMedia`, which
needs a secure context, which on a shop LAN means giving the installation its
own certificate: a per-installation CA, a leaf carrying the LAN IPs as SANs,
an `:8443` listener, rotation when DHCP moves the address, and a one-time trust
step on every staff phone — either three taps through Safari's "not private"
warning or a CA profile install.

**Decided out of scope.** The still-photo tier needs nothing at all: scan the QR
and it works, with no certificate, no warning, no setup and no internet. Live
scanning is strictly faster but charges every phone a setup tax and puts a
frightening browser warning in front of non-technical staff, which is a real
support cost. It only starts to pay for itself if staff scan long *runs* of
items rather than the occasional receipt, product photo or invoice — and that is
not what this was built for.

Worth knowing if it is ever revisited: the shutter is not the slow part we can
fix. Decoding is already ~100 ms; the remaining second or two is iOS opening its
own camera app, and no amount of work on our side touches that. Live video is
the only thing that removes it, which is exactly why it is the only route to a
genuinely sub-second scan.
