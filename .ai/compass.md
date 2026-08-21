# 🧭 Compass — resilience journal

Critical learnings only. Not a run log.

## 2026-08-19 - Redis "wedged" is a different outage from Redis "down"

**Learning:** Every fail-open guard in this backend (`apps.core.caching._safe_get`,
`apps.core.sessions`, the DRF throttle mixin, `apps.discounts.cache`,
`apps.price_checker.cache`, `apps.sales.register_summary`, `apps.catalog.cache`)
is a `try/except` — which only helps when Redis *raises*. A Redis that refuses
connections raises immediately; a Redis that accepts the TCP handshake and then
stops answering (host swapping, container wedged mid-restart, LAN dropping
packets after the handshake) never raises at all, because redis-py defaults
`socket_timeout`/`socket_connect_timeout` to `None`. Not one of those guards
fires. `try/except` around an unbounded blocking call is decoration.

**Action:** When auditing a fail-open guard, ask "does the failure it catches
actually *raise*?" before crediting it. For any client library, check the
timeout defaults first — `None` is common and always means "forever". Reproduce
with a black-hole listener (`bind` + `listen(backlog)`, never `accept`): the
kernel completes the handshake for you, so `connect()` succeeds and only the
read hangs — a deterministic, dependency-free way to simulate a wedged service.

## 2026-08-19 - Where Redis guards already live (don't re-audit these)

**Learning:** Already fail-open and verified: cache/user/permission/shop-settings
(`apps/core/caching.py`), sessions (`apps/core/sessions.py`, cached_db with the
cache side made fail-open), all auth throttles (`apps/core/throttling.py`
`_FailOpenThrottleMixin`), catalog + notifications version stamps, discount
preview, price-checker lookup, register-session summary, AI usage/digest,
catalog cache invalidation, `apps/channels/middleware.py`.

Still unguarded on a request path: `apps/messaging/ratelimit.py`
(`cache.add`/`incr`/`get` — outbound SMS pacing; fail-closed is arguably right
there, but a raw 500 is not a defined outcome). The `.delay()`/`.apply_async()`
calls are now all bounded through `apps/core/dispatch.py` — see the broker entry
below.

**Action:** Start from this list rather than re-grepping `django.core.cache`.

## 2026-08-19 - Bound the broker per-publish, not per-app

**Learning:** `CELERY_BROKER_URL` is the same Redis, and kombu's redis transport
also defaults `socket_timeout`/`socket_connect_timeout` to `None`, so
`apply_async()` against a wedged broker hangs forever. `retry=False` bounds
*retries*, not the socket. The obvious fix — `CELERY_BROKER_TRANSPORT_OPTIONS`
in settings — also lands on the worker's BRPOP consumer, whose `brpop_timeout`
is 1s: a 1s `socket_timeout` races the server's own nil reply. `send_task`
accepts `connection=`, and when it is supplied the app's producer pool is never
consulted, so a caller can carry its own bounded connection and leave the worker
entirely alone. That is `apps/core/dispatch.py` (`enqueue_best_effort` /
`enqueue_or_raise`); route every request-path dispatch through it.

**Action:** Also set `max_retries: 0` in those transport options — kombu's
`_extract_failover_opts` reads it, and without it the caller's deadline is
`socket_timeout × 4`, not `socket_timeout`. Measured: unbounded = never, 1.0s
alone = 4.01s, 1.0s + `max_retries: 0` = 1.00s.

## 2026-08-19 - `transaction.on_commit` still runs inside the request

**Learning:** `apps/fraud/services.py::schedule_targeted_sweep` looked like
background work — a `.delay()` behind an `on_commit` hook — but on_commit
callbacks execute in the request thread right after COMMIT, so its enqueue sat
squarely on the returns, void, exchange, register pay-out and register-close
responses. The sale committed and the till would have waited forever. The
`try/except Exception: pass` around it read as a guard and was decoration, for
the reason in the first entry above.

