# دفتر كروت (`cards/`)

The company's consumer card app. People sign in with their phone, buy
prepaid cards (telecom, internet, games, gift cards) and get the code at once.
The plan, the App Store analysis and the owner's decisions are in
[`DAFTAR_CARDS_APP_PLAN.md`](../DAFTAR_CARDS_APP_PLAN.md). The relay API it
talks to is documented in [`relay/README.md`](../relay/README.md), section
«Card App Customers».

- **Arabic-first, right to left.** Every visible string lives in
  `lib/l10n/app_ar.arb`; run `flutter gen-l10n` after changing it.
- **One code base, four channels.** `--dart-define=CARDS_CHANNEL=ios|play|apk|web`
  tells the relay which build is asking. The App Store build (`ios`) is shown
  the service categories only (App Store guideline 3.1.1), by the server.
- **The brand** (colours, IBM Plex Sans Arabic, payment-method marks) comes
  from [`shared/pointy_brand`](../shared/pointy_brand). The card-stack mark
  (concept أ, `ui/daftar-cards-logo/`) is in `assets/branding/`. Regenerate the
  launcher icons with `dart run flutter_launcher_icons`.
- **Card art is cached for a year.** Logos and flags are addressed by their
  content hash, so a stored copy is never stale. On a phone they live in their
  own disk store (`src/shared/art_cache.dart`: a year after last shown, room
  for 600). On the web the relay's `immutable` answer keeps them in the browser.

## Design

The bar is Airbnb and Apple Music: calm pages, the card art carries the colour,
and every tap answers. The rules live in `src/design/`:

- **Tokens** (`cards_tokens.dart`): an 8-pt spacing scale with a 20-pt page
  gutter; radii 14 (art), 16 (tiles), 20 (cards), 28 (sheets), pills; two-layer
  soft shadows; motion at 110/160/240/420 ms on ease-out curves.
- **Theme** (`cards_theme.dart`): large bold titles, capsule buttons, a frosted
  tab bar, native page transitions per platform. Teal is rationed to the one
  primary action and to what is selected. Text that acts uses
  `CardsTheme.link`, which brightens on dark.
- **Shared pieces** (`src/shared/`): `Pressable` (scale + haptic),
  `SectionHeader` («عرض الكل»), `Pill`, `Grouped` (inset grouped rows),
  `SegmentedPill`, `PinBoxes`, `Skeleton`, `MethodRow`/`MethodMark`.
  Build new screens from these, not from fresh styling.
- **Haptics** (`shared/haptics.dart`):
  - Screens say what happened, never how strongly to buzz.
  - `select` for moving between choices; `tap` for buttons that start
    something.
  - `success`, `warning` and `error` are the system's own patterns, used as
    follows:
    - `success`: paid, signed in, the card is here.
    - `warning`: money back in credit, not paid, under review, a step that
      cannot be undone.
    - `error`: a wrong code, a declined payment.
- **When things fail:**
  - Money outcomes are never red. A refund shows the amount going into
    credit, and the card greys out.
  - A wrong code shakes the boxes, as the lock screen does, and clears them.
  - A checkout error slides in. A passing problem (no connection, a busy
    gateway) is a soft amber that says try again. Red is kept for real
    refusals. `relayErrorIsPassing` decides which.
- **Tab bar** (`features/shell/cards_tab_bar.dart`):
  - On iOS 26 and later it is Apple's own Liquid Glass tab bar.
    `cupertino_native_better` hosts the real UIKit bar in the page and
    draws our Material icons into it.
  - Everywhere else it is our frosted bar.
  - The iOS project declares Arabic as its language, so native views lay out
    right to left.
  - A debug build answers taps slowly on the simulator. Judge the feel on a
    release build.

## Opening (splash)

- **The system's splash** shows the real Daftar logo
  (`assets/branding/daftar_mark.png`) on the page colour at once.
- **The opening** (`src/features/splash/`) starts from that same picture, at
  the same size and in the same place. It turns it into the دفتر كروت mark
  while the app builds underneath:
  - The page reshapes into the card.
  - The pencil shrinks into its amber band, which stretches into the stripe.
  - The real logo pictures show at rest at both ends. Shapes traced from the
    Daftar logo carry the motion between them.
  - `tool/render_splash_test.dart` keeps the trace within 1% of the picture.
- **It never gets in the way:**
  - The full opening (about 1.5 s, with the name) plays at most once every
    6 hours. Other opens get a 0.6 s quick one.
  - A tap skips it. Reduced motion skips straight to the end.
  - Nothing waits on it.
