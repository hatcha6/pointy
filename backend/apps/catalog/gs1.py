"""Reading a GS1 element string — the symbol on a pharmaceutical pack.

A prescription box does not carry a bare barcode. It carries a DataMatrix (or a
GS1-128) encoding several facts at once as *Application Identifiers*: the trade
item, the production lot, the expiry date and, where a market mandates
track-and-trace, a serial unique to that one pack. That is the shape EU FMD and
US DSCSA verification are built on, it is the shape imported stock on a Libyan
pharmacy's shelves already arrives in, and reading it is what turns
``serial_batch`` from a data-entry chore into one scan.

**Two details decide whether this works on real hardware**, and both are the
reason this is a length table rather than a split.

*Fixed-length AIs carry no separator.* ``01`` is followed by exactly fourteen
digits and then, immediately, the next AI. Splitting an element string on any
character would destroy it. So parsing is driven by :data:`FIXED_LENGTHS`: read
two (sometimes three or four) digits of AI, look up how much belongs to it, take
that much, continue.

*Variable-length AIs terminate at ``GS`` (ASCII 29) — and many scanners are
configured to strip it.* A reader that swallows the separator turns ``10`` +
``17`` into one unreadable run, and a parser that shrugs imports a lot number
with a date glued to its tail. This one detects the ambiguity and says so, so
the receiving sheet can print *«أعد ضبط القارئ»* with the fix instead of
recording a lot nobody can ever match.

Pure: strings in, a structure out. No models, no database, no settings — which
is what lets the till, the receiving sheet and a test all ask the same question
and get the same answer. Same posture as ``scale_barcodes``.
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field
from datetime import date

#: ASCII 29. The character GS1 uses to end a variable-length value.
GS = "\x1d"

#: Prefixes some scanners emit before the data itself. Stripped rather than
#: refused: a symbol is still the symbol whichever wrapper the reader put on it.
SYMBOLOGY_PREFIXES = ("]d2", "]C1", "]e0", "]Q3")

#: How many characters follow each fixed-length AI. Everything absent from this
#: table is variable-length and runs to the next ``GS`` or to the end.
#:
#: Deliberately narrow: the four AIs this product reads, plus the handful that
#: turn up on the same packs and would otherwise be mis-parsed as variable and
#: swallow the rest of the string.
FIXED_LENGTHS = {
    "00": 18,  # SSCC
    "01": 14,  # GTIN-14 — the trade item, which is a ProductVariant here
    "02": 14,  # GTIN of contained items
    "11": 6,   # production date, YYMMDD
    "12": 6,   # due date
    "13": 6,   # packaging date
    "15": 6,   # best-before
    "16": 6,   # sell-by
    "17": 6,   # expiry, YYMMDD
    "20": 2,   # variant
}

#: The AIs this feature actually acts on, named so a caller never types "10".
AI_GTIN = "01"
AI_PRODUCTION_DATE = "11"
AI_EXPIRY = "17"
AI_LOT = "10"
AI_SERIAL = "21"

#: Variable-length AIs and their maximum, used to spot a run that is too long to
#: be one value — which is what a stripped ``GS`` looks like.
VARIABLE_MAX_LENGTHS = {
    "10": 20,  # batch / lot
    "21": 20,  # serial
    "240": 30,
    "241": 30,
    "30": 8,
    "37": 8,
    "400": 30,
    "710": 20,
    "711": 20,
}

#: AI codes longer than two digits, which have to be tried before the two-digit
#: read or ``240`` parses as ``24`` + a stray ``0``.
LONG_AI_PREFIXES = ("240", "241", "400", "710", "711", "712", "713")


class Gs1Error(ValueError):
    """A string that is shaped like an element string but cannot be read."""


@dataclass(frozen=True)
class Gs1Warning:
    """Something the parser could read but does not trust."""

    code: str
    message: str
    ai: str = ""
    value: str = ""


@dataclass(frozen=True)
class Gs1Scan:
    """What one symbol said.

    ``elements`` keeps every AI, including the ones this product ignores, so a
    caller that later cares about one does not need the parser changed.
    """

    raw: str
    elements: dict = field(default_factory=dict)
    warnings: tuple = ()

    @property
    def gtin(self) -> str:
        return self.elements.get(AI_GTIN, "")

    @property
    def lot(self) -> str:
        return self.elements.get(AI_LOT, "")

    @property
    def serial(self) -> str:
        return self.elements.get(AI_SERIAL, "")

    @property
    def expiry_date(self):
        return _as_date(self.elements.get(AI_EXPIRY))

    @property
    def production_date(self):
        return _as_date(self.elements.get(AI_PRODUCTION_DATE))

    @property
    def is_usable(self) -> bool:
        """Did the symbol name a trade item at all?

        Without a GTIN there is nothing to resolve a variant from, and a lot
        number on its own is a string belonging to a product nobody named.
        """
        return bool(self.gtin)

    def as_dict(self) -> dict:
        return {
            "gtin": self.gtin,
            "lot": self.lot,
            "serial": self.serial,
            "expiry_date": self.expiry_date.isoformat() if self.expiry_date else "",
            "production_date": (
                self.production_date.isoformat() if self.production_date else ""
            ),
            "elements": dict(self.elements),
            "warnings": [
                {
                    "code": warning.code,
                    "message": warning.message,
                    "ai": warning.ai,
                    "value": warning.value,
                }
                for warning in self.warnings
            ],
        }


def strip_symbology(raw: str) -> str:
    text = str(raw or "").strip()
    for prefix in SYMBOLOGY_PREFIXES:
        if text.startswith(prefix):
            return text[len(prefix) :]
    return text


def looks_like_gs1(raw: str) -> bool:
    """Is this worth handing to :func:`parse`?

    Deliberately conservative, because the cost of a false positive is a plain
    barcode being read as an element string. A symbology prefix or a literal
    ``GS`` settles it; otherwise the string has to both start with a
    fixed-length AI and be long enough to carry that AI's value.
    """
    text = str(raw or "").strip()
    if not text:
        return False
    if any(text.startswith(prefix) for prefix in SYMBOLOGY_PREFIXES):
        return True
    if GS in text:
        return True
    head = text[:2]
    length = FIXED_LENGTHS.get(head)
    if length is None:
        return False
    # ``01`` + 14 digits is 16 characters, which is longer than any EAN a
    # scanner would hand over as a plain barcode — so a 16+ string starting
    # ``01`` is an element string and a 13-digit one starting ``01`` is a
    # product's own barcode.
    return len(text) > 2 + length or (
        len(text) == 2 + length and head in (AI_GTIN, "02", "00")
    )


def parse(raw: str) -> Gs1Scan:
    """Read an element string into its AIs.

    Never raises for content: an unreadable tail is reported as a warning and
    whatever was read before it is kept, because a receiver holding the box can
    do something useful with a GTIN and an expiry even when the serial came
    through mangled.
    """
    text = strip_symbology(raw)
    if not text:
        return Gs1Scan(raw=str(raw or ""), elements={}, warnings=())

    elements: dict = {}
    warnings: list = []
    index = 0
    length = len(text)
    while index < length:
        if text[index] == GS:
            index += 1
            continue
        ai = _read_ai(text, index)
        if ai is None:
            warnings.append(
                Gs1Warning(
                    code="unknown_ai",
                    message=(
                        "تعذّرت قراءة باقي الرمز — معرّف تطبيق غير معروف عند "
                        f"الموضع {index}."
                    ),
                    value=text[index : index + 4],
                )
            )
            break
        index += len(ai)
        fixed = FIXED_LENGTHS.get(ai)
        if fixed is not None:
            value = text[index : index + fixed]
            index += fixed
            if len(value) < fixed:
                warnings.append(
                    Gs1Warning(
                        code="truncated",
                        message=f"القيمة الخاصة بالمعرّف {ai} غير مكتملة.",
                        ai=ai,
                        value=value,
                    )
                )
        else:
            end = text.find(GS, index)
            if end == -1:
                value = text[index:]
                index = length
                warnings.extend(_separator_warnings(ai, value))
            else:
                value = text[index:end]
                index = end + 1
        if ai in elements:
            warnings.append(
                Gs1Warning(
                    code="repeated_ai",
                    message=f"المعرّف {ai} مكرّر في نفس الرمز.",
                    ai=ai,
                    value=value,
                )
            )
        elements[ai] = value

    warnings.extend(_value_warnings(elements))
    return Gs1Scan(raw=str(raw or ""), elements=elements, warnings=tuple(warnings))


def _read_ai(text: str, index: int):
    """The AI starting at ``index``, longest match first.

    ``240`` has to be tried before ``24``, or a three-digit AI parses as a
    two-digit one followed by a stray digit and everything after it shifts.
    """
    for prefix in LONG_AI_PREFIXES:
        if text.startswith(prefix, index):
            return prefix
    head = text[index : index + 2]
    if len(head) < 2 or not head.isdigit():
        return None
    if head in FIXED_LENGTHS or head in VARIABLE_MAX_LENGTHS:
        return head
    # An AI this table does not know, but which is still shaped like one. Treat
    # it as variable-length rather than stopping: the AIs this product reads may
    # follow it, and a ``GS`` will end it.
    return head


def _separator_warnings(ai: str, value: str) -> list:
    """A variable-length value that ran to the end of the string.

    Legitimate when it is genuinely the last element. Suspicious when it is
    longer than the AI allows, which is what a scanner configured to strip
    ``GS`` produces — the lot number and everything after it arrive as one run.
    """
    maximum = VARIABLE_MAX_LENGTHS.get(ai)
    if maximum is None or len(value) <= maximum:
        return []
    return [
        Gs1Warning(
            code="missing_group_separator",
            message=(
                "يبدو أن القارئ يحذف فاصل المجموعات (GS): القيمة أطول مما "
                "يسمح به المعرّف. أعد ضبط القارئ لإرسال الفاصل، ثم أعد المسح."
            ),
            ai=ai,
            value=value,
        )
    ]


_DATE = re.compile(r"^\d{6}$")


def _value_warnings(elements: dict) -> list:
    warnings = []
    gtin = elements.get(AI_GTIN, "")
    if gtin and (len(gtin) != 14 or not gtin.isdigit()):
        warnings.append(
            Gs1Warning(
                code="bad_gtin",
                message="رقم الصنف العالمي (GTIN) يجب أن يكون 14 رقمًا.",
                ai=AI_GTIN,
                value=gtin,
            )
        )
    for ai in (AI_EXPIRY, AI_PRODUCTION_DATE):
        value = elements.get(ai)
        if value and (not _DATE.match(value) or _as_date(value) is None):
            warnings.append(
                Gs1Warning(
                    code="bad_date",
                    message=f"التاريخ في المعرّف {ai} غير صالح.",
                    ai=ai,
                    value=value,
                )
            )
    return warnings


def _as_date(value):
    """``YYMMDD`` as a date, with GS1's own two rules about the odd parts.

    ``DD = 00`` means "the end of that month", which is how a pack that expires
    in a month rather than on a day is encoded — and reading it as an invalid
    date would refuse a perfectly ordinary box. The century follows GS1's
    51-year window: ``49`` is 2049 and ``50`` is 1950.
    """
    if not value or not _DATE.match(value):
        return None
    year = int(value[0:2])
    month = int(value[2:4])
    day = int(value[4:6])
    year += 2000 if year <= 49 else 1900
    if month < 1 or month > 12:
        return None
    if day == 0:
        day = _last_day(year, month)
    try:
        return date(year, month, day)
    except ValueError:
        return None


def _last_day(year: int, month: int) -> int:
    from calendar import monthrange

    return monthrange(year, month)[1]


def gtin_candidates(gtin: str) -> list:
    """The forms a GTIN-14 could have been stored as on a variant's barcode.

    A shop types the number printed under the barcode, which for most retail
    goods is the EAN-13 or UPC-A — the same trade item with the packaging
    indicator and leading zeros stripped. Matching only the padded 14-digit form
    would mean every pharmacy had to re-key its catalog before a scan worked.
    """
    digits = re.sub(r"\D", "", str(gtin or ""))
    if not digits:
        return []
    candidates = [digits]
    stripped = digits.lstrip("0")
    for length in (14, 13, 12, 8):
        if len(stripped) <= length:
            padded = stripped.rjust(length, "0")
            if padded not in candidates:
                candidates.append(padded)
    if stripped and stripped not in candidates:
        candidates.append(stripped)
    return candidates


__all__ = [
    "AI_EXPIRY",
    "AI_GTIN",
    "AI_LOT",
    "AI_PRODUCTION_DATE",
    "AI_SERIAL",
    "FIXED_LENGTHS",
    "GS",
    "Gs1Error",
    "Gs1Scan",
    "Gs1Warning",
    "gtin_candidates",
    "looks_like_gs1",
    "parse",
    "strip_symbology",
]
