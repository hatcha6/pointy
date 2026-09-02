# دفتر — Brand Identity

The identity is not a mood board. Almost all of it is already shipping, in code,
in four places that were built independently and have started to drift apart.
This document names one canonical set of values, says which file owns each one,
and lists the drift that has to be closed.

Readable version (swatches, specimens, the pre-flight checklist):
<https://claude.ai/code/artifact/fa760590-752f-4814-a349-8a5374a307b2> — source
in `marketing/brand-book.html`, republish after editing this file so the two
never disagree.

Read with:

- `DESIGN.md` — how the product behaves. Patterns, density, RTL, components.
  Brand governs what it *is*; DESIGN governs what it *does*. Neither repeats the
  other.
- `marketing/promo/README.md` — how a poster or a film is built.

---

## 1. The name

**دفتر** is the customer-facing brand. A دفتر is the ledger every Libyan shop
already keeps; the product is that ledger, doing the arithmetic. The name is the
positioning — do not explain it in copy.

| Where | What it is called |
| --- | --- |
| Anything a customer sees | **دفتر** |
| Latin-script contexts where Arabic can't be set | **Daftar** |
| Code, packages, protocols, deploys, CLI | **pointy** — never rename |
| The assistant | **GPT** |

`pointy` is load-bearing: `PointyTheme`, `pointy_frontend`, the `pointy-relay`
binary, `X-Pointy-Relay-Token`. Renaming it breaks deploys and protocol headers.
The 2026-06-28 rename was **user-facing only** and stays that way.

The assistant is named GPT by explicit decision. That is OpenAI's trademark; the
risk was raised and accepted. If it is ever revisited, the name lives in
`app_ar.arb` (`aiAssistant*`, `subscriptionAi*`, `aiDailyBriefLabel`) and in the
model's self-identity in `backend/apps/ai/relay_stream.py` and
`dashboard_digest.py`.

### The tagline

> **دُوّن في دفتر**

A pun: دَوَّن (to enter into a ledger) on دفتر. "Recorded in Daftar." It is a
**closing stamp**, not a headline — it goes at the foot of a printed slip, on
the end card of a film, under the mark on a profile. Never at the top of
anything, never inside the app.

It lives in `frontend/lib/src/shared/branding.dart` and every printed surface
pulls it from there. **Voweling is fixed:** one mark per letter (دُوّن, not
دُوِّنَ) because the PDF text shaper drops a kasra tucked under a shadda. Do not
"correct" it.

---

## 2. The promise

**الأرقام تطلع صح.** The numbers come out right.

That is the wedge, and it is chosen against the field: the competing systems in
Libya are fat clients writing straight to a database, and their accounting is
wrong in ways their customers can feel but not prove. Everything we say should
ladder back to a number that reconciles.

Four proof pillars — every piece of communication should stand on one of them,
and only one:

1. **الأرقام تتطابق.** The receipt, the Z report, the valuation and the payroll
   sheet all agree. Show the arithmetic; someone will check it.
2. **يشتغل بدون إنترنت.** One backend on the shop's own LAN. Generators and
   outages are the normal case, not the edge case.
3. **عربي أولاً.** Not a translated English layout. The shopkeeper's own Arabic.
4. **يتكامل مع اللي عندك.** The fingerprint terminal, the printer, the scanner,
   the tablet in the drawer. We do not sell hardware.

