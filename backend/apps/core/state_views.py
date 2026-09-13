"""``GET /api/state/`` — the smallest thing a client can ask repeatedly.

Every other response already carries the vector (see state_middleware), so this
endpoint only serves the case nothing else can: an idle till. It answers from
Redis alone — no queryset, no serializer, no DB — and almost always as a 304
with an empty body, so polling it every few seconds costs one MGET.

It returns counters and nothing else. That is deliberate: a client learning
"the catalog changed" still has to go and *fetch* the catalog through the
normal permission-checked endpoint to see any of it, so this can never become a
way to read data a user is not allowed to read. Per-user counters are resolved
against the caller, so one user's vector never carries another's.
"""

from django.conf import settings
from rest_framework import status
from rest_framework.decorators import api_view, permission_classes
from rest_framework.permissions import IsAuthenticated
from rest_framework.response import Response

from .state_version import REQUEST_CACHE_ATTR, fingerprint, versions

DEFAULT_POLL_INTERVAL_SECONDS = 15


def poll_interval_seconds() -> int:
    """How often clients should ask. Served in the body so a struggling shop
    can be slowed down from the server without shipping a new client."""
    return int(
        getattr(
            settings,
            "POINTY_STATE_POLL_INTERVAL_SECONDS",
            DEFAULT_POLL_INTERVAL_SECONDS,
        )
    )


@api_view(["GET"])
@permission_classes([IsAuthenticated])
def state_view(request):
    user_id = getattr(request.user, "pk", None)
    current = versions(user_id=user_id)
    # On the underlying HttpRequest, not the DRF wrapper: the middleware that
    # reads it back sees only the Django request.
    setattr(request._request, REQUEST_CACHE_ATTR, current)
    interval = poll_interval_seconds()

    etag = None
    if current:
        # The user id is part of the tag so one caller's 304 can never be
        # validated against another's vector, exactly as the catalog ETag does.
        etag = f'W/"state-u{user_id}-{fingerprint(current)}-i{interval}"'
        if request.headers.get("If-None-Match") == etag:
            return _no_store(
                Response(status=status.HTTP_304_NOT_MODIFIED, headers={"ETag": etag})
            )

    response = Response(
        {
            "versions": current,
            "poll_interval_seconds": interval,
            # Tells a client whether silence means "nothing changed" or "this
            # server publishes no versions" — without it, a client on a backend
            # with Redis down would trust its caches forever.
            "enabled": bool(current),
        }
    )
    if etag is not None:
        response["ETag"] = etag
    return _no_store(response)


def _no_store(response):
    # Nothing between the till and the backend may answer this from its own
    # store: a cached "nothing changed" is the one failure this whole mechanism
    # exists to prevent.
    response["Cache-Control"] = "no-store, must-revalidate"
    return response
