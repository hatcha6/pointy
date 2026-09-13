"""Stamp the state-version vector on every API response.

One Redis MGET per ``/api/`` response puts the whole vector in a header, so a
client learns what changed from whatever it was already doing — a checkout, a
catalog poll, a 304 — with no extra request and no per-endpoint plumbing. The
poll endpoint (``/api/state/``) exists only for the case this cannot cover: a
till sitting idle, sending nothing at all.

The two legacy single-value headers are stamped from the same read. Older
clients (and the frozen compat/win8 branch) know only those; they keep working
untouched, and this costs no extra Redis calls because the values come out of
the vector that was already fetched.
"""

from apps.catalog.cache import CATALOG_VERSION_HEADER, catalog_cache_enabled

from .state_version import (
    REQUEST_CACHE_ATTR,
    STATE_HEADER,
    header_value,
    state_versions_enabled,
    versions,
)

DISCOUNTS_VERSION_HEADER = "X-Pointy-Discounts-Version"

# Vector name -> legacy header, for clients that predate X-Pointy-State.
_LEGACY_HEADERS = {
    "catalog": CATALOG_VERSION_HEADER,
    "discounts": DISCOUNTS_VERSION_HEADER,
}


class StateVersionHeaderMiddleware:
    def __init__(self, get_response):
        self.get_response = get_response

    def __call__(self, request):
        response = self.get_response(request)
        if not request.path.startswith("/api/"):
            return response

        # Two independent switches, one Redis round trip. The vector is read
        # when either feature wants it; each then stamps only its own headers,
        # so turning the new one off leaves the catalog push exactly as it was
        # before it existed.
        publish_state = state_versions_enabled()
        publish_legacy = catalog_cache_enabled()
        if not (publish_state or publish_legacy):
            return response

        # The poll endpoint already read the vector for its own ETag.
        current = getattr(request, REQUEST_CACHE_ATTR, None)
        if current is None:
            current = versions(user_id=_user_id(request), force=True)
        if not current:  # Redis unusable — clients fall back to their TTLs
            return response

        if publish_state:
            response[STATE_HEADER] = header_value(current)
        if publish_legacy:
            for name, header in _LEGACY_HEADERS.items():
                # The catalog list ETag path stamps its own value from the
                # version it already computed; leave it rather than re-decide.
                if name in current and not response.has_header(header):
                    response[header] = current[name]
        return response


def _user_id(request):
    """This request's user id, or None. Never raises, never forces a login."""
    user = getattr(request, "user", None)
    if user is None or not getattr(user, "is_authenticated", False):
        return None
    return getattr(user, "pk", None)
