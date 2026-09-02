# Purchase Suggestions — اقتراحات الشراء

**Status:** SHIPPED — all five phases implemented and verified
**Date:** designed and built 2026-09-02
**Scope:** `apps/purchasing` (backend) + `features/purchasing` (frontend)

---

## 1. The problem

A Libyan shop's purchase orders are near-identical week after week. The same
supplier arrives, the buyer types the same twenty products, in roughly the same
order, in the same quantities — because that is how these shops actually run
(whether or not it is good inventory practice, it is the reality we must serve).

Today the purchasing screen already prefills **cost** from the last purchase
(`PurchaseViewModel._lastCostForVariant` → `variant-last-cost`). Everything
else — *which product* and *how many* — is typed by hand every single time.

Two things are guessable from the shop's own history:

| Guess | Evidence | Confidence we can reach |
|---|---|---|
| The **next product** the buyer is about to add | which products share a PO with the ones already in the draft, for **this supplier** | High for a supplier with a repeating basket |
| The **quantity** for a product just added | the quantities this shop has bought of it from this supplier, in the same unit | High only when the quantity is genuinely repeated |

The design below turns exactly those two into suggestions — and nothing more.
Where the evidence is weak, the feature says nothing rather than guessing.

## 2. Design principles (non-negotiable)

1. **Suggestion, never imposition.** Nothing is ever auto-filled into a line.
   Every suggestion is a chip that costs one tap to accept and zero taps to
   ignore. A buyer who never looks at the strip loses nothing.
2. **Silence beats a wrong number.** Every suggestion has a support floor. A
   product bought twice, or a quantity that swings 3 → 17 → 8, produces *no*
   suggestion. A purchase quantity flows into stock and into cost basis; a made-up
   number is worse than a blank field.
3. **No layout theft.** No dialogs, no focus stealing, no reordering of the
   catalog grid, no spinner where the suggestions will appear. The catalog search
   field stays the resting focus (see `pos-search-autofocus`).
4. **Never a keystroke slower.** The read path is precomputed and cached; the
   client fetches at most once per (supplier, draft contents) and re-uses an
   in-memory cache after that. Adding a line must not wait on the network.
5. **One definition of the unit.** A suggested quantity always carries its
   unit and `unit_factor`. "12" is meaningless; "12 cartons (×24)" is not.
   This keeps the UoM cost-normalization invariant intact.

## 3. Data model — two precomputed tables

Live `GROUP BY` over `PurchaseLine` is what made the purchases screen hang at
12K POs. Suggestions are read on every draft mutation, so they are precomputed.

### 3.1 `SupplierPurchaseHabit` — one row per (supplier, variant)

```python
class SupplierPurchaseHabit(TimeStampedModel):
    """How this shop habitually buys one product from one supplier.

    Rebuilt from the supplier's purchase history; never edited by hand.
    """
    supplier   = FK(Supplier, on_delete=CASCADE, related_name="purchase_habits")
    variant    = FK(ProductVariant, on_delete=CASCADE, related_name="purchase_habits")

    order_count     = PositiveIntegerField(default=0)   # POs in window containing it
    weighted_count  = FloatField(default=0)             # recency-decayed order_count
    last_ordered_at = DateTimeField(null=True)

    # The habitual quantity, expressed in the habitual purchase unit.
    # NULL means "the shop does not buy a repeatable quantity" → no hint shown.
    typical_quantity     = Decimal(12, 3, null=True)
    typical_unit         = Char(32, blank=True)         # "" = base unit
    typical_unit_factor  = Decimal(18, 6, default=1)
    quantity_confidence  = FloatField(default=0)        # share of recent buys at that qty

    # Cadence — powers the "due again" suggestion on an empty draft.
    avg_interval_days = FloatField(null=True)
    interval_cv       = FloatField(null=True)           # stdev/mean; low = regular

    # Mean normalized entry position (0 = first line typed, 1 = last).
    avg_position = FloatField(default=0)

    last_base_unit_cost = Decimal(10, 2, null=True)

    class Meta:
        constraints = [UniqueConstraint(fields=["supplier", "variant"], ...)]
        indexes = [Index(fields=["supplier", "-weighted_count"])]
```

