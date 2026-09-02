"""Arabic-aware text normalization for product search/matching.

Shared by the learned-alias model (to store a stable comparison key) and the AI
invoice matcher (to compare extracted names against products + aliases), so the
two always agree on what "the same name" means.
"""

import re
import unicodedata

# Fold the interchangeable Arabic letter variants to one form: alef variants → ا,
# alef-maqsura → ي, taa-marbuta → ه, the hamza carriers → their base letter.
_AR_FOLD = str.maketrans(
    {"أ": "ا", "إ": "ا", "آ": "ا", "ٱ": "ا", "ى": "ي", "ئ": "ي", "ؤ": "و", "ة": "ه"}
)


# Harakat (fatha…sukun), the superscript alef, and the tatweel: marks that are
# invisible-ish to a reader and never typed consistently.
_ARABIC_DIACRITICS = re.compile(r"[\u064B-\u0652\u0670\u0640]")


def search_normalize(text):
    """Light normalization for a DB ``search`` query: drop harakat and the
    tatweel only — NOT the letter folding. ``icontains`` compares against the RAW
    stored name, so folding ة→ه here would break the substring match; stripping
    the invisible diacritics only broadens it.

    Composes to NFC rather than decomposing. NFKD would split أ into alef plus a
    combining hamza and the mark-stripping below would then eat the hamza,
    turning "أخضر" into "اخضر" — which matches nothing, because the stored name
    still reads "أخضر". Hamza-carrying words are ordinary in product names
    (أخضر, أحمر, أبيض), so that silently broke matching for a large slice of the
    catalogue. Folding those letters is still correct, but it belongs in
    :func:`normalize_term`, which compares in Python instead of in SQL.
    """
    if not text:
        return ""
    s = unicodedata.normalize("NFC", str(text))
    s = _ARABIC_DIACRITICS.sub("", s)
    return re.sub(r"\s+", " ", s).strip()


def normalize_term(text):
    """Full comparison key (applied in Python over returned rows, and stored on an
    alias): diacritics + tatweel stripped AND the letter variants folded, casefolded."""
    if not text:
        return ""
    s = search_normalize(text)
    s = s.translate(_AR_FOLD).replace("ء", "")
    return s.casefold()
