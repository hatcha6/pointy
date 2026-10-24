# دفتر كروت — consumer voucher app (plan)

Status (2026-10-24): **phases 2–5 built** (uncommitted):

- relay phone sign-in;
- catalog, orders, Dafa payment (fee on top) and credit;
- the app foundation in `cards/` on `shared/pointy_brand`;
- every screen (see `cards/README.md`), run end to end on the web build against the real relay. Everything else is still a plan. Open decisions are at the end.

A phone-first app where any customer in Libya signs in with their phone number,
browses the company's card shelf (the same catalog «كروت دفتر» sells through
shops), pays with a Libyan method through Dafa, and gets the code at once.

---

## 1. Apple (and Google): is the idea allowed?

**Partly. The rule is narrower than "vouchers may use other payment methods".**

App Review Guidelines, current text:

- **3.1.1:** "Digital gift cards, certificates, vouchers, and coupons which can be
  redeemed for digital goods or services can only be sold in your app using
  in-app purchase."
- **3.1.3(e):** "If your app enables people to purchase physical goods or services
  that will be consumed outside of the app, you must use purchase methods other
  than in-app purchase."
- Developers selling PlayStation/Xbox/Steam codes through regional gateways were
  rejected in 2026 with: "The app allows users to purchase or sell digital items,
  codes, or currencies to be used in other apps or third-party platforms."
  (Apple forums thread 842225, no successful appeal on record.)
- The anti-steering exemption (links to outside payment) applies to the **US
  storefront** only, plus entitlement regions (EU, Japan…). Not Libya.

What that means for our shelf on iOS:

| Shelf | Examples | iOS with Dafa? |
|---|---|---|
| Telecom recharge | Libyana, Almadar, LTT | **Yes**: a real-world service consumed outside the app (3.1.3(e)) |
| Internet / TV subscriptions | LNET, HD Box | **Yes**: same reasoning |
| Bills | Reloadly utilities | **Yes** (Google even lists bill remittance by name) |
| Game & app store cards | PUBG UC, Free Fire, PSN, Xbox, Steam, iTunes, Google Play, Netflix, Spotify | **No**: digital goods → IAP only |
| Shopping gift cards | Amazon, noon | Grey. Amazon buys physical goods but also Kindle/Prime; expect a rejection |
| Crypto / prepaid instruments | Binance USDT, Mastercard | **No** on iOS (3.1.5 plus financial rules). Keep them off the app entirely |

IAP is not a way out: Apple keeps 15–30 % and our card margins are about 4–8 %.
Libyan payouts from Apple are also doubtful.

**Do not hide the game cards from review and switch them on later.** That is
guideline 2.3.1 (hidden features) and can cost the whole developer account,
including any future Daftar POS app on iOS.

**Google Play** also requires Play Billing for digital goods. Its exceptions are
physical goods, physical services, and bill remittances. In practice Play is
looser with gift-card resellers, but the written policy is the same risk. **Our
own APK download (no store) and a web app carry no store rule at all.** Many
Libyan users already install APKs.

Other store requirements that apply either way:

- In-app **account deletion** (5.1.1(v)).
- Phone-OTP sign-in is our own system, so **no Sign in with Apple** is required
  (4.8 exemption).
- Let people **browse without signing in**; ask for the phone at checkout.
- A payments app should be published from an **organization** developer account
  (D-U-N-S), not a personal one.

**Recommended distribution:**

1. Android: the full shelf via a direct APK and a PWA. Put the services shelf on
   Play, and add the full shelf there only after weighing the risk.
2. iOS: the **services-only** build (telecom, internet, TV, bills), plus the full
   shelf on the web for iPhone users.
3. Same code everywhere. The shelf a build may show comes from the **server**
   per platform/channel (`channel=ios|play|apk|web`), and the iOS build shows
   that shelf openly, with no switch to flip after review.

## 2. What we reuse (already built)

