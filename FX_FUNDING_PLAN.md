# Pricing dollar cards at what our dollars really cost

Status: **built (relay + console), reviewed, not deployed.** On 2026-11-26 production was already switched by hand
to the North Africa Bank series (`usd_rate_series bank`, `usd_rate_bank_code nab`) plus a 7% buffer, with card
margins of 10/9/8/8%.

## Why

In November 2026 we funded FazerCards with Binance USDT codes bought from BN Plus at **10.80 LYD per dollar**.
The relay priced those cards at the fulus.ly **cash** rate, which was about **10.0**. The Arena Breakout sales
(≈ $130) went to the shop at 10.56–10.85 LYD per dollar: below what the dollars had cost us.

Over the whole run, $167 of goods brought in 1,813 LYD against 1,890 LYD paid. Replacing those dollars at today's
BN Plus price (12.42) would cost 2,076 LYD.

A dollar's cost is what it costs us to **buy it again**. A market quote is not that cost, and neither is what we
paid last month.

## The rule (relay `internal/vouchers/fx.go`)

Dollar costs are priced at the **higher** of two rates. "Live rate" means the series the settings name; production
uses North Africa Bank.

| Rate | How it is computed | Why |
|---|---|---|
| **Replacement** | live rate × (1 + the refill premium) | The premium is the **median** of the latest `fx.premium_top_ups` (3) recorded top-ups: what we paid per dollar divided by the bank rate that day, never below 0. One odd or mistyped top-up can't reprice everything; a premium above 15% is flagged on the console. With no top-up in the last 60 days, `usd_rate_buffer_percent` stands in. |
| **Fading peak** | the highest replacement rate of the last `fx.peak_days` (7), losing `fx.fall_percent_per_day` (2%) for every whole hour of age | Rises reach prices at once. A fall is held back only while it is younger than `fx.release_hours` (24): a one-day dip can't drag prices under a refill we may still make at the high rate. **Once a lower rate has held for 24 hours, the peak is let go.** Falls can be sharp: the central bank's $2 billion injection in April 2026 took the street dollar from about 10 to about 8 in weeks. |

On top of that sits a **cushion** for a climbing dollar:

```
cushion = min(fx.cushion_cap_percent (5%), fx.momentum_share_percent (50%) × the rise over fx.momentum_days (7))
```

It covers the next refill costing more than this one.

- **Competitors (reference only).** The pricing does **not** depend on competitor prices: we have no reliable way to
  keep them current. The few captured in October (8 and 11 Oct) expired after `market_max_age_days` (30), so since
  about 10 November no card is priced from them. If fresh competitor data is ever loaded for a card, the peak and the
  cushion won't make that card dearer than the competitor; past that point it is priced at the replacement rate,
  and only while the supplier bought from stays the same. With no fresh data, that check simply doesn't apply.
- **The supplier bought from.** A card is priced from the cost of the supplier a purchase actually buys from: our own
  stock first, then the cheapest.
- **Greyed-out cards.** A card no supplier can sell right now is priced from the cheapest cost any supplier quotes,
  so it no longer shows a months-old catalog price. A card with no known cost at all keeps its catalog price.
- **Shocks.** A move of 3% or more within a day is flagged on the console (`fx.shock_percent`).
- **The fulus.ly feed goes stale** (older than `usd_rate_max_age`, 48h). If a manual `usd_rate` is set, it prices.
  Otherwise cards price from the **last rate the series holds**, never below what the **latest top-up** paid per
  dollar, with the **full cushion**. Cards keep selling instead of leaving the shelf, and the console shows it.
- **Fees.** The settings' `funding_percent` is for fees charged **per top-up** and is 0 today. The FazerCards
  subscription is a **monthly expense**, not a per-dollar cost: it is recorded in the relay's books (console →
  finance, as a recurring expense), not priced into cards.

### Why there is no cost floor (decided 2026-11-26)

The first build also priced the dollars a supplier still holds at **no less than they cost us**. It is now **off by
default** (`fx.book_floor`).

If we refill at 12.42 and the dollar falls to 11.50, the held dollars lost their value the moment it fell, whether we
sell them or not. Holding prices at 12.42 doesn't recover that. It adds a second loss: gift cards are the easiest
product there is to compare, so customers go to shops that refilled at 11.50, and our capital sits frozen at the
supplier.

Accounting treats it the same way: under the **lower of cost or market** rule, when replacement cost falls below cost,
inventory is written down and the loss is booked in that period. You don't wait for customers to pay the old cost.
Importers of hard-to-compare goods can hold old prices until stock sells; a $100 Apple card can't.

So the held dollars' FIFO cost is **reported**, not priced in: the console shows it per supplier as the FX gain or loss.
Capital is protected by **how many dollars are exposed**, not by the price:

- Keep each supplier's balance to about a week of sales. The worst a fall can cost is then that balance × the fall.
  A fall like April 2026 (about 20%) on a $500 float costs about 1,200 LYD. Size the float to what the business
  can absorb.
- When the dollar rises, held dollars gain, because we price at the cost of buying dollars again. Book the FX gains
  and losses as one line and judge them over a quarter. Falls do happen, and they are sharp when the central bank
  intervenes.
- The owner can still switch the floor on (`fx.book_floor: on`).

### The knobs

All of them sit under `fx.*` in the pricing settings. They are stored only once one is set.

