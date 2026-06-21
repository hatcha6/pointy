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


def search_normalize(text):
    """Light normalization for a DB ``search`` query: drop harakat (combining
    marks) and the tatweel only — NOT the letter folding. ``icontains`` compares
    against the RAW stored name, so folding ة→ه here would break the substring
    match; stripping the invisible diacritics only broadens it."""
    if not text:
        return ""
    s = unicodedata.normalize("NFKD", str(text))
    s = "".join(c for c in s if not unicodedata.combining(c)).replace("ـ", "")
    return re.sub(r"\s+", " ", s).strip()


def normalize_term(text):
    """Full comparison key (applied in Python over returned rows, and stored on an
    alias): diacritics + tatweel stripped AND the letter variants folded, casefolded."""
    if not text:
        return ""
    s = search_normalize(text)
    s = s.translate(_AR_FOLD).replace("ء", "")
    return s.casefold()
