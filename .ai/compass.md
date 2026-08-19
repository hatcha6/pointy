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
