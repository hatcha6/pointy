"""Costing a purchase the supplier invoiced in another currency.

The mirror image of ``apps.catalog.pricing``, and it rests on the same
invariant: **``PurchaseLine.unit_cost`` is always the shop's own currency.**
What the supplier invoiced is stored beside it in ``unit_cost_in_currency``,
together with the rate frozen on the order.

That placement is the whole design. ``unit_cost`` is the head of a chain —

    unit_cost → net_unit_cost → effective_unit_cost
              → effective_base_unit_cost → StockMovement.unit_cost
              → the valuation engine → COGS → margin

— so converting once, at entry, leaves every one of those untouched. Discounts,
landed-cost allocation, FIFO/LIFO/moving-average and the profit report never
learn that a currency was involved, which is exactly why this is a small change
rather than a rewrite.

**Why the rate is frozen and not re-read.** A purchase order records what the
shop actually paid. Re-deriving its cost basis from today's rate would rewrite
the margin on goods already sold — the same failure the sell side refuses, in
the other direction. A correction is an edit somebody makes on purpose.

**What stays in base currency, deliberately:** landed costs and the order-level
extra discount. For a Libyan importer these are customs, clearing and local
haulage — paid in dinars, on a foreign shipment. Entering them in dinars is the
common case, not a compromise, and it keeps the allocation arithmetic free of a
second conversion.
"""

from __future__ import annotations

import logging
from datetime import timedelta
from decimal import Decimal

from apps.core.models import ShopSettings
from apps.core.money_dates import day_range_end
from apps.fx.money import Money, quantize_amount, quantize_rate
from apps.fx.rates import decimals_for, rate_on

logger = logging.getLogger(__name__)


class PurchaseCurrencyError(Exception):
    """Raised when a foreign-currency order cannot be costed."""


def base_currency_code() -> str:
    return ShopSettings.load().currency_code


def is_foreign(currency_code: str | None) -> bool:
    """Whether ``currency_code`` means anything other than the shop's own."""
    code = str(currency_code or "").strip().upper()
    return bool(code) and code != base_currency_code()


def rate_moment_for(invoice_date):
    """The instant to price an invoice at, from its date.

    The **end** of the invoiced day, not its midnight: rates are published
    several times a day, and asking as-of midnight would cost a Tuesday invoice
    at Monday's closing rate. On-or-before then picks the last rate published
    during that day, which is the one the buyer was actually looking at.

    ``None`` (no invoice date on the order) means "as of now" — the resolver's
    own default.
    """
    if invoice_date is None:
        return None
    return day_range_end(invoice_date) - timedelta(microseconds=1)


def resolve_order_rate(currency_code: str | None, *, at=None, invoice_date=None):
    """The rate to seed an order with, or ``None`` for a base-currency one.

    ``invoice_date`` is the supplier's invoice date, and it is what the rate
    should be read as of — an invoice entered on Sunday for goods billed on
    Tuesday was priced at Tuesday's rate, and costing it at Sunday's silently
    misstates the cost basis by however far the dinar moved in between. That is
    exactly the error this feature exists to remove, so defaulting to "today"
    would have been the wrong default even though it is the convenient one.

    With no invoice date it falls back to now, which is the honest reading of an
    order somebody is entering as it happens.

    Returns the :class:`~apps.fx.rates.ResolvedRate` so the caller can store its
    instant and provenance alongside the number — a rate without them cannot be
    audited later.
    """
    if not is_foreign(currency_code):
        return None
    moment = at if at is not None else rate_moment_for(invoice_date)
    return rate_on(currency_code, base_currency_code(), at=moment)


def convert_unit_cost(amount, *, currency_code: str, rate) -> Decimal:
    """One invoiced unit cost, in the shop's own currency.

    The single conversion on the buy side. Rounds once, to the base currency's
    precision, using the same half-up regime the sell side uses — a purchase
    cost and a sale price meeting at different rounding would put a permanent
    fraction into every margin.
    """
    if rate is None or Decimal(str(rate)) <= 0:
        raise PurchaseCurrencyError(
            f"no usable exchange rate for {currency_code}; the cost cannot be "
            "converted"
        )
    base = base_currency_code()
    money = Money(amount, currency_code)
    converted = money.amount * quantize_rate(rate)
    return quantize_amount(converted, decimals_for(base))


def apply_order_currency(order, lines_data, *, rate=None):
    """Derive every line's base ``unit_cost`` from its invoiced foreign cost.

    Mutates ``lines_data`` in place — it is serializer ``validated_data``, and
    deriving there rather than at save is what lets the purchase-cost guard keep
    working untouched: by the time it compares a cost against a selling price,
    both are already in the shop's own currency. Comparing 12 USD against a
    82.20 LYD price would flag every foreign line as a loss.

    A base-currency order is left exactly as it was, which is every order that
    exists today.
    """
    currency_code = getattr(order, "currency_id", None) or None
    if not is_foreign(currency_code):
        for line in lines_data:
            line["unit_cost_in_currency"] = None
        return None

    effective_rate = rate if rate is not None else getattr(order, "exchange_rate", None)
    if effective_rate is None:
        raise PurchaseCurrencyError(
            f"a {currency_code} order needs an exchange rate before its costs "
            "can be recorded"
        )

    for line in lines_data:
        invoiced = line.get("unit_cost_in_currency")
        if invoiced is None:
            # The client sent only a base cost — honour it rather than zeroing
            # the line. Mixed entry is legitimate while a draft is being built.
            continue
        line["unit_cost"] = convert_unit_cost(
            invoiced,
            currency_code=currency_code,
            rate=effective_rate,
        )
    return effective_rate


def foreign_order_total(order) -> Decimal | None:
    """The order's total as the supplier invoiced it, for reconciliation.

    Derived rather than stored: it exists so a buyer can check the screen
    against the paper invoice, and it never feeds an aggregate — the stored
    totals stay base currency, which is what every report reads.

    Returns ``None`` for a base-currency order, and for a foreign one whose
    lines carry no invoiced amounts (nothing to reconcile against).
    """
    if not is_foreign(getattr(order, "currency_id", None)):
        return None
    total = Decimal("0.00")
    seen = False
    for line in order.lines.all():
        if line.unit_cost_in_currency is None:
            continue
        seen = True
        total += (line.unit_cost_in_currency * line.quantity).quantize(
            Decimal("0.01")
        )
    return total if seen else None
