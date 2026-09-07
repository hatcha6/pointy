# Surveillance (كاميرات المراقبة) — Hikvision / Dahua DVR integration

Live camera wall, invoice-linked playback, and clip export, driven by the shop's
own DVR/NVR over the LAN. Nothing here is a camera product — it is the *till's*
view of the camera, which is the part no DVR vendor ships: a receipt that plays
back the moment it was rung up.

## Why this is the shape it is

**Every camera in Libya is a Hikvision or a Dahua clone.** That is not a
simplification for v1; it is the market. Two drivers cover it, and a third would
be speculative work. Both speak HTTP digest auth on port 80 and RTSP on 554, so
the two drivers differ only in paths and time formats.

**The backend holds the credentials, the client never does.** A DVR password is
the keys to the shop. Handing it to every till so the till can pull RTSP would
put it in shared_preferences on machines cashiers use. So every byte of video
goes through the backend, which is also what makes playback work over the relay
tunnel when the owner is at home.

**The wire format to the client is MJPEG (`multipart/x-mixed-replace`), for both
live and playback.** One format, one client widget, one code path. It needs no
video codec on the client — decisive, because the tills are Windows machines
(some of them Windows 7 on the `compat/win8` branch) where every Flutter video
plugin is a liability, and because a dropped frame in MJPEG costs one frame
rather than resynchronising a stream.

**Nothing here decides the frame rate except the hardware.**

| Surface | Source | ffmpeg | Ceiling |
|---|---|---|---|
| Live (default) | RTSP sub-stream → MJPEG | yes | 60 |
| Live (fallback) | HTTP snapshot polling | no | 8 |
| Playback | RTSP playback URL (time-bounded) → MJPEG | yes | 60 |
| Export | RTSP playback URL → fragmented MP4, `-c copy` | yes | — |
| Still | first frame of a playback stream | yes | — |

A recorder that streams 30fps must reach the screen at 30fps, nine at a time.
The two live paths have genuinely different ceilings, and that is physics rather
than policy: snapshot polling costs an HTTP round trip per frame, so thirty
stills a second across nine channels simply stops a DVR answering. So the RTSP
path is the default wherever ffmpeg exists, snapshot polling is the fallback
capped at 8, and `views.resolve_live_stream` is the four lines that say so. The
server reports its real ceiling as `max_live_fps` and the client asks for that
rather than assuming a number we picked years ago.

ffmpeg is detected at runtime (`surveillance.transcode.ffmpeg_available`) and the
capability is reported to the client, which hides what it cannot do rather than
offering a button that fails. Live therefore works on any install; the image
ships ffmpeg so in practice everything works.

**The wall scrolls, it does not paginate.** Page numbers make you remember which
page the back door was on. The tile-size choice sets a target width and the
column count falls out of the viewport, so one setting gives four across on a
monitor and one on a phone with no breakpoint written anywhere.

**One upstream puller per camera, however many people are watching.** A shop with
four tills all showing the wall would otherwise hit the DVR with 4× the
snapshots. `streaming.FrameBroker` keys a producer thread by
(camera, mode, quality, time-window), refcounts subscribers, and lingers briefly
after the last one leaves so flipping between screens does not restart ffmpeg.

**The device's clock is not our clock.** Dahua playback URLs take *device-local*
time and Hikvision takes UTC. Every probe compares the device's reported current
time to ours and stores the offset (`Recorder.clock_offset_minutes`), so "play
the moment this invoice was rung up" lands on the right minute rather than an
hour out.

In practice almost every recorder in this market is set to Libyan local time,
which is correct in the owner's terms — the measured offset is then just +120,
and stating it would be reporting a non-event. So the settings screen compares
the recorder's clock to *the till's*, stays quiet when they agree, and warns
only when they do not. The measurement stays either way: it is what makes the
feature survive the installer who left the box on the factory timezone.

## Finding the recorder

Almost nobody configuring this knows what an IP address is, so the setup form
opens with a **network sweep**, and the manual fields sit below it under their
own heading. Picking a device fills the address, the port, the brand hint and
the username (`admin` on both brands, which is what a shop that never changed it
still has); the password is the only thing left to type.

**The sweep runs on the client, not the backend.** The backend is in a container
with no route onto the shop's broadcast domain — the same wall the UDP backend
discovery hit — while the till is already on the network the cameras are on. It
is a `compute` isolate doing a two-stage scan: a TCP connect on :80/:8080 across
the /24 (cheap, ~250ms per host, 64 at a time), then an HTTP probe of only the
hosts that answered, 8 at a time.

Identification needs **no credentials**. Both brands guard exactly one path the
other 404s, and answer it with a digest challenge — so *which* endpoint
challenges is the fingerprint, and the realm carries a model or serial worth
showing. The trap is the `200` case: plenty of embedded servers answer every
path with their own login page, so an unauthenticated success is only believed
when the body is what that endpoint actually returns. A box that guards both
paths is a web server with site-wide auth rather than a recorder speaking two
dialects; the realm breaks the tie, and when it cannot the address is still
offered with no brand claimed — the backend settles that once it has a password.

The identity logic lives in `recorder_identity.dart`, free of `dart:io` like
`lan_interfaces.dart`, so the part that decides "is this a DVR, and whose?" is
testable without a network.

## Data model (`apps/surveillance`)

- `Recorder` — one DVR/NVR box: host, ports, credentials, brand (or `auto`),
  probed identity, health, clock offset. A shop may have more than one.
