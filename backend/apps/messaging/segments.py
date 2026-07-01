"""SMS segment accounting.

Cost and delivery are per *segment*, and segment size depends on encoding: GSM-7
fits 160 chars (153 per part when concatenated), but any character outside the
GSM-7 alphabet forces the whole message to UCS-2 at 70 chars (67 per part).
Arabic is UCS-2, so even a short Arabic promo is often several segments — we
surface the count in composers and sum it into campaign cost.
"""

from __future__ import annotations

# GSM 03.38 basic alphabet (7-bit).
_GSM7_BASIC = (
    "@£$¥èéùìòÇ\nØø\rÅåΔ_ΦΓΛΩΠΨΣΘΞ\x1bÆæßÉ !\"#¤%&'()*+,-./0123456789:;<=>?"
    "¡ABCDEFGHIJKLMNOPQRSTUVWXYZÄÖÑÜ§¿abcdefghijklmnopqrstuvwxyzäöñüà"
)
# Extension chars: each costs two septets (an ESC prefix + the char).
_GSM7_EXT = "^{}\\[~]|€"
_GSM7 = set(_GSM7_BASIC) | set(_GSM7_EXT)


def is_gsm7(text: str) -> bool:
    return all(ch in _GSM7 for ch in text)


def count_segments(text: str) -> int:
    """Number of SMS segments ``text`` will occupy (minimum 1)."""
    if not text:
        return 1
    if is_gsm7(text):
        septets = sum(2 if ch in _GSM7_EXT else 1 for ch in text)
        if septets <= 160:
            return 1
        return -(-septets // 153)  # ceil
    # UCS-2: count UTF-16 code units so astral chars (emoji) count as 2.
    units = len(text.encode("utf-16-le")) // 2
    if units <= 70:
        return 1
    return -(-units // 67)  # ceil
