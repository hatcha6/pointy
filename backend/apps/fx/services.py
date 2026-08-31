"""Writing rates: seeding the registry, and recording a rate by hand.

The relay sync lands here too (phase 1). What is shared by every writer in this
module is the discipline the read path depends on:

* a rate row is **never edited in place** — a corrected rate is a new row at a
  new instant, so a document that froze the old one can still find it;
* every write drops the resolver's current-rate cache, so a rate the owner just
  typed takes effect on the next screen rather than up to a minute later;
* a **manual** row is the shop's own number and outranks anything the feed says
  for the same instant.
"""

from __future__ import annotations

import logging
from datetime import datetime, timedelta

from django.core.exceptions import ImproperlyConfigured
from django.db import transaction
from django.utils import timezone
from django.utils.dateparse import parse_datetime

from . import currencies as ref
from .models import Currency, ExchangeRate
from .money import CurrencyError, normalize_code, quantize_rate
from .rates import invalidate_rate_cache

logger = logging.getLogger(__name__)


def ensure_builtin_currencies(*, currency_model=None) -> int:
    """Idempotently upsert the built-in currency registry.

    Safe from a data migration (pass the historical model) or at runtime, the
    same contract as ``holidays.ensure_builtin_holidays``. Display fields are
    refreshed on every call so a symbol correction ships with an upgrade; the
    ``is_enabled`` flag is left alone once set, because hiding a currency is the
    shop's decision and an upgrade must not undo it.
    """
    model = currency_model or Currency
    count = 0
    for data in ref.BUILTIN_CURRENCIES:
        fields = ref.currency_row_fields(data)
        existing = model.objects.filter(pk=data["code"]).first()
        if existing is not None:
            fields.pop("is_enabled", None)
            for key, value in fields.items():
                setattr(existing, key, value)
            existing.save()
        else:
            model.objects.create(code=data["code"], **fields)
        count += 1
    return count


@transaction.atomic
def record_manual_rate(
    *,
    from_code: str,
    to_code: str,
    rate,
    instrument: str = ref.INSTRUMENT_CASH,
    bank_code: str = "",
    effective_at=None,
    note: str = "",
    entered_by=None,
) -> ExchangeRate:
    """Store a rate the shop typed.

    Manual rows are the escape hatch that makes the feed optional: an owner who
    negotiates their own rate with a changer, or whose relay has been unreachable
    for a week, types a number and the whole pricing path uses it. Because it is
    stored as an ordinary row at an instant, it competes with feed rows on
    recency rather than needing a separate precedence table. When a manual entry
    lands on exactly the same instant as a feed row, the ``update_or_create``
    below rewrites that row as ``manual`` — the owner's number wins the tie,
    which is the whole point of letting them type one.
    """
    moment = effective_at or timezone.now()
    source = normalize_code(from_code)
    target = normalize_code(to_code)
    resolved_instrument = ref.normalize_instrument(instrument)
    resolved_bank = ref.normalize_bank_code(bank_code, instrument=resolved_instrument)

    row, _created = ExchangeRate.objects.update_or_create(
        from_currency_id=source,
        to_currency_id=target,
        instrument=resolved_instrument,
        bank_code=resolved_bank,
        effective_at=moment,
        defaults={
            "rate": quantize_rate(rate),
            "source": ref.SOURCE_MANUAL,
            "note": str(note or "").strip()[:240],
            "entered_by": entered_by,
            "relay_id": "",
        },
    )
    invalidate_rate_cache()
    return row


