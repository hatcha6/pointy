# Camera rig

What it takes to know the surveillance stack works without a recorder on the
desk.

```sh
make camera-rig        # up
make camera-rig-test   # the backend tests that need it
make camera-rig-stop   # down
```

| service      | address                     | what it is |
|--------------|-----------------------------|------------|
| `mediamtx`   | `rtsp://localhost:8554/shop`| a real RTSP server carrying real H.264 |
| `publisher`  | —                           | ffmpeg looping a test pattern into it |
| `fake-dvr`   | `http://localhost:8090`     | the JPEG the field actually sent us |
| `fake-onvif` | `http://localhost:8091`     | a box that lies the way cheap boxes lie |

## The finding this rig exists because of

The obvious rig is MediaMTX and nothing else: real RTSP, real H.264, real
ffmpeg, real frames on a real wall. It is worth having and **it cannot catch the
bug that actually shipped.**

The grey pixels ([`4020930e`](../../backend/apps/surveillance/streaming.py)) were
a JPEG framing bug. `_jpeg_frames` scanned for `FFD9` from byte zero, and `FFD9`
is not rare inside a frame that has not ended — quantization tables are raw byte
arrays with no stuffing, so a table holding 255 next to 217 carries a perfectly
good end-of-image marker in the middle of the header. In the field a 677-byte
frame was cut at byte 46 and the remains painted flat grey.

Those bytes came from the **recorder's** encoder. Ours does not produce them:

> 630 ffmpeg encoder configurations — seven frame sizes × three pixel formats ×
> every `-q:v` from 2 to 31 — produced **zero** headers containing `FFD9`.

So every JPEG on the MediaMTX path is one our own ffmpeg wrote, and the pre-fix
demuxer handles all of them perfectly. This is not a hypothesis; it is pinned by
`RealVideoTests.test_the_real_path_cannot_catch_the_grey_pixel_bug`, and it was
measured by reintroducing the original bug and running both halves:

| with the bug reintroduced | result |
|---|---|
| `RealVideoTests` (MediaMTX, real video) | **passes** |
| `TrapFrameTests` (fake DVR) | **fails** — `105 != 23059` |

A MediaMTX-only rig would have shipped the grey pixels a second time.

## How the trap works

`fake_dvr.py` encodes **real video** with ffmpeg, then rewrites two adjacent
high-frequency entries of the first quantization table to `FF D9`. The picture is
unchanged — it decodes pixel-identical to the clean frame — but the header is now
a recorder's header. Three endpoints serve it:

- `/clean/snapshot.jpg?i=N` — untouched
- `/trap/snapshot.jpg?i=N` — the recorder's table; must look identical
- `/broken/snapshot.jpg?i=N` — cut at the false marker, i.e. what the shop saw

`/health` reports `trap_armed`. The tests read it and **refuse to pass** if the
frames have stopped carrying the trap, so the rig can never go quietly vacuous.

## Seeing it in the client

The preview harness paints synthetic **PNG** frames by default, which is fine for
layout and the clock and proves nothing whatsoever about JPEG framing. Point it
at the rig instead:

```sh
make camera-rig
make frontend-cameras-preview
open 'http://localhost:8080/?screen=grey-pixels'   # clean | trap | broken
open 'http://localhost:8080/?screen=wall&source=rig'
```

`?source=` takes `synthetic` (default), `rig`, `rig-clean`, `rig-broken`; `?rig=`
overrides the address. On web the harness polls stills rather than holding an
MJPEG socket — which is what `SurveillanceApiClient` does on web too, so it is
the real path there, not a shortcut around it.

## The ONVIF half

`fake_onvif.py` reproduces, by default and all at once, the three failures
`test_generic_drivers.py` names as what actually breaks an ONVIF integration:

- it **lies about its own address** (`GetCapabilities` returns `192.0.2.77`)
- it sells **Profile S without Profile G** — no replay, no recording search
- it publishes **one profile per encoder**, so 4 cameras answer with 8 profiles

`GetStreamUri` hands back the MediaMTX address, so a driver that survives all
three gets real H.264 at the end rather than stopping at "the XML parsed". Flags
(`--honest-xaddr`, `--profile-g`, `--single-profile`) turn each trap off.

## What it still does not prove

Vendor recording **search and playback** (Hikvision ISAPI, Dahua, Xiongmai
DVRIP), and the digest-auth identity handshake against real firmware. A box with
searchable stored footage is by definition a real premises, so those need real
hardware — `probe_recorder` and `camera_doctor` are the tools for that day.
