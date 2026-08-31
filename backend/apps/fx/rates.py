"""Reading a rate: the on-or-before resolver, and the only way to convert.

Every question this module answers has the same shape: *what was one unit of
``from_code`` worth in ``to_code``, as of this instant, for a shop that settles
this way?* It never answers "the latest rate" — that is the question whose
answer changes after the fact, and re-answering it is what rewrites a margin
that was already earned.

Three rules make the answers trustworthy:

**On-or-before, never nearest.** The newest row at or before the asked-for
instant wins. A rate published at 14:00 has no bearing on a sale rung up at
13:30, and a resolver that reached forward would make a document's own frozen
rate irreproducible.

**Fallbacks are reported, never silent.** A shop configured for its bank's
series that has no such row is served the generic bank rate, then the cash rate
— but the result says which series it actually used, so the UI can tell the
owner instead of quietly costing their imports off the wrong instrument. This is
``apps.treasury``'s "no silent assumptions" rule applied to FX: surface the
substitution, do not hide it inside a total.

**Staleness is information, not an error.** An old rate still resolves. Libya
runs on generators and intermittent links, and a sale must never wait on a
network call — so the resolver always answers if it can, and marks how old the
answer is. Refusing to price would be a worse failure than pricing off a rate
the cashier can see is four days old.
"""

from __future__ import annotations

import logging
import threading
import time as _time
from dataclasses import dataclass
from datetime import datetime, timedelta
from decimal import Decimal

from django.conf import settings
from django.utils import timezone

from . import currencies as ref
from .models import Currency, ExchangeRate
from .money import ONE, Money, convert, invert_rate, normalize_code

logger = logging.getLogger(__name__)

# The "as of now" lookup runs on the catalog read path, where a page may resolve
# the same handful of pairs repeatedly. Historical lookups (a document's frozen
# instant) are never cached: they must be exact, and they are rare.
#
# Forced off under tests, the same rule the Redis-backed singletons follow (see
# ``POINTY_SHOP_SETTINGS_CACHE_TTL``): a test's writes roll back, so a surviving
# cache would serve a row the next test's database no longer has.
_CACHE_TTL_SECONDS = 0 if settings.TESTING else 60
_cache_lock = threading.Lock()
_cached_rates: dict = {}
_cached_at = 0.0


@dataclass(frozen=True)
class ResolvedRate:
    """A rate, plus everything needed to explain where it came from.

    The provenance fields are not decoration. ``instrument``/``bank_code`` say
    what actually matched while ``requested_*`` say what was asked for, and the
    gap between them is a substitution the owner is entitled to see.
    """

    rate: Decimal
    from_code: str
    to_code: str
    effective_at: datetime
    source: str
    instrument: str
    bank_code: str
    requested_instrument: str
    requested_bank_code: str
    inverted: bool = False
    # Identity (LYD to LYD) and the seeded 1.0 rows are always available and
    # never age; marking them keeps a "your rates are stale" banner from firing
    # on a shop that only ever uses its own currency.
    is_identity: bool = False

    @property
    def is_substituted(self) -> bool:
        """Whether a different series than the one requested was used."""
        if self.is_identity:
            return False
        return (
            self.instrument != self.requested_instrument
            or self.bank_code != self.requested_bank_code
        )

    def age(self, *, now=None) -> timedelta:
        return (now or timezone.now()) - self.effective_at

    def is_stale(self, max_age_hours: int, *, now=None) -> bool:
        if self.is_identity or not max_age_hours:
            return False
        return self.age(now=now) > timedelta(hours=int(max_age_hours))

    def apply(self, money: Money, *, decimals: int = 2) -> Money:
        """Convert ``money`` with this rate. The only conversion entry point."""
        return convert(money, to_code=self.to_code, rate=self.rate, decimals=decimals)


def rate_on(
    from_code: str,
    to_code: str,
    *,
    at=None,
    instrument: str = None,
    bank_code: str = None,
    allow_inverse: bool = True,
) -> ResolvedRate | None:
    """The rate from ``from_code`` to ``to_code`` as of ``at`` (default: now).

    Returns ``None`` when nothing can be resolved — an unknown pair, or a shop
    whose feed has never delivered. Callers must handle that by degrading
    visibly (showing the foreign price alone, refusing to auto-convert), never
    by substituting 1.0.
    """
    source_code = normalize_code(from_code)
    target_code = normalize_code(to_code)
    if not source_code or not target_code:
        return None

    # Read the singleton once. Asking it separately for the instrument and the
    # bank code cost two queries per resolution under a cold cache.
    shop_instrument, shop_bank = (
        _shop_settlement() if instrument is None or bank_code is None else ("", "")
    )
    wanted_instrument = ref.normalize_instrument(
        instrument if instrument is not None else shop_instrument
    )
    wanted_bank = ref.normalize_bank_code(
        bank_code if bank_code is not None else shop_bank,
        instrument=wanted_instrument,
    )
    moment = at or timezone.now()

    if source_code == target_code:
        return ResolvedRate(
            rate=ONE,
            from_code=source_code,
            to_code=target_code,
            effective_at=moment,
            source=ref.SOURCE_BUILTIN,
            instrument=wanted_instrument,
            bank_code=wanted_bank,
            requested_instrument=wanted_instrument,
            requested_bank_code=wanted_bank,
            is_identity=True,
        )

    for try_instrument, try_bank in _fallback_ladder(wanted_instrument, wanted_bank):
        row = _newest_at_or_before(
            source_code, target_code, try_instrument, try_bank, moment
        )
        if row is not None:
            return _resolved(row, wanted_instrument, wanted_bank, inverted=False)

    if allow_inverse:
        for try_instrument, try_bank in _fallback_ladder(wanted_instrument, wanted_bank):
            row = _newest_at_or_before(
                target_code, source_code, try_instrument, try_bank, moment
            )
            if row is not None:
                return _resolved(row, wanted_instrument, wanted_bank, inverted=True)

    return None


