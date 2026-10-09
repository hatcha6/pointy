"""The till's «كروت دفتر» menu: the company's own shelf, in the company's order.

Selecting the «كروت دفتر» chip shows this in place of the product grid: our
category tabs, then a gift-card styled card per brand, then the brand's cards
by region and denomination. It is read from the shop's own mirror of the
shelf (:mod:`.vouchers`) — never from the relay — so opening it costs no round
trip, and its strings are the relay's (Arabic already).

Each brand carries its system product exactly as the catalog list sends it
(``catalog.views.catalog_list_payloads``): a card goes into the cart as that
product's variant, priced and checked at checkout like any other line, so the
menu is only ever a way of choosing one.

What a reader may see follows the rest of the till: a card's ``cost`` is the
shop's own figure and goes only to the reporting roles (``with_cost``);
everybody gets ``exceeds_float``, the one thing the till needed it for.
"""

from __future__ import annotations

import base64
from decimal import Decimal

from . import catalog, pricing_rules, services_menu, services_mirror, switches, vouchers
from .models import (
    IntegrationAccount,
    IntegrationVoucher,
    IntegrationVoucherBrand,
    IntegrationVoucherCountry,
)
from .providers.base import ERROR_NOT_CONFIGURED, ERROR_SWITCHED_OFF, ERROR_UNAVAILABLE
from .serializers import exceeds_float

#: The provider whose shelf this menu is.
PROVIDER = catalog.POINTY.key


def menu_payload(request, *, with_cost: bool) -> dict:
    """The whole menu, or ``available: false`` with why the shop cannot sell."""
    payload = {
        "available": False,
        "provider": PROVIDER,
        "error_code": "",
        # The relay buys from its test supplier: nothing sold here is real.
        "test_mode": False,
        # Whether this user may open «أسعار كروت دفتر».
        "can_edit_pricing": request.user.has_perms(("integrations.manage_integrations",)),
        "balance": None,
        "balance_at": None,
        "categories": [],
        "countries": [],
        "brands": [],
        # The company's direct top-up and bill payments, one entry per card the
        # till can draw (see ``services_menu.menu_services``); only the ones
        # that can be sold are listed.
        "services": [],
    }
    spec = catalog.spec_for(PROVIDER)
    if spec is None or not spec.is_available:
        return {**payload, "error_code": ERROR_UNAVAILABLE}
    if switches.is_switched_off(PROVIDER):
        return {**payload, "error_code": ERROR_SWITCHED_OFF}
    account = IntegrationAccount.objects.filter(provider=PROVIDER).first()
    if account is None or not account.is_active or not account.is_configured:
        return {**payload, "error_code": ERROR_NOT_CONFIGURED}
    payload["balance"] = _money(account.balance)
    payload["balance_at"] = account.balance_at.isoformat() if account.balance_at else None
    payload["test_mode"] = services_mirror.in_test_mode(account)
    # Before the cards: the services do not depend on the shelf. A relay with
    # no card wholesaler set up can still sell top-ups and bills.
    payload["services"] = services_menu.menu_services(account)
    if (account.config or {}).get(vouchers.CONFIG_LISTING_ERROR) == ERROR_UNAVAILABLE:
        # The relay sells no cards right now (its wholesaler is not set up):
        # what the mirror last held cannot be bought. If it still sells
        # top-ups and bills the menu is not "unavailable" — it is a menu with
        # no brands, which is what the till draws it as.
        if payload["services"]:
            return {**payload, "available": True}
        return {**payload, "error_code": ERROR_UNAVAILABLE}

    brands = list(
        IntegrationVoucherBrand.objects.filter(
            account=account, is_listed=True, product__isnull=False
        )
        .defer("print_logo")
        .order_by("rank", "name", "code")
    )
    cards: dict[int, list] = {}
    for voucher in IntegrationVoucher.objects.filter(
        account=account,
        brand_id__in=[brand.pk for brand in brands],
        is_listed=True,
        variant__isnull=False,
    ).order_by("rank", "code"):
        cards.setdefault(voucher.brand_id, []).append(voucher)
    brands = [brand for brand in brands if cards.get(brand.pk)]
    countries = list(IntegrationVoucherCountry.objects.filter(account=account))
    names = {country.code: country.name for country in countries}
    products = _products(request, brands)

    payload["available"] = True
    payload["categories"] = _categories(brands)
    used = {voucher.country for rows in cards.values() for voucher in rows if voucher.country}
    payload["countries"] = [
        {
            "code": country.code,
            "name": country.name,
            "flag": base64.b64encode(bytes(country.flag)).decode("ascii") if country.flag else None,
        }
        for country in countries
        if country.code in used
    ]
    payload["brands"] = [
        _brand_payload(
            account,
            brand,
            cards[brand.pk],
            product=products.get(brand.product_id),
            names=names,
            with_cost=with_cost,
        )
        for brand in brands
    ]
    return payload


def _products(request, brands) -> dict:
    from apps.catalog.views import catalog_list_payloads

    return catalog_list_payloads(request, [brand.product_id for brand in brands])


def _categories(brands) -> list[dict]:
    """Our categories that hold a brand on the menu, in our order."""
    seen = {}
    for brand in brands:
        if brand.category_key and brand.category_key not in seen:
            seen[brand.category_key] = brand
    ordered = sorted(seen.values(), key=lambda brand: (brand.category_rank, brand.category_key))
    return [
        {"key": brand.category_key, "name": brand.category_name or brand.category_key}
        for brand in ordered
    ]


def _brand_payload(account, brand, rows, *, product, names, with_cost) -> dict:
    return {
        "key": brand.code,
        "name": brand.name,
        # Other names a cashier may type («Visa» for the prepaid Mastercard).
        "aliases": [str(alias) for alias in (brand.aliases or []) if str(alias).strip()],
        "category": brand.category_key,
        "featured": brand.featured,
        "badge": brand.badge,
        "has_promo": any(voucher.has_promo for voucher in rows),
        "redeem_hint": brand.redeem_hint,
        "product": product,
        "items": [
            _card_payload(account, brand, voucher, names=names, with_cost=with_cost)
            for voucher in rows
        ],
    }


def _card_payload(account, brand, voucher, *, names, with_cost) -> dict:
    price = vouchers.voucher_price(account, voucher)
    card = {
        "variant_id": voucher.variant_id,
        "key": voucher.code,
        "label": voucher.label,
        "name": vouchers.card_name(voucher, names),
        "country": voucher.country,
        "face_value": _plain(voucher.face_amount),
        "face_currency": voucher.face_currency,
        "price": _money(price),
        # What it sells for without the promotion, struck through beside a
        # promotional price; the price itself when nothing is running.
        "regular_price": _money(
            voucher.regular_price if voucher.regular_price is not None else price
        ),
        "badge": voucher.badge,
        "promo_ends_at": voucher.promo_ends_at.isoformat() if voucher.promo_ends_at else None,
        "available": brand.is_listed
        and voucher.is_available
        and not pricing_rules.below_cost(account, voucher),
        "exceeds_float": exceeds_float(voucher.cost, account),
    }
    if with_cost:
        card["cost"] = _money(voucher.cost)
    return card


def _money(value) -> str | None:
    if value is None:
        return None
    return f"{Decimal(value):.2f}"


def _plain(value) -> str:
    """``10`` for 10.000, ``2.5`` for 2.500: a face value as it is written."""
    if value is None:
        return ""
    return format(Decimal(value).normalize(), "f")
