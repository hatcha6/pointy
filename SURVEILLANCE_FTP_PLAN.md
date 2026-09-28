# Surveillance — FTP upload setups (رفع التسجيلات عبر FTP)

A recorder can be connected two ways. **Direct** is what `SURVEILLANCE_PLAN.md`
describes: the backend dials the DVR, pulls live video and asks it for its
recordings. **FTP upload** turns that around: the backend runs an FTP server,
the DVR/NVR uploads its footage to it, and Pointy keeps only the stretches that
show an invoice being made. Invoice replay then plays from Pointy's own disk.

## Why a second way in

- **Every recorder can upload to FTP.** Direct playback needs a driver that can
  search and play the box's recordings (Hikvision, Dahua, Xiongmai, ONVIF-G).
  A great many OEM boxes can do neither over the network, but all of them have
  an FTP page.
- **The DVR's disk is small and overwrites itself.** A 1 TB disk behind sixteen
  cameras holds days. The footage an owner wants weeks later — the disputed
  sale, the refund nobody remembers — is gone. Pointy's copy is kept for as long
  as the shop says.
- **It keeps only what matters.** A DVR uploading everything would fill a shop
  PC in a day. So nothing is kept by default: a raw upload is held until every
  invoice that could overlap it exists, the invoice windows are cut out of it,
  and the rest is deleted.

## Shape

```
DVR ──FTP──▶ ftp service (pyftpdlib) ──▶ <footage>/inbox/<recorder>/…   (raw, transient)
                  │ records FootageUpload rows
                  ▼
             ingest loop (same process, own thread)
                  │ parses name → camera + device time, waits for the decision time,
                  │ intersects with invoice windows, cuts with ffmpeg -c copy
                  ▼
             <footage>/archive/<camera>/YYYY/MM/DD/…  + FootageClip rows (kept)
                  │
backend ◀─────────┘ playback / still / export / recordings read the archive
```

- **One service, `ftp`, owns the inbox**: it receives, decides and prunes. It is
  the backend image with a different entrypoint role, so it needs no image of
  its own in the offline bundle. The web backend only reads the archive.
- **The FTP IO loop never touches the database.** Credentials are a snapshot
  refreshed every few seconds on a side thread; upload events go through a queue
  that a side thread writes. A slow or restarting Postgres pauses bookkeeping,
  never an upload in flight.

## Setup

Adding a recorder asks one question first: direct connection or FTP upload. An
FTP setup needs only a name. Saving it generates the credentials and shows the
four things the installer types into the DVR:

| Field | Value |
|---|---|
| Server | the Pointy server's LAN address |
| Port | 21 |
| Username | `cam` + 4 digits, unique |
| Password | 12 characters, lower-case letters and digits, no look-alikes (`0 o 1 l i`) |

Lower-case alphanumerics because the installer types them with a mouse on the
DVR's on-screen keyboard, and some firmwares refuse punctuation in that field.
The password is stored as generated — it has to be shown again when the
installer comes back — and only users who may change recorders see it. It can
be regenerated.

**The server address comes from the client.** The backend runs in Docker and
cannot see the shop's network; the till can. The setup screen shows the address
the till reaches the backend on, with loopback swapped for the machine's LAN
address (`lanReachableUrl`, the same fix the companion QR uses), and stores it
on the account. The FTP server announces that same address in its `PASV`
replies — inside Docker its own address is a container address the DVR cannot
reach. `EPSV` and active mode need no address at all.
`POINTY_FTP_PASSIVE_ADDRESS` overrides it for unusual networks.

## What the DVR is allowed to do

`elawdfm`: change directory, list, append, store, delete, rename, make
directory. No `RETR` — the account can put footage in, never take it out. All
transfers are binary whatever `TYPE` the client asks for: ASCII mode would
rewrite line endings inside a video file. Logins are accepted only from private
addresses; ten failures from one address in ten minutes lock it out for
fifteen (per username on Windows, where every DVR shares one address — see
Deployment). Uploads are refused (452) when the disk is below its floor or the
inbox has backed up, so a stuck pipeline makes the DVR retry later instead of
filling the disk that Postgres lives on.

## Reading an upload

Nothing about the file is trusted blindly. In order:

1. **Camera.** From the path: Dahua's `…/2026-09-27/001/dav/…` channel folder,
   Hikvision's `<ip>_01_<timestamp>` picture names, `ch01`/`channel 1`/`cam1`
   markers; failing those, the camera's folder name (a DVR set to name folders
   by camera); failing that, channel 1 (a single-camera device). Each distinct
   source becomes a `Camera` on the recorder the first time it uploads,
   **flagged `covers_checkout`** — pointing a DVR's uploads at Pointy is how an
   installer says "this is for invoices". The shop can switch any off.
2. **Time.** Device wall-clock from the name: Dahua ranges
   `14.00.00-14.15.00`, 14/17-digit stamps, ISO-ish stamps; a date folder
   supplies the date for a time-only name. Converted with the recorder's clock
   offset. With no usable name, the upload itself is the clock: a picture was
   taken when it arrived, and a video ended when its upload finished.
3. **Clock offset**, measured from uploads, never configured. A file cannot
   arrive before it was recorded, so `device_end − received_at` is the offset
   minus the upload latency; snapped to 15 minutes, the largest recent value is
   the offset. It is raised at once and lowered only after six hours of
   agreement, so a DVR catching up on a backlog (all late, all low) cannot drag
   it down. The first measurement is adopted outright; before it, the shop's own
   timezone is assumed — which is what nearly every recorder in Libya is set to.