### 3.2 `SupplierPurchaseAffinity` — "what comes with what", per supplier

```python
class SupplierPurchaseAffinity(TimeStampedModel):
    supplier       = FK(Supplier, on_delete=CASCADE)
    anchor_variant = FK(ProductVariant, on_delete=CASCADE, related_name="+")
    variant        = FK(ProductVariant, on_delete=CASCADE, related_name="+")
    together_count = PositiveIntegerField()   # POs containing both
    confidence     = FloatField()             # weighted P(variant | anchor)

    class Meta:
        constraints = [UniqueConstraint(fields=["supplier", "anchor_variant", "variant"], ...)]
        indexes = [Index(fields=["supplier", "anchor_variant", "-confidence"])]
```

Directed pairs (both directions stored) so the read is a single indexed lookup
with no `Q(a=x) | Q(b=x)` gymnastics.

**Bounded by construction:**

- Only the top `K = 12` neighbours per (supplier, anchor) survive.
- Rows below `MIN_TOGETHER = 3` or `MIN_CONFIDENCE = 0.35` are never written.
- Anchors are capped at the supplier's top 2,000 variants by `weighted_count`.

Worst case per supplier: 24,000 rows; realistically a few thousand. Rows for
suppliers/variants that fall out of the window are pruned by the nightly pass.

## 4. The rebuild

New module `apps/purchasing/suggestions.py`, mirroring the shape of
`apps/catalog/popularity.py` (plain function, Celery wrapper in `tasks.py`,
idempotent, `bulk_update`/`bulk_create` — no per-row `save`).

```
rebuild_supplier_suggestions(supplier, *, reference_time=None)  # one supplier
rebuild_purchase_suggestions(*, window_days=270)                # all suppliers + prune
```

### 4.1 Evidence selection

- POs with `status in (SUBMITTED, PARTIALLY_RECEIVED, RECEIVED)`.
  Cancelled orders are not evidence. **Drafts are not evidence** — an abandoned
  draft is the buyer changing their mind, and feeding it back would make the
  feature reinforce its own mistakes.
- Trailing `WINDOW_DAYS = 270` (three quarters: long enough for a monthly
  restock cycle to show up four times, short enough to forget a discontinued line).
- Capped at the `MAX_ORDERS = 400` most recent POs per supplier.
- Lines ordered by `PurchaseLine.Meta.ordering = ["created_at"]` — that ordering
  *is* the buyer's entry sequence, which is what makes the "next product" signal
  possible at all.

### 4.2 Recency weighting

`w = 0.5 ** (age_days / 60)` — a 60-day half-life. Last month's basket counts
roughly four times what a basket from six months ago counts. Everything below
(`weighted_count`, `confidence`) is computed on `w`, so a supplier whose range
changed drifts to the new range on its own instead of needing a manual reset.

### 4.3 Typical quantity — the accuracy gate

For each (supplier, variant), take the **last 8** purchase lines:

1. Pick the dominant purchase unit; discard lines in other units (a shop that
   switched from pieces to cartons should not be offered a piece quantity).
2. Take the **exact mode** of the quantity across those lines.
3. Write `typical_quantity` **only if** `n >= 3` and `mode_share >= 0.5`.
   Otherwise `typical_quantity = NULL` and no quantity is ever suggested for
   that pair.

Mode, deliberately, not mean or median: a mean of 10 and 15 is 12.5, a number
this shop has never once purchased. The feature exists because shops repeat
themselves exactly; where they do not repeat exactly, it stays quiet.

*(If field telemetry later shows a large "near-repeat" population — 10, 12, 12,
11 — a clustered-median fallback can be added behind the same confidence gate.
Not in v1.)*

### 4.4 Affinity pass

Per basket, accumulate `w` for each ordered pair, then
`confidence(a→b) = weight(a,b) / weight(a)`.

