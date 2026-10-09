"""How the shop prices «كروت دفتر»: follow the company's suggestion, or its own.

``IntegrationPriceRule`` rows say where the shop departs from the company.
Resolution for a direct service: service+country, service, the shop-wide
default, then the company. A card variant has its own rule (a fixed price).
Whatever the rule, the customer never pays less than the shop does.
"""

from __future__ import annotations

from decimal import ROUND_CEILING, ROUND_HALF_UP, Decimal

from .models import IntegrationPriceRule as Rule

CENT = Decimal("0.01")
STEP = Decimal("0.25")
AIRTIME = "airtime"


def money(value) -> Decimal:
    return Decimal(value).quantize(CENT, rounding=ROUND_HALF_UP)


def round_up_step(value, step: Decimal = STEP) -> Decimal:
    return (Decimal(value) / step).to_integral_value(rounding=ROUND_CEILING) * step


def markup_price(shop_pays, markup_percent) -> Decimal:
    """``shop_pays × (1 + markup)`` rounded up to the step; never below what the shop pays."""
    pays = money(shop_pays)
    raw = pays * (Decimal(1) + Decimal(markup_percent) / Decimal(100))
    return max(money(round_up_step(raw)), pays)


def service_key(kind: str, bill_type: str = "") -> str:
    return AIRTIME if kind == "airtime" else f"bill:{bill_type}"


class Resolver:
    """The account's service rules, read once."""

    def __init__(self, account):
        self.default = None
        self.services = {}
        self.variants = {}
        for rule in Rule.objects.filter(account=account):
            if rule.variant_id:
                self.variants[rule.variant_id] = rule
            elif rule.scope == Rule.Scope.DEFAULT:
                self.default = rule
            else:
                self.services[(rule.service_key, rule.country)] = rule

    def markup(self, key: str, country: str = "") -> Decimal | None:
        """The shop's markup percent for this service, or ``None`` to follow the company."""
        for rule in (
            self.services.get((key, (country or "").upper())),
            self.services.get((key, "")),
            self.default,
        ):
            if rule is not None:
                return rule.markup_percent if rule.mode == Rule.Mode.CUSTOM else None
        return None

    def service_price(self, cost, company_price, key: str, country: str = "") -> Decimal:
        markup = self.markup(key, country)
        if markup is None or cost is None:
            return company_price
        return markup_price(cost, markup)


def forget(account) -> None:
    account.__dict__.pop("_price_resolver", None)


def resolver(account) -> Resolver:
    cached = getattr(account, "_price_resolver", None)
    if cached is None:
        cached = account._price_resolver = Resolver(account)
    return cached


def card_price(account, voucher, company_price) -> Decimal:
    """A card's price: its own custom rule, else the shop-wide default, else the company's."""
    rule = resolver(account).variants.get(voucher.variant_id)
    if rule is not None:
        if rule.mode == Rule.Mode.CUSTOM and rule.price is not None:
            # Not clamped to the cost: a price the shop's cost has since passed is
            # a card that must not be sold (:func:`below_cost`), not one sold at cost.
            return money(rule.price)
        return company_price
    default = resolver(account).default
    if (
        default is not None
        and default.mode == Rule.Mode.CUSTOM
        and default.markup_percent is not None
    ):
        return markup_price(voucher.cost, default.markup_percent)
    return company_price


def below_cost(account, voucher) -> bool:
    """Whether the shop's own price for this card is under what the shop now pays.

    Only a custom card price can be (the shop-wide and service markups are
    percentages of the cost itself, never negative). Such a card is not sold:
    the menu shows it unavailable, the sale refuses it, and the owner is told
    (``integrations.below_cost_cards``).
    """
    rule = resolver(account).variants.get(voucher.variant_id)
    return (
        rule is not None
        and rule.mode == Rule.Mode.CUSTOM
        and rule.price is not None
        and money(rule.price) < money(voucher.cost)
    )


def below_cost_vouchers(account) -> list:
    """The cards the shop can sell today whose custom price is under their cost."""
    from .models import IntegrationVoucher

    prices = dict(
        Rule.objects.filter(
            account=account, scope=Rule.Scope.VARIANT, mode=Rule.Mode.CUSTOM, price__isnull=False
        ).values_list("variant_id", "price")
    )
    if not prices:
        return []
    rows = IntegrationVoucher.objects.filter(
        account=account,
        variant_id__in=list(prices),
        is_available=True,
        brand__is_listed=True,
    ).select_related("brand")
    return [row for row in rows if money(prices[row.variant_id]) < money(row.cost)]
