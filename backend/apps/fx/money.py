"""Money that knows what currency it is in, and the one definition of a
conversion.

Every ``DecimalField`` in this product carries a bare number whose currency is
implied by context — which is exactly the ambiguity multi-currency has to
remove. This module is the pure, Django-free core of that removal: a
:class:`Money` value that refuses to be added to a different currency, and a
single :func:`convert` that is the only supported way to cross from one currency
to another.

Two decisions are load-bearing and deliberately stated here rather than
rediscovered at each call site.

**Rounding.** A converted amount becomes a *price*, and prices in this codebase
are quantized by ``apps.catalog.units.quantize_money`` — 2 decimal places,
``ROUND_HALF_UP``. This module matches that regime exactly. It is deliberately
*not* the sales-money regime (``apps.sales.services.money``, which inherits the
process decimal context and therefore rounds half-to-even): conversion feeds
pricing, and pricing rounds half-up. ``apps.sales.business_simulation`` carries
an independent re-implementation of all three regimes, so a drift here fails the
oracle rather than silently re-pricing the catalog.

**Direction.** A rate is always read as *"how many ``to_code`` units per one
``from_code`` unit"*. USD to LYD at 6.85 means one dollar buys 6.85 dinars.
The words "base" and "quote" are avoided throughout: this product already uses
"base currency" to mean *the shop's own currency*, and FX convention uses "base"
to mean *the currency being priced* — the opposite end of the same pair. Naming
the ends ``from`` and ``to`` (as ERPNext's ``Currency Exchange`` does) makes the
direction unambiguous at every call site, which is the only place a
silently-inverted rate could hide.
"""

from __future__ import annotations

from dataclasses import dataclass
from decimal import ROUND_HALF_UP, Decimal, InvalidOperation

# Pricing money: 2dp, HALF_UP. Mirrors apps.catalog.units.quantize_money.
MONEY_PLACES = Decimal("0.01")

# Stored rate precision. numeric(18,8) on the model; 8dp is far finer than any
# published parallel-market rate (which quote 2-3dp) and leaves room for the
# inverse of a large rate without collapsing to zero.
RATE_PLACES = Decimal("0.00000001")

# Every money column in this product is ``decimal_places=2``. A currency with
# more places than this cannot be stored faithfully, so the registry refuses
# one rather than truncating silently. ISO 4217 gives LYD and TND three places;
# we deliberately carry two (see ``currencies.py``).
MAX_SUPPORTED_DECIMALS = 2

ZERO = Decimal("0")
ONE = Decimal("1")


class CurrencyError(Exception):
    """Base class for every currency misuse this module refuses."""


class CurrencyMismatch(CurrencyError):
    """Raised when two amounts in different currencies are combined.

    This is the whole point of the type. Adding 12 USD to 82 LYD is not a
    rounding problem, it is a category error, and it must fail loudly at the
    line that does it rather than produce a plausible number.
    """

    def __init__(self, left: str, right: str):
        self.left = left
        self.right = right
        super().__init__(
            f"cannot combine amounts in different currencies: {left} and {right}"
        )


class InvalidRate(CurrencyError):
    """Raised for a rate that cannot describe a real exchange (<= 0, or NaN)."""


def normalize_code(code) -> str:
    """Canonical form of a currency code: upper-case, stripped.

    Codes arrive from a feed, a settings row, and hand entry; normalizing in one
    place is what lets ``"usd"``, ``" USD "`` and ``"USD"`` be the same currency
    instead of three.
    """
    return str(code or "").strip().upper()


def exponent_for(decimals: int) -> Decimal:
    """The ``quantize`` exponent for a currency with ``decimals`` places."""
    places = int(decimals)
    if places < 0 or places > MAX_SUPPORTED_DECIMALS:
        raise CurrencyError(
            f"unsupported currency precision: {places} decimal places "
            f"(every money column in this product holds {MAX_SUPPORTED_DECIMALS})"
        )
    return Decimal(1).scaleb(-places)


def quantize_amount(value, decimals: int = 2) -> Decimal:
    """Round ``value`` to a currency's precision, half-up.

    The one rounding call for converted money. See the module docstring for why
    this regime and not the sales-money one.
    """
    return _decimal(value).quantize(exponent_for(decimals), rounding=ROUND_HALF_UP)


def quantize_rate(value) -> Decimal:
    """Round an exchange rate to the stored precision (8dp)."""
    return _validated_rate(value).quantize(RATE_PLACES, rounding=ROUND_HALF_UP)


def invert_rate(rate) -> Decimal:
    """The reverse of ``rate``, quantized to stored precision.

    Inversion is lossy: converting with ``invert_rate(r)`` is not guaranteed to
    return the exact amount a forward conversion at ``r`` started from. Callers
    that need a round trip must keep the original rate, which is precisely why a
    document freezes the rate it used instead of re-deriving one.
    """
    return quantize_rate(ONE / _validated_rate(rate))


