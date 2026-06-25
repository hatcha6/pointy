"""Pure special-day rule engine + the built-in seed calendar.

This module has **no Django imports** so the rule logic is trivially unit
testable: it operates on lightweight :class:`Definition` objects, not model
rows. ``apps.holidays.models.Holiday.to_definition`` adapts a stored row into a
:class:`Definition`, and ``BUILTIN_HOLIDAYS`` feeds both the seed data migration
and the in-code fallback.

A "special day" is any of three shapes:

``fixed``
    Same Gregorian month/day every year (New Year, Independence Day, …),
    optionally lasting ``span_days``.

``nth_weekday``
    The N-th (or last) weekday of a month — e.g. White Friday = the *last*
    Friday of November. Supports an ``offset_days`` shift and ``span_days``.

``range``
    An explicit ``start_date``..``end_date`` window for a single occurrence,
    used for the moon-based Eids (entered per year) and ad-hoc local events.
"""

from __future__ import annotations

import calendar
from dataclasses import dataclass
from datetime import date, timedelta

# --- Rule types -------------------------------------------------------------
RULE_FIXED = "fixed"
RULE_NTH_WEEKDAY = "nth_weekday"
RULE_RANGE = "range"
RULE_TYPES = (RULE_FIXED, RULE_NTH_WEEKDAY, RULE_RANGE)

# --- Categories -------------------------------------------------------------
CATEGORY_NATIONAL = "national"
CATEGORY_RELIGIOUS = "religious"
CATEGORY_INTERNATIONAL = "international"
CATEGORY_COMMERCIAL = "commercial"
CATEGORY_LOCAL = "local"
CATEGORIES = (
    CATEGORY_NATIONAL,
    CATEGORY_RELIGIOUS,
    CATEGORY_INTERNATIONAL,
    CATEGORY_COMMERCIAL,
    CATEGORY_LOCAL,
)

# --- Provenance -------------------------------------------------------------
SOURCE_BUILTIN = "builtin"  # shipped in-app; works offline; never auto-deleted
SOURCE_RELAY = "relay"      # synced from the relay control plane
SOURCE_LOCAL = "local"      # reserved for shop-scoped rows
SOURCES = (SOURCE_BUILTIN, SOURCE_RELAY, SOURCE_LOCAL)

# Weekday convention: Python's ``date.weekday()`` — Monday=0 .. Sunday=6.
MONDAY, TUESDAY, WEDNESDAY, THURSDAY, FRIDAY, SATURDAY, SUNDAY = range(7)

# Ordinal sentinel for "the last <weekday> of the month".
ORDINAL_LAST = -1


@dataclass(frozen=True)
class Definition:
    """A rule for one special day, decoupled from persistence."""

    key: str
    name_en: str
    name_ar: str
    category: str
    rule_type: str
    month: int | None = None
    day: int | None = None
    weekday: int | None = None
    week_ordinal: int | None = None
    offset_days: int = 0
    span_days: int = 1
    start_date: date | None = None
    end_date: date | None = None
    show_in_dashboard: bool = True


@dataclass(frozen=True)
class Occurrence:
    """A definition resolved to a concrete window that covers a queried date."""

    key: str
    name_en: str
    name_ar: str
    category: str
    show_in_dashboard: bool
    start_date: date
    end_date: date

    def name(self, language: str = "en") -> str:
        return self.name_ar if str(language).startswith("ar") else self.name_en


def special_days_for_date(target: date, definitions) -> list[Occurrence]:
    """Return the special-day occurrences active on ``target``.

    Returns a list because a single date can carry several names — Dec 24 is
    both Libyan Independence Day and Christmas Eve. The result is deduped by key
    and ordered deterministically by ``(category, key)`` so stored snapshots and
    the dashboard banner are stable.
    """
    matches: dict[str, Occurrence] = {}
    for definition in definitions:
        window = _window_covering(definition, target)
        if window is None:
            continue
        start, end = window
        matches[definition.key] = Occurrence(
            key=definition.key,
            name_en=definition.name_en,
            name_ar=definition.name_ar,
            category=definition.category,
            show_in_dashboard=definition.show_in_dashboard,
            start_date=start,
            end_date=end,
        )
    return sorted(matches.values(), key=lambda occ: (occ.category, occ.key))


