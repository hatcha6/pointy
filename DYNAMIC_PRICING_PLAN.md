# Demand-aware card pricing: plan

Status: **plan only, nothing built.** It builds on the funding-aware dollar rate in `FX_FUNDING_PLAN.md`, which
must be live and trusted first.

## The principle

The dollar rate protects the **cost**. Demand pricing is about **scarcity**: it nudges the price of a card that is
selling far faster than anything explains, while its supply is limited. It is **not** a way to charge more because
people want something.

Three facts shape the design:

- Our customers are shops and app users who compare prices with competitors.
- **68%** of US adults agree dynamic pricing is price gouging (CivicScience, March 2024, around the Wendy's
  backlash; a January 2023 Capterra survey put it at 52%).
- Uber's 2014 agreement with the New York attorney general capped its emergency surge at the normal price range of
  the previous 60 days, **leaving out the three highest-priced days**.

So the uplift is small, slow and capped. It can always be explained in one Arabic sentence, and it never touches
anything essential.

## Scope

| Priced by demand | Never priced by demand |
|---|---|
| International gift cards and game cards (Apple, PSN, Steam, PUBG, Razer, FazerCards keys) | Local dinar cards (Libyana, Almadar, LTT): always sold at face value |
| | Direct airtime and bill payments: essentials |
| | eSIMs |
| | Anything during a holiday or national-emergency flag (the relay already keeps a holidays calendar) |

## Signals (all on data the relay already has)

1. **Demand.** Units sold per item per hour, from `relay_voucher_purchases` plus customer orders, shop and app
   combined.
2. **Baseline.** The median of the same hour of the week over the last 4 weeks. A plain average flags every Thursday
   night and every Eid as a spike.
3. **Spike score.** `z = (actual − baseline) / (1.4826 × MAD)` per item, smoothed over 3 hours. MAD is used instead of
   the standard deviation because one outlier would otherwise mask the next.
4. **Explained?** A spike is explained, and gets **no** uplift, when any of these is true:
   - one of our own promotions is running on the item;
   - the day is a holiday or the first 3 days of the month (salaries);
   - the item is new (under 14 days old);
   - a campaign or push notification went out for it in the last 48 hours.
5. **Scarcity.** The item has one supplier able to sell it, or the supplier's balance covers less than about 2 days
   at the current pace, or BN Plus is holding it (the 30-minute out-of-stock hold).

## The rule

The uplift applies only when **all** of the following hold:

- the item is in scope;
- the spike is **unexplained**;
- `z ≥ 3` for **3 hours running**;
- the item is **scarce**.

The cap is **+3%** of the funding-aware price (at the replacement rate, so it never stacks on the dollar
cushion), rising at most 1 point per 6 hours. When the spike ends, the uplift
fades to 0 within 24 hours.

Nothing here depends on competitor prices: we can't collect them reliably, and the ones captured in October are out
of date. The guard is our own: if more than a third of the items in scope carry an uplift at once, the logic is
reading something other than real scarcity (a payday, an app campaign the calendar missed), so it alerts and stops.

The mirror rule is applied first, because it is easier to sell: an item **with no sale in 14 days** gets up to
**−2%**, never going below the funding-aware cost plus the company's minimum margin. Slow sales are the signal we
can measure ourselves that a price is above the market.

## Where it goes

- **Pure function.** `vouchers.DemandAdjust(item, signals, policy) (percent, reason)`, next to `fx.go`, with knobs
  under `demand.*` in settings (off by default).
- **Hourly job.** A job on the relay writes `relay_demand_signals(item, hour, sold, baseline, z, explained_by,
  scarce, uplift)`. Pricing reads only the latest row, so the sale path stays as fast as it is now.
- **Console.** «الطلب» under Suppliers lists the items with a live uplift or discount, the one-line reason
  («طلب غير معتاد ×4 مع مورد واحد»), and a switch per item to opt it out.
- **Explanation everywhere.** The till's and app's price never says "surge". The console and the audit log keep
  the reason for every change.

## Phases

1. **Observe** (4 weeks): compute signals and show them in the console. Prices do not change. Check that the flagged
   spikes look real to the owner.
2. **Shadow** (2 weeks): log what the price **would** have been, and measure the margin it would have added against
   sales lost (an item's sales falling against its own baseline while the uplift would have been on).
3. **Live, gift cards only**, with the caps above. Review weekly: conversion per item, margin, complaints. If
   complaints rise, turn it off; the switch is one settings field.

## What we should not build

- A per-customer price. The till and app show one price to everyone.
- Raising local cards or airtime. Customers would read it as gouging, and a shop would lose them.
- An uplift larger than the FX cushion. Most of our real risk is the dollar, and `fx.go` already carries it.
