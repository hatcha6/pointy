# AI Assistant: Generative UI + Autonomous Invoice Intake — Plan

**Date:** 2026-09-02
**Scope:** two initiatives on the relay-hosted AI assistant (`backend/apps/ai/`, `frontend/lib/src/features/ai/`, `relay/internal/relay/ai.go`).

- **Initiative A — Generative UI in chat.** Let the assistant answer with real Pointy UI (charts, tables, metric grids, callouts, entity cards, small forms) composed freely by the model, while making visual drift impossible by construction.
- **Initiative B — Autonomous invoice intake.** Photograph a supplier invoice → the system extracts, reconciles against the catalog, plans product/unit/supplier creation, shows one review card, and creates the purchase order in a single transaction. No scanning a piece of every product, no manual search, no PO screen.

Both build on what already ships: the Django-owned agentic loop (`_agentic_stream`, 10 rounds), the read/write tool spine that dispatches through real DRF viewsets, the `ask_user` pause/resume protocol, the `product_picker` question type, `match_invoice_products`, `suggest_sale_price`, and `ProductAlias` learning.

---

## 0. Where we are (grounding)

| Area | Today | Gap the plan closes |
|---|---|---|
| Assistant output | Markdown only (`gpt_markdown`) + one structured widget, the `ask_user` question card | No charts, tables, cards, or interactive surfaces; the model can only narrate numbers |
| Chart widgets | `fl_chart` used in exactly one file, three private widgets in `dashboard_screen_widgets.dart` | No shared, themed chart components to hand to a catalog |
| Rich rendering hook | New SSE event → field on `AiMessage` → branch in `_AssistantMessage.build` | Clean, but there is no generic renderer; each rich type would be bespoke |
| Structured model output | Relay `wireRequest` has no `response_format` | Extraction and UI JSON are prompt-only, validated after the fact |
| Invoice → PO | Works, but the chat model orchestrates everything: vision turn 1 (image seen once), conservative matching, up to 5 `product_picker` questions per pause, one `create_resource` per new product, PO as final call | Slow (many rounds), fragile (10-round cap, 120 s per round, image lost after turn 1), non-transactional (orphans on mid-flow failure), still interactive per unmatched line |
| Invoice images | Metadata only, bytes never stored | Cannot re-inspect the image, cannot attach it to the PO for audit |
| Chat screen | `ai_assistant_screen.dart` is 3,411 lines holding every widget | Hard to extend safely |

---

## Initiative A — Generative UI

### A.0 Decision: GenUI vs. our own renderer

**Recommendation: adopt the A2UI wire protocol and the `genui` rendering engine, but never its widget catalog.** The vocabulary the model may use is a closed, Pointy-only catalog where every item is built from an existing shared component. Drift is prevented by the schema, not by prompting.

What we learned about `genui` (pub.dev 0.10.2, 2026-08-12):

- Requires Flutter ≥ 3.35.7 and Dart ≥ 3.10. We ship Flutter 3.38.6 / Dart ^3.10.7 on `main`. Compatible. (`compat/win8` is frozen on 3.19 and excluded, per its own rule.)
- Backend-agnostic: `SurfaceController.handleMessage(A2uiMessage)` accepts structured messages directly. We do not need `Conversation` or `A2uiTransportAdapter`; Django keeps owning the loop.
- Catalog = `CatalogItem(name, dataSchema, widgetBuilder, exampleData)`; the catalog can be rendered from example data with `DebugCatalogView` (free golden-test fixture).
- Protocol (A2UI v0.9.1): four envelopes `createSurface` / `updateComponents` / `updateDataModel` / `deleteSurface`; components are a flat adjacency list with a `root`; properties accept literals or `{path}` bindings into a per-surface data model; actions carry `{event: {name, context}}`.
- Costs: the package is alpha ("the API will change, sometimes drastically"; the controller was renamed between minors). Transitive deps include `video_player`, `video_player_win`, `flutter_markdown_plus` and `audioplayers`. The markdown and video deps are dead weight for us.

