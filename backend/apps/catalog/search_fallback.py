"""When a search finds nothing: the shop's own words, read forgivingly.

Field telemetry from a grocery till (Sep 2026) says why searches come back
empty once the category filter is out of the way: one-key slips on the Arabic
keyboard («عصبر» for «عصير», «قطوغ» for «قطوف») and words run together
(«هريسةمنز» for «هريسة منزلية»). A search engine's generic typo tolerance does
not help there — the common grocery words are three or four letters long, and
engines allow no typo that short. What does help is that a shop's catalogue is
a small, closed vocabulary (a few thousand words): a typed word that is not in
it can be checked against every word one keystroke away, preferring the
neighbouring keys, and split in two where both halves are shop words.

Nothing here runs unless the ordinary search found nothing, so a well-typed
search never pays for it.
"""

from __future__ import annotations

import bisect
import math
import threading
from collections import Counter

from django.db.models import Count, Max

from . import search_text

# The letter rows of the Arabic (101) keyboard, as folded letters (ى ئ -> ي,
# ؤ -> و, ة -> ه), so a substitution between neighbouring keys can be told
# from any other one.
_KEYBOARD_ROWS = (
    "ضصثقفغعهخحجد",
    "شسيبلاتنمكط",
    "يءورليهوزظ",
)


def _neighbours():
    """(beside, above-or-below) key sets for every letter."""
    beside, near = {}, {}
    for row_index, row in enumerate(_KEYBOARD_ROWS):
        for index, letter in enumerate(row):
            same_row = beside.setdefault(letter, set())
            for other_index in (index - 1, index + 1):
                if 0 <= other_index < len(row):
                    same_row.add(row[other_index])
            other_rows = near.setdefault(letter, set())
            for other_row_index in (row_index - 1, row_index + 1):
                if 0 <= other_row_index < len(_KEYBOARD_ROWS):
                    other_row = _KEYBOARD_ROWS[other_row_index]
                    for other_index in (index - 1, index, index + 1):
                        if 0 <= other_index < len(other_row):
                            other_rows.add(other_row[other_index])
    for letter in beside:
        beside[letter].discard(letter)
        near[letter] -= beside[letter] | {letter}
    return beside, near


_BESIDE, _NEAR = _neighbours()

# How likely each kind of slip is, relative to the others. A finger landing on
# the key beside the right one is the commonest slip on a till keyboard; a
# letter left out while typing fast comes next. Multiplied by how common the
# resulting word is — logarithmically, so a word forty products share does not
# drown out the key beside the one that was pressed.
_SLIP_WEIGHTS = {
    "beside": 0.5,
    "dropped": 0.35,
    "swapped": 0.3,
    "extra": 0.2,
    "near": 0.15,
    "far": 0.03,
}
# Every folded letter a keystroke can produce (ذ sits on the backquote key).
_ALPHABET = sorted(set("".join(_KEYBOARD_ROWS)) | {"ذ"})

# A typed word shorter than this is never corrected: at two letters almost
# every edit is some other real word.
MIN_CORRECTABLE_LENGTH = 3

_ARTICLE = "ال"


class Vocabulary:
    """The folded words of every name the shop's search can match, with how
    many products use each."""

    def __init__(self, counts: Counter):
        self.counts = counts
        self.words = sorted(counts)

    def __len__(self):
        return len(self.counts)

    def knows(self, token: str) -> bool:
        """Whether ``token`` occurs inside some word — i.e. the ordinary search
        could have found it on its own."""
        if token in self.counts:
            return True
        return any(token in word for word in self.counts)

    def starts_a_word(self, prefix: str) -> bool:
        """``prefix`` begins some word — or begins one after its article, since
        a cashier types «نبع» for the catalogue's «النبع»."""
        return self._starts(prefix) or self._starts(_ARTICLE + prefix)

    def _starts(self, prefix: str) -> bool:
        index = bisect.bisect_left(self.words, prefix)
        return index < len(self.words) and self.words[index].startswith(prefix)

    def prefix_weight(self, prefix: str, limit: int = 200) -> int:
        """How many products use a word beginning with ``prefix`` (with or
        without the article before it)."""
        return self._weight(prefix, limit) + self._weight(_ARTICLE + prefix, limit)

    def _weight(self, prefix: str, limit: int) -> int:
        index = bisect.bisect_left(self.words, prefix)
        total = 0
        for word in self.words[index : index + limit]:
            if not word.startswith(prefix):
                break
            total += self.counts[word]
        return total


# -- building and caching the vocabulary ----------------------------------------

_lock = threading.Lock()
_cached: dict = {"fingerprint": None, "vocabulary": None}


def _fingerprint():
    """Changes whenever a searchable name could have: a row added, removed or
    edited. Deliberately NOT the catalog version, which moves on every sale."""
    from .models import Product, ProductAlias, ProductVariant

    parts = []
    for model in (Product, ProductVariant, ProductAlias):
        row = model.objects.aggregate(count=Count("id"), latest=Max("updated_at"))
        parts.append((row["count"], row["latest"]))
    return tuple(parts)


