# Bolt's Journal ⚡

Critical performance learnings for the Pointy codebase. Not a log — only insights
that change future decisions.

## 2026-08-18 - Composite balance properties silently multiply per-row query cost
**Learning:** `Supplier.net_balance` is `payable_balance - credit_balance`, and
each of those is a Python `@property` that runs its own aggregate queries. Each
was *individually* batched (a good first-pass optimization visible in the code
comments), so it looked already-tuned. But serializing one supplier reads all
three fields → `payable_balance` (2 q) + `credit_balance` (1 q) + `net_balance`
(re-runs BOTH, 3 more q) = 6 queries/row. A 50-row `supplier-list` page = 303
queries; the annotations in `SupplierViewSet.get_queryset` only cover
`total_bought`/`purchase_count`, NOT the balance properties. This N+1 hid behind
"already batched" property internals and a composite property that recomputes its
parts. Same shape reached the purchasing dashboard/report (`_purchasing_summary_report`).
**Action:** When a serializer exposes property-backed money/aggregate fields,
count queries at the *page* level (CaptureQueriesContext with a scaling test),
not per-property. Fix with a `prime_supplier_balances`-style bulk primer +
`ListSerializer.to_representation` hook that sets `_<field>` cache attrs the
properties read first — keeps the property arithmetic as the single source of
truth (primed & cold always agree) instead of duplicating it in an annotation.
Watch for composite properties (`net = a - b`) that re-invoke their parts.

## 2026-08-18 - DRF PrimaryKeyRelatedField is the per-line query floor

**Learning:** Every document API here (checkout, PO create, both discount
previews) takes its lines as `PrimaryKeyRelatedField(queryset=...)`, and DRF
resolves each one with its own `.get(pk=...)`. That is a hard 1 query/line floor
that `select_related`/`prefetch_related` on the field's queryset **cannot**
remove — a `.get()` on a prefetched queryset just runs the prefetch for that one
row, which makes it *worse*. Worse still, those instances arrive bare, so any
later `variant.product`, `product.categories`, or `variant.display_name`
(option_values) read costs another query *each, per line* — the shape that made
purchaseorder-discount-preview 4 queries/line in field telemetry.

**Action:** Don't try to fix these by decorating the related field's queryset.
Bulk-reload after validation instead: `catalog.services.preload_line_variants`
(`in_bulk` + `select_related("product")` +
`prefetch_related("option_values__option", "product__categories")`) swaps
enriched instances into `lines_data`. Call it at the top of any line-based
`validate()`/service. Pair it with `product.categories.all()` — `.values_list()`
silently bypasses the prefetch and re-queries.

## 2026-08-18 - The Redis preview guard only covers the sales channel

**Learning:** `apps/discounts/cache.py::preview_with_cache` (active-rules gate +
per-cart memo) is written channel-generically — the digest already carries
`supplier_id` and `bump_rules_version` already drops the PURCHASING gate — but
only `apps/sales/services.py::preview_sales_discounts` calls it. The purchasing
preview calls `DiscountEngine().calculate()` straight, so a shop with zero
purchasing rules still pays the full engine pass on every PO line edit.

**Action:** Wiring purchasing's preview through `preview_with_cache` is the
obvious next win (~6 queries + the engine's CPU per keystroke for the common
no-purchasing-rules shop). Left out of the N+1 PR to keep the change one thing.
**Done 2026-08-18** — but the ~6-query estimate was wrong; see below.


## 2026-08-18 - A preview memo pays off on the edits that DON'T change the result

**Learning:** Two corrections to the estimate above, both from measuring rather
than reasoning. (1) The no-rules engine pass is **1 query, not ~6**: the engine's
rule scan is `.filter(is_active=True).prefetch_related(...)`, and Django skips
every prefetch when the base queryset comes back empty — so the active-rules gate
buys the engine's Python pass plus a single query, not a query storm. (2) The
real query win is the *per-cart memo on the with-rules path* (7 queries: rule
scan + 5 M2M prefetches + the tier read), and it lands because the PO editor
fires `refreshDiscountPreview()` from 13 undebounced sites — three of which
(`updateLandedCosts`, `updateLandedCostAllocationMethod`, `updateExtraDiscount`)
change a field that is **not in the digest**. Those are guaranteed hits: the
discount cannot have changed, yet the whole preview re-POSTs.

**Action:** When sizing a preview cache here, count the callers whose changed
field is outside the digest — that population is the hit rate, and it is much
more predictive than "shop has no rules". Also: don't estimate a saved query
count from the number of `prefetch_related` calls; an empty base queryset makes
them free. Measure with `CaptureQueriesContext` around a *second* request (the
first warms the gate, permissions and content types) or the numbers lie.

## 2026-08-18 - Mutation endpoints serve their response from a BARE object

