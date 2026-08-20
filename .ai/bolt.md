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

## 2026-08-19 - A bulk primer is worth writing when the codebase has already forked the arithmetic

**Learning:** `RegisterSession`'s four drawer aggregates cost 16 queries per
serialized session (four properties, `expected_cash` re-reading all four,
`cash_variance` re-reading `expected_cash`, `has_cash_variance` re-reading
`cash_variance`) — the same composite shape as `Supplier.net_balance`. What made
it findable was not reading the model but grepping the property *names* across
the repo: `apps/reports/services.py` and `apps/core/dashboard/helpers.py` had
each independently **re-implemented** the `expected_cash` sum in bulk SQL, and
`apps/notifications/services.py` annotates its own `cash_variance_amount` with a
comment saying the property is "a 4-aggregate Python property". Three
hand-rolled copies of the same money arithmetic is the loudest possible signal
that the property is too expensive to call — and each copy is a place the
drawer math can silently drift from the till.

**Action:** When hunting an N+1 in an unfamiliar subsystem, `grep -rn` the
property name across *all* apps before reading anything. Callers that annotate
or re-derive the same value in SQL are pointing at the bottleneck, and they also
size the win: those workarounds exist because someone already hit it. (Consuming
the primer from those three duplicates would let them delete their copies — a
correctness win, not just a speed one, but it needs its own value-equality tests
per report so it did not ride along here.) Also worth noting: an unbounded
`sum(1 for x in queryset if x.property)` — as in `_register_session_summary` —
is worse than a paginated N+1, because nothing caps the row count.

## 2026-08-19 - `variant.display_name` is a hidden per-row query in ~20 serializers

**Learning:** `ProductVariant.display_name` is `name.strip() or option_values_label
or product.name`, and `option_values_label` only reads a *prefetched*
`option_values` — otherwise it queries. A default variant has no explicit
`name`, so on real data the middle branch is the one that runs, and any
serializer with `source="variant.display_name"` whose queryset forgot
`option_values` pays 1 query **per line**. It hides well: the queryset looks
tuned (`materials__variant__product` was prefetched), the field looks like a
plain `CharField`, and the property's own docstring says it reuses a prefetch —
which is true only for the callers that supply one. The operations job board was
3 queries/row for a three-part repair; a 50-job page was 163 queries, 14 after.
`grep -rn 'variant.display_name'` finds ~20 sites (purchasing has six serializers
on it, sales two, customers one, plus non-serializer callers in printing,
price_checker and the dashboard helpers) — each one is a queryset to check.

**Action:** Treat `display_name`/`full_name`/`option_values_label` as
prefetch-dependent, not free. When auditing any list endpoint that serializes
lines, check its queryset for
`Prefetch("<path>__option_values", queryset=VariantOptionValue.objects.select_related("option"))`
— `OrderViewSet` is the reference. And prove it with value equality against a
cold variant, not just a query count: the prefetch must change *where* the label
comes from, never what it says.

**Next target (measured, unfixed):** `employee-list` is 2 queries/row —
`Employee.active_compensation_plan` re-`filter()`s the relation the viewset
already prefetches (so the prefetch is paid for and ignored), and `payroll_total`
is a per-row `Sum` aggregate. Measured 14 queries at 5 rows, 24 at 10; a
50-row page is ~104. Left out to keep this change one subsystem.

## 2026-08-19 - An unused `Prefetch` is a signpost, not a tuned queryset

**Learning:** `EmployeeViewSet` carried
`Prefetch("compensation_plans", queryset=...order_by("-effective_from", "-id"))`
— exactly the ordering `Employee.active_compensation_plan` needs — yet the
property called `self.compensation_plans.filter(...)`, which **builds a new
queryset and ignores the prefetch cache entirely**. So the page paid for the
prefetch *and* a query per row, and the endpoint read as already-optimized. The
`compensation_history` action ignores it too (`.order_by()` on the manager is
another fresh queryset), so nothing on the viewset ever consumed it. Measured
`employee-list`: 14 q at 5 rows, 24 at 10, **104 at 50** — 2.0 q/row from this
plus `payroll_total`'s per-row `Sum`. Flat 4 after.
**Action:** A `Prefetch` whose `to_attr` is absent and whose relation is only
reached through `.filter()`/`.order_by()` on the manager is dead weight —
`grep` the relation name and check every caller uses `.all()` (or the
`to_attr`). When the consumer is a property with a selection rule, the fix is
`to_attr` + a shared classmethod (`CompensationPlan.active_as_of`) so the cold
`.first()` and the prefetch's first row are the same rule, and the property
still owns the answer.

