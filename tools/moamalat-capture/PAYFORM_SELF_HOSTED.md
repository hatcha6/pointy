# Moamalat PayForm™ Plus — self-hosted card form (design)

> **Status: Option A (§6a) BUILT for the card app «دفتر كروت» (2026-10-25):**
> the relay hands the app Dafa's signed session (`relay/internal/dafa/cards.go`,
> `relay/internal/relay/customer_card_form.go`) and the phone calls Moamalat
> itself (`cards/lib/src/features/card_payment/`), so no PAN reaches our
> servers. 3-D Secure runs in a web view inside the app's page, like
> Moamalat's own iOS SDK (`Numo-iOS-SDK` PayButton: WKWebView on
> `ThreeDSUrl`, query params of the return URL → JSON → PayByCard again).
> Not yet run against the live sandbox. The POS's backend-proxied design
> below is still unbuilt.
>
> **Original status: reverse-engineered, not yet built.** Goal: replace Moamalat's hosted
> LightBox iframe with our own native Flutter card form, so the POS owns the UI,
> the RTL/Arabic layout, and the error handling instead of embedding PaySky's
> buggy white-label page. The actual charge is **backend-proxied**: our Django
> backend holds the merchant secret, signs the request, calls Moamalat, and
> verifies the signed receipt before anything books a `CardSettlement`.
>
> This is a *card-acceptance* (merchant-initiated charge) flow, distinct from
> the view-only merchant-data capture in `API_CONTRACT.md` and from the
> receipt-QR parser in `backend/apps/payments/card_receipts/moamalat.py`.
>
> Sandbox credentials below are Moamalat's **own published test data**
> (`docs.moamalat.net/testData.html`) — not secrets. Real MID/TID/secret key
> live in config, never here.

## 0. How the official integration actually works

The documented integration is: include a `<script>`, set
`Lightbox.Checkout.configure = {…}`, call `showLightbox()`. That script
(`https://tnpg.moamalat.net:6006/js/lightbox.js`, prod `npg…`) is a **thin
shim** — it contains no payment logic. All it does:

1. Reads your `configure` object, divides `AmountTrxn` by 1000, and builds a URL
   to `https://tnpg.moamalat.net:6006/Home/LightboxHostedCheckout?<all config as
   query params>` (note: `secureHashAnonymous`, `trxDateTime`, colours, customer
   fields all travel as query params).
2. Injects that URL as a full-screen `<iframe id="Lightbox">`.
3. Adds a `window.addEventListener('message', …)` that dispatches the iframe's
   `postMessage` payloads to `configure.completeCallback` / `errorCallback` /
   `cancelCallback`.

`showPaymentPage()` is the same thing as a full-page redirect instead of an
iframe. That is the entire shim.

**The hosted page** at `…:6006` is a static **Angular SPA** (esbuild bundle,
PaySky white-label — EGP flags, Meeza/NUMO/Jaywan logos, `poweredby:
Paysky_Logo`). It is just a client. The real work is a JSON API on a **different
origin**:

- **API base — test:** `https://tnpg.moamalat.net:6008/`
- **API base — prod:** `https://npg.moamalat.net:6008/`  *(confirm prod port on
  first live merchant)*
- All calls are `POST https://<base>/api/<Endpoint>`, `Content-Type:
  application/json`, `access-control-allow-origin: *` (so CORS does not block a
  direct call; we proxy anyway, see §5).
- Apple Pay session + Firebase-style attestation hosts seen in the bundle:
  `local.yalla.online:7007` (ApplePay, dev artifact), CyberSource device
  fingerprint `h.online-metrix.net`. Not needed for card entry.

So we do not need the shim or the iframe at all for card entry. We reproduce two
API calls (`LightboxHostedCheckout` + `PayByCard`) and only fall back to a
WebView for the 3-D Secure challenge, which is the one step that genuinely must
render the bank's ACS page.

## 1. Endpoints (recovered from the SPA bundle)

Base service prepends `api/`. Endpoint name constants from the bundle:

