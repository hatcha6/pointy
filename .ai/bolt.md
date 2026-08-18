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
