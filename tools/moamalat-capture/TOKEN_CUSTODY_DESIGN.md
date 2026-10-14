# Moamalat token custody & keepalive — design note

> Status: **built 2026-10-14** (uncommitted). Code: backend
> `apps/payments/moamalat/` (custody, matching, watch, portal, cadence), relay
> `internal/moamalat/` + `internal/relay/moamalat*.go`, Flutter
> `features/card_verification/`. Companion to `API_CONTRACT.md`. Describes how a
> Pointy install holds a live Moamalat merchant token for live-counter
> verification / `CardSettlement` reconciliation (see `card-settlement-moamalat`,
> `apps/treasury`). Pointy only ever *reads* the merchant's **own** account —
> but see §Token exposure: that is a property of our code, not of the token.

## The one constraint that drives everything

Moamalat's bearer token is a **~15-min sliding session** (measured — see
`API_CONTRACT.md` §1): every authenticated request resets a ~900 s TTL; after
~15 min of silence the token is dead (`401 + {"oprationstate":"6"}`). There is
**no refresh token** and **no OTP-less re-login** — recovery costs a human OTP.
But there is **no supersession** (many tokens for one user coexist) and **no
absolute cap** (a token poked every 60 s lived 30 h+).

So: *keep it warm and it lives forever; let it lapse 15 min and a human must
re-OTP.* The whole design is about never letting it lapse, cheaply, without
centralizing the credentials.

## Who owns what

