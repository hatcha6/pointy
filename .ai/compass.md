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
