# Runtime extensibility for Pointy — research

**Question.** Can Pointy support runtime plugins the way Odoo, Frappe/ERPNext, Saleor and
Shopify do — extending both the Django backend and the Flutter frontend — so that a client
can hire *any* developer to build a feature, and Pointy is not the only door?

**Short answer.** Yes on the backend, close to Odoo parity. On the frontend, "runtime plugin"
has to mean something different from what it means on the web, because Flutter is AOT-compiled
and cannot load third-party Dart at runtime. The design that gets you native feel without a
templating layer is: **plugins declare *contributions* against named extension points, and the
Flutter shell renders them with Pointy's own widgets.** Same widgets, same theme, same RTL —
just described from outside the binary. Where that isn't enough, a compiled plugin SDK produces
a per-shop build, which is legal and practical here because Pointy does not ship to the App
Store.

This document is research and a recommended architecture, not an implementation plan.

---

## 1. The physics: what "runtime plugin" can actually mean on each side

### Backend — genuinely dynamic

Python is dynamic; Django's app registry, DRF routers, Celery's task registry and the
permission framework are all built to be composed at import time. A plugin that adds models,
endpoints, background jobs, permissions and business logic is straightforwardly achievable.

Three Pointy-specific constraints shape it:

- **The runtime image is deliberately hardened.** `backend/Dockerfile` deletes `pip`,
  `apt`, `dpkg`, `/bin/sh` and `/bin/bash`, runs as a non-root `pointy` user, and sets
  `PYTHONSAFEPATH=1`. You cannot `pip install` a plugin into a running shop, and you should not
  undo that to make plugins work. Plugins must arrive as **self-contained bundles on a mounted
  volume** that get added to `sys.path` at boot, or run **out-of-process**.
- **Migrations run before the app serves.** `backend/docker/entrypoint.py` runs
  `manage.py migrate --noinput` in the `web` startup path. A third-party migration that raises
  therefore does not degrade a feature — it stops the shop from booting. Per-extension migration
  isolation and quarantine-on-failure is a hard requirement, not a nicety.
- **There is no domain event bus today.** Every `@receiver` in the tree
  (`apps/core/signals.py`, `apps/catalog/signals.py`, …) exists for cache invalidation.
  Business events — a sale checked out, a PO received, a stock count applied — are not
  published anywhere. This is the single largest missing piece and the foundation everything
  else sits on.

### Frontend — not dynamic, and no official path to becoming dynamic

- Flutter release builds are AOT snapshots. There is no `dart:mirrors`, no `Isolate.spawnUri`
  of arbitrary source, no supported way to link new Dart code into a running app.