Basket size guard: baskets with `n <= 40` lines pair fully; larger baskets pair
only within a **±12 sliding window of entry position**. This bounds the pair
count (a 200-line restock would otherwise produce ~40k pairs per basket) *and*
is the more faithful signal anyway — in a long order, "what comes next" is a
local property of the buyer's walk down the invoice, not of the whole document.

Cost: ≤ 400 baskets × ≤ 1,600 pairs ≈ well under a second per supplier in
CPython. It runs in a worker, never in a request.

### 4.5 When it runs

| Trigger | Job |
|---|---|
| Nightly (Celery beat) | `purchasing.rebuild_purchase_suggestions` — full pass + prune |
| PO submitted / received / **edited** | `purchasing.refresh_supplier_suggestions(supplier_id)` queued `on_commit`, per supplier |

The per-supplier refresh is what makes a shop's *daily* order feel alive: today's
delivery is evidence for tomorrow's. Editing a received PO unwinds and re-records
its delivery, so it must trigger the refresh too. A supplier already refreshed in
the last 10 minutes is skipped (Redis flag) so a burst of receipts does not
requeue the same work repeatedly.

## 5. The endpoint

```
GET /api/purchase-orders/suggestions/?supplier=<id>&variants=<csv>&limit=8
```

`permission_map["suggestions"] = ("purchasing.add_purchaseorder",)` — the same
code as `discount_preview`: you only need it while drafting.

```jsonc
{
  "supplier": 4,
  "generated_at": "2026-09-02T10:12:00Z",
  "usual_basket": { "line_count": 14, "available": true },
  "items": [
    {
      "variant": 812,
      "product_name": "ماء معدني ٠٫٥ل",
      "sku": "W-500",
      "suggested_quantity": "12.000",     // null when no stable quantity
      "unit": "carton",
      "unit_factor": "24.000",
      "unit_cost": "24.00",               // last cost in that unit; null if unknown
      "reason": "often_with",             // often_with | usual_for_supplier | due_again
      "reason_variant": 44,               // the anchor, for "usually bought with X"
      "score": 0.82,
      "evidence": { "orders": 9, "days_since_last": 6, "confidence": 0.78 }
    }
  ]
}
```

### 5.1 Ranking (read-time, ≤ 3 queries)

1. **Affinity candidates** — `SupplierPurchaseAffinity.objects.filter(supplier=…,
   anchor_variant__in=draft_variants)`, straight down the composite index.
   Combined across anchors with a noisy-or: `score = 1 − Π(1 − confidence)`, so
   three anchors that each weakly point at a product beat one that does strongly.
2. **Baseline candidates** — top habits by `weighted_count` when the draft is
   empty or affinity is thin, scored as `weighted_count / max_weighted_count`.
3. **Due-again candidates** — habits where `interval_cv <= 0.5`, `order_count >= 4`
   and `days_since_last >= 0.9 × avg_interval_days`. This is what fills the strip
   the moment a supplier is chosen, before a single product is typed.
4. **Sequence bonus** — ×1.15 for candidates whose `avg_position` sits just after
   the last added line's. A tie-breaker, never a primary signal; it degrades
   harmlessly to nothing on imported history where all lines share a timestamp
   (relevant for the reconstructed Fahd invoices).
5. **Exclusions** — already in the draft; archived or inactive products;
   `days_since_last > 120`; `score < MIN_SCORE (0.25)`. Cap at 8.

Three indexed queries returning ≤ ~100 rows. Cached in Redis under
`purch:sugg:{supplier}:{suggestions_version}:{catalog_version}:{hash(anchors)}`
— reusing the existing catalog version so a rename or archive invalidates for
free, and a per-supplier `suggestions_version` bumped by the rebuild.
A query-count regression test pins the read at its query budget, as
`test_receive_query_scaling.py` and friends do.

### 5.2 Client fetch discipline

- One request per distinct (supplier, sorted anchor set), 200 ms debounce,
  single-flight through the existing dedupe layer (`caching-initiative-2026-07`).
- In-memory LRU keyed identically, so removing a line and re-adding it is
  instant and silent.
- **Previous suggestions stay on screen while a refresh is in flight.** No
  spinner, no flash of empty. Suggestions are decoration; they never gate a keystroke.