**Pointy backend (the shop's own server) owns the human loop:**
- Stores the merchant's Moamalat **username only**. **The password is never
  stored** — anywhere. OTP is mandatory on every login, so a stored password
  buys no unattended capability; it would only be a secret at rest. The
  supervisor types password + OTP together at link time.
- Renders the **login + OTP** UI in **Shop settings (supervisor-only)**. The
  admin authenticates their *own* account — Daftar never holds the credentials
  and never enters the OTP. (The shop is the actor — the legal improvement.)
- Holds the **live token**, sealed at rest (§Token storage), and runs its own
  keepalive plus the reconciliation / verification reads.
- Pushes each new token to the relay over the installation-scoped
  `X-Pointy-Relay-Token` route (`relay-onprem-scoped-auth`) — never the fleet
  token.

**Relay owns a copy of the live token, as an independent second keepalive:**
- Receives the **bearer token** (never credentials) after a successful link.
- Pokes it on a fixed cadence, **unconditionally** — not only when the backend
  goes quiet (see §Why no hand-off protocol).
- Never prompts for an OTP. Cannot recover a dead token — it flags it.

The relay exists for the gaps the shop cannot cover: the backend off overnight,
a crash or deploy, and above all **the shop's internet link to Moamalat dropping
while the LAN is fine** (common in Libya) — the cloud relay keeps its own path.

## Why no hand-off protocol

An earlier draft had the backend beacon the relay and the relay step in only
after a silence threshold ("ping-pong", `handing_off`, beacon-back). Dropped:
- It saved ~288 cheap calls per MID per day — not worth a protocol.
- The silence trigger compared the relay's clock with a timestamp the shop PC
  sent; shop clocks are often wrong, so the relay would either never step in or
  step in constantly.
- Every message in it was a new way to let the token lapse.

Instead **both holders keep the token warm independently**, each on its own
clock, each unaware of the other. Any authenticated call from either resets the
same server-side window, so two independent paths only add margin. Rule for
every time comparison in this design: **a holder compares only against its own
clock** (the relay uses the DB's `now()`, never an instance's or a shop's).

## Keepalive cadence (both holders, same rules)

Design window **W = 840 s** (14 min — the longest gap measured to survive; the
first measured death was at 900 s). Each holder tracks `last_ok`: the last time
*it* got a 2xx from Moamalat with this token.

| parameter | value | why |
|---|---|---|
| tick | **every 4 min** (± 15 s jitter per MID) | 3 ticks fit in W; jitter spreads the fleet |
| call | `GET /get-merchant/dest` | cheap, no body; any authenticated call resets the window. A real reconciliation read also counts and resets `last_ok` |
| request timeout | 15 s | a hung call must not eat the window |
| retry after a transient failure | +20 s, +60 s, +120 s, then the next tick | network errors, timeouts, 5xx, Cloudflare HTML/403, 401 *without* `oprationstate:"6"` |
| **at risk** | `now − last_ok > 8 min` | switch to a retry **every 30 s** and raise an at-risk alert (below) |
| past the window | `now − last_ok > 15 min`: retry every **2 min**, never give up | the token may still live (the other holder kept it warm); only Moamalat's answer settles it. Death is still only `401 + oprationstate:"6"` |
| 429 | honour `Retry-After`, capped so the next attempt still lands before 14 min | never let politeness kill the token |

Worst case: both holders must fail **every attempt for ~14 minutes straight**
for the token to die. At its busiest a holder makes 1 call / 30 s / MID, only
while at risk — no storms.

**Death is a 401 with `oprationstate:"6"`, and nothing else.** On that, stop
immediately — no retry, ever (`error-storm-and-crash-fixes`) — and move to
`NEEDS_REAUTH` (§State machine). A Cloudflare challenge or a bare 401 is a
transient fault, not a death.

**Alerts.** At-risk and death are raised once per condition through the relay's
alert marks (`ClaimAlert` keys `moamalat_at_risk:<installation>:<fp>` and
`moamalat_reauth:<installation>:<fp>`), so several relay instances and repeated
ticks never send the same alert twice. The backend raises the shop-side notices
(§Re-auth surface).

### Backend side

A dedicated Celery beat task at the 4-min tick — **not** "whenever
reconciliation happens to poll", whose cadence is unrelated. Verification and
reconciliation reads update `last_ok` too, so a busy till spends no extra calls.

### Relay side — exactly one poke per tick, however many instances

The relay runs more than one instance; each must not poke every MID. Each link
row carries `next_poke_at` and the work is claimed as a queue on the DB clock:

```sql
UPDATE relay_moamalat_links SET next_poke_at = now() + interval '60 seconds'  -- claim lease
WHERE id IN (SELECT id FROM relay_moamalat_links
             WHERE state = 'alive' AND next_poke_at <= now()
             ORDER BY next_poke_at LIMIT 50 FOR UPDATE SKIP LOCKED)
RETURNING id, sealed_token, fingerprint;
```

The instance that claimed a row pokes it, then writes `last_ok` and the real
`next_poke_at` (tick, retry or at-risk cadence). If that instance dies mid-poke,
the 60 s lease expires and another instance picks the row up. One owner per
poke, no leader election, no clock but Postgres's. (Same principle as the alert
marks: `INSERT … ON CONFLICT … WHERE` / `SKIP LOCKED`, never an in-memory flag.)

## Token storage

- **Relay:** sealed exactly like the company voucher stock
  (`internal/vouchers/stock_seal.go`): AES-256-GCM under its **own** key from the
  relay environment (`POINTY_RELAY_MOAMALAT_TOKEN_KEY`, `pointy-relay
  gen-moamalat-key`), key derived by HMAC with a Moamalat-specific purpose
  string, AAD = `installation_id + MID` so a sealed token moved to another row
  does not open. Emptied once the token is dead. Keep the key with the other
  relay secrets, backed up apart from the DB; losing it costs only a re-link (a
  copy the relay cannot open is dropped, and the backend hands it over again).
- **Token identity:** the backend mints a random **`token_id`** at each link and
  both holders store it beside the token. It is what every compare-and-set keys
  on. (Built instead of an HMAC fingerprint: the two holders have different
  keys, so an HMAC would not be one shared name.)
- **Backend:** `apps/core/secret_box.SecretBox` (Fernet), its own override
  setting, like the other integration credentials. Stores the token and the
  username; never a password.
- Never logged, never in telemetry, never in a diagnostics dump, never in a URL.

## Token exposure (stated honestly)

The token is an HS256 bearer with **no `exp`** — whoever holds it has the
merchant's **full** portal session for as long as it is kept warm, not a
read-only grant. The portal has an invitation system (sharing a merchant to
another user) and a merchant-settable `merchant_reference`; assume the token
can change things. "View-only" is a promise about Pointy's code. Hence: sealed
at rest on both sides, scoped per installation, and revocable only one way —
**stop every keepalive and delete every copy** (no logout endpoint is captured;
a token nobody pokes dies in 15 min).

## State machine (per linked MID)

```
UNLINKED
   │ supervisor: username + password + OTP (backend)   → token T1, fingerprint F1
   ▼
ALIVE(F1) ── both holders tick independently ──┐
   │ ◄─────────────────────────────────────────┘
   │  401 + oprationstate:6 on the CURRENT token (either holder)
   ▼
NEEDS_REAUTH(F1)
   │  supervisor re-links → T2/F2, backend pushes T2 to the relay
   ▼
ALIVE(F2)

(any state) ── shop disable / operator kill switch ──► DISABLED
               (both sides stop poking and DELETE their copy)
```

- **Every transition is compare-and-set on the `token_id`.** A shop has one
  live token at a time, but re-linking mints a new one, and a poke with the old
  token can still be in flight: the relay pushes T2, then the old T1 poke comes
  back `401` and — without the check — flips the healthy T2 link to
  `NEEDS_REAUTH`. So `NEEDS_REAUTH` is written only
  `WHERE token_id = <the token that got the 401>`, and a 401 on any other token
  is dropped (tested on both sides).
- **Death detection is shared; resolution is shop-side.** Whichever holder gets
  the 401 flips the state (the backend reads the relay's flag on its next tick
  and vice versa). Only the shop's supervisor can resolve it.
- **Re-auth replaces the token everywhere.** The backend pushes T2; the relay
  swaps its sealed copy, fingerprint and state in one write and clears the flag.
- **Kill switch reaches the relay too.** `pointy-relay integrations disable
  moamalat` must stop the relay's own poker (it reads the relay's switch table
  before each claim) and delete the sealed tokens — the shop-side
  `provider_for()` gate (`integration-kill-switch`) alone would leave the
  relay's copy warm forever. A shop-side disable/unlink also tells the relay to
  delete its copy.

