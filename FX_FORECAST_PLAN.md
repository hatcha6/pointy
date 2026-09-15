# Exchange-Rate Alerting & Margin Protection — Plan

**Date:** 2026-09-12
**Status:** Proposed. Nothing built. Phase 1 needs no API key and no history.
**Builds on:** [MULTI_CURRENCY_PLAN.md](MULTI_CURRENCY_PLAN.md) Track A, shipped
2026-08-31 — the currency spine, the relay-held fulus.ly feed, per-product
pricing currency, and `PurchaseOrder.currency` with a frozen rate on the buy
side. This plan adds nothing to that spine; it reads it.

**The question that produced it:** *given fulus.ly's full history (~3,088 daily
observations, ~10 years), can we forecast next week's rate and tell a shop what
to reprice to — accurately?*

---

## 1. The answer, and the one substitution this plan makes

**No, not as asked — and the substitution is the whole plan.**

A point forecast of USD/LYD one week out cannot be made accurate. Not with
3,088 days, not with 30,000. §2 gives three independent reasons, none of which
is a matter of model choice or effort. Anything we ship that prints *"the dollar
will be 7.42 next Thursday"* will be wrong often enough to cost shops money in
both directions, and we will have caused the loss.

What can be made accurate is the thing the shop actually loses money on:

> A shop does not go broke failing to predict the rate. It goes broke **selling
> at the rate it bought at and restocking at today's**.

That is a subtraction, not a forecast, and we already hold both numbers — the
rate frozen on the purchase order and the rate published this morning. It is
exact, it is auditable against the shop's own documents, and it is available
today without an API key.

So the deliverable becomes a **ladder**, ordered by how much it speculates, each
rung gated on evidence before it ships:

```
  EXACT                                                          SPECULATIVE
  ═════════▶                                                     ◀═════════

  L0  replacement-cost watch   arithmetic on our own documents   ships alone
  L1  move-in-progress         conditional frequency, stated     gate: ≥25 episodes
  L2  calibrated band          calibrated, not precise           gate: coverage ±5pp
  L3  event overlay            widens the band; never a cause    flags only
      ─────────────────────────────────────────────────────────
  ✗   point forecast           not buildable at any accuracy     §2 — refused
```

The owner-facing number the original question asked for — *"the reference price
this currency is expected to go up to"* — survives, but as **L2's upper
quantile, named for what it is**: a *planning rate* (سعر تسعير آمن), the rate
you can price against and be covered in four weeks out of five. That is a claim
we can keep, measure, and publish a track record for. A prediction is not.

---

## 2. Why a point forecast cannot be made accurate

Four reasons. The first three are fatal independently.

### 2.1 Forty years of failing to beat the random walk

Meese & Rogoff (1983) showed that structural exchange-rate models do not beat a
random walk — *"tomorrow's rate is today's rate"* — out of sample at horizons
under about twelve months. Four decades of attempts with far richer data than
fulus publishes have not overturned it. If a model of ours beats the random walk
by 20% on this series, the correct conclusion is that we overfit, not that we
solved FX.

This does not mean *nothing* is predictable. **Volatility is** — it clusters,
strongly and reliably. Direction and level are not. That asymmetry is precisely
what the ladder is built around: L2 forecasts the *width* of the distribution,
never its centre.

### 2.2 The Libyan parallel rate moves in jumps, and the jumps are decisions

The moves that hurt a shop are not drift. They are step changes, and every one
of them is a decision taken outside the price series:

| Class of event | What it does to the series |
|---|---|
| CBL devaluation / rate unification | One-day step of 5–25%, then a new level |
| Foreign-currency levy introduced or revised | Step, plus a change in the *spread* between instruments |
| Central-bank leadership crisis | Multi-week run, high volatility, partial retracement |
| LC / auction policy change | Regime change in how fast the rate responds |
| Oil shutdown, political escalation | Run, with no fixed reversion level |

