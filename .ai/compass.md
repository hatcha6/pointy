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