## Real-time verification while a checkout is open

At rest the backend only keeps the token warm. While a till's **payment sheet is
open with a card amount**, the till posts a heartbeat (`POST /api/moamalat/watch/`)
every 5 s, and a card payment just recorded does the same for 3 minutes. Either
heats a **fast loop** on the backend: one read of the terminal's transaction
list every 5 s, matching as it goes. The till's sheet shows a quiet line under
the card tender: waiting / «وصلت عملية بطاقة بقيمة … على الجهاز …» / offline. It
never gates the confirm button.

**Wrong amounts and early swipes.** The sheet asks for *every* unclaimed swipe
since 10 minutes before it opened, whatever the amount, because cashiers often
swipe before going to the checkout. A planner (`swipe_plan.dart`) pairs swipes
with card lines by exact amount, then:

| what is left over | what the sheet does |
|---|---|
| one swipe **smaller** than the one card line still waiting | **fixes it automatically**: the card line becomes what the terminal took, and a new line holds the rest (card by default; the cashier may switch it). Banner with «تراجع»; an undone fix is offered again but never re-applied |
| a swipe **larger** than the waiting line | warns: the terminal must refund the difference; changes nothing |
| several stray swipes | offers each one («هذه عمليتي» / «ليست لهذه الفاتورة»), never guesses |
| a swipe and no card line (the sale started on cash) | offers it, likely taken before the sheet opened; using it turns the line to card, and any rest stays on its old method |
| a stray swipe beside a card line already proven | ignored: another till's business |

Nothing is recorded until the cashier confirms. After checkout, a card payment
whose only nearby swipe is for a different amount is flagged to supervisors
within ~2 minutes (`payments.moamalat_amount_mismatch`), not after 3 days.

The fast loop cannot run away against Moamalat, whatever a till does:

| guard | value | covers |
|---|---|---|
| one loop per shop | Redis key `moamalat:fast-loop`, TTL 20 s | many tills watching at once |
| heartbeat hold | 30 s | a till that crashes stops the loop within 30 s |
| hard ceiling per stretch | **10 min** from its start | a till stuck re-sending, a busy hour of card sales |
| cooldown after the ceiling | **2 min** before anything may restart it | back-to-back stretches |
| stop on failure | the first failed read ends the stretch | never fast-poll a failing server; the keepalive back-off takes over |
| till-side cap | the sheet's own poller stops at 10 min, after 3 failures, when there is no live link, and on close | belt and braces |

Worst case per shop: one read every 5 s for 10 minutes, then 2 minutes of
nothing. A read is also an authenticated call, so it doubles as the keepalive.

**What a read asks for.** `/transformerch` filters on the **processing
(settlement) date**, not the swipe date (`API_CONTRACT.md` §2). A live read asks
for processing dates from yesterday through **a week ahead** and reads the first
and last page (newest rows sit at one end). The sweep (`payments.moamalat-sweep`,
twice an hour, and after every re-link) reads every page back to the oldest
pending payment, within the portal's 30-day cap.

## Verification never blocks a sale

Real-time verification is the goal; it is never a gate a sale can fail on.

- At card payment the backend looks for the terminal transaction right away
  (`transformerch` by TID + amount + time window, or the RRN when the cashier
  enters it from the slip). Found → the payment is **verified** at the counter.
- Not found yet, Moamalat slow, token dead → the sale **completes anyway** and
  the payment is marked **pending verification**. The backend keeps retrying on
  its tick and verifies it the moment it can — including straight after a
  re-link, which sweeps every pending payment.