## 2026-08-19 - A grouped subquery keeps the join its dropped ORDER BY needed

**Learning:** `PayrollLine.Meta.ordering = ["employee__full_name", "id"]`. In a
correlated `Subquery(... .values("employee_id").annotate(Sum(...)))`, Django
correctly omits the Meta ORDER BY from the grouped SQL — but it does **not**
drop the `INNER JOIN employees_employee` that ordering pulled in. The result is
right and the join is invisible in the ORM code; it just costs an extra join
inside a subquery that runs once per row of the page. Adding an explicit
`.order_by()` before the `annotate()` removes it (verified by printing
`str(qs.query)`: 2 joins -> 1).
**Action:** Any `values().annotate()` subquery over a model whose `Meta.ordering`
traverses a relation (`PayrollLine`, `OrderLine`-shaped models here) needs an
explicit `.order_by()`. A query-count test will **not** catch this — the query
count is identical either way. Check the generated SQL, not just the count.

## 2026-08-19 - A correct, verified PR still cannot merge from a `bolt/*` branch
**Learning:** 🛡 Warden merges only PRs whose *head branch* starts with
`claude/`. The guard fires on the branch name, not authorship, so #36 —
reviewed clean, no defects found, regression test confirmed failing on `main` —
sat in the queue being skipped every hourly run. A whole cycle bought nothing.
🧪 Probe lost a run to the identical wall (#34 → #38), so this is a fleet-wide
trap, not a one-off. The recovery is cheap but only if you spot it: push the
same SHA to `claude/<name>` (`git push origin <sha>:refs/heads/claude/<name>`,
no checkout needed), open the PR there, close the old one.
**Action:** Name the branch `claude/bolt-<topic>` at creation. Before opening
any PR, check the prefix — and when an open PR of yours is unlabelled and
untouched across runs, suspect the branch name before assuming it is merely
awaiting review.

## 2026-08-19 - A `SerializerMethodField` guarded by `<fk>_id` is an invisible N+1
**Learning:** CRM's `get_outbound_status` is `obj.outbound.status if obj.outbound_id
else ""`. The `_id` guard makes it *look* prefetch-aware — it dodges the query for
rows with no relation — but every row that *has* one still fires its own
`.get()`. It reads as defensive code, so nobody re-checks the queryset. Both CRM
list-of-rows payloads had it (`CampaignRecipientSerializer`,
`ConversationMessageSerializer`) and both querysets prefetched the *sibling*
relation only (`recipients__customer`, `messages`) — the half that was obviously
needed. Measured: `campaign-detail` on a 200-recipient campaign 205 -> 6 queries,
`conversation-detail` on a 100-message thread 103 -> 4.
**Action:** Grep `_id else` / `_id and` inside serializer methods when auditing a
list endpoint — that idiom is where a missing prefetch hides. And when a
queryset already prefetches `rel__a`, check every field the row serializer reads,
not just the one the prefetch names; a partial prefetch is the strongest signal
that the audit stopped early.

**Also:** a writable M2M listed in `Meta.fields` (`Campaign.customers`) is a
`PrimaryKeyRelatedField(many=True)` and costs 1 query **per row of the list**,
not just on detail. It is easy to miss because it looks like a plain column in
the field list and the list viewset's `get_queryset` only ever gets tuned for
the `retrieve` branch. `campaign-list` was 1 q/campaign (23 at 20 rows, 4 after).
Worth checking before deleting it as "unread": the Flutter model parses neither
`customers` nor `recipients`, but the AI assistant reads `crm/campaigns` as a
generic data resource, so both fields do have a live consumer.

## 2026-08-19 - A second endpoint that serializes the same document re-derives the prefetch by hand
**Learning:** `CustomerViewSet.orders` serializes the *full* `OrderSerializer`
but assembled its own queryset —
`select_related("customer","register_session").prefetch_related("lines__variant__product","payments")`
— which is a plausible-looking subset of `OrderViewSet.queryset`'s eight
relations. Everything it omitted was invisible at the call site: `option_values`
(1 q/line via `variant.display_name`), `lines__adjustment_lines`
(**5** q/line — `can_void`/`can_return`/`can_exchange`/`returned_quantity`/
`returnable_quantity` each re-read them), `applied_discounts` and `exchanges`
(1 q/order each). That is 14 queries per invoice: a full 50-invoice page of
3-line orders was **1012** queries, 16 after. `customer-adjustments` had the
`display_name` half of the same hole (58 -> 9). The hand-rolled list read as
deliberate — it names two real relations — which is exactly why nobody
re-derived it against the serializer.
**Action:** When one serializer is used by two viewsets, the prefetch shape is
part of the serializer's contract, not the viewset's: put it on the queryset
(`OrderQuerySet.with_serializer_relations()`) and have both call it, so a new
serializer field cannot be fast in one endpoint and an N+1 in the other. Find
these with `grep -rn "<X>Serializer(" apps/` and diff each caller's queryset
against the canonical viewset's — a *shorter* list is the tell, and a partial
one is more suspicious than none at all.

**Next target (measured, unfixed):** `customer-sales-summary` is a flat **18**
queries, of which ~9 are avoidable: five separate reads over the same order
queryset (`Sum(total)`, three `COUNT`s, one `values_list` for
`last_invoice_at`) and six over the same adjustment queryset (three `SUM`s +
three `COUNT`s), all collapsible into two `aggregate()` calls with `filter=Q(...)`.
It is flat, so it is not rotting — but it is on the customer detail screen and
runs again after every debt collection (`record_payment` returns it).

## 2026-08-19 - Two `Count(distinct=True)` in one `annotate()` is a cross product, and `distinct=True` does NOT prevent it
**Learning:** `DiscountRuleViewSet` annotated `redemption_count=Count("redemptions",
distinct=True)` and `applied_count=Count("applied_discounts", distinct=True)` in
the *same* `annotate()`. Both are multi-valued reverse relations, so one query
LEFT JOINs both and the database materialises every (redemption x applied)
pair per rule. `distinct=True` corrects the returned *number* but not the work:
measured peak rows scanned went 8k -> 32k -> 128k -> 512k as I doubled per-rule
usage (20 rules), i.e. **quadratic**, and the GROUP BY runs over the whole table
so pagination cannot trim it. `AppliedDiscount` gains a row for every discounted
line ever sold, so the product only grows. At 20 rules x 500 applied + 500
redemptions the list query was **2657 ms**; as two `Subquery` counts, 8.4 ms.
The fix is `Coalesce(Subquery(model.objects.filter(rule=OuterRef("pk"))
.order_by().values("rule").annotate(c=Count("pk")).values("c")[:1]), 0)` —
`order_by()` strips `Meta.ordering` from the grouped subquery and `Coalesce`
reproduces the LEFT JOIN's 0 for an unused rule.
**Action:** A **query-count test cannot catch this** — the count is identical
before and after (see also the Meta.ordering-join entry above). Lock it with a
plan-based scaling test: `EXPLAIN (ANALYZE)` the queryset at N and 2N rows per
parent and assert peak `actual ... rows=` grows ~2x, not ~4x. It must run on
Postgres, so skip when `connection.vendor != "postgresql"`. Grep for two
aggregates over *different* reverse relations in one `annotate()`; aggregating
several columns of the **same** relation (`Sum("po__total")` + `Count("po")`) is
fine and is the common, harmless case.

**Next target (measured, unfixed):** `ProductCategoryViewSet.get_queryset`
(`apps/catalog/views.py`) has the identical shape — `children` + `products` —
and its comment states the opposite of the truth: "distinct=True on both
aggregates: ... would otherwise multiply the rows via the join fan-out". It
does multiply them. Measured 10 parents x 5 children x 40 products = **2,050**
peak rows scanned (exactly the cross product). Left out of the discounts PR to
keep the change one subsystem; the helper needs a field-name parameter to be
shared, so it wants its own change. Treat a comment that *asserts* a fan-out is
handled as a reason to measure, not to move on.

## 2026-08-19 - A worktree has no `backend/.env`, so backend tests silently run on SQLite
**Learning:** The primary checkout has `backend/.env` with
`DATABASE_URL=postgres://…`; a git worktree does **not** (it is untracked), so
`manage.py test` there falls back to SQLite. The journal's existing sanity check
is not enough to catch it: SQLite still prints
`Creating test database for alias 'default'...` — the `file:memorydb_default`
tell only shows at `-v 2`. I only noticed because `EXPLAIN (ANALYZE)` is a
Postgres syntax error. A plain query-count test would have passed happily and I
would have "measured" the wrong database, and any plan-based test would have
hit its `connection.vendor != "postgresql"` skip and reported green while
testing nothing.
**Action:** Pass the database explicitly from a worktree —
`DATABASE_URL='postgres://postgres:postgres@127.0.0.1:5432/pointy' \
/Users/hatem/Develop/pointy/backend/.venv/bin/python manage.py test apps.<app>`
— and confirm the run says `('test_pointy')`, not just "alias 'default'". Use
`--keepdb` on repeats; the migration run is most of the wall clock. Treat a
`skipTest` on `connection.vendor` as a *failure signal* when you expected
Postgres, not as a pass.

## 2026-08-19 - A hand-tuned `annotate()` comment stops the audit before `select_related`
**Learning:** `ProductCategoryViewSet.get_queryset` was ten lines: a comment
explaining why `distinct=True` was on both counts (it was wrong — see the
cross-product entry), and the counts. Nobody had noticed that the serializer's
`parent_name = CharField(source="parent.name")` had no `select_related("parent")`
next to it, so every subcategory on the page fired its own query. Both defects
lived in the same expression, and the deliberate-looking comment is why: a
`get_queryset` that visibly reasons about one cost reads as reviewed for all of
them. Measured `productcategory-list` at 50 categories: 43 -> **3** queries flat,
and the cross product 24,040 -> 120 rows scanned (7.94 ms -> 0.51 ms).
**Action:** When a `get_queryset` carries a performance comment, audit the
*other* fields anyway — read the serializer's field list against the queryset
line by line. A dotted `source=` on a plain `CharField`/`IntegerField` is the
cheapest N+1 in the codebase to find and the easiest to skim past, especially on
a self-referential FK where `parent` looks like a column. This closed the last
instance of the two-relations-in-one-`annotate()` shape; the helper now lives in
`apps/core/aggregates.py::related_count` and discounts consumes it.

## 2026-08-20 - A nested serializer's prefetch list is the SERIALIZER's contract, and the second caller always writes a shorter one
**Learning:** `StockCountViewSet.reconciliation` embeds the full
`ProductVariantSerializer` as `variant_detail` and hand-wrote its own prefetch
list — `variant`, `variant__product`, `variant__attachments`,
`variant__product__attachments`, `variant__option_values__option`. Five real
relations, so it reads as deliberate and reviewed. But `ProductVariantViewSet`'s
own queryset names *eleven*, and every one the copy omitted costs a query per
row: the product's categories/variant-options/modifier-groups/units (the
`product_detail` tree), each attachment's own `owner_content_type` /
`storage_volume` / `created_by` FKs, and the 1:1 `stock` row behind
`quantity_on_hand`. Measured 15 q/line — 54 queries at 3 lines, 99 at 6, so a
full 50-line page ≈ 754. This is the same shape as `CustomerViewSet.orders` vs
`OrderViewSet` (2026-08-19); it is now the *third* instance, so treat "two
viewsets, one serializer" as a standing audit item rather than a coincidence.
Note the copy also used `select_related("variant", "variant__product")`, which
structurally **cannot** carry the nested chains — a `Prefetch` on the same
forward FK can, because its inner queryset is rooted at `ProductVariant`.
**Action:** When a serializer is embedded anywhere but its own viewset, move the
prefetch shape into a shared factory next to the serializer
(`catalog.services.variant_detail_queryset()`) and have the viewset consume it —
then a new serializer field cannot be fast in one endpoint and an N+1 in the
other. Find them with `grep -rn "<X>Serializer(" apps/` and diff each caller's
relations against the canonical viewset's; a *shorter* list is the tell.

