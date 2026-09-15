# Learning Module — teaching Pointy inside Pointy

**Date:** 2026-09-10. **Last reconciled against the tree: 2026-09-15.**
**Status:** Phase 0 and most of Phase 1 shipped (`19103318`). See §0.
**Shape:** Run the *real* app against a sandbox shop, and make every lesson an
integration test with a narration track.

---

## 0. Status, 2026-09-15

The spine shipped, and so did 16 lessons. Everything below is the plan as
written on 2026-09-10; this section is the only part re-verified against the
tree, and it records where the plan was wrong rather than quietly editing the
prediction to match the outcome.

**What shipped.** `SandboxShop` + `SandboxClient` over a real `http.Client`,
the lesson engine, `TutorAnchor`/`TutorTarget`, the coach panel, the runner
screen, the CI runner, and 98 written guides with Arabic-normalizing search.
16 lessons: cash sale, multi-item with search, card sale, split tender, آجل with
a down payment, quotation, cash movement, register close, create product,
product with generated variants, carton barcode, create PO, receive short, add
customer mid-sale, collect a debt, pay a supplier.

**The phases interleaved, and that was right.** §12 put purchasing and the
catalogue in Phase 2, behind Phase 1's returns and exchange. It went the other
way: the catalogue and purchasing lessons landed, and returns, exchange, stock
count and the cart-quantity edit did not. Not a change of mind — they all need
an instance id on the shared `PointyQuantityStepper`, which is where the
quantity a learner would change lives, and putting learning-module knowledge
into a core design component deserved its own decision rather than being made in
passing. The sandbox has no handlers for them either: §5's "implement only what
lessons reach" holds, so those routes answer the same loud 501 as anything else
outside the practice shop.

**Where the plan was wrong.**

- **§6's example shows lesson text as ARB keys.** It is Dart strings. Guide and
  lesson prose is structured single-locale content, and
  `content/learning_library.dart` carries the reasoning. The *chrome* — buttons,
  the banner, the coach's own labels — is in the ARB as the house rule requires.
- **§6 promises a "show me" escape hatch.** Not built, and not missed: the
  escalation is a hint after 20 seconds. A lesson that performs itself is a
  lesson nobody has done, which is the same argument §13 makes about video.
- **§9's distinct `PointyTheme` accent did not ship.** The banner and the
  warning-coloured frame around the practice app did. The theme swap is still
  the right idea for "different at a glance from across the counter".
- **§9's simulated printing is contained by absence, not by a preview.** No
  printer is configured in the practice shop and the reprint route answers
  `{simulated: true}`, so nothing reaches a printer — but a lesson that prints
  does not yet *show* a labelled receipt, which is what the section asked for.
- **§9's "entering and leaving appears in the activity log" did not ship.**
- **§10's shop-type gate did not ship.** The capability gate did, on both ends:
  a lesson declares one, and CI fails if the seed's practice user could not
  reach the screen.
- **§10's `requires` DAG is a note, not a gate.** Ids resolve and cannot loop
  (CI checks both), and the guide says which lesson to do first — but someone
  sent to close the register today can practise closing the register today.
- **§11 says `useLearningMode` is granted through the backend's
  `ROLE_PERMISSION_CODES`.** It is granted in the frontend's base non-manager
  capability set. Same effect for every role today; an owner cannot yet withdraw
  it, which is what the backend grant was for.
- **§10 says progress is "per-user and local". It was per-*device*** — one key
  for the whole till, so two cashiers shared one set of ticks. Found by this
  reconciliation and fixed; the key is now scoped by user id and a test pins it.

**What the build added that the plan did not anticipate.** Anchors needed
*instance ids* — the SKU, the contact's name, the tender's index — or a step
rings an arbitrary one of several identical widgets and completes on something
the learner was never told to touch. Steps needed an `observe` act with an
explicit acknowledgement, so a lesson can explain something without the engine
skipping past it. And the CI runner needed three rot checks beyond §7's single
"the anchor resolved": an ambiguous anchor, a step already satisfied before the
learner acts, and an outcome already true at the start.

---

## 1. Why

