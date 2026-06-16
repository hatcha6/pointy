"""Display-text rendering for price-checker hardware.

The hard part is Arabic. Devices fall into capability tiers and each needs a
*different* byte stream for the same logical string:

* ``unicode`` — smart display (browser/OS) shapes cursive letters and reorders
  RTL itself. Send logical UTF-8, untouched.
* ``cp1256`` — dumb display whose firmware font shapes Arabic letters but does
  not reorder RTL. Send *base* letters in visual order, CP1256-encoded.
* ``glyphs`` — pure glyph blitter: no shaping, no bidi. Send pre-shaped Unicode
  presentation forms (U+FE70..U+FEFF) in visual order.
* ``none`` — no Arabic font. Fall back to Latin (e.g. ``12.50 LYD``).

Note that reshaping (presentation forms) and CP1256 are mutually exclusive:
CP1256 encodes the *base* letters, not the presentation forms, so the ``glyphs``
tier must stay on a Unicode-capable encoding.
"""

from __future__ import annotations

from dataclasses import dataclass
from decimal import Decimal

from django.conf import settings

from .models import PriceCheckerDevice

# Arabic shaping/bidi are optional at import time: the app must load even if the
# libraries are absent (then the Arabic tiers degrade to logical order).
try:  # arabic_reshaper: base letters -> contextual presentation forms
    import arabic_reshaper

    _RESHAPER_AVAILABLE = True
except Exception:  # pragma: no cover - exercised only when dep missing
    arabic_reshaper = None
    _RESHAPER_AVAILABLE = False

try:  # python-bidi moved get_display to the top level in 0.5; support both
    from bidi import get_display as _bidi_get_display

    _BIDI_AVAILABLE = True
except Exception:  # pragma: no cover
    try:
        from bidi.algorithm import get_display as _bidi_get_display

        _BIDI_AVAILABLE = True
    except Exception:  # pragma: no cover
        _bidi_get_display = None
        _BIDI_AVAILABLE = False


def arabic_shaping_available() -> bool:
    return _RESHAPER_AVAILABLE and _BIDI_AVAILABLE


def contains_arabic(text: str) -> bool:
    return any("؀" <= ch <= "ۿ" or "ﭐ" <= ch <= "﻿" for ch in text)


@dataclass(frozen=True, slots=True)
class ShapePlan:
    reshape: bool
    bidi: bool
    allow_arabic: bool


_SHAPE_PLANS = {
    PriceCheckerDevice.ArabicSupport.NONE: ShapePlan(False, False, False),
    PriceCheckerDevice.ArabicSupport.UNICODE: ShapePlan(False, False, True),
    PriceCheckerDevice.ArabicSupport.CP1256: ShapePlan(False, True, True),
    PriceCheckerDevice.ArabicSupport.GLYPHS: ShapePlan(True, True, True),
}


@dataclass(frozen=True, slots=True)
class DisplayProfile:
    rows: int
    cols: int
    plan: ShapePlan
    encoding: str

    @property
    def allow_arabic(self) -> bool:
        return self.plan.allow_arabic


def plan_for_support(arabic_support: str) -> ShapePlan:
    return _SHAPE_PLANS.get(
        arabic_support,
        _SHAPE_PLANS[PriceCheckerDevice.ArabicSupport.UNICODE],
    )


def profile_from_device(device: PriceCheckerDevice) -> DisplayProfile:
    return DisplayProfile(
        rows=max(1, device.display_rows or 1),
        cols=max(1, device.display_cols or 1),
        plan=plan_for_support(device.arabic_support),
        encoding=(device.encoding or "utf-8"),
    )


def currency_suffix(allow_arabic: bool) -> str:
    if allow_arabic:
        return str(getattr(settings, "POINTY_CURRENCY_SUFFIX", "د.ل"))
    return str(getattr(settings, "POINTY_CURRENCY_LATIN", "LYD"))


def format_money(amount: Decimal | None, *, allow_arabic: bool = True) -> str:
    """Logical (un-shaped) money string, e.g. ``"12.50 د.ل"``.

    Always Western digits and a space before the symbol, matching the rest of
    Pointy. Bidi reordering (if any) happens later in :func:`prepare_text` over
    the whole line, which keeps the numerals left-to-right inside RTL text.
    """
    value = Decimal("0.00") if amount is None else Decimal(amount)
    return f"{value:.2f} {currency_suffix(allow_arabic)}"


def prepare_text(text: str, profile: DisplayProfile) -> str:
    """Apply the device's shaping plan, returning a display-order string."""
    if not text:
        return text
    plan = profile.plan
    if not plan.allow_arabic and contains_arabic(text):
        # Device has no Arabic font: drop to what the encoding can represent so
        # we never blit garbage. Latin/digits survive; Arabic becomes "?".
        return text
    out = text
    if plan.reshape and _RESHAPER_AVAILABLE and contains_arabic(out):
        out = arabic_reshaper.reshape(out)
    if plan.bidi and _BIDI_AVAILABLE and contains_arabic(out):
        out = _bidi_get_display(out)
    return out


def encode_text(text: str, profile: DisplayProfile) -> bytes:
    """Encode for a byte-oriented transport, never raising on un-mappable chars."""
    return text.encode(profile.encoding, errors="replace")


def fit_line(text: str, cols: int) -> str:
    return text[:cols]


def layout_lines(lines: list[str], profile: DisplayProfile) -> list[str]:
    """Shape + truncate logical lines to the device's row/column budget."""
    prepared = [fit_line(prepare_text(line, profile), profile.cols) for line in lines]
    return prepared[: profile.rows]
