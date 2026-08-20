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

## 2026-08-19 - Secret hygiene and the public-token surface are clean; don't re-audit
**Learning:** Audited four things end to end and found nothing. (a) Credential
serializers are consistently write-only across three *independent*
implementations — `MessagingGatewaySerializer`, `BioTimeConnectionSerializer`,
`MigrationSourceSerializer` — each exposing only a `has_password` boolean, so a
GET never echoes a stored secret. (b) The public token-addressed views
(`PublicInvoiceView`, `PublicJobView`) are gated on `request_is_relayed` + a
`ShopSettings` feature flag + `secrets.token_urlsafe(24)` (192 bits), and both
serializers are explicit allow-lists carrying no cost prices and no phone
numbers. (c) The analytics 5xx capture stores `request.path` and a
`query_string_present` **boolean** — deliberately not the query string, no
headers, no body — and `traceback.format_exception` omits frame locals, so
credentials cannot reach an `AnalyticsEvent` row or the diagnostics export.
(d) `ClientFileView` is unauthenticated but layers a LAN gate, a manifest
filename allow-list, and a resolved-path containment check; the landing page
`escape()`s every interpolation.
**Action:** Skip "are secrets leaking into serializers / logs / tracking" and
"can the public invoice or job page be enumerated" as run themes. The one thing
worth re-checking cheaply is whether a *new* credential-bearing model followed
the write-only + `has_secret()` pattern — that is the convention, so a
deviation is the finding.

## 2026-08-19 - A `sentinel/*` branch is invisible to Warden, not merely unreviewed
**Learning:** PR #37 carried a verified fix and a clean Warden review, yet could
never merge: Warden's guard matches the head-branch *name* against `claude/`,
never the author, so the PR was skipped on every hourly run indefinitely.
Recovery is cheap — cherry-pick the single commit onto `claude/sentinel-<topic>`
off fresh `origin/main`, open the replacement, close the original with a pointer.
**Action:** Check `gh pr list --json headRefName` for your own stale PRs at the
*start* of a run, before picking an audit theme. Clearing a deadlocked
already-verified fix beats starting a new one.

## 2026-08-20 - Role *reachability* is the check worth running, not role coverage
**Learning:** The earlier "does every viewset declare a permission" sweep proved
coverage is fail-closed but says nothing about whether the declared permission is
the *right* one. Resolving every router route's `permission_map` and intersecting
it with each role's `*_PERMISSION_CODES` prints exactly what a cashier / auditor /
clerk can actually reach — a 40-line script, and the only way to see that e.g.
`OrderViewSet.void` needs merely `sales.add_order`. That one is deliberate: the
guard is `get_queryset` (own `register_session__owner_key`) plus the fact that a
void's money posts to the *current open* session, never the closed one it came
from. Auditor came back strictly read-only. Nothing else was misassigned.
**Action:** Re-run the reachability intersection rather than re-reading
`permission_map`s. Note plain `APIView`s are invisible to router introspection —
walk `get_resolver()` instead, which also surfaces the DRF default
(`IsAuthenticated` alone) on views that declare no `permission_classes`.

## 2026-08-20 - Enforcement often lives in the service, not the permission class
**Learning:** Four views that look under-permissioned are not. `ReportRunViewSet`
is `IsAuthenticated` with no map — but `create` goes through
`generate_report_payload`, which raises `ReportAccessDenied` per report
definition, and `get_queryset` narrows to own runs without
`reports.view_reportrun`. `BusinessNotificationViewSet` gates per-code in
`visible_notifications_for_user` / `NOTIFICATION_AUDIENCE_RULES`.
`AiConversationViewSet` filters `user=request.user`. Marketing consent is
enforced at campaign *expansion* (`campaigns.py` → `can_send`), not at
`enqueue_message`, which is consent-agnostic on purpose. And transactional SMS
deliberately ignores `do_not_contact` (`customers/models.py` documents it).
**Action:** Before flagging a bare `IsAuthenticated`, read the service the action
delegates to and the `get_queryset`. All five of these are settled — don't
re-flag them.