The people who have to operate Pointy have, in most of our shops, never operated
anything except a paper ledger. Today they learn it three ways, all bad:

- **Someone shows them once**, on the live till, during trading. Every mistake is
  a real mistake: a real sale, a real void, real stock moved.
- **They are told not to touch the parts that scare the owner.** Returns,
  purchase orders, stock count and the register close are the operations that
  most affect whether the shop's numbers are right, and they are exactly the ones
  nobody is trusted to practise.
- **They phone us.** Support load that scales with installs and never decays,
  because staff turn over faster than institutional memory accumulates.

This is not a polish problem. Our whole wedge is *correct numbers* — a shop
switches to us because the ledger stops lying. A cashier who never learned that
close-cash means drawer contents and not takings will produce wrong numbers with
perfectly working software, and we have already watched exactly that happen: 113
phantom variance alerts in one shop, every one of them a training defect wearing
a software defect's clothes.

A shop that can train its own new hire on the machine, on a Tuesday, without
risking a single dinar, is a shop that keeps its numbers right and stops calling
us. That is worth building.

## 2. What we build

A **Learning** destination in the app. Inside it, a catalogue of short lessons,
each one a real task ("ring up two items and take cash", "receive a delivery that
came up two boxes short", "close the register and print the Z-report").

When a lesson runs, the learner is looking at **the actual Pointy screens** —
same widgets, same layout, same Arabic, same keyboard shortcuts — but every
number on them belongs to a **sandbox shop that lives in memory**. They tap the
real POS. Stock really decrements. The register really accumulates. The invoice
really exists afterwards and can be found in the invoices list. Nothing touches
the shop's database, and nothing survives closing the lesson.

Not a video. Not a slideshow. Not a set of coach-marks pointing at things the
learner may not touch. A practice shop.

## 3. The seam that makes this cheap

This would be a large project in most codebases. It is a small-to-medium one in
ours because the injection point already exists and is already exercised.

[`PointyApp`](frontend/lib/src/app.dart:32) takes an optional API service:

```dart
class PointyApp extends StatefulWidget {
  const PointyApp({super.key, this.apiService});
  final PosApiService? apiService;
```

It hands that straight to [`PointyAppDependencies`](frontend/lib/src/app_dependencies.dart:97):

```dart
PointyAppDependencies({
  PosApiService? apiService,
  bool? enableAutomaticConnection,
}) : service = apiService ?? PosApiService(baseUrl: defaultApiBaseUrl()),
     _enableAutomaticConnection = enableAutomaticConnection ?? apiService == null {
```

Two things fall out of those four lines:

1. **All 38 repositories are constructed over that one service** — `CatalogRepository(service)`,
   `SaleRepository(service)`, `RegisterSessionRepository(service)`, and so on down
   `app_dependencies.dart`. Replace the service and you have replaced the entire
   data layer of the app in one assignment.
2. **Injecting a service already disables LAN discovery** (`enableAutomaticConnection ?? apiService == null`
   resolves to `false`). A sandboxed app will not go looking for a backend, will
   not race the discovery sweep, and cannot accidentally find the real one.

And this is not theoretical. [`test/e2e/pilot_day_flow_test.dart`](frontend/test/e2e/pilot_day_flow_test.dart:208)
already does it:

```dart
final apiService = _PilotDayApiService();
await tester.pumpWidget(PointyApp(apiService: apiService));
```

571 lines that drive the whole real app through a whole real day — open the
register with a float, add a customer, tap two product tiles, take a split
payment, print, withdraw cash, close the session, open reports — against a fake
service holding `_sessionOpen`, `_nextOrderId` and a list of orders.

**The learning module is that test, with a UI, and a bigger sandbox.** The
architecture question is already answered and merged; what remains is scope.

The 31 harnesses in [`frontend/lib/dev/`](frontend/lib/dev/) and the
`## UI Preview Harness (Flutter web)` convention in [AGENTS.md:60](AGENTS.md:60)
are the same pattern one level down — real panes, fake repositories — so the team
already knows how to write these.

## 4. Where to cut the fake

Three candidate seams. We pick the middle one.

| Seam | What you fake | Fidelity | Cost |
|---|---|---|---|
| `PosApiService` | 345 typed methods (2,445 lines of facade) | Skips all JSON serialization | Highest — every method by hand |
| `http.Client` under [`ApiSession._send`](frontend/lib/src/data/services/api_session.dart:728) | One `send()`, dispatching on method + path | Real serialization, real repositories, real view models, real screens | One class, grows with lessons |
| A real backend with a demo tenant | Nothing | Total | Unacceptable — see below |

**Decision: fake the `http.Client`.** `ApiSession` funnels every request through
one `_send`; a sandbox that answers there exercises the real serializers and the
real error paths, so a lesson breaks when the API contract breaks — which is
exactly when we want to hear about it. Faking `PosApiService` instead would let
the app and its lessons drift apart silently.

We keep `PointyApp(apiService:)` as the injection point regardless — the sandbox
is a `PosApiService` constructed over a sandbox `ApiSession` over a sandbox
client. Same public seam, deeper fake.

**Why not a real backend.** On-prem Pointy is single-tenant: there is one
database and it is the shop's. Training against it means a trainee's practice
sale decrements real stock and lands in real reports. A second Postgres database
for training would double the install's footprint on hardware that is frequently
a 2011 OptiPlex, need its own migrations on every update, and put the shop one
misconfigured connection string away from selling out of the wrong ledger. The
in-memory sandbox has none of these properties and cannot, by construction, write
to the shop.

## 5. The sandbox is a small in-memory shop

This is the real engineering, and the place scope discipline pays.

A lesson is not "look at this screen"; it is "do this and see what happened". So
the sandbox must **mutate**. If step 2 sells two units and step 4 opens the stock
list, the stock list has to be down two units — otherwise the learner's model of
the software is being actively corrupted by the thing teaching it.

```
frontend/lib/src/features/learning/sandbox/
  sandbox_shop.dart        # the state: products, stock, contacts, session, orders,
                           # payments, POs, expenses, ledger
  sandbox_client.dart      # http.Client: dispatch on (method, path) -> handler
  handlers/                # one file per API area, mirroring lib/src/data/services/*_api_client.dart
  seeds/                   # named starting states: grocery_morning, repair_bench, ...
```

Rules that keep this from becoming a second backend:

- **Implement only what lessons reach.** Every unimplemented route returns a
  loud, explicit `501` that the UI surfaces as "this is not part of the training
  shop" — never an empty list, never a silent success. A blank screen in a
  tutorial teaches the learner the software is broken.
- **The sandbox owns invariants, not business rules.** It decrements stock,
  advances sequences, sums a drawer. It does not reimplement the discount engine
  or the valuation methods. Where a lesson needs a computed number, the seed
  supplies it.
- **Seeds are small and legible.** A dozen products with Arabic names a Libyan
  cashier recognises, two suppliers, three customers, one open register. Not a
  simulation dump.
- **The whole thing is disposable.** Closing the lesson throws the object away.
  "Start over" is a constructor call, which is also the answer to a learner who
  has wedged themselves.

`_PilotDayApiService` is ~360 lines for one narrow path with no stock model. A
sandbox that properly backs the day-one cashier lessons is a different order of
thing — plan for a real in-memory shop, not a pile of canned responses.

## 6. A lesson is an integration test with a narration track

This is the load-bearing idea of the whole plan.

The failure mode that kills in-app tutorials is **rot**: the UI moves, the lesson
still says "tap the button at the top right", and now the software's own teacher
is lying to the person least able to detect it. Screenshots rot. Videos rot
worse. Prose rots silently.

So lessons are **data**, and the same data structure drives two consumers:

```dart
const cashSale = TutorLesson(
  id: 'pos.cash_sale',
  title: LessonText.posCashSaleTitle,          // ARB key
  capability: AppCapability.accessPos,
  requires: ['register.open'],                  // lesson prerequisites
  seed: SandboxSeed.groceryMorning,
  steps: [
    TutorStep(
      say: LessonText.posCashSaleStep1,         // "اضغط على المنتج لإضافته للسلة"
      anchor: TutorAnchor.posProductTile,
      act: TutorAct.tap(),
      expect: TutorExpect.cartLineCount(1),
    ),
    TutorStep(
      say: LessonText.posCashSaleStep2,
      anchor: TutorAnchor.posCheckoutButton,
      act: TutorAct.tap(),
      expect: TutorExpect.visible(TutorAnchor.paymentSheet),
    ),
    // ...
  ],
  outcome: TutorExpect.all([
    TutorExpect.orderCount(1),
    TutorExpect.stockOf('PCE0', 8),
    TutorExpect.drawerCash(27.00),
  ]),
);
```

**Consumer 1 — the learner.** The engine renders `say` in a coach panel, spotlights
`anchor`, waits for the learner to do it themselves, and checks `expect` before
advancing. It never performs the action for them: a lesson you watch is a lesson
you have not learned. Getting it wrong is allowed and expected; the panel nudges
after a while, and offers "show me" as a last resort.

**Consumer 2 — CI.** `flutter test test/learning/` runs every lesson headlessly
through `PointyApp(apiService: sandbox)`, *performing* each `act` and asserting
each `expect` and the final `outcome`. Same lesson file, same anchors, same
sandbox.

Which gives us the property that makes this maintainable:

> **A lesson that no longer matches the UI is a red build, not a confused
> cashier.**

Move a button, rename a screen, change a flow — the lesson breaks in CI, on the
PR that broke it, in front of the person who broke it. This is the difference
between a tutorial that survives two years of development and one that is
quietly wrong within a month.

## 7. Anchors, and the honest problem with them

Lessons must point at widgets. Today we do not have a systematic way to do that,
and the existing e2e test shows the trap — it mostly finds widgets by their
Arabic label:

```dart
await tester.tap(find.text('بدء الجلسة'));
await tester.tap(find.text('تأكيد الدفع'));
```

That is anchoring a tutorial to copy. The first time someone rewords a button,
every lesson touching it fails — and worse, a *near*-match keeps passing while
pointing at the wrong thing.

There are 215 `ValueKey('...')` uses in `lib/src`, sprinkled ad hoc (and zero
`const Key('...')`), so the raw material exists but there is no registry.

**The contract:**

1. `TutorAnchor` is a closed enum in `frontend/lib/src/shared/tutor/anchors.dart`.
   Adding a lesson step that needs a new target means adding an enum value —
   visible in review, greppable, countable.
2. A `TutorTarget` widget wraps the real widget in the real screen and registers
   its `GlobalKey` against the enum value. It is inert outside learning mode: no
   rebuilds, no cost, no behaviour.
3. **CI asserts every anchor referenced by a lesson resolves during that lesson's
   run.** An anchor that stops mounting is a failing test, not a spotlight over
   empty space.
4. Lessons never anchor on text, position, or index. `find.text` is banned in the
   lesson runner by review, and worth a lint if it recurs.
5. **(Added in the build.)** Where an anchor repeats — a product tile, a cart
   line, a tender, a menu action — the wrapper carries an *instance id* and the
   step names it. Without this a step rings whichever instance mounted first and
   completes on a different one, which is worse than no spotlight: the narration
   keeps describing something the learner is not looking at. CI fails a step
   that omits the id while more than one instance is on screen.

The cost is honest and should be stated: **this sprinkles `TutorTarget` through
feature screens.** It is a small, mechanical, reviewable diff per screen, but it
is a diff in code that is otherwise none of the learning module's business, and
it grows with lesson coverage.

## 8. What "every business operation" actually means

The ambition is right and the literal scope is a trap, so let us size it
honestly.

- **26** top-level destinations in [`AppNavigationDestination`](frontend/lib/src/shared/navigation/app_navigation.dart:7)
- **53** `*_screen.dart` files
- **89** values in `AppCapability`
- **8** roles, from cashier to auditor
- **8** shop types, whose [`SHOP_TYPE_PRESETS`](backend/apps/core/models.py:382)
  flip `enable_kitchen_operations`, `enable_repair_operations`,
  `enable_production_operations`, `allow_overselling` and more

Discrete operations worth their own lesson — checkout, split payment, credit
invoice (آجل), quotation (عرض), return, exchange, PO create / receive / pay,
stock count apply, expense, payroll run, repair intake, repair settlement,
modifiers, units of measure, discounts, treasury, FX, card payments, kitchen
routing — is an estimate, not a count, and the estimate is **120–200**.

Two consequences:

- **The set is not fixed.** A grocery and a car workshop share maybe half their
  operations. Presenting a bakery's staff with repair-settlement lessons is worse
  than presenting nothing.
- **Authoring 200 lessons is a content project the size of a small product**, and
  it is not a project the engine has to finish before the module is worth
  shipping.

The mitigation is the one thing that keeps it tractable: **lessons are data, so
breadth is content, not engineering.** Build the spine once; add lessons forever.

One genuine simplification worth naming: we are **single-locale**. `l10n.yaml`
declares `app_ar.arb` as both template and only ARB (8,482 keys), and
[`app.dart:142`](frontend/lib/src/app.dart:142) pins `locale: const Locale('ar')`.
Lesson text is written once, in Arabic, by someone who knows the shop floor.
There is no translation matrix.

## 9. Training mode must be unmistakable

In a POS this is a safety requirement, not a design flourish. Two symmetrical
money bugs live here:

- A trainee believes a practice sale took real money, and hands over goods.
- A cashier believes a real sale is practice, and hands over goods without ringing
  it.

So:

- A **persistent, unmissable banner** across the top of every screen in learning
  mode — full width, distinct colour, Arabic, always visible, never dismissible.
- A **distinct accent colour** applied through `PointyTheme`, so the whole app
  reads as different at a glance from across the counter.
- **Printing is simulated.** Learning mode never reaches a real printer. A lesson
  that prints shows a rendered preview of the receipt, labelled as such. Nothing
  the shop can mistake for a real receipt ever leaves a printer.
- **Entering and leaving is explicit** and appears in the activity log, so an
  owner reviewing the day can see that the till spent 20 minutes in training and
  that no sale in that window was real.

## 10. Role and shop-type filtering

The catalogue shows a learner the lessons that apply to *them*, in this shop:

- **Capability gate.** Each lesson declares an `AppCapability`. The existing
  authorization system already decides whether the learner has it, so a cashier
  never sees a payroll lesson — for free, with no second permission model.
- **Shop-type gate.** Lessons declare the feature flags they need
  (`enable_repair_operations`, etc.). The shop's real `ShopSettings` decides
  visibility, so a bakery's catalogue is a bakery's catalogue.
- **Ordering.** `requires` builds a DAG, so "close the register" cannot be
  offered before "open the register". Progress is per-user and local.

A manager should also be able to see who has completed what. Local-only at first;
a backend-backed record is a later question, not a Phase 1 one.

## 11. Where it lives

As built (2026-09-15):

```
frontend/lib/src/features/learning/
  content/                            # 98 guides, one file per track
  views/learning_screen.dart          # catalogue
  views/lesson_runner_screen.dart     # hosts the sandboxed app + coach panel
  views/coach_panel.dart              # narration, spotlight, progress, hint
  engine/lesson.dart                  # TutorLesson / TutorStep / TutorAct
  engine/expectations.dart            # TutorExpect + what it may read
  engine/lesson_runner.dart           # shared by the UI and the CI runner
  lessons/                            # 16 lessons, one file per track
  sandbox/sandbox_shop.dart           # the state and its invariants
  sandbox/sandbox_models.dart         # what the shop owns
  sandbox/sandbox_payloads.dart       # the wire format
  sandbox/sandbox_request.dart        # one parsed request + a route matcher
  sandbox/sandbox_client.dart         # http.Client, dispatching to:
  sandbox/handlers/                   # one file per API area (§5)
  sandbox/seeds/                      # named starting shops
frontend/lib/src/shared/tutor/
  anchors.dart                        # TutorAnchor enum
  tutor_target.dart                   # the wrapper widget + registry
frontend/test/learning/
  lessons_test.dart                   # performs every lesson headlessly
  lesson_staleness_test.dart          # the checks that need no widget tree
  practice_storage_test.dart          # nothing reaches the device
  lesson_runner_screen_test.dart      # the learner-facing half
frontend/lib/dev/learning_preview.dart
```

Plus:

- `AppNavigationDestination.learning` + an entry in
  [`navigation_catalog.dart`](frontend/lib/src/shared/navigation/navigation_catalog.dart)
  — which is the single source of truth for the drawer, the rail *and* the command
  palette, so ⌘K finds it with no extra work.
- A new `AppCapability.useLearningMode`, granted to all eight roles in
  `ROLE_PERMISSION_CODES`, so an owner can withdraw it but nobody needs it
  granted.
- `make frontend-learning-preview` following the existing target convention.

## 12. Phasing

**Phase 0 — the spine.** Sandbox shop + sandbox client + lesson engine + anchor
registry + coach panel + the CI runner + **one** end-to-end lesson (cash sale).
Nothing ships to shops. The deliverable is the proof that a learner can complete
a real task against the real UI and that CI fails when the UI moves.

**Phase 1 — day one on the till.** The ~12 operations a new cashier does in their
first week: open register, cash sale, multi-item sale, quantity edit, scan, split
payment, customer on a sale, credit sale, return, exchange, cash movement, close
register + Z-report. This is the version that ships, and the version worth
selling.

**Phase 2 — the other roles.** Inventory clerk (receive, count, adjust),
purchasing agent (PO lifecycle, supplier payment), supervisor (discounts, users,
reports). Filtered by capability, so the catalogue stays short for everyone.

**Phase 3 — breadth by shop type.** Repair intake and settlement, kitchen
routing, production, assets. Content work, gated on demand from actual shops
rather than on completeness for its own sake.

Ship Phase 1 and stop to look. If shops use it, breadth is cheap; if they do not,
we have learned that for the price of a spine and twelve lessons rather than two
hundred.

> **What happened (2026-09-15).** Phase 0 shipped as written. Phase 1 shipped
> ten of its twelve operations and borrowed four from Phase 2 — the catalogue
> and purchasing lessons — while returns, exchange, the quantity edit and the
> scan did not land. The stopping point still holds: 16 lessons, and the next
> question is whether a shop uses them, not whether the list is complete. §0
> has the reasoning.

## 13. What we are deliberately not building

- **Video or screenshot walkthroughs.** They rot fastest, teach least, and cannot
  tell whether the learner did the thing.
- **Coach-marks over live data as the primary mechanism.** You cannot practise a
  checkout without taking money. A read-only guided tour of live screens may be a
  nice later addition; it is not the product.
- **A separate training build or app.** Staff must learn on the till they will
  use, with that shop's shop-type and their own role, or the training is about a
  different piece of software.
- **A training database.** §4.
- **Certification, scoring, gamification.** A learner who completed the lesson is
  the only signal we need, and it is enough.

## 14. Open questions

1. **Does the AI assistant subsume part of this?** It already draws real Pointy UI
   via `render_ui` and deep-links with `pointy://`. It can answer "how do I do
   X"; it cannot let anyone *practise* X. The interesting composition is the other
   direction — the assistant available *inside* a lesson, so "why did it do that?"
   is answerable in the moment. Worth prototyping in Phase 2, not Phase 0.
2. **Should completion be recorded server-side?** An owner asking "has Fatima been
   trained on returns?" is a real question. It is also a new model, a new
   endpoint, and a migration. Local-first; revisit after Phase 1.
3. **Does the sandbox drift from the backend?** It answers HTTP the way the real
   API does, so it can go stale when the API changes. Partly mitigated because
   lessons run in CI against real serializers. A contract test that replays real
   response fixtures through the sandbox handlers is the fuller answer if drift
   turns out to bite.
4. **How much `TutorTarget` sprinkling is too much?** ~~Worth measuring after
   Phase 1~~ — **measured: 16 lessons, 63 anchors**, against the "forty for
   twelve" line this question drew. Affordable, and the marginal cost is
   falling: the contact picker, the searchable picker and the record-payment
   dialog are each wrapped once and used by several lessons across different
   screens. The cost that did show up is not the count but *where* — the next
   lessons (returns, exchange, stock count, cart quantity) all want an id on
   one shared design component, `PointyQuantityStepper`, which is a different
   kind of decision from wrapping a feature screen.