Why still take it: the engine parts we would otherwise write (adjacency-list tree building, data-model bindings, child templates over lists, event dispatch, progressive rendering of partial trees, schema validation) are the fiddly parts, and the Flutter team is investing there. Our catalog and wire format stay ours, so if the engine churns we swap it behind one adapter.

**Gate: a 2–3 day spike before committing (A.1).** Kill criteria:

1. `flutter pub add genui json_schema_builder` resolves on 3.38.6 without downgrading any current dependency, and Android, Windows and web builds pass (watch `video_player_win`).
2. `SurfaceController` + `Surface` render a Pointy catalog item from a server-fed `A2uiMessage` inside an RTL chat bubble, in light and dark, with no `Conversation` facade.
3. An `fl_chart` chart inside a `Surface` inside the coalesced chat list does not reintroduce the per-token rebuild storm (`_CoalescedBuilder` invariant holds; verify with the perf sweep harness).
4. The catalog prompt/schema is under ~6k tokens.

If any criterion fails, fall back to a **Pointy-native renderer** implementing the same A2UI subset (createSurface, updateComponents, updateDataModel, literal + `{path}` bindings, list templates, no expression language). Estimate for that fallback: ~800 lines plus tests. Everything below is written so the fallback is a drop-in.

### A.1 How the model produces UI: a `render_ui` tool, validated server-side

Not prompt-first JSON in the text stream. The model calls a tool; Django validates; the client renders. This matches the existing loop exactly and lets a bad payload self-correct like any other tool error.

- New tool `render_ui` in `apps/ai/tools.py`, advertised only when the request carries `supports_ui: true` (mirrors `supports_ask_user` / `supports_actions`; old clients never receive a `ui` event).
  - Arguments: `{surface_id, title?, components: [...], data?: {...}}` — the `updateComponents` + `updateDataModel` payload for one surface. The tool parameter schema stays deliberately loose (`components: array of object`) because some providers reject deep `oneOf` unions in function schemas.
  - The full per-component schema lives in a **single JSON catalog file** shared by both sides: `shared/ai_ui_catalog/pointy_catalog.json` (A2UI-shaped, `$id`/`catalogId` = `https://pointy.app/ai-ui/v1`). Backend loads it for validation and prompt rendering; frontend loads it to build `CatalogItem` schemas (or a parity test asserts the Dart schemas equal the JSON).
  - Server validation with `jsonschema` (Python): unknown component → error; unknown property → error (`additionalProperties: false` everywhere); dangling child id → error; `root` missing → error. Errors return structured `{ok:false, error:"invalid_ui", problems:[...]}` so the model fixes and retries within the same round budget.
  - A valid surface is emitted as a new SSE event `ui` `{surface_id, title, messages:[A2UI envelopes]}` and appended to `AiMessage.ui_surfaces` (migration 0008, JSON list) so it re-renders on reload exactly like `pending_question` does.
  - `render_ui` is non-mutating; it does not count against the write cap.
