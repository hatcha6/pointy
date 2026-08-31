"""One statement of which currency a money column is in.

``money_dates.py`` exists because the same money figure was dated three
different ways in three surfaces, and a report ended up including a wage while
excluding the sale that paid it. This module is the same discipline applied to
the other half of the question: not *when* the money moved, but *what currency
it is denominated in*.

The rule this codebase runs on is deliberately blunt, and it is what keeps
multi-currency from touching 273 columns:

    **Every stored money column is in the shop's base currency
    (``ShopSettings.currency_code``) unless it is registered below.**

That is why nothing downstream — stock value, margin, the loss guard, discounts,
payroll, the treasury position, the oracle — had to learn about currencies. A
foreign amount is an *additional* column beside the base one, never a
reinterpretation of it.

A registered foreign amount is never allowed to travel alone. It must be stored
with the currency it is in **and** the rate that converted it **and** the instant
that rate was effective, because an amount without its rate cannot be audited and
an amount whose rate is re-read is an amount that silently rewrites history. The
tests in ``apps/fx/test_money_currency.py`` enforce all of that statically —
they read the source rather than run it, because the failure being prevented is
a developer adding a column, and no runtime test sees that until the numbers have
already diverged.

When one of those tests fails, the fix is almost never to widen the allow-list.
It is to register the column, or to route the conversion through
``apps.fx.rates`` like everything else does.
"""

from __future__ import annotations

from dataclasses import dataclass

# The column that names the shop's own currency. Every unregistered money column
# in the product is denominated in whatever this says.
BASE_CURRENCY_SETTING = "core.ShopSettings.currency_code"

# The only package allowed to read the rate table directly or to do arithmetic
# with an exchange rate. Everything else asks ``apps.fx.rates`` for a resolved
# rate and calls ``.apply()`` on it.
FX_PACKAGE = "apps/fx/"


@dataclass(frozen=True)
class ForeignAmountGroup:
    """A money column that is *not* in the shop's base currency.

    Every field here is a **dotted path** from the model, because the three
    pieces of a foreign amount rarely all live on one row and the direction
    varies:

    * a product's price sheet currency lives on the *product* while the amount
      and its rate live on each *variant* — the currency belongs to the sheet,
      not to each row of it;
    * a purchase order is the reverse — the order carries the currency and the
      one rate the whole delivery was costed at, while each *line* carries the
      amount its supplier invoiced.

    ``amount_field`` may be ``None`` for a document that carries the rate on
    behalf of its lines but holds no foreign amount itself. That is a real and
    distinct role, not a gap: it is where the rate is frozen.
    """

    amount_field: str | None
    rate_field: str
    rate_at_field: str
    currency_path: str


# Model label -> the foreign amount it stores. Adding a foreign money column
# means adding a line here; the guard fails otherwise.
FOREIGN_AMOUNT_COLUMNS: dict[str, ForeignAmountGroup] = {
    # --- Sell side: a product's price sheet written in another currency ------
    "catalog.ProductVariant": ForeignAmountGroup(
        amount_field="price_amount",
        rate_field="price_rate",
        rate_at_field="price_rate_at",
        currency_path="product.pricing_currency",
    ),
    "catalog.ProductUnit": ForeignAmountGroup(
        amount_field="price_amount",
        rate_field="price_rate",
        rate_at_field="price_rate_at",
        currency_path="product.pricing_currency",
    ),
    # --- Buy side: a supplier invoice in another currency -------------------
    # The order freezes one rate for the whole delivery and holds no foreign
    # amount of its own; each line holds what the supplier invoiced.
    "purchasing.PurchaseOrder": ForeignAmountGroup(
        amount_field=None,
        rate_field="exchange_rate",
        rate_at_field="rate_effective_at",
        currency_path="currency",
    ),
    "purchasing.PurchaseLine": ForeignAmountGroup(
        amount_field="unit_cost_in_currency",
        rate_field="purchase_order.exchange_rate",
        rate_at_field="purchase_order.rate_effective_at",
        currency_path="purchase_order.currency",
    ),
}

# Field names that mean "an exchange rate" and nothing else. Deliberately
# specific: this codebase uses the bare word ``rate`` for a valuation bin's
# cost-per-unit and for a payroll pay rate, and a guard that matched those would
# be noise rather than protection.
EXCHANGE_RATE_FIELD_NAMES = (
    "price_rate",
    "exchange_rate",
    "conversion_rate",
    "fx_rate",
)

# Columns whose name matches the foreign-amount trio and which therefore must
# belong to a registered group.
FOREIGN_TRIO_FIELD_NAMES = (
    "price_amount",
    "unit_cost_in_currency",
    *EXCHANGE_RATE_FIELD_NAMES,
)


class UndeclaredForeignAmount(LookupError):
    """Raised when a foreign money column is used without being registered."""


def foreign_amount_group(model) -> ForeignAmountGroup | None:
    """The foreign-amount declaration for ``model``, or ``None`` if it has none."""
    return FOREIGN_AMOUNT_COLUMNS.get(model._meta.label)


def require_foreign_amount_group(model) -> ForeignAmountGroup:
    group = foreign_amount_group(model)
    if group is None:
        raise UndeclaredForeignAmount(
            f"{model._meta.label} stores a foreign amount but is not in "
            "FOREIGN_AMOUNT_COLUMNS in apps/core/money_currency.py. Register it "
            "with the currency and rate columns that accompany the amount."
        )
    return group


__all__ = [
    "BASE_CURRENCY_SETTING",
    "EXCHANGE_RATE_FIELD_NAMES",
    "FOREIGN_AMOUNT_COLUMNS",
    "FOREIGN_TRIO_FIELD_NAMES",
    "FX_PACKAGE",
    "ForeignAmountGroup",
    "UndeclaredForeignAmount",
    "foreign_amount_group",
    "require_foreign_amount_group",
]
