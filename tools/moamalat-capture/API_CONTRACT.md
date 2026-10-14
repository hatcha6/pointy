# Moamalat merchant app — API contract (capture scaffold)

> **Status: partially captured** (auth, lifetime, transactions, settlement).
> Keepalive and token handling live in `TOKEN_CUSTODY_DESIGN.md` — that file
> wins where the two differ. Same structure as
> `tools/qareeb-capture/API_CONTRACT.md`. Redact tokens, PINs,
> merchant IDs, phone numbers, and any card PANs before committing — keep the
> *shape* of each field, replace the value with `<redacted:kind>`.
>
> Goal of this integration: read our own merchant account's card transactions so
> Pointy can attribute a terminal transaction to a specific invoice and reconcile
> the `CardSettlement` (see `card-settlement-moamalat` / `apps/treasury`) against
> what Moamalat actually released, instead of only the derived claim rule.
> View-only: this driver never creates or moves anything on Moamalat's side.

## 0. Build & transport facts (fill first)

- App: Moamalat merchant app (iOS), **Flutter** (confirmed by user).
- Platform captured from: iPhone, mitmproxy WireGuard mode (Flutter ignores the
  iOS system proxy — see Qareeb note).
- Pinning / attestation: `<does its own API host pin? yes/no>` — if login only
  works under a split tunnel, record which hosts had to go direct (Firebase App
  Check = `firebaseappcheck.googleapis.com`, Apple, etc.).
- **API host(s):** `<https://...>` → `<IP>`  (note any one-e/two-e style host
  typo traps like Qareeb had; record every host the app actually talks to).
- Token scheme: `<JWT access/refresh? opaque bearer? session cookie?>`

## 1. Auth flow (the part that needs the live phone)

**Recovered from the AOT binary (v2.1.1) + one live probe, 2026-10-12.** Request
bodies are best-effort field names (Dart named params leak as `init:<field>`);
confirm the exact shapes on first live capture.

- **OTP is mandatory on EVERY login** — not a new-device gate. The binary wires
  `OtpLoginRemote` / `confirmOtpLogin` / `resendOtpLogin` / `otpSent` into the
  login path itself (not just signup). There is no OTP-less login to recover.
  → A human must enter an SMS OTP for every token. Unattended auth is impossible.
- Step 1 — `POST /login-user` body `{username, password, platform, version}`
  (optional `token` = FCM, `deviceId`) → sends OTP to the merchant phone.
- Step 2 — `POST /verify-code` body `{username, otp, platform, version}` →
  returns the bearer JWT.
- Merchant identity travels as `username` (also `outLet` in the token).
- **Token = HS256 JWT, custom claims only: `{user_id, stat, outlet, date}`.**
  No `exp`/`iat`/`nbf`. Decoded sample: `user_id` (small sequential int),
  `stat:1`, `outlet` (plaintext), `date` = issue time.
- **No refresh token. No refresh/renew endpoint exists.** Renewal = full OTP
  login again.
