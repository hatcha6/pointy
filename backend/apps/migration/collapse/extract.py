"""Reading a product name that is really an inventory row.

The prospect's catalogue holds one product per physical handset (§1.1):

    iPhone 13 Pro 256GB Blue Battery86 IMEI351234567890111

Four different kinds of fact are welded into that one string, and the whole
collapse turns on pulling them apart correctly:

* the **identifier** — what makes the row a unit rather than a product,
* the **variant options** (storage, colour) — facts about the *model*, so two
  handsets that share them share a variant,
* the **unit attributes** (battery health, condition grade) — facts about this
  one article, which belong on the unit and nowhere else,
* and whatever is left, which is the **product**.

Three rules keep this honest.

**Masking, not scanning.** Each extractor runs over what the previous ones did
not claim, longest-lived first: identifier, then storage, then battery, then
grade, then colour. A 15-digit IMEI contains "256"; a name ending "… 128GB"
contains a two-digit run that looks like a battery percentage. Running the
patterns independently over the whole string and hoping they do not collide is
how a migration silently reports every phone at 12% battery.

**Folding preserves length.** Matching has to see ``اسود`` and ``أسود`` as the
same word and ``٨٦`` and ``86`` as the same number, but the *stem* is cut out of
the original string — so the folded form is built one character at a time and is
always exactly as long as what it folded, and every span found in it indexes the
original. A fold that deleted a tatweel would shift every span after it by one
and cut the product's name in the wrong place.

**Nothing here decides anything.** This module reports what it found and how
sure it is; :mod:`apps.migration.collapse.planner` clusters, and the owner
approves. An extraction with no identifier is not a failure — it is a product,
and it stays one (§12.4).
"""

from __future__ import annotations

import re
import unicodedata
from dataclasses import dataclass, field

from apps.inventory.identity import (
    IdentifierKind,
    luhn_check,
    normalize_identifier,
    vin_check_digit_ok,
)

# --- folding ----------------------------------------------------------------

#: Arabic orthography a shop does not distinguish when it types a product name.
#: Every entry is one character mapping to one character, because the folded
#: string has to stay the same length as what it folded.
_LETTER_FOLD = {
    "أ": "ا",
    "إ": "ا",
    "آ": "ا",
    "ٱ": "ا",
    "ٲ": "ا",
    "ٳ": "ا",
    "ى": "ي",
    "ئ": "ي",
    "ة": "ه",
    "ؤ": "و",
    "ک": "ك",
    "ګ": "ك",
    "ی": "ي",
    "ۀ": "ه",
}
#: Decoration: tatweel, the harakat, and the bidi marks a copy-paste leaves
#: behind. Folded to a space rather than removed — see the module docstring.
_BLANKED = frozenset(
    "ـ"  # tatweel
    "ًٌٍَُِّْٰٕٓٔ"
    "​‌‍‎‏‪‫‬‭‮﻿"
)
#: Punctuation that separates tokens in a product name. Folded to a space so
#: ``iPhone-13/Pro`` and ``iPhone 13 Pro`` cluster together.
_PUNCTUATION = frozenset("-_/\\|,;:()[]{}<>\"'`*#~+%،؛؟…«»٪")


def fold(text: str) -> str:
    """The comparison form of ``text``, character for character.

    ``len(fold(text)) == len(text)`` always — the property every span in this
    module depends on. Anything that would change the length (NFKC, stripping,
    a locale-aware lowercase) is deliberately not done here.
    """
    if not text:
        return ""
    out = []
    for char in text:
        out.append(_fold_char(char))
    return "".join(out)


def _fold_char(char: str) -> str:
    if char in _BLANKED:
        return " "
    mapped = _LETTER_FOLD.get(char)
    if mapped is not None:
        return mapped
    if char.isdigit() and not char.isascii():
        try:
            return str(unicodedata.digit(char))
        except (TypeError, ValueError):
            pass
    lowered = char.lower()
    return lowered if len(lowered) == 1 else char


def cluster_key(text: str) -> str:
    """The folded, punctuation-free, single-spaced form two names must share to
    be the same product.

    Public because renaming a proposed product is also how two of them are
    merged (``services.rename_collapse_cluster``): the new name has to be keyed
    exactly the way the builder keyed the old one, or the merge silently makes a
    third cluster.
    """
    folded = fold(text)
    squeezed = "".join(" " if char in _PUNCTUATION else char for char in folded)
    return " ".join(squeezed.split())