**Action:** An `on_commit` hook is *not* off the request path. When auditing
"is this dispatch on the critical path?", follow `on_commit`,
`ATOMIC_REQUESTS`, middleware and DRF finalizers, not just the view body. To
inject a broker failure against the real app in a test, set the
`CELERY_BROKER_URL` **environment variable** (celery's `Settings.broker_url`
reads `os.environ` ahead of the configured value) and then drop the cached pools
with `app.__dict__.pop("amqp", None); app._pool = None` — see
`apps/core/test_broker_timeouts.black_hole_broker`.

## 2026-08-19 - A guard cannot cover what the caller evaluates to reach it

**Learning:** Wrapping a fragile call in `enqueue_best_effort(...)` moved the
`try/except` *inside* the helper — but the inbound SMS webhook was passing
`current_app.tasks["crm.route_inbound"]` as the argument, and arguments are
evaluated before the callee is entered. Celery's registry raises `NotRegistered`
on a miss, which is exactly the condition a by-name lookup exists to tolerate
(crm's tasks module not imported yet), so the new guard covered strictly *less*
than the bare `try/except` it replaced: the row was written and the view then
500'd, handing a retryable error back to a gateway for a message already stored.
Worse, it only reproduced when `apps.messaging` ran alone — a full-suite run
imports crm and the registry hits, so the whole suite was green.

**Action:** When centralising a guard, check what the call sites must *evaluate*
to call it. If a lookup, parse or property access can throw, the helper has to
take the raw input (a task **name**, a URL string, a key) and do the lookup
inside its own `try` — never accept the already-resolved object. And when a
failure depends on import order, inject it explicitly (`mock.patch.dict` over
`current_app.tasks`) rather than trusting an app-scoped run to expose it.

## 2026-08-20 - The client had no read deadline either

**Learning:** The journal's first entry (a wedged service never raises, so the
`try/except` around it never fires) is not a backend-only shape — it held on the
Flutter side too, and worse. `PosApiSession._send` is the single funnel for
every buffered request in the app, and it awaited `package:http` with no
`.timeout()`. `dart:io`'s `HttpClient` sets no read deadline, so a backend that
accepted the connection and went silent (wedged uvicorn, AP roam stranding a
pooled connection, LAN dropping packets post-handshake) hung a checkout POST
forever. Everything downstream was already correct — the relay fallback, the
`onLocalTargetUnreachable` re-discovery hook, the repositories' `on Exception`
— and none of it ever ran, because nothing ever threw. The printing transports,
the discovery probe and the self-updater were all bounded; the main API path
was the one nobody had checked.

**Action:** When a codebase has visibly careful timeouts on its *peripheral*
I/O, that is not evidence the central path is bounded — check the funnel every
request goes through, and check the client library's defaults rather than the
surrounding code. Reproduce with a `MockClient` returning
`Completer<http.Response>().future`: it is the client-side twin of the
black-hole listener, needs no sockets, and fails deterministically in a test
bounded by `expectLater(...).timeout(...)`.

## 2026-08-20 - A timeout is not a connection refusal, on the money path

**Learning:** Adding a deadline silently changed what an exception *means* to
the retry above it. `_send`'s relay-fallback replay was written for "connection
refused" — proof the server never saw the request, so replaying is free. A
`TimeoutException` proves nothing: the sale may already be committed, and the
same replay would then bill the customer twice. The saving grace was elsewhere:
`checkoutIdempotencyKeyFor` derives the key from the draft JSON, so it is
stable across retries of the same cart — the cashier pressing checkout again
after a timeout is already safe.

**Action:** When introducing a timeout into an existing error path, re-read
every `catch` above it and ask whether it was written for a failure that proved
the request never landed. Gate the replay (`replayable`: GETs and keyed writes
only) rather than widening it. And check that the *user's* natural retry is
idempotent too — that is the retry that actually happens.

## 2026-08-20 - `os.replace` is atomic against a crash, not against a power cut

