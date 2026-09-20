"""Qareeb — vouchers and airtime; listed pending agency access.

No credentials or endpoint documentation yet. Present in the catalog so the
settings screen shows the full roadmap rather than only what happens to work.
"""

from __future__ import annotations

from .base import PlannedProvider, register


@register("qareeb")
class QareebProvider(PlannedProvider):
    pass
