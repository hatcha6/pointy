# Pointy plugin system — build plan

Status: **proposed, decided.** This turns `PLUGIN_ARCHITECTURE_RESEARCH.md` into one
architecture. Every open question in §7 of that document is answered below; nothing here
is "maybe".

---

## 0. The decisions

| Question | Decision |
|---|---|
| What is a plugin? | **One signed bundle = one Django app + one UI manifest.** Python only. Runs in-process in the backend. |
| How does the UI change? | **Server-driven.** The plugin describes UI in Python; the backend serves it as JSON; Flutter draws it with Pointy's own widgets. No Dart in plugins, ever. |
| Which renderer? | **The AI generative-UI catalog**, generalized. One closed widget vocabulary, two producers: the model and plugins. No RFW, no `flutter_eval`, no per-shop Flutter builds. |
| Where can UI change? | Only at **named slots** that core screens render (list columns, detail sections, POS actions, nav entries, dashboard cards, settings pages, receipt blocks). Plugins never patch core widgets. |
| How does behaviour change? | Only through **named hooks** that core code calls explicitly: *events* (after commit, async, cannot break anything) and *filters* (in-band, can change a value or veto, fail open). No monkeypatching. |
| How do columns get added? | Database: the plugin's **own tables** (sidecar, `OneToOne` to the core row), or declared **custom fields** in a JSONB `ext` column on core models. API: a **serializer extender** adds the value to core payloads. UI: a **list-column contribution** shows it. |
| "Runtime"? | Install/upgrade/uninstall without rebuilding or redeploying the image: verify → migrate → recycle backend processes (seconds). **Enable/disable is hot** — no restart. Flutter picks up UI changes live, no app update. |
| Trust | Bundles are **Ed25519-signed, fail-closed** (same as release bundles). Pointy's key is trusted by default; the **shop owner may add a third-party developer key**. Plugins are not sandboxed — the signature is the boundary, and the install dialog says so. |
| Out-of-process apps / webhooks | Not v1. They fall out of the event bus later (an event → signed webhook is one subscriber). |
| Marketplace | Not v1. Sideload a file or install from the relay registry. |
| `compat/win8` | Plugin **behaviour** applies to Win8 tills (they talk to a `main` backend). Plugin **UI** does not appear there — the frozen branch has no slot renderer. Documented, not fixed. |

---

## 1. Why these and not the alternatives

- **Flutter cannot load Dart at runtime.** Release builds are AOT and obfuscated. The only
  runtime UI is data the app interprets. So the question is only *which* data format.
- **We already own one.** `frontend/lib/src/features/ai/ui/items/` is a closed catalog of
  Pointy-component widgets with **no styling properties**, validated by a backend test and
  exported to `shared/ai_ui_catalog/`. That is exactly the contract plugins need: a plugin can
  state meaning (`tone`, `variant`, `kind`) and nothing else, so a plugin screen *cannot* look
  off-brand or break RTL/dark mode. Building RFW alongside it would be a second vocabulary to
  keep in sync.
- **The backend is Cython-compiled** (`CODE_PROTECTION_PLAN.md` P1). Compiled modules bind
  calls early, so `apps.sales.services.checkout_order = patched` does not reach internal
  callers. Odoo-style "reopen and override" is not just unwise here — it does not work. Hooks
  that core calls by name are the only extension mechanism that survives compilation.
- **A POS must not wait on a plugin.** Events run after commit in Celery. Filters are few,
  measured, and fail open — a broken plugin costs a discount, never a sale.

---

## 2. What a plugin developer writes

### 2.1 Tooling

```bash
pip install pointy-sdk              # pure-Python: typed API, hook signatures, UI DSL, CLI, test kit
pointy-plugin new loyalty           # scaffold
pointy-plugin dev                   # mount into a local Pointy backend, live reload backend + UI
pointy-plugin test                  # pytest against a real Postgres core
pointy-plugin check                 # contract checks (below)
pointy-plugin build                 # -> dist/loyalty-1.0.0.pointy
pointy-plugin sign --key dev.key    # Ed25519 signature next to the bundle
pointy-plugin keygen                # developer key pair; give the .pub to the shop owner
```

`pointy-plugin dev` runs the published `pointy-backend:<version>-sdk` image (same compiled core,
with the plugin directory mounted and autoreload on), seeds a demo shop, and prints a login. The
developer opens any Pointy client — desktop, Android or the web preview — against it. Editing
`ui.py` and saving makes the screen change in the running app within a second (the UI manifest
is pushed through the existing state-version revalidation). **No Flutter toolchain is needed to
build a plugin.**

### 2.2 Bundle layout