def _word(pattern: str) -> str:
    """``pattern``, matched only as a whole word."""
    return rf"(?<!\w)(?:{pattern})(?!\w)"


def _keywords(*words: str) -> str:
    """An alternation of folded keywords, longest first.

    The words are written here the way a shop writes them and folded on the way
    into the regex, so the table stays readable and cannot drift from
    :func:`fold`.
    """
    folded = sorted({fold(word) for word in words}, key=len, reverse=True)
    return "|".join(re.escape(word) for word in folded)


#: Arabic takes its definite article as a prefix, so ``الأسود`` and ``أسود`` are
#: the same colour written twice.
_AL = r"(?:ال)?"


# --- identifiers -------------------------------------------------------------

_IMEI_LABEL = _keywords("IMEI", "I.M.E.I", "ايمي", "أيمي", "امي", "رقم الجهاز")
_SERIAL_LABEL = _keywords(
    "serial no",
    "serial",
    "s/n",
    "sn",
    "سيريال",
    "الرقم التسلسلي",
    "رقم تسلسلي",
    "تسلسلي",
)
_VIN_LABEL = _keywords("vin", "chassis", "رقم الهيكل", "شاسيه", "الشاسيه")

_IDENTIFIER_PATTERNS = (
    # Labelled beats bare: a number somebody wrote "IMEI" in front of is a
    # number somebody meant.
    (
        "imei_labelled",
        IdentifierKind.IMEI,
        re.compile(rf"(?:{_IMEI_LABEL})\s*[:#.\-]?\s*(\d{{14,17}})(?!\d)"),
    ),
    (
        "vin_labelled",
        IdentifierKind.VIN,
        re.compile(rf"(?:{_VIN_LABEL})\s*[:#.\-]?\s*([a-hj-npr-z0-9]{{17}})(?![a-z0-9])"),
    ),
    (
        "serial_labelled",
        IdentifierKind.SERIAL,
        re.compile(rf"(?:{_SERIAL_LABEL})\s*[:#.\-]?\s*([a-z0-9][a-z0-9\-]{{4,31}})(?![a-z0-9])"),
    ),
    # A bare fifteen-digit run is an IMEI in every catalogue we have seen, and
    # is long enough that nothing else in a product name collides with it: an
    # EAN-13 is two digits shorter and a price never runs that long.
    ("imei_bare", IdentifierKind.IMEI, re.compile(r"(?<!\d)(\d{15})(?!\d)")),
    (
        "vin_bare",
        IdentifierKind.VIN,
        re.compile(
            r"(?<![a-z0-9])((?=[a-hj-npr-z0-9]*[a-hj-npr-z])(?=[a-hj-npr-z0-9]*\d)"
            r"[a-hj-npr-z0-9]{17})(?![a-z0-9])"
        ),
    ),
    # 14 (no check digit) and 16/17 (IMEISV, MEID) happen; they are accepted and
    # cost confidence rather than being thrown away.
    ("imei_odd_length", IdentifierKind.IMEI, re.compile(r"(?<!\d)(\d{14}|\d{16}|\d{17})(?!\d)")),
)

# --- variant options ---------------------------------------------------------

_STORAGE_UNITS = (
    ("tb", _keywords("tb", "t.b", "تيرا", "تيرابايت")),
    ("gb", _keywords("gb", "g.b", "جيجا", "جيغا", "چيجا", "جيجابايت", "جب")),
    ("mb", _keywords("mb", "m.b", "ميجا", "ميغا")),
)
_STORAGE_PATTERN = re.compile(
    r"(?<![\w.])(\d{1,4})\s*(?:"
    + "|".join(f"(?P<{key}>{alternation})" for key, alternation in _STORAGE_UNITS)
    + r")(?!\w)"
)