def current_rate(from_code: str, to_code: str, **kwargs) -> ResolvedRate | None:
    """``rate_on`` as of now, served from a short process-local cache.

    The cache exists because the catalog read path can ask for the same pair
    many times in one request. It is bypassed entirely whenever a caller pins an
    instant, and dropped outright after a sync.
    """
    global _cached_at

    if kwargs.get("at") is not None:
        return rate_on(from_code, to_code, **kwargs)

    key = (
        normalize_code(from_code),
        normalize_code(to_code),
        kwargs.get("instrument"),
        kwargs.get("bank_code"),
        kwargs.get("allow_inverse", True),
    )
    now = _time.monotonic()
    with _cache_lock:
        if _cached_rates and (now - _cached_at) < _CACHE_TTL_SECONDS:
            if key in _cached_rates:
                return _cached_rates[key]

    resolved = rate_on(from_code, to_code, **kwargs)

    with _cache_lock:
        if (_time.monotonic() - _cached_at) >= _CACHE_TTL_SECONDS:
            _cached_rates.clear()
            _cached_at = _time.monotonic()
        _cached_rates[key] = resolved
    return resolved


def invalidate_rate_cache() -> None:
    """Drop the current-rate cache. Called after any write to the rate table."""
    global _cached_at
    with _cache_lock:
        _cached_rates.clear()
        _cached_at = 0.0


def convert_amount(
    amount,
    *,
    from_code: str,
    to_code: str,
    at=None,
    instrument: str = None,
    bank_code: str = None,
) -> tuple[Money, ResolvedRate] | tuple[None, None]:
    """Convert a bare amount between currencies, returning the rate that did it.

    Returning the :class:`ResolvedRate` alongside the money is deliberate: the
    caller is expected to *store* it on whatever document it is building, which
    is the whole freeze-the-rate discipline. A helper that returned only the
    converted number would make forgetting to freeze the easy path.
    """
    resolved = rate_on(
        from_code,
        to_code,
        at=at,
        instrument=instrument,
        bank_code=bank_code,
    )
    if resolved is None:
        return None, None
    decimals = decimals_for(to_code)
    return resolved.apply(Money(amount, from_code), decimals=decimals), resolved


def decimals_for(code: str) -> int:
    """Decimal places for ``code``, defaulting to the product-wide 2."""
    spec = currency_spec(code)
    return spec.decimals if spec is not None else ref.BUILTIN_DECIMALS


def currency_spec(code: str):
    """The :class:`~apps.fx.money.CurrencySpec` for ``code``, or ``None``."""
    normalized = normalize_code(code)
    if not normalized:
        return None
    row = Currency.objects.filter(pk=normalized).first()
    return row.to_spec() if row is not None else None


# --- internals --------------------------------------------------------------
def _fallback_ladder(instrument: str, bank_code: str):
    """The series to try, most specific first.

    A shop banking with a particular bank prefers that bank's published series,
    falls back to the generic bank series, and finally to cash. Cash-settling
    shops try only cash: substituting a bank rate for a shop that pays in notes
    would misstate its cost in the opposite direction, and there is no reason to
    guess when the answer can simply be "no rate".
    """
    if instrument == ref.INSTRUMENT_BANK:
        ladder = []
        if bank_code:
            ladder.append((ref.INSTRUMENT_BANK, bank_code))
        ladder.append((ref.INSTRUMENT_BANK, ""))
        ladder.append((ref.INSTRUMENT_CASH, ""))
        return ladder
    return [(ref.INSTRUMENT_CASH, "")]


def _newest_at_or_before(from_code, to_code, instrument, bank_code, moment):
    return (
        ExchangeRate.objects.filter(
            from_currency_id=from_code,
            to_currency_id=to_code,
            instrument=instrument,
            bank_code=bank_code,
            effective_at__lte=moment,
        )
        .order_by("-effective_at")
        .first()
    )


def _resolved(row, wanted_instrument, wanted_bank, *, inverted):
    return ResolvedRate(
        rate=invert_rate(row.rate) if inverted else row.rate,
        from_code=row.to_currency_id if inverted else row.from_currency_id,
        to_code=row.from_currency_id if inverted else row.to_currency_id,
        effective_at=row.effective_at,
        source=row.source,
        instrument=row.instrument,
        bank_code=row.bank_code,
        requested_instrument=wanted_instrument,
        requested_bank_code=wanted_bank,
        inverted=inverted,
    )


def _shop_settings():
    from apps.core.models import ShopSettings

    return ShopSettings.load()


def _shop_settlement() -> tuple[str, str]:
    """How this shop settles, as ``(instrument, bank_code)``.

    Degrades to cash rather than raising: a settings read that fails must not
    take the price of a product down with it.
    """
    try:
        row = _shop_settings()
        return row.fx_instrument, row.fx_bank_code
    except Exception:  # noqa: BLE001 — pricing must not break on a settings read
        logger.exception("fx: could not read shop settlement instrument")
        return ref.INSTRUMENT_CASH, ""
