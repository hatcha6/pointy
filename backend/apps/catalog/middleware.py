"""Stamp the catalog version on every API response.

Client-side POS caches (barcode resolutions, search pages) key their entries
on this header (see ``apps.catalog.cache``). Stamping it uniformly — one Redis
GET per request, nothing when caching is disabled or Redis is down — means any
response the till receives pushes the current version: a checkout's own stock
writes, a manager's product edit, a stock-count apply. The client learns "the
catalog changed" from whatever it was already doing, with no polling and no
per-endpoint plumbing.
"""

from .cache import CATALOG_VERSION_HEADER, attach_catalog_version


class CatalogVersionHeaderMiddleware:
    def __init__(self, get_response):
        self.get_response = get_response

    def __call__(self, request):
        response = self.get_response(request)
        # The conditional-GET mixin already stamps catalog lists (reusing the
        # version it computed for the ETag) — don't fetch it twice.
        if request.path.startswith("/api/") and not response.has_header(
            CATALOG_VERSION_HEADER
        ):
            attach_catalog_version(response)
        return response