```
pointy-loyalty/
  pointy_plugin.toml           # identity + compatibility
  loyalty/
    __init__.py
    plugin.py                  # register(): hooks, extenders, permissions, settings
    models.py                  # own tables (sidecars)
    migrations/
    api.py                     # DRF viewsets -> /api/ext/loyalty/...
    ui.py                      # screens + slot contributions (Python DSL -> JSON)
    tasks.py                   # Celery tasks / schedules
    locale/ar.json             # every visible string; Arabic required, `check` fails without it
  tests/
```

```toml
# pointy_plugin.toml
id           = "loyalty"                 # [a-z][a-z0-9_]{2,31}; namespaces everything
name         = { ar = "برنامج الولاء" }
version      = "1.0.0"
pointy_api   = ">=1.0,<2.0"              # refused outside the range, never half-loaded
author       = "Example Dev"
requires     = []                        # other plugin ids
python_deps  = []                        # vendored, pure-Python only (checked at build)
filters      = ["sales.cart.discounts"]  # in-band hooks it wants; shown at install
```

### 2.3 A complete small plugin

```python
# loyalty/models.py
from pointy_sdk.db import PluginModel, models
from pointy_sdk.core import Customer

class Member(PluginModel):                     # table: ext_loyalty_member
    customer = models.OneToOneField(Customer, on_delete=models.CASCADE, related_name="+")
    points = models.IntegerField(default=0)
    tier = models.CharField(max_length=16, default="bronze")
```

```python
# loyalty/plugin.py
from decimal import Decimal
from pointy_sdk import plugin, events, filters, permissions, settings, serializers
from .models import Member

permissions.declare("view_members", "manage_members")   # -> loyalty.view_members in the role editor

settings.declare({                                      # rendered natively in Shop Settings
    "points_per_dinar": settings.Int(default=1, min=0),
    "gold_discount_pct": settings.Decimal(default=Decimal("5")),
})

@events.on("sales.order.checked_out")                   # after commit, in Celery, retried
def award(event: events.OrderCheckedOut):
    if event.customer_id is None:
        return
    m, _ = Member.objects.get_or_create(customer_id=event.customer_id)
    m.points += int(event.total) * settings.get("points_per_dinar")
    m.save(update_fields=["points"])

@filters.on("sales.cart.discounts")                     # in-band; fails open
def gold_discount(discounts: list[filters.Discount], ctx: filters.CartContext):
    if ctx.customer_id and Member.objects.filter(customer_id=ctx.customer_id, tier="gold").exists():
        discounts.append(filters.Discount.percent(settings.get("gold_discount_pct"),
                                                  label="loyalty.gold_discount"))
    return discounts

@serializers.extend("customers.Customer")               # adds a key to core payloads
class CustomerLoyalty(serializers.Extender):
    fields = {"loyalty_points": serializers.Int(), "loyalty_tier": serializers.Str()}

    def prefetch(self, ids):                            # one query per page, never per row
        return {m.customer_id: m for m in Member.objects.filter(customer_id__in=ids)}

    def values(self, obj, m):
        return {"loyalty_points": m.points if m else 0, "loyalty_tier": m.tier if m else None}
```

```python
# loyalty/ui.py
from pointy_sdk import ui

ui.list_column("customers.list", key="loyalty_points",
               label="loyalty.points", kind="number", capability="loyalty.view_members")

ui.detail_section("customers.detail", id="loyalty.card", capability="loyalty.view_members",
    body=lambda r: ui.MetricRow([
        ui.Metric(label="loyalty.points", value=r.field("loyalty_points")),
        ui.Metric(label="loyalty.tier",   value=r.field("loyalty_tier"), tone="info"),
    ]))

ui.pos_action(id="loyalty.redeem", label="loyalty.redeem", icon="redeem",
              requires="cart.customer", opens=ui.Sheet("loyalty.redeem_form"))

ui.screen("loyalty.members", label="loyalty.members", icon="card_giftcard",
          nav_group="customers", capability="loyalty.view_members",
    body=ui.DataTable(source="/api/ext/loyalty/members/", search=True,
        columns=[ui.Col("customer_name", "loyalty.customer"),
                 ui.Col("points", "loyalty.points", kind="number"),
                 ui.Col("tier", "loyalty.tier", kind="status")],
        on_row=ui.Navigate("customers.detail", id=ui.row("customer_id"))))

ui.form("loyalty.redeem_form", submit="/api/ext/loyalty/redeem/",
        fields=[ui.NumberField("points", "loyalty.points_to_redeem", min=1)],
        on_success=ui.RefreshCart())

ui.dashboard_card("loyalty.points_today", source="/api/ext/loyalty/stats/today/",
                  body=lambda d: ui.Metric(label="loyalty.points_today", value=d.field("points")))
```

