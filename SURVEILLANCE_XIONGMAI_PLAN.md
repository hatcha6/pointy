# Making Xiongmai Live View Actually Work

Remediation plan for the surveillance failure found in the 10–16 Sep 2026 field
export (`pointy-analytics-events-20260916T085736Z.zip`, 417,527 events).

**Status:** W2, W3 and W4 implemented (see §5). W1 (deploy) and W5 (the
nightly windows) outstanding — both need site access, not code.
**Field site:** one grocery, backend + back-office client on **v0.5.2**, one
Xiongmai recorder, 16 cameras, 3 of them flagged as checkout cameras.

---

## 1. What the field actually did

All figures are from `camera.stream` events and `backend.request` rows in the
export. `camera.stream` folds repeated failures per camera into a 5-minute
window (`telemetry.py: DEFAULT_FAILURE_WINDOW_SECONDS`), so **rows written** and
**attempts** are different numbers and both matter.

| | rows written | folded repeats | implied attempts | succeeded |
|---|---|---|---|---|
| `live-snap` (snapshot polling) | 7,441 | ~85,600 | **~93,000** | **0** |
| `live-rtsp` (ffmpeg) | 226 | 2,360 | ~2,590 | **36** |

Cross-check: 95,723 `surveillance-camera-live` backend requests in the same
window. The two sources agree.

**Observed.** The snapshot path has never produced a single frame on this
hardware — not one, in ninety-three thousand attempts. Every failure took
**exactly 6,001 ms** (min 6,001, p50 6,001) and returned `error_kind:
StreamError`, `frames: 0`.

**Observed.** The RTSP path *works*. Five viewing sessions produced real video:

| session | window | attempts | ok | frames | first frame |
|---|---|---|---|---|---|
| 1 | Sep 10 11:22:12–11:25:55 | 27 | 18 | 6,029 | 2.2–5.7 s |
| 2 | Sep 10 23:35:37–23:35:46 | 12 | **9** | 2,922 | 0.02–3.1 s |
| 3 | Sep 12 13:36:40–13:36:54 | 17 | **9** | 3,248 | 0.02–4.8 s |
| 4 | Sep 14 01:28:34–02:05:19 | 152 (+2,327 folded) | **0** | 0 | never |
| 5 | Sep 15 02:03:33–02:04:32 | 18 (+33 folded) | **0** | 0 | never |

Sessions 2 and 3 are independent, days apart, different quality settings — and
both stop at **exactly nine** successful streams out of 12 and 17 attempts.

---

## 2. Root cause

A four-link chain. Three links are already fixed in `main`; the first is not,
and it is the one that produced 99.7% of the traffic.

### Link 1 — the dashboard pins itself to the snapshot path, on purpose

`frontend/lib/src/features/dashboard/view_models/dashboard_cameras_view_model.dart:153`

```dart
/// `smooth: false` is the whole point — it pins this to the recorder's
/// snapshot endpoint, so a dashboard left open overnight costs the server no
/// transcoding.
  fps: framesPerSecond,       // 2
  quality: CameraQuality.sub,
  smooth: false,
```

The class docstring is explicit about why: *"Running an H.264 decode per camera
on a shop mini-PC for hours so an unwatched corner of a screen can be smooth is
the wrong trade."* That reasoning is correct and should survive this fix.

**This is the load.** Three checkout cameras (`17`, `19`, `20`) received 30,773 /
30,770 / 30,164 requests each — 91,707 of 95,723. They are the dashboard tiles,
refreshing at 2 fps, on a screen the back office leaves open all day and most of
the night. The 16-camera wall (`cameras` screen, opened 10 times all week) is
sessions 1–5 above, and nothing else.

### Link 2 — Xiongmai has no snapshot endpoint, and always said so

`backend/apps/surveillance/drivers/xiongmai.py:476`

```python
supports_snapshot = False
```

`xiongmai.py:565` raises `RecorderCapabilityError("This recorder has no snapshot
address; its live view needs ffmpeg on the server.")`

So the dashboard asks, every 500 ms, for something this box does not have.

### Link 3 — v0.5.2 never consulted the declaration *(fixed in v0.5.3)*

`resolve_live_stream` in `backend/apps/surveillance/views.py:108` gained a
`supports_snapshot` parameter in `4020930e` (2026-09-10 17:13). Its own docstring
diagnoses this exact failure. **That commit is in v0.5.3 and later. The site runs
v0.5.2.**

### Link 4 — and the failure cost six seconds each time *(fixed in v0.5.3)*

