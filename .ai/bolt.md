# Bolt's Journal ⚡

Critical performance learnings for this codebase. Not a work log.

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