None of these is present in the price history *before* it happens. A model fit
on prices learns the **aftermath** of jumps, never their arrival — and the
aftermath is the part the shop has already been hit by.

> Dates and magnitudes for the specific Libyan episodes must be pinned against
> the fetched series and a documented source before they are written into the
> model's documentation or used to label a regime. Do not take them from
> memory — including this document's memory.

### 2.3 The effective sample is about fifteen, not 3,088

This is the one that settles it. 3,088 daily observations is a respectable
sample *for estimating volatility*. But for the thing the question asks about —
the next jump — the sample is the number of **distinct episodes in a decade**:
on the order of ten to twenty.

You cannot fit a jump-timing model on fifteen events. Any backtest that says you
can is reading noise, and it will be a *confident* backtest, because with
fifteen episodes and a handful of features there is always a rule that catches
most of them in hindsight.

Worse, the episodes are not exchangeable: the 2021 unification, the 2024
leadership crisis and the 2025 devaluation have different causes, different
policy regimes and different aftermaths. Treating them as draws from one
distribution is the modelling error, not the modelling technique.

### 2.4 The publication artifacts that will fake skill in a backtest

Even the honest layers will look better than they are unless the series is built
carefully. Four traps, all of which inflate apparent skill:

1. **Stale repeats.** fulus publishes several times a day; an unchanged rate
   re-published is not a new observation. Left in, it manufactures
   autocorrelation, which every momentum rule will happily "discover".
2. **Forward-filled gaps.** Filling a Friday or a holiday produces a zero
   return, which deflates measured volatility and makes every band too narrow.
   Gaps must stay missing.
3. **Bank series treated as market observations.** The thirteen bank series are
   thinner and move on their own administrative schedule. They are not thirteen
   independent looks at one process.
4. **Look-ahead in the vol estimate.** Standardising returns by a
   full-sample volatility is the single most common way a backtest of exactly
   this kind comes out beautiful and fails live.

### 2.5 And the loss is asymmetric in the direction that punishes a guess

Under-price during a real run and the shop sells stock below replacement cost —
unrecoverable, invisible until the next order. Over-price on a forecast that
does not happen and the shop is the expensive one on the street, in a
price-transparent cash market where the competitor is priced off this morning's
rate. Both are real; only the first is silent.

The correct response to an asymmetric loss is **not a better point forecast**.
It is a decision rule over a distribution — which is L2, and which needs
calibration rather than precision to work.

---

## 3. The four layers

### L0 — Replacement-cost watch *(exact; no forecasting)*

**What it says.** Not what the rate will do. What it has *already* done to the
cost of refilling this shelf:

> الدولار اليوم 7.12، واشتريت هذه الأصناف بـ 6.84.
> 23 صنف نزل هامشها تحت 12٪ — 4,180 د.ل من المخزون تبيعه بأقل من تكلفة إرجاعه.

**Where every number comes from.** All of it is already in the database:

```
PurchaseLine.unit_cost_in_currency ──┐
PurchaseOrder.currency               ├──▶ cost basis, at the rate that was frozen
PurchaseOrder.exchange_rate          │     on the supplier's invoice date
PurchaseOrder.rate_effective_at    ──┘

fx.rates.current_rate(...)         ──────▶ what that same basis costs today
StockValuationBin.valuation_rate   ──────▶ what the shelf is carried at
ProductVariant.price_amount        ──────▶ what it is being sold for
StockItem.quantity_on_hand         ──────▶ how many dinars of exposure that is
```

**Two populations, and only one of them is covered today.**

| Population | Covered? |
|---|---|
| **A** — products with `pricing_currency` set | ✅ `catalog/pricing.py::reprice_preview` already produces the drift list |
| **B** — products priced in **LYD** whose *cost* came from a foreign PO | ❌ **nothing sees these.** This is the gap, and it is the larger population |

Population B is the importer who sells in dinars — which is nearly every shop
Track A was built for. Their sell price is local and static; their cost is
foreign and moving. Nothing in the product currently tells them their margin has
been eaten.