`SnapshotSource.frames` in `backend/apps/surveillance/streaming.py` now raises
immediately on `RecorderCapabilityError`. In v0.5.2 that exception fell through
to the generic `RecorderError` branch, which retried four times sleeping
1 s + 2 s + 3 s before giving up — **6.001 s, holding one ASGI threadpool thread**,
which is the whole of the 160.1 request-hours and the eight
`RuntimeError: can't start new thread` in the export.

### What the v0.5.2 site is missing

| commit | date | what it fixes | first tag |
|---|---|---|---|
| `4020930e` | Sep 10 17:13 | `supports_snapshot` routing, instant capability failure, recorder circuit breaker | **v0.5.3** |
| `5fc5c419` | Sep 10 17:14 | telemetry queue shipping three-week-old events | **v0.5.3** |

The site upgraded 0.5.1 → 0.5.2 at **11:19:40 on 10 September**. The fix landed
**five hours and fifty-four minutes later**. Tags now run to v0.5.9.

---

## 3. Why upgrading is necessary but not sufficient

`resolve_live_stream` resolves the conflict in Link 1 by **overriding the
client**:

```python
if not supports_snapshot:
    # No fallback exists on this hardware: RTSP or nothing.
    return True, fps
```

Correct as a way to stop a guaranteed failure. But applied to the dashboard it
produces precisely the outcome the dashboard was written to avoid: **three
permanent ffmpeg H.264 decodes on the shop's back-office mini-PC, 24 hours a
day** — a machine the same export shows already rendering 50.0% slow frames.

Two further interactions fall out of it:

- **Process budget.** `POINTY_SURVEILLANCE_MAX_FFMPEG` defaults to 12. Dashboard
  (3, permanent) + wall (16, on open) = 19. The wall will start handing out
  "Too many camera streams are already running."
- **The recorder's own ceiling.** Nine, on the evidence above. Even inside the
  budget, tiles 10–16 fail.

So the upgrade converts ~93,000 cheap guaranteed failures into 3 permanent
transcodes plus a wall that fails above nine tiles. Better, but not "working".

---

## 4. Two more defects the data exposes

### 4.1 The recorder serves about nine concurrent RTSP sessions

**Observed.** Sessions 2 and 3: 9 successes each, from 12 and 17 simultaneous
attempts. Session 1: 18 successes across two waves several minutes apart.
**Derived.** A hard ceiling around 8–9 concurrent streams.

**It is not our cap.** `transcode.reserve_slot()` allows 12 and raises
`"Too many camera streams..."`, which `_record_failure` maps to
`telemetry.BUSY`. There are **zero `BUSY` outcomes** in 93,000 failures — the
ffmpeg cap was never reached. The refusal comes from the DVR.

**Hypothesis (needs §5 to confirm):** a per-device or per-account simultaneous
stream limit in the Xiongmai firmware, which is common on this family.

Nothing in the codebase budgets streams **per recorder**. The wall opens every
enabled camera at once (`camera_wall_view_model.dart:96`,
`loadCameras(enabledOnly: true)` — all of them, the grid only decides columns),
so on a 16-camera recorder seven tiles are guaranteed to fail on every open.

### 4.2 Failures are unclassifiable, which is why this took a forensic export

`backend/apps/surveillance/views.py:267`

```python
_OUTCOMES = {
    "RecorderUnreachable": telemetry.UNREACHABLE,
    "RecorderAuthError": telemetry.AUTH,
    "TranscodeUnavailable": telemetry.NO_FFMPEG,
}

def _record_failure(report, exc):
    name = exc.__class__.__name__
    report.outcome = _OUTCOMES.get(name, telemetry.FAILED)
```

Classification is on the **exception class**. Every snapshot and every ffmpeg
failure arrives as `StreamError`, so it lands on `FAILED`. Across 93,000 field
failures the distribution of `outcome` is: `failed` 7,631, `ok` 36. The
`UNREACHABLE` / `AUTH` / `UNSUPPORTED` / `BUSY` vocabulary in `telemetry.py` is
**dead — zero occurrences**.

Meanwhile `streaming.py:468 _humanize_ffmpeg_error` *already* distinguishes
401/unauthorized, connection refused, timeout, 404 and 5xx — and the result is
used only for the message shown on screen, then discarded.

**Consequence, concretely:** sessions 4 and 5 — 2,479 RTSP attempts, zero first
frames, ~3.4 s each, at low concurrency, in two late-night windows — **cannot be
explained from the telemetry.** Whether the DVR was powered down at closing,
rebooting on a schedule, refusing auth, or refusing the channel is exactly what
ffmpeg's stderr says, and stderr is captured (`transcode.ERROR_LINES_KEPT = 40`),
logged at `logger.info`, and never carried into the event.