- `Camera` — one channel on a recorder. Carries **our** name (editable, instant,
  never a write to the DVR), display order, enabled flag, default quality, and
  `covers_checkout` — the flag that makes a camera an option on an invoice.

Camera names are ours by design: renaming a channel on the DVR needs admin rights
on the DVR, takes effect for every other client of it, and half the boxes in the
field reject the write. A local name is instant and reversible.

## The dashboard band

The dashboard carries a full-width strip of live cameras under the headline
numbers — "how is the shop doing" is naturally followed by "and what does it
look like right now". Video wants width, so it is a band rather than one card in
the masonry grid, and it takes up no space at all when there is nothing to show.

**It shows something without being configured.** A dashboard that starts empty
and waits to be set up is a dashboard nobody sets up. With no choice stored it
picks up to three itself, `covers_checkout` first — those are the ones a shop's
dashboard is for. A per-device choice (like the printer and theme settings; the
office PC and the till want different cameras) overrides that, and the three
states are distinct: unset means "you pick", a list means exactly that list, and
an *empty* list means someone deliberately turned it off. Stored ids are
re-resolved against the live camera list every build, so a camera that has since
been unplugged drops out instead of leaving a tile that streams nothing forever.

**It refreshes stills; it does not stream.** This is the load-bearing decision.
The dashboard is left open all day, and holding an H.264 decode per camera open
on a shop mini-PC for hours so an unwatched corner of a screen can be smooth is
the wrong trade — it is why Home Assistant's picture cards default to refreshing
snapshots rather than live video. The band asks for the recorder's own snapshot
path at 2fps (`smooth=false`), which costs no transcoding at all, still reads as
alive for a shop scene, and shares one upstream pull across every open
dashboard. Watching properly is one tap away in the full-screen player.

The picker shows a real still per row, because a shop names its channels late or
never and `CAM 3` answers nothing that a picture answers instantly.

## Which camera plays back an invoice

`Order` records who sold, not which physical till, so there is no reliable
device→camera link to derive. The honest answer is the one implemented: cameras
flagged `covers_checkout` are offered on the invoice, newest-ordered, and the
user picks. Guessing wrong would be worse than asking.

The window is `created_at − pre_roll … created_at + post_roll`
(`ShopSettings.surveillance_pre_roll_seconds` / `_post_roll_seconds`, default
20/40), so the customer is already at the counter when the clip opens.

## Gating

`ShopSettings.enable_surveillance` gates every surface. It is off until a
recorder connects successfully, at which point the backend turns it on (a shop
that has just wired up its DVR and sees nothing concludes the feature is
broken), and a manager can turn it off again in one tap. No recorder, no
navigation entry, no invoice panel, no mention.

## Permissions

`surveillance.view_live`, `surveillance.view_playback`,
`surveillance.export_footage` on top of the usual model permissions. Managers get
all three; the rest are grantable per user, because "the supervisor may watch the
wall but not export" is a real request from shops.

## Client performance

`MjpegView` is the frame rate. Nine tiles at 30fps is 270 decodes and 270
repaints a second, so all five of these are load-bearing:

1. **No widget rebuild per frame.** The decoded image lands in a `ValueNotifier`
   the painter listens to, so a frame repaints one layer and never walks the
   element tree. `setState` per frame is 270 dirty elements a second across a
   wall — Flutter spending its budget on bookkeeping for pixels about to be
   replaced.
2. **Decode to the size actually shown.** `targetWidth` comes from the tile's
   real layout, so a 704×576 frame in a 240px tile is scaled *inside* the JPEG
   decoder. The source size is learned from the first frame, so it only ever
   scales down. The server scales too — each tile asks for its own width.
3. **Drop frames, never queue them.** Newest wins while a decode is in flight.
4. **One decode per displayed frame**, scheduled post-frame, so decoding cannot
   outrun the compositor however fast the server sends.
5. **Cost nothing when unwatched.** The wall grid runs with `cacheExtent: 0`, so
   a tile scrolled off screen is disposed, its socket closes, and the server
   stops pulling that camera from the recorder.

A run of failed decodes surfaces as an error rather than a permanently black
tile — silence there is indistinguishable from a dead camera, and it is exactly
how the first version of this hid a broken codec call.

## The player

One full-screen player serves live and playback, built to the conventions people
arrive with: the picture is the screen, the controls are a translucent overlay
that auto-hides, tap toggles them, double-tap either side skips, and every
target is 48dp. Secondary actions sit behind one overflow menu instead of a row
of buttons across the bottom.

The auto-hide is 9 seconds on touch against 4 with a mouse. That asymmetry is
the point: a mouse re-summons the controls by merely moving, so a short timeout
costs nothing, while on a phone every re-summon is a tap that also toggles what
you were reaching for. It holds indefinitely while a finger is on the timeline.

The timeline paints the recorder's own recorded segments, so a gap in the
recording is visible before you scrub into it. It runs left-to-right whatever
the app's direction, and so do the transport controls: time is not text, and no
camera software anywhere puts the past on the right.

**Export is a mode, not two buttons.** Entering it turns the bar into a range
selector with draggable brackets, dims everything outside the clip, and cuts the
playback stream to the selection so it *loops inside the range* — what you are
watching is exactly the file you will get. Neither a scrub nor a bracket drag
re-cuts until the finger lifts, because every re-cut is an ffmpeg process.