Labels are keys into `locale/ar.json`; the server resolves them for the user's locale. A
plugin cannot pass a colour, size, padding or font anywhere — the DSL has no such parameter,
and the server validates the JSON against the exported catalog schema before serving it.

### 2.4 What a plugin may import

| Import | Status |
|---|---|
| `pointy_sdk.*` | **The contract.** Versioned by `pointy_api`. Breaking changes only on a major. |
| `pointy_sdk.core` — re-exports of `Product`, `ProductVariant`, `Customer`, `Supplier`, `Order`, `OrderLine`, `PurchaseOrder`, `StockMovement`, `Employee`, `Job` | **Read** freely. Write only through `pointy_sdk.services` (wrapped service functions: stock movement, customer payment, etc.) so audit, locking and money rules hold. |
| `django.*`, `rest_framework.*`, `celery` | Allowed. |
| `apps.*` (core internals) | **Rejected by `check`** for third-party keys. Allowed with a warning for Pointy-signed plugins. |

### 2.5 `pointy-plugin check`

Fails the build when: `pointy_api` range missing; a visible string has no Arabic; a UI node
uses an unknown catalog item or property; a declared filter isn't in the catalog; a model
table isn't `ext_<id>_` prefixed; a migration touches a non-plugin table; `apps.*` is imported;
a vendored dependency contains native code; a serializer extender has no `prefetch`.

---

## 3. Backend architecture

### 3.1 Files

```
backend/apps/plugins/                 # the host
  models.py        InstalledPlugin (id, version, state, enabled, signature key, health),
                   PluginSetting (plugin, key, value JSON), PluginFailure (dead letters)
  loader.py        discovery at settings time from the plugins volume + plugins.lock
  install.py       verify signature -> unpack -> compat check -> migrate -> lock -> recycle
  registry.py      in-memory: events, filters, extenders, permissions, ui contributions
  ui_manifest.py   builds + validates + caches the per-user UI manifest
  views.py         /api/plugins/ (list/install/enable/disable/settings/health), /api/plugins/ui/
  trust.py         trusted public keys (Pointy's baked in, owner-added in DB)
backend/apps/core/events.py           # the domain event catalog + publish()
backend/apps/core/filters.py          # the filter catalog + apply()
backend/pointy_sdk/                   # source of the published SDK (pure Python, NOT compiled)
```

`pointy_sdk` is excluded from Cython compilation and published to PyPI from this repo: the
SDK a developer installs *is* the module the backend imports.

### 3.2 Loading

1. `settings.py` reads `/var/lib/pointy/plugins/plugins.lock` (written only by the installer):
   the list of installed, healthy plugin ids + versions. Each lives in
   `/var/lib/pointy/plugins/<id>/<version>/` and is appended to `sys.path` and `INSTALLED_APPS`.
2. Each app's `AppConfig.ready()` calls the plugin's `register()`; decorators fill the registry.
   Any exception here → plugin marked `broken`, its registrations dropped, core continues.
3. Plugin URLs mount under `/api/ext/<id>/` through one include in `pointy/urls.py`. Because
   they are DRF router registrations, `apps/ai/tool_registry.py` exposes them to the assistant
   automatically, permission-scoped.

The image stays hardened: no `pip` at runtime. Bundles are self-contained zips on a volume.

### 3.3 Install / upgrade / uninstall

```
upload .pointy  ->  verify Ed25519 against trusted keys  (fail closed)
                ->  check pointy_api range, requires[], declared filters
                ->  unpack to <id>/<version>/ (old version stays on disk)
                ->  `manage.py plugins migrate <id>` in its own process, under the
                    advisory lock entrypoint.py already uses
                       fail -> state=broken, lock unchanged, nothing else happens
                ->  rewrite plugins.lock atomically
                ->  recycle web + celery (same path as the update agent; seconds)
                ->  /readyz; on failure revert plugins.lock to previous and recycle again
```

- **Uninstall** removes it from the lock and recycles. Tables stay. "Delete data" is a separate,
  confirmed action that runs the plugin's reverse migrations.
- **Core updates**: the update agent refuses to apply a Pointy version outside any installed
  plugin's `pointy_api` range unless the owner chooses "disable incompatible plugins and update".
  The upgrade rehearsal harness runs with the shop's plugins installed.
- **Enable/disable** flips `InstalledPlugin.enabled`, bumps a state version, and takes effect on
  the next request in every process: the registry checks the flag at dispatch, plugin routes
  return 404, and the UI manifest drops the plugin's contributions. No restart.