- **Lifetime (measured, supersedes the earlier "≤24h" guess):**
  - **No single-session invalidation.** Logging in again (fresh portal login)
    does **not** kill an existing token — the same user holds multiple live
    tokens at once. → Pointy's token survives the merchant's own app/web logins.
  - **No ~24h absolute cap.** A web token polled every 60s stayed alive past
    **30h** and counting (`token_lifetime_probe.py`, 2026-10-13/14).
  - **Death is a ~15-min SLIDING idle TTL (measured & confirmed sliding).**
    Every authenticated request resets the clock. Measured 2026-10-14: 14-min
    idle gaps survive repeatedly (token reached 56 min total alive with no gap
    >14 min — proving it's sliding, not absolute), while a 15-min gap returns
    401. So the window ≈ **900 s**. Keepalive cadence: see
    `TOKEN_CUSTODY_DESIGN.md`.
  - Dead-token signal: **HTTP 401 + `{"oprationstate":"6"}`**.
- **Integration consequence:** unattended polling is viable, but only from an
  **always-on host with a ≤~15-min keepalive heartbeat** (any authenticated call
  resets the window — a cheap `GET /get-merchant/dest` works). Fragility: **any
  gap longer than the idle window kills the token and forces a human OTP.** So
  the keepalive runs on the backend and the relay (never on a till that powers
  off), and only the shop's supervisor can re-link (the OTP goes to the
  merchant's phone). The robust production
  path remains a server-side settlement feed from Moamalat (no token to keep
  warm).
- Logout (if any): `<path>` — not yet captured.

## 2. Logged-in surface (Bearer)

**Captured live from the Nuxt web portal, 2026-10-12** (`merchant.moamalat.net`,
Cloudflare-fronted; same `/api` the mobile app uses). Transport: `$fetch`,
`Authorization: Bearer <jwt>`, JSON. Response envelope is usually
`{..., msg, oprationstate}` where `oprationstate:"1"` = OK, `"6"` = auth
fail/expired.

- `GET /get-merchant/dest` — merchant list for the account (lightweight; good
  liveness probe): `{"listOfMerchant":[{"owner":true,"english_name":"<redacted>","outlet_number":"<redacted:MID>"}],"msg":...}`
- `POST /get-pos` — terminals for a merchant: `{"listofpos":[{"POS_code":"<redacted:TID>"}],"msg":...}`
- `POST /transsumamountforchart` — dashboard daily totals: `{"listOfTrans":[{"COUNTTRN":<int>,"TRANSACTION_AMOUNT":<num>,"PROCESSING_DATE":"YYYY-MM-DD"}],...}`
- **`POST /transformerch?page=N` — the transactions list (THE one we need).**
  Body: `{"out_let":"<MID>","fromdate_proc":"YYYY-MM-DD","todate_proc":"YYYY-MM-DD","card_type":"local"}`
  plus optional `pan` (last 4) and `ref_number` (RRN). **The date range filters
  the PROCESSING (settlement) date**, not the swipe date; the app sometimes also
  sends `fromdate`/`todate`, but `_proc` sets the range. 10 rows a page;
  top-level `total` (transactions, not rows) and `pages`. An empty range answers
  `listOfTrans: []`, `total: 0`, `pages: 1`. Only `card_type:"local"` was seen.
- **`POST /transsumamountbydate?page=N` — the settlement/payout batch feed**
  (portal `/transfer` page, التحويلات). Rows grouped by settlement date +
  terminal: `{"COUNTTRN":4,"TRANSACTION_AMOUNT":445.0,"SETTLEMENT_AMOUNT":440.55,"PROCESSING_DATE":"2026-10-07","TERMINAL_ID":"<redacted:TID>"}`.
  `SETTLEMENT_AMOUNT` = gross − ~1% MDR = **what actually hit the bank** that
  date. Same `{listOfTrans,total,pages,...}` envelope. **Request body** (from the
  portal source): `{"fromdate":"YYYY-MM-DD","todate":"YYYY-MM-DD","out_let":"<MID>","page":N}`
  → accepts any date window (≤30 days), so historical batches are pullable.
  Transfer-page siblings (all keyed `fromdate`/`todate`/`out_let`[/`term_id`]):
  - `POST /transfares-visa?page=N` — per-transaction *transfer* detail (detailed toggle of the same page).
  - `GET /transsumamountbydatereportweb?fromdate=&todate=&out_let=[&term_id=]` — batch report (web).
  - `GET /exportexcelforsumamount?<same qs>` — **batch settlement Excel**.
  - `POST /transfares-visa-excel` body `{fromdate,todate,out_let[,term_id]}` — detailed-transfer Excel.
  - `GET /transfares-visa-pdf?<same qs>` — detailed-transfer PDF.
- Settlement therefore exists at **two levels** that tie together:
  per-row (`transformerch`.`ACQUIRER_SETTLEMENT_AMOUNT`) and per-batch
  (`transsumamountbydate`.`SETTLEMENT_AMOUNT`). Sum of a day+terminal's per-row
  nets == that batch's `SETTLEMENT_AMOUNT` == the bank deposit.
- Export (Excel) — **`GET /exportexcelfortransmerchant?fromdate_proc=YYYY-MM-DD&todate_proc=YYYY-MM-DD&out_let=<MID>`**.
  Returns a real `.xlsx` (zip, `50 4b` magic) as a download, filtered by
  **settlement/posting date** (`_proc`), no pagination. 7 columns:
  رقم الآلة (TID) · رقم البطاقة (masked PAN) · تاريخ الحركة (sale datetime) ·
  قيمة الحركة (gross) · القيمة بعد الخصم (net after MDR) · رقم العملية (RRN) ·
  تاريخ الترحيل (settlement date). **Thinner than the JSON** — drops
  `chip_index`, `merchant_reference`, `action`, `transaction_type`. Date range
  capped at 30 days. Good for a bulk settlement dump; use `transformerch` JSON
  when you need type/refund flag or to read/write `merchant_reference`.
- Export (PDF): `/report_…` / `transfares-visa-pdf` family (not yet captured).

## 3. The transaction object — reconciliation keys (MOST IMPORTANT)

**Captured.** One real `/transformerch` row, values redacted to `<redacted:kind>`
but shape/type preserved:

```json
{
  "TERMINAL_ID": "<redacted:TID>",                 // e.g. "0JNSWZ11"
  "chip_index": "<redacted:emv>    ",              // opaque EMV token, space-padded
  "CARD_NUMBER": "<redacted:maskedPAN>",           // already masked: 63997*****4558
  "TRANSACTION_DATE": "2026-10-01 18:50:02",       // sale time (local, no tz)
  "TRANSACTION_AMOUNT": 25.0,                       // gross
  "REFERENCE_NUMBER": "<redacted:RRN>",            // 12 digits, e.g. 627416000329
  "PROCESSING_DATE": "2026-10-05",                  // settlement/release date
  "ACQUIRER_SETTLEMENT_AMOUNT": 24.75,             // net after MDR (~1%)
  "merchant_reference": null,                       // merchant-settable, always null here
  "action": 1,
  "transaction_type": "Sale"                        // Sale | Refund
}
```
Envelope: `{"listOfTrans":[...],"total":8,"pages":1,"msg":"...","oprationstate":"1"}`.

| field | use |
|-------|-----|
| `TRANSACTION_AMOUNT` | match (exact, gross) |
| currency | implicit LYD (no field) — guard by account |
| `TRANSACTION_DATE` | match (± window); **local time, no tz** — watch DST/offset |
| `REFERENCE_NUMBER` (RRN) | **strong unique match key — present, 12 digits** |
| `chip_index` | secondary unique token (EMV); trim trailing spaces |
| `TERMINAL_ID` (TID) | which physical terminal (ties to `POS_code`) |
| MID | per-account (`outlet_number` / token `outlet`), not on the row |
| status | `transaction_type` (Sale/Refund) + `action`; no declined rows seen |
| `CARD_NUMBER` | display only (pre-masked) |
| `ACQUIRER_SETTLEMENT_AMOUNT` + `PROCESSING_DATE` | **the settlement figures — reconcile CardSettlement directly** |

**Answers the key question:** yes — `REFERENCE_NUMBER` (RRN) is a stable unique
id the terminal prints on the merchant slip → **exact matching is possible.**
Even better, **`merchant_reference` is a nullable, merchant-settable field**: if
the POS/terminal integration can stamp Pointy's invoice number into it at
transaction time, the join becomes trivial and exact. Fallback remains
amount + time-window + TID. MDR is ~1% (25.00→24.75, 70.00→69.30), so reconcile
against `ACQUIRER_SETTLEMENT_AMOUNT`, not the gross.

## 4. Polling model (no webhook expected)

- Poll `POST /transformerch?page=N` with a `movement date from/to` (or settlement
  date) filter in the body to get transactions in a window. Date range is capped
  at **30 days** per request (app string: "Date range exceeded 30 days").
- Freshness: rows carry `TRANSACTION_DATE` (sale time) and `PROCESSING_DATE`
  (settlement). Not yet confirmed whether a sale appears before batch close — do
  one real card sale and watch. The dashboard examples show `PROCESSING_DATE`
  lagging `TRANSACTION_DATE` by ~2 days, so settlement figures are **T+2-ish**.
- Auth: one OTP seeds a token that lives as long as it is kept warm (§1,
  `TOKEN_CUSTODY_DESIGN.md`). A server-side settlement feed keyed by RRN remains
  the preferred production path.
- Rate limits / 429s under tight polling: not observed yet.

## 5. Merchant (MID) selection — for "one Pointy install → one MID"

A logged-in user may have several MIDs. Switching between them is **client-side
only** — pick a MID and pass it as `out_let` per request. There is **no switch
endpoint, no token re-issue, no OTP** to change MID.

- `GET /get-merchant/dest` → `{"listOfMerchant":[{"owner":true|false,"english_name":"<name>","outlet_number":"<MID>"}]}`
  — the full set of MIDs this login can act on. (`owner` flags merchants the
  user owns vs. ones shared to them via the invitation system.)
- Every data call takes the chosen MID: body field `out_let` (POST:
  `transformerch`, `transsumamountbydate`, `get-pos`, `transfares-visa-excel`) or
  query `out_let=` (GET exports). The web portal defaults to `listOfMerchant[0]`.
- The bearer token's `outlet` claim is just the default/primary MID; it does
  **not** restrict which `out_let` a request may pass — one token reads any MID
  in its list. (Whether the server *rejects* an `out_let` outside that list is
  assumed, not observed — see below.)

**Pointy build:** at setup, call `get-merchant/dest`, show `english_name` +
`outlet_number`, store the chosen `outlet_number` as the installation's MID, and
send it as `out_let` on every reconciliation query. No per-switch auth cost.
(Assumed yes: the server rejects an `out_let` outside the user's
`listOfMerchant` — expected but not observable on a single-MID account.
Regardless, the backend should pin the configured MID from that account's own
`listOfMerchant` rather than relying on the server to reject a stray value, so
it stays correct either way. Re-verify when a multi-MID account is available.)

## 6. Auth claim shapes (two clients differ)

- **Web bearer** claims: `{user_id, user_name, outlet(=MID), stat, idsissen(issue), firstlog}`.
- **App bearer** claims: `{user_id, stat, outlet(=username), date(issue)}`.
- Both HS256, both **no `exp`**. Issue-time claim name differs (`idsissen` web /
  `date` app) — the probe handles both.
- Static `publickey:"BecomITPementKey"` sent on login (vendor = "BecomIT",
  matches the leaked Django dev path). Not a per-user secret.