---

## 5. The work

Ordered so that each step is independently shippable and each one's effect is
measurable in the next export.

### W1 — Deploy v0.5.9 to the field site *(no code; do this first)*

Stops ~93,000 guaranteed failures a week and the thread-exhaustion class. Ships
the breaker, so W2's ffmpeg risk is bounded while W2 is being built.

- Roll out via the existing fleet mechanism, canary this site first.
- **Before:** confirm `ffmpeg` is present in the deployed image. The field proves
  it was on 10 Sep (36 RTSP streams decoded), but v0.5.3+ makes ffmpeg the *only*
  live path on this hardware — if it is ever missing, live view goes from
  "broken slowly" to "broken instantly", and a 503 is the whole feature.
- **After:** expect `live-snap` rows for this recorder to fall to zero and
  `live-rtsp` to become the whole population. Expect ffmpeg process count to sit
  at 3 permanently. That is W2's problem.
- **Watch:** `RuntimeError: can't start new thread` must go to zero.

### W2 — A cheap live path for recorders with no snapshot endpoint ✅ **DONE**

The dashboard's requirement is *stills at ~2 fps with no per-viewer transcode*.
The Xiongmai constraint is *RTSP or nothing*. Both are now satisfied.

**What shipped.** `smooth=false` means **cheap**, not "the snapshot endpoint",
and the server picks the cheapest pipeline the recorder can actually serve:

| | recorder serves stills | recorder does not (Xiongmai) |
|---|---|---|
| `smooth=false` | `LivePath.SNAPSHOT` — HTTP, no transcode | **`LivePath.STILL`** — keyframes sampled from RTSP |
| `smooth` unset/true | `LivePath.SMOOTH` — full decode | `LivePath.SMOOTH` — full decode |
| no ffmpeg, no stills | immediate 503, unchanged | immediate 503, unchanged |

- `resolve_live_stream` returns a three-valued `LivePath` instead of a bool
  (`backend/apps/surveillance/views.py`). The previous fix answered a request for
  cheap with a full decode; this answers it with a cheap one.
- `SampledRtspSource` (`streaming.py`) runs **one** ffmpeg per camera through the
  existing broker, so every dashboard on every till shares it.
- `transcode.open_mjpeg_stills` decodes **keyframes only** (`-skip_frame nokey`,
  before `-i`, where it is a decoder option) and emits exactly what it decoded
  (`-fps_mode passthrough`, falling back to `-vsync 0` below ffmpeg 5.1). No
  `-r`: a target rate makes ffmpeg duplicate the last keyframe to fill gaps, so
  the tile would pay an encode and a frame on the wire for a picture it has.
- **Rate and width are the server's numbers, not the client's**
  (`POINTY_SURVEILLANCE_STILL_FPS`=2, `POINTY_SURVEILLANCE_STILL_WIDTH`=640).
  This is what makes sharing real: a 1024-wide dashboard and a 1280-wide one
  compute tile widths a few dozen pixels apart, and *any* scheme that keeps the
  client's number — rounded or bucketed, however coarsely — splits them onto two
  ffmpeg processes as soon as they straddle a boundary. A first attempt bucketed
  to 160 px and the sharing test caught it: widths 300/320/331 produced two
  pipelines. Scaling only ever shrinks (`scale='min(640,iw)':-2`), so a 492-wide
  sub-stream passes through untouched.
- New `skipped_frames` metric on `camera.stream`: non-zero means this recorder's
  keyframe interval is *shorter* than a tile needs, which is the one case where
  the path is still paying for pictures nobody sees.

**Verified against a real ffmpeg 8.0.1**, not just asserted — a 10 s 492×402
clip with `-g 30` at 15 fps (150 frames, 5 keyframes):

| | JPEG frames out | CPU |
|---|---|---|
| full decode, `-r 2` | 22 | 0.05 s |
| keyframes only | **5** | **0.01 s** |

Exactly the 5 keyframes, no duplication, output geometry 492×402 (no upscale to
640). The CPU figures are a synthetic clip and are small enough to be noisy in
absolute terms; the ratio is the point, and it follows the 5-of-150 decode.

**Tests:** 189 in `apps.surveillance`, green — a dashboard request reaches the
stills path and never `open_mjpeg_stream`; three viewers at three tile widths
open **one** pipeline; `-skip_frame nokey` precedes `-i`; no `-r`; no upscale;
the rate ignores whatever the client asked; snapshot-capable recorders are
untouched; keyframes arriving faster than the tile needs are dropped and counted.