- **Catalog & supply:** `relay/internal/vouchers` already handles shop view,
  ranking, ETag, prices, availability, promos and flags. Supplier ranking runs
  across BN Plus, Reloadly and our own stock. Images are served from
  `/v1/vouchers/images/{sha}`. The ops pipeline covers logos and card art
  (`ops/catalog`).
- **Purchases:** `placeCardPurchase` / `placeServiceOrder` take a `voucherBuyer`.
  Company purchases (`installation_id NULL`, `vouchers_company.go`) already show
  that a buyer without a shop works with the same ledger, reconciler and holds. A
  customer becomes a third buyer kind.
- **Codes:** the relay keeps no codes and re-reads them from the supplier by
  order id. A customer's reveal reuses that path.
- **Payments:** `relay/internal/dafa` (Initiate / Confirm OTP / Payment read-back)
  and `wallet_gateway.go` verify/settle logic. That logic is the "only Dafa's
  answer is proof" rule, with the webhook as a nudge and an HMAC webhook token.
  Seven methods: Sadad, Edfali, Mobicash, Yusr Pay, Masrafi Pay, Sahara Pay,
  Moamalat cards. Icons are in `frontend/assets/payment_methods/`.
- **SMS:** `relay/internal/resala`. It currently has template sends only; an OTP
  sender has to be added (§3).
- **Flutter UI:** `voucher_card_art.dart`, `voucher_country_flag.dart`, the
  bundled flags, `PointyTheme` tokens and the IBM Plex Sans Arabic font. Brand
  sheet / denomination tiles exist in `features/pos/views/pos_voucher_*`.

## 3. What is new

### Relay (Go): `internal/customers` + `relay/customer_*.go`

- **Phone OTP**
  - `POST /v1/customers/auth/otp` {phone} sends a 6-digit code.
  - `POST /v1/customers/auth/verify` {phone, code, device} returns a session.
  - Codes are hashed at rest, live 5 min, allow 5 tries, and resend after 30 s
    (server-enforced).
  - Rate limits per phone, per IP and per device, plus a daily cap per number,
    because SMS costs us per part.
  - Sender: Resala's OTP source (`/pins`) if our account has it; otherwise an
    approved template «رمز الدخول إلى دفتر كروت: $1». Either way the text ends
    with the Android SMS-Retriever app hash, and the `@domain #code` line enables
    iOS domain-bound autofill.
  - Libyan numbers only (`2189[1-5]…`).
- **Sessions:** a short access token plus a rotating refresh token bound to the
  device. "Sign out everywhere" and **delete account** (anonymises the phone and
  keeps the money ledger).
- **Customer orders** (`relay_customer_orders`)
  - Each order holds: customer, item, qty, quoted price, `channel`, Dafa
    payment id, and state.
  - States: `awaiting_payment → paid → fulfilling → delivered | refunded`.
  - The supplier purchase is placed **only after Dafa's own read-back says
    paid**. It reuses `placeCardPurchase` with `voucherBuyer{CustomerID}` and
    the idempotency key `corder:<id>`.
- **Refunds:** our Dafa client has no refund call. If the supplier fails after
  the customer paid, the money goes to a **customer credit** («رصيد في دفتر
  كروت») that pays the next order. A cash-out is done by an operator from the
  console. See decision D3.
- **Catalog for customers:** `GET /v1/customers/catalog?channel=` is the shop view
  filtered by the channel's allowed categories and priced at the consumer price
  (D2). It uses the same ETag.
- **Console:** a customers page (lookup by masked phone, orders, credit, block)
  and orders appear in the company books as their own income line.

### Flutter app: `cards/` (project `pointy_cards`, bundle id `ly.dftr.cards`)

- It is a separate app (its own bundle id, icon and store listing), not a mode of
  the POS. The POS carries printers, cameras and native plugins that a consumer
  app must not ship.
