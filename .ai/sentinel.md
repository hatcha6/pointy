# 🔐 Sentinel journal

Critical learnings only — not a run log.

## 2026-08-19 - Permission-map coverage is fail-closed; don't re-audit it
**Learning:** `HasPointyPermission._required_permissions` returns `None` (→ deny) for
any action a viewset's `permission_map` doesn't name, so an unmapped custom
`@action` can never silently inherit a weaker default. Introspecting every router
route confirmed only two viewsets have unmapped actions and both fall through to
`None`. The catalog + `validate_extra_permissions` escalation guard are likewise
bounded by the acting admin's own permissions.
**Action:** Skip "does every viewset declare a permission" as a run theme. If you
re-check it, do it as a 2-minute URL-resolver introspection, not a file read.

## 2026-08-19 - Detail actions that look like they skip `get_object()` don't
**Learning:** `OrderViewSet.void`, `RegisterSessionViewSet.close`,
`PurchaseOrderViewSet.receive` etc. wrap their body in `run_idempotent_request(...)`
and delegate to a private `_void` / `_close` method that calls `self.get_object()`.
An AST scan of the decorated function alone reports "NO get_object" for ~25 money
and stock actions — all false positives.
**Action:** Follow the delegate before flagging. Row-scoping lives in
`get_queryset()`, and `get_object()` is what applies it.

## 2026-08-19 - The AI tool dispatcher is not a parallel permission model
**Learning:** `apps/ai/tools.py` reaches business data by *replaying the real
viewset* (`_run_viewset` / `_run_write_viewset` / `_scoped_queryset`, the last of
which calls `view.check_permissions()` explicitly), so a cashier-token AI session
sees exactly what the cashier's API session sees. Only `list_resources`,
`describe_resource` and `suggest_sale_price` skip scoping, and none of them read
business rows. Note the dispatcher uses `APIRequestFactory`, so it bypasses all
Django *middleware* — anything security-relevant must live in a permission class
or `get_queryset`, never in middleware.
**Action:** Audit new AI tools by asking "does it go through a viewset?", not by
re-reading the registry deny-lists.

## 2026-08-19 - Blank stored secret + `compare_digest` = anonymous auth
**Learning:** `RelayInstallation.connector_token` is legitimately `""` — 
`ensure_relay_installation` copies it straight from the optional
`POINTY_RELAY_CONNECTOR_TOKEN` env var. Three endpoints hand-rolled the same
`secrets.compare_digest(header, installation.connector_token)` check; two guarded
the blank case and the heartbeat one did not, so a missing header compared equal
to the empty stored token and authenticated anonymous callers. Also:
`secrets.compare_digest` raises `TypeError` on non-ASCII `str`, and Django decodes
headers as latin-1 — a high byte in a credential header is a 500, not a rejection.
**Action:** Whenever a secret is compared against a model field, check whether the
field can be empty *and* whether the comparison is duplicated. Duplication is the
tell — the copies drift. Prefer one shared helper (`connector_token_accepted`).

## 2026-08-19 - Environment: Docker may be down; sqlite is the documented fallback
**Learning:** `make postgres && make redis` fails silently-ish when Docker Desktop
isn't running. Under `DATABASE_URL='sqlite://:memory:'` the whole
`apps.core.BootstrapAdminTests` class (13 tests) errors on Redis
`ConnectionError` — pre-existing and unrelated to any change.
**Action:** Baseline the suite on a stashed tree before attributing failures to
your diff; `git stash push -- <only your files>` keeps other routines' in-progress
work untouched.
