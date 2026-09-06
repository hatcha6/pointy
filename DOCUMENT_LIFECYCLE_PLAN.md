# Documents & Document Lifecycle — Architecture Plan

**Date:** 2026-09-05
**Status:** Phases 1 and 2 shipped — the primitive, `PurchaseOrder` and `Order`.
See §11 for what landed and §9 for what is next.
**Roadmap slot:** [ERPNEXT_BENCHMARK_PLAN.md](ERPNEXT_BENCHMARK_PLAN.md) §7 Phase 1a + 1b — the last
unbuilt piece of the correctness spine.
**Mirror project:** [frappe/erpnext](https://github.com/frappe/erpnext) and the Frappe framework
underneath it, whose `docstatus` is the most beaten-on implementation of this idea in existence.

---

## 1. The problem, stated precisely

Pointy has no concept of *a document*. It has twenty-odd tables that each invented their own answer
to the same four questions: when does this row stop being a draft, when is it allowed to change, how
is it undone, and what does undoing it undo?

There are four incompatible dialects in the tree today:

| Model | States | What the field actually means |
|---|---|---|
| `sales.Order` | `open` / `paid` / `void` | Lifecycle **and** payment, conflated |
| `purchasing.PurchaseOrder` | `draft` / `submitted` / `partially_received` / `received` / `cancelled` | Lifecycle **and** fulfilment progress, conflated |
| `employees.PayrollRun` | `draft` / `approved` / `paid` / `void` | Lifecycle **and** approval **and** payment, conflated |
| `payments.Payment`, `expenses.Expense`, `purchasing.PurchaseReceipt` | *(none)* | Born final, editable and deletable forever |

Five different functions undo a document, no two with the same contract:
[`void_order`](backend/apps/sales/services.py:1674),
[`void_payroll_run`](backend/apps/employees/services.py:602),
[`cancel_purchase_order`](backend/apps/purchasing/services.py:2108),
[`cancel_job`](backend/apps/operations/services.py:434),
[`cancel_intake`](backend/apps/invoice_intake/services.py:553).

### 1.1 What that has already cost us

This is not a tidiness argument. Every one of these is a merged fix from the last three weeks, and
all of them are the same bug wearing different clothes:

- **#131** — a voided sale still left profit on the books.
- **#134** — a voided sale still ranked as the shop's best seller.
- **87117460** — "a purchase order stays editable until money settles against it": an entire
  hand-written editability rule, plus an unwind-and-rebuild of the delivery, because there was no
  primitive that could say *this document is closed now*.

Each was fixed inside one domain. The next domain will pay for it again.

### 1.2 The two live defects this design closes on day one

Both were found while writing this plan, both are consequences of having no primitive, and both are
closed as of Phase 2 (§10):

1. **`Order.status = open` means two unrelated things.** A standard sale that is `open` is a cart on
   a screen. A *credit* invoice that is `open` is an issued, delivered, revenue-recognised sale that
   happens to be unpaid. Every report in the system has to know this, which is why
   [`recognized_sale_q`](backend/apps/sales/models.py:474) and `transactional_sale_q` exist and are
   spread across 41 call sites. Nobody can add a query to this codebase without learning that rule
   first, and the day someone writes `status="paid"` without it, revenue quietly drops by the value
   of every credit invoice outstanding.

2. **Voiding a sale does not check the period lock.** [`period_lock.py`](backend/apps/core/period_lock.py:1)
   opens by naming this exact scenario — "a cashier could void a September sale on the 4th" — and
   `assert_period_open` is duly called by expenses, treasury, payroll and supplier payments.
   `void_order` never calls it. September's revenue can still be rewritten in October, from the
   returns desk, by anyone. There is no bug report for this because nobody has noticed yet.

A primitive fixes #2 once, for every document type that will ever exist, instead of eight times.

---

## 2. What ERPNext actually does

Frappe's model, mechanically:

- Every submittable DocType carries `docstatus`: **0 = Draft, 1 = Submitted, 2 = Cancelled**.
- `submit()` writes the document's side effects — GL Entries, Stock Ledger Entries, updates to linked
  documents' fulfilment fields — inside one transaction, and flips `docstatus` 0 → 1.
- A submitted document is **immutable**: `_validate_update_after_submit` compares the in-memory doc
  against the stored row and raises unless the changed field is flagged `allow_on_submit`.
- `cancel()` flips 1 → 2 and unwinds the side effects. Modern versions post **reversing** ledger
  entries rather than deleting rows (`Cancelled` flags on the originals).
- Correction is **cancel + amend**: a new document is created with `amended_from` pointing at the
  cancelled one and a name suffixed `-1`, `-2`, …
- Cancelling checks **links**: a scan across every DocType with a Link field to this one, refusing
  while a submitted document still points at it.
- Alongside `docstatus`, most transaction DocTypes carry a separate derived `status` field
  ("To Bill", "Partly Paid", "Completed", "Closed") maintained by a hand-written `set_status()`.

That last point is the one thing ERPNext gets structurally right that we get wrong: **lifecycle and
progress are two different axes and they keep two different fields.** Our `PurchaseOrder.status`
tries to be both, which is exactly why `cancel_purchase_order` cannot cancel a received order — the
lifecycle information it needs has been overwritten by fulfilment information.

---

## 3. Where ERPNext fails, and what we do instead

Ten traps. Each is a real, documented failure mode of the mirror project; each gets a decision.

### T1 — Cancel-and-amend is a bulldozer
In ERPNext the *only* way to correct a submitted document is to cancel it, which unwinds everything
downstream, which is refused while anything downstream is submitted. Fixing a typo'd supplier
invoice number can mean cancelling a Payment Entry, a Purchase Receipt and a Purchase Invoice, then
re-entering all three. This is the single most common complaint about the model, and it is why real
deployments hand out the "Cancel" permission far more widely than they should.

**Ours:** four separate correction routes, chosen by *what the change actually touches*, declared
per document type:
- **`ALLOW_AFTER_SUBMIT`** — a named allow-list of fields with no financial consequence (notes,
  supplier invoice number, due date, customer reference). Editable in place on a submitted document,
  every edit written to the document trail with a before/after diff. No cancellation, no reversal.
- **`AMEND`** — the ERPNext route, for a document whose *numbers* are wrong: cancel, then a
  successor carrying the corrections.
- **`COUNTER`** — a reversing document (return, refund, credit note, negative adjustment), for a
  document whose numbers were right at the time and where the world has since changed.
- **`IN_PLACE`** — rewrite the submitted document itself, while a condition the type declares still
  holds. This one has no ERPNext equivalent at all, and it is the deliberate divergence: a Pointy
  purchase order stays correctable until money settles against it (commit `87117460`), because an
  owner who typed the wrong cost must not have to cancel a delivery to fix a digit.

  Its cost is real and worth stating plainly: the original figures are not preserved as their own
  version, so the audit trail records *that* a value changed and *what to*, but the superseded
  document is not independently readable the way an amendment's predecessor is. What makes it a
  route rather than a hole is that the closing condition, the permission and the period lock are all
  checked by the primitive, and the before/after of every field the rewrite touched lands in the
  trail — where today's code records only that something was "updated". Converting this route to a
  true amendment is one clause of the registry, and is the next step for purchase orders.

ERPNext has all three behaviours but only names one of them, so users reach for cancel by reflex.
Naming them, and forcing each document type to declare which apply, is most of the fix.

### T2 — Immutability is enforced in one Python method, and ERPNext itself routes around it
`_validate_update_after_submit` only runs on `doc.save()`. `frappe.db.set_value`, `doc.db_set(...)`,
and raw SQL all bypass it, and ERPNext's own code uses those constantly on submitted documents. The
guarantee is real in principle and porous in practice.

**Ours:** enforce the freeze at the **model** layer *and* at the **queryset** layer — `save()` diffs
frozen fields against the stored row, and the manager's `update()` refuses to touch frozen columns on
non-draft rows. Both raise `DocumentFrozen`.

There is one deliberate escape hatch, `documents.guards.system_write()`, a context manager that
lifts the freeze for machine paths that legitimately rewrite history: `repost_valuation` restamping
`OrderLine.unit_cost`, data migrations, the backup restore, and the business simulation. This follows
the doctrine `period_lock.py` already sets down — *guards govern people, not code* — and it is
greppable, so "who is allowed to write to a submitted document" is a five-second question with a
finite answer. A test asserts the set of call sites stays finite.

We deliberately do **not** use database triggers. They would also block the repost, the restore and
the oracle, and the house style is one enforcement layer you can read, not two that disagree.

### T3 — The amendment chain has no head and no current-version pointer
`amended_from` points backwards only. Finding the live version of a document means walking the chain
forward with a query per hop, so ERPNext reports mostly don't, and a cancelled-and-amended invoice
shows up in naive queries alongside its replacement.

**Ours:** both directions. `amended_from` (predecessor) and `superseded_by` (successor, indexed and
nullable), so "current version only" is `superseded_by__isnull=True` — an index scan, not a
subquery — and "where did this go?" is one read. The redundancy is written in exactly one place, by
the amend transition.

This also *retires* an existing hand-rolled field: [`Order.converted_to`](backend/apps/sales/models.py:348),
which links an accepted quotation to the sale that replaced it, is `superseded_by` with a different
name.

### T4 — Amendment mangles the document number
ERPNext renames the successor `ACC-SINV-2026-00042-1`. The customer holding a printed receipt for
`00042` now holds a number that matches nothing, integrations that parse the number break, and a
document amended twice is `-1-1`.

**Ours:** **the number never changes.** Amendment increments `amendment_index` (0, 1, 2 …) and the
uniqueness constraint moves from `number` to `(number, amendment_index)`. The number identifies the
*document*; the pair identifies the *version*. Lookup by number — the returns desk scanning a
receipt — resolves to the current version by construction.

### T5 — Reversals get posted on the original date, silently rewriting closed periods
ERPNext exposes this as a global setting, and the wrong choice is the default in older versions: a
cancellation writes its reversing entries on the *original* posting date, so cancelling a June
invoice in August changes June's numbers after June was reported.

**Ours:** **a reversal always posts on the date it happens.** Never backdated. Not configurable,
because there is no honest reason to want the other behaviour.

But dating the reversal correctly is only half of it, and the half ERPNext argues about is the less
important one. **A retraction also changes what the *original* period reports**, whatever its
reversal is dated: every report filters a document by its own money date and reads its status, so
voiding a September sale moves September's revenue even when the counter-entry is stamped in October.
So the lock is checked against *both* dates — the original document's money date and the reversal's —
and it is the first of those that actually bites. That is the check `void_order` has never had.

### T6 — "Cancelled" and "reversed by a counter-document" are conflated in reporting
A cancelled Sales Invoice and a Sales Return mean opposite things to a business — one is *this never
happened*, the other is *this happened and then was given back* — and ERPNext's reports treat the
distinction inconsistently.

**Ours:** the distinction is structural, not stylistic. `CANCELLED` means the document is retracted
and its side effects reversed. A return/refund/exchange is a **separate submitted document** that
points at its origin, and the origin stays `SUBMITTED`. Our sales code already does exactly this
(`OrderAdjustment` + `Order.status = void`), and the lifecycle keeps that shape rather than
flattening it. The reason it matters: a shop's *returns rate* and its *cashier void rate* are two
different fraud signals, and `apps.fraud` already reads them separately.

### T7 — Everything is submittable, so cancel paths exist that nobody has ever run
ERPNext marks ~100 DocTypes submittable, including many that are configuration. Untested cancel
paths are where the data-integrity bugs live.

**Ours:** a **closed registry**. A model is a document only by explicit registration, and
registration requires declaring the full contract (§5). A test walks the registry and asserts every
registered type actually implements every clause — you cannot register a document type and forget to
write its reversal.

### T8 — The derived `status` field drifts from reality
`set_status()` is hand-written per DocType, called from a dozen places, and reliably drifts: the
classic ERPNext support answer is "run `repost_item_valuation` / re-save the document to fix the
status".

**Ours:** progress is computed by **one function per type**, invoked from **one place** (the
primitive, after every transition and every dependent write), and there is an invariant test —
`status == recompute(status)` for every document in the fixture, plus an oracle assertion at
simulation scale. A drifted status becomes a failing test rather than a support ticket.

### T9 — Whoever can submit can cancel
In a shop this is exactly wrong. A cashier submits a hundred sales a day; a cashier must not be able
to unwind yesterday's.

**Ours:** every transition has its own permission and its own **window**. Within the correction
window the operator who created the document may retract it; after it, a manager or an explicit
permission holder must. This generalises [`validate_order_adjustment_allowed`](backend/apps/sales/services.py:1432)
and its `process_return_lookup` bypass — which is already the right policy, written once for one
table.

### T10 — Drafts are inert, which is useless for a till
ERPNext drafts hold nothing. Our drafts must hold real things: an open POS cart commits stock, a
quotation reserves it, a draft PO records expected stock.

**Ours:** the registry declares what a draft may touch. The rule is that a draft may only take
**reversible, unvalued** positions — reservations, commitments, expected quantities — and may never
write to the stock ledger, the money position, or a receivable. Those are submit-time effects, full
stop. This is a genuine extension of the ERPNext model rather than a copy of it, and it is what
makes the primitive usable at a counter.

---

## 4. The model

### 4.1 Three axes, never conflated

| Axis | Field | Owner | Values |
|---|---|---|---|
| **Lifecycle** | `doc_status` | the primitive | `draft` → `submitted` → `cancelled` |
| **Progress** | the existing `status` (where it exists) | one recompute function per type | fulfilment/settlement, always derived |
| **Approval** | separate gate | the type's policy | optional pre-submit requirement |

Three lifecycle states, not four. "Amended" is not a state: it is `cancelled` plus a non-null
`superseded_by`, so it stays derivable and no report has to learn a fourth value.

### 4.2 The mixin

```python
class DocumentMixin(models.Model):          # abstract
    doc_status      = CharField(choices=DocumentStatus, default=DRAFT, db_index=True)
    submitted_at    = DateTimeField(null=True)
    submitted_by    = FK(User, null=True, on_delete=SET_NULL)
    cancelled_at    = DateTimeField(null=True)
    cancelled_by    = FK(User, null=True, on_delete=SET_NULL)
    cancel_reason   = TextField(blank=True)
    amended_from    = FK("self", null=True, on_delete=SET_NULL)
    superseded_by   = FK("self", null=True, on_delete=SET_NULL, db_index=True)
    amendment_index = PositiveSmallIntegerField(default=0)
```

Lifecycle fields live **on the domain row**, not in a central registry table. The POS hot path cannot
afford a join, the stock ledger already addresses documents as `(voucher_type, voucher_id)` with no
registry and that works, and a second copy of state is a second thing that can drift. What genuinely
needs its own table is the trail (§4.5) — and nothing else.

### 4.3 Links are the FK graph, not a link table

ERPNext scans for links at cancel time across every DocType. We do not need to: the dependencies are
already foreign keys. The type declares them by accessor:

```python
blocks_cancel = ("supplier_payments", "supplier_credits", "adjustments")
cascades      = ("receipts",)
```

`blocking_documents(doc)` returns the real rows that stand in the way, so the user is told *which*
payment blocks the cancellation and can act on it — instead of ERPNext's bare "Cannot cancel because
it is linked with Payment Entry". No new table, no drift, and it is the same information the
existing `purchase_order_is_editable` computes by hand today.

### 4.4 The reversal contract

Every registered type implements:

```python
def reverse(document, *, at, actor, reason) -> None
```

posting counter-entries — never deleting rows — dated `at` (the cancellation time, per T5). The
primitive calls it inside the cancel transaction, after the period lock and the blocking check, and
before `doc_status` is flipped.

### 4.5 The trail

One append-only `DocumentEvent` table, generalising
[`PurchaseOrderAuditEvent`](backend/apps/purchasing/models.py:807): `doc_type`, `doc_id`,
`doc_number`, `action`, `actor`, `reason`, `details` (including the field diff for an
allow-after-submit edit), `created_at`. It survives the deletion of its document (`doc_number` is
denormalised), which is the whole point of an audit trail.

This is deliberately *separate* from the analytics domain events that `record_domain_event` already
writes. Those are the fleet's telemetry; this is the shop's own record, shown in the app, printed on
demand, and never sampled or dropped.

### 4.6 Numbering (roadmap item 1b)

A `DocumentSeries` service allocates numbers per type, per period, under a short row lock taken late
in the transaction.

**Existing formats do not change.** `R20260905000123` and `P20260723012834` are read aloud in shops,
printed on receipts, and typed into the returns desk; the series primitive exists so that *new*
document types get numbering without new code and so a shop can later configure a prefix — not to
renumber history.

Numbers are **unique and monotonic, but not gapless**, and that is a decision, not an accident: a
gapless series requires holding its lock for the whole enclosing transaction, which would serialise
checkout behind the slowest cart in the shop. Libya imposes no gapless-invoice requirement (and we
ship no tax module by policy), so the trade is not close.

---

## 5. What a document type must declare

Registration is a dataclass, and every field is mandatory — there is no default that lets a type
skip a clause it has not thought about (T7).

```python
@register
class PurchaseOrderDocument(DocumentType):
    model            = PurchaseOrder
    number_field     = "order_number"
    money_date       = money_dates.purchase_order          # which date the period lock guards
    draft_effects    = ("expected_stock",)                 # reversible, unvalued (T10)
    submit_effects   = ("stock_ledger", "supplier_balance")
    correction       = (Correction.ALLOW_AFTER_SUBMIT, Correction.AMEND)
    mutable_after_submit = ("notes", "supplier_invoice_number", "due_date")
    blocks_cancel    = ("supplier_payments", "supplier_credits", "adjustments")
    cascades         = ("receipts",)
    progress         = recompute_purchase_order_progress    # writes the derived `status`
    permissions      = {SUBMIT: "purchasing.add_purchaseorder",
                        CANCEL: "purchasing.cancel_purchaseorder",
                        AMEND:  "purchasing.change_purchaseorder"}
    correction_window = None                                # managers only, any age
    reverse          = reverse_purchase_order
```

### 5.1 The eight types and their contracts

| Type | Draft means | Submit posts | Cancel reverses | Correction |
|---|---|---|---|---|
| `sales.Order` (standard) | an open cart; stock committed | stock ledger issue, COGS, revenue, register cash | the issue + the cash | `COUNTER` (return/exchange); no amend |
| `sales.Order` (quotation) | being written | stock *reserved* only | the reservation | `AMEND`; supersede on acceptance |
| `sales.Order` (credit) | an open cart | as standard, plus a receivable | as standard, plus the receivable | `COUNTER` |
| `purchasing.PurchaseOrder` | editable order, holds nothing | expected stock | expected stock **and any delivery** | `IN_PLACE` (today) → `AMEND` (next) |
| `purchasing.PurchaseReceipt` | *(never a draft)* | stock ledger receipt, valuation, expected stock | the goods off the shelf **and** the expectation back on the order | `COUNTER` (a purchase return), or correcting the order it belongs to |
| `purchasing.SupplierPayment` | *(never a draft)* | supplier balance, money position, register pay-out | credit back on the note, cash back into the drawer; the row stops counting | `COUNTER` + `ALLOW_AFTER_SUBMIT` |
| `payments.Payment` | *(never a draft)* | order balance, register cash, money position | an opposing payment | `COUNTER` + `ALLOW_AFTER_SUBMIT` (the card receipt) |
| `expenses.Expense` | *(never a draft)* | money position, register pay-out | the cash back into the open drawer; the row stops counting | `IN_PLACE` while the drawer is open + `ALLOW_AFTER_SUBMIT` |
| `employees.PayrollRun` | being computed | employee balances, money position | counter-entries | `AMEND`, approval gate before submit |
| `inventory.StockCount` | counting in progress | stock ledger adjustments | counter-adjustments | `AMEND` |

`Payment`, `Expense`, `PurchaseReceipt` and `SupplierPayment` are the four that have **no lifecycle
at all** today — `ModelViewSet` with full update and destroy. They are born `SUBMITTED` (no draft
state exists for them) and they lose their delete verb. That is the single largest behavioural change
in this plan, and it is the point of it: a `PATCH` that rewrites the amount of an expense whose
register session has already been Z-reported is not an edit, it is a rewrite of a reported number.

---

## 6. Enforcement

1. **`save()` guard** — the mixin diffs frozen fields against the stored row; raises `DocumentFrozen`
   naming the field.
2. **QuerySet guard** — `update()` on a queryset containing non-draft rows refuses frozen columns.
3. **`system_write()`** — the one escape, greppable, enumerated by a test.
4. **Registry completeness test** — every registered type declares every clause and its `reverse`
   is callable.
5. **Round-trip test per type** — submit → cancel leaves the world exactly as it was: stock balance,
   stock *value*, money position, receivable, register totals. This is the test that would have
   caught #131 and #134 without either of them being thought of in advance.
6. **Progress-drift test** — `status == recompute(status)` everywhere (T8).
7. **Oracle invariants** — the business simulation gains cancel and amend as operations it can
   perform, and asserts the round-trip property at volume.

---

## 7. Migration strategy

Expand/contract, per the zero-downtime rule (`ZERO_DOWNTIME` in the update docs): each type is
adopted in three deploys — add `doc_status` and backfill it; make it authoritative while the legacy
field is maintained as derived; remove the legacy meaning.

Backfill mapping, all deterministic:

| From | To |
|---|---|
| `Order.status=open`, standard/quotation | `draft` |
| `Order.status=open`, credit | `submitted` |
| `Order.status=paid` | `submitted` |
| `Order.status=void` | `cancelled` (+ `superseded_by` from `converted_to`) |
| `PurchaseOrder.status in (draft)` | `draft` |
| `PurchaseOrder.status in (submitted, partially_received, received)` | `submitted` |
| `PurchaseOrder.status=cancelled` | `cancelled` |
| `PayrollRun.status in (draft, approved)` | `draft` (approval is a gate, not a lifecycle state) |
| `PayrollRun.status=paid` | `submitted` |
| `PayrollRun.status=void` | `cancelled` |
| `Payment`, `Expense`, `PurchaseReceipt`, `SupplierPayment` | `submitted` |

No stock or money is touched by any of it: this migration writes one column.

---

## 8. What we deliberately do not build

- **No GL posting.** The lifecycle is what a ledger would eventually hang off, but the ledger stays
  deferred on the evidence in ERPNEXT_BENCHMARK_PLAN §10.3.
- **No generic workflow engine.** Approval gates are a per-type flag here; the engine is Phase 6.
- **No versioning of drafts.** ERPNext's `tabVersion` records every keystroke of a draft's history.
  A cart on a POS screen would generate thousands of rows a day for no reader.
- **No `Closed` state.** A PO that will never be completed is already expressed by
  `cancelled_quantity` on its receipt lines, which is finer-grained and already reconciles.
- **No renumbering, no format change, no gapless series** (§4.6).

---

## 9. Phasing

**Phase 1 — the spine** (no behaviour change anywhere)
`apps/documents`: statuses, mixin, registry, transitions, guards, trail, policy, the completeness
test. Nothing registered yet. *Exit: the app is fully tested in isolation.*

**Phase 2 — the two hard types**
`PurchaseOrder` (proves progress-vs-lifecycle separation, allow-after-submit, blocking dependents,
cascade reversal) and `Order` (proves the hot path, the counter-document route, quotation
supersession). Retires `converted_to`, `purchase_order_is_editable`, `PurchaseOrderAuditEvent`, and
the two-clause `recognized_sale_q`. *Exit: round-trip tests green; the period-lock hole in
`void_order` is closed.*

**Phase 2c — purchase orders become amendable** (next). The in-place route is
one clause; converting it means `amend_copy` plus deciding what follows a
purchase order's identity when its row changes — attachments, intake plans, the
supplier's history.

**Phase 3 — the four unprotected types** ✅
`Payment`, `Expense`, `PurchaseReceipt`, `SupplierPayment`. Delete verbs replaced by cancel.

**Phase 4 — the rest, and the oracle** ✅
`PayrollRun` and `StockCount`; the simulation learned to retract. `OrderAdjustment` was
deliberately left out — see §10.

**Phase 5 — the user-facing surface** ✅ (the numbering series is deferred — §10).

---

## 10. What shipped

**Phase 1 — the primitive** (`backend/apps/documents/`, 54 tests):

| Piece | Where |
|---|---|
| Three-state lifecycle, four correction routes, the field vocabulary | `statuses.py` |
| `DocumentMixin` (lifecycle columns, both amendment pointers) + the append-only `DocumentEvent` trail | `models.py` |
| The closed registry: every clause mandatory, validated at import | `registry.py` |
| The freeze, at `save()` and at `QuerySet.update()`, plus the one escape | `guards.py` |
| Permission per transition, correction window, period lock on both dates | `policy.py` |
| `submit` / `cancel` / `amend` / `supersede` / `edit_submitted` / `correct_in_place` | `services.py` |
| Every registered type, in one readable file | `registrations.py` |
| Test-only documents, in their own app, so the primitive is provable before anything adopts it | `testkit/` |

Two guards worth naming: the escape hatch has a **census test** — a non-test module that calls
`system_write()` and is not on the allow-list fails the build — and a save that names no frozen
field never reads the row back, so the freeze stays off the checkout path's critical section.

A note for whoever adds the next test-only model anywhere in this codebase: `testkit` is a real,
migrated app installed only under `settings.TESTING`, and it went through two wrong shapes first.
Conjuring tables with the schema editor per test class and dropping them afterwards leaves the
*models* registered for the rest of the run, so anything that sweeps every model — the initial-setup
check, and Django's own delete collector whenever a user is deleted — queries a table that is gone.
Creating them once and never dropping them fixes that and breaks every `TransactionTestCase`, whose
flush cannot `TRUNCATE auth_user` while an unmanaged table references it. Only a managed app that
`migrate` creates and `flush` knows about has neither problem.

**Phase 2a — `PurchaseOrder`** (12 tests in `apps/purchasing/test_document_lifecycle.py`):

- Lifecycle and progress separated. `status` kept every value it had and every query that reads it
  still works, but it is now *derived* — computed by one function, written from one place.
- Cancelling a received order became possible. It was refused outright before, so a delivery booked
  against the wrong order could only be un-done by editing it. Now the expected stock and the
  delivery both come back, it needs the receiving permission, and it refuses when the goods have
  already been sold.
- Money that has settled blocks a cancellation and the refusal **names the rows** that block it.
- Editing a submitted order runs through `correct_in_place`, so it now leaves a field-level diff.
- A migration-window bridge keeps the two fields in step: an order created with a progress status
  and no lifecycle (the POS cash purchase, the importer, a hundred tests) gets the lifecycle that
  status implies, on insert only, and an explicit `doc_status` always wins.

**Phase 2b — `Order`** (13 tests in `apps/sales/test_document_lifecycle.py`):

- **The two meanings of `open` came apart.** A standard sale that is `open` is a
  checkout that never settled; a *credit* invoice that is `open` is an issued,
  delivered, revenue-recognised sale that happens to be unpaid. `doc_status`
  carries the document's own state now, and `status` is derived from payments
  and returns — so `recognized_sale_q` and its forty-one call sites keep working
  unchanged, while the ambiguity stops being the thing holding the reports up.
- **The period lock finally applies to a void.** `void_order` never called
  `assert_period_open`, so September's revenue could be rewritten in October
  from the returns desk by anyone. It goes through the primitive now, which
  checks the original period as well as the reversal's.
- **A refund leaves the drawer that is open now.** The reversal hook receives
  the caller's `context` — the till doing the work — rather than assuming the
  session that took the money. The randomized business simulation caught this
  the moment it was got wrong: `session cash_refund_total: backend=7.21
  oracle=10.58`.
- **A sale is immutable at the model layer.** The viewset has said so in a
  comment for a long time ("orders are append-only … so a sale can never be
  silently edited or erased, including by a manager") and enforced it only over
  HTTP. `customer` is the single declared exception, because fixing *who owes*
  an unpaid debt invoice is the returns desk's job and moves no money.
- **An accepted quotation is superseded, not flagged.** `converted_to` is the
  forward pointer under an older name; both are written until the column goes.
- Derived progress keeps the high-water-mark rule the assigned field held by
  accident: a part-returned sale is still `paid`, because a refund is stored as
  a negative payment and would otherwise make a settled sale look unpaid.

**Phase 3 — the four that had no lifecycle at all** (44 tests):

These are the ones the plan called "born final, editable and deletable forever":
`ModelViewSet`s with `update` and `destroy` over money that had already been
counted into a shift and reported. Each is now a document from the moment it
exists — `has_draft_state=False`, a clause the registry enforces, since money
either moved or it did not and there is no half-written state to be in.

| | What it could do before | What it does now |
|---|---|---|
| `payments.Payment` | `PATCH` the amount; `DELETE` it, making a settled invoice unpaid with nothing left to say it had been paid | Frozen; `cancel` writes an **opposing payment** — the shape refunds already take, so no sum anywhere had to learn a new rule. The card receipt a terminal produces afterwards still attaches |
| `expenses.Expense` | Edit or delete forever, guarded only by the period lock | Frozen except the words; correcting the amount runs through the in-place route **while the drawer that paid it is still open** — the rule the expense screen already had, now the type's own. `cancel` replaces delete: the row survives with its reason, and cash goes **back into the open till** instead of leaving an unexplained pay-out behind |
| `purchasing.SupplierPayment` | Create and read only — **no way to undo one at all**, and since a payment blocks its purchase order from being cancelled, one typo locked an order shut for good | `cancel` gives back what it took: credit back on the supplier's note, cash back into the open drawer, and the order it was blocking can be retracted again |
| `purchasing.PurchaseReceipt` | Unwound only as a side effect of editing its order | A document that undoes itself, cancelled **with** its order: goods off the shelf and the expectation back on the order — the half that is easy to miss |

Two reversal styles, chosen per type by what the domain already does, and stated
here because mixing them silently would be the bug: a **counter document** where
one already exists (a payment's opposing row nets every sum on its own), and
**exclusion** where retraction simply stops something counting (`.live()`, added
to fifteen aggregation sites across treasury, reports, the dashboard, the
register summary and the supplier balance — including the batched balance
primer, which now has a test asserting it agrees with the property it replaces).

The frontend followed for the one verb it actually used: the expenses screen's
delete became a retraction with a reason box, and its strings say so in Arabic.
1,297 Flutter tests still pass.

**Phase 4 — the last two types, and the oracle** (16 tests + three simulation operations):

| | What it could do before | What it does now |
|---|---|---|
| `employees.PayrollRun` | Three meanings in one field — approval, payment, and whether the run was live — and **a paid run could never be voided**, so one paid by mistake was permanent | Approval is a gate on paying, not a state: an approved run is still a draft. Paying is what submits it. A paid run can be retracted, and every loan instalment it collected goes back on the loan — a settled loan is owed again |
| `inventory.StockCount` | Counting and applying shared a status field, and **an applied count could not be undone**, so a miscount rewrote the shelf permanently | Counting is the draft, applying is the submission. Undoing one puts every movement it made back, refuses when the stock it added has since been sold, and takes the permission that *applying* took |

The stock count is also what made the primitive grow a **`DISCARD` transition**:
abandoning a half-walked shelf and un-applying a count are different acts by
different people, so a type may name a permission for each. Types that declare
only `CANCEL` are unaffected.

**The oracle now retracts.** The business simulation gained three operations —
cancel an expense, cancel a supplier payment, undo an applied stock count — each
asserting the round trip against the oracle's independent model: drawer cash,
a payable that several separate queries compute, and stock quantity *and* value.
Each has a vacuity guard in the entry-point test, so a run that never retracted
anything cannot pass for coverage. This is the check that would catch an
aggregation site that forgot `.live()`, which is the failure mode of the
exclusion style and looks identical to correct code until a month is closed.

`sales.OrderAdjustment` was left unregistered on purpose. It is not a document
waiting for a lifecycle — it *is* the counter-document, the thing a sale is
reversed *by*. Retracting one would mean issuing the goods again and taking the
money again, which is a new sale rather than a reversal; and the protection
registering it would buy is already there, because nothing creates, edits or
deletes one except the sales service actions that write it.

**Phase 5 — what a shopkeeper actually sees** (17 tests):

Three things, and deliberately not a fourth.

**The trail.** `GET /api/document-events/?document_type=…&object_id=…`, asking
for the *document's own* view permission rather than one of its own — a sale's
history is as sensitive as the sale. It refuses to answer without a document to
answer about: a listing across every document in the shop is not something
anyone needs, and each of its rows would need a different permission.

In the app it is the same sheet, the same shape and the same gestures as the
print-and-share history a user has already met, because someone who has opened
one has learned to read the other. What it adds is the two things a print event
never has: **the words a person typed as their reason**, in a quoted block of
its own rather than folded into a metadata line, and **what a correction moved**
— "الإجمالي: من 96.00 إلى 144.00", with the field named in Arabic and an unset
value named rather than left blank.

**The retraction, said out loud.** A cancelled document used to say only
"cancelled", which invites the next question and answers none of it. Both detail
screens now carry who retracted it, when, and why — appended to the callout each
screen *already had*, so nothing gained a second banner. The wording is
deliberately nominal ("بواسطة أحمد — 2026/09/05 16:04"): an Arabic verb would
have to agree with the document's gender, and "ألغاه" reads wrong under "هذه
الفاتورة" and right under "هذا المستند".

**Reachability without churn.** `DocumentTrailScope` sits above the Navigator
beside the companion camera's scope, so a screen that shows a document can offer
its history without a constructor parameter for it — and simply does not offer
it where no scope is installed, which is what previews and tests get.

Verified visually in `lib/dev/document_trail_preview.dart` (`make
frontend-document-trail-preview`): phone, wide, dark, empty, and a voided
invoice in place. Two things the preview caught that reading the code did not:
the gendered verb above, and a wide frame that looked stretched until the modal's
own `AdaptiveModalSizing` cap was taken into account.

**What is NOT built: the numbering series (1b).** Every document type that needs
a number has one, in a format shops read aloud and type into the returns desk,
and §4.6 already ruled that those formats do not change. So a series today would
add an allocation path nothing calls — the same unused route this design refuses
elsewhere — plus a lock near the checkout path, for no user-visible gain. Two
things would change the answer: a shop asking for its own invoice prefix, or a
new document type that needs a number of its own.

## 11. Upgrading a shop that is on v0.4.7

Rehearsed against a real v0.4.7 database, not reasoned about: build the schema
at that tag, seed a shop with history in every shape the backfill has to
classify, run the new migrations, and then keep the **old** backend trading
against the new schema.

**Every schema operation is `AddField` or `CreateModel`.** No column is dropped,
renamed or retyped, which is the expand half of expand/contract and what lets
the two versions share the database for the minute a live update takes.

**Timing.** 4.8 s on a small shop; **12.3 s** on 200,000 orders, 200,000
payments and 20,000 purchase orders — index builds and backfills included. Every
backfill is set-based: the three that started as a loop over rows (converted
quotations, voided payroll runs, applied stock counts) are single `UPDATE`
statements, so a shop with years of history pays one round trip rather than one
per row.

**Two real defects the rehearsal found, both fixed:**

1. **The old backend could not write.** Django backfills a new column with the
   Python default and then *drops* the database default, leaving `doc_status`,
   `cancel_reason` and `amendment_index` NOT NULL with nothing to fall back on —
   and the old code's `INSERT` names no such column. Every till write failed:
   sales, payments, purchase orders, supplier payments, expenses, stock counts.
   Fixed with `db_default` on the mixin, and a test that reads
   `information_schema` for all eight tables so it cannot regress quietly.
2. **What the old backend wrote was left half-classified.** With the default in
   place its inserts work, but a sale rung up in that minute lands with a
   draft's lifecycle and a finished sale's progress — and voiding one would take
   the *draft* path and reverse nothing. `apps/documents/reconciliation.py`
   promotes them on `post_migrate`, which fires again when the managed container
   is rebuilt on the new image *after* the flip. Idempotent, indexed, and empty
   on a fresh install.

**One deprecated verb kept.** `DELETE /api/expenses/{id}/` now retracts instead
of deleting rather than disappearing: nothing gates an older app from talking to
a newer server, so removing it would have broken the delete button on every till
still running the previous build. It does what that button always promised.

**The same trap elsewhere in the release, since fixed.** Comparing the two
schemas column by column found sixteen more, none of them ours: the customer
credit-limit work added `enforce_customer_credit_limits` and — the one that
mattered — `customers_customer.credit_limit_policy`, which sits on the checkout
path, because the card deduper creates a customer row for an unrecognised card.
A sale would have failed mid-flip. The file-based migration rewrite added
fourteen more on its upload tables. All now carry `db_default`.

`scripts/check_upgrade_compatibility.py` is that comparison, kept: it builds the
schema at a given tag and at the working tree and reports both halves of the
rule — columns an older backend cannot write, and columns it still writes that
have been dropped. Neither is visible to the test suite, which only ever sees
one schema at a time.

**One thing it reports that is not fixed here.** The file-based migration
rewrite *dropped* nine columns from `migration_migrationsource` — the contract
half of expand/contract, done in the same release as the expand. Nothing on a
till path touches that table; it is the "import from your old POS" screen, used
once when a shop is onboarded. The exposure is a data import started inside the
minute an update takes. Worth a decision at release time rather than a silent
pass: either keep the columns for one release, or ship `UPDATE_STRATEGY.txt`
containing `restart`, which every updater honours by falling back to a full
restart.

## 12. Open decisions

1. **Does a standard sale ever get amended?** This plan says no — a sale is corrected by a return or
   an exchange, never by editing what the customer was handed. Amending a *credit* invoice before any
   payment is the arguable case.
2. **Retention of cancelled drafts.** A POS cart abandoned mid-shift is a draft that will never be
   submitted. Purge after N days, or keep forever as evidence? Leaning purge, since `apps.fraud`
   already watches abandoned carts by its own rules.
3. **Does `RegisterSession` become a document?** It has open/closed and a Z-report, but it is a
   *container* for documents rather than one itself. Leaning no.