def _window_covering(definition: Definition, target: date):
    """Return the ``(start, end)`` window of ``definition`` that covers
    ``target``, or ``None`` if it does not apply on that date."""
    if definition.rule_type == RULE_RANGE:
        start, end = definition.start_date, definition.end_date
        if start and end and start <= target <= end:
            return start, end
        return None

    # ``fixed`` / ``nth_weekday`` recur every year. A span can reach across a
    # year boundary (a Dec-31 + span-3 event still covers Jan 1-2), so we test
    # the anchor for both the target's year and the previous year.
    for year in (target.year, target.year - 1):
        anchor = _anchor_date(definition, year)
        if anchor is None:
            continue
        start = anchor + timedelta(days=definition.offset_days or 0)
        end = start + timedelta(days=max(definition.span_days or 1, 1) - 1)
        if start <= target <= end:
            return start, end
    return None


def _anchor_date(definition: Definition, year: int):
    """The first day of ``definition``'s occurrence in ``year`` (before
    ``offset_days``/span), or ``None`` if it does not occur that year."""
    if definition.rule_type == RULE_FIXED:
        if not definition.month or not definition.day:
            return None
        try:
            return date(year, definition.month, definition.day)
        except ValueError:
            # e.g. Feb 29 in a non-leap year: the event simply does not occur.
            return None
    if definition.rule_type == RULE_NTH_WEEKDAY:
        return _nth_weekday_of_month(
            year, definition.month, definition.weekday, definition.week_ordinal
        )
    return None


def _nth_weekday_of_month(year, month, weekday, ordinal):
    """The date of the N-th (or last, ``ordinal == -1``) ``weekday`` of
    ``month`` in ``year``; ``None`` if it does not exist (e.g. no 5th Friday)."""
    if not month or weekday is None or not ordinal:
        return None
    try:
        days_in_month = calendar.monthrange(year, month)[1]
    except (ValueError, TypeError):
        return None

    if ordinal == ORDINAL_LAST:
        # Walk backward from the last day to the target weekday. This is the
        # off-by-one-proof way to get "last Friday" — never "5th else 4th".
        for day in range(days_in_month, 0, -1):
            candidate = date(year, month, day)
            if candidate.weekday() == weekday:
                return candidate
        return None

    if ordinal < 1:
        return None
    first = date(year, month, 1)
    first_match_day = 1 + (weekday - first.weekday()) % 7
    day = first_match_day + (ordinal - 1) * 7
    if day > days_in_month:
        return None  # e.g. no 5th occurrence of this weekday this month
    return date(year, month, day)