**Learning:** `apps/core/backup.py` wrote the nightly archive to `.name.tmp` and
`os.replace`d it into place — the textbook atomic-publish shape, and it *looks*
finished. It is only half of the recipe: closing the `ZipFile` hands the bytes
to the page cache and nothing more, so a mains cut inside the writeback window
leaves the final filename pointing at a truncated or zero-length file. Three
things then conspire to make the loss total and silent — `_delete_old_backups`
unlinks the previous good archives immediately after (unlinks are journaled
metadata and *do* survive the cut the data did not), `_sha256_file` reads the
same page cache so the recorded checksum always matches, and the job row is
marked SUCCEEDED. The destination is a USB stick in a shop whose power is not
dependable, which is the exact hardware where write-back caching is longest.
The whole backend contained no `os.fsync` call at all; the Flutter side already
had this right (`sqlite_key_value_store.dart`, WAL + `synchronous=FULL`).

**Action:** Treat "temp file + atomic rename" as an *incomplete* durability
guard until you see `fsync(file)` before the rename and `fsync(dir)` after it —
grep for `os.replace`/`shutil.move`/`.rename(` and check each for a neighbouring
fsync. Ask what runs *after* the publish: a prune, a retention sweep or a
cleanup that destroys the previous good copy turns a survivable partial write
into total loss. To test durability without a real power cut, wrap `os.fsync`
(record `os.fstat(fd).st_ino`), `os.replace` and the prune, then assert the
*ordering* of inodes — rename preserves the inode, so the temp file is
identifiable from the final path afterwards.

## 2026-08-20 - A persistent connection outlives the server it points at

**Learning:** `CONN_MAX_AGE=120` (what on-prem runs) means each worker keeps a
Postgres connection across requests, and nothing in Django notices when the
*server* end goes away — a Postgres or PgBouncer restart after a mains blip, a
container recycle, an update flip. `close_old_connections` on `request_started`
only closes connections that are obsolete by age or that have **already**
errored, so a connection inside its window that has never failed is handed
straight to the view and raises on its first query: one 500 per pooled
connection after every restart, and one of them can be a checkout. Same shape
as this journal's Redis entries — the recovery path existed (Django reconnects
the moment the connection is closed) and simply never ran, because nobody
looked. `CONN_HEALTH_CHECKS` was never set. It also made `/readyz/` report a
perfectly healthy database as down, which is the signal compose's healthcheck
and the update-agent's auto-rollback read — a DB restart could therefore roll
an update back on its own.

**Action:** Whenever a resource is *pooled or cached across requests*, ask what
proves it is still alive, not just what happens when it dies. For Django
specifically: `CONN_MAX_AGE > 0` without `CONN_HEALTH_CHECKS = True` is always
a bug. Two test traps here: (1) `ClientHandler` deliberately disconnects
`close_old_connections`, so the test client never fires the request boundary —
call `close_old_connections()` by hand or the health check is skipped and the
test lies; (2) the runner leaves `CONN_MAX_AGE` at 0, so the failure cannot
reproduce until the connection is put into production shape
(`close()`, set `CONN_MAX_AGE`, `connect()`). Inject the failure with
`pg_terminate_backend(pid)` from a second connection — the server-side twin of
the black-hole listener, and literally what a restart does.

## 2026-08-20 - The thing that saves the cart is the thing that double-bills it

**Learning:** `pos_persistence.dart` snapshots the POS carts to disk expressly
so "a crash or restart never loses a sale" — and that feature is what turns a
mains cut into a double sale. The idempotency key lived only in
`_PosSaleSession._checkoutIdempotencyKeysBySignature`, an in-memory map that
was never part of the snapshot. Cut the power in the window between the backend
committing the sale and the till reading the response, and the next launch
restores the *cart* without the *key*: the cashier sees the same basket, presses
checkout, a fresh random key is minted, and the same sale is billed, de-stocked
and rung into the till twice. Two further traps sat behind it. (1) The key was
memoized but not derived — it is a random UUID, so nothing else can reconstruct
it; the journal's earlier note that it was "derived from the draft JSON" was
wrong, and the safety it credited only ever held inside one process lifetime.
(2) The memo key was the *whole* draft JSON including `print_invoice`, so a
printer that resolved differently between two attempts — the shop settings
failing to reload during the very outage that swallowed the first response
clears the manual print toggle — rotated the key on its own, no power cut
needed. Writing the snapshot is debounced 500ms, so simply persisting the key
was not enough either: it has to be flushed *before* the request goes out.

