"""Runtime services for the holidays calendar: a hot-path-safe definition
cache, the tagging + dashboard helpers, and the relay sync."""

from __future__ import annotations

import logging
import threading
import time
from datetime import date, datetime

from django.core.exceptions import ImproperlyConfigured

from apps.core.timeutils import business_local_date

from . import rules
from .models import Holiday

logger = logging.getLogger(__name__)

# Tagging runs on the checkout critical path, so it must never issue a DB query
# per sale. Definitions are tiny (~15-25 rows) and change rarely, so we hold a
# process-local snapshot refreshed at most every TTL seconds, and invalidated
# explicitly after a sync.
_CACHE_TTL_SECONDS = 300
_cache_lock = threading.Lock()
_cached_definitions: list[rules.Definition] | None = None
_cached_at = 0.0


def get_active_definitions(*, force_refresh: bool = False) -> list[rules.Definition]:
    """Return the active special-day definitions from a process-local TTL cache."""
    global _cached_definitions, _cached_at
    now = time.monotonic()
    with _cache_lock:
        fresh = (
            _cached_definitions is not None
            and (now - _cached_at) < _CACHE_TTL_SECONDS
        )
        if fresh and not force_refresh:
            return _cached_definitions

    # Load outside the lock so a slow query can't serialise checkout threads.
    definitions = [
        holiday.to_definition()
        for holiday in Holiday.objects.filter(active=True)
    ]
    with _cache_lock:
        _cached_definitions = definitions
        _cached_at = time.monotonic()
        return _cached_definitions


def invalidate_definitions_cache() -> None:
    global _cached_definitions, _cached_at
    with _cache_lock:
        _cached_definitions = None
        _cached_at = 0.0


def special_days_for(moment: datetime | date | None = None) -> list[rules.Occurrence]:
    """Occurrences active on the shop-local date of ``moment`` (default: now)."""
    local_date = moment if isinstance(moment, date) and not isinstance(moment, datetime) else business_local_date(moment)
    return rules.special_days_for_date(local_date, get_active_definitions())


def special_day_keys_for(moment: datetime | date | None = None) -> list[str]:
    """The special-day keys to snapshot onto a sale/purchase made at ``moment``.

    Defensive by contract: tagging must never break a checkout, so any failure
    (cache miss, bad data, DB hiccup) degrades to an empty list rather than
    raising.
    """
    try:
        return [occurrence.key for occurrence in special_days_for(moment)]
    except Exception:  # noqa: BLE001 — never let tagging roll back a paid sale
        logger.exception("special_day_keys_for failed; tagging with empty list")
        return []


def today_dashboard_special_days(moment: datetime | date | None = None) -> list[dict]:
    """Today's dashboard-visible special days as plain dicts for the API.

    Excludes ``show_in_dashboard=False`` entries (e.g. Valentine's Day, which is
    still tagged on sales but not announced). Returns ``[]`` on any failure so a
    holidays bug can never 500 the dashboard.
    """
    try:
        return [
            {
                "key": occurrence.key,
                "name_en": occurrence.name_en,
                "name_ar": occurrence.name_ar,
                "category": occurrence.category,
            }
            for occurrence in special_days_for(moment)
            if occurrence.show_in_dashboard
        ]
    except Exception:  # noqa: BLE001
        logger.exception("today_dashboard_special_days failed")
        return []


# --- Seeding ---------------------------------------------------------------
def ensure_builtin_holidays(*, holiday_model=None) -> int:
    """Idempotently upsert the built-in fixed holidays + White Friday.

    Safe to call at runtime or from a data migration (pass the historical model).
    Only the built-in keys are touched; relay/local rows are left alone.
    """
    model = holiday_model or Holiday
    count = 0
    for data in rules.BUILTIN_HOLIDAYS:
        model.objects.update_or_create(
            key=data["key"],
            defaults=rules.row_fields(data, source=rules.SOURCE_BUILTIN),
        )
        count += 1
    invalidate_definitions_cache()
    return count