- **Preview:** `?screen=splash`.
- **After a logo change:** `make cards-splash` redoes the native splash.

## Layout

    lib/
      main.dart                     reads the config, restores the session, runs the app
      src/config.dart               relay URL + channel from --dart-define
      src/dependencies.dart         the repositories, built once
      src/core/                     Result, Money (exact thousandths, never floats)
      src/data/api/relay_api.dart   JSON client; refreshes an expired token once for every waiting call
      src/data/session/             the token pair in the keychain/keystore
      src/data/models/              catalog, orders, codes, credit, customer
      src/data/repositories/        auth, catalog (cached on device, ETag), orders
      src/design/                   the app's theme and tokens on the shared brand
      src/data/vault/               delivered codes in the keychain; Face ID / fingerprint in front
      src/features/                 the screens (below)
      dev/cards_fixtures.dart       a fake relay with a realistic shelf (preview + widget tests)
      dev/cards_preview.dart        preview harness (not shipped)

## Screens

- **Home** (`features/home`):
  - Search first. It forgives how Arabic is typed: أ/إ/آ, ة/ه, ى/ي, diacritics, Arabic digits.
  - A large title, then a pinned search and an icon category bar (Airbnb).
  - A «الأكثر طلباً» carousel, «اشترِ مجدداً», then a shelf per category with
    «عرض الكل» (Apple Music). A category shows its brands as a grid.
  - Skeletons while loading. The saved shelf opens at once and offline.
- **Brand** (`features/brand`):
  - The art grows out of the shelf (Hero) over a brand-tinted header.
  - «تبدأ من», a trust row (instant, secure, saved), country chips, value
    tiles (an unavailable one is greyed, never hidden), and how to redeem.
  - A frosted bar: the total, the quantity stepper and «اشترِ».
- **Sign-in** (`features/sign_in`):
  - A sheet, asked only at the moment of buying or opening «كروتي».
  - The phone, then one 6-digit field that takes the OS's code autofill and
    goes on its own at the sixth digit.
  - A 30-second resend countdown and a specific message for each refusal.
- **Checkout** (`features/checkout`):
  - One sheet. The last-used method is preselected; «تغيير» opens the methods.
  - Credit first. Price, credit, fee and total are shown before paying.
  - The payer's details (wallet number, Sadad's birth year) are asked in a
    dialog after «ادفع».
  - A wallet's own code is asked in the same sheet, named for the wallet, so
    it is never confused with the sign-in code.
- **Order progress** (`features/orders`):
  - Watches the relay: every 2 s for a minute, then every 6 s, and at once when
    the app comes back to the front.
  - Opens the bank-card form (below); Dafa's page only as the fallback.
  - Shows a refund to credit, or an unpaid order.
- **Bank cards** (`features/card_payment`):
  - The app's own form: number grouped in fours with its network, the
    holder's name and MM/YY. Local cards carry no CVV, so none is asked.
    Luhn and expiry are checked before sending.
    The fields carry card autofill hints, so the phone's own card store can
    fill them and offer to save a card after a payment; the app keeps none.
  - The relay hands over the Moamalat checkout Dafa signed (`/card`); the
    phone calls Moamalat itself (`moamalat_client.dart`), so the card never
    passes through the relay, then sends Moamalat's receipt back
    (`/card/complete`). The relay believes only Dafa's read-back.
  - When the bank asks for its code (3-D Secure), its page opens inside the
    form's own page (`three_ds_view.dart`, webview_flutter); returning to
    `/v1/customers/card-return` carries the bank's answer, and the charge is
    sent again with it. Closing it goes back to the card.
  - No session from Dafa, Moamalat unreachable, the web build, or «الدفع من
    صفحة البوابة بدلاً من ذلك»: Dafa's page, as before.
  - Saved cards (`data/vault/card_vault.dart`), Stripe-style: an unchecked
    «احفظ البطاقة على هذا الهاتف» switch under the form; the card is kept
    only after it has paid. Next time the saved cards are tiles (•••• 0860,
    holder, expiry) and «ادفع» asks the phone for Face ID or the passcode
    before the app may read the number: the number sits in the Keychain
    (passcode-only, this device, `userPresence`) or the Keystore (biometric
    per read), never synced, never sent anywhere but Moamalat. The list
    (last four, name, expiry) is kept apart so it shows without a prompt.
    Removed from «حسابي» ← «البطاقات المحفوظة», and all of them on sign-out
    or account deletion. Not on the web.