**Action:** When a client-side guard is a *memo* rather than a *derivation*,
ask what happens to the process holding it — a random value cached in RAM is
not a guarantee, it is a guarantee for as long as nothing restarts. Whenever a
feature restores user state after a crash, enumerate what is restored *with* it:
restoring an action's inputs without restoring its de-duplication token invites
the user to repeat it. And check the memo's cache key for fields that are not
part of the operation's identity (routing, presentation, device config) — they
turn an unrelated failure into a rotated token. Reproduce with two view models
sharing one `MemoryScopedJsonStorage`: let the debounce flush the cart, fail the
first checkout, then build a second view model and `restorePersistedSessions` —
on `main` the cart comes back and the keys differ, which is exactly the shape
of the bug.

## 2026-08-20 - A 503 on a health endpoint is an action, not a report

**Learning:** Every request path in this backend is fail-open on Redis (see the
entries above), and `/readyz/` still counted the cache as a *required*
dependency. That endpoint is not diagnostics: it is the compose healthcheck
(`deploy/onprem/docker-compose.yml`), so a sustained Redis outage marked the
backend unhealthy, and `deploy/onprem/watchdog.sh` "heals" an unhealthy
container by `docker restart` — SIGTERMing a backend that was serving every
till correctly, once per cycle, for as long as Redis stayed down. `celery-worker`,
`celery-beat` and the relay `connector` all gate on `backend: service_healthy`,
and the zero-downtime flip only moves traffic to a container that answered
`/readyz/`. The same assumption sat one layer earlier:
`backend/docker/wait_for_services.py` waited on Redis before starting *anything*
and `SystemExit(75)` when it did not answer, so a shop rebooting after a power
cut onto a Redis with a corrupt dump could never bring the POS up at all —
with a perfectly healthy Postgres behind it.

**Action:** For every health/readiness check, ask *who acts on the answer* before
asking whether the answer is accurate — a restart loop, a `depends_on` gate and
an update rollback are all downstream of one boolean. Split checks into required
vs optional explicitly (`OPTIONAL_CHECKS` in `pointy/health.py`) rather than
`all(...)`, and keep reporting the optional failure in the payload so it is
visible without being actionable. The general shape: whenever the codebase has
worked hard to make a dependency survivable at request time, grep for the places
that still treat it as fatal — startup waiters, healthchecks, `depends_on`,
readiness probes. `deploy/onprem/README.md` still says `/readyz/` "verifies
database and Redis access"; left alone deliberately (deploy/** escalates).

## 2026-08-21 - A `try/except` inside a transaction is decoration for DB errors