- CLI parity: `pointy-ctl plugins install|list|enable|disable|uninstall|logs <id>`.

### 3.4 Events (observers)

`core/events.py` holds a typed catalog. Core services publish explicitly:

```python
events.publish(events.OrderCheckedOut(order_id=..., customer_id=..., total=..., cashier_id=...))
```

`publish` registers a `transaction.on_commit` that calls `dispatch.enqueue_best_effort` once per
subscribing plugin. With no subscribers it returns immediately. Payloads are frozen dataclasses
of ids and amounts (never ORM objects), so they serialize and stay stable.

v1 catalog (from the existing service layer):

```
sales.order.checked_out  .voided  .returned  .exchanged  .paid
sales.register.opened  .closed
purchasing.po.submitted  .received  .cancelled
payments.customer_payment.recorded  payments.supplier_payment.recorded
inventory.movement.recorded  inventory.count.applied
catalog.product.saved  catalog.price.changed
customers.customer.saved
operations.job.created  .status_changed  .completed
```

Failures retry with backoff (3×), then land in `PluginFailure` and on the plugin's health card.

### 3.5 Filters (in-band behaviour changes)

```python
discounts = filters.apply("sales.cart.discounts", discounts, ctx)
```

Rules, enforced in `apply()`:

- Only filters in the catalog exist, and a plugin gets only those it **declared in its toml**
  (shown to the owner at install).
- Each call runs inside a savepoint with `SET LOCAL statement_timeout` (default 200 ms).
- Exception or timeout → the value from before this plugin is used, a `PluginFailure` row is
  written, the sale continues. **Filters fail open.**
- Wall time is measured; 5 failures or budget overruns in 10 minutes **opens the circuit**: that
  plugin's filter is skipped and the owner is notified. Python cannot pre-empt a thread, so the
  budget is enforced by measurement + circuit, and by the DB timeout for the common case.
- Return values are type-checked against the filter's signature.

v1 filter catalog (deliberately small):

```
sales.cart.discounts          add/remove discount lines (composes with the discount engine)
sales.checkout.validate       veto with a translatable message
sales.payment_methods         hide/reorder methods
catalog.product.validate      veto a product save
printing.receipt.blocks       add blocks to receipts / chits
reports.register              add a report (name, params schema, run function)
```

New filters are added to core when a real plugin needs one — never speculatively.

### 3.6 Data