#: ``(canonical key, Arabic label, written forms)``. A shop writes a colour the
#: way the box writes it, so the compound marketing names are in here beside the
#: plain ones — otherwise ``Phantom Black`` loses only "Black" and leaves
#: "Phantom" stranded in the product's name.
COLOUR_LEXICON = (
    ("rose_gold", "ذهبي وردي", ("rose gold", "rosegold", "ذهبي وردي", "وردي ذهبي")),
    ("space_gray", "رمادي فضائي", ("space gray", "space grey", "رمادي فضائي", "سبيس جراي")),
    ("graphite", "جرافيت", ("graphite", "جرافيت", "جرافيتي")),
    ("midnight", "ميدنايت", ("midnight", "ميدنايت", "أسود منتصف الليل")),
    ("starlight", "ستارلايت", ("starlight", "ستارلايت", "ضوء النجوم")),
    (
        "titanium",
        "تيتانيوم",
        (
            "natural titanium",
            "desert titanium",
            "black titanium",
            "white titanium",
            "blue titanium",
            "titanium",
            "تيتانيوم",
            "تيتانيم",
        ),
    ),
    ("black", "أسود", ("phantom black", "midnight black", "black", "أسود", "اسود", "سوداء")),
    ("white", "أبيض", ("phantom white", "starlight white", "white", "أبيض", "ابيض", "بيضاء")),
    (
        "blue",
        "أزرق",
        (
            "sierra blue",
            "pacific blue",
            "blue",
            "أزرق",
            "ازرق",
            "زرقاء",
            "كحلي",
        ),
    ),
    ("red", "أحمر", ("product red", "red", "أحمر", "احمر", "حمراء")),
    ("green", "أخضر", ("alpine green", "midnight green", "green", "أخضر", "اخضر", "خضراء")),
    ("gold", "ذهبي", ("gold", "ذهبي", "دهبي", "ذهبية")),
    ("silver", "فضي", ("phantom silver", "silver", "فضي", "فضية", "سلفر")),
    ("gray", "رمادي", ("gray", "grey", "رمادي", "رمادية")),
    ("purple", "بنفسجي", ("deep purple", "purple", "violet", "بنفسجي", "موف", "ارجواني")),
    ("pink", "وردي", ("pink", "وردي", "زهري", "بينك")),
    ("yellow", "أصفر", ("yellow", "أصفر", "اصفر", "صفراء")),
    ("orange", "برتقالي", ("orange", "برتقالي", "اورنج")),
    ("brown", "بني", ("brown", "بني", "بنية")),
    ("beige", "بيج", ("beige", "بيج")),
)
_COLOUR_LABELS = {key: label for key, label, _aliases in COLOUR_LEXICON}
#: Aliases are matched globally longest-first, so an alias that is a prefix of a
#: longer one can never win the race at the same starting position.
_COLOUR_ALIASES = sorted(
    (
        (folded, key)
        for key, _label, aliases in COLOUR_LEXICON
        for folded in {fold(alias) for alias in aliases}
    ),
    key=lambda pair: (-len(pair[0]), pair[0]),
)
_COLOUR_GROUPS = {f"c{index}": key for index, (_alias, key) in enumerate(_COLOUR_ALIASES)}
_COLOUR_PATTERN = re.compile(
    "|".join(
        rf"(?P<c{index}>{_word(_AL + re.escape(alias))})"
        for index, (alias, _key) in enumerate(_COLOUR_ALIASES)
    )
)

# --- unit attributes ---------------------------------------------------------

_BATTERY_LABEL = _keywords(
    "battery health",
    "battery",
    "batt",
    "bat",
    "بطارية",
    "البطارية",
    "صحة البطارية",
)
_BATTERY_PATTERNS = (
    re.compile(rf"(?:{_BATTERY_LABEL})\s*[:#.\-]?\s*(\d{{1,3}})\s*[%٪]?(?!\d)"),
    re.compile(r"(?<![\w.])(\d{1,3})\s*[%٪]"),
    re.compile(rf"(\d{{1,3}})\s*[%٪]?\s*(?:{_BATTERY_LABEL})(?!\w)"),
)

