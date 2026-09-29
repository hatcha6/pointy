"""How search reads text: one folding rule, written twice and kept identical.

Product search compares what a cashier types against names the shop typed, and
neither side is consistent: the catalogue spells rice «أرز» in some names and
«ارز» in others, puts «ة» or «ه» at the end of the same word, glues sizes onto
names («كاتشب575»), and nobody types hamza on a till keyboard. Folding BOTH sides
the same way before comparing is what makes those the same word.

:func:`fold` is the Python half. The database half is the SQL function
``pointy_search_fold`` (migration ``catalog.0034``), which the product and
variant searches match against through trigram expression indexes. The two must
agree byte for byte — ``test_search_text`` runs every rule through both — so a
change here is a change to that migration's SQL too, followed by a REINDEX.

Also here: the loanword key (:func:`skeleton`, SQL ``pointy_search_skeleton``)
that lets «شوكولاطة» find «شكلاطة», the keyboard-layout map that turns
«hgpgdf» (Arabic typed on the English layout) back into «الحليب», and the phone
key that lets «+218 91-234 5678» find a customer saved as «0912345678».
"""

from __future__ import annotations

import re
import unicodedata

# Apostrophes go first and without a space, so «Kellogg's» reads «kelloggs» —
# before NFKC, which would otherwise turn «´» into a space and an accent.
_APOSTROPHES = "'\u2019\u2018`\u00b4"
_APOSTROPHE_RE = re.compile(f"[{_APOSTROPHES}]")

# Invisible marks nobody types consistently: Quranic annotation signs,
# harakat, the superscript alef, Quranic small high signs, the tatweel, and
# the zero-width / direction controls that ride along with copied Arabic text.
_DROP_CHARS = (
    "\u0610-\u061a\u064b-\u065f\u0670\u06d6-\u06ed\u0640"
    "\u200b-\u200f\u202a-\u202e\u2066-\u2069\ufeff"
)
_DROP_RE = re.compile(f"[{_DROP_CHARS}]")

# Letter forms that are the same letter to a shop, and the digits of both
# Arabic scripts. «ک»/«ی» are the Persian kaf/yeh some keyboards produce.
_FOLD_FROM = (
    "أإآٱ"  # أ إ آ ٱ -> ا
    "ىئی"  # ى ئ ی -> ي
    "ؤ"  # ؤ -> و
    "ةۀ"  # ة ۀ -> ه
    "ک"  # ک -> ك
    "٠١٢٣٤٥٦٧٨٩"
    "۰۱۲۳۴۵۶۷۸۹"
    "٫٬،"  # Arabic decimal point, thousands mark, comma
)
_FOLD_TO = (
    "اااا"
    "ييي"
    "و"
    "هه"
    "ك"
    "01234567890123456789"
    ".,,"
)
_FOLD_TABLE = str.maketrans(_FOLD_FROM, _FOLD_TO)

# Punctuation that separates words. «.», «,» and «/» are handled on their own
# because inside a number they are part of it (4.75, 1/4).
_PUNCTUATION = (
    "!\"#$%&()*+:;<=>?@[\\]^_{|}~-"
    "«»؛؟٪٭“”–—…•·"
)
_PUNCTUATION_RE = re.compile(f"[{re.escape(_PUNCTUATION)}]")
_LOOSE_SEPARATOR_RE = re.compile(r"(?<![0-9])[.,/]|[.,/](?![0-9])")
_DIGIT_THEN_LETTER_RE = re.compile(r"([0-9])([^0-9\s.,/])")
_LETTER_THEN_DIGIT_RE = re.compile(r"([^0-9\s.,/])([0-9])")
_SPACE_RE = re.compile(r"\s+")

_ARABIC_LETTER_RE = re.compile("[ء-يٱ-ۓ]")
_LATIN_LETTER_RE = re.compile("[A-Za-z]")
_DIGIT_RE = re.compile("[0-9٠-٩۰-۹]")


