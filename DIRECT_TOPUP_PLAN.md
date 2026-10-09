# كروت دفتر, part 2: Reloadly, direct top-up and bill payments

Status: **design + build in progress** (2026-10-08). Extends `VOUCHER_SHOP_PLAN.md`; read that first.
Owner's calls (2026-10-08):

1. **Reloadly is a second card supplier** next to BN Plus. For an item both can sell, the relay buys from the
   cheaper one at purchase time, in dinars. Libyan products stay BN Plus only (Reloadly has none).
2. **Direct top-up** ("airtime": credit sent straight to a phone number abroad, no card) and **bill payments**
   (electricity / water / TV, as far as Reloadly offers them) are sold from the same company shelf, as **two
   sub-categories (tabs) inside the «كروت دفتر» menu**, next to the card categories. They are NOT part of the
   HD Box / LNET recharge screen and do not touch it.
3. The UX must teach a concept that is new in Libya: very clear, very fast, everything visible on one screen.
   The cashier can type a country code if they know it, or pick from a searchable list of countries (with flags).
4. Pricing (our margin, the shop's room to earn) is decided AFTER this is built. Every number is a relay setting
   with a clearly marked demo default; nothing is hard-coded.

Names: the code calls them **`airtime`** and **`bill`** (the word "top-up" already means wallet/float top-ups in
the code base: `IntegrationOffer.isTopUp`, `recordIntegrationTopUp`, `walletTopUp*`). Arabic UI: «الشحن المباشر»
and «دفع الفواتير».

## 1. Money

Reloadly account: one, in USD, held by the company (its terms bar Libya-based accounts, so it is held abroad).

```
cost_lyd      = cost_usd * usd_rate * (1 + funding_percent/100)      # what the company really pays, in dinars
shop price    = round_up_2dp( cost_lyd * (1 + shop_markup_percent/100) )          # `unit_price`: charged to the shop's voucher balance
retail price  = round_up_to_step( cost_lyd * (1 + retail_markup_percent/100), retail_step )   # `retail_price`: suggested to the customer
              (never below shop price + min_shop_margin; never above 2 decimals)
```

* `cost_usd` comes from Reloadly's own numbers (`internal/reloadly/cost.go`, formulas VERIFIED against the sandbox in
  `internal/reloadly/doc.go`), for the amount and currency the order is placed in (see the order currency below).
* Settings live in the relay (`pointy-relay vouchers settings show|set`, append-only history like catalogs):
  `usd_rate` (dinars per dollar, the company's real cost of a dollar, e.g. `9.71`), `funding_percent` (default `0`: the
  card/bank/crypto fee of filling the Reloadly account), `airtime` and `bills` blocks `{shop_markup_percent,
  retail_markup_percent}`, `retail_step` (default `0.25`), `min_shop_margin` (default `0.10` dinars), `popular`
  (ordered country codes). **No `usd_rate` = Reloadly cannot be priced: every Reloadly offer/service is unavailable
  with reason `rate_unset`** (never priced by guess).
* Demo defaults (NOT decisions, flagged in every doc and CLI output): shop 2 %, retail 5.5 %, step 0.25 — the same
  as the card knobs in `ops/catalog/tools/catalog_config.py`.
* **In which currency Reloadly is ordered (built; the owner confirms the defaults in the pricing talk).** Reloadly pays
  its commission (`internationalDiscount`, about 5 % on a typical operator) on an order placed in US dollars and forfeits
  it on one placed in the recipient's own currency (`useLocalAmount`): Orange Mali 4 dollars cost 3.80, 2,000 CFA francs
  cost exactly their dollar value. The customer always picks a **local** amount (tiles stay «5,000 فرنك أفريقي»); what the
  company orders is its setting (`vouchers.Settings`, flags `--airtime-order-mode`, `--airtime-usd-buffer`,
  `--bills-order-mode`, `--bills-usd-buffer`; every one a demo default until decided):
  * `airtime.order_mode` = **`usd`** (default): the order goes out in dollars, `S = round UP (5 decimals) of
    L / fx.rate x (1 + usd_buffer_percent/100)` with `useLocalAmount=false`; cost = `AirtimeCost(op, S, false)`. The recipient
    receives at least `L` (the buffer, default `0.5`, absorbs a rate that moved a hair; the receipt carries the amount
    **actually delivered**, and a delivery under `L` is logged and counted, never refused). A FIXED operator orders the
    aligned dollar plan (`fixedAmounts[i]` for `localFixedAmounts[i]`). An amount whose dollar order falls outside the
    operator's dollar limits is ordered locally, not refused. Operators that take no local amounts (dollar tiles) are
    unchanged (`approximate: true`). `quote.receive` is `L` and is **not** marked approximate in either mode.
  * `airtime.order_mode` = `local`: the exact local amount, no commission (cost = `AirtimeCost(op, L, true)`).
  * `bills.order_mode` = **`auto`** (default): dollars (same `S`) only for a **prepaid RANGE biller without an invoice** that
    takes dollars, and only when that order costs less than the exact one; everything that must be exact stays local:
    invoice billers (an invoice is paid to the unit), FIXED plans (Reloadly's dollar plan prices are unrelated to its rate;
    ask Reloadly which the live API wants before ever paying a plan in dollars: Canal+ Mali would save 18 %), postponed
    bills. `local` forces local everywhere. Billers that take no local amounts are dollars as asked.
  * The order currency and amount are in the ledger `details` (`order_mode`, `order_currency`, `order_amount`,
    `buffer_percent`) and in the receipt (`order_amount`, `order_currency`), so a statement is auditable. The wire
    contract to the shop does not change.
* All dinar values on the wire are strings with at most two decimals; foreign amounts are plain decimal strings.

## 2. Relay (Go)

### 2.1 Configuration (all optional; services are configured when Reloadly is configured or test mode is on)

| Variable | Meaning |
| --- | --- |
| `POINTY_RELAY_RELOADLY_CLIENT_ID` / `_CLIENT_SECRET` | the company's API pair (both or none) |
| `POINTY_RELAY_RELOADLY_SANDBOX` | `true` = `*-sandbox.reloadly.com` (fake money). Default `false` |
| `POINTY_RELAY_RELOADLY_REQUEST_TIMEOUT` | one Reloadly call, default `45s` |
| `POINTY_RELAY_RELOADLY_DIRECTORY_INTERVAL` | how often countries/operators/billers are re-read, default `15m` (`0` = once) |
| `POINTY_RELAY_SERVICES_SETTLE_WAIT` | how long a bill Reloadly accepted is waited for (polling its status) before the order is left held for the reconciler, default `20s` |

