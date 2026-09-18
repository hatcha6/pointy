"""Identifiers for identified stock: normalising them, checking them, and
describing a clash precisely enough that a client can offer a way out of it.

Three ideas live here and nowhere else.

**Normalisation is one function.** A scanner, a keyboard and a supplier's
spreadsheet write the same IMEI three ways — ``35 1234 567890111``,
``351234-567890111``, ``351234567890111`` — and a lookup that misses because of
a dash is a lookup that sends a phone back out of the door untracked. Every
identifier in this app (unit codes, secondary codes, lot codes) goes through
:func:`normalize_identifier` on write and on read, so the stored form and the
searched form cannot drift.

**Validation warns, it does not wall.** A failed IMEI Luhn is almost always a
keying error and catching it at receipt is worth far more than catching it at a
warranty claim two years later — but a guard that blocks a legitimate oddity
gets disabled, and a disabled guard catches nothing. So this module *reports*
and the caller decides, exactly as ``purchase-cost-guard`` does for a mistyped
cost.

**A clash is data, not a 500.** ``apps.catalog.identity`` established the shape:
the field, the value, what already owns it, and where in the payload it came
from. Identified stock reuses it rather than inventing a second dialect.
"""

from __future__ import annotations

import unicodedata
from dataclasses import dataclass, field as dataclass_field

#: Characters that are decoration rather than identity. Scanners insert them,
#: humans type them, and no identifier scheme in this feature gives them
#: meaning.
_STRIPPED = {" ", "\t", "-", "_", ".", "/", "\\", "‏", "‎", " "}

#: VIN excludes I, O and Q so they cannot be confused with 1 and 0 (ISO 3779).
VIN_FORBIDDEN = frozenset("IOQ")
VIN_LENGTH = 17
_VIN_TRANSLITERATION = {
    **{str(digit): digit for digit in range(10)},
    "A": 1, "B": 2, "C": 3, "D": 4, "E": 5, "F": 6, "G": 7, "H": 8,
    "J": 1, "K": 2, "L": 3, "M": 4, "N": 5, "P": 7, "R": 9,
    "S": 2, "T": 3, "U": 4, "V": 5, "W": 6, "X": 7, "Y": 8, "Z": 9,
}
_VIN_WEIGHTS = (8, 7, 6, 5, 4, 3, 2, 10, 0, 9, 8, 7, 6, 5, 4, 3, 2)


class IdentifierKind:
    """What sort of number an identifier is, which decides how it is checked."""

    IMEI = "imei"
    SERIAL = "serial"
    VIN = "vin"
    PLATE = "plate"
    CUSTOM = "custom"

    CHOICES = [
        (IMEI, "IMEI"),
        (SERIAL, "Serial number"),
        (VIN, "VIN / chassis"),
        (PLATE, "Plate number"),
        (CUSTOM, "Custom identifier"),
    ]


def normalize_identifier(value) -> str:
    """The canonical form of an identifier: NFKC, digit-folded, stripped, upper.

    Blank in, blank out — a unit without a secondary code stores an empty
    string rather than a sentinel, so the index over it stays honest.

    **NFKC is not a digit fold**, and on an Arabic-first till that matters more
    than anywhere else. ``٣٥١٢٣٤…`` typed on an Arabic keyboard is a different
    string from the ``351234…`` the scanner reads off the same box, and NFKC
    leaves U+0660–0669 exactly where they are. Worse, Python's ``str.isdigit``
    and ``int()`` both accept them, so the IMEI validator's Luhn branch passes
    and says the number is fine — the one check whose job is to catch a keying
    error waves it through. The shop ends up with two live units for one
    handset, and the partial unique index cannot object because the strings
    genuinely differ. So every decimal digit is folded to ASCII first, which
    covers Arabic-Indic, Eastern Arabic-Indic (Persian, U+06F0–06F9) and every
    other decimal script Unicode knows about.
    """
    if value is None:
        return ""
    text = unicodedata.normalize("NFKC", str(value)).strip()
    if not text:
        return ""
    text = _fold_digits(text)
    return "".join(char for char in text if char not in _STRIPPED).upper()


def _fold_digits(text: str) -> str:
    """Every decimal digit to its ASCII counterpart, everything else untouched.

    ``unicodedata.digit`` answers for any character Unicode classifies as a
    decimal digit, so this needs no per-script table and cannot fall behind one.
    """
    if text.isascii():
        return text
    out = []
    for char in text:
        if char.isdigit() and not char.isascii():
            try:
                out.append(str(unicodedata.digit(char)))
                continue
            except (TypeError, ValueError):
                pass
        out.append(char)
    return "".join(out)


def luhn_check(digits: str) -> bool:
    """The Luhn check digit, as GSMA specifies it for a 15-digit IMEI."""
    if not digits.isdigit() or len(digits) < 2:
        return False
    total = 0
    for index, char in enumerate(reversed(digits)):
        value = int(char)
        if index % 2 == 1:
            value *= 2
            if value > 9:
                value -= 9
        total += value
    return total % 10 == 0


def vin_check_digit_ok(vin: str) -> bool:
    """ISO 3779's check digit at position 9.

    North American VINs carry it and most imported vehicles do; schemes that do
    not are why this is a warning rather than a refusal.
    """
    if len(vin) != VIN_LENGTH:
        return False
    if any(char in VIN_FORBIDDEN for char in vin):
        return False
    total = 0
    for char, weight in zip(vin, _VIN_WEIGHTS):
        if char == "X" and weight == 0:
            continue
        value = _VIN_TRANSLITERATION.get(char)
        if value is None:
            return False
        total += value * weight
    expected = total % 11
    return vin[8] == ("X" if expected == 10 else str(expected))