- Zero requests when the shop setting is off, when no supplier is selected, or
  when a supplier has already answered "nothing to suggest" for this draft state
  (a no-suggestions latch, same shape as the discount-preview no-rules latch).

## 6. The three UI surfaces

### A. Suggestion strip — catalog pane

A single horizontally-scrolling row of chips, sitting under the quick-access
category strip in `PurchaseCatalogPane`, above the grid.

```
┌────────────────────────────────────────────────────────────┐
│ [ الطلب المعتاد · ١٤ صنف ]  [ ماء معدني ×١٢ ]  [ عصير ×٦ ] …│
└────────────────────────────────────────────────────────────┘
```

- Chip = product name + (if there is one) a muted trailing `×12 كرتون`.
  One tap adds the line at that quantity, unit and last-known cost, then returns
  focus to search — the exact path a catalog tile tap already takes.
- Renders **only** when there is at least one suggestion above threshold. No
  empty state, no "no suggestions yet" message, no reserved blank band.
- A trailing `×` collapses the strip for the current draft. A shop setting hides
  it permanently.
- Long-press → "لا تقترح هذا" mutes one (supplier, variant) pair locally
  (persisted in the SQLite `KeyValueStore`). Shop-wide mutes are a v2 question.

### B. Quantity hint — draft line tile

When a line is added and its habit carries a `typical_quantity` that differs
from the line's current quantity, `PurchaseDraftLineTile` shows a small chip
beside `PointyQuantityStepper`:

> `المعتاد ١٢` → tap sets the quantity.

It occupies space that was previously empty (no reflow), and it disappears on
accept, on any manual quantity edit, or when the line is removed. **F6** accepts
it for the active line, joining the existing F1–F4 keys in
`purchasing_shortcuts_sheet.dart` — the buyer's hands never leave the scanner.

Deliberately *not* auto-filled: a quantity is the number that becomes stock and
cost basis. It gets a tap.

### C. "املأ الطلب المعتاد" — usual basket

Offered when a supplier has ≥ 4 POs in the window and a stable recurring basket
(products with weighted presence ≥ 0.7). One tap adds every one of them at its
usual quantity and last cost, and raises a single **Undo** snackbar — the same
reversal pattern `_deleteActiveLine` already uses. The buyer then edits and
deletes normally; nothing is submitted, nothing is locked.

This is the single biggest time saver for a daily repeat order, and it is one
button that a shop with irregular buying will simply never see.

## 7. Settings

`ShopSettings.enable_purchase_suggestions = BooleanField(default=True)`,
surfaced in the purchasing section of shop settings. Off = all three surfaces
gone and zero suggestion requests issued.

## 8. Telemetry — how we find out whether it actually works

Through the existing analytics engine:

| Event | Payload |
|---|---|
| `purchase_suggestion_shown` | supplier, count, reasons — **one event per anchor-set change**, coalesced, never per rebuild |
| `purchase_suggestion_accepted` | reason, chip position, whether the quantity was kept |
| `purchase_suggestion_dismissed` | reason |
| `purchase_quantity_hint_accepted` | variant, suggested vs final quantity |
| `purchase_usual_basket_filled` | lines added, **lines still present at submit** |

The coalescing matters: a strip that re-renders on every keystroke would emit
the same event shape that produced the 2026-08 ingest storm. Emit on state
change, not on build.

The metric that decides the feature's fate is **lines accepted and still present
at submit**, per `reason`. If `often_with` lands and `due_again` does not, the
thresholds move on evidence rather than on taste.

## 9. Risks and honest limits

- **Cold start.** A new shop, or a new supplier, sees nothing until it has 3+
  orders. That is correct behaviour, not a defect — and it is why the feature can
  never be the *only* way to add a line.
- **Imported history.** Reconstructed legacy invoices (Fahd) may carry identical
  `created_at` across all lines; the sequence bonus then contributes nothing and
  co-occurrence carries the whole signal. Graceful, but worth verifying against a
  real imported dataset before trusting the `avg_position` term.