## 2026-08-20 - Every hand-rolled `compare_digest` now goes through one helper
**Learning:** The non-ASCII `TypeError` noted in the connector-heartbeat entry was
not confined to headers. Three more sites had it — `connector_setup_token_accepted`
(latin-1 header), `IsGatewayPeer` (UTF-8 `?token=` query param, raising inside
`has_permission`), and the SMS Gate `X-Signature` HMAC — each letting an
unauthenticated caller convert a 403 into a 500 at will. All four now call
`apps.core.credentials.constant_time_secret_equal`, which compares UTF-8 *bytes*
(never raises, and a non-ASCII stored secret still authenticates) and treats a
blank side as unequal. `apps.channels.authenticate_api_key` was already clean —
it compares hex hashes and `.exclude(api_key_hash="")`.
**Action:** Any new secret comparison uses that helper. A bare `compare_digest`
on `str` in a credential path is the finding, no further analysis needed.

## 2026-08-20 - "Private REMOTE_ADDR" is not "on the LAN" — the connector is on the LAN
**Learning:** The relay connector dials the local backend from the shop's own
network, so **every** request tunnelled in from the internet arrives with a
private `REMOTE_ADDR`. `request_is_private_network()` therefore returns True for
remote callers, and is not by itself an authorisation gate.
`request_discovery_allowed` knew this (it rejects `request_is_relayed` first) and
the client-installer views inherited the fix by reusing it — but the two
hand-rolled copies did not: `price_checker.IsPrivateNetworkOrAuthenticated` and
`messaging.IsGatewayPeer` called `request_is_private_network` directly. The
price-checker pair was genuinely reachable (`relayTarget` proxies any `/api/…`
path on the access token alone), giving anyone holding the shop's *device-level*
relay token an unauthenticated catalogue read and kiosk-registration write with
no user session. All three now go through `request_is_lan_local()`.
**Action:** Treat `request_is_private_network` as a plumbing primitive, not a
gate — a new caller of it in a permission class is the finding. This is the same
"duplication is the tell" shape as the `compare_digest` sweep: the LAN check had
drifted into three copies and only the original stayed correct.

## 2026-08-20 - Surface 5 (injection / input handling) audited; nothing found
**Learning:** Swept it end to end and it is clean, so don't re-derive: the only
non-migration `RawSQL`/`cursor.execute` sites build identifiers from
`_meta.db_table` + `connection.ops.quote_name` (`analytics/export.py`) or are
transport code that parameterises values and quotes identifiers
(`migration/transports/sql_base.py`). Both URL fetchers are hardened and
documented — `AiFaviconView` only ever fetches a fixed Google endpoint with the
host as a *query param*, and `attachments/image_search.py` has a real SSRF guard
(scheme/credential/hostname checks plus `getaddrinfo` → private/loopback/
link-local/multicast/reserved rejection) that is re-applied on every redirect via
`ValidatingRedirectHandler`. Attachment storage paths are `uuid4().hex` with a
regex-validated extension — the uploaded filename never reaches the path. The
restore-archive reader (`core/backup.py`) requires a `pointy-backup/` first
component and rejects absolute paths and `..`.
**Action:** Skip this surface as a run theme. Re-check only a *newly added*
outbound fetch (does it call `validate_remote_image_url`?) or a new writer that
derives a path from user input.

