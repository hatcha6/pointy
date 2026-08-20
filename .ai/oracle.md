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

## 2026-08-20 - The unit travels with the line, never with the variant

**Learning:** A purchase *line* knows its unit (`unit`, `unit_factor`,
`to_base_quantity`). A `PurchaseOrderAdjustmentReplacementLine` does not — it is
keyed by variant alone, because a replacement may be a different product
entirely, so `record_purchase_replacement_stock_movements` adds its `quantity`
straight to `quantity_on_hand`. Replacement quantities and unit costs are
therefore **base units, always**. The exchange serializer's like-for-like
default (an exchange posted with no `replacement_lines`) copied the *line's*
pack figures across unconverted: exchanging one carton of 24 took 24 bottles out
and put 1 back, and did it while reporting `outbound 48.00 / replacement 48.00 /
net 0.00`. Every money assertion in the codebase agreed, because the money *was*
right — 1 × 48.00 and 24 × 2.00 are the same number. Only the stock was wrong.

**Action:** When a quantity moves between two models, ask **which of them
carries the unit**. If one has `unit_factor` and the other does not, the one
without it is base-unit by definition and the crossing needs
`to_base_quantity` — and the money is no help in spotting the omission, because
`amount / packs × packs` and `amount / base × base` are equal. The invariant that
*does* catch it is conservation: a like-for-like exchange must leave
`quantity_on_hand` exactly where it found it. Reach for a conservation law
whenever a bug could be unit-shaped; totals are blind to it. Sibling crossings
still worth the same read: `PurchaseOrderAdjustmentLine.unit_cost` (per pack,
matching `adjusted_quantity`/`accepted_quantity`, and consumed by nothing that
wants base units — currently consistent), and the exchange dialog, which asks for
the outbound quantity in packs and the replacement quantity in base units with
nothing on screen saying so.

**Also:** the business simulation models no supplier return, refund or exchange
at all — `PurchaseOrderAdjustment` appears nowhere in it. That is why this, like
the two `purchase_adjustment_line_amount` defects before it, had to be found by
reading. It is the largest remaining hole in the oracle's reach.

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
## 2026-08-20 - A value the simulation supplies is a value nobody is testing

**Learning:** Every sale the simulation rang up called `checkout_order`
directly **and handed it the price to charge** — `effective_unit_price` rides in
on `lines_data`, because that is the service's contract. So the oracle was
asserting that the backend stored the number the oracle itself had just given
it. `unit_sale_price` — the server's own answer to "what does one carton cost",
custom per-unit price or base price × factor — was therefore never under test at
all, in 3500-op sweeps that looked exhaustive. Adding one cent to its
non-base-unit branch and running 300 ops: **clean, no failure**. The same
mutation through the DRF checkout endpoint dies at op#2, because there the
client sends a variant id, a quantity and a unit code, and the server decides
the price. The two entry points also genuinely *disagree* on coupons — the
service silently ignores a coupon that applies to nothing, the serializer
refuses the whole sale (`unapplied_coupon_codes`) — so modelling the API meant
teaching the oracle to predict **which** coupons its engine applied, not merely
what they were worth.

**Action:** Whenever an operation hands the backend a value the backend is
capable of deriving itself, that value is not being verified — it is being
dictated, and every assertion about it is circular. Read each op's payload and
ask which fields a real client would *not* send: `effective_unit_price`,
`unit_factor` and `unit_cost` are all in this category on the sales side, and
the purchasing ops have the same shape. The fix is never another assertion on
the same path; it is entering through the layer that performs the computation.
`op_api_sale` does this for sales; purchasing (`/api/purchase-orders/`) and the
returns/exchange endpoints are the same trade waiting to be made.

**Also:** `_assert_order` checked only the order's three totals, which — per the
2026-08-19 entry on document-level figures — is satisfiable while no line agrees
with them. `_assert_order_lines` now pins each line's unit price, quantity, unit
factor, base quantity and discount against the oracle plus the
`sum(lines) == document` identity. Note it is *not* a blindness the old harness
had entirely: a corrupt line snapshot did surface a few operations later, as a
stock or `amount_paid` divergence on some *other* entity. What the identity buys
is the failure being reported at the operation that caused it, naming the line.

