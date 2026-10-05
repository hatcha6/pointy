# دفتر — product page

A single long product page in the style of Apple's product pages, written for
Libyan shop owners. Arabic, RTL, static: `index.html` + `assets/`. No framework,
no build step, no third-party requests.

```sh
make marketing-site            # http://127.0.0.1:8095
make marketing-site-capture    # re-record every image and clip from the app
```

`assets/img/` and `assets/video/` are not in git (size): a fresh clone has to
run `make marketing-site-capture` before the page shows its pictures.

Identity, palette and the "do not say" list come from
[`../BRAND.md`](../BRAND.md). One deliberate exception: **the page's copy is
Modern Standard Arabic (فصحى)**, by the owner's decision (2026-10-05) — not the
colloquial shopkeeper's voice BRAND.md describes, and not Libyan dialect. The
hero promise is «أرقامك صحيحة. دائماً.» rather than «الأرقام تطلع صح». Keep new
copy in فصحى.

## Everything on the page is the app

No mock-ups. Every screen is a real Flutter screen rendered by a dev-only
preview harness in `frontend/lib/dev/` (real widgets, fake repositories, no
backend), recorded in headless Chromium:

- **Stills** are retina screenshots (`capture/stills.js`), encoded to WebP at
  two widths.
- **Clips** are the harness being used: typing in the POS search, adding items,
  paying; typing a question to GPT and scrolling its answer; pressing play on an
  invoice's camera clip; moving a repair job across the workshop board,
  entering the customer's agreed price at the approval step; scrolling the
  phone dashboard (`capture/videos.js`).
  Frames come from the Chrome DevTools screencast at 2× and are encoded to
  H.264 with `+faststart`. A soft teal dot marks taps.

`dev/marketing_preview.dart` exists for this page: it renders the screens no
other harness covered — app updates, BioTime attendance and its device page, a
payroll run built from that attendance, a product priced in USD, parallel-market
exchange rates with the repricing list, and the IMEI picker at the till.
`pos_preview.dart` gained a fake open drawer and a fake checkout so the recorded
sale ends on the real «تم تسجيل البيع» path, and its totals now sum the actual
cart. `operations_preview.dart` gained a fake stage move and price update, so a job
actually advances on the board instead of failing with «تعذر تنفيذ العملية».
`ai_chat_preview.dart` gained `?screen=ui-live` (the `ui` reply, but
nothing sent on load, so the question can be typed on camera).

**One stand-in:** the invoice-replay footage. The player, the invoice screen
and the camera chips are real; the picture is a CC0 photo graded to look like
CCTV (`capture/footage.py`, source in `../promo/public/cam/`). Swap in real,
consented shop footage when there is some.

## Numbers on the page, and where they come from

| Claim | Source |
| --- | --- |
| 4,140 sales in one week; checkout 0.31 s median, 0.49 s p95; state sync 0.013 s; scan/search 0.17 s; discounts 0.10 s; last cost 0.07 s | `frontend.http_request` / `sales.checkout.completed` events from one supermarket, 22–28 Sep 2026 (`pointy-analytics-events-20260928T205416Z.zip`, 40,160 till requests). Round trip measured on the till. |
| Update: longest till wait 0.95 s; 827K orders migrated in 49 s; first live update 8 Sep 2026 | Upgrade rehearsal at real scale and the first live update (project memory `zero-downtime-updates`). |
| Attendance 25/26 days, payroll 5,900.00 + 258.17 − 600.00 = 5,558.17 | The marketing harness's fake data; reconciles on screen. |
| 12.00 $ → 82.20 د.ل at 6.85 | Same; matches the till and the repricing list. |
| SMS campaign 130 recipients × 2 parts ≈ 39.00 د.ل | `campaigns_preview.dart` (`?screen=cost`). |

If any of these are re-measured, update the copy and this table together.

## How the page moves

All in `assets/js/site.js`, progressive enhancement only — without it the page
is complete, videos just show their posters.

- **Hero:** a sticky stage; the laptop starts tilted back and settles flat as
  you scroll (`--p` on `.hero-device`). Flat and static on phones.
- **Highlights:** a scroll-snap carousel; each clip plays when its card is
  current and advances the carousel when it ends; pause button.
- **Statement:** words light up as you scroll through a sticky block.
- **Speed:** counters and latency bars animate once, in view.
- **Updates:** a sticky stage scrubs a four-step server swap while the till
  counters keep rising.
- **Design:** a light/dark comparison slider.
- **Videos** load only near the viewport (`preload="none"`, `data-src`) and
  pause off-screen. `prefers-reduced-motion` turns all of it off and shows
  video controls instead of autoplay.

## Weight

First paint needs the HTML, `site.css`, two woff2 fonts (subset IBM Plex Sans
Arabic, ~55 KB each) and the hero poster (~50 KB). Everything else is lazy:
~3.8 MB of WebP across ~120 files and ~3.3 MB of H.264 across 5 clips, fetched
as you reach them. AV1 was tried and was no smaller on flat UI footage.

## Open items

- The contact buttons (`data-todo="whatsapp"`, `data-todo="facebook"`) have no
  targets yet — add the real WhatsApp number and Facebook page.
- No hosting is set up; any static host works (set long cache headers on
  `assets/`).
- The attendance day rows show worked time as "8.0h" — an English unit
  hard-coded in `attendance_review_tab.dart`. Fix in the app, then re-capture.