## Deciding what to keep

An invoice at `t` wants `[t − pre − 10s, t + post + 10s]` (the shop's pre/post
roll plus a margin, so lengthening the roll later does not find the footage
already trimmed). An upload covering `[s, e]` can be wanted by invoices with
`t` up to `e + pre + 10s` — in the future when the file lands — so it is held
until `received_at + pre + 10s + 60s` and decided then. `received_at ≥ e`
always, which makes that safe whatever the device clock says.

Moments that count: every till-rung order (standard, quotation, credit) and
every return or void. Only cameras that are enabled, on an enabled recorder and
`covers_checkout` keep anything; everything else is discarded on arrival.

- **Nothing overlaps** → deleted, no ffmpeg run at all.
- **A picture overlaps** → moved into the archive as-is.
- **A video overlaps** → remuxed to Matroska (`-c copy`; Matroska takes
  H.264/H.265 with G.711 audio, which MP4 does not), its keyframes read, and
  each merged window cut from the keyframe at or before it. Past 80% coverage
  the whole file is kept instead of being re-cut.

## Retention

`ShopSettings.surveillance_archive_retention_days` (default 30) deletes clips
by age. Independently, the archive may use at most 40% of its disk and must
leave the larger of 10 GB or 5% free; the oldest clips go first when either is
breached — the POS database outranks old footage.

## Playback

`FootageClip` rows answer everything the recorder used to:

- **playback** — video clips through ffmpeg from the file (`-ss`, `-readrate`),
  pictures straight out as MJPEG parts paced by their own timestamps. Same wire
  format, same player.
- **recordings** — the kept clips are the timeline, and `known` is true.
- **still / export** — from the clip under the moment; export concatenates the
  clips in the window into fragmented MP4 (audio to AAC).

An FTP camera has no live view. `?enabled=true` — what the wall and dashboard
ask for — leaves archive-only cameras out, so older tills never draw a tile that
can only fail, and `supports_live` tells the player not to offer live.

## Deployment

`ftp` service in the on-prem compose: backend image, role `ftp`, container port
2121 published as 21, passive range `30000-30019` published 1:1, the
`pointy-footage` volume shared with `backend` (which plays the archive back).
The live updater recreates it after the workers; a DVR retries an upload the
restart cut off, and the ingest resumes from its rows.

**A taken port 21 must not fail an install.** Compose fails the whole `up` when
one container cannot bind its port, and some shop machines already run an FTP
server. `install.sh` therefore brings up everything but `ftp` when that is what
it takes, and says which port is in the way; a core service that cannot bind
still fails the install as before. The live updater already treats a failed
`ftp` recreate as a warning.

**Why 30000-30019.** Below both ephemeral ranges (Linux 32768+, Windows
49152+). On Windows, Hyper-V's NAT — which WSL runs on — reserves random blocks
of its range at every boot, and a forward inside one cannot listen; `netsh`
still reports success. A shop that has to move the range sets
`POINTY_FTP_PASSIVE_PORTS`, and everything below follows it.

### Windows (WSL)

The stack runs in a WSL VM behind a NAT, so the DVRs reach it the way the tills
do: through `netsh interface portproxy`, re-pointed by `bootstrap-wsl.ps1 -Boot`
whenever the VM's address changes (and by `keep-pointy-running.ps1` on shops
using the keeper). Each reconcile:

- reads the FTP ports from the stack's `.env` (`grep ^POINTY_FTP_`, defaults as
  in compose), so moving them needs no PowerShell edit;
- forwards the control port and **every passive port 1:1** — PASV hands the DVR
  the PC's LAN address, so each data port must be a forward of its own (a range
  of more than 100 is refused rather than forwarded port by port);
- opens the firewall for them to the **private ranges only** ("Pointy FTP (TCP
  21)", "Pointy FTP data (TCP 30000-30019)");
- proves the path like the tills': our own greeting (`220 Pointy …`) from
  Windows to the VM, then on `127.0.0.1` and each LAN address; each passive
  forward by its IP Helper listener, since nothing answers there between
  transfers. A dead hop is re-created once, then named in `bootstrap.log`: the
  process holding port 21 (IIS's `ftpsvc` by name), a block Windows reserved,
  another program on a data port.

A broken FTP bridge stops camera uploads, not selling: it is logged and kept
in `bridge-state.json` (`ftp_verified`), and never makes the tills' bridge
count as broken.

**Behind the portproxy every DVR arrives from one address** — the Windows
host's own — which the server cannot tell apart. `POINTY_FTP_BEHIND_PROXY=auto`
recognises WSL by its kernel (a container shares it) and then: locks out a
**username** after ten failures instead of the shared address (which locks only
after 100, a guesser trying many names); lifts the per-address connection cap;
lets active mode dial the DVR's own private address (its `PORT` never matches
the proxy's); and records no peer address, so the setup page says "a device"
instead of sending the installer to a machine that does not exist. The
backend's own private-address check sees only the proxy there — the firewall
rule is what keeps FTP on the LAN.

## Not in this version

- FTPS/SFTP: the upload stays on the shop LAN.
- Footage that is not an invoice (a theft with no sale). The DVR's own disk
  still has it for its own retention; Pointy's archive is the evidence archive.
- A live view for FTP cameras.