| Endpoint (`/api/…`)          | Used for                                              | Auth |
|------------------------------|-------------------------------------------------------|------|
| `LightboxHostedCheckout`     | init a hosted-checkout session (anonymous hash)       | none (hash in body) |
| `OpenLightBox`               | init a **pay-link** session (`MID/TID/POID`)          | none |
| `PayByCard`                  | **the charge** (card, saved-token, or Apple Pay)      | `Bearer <session JWT>` |
| `ApplePayStartSession`       | Apple Pay merchant validation                         | `Bearer` |
| `GenerateQR`                 | mVisa / wallet QR                                     | `Bearer` |
| `RequestToPay`               | wallet push-to-pay                                    | — |
| `CheckTransactionStatus`     | poll QR/wallet result                                 | — |
| `UpdateAliasToken` / `RemoveToken` / `ChangeDefaultToken` | saved-card management         | — |
| `OrderPaymentFeedback`       | post-payment feedback (optional, cosmetic)            | — |
| `signal` (WebSocket)         | SignalR hub `…/signal?POID=<id>`, pushes `checkTxnStatus` to trigger the poll | — |

For a card charge we need **only** `LightboxHostedCheckout` then `PayByCard`.
Wallet/QR/ApplePay are documented here for completeness but are phase 2.

## 2. Request secure hash (the only server-trusted secret)

HMAC-SHA256. **Key = the merchant secret key, hex-decoded to bytes** (the key
string is itself hex). Message = sorted `name=value` pairs joined by `&`.

Request-hash fields (ascending by name):
`Amount`, `DateTimeLocalTrxn`, `MerchantId`, `MerchantReference`, `TerminalId`.

- `Amount` is in **minor units** (1 LYD = 1000). `DateTimeLocalTrxn` =
  `yyyyMMddHHmm` (12 chars, == the `trxDateTime` sent to init).
- Result: hex, **uppercase**.

Verified against the doc's own vector:
```
key  35333335653063302D663464372D343237652D623739362D643234666661386432323065
msg  Amount=100&DateTimeLocalTrxn=202009171418&MerchantId=43233&MerchantReference=Txn-1234&TerminalId=53532091
→    EAD7AB68E23BFF2E5B03F4A0CD41581722FD14C349C6743CD91B577341465A61   ✓
```

## 3. Flow

### 3.1 Init — `POST /api/LightboxHostedCheckout`

Request body (field names exactly as the SPA sends them; most of the
`AdditionalCustomerDataReq` block is optional cosmetic/wallet config and can be
omitted or null):

```json
{
  "OrderID": "",
  "MID": "10081014649",
  "TID": "99179395",
  "Amount": 1.5,
  "Referrer": "",
  "PaymentMethodFromLightBox": 2,
  "MerchantReference": "<our invoice ref, ≤50 chars>",
  "SecureHashAnonymous": "<request hash, §2>",
  "TrxDateTime": "202610130116",
  "feeAmount": 0,
  "AdditionalCustomerDataReq": { "AdditionalFees": 0 },
  "ReturnUrl": ""
}
```

> Note the minor-unit quirk: init takes `Amount` as **major units** (`1.5`),
> because the shim divides `AmountTrxn/1000` before building the URL — but the
> **hash** is computed on **minor units** (`1500`). Keep both representations.

Response (`message: 7` means OK — see the enum in §4; it is *not* an error
despite the "Success with an unknown error" label):

```jsonc
{
  "orderDetailsModel": {
    "merchantID": "10081014649",
    "merchantReferenceNumber": "<our ref>",
    "merchantName": "TEST_SDK",
    "formatedAmount": "LYD 1.500",
    "terminalID": "99179395",
    "currency": 434,                 // LYD ISO numeric
    "currencyName": "LYD",
    "amount": 1,                     // echoes init Amount
    "orderID": null,
    "extraInfo": "<txn correlation id, needed for wallet status>",
    "paymentMethod": "Card",
    "isCard": true,
    "supportedPaymentMethods": ["mastercard","visa","numo"],
    "supportedPaymentCards": ["mastercard","visa"],
    "termsAndConditions": "<html>", "termsAndConditionsEnabled": true,
    "showLightboxFeedback": true,
    "merchantBankLogo": "data:image/…",   // base64, for the SPA UI — we ignore
    "cardModel": { "...": "echo of ids + CyberSource fingerprint refs" }
  },
  "message": 7,
  "token": "<session JWT>"            // <-- carry this into PayByCard
}
```

The **`token`** is an HS256 JWT: `{MID, TID, CacheKey:"Order_<uuid>", exp, iss:
"SecureApi", aud:"SecureApiUser"}`. It is the per-session bearer. `CacheKey`
binds the session to the amount/ref server-side, so `PayByCard` cannot be
replayed with a different amount.

