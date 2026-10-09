# كروت دفتر: the company's own voucher shop

Status: **groundwork built** (2026-10-07): relay, shop backend and till, verified end to end against a real relay in test mode. Not yet run against the live BN Plus API (needs the merchant password).

Shops sell **our** prepaid cards — local (Libyana, Almadar, …) and international
(iTunes, PlayStation, Google Play, …) — out of a **voucher balance** they fill on
the relay. The company buys each card from a wholesaler with **its own** account
(BN Plus first; Reloadly / DingConnect later) the moment the shop's invoice is
paid. The catalog — what is sold, our categories, the order on the till, the
logos, the promotions — is ours, not the wholesaler's.

Unlike Qareeb / HD Box / LNET, the shop holds **no provider credential**. The
company's BN Plus e-mail, password and token live only in relay env, like the
Resala and Dafa keys. The shop's backend talks to the relay with its installation
token.

```text
Operator: catalog.json + logos ─ pointy-relay vouchers catalog push ─┐
                                                                      ▼
Till ─► on-prem Django ─(5 min, ETag)─► relay GET /v1/vouchers/catalog
         │  mirrors brands/items into system products («كروت دفتر» chip)
         │
Sale paid ─► POST /api/integrations/fulfillments/charge/
         ─► relay POST /v1/vouchers/purchases {item, idempotency_key, max_unit_price}
                 hold unit price from the shop's VOUCHER balance (one step with the claim)
                 ─► BN Plus POST /api/merchant/buy-card {card_id, quantity}
                 ◄─ codes   → purchase succeeded (charge kept)
                 ◄─ refused → purchase failed, refunded
                 ◄─ unknown → held; the relay's reconciler reads BN Plus back
         ◄─ {purchase: {status, codes}, balance}
Receipt prints the code (slip at the top, brand print-logo + Daftar mark, QR).
```

## Decisions (and why)