## 2026-08-20 - The relay trust boundary audited end to end; nothing found
**Learning:** Audited surface 3 (the Go relay) fully and it is clean. Specifics
worth not re-deriving: every route in `ServeHTTP`'s switch carries an explicit
`RouteMode` gate *plus* an auth wrapper, and all three wrappers are fail-closed
on an unset secret — `withAdmin` 401s when `AdminToken == ""` (unless the
explicit `AllowOpenAdmin` dev flag), `withNodeProxy` 404s when `NodeProxyToken`
is blank. The scoped-vs-fleet split holds: `handleInstallationRoutes` computes
`selfServiceable` from (path-part count, method) and then requires
`ValidateAccessTokenIdentity(...).ID == id`, so an installation token reaches
only its own GET / connector-certificate / metadata routes and every other
sub-route falls through to `withAdmin`. No handler anywhere takes an
installation id from a body or query field — `handleAgentManifest`,
`handleAgentStatus`, `handleAIUsage`, `handleListHolidays` all derive it from
the validated token (the only `FormValue("installation_id")` is the
admin-gated console form). Artifact traversal is closed twice over:
`handleAgentArtifact` rejects any `/` in the version and `artifacts.safeVersion`
is a character allow-list that additionally rejects `..`.
**Action:** Do not re-audit relay routing, wrapper fail-closure, scoped-token
containment or artifact path handling. Re-check only if a *new* route is added
to the `ServeHTTP` switch — the thing to verify then is that it has both a
`RouteMode` gate and a wrapper, since the switch is hand-maintained.
## 2026-08-20 - An empty permission tuple means "any authenticated user"
**Learning:** `HasPointyPermission` has three outcomes, not two:
`_required_permissions` returning `None` denies (the unmapped case, already
journaled), but returning an **empty** tuple hits `if not required_permissions:
return True` — authenticated-only, no permission required. So `"action": ()` in
a `permission_map`, or a `get_required_permissions` that returns `()`, is a
real open door that the "is every action mapped?" check does not catch. All
three current uses are legitimately scoped *inside* the handler, and each is a
false positive: `EmployeeLoanViewSet.mine` filters `Employee.objects.filter(
user=request.user)`; `request_loan` delegates to `EmployeeLoanRequestSerializer`,
which has no `employee` field and calls `request_employee_loan(user=request.user)`
so the loan can only ever be bound to the caller; and `DashboardView` gates every
section individually, with all revenue/profit sections behind
`reports.view_reportrun` and row scope behind `user_has_full_visibility`.
**Action:** `grep -rn ': ()' apps/*/views.py` plus a scan of every
`get_required_permissions` is a cheap, high-signal 2-minute check. Treat a hit
as a finding *only* if the handler does not scope to `request.user` — but a
newly added empty tuple with no such scoping is a genuine hole.

## 2026-08-20 - The escalation guard covered `extra_permissions` but not `role`
**Learning:** `PosUserSerializer.validate_extra_permissions` has an explicit
"you can only grant what you hold" rule — and the two adjacent fields that grant
just as much had none. `role` is a `ChoiceField` over `ROLE_GROUPS` with no
guard, and `manager` resolves to `role_permission_codes(...) is None` = every
permission; `password` lets an actor take over any account outright. Both
`auth.add_user` and `auth.change_user` are in `PERMISSION_CATALOG`, so a manager
delegating staff-account upkeep to a cashier handed them a one-request path to
`role: manager` (or to resetting the manager's own password and logging in).
Guards now sit in `validate_role` + `validate()`, keyed on
`role_permission_codes(resolved_role) is None` so a manager/superuser
short-circuits and the default configuration is unchanged.
**Action:** When one field on a serializer carries an authorization check, ask
what *else* on that serializer grants the same thing. A per-field guard is a
smell: the check belongs to the operation, not the field. Self-service edits use
different serializers (`CurrentUserUpdateSerializer`, `PasswordChangeSerializer`)
so tightening `PosUserSerializer` cannot break a user editing their own profile.

## 2026-08-20 - A transport that self-declares "trusted" is an auth bypass
**Learning:** `IsGatewayPeer` authenticates a messaging webhook on the gateway's
shared `webhook_token` when one is stored, and otherwise **delegates to
`transport.verify_inbound`** — which makes each driver its own authenticator.
`base.py` returns False and `sms_gate.py` requires a signing key, but
`fake.py` returned `True` unconditionally ("tests exercise the routing
pipeline"). That driver is registered in production (`transports/__init__.py`
imports it for the `@register` side effect) and `Provider.FAKE` is a real
model choice, so a gateway created but never activated — no token provisioned —
accepted an unauthenticated POST from any LAN peer, with a caller-chosen
`from` number. That routes into `crm.route_inbound`: a forged "STOP" revokes a
real customer's marketing consent, anything else threads into the conversation
staff read and reply to. Verified 200 + row stored before the fix.
**Action:** Two things generalise. (a) When a permission class delegates the
credential check to pluggable code, audit *every* registered implementation,
not the base class — the abstract default being fail-closed proves nothing.
(b) "Test-only" is a claim about intent, not reachability: check whether the
thing is registered in production and selectable through the API. The new
`test_no_registered_transport_vouches_for_a_secretless_gateway` asserts the
invariant over the whole registry so the next driver cannot reopen it.