### 3.2 Charge — `POST /api/PayByCard`  (header `Authorization: Bearer <token>`)

```jsonc
{
  "CardPaymentModel": {
    "amount": 1, "currency": 434,
    "orderID": null,
    "terminalId": "99179395", "merchantId": "10081014649",
    "merchantName": "TEST_SDK", "merchantReference": "<our ref>",
    "cardNumber": "6395043835180860",   // digits only
    "expiration": "0127",                // MMYY, no slash
    "nameOnCard": "…",
    "cVV": "",                           // NUMO may allow empty; Visa/MC require
    "isSaveCard": false, "isTokenized": false,
    "deviceFingerPrint": "{…}",          // JSON string, browser-info object; see §6
    "ReturnURL": "<OUR 3DS return url>", // client-chosen! see §3.3
    "additionalCustomerData": "{}"
  },
  "token": "<session JWT>",
  "amount": 1,
  "customerPaymentOrderFields": []
}
```

Response — two shapes:

- **Approved, no 3DS** (`message:7`, `threeDSSecureModel:null`): a signed
  `receiptModel` (see §3.4). Done.
- **3DS required** (`message:7`, `threeDSSecureModel.threeDSURL` present): render
  that URL in a WebView (§3.3), then **re-POST the same `PayByCard` body** with
  `CardPaymentModel.vPCData` set to the 3DS result, to finalise.

Saved-card and Apple Pay are variants of the same `PayByCard` call
(`isTokenized:true` + `tokenCardId`/`tokenizedCardsStr`, or
`applePayPaymentToken`). Out of scope for v1.

### 3.3 3-D Secure — the one unavoidable WebView

`ReturnURL` is **set by the client**, not the server. The SPA computes
`window.location.origin + <base> + "/three-ds-return-url"` and the ACS posts the
result back to that route. The return page simply collects the query string and
`postMessage`s `{action:"3DS", threeDsResponse:<json string of all params>}` to
its opener. Then the SPA re-calls `PayByCard` with `vPCData = threeDsResponse`.

For Flutter: host a trivial return page at a URL we control (our backend, e.g.
`https://<shop-relay>/moamalat/3ds-return`), load `threeDSURL` in a
`WebView`/`flutter_inappwebview`, intercept navigation to our return URL, read
the query params, hand them back to the backend as `vPCData`, and let the
backend finalise `PayByCard`. The ACS page is the only HTML we ever render.

### 3.3a The OTP screen — why it stays a WebView (not native fields)

A common ask: let the customer type the SMS OTP into *our* field. **We cannot,
and must not.** The `threeDSURL` is the **issuing bank's ACS page**; under EMV
3-D Secure only the issuer may present and validate the OTP challenge, and the
ACS signs the result (`vPCData`) that the acquirer checks. The SPA proves there
is no native OTP path: the entire 3DS handler (`app-three-ds-checker`) is just
`iframe src = threeDSURL` + a `postMessage` listener for the signed result —
there is **no OTP input field anywhere in the card flow** (grep of the bundle:
the only `otp` hits are an unused PrimeNG `inputotp` widget and a `hotpink`
false positive). Collecting the OTP ourselves and forwarding it would fail
validation and break the scheme/acquirer agreement and our PCI/3DS posture.

What we *do* own is everything around it. Card entry, brand logos, amount,
Arabic/RTL chrome, spinners, errors, the success receipt — all native Flutter.
Only the few seconds of the OTP challenge render the bank's page, and we embed
that `WebView` **inline inside our own sheet** (our header/footer/loader) so it
reads as one continuous Pointy screen with a bank OTP box in the middle, not a
jump to Moamalat's page. On redirect to our return URL we tear the WebView down
and finish natively.

Note 3DS is conditional: the issuer/scheme decides. The sandbox **NUMO** test
card approved with `threeDSSecureModel: null` — **no OTP step at all**, fully
native end to end. Visa/Mastercard will usually challenge, so the WebView path
must exist, but a large share of local-card tills may never see it.

### 3.4 Receipt + its signature (what the backend must verify)

`receiptModel` on success:

```jsonc
{
  "referenceNumber": "628601183699", "systemReference": "1334761",
  "networkReference": "628601183699",
  "txnDate": "261013011634",         // yyMMddHHmmss
  "merchantReference": "<our ref>", "amount": "1500", "currency": "434",
  "paidThrough": "Card", "payerAccount": "639504XXXXXX0860",
  "payerName": "…", "providerSchemeName": "",
  "merchantId": "10081014649", "terminalId": "99179395",
  "formattedAmountWithCurrency": "1.500 LYD",
  "secureHash": "<HMAC>"
}
```