| Knob | Default | |
|---|---|---|
| `enabled` | on | `off` returns to live rate + buffer only |
| `premium_source` | learned | `setting` always uses the buffer |
| `premium_max_age_days` / `premium_top_ups` | 60 / 3 | the premium is the median of the latest N top-ups within the age |
| `peak_days` / `fall_percent_per_day` / `release_hours` | 7 / 2 / 24 | the peak and momentum windows may not exceed 30 days, the history read |
| `momentum_days` / `momentum_share_percent` / `cushion_cap_percent` | 7 / 50 / 5 | |
| `book_floor` | off | `on` never prices held dollars below their cost (see above) |
| `shock_percent` | 3 | |

## What was built

- **Ledger.** `relay_supplier_fundings` (migration 50) stores supplier, USD that arrived, LYD paid, method,
  reference, the bank rate that day, note, actor and time. It is append-only: a mistake is voided with a reason.
  - A **reference** (company purchase ids, a bank reference) already named by a top-up still in force is refused,
    so the same USDT purchase can't be counted twice.
  - With no bank rate stored for the top-up's date, the bank rate must be typed (`market_rate`); it is never
    silently left out.
  - Admin routes:
    - `GET /v1/vouchers/admin/fx`
    - `POST /fx/preview` (a quiet write, not audited)
    - `POST /fx/fundings` and `POST /fx/fundings/{id}/void` (both need a passkey tap)
- **Pricing.** `withLiveRate` → `withFX` lays the quote on the settings.
  - Card offers are converted at each supplier's own rate (`USDToLYDFrom`). Airtime, bills and eSIMs use the
    market rate: they have no held-dollar book of their own.
  - Competitor prices are scaled by the **plain live rate** (`MarketScaleRate`), never by our premium, peak or
    cushion.
  - The finance views value dollars at the **replacement** rate (`BookRate`), not the pricing rate.
  - The fade steps by whole hours, so caches keyed on the rate stay warm.
  - The ledger and series are cached for 20 seconds. A top-up recorded on one relay node reaches the others within
    that.
- **Held dollars.** A supplier's held dollars are its live balance plus any top-up recorded after that balance was
  read, matched FIFO to the top-ups. eSIM Access has no balance reader, so it has no held book, but its top-ups
  still teach the premium.
- **Console.** Suppliers → «الدولار والتمويل» shows:
  - The rate step by step, with a 30-day sparkline.
  - Each supplier's held dollars: cost, average, the rate it is priced at, FX gain or loss, and what a $100 card
    sells for.
  - Warnings for a stale feed, a manual rate, a high premium, a shock, and dollars no top-up explains.
  - The ledger, with a void action.
  - «سجّل شحنة رصيد»:
    1. Pick the Binance USDT purchases from «مشتريات الشركة». The dinars fill in; the dollars do **not**, because
       Binance takes a fee (about 1–1.5 USDT) to send them, so you type what actually arrived.
    2. Purchases already recorded can't be picked.
    3. See the before/after preview, then confirm with a passkey tap.

## Rollout

1. Deploy the relay. Migration 47 only adds a table, and the funding-aware rate is on by default with every default
   knob.
   - The settings JSON gains an `fx` block **only when an `fx` knob is set**. Untouched settings stay readable by old
     nodes and the old `ops/pointy-relay`.
   - Before you set any `fx` knob, make sure every node runs the new build and rebuild the CLI (`make relay-cli`).
     Old nodes refuse unknown fields.
   - The CLI's own `vouchers settings show` ladder still prices at live rate + buffer. Trust the console for the
     funding-aware rate.
2. Record the November top-ups in the console:
   - 5 USDT for 54.008 on 11-03
   - 50 USDT for 540.075 on 11-05
   - 120 USDT for 1,296.18 on 11-10

   Enter the dollars that actually arrived at FazerCards, and the bank rate of each day: the North Africa Bank series
   was only switched on 11-26, so its history may not reach back.
3. Leave `usd_rate_buffer_percent` at 7 as the fallback premium. It is not added twice: with `fx` on, the buffer is
   used only when no top-up teaches a premium.
4. From then on, record **every** top-up when it happens.

## Decided (owner, 2026-11-26)

- **The FazerCards subscription** ($3.99–9.99 a month) is a monthly expense recorded in the relay's books (a
  recurring expense in the console's finance), not a markup on cards. It shows in the monthly profit, not in prices.
- **Competitor prices are reference only.** There is no efficient way to collect them, and the October captures are
  out of date. Prices stand on our own costs: replacement rate, peak, cushion and margin. The competitor check stays
  in the code but is inert without fresh data. Competitiveness comes from refilling at the best rate, keeping margins
  honest, and the 10/9/8/8% ladder (a $100 card at about 1,340, inside the 1,300–1,400 the market showed in November). Spot-check a few big cards against the market by hand now and
  then instead.

## Operating rules (owner)

- **Hold the float in dollars, not dinars.** Take shop dinars into USDT as soon as the balance allows. Dinars waiting
  in a till lose value while the dollar climbs.
- **Top up small and often.** Several smaller top-ups average the rate and cap what one bad day can cost. Size each one
  to about a week of sales. This, not a price floor, is what protects capital when the dollar falls.
- **Judge profit in dollars.** A sale earned money only if the dinars it brought buy back more dollars than it used. The
  «ربح/خسارة الصرف» line on each supplier shows exactly that.
- **Watch the central bank.** Devaluations and dollar injections (April 2025, January 2026, April 2026) move the street
  rate by 10–20% within days to weeks. On news of one, hold off refilling until the rate settles. Prices follow the feed on their own.
