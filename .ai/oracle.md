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

## 2026-08-20 - A preview is a second port of the arithmetic, and it drifts in three places at once

**Learning:** `purchase_preview_line_payloads` re-implements what
`PurchaseOrder.recalculate()` does, because the preview has no order to read
from. Three independent drifts had accumulated in that one function, all
invisible to the document-level totals — subtotal, discount_total and total
agreed in every case:
(1) the zero-weight fallback was applied to the **cost** method only, while the
model's lives in `_landed_cost_allocations` and therefore covers **every**
method — so a retail-value order whose variants are all priced 0.00 (samples, or
stock not priced yet) previewed *no landed cost at all* and then saved with the
whole of it on the lines: 1.00 a unit on screen, 17.67 written;
(2) landed costs were allocated on unpadded `str(index)` keys, and
`allocate_discount_amount` breaks a remainder tie on the key *as a string*, so
"10" sorts ahead of "2" — the manual-discount block three lines above already
padded to `f"{index:06d}"` for exactly this reason, and the landed-cost block
below it did not;
(3) `net_unit_cost` used a bare `.quantize()` (half-even) where the model rounds
that one figure `ROUND_HALF_UP`.
The oracle's own port had drift (1) too, in the same shape — it had copied the
structure of `_landed_cost_weights` (per-method) rather than of
`_landed_cost_allocations` (where the fallback actually sits).

**Action:** Wherever a preview/quote/estimate endpoint exists, treat it as a
*second implementation* and diff it against the writer line by line, not
total by total — every one of these survived because the totals matched. Three
specific things to check on any such pair: which function owns a fallback (a
fallback hoisted one level up in the writer is silently method-specific in the
copy), whether every allocator key sorts in the same order as the writer's
(string keys and integer pks diverge from index 10 onwards, so nothing under 11
lines will ever show it), and whether each `.quantize()` names the same rounding
— Pointy rounds `net_unit_cost` half-up and its neighbours `landed_unit_cost` /
`effective_unit_cost` half-even, so "copy the quantize from the line above" is
wrong half the time. Pointy's other preview surfaces still unaudited on this
axis: `apps/price_checker/pricing.py` (`final_price`) and the POS cart preview.

## 2026-08-20 - Put the API layer under the oracle, but never let it grade itself

**Learning:** The previous entry predicted the simulation was blind to the API
layer; this run closed part of that. `op_purchase_submit` now also POSTs the
same payload to `purchaseorder-discount-preview` and checks the returned lines —
and it found drift (3) immediately, at a seed whose 4000-op sweep had been
clean minutes earlier. The tempting shape is to assert preview == saved order:
it is one line, and it is worthless, because two backend surfaces agreeing says
nothing about either being right (here they would have agreed on drift (1) if
the fallback had been wrong in the model instead of the copy). The assertion is
against `rec`, the oracle's own line costs, computed from the payload's inputs.

**Action:** When adding an API-layer check, assert the response against the
oracle record that already exists for that document, never against the object
the request created. Also: the simulation's own generators bound what any new
assertion can reach — the tie-break drift needed **11+ lines** and the catalog
only had 10 stock items, so widening the world (9 piece products, and a 12%
branch that orders 11+ lines) was a prerequisite for the check, not a garnish.
Before adding an invariant, ask what the generators would have to produce for it
to fire, and widen them in the same change.
