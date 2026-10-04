"""Which held card days a deposit most likely paid.

The owner knows one number — the amount in the SMS or on the bank statement —
and has to say which takings it covers. Asking them to add days up by hand is
how a held balance drifts, so this proposes an answer and says how sure it is:

``exact``  the deposit equals a set of whole days, net of the estimated fee;
``gross``  it equals them before the fee — the processor did not deduct one;
``close``  the oldest days come within a fee rounding of it;
``due``    nothing adds up, so the days that should have landed by now are
           proposed and the difference is shown for the owner to explain;
``none``   nothing is due yet either — the oldest held day is proposed.

Pure: no database, so every rule here is tested with plain numbers.
"""

from __future__ import annotations

from dataclasses import dataclass
from datetime import date
from decimal import Decimal
from itertools import combinations

MONEY_PLACES = Decimal("0.01")
ZERO = Decimal("0.00")

MATCH_EXACT = "exact"
MATCH_GROSS = "gross"
MATCH_CLOSE = "close"
MATCH_DUE = "due"
MATCH_NONE = "none"

# Days beyond the due ones that a deposit may still cover: a processor that
# paid a day early, or a schedule the owner set one day too long.
_EXTRA_CANDIDATES = 3
# Exhaustive search is cheap below this; above it only whole-day prefixes are
# tried, which is what a processor paying in order produces anyway.
_SUBSET_SEARCH_LIMIT = 12
# How far a deposit may sit from the estimate and still be called "close": a
# fee computed on the day's total rather than per sale differs by cents.
_CLOSE_RATIO = Decimal("0.01")
_CLOSE_FLOOR = Decimal("0.05")


@dataclass(frozen=True)
class PendingDay:
    """One processor day of held card takings."""

    day: date
    expected_on: date
    gross: Decimal
    commission: Decimal
    count: int

    @property
    def net(self) -> Decimal:
        return (self.gross - self.commission).quantize(MONEY_PLACES)


@dataclass(frozen=True)
class Suggestion:
    days: tuple[date, ...]
    match: str
    expected: Decimal
    difference: Decimal | None


def _net(days) -> Decimal:
    return sum((day.net for day in days), ZERO).quantize(MONEY_PLACES)


def _gross(days) -> Decimal:
    return sum((day.gross for day in days), ZERO).quantize(MONEY_PLACES)


def _suggestion(days, match, amount) -> Suggestion:
    chosen = tuple(sorted(day.day for day in days))
    expected = _net(days)
    difference = None if amount is None else (amount - expected).quantize(MONEY_PLACES)
    return Suggestion(days=chosen, match=match, expected=expected, difference=difference)


def _exact_subset(candidates, amount, total):
    """The subset of ``candidates`` whose ``total`` equals ``amount``.

    Oldest-first prefixes are tried before anything else — a processor pays in
    order, so the run of oldest days is the overwhelmingly likely answer. Then,
    for a short list, every combination, preferring the one that reaches least
    far forward, so a day is never skipped in favour of a later one that
    happens to add up.
    """
    for end in range(1, len(candidates) + 1):
        if total(candidates[:end]) == amount:
            return candidates[:end]
    if len(candidates) > _SUBSET_SEARCH_LIMIT:
        return None
    best = None
    for size in range(1, len(candidates) + 1):
        for subset in combinations(candidates, size):
            if total(subset) != amount:
                continue
            key = (max(day.day for day in subset), -size)
            if best is None or key < best[0]:
                best = (key, subset)
    return best[1] if best else None


def suggest(days, *, amount: Decimal | None, settled_on: date) -> Suggestion:
    """Propose the held days a deposit of ``amount`` on ``settled_on`` paid."""
    ordered = sorted(days, key=lambda day: day.day)
    # A deposit cannot pay for takings the processor had not closed yet.
    possible = [day for day in ordered if day.day <= settled_on]
    due = [day for day in possible if day.expected_on <= settled_on]
    fallback = due or possible[:1]
    fallback_match = MATCH_DUE if due else MATCH_NONE

    if amount is None or not possible:
        return _suggestion(fallback, fallback_match, amount)

    amount = Decimal(amount).quantize(MONEY_PLACES)
    candidates = possible[: len(due) + _EXTRA_CANDIDATES]

    exact = _exact_subset(candidates, amount, _net)
    if exact:
        return _suggestion(exact, MATCH_EXACT, amount)
    gross = _exact_subset(candidates, amount, _gross)
    if gross:
        return _suggestion(gross, MATCH_GROSS, amount)

    tolerance = max(abs(amount) * _CLOSE_RATIO, _CLOSE_FLOOR)
    closest = None
    for end in range(1, len(candidates) + 1):
        gap = abs(amount - _net(candidates[:end]))
        if gap <= tolerance and (closest is None or gap < closest[0]):
            closest = (gap, candidates[:end])
    if closest is not None:
        return _suggestion(closest[1], MATCH_CLOSE, amount)

    return _suggestion(fallback, fallback_match, amount)


__all__ = [
    "MATCH_CLOSE",
    "MATCH_DUE",
    "MATCH_EXACT",
    "MATCH_GROSS",
    "MATCH_NONE",
    "PendingDay",
    "Suggestion",
    "suggest",
]