**The suggestion restores margin, not the rate.** The proposed price is the one
that returns the **margin percentage the owner had at purchase**, not the old
price multiplied by the rate move. Those differ whenever the item was not priced
at a clean markup, and multiplying by the rate quietly re-prices the shop's
mistakes along with its costs.

**Ranking, so it is a shortlist and not a chore.** Sort by dinars at risk —
`units on hand × (replacement cost − recorded cost)` — with a velocity floor
from recent sales. Two units of a dead line is not an alert.

**The trap.** Costs are stored **per pack**. Every read that reaches a base unit
divides by `unit_factor`, exactly as `base_unit_cost` does. This is the
phantom-loss bug class from the UoM work; it will produce plausible, wrong
dinars if it is skipped anywhere in this path.

L0 is jump-proof by construction: a devaluation nobody predicted still shows up
here the morning after, correctly, in dinars.

### L1 — Move-in-progress *(conditional frequency, not prediction)*

Not *"will it rise"* but *"it is rising, and here is what followed the last time
it looked like this"*:

> USD/LYD is up 2.3% in five days. That has happened 41 times in ten years.
> Seven days later it was higher in 27 of them — median +1.6%, with a
> 10th–90th range of −0.9% to +6.4%.

Every clause is a checkable fact about the data. The uncertainty is in the
sentence rather than hidden behind it. §6.2 specifies the matching, including
the **de-clustering** that stops overlapping windows inflating that "41".

### L2 — Calibrated band, and the planning rate *(the honest "reference price")*

A distribution for the rate at horizon *H*, published as quantiles, from which
the owner-facing planning rate is drawn — not a mean, a **quantile**:

> Price against **7.25** and you are covered in four weeks out of five.
> Our 80% band has contained the actual rate **81%** of the last 200 weeks.

The promise we make is **calibration**, which is measurable and which we publish
a running scorecard for (§5.3). The promise we do not make is precision.

Two design rules that matter more than the model choice:

- **Drift is fixed at zero.** A drift estimated over a decade in which the dinar
  fell would extrapolate that fall forever — right for years, catastrophically
  wrong when policy holds, and it would make *every* week an alert week, which
  is the same as no weeks.
- **The horizon is the shop's, not seven days.** A shop with sixty days of cover
  does not care about a weekly move. `purchasing/suggestions.py::_cadence`
  already returns `(avg_interval_days, interval_cv)` per supplier; the horizon is
  that cadence clipped to [7, 45], and the CV decides whether we trust it.

### L3 — Event overlay *(flags; never a cause)*

Known dates — CBL announcements, holidays via `apps.holidays`, anything on a
published schedule — **widen the band** and raise a *"volatile week"* flag. We
never claim to predict what the event will decide.

One genuinely informative observable belongs here too: **the cash-versus-bank
spread**. Both series are parallel-market (MULTI_CURRENCY_PLAN §4); when they
pull apart, something is happening to settlement itself. That is a measurement,
published as a stress indicator, not a forecast.

---

## 4. Where we start from

| Piece | Today |
|---|---|
| Rate feed | ✅ Relay holds one fulus subscription; webhook + 30-minute polling backstop |
| Rate history in the relay | ◐ Only what has arrived since 2026-08-31. `/rates/history` is known to the client but **never backfilled** |
| Rate storage in Django | ✅ `fx.ExchangeRate`, append-only, on-or-before resolver in `fx/rates.py` |
| Shop's settlement choice | ✅ `ShopSettings.fx_instrument` / `fx_bank_code` / `fx_rate_staleness_hours` |
| Foreign **sell** price | ✅ `Product.pricing_currency` + frozen `price_rate` trio |
| Foreign **cost** basis | ✅ `PurchaseOrder.currency` + frozen `exchange_rate`/`rate_effective_at`; `PurchaseLine.unit_cost_in_currency` |
| Repricing surface | ✅ `reprice_preview` / `apply_reprice` — drift list, select-all, one confirm |
| Margin-at-risk for LYD-priced imports | ❌ **does not exist.** This is L0's population B |
| Alerting surface | ✅ `BusinessNotification` (fingerprinted, deduped) + the AI dashboard digest |
| Entitlement | ✅ `fx_enabled` on the relay, independent of remote access |
| Any forecasting anywhere in the product | ❌ none — `forecast` appears only as a comment about ML *feature* capture |

