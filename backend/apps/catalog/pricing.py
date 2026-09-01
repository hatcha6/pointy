"""Pricing a product whose price sheet is written in another currency.

The shape of the feature, in one sentence: **the foreign number is what the
owner maintains, the base-currency number is what the shop sells at, and moving
from one to the other is a decision someone makes — never something that happens
while a customer is standing there.**

That is why ``ProductVariant.unit_price`` stays base currency and stays stored.
A design that kept only the dollar price and multiplied by "today's rate" on
every read would be simpler to write and wrong in three separate ways: the shelf
price would differ from the receipt when the rate ticked between them, every
existing query that compares or sums a price would silently mix currencies, and
last month's margin would be recomputed every time a report was opened.

So the foreign price is *frozen* alongside the base price, together with the rate
that produced it and the instant that rate was effective. Nothing re-derives a
price implicitly. When rates move, :func:`reprice_preview` shows the owner what
has drifted and by how much, and :func:`apply_reprice` writes the numbers they
approved — the "repricing is a decision, not an emergency" rule from
``MULTI_CURRENCY_PLAN.md``.
"""

from __future__ import annotations

import logging
from dataclasses import dataclass
from decimal import Decimal

from django.db import transaction
from django.utils import timezone

from apps.core.models import ShopSettings
from apps.fx.money import Money, quantize_amount
from apps.fx.rates import decimals_for, rate_on

from .models import Product, ProductUnit, ProductVariant

logger = logging.getLogger(__name__)

VARIANT = "variant"
UNIT = "unit"


@dataclass(frozen=True)
class PriceProposal:
    """One row's foreign price, restated at a new rate.

    Carries both the old and the new rate so the UI can explain *why* a price
    moved — "the dollar went from 6.85 to 7.11" reads very differently from a
    price that simply changed on its own.
    """

    kind: str
    target_id: int
    product_id: int
    label: str
    currency_code: str
    price_amount: Decimal
    current_base_price: Decimal
    proposed_base_price: Decimal | None
    old_rate: Decimal | None
    new_rate: Decimal | None
    rate_effective_at: object = None
    # Set when no rate could be resolved at all. The row is reported rather than
    # skipped: a product the shop cannot currently price is exactly the thing
    # the owner needs told about.
    unpriceable: bool = False

    @property
    def changed(self) -> bool:
        if self.unpriceable or self.proposed_base_price is None:
            return False
        return self.proposed_base_price != self.current_base_price

    @property
    def delta(self) -> Decimal:
        if self.proposed_base_price is None:
            return Decimal("0")
        return self.proposed_base_price - self.current_base_price

    @property
    def delta_percent(self) -> Decimal:
        if not self.current_base_price or self.proposed_base_price is None:
            return Decimal("0")
        return quantize_amount(
            (self.delta / self.current_base_price) * Decimal("100"), 2
        )


def base_currency_code() -> str:
    """The shop's own currency — the one every stored money column is in."""
    return ShopSettings.load().currency_code


def set_foreign_price(target, amount, *, at=None, save=True):
    """Record a foreign price on a variant or unit and derive its base price.

    ``target`` is a :class:`~apps.catalog.models.ProductVariant` or
    :class:`~apps.catalog.models.ProductUnit`. The product's
    ``pricing_currency`` decides what ``amount`` means; if the product has none,
    the amount *is* base currency and is stored as such with no rate attached.

    Returns ``True`` when a base price was derived, ``False`` when no rate could
    be resolved. A ``False`` return leaves the existing base price untouched —
    an unpriceable product keeps selling at yesterday's number rather than
    dropping to zero, which is the only safe direction to fail in.
    """
    product = target.product
    currency = product.pricing_currency_id
    base = base_currency_code()
    amount = quantize_amount(amount, decimals_for(currency or base))

    if not currency or currency == base:
        # Base-priced: the foreign trio stays empty so nothing later mistakes
        # this row for one that needs repricing.
        _write_base_price(target, amount)
        target.price_amount = None
        target.price_rate = None
        target.price_rate_at = None
        if save:
            _save(target)
        return True

    resolved = rate_on(currency, base, at=at)
    target.price_amount = amount
    if resolved is None:
        logger.warning(
            "no %s->%s rate; kept existing base price for %s %s",
            currency,
            base,
            target.__class__.__name__,
            target.pk,
        )
        if save:
            _save(target)
        return False

    converted = resolved.apply(Money(amount, currency), decimals=decimals_for(base))
    _write_base_price(target, converted.amount)
    target.price_rate = resolved.rate
    target.price_rate_at = resolved.effective_at
    if save:
        _save(target)
    return True


