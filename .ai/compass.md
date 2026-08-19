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

Still unguarded on a request path (deliberately left, not on the checkout path):
`apps/messaging/ratelimit.py` (`cache.add`/`incr`/`get` — outbound SMS pacing;
fail-closed is arguably right there, but a raw 500 is not a defined outcome),
and the `.delay()`/`.apply_async()` calls in `apps/core/backup.py`,
`apps/customers/views.py`, `apps/messaging/views.py` (inbound SMS webhook),
`apps/migration/services.py`.

**Action:** Start from this list rather than re-grepping `django.core.cache`.

## 2026-08-19 - The Celery broker has the same unbounded-read hole

**Learning:** `CELERY_BROKER_URL` is the same Redis. Kombu's redis transport
also defaults `socket_timeout` and `socket_connect_timeout` to `None`, so
`apply_async()` against a wedged broker hangs forever — including
`apps/notifications/services.py`'s top-up, which sits on the bell/badge poll
every device runs. `retry=False` bounds *retries*, not the socket.

**Action:** The fix is `CELERY_BROKER_TRANSPORT_OPTIONS = {"socket_timeout":
..., "socket_connect_timeout": ...}`, but it applies to the worker's consumer
connection too, so it needs verification against a running worker (kombu's
consumer side is async/hub-driven, so it *should* be safe — confirm, don't
assume). Left out of the CACHES timeout PR deliberately to keep the blast
radius to the web process.
