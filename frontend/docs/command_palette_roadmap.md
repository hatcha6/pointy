# Command Palette — Roadmap & Ideas

A backlog of enhancements for the global ⌘/Ctrl+K palette, synthesized from (a) a full
inventory of what Pointy can already do, and (b) deep research into best-in-class command
palettes (Raycast, Linear, Superhuman, VS Code, Spotlight) and production POS keymaps
(WooPOS, RetailEdge, Lightspeed R/X-Series, MS Dynamics RMS). Each item notes **why it
matters**, **how it maps to existing Pointy code**, an **exemplar**, and rough **effort**.

## What ships today
Jump to any screen · search products (name/barcode), customers, suppliers, invoices, POs →
open detail · quick actions (new sale, new PO, record expense, start stock count) · recents
(persisted, re-open by id) · row actions (print label, reorder, reprint) with Tab/Enter
keyboard accelerators · capability-gated throughout.

The research confirms the **load-bearing baseline is already in place**: one consistent
shortcut summonable everywhere, two jobs (navigation + quick-actions), the four-part anatomy
(trigger / search / recent-first list / execution feedback), and keyboard ergonomics.

---

## P0 — Quick wins (hours–days, the framework already supports them)

### 1. More searchable entities
Add **Jobs/repairs, Discounts, Employees, Payroll runs, Stock-count sessions, Users** as
`AsyncCommandSource`s (~10 lines each, capability-gated). *Why:* "find anything" should mean
anything. *Maps to:* each has a list/search repo method + detail screen (`operationsRepository.loadJobs`,
`discountRepository.loadDiscountRules`, `employeeRepository.loadEmployees`/`loadPayrollRuns`,
`stockCountRepository.loadCounts`, `userRepository.loadUsers`). *Exemplar:* Linear (search any object).

### 2. "Run report" commands
Expose the 9 `ReportRunType`s as quick actions ("run sales summary", "run reorder list",
"run Z/register closure"). *Why:* managers reach for reports constantly; one keystroke to a
PDF. *Maps to:* `_AuthenticatedRoutes.previewReport(request)` already builds+previews. *Exemplar:* Stripe dashboard.

### 3. More row actions (per-entity verbs)
The row-action framework is built — just add `CommandRowAction`s: Product → archive/restore,
view stock movements; Invoice → void, return, **share PDF**; PO → **receive**, **send to vendor**,
print, cancel, share PDF; Discount → enable/disable; Payroll run → approve, mark paid; Fraud
finding → review/dismiss. *Why:* act without opening the screen. *Maps to:* every method exists
(`archiveProduct`, `voidOrder`, `receiveOrder`, `enable/disableDiscountRule`, `approvePayrollRun`,
`review/dismissFinding`, `shareSaleInvoice`/`sharePurchaseOrder`). *Exemplar:* Raycast contextual actions.

### 4. Confirm destructive actions
Wrap void / cancel / archive / mark-paid in a confirm step. *Why:* these move money/inventory;
the four-part anatomy stresses **execution feedback** for real actions. *Maps to:* `PointyDestructiveConfirmationDialog`.

### 5. Show the matched alias
When a result matched on a keyword, show it (e.g. `شاشة البيع (pos)`). *Why:* confirms *why* a
row matched and teaches vocabulary. *Maps to:* `CommandItem.keywords` already exist — surface the hit.
*Exemplar:* Superhuman ("Mark Done (archive)"), Raycast alias badges.

### 6. Cash-management verbs
Open drawer / no-sale, cash pay-in & pay-out (record register cash movement), start/close
register session. *Why:* the single most universal cashier/manager verbs across **every**
production POS keymap surveyed. *Maps to:* register-session repo + `createRegisterCashMovement`.
*Exemplar:* MS Dynamics RMS (cash drop/payout, X/Z report, no-sale).

---

## P1 — High-impact (the features that make it indispensable)

### 7. Context-aware actions ⭐ (biggest differentiator)
Surface actions for the **current screen/object** at the top of the palette: on the open cart →
"apply discount / add payment / void line / hold sale"; on a PO → "receive items / send to
vendor / cancel"; on an invoice → "void / return / reprint". *Why:* the #1 verified pattern
("show/hide commands by app state") — turns ⌘K from a global launcher into a verb surface for
the task in hand. *Maps to:* needs a lightweight "active context" registry that open screens
publish to (e.g. the POS screen registers its cart verbs); the scope already centralizes
navigation. *Exemplar:* Superhuman, Linear. *Effort:* L.

### 8. "What needs attention" surface ⭐
A section (on empty query) or command listing **business alerts**: low/out-of-stock, expiring
batches, overdue POs, register variance, payroll-ready, fraud signals — each jumps to the fix.
*Why:* turns the palette into a daily cockpit; directly answers the "proactive intelligence"
gap from the original audit. *Maps to:* `businessAlertRepository.loadAlerts()` + the existing
`openBusinessAlert` handlers + `BusinessAlertType` (12 types). *Exemplar:* Raycast's "today" view. *Effort:* M.

### 9. Fuzzy + Arabic-aware matching
Replace the sync substring `CommandItem.matches` with a fuzzy scorer (command-score style,
score threshold), and **normalize Arabic** before matching: strip tashkeel, fold alef/hamza
(أ/إ/آ→ا) and taa-marbuta (ة→ه), and map Arabic-Indic ↔ ASCII digits (٠–٩ ↔ 0–9). *Why:*
cashiers transpose under speed ("lnik"→"link"); Arabic exact/prefix matching is especially
brittle, and barcodes/SKUs mix digit systems. *Maps to:* `CommandItem.matches` (+ pass the
same normalization to entity-search query strings). *Exemplar:* Superhuman/Raycast fuzzy. *Effort:* M.
> Open question the research flagged: confirm the exact Arabic normalization set with real
> product/customer data; no source covered Arabic fuzzy specifics.