- **Reveal** (`features/reveal`):
  - A seal springs in, then the card flips from its art to the code, with
    haptics on both. The code is large, one line, left to right, and copies
    in one tap. Several codes page with dots.
  - QR, «أرسلها هدية» by WhatsApp, and mark as used.
  - «اشحن الآن» dials only where the brand's redeem hint spells the code out
    (`*112*…#`). The app never guesses an operator's code.
- **كروتي** (`features/my_cards`):
  - Open orders first, then all / unused / used.
  - Saved codes open behind Face ID / fingerprint, unlocked for 5 minutes.
- **حسابي** (`features/account`):
  - The number, the credit and its history, the devices, signing out
    elsewhere, signing out, and deleting the account.
  - «حول التطبيق»: the about page (version, WhatsApp, site, open-source
    licences), the privacy policy and the terms of use. The sign-in sheet
    names the last two as links under «أرسل الرمز».
  - The legal texts live in `assets/legal/<doc>.<lang>.md` (`## ` headings,
    `- ` items, paragraphs), so they can be changed without touching code.
    A language without its own file shows the Arabic one. Change the «آخر
    تحديث» date with any change, and publish the same text on the web for
    the store listings.

Previews: `make cards-preview`, then `?screen=board`, or any single screen:
`home`, `brand`, `brand-itunes`, `sign-in`, `sign-in-code`, `checkout`,
`wallet-code`, `preparing`, `refunded`, `reveal`, `my-cards`, `account`,
`signed-out`, `onboarding`, `about`, `privacy`, `terms`, `card-pay` (the bank-card form; `&card=verify` has the bank ask for its code, `&card=decline` refuses the card). The address's path opens like a tapped `cards.dftr.ly` link: `/category/gaming?screen=home`, `/brand/pubg?screen=home`. Add `&platform=ios` or `&platform=android` for that phone's browser (the web «get the app» bar; a desktop browser's phone emulation still reports a Mac), `&theme=dark` for dark, `&lang=en` or `&lang=fr` for English or French (only while `AppSettings.languageChoice` is on).

`make cards-preview-live` is the same harness on the **real shelf** of a local
relay (`make relay-run`, then `pointy-relay vouchers catalog push
ops/catalog/catalog.json` to it). It is already signed in, and orders, payment
and codes stay fake, so `?screen=home` lets you walk the whole app (buy, pay,
reveal, كروتي, حسابي) on real brands and art without a phone or a payment.

End to end: `make relay-run` (customer OTP test mode, the web origin allowed),
then `make cards-web` and open `http://127.0.0.1:8093`.

## Links

`https://cards.dftr.ly/…` is the app's one official link, for ads, messages
and QR codes. On a phone with the app it opens the app (iOS Universal Links,
Android App Links); everywhere else it opens the web build at the same
address. `lib/src/features/links/cards_link.dart` lists every address:

| Address | Opens |
| --- | --- |
| `/` | the shelf |
| `/category/<key>` | one category (`telecom`, `internet`, `gaming`, …) |
| `/search?q=<text>` | the shelf searching |
| `/brand/<key>` | a brand's page; `?item=<item key>` starts on one card |
| `/my-cards`, `/account` | the other tabs |
| `/privacy`, `/terms`, `/about` | the legal pages and about |

An unknown address, a brand no longer sold or a category that is not on the
channel's shelf opens the shelf. Ad parameters (`utm_*`, …) are ignored. A link
tapped while the app runs closes what is open first, except a card payment
in progress. On the web, the address bar follows the tab, the filter and the
open page, so any page can be copied and shared.

A link pasted into WhatsApp, Telegram, iMessage or Facebook shows a preview:
a brand's link shows «كروت ليبيانا» and the brand's card on its own colours,
a category's link its name, any other link the shelf's mark. The relay
writes those `og:` tags into each page and draws the pictures itself
(`relay/internal/cardsweb`), every brand's ahead of time, since those apps
never run the page's code.

What makes the phone hand the link to the app:

- iOS: `ios/Runner/Runner.entitlements` (`applinks:cards.dftr.ly`) and
  `web/.well-known/apple-app-site-association` (team `TAA934964D`).
- Android: the `autoVerify` intent filter in `AndroidManifest.xml` and
  `web/.well-known/assetlinks.json`. It lists the SHA-256 of the key the APK
  is signed with; today that is the build Mac's debug key. When the app gets
  a release key (or Play App Signing), add that key's fingerprint there, or
  Android opens the links in the browser instead.

Hosting: the relay serves the web build on `cards.dftr.ly`
(`POINTY_RELAY_CARDS_WEB_HOSTS=cards.dftr.ly`; see `relay/README.md`).
`.github/workflows/cards-web.yml` publishes the build as the
`pointy-cards-web` image whenever `cards/` changes, and the relay image
copies the latest one in, so a new web build goes live with the next relay
release. `make cards-web-build` makes the same build locally.

The first load is kept small for slow mobile networks (about 2.4 MB on
Chrome, from 6.3 MB):

- **WebAssembly** (`--wasm`, the skwasm renderer) where the browser runs it,
  Chrome and Edge; Safari and Firefox get the JavaScript build in the same
  output.
- **`tool/web_postbuild.sh`** (part of `make cards-web-build` and CI; needs
  `brotli`, and `pyftsubset` from fonttools): fingerprints the code files so
  the relay caches them for good, adds preconnects and preloads for exactly
  what this browser will fetch, trims the web copy of the Arabic font
  (hinting and unused scripts; shaping checked identical), and writes Brotli
  and gzip copies beside each file. `relay/internal/cardsweb` sends them.
- **No Flutter opening on the web**: the page's own splash covers the
  download, and the app shows itself the moment it can.

## Analytics and feature flags

PostHog (EU cloud), spoken to only through `lib/src/core/analytics/`: the
rest of the app sees an `Analytics` with `capture`, `screen`, `identify`,
`reset`, `isEnabled(flag)` and a `flags` listenable.

- **Release builds only.** A debug `flutter run` sends nothing. The project
  token is public and baked in (`CardsConfig`); `--dart-define=CARDS_POSTHOG_TOKEN=`
  (empty) builds an app that sends nothing, `CARDS_POSTHOG_HOST` moves it.
- **Who.** Customers are their customer id once signed in, never their
  phone; a sign-out starts over. Every event carries `channel`.
- **Screens.** Name a page with `settings: screenSettings('name')` (sheets:
  `routeSettings:`). Not `RouteSettings(name:)`: that becomes the web
  build's address. The shell's tabs report themselves.
- **Never recorded.** Session replay and web autocapture stay off: a card's
  code is on screen.
- **Web.** `web/index.html` holds posthog-js's loader stub; the app calls
  `posthog.init` itself, so the library is fetched only with a token.

## Notifications

Firebase Cloud Messaging, project `daftar-cards` (apps `ly.dftr.cards` on iOS
and Android), spoken to only through `lib/src/core/push/`. Its client keys are
in `firebase_options.dart`: no `GoogleService-Info.plist` or
`google-services.json`. The web build has none.

- **Sending.** From the relay's operator console («تطبيق دفتر كروت» →
  الإشعارات): to everyone, to one build (`ios`, `play`, `apk`), or from a
  customer's page to that customer's phones. The App Store build sells
  services only, so an offer on game cards goes to `play` and `apk`, never
  everyone. A link (a `https://cards.dftr.ly/…` page) opens when tapped;
  the campaign name reaches PostHog (`push_opened`). Firebase's own console
  can send to the topics too.