def fold(value) -> str:
    """The comparison form of ``value``: what search stores and what it looks for.

    Apostrophes dropped, NFKC (Arabic presentation forms and the lam-alef
    ligature become ordinary letters), lower case, marks dropped, letter variants folded, both Arabic
    digit sets made ASCII, punctuation turned into spaces, a number split from a
    word it was glued to (``كاتشب575`` -> ``كاتشب 575``), spaces collapsed.

    Mirrors the SQL function ``pointy_search_fold`` step for step.
    """
    if value is None:
        return ""
    text = _APOSTROPHE_RE.sub("", str(value))
    text = unicodedata.normalize("NFKC", text).lower()
    text = _DROP_RE.sub("", text)
    text = text.translate(_FOLD_TABLE)
    text = _PUNCTUATION_RE.sub(" ", text)
    text = _LOOSE_SEPARATOR_RE.sub(" ", text)
    text = _DIGIT_THEN_LETTER_RE.sub(r"\1 \2", text)
    text = _LETTER_THEN_DIGIT_RE.sub(r"\1 \2", text)
    return _SPACE_RE.sub(" ", text).strip()


def tokens(value) -> list[str]:
    """The folded words of ``value``, in order, without repeats."""
    seen = []
    for word in fold(value).split(" "):
        if word and word not in seen:
            seen.append(word)
    return seen


# -- the loanword key ---------------------------------------------------------

# Letters that a Libyan spelling of a foreign word swaps freely: the hard g
# (سباجيتي / سباقيتي / سباغيتي), t (شوكولاتة / شكلاطة), s, d, z, and the
# Persian letters brand names borrow (ڤيمتو).
_SKELETON_FROM = "جغطضظذصثڤپچ"
_SKELETON_TO = "ققتدززسسفبش"
_SKELETON_TABLE = str.maketrans(_SKELETON_FROM, _SKELETON_TO)
_ARTICLE_RE = re.compile(r"(^| )ال(?=[^ ]{3})")
_LONG_VOWEL_RE = re.compile("[اوي]")
_FINAL_HEH_RE = re.compile(r"ه(?= |$)")


def skeleton(value) -> str:
    """A spelling-proof key for each word: what a word sounds like, roughly.

    The article «ال» comes off a word long enough to keep three letters, the
    interchangeable letters above collapse to one, the long vowels (ا و ي)
    and a final «ه» (the folded «ة») drop out. «شوكولاطة» and «شكلاطة» both
    become «شكلت»; «كاتشاب» and «كاتشب» both «كتشب». Only ever a last resort:
    it is deliberately lossy.

    Mirrors the SQL function ``pointy_search_skeleton``.
    """
    text = fold(value)
    text = _ARTICLE_RE.sub(r"\1", text)
    text = text.translate(_SKELETON_TABLE)
    text = _LONG_VOWEL_RE.sub("", text)
    text = _FINAL_HEH_RE.sub("", text)
    return _SPACE_RE.sub(" ", text).strip()


# -- what kind of text is this -------------------------------------------------


def has_arabic_letters(value) -> bool:
    return bool(_ARABIC_LETTER_RE.search(value or ""))


def has_latin_letters(value) -> bool:
    return bool(_LATIN_LETTER_RE.search(value or ""))


def has_digits(value) -> bool:
    return bool(_DIGIT_RE.search(value or ""))


def letter_count(value) -> int:
    """Arabic and Latin letters in ``value`` — not digits, spaces or marks."""
    text = value or ""
    return len(_ARABIC_LETTER_RE.findall(text)) + len(_LATIN_LETTER_RE.findall(text))


def looks_like_code(value) -> bool:
    """One word with a digit in it and no Arabic letters: ``1004``, ``AB-12``,
    ``1/4``. Codes rank above names for such a query."""
    text = (value or "").strip()
    if not text or " " in text:
        return False
    return has_digits(text) and not has_arabic_letters(text)


def code_form(value) -> str:
    """A typed code as the database stores codes: trimmed, Arabic digits made
    ASCII, direction marks gone. Case is left alone — code lookups compare
    case-insensitively."""
    text = unicodedata.normalize("NFKC", str(value or ""))
    text = re.sub("[​-‏‪-‮⁦-⁩﻿]", "", text)
    return text.translate(_FOLD_TABLE).strip()


# -- keyboard layout -----------------------------------------------------------