# --- Relay sync ------------------------------------------------------------
def sync_holidays(*, client=None) -> dict:
    """Pull the relay's holiday calendar and reconcile it into the local table.

    Reconciliation rules (idempotent, resilient):
      * Upsert by ``key``. The relay is authoritative for the fields of any key
        it returns.
      * A returned key that is a built-in keeps ``source="builtin"`` so it is
        never auto-deactivated; other keys are stored as ``source="relay"``.
      * Relay-sourced rows that vanish from the response are deactivated
        (``active=False``) — never hard-deleted, so historical key references
        and any re-appearance stay intact.
      * The relay being unreachable is a soft no-op: built-ins persist untouched.
    """
    # Imported lazily so importing this module never drags in the relay client.
    from apps.core.models import RelayInstallation
    from apps.core.relay import RelayControlClient, RelayControlError

    installation = RelayInstallation.load()
    if installation is None or not installation.access_token:
        logger.info("holidays sync skipped: no relay installation / access token")
        return {"synced": 0, "skipped": True}

    client = client or RelayControlClient()
    try:
        payload = client.get_holidays(access_token=installation.access_token)
    except (RelayControlError, ImproperlyConfigured) as exc:
        logger.warning("holidays sync soft-failed (built-ins retained): %s", exc)
        return {"synced": 0, "error": str(exc)}

    rows = (payload.get("holidays") if isinstance(payload, dict) else None) or []
    seen_keys: set[str] = set()
    synced = 0
    for row in rows:
        key = str(row.get("key") or "").strip()
        if not key:
            continue
        try:
            _upsert_relay_holiday(key, row)
        except Exception:  # noqa: BLE001 — one bad row must not abort the batch
            logger.exception("holidays sync: failed to upsert row %r", row)
            continue
        seen_keys.add(key)
        synced += 1

    deactivated = 0
    if seen_keys:
        deactivated = (
            Holiday.objects.filter(source=rules.SOURCE_RELAY)
            .exclude(key__in=seen_keys)
            .update(active=False)
        )

    invalidate_definitions_cache()
    return {"synced": synced, "deactivated": deactivated}


def _upsert_relay_holiday(key: str, row: dict) -> None:
    is_builtin = key in rules.BUILTIN_KEYS
    defaults = {
        "name_en": str(row.get("name_en") or "").strip(),
        "name_ar": str(row.get("name_ar") or "").strip(),
        "category": str(row.get("category") or rules.CATEGORY_NATIONAL).strip(),
        "rule_type": str(row.get("rule_type") or "").strip(),
        "month": _as_int(row.get("month")),
        "day": _as_int(row.get("day")),
        "weekday": _as_int(row.get("weekday")),
        "week_ordinal": _as_int(row.get("week_ordinal")),
        "offset_days": _as_int(row.get("offset_days")) or 0,
        "span_days": _as_int(row.get("span_days")) or 1,
        "start_date": _as_date(row.get("start_date")),
        "end_date": _as_date(row.get("end_date")),
        "show_in_dashboard": bool(row.get("show_in_dashboard", True)),
        "active": bool(row.get("active", True)),
        # A built-in key stays a built-in so it is never auto-deactivated on
        # vanish; the relay can still correct its display fields and dates.
        "source": rules.SOURCE_BUILTIN if is_builtin else rules.SOURCE_RELAY,
        "relay_id": str(row.get("id") or "").strip(),
    }
    Holiday.objects.update_or_create(key=key, defaults=defaults)


def _as_int(value):
    if value in (None, ""):
        return None
    try:
        return int(value)
    except (TypeError, ValueError):
        return None


def _as_date(value):
    if not value:
        return None
    if isinstance(value, date) and not isinstance(value, datetime):
        return value
    if isinstance(value, datetime):
        return value.date()
    try:
        return date.fromisoformat(str(value)[:10])
    except (TypeError, ValueError):
        return None