# --- Relay sync -------------------------------------------------------------
def sync_exchange_rates(*, client=None, lookback_days: int = 30) -> dict:
    """Pull published rates from the relay and reconcile them into the table.

    Deliberately the same shape as ``holidays.sync_holidays``, because it is the
    same problem: centrally-managed reference data arriving at a shop that may be
    offline, may have local overrides, and must keep working either way.

    Reconciliation rules:

      * Upsert on the natural key ``(from, to, instrument, bank_code,
        effective_at)``. Re-running the sync is therefore free, and a webhook
        push that overlaps the nightly pull cannot duplicate a rate.
      * A row the shop typed is **never overwritten**. The owner's number
        outranks the feed, permanently — that is what makes the feed optional.
      * Rows are only ever added. Nothing is deleted or deactivated on vanish,
        unlike the holidays calendar, because a rate is a historical fact: a
        document that froze it must still be able to resolve it years later.
      * An unreachable relay is a **soft no-op**. Existing rates persist and the
        shop keeps pricing off the last thing it knew.
      * A currency we do not carry is skipped with a log line rather than
        auto-created, so a typo upstream cannot invent a currency locally.

    Returns a summary dict; never raises for an ordinary transport failure.
    """
    from apps.core.models import RelayInstallation
    from apps.core.relay import RelayControlClient, RelayControlError

    installation = RelayInstallation.load()
    if installation is None or not installation.access_token:
        logger.info("fx sync skipped: no relay installation / access token")
        return {"synced": 0, "skipped": True}

    if _manual_only():
        logger.info("fx sync skipped: shop is configured for manual rates only")
        return {"synced": 0, "skipped": True}

    client = client or RelayControlClient()
    since = _newest_relay_rate_at(lookback_days)
    try:
        payload = client.get_exchange_rates(
            access_token=installation.access_token,
            since=since.isoformat() if since else None,
        )
    except (RelayControlError, ImproperlyConfigured) as exc:
        # A shop without the FX entitlement gets one fetch a day; the relay
        # answers 429 once it is spent. That is the normal, expected state for
        # most of the day on the free tier — not a failure worth a warning, and
        # emphatically not a reason to disturb anything: the rates already
        # pulled this morning are still on the shelf.
        if "429" in str(exc):
            logger.info("fx sync: daily allowance already used today")
            return {"synced": 0, "throttled": True}
        logger.warning("fx sync soft-failed (existing rates retained): %s", exc)
        return {"synced": 0, "error": str(exc)}

    rows = (payload.get("rates") if isinstance(payload, dict) else None) or []
    # "full" or "daily" — surfaced so the app can say "rates update once a day
    # on your plan" instead of leaving the owner to infer it from staleness.
    access = (payload.get("access") if isinstance(payload, dict) else "") or ""
    entitled = bool(payload.get("entitled")) if isinstance(payload, dict) else False
    known_codes = set(
        Currency.objects.values_list("pk", flat=True)
    )
    synced = 0
    skipped_unknown = 0
    for row in rows:
        try:
            outcome = _upsert_relay_rate(row, known_codes)
        except Exception:  # noqa: BLE001 — one bad row must not abort the batch
            logger.exception("fx sync: failed to upsert row %r", row)
            continue
        if outcome == "unknown_currency":
            skipped_unknown += 1
        elif outcome == "synced":
            synced += 1

    invalidate_rate_cache()
    return {
        "synced": synced,
        "skipped_unknown_currency": skipped_unknown,
        "received": len(rows),
        "access": access,
        "entitled": entitled,
    }


def _upsert_relay_rate(row: dict, known_codes: set) -> str:
    from_code = normalize_code(row.get("from") or row.get("from_code"))
    to_code = normalize_code(row.get("to") or row.get("to_code"))
    if not from_code or not to_code:
        return "invalid"
    if from_code not in known_codes or to_code not in known_codes:
        logger.info(
            "fx sync: skipping unknown currency pair %s->%s", from_code, to_code
        )
        return "unknown_currency"

    effective_at = _as_datetime(row.get("effective_at") or row.get("created_at"))
    if effective_at is None:
        return "invalid"
    try:
        rate = quantize_rate(row.get("rate"))
    except CurrencyError:
        # Malformed or non-positive rates are an expected condition from an
        # upstream feed, not an exceptional one — logged as a warning so a bad
        # row does not fill the log with tracebacks.
        logger.warning("fx sync: refusing unusable rate in %r", row)
        return "invalid"

    instrument = ref.normalize_instrument(
        row.get("instrument") or row.get("rate_type")
    )
    bank_code = ref.normalize_bank_code(
        row.get("bank_code") or row.get("bank_name"), instrument=instrument
    )

    existing = ExchangeRate.objects.filter(
        from_currency_id=from_code,
        to_currency_id=to_code,
        instrument=instrument,
        bank_code=bank_code,
        effective_at=effective_at,
    ).first()
    if existing is not None and existing.source == ref.SOURCE_MANUAL:
        # The shop's own number. The feed does not get to correct it.
        return "manual_kept"

    ExchangeRate.objects.update_or_create(
        from_currency_id=from_code,
        to_currency_id=to_code,
        instrument=instrument,
        bank_code=bank_code,
        effective_at=effective_at,
        defaults={
            "rate": rate,
            "source": ref.SOURCE_RELAY,
            "relay_id": str(row.get("id") or "").strip()[:80],
        },
    )
    return "synced"


def _newest_relay_rate_at(lookback_days: int):
    """The instant to ask the relay for rates *since*.

    Backdated by a margin rather than using the exact newest row: rates can be
    published slightly out of order, and re-fetching a handful of already-known
    rows is free (the upsert is idempotent) while missing one is not.
    """
    newest = (
        ExchangeRate.objects.filter(source=ref.SOURCE_RELAY)
        .order_by("-effective_at")
        .values_list("effective_at", flat=True)
        .first()
    )
    if newest is None:
        return timezone.now() - timedelta(days=lookback_days)
    return newest - timedelta(hours=1)


def _manual_only() -> bool:
    from apps.core.models import ShopSettings

    try:
        return bool(ShopSettings.load().fx_manual_only)
    except Exception:  # noqa: BLE001
        return False


def _as_datetime(value):
    if isinstance(value, datetime):
        return value if timezone.is_aware(value) else timezone.make_aware(value)
    if not value:
        return None
    parsed = parse_datetime(str(value))
    if parsed is None:
        return None
    return parsed if timezone.is_aware(parsed) else timezone.make_aware(parsed)