**Receipt hash** (same HMAC/key as §2) covers, ascending:
`Amount`, `Currency`, `MerchantId`, `MerchantReference`, `PaidThrough`,
`TerminalId`, `TxnDate`
→ `Amount=1500&Currency=434&MerchantId=…&MerchantReference=…&PaidThrough=Card&TerminalId=…&TxnDate=<txnDate>`.
This matches the docs' "complete callback" rule (all response params except
`SecureHash`, sorted) for the card case. The backend **must** recompute and
reject a mismatch before booking anything — the receipt is otherwise forgeable,
exactly the gap `card_receipts/moamalat.py` documents for the QR path.

## 4. `message` code enum (from the bundle's `sendErrorCallback` map)

`7` = OK/success. Everything else is a failure to surface in Arabic:

```
0 OrderNotFound      1 PaidOrder            2 CancelledOrder     3 AlreadySubmitted
4 NoChannelAllowed   5 Merchant/TerminalInactive  6 InvalidTerminalPayFromWeb
7 Success            8 InvalidMerchantID    9 InvalidTerminalID  10 InvalidCurrency
11 AmountNotValid    12 ErrorProcessingOrder 13 UnknownError     14 InvalidExpiryDate
15 InvalidDomainRequest  16 OrderExpired     17 InvoiceError
```
`PayByCard` may also carry `vpcMessage` / `errorMessage` (acquirer text) and
`isExpiredCard`.

## 5. Our architecture — backend-proxied

```
Flutter (our card widgets, Arabic/RTL)
   │  POST /pos/card/moamalat/charge  { invoice, amount, PAN, exp, cvv, name, deviceInfo }
   ▼
Django backend (apps/payments)
   │  1. compute request SecureHash  (merchant secret, server-only)
   │  2. POST /api/LightboxHostedCheckout  → session JWT
   │  3. POST /api/PayByCard (Bearer JWT)
   │       ├─ 3DS? return {threeDSURL} to client; client runs WebView; re-call with vPCData
   │       └─ receipt → verify receiptModel.secureHash → book CardSettlement
   ▼
Moamalat API  (tnpg/npg …:6008)
```

Why backend-proxied (your call, recorded):
- Merchant **secret key never ships** in the Flutter binary.
- PAN/CVV transit our backend once and are **not stored** (forward, discard) —
  keeps the client out of the worst of PCI scope; revisit whether even that hop
  is acceptable vs. a tokenised/hosted-field option before go-live.
- The backend is the only place that can **verify the receipt hash** and tie the
  `systemReference`/`networkReference` to the invoice + drawer session, which is
  the whole point of the Moamalat integration (see memory
  `card-settlement-moamalat`: clearing kind + `CardSettlement`, claim is derived).
- Idempotency: key on our `MerchantReference` (= invoice-scoped, ≤50 chars);
  Moamalat rejects a reused ref as `PaidOrder(1)`/`AlreadySubmitted(3)`.

### Backend pieces to add (`apps/payments`)
- `moamalat_payform.py` — client: `sign()`, `init_checkout()`, `pay_by_card()`,
  `finalise_3ds()`, `verify_receipt()`. Mirror the hash helper already proven in
  `tools/moamalat-capture`. Hosts/keys from config, **test vs prod by env**.
- A DRF view `POST /pos/card/moamalat/charge` (+ a `…/3ds-finalise`), permissioned
  like other till card actions, attributing cashier + drawer session per
  `invoice-cashier-attribution`.
- On verified receipt → existing `CardSettlement` booking path (treasury
  clearing kind), never re-tagging payments (memory `card-settlement-moamalat`).
- Tests on **Postgres** (`make backend-test-pg`), against a recorded fixture of
  the sandbox init/pay/receipt JSON — do **not** hit the live sandbox in CI.

### Flutter pieces
- A `MoamalatCardForm` widget (our design system, dense, RTL, Arabic strings in
  `l10n/`, no hardcoded copy) collecting PAN (grouped), expiry `MM/YY`, CVV,
  name; Luhn + expiry validation client-side (the SPA's rules: exp year ≤
  now+20, CVV length per BIN).