def _build():
    from .models import Product, ProductAlias, ProductVariant
    from .search_sql import SearchFold

    visible = Product.objects.filter(archived_at__isnull=True)
    names = []
    names += visible.annotate(_folded=SearchFold("name")).values_list(
        "id", "_folded"
    )
    names += (
        ProductVariant.objects.filter(product__archived_at__isnull=True)
        .exclude(name="")
        .annotate(_folded=SearchFold("name"))
        .values_list("product_id", "_folded")
    )
    names += (
        ProductAlias.objects.filter(product__archived_at__isnull=True)
        .annotate(_folded=SearchFold("alias"))
        .values_list("product_id", "_folded")
    )
    words_by_product: dict[int, set[str]] = {}
    for product_id, folded in names:
        words_by_product.setdefault(product_id, set()).update(
            word for word in (folded or "").split(" ") if word
        )
    counts = Counter()
    for words in words_by_product.values():
        counts.update(words)
    return Vocabulary(counts)


def shop_vocabulary() -> Vocabulary:
    """The current vocabulary, rebuilt only when a name changed."""
    fingerprint = _fingerprint()
    with _lock:
        if _cached["fingerprint"] == fingerprint and _cached["vocabulary"] is not None:
            return _cached["vocabulary"]
    vocabulary = _build()
    with _lock:
        _cached["fingerprint"] = fingerprint
        _cached["vocabulary"] = vocabulary
    return vocabulary


# -- correcting a query ------------------------------------------------------------


def _edits(word: str):
    """Every string one keystroke away from what was typed, with the kind of
    slip that would explain it: a letter typed extra, two swapped, one key
    hit instead of another (beside it, above/below it, or anywhere), or a
    letter left out."""
    splits = [(word[:index], word[index:]) for index in range(len(word) + 1)]
    for left, right in splits:
        if right:
            yield left + right[1:], "extra"
        if len(right) > 1:
            yield left + right[1] + right[0] + right[2:], "swapped"
        if right:
            typed = right[0]
            beside = _BESIDE.get(typed, ())
            near = _NEAR.get(typed, ())
            for letter in _ALPHABET:
                if letter == typed:
                    continue
                kind = "beside" if letter in beside else "near" if letter in near else "far"
                yield left + letter + right[1:], kind
        for letter in _ALPHABET:
            yield left + letter + right, "dropped"


def _best_edit(token: str, vocabulary: Vocabulary):
    best = None
    best_score = 0.0
    for candidate, kind in _edits(token):
        if len(candidate) < MIN_CORRECTABLE_LENGTH:
            continue
        if candidate in vocabulary.counts:
            # A whole word the shop uses beats the start of one.
            score = _SLIP_WEIGHTS[kind] * math.log(2 + vocabulary.counts[candidate])
        elif vocabulary.starts_a_word(candidate):
            weight = vocabulary.prefix_weight(candidate)
            score = _SLIP_WEIGHTS[kind] * math.log(2 + weight) * 0.5
        else:
            continue
        if score > best_score:
            best, best_score = candidate, score
    return [best] if best else None


# Only a word this long is tried as two run together, and its first half must
# be a whole shop word of at least three letters: «ليلس» is a slip, not «لي»
# and «لس».
MIN_SPLIT_LENGTH = 6


def _best_split(token: str, vocabulary: Vocabulary):
    """«هريسهمنز» -> «هريسه» + «منز»: a whole shop word, then the start of
    another (at least two letters of it: «عصيربو» -> «عصير» + «بو»)."""
    if len(token) < MIN_SPLIT_LENGTH:
        return None
    best = None
    best_score = None
    for index in range(3, len(token) - 1):
        left, right = token[:index], token[index:]
        if left not in vocabulary.counts:
            continue
        if right in vocabulary.counts:
            score = (2, vocabulary.counts[left] + vocabulary.counts[right])
        elif vocabulary.starts_a_word(right):
            score = (1, vocabulary.counts[left] + vocabulary.prefix_weight(right))
        else:
            continue
        if best_score is None or score > best_score:
            best, best_score = [left, right], score
    return best


def correct_tokens(tokens: list[str], vocabulary: Vocabulary) -> list[str] | None:
    """The tokens with each word the shop does not use replaced by the nearest
    one it does, or ``None`` when nothing needed (or admitted) correcting.

    Codes and numbers are left alone, as is anything too short to correct
    safely.
    """
    if not len(vocabulary):
        return None
    corrected = []
    changed = False
    for token in tokens:
        if (
            len(token) < MIN_CORRECTABLE_LENGTH
            or search_text.has_digits(token)
            or vocabulary.knows(token)
        ):
            corrected.append(token)
            continue
        replacement = _best_split(token, vocabulary) or _best_edit(token, vocabulary)
        if replacement is None:
            corrected.append(token)
            continue
        corrected.extend(replacement)
        changed = True
    return corrected if changed else None
