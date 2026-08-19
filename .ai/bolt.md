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
