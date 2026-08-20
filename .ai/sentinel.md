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

## 2026-08-20 - The relay's identity plumbing is sound; its *metering* was the gap
**Learning:** Audited the whole relay trust boundary end to end and the identity
half is genuinely tight — every `Validate*Token` enforces the token *purpose*
(so a ticket can't act as an access token), tokens are stored as SHA-256 hashes
(a blank stored hash therefore never matches, unlike the Django-side plaintext
`compare_digest` bug), `handleRelay` routes to `installation.ID` taken from the
validated credential and never from a path or body field, the connector
handshake binds the mTLS certificate fingerprint to the token's installation,
and `handleInstallationRoutes` restricts self-service to three routes and
requires `installation.ID == path id`. Don't re-audit those. The real gap was
one layer up: `POST /v1/ai/chat` read `count_usage` **from the request body** to
decide whether to charge the per-shop usage window — and the caller is the
shop's own on-prem backend, so that is an unverifiable claim. Marking every turn
a continuation made the paid 5h/weekly limits opt-out entirely; the repo's own
`TestHandleAIChatCountUsageFalseSkipsCharge` documented it ("never charge, so
they always pass"). The code's stated safeguard — the global `limit.Limiter`
slot — is a non-blocking *concurrency* semaphore: it bounds in-flight count, not
request rate and not cost.
**Action:** Two reusable tells. (1) When a handler branches on a client-supplied
field to skip a *charge* or a *limit*, ask who the client is — on the relay it is
never Anthropic-side code, it is the shop. (2) A concurrency semaphore is not a
rate limit; don't accept "the global limiter covers it" as the answer for an
unmetered path. Also note `validateConnectorCertificate` returns nil when
`ConnectorCertificateFingerprint == ""` — that is the deliberate pre-enrolment
bootstrap window (token-only auth, still 32 random bytes), not a finding.