- **One customer.** While signed in with notifications on, the app gives the
  relay its token (`PUT /v1/customers/me/push`, `core/push/follow_push_token.dart`);
  turning them off or signing out takes it away.
- **Asking.** The onboarding's last step offers notifications (with its own
  scene in the art); «ليس الآن» leaves the phone's question for after the
  first card is revealed, asked once. The account page has the switch.
- **While open.** An iPhone shows the banner itself; Android shows it along
  the bottom with «عرض».
- **iOS needs an APNs key** uploaded in Firebase (Project settings → Cloud
  Messaging → Apple app configuration: the `.p8`, its key id, team
  `TAA934964D`). Without it iPhones get nothing.

## Get the app (web)

On a phone's browser every page has a bar across the top offering the app
from its store (`features/shell/get_app_banner.dart`). Closed, it stays away
for two weeks. It shows only where the build was given the listing:
`--dart-define=CARDS_IOS_STORE_URL=…`, `CARDS_ANDROID_STORE_URL=…`; empty,
as now, it never shows. Preview it with `&platform=ios`.

## Commands

    make cards-check     # analyze + test this app and shared/pointy_brand
    make cards-run       # run against a local relay (CARDS_RELAY_URL, CARDS_CHANNEL)
    make cards-preview   # preview harness on :8090 (screens listed above)
    make cards-web       # the real web app on :8093 against a local relay
    make cards-web-build # the web app for https://cards.dftr.ly (build/web), as CI builds it

Run a local relay with `make relay-run`. It turns on the customer OTP test mode,
so the sign-in code comes back in the response instead of by SMS.