@dataclass(frozen=True)
class IdentifierWarning:
    """One thing that looks wrong about an identifier, and why."""

    #: A stable machine code, so a client can phrase its own sentence.
    code: str
    #: Arabic, because the receiver holding the box reads this one.
    message: str
    value: str = ""
    kind: str = ""


def check_identifier(value, *, kind=IdentifierKind.SERIAL) -> list:
    """Everything suspicious about ``value``, as warnings the caller may ignore.

    Returns an empty list for anything that looks right, and never raises: an
    identifier this function dislikes is still an identifier the shop is holding
    in its hand.
    """
    code = normalize_identifier(value)
    warnings = []
    if not code:
        return [
            IdentifierWarning(
                code="empty",
                message="المعرّف فارغ.",
                value="",
                kind=kind,
            )
        ]
    if len(code) > 120:
        warnings.append(
            IdentifierWarning(
                code="too_long",
                message="المعرّف أطول من 120 خانة.",
                value=code,
                kind=kind,
            )
        )
    if kind == IdentifierKind.IMEI:
        warnings.extend(_check_imei(code))
    elif kind == IdentifierKind.VIN:
        warnings.extend(_check_vin(code))
    return warnings


def _check_imei(code: str) -> list:
    if not code.isdigit():
        return [
            IdentifierWarning(
                code="imei_not_numeric",
                message="رقم IMEI يتكوّن من أرقام فقط.",
                value=code,
                kind=IdentifierKind.IMEI,
            )
        ]
    # 14 = IMEI without its check digit, 15 = IMEI, 16 = IMEISV. Anything else
    # is a length nobody's handset has.
    if len(code) not in (14, 15, 16):
        return [
            IdentifierWarning(
                code="imei_length",
                message="رقم IMEI يجب أن يكون 15 خانة (أو 14 بدون خانة التحقق).",
                value=code,
                kind=IdentifierKind.IMEI,
            )
        ]
    # Only the 15-digit form carries the Luhn digit; the 16-digit IMEISV
    # replaces it with a software version, so checking it would fail every time.
    if len(code) == 15 and not luhn_check(code):
        return [
            IdentifierWarning(
                code="imei_checksum",
                message="خانة التحقق في رقم IMEI غير صحيحة — تأكّد من الرقم.",
                value=code,
                kind=IdentifierKind.IMEI,
            )
        ]
    return []


def _check_vin(code: str) -> list:
    warnings = []
    if len(code) != VIN_LENGTH:
        warnings.append(
            IdentifierWarning(
                code="vin_length",
                message="رقم الشاسيه يتكوّن من 17 خانة.",
                value=code,
                kind=IdentifierKind.VIN,
            )
        )
        return warnings
    forbidden = sorted(set(code) & VIN_FORBIDDEN)
    if forbidden:
        warnings.append(
            IdentifierWarning(
                code="vin_forbidden_letters",
                message="رقم الشاسيه لا يحتوي على الحروف I أو O أو Q.",
                value=code,
                kind=IdentifierKind.VIN,
            )
        )
        return warnings
    if not vin_check_digit_ok(code):
        warnings.append(
            IdentifierWarning(
                code="vin_checksum",
                message="خانة التحقق في رقم الشاسيه غير صحيحة — تأكّد من الرقم.",
                value=code,
                kind=IdentifierKind.VIN,
            )
        )
    return warnings


# --- clashes ---------------------------------------------------------------

#: What the value collided with, mirroring ``apps.catalog.identity``'s kinds.
KIND_UNIT = "stock_unit"
KIND_BATCH = "stock_batch"
KIND_PAYLOAD = "payload"
KIND_EXPIRY = "batch_expiry"


@dataclass(frozen=True)
class TrackingConflict:
    """One identifier that cannot be written, and what is in its way.

    Carries enough for a client to offer the useful action rather than a red
    toast: *«افتح الجهاز الموجود»* for a live duplicate, *«نفس الدفعة — سيتم
    الإضافة للرصيد»* for a known lot, *«أي التاريخين صحيح؟»* for a lot whose
    expiry disagrees with its label.
    """

    field: str
    value: str
    kind: str
    message: str
    object_id: int | None = None
    label: str = ""
    index: int | None = None
    details: dict = dataclass_field(default_factory=dict)

    def at(self, index):
        """A copy tagged with the payload row the value came from."""
        return TrackingConflict(
            field=self.field,
            value=self.value,
            kind=self.kind,
            message=self.message,
            object_id=self.object_id,
            label=self.label,
            index=index,
            details=self.details,
        )

    def as_dict(self) -> dict:
        payload = {
            "field": self.field,
            "value": self.value,
            "kind": self.kind,
            "message": self.message,
        }
        if self.object_id is not None:
            payload["object_id"] = self.object_id
        if self.label:
            payload["label"] = self.label
        if self.index is not None:
            payload["index"] = self.index
        if self.details:
            payload.update(self.details)
        return payload


def conflict_error(conflicts) -> dict:
    """The 400 body for a list of conflicts.

    One flat ``detail`` for a client that only prints strings, plus the
    machine-readable list for one that can mark the offending input.
    """
    rows = [conflict.as_dict() for conflict in conflicts]
    return {
        "detail": rows[0]["message"] if rows else "تعذّر حفظ المعرّفات.",
        "conflicts": rows,
    }


__all__ = [
    "IdentifierKind",
    "IdentifierWarning",
    "TrackingConflict",
    "KIND_BATCH",
    "KIND_EXPIRY",
    "KIND_PAYLOAD",
    "KIND_UNIT",
    "check_identifier",
    "conflict_error",
    "luhn_check",
    "normalize_identifier",
    "vin_check_digit_ok",
]
