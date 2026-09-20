"""LNET — listed, not yet reachable.

LNET's agency portal sits behind a Cloudflare rule that returns a flat 403 to
entire networks, so the site cannot be surveyed at all, let alone driven. Until
they publish a reseller API or permit an origin we control, this stays a catalog
entry so a shop owner can see it is coming.
"""

from __future__ import annotations

from .base import PlannedProvider, register


@register("lnet")
class LnetProvider(PlannedProvider):
    pass