- **Deferred components** ([docs](https://docs.flutter.dev/perf/deferred-components)) are
  Android-only, still experimental, delivered through Play's split-install, and split *your own*
  code — they are a download-size feature, not a third-party extension mechanism.
- `dart_eval` / `flutter_eval` ([pub](https://pub.dev/packages/flutter_eval)) is a real Dart
  bytecode compiler + interpreter that genuinely can run third-party Dart against Flutter
  widgets at runtime. Assess it honestly: v0.8.2, last published ~7 months ago, ~330 weekly
  downloads, 70 pub points, and its own README says it "does not support all" Dart and Flutter
  features. That is not something to put on the money path of a point-of-sale system in 2026.
  Worth tracking; not worth betting on.
- **RFW — Remote Flutter Widgets** ([pub](https://pub.dev/packages/rfw),
  [source](https://github.com/flutter/packages/tree/main/packages/rfw)) is published by
  `flutter.dev`, BSD-3, ~11k weekly downloads, and is explicitly designed for this: declarative
  UI descriptions fetched at runtime, composed against **a widget library you provide at compile
  time**. It renders real widgets, not a webview. Its documented sweet spot — "interfaces made
  out of prebuilt components" — is exactly a business-app extension surface, and its documented
  weak spots (page transitions, drag-and-drop, custom painters) are things a plugin pane should
  not be doing anyway.

**One large advantage Pointy has:** `.github/workflows/release.yml` builds Android, Windows and
Linux. There is no iOS or macOS release. Apple's prohibition on downloaded executable code —
the reason most Flutter shops write off code-push and per-tenant builds — simply does not apply.
That legitimises the compiled-plugin tier below in a way it wouldn't for a typical app.

---

## 2. How the comparable systems actually do it

| System | Backend extension | UI extension | The lesson for Pointy |
|---|---|---|---|
| **Odoo** | Python addons on the server path; `_inherit` reopens an existing model to add real columns and `super()` into methods; `__manifest__.py` declares deps | XML view inheritance with XPath patches into the parent view; OWL component registry with `patch()` on the JS side | Maximum power, in-process, no isolation. Third-party modules routinely break across major versions precisely *because* they patch internals. Power without a narrow contract has a real cost. |
| **Frappe / ERPNext** | One `hooks.py` per app: `doc_events`, `override_whitelisted_methods`, `scheduler_events`, `override_doctype_class`. "Extend, don't fork." Multiple apps hook the same event and all run | Client Scripts (JS injected into forms) and Server Scripts (RestrictedPython) | **The best backend model to copy.** A single declarative hook manifest is a much narrower, much more upgrade-stable contract than "reopen the class." But: their `safe_exec`/RestrictedPython sandbox has a documented escape history ([CVE-2023-54345](https://www.tenable.com/cve/CVE-2023-54345), plus a later `format_map` read primitive) — treat "sandboxed Python" as a comfort, not a boundary. |
| **Saleor** | Apps are *separate services*. They hold a scoped token, call the public GraphQL API, and receive signed webhooks. Synchronous webhooks can even participate in checkout | Apps declare dashboard extensions in their manifest; the dashboard renders/mounts them | **The tier that genuinely un-locks a client.** Any language, any host, crash-isolated, zero knowledge of internals. This should be the *default* recommendation to a third-party developer. |
| **Shopify** | Apps over Admin API + webhooks | [Remote rendering](https://shopify.engineering/remote-rendering-ui-extensibility): extension code runs in a sandboxed worker and builds a tree of lightweight component objects via [remote-dom](https://github.com/Shopify/remote-dom); the **host** renders those as native Polaris components | **The exact idea to port to Flutter.** The extension never touches the host's render tree; it emits a description against a fixed component contract, and the host draws it with first-party components. That is why Shopify extensions look native instead of looking like embedded iframes. RFW-with-a-Pointy-widget-library is the Flutter equivalent. |
| **WordPress / Home Assistant** | Hook/filter bus (`add_action`/`add_filter`); HA integrations as importable packages with a manifest | — | Two lessons: (1) an ecosystem forms around a *stable named hook catalog*, not around "you can import anything"; (2) HACS proves a community registry works when the core is agnostic about who hosts it. |

Two conclusions run through all of them:

1. **Narrow, named, versioned hook contracts age well. Reopening internals does not.**
2. **The systems whose UI extensions feel native are the ones where the host renders
   first-party components from a remote description** — Shopify's remote-dom, Odoo's view
   inheritance. The ones that embed iframes feel bolted on.

---

## 3. Pointy's current extension surface — audit

| Surface | State | Verdict |
|---|---|---|
| Django apps | 27 under `backend/apps/`, all hardcoded in `INSTALLED_APPS` (`backend/pointy/settings.py:95`) | Needs settings-time composition from an extensions directory |
| REST API | 55 router registrations, all hand-listed in `backend/pointy/urls.py` | Needs an `/api/ext/<plugin>/` mount point |
| Business logic | Clean function-based service layer (`apps/sales/services.py` — `checkout_order`, `void_order`, `return_order_items`, `exchange_order_items`, `record_customer_payment`, `mark_order_paid`) | **Excellent hook surface.** Well-named, transactional, already the seam a plugin would want |
| Signals | Cache invalidation only; no business events | Build a domain event bus |
| Permissions | `apps/core/permission_catalog.py` already documents itself as "the single, **expansible** source of truth" and is read by the API, the validator and the Flutter editor | Already plugin-shaped. Just append |
| Settings | `ShopSettings` — 32 fields on a `pk=1` singleton (`apps/core/models.py:58`) | Closed. Plugins need a namespaced settings store, never new columns here |
| Internal plugin precedent | `apps/migration/connectors/__init__.py` — `pkgutil` autodiscovery over a package, drop a file and it registers | **Mirror this idiom exactly** so the plugin registry feels like existing Pointy code |
| AI tools | `apps/ai/tool_registry.py` derives queryable resources *from the DRF router* and runs each viewset as the current user, so permissions hold automatically | A plugin that registers a viewset becomes AI-queryable and permission-scoped **for free**. This is a genuine differentiator — no other POS gives a third-party feature an AI interface by default |
| Print templates | `PrintTemplate` + `PrintTemplateVersion` with content, JSON schema, versioning, publish | A working no-code extension surface already in production. Precedent for tier 0 |
| Workflow templates | `apps/operations` `WorkflowTemplate` | Same |
| Flutter navigation | `AppNavigationDestination` — a 24-value enum with exhaustive `switch` in `app_navigation.dart:39` and a route-builder switch in `authenticated_home.dart:245` | **The single biggest frontend blocker.** An enum cannot gain members at runtime |
| Flutter capabilities | `AppCapability` — 76-value enum in `core/authorization.dart` | Same problem, same fix |
| Flutter nav catalog | `shared/navigation/navigation_catalog.dart` — already documented as the single source of truth for both the drawer/rail *and* the command palette | Well-factored: make it merge core + contributions and plugin screens appear in ⌘K for free |
| Flutter API client | `PosApiService` — 273 methods in one class | Plugins can't extend it. But `PosApiSession` (dedupe, ETag/If-None-Match cache, relay token, SSE, perf hooks) is the right primitive to hand out |
| Flutter design system | `shared/design/` + 29 `Pointy*` components in `shared/components/` | **This is the asset that makes native-feeling plugin UI possible.** It is already a component contract; it just isn't addressable from outside |
| Distribution | Relay artifact store (sha256, resumable, authenticated), fleet control plane with canary/rollout/pin, host update agent with verify → `pg_dump` → install → `/readyz` → auto-rollback, and `apps/clients` LAN self-update | ~80% of a plugin registry already exists |

The encouraging read: the parts that are hard to build — a permission catalog designed for
extension, an AI layer that auto-derives from the router, a signed artifact/rollout pipeline,
a coherent component library, a service layer with clean seams — are already there. The parts
that are missing are mostly *de-hardcoding*.

---

## 4. Recommended architecture

### 4.1 Four trust tiers, not one plugin system

The mistake to avoid is a single "plugin" concept that must simultaneously be safe enough for
an unknown developer and powerful enough to change checkout pricing. Split it:

**Tier 0 — Configuration (no code, anyone).**
Custom fields, custom print templates, custom report definitions, workflow templates,
declarative automations ("when a sale over X is voided, notify Y"), declarative UI
contributions. No signing, no review, no risk. Two of these already ship. This tier alone
absorbs a surprising share of "can you add…?" requests, and every one it absorbs is one you
don't have to build or support.

**Tier 1 — App (out-of-process, any language).**
A separate service holding a scoped API key. Reads and writes through the public REST API,
receives business events as signed webhooks, contributes UI declaratively. Cannot crash the
backend, cannot touch a transaction, cannot see the database. **This is what you point an
outside development shop at by default.** It is also the tier that makes the anti-lock-in claim
true in the strongest sense: the developer needs no Pointy source, no Pointy relationship, and
no Pointy internals.

**Tier 2 — Extension (in-process Python, signed).**
A bundle on the extensions volume: real Django app, real models, real ORM, real Celery tasks,
participant hooks. Full power. Requires a signature from a key **the shop owner has explicitly
trusted** — which may be their own developer's key, not Pointy's. Be explicit in the
documentation that this tier is not sandboxed and cannot be; the boundary is provenance, not
containment. Frappe's CVE history is the evidence for saying so plainly rather than shipping
a RestrictedPython fig leaf.

**Tier 3 — Compiled client extension (Dart package, signed).**
A Dart package implementing `PointyExtension`, composed into a build via a generated
registration file, distributed through the existing client self-update channel. Not runtime —
but fully native, and viable precisely because there's no App Store in the release matrix.

A plugin declares its tier in its manifest, the tier determines what capabilities it may
request, and the install screen shows the user what it is asking for.

### 4.2 Backend: one manifest per extension, Frappe-shaped

```python
# pointy_loyalty/extension.py
NAME          = "loyalty"
DISPLAY_NAME  = "برنامج الولاء"
VERSION       = "1.2.0"
API_VERSION   = ">=1.0,<2.0"      # refuse to load out of range, don't half-work
TIER          = "extension"
DJANGO_APPS   = ["pointy_loyalty"]

# Observers: after-commit, async, cannot fail the sale. The default.
OBSERVES = {
    "sales.order.checked_out": "pointy_loyalty.hooks.award_points",
    "sales.order.returned":    "pointy_loyalty.hooks.claw_back_points",
}

# Participants: inside the transaction, may mutate or veto. Declared capability,
# hard deadline, no network I/O. Tier 2 only.
PARTICIPATES = {
    "sales.pricing.resolve": "pointy_loyalty.hooks.apply_member_price",
}

SCHEDULED    = {"expire_points": {"task": "...", "crontab": "0 2 * * *"}}
PERMISSIONS  = [...]      # merged into permission_catalog.PERMISSION_CATALOG
SETTINGS     = {...}      # JSON-schema, stored namespaced, rendered natively
CONTRIBUTES  = {...}      # the Flutter side — see 4.3
AI_TOOLS     = [...]      # optional; router-registered viewsets are automatic
```

**The observer/participant split is the most important decision in this document.**

Odoo's `super()` chains and Frappe's `doc_events` both run inline, which is why a third-party
customization there can hang a document submit. Pointy is a POS: a cashier with a queue cannot
wait on someone else's HTTP call. So:

- **Observers** are the default and cover ~90% of real plugins. They fire from
  `transaction.on_commit`, publish through `apps/core/dispatch.enqueue_best_effort` (which
  already bounds the broker connection precisely because a wedged Redis must never park a
  request thread), and execute in Celery. An observer that raises, hangs, or crashes affects
  nothing but itself and its own dead-letter record.
- **Participants** run in-band and can change the outcome. They are opt-in per extension point,
  granted per-extension at install, wrapped in a deadline, and forbidden from network I/O. The
  checkout path already has the right instinct here — `_guardedPrint*` / `_checkoutPrintDeadline`
  bound best-effort printing rather than awaiting it — and participant hooks should follow the
  same discipline.

Candidate event catalog, derived from the existing service layer:

```
sales.order.checked_out / .voided / .returned / .exchanged / .paid
sales.register.opened / .closed / .cash_moved
purchasing.po.submitted / .received / .cancelled
payments.customer_payment.recorded / payments.supplier_payment.recorded
inventory.movement.recorded / inventory.count.applied
catalog.product.saved / catalog.price.changed
customers.customer.saved / customers.debt.settled
operations.job.created / .status_changed / .completed
employees.payroll_run.finalized
```

Candidate participant points (bounded, opt-in):

```
sales.pricing.resolve          # compose with the discount engine's O(1) path
sales.checkout.validate        # veto with a structured, translatable error
sales.payment_methods.filter
printing.payload.augment       # add a block to a receipt/chit
catalog.search.boost
```

**Extending core data.** Two mechanisms, both needed:

- **Namespaced JSONB** — one `extension_data` column on the high-value core models (Order,
  Product, Customer, PurchaseOrder, Job), keyed by extension id, with a declared JSON schema per
  namespace, exposed through a serializer mixin, GIN-indexed. This is what powers Tier 0 custom
  fields: a shop adds "warranty months" to a product without a developer and without a
  migration. It is also the safe way for Tier 1 apps to annotate core records.
- **Sidecar models** — Tier 2 extensions define their own tables with a `OneToOneField` to the
  core record. Migration-safe, properly typed, properly indexed. This replaces Odoo's `_inherit`
  column injection, which is the mechanism most responsible for Odoo upgrade pain.

**Namespacing.** Everything an extension owns lives under its id: routes under
`/api/ext/<id>/`, tables prefixed `ext_<id>_`, settings under `<id>.*`, permissions under
`<id>.*`, events it emits under `<id>.*`. Collisions become impossible by construction and any
5xx, slow query or audit entry is attributable to an extension at a glance — which matters a
great deal the first time a client says "Pointy is broken."

**Migration safety.** Discovery happens at settings time; migrations run per-extension with the
result recorded. An extension whose migration fails is **quarantined** — flagged unhealthy,
excluded from `INSTALLED_APPS` on the next boot, surfaced in Shop Settings — and the core stack
boots normally. Given `entrypoint.py` migrates before serving, the alternative is a third-party
bug that takes a shop offline until someone with SSH arrives.

### 4.3 Frontend: contributions rendered by the shell, not markup interpreted by it

The distinction the user is asking for — "not just some templating system" — comes down to
*who owns the widget tree*. In a templating system the plugin ships markup and the host
interprets it, which is why it always looks slightly foreign. In the model below the plugin
ships a **description addressed to Pointy's own component contract**, and the shell builds the
widget tree out of `PointyMetricTile`, `PointyDataList`, `PointyDetailHero`, `PointyStatusPill`
— the same 29 components every core screen uses, under the same `PointyTheme`, with the same
RTL handling, the same skeletons, the same dark mode. It cannot look foreign, because there is
nothing foreign in the tree. This is Shopify's remote-rendering insight, and RFW is the
mechanism Flutter already has for it.

Three layers, in increasing power:

**(a) Declarative contributions — the default, covers most plugins.**
The manifest names an extension point and supplies a typed payload:

```jsonc
"CONTRIBUTES": {
  "nav.destination": [{
    "id": "loyalty.members", "label": {"ar": "الولاء"}, "icon": "card_giftcard",
    "capability": "loyalty.view_member", "group": "sales",
    "screen": {"kind": "resource_list", "source": "/api/ext/loyalty/members/",
               "columns": [...], "detail": {...}}
  }],
  "dashboard.card":        [{"id": "loyalty.points_issued", "source": "...", "size": "medium"}],
  "order.detail.section":  [{"id": "loyalty.earned", "source": "..."}],
  "pos.action":            [{"id": "loyalty.redeem", "icon": "redeem", "opens": "..."}],
  "settings.page":         [{"id": "loyalty", "schema": "..."}],
  "product.list.column":   [{"id": "loyalty.tier", "path": "extension_data.loyalty.tier"}]
}
```

A handful of parameterised screen kinds — `resource_list`, `detail`, `form`, `metric_board`,
`settings` — built from existing scaffolds (`PointyDataList`, `InfiniteScroll`,
`PointyDetailHero`, `PointyMetricGrid`) covers the large majority of business-app UI. These are
CRUD apps; most plugin screens genuinely are a filtered list, a detail page, a form and a few
metrics.

**(b) RFW panes — for custom layouts inside a contributed surface.**
Register Pointy's components as an RFW *local widget library*, so a `.rfw` blob composes real
Pointy widgets. Cache blobs locally, version them against the extension API, fall back to the
last-good blob offline. RFW carries no executable code, which makes it the right choice for a
surface that may come from a registry you don't control. Constrain it to panes and cards —
never navigation, never the cart, never checkout.

**(c) Compiled Dart plugins — for genuinely deep UI.**
`PointyExtension` as a Dart interface; a build composes core + selected packages via a
generated registration file; the artifact ships through the existing self-update channel. This
is where "a whole new POS mode for a pharmacy" lives. It is not runtime, but it *is* real
Flutter written by someone who is not you — which is the actual requirement.

Critically, **all three tiers address the same extension-point IDs and the same manifest**. A
plugin can start as a declarative contribution and graduate to a compiled one without changing
its backend, its identity, or its install story.

**The de-hardcoding this requires:**

1. `AppNavigationDestination` enum → a string-keyed `DestinationId` value type with core
   destinations as constants and a registry for the rest. The two exhaustive switches
   (`app_navigation.dart:39`, `authenticated_home.dart:245`) become registry lookups with the
   core table as the built-in provider. This is the largest single refactor on the frontend.
2. `AppCapability` → same, or keep the enum for core and allow string keys for extensions.
3. `navigation_catalog.dart` → merge core + contributions. Because it is already the shared
   source of truth for the drawer, the rail and the command palette, plugin screens become
   ⌘K-reachable with no extra work. Good factoring paying a dividend.
4. Expose `PosApiSession` — not `PosApiService` — as the plugin transport primitive. It already
   carries in-flight GET dedupe, the If-None-Match/ETag LRU, relay-token routing, SSE and the
   perf callback. A plugin gets caching and offline behaviour for free by using it.
5. A namespaced `ExtensionSetting` store plus a schema-driven settings renderer, so plugins never
   add columns to `ShopSettings`.
6. Name and freeze the extension points: dashboard cards, POS action bar, order detail sections,
   list columns, print blocks, settings pages.

### 4.4 Distribution — and the actual test for "not locked in"

Reuse the relay: the artifact store (sha256, range-resumable, authenticated), the fleet control
plane (canary, staged rollout, pin, pause) and the update agent's verify → `pg_dump` →
install → `/readyz` → auto-rollback sequence are all directly applicable to extension bundles.
Add one thing that changes the meaning of the whole system:

> **The shop, not Pointy, decides which registries and signing keys it trusts.**

Concretely, all three must work:

- **Sideload** from a local file or a LAN path — no relay, no internet, no Pointy account.
- **Trust an arbitrary registry** by URL + public key, added by the shop owner.
- **Pointy's registry** is simply the default entry in that list.

The acceptance test for the anti-lock-in goal is a single sentence, and it is worth writing into
the spec: *a shop can install an extension Pointy has never seen, written by a developer Pointy
has no relationship with, on a machine that cannot reach Pointy's servers.* If that works, the
claim is real. If it doesn't, it's marketing.

### 4.5 Versioning, and why Odoo modules break

Odoo third-party modules break on major upgrades because they patch internals — `_inherit`
reopens classes and XPath patches address the parent view's structure, so any internal change is
a breaking change. Frappe fares better because `hooks.py` is a narrow, named contract.

For Pointy:

- A single **Extension API version**, declared in the manifest as a range. Out-of-range
  extensions are refused with a clear message rather than loaded to half-work.
- The API is a **separate importable surface** — `pointy.extensions.api` — re-exporting only
  what is stable. Importing `apps.sales.services` directly remains physically possible for Tier 2
  and should be documented as explicitly unsupported.
- A **contract test harness** (`pointy-ext check`) that boots a scratch instance and asserts
  hooks resolve, migrations apply, contributions validate against the extension-point schemas,
  and declared permissions exist. Ship it with the SDK so a third-party developer can prove
  compatibility before a shop installs anything.
- **Deprecation with overlap**: an extension point marked deprecated keeps working for one
  full API minor cycle and logs a warning attributed to the extension.

### 4.6 Overhead

The "little to no overhead" requirement is meetable, and worth stating in measurable terms:

- **Zero extensions installed**: the registry is an empty dict; event dispatch is
  `if not receivers: return`. Not measurable.
- **Observers**: an after-commit `enqueue_best_effort` — the same bounded-publish path already
  used on returns, voids and register close. Sub-millisecond on the request thread.
- **Participants**: the only real in-band cost, bounded by an explicit deadline and capped in
  count per extension point.
- **Flutter contributions**: resolved once at login into an immutable registry. Navigation goes
  from a `switch` to a map lookup. Nothing per-frame, nothing per-build.
- **`extension_data` JSONB**: one column on five models, no join, serialized only for namespaces
  a loaded extension claims.
- **RFW**: parse-and-cache per blob version, not per frame.

The honest cost is not runtime — it's the discipline of keeping a public contract stable, and
the support surface described below.

---

## 5. Risks and how each is contained

| Risk | Containment |
|---|---|
| A plugin hangs or breaks checkout | Observers are async and cannot; participants need an explicit capability grant, a deadline, and a no-network rule |
| A plugin migration bricks a shop's boot | Per-extension migration isolation + quarantine; core boots regardless |
| "Pointy is broken" when it's an extension | Every route, table, task, log line and 5xx tagged with the extension id. The 5xx tracking already carries `error_type`/`message`/`traceback` — add the attribution and a per-extension health card in Shop Settings |
| Tier 2 is not sandboxed | Say so, loudly, in the install dialog and the docs. Provenance (signature the owner trusted) is the boundary. Don't ship RestrictedPython and imply otherwise — see [CVE-2023-54345](https://www.tenable.com/cve/CVE-2023-54345) |
| Untrusted code on the money path, eventually | WASM (Extism / wasmtime-py) with fuel and memory limits is the credible future answer for participant hooks specifically. Real isolation, real resource caps, but a steep ergonomics tax — no Django ORM inside the guest. A v2 item, not a v1 one |
| Data exfiltration by a Tier 1 app | Scoped API keys with the *existing* permission catalog, per-app rate limits, and an audit trail. `apps/channels` already carries per-channel API keys as precedent |
| Ecosystem fragmentation / abandonware | API version ranges, the contract test harness, and a "last verified against" badge in the registry |
| Support load multiplies | Per-extension attribution (above) plus a one-click "disable all extensions and retry" diagnostic, so the first support question is answerable in seconds |

---

## 6. Suggested sequencing

Each phase is independently useful; none requires the next to have shipped.

**Phase 0 — Foundations (backend, invisible).**
Domain event bus in `apps/core/events.py` with a named catalog and after-commit async dispatch.
`extension_data` JSONB on Order, Product, Customer, PurchaseOrder, Job with a serializer mixin.
Both are worth having even if the plugin system never ships — the event bus alone unlocks
automations, better audit and better AI hints.

**Phase 1 — Tier 0, no code.**
Custom fields on the JSONB columns, rendered natively from a schema. Declarative automations
over the event bus. This ships client-visible value fastest and validates the extension-point
naming before anything external depends on it.

**Phase 2 — Tier 1, out-of-process apps.**
Scoped API keys, signed outbound webhooks over the event bus, a manifest, and the declarative
contribution renderer on the Flutter side. **This is the phase that delivers the actual goal** —
after it, a client can hire anyone. It requires the frontend de-hardcoding (`DestinationId`,
capabilities, nav catalog merge) but no in-process Python loading at all.

**Phase 3 — Tier 2, in-process extensions.**
Extensions volume, settings-time discovery, per-extension migrations with quarantine, the hook
manifest, signing and trust store, registry over the relay artifact store, `pointy-ext check`.

**Phase 4 — Richer UI and deeper plugins.**
RFW panes with the Pointy widget library. Then the compiled Dart SDK and per-shop composed
builds through the existing self-update channel.

WASM participant sandboxing sits after all of this, if and when third-party pricing logic on the
money path becomes a real demand rather than a hypothetical one.

---

## 7. Decisions worth making before any code

1. **Which tier is the headline?** Recommending Tier 1 (out-of-process) as the default answer
   to outside developers is the strongest anti-lock-in position and by far the cheapest to
   support — but it can't do everything a client will ask for. Tier 2 is what people mean when
   they say "like Odoo," and it is a permanent support-surface commitment.
2. **How far does the trust model go?** Specifically: may a shop owner add a third-party signing
   key with no Pointy involvement? A "yes" is what makes the claim credible; it also means an
   extension you have never reviewed can run in-process on a shop's money system.
3. **Is a marketplace in scope, or only a protocol?** The protocol is the promise. A registry is
   a business. They can ship years apart, and the protocol should not assume the registry exists.
4. **Does the compiled-Dart tier justify per-shop builds?** It's viable here specifically because
   there's no App Store, but it puts you in the business of building and signing bespoke
   binaries. Worth deciding before the SDK is designed around it.
5. **Do participant hooks exist in v1 at all?** Shipping observers only, and adding participants
   once the event catalog has settled, is the conservative sequencing — and observers alone cover
   most of what plugins actually do.

---

## Sources

- [Odoo 19 — Inheritance](https://www.odoo.com/documentation/19.0/developer/tutorials/server_framework_101/12_inheritance.html) · [Building a Module](https://www.odoo.com/documentation/19.0/developer/tutorials/backend.html)
- [Frappe — Hooks](https://docs.frappe.io/framework/user/en/python-api/hooks) · [safe_exec.py](https://github.com/frappe/frappe/blob/develop/frappe/utils/safe_exec.py) · [CVE-2023-54345](https://www.tenable.com/cve/CVE-2023-54345)
- [Shopify — Remote rendering: Shopify's take on extensible UI](https://shopify.engineering/remote-rendering-ui-extensibility) · [remote-dom](https://github.com/Shopify/remote-dom) · [Admin UI extensions](https://shopify.dev/docs/api/admin-extensions/latest)
- [rfw — Remote Flutter Widgets](https://pub.dev/packages/rfw) · [source](https://github.com/flutter/packages/tree/main/packages/rfw)
- [Flutter — Deferred components](https://docs.flutter.dev/perf/deferred-components) · [dart-lang/sdk#50406 — load AOT image dynamically](https://github.com/dart-lang/sdk/issues/50406)
- [flutter_eval](https://pub.dev/packages/flutter_eval) · [dart_eval](https://pub.dev/packages/dart_eval)
- [Extism — sandboxing generated code](https://extism.org/blog/sandboxing-llm-generated-code/) · [MicroPython + Wasmtime sandbox](https://simonwillison.net/2026/Jun/6/micropython-in-a-sandbox/)
