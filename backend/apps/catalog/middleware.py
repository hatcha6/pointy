"""Stamp the catalog version on every API response.

Client-side POS caches (barcode resolutions, search pages) key their entries
on this header (see ``apps.catalog.cache``). Stamping it uniformly — one Redis
GET per request, nothing when caching is disabled or Redis is down — means any
response the till receives pushes the current version: a checkout's own stock
writes, a manager's product edit, a stock-count apply. The client learns "the
catalog changed" from whatever it was already doing, with no polling and no
per-endpoint plumbing.
"""

from .cache import (
    CATALOG_VERSION_HEADER,
    attach_catalog_version,
    catalog_cache_enabled,
)

# Discounts twin of the catalog version: bumped on any rule/tier/targeting
# edit (apps.discounts.signals). The POS uses it to latch "no active discount
# rules" — while the pushed value matches the latched one, the client skips
# discount-preview requests entirely and computes totals locally, so the
# preview's failure mode cannot occur for shops that run no promotions.
DISCOUNTS_VERSION_HEADER = "X-Pointy-Discounts-Version"


class CatalogVersionHeaderMiddleware:
    def __init__(self, get_response):
        self.get_response = get_response

    def __call__(self, request):
        response = self.get_response(request)
        if not request.path.startswith("/api/"):
            return response
        # The conditional-GET mixin already stamps catalog lists (reusing the
        # version it computed for the ETag) — don't fetch it twice.
        if not response.has_header(CATALOG_VERSION_HEADER):
            attach_catalog_version(response)
        if catalog_cache_enabled():
            from apps.discounts.cache import rules_version

            response[DISCOUNTS_VERSION_HEADER] = str(rules_version())
        return response