@dataclass(frozen=True)
class CurrencySpec:
    """Everything needed to render and round one currency, free of persistence.

    ``apps.fx.models.Currency.to_spec`` adapts a stored row into one of these,
    the same way ``holidays.Holiday.to_definition`` adapts a holiday row — so
    the arithmetic below is unit-testable without a database.
    """

    code: str
    decimals: int = 2
    symbol_ar: str = ""
    symbol_en: str = ""

    def __post_init__(self):
        object.__setattr__(self, "code", normalize_code(self.code))
        object.__setattr__(self, "decimals", int(self.decimals))
        # Fail at construction, not at the first conversion, so a bad registry
        # row is caught by seeding rather than by a cashier.
        exponent_for(self.decimals)

    def symbol(self, language: str = "ar") -> str:
        """The symbol to render, falling back to the code when none is set."""
        if str(language).startswith("ar"):
            return self.symbol_ar or self.symbol_en or self.code
        return self.symbol_en or self.symbol_ar or self.code

    def money(self, amount) -> "Money":
        """A :class:`Money` in this currency, rounded to its precision."""
        return Money(quantize_amount(amount, self.decimals), self.code)


@dataclass(frozen=True)
class Money:
    """An amount that carries its currency.

    Immutable, and closed under arithmetic only within a single currency.
    Combining two currencies raises :class:`CurrencyMismatch` rather than
    coercing — there is no exchange rate in scope here, and guessing one is the
    bug this type exists to prevent.
    """

    amount: Decimal
    currency: str

    def __post_init__(self):
        object.__setattr__(self, "amount", _decimal(self.amount))
        code = normalize_code(self.currency)
        if not code:
            raise CurrencyError("Money requires a currency code")
        object.__setattr__(self, "currency", code)

    # --- construction ------------------------------------------------------
    @classmethod
    def zero(cls, currency: str) -> "Money":
        return cls(ZERO, currency)

    # --- arithmetic --------------------------------------------------------
    def _same(self, other: "Money") -> None:
        if not isinstance(other, Money):
            raise CurrencyError(f"expected Money, got {type(other).__name__}")
        if other.currency != self.currency:
            raise CurrencyMismatch(self.currency, other.currency)

    def __add__(self, other: "Money") -> "Money":
        self._same(other)
        return Money(self.amount + other.amount, self.currency)

    def __sub__(self, other: "Money") -> "Money":
        self._same(other)
        return Money(self.amount - other.amount, self.currency)

    def __neg__(self) -> "Money":
        return Money(-self.amount, self.currency)

    def __abs__(self) -> "Money":
        return Money(abs(self.amount), self.currency)

    def __mul__(self, factor) -> "Money":
        """Scale by a plain number (a quantity), never by another Money."""
        if isinstance(factor, Money):
            raise CurrencyError("cannot multiply Money by Money")
        return Money(self.amount * _decimal(factor), self.currency)

    __rmul__ = __mul__

    # --- comparison --------------------------------------------------------
    def __lt__(self, other: "Money") -> bool:
        self._same(other)
        return self.amount < other.amount

    def __le__(self, other: "Money") -> bool:
        self._same(other)
        return self.amount <= other.amount

    def __gt__(self, other: "Money") -> bool:
        self._same(other)
        return self.amount > other.amount

    def __ge__(self, other: "Money") -> bool:
        self._same(other)
        return self.amount >= other.amount

    # --- helpers -----------------------------------------------------------
    @property
    def is_zero(self) -> bool:
        return self.amount == ZERO

    def quantized(self, decimals: int = 2) -> "Money":
        return Money(quantize_amount(self.amount, decimals), self.currency)

    def __str__(self) -> str:
        return f"{self.amount} {self.currency}"


def convert(money: Money, *, to_code: str, rate, decimals: int = 2) -> Money:
    """Convert ``money`` into ``to_code`` at ``rate``, rounding once at the end.

    ``rate`` is *how many ``to_code`` units per one ``money.currency`` unit* —
    USD to LYD at 6.85 turns 12.00 USD into 82.20 LYD.

    Converting a currency to itself is allowed only at rate 1; anything else is
    a caller mistake worth failing on, since it would silently re-price a
    same-currency amount.

    The multiplication runs at full ``Decimal`` precision and the result is
    quantized exactly once. Quantizing the intermediate — or applying a rate in
    two steps — is how a per-line conversion drifts a cent away from the
    document total that was computed from the same inputs.
    """
    if not isinstance(money, Money):
        raise CurrencyError(f"expected Money, got {type(money).__name__}")
    target = normalize_code(to_code)
    if not target:
        raise CurrencyError("convert requires a target currency code")
    checked = _validated_rate(rate)
    if target == money.currency and checked != ONE:
        raise InvalidRate(
            f"converting {money.currency} to itself requires rate 1, got {checked}"
        )
    return Money(quantize_amount(money.amount * checked, decimals), target)


def _decimal(value) -> Decimal:
    if isinstance(value, Decimal):
        return value
    try:
        return Decimal(str(value))
    except (InvalidOperation, TypeError, ValueError) as exc:
        raise CurrencyError(f"not a usable decimal amount: {value!r}") from exc


def _validated_rate(value) -> Decimal:
    rate = _decimal(value)
    if not rate.is_finite():
        raise InvalidRate(f"exchange rate must be finite, got {value!r}")
    if rate <= ZERO:
        raise InvalidRate(f"exchange rate must be positive, got {rate}")
    return rate