def reprice_preview(*, products=None, at=None, include_unchanged=False):
    """What every foreign-priced row would cost if repriced at ``at``'s rates.

    Nothing is written. ``products`` narrows the scan to a queryset; by default
    every foreign-priced product in the catalog is considered.

    Rows whose base price would not move are dropped unless
    ``include_unchanged`` — an owner opening this screen wants the list of
    things that drifted, not the whole catalog.
    """
    base = base_currency_code()
    queryset = products if products is not None else Product.objects.all()
    queryset = queryset.filter(
        pricing_currency__isnull=False, archived_at__isnull=True
    ).exclude(pricing_currency_id=base)

    proposals: list[PriceProposal] = []
    # One rate lookup per currency, not per row: a catalog of 4,000 dollar-priced
    # products must not issue 4,000 identical queries.
    rate_cache: dict[str, object] = {}
    # Likewise the base currency's precision — reading it inside the loop cost a
    # currency-table query per row, which is the same N+1 in a quieter disguise.
    base_decimals = decimals_for(base)

    variants = (
        ProductVariant.objects.filter(
            product__in=queryset, price_amount__isnull=False
        )
        .select_related("product")
        .order_by("id")
    )
    for variant in variants:
        proposals.append(
            _propose(
                VARIANT,
                variant,
                variant.unit_price,
                base,
                at,
                rate_cache,
                base_decimals,
                label=variant.name or variant.product.name,
            )
        )

    units = (
        ProductUnit.objects.filter(product__in=queryset, price_amount__isnull=False)
        .select_related("product", "unit")
        .order_by("id")
    )
    for unit in units:
        proposals.append(
            _propose(
                UNIT,
                unit,
                unit.price or Decimal("0.00"),
                base,
                at,
                rate_cache,
                base_decimals,
                label=f"{unit.product.name} / {unit.unit_id}",
            )
        )

    if include_unchanged:
        return proposals
    return [p for p in proposals if p.changed or p.unpriceable]


@transaction.atomic
def apply_reprice(proposals) -> int:
    """Write the proposals the owner approved, at the rate they were shown.

    Deliberately applies the *previewed* rate rather than re-resolving: a
    repricing that quietly used a newer rate than the one on screen would make
    the confirmation dialog a lie, and parallel rates move fast enough for that
    to happen within one session.
    """
    written = 0
    for proposal in proposals:
        if proposal.unpriceable or not proposal.changed:
            continue
        model = ProductVariant if proposal.kind == VARIANT else ProductUnit
        target = model.objects.filter(pk=proposal.target_id).first()
        if target is None:
            continue
        _write_base_price(target, proposal.proposed_base_price)
        target.price_rate = proposal.new_rate
        target.price_rate_at = proposal.rate_effective_at
        _save(target)
        written += 1
    return written