_GRADE_LABEL = _keywords("grade", "درجة", "الدرجة", "حالة", "الحالة")
#: The seeded ``condition_grade`` choices (``inventory.unit_attributes``). The
#: extractor writes these keys and nothing else, so a migrated handset's grade is
#: the same value the grade dropdown shows.
_GRADE_VALUES = {
    "a+": "a_plus",
    "b+": "b",
    "c+": "c",
    "a": "a",
    "b": "b",
    "c": "c",
}
_GRADE_PATTERNS = (
    re.compile(rf"(?:{_GRADE_LABEL})\s*[:#.\-]?\s*([abc]\+?)(?!\w)"),
    re.compile(r"(?<!\w)([abc]\+)(?!\w)"),
)
_GRADE_WORDS = (
    ("a_plus", _keywords("ممتاز جدا", "ممتازة جدا", "كالجديد", "كسر زيرو")),
    ("a", _keywords("ممتاز", "ممتازة", "نظيف جدا")),
    ("b", _keywords("جيد", "جيدة", "نظيف")),
    ("c", _keywords("مقبول", "مقبولة", "مستعمل بكثرة")),
    ("parts", _keywords("قطع غيار", "للقطع", "خردة")),
)
_GRADE_WORD_PATTERN = re.compile(
    "|".join(rf"(?P<{key}>{_word(alternation)})" for key, alternation in _GRADE_WORDS)
)


# --- result ------------------------------------------------------------------

#: Confidence below which a row is shown first and flagged for review.
LOW_CONFIDENCE = 0.5
#: Confidence at or above which a row is treated as routine.
HIGH_CONFIDENCE = 0.8


@dataclass
class Extraction:
    """Everything one legacy product name turned out to be."""

    name: str
    stem: str = ""
    stem_key: str = ""
    identifier: str = ""
    identifier_kind: str = ""
    #: ``{"storage": "256GB", "colour": "blue"}`` — the variant's axes.
    options: dict = field(default_factory=dict)
    #: ``{"battery_health": 86, "condition_grade": "a"}`` — the unit's own facts.
    attributes: dict = field(default_factory=dict)
    confidence: float = 0.0
    #: Machine codes explaining the confidence, for the review screen.
    reasons: list = field(default_factory=list)

    @property
    def collapsible(self) -> bool:
        """Is there enough here to make a unit out of?

        An identifier and something to call the product. Either one missing and
        the row stays an ordinary product, which is §12.4's "anything
        unparseable stays a product" stated as a predicate.
        """
        return bool(self.identifier and self.stem_key)


def extract(name: str) -> Extraction:
    """Pull one legacy product name apart. Never raises; never guesses silently."""
    original = str(name or "")
    result = Extraction(name=original)
    if not original.strip():
        result.reasons.append("empty_name")
        return result

    working = fold(original)
    claimed: list[tuple[int, int]] = []
    reasons: list[str] = []
    penalty = 0.0

    working, penalty = _take_identifier(working, claimed, result, reasons, penalty)
    working = _take_storage(working, claimed, result)
    working = _take_battery(working, claimed, result)
    working = _take_grade(working, claimed, result)
    working = _take_colour(working, claimed, result)

    result.stem = _stem_from(original, claimed)
    result.stem_key = cluster_key(result.stem)
    if result.identifier and not result.stem_key:
        reasons.append("no_stem")
        penalty += 0.5
    elif len(result.stem_key) < 3:
        reasons.append("weak_stem")
        penalty += 0.35
    if not result.identifier:
        reasons.append("no_identifier")

    result.reasons = reasons
    result.confidence = round(max(0.0, 1.0 - penalty), 2) if result.identifier else 0.0
    return result


def _take_identifier(working, claimed, result, reasons, penalty):
    for code, kind, pattern in _IDENTIFIER_PATTERNS:
        match = pattern.search(working)
        if match is None:
            continue
        value = normalize_identifier(match.group(1))
        if kind == IdentifierKind.VIN and not _looks_like_vin(value):
            continue
        result.identifier = value
        result.identifier_kind = kind
        claimed.append(match.span())
        working = _mask(working, *match.span())
        if code.endswith("_bare"):
            reasons.append("identifier_unlabelled")
            penalty += 0.1
        # An IMEI is fifteen digits. Fourteen (no check digit) and sixteen
        # (IMEISV) are real and are kept, but they cannot be check-summed, so
        # the one guard that catches a keying error cannot run on them.
        if kind == IdentifierKind.IMEI and len(value) != 15:
            reasons.append("identifier_odd_length")
            penalty += 0.2
        elif kind == IdentifierKind.IMEI and not luhn_check(value):
            reasons.append("imei_check_digit_failed")
            penalty += 0.2
        if kind == IdentifierKind.VIN and not vin_check_digit_ok(value):
            reasons.append("vin_check_digit_failed")
            penalty += 0.1
        # A second identifier-shaped run in the same name means the parser
        # picked one of two, and which one it picked is a coin toss the owner
        # should get to look at.
        if _has_second_identifier(working):
            reasons.append("second_identifier_present")
            penalty += 0.25
        return working, penalty
    return working, penalty