Two existing decisions constrain everything below, and both are correct:

- **§10b — the till does not reprice reactively.** Labels, the price-checker
  kiosk and verbal quotes all commit to the stored price before the customer
  reaches the counter. Nothing here softens that. Alerts nudge; humans decide.
- **The relay holds one subscription for the fleet.** Backfill and modelling
  therefore happen **once, centrally** — never per shop.

---

## 5. Architecture

### 5.1 The split

```
   ┌────────────────────────── RELAY (one subscription, one model) ─────────────┐
   │                                                                            │
   │  /rates/history  ──▶ backfill (quota-budgeted, one time)  ──▶ rate store    │
   │                                                                │           │
   │                       daily series · dedupe · holiday gaps  ◀──┘           │
   │                                    │                                       │
   │                       EWMA vol ──▶ filtered historical simulation           │
   │                                    │                                       │
   │                       episode matcher (L1) ──┐                             │
   │                                              ▼                             │
   │                                   ┌──────────────────────┐                 │
   │                                   │  RATE OUTLOOK doc    │  per pair ×      │
   │                                   │  quantiles · vol ·   │  instrument      │
   │                                   │  episodes · scorecard│                  │
   │                                   └──────────┬───────────┘                 │
   └──────────────────────────────────────────────┼─────────────────────────────┘
                                                  │ rides the EXISTING pull
                                    GET /v1/exchange-rates?since=…
                                                  │
   ┌──────────────────────────────────────────────▼─────────────────────────────┐
   │                        SHOP (Django) — where the dinars are                │
   │                                                                            │
   │   fx.RateOutlook  ──┐                                                      │
   │                     ├──▶ margin-at-risk engine ──▶ ranked list + prices     │
   │   POs · valuation ──┘            │                                         │
   │   bins · stock · sales           └──▶ BusinessNotification · digest card    │
   └────────────────────────────────────────────────────────────────────────────┘
```

**Why the model sits on the relay.** The rate process is identical for every
shop in the fleet; fitting it per installation would be the same arithmetic run
N times on N copies of the same series, on hardware that is also running a till.
The margin arithmetic is the opposite — it needs *this* shop's purchase orders
and stock — so it stays local.

**Why no new transport.** The outlook document is served by the endpoint shops
already poll. No push down the connector tunnel, no new schedule, no new
failure mode. Same reasoning as the rate feed itself.

### 5.2 The model runs in Go, with no fitting at runtime

EWMA volatility with a fixed λ requires no estimation — it is a recurrence. FHS
is standardise, resample, rescale. Together that is arithmetic the relay can do
in ~150 lines of dependency-free Go.

λ, the horizon set, the episode buckets and the quantile grid are **chosen
offline** by the Python validation harness (Phase 2) and baked in as constants
with the backtest that justified them. This keeps the relay free of a numerical
stack, keeps the model reproducible, and makes every parameter traceable to the
run that picked it. If a parameter ever needs to change, that is a code review
with a backtest attached — not a silent refit.

### 5.3 Schema

**Relay** — `rate_outlooks`, one row per (from, to, instrument, bank, horizon):

```
computed_at · horizon_days · q05 q25 q50 q75 q95 · spot_at_compute
vol_ewma_daily · vol_regime (calm|elevated|stressed)
episode_stats  JSON  — n, n_up, median_fwd, p10, p90, declustered
calibration    JSON  — trailing coverage at 50/80/90, n_scored, as_of
flags          JSON  — L3: known dates in window, cash/bank spread z
```