# --- Built-in seed calendar -------------------------------------------------
# Fixed Gregorian holidays + White Friday. The moon-based Eids and any local
# events are NOT seeded here — they are added manually on the relay as ``range``
# rows. Keys are stable slugs and form the snapshot/join handle on sales and
# purchases, so they must never change once shipped.
BUILTIN_HOLIDAYS = [
    {"key": "new_year", "name_en": "New Year's Day", "name_ar": "رأس السنة الميلادية",
     "category": CATEGORY_NATIONAL, "rule_type": RULE_FIXED, "month": 1, "day": 1},
    {"key": "feb17_revolution", "name_en": "17 February Revolution",
     "name_ar": "ثورة 17 فبراير", "category": CATEGORY_NATIONAL,
     "rule_type": RULE_FIXED, "month": 2, "day": 17},
    {"key": "valentines_day", "name_en": "Valentine's Day", "name_ar": "عيد الحب",
     "category": CATEGORY_COMMERCIAL, "rule_type": RULE_FIXED, "month": 2, "day": 14,
     "show_in_dashboard": False},
    {"key": "womens_day", "name_en": "International Women's Day",
     "name_ar": "اليوم العالمي للمرأة", "category": CATEGORY_INTERNATIONAL,
     "rule_type": RULE_FIXED, "month": 3, "day": 8},
    {"key": "mothers_day", "name_en": "Mother's Day", "name_ar": "عيد الأم",
     "category": CATEGORY_COMMERCIAL, "rule_type": RULE_FIXED, "month": 3, "day": 21},
    {"key": "labour_day", "name_en": "Labour Day", "name_ar": "عيد العمال",
     "category": CATEGORY_NATIONAL, "rule_type": RULE_FIXED, "month": 5, "day": 1},
    {"key": "fathers_day", "name_en": "Father's Day", "name_ar": "عيد الأب",
     "category": CATEGORY_COMMERCIAL, "rule_type": RULE_FIXED, "month": 6, "day": 21},
    {"key": "martyrs_day", "name_en": "Martyrs' Day", "name_ar": "يوم الشهيد",
     "category": CATEGORY_NATIONAL, "rule_type": RULE_FIXED, "month": 9, "day": 16},
    {"key": "liberation_day", "name_en": "Liberation Day", "name_ar": "يوم التحرير",
     "category": CATEGORY_NATIONAL, "rule_type": RULE_FIXED, "month": 10, "day": 23},
    {"key": "mens_day", "name_en": "International Men's Day",
     "name_ar": "اليوم العالمي للرجل", "category": CATEGORY_INTERNATIONAL,
     "rule_type": RULE_FIXED, "month": 11, "day": 19},
    {"key": "white_friday", "name_en": "White Friday", "name_ar": "الجمعة البيضاء",
     "category": CATEGORY_COMMERCIAL, "rule_type": RULE_NTH_WEEKDAY, "month": 11,
     "weekday": FRIDAY, "week_ordinal": ORDINAL_LAST},
    {"key": "independence_day", "name_en": "Libyan Independence Day",
     "name_ar": "عيد الاستقلال", "category": CATEGORY_NATIONAL,
     "rule_type": RULE_FIXED, "month": 12, "day": 24},
    {"key": "christmas_eve", "name_en": "Christmas Eve", "name_ar": "ليلة عيد الميلاد",
     "category": CATEGORY_RELIGIOUS, "rule_type": RULE_FIXED, "month": 12, "day": 24},
]

BUILTIN_KEYS = frozenset(item["key"] for item in BUILTIN_HOLIDAYS)


def row_fields(data: dict, *, source: str = SOURCE_BUILTIN) -> dict:
    """Normalise a seed mapping into a full set of ``Holiday`` field values
    (filling rule defaults). Shared by the seed migration and runtime seeding so
    there is one definition of the defaults."""
    return {
        "name_en": data["name_en"],
        "name_ar": data["name_ar"],
        "category": data.get("category", CATEGORY_NATIONAL),
        "rule_type": data["rule_type"],
        "month": data.get("month"),
        "day": data.get("day"),
        "weekday": data.get("weekday"),
        "week_ordinal": data.get("week_ordinal"),
        "offset_days": data.get("offset_days", 0),
        "span_days": data.get("span_days", 1),
        "start_date": data.get("start_date"),
        "end_date": data.get("end_date"),
        "show_in_dashboard": data.get("show_in_dashboard", True),
        "active": data.get("active", True),
        "source": source,
        "relay_id": data.get("relay_id", ""),
    }


def definition_from_mapping(data: dict) -> Definition:
    """Build a :class:`Definition` from a seed mapping (used for the in-code
    fallback and tests)."""
    return Definition(
        key=data["key"],
        name_en=data["name_en"],
        name_ar=data["name_ar"],
        category=data.get("category", CATEGORY_NATIONAL),
        rule_type=data["rule_type"],
        month=data.get("month"),
        day=data.get("day"),
        weekday=data.get("weekday"),
        week_ordinal=data.get("week_ordinal"),
        offset_days=data.get("offset_days", 0),
        span_days=data.get("span_days", 1),
        start_date=data.get("start_date"),
        end_date=data.get("end_date"),
        show_in_dashboard=data.get("show_in_dashboard", True),
    )


def builtin_definitions() -> list[Definition]:
    return [definition_from_mapping(item) for item in BUILTIN_HOLIDAYS]