def _looks_like_vin(value: str) -> bool:
    return (
        len(value) == 17
        and value.isalnum()
        and any(char.isdigit() for char in value)
        and any(char.isalpha() for char in value)
    )


def _has_second_identifier(working: str) -> bool:
    return any(
        pattern.search(working) is not None
        for code, _kind, pattern in _IDENTIFIER_PATTERNS
        if code in ("imei_labelled", "imei_bare", "vin_labelled")
    )


def _take_storage(working, claimed, result):
    match = _STORAGE_PATTERN.search(working)
    if match is None:
        return working
    unit = next(key for key, _alt in _STORAGE_UNITS if match.group(key))
    result.options["storage"] = f"{int(match.group(1))}{unit.upper()}"
    claimed.append(match.span())
    return _mask(working, *match.span())


def _take_battery(working, claimed, result):
    for pattern in _BATTERY_PATTERNS:
        match = pattern.search(working)
        if match is None:
            continue
        value = int(match.group(1))
        # Anything outside this is not a battery percentage — it is a model
        # number, a year or a price that happened to sit next to a per-cent
        # sign, and writing it onto the unit would be inventing a fact.
        if not 1 <= value <= 100:
            continue
        result.attributes["battery_health"] = value
        claimed.append(match.span())
        return _mask(working, *match.span())
    return working


def _take_grade(working, claimed, result):
    for pattern in _GRADE_PATTERNS:
        match = pattern.search(working)
        if match is None:
            continue
        value = _GRADE_VALUES.get(match.group(1))
        if value is None:
            continue
        result.attributes["condition_grade"] = value
        claimed.append(match.span())
        return _mask(working, *match.span())
    match = _GRADE_WORD_PATTERN.search(working)
    if match is not None and match.lastgroup:
        result.attributes["condition_grade"] = match.lastgroup
        claimed.append(match.span())
        return _mask(working, *match.span())
    return working


def _take_colour(working, claimed, result):
    match = _COLOUR_PATTERN.search(working)
    if match is None or match.lastgroup not in _COLOUR_GROUPS:
        return working
    result.options["colour"] = _COLOUR_GROUPS[match.lastgroup]
    claimed.append(match.span())
    return _mask(working, *match.span())


def _mask(working: str, start: int, end: int) -> str:
    return working[:start] + " " * (end - start) + working[end:]


def _stem_from(original: str, claimed: list) -> str:
    """The original name with every claimed span cut out, tidied for display.

    Cut from the *original*, so the product keeps the shop's own capitalisation
    and spelling — ``iPhone 13 Pro``, not ``iphone 13 pro``.
    """
    kept = list(original)
    for start, end in claimed:
        for index in range(start, min(end, len(kept))):
            kept[index] = " "
    text = "".join(kept)
    # Separators that only made sense between two things, one of which is gone.
    text = "".join(" " if char in _PUNCTUATION else char for char in text)
    return " ".join(text.split())


def colour_label(key: str) -> str:
    """The Arabic name of an extracted colour, for the option value."""
    return _COLOUR_LABELS.get(key, key)


def option_label(axis: str, value: str) -> str:
    """How an option value is written on a variant."""
    return colour_label(value) if axis == "colour" else value


#: The same function under a name that cannot be confused with this module.
#: ``from . import extract`` inside the package resolves to whichever the
#: package attribute happens to be, and a package that re-exported the function
#: would silently hand a caller a function where it asked for a module.
extract_name = extract


__all__ = [
    "COLOUR_LEXICON",
    "Extraction",
    "HIGH_CONFIDENCE",
    "LOW_CONFIDENCE",
    "cluster_key",
    "colour_label",
    "extract",
    "extract_name",
    "fold",
    "option_label",
]