**Django** — two models in `apps.fx`:

- `RateOutlook` — the synced mirror, same reconciliation rules as holidays and
  rates: relay writes, local never edits, unreachable relay is a soft no-op.
- `RateAlert` — **the honesty ledger.** What we said, when, for which horizon,
  the quantiles as published, and — once the horizon closes — what actually
  happened and whether the band held. Append-only, same spirit as `ExchangeRate`.

**Notifications** — add `BusinessNotification.Category.FX`. Fingerprint on
`(code, currency, instrument, iso-week)` so a rate that moves all week produces
one row with a rising `occurrence_count`, not fifty rows. Generated on a Celery
beat, **never computed inside a GET** — that was a named finding in the 2026-06
performance audit and it is not to be re-introduced here.

### 5.4 What the owner actually sees

| Surface | What lands there |
|---|---|
| Dashboard card | L0 headline: dinars of margin at risk, item count, one tap to the list |
| The existing drift list | Gains population B, plus the planning rate as an optional basis |
| Rates screen (Settings) | The band, the vol regime, and **the calibration scorecard** |
| `BusinessNotification` | One row per episode per currency, severity by dinars at risk |
| AI daily brief | One sentence, generated from the same figures — never its own opinion |

---

## 6. The statistics, specified

### 6.1 Building the series

- One observation per instrument per day: the **last print before a fixed local
  cutoff**, per (pair, instrument, bank).
- Drop consecutive identical prints — a re-publication is not an observation.
- Gaps (weekends, holidays via `apps.holidays`, feed outages) stay **missing**.
  No forward-fill, ever. Returns are computed across the gap with the gap's
  length recorded, so a three-day return is never read as a one-day move.
- Log returns throughout.
- **No winsorising.** The jumps are the subject, not contamination. Robust
  estimators (MAD, bipower variation) keep one jump from permanently inflating
  the volatility state instead.
- Cash and each bank are separate series. Never pooled.

### 6.2 L1 — episode matching

Features, all computable at time *t* from data strictly before *t*: 3/5/10-day
returns, EWMA vol relative to its own one-year median, cash-bank spread z-score,
distance from the 60-day high.

Matching is bucketed, not nearest-neighbour — with fifteen regimes in the
sample, a clever distance metric is a way to find fifteen matches that are
really one.

**De-clustering is mandatory.** Overlapping trigger days inside one episode are
collapsed to a single observation. Without it, a three-week run contributes
fifteen "independent" cases and the reported confidence is fiction. Confidence
intervals come from a **stationary block bootstrap** (mean block ≈ 20 days), not
from an i.i.d. resample.

**Gate:** an episode statement is publishable only with **≥25 de-clustered
episodes** and a bootstrap CI on the median forward move that excludes zero. Any
bucket that fails says so and shows nothing.

### 6.3 L2 — the band

- **Level:** random walk, **drift ≡ 0** (§3, L2).
- **Scale:** EWMA, λ ≈ 0.94 as a starting point, validated against GARCH(1,1)
  with *t* errors on out-of-sample pinball loss. The simpler one wins ties.
- **Shape:** filtered historical simulation. Standardise historical *H*-day
  returns by the volatility that was current *at the time*, pool the residuals,
  resample, rescale by today's vol forecast. This preserves the fat tails and
  the jump asymmetry that a normal assumption throws away — and it is what makes
  the upper quantile honest rather than optimistic.
- **Output:** q05 / q25 / q50 / q75 / q95 at each horizon in {7, 14, 30, 45}.

### 6.4 The planning rate

`planning_rate = Q_q(H)`, where *H* is the shop's restock cadence and *q*
defaults to **0.75** — protection in three weeks out of four, tunable per shop.

It is labelled in the UI as a planning rate with its horizon and its coverage
stated beside it. It is never called a forecast, never rendered as a single
number without its band, and never applied automatically.

