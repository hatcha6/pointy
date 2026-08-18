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