**Learning:** Every lifecycle action on `PurchaseOrderViewSet` (submit, receive,
cancel, return/refund/exchange, pos-cash-purchase) handed the *detail* serializer
an object with no prefetch cache, so the response payload N+1'd over every line,
receipt line, adjustment and variant. Two ways it happens, both invisible at the
call site: (a) the service layer returns `select_for_update().get(pk=...)` —
`receive_purchase_order` returns its **locked** order, not the `get_object()` you
passed in; (b) `purchase_order.refresh_from_db()` **clears
`_prefetched_objects_cache`**, so an object that arrived prefetch-rich from
`get_object()` is bare by the time it is serialized. Measured: the *response
alone* was 495 of the 920 queries on a 20-line receive. This is the identical
shape as the sales-checkout fix (`self.get_queryset().get(pk=...)`), so treat it
as systemic: any POST that returns a detail payload is a suspect.

**Action:** For a mutation response, re-read through the class-level queryset
(`self.queryset.get(pk=...)` — NOT `get_queryset()`, whose list-only
`?product=`/`?variant=` filters can filter the just-mutated order out of its own
response). And when auditing, measure the service and the serialization
*separately* — one `CaptureQueriesContext` around the endpoint hides which half
is bleeding, and here they were nearly 50/50.

## 2026-08-18 - `previous_unit_cost_value` is an annotation that no longer exists

**Learning:** `PurchaseLineSerializer._previous_base_unit_cost` reads an
annotation `previous_unit_cost_value` "the list views annotate" and falls back to
a per-line `latest_purchase_line_for_variant()` lookup. Nothing annotates it any
more — `git log -S` shows it was added for the PO list (3b6d77dc) and removed
when the list stopped serializing lines at all (59e789f8, line_count only). So
the fallback is now the *only* path, and it costs exactly 1 query per line on
every PO detail read. It survives review because the comment reads like the fast
path is live.

**Action:** This is the last per-line query on `purchaseorder-detail` (measured
slope 1.0 q/line after the prefetch fix). Fixing it means a `Prefetch("lines",
queryset=...annotate(previous_unit_cost_value=Subquery(...)))` on the detail
queryset whose subquery must reproduce `latest_purchase_line_for_variant(
variant_id, before_line=line)` ordering exactly — real correctness risk (it
drives the "cost changed" flag), so it deserves its own change with its own
value-equality test, not a ride-along. Generally: a `getattr(obj, "x", MISSING)`
optimization hook is dead code the moment its annotator moves — grep for the
annotator, don't trust the comment.
**Done 2026-08-18** — but not with a Subquery of the *value*; see below.

## 2026-08-18 - Batch a money lookup by subquerying the ROW ID, not the value

**Learning:** The obvious way to kill the `previous_unit_cost` N+1 was to
annotate the previous line's cost in SQL — and that means re-expressing
`unit_cost / unit_factor` (with its `factor <= 0` guard, its full-precision
no-quantize rule and its NULL handling) as a database expression, i.e. a second
copy of money arithmetic that can silently disagree with the Python one and flip
the "cost changed" flag. Annotating the previous line's **pk** instead
(`Subquery(...values("pk")[:1])`) plus one `in_bulk` reload is still O(1) — two
queries for the whole order — but the arithmetic stays in the one Python helper
both paths call, so primed and cold cannot drift. The subquery only has to
reproduce the *selection* rule, which is testable by value-equality; I verified
the test has teeth by flipping the ordering to ascending and watching it fail.
Two other things worth knowing: `created_at` is `auto_now_add`, so
`created_at__lt=OuterRef("created_at")` already excludes the row itself and the
`exclude(pk=...)` is redundant; and `in_bulk([])` short-circuits, so an order of
first-ever purchases costs one query, not two.

**Action:** Prefer id-subquery + bulk reload over value-subquery whenever the
value is money or otherwise carries business arithmetic. Gate the primer on
`len(rows) > 1` — a 2-query primer is a *regression* on a 1-line payload where
the cold lookup is 1 query. Measured: `purchaseorder-detail` on a 20-line order
43 -> 25 queries (1.0 -> 0.05 per line); receive 467 -> 449.

## 2026-08-18 - Raw-column annotations are the third option, and they are free

**Learning:** The entry above chose id-subquery + `in_bulk` over a value
subquery, for the right reason (money arithmetic must not exist twice). But it
framed the choice as two options when there are three: annotating the previous
row's **raw columns** (`unit_cost`, `unit_factor`) keeps the arithmetic in Python
just as well as an id does, and costs *zero* queries when the rows are already
being read from a queryset we control — the PO detail tree prefetches `lines`
regardless, so the subqueries ride along inside a query that was going to run.
Two facts made the primer look better than it is: `prime_previous_unit_costs`
runs once per `to_representation`, so on `supplier-purchase-history` (the detail
serializer over a whole *page* of orders) it pays its 2 queries **per order**,
not per page; and the `len(rows) > 1` guard means a 1-line order still goes cold.
Both disappear when the annotation is present. Measured on the same fixtures:
detail 25 -> 23, `supplier-purchase-history` (10 orders x 5 lines) 48 -> 28.