**Do not say:** cloud, ERP, "digital transformation", offline-sync (we
deliberately have none — it is the rivals' bug class), a named competitor,
"official vs parallel" of an exchange rate, or any AI claim beyond what the
model actually does on a shop's own data.

---

## 3. Voice

Five rules. They are already how the shipped copy reads; this is only writing
them down.

1. **Say the number.** «24 يوم حضور من 26، يومين غياب −200.00 د.ل» beats "smart
   attendance tracking". Every figure on a poster, in a film or in a caption
   must reconcile with every other figure on it.
2. **The shopkeeper's Arabic, not the press release's.** «شنو أكثر صنف مبيعاً
   هذا الأسبوع؟» — not «ما هو المنتج الأكثر مبيعاً خلال الأسبوع الحالي؟».
3. **One idea per sentence, one claim per surface.** If a poster needs two
   headlines it is two posters.
4. **Name the limit.** «ما يُحفظ شيء قبل ما تراجعه وتوافق» is voice, not a
   disclaimer. Stating what the product will not do on its own is what makes
   the rest believable.
5. **Never sell against a named competitor.** Half our future customers are
   somebody's customer today. Claims are about our behaviour, never their
   product.

### Arabic typography law

Non-negotiable, everywhere — app, print, posters, films, kiosk:

- **No letter-spacing. Ever.** Positive tracking breaks connected Arabic.
  `PointyTypography` sets `letterSpacing: 0` globally; do not undo it locally.
- **Western digits** in UI, prices and reports.
- **Money inherits the paragraph's RTL.** Forcing `TextDirection.ltr` on a field
  containing د.ل mangles it. Isolate the *numeral* if you must
  (`\u{2066}…\u{2069}`), never the whole phrase.
- **Two decimals** for our own money. Three decimals (75.000) only when
  reproducing someone else's Libyan document, where that is how it prints.
- **Tabular figures** for anything in a column: `PointyTypography.numeric`.
- Mixed expressions like "rows × cols" flip under an RTL paragraph — wrap them
  in an LTR isolate.

---

## 4. The mark

A tilted page with a second page behind it, and a pencil with a single amber
band, on a rounded-square teal ground. Page + pencil = دفتر + دُوّن. The amber
band is the only warm note in the mark and it is why amber is the accent
everywhere else.

`frontend/assets/branding/logo.png` (colour) · `logo_black.png` (one-colour,
for inline PDF use) · `marketing/promo/public/logo.png` (the promo copy).

**Lockup.** Mark + دفتر, already codified in
`marketing/promo/src/posters/kit.tsx`:

- gap between mark and wordmark = **0.34 ×** mark size
- wordmark cap size = **0.72 ×** mark size
- mark corner radius = **0.235 ×** mark size

**Clearspace:** one quarter of the mark's width on every side. Nothing enters
it — not a headline, not a device, not a chip.

**Minimums:** 24 px for the mark alone, 40 px for the lockup. Below 24 px only
the page-and-pencil survives, which is why the avatar is built the way it is.

**The avatar is the one sanctioned colour exception.** Its ground is a flat fill
of the artwork's own teal `#0C6D69`, so the icon's rounded corners dissolve into
it and a circular crop has nothing to cut. That value is *sampled from the mark*
and is used for that purpose only. It is not the brand teal.

**Never:** recolour the mark, add a gradient or glow to it, set it on a busy
photograph, place it on top of a device or product, stretch it, rebuild the
wordmark in another face, or let it become the largest thing in a frame. The
logo sits quietly in a corner; the product is the hero.

---

## 5. Colour

`frontend/lib/src/shared/design/pointy_colors.dart` is **the** palette.
Everything else mirrors it — it does not get its own opinion.

### The light palette

| Token | Value | Role |
| --- | --- | --- |
| `primary` | `#0F766E` | The brand teal. CTAs, selection, positive emphasis. |
| `primaryStrong` | `#006C53` | Pressed states, strong text emphasis, the accent on paper grounds. |
| `primaryDark` | `#064E3B` | Depth and gradients. |
| `darkTopBar` | `#0B111C` | POS and high-focus app bars. |
| `accentAmber` | `#C98A3B` | Money, tender, attention. Never decoration. |
| `danger` | `#B42318` | Destructive, errors. |
| `warning` | `#B65F2A` | Low stock, caution. |
| `success` | `#0E6B4E` | Completed, available. |
| `ink` | `#101828` | Primary text. |
| `mutedInk` | `#667085` | Secondary text. |
| `line` | `#E5E0D8` | Hairlines. |
| `lineStrong` | `#D5CFC4` | Emphasised separation. |
| `surface` | `#FFFFFF` | Cards, sheets, inputs. |
| `page` | `#F8F7F4` | The page. |
| `surfaceSunken` | `#F1EFEA` | Recessed wells. |
| `subtleFill` | `#F2F4F2` | Quiet fills. |
| `primaryContainer` | `#E0F2EF` | Teal wash. |
| `amberContainer` | `#FFF4E3` | Amber wash. |

Dark mode mirrors it token for token in `PointyColorsDark`; the teal brightens
to `#2DD4BF` so it survives on a dark surface. A palette-driven theme means
adding a colour means adding a token to *both*.

### The two rules that make it a brand and not a list

**The neutrals are warm.** `#F8F7F4`, `#F1EFEA`, `#E5E0D8`, `#D5CFC4` are paper,
not grey. This is the single most identifying thing about the palette and the
easiest to lose — a cool grey `#F5F5F5` anywhere reads as a different product.

**Teal acts, amber counts, everything else is paper.** Teal is reserved for what
the user can do and what succeeded. Amber is money and attention. If a surface
needs a third colour to make sense, the layout is wrong.

### Grounds (marketing only)

Two, and only two — `marketing/promo/src/posters/kit.tsx`:

- **ink** — `#06090E` rising to `#0D141C`, a lit room for the product to float
  in. Objects live here: devices, paper, hardware.
- **paper** — the app's own `page` colour. Ideas live here: lists, claims,
  arithmetic.

Alternating them down a feed is what gives a grid rhythm. The dark stage palette
is film-and-poster only and never ships inside the app.

### Drift register — open

Four surfaces have their own values. This is the incoherence to close:

| Where | Has | Should be |
| --- | --- | --- |
| `frontend/lib/src/shared/pdf/pointy_pdf_palette.dart` `accent` | `#0B6B64` | `#0F766E` |
| …`ink` | `#172026` | `#101828` |
| …`muted` | `#64717A` | `#667085` |
| …`border` | `#D6DDE2` (cool) | `#E5E0D8` (warm) |
| …`fill` / `zebra` / `highlight` | cool greys | the warm `surfaceSunken` / `subtleFill` family |

Printed documents are the only artifact a customer's accountant, bank or
supplier ever sees, and they currently read as a different product from the app:
cool neutrals against the app's warm ones, and a teal nobody else uses. Closing
this changes the appearance of every invoice, purchase order and report, so it
is proposed here rather than done silently — but until it is closed, the brand
is not coherent.

---

## 6. Type

**IBM Plex Sans Arabic**, weights 400/500/600/700, bundled at
`frontend/assets/fonts/` and copied to `marketing/promo/public/fonts/` so films
and posters set in the same face the app ships. There is no second brand face.

Product ramp: `DESIGN.md` § Typography. Marketing ramp, from the poster kit:

| Role | Size | Weight |
| --- | ---: | ---: |
| Poster headline | 76–96 | 700 |
| Poster sub | 32–36 | 500 |
| Kicker (names the feature) | 30 | 600 |
| Card title inside a Detail | 25–30 | 600–700 |
| Figure | 34–62 | 700 |

Headlines are **broken by hand** with `\n`. A line allowed to wrap on its own
produces a one-word orphan; no headline runs longer than two written lines.
Emphasis is weight, size and the teal — never tracking, never italics (Arabic
has none), never all-caps.

**One typeface exception:** anything that is explicitly *not ours* — a legacy
till, a supplier's invoice — is set in the system stack
`'Geeza Pro', Tahoma, Arial`. The moment someone else's document is set in IBM
Plex it reads as our artwork instead of their paper.

---

## 7. Space, shape, motion

Product tokens are in `DESIGN.md` (8 px base, 8 px card radius,
`PointyShadows.raised` / `.overlay`, `PointyMotion` 150/200/250 ms
`easeOutCubic`). Never invent an ad-hoc shadow or duration.

Marketing: 4:5 at 1080 × 1350, one margin `M = 96`, and nothing crosses it
except a deliberate bleed. Copy is anchored top-right in every poster — that
single constraint is what makes a dozen different images read as one campaign.

---

## 8. Pictures and props

- **A fragment of the real interface, enlarged past any size a phone shows it.**
  That is the move that separates a poster from a screenshot. Recreated screens
  are colour-accurate to the shipping app or they are not honest.
- **Numbers reconcile.** 20.00 − 3.00 = 17.00. 4,285.50 ÷ 187 = 22.92.
  2,600.00 − 200.00 + 225.00 = 2,625.00.
- **Props are drawn, fictional, and not in our typeface.** We do not photograph
  a real shop's invoice: it would publish a real business's prices, phone number
  and customer. A prop that depicts a capability we have not proven — handwriting,
  say — is a promise, so do not draw it.
- **A competitor is an archetype, never a product.** No vendor's name, mark or
  copied layout. The claim is about how much is on screen at once, never about
  anyone's software being bad.
- **A third-party mark names a product; it never implies a partnership.**
  ZKTeco's logo appears in exactly one place, on the "works with" chip of the
  attendance poster, on the dark chip its reversed artwork was drawn for. Never
  recoloured, never on our teal, never larger than our own lockup. If the
  integration stops being true, the chip goes.

---

## 9. Where the brand lands

| Surface | Carries | Owned by |
| --- | --- | --- |
| App UI | Palette, type ramp, components, motion | `shared/design/*`, `DESIGN.md` |
| Thermal receipt | Mark stacked over دُوّن في دفتر | `branding.dart`, `esc_pos_receipt_encoder.dart` |
| PDF invoice / PO / report | Masthead, footer credit, table styling | `shared/pdf/*` — **see drift register** |
| Barcode labels | Price, name, Code 128 | `shared/pdf/` label path |
| Price-checker kiosk | Mark on a white medallion, shop name, the price | `PriceCheckerKioskView` |
| Client-download page | Title + heading in دفتر | `backend/apps/clients/views.py` |
| Posters & films | Grounds, lockup, copy anchor | `marketing/promo/` |
| Profile & covers | Avatar, covers, highlight circles | `marketing/promo/src/brand/` |
| Post copy | Voice, hashtags | `marketing/promo/POSTS.md` |

Still carrying the old identity, in priority order: app store and bundle
identifiers, the Android `applicationId`, and the icon/splash artwork.

---

## 10. Governance

**One value, one owner.** `pointy_colors.dart` owns colour; `branding.dart` owns
brand wording; `pointy_typography.dart` owns the ramp;
`marketing/promo/src/theme.ts` **mirrors** `pointy_colors.dart` token for token
and is not permitted an independent value. Change the app palette and change the
mirror in the same commit, or the films stop being honest.

Before anything brand-facing ships:

- [ ] Colours came from a token, not a hex typed into the file.
- [ ] Set in IBM Plex Sans Arabic, `letterSpacing: 0`, headline broken by hand.
- [ ] Every number on it reconciles with every other number on it.
- [ ] Money renders RTL-correct with د.ل; digits are Western and tabular.
- [ ] One claim, laddering to one of the four pillars.
- [ ] The limit is stated where the claim would otherwise over-promise.
- [ ] The mark has its clearspace and is not the hero.
- [ ] No competitor named, no third-party mark implying a partnership.