- **Table growth.** Bounded by top-K, the anchor cap and nightly pruning. The
  nightly job logs row counts so growth is visible before it is a problem.
- **Seasonality.** A 270-day window with a 60-day half-life tracks Ramadan-scale
  shifts about as well as a non-ML approach can. `special_day_keys` is already
  snapshotted on every PO; a holiday-aware term is the obvious v2, and is
  deliberately out of v1 scope.
- **Self-reinforcement.** Suggestions are evidence-fed from *submitted* orders,
  which include orders that started as accepted suggestions. Real, and mild —
  the buyer still confirms every line, and drafts are excluded. The acceptance
  telemetry is what would expose it if it ever stopped being mild.

## 10. Phasing — as built

| Phase | Deliverable | Where it landed |
|---|---|---|
| 0 | Models, rebuild engine, Celery tasks, management command | `apps/purchasing/{models,suggestions,tasks}.py`, `management/commands/rebuild_purchase_suggestions.py`, migration `0027` |
| 1 | Endpoint + serializer + Redis cache | `views.PurchaseOrderViewSet.suggestions`, `serializers.PurchaseSuggestion*`, `suggestions.cached_suggestions_for_draft` |
| 2 | Client fetch discipline + strip | `purchase_suggestion_controller.dart`, `purchase_suggestion_strip.dart`, `PointyCatalogPane.suggestionStrip` |
| 3 | Quantity hint + F6 + usual-basket fill with Undo | `PurchaseQuantityHintChip`, `PurchaseViewModel.{acceptSuggestion,fillUsualBasket,applySuggestedQuantity}` |
| 4 | Shop setting + telemetry | `ShopSettings.enable_purchase_suggestions`, `purchasing.draft.suggestion.{accepted,basket_filled}` |

### Tests

- **Backend, 34 tests** (`apps/purchasing/test_suggestions.py`). Most of them
  assert *silence*: a pair seen twice, a quantity that wanders 3 → 17 → 8 → 40,
  a cancelled order, a draft order, a product last bought 200 days ago and a
  supplier with two orders behind it all have to produce nothing. Plus a
  query-count guard proving the read stays flat as the draft grows, and
  scheduling tests proving a burst of receipts queues exactly one rebuild and
  that an unreachable broker cannot fail a receipt.
- **Frontend, 21 tests** (`purchase_suggestion_controller_test.dart`): one
  request per draft state, bursts collapsed, a returned-to state served from
  cache, a disabled shop asked exactly once, a barren supplier asked once rather
  than once per line, previous answers held on screen during a refresh, an
  offline read failing silently, and every accept path.

### Verified in the preview harness

`make frontend-pos-preview` → `?screen=purchase` (add `&theme=dark`), with fake
habit data wired into the harness's purchase repository. Confirmed live: the
strip appears once a supplier is chosen; a chip tap adds the line at its
habitual quantity, unit and last cost, and the chip leaves the strip; the
quantity pill moves a line from 4 to 8 cartons and then disappears because the
line now matches; "الطلب المعتاد" fills the remaining lines behind one Undo that
restores the total exactly; every reason string names its own evidence; and both
palettes read correctly.

### Deviations from the design above

- The quantity hint moved off the stepper. Its first placement hung it under the
  stepper, where it rendered level with the per-base-unit conversion text and
  read as clutter. It now shares that secondary row deliberately — conversion on
  one side, the offer on the other — and is styled as a soft primary pill rather
  than a muted badge, so it reads as an action rather than a label. It also
  carries its unit ("المعتاد ٨ كرتون"), because "8" alone is the difference
  between eight bottles and eight cartons of them.
- The `due_again` reason states days *since the last purchase* ("اشتُري قبل ٢١
  يوم — وحان موعده") rather than the average interval. The interval is what the
  cadence is computed from; the days since last purchase is the fact the buyer
  can check, and it is the number the payload actually carries.
- `next_due_at` and `presence_ratio` are precomputed columns rather than
  read-time arithmetic, and a third table (`SupplierPurchaseProfile`) holds the
  per-supplier totals that both are measured against — it also supplies the
  cache-key version that a rebuild bumps.