def _propose(kind, target, current_base, base, at, rate_cache, base_decimals, *, label):
    currency = target.product.pricing_currency_id
    if currency not in rate_cache:
        rate_cache[currency] = rate_on(currency, base, at=at)
    resolved = rate_cache[currency]

    common = {
        "kind": kind,
        "target_id": target.pk,
        "product_id": target.product_id,
        "label": label,
        "currency_code": currency,
        "price_amount": target.price_amount,
        "current_base_price": current_base or Decimal("0.00"),
        "old_rate": target.price_rate,
    }
    if resolved is None:
        return PriceProposal(
            proposed_base_price=None,
            new_rate=None,
            unpriceable=True,
            **common,
        )
    converted = resolved.apply(
        Money(target.price_amount, currency), decimals=base_decimals
    )
    return PriceProposal(
        proposed_base_price=converted.amount,
        new_rate=resolved.rate,
        rate_effective_at=resolved.effective_at,
        **common,
    )


def _write_base_price(target, amount):
    if isinstance(target, ProductUnit):
        target.price = amount
    else:
        target.unit_price = amount


def _save(target):
    fields = ["price_amount", "price_rate", "price_rate_at", "updated_at"]
    fields.append("price" if isinstance(target, ProductUnit) else "unit_price")
    target.save(update_fields=fields)


def set_base_price(target, amount, *, save=True):
    """Write a hand-typed **base-currency** price on a variant or unit.

    The counterpart to :func:`set_foreign_price`: here somebody typed the number
    the shop actually sells at, not the one on a foreign price sheet.

    For a base-priced product that is the whole job. For a *foreign*-priced one
    the frozen trio has to move with it, otherwise the price just set is
    silently temporary: :func:`reprice_preview` compares the stale
    ``price_amount`` against the new base price, reports a drift nobody caused,
    and the next repricing puts the old shelf price back. So the foreign amount
    is restated from the new base price at the rate already frozen on the row
    (the rate that price sheet was agreed at), falling back to today's rate for
    a row that has never carried a foreign price.

    Returns ``True`` when the foreign amount was kept in step, ``False`` when
    the product is foreign-priced but no rate could be resolved — the base price
    is written either way, because refusing to price a product is never the
    safer failure.
    """
    product = target.product
    currency = product.pricing_currency_id
    base = base_currency_code()
    amount = quantize_amount(amount, decimals_for(base))

    if not currency or currency == base:
        _write_base_price(target, amount)
        target.price_amount = None
        target.price_rate = None
        target.price_rate_at = None
        if save:
            _save(target)
        return True

    _write_base_price(target, amount)
    rate = target.price_rate
    effective_at = target.price_rate_at
    if not rate:
        resolved = rate_on(currency, base, at=None)
        if resolved is None:
            logger.warning(
                "no %s->%s rate; base price written without restating the "
                "foreign price for %s %s",
                currency,
                base,
                target.__class__.__name__,
                target.pk,
            )
            if save:
                _save(target)
            return False
        rate = resolved.rate
        effective_at = resolved.effective_at

    target.price_amount = _foreign_amount_for(amount, rate, currency, base)
    target.price_rate = rate
    target.price_rate_at = effective_at
    if save:
        _save(target)
    return True


def _foreign_amount_for(base_amount, rate, currency, base):
    """The foreign amount that restates ``base_amount`` at ``rate``.

    Its round trip is exact whenever the rate can express the base price at the
    foreign currency's precision, and off by at most one minor unit when it
    cannot (90.00 dinars at 6.85 sits between $13.13 -> 89.94 and
    $13.14 -> 90.01; no dollar amount lands on it). That residue is a rounding
    artifact of a two-decimal price sheet, not a lost reprice: the base price —
    the number the shop actually sells at — is exactly what was typed, so the
    reprice screen can at worst offer the cent back, never the old price.
    """
    nearest = quantize_amount(
        Decimal(base_amount) / Decimal(rate), decimals_for(currency)
    )
    if quantize_amount(nearest * Decimal(rate), decimals_for(base)) != base_amount:
        logger.debug(
            "%s cannot express %s %s at rate %s; price sheet restated to %s",
            currency,
            base_amount,
            base,
            rate,
            nearest,
        )
    return nearest