**Learning:** Checkout's kitchen-chit enqueue was already wrapped in
`try/except Exception` with the comment "must never fail or roll back a
completed, paid sale". It cannot do that. `run_idempotent_request` wraps the
whole checkout in one `transaction.atomic()`, and a step that fails on a
*database* error aborts the entire Postgres transaction — so swallowing it only
defers the failure to the next query (the idempotency record's own `save()`),
which raises `InFailedSqlTransaction` and rolls the sale back anyway. Only a
savepoint (`with transaction.atomic():` *inside* the `try`) actually recovers.
The receipt claim next to it had no guard at all — despite the kitchen comment
claiming it "mirrors the receipt enqueue" — so *any* printing fault, DB or not,
discarded a completed, paid, de-stocked sale and 500'd the cashier, identically
on every retry. Note which calls do and don't get a savepoint for free:
`get_or_create` and `claim_print_job` have their own `atomic()`, but the bare
`.save()`/`.create()` in `create_job_event` and the enqueue paths do not.

**Action:** This is the transaction-shaped twin of the journal's first entry
("does the failure it catches actually raise?"): ask instead **"is the
transaction still usable after this `except`?"**. Any `try/except` around DB
work inside an outer `atomic()` needs its own `transaction.atomic()` savepoint
or it is decoration. And when a comment says a guard mirrors another one, go
read the other one — here the model being mirrored didn't exist. Reproduce
without mocking a driver: patch the fragile step to run
`cursor.execute("SELECT 1 / 0")`. That is a real aborted transaction, and it
only reproduces on Postgres — sqlite will pass and lie.

## 2026-08-21 - Every `select_for_update` in this repo waited forever

**Learning:** Postgres' `lock_timeout` defaults to `0` — *wait forever* — and
nothing in this backend ever set it, so all ~40 `select_for_update` sites were
unbounded waits. The journal's recurring shape again: the failure never raises,
so no guard fires. What made it a money bug rather than a slowness bug is where
the wait ends. `run_idempotent_request` opens the transaction that wraps every
checkout/return/void/register operation, and the till's own deadline
(`ApiSession.defaultRequestTimeout`, 60s) is what actually expires — and a
client-side timeout on a money write is precisely the failure that *cannot say
whether the sale committed* (see the 2026-08-20 entry). A server-side bound
converts an unknown outcome into a known one: lock never taken → transaction
rolled back → nothing sold → retry is safe. Realistic holders are ordinary shop
work (bulk reprice/archive over thousands of products, a stock-count apply, a
legacy import) plus the unbounded one: a session left *idle in transaction* by a
worker blocked or killed mid-flight.

**Action:** Use `SET LOCAL lock_timeout` (never plain `SET`) at the top of the
one transaction that matters — it is transaction-scoped, so it is safe under
PgBouncer transaction pooling and leaves migrations, backups and reports with
their unlimited wait, which they need. Detect it by SQLSTATE `55P03` on the
wrapped driver error (`exc.__cause__.sqlstate`), not by message; `57014` is
`statement_timeout`, a different and far riskier knob that this repo should keep
unset. Do NOT reach for a connection-level `options: -c statement_timeout=...`:
it lands on `manage.py migrate` and the analytics export too. To test an
unbounded wait, hold the row from a *second real connection* (`connections.
create_connection("default")`, `set_autocommit(False)`, `SELECT ... FOR UPDATE`)
under `TransactionTestCase`, and run the request on a `threading.Thread` with a
`join(deadline)` — otherwise "hangs forever" wedges the runner instead of
failing it.

## 2026-08-20 - A job row is a lock, and a killed worker never unlocks it

**Learning:** `apps/core/backup.py::active_maintenance_job()` gates *every*
backup — the daily scheduled one, the manual button, and restores — on "is any
`SystemMaintenanceJob` still queued/running?". But only `run_backup`'s `except`
block marks a job failed, so anything that kills the process outright (power
cut, container restart, OOM, celery's hard `time_limit`) leaves the row
`running` forever, and a `queued` row is stranded the same way when the broker
restarts empty and the task is never delivered. One abandoned row silently
disables the shop's backups permanently: the scheduled task no-ops every minute,
the manual button 400s "another job is already running", and the UI shows a
spinner that never resolves. There is no cancel endpoint and no reaper — the
only exit is a DB edit. On unreliable mains, the shop loses its backups to
exactly the outage backups exist for.

**Action:** Any "is something already in progress?" guard that reads a
*persisted* row is a lock held by a process that may not survive to release it.
Ask what releases it when the holder is SIGKILLed. The bound wants deriving from
an existing authority, not a new magic number: celery hard-kills at
`POINTY_BACKUP_TASK_TIME_LIMIT`, so a job whose heartbeat (`updated_at`, bumped
by `update_progress`) predates that cannot still be alive. Reap by marking
*failed*, not by ignoring the row — ignoring it leaves the UI's phantom
"running" state in place. Look for this shape elsewhere: `_ensure_no_active_job`
is one instance; stock-count applies, migration runs and payroll drafts are
worth checking for the same pattern.
