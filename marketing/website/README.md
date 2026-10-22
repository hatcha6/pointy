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
  paying, and the checkout's progress → result dialog (change due, the
  customer's invoice QR, «طُبع الإيصال»); selling a «كروت دفتر» card through to
  its PIN in that same dialog; typing a question to GPT and scrolling its answer; pressing play on an
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
`pos_preview.dart` takes `&links=on&printer=on` for the recorded sale: the
result shows the online-invoice QR and a receipt that printed
(`dev/preview_receipt_printer.dart` is a printer that always works).
`voucher_menu_preview.dart` takes `&seed=off&printer=on&menu=live`: an empty
invoice, a fake checkout whose card comes back with a PIN, and the **live
catalog** — every brand and card every shop is offered, at live prices and
availability, each with its real logo. `capture/build.sh` reads it from the
relay (`ops/pointy-relay vouchers catalog show --json`, read-only, needs
`ops/.env`'s admin token), turns it into the till's menu with
`capture/live_menu.py`, and copies the logos from `ops/catalog/logos/`
(git-ignored); it stops if either is missing. Promotions, out-of-stock cards
and the category list are whatever is live on the day of the capture, so
re-check the section's chips («أكثر من 40 علامة», the seven categories) after
re-capturing.
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
| «كروت دفتر»: more than 40 brands, 7 categories | The relay's live shop view on 17 Oct 2026: 46 brands, 436 cards (359 in stock). |
| SMS campaign 130 recipients × 2 parts ≈ 39.00 د.ل | `campaigns_preview.dart` (`?screen=cost`). |

If any of these are re-measured, update the copy and this table together.

## How the page moves

All in `assets/js/site.js`, progressive enhancement only — without it the page
is complete, videos just show their posters.

- **Hero:** a sticky stage; the laptop starts tilted back and settles flat as
  you scroll (`--p` on `.hero-device`). Flat and static on phones.
- **كروت دفتر:** the page's one warm (amber) section — amber is the colour that
  counts money, and this is money the shop earns. It also has an amber card in
  the highlights and an amber nav link. Shows the card shelf only: the direct
  top-up and bill-payment tabs stay off the page (not in the harness menu)
  until it is decided they stay.
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
~3.8 MB of WebP across ~120 files and ~4.9 MB of H.264 across 6 clips, fetched
as you reach them. AV1 was tried and was no smaller on flat UI footage.

## Publishing to dftr.ly

The page lives at the root of **https://dftr.ly** on the LibyanSpider hosting
plan (cPanel, Apache/LiteSpeed); `www.dftr.ly` redirects to it. `my.`, `shop.`
and `tunnel.` belong to the relay — never point them here.

```sh
make marketing-site-dist     # → dist/site/ and dist/dftr-site.zip
```

The build refuses to run while assets are missing or the contact buttons are
still placeholders (`data-todo`; `ALLOW_TODO=1` overrides). It copies only the
page, `404.html`, `robots.txt`, `sitemap.xml`, `assets/` and
`deploy/.htaccess`, and makes `assets/img/og.jpg` — the 1200×630 link preview
WhatsApp and Facebook show (they ignore WebP and relative URLs, hence the
absolute `https://dftr.ly/…` in the head).

Upload: cPanel → File Manager → `public_html` → upload `dftr-site.zip` →
Extract → delete the zip. Enable hidden files in File Manager to see
`.htaccess`. Before the first upload, issue the SSL certificate for `dftr.ly`
and `www.dftr.ly` (cPanel → SSL/TLS Status → Run AutoSSL): `.htaccess` sends
every visitor to HTTPS. HTML is served `no-cache`; assets are cached a week, so
a re-captured image with the same name may take up to a week to reach repeat
visitors.

## Open items

- The attendance day rows show worked time as "8.0h" — an English unit
  hard-coded in `attendance_review_tab.dart`. Fix in the app, then re-capture.
