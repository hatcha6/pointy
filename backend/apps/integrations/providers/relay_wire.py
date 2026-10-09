"""Reading values off the relay's JSON, defensively.

Everything the company's relay sends is parsed through these, by every part of
the «كروت دفتر» driver (the card shelf in :mod:`.pointy`, the direct top-up and
bill payments in :mod:`.pointy_services`). The rule they share: a value that is
not what its field should be reads as *absent* — ``""``, ``0``, ``None`` — and
never raises, so one malformed row costs that row and not the whole answer.

Money is dinars at two places (cost, price and the shop's books all keep two).
"""

from __future__ import annotations

import json
from datetime import timezone as dt_timezone
from decimal import ROUND_HALF_UP, Decimal, InvalidOperation

from django.utils import timezone
from django.utils.dateparse import parse_datetime

_CENT = Decimal("0.01")


def text(value, limit: int = 255) -> str:
    """A string field, trimmed and cut to ``limit``; ``""`` for anything else."""
    if value is None or isinstance(value, (dict, list)):
        return ""
    return str(value).strip()[:limit]


def integer(value) -> int:
    try:
        return int(value)
    except (TypeError, ValueError):
        return 0


def decimal(value) -> Decimal | None:
    if value in (None, "") or isinstance(value, bool):
        return None
    try:
        number = Decimal(str(value))
    except (InvalidOperation, ValueError):
        return None
    return number if number.is_finite() else None


def money(value) -> Decimal | None:
    """A money figure at two places, or ``None`` when it is not one."""
    number = decimal(value)
    if number is None or number < 0:
        return None
    return number.quantize(_CENT, rounding=ROUND_HALF_UP)


def money_text(value) -> str | None:
    number = money(value)
    return None if number is None else f"{number:.2f}"


def plain_number(value: Decimal) -> str:
    """``10`` for 10.000 and ``2.5`` for 2.500: a face value as people write it."""
    return format(value.normalize(), "f")


def instant(value):
    stamp = text(value, 64)
    if not stamp:
        return None
    parsed = parse_datetime(stamp)
    if parsed is None:
        return None
    if timezone.is_naive(parsed):
        parsed = timezone.make_aware(parsed, dt_timezone.utc)
    return parsed


def json_object(value) -> dict | None:
    """``value`` as a JSON object, or ``None`` when it is not one."""
    try:
        parsed = json.loads(value or "")
    except (TypeError, ValueError):
        return None
    return parsed if isinstance(parsed, dict) else None
