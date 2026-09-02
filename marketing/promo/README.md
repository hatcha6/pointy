# Daftar promo films

> The identity these are built on — name, promise, voice, mark, palette, type —
> is in [`../BRAND.md`](../BRAND.md). This file covers only how a film or a
> poster is made. If the two ever disagree, BRAND.md wins.

Four 30-second vertical films for دفتر (Daftar), rendered from code with
[Remotion](https://remotion.dev). Every frame is deterministic, so a re-render
always produces the same video — and a copy tweak is a one-line change, not a
re-shoot.

| Composition   | Output                        | Subject                                   |
| ------------- | ----------------------------- | ----------------------------------------- |
| `PosCheckout` | `out/daftar-pos-checkout.mp4` | Scan → cart → auto discount → tender → receipt |
| `AiAssistant` | `out/daftar-ai-assistant.mp4` | Arabic assistant reads shop data and proposes actions |
| `Inventory`   | `out/daftar-inventory.mp4`    | Blind stock count, variance review, delta-only apply |
| `Reports`     | `out/daftar-reports.mp4`      | Owner dashboard and the Z shift report    |

All four are **1080 × 1920 @ 60fps, 1800 frames (30.0s)**, H.264.

## Posters

Fifteen still posters at **1080 × 1350 (4:5)**, rendered from the same tokens,
typeface and logo as the films — so a feed of stills and a film read as one
brand.

| Composition      | Output                        | Subject                                     |
| ---------------- | ----------------------------- | ------------------------------------------- |
| `PosterBrand`    | `out/posters/01-brand.png`    | The mark, the name, دُوّن في دفتر           |
| `PosterCheckout` | `out/posters/02-checkout.png` | The till, and a discount that applies itself |
| `PosterAi`       | `out/posters/03-ai.png`       | A question in Arabic, answered from shop data |
| `PosterOffline`  | `out/posters/04-offline.png`  | The shop keeps selling with the line down    |
| `PosterStock`    | `out/posters/05-stock.png`    | Blind count, visible variance                |
| `PosterReports`  | `out/posters/06-reports.png`  | The day closing out on the numbers           |
| `PosterCredit`   | `out/posters/07-credit.png`   | آجل: a payment allocated oldest-invoice-first |
| `PosterPriceChecker` | `out/posters/08-price-checker.png` | The shelf display that answers "بكم؟" |
| `PosterCompare`  | `out/posters/09-compare.png`  | A crowded legacy till, and the دفتر desktop in front of it |
| `PosterMinutes`  | `out/posters/10-minutes.png`  | The whole cashier's job, in three steps      |
| `PosterAttendance` | `out/posters/11-attendance.png` | Fingerprint punches landing in the salary sheet |
| `PosterFx`       | `out/posters/12-fx.png`       | The same dollar at the cash rate and the صك rate |
| `PosterAiInvoice` | `out/posters/13-ai-invoice.png` | A supplier invoice, photographed, becoming a draft PO |
| `PosterAiCapabilities` | `out/posters/14-ai-capabilities.png` | Everything the assistant does, in six lines |
| `PosterKiosk`    | `out/posters/15-kiosk.png`    | Kiosk mode: an old tablet, waiting for a shopper |

```bash
npm run posters                 # all fifteen
npx remotion still PosterAi out/posters/03-ai.png
```

### How a poster is built

One idea, one object, one line — never two. `src/posters/kit.tsx` holds the
whole vocabulary:

- **`Poster`** — the ground. `ink` is the lit room the product floats in;
  `paper` is the app's own page colour, for posters that are an idea rather
  than an object. Alternating them down a feed is what gives the grid rhythm.
- **`Copy`** — kicker, headline, one sentence. Anchored top-right in every
  poster, which is what makes six different images look like one campaign.
- **`Detail`** — a fragment of the real interface, lifted out and enlarged past
  any size a phone shows it. This is the move that separates a poster from a
  screenshot.
- **`Device`** and the `screens/` — shared with the films, so the product on a
  poster is the product in the film. `screens/PosDesktopScreen.tsx` is the
  poster-only exception: the real two-pane desktop workspace (catalogue pane
  beside cart pane, as `AppBreakpoints.usesTwoPane` gives it), authored at
  1440 × 900 and scaled by whatever frames it. Compare a desktop with a
  desktop — a phone against a till is not the same job.

Rules, in addition to the film rules above:

- **Break headlines by hand.** Both `Headline` and `Sub` split on `\n`. Let a
  line wrap on its own and you get a one-word orphan; there is no headline here
  longer than two written lines.
- **No letter-spacing, ever.** Emphasis is weight, size and the teal — tracking
  breaks connected Arabic.
- **Numbers reconcile,** exactly as the films do. 20.00 − 3.00 = 17.00 on the
  POS poster; 4,285.50 ÷ 187 = 22.92 on the reports poster.
- **The logo sits quietly in a corner** and never lands on top of the handset.
- **The supplier invoice in `PosterAiInvoice` is a prop, not a scan.** It is
  drawn — pre-printed blue form, aged paper, a crease, a crooked stamp, the
  three decimals a dinar is written in — from a fictional wholesaler, because
  photographing a real shop's invoice would publish a real business's prices and
  phone number. It is set in `'Geeza Pro', Tahoma, Arial` (the same system stack
  `legacy_ui` uses), never in IBM Plex: the moment someone else's paper is set
  in our typeface it reads as our artwork instead of their document. The line
  names on it deliberately differ from the catalogue names on the order card —
  زيت ذرة الجود 1 لتر against زيت ذرة 1 لتر — because the matching is the
  feature, and an invoice that already used our wording would be showing
  nothing.
- **Third-party marks name a product, they don't imply a partner.**
  `public/zkteco-logo.png` is ZKTeco's own reversed logo, taken from their site,
  and it appears in exactly one place: the "works with" chip on
  `PosterAttendance`. It sits on a dark chip because that is the ground the
  reversed mark was drawn for — never recoloured, never on our teal, never
  larger than our own lockup. It is there because we integrate with BioTime and
  a shop owner needs to recognise the box on their wall. If the claim ever stops
  being true, the chip goes.
- **The legacy till in `PosterCompare` is an archetype, never a product.**
  `src/posters/legacy_ui.tsx` draws the era every Libyan shop recognises —
  Windows chrome, an F-key command row, a wall of category buttons with most of
  them still empty, a numeric keypad — in a different typeface from ours, with
  no vendor's name, mark or copied layout. The claim it makes is about how much
  is on screen at once, never about anyone's software being bad. Keep it that
  way; half your future customers are somebody's customer today.

## Profile and covers

Everything needed to stand a دفتر page up, rendered from the same tokens as the
posters and the films.

```bash
npm run brand                   # all of it → out/brand/
npx remotion still Avatar out/brand/avatar-1080.png
```

| File                              | Size        | Goes on                                        |
| --------------------------------- | ----------- | ---------------------------------------------- |
| `avatar-1080.png`                 | 1080 × 1080 | Facebook, Instagram, TikTok, WhatsApp Business |
| `cover-facebook-1640x624.png`     | 1640 × 624  | Facebook page cover                            |
| `cover-youtube-2560x1440.png`     | 2560 × 1440 | YouTube channel art                            |
| `highlight-*.png` (5)             | 1080 × 1080 | Instagram highlight covers                     |

Highlights, in the order they should be pinned: `features` (الميزات),
`pricing` (الأسعار), `setup` (التركيب), `customers` (آراء العملاء),
`contact` (تواصل معنا). Instagram prints the name under the circle, so the
cover is one glyph and no word.

### Designed for the worst crop, not the nominal one

Platform crops differ per surface and change without notice, so none of these
depend on an exact frame:

- **The avatar is circle-safe.** The ground is a flat fill of the mark's own
  teal (`#0B6C69`, sampled from the artwork), so the icon's rounded corners
  dissolve into it and the circle mask has nothing to cut. The page-and-pencil
  sits inside the inscribed circle, which is all a 32px avatar ever shows.
- **The Facebook cover keeps its middle clear.** Facebook crops narrower on
  phones than on desktop, so mark, name and line live in the centre and the
  product at the edges is atmosphere that is *meant* to be cut. The bottom-left
  and bottom-centre are deliberately empty: that is where the profile picture
  lands, on desktop and on phones respectively.
- **The YouTube art fills only the safe box.** Nothing but light lives outside
  the centre 1546 × 423 that every device is guaranteed to show; on a TV the
  rest is the lit room.

Check the sizes against whatever the platform asks for on the day you upload —
these are the common ones, and the designs survive the variance, but the
numbers do move.

## Working on them

```bash
npm install
```

Live preview with a timeline scrubber — the fastest way to judge motion:

```bash
npm run dev
```

Render everything to `out/`:

```bash
npm run render
```

One film only:

```bash
npx remotion render Reports out/daftar-reports.mp4
```

A single frame, which is how most of these scenes were checked:

```bash
npx remotion still PosCheckout /tmp/frame.png --frame=900
```

## How a film is built

Each film in `src/videos/` opens with a **cue sheet** — a `const C = {...}` of
frame numbers. Everything else derives from it, so retiming a beat means moving
one number, never chasing animations across a file.

```
src/
  theme.ts        Design tokens. `brand` mirrors pointy_colors.dart token for token.
  anim.ts         at() / pulse() / spr() / countTo() — the whole motion vocabulary.
  fonts.tsx       IBM Plex Sans Arabic, held until every weight rasterises.
  components/     Stage (the lit room), Device (the handset), Type, Caption, Tap, BrandCard.
  ui/             Recreated app atoms: AppBar, Chip, Money, icons, product art, Toast.
  screens/        The app screens themselves — Pos, Payment, Success, Ai, Stock, Dashboard, ZReport.
  videos/         The four films. Cue sheet + choreography only.
```

Screens are **presentational**: they take the state to draw and never read the
frame clock. The film computes state from its cue sheet and passes it down.
That is why the same `PosScreen` serves the catalogue beat, the discount beat
and the blurred backdrop behind the payment sheet.

## Rules the films follow

- **Colour-accurate.** `src/theme.ts` `brand` is a token-for-token copy of
  `frontend/lib/src/shared/design/pointy_colors.dart`. Change the app palette
  and change it here too, or the films stop being honest.
- **The real typeface.** IBM Plex Sans Arabic, copied from
  `frontend/assets/fonts/`. No letter-spacing anywhere — positive tracking
  breaks connected Arabic script.
- **Numbers reconcile.** Anyone who runs a shop will check. The POS film:
  20.00 − 3.00 discount = 17.00 due, 20.00 tendered, 3.00 change. The reports
  film: 3,140.50 cash + 1,145.00 card = 4,285.50 takings, ÷ 187 invoices =
  22.92 average, and the Z report reconciles the drawer against the same day.
- **Currency is د.ل** (`CUR` in `theme.ts`). One constant to swap for another
  market.
- **Western digits in app UI**, matching the shipping screens and `ui/*.png`.

## Changing things

**Copy.** Captions live inline in each film's JSX. Edit the `title` / `sub`.
Words listed in `accent` render in the teal highlight.

**Timing.** Move a number in `C`. Captions are `start` → `end` frames; a
caption's words stagger in over ~40 frames, so leave at least 90 frames of life.

**Currency or market.** Change `CUR` in `src/theme.ts`. Prices are in
`src/data.ts`.

**A new film.** Copy `src/videos/Reports.tsx` as a skeleton — Stage, Opener,
Device with a screen inside, Captions, EndCard — and register it in
`src/Root.tsx`.

## Voiceover

`VOICEOVER.md` has the Arabic narration for all four films with timecodes keyed
to the on-screen beats, plus the pacing each line was written against.