**Escape hatch.** `POINTY_SURVEILLANCE_STILL_FPS=0` turns the sampled path off
and restores full decodes, so a shop whose recorder does not mark keyframes the
way ffmpeg expects can be recovered without waiting for a release.

**Known limit.** The broker declares a producer stalled after
`POINTY_SURVEILLANCE_STALL_SECONDS` (20 s). Because this path only emits on
keyframes, a recorder with a keyframe interval longer than ~20 s would be read as
stalled. DVR GOPs in this market are 1–4 s, so this is a real but distant edge;
if a box ever shows it, the stall window for this path should be expressed in
keyframe intervals rather than seconds.

**Interaction with W3.** A stills pipeline still occupies one of the 12
`POINTY_SURVEILLANCE_MAX_FFMPEG` slots even though it costs a fraction of a full
decode. Three checkout cameras therefore leave the wall 9 slots — which happens
to match the recorder's own ceiling, but by accident. W3 should decide whether
the cap is weighted by path or split per purpose.

### W3 — Budget streams per recorder ✅ **DONE**

**What shipped.** `backend/apps/surveillance/budget.py`: a per-recorder session
budget, held for a *producer's* life rather than a viewer's, so three tills
sharing one stream consume one slot.

- `Recorder.max_concurrent_streams` (migration `0003`, nullable, `db_default`
  for the zero-downtime window) for the installer who knows the number.
- **When nobody knows it, we learn it.** A cold failure — zero frames — on a
  recorder that was already serving `N` streams is evidence the box tops out at
  `N`, so that becomes the ceiling. Only ever lowered, so repeated evidence
  converges instead of oscillating; raised only by a stream that *succeeded*
  above the learned limit, so one bad evening cannot cap a recorder for a week.
  Floor of 4: a single timeout at low concurrency is a blip, and a learned
  ceiling of 1 would be a worse bug than the one this fixes.
- **Two guards, deliberately.** The authoritative reservation lives in the
  source, where the lifetime is right. But the broker paints the last-known
  frame on a cold start, so a producer that fails a moment later has already
  answered **200** — correct for a camera that blinked, wrong for a full
  recorder, where a stale picture is not an answer to "wait five seconds". So
  the request path also calls `budget.check()` before subscribing, and skips it
  when `broker.has_producer(key)` — a viewer joining a running stream costs the
  recorder nothing and is never refused. This was found by a test, not by
  reasoning.
- A refusal is **503 + `Retry-After`** with `code: recorder_at_capacity`, which
  `mjpeg_view.dart` already honours over its own backoff ladder. It deliberately
  does **not** trip the breaker: a recorder that is full is answering, and
  pausing it would take down the streams that are working.
- The tile now says <bdi>جهاز التسجيل ممتلئ</bdi> ("the recorder is full") rather
  than "the stream failed", because seven black tiles on a sixteen-camera wall
  read as seven broken cameras instead of one full DVR.
- Playback and export take no slot: a manager reviewing an incident is one
  stream, not repeated by a retrying wall.
- The learned ceiling is forgotten when the recorder is edited or re-probed — it
  was learned about the box at the old address, on the old firmware.

**Tests (12):** an unmeasured recorder is never limited; an installer's number is
obeyed and beats the guess; slots are reusable and double-release is harmless;
the ceiling is learned, converges downward, respects the floor, and is raised by
success; a failure with no healthy neighbours teaches nothing (that is the
breaker's job); a stream that delivered frames and then died teaches nothing
(that is the network); end-to-end, a full recorder answers 503 +
`recorder_at_capacity` + `Retry-After` and does not trip the breaker.

### W4 — Make a stream failure say what happened ✅ **DONE**

**What shipped.**

- `StreamError` now carries `reason` (a closed vocabulary — `StreamFailure`:
  auth, unreachable, timeout, refused, no_channel, no_video, unreadable,
  stalled, busy, unsupported, unknown) and `detail`. Every raise site names one.
- `classify_ffmpeg_error` returns the reason **and** the sentence from the same
  match, so the row and the message the shop is shown can never disagree. The
  sentences were already there; only the classification was being thrown away.
- `_record_failure` classifies on the reason first and the exception class only
  as a fallback. `auth` / `unreachable` / `busy` / `unsupported` are live
  vocabulary again rather than unreachable code.
- `camera.stream` now emits **`camera_id`** and **`recorder_id`** — both were on
  `StreamReport` all along and neither was written out. Their absence is why
  this analysis had to infer which camera failed by joining request paths on
  timestamps.
- The failure fold is keyed on `(camera_id, outcome, reason)`. Two diagnoses
  inside one window are two facts; folding the second into the first is how a
  recorder that changed failure mode looks like one that did not.

**Credentials.** `transcode.redact_secrets` strips recorder passwords at the
point stderr is *read*, which covers the telemetry row and the `logger.info`
line in one guard — the log was leaking them too. Both shapes go: the userinfo
in `rtsp://user:pass@host` and the `user=…&password=…` Xiongmai repeats in the
path. A test asserts the password is gone and that the host and the `401` survive,
because a redaction that destroys the diagnosis is not a fix.

**Tests (10):** each ffmpeg signature maps to its reason and its sentence; an
unrecognised complaint is kept rather than flattened; silence is its own reason;
reasons decide the outcome; `timeout` and `refused` share a bucket while keeping
their reason; an unnamed failure records `unknown` rather than nothing; rows name
the camera and recorder; two diagnoses in one window write two rows; a password
never reaches the log or a row; an innocent line is left alone.

### W5 — Explain the two nightly windows

Not a code change yet — a question W4 answers. Sessions 4 and 5 (2,479 attempts,
zero first frames, ~3.4 s each, Sep 14 01:28–02:05 and Sep 15 02:03–02:04) sit
right at the shop's closing time (بحر closed the till at 02:06 and 02:13 those
nights).