- Prompt: `build_system_prompt(supports_ui=)` appends `_ui_guidance()`: when to use UI (comparisons, trends, breakdowns, lists of entities, anything with ≥ 3 numbers, any pick-one/confirm situation), when **not** to (a one-line answer), the rule "compose, never style", and 3 compact worked examples (metric grid + trend, table with totals, entity cards with actions). Catalog reference rendered from the JSON file (name, one-line purpose, properties with enums) — placed at the end of the static system prefix so provider prompt caching applies.
- Text and UI interleave: the model may emit markdown, call `render_ui`, and continue. The bubble renders content in arrival order: markdown blocks and surfaces as siblings. Persisted order comes from `tool_events` ordering plus `ui_surfaces` index.
- Interaction back to the model: every catalog action is `{event:{name, context}}` and is handled in one of three ways, chosen by a reserved `name` prefix:
  - `navigate:` → `pointy://` deep link, handled locally (existing `openAiLink`), no model call.
  - `ask:` → sends a new user turn whose text is the context's `prompt` (existing seed-prompt path). Used for "drill in", "show by category", "explain".
  - `submit:` → sends a new user turn with a structured `ui_interaction` block `{surface_id, name, context, data}` (A2UI's user-interaction part) plus the surface's current data model. Django renders that into the user message content as a fenced JSON block, so the model reads what the user filled in. This is how a small form (quantity, date range, choice) comes back.
  - No new backend endpoint is needed; `POST /api/ai/chat/` gains an optional `ui_interaction` field alongside `message`.

### A.2 The Pointy catalog v1 (the only vocabulary)

Every item's builder uses `context.pointyColors`, `PointyTypography`, `PointyRadii`; there are **no** style properties in any schema — no color, size, padding, font, width, or icon-by-arbitrary-name. The only appearance knobs are semantic enums (`tone: neutral|info|success|warning|danger`, `variant: title|body|caption|numeric`, `emphasis: normal|strong`).

| Group | Item | Built from | Notes |
|---|---|---|---|
| Layout | `Column`, `Row` | `AdaptiveSpacing` gaps | `children: ChildList` (static list or `{template, path}` over data) |
| | `Card` | the dashboard `_DashboardCardShell`, promoted to `PointyCard` | optional `title`, `subtitle`, `trailing` child |
| | `Section` | `PointySectionHeader` + child | |
| | `Divider` | | |
| Text | `Text` | `PointyTypography` ramp | `variant`, `emphasis`, `align: start|center|end` |
| | `Markdown` | `gpt_markdown` | for prose inside a card |
| | `Callout` | `PointyDetailCallout` | `tone`, `title`, `body`, optional action |
| | `StatusPill` | `PointyStatusPill` | `tone`, `label` |
| Numbers | `MetricGrid` / `Metric` | `PointyMetricGrid` + `PointyMetricTile` | `value`, `label`, `delta` (number + direction → arrow/tone computed by the widget, not the model), `unit: currency|count|percent` — formatting is the client's job |
| | `SummaryList` | `PointySummaryList` / `PointySummaryRow` | key/value rows, `total` row flag |
| | `Table` | `ReportResultView`'s `_SectionTable`, promoted to `PointyDataTable` | `columns[{key,label,kind:text|number|money|percent|date}]`, `rows: path`, `totals: bool`, optional `rowAction` (deep link per row) |
| Charts | `LineChart`, `BarChart`, `DonutChart`, `Sparkline` | new `lib/src/shared/charts/` extracted from the dashboard (`_SalesTrendChart`, `_HourlySalesChart`, `_PaymentMixChart`) | series colors come from a fixed palette ramp keyed by series index; axis formatting by `kind`; RTL-safe; height fixed by the widget. Dashboard is migrated to the shared widgets (dedupe) |
| Domain | `ProductCard` | catalog card visuals from `PointyCatalogPane` | by `variant_id` only; the widget fetches name/price/stock/image through the existing repository (no arbitrary image URLs in the schema) |
| | `EntityChip` | `PointyStatusPill` + icon | `type + id + label` → `pointy://` deep link. Also becomes the renderer for `pointy://` links in markdown (see A.4) |
| | `PurchaseOrderSummary`, `SaleSummary`, `CustomerSummary` | `PointyDetailHero` + `PointySummaryList` | fetch by id; used after actions ("here is what I created") |
| | `InvoiceIntakeReview` | new (Initiative B) | the flagship interactive card |
| Input | `Button` | themed `FilledButton`/`OutlinedButton` | `label`, `variant: primary|secondary|destructive`, `action` |
| | `ChoiceChips` | `ChoiceChip` themed | `options`, `multi`, bound `value` |
| | `TextField`, `NumberField`, `DatePicker`, `Checkbox` | existing global input theme | bound `value`; `NumberField` supports `unit`, `min`, `max`, `decimals` |
| | `Form` | Column + submit `Button` | wraps inputs; its submit sends the surface data model |

Deliberately excluded from v1: `Image` by URL, `Video`, `Audio`, `Modal`, `Tabs`, free icon names, any spacing/size props.

Drift guards (all automated):

1. `test/ai_ui/catalog_schema_lint_test.dart` + `apps/ai/test_ui_catalog.py`: the catalog JSON must not contain forbidden property names (`color`, `colour`, `background`, `style`, `font`, `padding`, `margin`, `width`, `height`, `radius`, `elevation`, `icon` as free string).
2. `DebugCatalogView` golden tests: every item rendered from its `exampleData`, light + dark, RTL, at phone and desktop widths. Added to `lib/dev/theme_preview.dart` as a new tab so it is also a design-review surface.
3. Parity test: Dart `CatalogItem.dataSchema` set == JSON catalog components set; property names match.
4. Server validator is strict (`additionalProperties: false`); anything not in the catalog never reaches a client.

### A.3 Frontend integration

- New feature package `lib/src/features/ai/ui/`:
  - `pointy_ai_catalog.dart` (all `CatalogItem`s, grouped per file under `ui/items/`).
  - `ai_surface_host.dart`: wraps `SurfaceController` per conversation; feeds `ui` events (`A2uiMessage.fromJson`), rebuilds surfaces from `AiMessage.uiSurfaces` on load; disposes on conversation switch/new/rewind (truncate must also drop surfaces).
  - `ai_surface_view.dart`: the widget placed in the assistant bubble; `RepaintBoundary`, `ValueKey(surfaceId)`, and it does **not** listen to the message notifier (surfaces are immutable once received; only their data model is live).
- Models: `AiChatUi` event (`ai_chat.dart`), `AiMessage.uiSurfaces` + `attachUiSurface` mutator, `fromJson` rehydration. `parseEvent` handles `ui`. VM: `_drive` routes `ui` to the host; `sendUiInteraction(surfaceId, name, context, data)`.
- Request flags: `supports_ui: true` on chat + resume bodies.
- Preview harness: `ai_chat_preview.dart` gains `?screen=ui` (a scripted answer with metrics + trend chart + table + entity chips) and `?screen=ui-form` (a small form round-trip with the fake repository).
- Streaming perf: surfaces attach once per tool result, not per token; the existing INVARIANT (never notify the VM per token) is untouched. Measure with `make frontend-perf-sweep` on `?screen=long` + `?screen=ui`.

### A.4 Chat shell UX improvements (independent of the engine, ship early)

These are grounded in the current code and are cheap relative to their payoff. They also make the screen file extensible before A.3 lands on it.

1. **Split `ai_assistant_screen.dart`** (3,411 lines) into `views/widgets/`: `assistant_message.dart`, `user_message.dart`, `question_card.dart`, `tool_activity.dart`, `composer.dart`, `sources.dart`, `sheets/`. Pure move, tests unchanged. Precondition for everything else.
2. **Working timeline instead of transient chips.** Group a turn's tool runs into one collapsible "يعمل…" strip (step count, elapsed, current step label); expand shows steps in order with the existing detail sheet. Mutating steps keep their accented persistent chip. Backend already emits `label`, `phase`, `mutates`; no server change.
3. **Suggested follow-ups.** The `done` event gains `suggestions: [str]` (≤ 3, model-generated in the final round through a tiny addition to the answer prompt; relay untouched). Rendered as chips under the last assistant turn; tap = seed prompt.
4. **Entity chips for deep links.** `pointy://` links inside markdown render as `EntityChip` (icon + label) via `GptMarkdown`'s link builder instead of underlined text.
5. **Starter prompts on the empty state**, keyed by `shop_type` and role (cashier vs manager), plus "scan an invoice" as a primary action.
6. **Stop button** while streaming (client aborts the stream; server `GeneratorExit` path already persists the partial answer). Composer shows send/stop toggle.
7. **Desktop keys:** Enter sends, Shift+Enter newline, Esc stops/clears attachment strip.
8. **One-tap retry after a failed resume** (documented v1 limitation): the client keeps the last answered question id; retry calls a new `POST /api/ai/chat/resume/retry/` that re-enters the loop for an already-`answered` paused message without re-recording the answer.
9. **Attachment capture for documents:** camera-first "scan" flow with multi-page capture, auto-crop hint, and a `document` downscale profile (long side 2,048 px, JPEG q85) instead of the universal 1,024 px, which is too small for dense invoices. Used by Initiative B.

### A.5 Phasing (Initiative A)

| Phase | Deliverable | Depends on |
|---|---|---|
| A-P0 (≈ 1 wk) | A.4 items 1, 2, 4, 5, 7; shared `lib/src/shared/charts/` extracted from the dashboard with goldens; the JSON catalog file drafted | — |
| A-P1 (2–3 d) | GenUI spike against the kill criteria; go/no-go recorded at the top of this file | A-P0 (charts) |
| A-P2 (≈ 1.5 wk) | Backend: `render_ui` tool, validator, `ui` SSE event, `ui_surfaces` persistence, `_ui_guidance`, tests. Frontend: catalog v1 (layout, text, numbers, charts, entity chips), surface host, rehydration, previews, goldens, drift lints | A-P1 |
| A-P3 (≈ 1 wk) | Inputs + `Form` + `ui_interaction` round trip; domain summary cards; A.4 items 3, 6, 8, 9 | A-P2 |
| A-P4 (ongoing) | Eval: 30 representative shop questions (analytics, comparisons, lists, decisions) scored for "used UI when it should / didn't when it shouldn't / valid on first try"; tune `_ui_guidance` | A-P2 |

---

## Initiative B — Autonomous invoice intake

### B.0 Design shift

Today the chat model *is* the pipeline. The plan moves the pipeline server-side into a deterministic service that uses the model only for the two fuzzy steps (reading the image, adjudicating ambiguous matches). The chat becomes one of two front doors to that service; the other is a "scan invoice" button on the Purchasing screen. Review happens once, on a single card, and creation is one transaction.

```
photo(s)/PDF ──► Intake job ──► Extraction (vision, strict JSON) ──► Arithmetic checks
      ──► Reconciliation (deterministic tiers → LLM adjudication for the remainder)
      ──► Plan (products/units/supplier to create, PO lines, warnings)
      ──► Review card (one GenUI surface, inline edits)  ──► Apply (1 transaction) ──► PO + attachment
                                    └── or auto-apply when everything is high-confidence and totals reconcile
```

### B.1 Data model and storage (backend `apps/purchasing/intake/` or new `apps/invoice_intake/`)

- `InvoiceIntake`: `id`, `created_by`, `source: chat|purchasing_screen`, `conversation` (nullable FK), `status: capturing|extracting|reconciling|planned|applied|failed|cancelled`, `pages` (M2M to `Attachment`), `extraction` (JSON), `plan` (JSON), `review_edits` (JSON), `purchase_order` (nullable FK), `supplier` (nullable FK), `confidence_summary` (JSON), `error`, timestamps.
- Pages are stored through the existing `apps/attachments` (the assistant currently keeps metadata only; intake needs the bytes). On apply, the pages are re-attached to the created PO — the invoice image travels with the PO for audit, which matters where the paper document is the legally authoritative record. Retention: intakes not applied are purged after 30 days (Celery beat).
- `ProductAlias.source` gains `ai_adjudicated` alongside `invoice` and `manual`, so machine-made matches can be weighted lower or revoked in bulk.

### B.2 Extraction (relay + backend)

- **Relay:** add `response_format` passthrough to `wireRequest` (`openrouter.go`) and to the `/v1/ai/chat` body (`ai.go`), gated to `json_schema` only; a new optional `purpose: "extract"` hint lets the relay pick `POINTY_RELAY_AI_EXTRACT_MODEL` (default = vision model) and bypass the difficulty router. Continuations are unaffected. Non-streaming `Complete` already exists; extraction uses the streaming path so the intake can show progress.
- **Schema `InvoiceExtraction`** (`apps/invoice_intake/schemas.py`, also the tool contract): `supplier{name, phone?, tax_id?, address?}`, `invoice_number?`, `date?`, `currency?`, `lines[{index, raw_name, quantity, unit_label?, pack_size?, unit_cost, line_total?, barcode?, notes?, confidence}]`, `subtotal?`, `discount?`, `tax?`, `total?`, `page_count`, `warnings[]`.
- **Arithmetic checks** (deterministic): per line `qty × unit_cost ≈ line_total` (tolerance 1%); `Σ line_total ≈ subtotal`; `subtotal − discount + tax ≈ total`. A failed line check triggers a **targeted second pass**: re-send the page(s) with the list of flagged lines and ask only for those, at the frontier tier. A failed total check is surfaced on the review card, never silently accepted.
- **Multi-page**: all pages go in one extraction request when they fit the image cap (`POINTY_RELAY_AI_MAX_IMAGES`, raise the per-request cap for `purpose: extract` to 10); otherwise pages are extracted per request and lines concatenated with `index` continuity.
- **Pack/unit language**: the schema asks for `unit_label` and `pack_size` verbatim (e.g. "كرتونة 12", "شد 6"), so B.3 can map to `ProductUnit` and avoid the base-unit scale bug class already documented for UoM costs.

### B.3 Reconciliation (backend, deterministic first)

Extend `_match_invoice_line` into a tiered `reconcile_lines(extraction, supplier)`:

1. barcode exact → `ProductVariant.barcode` and `ProductUnitBarcode` (carton EANs).
2. learned alias exact (`ProductAlias`, all sources).
3. normalized-exact name against product/variant names (existing).
4. **supplier purchase history** (new, strong prior): products previously bought from this supplier, matched by normalized name similarity and by last-known cost proximity; this alone resolves most repeat invoices.
5. fuzzy candidates: existing token-Jaccard plus PostgreSQL trigram (`pg_trgm`, indexed on `search_normalize(name)`) — top 6.
6. **LLM adjudication** for what is left: one text-only smart-tier call per batch of ≤ 20 lines with `{raw_name, qty, unit_cost, candidates[{variant_id, name, barcode, last_cost, price}], supplier_history_hint}` → strict JSON `{decisions[{index, decision: match|new|ambiguous, variant_id?, confidence, reason}]}`. Auto-accept `match` at confidence ≥ 0.85 **and** cost within the purchase cost guard's tolerance of the candidate's last cost; otherwise `ambiguous`.
7. Unit mapping: `unit_label`/`pack_size` → an existing `ProductUnit` on the matched product, else a proposed new purchase unit `{name, factor}` in the plan; unit cost stays per pack, base cost derived per the UoM normalization rule.
8. Cost sanity: run the existing purchase-time cost guard (cost vs sale price, cost vs previous cost, base-unit scale) → `warnings` per line, never a block at this stage.
9. Supplier: existing `_match_supplier` plus phone/tax-id exact; else propose create-by-name.

Output: `IntakePlan` = `{supplier: {id | create{name,...}}, creates: [{line_index, product{name, barcode?, category_id?, unit_price (from suggest_sale_price), tracks_expiry: false}, unit?}], lines: [{line_index, variant_id | create_ref, unit_id | unit_create_ref, quantity, unit_cost, status: matched|auto|new|review, confidence, warnings[]}], totals_check, po: {supplier_invoice_number, supplier_invoice_date, currency, notes}}`.

Category guess for new products: nearest existing category by name similarity to the raw line and to the supplier's usual categories; left blank below a threshold (the user can set it on the card).

### B.4 Apply (one transaction, idempotent)

`apply_intake(intake_id, edited_plan, options)` in `apps/invoice_intake/services.py`, wrapped in `transaction.atomic()` and keyed on the intake id (re-applying returns the existing PO):

1. Create/lookup supplier.
2. Create products with nested `default_variant{unit_price, barcode}` (existing serializer path, so SKU generation and identity-conflict `conflicts` 400s apply — a conflict aborts the whole apply with the offending line highlighted).
3. Create `ProductUnit`s.
4. Create the PO through `save_purchase_order_with_lines` (draft by default; `submit` if the user chose), with `supplier_invoice_number/date`, `acknowledge_cost_warnings` from the review.
5. Attach the pages to the PO.
6. Optional, permission-gated: receive in full; record supplier payment (cash → reuses the POS cash-purchase register linkage rules; otherwise a plain supplier payment).
7. Learn aliases from every user-confirmed or auto-accepted match; record `ai_adjudicated` for the latter.

Everything runs as the requesting user through the same serializers/viewset services, so permissions and side effects (valuation ledger, cost guard, catalog version bump) are the real ones.

### B.5 Review UI (the one screen)

A GenUI domain card `InvoiceIntakeReview`, emitted by the backend (not composed by the model) as the `ui` event on the intake tool's result, and also mounted standalone from the Purchasing screen. Contents:

- Header: supplier (matched or "new"), invoice number/date, page thumbnails (tap → full-screen viewer with pinch-zoom), totals check (extracted vs computed, tone by delta).
- Lines table grouped by status with counts: **matched** (barcode/alias/exact/history), **auto** (AI adjudicated, confidence shown, tap to change), **new** (editable name, barcode, sale price prefilled from `suggest_sale_price`, category), **needs attention** (missing qty/cost, cost anomaly, unit unknown, totals mismatch). Row tap opens the existing `AsyncMultiSelectPicker` product search (variant-keyed) with the "create new" alternative — the same control the `product_picker` question uses today.
- Line-level edits: quantity, unit, unit cost, remove line, merge duplicate lines.
- Footer (sticky): `Create draft PO`; secondary menu `Create & submit`, `Create & receive`, `Create, receive & pay` (each permission-gated). Disabled while any "needs attention" line remains unresolved.
- Result: a `PurchaseOrderSummary` card with a deep link, and the chat says one line.

Edits post to `POST /api/invoice-intakes/{id}/apply/` directly from the card (a `submit:` action handled by the client without a model round trip); the assistant is told the outcome via a synthetic tool result so the conversation stays coherent.

### B.6 Chat integration and zero-touch mode

- The chat tool `match_invoice_products` is replaced by `start_invoice_intake(attachment_refs)`; attachments are now saved (B.1) and referenced by id, so the "image seen only on turn 1" crux disappears. The tool enqueues the job and streams progress as `tool` phases (`extracting`, `checking`, `matching 12/40`, `planning`) while the HTTP stream is held; the existing `ping`s keep the connection alive. If the job exceeds 90 s the tool returns `{status: running, intake_id}` and the client polls `GET /api/invoice-intakes/{id}/` to render the card when ready.
- `_action_guidance`'s five-step invoice playbook shrinks to: "when the user sends an invoice or asks to enter one, call `start_invoice_intake`; do not extract lines yourself; after the card is shown, answer only questions about it."
- **Zero-touch**: shop setting `ai_invoice_auto_apply` (manager-only, default off). When on, an intake with no `review`/`new` lines, all `auto` matches ≥ 0.95, and a passing totals check is applied immediately as a **draft** PO; the card still shows with an "undo" (cancel PO) button for 24 h. New products are never created without review.
- Entry points: chat composer "scan invoice" action; Purchasing screen `Scan invoice` button; Android share-target for images/PDFs (later).

### B.7 Evaluation and rollout

- **Invoice corpus**: collect ≥ 40 real supplier invoices (thermal, dot-matrix, handwritten, multi-page, foreign-currency) from the first clients; store under `backend/apps/invoice_intake/evals/` with golden `InvoiceExtraction` JSON and expected reconciliation against a fixture catalog. Metrics: line recall, quantity/cost exact-match rate, false auto-match rate (must be ≈ 0), review-lines-per-invoice (the number the user actually touches), end-to-end time.
- `make ai-intake-eval` runs the corpus against the configured relay models and prints the table; run on every prompt/schema/model change.
- Rollout: behind `supports_ui` + a shop feature flag `invoice_intake_enabled`; first with review-only, then enable zero-touch per shop after their false-auto-match rate is observed at 0 over ≥ 20 invoices.

### B.8 Phasing (Initiative B)

| Phase | Deliverable | Depends on |
|---|---|---|
| B-P0 (≈ 3 d) | Relay `response_format` + `purpose: extract` passthrough with tests; document capture profile (A.4 item 9); attachment persistence for intakes | — |
| B-P1 (≈ 1.5 wk) | `InvoiceIntake` model + extraction service + arithmetic checks + targeted second pass; eval corpus v1 and `make ai-intake-eval` | B-P0 |
| B-P2 (≈ 1.5 wk) | Reconciliation tiers incl. supplier history, `pg_trgm`, LLM adjudication, unit mapping, cost guard warnings; `IntakePlan`; `apply_intake` transaction; API (`/api/invoice-intakes/`) | B-P1 |
| B-P3 (≈ 1.5 wk) | `InvoiceIntakeReview` catalog item + standalone Purchasing entry; chat tool `start_invoice_intake` with progress; playbook rewrite; alias learning incl. `ai_adjudicated` | A-P2 (surface host), B-P2 |
| B-P4 (≈ 3 d) | Zero-touch mode + undo; feature flags; telemetry (`intake.completed` with review-line counts) | B-P3 |

A and B can run in parallel from the start; the only cross-dependency is B-P3 on A-P2. If A slips, B-P3 ships the review card as a plain Flutter screen reached from a deep link in the chat, and is wrapped into a catalog item once the surface host lands (a catalog item is just a widget with a schema).

---

## Cross-cutting

**Security.** `render_ui` is read-only and renders nothing that is not a catalog item; entity cards fetch by id through the user's own permissions (same repositories the screens use). `submit:` interactions are user turns, so they cannot trigger a write without the model calling a write tool, which keeps the existing confirm-before-irreversible rule, idempotency keys and the per-turn write cap intact. `apply_intake` runs under the user's permissions and is a normal authenticated endpoint. Invoice pages live on-prem only; they are sent to the relay for extraction exactly as chat attachments are today.

**Telemetry.** New events: `ai.ui_rendered` (component counts, validity on first try), `ai.ui_interaction`, `intake.stage` (durations per stage), `intake.completed` (lines matched/auto/new/review, apply options). All ride the existing analytics pipeline with its burst guards.

**Compat branch.** None of this targets `compat/win8`.

**Docs/memory.** Record the GenUI go/no-go outcome and the catalog drift rules in `AGENTS.md` (UI Preview Harness section) and in the project memory once A-P1 concludes.

## Risks

| Risk | Mitigation |
|---|---|
| `genui` alpha churn breaks builds | Exact version pin; engine isolated behind `ai_surface_host.dart`; native fallback renderer designed in |
| Heavy transitive deps (`video_player_win`) bloat the Windows installer or fail to build | Kill criterion 1 in the spike; fallback renderer |
| Model emits invalid UI often → wasted rounds | Strict validator with actionable errors; catalog examples in prompt; eval A-P4; provider choice per tier |
| Catalog prompt tokens on every turn | Only when `supports_ui`; static prefix placement for provider caching; keep catalog ≤ 6k tokens |
| Extraction misreads quantities/costs on low-quality photos | Document capture profile, arithmetic checks, targeted second pass, review card never hidden when checks fail |
| False auto-match creates wrong PO lines | Deterministic tiers before the LLM, confidence + cost-proximity double gate, `ai_adjudicated` alias source revocable, zero-touch off by default |
| Long intake jobs hold the SSE stream | Progress phases + `ping`s; 90 s handoff to polling |
| Orphans on partial apply | Single `transaction.atomic()` apply keyed on intake id |