### 10. Prefix-scoped modes in one box
A leading sigil scopes the search: `>` actions · `#` screens · `@` customers · `/` reports ·
plain text = everything. *Why:* one ⌘K hosts many scopes without extra shortcuts to memorize.
*Maps to:* parse the leading char in the sheet → restrict which sources run. *RTL caveat
(verified):* evaluate by **logical first-typed character**, not visual position; consider a
visible **mode-chip** selector so touch users (and Arabic typists who may find Latin sigils
unnatural) aren't forced to type sigils. *Exemplar:* VS Code (`>`/`@`/`#`/`:`). *Effort:* M–L.

### 11. Inline-argument / multi-step actions (mini-forms)
Let an action take one input without leaving the palette: "record expense → amount", "reorder
→ qty", "cash pay-out → amount + reason", "add payment → amount". *Why:* complete a quick
action in-place; a verified high-value advanced pattern. *Maps to:* extend the sheet with a
second "prompt" step (a focused field that feeds the action). *Exemplar:* Raycast arguments;
the Flutter `command_palette` package's `input`/nested-action types validate the approach. *Effort:* M–L.

### 12. Inventory quick-filters → deep-link
"low-stock products", "expiring soon", "unpaid invoices", "today's sales" → open the list
**pre-filtered**. *Why:* turns a vague worry into an actionable list in one keystroke. *Maps to:*
`ProductStockFilter`, `SaleOrderQuery`, etc. — needs screens to accept an initial filter (the
activity log already does this via `applyInvestigationQuery`). *Exemplar:* GitHub's saved
filters in the palette. *Effort:* M.

---

## P2 — Exploratory (validate value first)

### 13. Frecency ranking + pinned/favorites
Rank by frequency×recency, and let users **pin** a product/customer/action. *Why:* the few
things you touch all day float to the top. *Maps to:* extend the persisted recents store with
usage counts + a pinned list. *Exemplar:* Raycast/Spotlight ranking, Linear favorites. *Effort:* M.

### 14. "Create from query" on no-results
Search a customer/product that doesn't exist → offer "create 'X'". *Why:* removes a dead end.
*Maps to:* `createCustomer`/`createProduct` drafts (or navigate to the create form pre-filled).
*Exemplar:* Linear, Notion. *Effort:* M.

### 15. Touch-terminal ergonomics
Many POS terminals have no keyboard. Consider a **persistent search bar**, a barcode-scanner
that opens straight into product results, and (since there's no Alt to "hold for tooltips")
always-visible action affordances. *Why:* the keyboard-accelerator wins don't translate to
touch — the palette must be first-class by tap too. *Exemplar:* Square/Lightspeed touch sell
screens. *Effort:* M.

### 16. Accessibility semantics (web/screen-reader)
Annotate the sheet with combobox/listbox/option Semantics and keep focus on the input while a
highlight moves (the `aria-activedescendant` pattern). *Why:* screen-reader usability. *Caveat
(verified):* real-world `activedescendant` support is inconsistent (VoiceOver/mobile often
ignore it) and **no source tested Arabic/RTL announcement** — verify on the actual target
readers. *Maps to:* Flutter `Semantics` (differs from raw ARIA — needs care). *Exemplar:* W3C ARIA APG. *Effort:* M.

### 17. Calculator / quick math
Type `12.5*8` → show the result (and offer "use as price"/"as change"). *Why:* handy at the
counter. *Caveat:* research found **no POS-specific evidence** this earns its place vs. clutter —
ship behind a flag and watch usage. *Exemplar:* Spotlight, Raycast. *Effort:* S.

---

## Do NOT build (refuted by the research)
- **"One palette must hold every command"** — splitting scopes (e.g. a separate quick-switcher)
  is fine; don't contort everything into one list.
- **Auto-generate POs on low stock** as a headline workflow — not a real/expected POS behavior;
  prefer a *suggested reorder list* the manager reviews (see #8/#12).

## Open questions worth a quick spike
1. The exact Arabic normalization set (diacritics, alef/hamza/taa-marbuta, Arabic-Indic digits,
   Arabic↔Latin transliteration) against real Pointy data.
2. RTL behavior of prefix sigils + whether a visible mode-chip beats typed `>`/`@` for Arabic users.
3. How the keyboard accelerators degrade gracefully on keyboard-less touch terminals.

## Suggested sequence
1. **Sprint 1 (P0):** entities #1, report commands #2, row actions #3 + confirm #4, cash verbs #6, matched-alias #5.
2. **Sprint 2 (P1):** context-aware actions #7 + "needs attention" #8 (the two that change how the palette *feels*).
3. **Sprint 3 (P1):** fuzzy+Arabic #9, prefix modes #10, inline arguments #11, quick-filters #12.
4. **Later (P2):** frecency/pins, create-from-query, touch ergonomics, a11y, calculator.

---

### Sources (verified, deep-research pass)
- Superhuman — *How to build a remarkable command palette* (focus contract, fuzzy, aliases, context ranking)
- VS Code docs / design-bootcamp — prefix-scoped modes (`>`/`@`/`#`/`:`)
- Mobbin glossary — two jobs (navigation + quick-actions); four-part anatomy
- WooPOS, RetailEdge, Lightspeed R/X-Series, MS Dynamics RMS 2009 — cashier/back-office verb vocabulary
- Square — purchase-order verbs (create/edit/send-to-vendor/receive)
- W3C ARIA APG (combobox) — accessibility contract
- pub.dev `command_palette` changelog — nested actions + inline `input` pattern precedent