- Card-brand detection for the input logo (visa/mastercard/numo) — cosmetic.
- 3DS: `flutter_inappwebview` **embedded inline in our payment sheet** (our
  chrome around the bank's ACS/OTP page — see §3.3a), intercept our return URL,
  pop with the params. The OTP box is the bank's, not ours, by design.
- Never persist PAN; send once to our backend over TLS.

## 6. `deviceFingerPrint` object (CyberSource browser info)

`PayByCard` wants a JSON string of browser/device info. On web the SPA fills it
from `navigator`/`screen`. From Flutter we send an analogous object (timezone,
language, screen w/h, platform, user-agent-ish). Fields the SPA sends:
`timeOpened, timezone, referrer, previousSites, browserName, browserEngine,
browserVersion1a/1b, browserLanguage, browserOnline, browserPlatform,
javaEnabled, dataCookiesEnabled, sizeScreen*/sizeIn*/sizeAvail*, scrColorDepth,
scrPixelDepth, browserAcceptHeader`. Most are advisory for risk scoring; send
best-effort, do not fail the charge if some are absent.

## 6a. Relationship to Dafa (`dafa.ly`) — cards are Moamalat underneath

REA of Dafa's hosted card page (2026-10-12, live against the dev API) shows
Dafa's "local bank cards" (`provider:"moamalat"`) product **is the Moamalat
LightBox from this doc, double-wrapped**. There is no distinct Dafa card form.

Chain (traced with our own `dafa_test_` key):
```
POST dev.dafa.ly/api/v1/payments/initiate {provider:"moamalat"}
  → payment_page_url = https://localbankcards.dafa.ly/<payment-id>   (a Vite/React shell)
       → GET tyrian-ant.sadeem-factory.com/api/v1/payment-gateways/moamalat/<ref>/data
            → { MID, TID, AmountTrxn, TrxDateTime, SecureHash }       ← pre-signed server-side
       → window.Lightbox.Checkout.configure = {…that data…, completeCallback}; showLightbox()
            → Moamalat LightBox iframe (tnpg.moamalat.net:6006)        ← §0–§5 above
       → completeCallback → GET …/payment-gateways/moamalat/<ref>/confirm
```
Evidence: the `localbankcards.dafa.ly` CSP whitelists `frame-src …moamalat.net:6006`;
the bundle calls `window.Lightbox.Checkout.showLightbox()`; the `/data` endpoint's
`SecureHash` recomputes **byte-for-byte** with §2's HMAC. Dafa's test workspace
("منظومة دفتر") even uses Moamalat's *published sandbox* merchant
(MID `10081014649`); in prod it is the company's real Moamalat merchant, whose
secret Dafa (vendor "Sadeem") holds and signs with. Dafa adds only: holding/
signing the credential, and a `confirm` bookkeeping call.

So to render cards natively and keep the payer out of both the `dafa.ly` page and
the Moamalat iframe, two paths:

- **Option A — keep Dafa, drop both wrappers.** Dafa's `/data` endpoint returns a
  *pre-signed* Moamalat config, so Pointy can: Dafa `initiate` → fetch `/data` →
  drive §3's `LightboxHostedCheckout`+`PayByCard` natively → Dafa `/confirm`. **No
  merchant secret needed on our side** (Dafa already signed). Cost: depends on
  Dafa's private, undocumented `sadeem-factory.com` endpoints (brittle; confirm it
  is within our agreement), and takes PAN into our UI (PCI, §7).
- **Option B — go direct to Moamalat, cut Dafa from the card path.** This doc as
  written. Removes `dafa.ly` *and* Dafa for cards. Needs the company's **own**
  Moamalat merchant + secret — verify whether that exists independently or only
  via Dafa. Loses Dafa's card aggregation/settlement.

Non-card Dafa methods (Sadad, Edfali, MobiCash, Yussor/Masrafi/Sahara) are already
afa.ly-free: pure relay-side OTP, no hosted page. Only the card path leaks the
domain.

## 7. Open questions before build
- Prod API base/port (`npg.moamalat.net:6008`?) and whether prod pins TLS for the
  API host (the SPA host sends an HPKP `public-key-pins` header).
- Does our acquirer config force 3DS for NUMO, or only for Visa/MC? (Sandbox NUMO
  test card approved **without** 3DS.)
- CVV optionality for NUMO in prod.
- PCI posture sign-off on the single backend PAN hop vs. a tokenised alternative.