# The Arabic (101) layout over US QWERTY, unshifted then shifted. A cashier
# who types «hgpgdf» meant «الحليب»; a USB scanner left on the Arabic layout
# types a Latin barcode as Arabic letters and marks. Only the letter keys are
# mapped; digits come out as digits either way.
_LAYOUT_PAIRS = (
    ("`", "ذ"),
    ("q", "ض"), ("w", "ص"), ("e", "ث"), ("r", "ق"),
    ("t", "ف"), ("y", "غ"), ("u", "ع"), ("i", "ه"),
    ("o", "خ"), ("p", "ح"), ("[", "ج"), ("]", "د"),
    ("a", "ش"), ("s", "س"), ("d", "ي"), ("f", "ب"),
    ("g", "ل"), ("h", "ا"), ("j", "ت"), ("k", "ن"),
    ("l", "م"), (";", "ك"), ("'", "ط"),
    ("z", "ئ"), ("x", "ء"), ("c", "ؤ"), ("v", "ر"),
    ("b", "لا"), ("n", "ى"), ("m", "ة"), (",", "و"),
    (".", "ز"), ("/", "ظ"),
)
_SHIFTED_PAIRS = (
    ("Q", "َ"), ("W", "ً"), ("E", "ُ"), ("R", "ٌ"),
    ("T", "لإ"), ("Y", "إ"), ("U", "‘"), ("I", "÷"),
    ("O", "×"), ("P", "؛"),
    ("A", "ِ"), ("S", "ٍ"), ("D", "]"), ("F", "["),
    ("G", "لأ"), ("H", "أ"), ("J", "ـ"), ("K", "،"),
    ("L", "/"),
    ("Z", "~"), ("X", "ْ"), ("C", "}"), ("V", "{"),
    ("B", "لآ"), ("N", "آ"), ("M", "’"),
)
_LATIN_TO_ARABIC = {latin: arabic for latin, arabic in _LAYOUT_PAIRS}
# Longest keys first so «لا» is read as one key (b), not «ل» then «ا».
_ARABIC_TO_LATIN = sorted(
    [(arabic, latin) for latin, arabic in _LAYOUT_PAIRS + _SHIFTED_PAIRS],
    key=lambda pair: -len(pair[0]),
)


def latin_to_arabic_layout(value) -> str:
    """What the keys pressed would have typed on the Arabic layout."""
    return "".join(_LATIN_TO_ARABIC.get(char, char) for char in (value or "").lower())


def arabic_to_latin_layout(value) -> str:
    """What the keys pressed would have typed on the English layout — undoes a
    scanner or a cashier left on the Arabic layout. Keeps the case the shifted
    keys imply, since a code is compared case-insensitively anyway."""
    text = value or ""
    out = []
    index = 0
    while index < len(text):
        for arabic, latin in _ARABIC_TO_LATIN:
            if text.startswith(arabic, index):
                out.append(latin)
                index += len(arabic)
                break
        else:
            out.append(text[index])
            index += 1
    return "".join(out)


def code_readings(value) -> list[str]:
    """Every way a scanned or typed code could have been meant, exact first.

    A USB scanner types a code by pressing keys, so on a till left on the
    Arabic keyboard layout a Latin code arrives as Arabic letters (field data:
    about one failed scan in twenty at a grocery). Arabic-Indic digits typed
    by hand are the other half. Each reading is still matched exactly — this
    only adds the one the keys meant. A real code is ASCII, so the raw value
    and its readings can never both match.
    """
    value = value or ""
    readings = [value]
    for reading in (code_form(value), code_form(arabic_to_latin_layout(value))):
        if reading and reading not in readings:
            readings.append(reading)
    if has_arabic_letters(value):
        upper = readings[-1].upper()
        if upper not in readings:
            readings.append(upper)
    return readings


# -- phone numbers -------------------------------------------------------------

_NON_DIGIT_RE = re.compile(r"[^0-9]")
_PHONE_TEXT_RE = re.compile(r"^[\s0-9٠-٩۰-۹+()\-./]+$")
_LIBYA_PREFIX_RE = re.compile(r"^(?:00218|218|0)")


def phone_key(value) -> str:
    """The national part of a Libyan phone number, digits only.

    «+218 91-234 5678», «00218912345678», «0912345678» and «912345678» all give
    ``912345678``. Mirrors the SQL function ``pointy_phone_key``.
    """
    digits = _NON_DIGIT_RE.sub("", str(value or "").translate(_FOLD_TABLE))
    return _LIBYA_PREFIX_RE.sub("", digits, count=1)


def looks_like_phone(value, *, minimum_digits: int = 6) -> bool:
    """Only digits and the characters people write phone numbers with, and
    enough digits to be one."""
    text = (value or "").strip()
    if not text or not _PHONE_TEXT_RE.match(text):
        return False
    return len(_NON_DIGIT_RE.sub("", text.translate(_FOLD_TABLE))) >= minimum_digits
