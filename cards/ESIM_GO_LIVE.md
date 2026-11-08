# eSIMs: Airalo go-live checklist

Airalo's [go-live checklist](https://developers.partners.airalo.com/go-live-checklist-1531786m0),
where each item stands. The flow was run against Airalo's real Sandbox on 2026-11-05: browse, order, lookup
by reference, install details, usage, top-up, error packages, phone check. Still
unproven: the webhook signature (the simulator needs a public URL).

**To check on the first real top-up:** in Sandbox a top-up listed at $4 was charged $7.20,
twice in a row (`discount_amount` 1.8, so a base of $9). Airalo says Sandbox pricing is
emulated and does not reflect Production. The shelf prices from the list, so a real charge
like this would sell at a loss. The relay alerts the operator if it happens.

| # | Airalo asks | Status |
| --- | --- | --- |
| 1 | Live store URL for review | Owner: App Store and Play links |
| 2 | Primary customer segment | Owner (likely "Leisure travelers") |
| 3 | Signed contract | Owner |
| 4 | Sandbox flow: browse → order → install → top-up | Built; **run it on Sandbox credentials** |
| 5 | Can accept and complete live orders | Built; **1-2 real test orders after the switch** (sandbox ICCIDs cannot be installed) |
| 6 | Re-authenticates when tokens expire | Built: one shared token, renewed on 401 (`TestOneTokenIsSharedAndRenewedWhenRefused`) |
| 7 | Monitoring logs errors, requests, responses | Built: every call logged with op, path, status, code and time; never a token or activation code |
| 8 | Edge cases such as invalid ICCIDs | Built (`TestOrderAndItsEdgeCases`) |
| 9 | Packages synced hourly | Built: `ESIMCatalogSync` |
| 10 | Low-data webhooks notify customers and encourage top-ups | Built: pushes at 75%, 90%, 3 days, 1 day. **Set `POINTY_RELAY_AIRALO_WEBHOOK_URL`** |
| 11 | Handles 4xx/5xx gracefully | Built: Airalo's whole error table is sorted into refund, hold or retry |
| 12 | Safeguards against duplicate orders | Built: one claim per order, never resent, lost answers looked up first (`TestESIMLostAnswerIsFoundAndNeverOrderedTwice`) |

## Never sell on Sandbox: the shelf is the review account's alone

Sandbox eSIMs cannot be installed, while a customer's payment through Dafa would be real. So
while `_SANDBOX=true` the relay shows the shelf **only to the stores' review account**
(`POINTY_RELAY_CUSTOMER_REVIEW_PHONE`): every other caller, signed in or not, gets
`available: false`, a 404 on a destination, no device answer, and a refused `esim:` order, on
every route. The app sends its session with those reads and reads the shelf again on sign-in
and sign-out, so the shelf appears only once the review account signs in.

The review account pays for show (no Dafa), but its eSIM is ordered from **Airalo's Sandbox for
real**: it is on the Sandbox dashboard, installs with what Airalo issued, and its top-ups go
there too. Its orders are test money and stay out of the books, and the loss alert skips them
(Sandbox prices are emulated). On a live account (`_SANDBOX=false`) the shelf opens to everyone
and the review account goes back to simulated eSIMs, so a review never buys a real one.

Old app builds read the shelf without a session, so they never see a Sandbox shelf.

**App Review note (paste into the review notes while `_SANDBOX=true`):** «eSIM data plans are
shown only to this review account while our eSIM supplier, Airalo, completes its own review of
the app. They will open to all customers once it does, with no app update. The eSIMs bought
here are Airalo test eSIMs: they appear in the app and in our Airalo dashboard but cannot be
installed on a phone.»

## To turn it on

1. On a local or staging relay, set `POINTY_RELAY_AIRALO_CLIENT_ID`, `_CLIENT_SECRET`, `_SANDBOX=true` and
   `_WEBHOOK_URL` (`https://my.dftr.ly/v1/customers/esim/webhook`) on the relay.
2. If the account uses an IP allowlist, add the relay's outbound addresses (code 89
   otherwise).
3. Check on Sandbox what the fake cannot prove:
   - Webhooks do not fire in Sandbox. Use `POST /v2/simulator/webhook` with the
     relay's URL, and confirm **`airalo-signature` verifies**: Airalo's docs show
     the signature but not exactly which text it is computed over.
   - Package titles and country names in Arabic (`Accept-Language: ar`).
   - The response shapes of `GET /v2/balance` and `GET /v2/notifications/opt-in`.
4. Complete the checklist in the Partner Platform and ask for Production. It is one
   way: request separate Sandbox credentials first if you want to keep one.
5. Set `_SANDBOX=false`. Buy a real eSIM on an iPhone and on an Android phone, and
   install each with the button.

## Decisions to check

- **Price:** 100% of Airalo's recommended retail price at the card dollar rate
  (`POINTY_RELAY_AIRALO_RRP_PERCENT`), never under the card margin on net.
- **Store rules:** the shelf sells on every channel, on the reading that an eSIM is
  a telecom service used outside the app (App Store 3.1.3(e), the Play equivalent).
  While on Sandbox, only the review account sees the shelf and buys Sandbox eSIMs (see
  above; disclose it in the review notes). On Production it buys simulated ones. A new iOS
  build needs review.
- **Legal text:** `assets/legal/` gained eSIM clauses and Airalo as a recipient: for
  the lawyer to read.
