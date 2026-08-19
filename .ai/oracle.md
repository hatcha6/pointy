# 🔍 Oracle journal

Critical learnings only. Not a run log, and never a list of seeds.

## 2026-08-19 - Two rounding regimes are fine; letting one answer the other's question is not

**Learning:** The backend rounds money two ways *on purpose* —
`apps.discounts.services.money` is 2dp **HALF_UP** (the discount engine, so a
discount rounds in the shop's favour) and `apps.sales.services.money` /
`Order.recalculate` / `OrderLine.line_subtotal` are 2dp **HALF_EVEN** (the sales
regime, what an order actually stores). Both are correct in their own domain.
The bug class is not the existence of two regimes — it is a value produced in
one regime being used to answer the other's question. `discount_result.total` is
an engine-domain number; three call sites used it as *the amount the customer
tenders*. On a line landing exactly on a half-cent (0.75 × 5.50 = 4.125 → engine
4.13, order 4.12) the order refused the payment it had just demanded and
checkout died with HTTP 400. No discount rule needed to exist — the divergence is
in the subtotal itself, so every weighed/fractional sale on that boundary was
simply unringable.

**Action:** When chasing a money discrepancy, first ask *which regime produced
this number and which regime is being asked about* — a one-cent gap with no
plausible arithmetic error is almost always a regime crossing, not a formula
bug. Grep for engine-domain values (`discount_result.total`, `.subtotal`,
`result.total`) escaping into sales/tender/display code; each one is a candidate.
The fix is never to unify the regimes (the split is deliberate and the oracle
ports both as `even2`/`up2`) — it is to recompute in the *destination's* regime
at the boundary. `apps.sales.services.expected_order_totals` is that boundary for
sales. Still unaudited on this axis: `apps/purchasing/serializers.py` (PO
preview) and `apps/price_checker/pricing.py` (`final_price`), which both still
publish engine-domain figures.

## 2026-08-19 - The simulation is blind to anything the API layer decides

**Learning:** The above bug survived a clean 3500-operation sweep. The reason is
structural: the simulation calls `checkout_order` (the service) directly and
tenders the total *the oracle* computed, which is already in the sales regime —
so it never exercised `OrderCheckoutSerializer.validate`, where the engine's
total was being used to gate payments. The oracle proves the service layer's
arithmetic; it says nothing about the serializer's.

**Action:** A clean sweep is evidence about services, not about the API. When
extending coverage, prefer operations that go through the DRF layer (as the
register open/close ops already do), and treat "which layer does this operation
actually enter through?" as part of the modelling decision. A bug found only via
a new op is worth a *deterministic* regression test at the layer that broke, not
only a pinned seed — the seed reproduces it, the API test explains it.
