# POS tour film

A ~1:50 vertical (1080 × 1920) film of the till for TikTok and phones: every
frame of the app is a **real screen recording** of the shipping Flutter screens,
cut to the beat of a licensed track, with an Arabic voice-over.

Output: `../promo/out/daftar-pos-tour.mp4`. Rebuild everything with
`make marketing-pos-tour` (or `./run.sh`).

## Pipeline

| Step | File | What it does |
| --- | --- | --- |
| Script | `script.json` | One scene per feature: caption, narration (`say`, فصحى, voweled for the voice), voice name. |
| Voice | `voice.py` | One WAV per scene, silence trimmed, plus `durations.json`. Default: Microsoft neural TTS (`edge-tts`, `ar-SA-HamedNeural`) → `out/voice/`. `voice.py eleven` uses ElevenLabs v3 (`script.json` → `eleven`, each scene's `tone` as an emotion tag; needs `ELEVENLABS_API_KEY`) → `out/voice-eleven/`; build with `VOICE_DIR=out/voice-eleven node build-tour.mjs`. Library voices need a paid ElevenLabs plan, and publishing needs Starter or above for commercial rights. The text is sent to the chosen service. |
| Invoice page | `invoice/render.sh` | Renders the customer's public invoice page (what the receipt QR opens) with the relay's own template, copied fresh each run, from `invoice/payload.json` — the same 46.20 sale the till rings up. |
| Captures | `capture.js` | Drives the dev harnesses (`frontend/lib/dev/pos_preview.dart` with `&banks=on&links=on&printer=on`, `voucher_menu_preview`, `camera_wedge_preview`, `cameras_preview`) at 1440 × 900 @2x. Widgets are found by their **accessibility label** (`sem.js`), so taps survive layout shifts. Every tap and focus point is logged with its time to `<scene>.json`. |
| Data | `build-tour.mjs` | Gathers script, voice lengths, clips, tap logs and `music.json` into `../promo/src/tour/tour.json`; copies media to `../promo/public/tour/` (git-ignored). |
| Cut | `../promo/src/tour/` | Remotion composition `PosTour`. A virtual camera follows the tap log (`camera.ts`): the window opens as the whole screen and grows into a tall frame as it zooms toward each touch. Cuts snap to the track's beats (`timeline.ts`); music ducks under the voice. |

`probe.js` is the exploration tool used to map a flow before scripting it:
`node probe.js pos_preview '?screen=pos&banks=on' '[["tap","ادفع"],["dump"],["shot","x"]]'`.

## What is composited, and why

Everything on screen is the real app, but two scenes join two real recordings:

- **Counter camera (`wedge`)** — the F8 panel is recorded from
  `camera_wedge_preview` and floated over the till recording, where the app
  docks it; the POS harness has no camera scope installed.
- **Phone (`online`)** — the invoice page is the relay's real template, rendered
  offline (the fake link in the harness does not resolve).

The voucher slip's QR is printed only (it is not on screen); the scene shows the
PIN card, and the narration names the printed QR.

## Music

**Deep Urban** — Eugenio Mininni, from [Mixkit](https://mixkit.co/free-stock-music/tag/technology/),
under the Mixkit Stock Music Free License (commercial use on social media and
online ads, no attribution required; tracks may not be re-registered or claimed).
It is not committed: download it to `../promo/public/tour/music.mp3`.

`music.json` holds the analysis (librosa beat tracking): the drop at 15.51 s (the
hook ends on it), and a jump from 77.21 s to 191.89 s that steps over the
track's near-silent breakdown. Swapping the track means re-running that analysis
and updating `drop`, `jumpFrom`, `jumpTo` and `beats`.

## Numbers reconcile

Seeded cart: 2 cartons of water 30.00 + croissant 3.20 + 2 coffees at 7.25 =
47.70, less 1.50 (rule 1.00 + coupon 0.50) = **46.20**. Cash 50.00 → change
3.80. Split: 20.00 cash + 26.20 card. Credit: 10.00 down → 36.20 owed. The
invoice page shows the same lines and totals.
