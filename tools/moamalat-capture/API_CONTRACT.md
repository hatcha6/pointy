# Moamalat merchant app — API contract (capture scaffold)

> **Status: UNCAPTURED.** This is a scaffold to fill *during* capture. Same
> structure as `tools/qareeb-capture/API_CONTRACT.md`. Redact tokens, PINs,
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

Record each request → response, in order, for a **fresh login**:

- Login request: `POST <path>` body `{ ... }` → response `{ ... }`.
- Is there a new-device / OTP gate? If so, capture the full exchange (step1,
  captcha if any, verify, token exchange) — Qareeb's OTP was a two-step
  `verify_otp` → `login_with_otp` that the first driver got wrong, so capture the
  *successful* code path end to end, not just a failure.
- What identifies the merchant? `<merchant ID? phone? username?>` — note which
  field it travels in.
- Token refresh: `POST <path>` `{ ... }` → `{ ... }`. TTLs if visible.
- Logout (if any): `POST <path>`.

## 2. Logged-in surface (Bearer)

List every endpoint the app hits once logged in, with method + a redacted
sample response. Mark which one is the **transactions list** and which is
**account / merchant info (balance)**.

- `GET <path>` — account/merchant info: `{ ... }`
- `GET <path>` — transactions list: `{ ... }`
- `GET <path>` — transaction detail (if a row expands): `{ ... }`
- Pagination shape (cursor? page/limit? date range params?): `<...>`
- Any settlement / batch endpoint (daily release): `<path or "none seen">`

## 3. The transaction object — reconciliation keys (MOST IMPORTANT)

For one real transaction, record every field and flag which we can match on.
Pointy needs to join a Moamalat row to a Pointy invoice. Candidates:

| field | sample (redacted) | use |
|-------|-------------------|-----|
| amount | `<...>` | match (exact) |
| currency | `<...>` | guard (expect LYD) |
| timestamp / `paid_at` | `<...>` | match (± window); note the timezone |
| STAN / RRN / auth code | `<...>` | **strong unique match key if present** |
| terminal ID (TID) | `<...>` | which physical terminal |
| merchant ID (MID) | `<...>` | which account |
| status (approved/declined/reversed/settled) | `<...>` | only count approved |
| masked PAN / card scheme | `<...>` | display only |
| settlement/batch ref | `<...>` | ties row → released batch |

The key question for the build: **is there a stable unique id per transaction
(RRN/STAN/auth code) the terminal also prints on the merchant slip?** If yes,
matching is exact. If not, we fall back to amount + time window + TID and accept
occasional ambiguity (the till already knows which invoice it just closed on
card, so we match forward from that).

## 4. Polling model (no webhook expected)

- Which endpoint + params would we poll to get "new transactions since X"?
  `<path + date/cursor param>`
- How fresh is it — does a terminal transaction show up within seconds, or only
  after batch close? `<observe by doing one real card sale and watching>`
- Rate limits / anything that 429s on tight polling: `<...>`