---

## 7. Validation, and the gates that decide whether L1/L2 ship at all

The harness is Phase 2 and it lands **before** the model it validates: a
self-contained `tools/fx-backtest/`, laid out like `tools/dump-analysis/` —
README, a series library, a runner. Python, numpy only.

**Protocol.** Walk-forward, expanding window, three-year burn-in, parameters
re-selected every four weeks using only data up to that point. Nothing after
*t* is visible at *t*, including the volatility state.

**Benchmarks.** Level: the random walk. Interval: the **unconditional
historical quantile** — the last ten years of *H*-day returns, ignoring current
conditions. That second one is the benchmark that matters, because it asks the
only question worth asking: *does conditioning on today's volatility beat not
bothering?* If it does not, L2 is a worse version of a lookup table and should
not ship.

**Metrics.** Theil's U for the level (reported honestly; ≈1.0 is the expected
and acceptable answer). PIT histogram, coverage at 50/80/90, and pinball loss at
every published quantile for the band.

**Ship gates:**

| Layer | Gate |
|---|---|
| L1 | ≥25 de-clustered episodes per published bucket; bootstrap CI on the median excludes zero |
| L2 | Pinball loss beats the unconditional benchmark by **≥10%**, and coverage is within **±5pp** of nominal over the last three years |
| L2, again | Coverage within **±8pp** on the highest-volatility decile **and** on each major episode window evaluated separately |
| L0 | No statistical gate. It is arithmetic; it is gated by tests against the oracle's own figures |

That third gate is the one that will hurt, and it is the one that matters: a
band calibrated only in calm weeks is worse than no band, because it will be
narrowest exactly when it is about to be wrong.

**The decision-level check.** Replay the alert rule over a real shop's purchase
and sales history and report **two separate numbers**: dinars of margin
protected, and days spent priced above the market. We do not know any shop's
price elasticity and will not invent one to collapse those into a single score.
The owner sees the trade; the owner makes it.

**And after it ships:** every alert is scored when its horizon closes, into
`RateAlert`. The calibration scorecard is public in the UI. If trailing 26-week
coverage drifts more than 10pp from nominal, the feature **demotes itself to
L0** and says so, rather than waiting for someone to notice.

---

## 8. Phasing

| Phase | Scope | Effort | Needs the key? |
|---|---|---|---|
| **1 — L0 replacement-cost watch** | Margin-at-risk engine over population B; margin-restoring price suggestion; ranking with velocity floor; `Category.FX` notification; dashboard card; drift list extended | ~1 wk | **No** |
| **0 — History backfill** | Paginated `/rates/history` sweep under an explicit quota budget, one time, stored on the relay forever; daily series construction; dedupe; holiday-aware gaps | ~3 d | Yes |
| **2 — Validation harness** | `tools/fx-backtest/`: walk-forward, PIT/coverage/pinball, episode de-clustering, the gate report. **Produces the decision on whether Phase 3 ships** | ~3 d | after Phase 0 |
| **3 — L1 + L2 on the relay** | EWMA + FHS in Go, episode matcher, outlook document, served on the existing pull; Django `RateOutlook` sync | ~1 wk | — |
| **4 — Delivery + honesty ledger** | Band and scorecard on the rates screen; planning rate as an optional repricing basis; `RateAlert` scoring; auto-demotion | ~4 d | — |
| **5 — L3 overlay** | Known-date widening via `apps.holidays`; cash-bank spread stress flag | ~2 d | — |

**Total ≈ 3.5 weeks**, of which the first week ships standalone value and the
next six days decide whether the remaining two weeks are worth spending.

Note the ordering: **Phase 1 before Phase 0.** L0 needs no history, no backfill
and no API key — it reads rates we already store and documents we already wrote.
It is also the layer with the largest share of the value. There is no reason for
it to wait behind a data-acquisition task.

---

## 9. Anti-goals

