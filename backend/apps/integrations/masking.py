"""Showing a customer's number without showing it.

A phone number topped up, a meter paid, a subscription renewed: each is a
customer's identifier, and the shop's logs and telemetry leave the shop (see
``telemetry``). So wherever a number could end up in words that are logged — an
error detail, a telemetry row, a log line — it goes through here first:
``+22370123456`` is written ``+223•••••456``, and a number too short to hide
part of is hidden whole.

Numbers are also kept out of addresses (the relay's detection is a POST), but a
relay's own error text may repeat one back, and a transport error may carry the
request it failed on; this is the last line, not the only one.
"""

from __future__ import annotations

import re

#: Seven or more digits written the way people write a number — a leading plus,
#: grouped by single spaces — and not part of a longer word: not a date
#: (``2026-10-08`` has no run of seven), not the tail of an identifier
#: (``…-446655440000``).
_LONG_NUMBER = re.compile(r"(?<![\w\-])\+?\d(?: ?\d){6,}(?![\w\-])")
#: Groups of digits joined by single hyphens, dots or spaces
#: (``0422-3568-280``, ``070.123.456``), three groups or more. Dates, times and
#: prices are the same shape with fewer digits, so only nine or more digits in
#: all are a number (:func:`_mask_separated`).
_SEPARATED_NUMBER = re.compile(r"(?<![\w\-.:])\+?\d{2,6}(?:[ .\-]\d{2,6}){2,}(?![\w\-:]|\.\d)")
#: An account that begins with letters (``SC123456789``): one to four of them
#: and seven digits or more, standing alone.
_ALPHANUMERIC_ACCOUNT = re.compile(r"(?<![\w\-])[A-Za-z]{1,4}\d{7,}(?![\w\-])")
#: A dotted quad is an address, not a customer; it is left for whoever reads
#: the log to see where a connection failed.
_IPV4 = re.compile(r"\d{1,3}(?:\.\d{1,3}){3}")
#: What a mask is made of.
_DOT = "•"


def mask_number(value) -> str:
    """``+22370123456`` as ``+223•••••456``; the end of it only, and only of a long one."""
    text = re.sub(r"[ .\-]", "", str(value or ""))
    size = len(text)
    if size < 8:
        return _DOT * size
    if size < 11:
        return _DOT * (size - 3) + text[-3:]
    head = 4 if text.startswith("+") else 3
    return text[:head] + _DOT * (size - head - 3) + text[-3:]


def mask_numbers(text) -> str:
    """``text`` with every number and account number in it masked."""
    text = _LONG_NUMBER.sub(lambda found: mask_number(found.group(0)), str(text or ""))
    text = _SEPARATED_NUMBER.sub(_mask_separated, text)
    return _ALPHANUMERIC_ACCOUNT.sub(lambda found: mask_number(found.group(0)), text)


def _mask_separated(found) -> str:
    value = found.group(0)
    if _IPV4.fullmatch(value) or sum(char.isdigit() for char in value) < 9:
        return value
    return mask_number(value)