`POINTY_RELAY_VOUCHERS_TEST_MODE=true`: every card/airtime/bill purchase goes to a built-in fake (deterministic
`TEST-…` codes / fake transaction ids, balance still charged, entries marked test). The services directory then comes
from Reloadly when configured, else from an embedded fixture (`internal/services/fixture/`), so the shop backend and the
till can be developed offline.

### 2.2 Cards: several suppliers per item (built)

Catalog item (`supplier` stays valid and means a one-element list; exactly one of the two; `suppliers` takes 1-4 entries,
one per supplier key, in the order that breaks price ties):

```json
"suppliers": [
  {"key": "bnplus",   "card_id": 123, "max_cost": "520.00"},
  {"key": "reloadly", "product_id": 13441, "amount": "50", "max_cost": "515.00"}
]
```

* `amount` is the card's face value in the Reloadly product's own currency (the `unitPrice` of the order): a positive decimal
  with at most three decimals, a JSON string or number. `Ref.ID` for Reloadly is `"<product_id>/<amount>"`, the amount
  without trailing zeros (`"13441/50"`, `"7/7.5"`). `max_cost` is **dinars for every supplier** (BN Plus quotes dinars;
  Reloadly's dollar price is converted). Unknown fields are refused; a document published before lists existed validates
  and encodes exactly as before (same fingerprint).
* Code: `vouchers.Item.Suppliers`, `vouchers.ParseRefs(item)`, `Located.Refs` (`Located.Ref` is the first);
  the ranking is a pure function of the item, the stored offers and the settings
  (`VoucherConfig.rankSuppliers`, `relay/internal/relay/vouchers_suppliers.go`).
* At purchase every listed supplier that is configured, sells the card and costs at most its `max_cost` is a candidate.
  "Sells the card": its offer is known and in stock; a supplier whose offers were **never read** is "unknown" (allowed,
  tried after every supplier with a known cost) except **Reloadly, which is never priced blind** (no offer, or no
  `usd_rate`, and it is out, reason `rate_unset`). The dinar cost of an offer is its price for `LYD` (or no currency),
  `usd_rate x (1+funding%)` for `USD`; any other currency is out. Candidates are ranked by dinar cost, ties by listing order.
* The first is called; on a **definite** failure (nothing bought: out of stock, balance, refusal, unreachable before send,
  bad credentials, a FAILED/REFUNDED order) `RedirectVoucherPurchase` re-points the row and the next candidate is tried
  (with the same purchase id as its reference); an **uncertain** failure stops the loop and the purchase is held, as with
  one supplier, and so does a redirect the store refuses or fails. The shop's `unit_price` never changes with the
  supplier: only our margin does. A failed purchase carries the **last** supplier's code and a detail that names each
  supplier tried; the log line has `suppliers_tried` and `suppliers_skipped`.
* An item is `available` when at least one candidate exists; the reason of an unavailable item names why each supplier was
  dropped (a single supplier's reason reads as it always did). Test mode keeps the one built-in supplier.
* Offers: BN Plus lists everything it sells; Reloadly implements the optional `vouchers.WantedOffers` and is asked only for
  the refs the current catalog names (a RANGE product's price depends on the amount), by the same offer sync (30 min). The
  cost in an offer is the **upper bound** of `reloadly.GiftCostBounds` (the published exchange rate is only known to its
  rounding), five decimals, `USD`; a product that vanished or does not sell the amount is absent ("no longer sold"); an
  inactive one is listed out of stock. The catalog read is reused for 10 minutes and re-read once a minute at most for a
  missing product. After publishing a catalog, `vouchers offers --sync` prices the new Reloadly cards at once.
* Health: the offer sync also reads Reloadly's balance (`vouchers.BalanceReader`); a Reloadly card dearer in dinars than a
  balance read in the last 2 h is dropped, with the balance in the reason. A supplier that fails in a way that will repeat
  (`supplier_credit`, `supplier_unauthorized`, `supplier_unreachable`, a timeout or 5xx) is skipped for 5 min per node
  (`SupplierBreaker`, one ERROR when it opens, a sale closes it) while another supplier can sell the card. Offers older than
  3 sync intervals (min 2 h) are "unknown" (Reloadly: not sold); an empty answer from a supplier with >= 10 stored offers
  is not believed. An unparseable settings document is "no dollar rate" for cards, not a 500. A relay on the Reloadly
  sandbox marks every card sale test (`VoucherConfig.SandboxMode()` / `MarksTest()`; services call `SandboxMode()` too).
* Reads: Reloadly implements the optional `vouchers.RefFinder` (`FindByClientRef`): the order is placed with
  `customIdentifier = purchase id`, so a held purchase is looked up exactly and the reconciler prefers it to `Find`
  (which Reloadly refuses). Codes are re-read through `Lookup(transactionId)`; an order whose codes cannot be read is
  `pending`, never a success. A card number is the `code` and a PIN its `serial`; a PIN beside a redemption link is
  `code` + `serial`; a link alone is the `code`.
* The relay compares in dinars: BN Plus `merchant_price` is dinars; Reloadly USD x `usd_rate` x `(1+funding%)`.
* Failure codes the shop must understand (all become a refused, refunded purchase): `supplier_out_of_stock`,
  `supplier_credit`, `supplier_unauthorized`, `supplier_unreachable`, `supplier_refused` (+ `unknown` stays held). A reused
  `customIdentifier` is never a refusal (`unknown`, held): the earlier order is found by its reference.
* Operator: `pointy-relay vouchers compare [--brand KEY]` (cost per supplier in dinars, winner, saving, shop price and margin,
  totals), `vouchers offers` (adds the dinar cost), `vouchers catalog show` (every supplier of an item),
  `vouchers reloadly balance`. The admin catalog route gives each item a `suppliers` array and a `winner`.
* `ops/catalog/tools/build_catalog.py` lists Reloadly (BN Plus first) on every gift card it sells identically (129 of 436
  items on 2026-10-08, Mastercard excluded); `max_cost` = its dollar cost x 9.71 x the same slack as BN Plus.

### 2.3 Services directory (airtime operators, billers)

Built from Reloadly (`/countries`, `/operators` all pages, `/billers`), refreshed in the background, last good copy
kept on error, served from memory. **v1 scope:** plain airtime operators only (`bundle`, `data`, `comboProduct`, `pin`
all false; `status == ACTIVE`) and every biller, including those that need an invoice number (`requiresInvoice`: Senegal's
water company and postpaid electricity are the only water/postpaid ones Reloadly has, so "water bills" depends on them). (Chad, Sudan, Syria, Somalia, Eritrea and
Libya have no operator at Reloadly today; they are listed as `unsupported` so the till can say so.)

**Left out of the directory on purpose** (owner / coordinator, 2026-10-08): (1) a country the relay cannot name in Arabic —
the card shop's table `vouchers.CountryName`, plus `extraCountryNamesAR` in `internal/services/countries.go` (today only
`AN` «جزر الأنتيل الهولندية») — is not offered at all, nor listed as `unsupported`. On Reloadly's list that is Israel
alone (`IL`, 3 operators): its operators and billers can be neither listed, quoted, detected nor ordered. The drop is
counted (`skipped.no_arabic_country_name`, `dropped_countries`), logged once per reading that changed anything
(`the services directory leaves out countries that have no Arabic name`) and shown by `pointy-relay services status`.
(2) A fixed bill plan whose **English description contains a word of `hiddenPlanWords`** (any letter case) is not offered:
the default is `Charme`, Canal+'s adult-content plans — 8 of the 28 plans of Canal+ Mali — a conservative-market default
kept as one list in `internal/services/normalize.go`. A hidden plan cannot be quoted or ordered either (`422
amount_not_offered`, by its `amount_id` or by its amount); a biller left with no plan is not offered; `hidden_plans`
counts them in the build stats.

**Fresh, sane, and honest about test** (review, 2026-10-08). (1) The directory is replaced whenever *any* row it is made
of changed at the supplier (commission, discount, fee, rate, limits, plan lists), not only when the visible structure did;
`version` (the ETag) moves with every price or limit a shop would see. (2) A quote or an order is accepted only while the
last good reading of the supplier is younger than three refresh intervals (at least 45 minutes): older, it answers `409
{"code": "service_unavailable", "reason": "stale"}`; the directory itself is still served. (3) A reading that lists no
country, none of a kind the directory in use has, or fewer than half of them, does not replace it (ERROR log, shown by
`pointy-relay services status`; `pointy-relay services directory --refresh --accept` believes it, once); the first reading
accepts anything that is not empty. (4) **Reloadly's sandbox is not test mode:** orders are really placed there (fake
money), but `test_mode` is `true` in the directory, the ledger row and the wallet statement entry of every order are
marked test, and the receipt carries `"test_mode": "true"` (the text `true`, like every receipt value; a live receipt has no
such key). The same holds for the fake supplier of `POINTY_RELAY_VOUCHERS_TEST_MODE`.

`GET /v1/services/directory` — installation token; `ETag` / `If-None-Match` → `304`.

```json
{
  "version": "16 hex",
  "generated_at": "2026-10-08T12:00:00Z",
  "currency": "LYD",
  "test_mode": false,
  "configured": true,
  "priced": true,
  "popular": ["NE", "ML", "NG"],
  "countries": [{
    "code": "ML", "name": "مالي", "name_en": "Mali", "dial": ["223"], "currency": "XOF", "currency_name": "فرنك أفريقي",
    "flag": "sha256:<hex>" ,
    "popular": 2,
    "airtime": {"operators": [ <Operator> ]},
    "bills":   {"billers":   [ <Biller>   ]}
  }],
  "unsupported": [{"code": "SD", "name": "السودان"}]
}
```

`currency_name` is the everyday short Arabic name a cashier would say next to an amount («فرنك أفريقي», «نيرة نيجيرية»,
«جنيه مصري», «دينار تونسي», «دولار»), from a table in `internal/services/currencies.go`; it falls back to the ISO code.
`airtime` / `bills` are omitted when the country has none. `flag` is a catalog image reference
(`GET /v1/vouchers/images/<sha>`), `""` when the catalog has no flag for it. `popular` is the 1-based rank in the
popular list, `0` when not in it; the top-level `popular` lists only popular countries that have a service, in order, and the
ranks count within it. `priced: false` when `usd_rate` is unset (amounts then carry no prices). `name_en` of a country is
Reloadly's English name, for search only like the operators' (clients never display it). `version` is the hash of the priced
body without `version` and `generated_at` (it moves with any price, name, flag, operator or order-mode change; `generated_at`
only moves when the supplier's data did, so a quiet directory has a stable body). A relay without Reloadly and without test
mode answers `200` with `configured: false` and empty lists; one that could not read Reloadly yet answers `503
services_unavailable` (`Retry-After`).

**Arabic only on screen (owner, 2026-10-08).** Every name a cashier or customer reads is Arabic: `name` is the Arabic
display name (from the table in `internal/services/names_ar.go`: «أورنج مالي», «كهرباء إيكيجا (مسبقة الدفع)»,
«كانال بلس أكسيس إنجليش بيسك – شهر»); `name_en` is Reloadly's own spelling, sent only so the search box also finds
«Orange» typed in Latin letters and so an operator can diagnose; **clients never display `name_en`**. A name missing from the
table falls back to the Latin spelling and is logged (`pointy-relay services names --missing` lists them).

`<Operator>`:

```json
{
  "id": 289, "name": "أورنج مالي", "name_en": "Orange Mali",
  "logo": "https://s3.amazonaws.com/rld-operator/….png",
  "mode": "range",                         // "range" | "fixed"
  "amount_currency": "XOF",                // currency of amount/min/max below: the local currency when the operator
                                           // takes local amounts, else USD
  "receive_currency": "XOF",               // what the recipient is credited in
  "approximate": false,                    // true when the recipient's amount is converted at Reloadly's rate (dollar tiles);
                                           // false for local tiles even when the order itself goes out in dollars
  "min": "1967", "max": "32800",           // range only
  "amounts": [{
    "amount": "5000", "receive": "5000", "receive_currency": "XOF",
    "unit_price": "91.30", "retail_price": "96.50"                    // omitted when priced is false
  }],                                      // fixed: every denomination; range: 3-6 round suggestions inside [min,max]
                                           // (1/2/5 x 10^k worth roughly 1.25-60 dollars, the popular amount always among them)
  "popular_amount": "5000"                 // or null
}
```

`<Biller>`:

```json
{
  "id": 5, "name": "كهرباء إيكيجا (مسبقة الدفع)", "name_en": "Ikeja Electricity Prepaid",
  "type": "electricity",                   // electricity | water | tv | internet | toll | other
  "service": "prepaid",                    // prepaid | postpaid
  "mode": "range",                         // range | fixed
  "requires_invoice": false,               // true: the order must carry the invoice number (postpaid / "facture" billers)
  "amount_currency": "NGN",
  "approximate": true,                     // only present when true: amounts are dollars that Reloadly converts (a biller
                                           // that takes no local amounts, e.g. South Africa's electricity)
  "min": "1000", "max": "300000",          // range only
  "suggested": [{"amount": "2000", "unit_price": "…", "retail_price": "…"}],         // range: round suggestions
  "plans": [{"id": 3, "amount": "10000", "description": "كانال بلس أكسيس إنجليش بيسك – شهر",
             "description_en": "Canalplus Acces English Basic (10000/1MOIS)",
             "unit_price": "…", "retail_price": "…"}]                                 // fixed only
}
```

Bills are sold **by type**, never as one undifferentiated list: the till shows one voucher-style card per type that has
at least one biller (كهرباء, مياه, تلفزيون, إنترنت; `toll`/`other` are not offered in v1), and inside it asks for the
country (only countries having that type) and then lists that country's providers by their Arabic names.

`POST /v1/services/detect` with `{"country": "ML", "phone": "70123456"}` — the operator Reloadly detects for a number
(a POST although it changes nothing: a customer's number never travels in a URL, where access logs would keep it).
`200 {"operator": <Operator>, "phone": {"e164": "+22370123456", "national": "70123456", "country": "ML"}}`;
`404 {"code": "operator_not_detected"}`; `422 {"code": "invalid_phone"}`; `503` when Reloadly is unreachable.
`phone` may be national digits, with or without a trunk `0`, or international digits with/without `+`/`00`; the
relay normalizes (the exact formats Reloadly accepts are recorded in `internal/reloadly/doc.go`): Arabic-Indic digits, spaces,
dashes and brackets are accepted, a trunk `0` is dropped when what remains is a plausible number, a number that starts with
the country's code and has the length of one that carries it is taken as international, and Reloadly is asked
`<country code><national digits>`. **A number must have the national length of its country** (`nationalShapes` in
`internal/services/phone.go`: 8 digits in Mali and Niger, 10 in Nigeria, Egypt, Turkey and Pakistan, 10 in Côte d'Ivoire and
Benin *with* the leading `0` that belongs to their numbers, and so on; and, where numbers never begin with `0`, none is
left once the trunk zero is dropped): one digit short or long (`6123456` in Mali, `80123456789` in Nigeria, `707123456` in
Côte d'Ivoire) is `422 invalid_phone` in detect, quote and order, before anything is charged, instead of a sale Reloadly
refuses afterwards. A country the table lacks keeps the generic rule (a plausible length, 15 digits in all at most). The
detected operator must be one of the directory (else `operator_not_detected`). In test
mode without Reloadly the operator is picked from the number's first digit (deterministic, meaningless). There is no GET variant.
No log line, ledger text or error detail the relay writes contains a full number or account: they are masked
(`+223•••••456`) and every supplier sentence is redacted of them.

`POST /v1/services/quote` — exact price of one thing, no Reloadly call (the directory is the data):

```json
{"kind": "airtime", "operator_id": 289, "amount": "5000", "amount_currency": "XOF"}
{"kind": "bill",    "biller_id": 5, "amount": "5000", "amount_currency": "NGN", "amount_id": null}
→ 200 {"quote": {"kind": "airtime", "name": "شحن مباشر · أورنج مالي · 5,000 فرنك أفريقي",
                 "unit_price": "91.30", "retail_price": "96.50",
                 "receive": {"amount": "5000", "currency": "XOF"}, "approximate": false}}
→ 422 {"code": "amount_out_of_range", "min": "1967", "max": "32800"} | "amount_not_offered" | "invalid_amount"
        | "invalid_invoice" | "invoice_required"   (only when the request carries a blank / malformed "invoice_id")
        | "invalid_phone"                           (only when an airtime request carries a "phone", see below)
→ 404 {"code": "unknown_operator"|"unknown_biller"} | 400 {"code": "invalid_request"}
→ 409 {"code": "service_unavailable", "reason": "rate_unset" | "directory_unavailable" | "cost_unknown" | "stale"}
→ 503 {"code": "services_unconfigured"}
```

**The number, read by the relay.** An airtime quote MAY also carry `"country": "CI"` (ISO; the operator's own when
omitted) and `"phone": "<digits as typed>"` — any form `ParsePhone` reads: national, with or without the trunk `0`,
`+<code>…`, `00<code>…`, `<code>…`, spaces / dashes / brackets, Arabic-Indic digits. The answer then also carries how
the relay read it, next to `quote`:

```json
→ 200 {"quote": {…}, "phone": {"e164": "+2250707123456", "national": "0707123456", "country": "CI"}}
```

`national` is what follows the country code **as Reloadly dials it** (for Côte d'Ivoire and Benin the leading `0` is part
of the number — 10 digits — and is kept; elsewhere a trunk `0` is dropped: `+2348031234567` / `8031234567`). **The shop must
not re-implement these rules: hand the number over as typed and use `phone.e164` / `phone.national`.** The `e164` it
returns round-trips: sent back as `phone` to `quote`, `orders` or `detect` it reads as the same number. An unreadable
number (`letters`, too short or too long, another country's code, a country that is not the operator's) answers `422
{"code": "invalid_phone"}`. A quote **without** `phone` (or with a blank one) is valid and answers exactly as before, with
no `phone` key: the till quotes its tiles before the number is typed. A bill quote ignores both fields. Table-tested for
CI, BJ, NG, ML, NE, EG, TR and PK in every form (`internal/services/phone_forms_test.go`).

`stale` (409): the supplier has not been read successfully for three refresh intervals (at least 45 minutes), so its
prices cannot be trusted; quotes and orders are refused until the next good reading. The directory itself is still served.

`POST /v1/services/orders` — the money call, idempotent on `idempotency_key`, same semantics, status codes and
held/uncertain handling as `POST /v1/vouchers/purchases`:

```json
{"kind": "airtime", "operator_id": 289, "country": "ML", "phone": "70123456",
 "amount": "5000", "amount_currency": "XOF",
 "idempotency_key": "≤100 chars", "max_unit_price": "91.30", "requested_by": "cashier"}
{"kind": "bill", "biller_id": 5, "country": "NG", "account": "04223568280", "invoice_id": null,
 "amount": "5000", "amount_currency": "NGN", "amount_id": null,
 "idempotency_key": "…", "max_unit_price": "…", "requested_by": "…"}
```

`201`/`200` replay → `{"purchase": P, "balance": "…", "replayed": bool}` with `P.status = succeeded`; `202` pending;
`402 insufficient_balance`; `404 unknown_operator|unknown_biller`; `409 price_changed {unit_price}` / `in_flight` /
`service_unavailable {reason}` / `idempotency_key_reused`; `422 invalid_phone|invalid_account|invalid_invoice|invoice_required|invalid_amount|amount_out_of_range|amount_not_offered`;
`429 rate_limited`; `502` + one of the supplier codes of 2.2 with `purchase`; `503 services_unconfigured|services_unpriced|services_unavailable`.
`max_unit_price` is the shop cost it was quoted: the relay charges its current price when that is not higher, else
`price_changed` (`unit_price` with two decimals; the till then re-quotes). A key that already names a different order
(another item, **another number or account — compared in full, not by its mask —, another invoice number**, another kind,
or a card purchase) is `409 idempotency_key_reused`; the same order written differently (`0022370…` for `+22370…`,
`5000.00` for `5000`, a fixed plan named by its amount for the same plan named by its id) replays the first answer. The
relay compares the whole target by a keyed digest it keeps in the order's details (2.4); a row without a usable digest (older,
or made under a key since replaced) is judged by its masked target, as before. `amount_currency` is
required (`400 invalid_request`); `amount` and `max_unit_price` may be JSON strings or numbers; **an `amount` may have no
more decimals than its currency has: whole numbers for `XOF XAF XPF JPY KRW VND UGX RWF GNF PYG CLP ISK KMF DJF BIF VUV`,
at most two for every other, else `422 invalid_amount` (`5000.5 XOF`; `5000.00` is the whole 5000, accepted; a fixed plan is
whatever the supplier lists); the directory never offers an amount of its own that this refuses**; `invoice_id` is read
only for billers that require one (1-24 chars of `[A-Za-z0-9_/-]`), `account` is 3-40 chars of `[A-Za-z0-9._/-]` with
spaces removed. A fixed biller's plan is named by `amount_id` or, when the amount is unique, by `amount` alone.

`P` is the voucher purchase payload (VOUCHER_SHOP_PLAN.md) with these changes: `kind` (`card` | `airtime` | `bill`; a card
payload now carries `"kind": "card"` and `"target": ""`); `codes` is `[]` and `codes_pending` `false` for services; `target`
is the masked number/account (`+223•••••456`, `•••••••280`); `item` is `airtime:289:5000:XOF` / `bill:5:5000:NGN` (a fixed
plan adds `:<amount_id>`), `brand` is `airtime` / `bill`, `name` the frozen Arabic statement name («شحن مباشر · أورنج مالي ·
5,000 فرنك أفريقي», «دفع فاتورة كهرباء · كهرباء إيكيجا (مسبقة الدفع) · 5,000 نيرة نيجيرية»; a fixed plan adds its description);
`unit_price` / `amount` are the ledger's (three decimals, `"93.630"`, like a card's); and two keys that are always present:
`receipt` (an object: the slip's fields once the order is carried out and can be read from Reloadly, `{}` otherwise) and
`receipt_pending` (`true` while the order is open, or succeeded and the receipt cannot be read right now):

```json
// airtime
{"transaction_id": "4602843", "operator": "Orange Mali", "phone": "+22370123456",
 "delivered_amount": "5025", "delivered_currency": "XOF", "operator_reference": "7297929551:OrderConfirmed",
 "order_amount": "9.9505", "order_currency": "USD"}
// bill
{"transaction_id": "36", "biller": "Ikeja Electricity Prepaid", "account": "04223568280",
 "amount": "5000", "currency": "NGN", "token": "2737-6032-5315-7183-0856", "units": "10.7 kWh",
 "biller_reference": "T_QKTBYLMGPA", "order_amount": "5000", "order_currency": "NGN", "info": "DIAL *555#"}
```

`delivered_amount` / `amount` are what the recipient / the biller **received**, in their own currency (an order placed in
dollars delivers a little more than the quote because of the buffer); `order_amount` / `order_currency` are what was ordered.
**The amounts are Reloadly's own text, untouched** (`"2010.002"`, `"5025.0003"`, never rounded, trimmed or padded by the
relay): **the shop formats them** for the currency they are in (a whole number of CFA francs, say).
`info` carries any other line the biller printed beside the token and is omitted when empty; `token` and `units` only exist
for prepaid meters (Reloadly's sandbox returns none). Keys with no value are left out. An order that is not real money (the
fake supplier, or Reloadly's sandbox) adds `"test_mode": "true"` to its receipt; the purchase's own `test_mode` is the
boolean.

The relay keeps no tokens/PINs: they are re-read from Reloadly by transaction id on every read (`receipt_pending: true`
while they cannot be read back). `GET /v1/vouchers/purchases/<key>` returns any kind (the shop's read-back path is
unchanged); `GET /v1/services/orders/<key>` is an alias. A replay of a succeeded order answers `200` (`202` with
`receipt_pending: true` when Reloadly cannot be read), of a failed one `502`, of an open one `202` (`409 in_flight` while the
first request is still on its way).

**Pending and held.** A top-up answers its final state on the call; a bill is *accepted* first (`PROCESSING`), settles
within seconds in the sandbox and up to a day live. The relay polls its status for `POINTY_RELAY_SERVICES_SETTLE_WAIT`, then
answers `202` with the order held (`held: true`, Reloadly's id kept). The reconciler (every minute, the same worker as for
cards) reads the order by id — or, when Reloadly named none, finds it by the purchase id used as `customIdentifier` /
`referenceId` — and settles it: `SUCCESSFUL` keeps the charge, `FAILED` / `REFUNDED` returns the price, anything else is
asked again next time. A bill is never refunded before Reloadly says so; an order nobody finds is refunded only after 15
minutes for a top-up and **25 hours for a bill** (a payment may stay `PROCESSING` for a day and a lost-answer one may not be
listed meanwhile; an hourly WARN says it is being waited for). An order unresolved or unreadable for two days logs an ERROR
(hourly) for the operator (`vouchers resolve`). When several orders carry one identifier (Reloadly's duplicate check is not
atomic) a `SUCCESSFUL` one wins over a `FAILED` / `REFUNDED` twin; two `SUCCESSFUL` ones, or a failed one beside one still
open, stay held for a person. The `error_code` of a refund by Reloadly's word is the one the first uncertain answer left
(`supplier_unknown`) or `supplier_refused`.

### 2.4 Ledger

`relay_voucher_purchases` gains `kind text not null default 'card'`, `target text not null default ''`,
`details jsonb`. A service order is one row: `item_key` = `airtime:289:5000:XOF` / `bill:5:5000:NGN`, `brand_key` =
`airtime` / `bill`, `quantity` = 1, `unit_price` = the shop price, `supplier` = `reloadly` (`test` in test mode), `supplier_ref`
= operator/biller id, `supplier_order_id` = Reloadly transaction id **prefixed with the kind** (`airtime:4602843`, `bill:36`:
Reloadly numbers top-ups, payments and gift cards separately and the ledger allows one purchase per (supplier, order id), so a
bare id could collide), `supplier_cost` = USD, `supplier_currency` = `USD`, `target` = the masked number, `details` = what was
ordered (operator / biller ids and names, country, amount, currency, receive, `order_mode`, `order_amount`,
`order_currency`, `buffer_percent`, an invoice flag — never the number, the account or the invoice), plus the calling
codes the number was read with (`dial`), `target_digest` and `target_kid`: **`target_digest` is the first 16 hex digits of
HMAC-SHA256 under a relay-side secret** over (shop id, kind, the digits of the number with its country code or the account,
the invoice number when the biller takes one, the currency of the amount). It is how a replay is told from another order
that shares the mask (`+223•••••456`); it is keyed, never a plain hash, because a phone number has too few digits to hide
behind one. The key is `HMAC-SHA256(admin token, "pointy-relay-service-target/v1")`, derived like the node-proxy token:
identical on every instance, stable across restarts, held by the relay and not by the database; rotating the admin token
changes it, which `target_kid` (a four-digit name of the key) lets the relay notice, so an older order is judged by its mask
instead of being refused. Charge
`voucher:<id>` / refund `voucher-refund:<id>` on the `vouchers` wallet account — **one balance pays for cards, top-ups
and bills**. Reloadly's `customIdentifier` / `referenceId` is the purchase id, so a lost answer is found exactly
(`FindTopups/FindPayments/FindGiftTransactions`), never by guessing. The reconciler dispatches on `kind`.

### 2.5 Operator CLI

`pointy-relay vouchers settings show|set …` (now with `--airtime-order-mode usd|local`, `--airtime-usd-buffer`,
`--bills-order-mode auto|local`, `--bills-usd-buffer`), `pointy-relay services directory [--country ML,NE] [--refresh] [--json]`,
`pointy-relay services quote --kind airtime --operator 289 --amount 5000` (price, and how it is ordered from Reloadly),
`pointy-relay services names --missing` (operators, billers, plans without an Arabic spelling), `pointy-relay services balance`
(the three product balances; a clear message when Reloadly is not configured), `pointy-relay services status`,
`pointy-relay vouchers purchases --kind airtime`. `vouchers offers --sync` also reads Reloadly. Admin routes:
`/v1/services/admin/{config,directory,quote,names,balance}`. No command takes a phone number or an account.

## 3. Shop backend (Django, `apps/integrations`)

Provider `pointy` gains two service lines. Nothing about HD Box / LNET / Qareeb changes.

* Capabilities `CAPABILITY_AIRTIME = "airtime"`, `CAPABILITY_BILLS = "bills"` on `POINTY`.
* Service variants (system SERVICE products, made by `provisioning.service_variant_for`): SKU `INTEG-POINTY-AIRTIME`
  «شحن مباشر» and `INTEG-POINTY-BILL` «دفع فاتورة».
* Mirror: `IntegrationServiceCountry` (account, code, name, dial JSON, currency, currency_name, popular, flag PNG ≤96px
  (via the existing image machinery of `voucher_flags.py`), counts, `payload` JSON `{airtime:{operators}, bills:{billers}}`)
  + the unsupported list on `account.config`; synced by `integrations.sync_relay_services` every 5 min (ETag; `304`
  writes nothing). Reads never call the relay.
* **Option codes** (≤ 64 chars): `air:<operator_id>:<amount>:<CUR>`, `bill:<biller_id>:<amount>:<CUR>[:<amount_id>[:<invoice_id>]]`
  (`amount_id` empty when none: `bill:24:15000:XOF::2024-118833`; invoice ids are 1–24 chars of `[A-Za-z0-9-_/]`).
  `subscriber_ref` = E.164 phone (`+22370123456`) / the bill account number. The cart line is the service variant with an
  `integration` payload `{provider: "pointy", subscriber_ref, option_code, option_label, quote}`.
* **Sealed quote** (`quotes.py`) additionally seals the retail `price`; checkout opens `(cost, price)`; the line price is
  `max(price, cost)`; `cost` = the relay's `unit_price`.
* `resolve_line_integration` branches on the variant: card variant → `_resolve_voucher_line` (unchanged); the two
  service SKUs → `_resolve_service_line`. `fulfillment_kind` returns `airtime` / `bill` for those.
* `PointyProvider.recharge(card_no, option_code, expected_cost, attempt_key)`: an `air:`/`bill:` option goes to
  `POST /v1/services/orders` (`card_no` = the subscriber_ref); anything else is a card as today.
  `attempt_outcome` reads `GET /v1/vouchers/purchases/<key>` and parses by `purchase.kind`. The driver must also map
  EVERY relay failure code (`supplier_credit`, `supplier_unauthorized`, `supplier_unreachable`, `supplier_refused`,
  `supplier_out_of_stock`) to a definite refusal (today only three are mapped, the rest are wrongly "indeterminate").
* `provider_receipt` / slip `printed` for the new kinds carries ready-made rows so no client release is needed for new
  wording: `printed = {"title": "شحن مباشر", "rows": [["الشبكة", "أورنج مالي"], ["الرقم", "+223 70123456"],
  ["المبلغ المرسل", "5,000 فرنك أفريقي"], ["رقم العملية", "4602843"]], "pin": "<bill token or ''>",
  "pin_label": "رمز الشحن", "notice": "…"}` — every amount carries its currency in Arabic (the mirror's `currency_name`
  for that ISO code from ANY country; «دولار أمريكي» / «يورو» when none names it; the bare code only when nothing does),
  the phone is grouped by its country's calling code, units (kWh) print as the relay wrote them — emitted on BOTH receipt routes (thermal JSON `apps/printing/services.py`, `redeem.py`; document route
  `SaleLineIntegration`).
* Endpoints (permission `integrations.use_integrations`; `with_cost` as in the voucher menu):

  | Endpoint | Purpose |
  | --- | --- |
  | `GET /api/integrations/vouchers/menu/` | gains `"services": [{"key": "airtime", "kind": "airtime", "available": true, "variant_id": 123, "countries": 126, "providers": 411}, {"key": "bill:electricity", "kind": "bill", "bill_type": "electricity", "available": true, "variant_id": 124, "countries": 6, "providers": 25}, {"key": "bill:water", …}, {"key": "bill:tv", …}]` — one entry per service CARD: airtime, plus one per bill type that has a biller (both `airtime` and every bill type are listed only when available). Keys only: names, descriptions and art are the till's (l10n + drawn), never the backend's |
  | `GET /api/integrations/services/directory/` | `{available, error_code, version, balance, popular: [...], countries: [{code, name, dial, currency, currency_name, popular, airtime: <n>, bills: <n>}], bill_types: [{type: "electricity", countries: ["NG","SN",…], counts: {"NG": 10, "SN": 4, …}, billers: 25}, …], unsupported: [{code, name}]}` (no operators, no flags) |
  | `GET /api/integrations/services/countries/<CODE>/` | `{country, airtime: {operators}, bills: {billers}}` as in 2.3 (prices = `retail_price` as `price`; `cost` only with full visibility) |
  | `GET /api/integrations/services/flags/?codes=ML,NE` | `{"flags": {"ML": "<base64 png>"}}`, ≤ 40 codes, unknown omitted |
  | `POST /api/integrations/services/detect/` | body `{country: "ML", phone: "70123456"}` (never in the URL) → live relay detect: `{detected: bool, reason: "", operator, phone: {e164, national, country}}` (`200` always for refusals) |
  | `POST /api/integrations/services/quote/` | `{kind, country, operator_id\|biller_id, phone\|account, amount, amount_currency, amount_id?}` → `{ok, kind, option_code, option_label, subscriber_ref, price, receive: {amount, currency}, approximate, quote, service_variant_id, exceeds_float, cost?}` or `{ok: false, error_code, min?, max?}` |
  | `GET /api/integrations/services/recent/?kind=airtime` | last 12 distinct recipients: `{phone, country, operator_id, operator_name, amount, currency, at}` |

* Refusal vocabulary (stable codes; the till owns the Arabic): `detect.reason` ∈ `not_detected`, `invalid_phone`,
  `unavailable`, `not_configured`, `switched_off`; `quote.error_code` ∈ `amount_out_of_range` (+`min`,`max`),
  `amount_not_offered`, `invalid_amount`, `invalid_phone`, `invalid_account`, `invoice_required` (none given),
  `invalid_invoice` (given, but not an invoice number), `unknown_operator`, `unknown_biller`,
  `service_unavailable` (+`reason`), `rate_unset`, `unreachable`, `not_configured`, `switched_off`. A transport or
  permission failure is an ordinary HTTP error as everywhere else. The shop passes the number to the relay as typed
  (`country` + `phone`) and sells to the relay's `phone.e164`; it only checks that what is typed has the shape of a
  number (6-15 digits), and an amount's decimals against the currency (whole numbers for the relay's list, two for the
  rest, unless the network itself lists that amount).
* A service is charged with `max_unit_price` = **what the customer actually paid for the line, after every discount**
  (`recharge.cost_ceiling`; never below the quoted cost), not the quoted cost: the relay's price follows the exchange rate
  and a quote does not expire. A rise inside it is performed and the real cost recorded on the line; a rise above it is
  refused as the driver code `price_changed`
  (definite, nothing bought), whose figures go only to readers who may see cost. A void or a full return of the line
  withdraws a still-`pending` fulfillment (`cancelled`); a `submitted` one is left to reconciliation.
* Everything else (checkout, `fulfillments/charge/`, reconciliation, float ledger, receipts) is the existing machinery;
  the new kinds ride it. Tests run on Postgres with their OWN database name and Redis db (see AGENTS.md /
  `backend-test-db-exclusivity`).

## 4. Till (Flutter): the experience

**Everything on screen is Arabic** (owner, 2026-10-08): the UI strings (l10n) and every network / provider / plan name
(the backend sends Arabic `name`; `name_en` is only searched, never shown). Currency names are Arabic («فرنك أفريقي»).

**The new product must explain itself** — a shop owner who has never heard of it must understand it from the screen
alone, with nobody explaining it. So:

* Every service is a **voucher-style card** (same footprint, press feel and 16:10 art as the brand cards, drawn natively:
  a gradient plus a large pictogram, light and dark) with its Arabic title AND a one-line Arabic promise under it:
  «شحن مباشر» — «أرسل رصيداً إلى أي رقم هاتف في العالم خلال ثوانٍ، بدون بطاقة»؛ «فواتير الكهرباء» — «ادفع فاتورة
  الكهرباء أو اشحن عدّاد أهلك في الخارج»؛ «فواتير المياه»؛ «اشتراكات التلفزيون»؛ «الإنترنت» — each with a «جديد» badge
  for the first weeks. Cards exist only for services the menu says are available.
* Inside `PosVoucherMenuPane`: the category tab row gets two **service tabs** right after «الكل»: «الشحن المباشر» (bolt
  icon) and «دفع الفواتير» (receipt icon). «الكل» also shows a **services strip** (the same cards) above the brand grid so
  the new concept is seen without opening any tab. The «دفع الفواتير» tab is a grid of **bill-type cards**: «فواتير
  الكهرباء», «فواتير المياه», «اشتراكات التلفزيون», «الإنترنت» (only those with providers).
* Every flow starts with a one-line "what you need" («رقم هاتف المستلم»، «رقم العدّاد — تجده على الفاتورة أو على
  العدّاد نفسه»), shows example formats, says what happens next as a visible 4-step timeline (اختر ← أضف إلى السلة ← أصدر
  الفاتورة ← يصل المبلغ ويُطبع الإيصال), and says plainly what is NOT possible (no refund after sending; countries not served).
* Selecting a service tab for airtime replaces the brand grid with the guided pane below. **Everything is on one screen;
  nothing hides behind a wizard**: steps are numbered sections that are visible and dimmed until their turn, and a live
  summary card repeats what the cashier will read back to the customer.

### الشحن المباشر

1. **Explainer** (dismissible, remembered; a help icon brings it back): «أرسل رصيداً إلى أي رقم هاتف في العالم خلال
   ثوانٍ — بدون بطاقة. اختر الدولة، اكتب الرقم، اختر المبلغ.» + «كيف يعمل؟» opens three illustrated steps and says the
   truth: sent when the invoice is issued, cannot be taken back, which countries are not served.
2. **Recent numbers** chips (flag, number, network, last amount): one tap fills country + number + network.
3. **① الدولة.** Search box «ابحث بالاسم أو اكتب رمز الدولة (مثل 223)». Digits are matched against dial codes
   (`223` → Mali, `1` → أمريكا/كندا candidates, `1868`…, longest prefix wins); Arabic search is normalized (أ/إ/آ, ة/ه,
   ى/ي, tashkeel, Arabic-Indic digits); English names also match. Empty search shows the **popular** flags grid
   (NE, ML, NG, EG, …) then the A-Z list with flag, Arabic name and `+dial`; unsupported countries appear greyed with
   «غير متاح حالياً» when searched (so «السودان» never answers "no results"). A pasted full number
   (`+223 70 12 34 56`, `00223…`) in the number field selects the country by itself.
4. **② رقم الهاتف.** LTR digits-only field with the fixed `+223` chip; grouped as typed; paste-aware. A status line
   under it: «جارٍ التعرف على الشبكة…» → «✓ Orange Mali» with the logo. The country's networks are always shown as chips
   below (the detected one selected): the cashier can pick one at once without waiting, or after a failed detection
   («لم نتعرف على الشبكة، اختر الشبكة»).
5. **③ المبلغ.** Tiles: big «5,000 فرنك» (what the recipient receives) and small «96.50 د.ل» (what the customer pays);
   range networks: suggested tiles + «مبلغ آخر» with min–max hint and live price (debounced quote); fixed networks: their
   denominations. Approximate conversions are marked «≈».
6. **Summary card** (sticky): country, number (LTR), network, «يصل للمستلم», «يدفع الزبون», the one-line truth
   «يُرسل الرصيد فور إصدار الفاتورة ولا يمكن استرداده بعد إرساله», and **«أضف إلى السلة»** (disabled with the reason
   under it). After adding: snackbar, the form returns to ② keeping the country, the recents update.

### دفع الفواتير (by bill type)

Tapping a bill-type card (e.g. «فواتير الكهرباء») opens a **dialog on wide screens / full-height sheet on phones**
(the same family as the brand sheet; modal, so POS hotkeys and the barcode listener cannot interfere) with a breadcrumb
that is always visible (كهرباء ‹ نيجيريا ‹ كهرباء إيكيجا (مسبقة الدفع)) and a back arrow:

1. **اختر الدولة** — only countries that have this bill type, with flags and Arabic names (searchable when > 8), each
   showing how many providers it has («نيجيريا · 10 جهات»).
2. **اختر الجهة** — the country's providers by their **Arabic names**; electricity grouped «عدّاد مسبق الدفع — تستلم
   رمزاً وتُدخله في العدّاد» / «فاتورة لاحقة الدفع — تسدّد قيمة فاتورتك»; TV by company; water by company. No Latin names.
3. **رقم العدّاد / الحساب / الاشتراك** — LTR field with the right label and example for the type (electricity «رقم
   العدّاد», water «رقم الحساب», TV «رقم بطاقة الاشتراك»), "تأكد من الرقم: لا يمكن استرجاع الدفع بعد إرساله".
4. **المبلغ** — range: round suggestions + a field with limits; fixed: the plans (Arabic descriptions) as tiles.
5. **ملخص** and «أضف إلى السلة».

Prepaid electricity says «ستظهر على الإيصال شيفرة الشحن لإدخالها في العدّاد». Airtime keeps its inline pane in its tab
(highest-frequency flow); only the POS-key hazards of inline fields need care there.

### After the sale

The cart line reads «شحن مباشر · Orange Mali · 5,000 فرنك ← +223 70 12 34 56» (its own cart-tile string, not the
"card" one). Checkout → the existing charge call → a **success dialog for these kinds** (a charged airtime/bill result
used to be a snackbar only): ✓, number, network, amount received, reference, and for a bill the token large with copy;
the slip prints automatically (kinds `airtime` / `bill`, rows from `printed.rows`, token as the slip's PIN with
`pin_label`). A pending answer uses the existing «نتيجة الشحن غير معروفة» dialog (do not retry).

## 5. Work split (files each worker owns)

| Worker | Owns |
| --- | --- |
| R0 reloadly client | `relay/internal/reloadly/*` |
| R1 relay core | `relay/internal/control/*` (settings store, purchase `kind/target/details`, `RedirectVoucherPurchase`, migration v21, cached wrapper), `relay/internal/vouchers/settings.go` (the typed settings + pricing helpers), the settings admin route + CLI (`vouchers settings`) |
| R2 relay cards | `relay/internal/vouchers/{supplier,catalog,bnplus,reloadly}*.go`, `relay/internal/relay/vouchers.go` (purchase flow, availability) and `vouchers_workers.go` (offer sync), CLI offers |
| R3 relay services | `relay/internal/services/*` (new), `relay/internal/relay/services*.go` (new), a kind dispatch in `checkVoucherPurchase`, CLI `services …`, wiring in `cmd/pointy-relay/main.go` |
| B shop backend | `backend/apps/integrations/*`, `backend/apps/printing/*` receipt payloads |
| F till | `frontend/lib/**` (models, API client, repository, view models, widgets, l10n, preview, slips) + tests |

Shared files (`relay/internal/relay/vouchers.go`, `cmd/pointy-relay/*.go`, `control/vouchers.go`): anchored `Edit`s only,
never a whole-file `Write`; re-read before each edit.

## 6. Verification

Go: unit tests with `httptest` fakes of Reloadly + the in-memory/file store; the same suite against Postgres where
the repo already does. Sandbox smoke (opt-in env): gift card, airtime and bill orders against the Reloadly SANDBOX only.
Django: Postgres, own DB + Redis db. Flutter: unit/widget tests, headless goldens of the new panes (light/dark, RTL,
1366/1024/phone), receipts rasterized. Final: a real relay binary (sandbox keys, test mode off) + real Django + the
till preview doing an airtime top-up and a bill payment end to end.
