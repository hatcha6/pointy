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

## 2026-08-19 - A document-level number that never reaches the lines

**Learning:** `PurchaseOrder.extra_discount_amount` (the manual "knock it off the
whole order" discount) was folded into `discount_total` and `total` but never
allocated to the lines. The *money* was therefore right — the balance, the
supplier payments, the receipt — and every existing test agreed, because they all
asked the order. What was wrong was the **cost basis**: `net_line_total` and
`effective_unit_cost` kept quoting the pre-discount cost, so margins were
understated, the purchase-history cost chart was inflated, and
`purchase_adjustment_line_amount` credited a supplier return at more than the
shop ever paid for those units. Discovered by reading, not by a sweep, because
the simulation created purchase orders with neither landed costs nor a manual
discount.

**Action:** For any document that carries both an order-level figure and lines,
the invariant to reach for first is not "is the total right" but **do the lines
add up to the total** — `sum(effective_line_total) == total`,
`sum(line.discount_amount) == discount_total`. An order-level adjustment that
skips the lines passes every total-shaped assertion and fails only this one.
Pointy has more documents of this shape (`Order` + `OrderLine`,
`PurchaseOrderAdjustment` + its lines); each is worth the same two-line identity.
Note the two allocators that both spread money over purchase lines and are NOT
interchangeable: `apps.discounts.services.allocate_discount_amount` filters
zero-weight keys and breaks ties on the *string* key, while
`PurchaseOrder._landed_cost_allocations` keeps them and breaks ties on the
*integer* pk. The oracle ports them separately on purpose — collapsing them would
hide a real divergence between the PO preview and the PO that gets saved.

## 2026-08-19 - The quantity a document was written for is not the quantity it can credit

**Learning:** `purchase_adjustment_line_amount`'s "these are the last units"
branch handed back `line.net_line_total` — the discounted value of the whole
**ordered** line — while the units it is allowed to send back
(`adjustable_quantity = accepted - adjusted`) are only the **accepted** ones.
The two are equal on a fully-received order, which is every test the codebase
had and every case the simulation generates, so the defect was invisible. On a
short shipment (ordered 10, received 4) returning the 4 minted a 100.00 supplier
credit for 40.00 of goods, and — because an exchange with no explicit
replacement prices values incoming stock at `amount / quantity` — walked the
replacements back in at 25.00 a unit instead of 10.00. Note the *proportional*
branch was already right (`net_line_total × q / ordered` is the correct per-unit
share); only the ceiling was wrong. Related but deliberately left alone:
`payable_balance` still bills the full ordered total on a short shipment.

**Action:** Whenever a per-line money figure is gated by one quantity
(`adjustable_quantity`, `returnable_qty`, `outstanding_quantity`) but computed
from another (`line.quantity`), the two are a bug waiting for the first document
where they diverge — and "fully received / fully delivered" is exactly the case
every fixture picks, so the divergence never shows up by accident. Grep for
money that reads `line.quantity` and ask which quantity actually authorises it.
The same pairing exists on the sales side (`OrderLine.returnable_qty` vs
`line.quantity`) and is worth the same read. Also: a partial-receipt path is
reachable two ways — left open (`partially_received`) or closed by cancelling
the remainder (`received`) — and a fix must cover both, since only the second
looks "finished".

## 2026-08-19 - An unreceived line is not a returnable line

**Learning:** Tightening the credit ceiling to the accepted quantity broke one
existing test that computed a return credit on an order it had never submitted
or received — it now (correctly) got 0.00. The test was not wrong about its own
invariant, only about its shortcut: production's
`validate_purchase_order_adjustment_allowed` refuses any adjustment outside
`partially_received`/`received`, so the state it exercised is unreachable.

**Action:** When a purchasing test needs a line that can be *returned*, receive
the order first (`submit_purchase_order` then `receive_purchase_order`) rather
than asserting against a draft. A draft order is fine for testing totals and
allocation; it is not a valid fixture for anything downstream of receipt. The
same trap will catch the next tightening of a receipt-gated figure — when such a
change breaks an old test, check whether the fixture is in a state production
would ever allow before concluding the change is wrong.

## 2026-08-19 - The oracle proved every number on a sale except what it cost

**Learning:** `_assert_order` checked six order-level figures and not one line.
The sales side therefore had *no* cost coverage at all: `OrderLine.unit_cost` —
the COGS snapshot every margin, every profit report and `returned_cost_total`
are computed from — could be arbitrarily wrong and every assertion in a
3500-operation sweep would still pass, because revenue never touches it. The
chain is three hops, each with its own chance to go wrong: newest non-cancelled
purchase line → `base_unit_cost` (per *base* unit, the raw price divided by the
purchase's own `unit_factor`) → `× the sale's unit_factor`. Dropping that last
multiply is the phantom-loss bug class in its purest form, and nothing in the
harness would have noticed. Two modelling points that are not guesses: the cost
is the *raw* purchase price, deliberately not the landed/discounted
`effective_unit_cost`; and a purchase moves the cost basis the moment its lines
exist, before receipt — only CANCELLED drops out.

**Action:** When a record carries both a *price* and a *cost*, assume the cost
is unproven until you have checked it explicitly — revenue assertions cannot
reach it, so it fails silently and forever. The general shape: any field that
only ever feeds *reports* (cost, margin, popularity, rank) is invisible to a
harness built around what the customer paid. Mutation-test any new assertion
before believing it (break the backend, confirm the sweep dies) — and when the
expectation can legitimately be zero, count how often it was non-zero and make
the entry-point test refuse a run that never saw a real value, or the coverage
is decorative. Still unmodelled on this axis: `returned_cost_total`'s DB-side
`Sum(quantity * unit_cost)`, whose rounding may differ between sqlite and
Postgres, and the production-cost fallback (`latest_production_unit_cost`) for
goods that are made rather than bought.