- Still unmatched after the settlement date has passed → it lands in the
  reconciliation exceptions for a supervisor. Money flow is unchanged: the
  payment still sits in the clearing account by the existing derived claim rule;
  verification is a flag on it, never a re-tag.

> ⚠ **Unverified premise — built on the user's assumption (2026-10-14).**
> Real-time verification assumes a fresh sale is listed in `/transformerch`
> within seconds, with a processing date inside the live window (yesterday to a
> week ahead). Neither half is confirmed; settlement shows ~T+2. **Confirm with
> one real card sale** and watch the till's live line. If rows only appear at
> batch close, or carry no processing date until then, nothing breaks: every
> payment goes through *pending verification* and the sweep matches it once it
> is listed.

### Re-auth surface (role-split)

- **Cashier:** a quiet, non-actionable POS banner — card verification is
  offline, payments will be verified later, tell a supervisor. Nothing blocked,
  never a modal over checkout.
- **Supervisor/admin:** the actionable banner, deep-linking to **Shop settings →
  Moamalat** (login + OTP + status). Shop-level integration, so not the DEVICE
  tile. The OTP goes to the merchant's registered phone — the account holder may
  need to be called.
- Explicit audiences both ways — a notice with no audience reaches nobody
  (`notification-audience-rules`).
- **Relay console** mirrors the per-shop state (alive / at risk / needs re-auth)
  for Daftar operators — visibility and nudging only; they cannot complete the
  shop-side OTP.

## Failure modes

| event | effect | handling |
|-------|--------|----------|
| backend off (shop closed overnight) | relay alone keeps it warm | no morning OTP |
| backend crash / restart / deploy | relay covers the gap | backend resumes its own tick |
| shop internet → Moamalat drops, LAN fine | backend at risk | relay warms it over its own link; backend recovers with no re-OTP |
| relay restart / deploy | backend covers the gap | tokens persisted sealed; claim queue resumes on boot; zero-downtime deploys |
| relay instance dies mid-poke | — | 60 s claim lease expires, another instance pokes |
| both paths down > ~14 min | token dies | `NEEDS_REAUTH`; sales continue as *pending verification*; supervisor re-links |
| `401 + oprationstate:6` | death | CAS to `NEEDS_REAUTH`, one alert, no retries |
| stale 401 from a replaced token | — | ignored (fingerprint mismatch) |
| 429 | throttled | `Retry-After`, capped by the window |

## Legal / operational guardrails

- **Per-merchant mandate.** Record a mandate authorizing Daftar's relay to hold
  the token and keep it warm on the merchant's behalf
  (`integrations-legal-position`).
- **Kill switch** — see the state machine; it must reach the relay.
- **Traffic shape risk.** Moamalat will see one token used from the shop's IP and
  a cloud IP, and fleet-wide many merchants' tokens poked from one datacenter
  IP. That can read as an aggregator to anomaly checks and adds to the ToS
  exposure; the 4-min cadence keeps the footprint small but not invisible.
- **Preferred long-term path.** A server-side **settlement feed from Moamalat**
  (RRN-keyed) removes the token, the keepalive and most of this document. Keep
  pursuing it; this is the fallback that works without their cooperation.

## Open questions

1. **Does a sale appear in `/transformerch` before batch close, and with what
   processing date?** Unverified; assumed yes (user, 2026-10-14). One real card
   sale settles it (see §Verification).
2. ~~HTTPS from the relay host.~~ **Resolved 2026-10-14:** from the production
   relay host, an unauthenticated
   `curl https://merchant.moamalat.net/api/get-merchant/dest` returned
   `{"oprationstate": "6"} 401` — the API itself answered with JSON; Cloudflare
   did not block or challenge the datacenter IP. Keep treating a Cloudflare HTML
   or 403 response as a transient fault (§Keepalive cadence) in case that
   changes.
3. **App vs web token window.** The ~900 s window was measured on the web
   portal token. If the backend logs in through the app's `/login-user` path,
   confirm that token slides the same way (claims differ — `API_CONTRACT.md` §6).
4. **Rate limits.** None observed; the at-risk cadence (1 call / 30 s / MID) is
   the worst case to confirm against.
5. **`out_let` scoping** (assumed). Assume the server rejects an `out_let`
   outside the user's `listOfMerchant`; regardless, the backend pins the MID
   from that account's own list and never sends an arbitrary one. Re-verify on a
   multi-MID account (`API_CONTRACT.md` §5).

Resolved: shared token (one login, two holders — no supersession makes it
safe); the backend is assumed online while the shop is open; the re-auth
surface (above).
