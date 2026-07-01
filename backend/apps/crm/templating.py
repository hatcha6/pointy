"""Safe ``{{ placeholder }}`` substitution for campaign bodies.

Only a small allow-list of placeholders is substituted; anything unknown is left
verbatim (so a stray ``{{ }}`` can never leak data or crash a render).
"""

from __future__ import annotations

import re

_PLACEHOLDER = re.compile(r"\{\{\s*(\w+)\s*\}\}")


def render_template(template: str, customer, *, shop_name: str = "") -> str:
    full_name = (getattr(customer, "full_name", "") or "").strip() if customer else ""
    first_name = full_name.split()[0] if full_name else ""
    values = {
        "name": full_name,
        "full_name": full_name,
        "first_name": first_name,
        "shop_name": shop_name,
    }

    def _sub(match: re.Match) -> str:
        return values.get(match.group(1).lower(), match.group(0))

    return _PLACEHOLDER.sub(_sub, template or "")
