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

## 2026-08-20 - The oracle can inherit the backend's model, and then it proves nothing

**Learning:** A short shipment kept billing for goods that never arrived.
``receive_purchase_order`` records ``cancelled_quantity`` — units the supplier
could not supply, or the shop rejected at the door — closes the order as
``received``, and never touches the money: ``balance_due`` and
``Supplier.payable_balance`` still quoted the whole *ordered* total. Nothing
downstream could clear it either, because a supplier return credits
``adjustable_quantity``, which counts *accepted* units, so the phantom payable
was permanent and the payables list carried the row forever. The part worth
recording is why 3500 clean operations never saw it: the simulation *does*
generate cancellations, and ``_assert_po`` asserted
``balance_due == total - paid`` — the oracle had ported the backend's model of
what an order owes rather than deriving it. Both sides agreed, and agreement is
all a tautology ever produces.

**Action:** The rule "never read a number back from the backend" is not enough —
an expectation can be independent in its *arithmetic* and still borrowed in its
*model*. When adding or reviewing an assertion, ask what real-world quantity it
claims (here: "what does the shop owe this supplier?") and derive it from the
transaction inputs, rather than restating the formula the backend happens to
use. A good smell test: if the assertion would still pass after deleting a whole
category of event the simulation generates (cancellations, in this case), it is
describing the code, not the business. Where a number has several backend ports
— ``raw_balance_due``, ``Supplier.payable_balance``, ``prime_supplier_balances``
and the dashboard's row pass are four ports of *one* question — assert the
oracle's figure against each of them; ``_assert_supplier_ap`` now checks the
cold and primed paths against the same independently derived total.

## 2026-08-20 - Inserting a helper above a function steals its decorator

**Learning:** Adding ``purchase_order_cancelled_total`` immediately before
``receive_purchase_order`` put the new function underneath the existing
``@transaction.atomic`` line, so the *helper* became atomic and the receipt —
which writes stock movements, receipt lines, expected-quantity adjustments and
the order's status in one go — silently stopped being. The whole 174-test
purchasing suite passed, because nothing in it forces a mid-receipt failure; a
partial receipt would have half-applied under any real error. That is a worse
money bug than the one the change was fixing, and it came from where the text
was inserted, not from anything the change said.

**Action:** After inserting a top-level function, read the two lines *above*
the insertion point, not just the diff hunk for the new code — a decorator, and
in this codebase that usually means ``@transaction.atomic``, sits on its own
line and belongs to whatever follows it. ``git diff`` shows this clearly: if a
hunk adding a new function opens with an unchanged ``@transaction.atomic``
context line, the decorator has changed owner. Prefer appending after the end of
the function you are working near, and check that the diff contains no
decorator lines you did not intend to move.
