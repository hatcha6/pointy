# «كروت دفتر» pricing v2 — contract (2026-10-08, owner's calls)

Shared by the relay, shop backend and till workers. Builds on DIRECT_TOPUP_PLAN.md.

## Owner's calls
1. **Live FX**: the dinar rate for Reloadly costs comes from our own FX module (the relay's fulus.ly rates,
   `relay/internal/relay/fulus*.go`, stored as `control.ExchangeRate`), in real time — not a typed constant.
   Funding cost is unknown: keep `funding_percent` (default 0).
2. **Margin grows with size**: a $100 card must earn far more (in dinars) than a $2 one. Strategy (industry
   norm: fixed fee + percentage, percentage tapering with value):
   `margin = fixed_lyd + Σ marginal bracket percentages over cost` (like tax brackets: continuous, monotone),
   then `margin = max(margin, min_margin_lyd)`.
   Demo defaults (owner tunes later): fixed 0.50 LYD; 8 % on the first 50 LYD of cost, 6 % from 50–200,
   5 % from 200–1000, 4 % above 1000; min margin 0.50 LYD. (≈ $2 card 19 LYD → 2.0 LYD; $100 card 971 LYD → ~50 LYD.)
3. **50-50 split** of that margin between the company and the shop (`shop_share_percent`, default 50):
   `shop_pays = round_up_2dp(cost + margin × (1 − shop_share))`,
   `suggested_retail = round_up_to_step(cost + margin)` (step default 0.25), never below `shop_pays + min_shop_margin` (0.10).
4. **Shops choose per product**: follow the company's suggested price, or set their own. Configurable shop-wide
   default and per product (each card variant; each direct service: airtime and each bill type, optionally per country).
   A shop price can never be below what the shop pays (existing loss guard stays).

## Relay (Go)
- `vouchers.Settings`: replace the shop/retail markup pair by `margin` = `{fixed_lyd, min_margin_lyd,
  brackets:[{up_to_lyd|"" (open), percent}], shop_share_percent, round_step, min_shop_margin}` — globally and
  optionally per kind (airtime / bill / card). Keep reading old settings documents (migrate old fields in Normalize).
- `usd_rate_source`: `fulus` (default when a rate exists) | `manual`. With `fulus`: series `cash` | `bank` + `bank_code`
  (default `cash`), plus `usd_rate_buffer_percent` (default 0); a rate older than `usd_rate_max_age` (default 48h) is
  stale → fall back to the manual `usd_rate` if set, otherwise refuse with a clear error (no sale at a stale guess).
  The rate used is recorded on each purchase (`details.usd_rate`, `details.usd_rate_source`).
- Wire shape to shops unchanged: `price` (= shop pays) and `retail` (= suggested) per option/quote. Add
  `pricing: {fixed_lyd, brackets, shop_share_percent, round_step}` to the services directory so the shop can show it.
- Cards: the catalog's static prices stay valid; add `price_mode: "auto"` on items (or catalog-wide default) so the
  relay prices a card from its cheapest supplier cost with the same formula. `ops/catalog/tools/build_catalog.py`
  emits `auto` for every item.
- CLI `pointy-relay vouchers settings set` gains the new flags; `vouchers settings show` prints an example ladder
  (cost 20/100/500/1000 LYD → margin, shop pays, retail).

## Shop backend (Django)
- Model `IntegrationPriceRule` (provider `pointy`): `scope` = `default` | `service` (key `airtime`, `bill:electricity`…,
  optional `country`) | `variant` (FK ProductVariant); `mode` = `company` | `custom`; for services `markup_percent`
  (custom retail = round_up_step(shop_pays × (1+markup))) ; for variants `price` (fixed dinars).
  Resolution: variant/service+country → service → default → company.
- Sync (`sync_relay_vouchers`) must not overwrite a variant whose rule is `custom`; `company` variants follow the relay's retail.
- Services quote seals the resolved price.
- API (owner/manager perms, same as other integration settings):
  `GET  /api/integrations/pointy/pricing/` → `{"default_mode", "services":[{"key","label","mode","markup_percent",
  "example":{"cost_hint","shop_pays","company_price","your_price"}}], "company_rule":{fixed_lyd, brackets, shop_share_percent}}`
  `PUT  /api/integrations/pointy/pricing/` (default_mode, services[])
  `GET  /api/integrations/pointy/pricing/cards/?search=&brand=&page=` → rows `{variant_id,name,brand,shop_pays,company_price,mode,custom_price}`
  `PUT  /api/integrations/pointy/pricing/cards/<variant_id>/` `{mode, price}`; `POST .../cards/bulk/` `{variant_ids|brand, mode, markup_percent?}`.
  400 with Arabic message when a price is below `shop_pays`.

## Till (Flutter)
- **Direct top-up becomes a stepped dialog** like the bills flow (country → number + detected network → amount →
  summary → add to cart), opened from the «الشحن المباشر» tab (a launcher card + recent numbers). Remove the inline
  two-column pane. Keep every guard (read-back, mismatch, balance, test mode).
- **Pricing screen** «أسعار كروت دفتر» (owner/manager): default mode switch, services list (company price / my
  markup %, with a live example line), cards tab (search, brand filter, per-row custom price, bulk "follow company").
  Arabic only; strings in app_ar.arb.

## Addendum (2026-10-08): supplier anonymity, service fee, below-cost alert
- **Shops never learn the supplier.** Operator logos are fetched and kept by the relay (voucher image store, served at
  `GET /v1/services/logos/{sha256}`); the directory carries `sha256:<hex>` only, the shop mirrors them
  (`services_logos.py`) and tills get the shop backend's own `/api/integrations/services/logos/<hex>/`. Failure codes to
  shops are neutral (`out_of_stock`, `refused`, `unavailable`, `unknown`), error details are fixed sentences, receipts carry
  our purchase id as `transaction_id`. `internal/relay/services_anonymity_test.go` fails on supplier words/hosts.
- **Airtime service fee** `airtime.service_fee_lyd` (default 2; `--airtime-service-fee`): added on top of the margin to both
  what the shop pays and the suggested retail, never split; recorded as `service_fee_lyd` in the purchase details.
- **Below-cost cards**: a custom card price under what the shop now pays blocks the card (menu unavailable, sale refused),
  raises `integrations.below_cost_cards` for owner/managers (one alert per set of cards, clears itself), and the cards
  endpoint gives `below_cost` per row, `?below_cost=1`, `below_cost_count`, and `bulk {below_cost: true, mode: "company"}`.