**And a coordination hazard, found resolving this branch's rebase.** Two Oracle
runs independently invented `_assert_order_lines` on the same method name — this
one (price, quantity, unit factor, base quantity, discount, and the
`sum(lines) == document` identities) and #82's (the per-line **cost** basis and
its vacuity counters). They assert disjoint things, so the obvious conflict
resolutions — take HEAD, take mine — each silently delete half the coverage and
leave a suite that is green *and* green for the wrong reason. Nothing in the
test output would have said so. The merged method keeps both, and the clamp
question the two disagreed on resolves in favour of the clamp: `recalculate`
(`apps/sales/models.py`) sets `discount_total = min(sum_of_line_discounts,
subtotal)`, so the unclamped identity would have reported an over-discounted
order as a defect the backend does not have — while `sum(line_total) ==
order.total` is only true *unclamped* and is now guarded accordingly.

**Action:** after any conflict in `business_simulation.py`, do not trust a green
run to prove the resolution kept what was there — a deleted assertion cannot
fail. Mutation-test **one assertion from each side** of the conflict before
pushing (here: a cent added to `unit_sale_price`'s non-base-unit branch for this
side, caught at op#41; dropping `* unit_factor` from `OrderLine.unit_cost` for
#82's, caught at op#203 as `backend=0.40 oracle=9.60`). Losing coverage in a
merge is invisible in exactly the way losing it in a fix is not.

## 2026-08-20 - The ceiling was right, the slope was wrong

**Learning:** `purchase_adjustable_line_value` correctly caps an over-shipped
line's returnable value at what the order *billed* (the surplus units were never
paid for), and `purchase_adjustment_line_amount`'s "last units back" branch
honours that cap. But its **proportional** branch divided `net_line_total` by
the **ordered** count while being charged against the **arrived** count. Ordered
10 at 10.00, supplier ships 12, send 11 back: `100.00 × 11 / 10` = **110.00**
credited on a line the shop was billed 100.00 for — straight past a ceiling that
exists three lines above. The twelfth unit then priced at `100.00 - 110.00` =
−10.00, which `purchase_adjustment_amount` rejects as non-positive, so the last
unit became unreturnable as well. Note this is the *mirror* of the 2026-08-19
short-shipment defect: that one read `line.quantity` where an *accepted* count
authorised the money, this one reads it where an accepted count *divides* it.
The existing over-receipt test asserted only the whole-line return, which takes
the ceiling branch and was always right.

**Action:** a clamp and the formula it clamps are two implementations of the
same intent, and a test that only exercises the clamp proves nothing about the
formula. Whenever a ceiling function exists next to a proportional one, test the
proportional branch *against the ceiling* — `partial ≤ ceiling` and
`Σ partials == ceiling` — not against a hand-computed figure, because a
hand-computed figure is written by whoever also wrote the formula. Pointy still
has this pair shape in `OrderLine.returnable_qty` vs the sales refund
allocation, and in `payable_balance` vs `billable_total`.

**Also — over-receipt is a whole axis the harness never generated.** The
simulation's receive op drew `accepted` from `randint(1, outstanding)`, so
`accepted > ordered` was unreachable and the `accepted_overage` arm of
`_apply_receipt` was dead defensive code. The API derives
`allowed_over_receipt_quantity` itself from whatever the client types, so this
is a one-field receipt away in production. Generators bound assertions: before
believing a money surface is covered, ask which *shipment shapes* the sim can
produce, not only which operations.

## 2026-08-20 - The purchasing side of the simulation has no packs at all

**Learning:** Found while mutation-testing the new supplier-return assertions.
Breaking `record_purchase_adjustment_stock_movements` so returned goods leave in
*packs* instead of base units (dropping `to_base_quantity`) produced **no
failure at any seed** — the exact bug class the 2026-08-20 exchange entry is
about, and the harness is blind to it. The reason: `op_purchase_submit` builds
every `PoLineRec` with `unit_factor=Decimal("1")` and passes no `unit` to
`save_purchase_order_with_lines`. The simulation has *never* bought anything by
the carton. So every pack↔base crossing on the purchasing side — receipts,
returns, `base_unit_cost`, the `expected` stock the order reserves — is
exercised only at factor 1, where the conversion is the identity and a dropped
multiply is invisible. (The *sales* side does model multi-unit lines, which is
why `OrderLine.unit_cost` coverage was reachable.)

**Action:** this is the next extension to make, and it is bigger than it looks —
`op_purchase_submit` must pass a real `unit`, and `expected` stock accounting
(`self.oracle.expected[...] += q3(Decimal(quantity))`, no factor) is already
wrong for anything but factor 1, so it has to move in the same change. Do it on
its own run: it is not a garnish on another change. Until then, treat every
purchasing figure that crosses units as **unproven**, whatever a clean sweep
says.