**Action:** Keep both. The primer is the general safety net for callers that hand
the serializer bare rows (create responses, `PurchaseLineViewSet`); the
annotation is the hot path. Wire them so the primer *fills from the annotation
first* and only batches what is left — one cache, one arithmetic implementation,
and the cost rule ("is batching worth a query?") lives in the primer rather than
in its caller. And when judging a per-payload primer, check whether the payload
nests: a per-order cost multiplies by page size somewhere.

## 2026-08-18 - A `Prefetch` with a queryset must precede its own `lines__…` strings

**Learning:** `PurchaseOrderViewSet.queryset` prefetches `lines__variant__product`,
`lines__receipt_lines`, … as strings. Adding `Prefetch("lines", queryset=...)`
**after** them raises `ValueError: 'lines' lookup was already seen with a
different queryset` — the string lookups claim `lines` with a default queryset as
they are processed, and the first lookup to claim it wins. Put the Prefetch
first and the nested string lookups traverse through it, annotation intact.

**Action:** Any future "annotate the lines prefetch" change here goes at the TOP
of the `prefetch_related(...)` list. Also worth knowing: `prefetch_related(None)`
in the list path clears it, so list payloads never pay for detail-only
annotations.

## 2026-08-18 - `supplier-purchase-history` serializes the DETAIL payload per page

**Learning:** While measuring the detail fix I found `SupplierViewSet.purchase_history`
reuses `PurchaseOrderViewSet.queryset` with the full `PurchaseOrderSerializer`
over a *paginated page of orders* — so every per-line cost on the detail screen
is paid ~N_orders times there. Measured on 10 orders × 5 lines: 78 → 28 queries
from the same one-line annotation (50 removed, 64%). Detail-path optimizations
here are worth roughly a page-size multiple more than they look.

**Action:** When sizing a `purchaseorder-detail` serialization win, check
`purchase_history` too — it is the same serializer at page scale, and it is easy
to miss because it lives on `SupplierViewSet`, not the PO viewset.

## 2026-08-19 - Check whether the payload is READ before making it fast

**Learning:** `select_related("variant__product")` looks like the right tool for
a serializer that renders `source="variant.product"` — but when the *same*
product repeats across rows it re-materializes a separate Python instance per
row, so every nested prefetch the embedded serializer needs is impossible and
every property-aggregate reruns. `Prefetch("variant__product", queryset=...)` on
the same forward FK does the opposite: one `pk__in` query, one instance per
distinct product, shared by every row that points at it, and the inner queryset
can carry both `annotate()` and the whole nested `prefetch_related` chain.
Measured on `stock-movements/?product=X` (the shape the Flutter client actually
requests — a page of movements for ONE product): 8 rows went 187 -> 16 queries,
and adding 7 more movements of the same product used to cost 161 extra queries
(26 -> 187) and now costs zero. The generic distinct-product case was 23
queries/row -> 0. (That endpoint ultimately shipped a different fix — see the
last paragraph — but the technique stands for any embedded serializer that has
to stay.)

**Action:** When an embedded serializer hangs off a forward FK whose values
repeat down the page (`variant.product`, `line.supplier`, `payment.customer`),
reach for `Prefetch` on that FK, not `select_related`. Two things make it work:
the inner queryset is rooted at the related model, so the nested serializer's own
prefetch list composes straight in; and a `.aggregate()`-backed property
(`Product.quantity_on_hand`)
that no prefetch can ever satisfy is killed by annotating the SAME name the
serializer already checks (`stock_quantity_on_hand`) on that inner queryset —
no new code path, and a payload-equality test against a cold instance proves
primed and cold agree.

**But the prefetch was the wrong fix, and measuring the payload is what showed
it.** The Flutter `StockMovement`/`StockItem` models parse only `product` (the
id) and the quantity/note fields — **nothing reads `product_detail` at all**, and
the frontend test fixtures for those endpoints never even included the key. So
the tuned prefetch was making an unread 4KB-per-row product tree cheap to build
instead of not building it. Deleting the field beat the prefetch on every axis:
50-row `stock-movements/?product=X` went 1153 -> **4** queries (the prefetch had
got it to 16) and 204,699 -> **23,449** bytes, and the diff got *smaller* — the
`Prefetch` helper, the stock-rollup annotation and a shared-prefetch extraction
in `catalog/services.py` all evaporated. What is left is `select_related` for the
names plus one `variant__option_values__option` prefetch.