**Also:** a `get_<field>` that reads `getattr(obj, "<name>", None)` and falls
back to a `.count()` is only fast for the annotation the viewset remembered to
add. `StockCountViewSet` annotated `counted_line_count` and not
`variance_line_count`, so the session list paid a COUNT per row (5 q at 1 row,
10 at 6). Both counts aggregate the **same** reverse relation, so adding the
second to the existing `annotate()` is safe — the two-relations cross product
(2026-08-19) needs *different* relations. Grep the annotated names against the
serializer's fallbacks; the pair almost always drifts apart.

## 2026-08-20 - A correct prefetch elsewhere in the same FILE is what hides the missing one
**Learning:** The `variant.display_name` sweep (2026-08-19) looked finished:
every app whose serializers carry a `display_name` source — customers,
inventory, purchasing, sales, operations — greps positive for an
`option_values` prefetch. But `apps/operations/views.py` holds *five* viewsets,
and only `JobViewSet` had it. `BillOfMaterialsViewSet`, 300 lines below in the
same file, prefetched `lines__component_variant__product` — a real relation, so
it reads as deliberate — and paid 1 query for the output variant plus 1 per
component line. Measured `bom-list` with 4 components a recipe: 31 q at 5
recipes, 56 at 10, **256 at 50**; flat 8 after. A per-app grep for the fix marks
the app clean; the hole is per-*viewset*.
**Action:** When checking whether a known N+1 shape is fixed, grep for the
*symptom* (the serializer's `source=`) and resolve it to the viewset that owns
it, not for the *cure* (`option_values`) at app or file granularity. A file with
several viewsets where one is visibly tuned is the highest-yield place to look —
the tuned one is why nobody re-read the others.

## 2026-08-20 - A line's per-line reads happen in the CHILD serializer, so a parent-level preload is always too late
**Learning:** `apps/sales/services.py::checkout_order` calls
`preload_line_variants` with a comment saying it batches "the per-line product /
categories / option_values reads below" — and `prepare_discount_lines` has a
matching comment saying `.all()` "reuses the preloaded prefetch". Both were dead
on the checkout path: DRF validates a `many=True` child **before** the parent's
`validate()` runs, and `CheckoutLineSerializer.validate` is where the per-line
reads actually live (`product.modifier_groups.filter(is_active=True)`,
`resolve_unit` → `product.units` and `_base_uom`). By the time either the parent
or the service could preload, every line had already paid. Measured on
`order-checkout`: 8.0 q/line, of which 3 were catalog reads
(`unitofmeasure` + `modifiergroup` + `productcategory`, 1 each per line). The
same child serializer backs `order-discount-preview`, which the POS fires on
**every cart edit** — 4.0 q/line there (51 queries on a 12-line cart).
The fix is a `Meta.list_serializer_class` whose `to_internal_value` bulk-loads
the cart's variants *before* `super()` runs the children, and a child `validate`
that swaps in the enriched instance. Checkout 8.0 → 5.0 q/line (161 → 128 at 12
lines), preview 4.0 → 1.0 (51 → 21); what is left is the `PrimaryKeyRelatedField`
floor plus the genuine per-line writes.
**Action:** When a document endpoint has per-line reads, find out *which*
serializer level runs them before deciding where to batch. If they are in the
child's `validate`, the only hook early enough is the ListSerializer's
`to_internal_value`. And check the comments: two separate ones here asserted a
prefetch was being reused that could not possibly be live on that path.

**Also — a global lookup is not fixed by a prefetch.** `catalog/units.py::_base_uom`
is `UnitOfMeasure.objects.filter(code=…).first()`, a lookup of a *tiny seeded
table* that runs once per line resolved in its base unit (i.e. almost every
line, in both sales and purchasing). No relation prefetch can reach it; it
needed its own bulk primer (`prime_base_units`) stashing the row the function
reads first.

**And gate the primer on the cart size.** The bulk load costs ~6 queries however
small the cart, replacing 3/line — so it breaks even at 2 lines and *regresses*
a one-line sale, the commonest sale at a till (preview 7 → 10 q before I added
the threshold). `preload_line_variants` had no such gate either, so it was
already a net loss on one-line checkouts: gating it there took a one-line
checkout 75 → 72. Measure at n=1 and n=2, not just at n=8.

## 2026-08-20 - `--keepdb` reports a cascade of phantom failures after a TransactionTestCase run
**Learning:** A broad `manage.py test … --keepdb` run reported 52 errors, all
`UnitOfMeasure.DoesNotExist` in tests I had not touched. Nothing was wrong: this
suite contains `TransactionTestCase`-based tests (the business simulation) which
truncate every table on teardown and do not restore rows created by *data
migrations*, so a kept database is left permanently missing its seeded reference
data. The same suite on a fresh database was 993 tests, OK.
**Action:** `--keepdb` is safe for iterating on one app's tests, but re-create
the database (`--noinput`, no `--keepdb`) for the verification run — and when a
keepdb run fails in code you never touched, suspect the kept database before the
diff.

## 2026-08-20 - When an endpoint scales with a dimension its operation never touches, the RESPONSE is the whole N+1
**Learning:** `order-return-items` returning ONE line cost 74 q on a 3-line
invoice and 119 q on a 12-line one. The return itself does identical work in
both cases, so every one of those 45 extra queries was the *response* — 5.0
q/line, from `OrderSerializer` reading `variant.display_name` (option labels)
plus the five affordance properties (`can_void`/`can_return`/`can_exchange`/
`returned_quantity`/`returnable_quantity`) that each re-read
`adjustment_lines`. `order.refresh_from_db()` is what stripped the prefetch
cache `get_object()` had filled. Measured the halves separately: serializing
the refreshed instance was 36/51/81 q at 3/6/12 lines, the same order re-read
through `Order.objects.with_serializer_relations()` a flat **12**.
The trap is that this was *already* a known-and-fixed shape here — `_checkout`
carries a comment explaining the exact fix — and the purchasing lifecycle
actions were later fixed by copying it. Nobody re-read the six sibling actions
in the same file (`return_items`, `void`, `exchange_items`, `record_payment`,
`assign_customer`, `convert`), all of which kept `refresh_from_db()` + a bare
serialize. Also found while there: `_checkout` re-read via `get_queryset()`,
whose `?product=`/`?variant=` filters can filter a just-mutated order out of
its own response — `self.queryset` is the right handle.
**Action:** Before profiling a mutation endpoint, ask which dimension the
*operation* actually scales in. If the measured slope follows a dimension the
write does not touch (invoice line count for a one-line return), stop and
measure the serialization alone — one `CaptureQueriesContext` around the whole
request hides which half bleeds. And when you find a fix-with-a-comment on one
action, grep the *file* for its siblings before moving on; a comment explaining
a fix is evidence the file was read once, not that it was read through.

## 2026-08-20 - A model's `recalculate()` loop is an N+1 no viewset prefetch can reach
**Learning:** `PayrollRun.recalculate()` iterates `self.lines.all()` and each
`line.recalculate()` reads `compensation_plan` (rate, overtime multiplier,
daily hours) and walks `adjustments` — 2 queries per line on the **write** path,
in a method called from six places (approve, both draft services,
apply-attendance, bulk-adjustments, line-adjustments). `PayrollRunViewSet`
already prefetches `lines__employee/compensation_plan/adjustments`, but the
services re-read the run with a bare `PayrollRun.objects.select_for_update()
.get(pk=…)`, so the object reaching `recalculate()` has an empty prefetch cache
and the viewset's tuning is invisible to it. `payroll-run-approve` on a 50-line
run: 314 queries / 123 ms, of which only 50 were the genuine line UPDATEs.
The fix is a `_lines_for_recalculation()` guard — reuse `self.lines.all()` when
`"lines" in self._prefetched_objects_cache`, otherwise
`select_related("compensation_plan").prefetch_related("adjustments")`. The guard
matters: unconditionally building a fresh queryset would *discard* a warm cache
and make the already-tuned callers slower.
**Action:** Grep models for `for <x> in self.<related>.all():` where the loop
body touches each child's own FK or reverse relation. Those are invisible to
every viewset audit — the cost is in the model layer, on writes, and the
serializer looks clean. Fix inside the model with a cache-aware accessor, never
by prefetching at one call site.

**Also — this is the fourth "mutation serializes a bare object", and the sibling
fix was already present.** Three of `PayrollRunViewSet`'s six lifecycle actions
already re-read via `self.get_queryset().get(pk=…)` before serializing; the
other three (`approve`, `mark_paid`, `void`) did not, and `draft_monthly` never
did. So the counter-signal is not only "a fix with a comment" (2026-08-20) — an
*uncommented* fix present in half a file's actions propagates even less. Extract
it into one helper the moment you find the second copy. And prefer
`self.queryset.all()` over `get_queryset()` there: `get_queryset()` applies the
`?employee=` / `?period_start=` filters, which can filter a just-mutated run out
of its own response (`.get()` → `DoesNotExist` → 500).

## 2026-08-20 - `variant.full_name` is a hidden query on every default variant
**Learning:** `ProductVariant.full_name` reads `self.name.strip() or
self.option_values_label`, and `create_product_with_default_variant` makes the
default variant with `name=""` — so for the *simple* product that a normal shop
sells almost exclusively, `full_name` always falls through to
`option_values_label`, which is a query. It reads as a plain attribute, so it
never looks like a relation traversal a `select_related` audit would catch.
Measured on `apps/reports/services.py` at the real 120-row section cap:
inventory-status **128 q / 65 ms**, stock-movements 127 / 64, reorder-items
124 / 62 — flat 9 / 8 / 5 and ~10 ms once `variant__option_values` (with an
inner `select_related("option")`, which the prefetched branch needs) rides
along. Same file, same function: `purchase_rows` read `order.balance_due`,
which sums `supplier_payments` **twice** in Python (paid + credit-applied), for
252 q / 98 ms at 120 orders → 13.
**Action:** Treat `full_name` / `display_name` / `option_values_label` on a
variant as a query, not an attribute, wherever rows are built outside a
serializer that already prefetches. And note the counter-signal again: the
purchasing function had `prime_supplier_balances` with a comment three lines
below the unprimed PO rows, and `_register_closure_report` in the same file is
a textbook bulk-primer — a file can be visibly tuned in most of its functions
and still leak in the rest. Report *services* are a blind spot generally:
serializer N+1 audits never reach them.

## 2026-08-20 - A flat query count can still hide a cost that scales — count ROWS, not statements
**Learning:** The notification feed (the bell/badge poll every signed-in device
makes) prefetched `user_states` unfiltered, so it loaded **every member of
staff's** state for every alert and then discarded all but one —
`_state_for_user` is the only reader and it wants exactly the viewer's row. The
endpoint already carried a passing test asserting the statement count does not
grow with alert count, and that test is green **with or without** the fix: the
prefetch is one statement either way. The cost scales in *headcount*, a
dimension the request does not depend on. Measured on a full 50-alert page with
10 staff: **500 → 50** `BusinessNotificationUserState` instances materialized,
14.3 → 11.1 ms; the growth was exactly linear in staff (20/40/80/160 rows at
1/2/4/8 staff for 20 alerts). This is the mirror image of the two-`Count`
cross-product entry (2026-08-19): there the *plan* was quadratic at a constant
statement count; here the *result set* is. Both are invisible to
`CaptureQueriesContext`.
**Action:** When an endpoint already has a query-count test, that is a reason to
measure a *different* axis, not a sign it was audited. Count rows materialized
by patching `Model.from_db` with a counter and scaling the dimension the
request should not care about (staff, devices, sibling rows). Also: prefer the
plain filtered `Prefetch` over `to_attr` when the consumer already discriminates
(`state.user_id == user.id` here) — it needed **zero** logic change, and
crucially `refresh_from_db()` clears `_prefetched_objects_cache` but does **not**
clear a `to_attr` attribute, so a `to_attr` here would have silently broken the
three mutation actions that refresh precisely to drop the stale prefetch.

## 2026-08-20 - A custom `@action` hides inside the very viewset whose queryset is tuned
**Learning:** The `display_name`/`option_values` sweep has now missed the same
shape four times, and this instance shows why "resolve the symptom to the
viewset that owns it" (2026-08-20) is still not tight enough.
`PurchaseOrderViewSet.queryset` prefetches
`adjustments__lines__variant__option_values__option` **with an explanatory
comment**, so the class greps clean — but `product-cost-history`,
`variant-cost-history` and `adjustment-history` are `@action`s *on that same
class* that each build their own queryset from scratch
(`PurchaseLine.objects…`, `PurchaseOrderAdjustmentLine.objects…`) and never
touch it. Same for `PublicInvoiceView`, which re-derives a two-relation subset
of `OrderViewSet`'s. Measured 1.0 q/row on all three: cost-history 55 → 6 at 50
rows, adjustment-history 53 → 4, public invoice 28 → 9 at 20 lines. The unit
that owns a prefetch is a **queryset expression**, not an app, a file, a class
or a viewset — and a tuned class-level queryset is the strongest camouflage
there is, because every plausible grep for the cure hits it.
**Action:** Grep the *symptom* (`source="…display_name"`, `variant.full_name`)
and resolve each serializer to **every** queryset that feeds it, including
`@action` bodies and `APIView.get_queryset`. `grep -n "\.objects\." views.py`
is the fast way to enumerate the hand-rolled ones; each is its own audit.
**Also:** measure with a warm-up request. The first two attempts here read 0.67
q/row because the permission and content-type queries landed on the smaller
measurement — the slope only showed as a clean 1.0 after an untimed request
preceded each `CaptureQueriesContext`.

## 2026-08-20 - An annotation-or-count fallback costs once per SERIALIZATION, not once per instance
**Learning:** `UnitOfMeasureSerializer.get_product_count` is the familiar
`getattr(unit, "product_count", None) or unit.product_units.count()` hook, and
`UnitOfMeasureViewSet` supplies the annotation — so the field greps clean. But
`unit_detail` is nested under every product's `units`, and a *forward-FK*
prefetch (`units__unit`) hands every row the **same shared UnitOfMeasure
object**, which made me expect one COUNT. It is one COUNT per row anyway:
nothing caches the fallback on the instance, so the serializer re-runs it every
time it renders that same object. Measured `product-list` at 50 rows with one
packaging unit each: 67 -> 17 queries; `product-variant-list` 64 -> 14. It hid
because the existing catalog scaling tests build products with *no*
`ProductUnit` rows, so the whole branch never ran under test while multi-unit
products are a shipped feature.
**Action:** For an annotation-or-fallback field, count the *serializations*, not
the instances — a shared prefetched object still pays per render. Fix by
annotating on the prefetch queryset (`Prefetch(lookup, queryset=...annotate())`)
and have the owning viewset consume the same factory, so primed and cold can't
drift. And when a scaling test is flat, check its fixture actually populates the
optional relations: an unpopulated relation makes an N+1 test-invisible.

**Also — the "two viewsets, one serializer" audit item claims its fourth
instance, and this time the shared factory already existed.**
`ProductViewSet.variants` (the product-detail screen's variant list) hand-rolled
five relations while `catalog.services.variant_detail_queryset()` — written for
exactly this reason, and consumed by `ProductVariantViewSet` and the stock-count
screen — sat imported in the same file. Measured 15.0 q/variant (72/117/207/327
at 3/6/12/20 variants), flat 33 after. A shared factory does not close the shape;
grep every `@action` that builds its own queryset against it.

## 2026-08-20 - Diff the query-shape HISTOGRAM at N and 2N, not the total
**Learning:** `order-checkout` had a documented per-line floor of 5 queries,
annotated in `test_checkout_line_preload.py` as "the `PrimaryKeyRelatedField`
floor plus the genuine per-line writes" — which reads like nothing is left to
take. Bucketing the captured SQL by `verb + table` and diffing the counts
between a 2-line and an 8-line cart showed the floor was actually five *distinct*
shapes at exactly 1.00/line each, and three of them were the stock write:
`SELECT inventory_stockitem FOR UPDATE`, `UPDATE inventory_stockitem`,
`INSERT INTO inventory_stockmovement`. All three batch trivially
(`variant_id__in` lock, `bulk_update`, `bulk_create`) because
`prepare_sale_stock_adjustments` has already aggregated the cart to one entry
per distinct variant. Measured: 4.67 -> 1.67 q/line, 167 -> 110 on a 20-line
cart. A total-count scaling test cannot tell "one irreducible read per line"
from "five things, three of them batchable"; the histogram can, and it took
about ten lines of `re` + `Counter` in a throwaway test.
**Action:** When a scaling test is *already passing* at a bound someone wrote
down, print the per-shape slope before believing the bound. And on the write
side specifically: a per-line INSERT/UPDATE loop is invisible to every
serializer/prefetch audit in this journal, so it survives long after the reads
are clean.

**Also — a batched `select_for_update()` must carry its own `order_by()`.**
`StockItem.Meta.ordering` is `["variant__product__name", "variant__name"]`, so a
bare `StockItem.objects.select_for_update().filter(variant_id__in=…)` would join
`catalog_productvariant` + `catalog_product` into the lock and take row locks on
the catalog too. `.order_by("variant_id")` drops the joins *and* preserves the
ascending-id lock ordering the per-row loop relied on for deadlock avoidance
(Postgres puts LockRows above Sort, so rows are locked in output order).
And `bulk_update` does not run field `pre_save`, so an `auto_now` column has to
be stamped by hand — the per-row `save(update_fields=[..., "updated_at"])` it
replaces did refresh it.

## 2026-08-20 - A "flat" endpoint can still be thirteen round trips over two tables
**Learning:** Every N+1 hunt in this journal asks "does the count grow with N?".
`customer-sales-summary` answers *no* — and was still asking `sales_order` seven
separate questions and `sales_orderadjustment` six, because the view built one
queryset per figure (`orders.count()`, `orders.filter(status=PAID).count()`,
`adjustments.filter(type=RETURN).aggregate(Sum)`, …). A scaling test is blind to
this by construction, and so is every "slope per row" measurement in this file.
Folding them into one `aggregate()` per table with `Count/Sum(filter=Q(...))` took
19 -> 8 queries and 7.6 -> 4.7 ms median wall time (400 invoices / 100
adjustments, localhost Postgres — on-prem through PgBouncer the round trips cost
more). Safe here specifically because each aggregate reads **one** table with no
joined multi-valued relation, so the two-`Count` cross product (2026-08-19) can't
bite; the adjustments query joins `sales_order` but only through a forward FK.
**Action:** Add "how many statements does this endpoint issue *at all*" to the
audit, not just "how many per row". The tell is a view body with several
`.count()` / `.aggregate()` calls over sibling filters of one base queryset.
Fold them, but keep the filter definition shared — `transactional_sale_q()`
already existed as the `Q` mirror of `OrderQuerySet.transactional`, precisely so
a `Count(filter=...)` cannot become a second definition of "what counts as a
sale". If no such mirror exists, write it before folding, not a copy of the
predicate. **Also:** a query-count test wants `FROM "<table>"`, not a substring
match — an aggregate that *joins* the table you are counting will otherwise mask
the very difference you are measuring (it read 3 instead of 2 until I anchored
on `FROM`).