| Decision | Why |
| --- | --- |
| Provider key **`pointy`**, shown as «كروت دفتر» | Code names stay `pointy` (see branding). The company is the provider. `pointy-relay integrations disable pointy` stops selling fleet-wide through the existing kill switch. |
| Voucher balance is its own wallet account, `vouchers` («رصيد الكروت») | Same ledger as main/SMS: one locked balance row, signed entries, idempotent postings. |
| It is filled by a **transfer from the main wallet**, exactly like the SMS balance (owner's call, 2026-10-07) | One way to put money in (the main wallet's Dafa top-up); the owner then splits it across SMS and cards. |
| **The wallet is an asset in the shop's books** (owner's call, 2026-10-07) | A paid top-up is a transfer bank → «محفظة دفتر» (a treasury balance), not an expense. SMS and plan purchases become expenses («خدمات دفتر») paid from that balance when bought. Money moved to cards is a transfer «محفظة دفتر» → the «كروت دفتر» float, and each card sold records its real cost and draws the float. Every figure is exact, per-card profit included. Top-ups already booked as expenses stay; their unspent part is "pre-booked" and is consumed first by SMS/plan spending without a second expense. |
| Shop's cost = our `unit_price`; customer price = our `retail_price` | Both set by us, per item. Prices carry **at most 2 decimals** so they match the shop's books (fulfillment cost, unit cost and top-ups keep 2). |
| Promotion = a time-boxed `unit_price` and/or `retail_price` plus a badge | "This one has a discount, sell it to profit more": a lower shop cost raises the shop's margin; a lower retail price is a customer-facing deal. Cashiers see the badge, never our cost. |
| Our own categories and order | Category `sort`, brand `featured` + `sort`, item `sort`. The relay computes one `rank` per level; the shop orders by it. BN Plus groups are never shown. |
| Countries on items (ISO 3166 alpha-2, plus `WW` worldwide and `EU`) | iTunes US ≠ iTunes UK. The relay owns the Arabic names; flags are operator-uploaded images (emoji flags do not render on Windows tills). |
| Every selected detail is in the line name | Brand = product name; item = variant name `«<country> · <denomination>»` (e.g. «الولايات المتحدة · 10 دولار»). The cart, receipt and invoice print product + variant, so nothing is lost. |
| Two logos per brand | `display` = card art (16:10, colour) for the till; `print` = monochrome for thermal slips. Content-addressed (`sha256:<hex>`): a new logo is a new path, so every cache refreshes at once. |
| Bought right after checkout | Same draft-invoice flow as Qareeb: the card is a cart line in the draft invoice and is bought only when the invoice is issued — a standard sale once fully paid, or a **credit (آجل) sale** (owner's call: selling on credit is the shop's business; the company is paid from the voucher balance either way). |
| The relay stores **no codes** | Codes come back in the purchase answer; a replay or late resolution re-reads them from the supplier (BN Plus keeps every order's codes). The shop's backend keeps them, as for Qareeb. |
| Suppliers are pluggable | Each catalog item names `supplier.key` (`bnplus`; `test` in test mode). Reloadly / DingConnect become new supplier adapters; nothing else changes. |

## Relay

### Configuration

| Variable | Default | Meaning |
| --- | --- | --- |
| `POINTY_RELAY_BNPLUS_BASE_URL` | `https://portal.bn-plusli.ly` | API root `/api/merchant` is appended |
| `POINTY_RELAY_BNPLUS_EMAIL` / `_PASSWORD` / `_TOKEN` | empty | the company's merchant credentials (Api-Email, Api-Password, Bearer). All three or none: a partial set leaves BN Plus off with a startup warning |
| `POINTY_RELAY_BNPLUS_REQUEST_TIMEOUT` | `45s` | one BN Plus call (a purchase fetches codes from BN Plus's own suppliers) |
| `POINTY_RELAY_VOUCHERS_TEST_MODE` | `false` | every purchase goes to the built-in test supplier: deterministic fake codes `TEST-…`, the balance is still charged (entries marked test) |
| `POINTY_RELAY_VOUCHERS_SYNC_INTERVAL` | `30m` | how often supplier offers (price, stock) are read; `0` off |
| `POINTY_RELAY_VOUCHERS_RATE_LIMIT` | `30/minute` | purchases per shop |

Vouchers are **configured** when BN Plus is configured or test mode is on.

### Shop API (installation token, identity only)

`GET /v1/vouchers/catalog` — `ETag: "<version>"`, `If-None-Match` → `304`.

```json
{
  "version": "3f2a…16 hex",
  "currency": "LYD",
  "test_mode": false,
  "generated_at": "2026-10-07T12:00:00Z",
  "categories": [{"key": "gift_cards", "name": "بطاقات الهدايا", "rank": 0}],
  "countries": [{"code": "US", "name": "الولايات المتحدة", "flag": "sha256:<64 hex>"}],
  "brands": [{
    "key": "itunes", "name": "آيتونز", "aliases": ["iTunes", "Apple"],
    "category": "gift_cards", "rank": 0, "featured": true, "badge": "الأكثر مبيعاً",
    "redeem_hint": "App Store ← الحساب ← استرداد بطاقة هدية",
    "logo": "sha256:<hex>", "print_logo": "sha256:<hex>",
    "items": [{
      "key": "itunes-us-10", "country": "US", "label": "10 دولار",
      "face_value": "10", "face_currency": "USD",
      "unit_price": "50.00", "retail_price": "60.00",
      "regular_unit_price": "52.00", "regular_retail_price": "60.00",
      "promo": {"badge": "عرض", "ends_at": "2026-10-20T00:00:00Z"},
      "available": true, "rank": 0
    }]
  }]
}
```

* Only **active** categories / brands / items are listed: what disappears is withdrawn.
* `available: false` = listed but not sellable right now (supplier out of stock,
  supplier cost above the item's `max_cost`, supplier not configured).
* `flag`, `logo`, `print_logo` may be `""`. `promo` is `null` when none is running.
* `version` changes when the catalog, a promotion window or an availability changes.

`GET /v1/vouchers/images/<sha256 hex>` — the image bytes (`Content-Type` as
uploaded, `Cache-Control: private, max-age=31536000, immutable`); `404` unknown.

`POST /v1/vouchers/purchases`

```json
{"item": "itunes-us-10", "quantity": 1, "idempotency_key": "≤100 chars",
 "max_unit_price": "52.00", "requested_by": "cashier name"}
```

| Status | Body | Meaning |
| --- | --- | --- |
| `201` / `200` replay | `{"purchase": P, "balance": "…", "replayed": bool}` | `P.status = succeeded`, codes in `P.codes` |
| `202` | same | `P.status = pending`: the outcome is not known yet; the price stays held. Poll `GET`. |
| `402` | `{"code": "insufficient_balance", "balance", "amount"}` | nothing held |
| `404` | `{"code": "unknown_item"}` | |
| `409` | `{"code": "item_unavailable"}` / `{"code": "price_changed", "unit_price"}` / `{"code": "in_flight"}` (Retry-After) | nothing held |
| `422` | `{"code": "invalid_quantity" \| "invalid_request"}` | |
| `429` | `{"code": "rate_limited"}` | |
| `502` | `{"code": "supplier_out_of_stock" \| "supplier_refused" \| "supplier_unavailable", "purchase": P}` | `P.status = failed`, refunded |
| `503` | `{"code": "vouchers_unconfigured"}` | |

`max_unit_price` is the shop's cost at checkout. The relay charges its current
price when that is not higher; when it is higher it refuses `price_changed` —
except within 30 minutes after a promotion ended, when it honours the
promotion's price the shop saw.

`P`:

```json
{"id": "uuid", "idempotency_key": "…", "item": "itunes-us-10", "brand": "itunes",
 "name": "آيتونز · الولايات المتحدة · 10 دولار", "quantity": 1,
 "unit_price": "50.00", "amount": "50.00",
 "status": "pending|succeeded|failed", "held": false,
 "error_code": "", "error_detail": "",
 "codes": [{"code": "…", "serial": "…"}], "codes_pending": false,
 "test_mode": false, "created_at": "…", "completed_at": "…"}
```

`codes_pending: true` = the purchase succeeded but the codes could not be read
back right now (a replay while BN Plus is unreachable); ask again.

`GET /v1/vouchers/purchases/<idempotency key>` → `{"purchase": P, "balance": "…"}` or `404`.

### Wallet changes

* `GET /v1/wallet` adds `"vouchers": {"balance": "…", "configured": bool, "test_mode": bool}`.
* `POST /v1/wallet/vouchers/allocations` `{amount, idempotency_key, requested_by}` —
  the owner moves money from the main wallet into the voucher balance, exactly
  like `/v1/wallet/sms/allocations`: `201 {balance, vouchers, transfer: {out, in},
  replayed}` (`200` on replay); `409 insufficient_balance {balance, amount}`,
  `422 invalid_amount`, `503 vouchers_unconfigured`. One-way, like SMS.
* `GET /v1/wallet/entries?account=vouchers` — the voucher statement.

### Ledger

* `relay_voucher_purchases` (one row per purchase, unique per shop + key) with
  the charge `voucher:<id>` and refund `voucher-refund:<id>` on the `vouchers`
  account. A failure that may still have bought the card is **held**
  (`held_since`): the reconciler reads it back (order status when BN Plus named
  the order, else the order history matched by card, quantity and time, each
  BN Plus order claimed once) and settles it — found: succeeded; absent after
  15 minutes: refunded; unreadable for 48 h: left held with an ERROR for the
  operator (`vouchers resolve`).
* `relay_voucher_catalogs` (every pushed document; the newest is current),
  `relay_voucher_images` (content-addressed), `relay_voucher_offers` (supplier
  price/stock by card).

### Operator CLI

```sh
pointy-relay vouchers catalog example > catalog.json   # a starter document
pointy-relay vouchers catalog check catalog.json        # validate locally
pointy-relay vouchers catalog push catalog.json --note 'October promos'
pointy-relay vouchers catalog show                      # what shops get now
pointy-relay vouchers offers --sync                     # BN Plus price/stock per card
pointy-relay vouchers bnplus wallets|groups|companies|cards --branch N|orders|order <id>
pointy-relay vouchers purchases --status pending
pointy-relay vouchers check <purchase-id>
pointy-relay vouchers resolve <purchase-id> --refund|--found <bnplus order id> --reason '…'
pointy-relay wallet show <installation-id> --account vouchers
```

The catalog document (images by path, relative to the file; the CLI uploads them):

```json
{
  "categories": [{"key": "gift_cards", "name": "بطاقات الهدايا", "sort": 10}],
  "countries": [{"code": "US", "flag": "flags/us.png"}],
  "brands": [{
    "key": "itunes", "name": "آيتونز", "aliases": ["iTunes"], "category": "gift_cards",
    "sort": 10, "featured": true, "badge": "الأكثر مبيعاً", "redeem_hint": "…",
    "logo": {"display": "logos/itunes.png", "print": "logos/itunes-print.png"},
    "items": [{
      "key": "itunes-us-10", "country": "US", "face_value": "10", "face_currency": "USD",
      "price": "52.00", "retail_price": "60.00", "sort": 10,
      "promo": {"price": "50.00", "badge": "عرض", "starts_at": "2026-10-10T00:00:00+02:00", "ends_at": "2026-10-20T00:00:00+02:00"},
      "supplier": {"key": "bnplus", "card_id": 123, "max_cost": "10.30"}
    }]
  }]
}
```

`label` defaults to the face value in Arabic ("10 دولار"); `active: false` hides
anything. Brand keys `libyana` and `almadar` get the verified dial strings on the
receipt (`redeem.DIAL_FORMATS`).

## Shop backend (Django)

* Provider spec `pointy`: capabilities balance + vouchers, **no fields**, low-balance
  setting (default 50). Enabling = `PUT /api/integrations/pointy/` with `{}`.
  `receipt_logos/pointy.png` (Daftar mark, thermal).
* Driver `providers/pointy.py` over the relay (installation token):
  `probe` → voucher balance; `voucher_catalog` → the catalog (ETag kept in
  `account.config`); `voucher_logo("sha256:…")` → image bytes;
  `recharge("", item_key, expected_cost=…, attempt_key=…)` → purchase;
  `attempt_outcome(attempt_key)` → read a purchase back.
  Relay credentials are read on the calling thread and pinned for `in_parallel` workers.
* `recharge.charge` passes `attempt_key = "<fulfillment pk>-<created_at %Y%m%d%H%M%S%f>-<attempt_count>"`
  (other drivers ignore it); `RechargeResult.actual_cost` lets `_record` correct
  the fulfillment cost and the line's `unit_cost` to what was really charged.
* SUBMITTED `pointy` rows are settled every 2 minutes (and by the nightly
  reconciliation) through `attempt_outcome`, never by history matching:
  succeeded → CONFIRMED with the code; failed → PENDING (unperformed); unknown to
  the relay after 2 minutes → PENDING; pending → stays.
* Mirror: `IntegrationVoucherBrand` + `rank`, `featured`, `badge`,
  `category_key`, `category_name`, `category_rank`, `redeem_hint`;
  `IntegrationVoucher` + `country`, `face_currency`, `rank`, `badge`,
  `promo_ends_at`, `regular_price`; new `IntegrationVoucherCountry` (code, name,
  rank, flag PNG). SKU prefix `DFT`. Variant name `«<country> · <label>»`.
  Sync every 5 minutes (one ETag'd call; `304` writes nothing).
* Quick-access chip «كروت دفتر» (`system_key = vouchers:pointy`), made by the
  existing `shelf_category`. The category serializer now exposes `system_key`.
* `GET /api/integrations/vouchers/menu/` (`integrations.use_integrations`) — the till's menu:

```json
{
  "available": true, "provider": "pointy", "error_code": "",
  "balance": "123.45", "balance_at": "…",
  "categories": [{"key": "gift_cards", "name": "بطاقات الهدايا"}],
  "countries": [{"code": "US", "name": "الولايات المتحدة", "flag": "<base64 PNG or null>"}],
  "brands": [{
    "key": "itunes", "name": "آيتونز", "category": "gift_cards",
    "featured": true, "badge": "الأكثر مبيعاً", "has_promo": true, "redeem_hint": "…",
    "product": {"…": "the same product JSON GET /api/products/?system=sellable returns, with variants and primary_image"},
    "items": [{
      "variant_id": 101, "key": "itunes-us-10", "label": "10 دولار", "name": "الولايات المتحدة · 10 دولار",
      "country": "US", "face_value": "10", "face_currency": "USD",
      "price": "60.00", "regular_price": "60.00", "badge": "عرض", "promo_ends_at": "…",
      "available": true, "exceeds_float": false,
      "cost": "50.00"
    }]
  }]
}
```

  `cost` only for readers with full visibility (`user_has_full_visibility`). Brands
  and items arrive in display order.
* Wallet: `POST /api/wallet/vouchers/allocations/` (mirrors the SMS allocation);
  `GET /api/wallet/` adds `vouchers` (`balance`, `configured`, `test_mode`,
  `enabled`); `GET /api/wallet/entries/?account=vouchers`.
* Books (wallet as an asset): treasury account «محفظة دفتر» (kind provider);
  paid top-up → `MoneyTransfer` bank (or outside) → wallet; SMS allocation and
  plan purchase → `Expense` (transfer, `money_account` = wallet); voucher
  allocation → `MoneyTransfer` wallet → «كروت دفتر» float. The treasury subtracts
  expenses tagged with a provider account from that account.

## Till (Flutter)

* Selecting the «كروت دفتر» chip shows the **voucher menu** in place of the
  product grid: our category tabs, then gift-card styled brand cards (display
  logo full-bleed 16:10, name, price range, promo/featured badge, country flags).
* Tapping a brand opens its sheet: country chips with flags (when the brand has
  more than one country), then denomination tiles (face value, price, promo
  badge, struck-through regular price; the shop's profit only for owners, and
  only once cost is revealed with F9, like the cart's margin). Picking one adds
  the variant; the line reads «آيتونز - الولايات المتحدة · 10 دولار».
* Wallet: «رصيد الكروت» card with «تحويل إلى رصيد الكروت» (a sheet like the SMS
  allocation) and its statement tab.
* Integrations: «كروت دفتر» card (enable / disable, balance, low-balance setting).

## Operator: going live

1. Put the company's BN Plus e-mail, password and token in the relay's env
   (`POINTY_RELAY_BNPLUS_*`; locally `relay/.env`, never a tracked file).
2. `pointy-relay vouchers bnplus wallets` (proves the credentials and shows the
   dinar/dollar balances), `… companies`, `… cards --branch N` to find each
   card's `card_id` and cost; `vouchers offers --sync`.
3. Write `catalog.json` (start from `vouchers catalog example`) with two logos
   per brand (display: 16:10 card art, e.g. 640×400 PNG; print: monochrome PNG)
   and a flag per region; `vouchers catalog check`, then `vouchers catalog push`.
   The company's own is generated, not hand-written, in the operator workspace
   `ops/catalog/` (not in git; see its `README.md`): every BN Plus company with stock is a brand
   there (card names read by `tools/card_names.py`), every country the relay accepts has a flag,
   and `tools/build_catalog.py` writes the document from BN Plus's own card list.
4. Shops: Shop Settings → Integrations → «كروت دفتر» on; move money into
   «رصيد الكروت» from the wallet; the chip appears on the till once a card is live.

## Later

* Reloadly / DingConnect supplier adapters (OAuth gift-card API; Ding
  `SendTransfer` with `DistributorRef`). Note from the 2026-09-29 research:
  Reloadly's terms list Libya as a jurisdiction it will not open accounts for,
  and Ding has no Libya coverage — the account likely has to be held abroad.
* An admin page for the catalog (today: the JSON + CLI).
* A margin report (`vouchers usage`): charged vs supplier cost per currency.

## Part 2 pointer

Reloadly as a second card supplier, direct top-up and bill payments: see `DIRECT_TOPUP_PLAN.md`.