- **Sidecar tables** (the plugin's own models, `ext_<id>_*`). The default.
- **Custom fields**: `ext = JSONField(default=dict)` on `Product`, `ProductVariant`, `Customer`,
  `Supplier`, `Order`, `PurchaseOrder`, `Job`, GIN-indexed, keyed `ext[<plugin_id>][<field>]`.
  Declared with a schema (`fields.declare("catalog.Product", "warranty_months", Int(min=0))`),
  validated on write, included in the serializer, filterable through the existing query
  filters. This also powers no-code custom fields for owners later (plugin id `shop`).
- **Serializer extenders** (§2.3) add computed keys to core payloads, with a mandatory batched
  `prefetch(ids)` so a page of 50 rows costs one extra query per extender. List-payload rules
  still apply (`list-row-is-not-a-document`).

### 3.7 Permissions, settings, audit

- `permissions.declare()` appends a group to `PERMISSION_CATALOG` under `<id>.*`; the existing
  role editor shows it with Arabic labels from the plugin locale.
- `settings.declare()` schemas render as a page under Shop Settings → الإضافات → <plugin>.
- Every log line, 5xx record, Celery task and `PluginFailure` carries `plugin_id`. Support's
  first tool is **"disable all plugins"** — one switch, hot.

---

## 4. Flutter architecture

### 4.1 One renderer, two producers

Generalize `features/ai/ui/` into `shared/surfaces/`:

```
shared/surfaces/
  surface_catalog.dart        the closed item vocabulary (today's PointyAiCatalog items + new ones)
  surface_host.dart           the ONLY genui import (today's ai_surface_host.dart, moved)
  surface_action.dart         navigate / submit / refresh / open_sheet / ask
  surface_data_source.dart    item-owned fetching over PosApiSession (ETag, dedupe, relay)
features/ai/                  uses shared/surfaces (unchanged behaviour)
features/plugins/
  plugin_manifest.dart        model of /api/plugins/ui/
  plugin_manifest_store.dart  fetch, cache to disk, revalidate on state version
  extension_slot.dart         ExtensionSlot(id, context) — what core screens embed
  plugin_screen.dart          route for nav-registered plugin screens
  plugin_form_sheet.dart
```

New catalog items, each built from an existing shared component (AGENTS.md rule):
`data_table` (paged, searchable, owns its own loading — `PointyDataList` + `InfiniteScroll`
+ skeletons), `form` (fields from schema → existing form fields, submits to a plugin
endpoint, shows server validation errors), `metric`, `metric_row`, `status`. Exported by
`make frontend-export-ai-catalog` exactly as today, so the backend validator covers plugin UI too.

### 4.2 Slots core screens must render

| Slot id | Where | Contribution |
|---|---|---|
| `nav` | drawer, rail, ⌘K (via `navigation_catalog.dart`) | screen entry |
| `<resource>.list` columns | products, customers, suppliers, orders, POs, jobs lists | column (key from extender/`ext`) |
| `<resource>.detail` sections | same resources' detail screens | section surface |
| `<resource>.actions` | detail app bars | action → sheet / navigate / submit |
| `pos.actions` | POS action bar | action, `requires` cart/customer |
| `dashboard.cards` | dashboard masonry | card surface |
| `settings.pages` | Shop Settings → الإضافات | rendered from settings schema |
| `reports` | reports hub | report registered by `reports.register` |

Each slot is a single `ExtensionSlot(id: ..., context: {...})` widget; with no contributions it
builds `SizedBox.shrink()` and costs nothing.

### 4.3 De-hardcoding (required refactors)

1. `AppNavigationDestination` enum → keep the enum for core, wrap targets in a sealed
   `NavTarget` = `CoreTarget(AppNavigationDestination)` | `PluginTarget(String screenId)`.
   The two exhaustive switches stay exhaustive.
2. `AppCapability` → keep the enum; add `capabilities.hasExtension('loyalty.view_members')`
   for string keys from the permission catalog.
3. `navigation_catalog.dart` merges core + manifest entries, so plugin screens appear in the
   drawer, the rail and ⌘K together.

### 4.4 Manifest lifecycle

`GET /api/plugins/ui/` returns contributions **already filtered by the user's permissions**,
labels resolved to Arabic, validated. ETag'd; revalidated when the state version bumps (the same
mechanism catalog and settings use). Cached on disk so a till that restarts offline still shows
last-known plugin UI. Fetched once at login into an immutable registry: slots are map lookups,
nothing per frame.

---

## 5. Phases

Each phase ships and is useful on its own. Exit criteria are tests, not impressions.

**P1 — Events + filters in core (invisible).**
`core/events.py`, `core/filters.py`, publish calls in the sales/purchasing/payments/inventory/
operations services, filter call sites for the six v1 filters (no-ops without plugins).
*Exit:* checkout benchmark unchanged with zero subscribers; tests prove an observer that raises
does not affect the sale and a filter that raises/times out falls back.

**P2 — Host: load, install, sign, quarantine.**
`apps/plugins`, `plugins.lock`, signature verification, per-plugin migrate + rollback, hot
enable/disable, health + dead letters, CLI, `/api/ext/<id>/` mount, permissions/settings merge.
*Exit:* on a compiled-image on-prem stack — install a plugin whose migration raises → core
boots and serves; install a good one → its route works and the AI can query it; disable → 404
on next request without restart.

**P3 — Data extension.**
`ext` JSONB on the seven models, field declaration + validation, serializer extenders with
enforced `prefetch`, `ext` filters in list queries.
*Exit:* query-count tests show +1 query per extender per page on Postgres.

**P4 — Flutter surfaces + slots.**
Move AI UI to `shared/surfaces`, add the new items, manifest store, `ExtensionSlot` in the
slots table, `NavTarget`, capability strings, settings page renderer. Preview harness
`?screen=plugins` with a fake manifest.
*Exit:* the AI preview still passes; a fake manifest renders a column, section, POS action,
nav screen and dashboard card in RTL, light and dark.

**P5 — SDK + reference plugin.**
Publish `pointy-sdk` + CLI + `-sdk` dev image + `check`. Build **loyalty** (above) as the
reference plugin and docs walkthrough. Then build one *real* customer-requested feature as a
plugin, by someone who did not build the plugin system, using only the SDK docs.
*Exit:* the acceptance test below passes.

**Acceptance test for the whole system:** a developer outside the core team builds, signs and
ships a plugin that adds a table, a customer column, a checkout discount, a POS button and a
screen; the shop owner trusts their key and installs it from a USB file on a till network with
no internet; the core is then updated to a newer Pointy release and the plugin still works.

**Later, only on real demand:** event → signed webhook (out-of-process apps), owner-defined
custom fields UI on top of `ext`, a registry on the relay, more filters.