- The shared look lives in `shared/pointy_brand/` (palette, type face, payment
  marks, logo). The card app depends on it. The till moves onto it later; its
  class names match, so that move is a re-export.
- Arabic-first, RTL, l10n through `AppLocalizations`, dark mode. Codes and phone
  numbers are wrapped LTR-isolated.
- A preview harness `lib/dev/cards_preview.dart` (`?screen=board|home|brand|
  checkout|reveal|wallet|login`) is cloned from the stock-count harness.

## 4. UX: what "exceptional" means here

Principles from the research (Visa/Twilio OTP patterns, Voucherify gift-card UX,
2026 fintech trust patterns) and from what Libyan buyers do today (Qareeb in shops,
Libyana's gamecode.ly by SMS):

1. **Seconds, not steps.** The core loop (open → card → pay → code) is about
   4 taps for a repeat buy. «اشترِ مجدداً» sits at the top of home.
2. **No login wall.** Browse freely; the phone is asked for at the moment of
   paying, inside the checkout sheet, without leaving it.
3. **Trust made visible.** Show the exact LYD price before anything, the method's
   logo and colour, «الكود يصلك فوراً», and a clear state for "payment received,
   card on its way". Never a blank error.
4. **The reveal is the product.**
   - The card art flips to the code.
   - The code is large, monospaced and LTR, with one tap to copy, a haptic tick
     and a toast.
   - **«اشحن الآن»** opens the dialer with the recharge string
     (`*121*PIN#` style per operator) for telecom cards.
   - «طريقة الاستخدام» shows the brand's 3 redeem steps.
   - «أرسلها هدية» shares the card by WhatsApp.
   - A QR is available for scanning from another phone.
5. **Every code is kept safe.** «كروتي» lists every purchase. Codes are blurred
   until Face ID / fingerprint, and the user can mark a card «مستخدم». Codes are
   always re-readable from the relay, so changing phones loses nothing.

Screens:

- **Sign-in sheet**
  - A fixed `+218` chip. The field accepts `09x…`, `9x…` and `2189x…`, formats
    as `09X XXX XXXX`, and shows the operator logo once recognised.
  - Then one 6-digit OTP field with autofill (iOS `oneTimeCode`, Android SMS
    Retriever). It auto-submits on the 6th digit.
  - A 30 s countdown turns into «أعد الإرسال», and «تعديل الرقم» stays one tap
    away.
  - A wrong code shakes the field with a specific message (wrong / expired / too
    many tries).
- **Home**
  - Search first. It accepts Arabic and English names and spelling slips
    («ببجي» = PUBG).
  - Below the search: a buy-again row, category chips (اتصالات · إنترنت ·
    ألعاب · تسوّق · ترفيه), and a brand grid of 16:10 card art.
  - Promo stickers come from the catalog. Unavailable cards are greyed, never
    hidden.
- **Brand page**
  - The hero card art, country chips with bundled flags, and denomination tiles
    with the LYD price. The cheapest tile is highlighted.
  - A quantity stepper (≤10) and a sticky bottom bar «ادفع ٥٠٫٠٠ د.ل».
- **Checkout sheet** (one sheet, no page change)
  - Order summary, then the last-used payment method preselected, with the
    other methods one tap away as logo tiles.
  - The pay button opens the payer dialog (wallet phone / Sadad birth year),
    following the existing wallet rule.
  - The wallet OTP is labelled with the wallet's name, so it is never confused
    with the sign-in code.
  - Moamalat card payments open Dafa's hosted page in an in-app browser.
- **Pending**
  - An animated progress state. The relay resolves the order itself.
  - A push notification arrives when the card is ready, so the user can leave
    the app.
- **Reveal** — as above.
- **كروتي** — search and filters (غير مستخدم / مستخدم / الكل), each card opens
  its reveal.
- **حسابي** — phone, credit balance, orders, support (WhatsApp), terms, delete
  account, and appearance (system/light/dark).

Craft details:

- Skeletons instead of spinners.
- Images cached with the catalog ETag, so the second open is instant.
- Haptics on copy, success and error.
- Motion: 200–300 ms ease-out, respecting "reduce motion".
- 48 px touch targets.
- Western digits in prices, matching the existing money format (`money()` /
  «د.ل» on the left).

## 5. Logo: «دفتر كروت»

Keep the master mark: teal rounded square, a folded light page, the amber band.
Turn the page into a **card**:

- The page becomes a stack of two cards (the fold is already there).
- The pencil gives way to the amber band running across the front card as a gift
  ribbon / card stripe.
- A small notch or chip on the card makes it read "voucher".

Wordmark «دفتر كروت»: «دفتر» in the master weight, «كروت» in amber.

We will draw 3 concepts as SVG, judge them at 1024 px, as a 48 px home-screen
icon and in mono, then pick one.

## 6. Phases

1. **Decisions** (below) + logo concepts.
2. **Relay auth** (BUILT; API and settings in `relay/README.md`, «Card App Customers»): OTP, sessions, delete account, rate limits. Tests on
   Postgres with a fake Resala.
3. **Relay orders** (BUILT; «Catalog and orders» in `relay/README.md`): catalog channel filter, consumer price, Dafa order flow,
   purchase, reveal, credit, reconciler. E2E in test mode with the real binary,
   like the shop flow.
4. **App foundation** (BUILT: `cards/`, `shared/pointy_brand/`; see `cards/README.md`): project, `daftar_design` package, l10n, API client,
   secure token storage, preview harness.
5. **App screens** (BUILT) in the order sign-in → home → brand → checkout → reveal →
   كروتي → حسابي, each previewed at 390 / 430 / 768.
5b. **Premium polish** (BUILT): an Airbnb / Apple Music pass. Tokens (8-pt scale,
   radii, two-layer shadows, motion), large titles, pinned search + icon category
   bar, featured carousel and per-category shelves, Hero art into a tinted brand
   header, frosted buy bar and tab bar, grouped settings rows, PIN boxes for the
   sign-in code, a spring seal and flip on reveal, press-scale + haptics. See
   «Design» in `cards/README.md`.
6. **Release:** APK + PWA first, then Play (services shelf), then the App Store
   services-only build with review notes that explain the shelf.

## 7. Decisions

**Owner's calls (2026-10-24):**

- D1: the App Store gets the **services-only** build. Game and gift cards are sold
  through the APK and the web app.
- D2: customers pay the **same price as shop retail**. The part paid through
  Dafa carries the gateway fee on top, shown before paying, like a shop
  top-up (decided 2026-10-24). The fee is grossed up so Dafa's share of the
  whole payment is covered: 10.00 → 10.21 at 2%.
- D3: a card that fails after payment is credited to the customer's **in-app
  balance**. An operator can cash the balance out. This still needs a lawyer's
  check on stored-value rules.
- Logo: **concept أ, the card stack** (`ui/daftar-cards-logo/a-card-stack.svg`): two tilted cards, an amber stripe on the front card, and a teal chip.

Still open: D4.

Original options, kept for the record:

- **D1 iOS scope:** services-only on the App Store (recommended), or skip iOS and
  send iPhone users to the web app.
- **D2 Consumer price:** the app sells direct, so it competes with our own shops.
  Options:
  - (a) the same retail price shops charge (recommended: shops are not undercut);
  - (b) a small premium;
  - (c) cheaper than shops.
- **D3 When a card fails after payment:** credit to the customer's in-app balance
  (instant, recommended), or a manual refund by an operator. A spendable
  customer balance may count as stored value under Central Bank of Libya rules;
  credit-only-from-refunds keeps it small, but a lawyer should confirm.
- **D4 Resala OTP:** confirm our Resala account has the OTP (`/pins`) source, or
  register an OTP template.
