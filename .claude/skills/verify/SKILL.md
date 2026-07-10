# Verify Pointy changes at their runtime surface

## Backend API / SSE under real ASGI (uvicorn)

Production serves Django via uvicorn (`backend/docker/entrypoint.py`), while
`make backend-run` and the test client are WSGI — ASGI-only bugs (streaming,
async iteration) never show up in tests or runserver. Verify those against
uvicorn directly:

1. Scratch DB (never touch `db.sqlite3`):
   `export DATABASE_URL="sqlite:////abs/scratch/verify.sqlite3"` then
   `backend/.venv/bin/python manage.py migrate` and seed a superuser +
   `RelayInstallation(subscription_active=True, ai_enabled=True, relay_enabled=False)`
   for AI endpoints. Redis is optional — every cache layer is fail-open.
2. Stub external deps in an ASGI wrapper module (scratch dir), e.g. replace
   `apps.ai.views.RelayControlClient` with a fake whose `open_ai_stream`
   returns a line-iterable of SSE bytes with `time.sleep` between events —
   arrival-time spacing at the client then distinguishes live streaming from
   Django's buffered sync-iterator fallback.
3. Launch: `cd backend && DATABASE_URL=... .venv/bin/python -m uvicorn
   --app-dir <scratch> verify_asgi:application --port 8765` (wrapper calls
   `get_asgi_application()` first, then patches).
4. Drive with a timed reader: urllib streaming POST, print
   `time.monotonic()` per line. Auth: BasicAuth is enabled
   (`Authorization: Basic <user:pass>`). Do NOT send
   `Accept: text/event-stream` — DRF content negotiation 406s it; the SSE
   views work with the default Accept.
5. Check `uvicorn.log` for `Warning: StreamingHttpResponse must consume
   synchronous iterators…` — its presence means an SSE endpoint regressed to
   a sync iterator and is being buffered wholesale under ASGI.

Good probes: abrupt client disconnect mid-stream (server must stay clean and
the turn generator's `finally` must run), then an immediate follow-up request.