1. **No point forecast, ever shown to an owner.** No *"the dollar will be
   7.42"*. If a surface cannot show the band, it shows nothing.
2. **No drift term.** §3. A fitted drift turns a decade of devaluation into a
   permanent prediction of more.
3. **No auto-repricing.** §10b of the currency plan settled this: labels, the
   kiosk and verbal quotes commit to the stored price first. If staleness proves
   to be a real field problem, the next step is the *opt-in nightly* reprice
   already described there — not anything in this document.
4. **No per-shop model fitting.** One fleet model on the relay. A till does not
   run a bootstrap.
5. **No alert without dinars attached to real stock.** A rate move with no
   exposure behind it is a number, not a notification.
6. **No official CBL rate.** We carry settlement instruments, not markets. If an
   official rate is ever wanted it is a different source with a different
   meaning.
7. **No blocking, no guessing on a stale feed.** Past
   `fx_rate_staleness_hours`, the band is withheld and says why. Silence, not
   extrapolation.
8. **No ML framework.** numpy in the offline harness; arithmetic in the relay.
   Nothing in this plan needs more, and a dependency that is only justified by
   ambition is a dependency that will be justified by nothing.
9. **No claim of event prediction.** L3 flags scheduled dates. It never implies
   we know what will be decided on them.

---

## 10. Risks

| Risk | Mitigation |
|---|---|
| **An owner reads a band as a promise** | No point number anywhere; the horizon and the coverage are rendered beside the rate; the scorecard is visible, including when it is unflattering |
| **Crying wolf** | One notification per currency per episode per week, fingerprinted; a dinars-at-risk floor; severity scaled by exposure, not by the size of the rate move |
| **`/rates/history` does not reach ten years on our plan** | **Verify before Phase 0 is scheduled.** The ladder degrades gracefully: L0 is unaffected, L1's gate simply fails on thin buckets and publishes nothing |
| **Backfill burns the daily quota and blinds the live feed** | One-time, paginated, explicitly budgeted, resumable, run off-peak; the poller already parks on a 429 until the reset, and the backfill must respect the same budget rather than compete with it |
| **The backtest is beautiful and the model fails live** | Walk-forward only; the unconditional-quantile benchmark; the crisis-window gate; and the post-ship scorecard with automatic demotion |
| **A policy jump the week after we publish "calm"** | Stated in the UI: the band covers market movement, not policy decisions. L0 catches the jump the next morning regardless — which is why L0 is the headline and L2 is the accessory |
| **Reputation: a shop follows the planning rate into lost sales** | It is a quantile, labelled, with a track record, never auto-applied, and every price passes through the owner's existing confirm step |
| **UoM phantom loss in the cost path** | Every base-unit read divides by `unit_factor`; a test asserts the L0 figures against a pack-priced product specifically |
| **Notification recomputation on GET** | Celery beat writes; the endpoint reads. The 2026-06 audit finding does not get re-introduced |
| **Model constants drift silently** | λ and the buckets are constants in the relay with the backtest run that chose them cited beside them; changing one is a reviewed change |

---

## 11. Recommendation

**Build Phase 1 now.** It needs no API key, no backfill and no model. It closes
a real hole — an importer selling in dinars currently has *nothing* telling them
their margin has been eaten — and it is exact, so it can never embarrass us.

**Then Phase 0 and Phase 2, and let the gate report decide the rest.** If the
band cannot be calibrated through a crisis window, L2 does not ship, and that is
a successful outcome for six days of work: we will have established, with our
own data, that the feature we were asked for is not available at the accuracy
its user needs — instead of shipping it and finding out through a shop's losses.

If it does calibrate, L1 and L2 ship as what they are: a statement about how
wide the next few weeks could be, with a planning rate the owner can price
against, carrying its own track record on the same screen.

The line worth holding on to:

> **The shop does not need to know what the dinar will do. It needs to know what
> the dinar already did to the cost of refilling that shelf — and that is not a
> forecast, it is a subtraction.**