Candidates, none of them established:

- the DVR is on a circuit that is switched off at closing;
- a scheduled nightly reboot or maintenance window in the firmware;
- a session/auth expiry that only shows up after hours of uptime;
- the network switch the DVR sits behind losing power.

`~3.4 s with no first frame` is too slow for a refused TCP connection on a LAN
and too fast for a dead host's connect timeout, which is why guessing is not
good enough here.

**Do this now, before W4 ships:** run
`python manage.py camera_doctor` (and `probe_recorder`) at the site *during* the
02:00 window. That command already exists and exercises the path directly.
Correlate with the shop's closing routine — one question to the owner about what
gets switched off at close may settle it without any code.

---

## 6. Sequencing

| | Work | Depends on | Effect you can measure |
|---|---|---|---|
| **Done** | W2 sampled-stills path | — | a new `live-still` mode in `camera.stream`; one pipeline per camera however many tills watch |
| **Done** | W4 failure classification | — | `outcome` stops being 100% `failed`; `camera_id`, `recorder_id` and `reason` on every row |
| **Done** | W3 per-recorder budget | W4 | a full recorder answers 503 + `Retry-After` instead of leaving tiles black |
| **Now** | W1 deploy v0.5.9 + this change | — | `live-snap` → 0 rows; thread errors → 0; camera share of backend time collapses |
| **Now** | W5 `camera_doctor` at 02:00 | site access | the nightly window is named |

W1 and W5 are what is left, and neither is code: one is a rollout, the other is
a question for the shop and one run of `camera_doctor` at closing time.

---

## 7. How we will know it worked

From the next weekly export, for this recorder:

| Metric | Now | Target |
|---|---|---|
| `camera.stream` success rate | **0.04%** (36 / ~95,600) | > 95% of attempts a human initiated |
| Implied attempts / week | ~95,600 | < 5,000 |
| `surveillance-*` share of backend request time | **98.5%** | < 5% |
| `RuntimeError: can't start new thread` | 8 | 0 |
| ffmpeg processes with the dashboard open | n/a (0) | 1 per checkout camera, not per viewer |
| Wall tiles that show a picture (16 cameras) | 9 | 16, or 9 live + 7 stills, and never a blank |
| First-frame latency p50 | 2.8 s | < 1.0 s warm |
| Failures with a `reason` that is not `unknown` | 0% | > 90% |

---

## 8. Things I could not determine, and what would settle them

| Question | Why the telemetry can't answer it | What settles it |
|---|---|---|
| Why RTSP failed 100% in the two nightly windows | ffmpeg stderr is captured and never recorded | W4, or `camera_doctor` run at 02:00 |
| Whether the ~9 ceiling is per-account, per-device or bandwidth | no per-recorder concurrency telemetry, and `camera_id` is not emitted | W3's learning probe; or two simultaneous logins against the box |
| Whether the wall's 7 extra attempts cost the DVR anything | no recorder-side metrics | vendor docs / observation during `camera_doctor` |
| Whether ffmpeg is in the currently deployed image | no event carries it | `surveillance/status/` returns `ffmpeg_version`; read it before W1 |

---

## 9. Scope note

This plan covers the surveillance failure only. The same field export produced
other findings — receipt numbers burning ~32 per backend restart, credit sales
with no customer attached, pack-level purchase costs, `trace_id` empty on all
417,527 events — which are tracked separately and deliberately not mixed in here.
