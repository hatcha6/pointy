"""The shop's pricing screen «أسعار كروت دفتر»: what it reads and writes.

Rules live in :class:`~apps.integrations.models.IntegrationPriceRule`; this module
turns them into the screen's payloads and validates what the owner sets. Every
refusal is a ``ValidationError`` with an Arabic message (a ``400``).
"""

from __future__ import annotations

from decimal import Decimal, InvalidOperation

from django.db import transaction
from rest_framework.exceptions import ValidationError

from apps.catalog.models import ProductVariant

from . import catalog, pricing_rules, services_mirror, services_options, vouchers
from .models import IntegrationAccount, IntegrationPriceRule as Rule, IntegrationVoucher
from .pricing_rules import money

PROVIDER = catalog.POINTY.key
#: The cost the examples are drawn for: a 20-dinar top-up.
COST_HINT = Decimal("20.00")
PAGE_SIZE = 30
MAX_MARKUP = Decimal("1000")
MODES = (Rule.Mode.COMPANY, Rule.Mode.CUSTOM)

BELOW_COST = "لا يمكن أن يكون السعر أقل مما تدفعه أنت للشركة ({pays})."
BAD_MODE = "اختر «سعر الشركة» أو «سعري»."
BAD_MARKUP = "نسبة الربح غير صحيحة."
NO_ACCOUNT = "خدمات «كروت دفتر» غير مفعّلة في هذا المتجر."


def _account() -> IntegrationAccount:
    account = IntegrationAccount.objects.filter(provider=PROVIDER).first()
    if account is None:
        raise ValidationError({"detail": NO_ACCOUNT})
    return account


def _mode(value) -> str:
    if value not in MODES:
        raise ValidationError({"mode": BAD_MODE})
    return value


def _percent(value) -> Decimal:
    try:
        percent = Decimal(str(value))
    except (InvalidOperation, TypeError):
        raise ValidationError({"markup_percent": BAD_MARKUP}) from None
    if not percent.is_finite() or percent < 0 or percent > MAX_MARKUP:
        raise ValidationError({"markup_percent": BAD_MARKUP})
    return percent.quantize(Decimal("0.01"))


def _text(value) -> str:
    return "" if value is None else format(money(value), "f")


# --- the company's rule, for the examples ----------------------------------------------------
def company_rule(account) -> dict:
    rule = (account.config or {}).get(services_mirror.CONFIG_PRICING)
    rule = rule if isinstance(rule, dict) else {}
    return {
        "fixed_lyd": rule.get("fixed_lyd"),
        "brackets": rule.get("brackets") if isinstance(rule.get("brackets"), list) else [],
        "shop_share_percent": rule.get("shop_share_percent"),
        "round_step": rule.get("round_step"),
    }


def _company_example(rule: dict, cost: Decimal) -> tuple[Decimal, Decimal]:
    """``(shop_pays, company_price)`` for ``cost`` by the company's published margin."""
    try:
        margin = Decimal(str(rule.get("fixed_lyd") or 0))
        floor = Decimal(0)
        for bracket in rule["brackets"]:
            top = bracket.get("up_to_lyd")
            top = Decimal(str(top)) if top not in (None, "") else None
            if cost > floor:
                span = (min(cost, top) if top is not None else cost) - floor
                margin += span * Decimal(str(bracket.get("percent") or 0)) / 100
            if top is None:
                break
            floor = top
        share = Decimal(
            str(
                rule.get("shop_share_percent") if rule.get("shop_share_percent") is not None else 50
            )
        )
        step = Decimal(str(rule.get("round_step") or "0.25"))
        pays = money(cost + margin * (1 - share / 100))
        retail = max(money(pricing_rules.round_up_step(cost + margin, step)), pays)
        return pays, retail
    except (KeyError, TypeError, ArithmeticError, ValueError):
        return cost, cost


def _service_rows(account) -> list[dict]:
    rule = company_rule(account)
    pays, company = _company_example(rule, COST_HINT)
    resolver = pricing_rules.Resolver(account)
    rows = []
    keys = [(card["key"], "") for card in services_mirror.cards(account)]
    keys += sorted(k for k in resolver.services if k[1])
    for key, country in keys:
        found = resolver.services.get((key, country))
        label = _label(key)
        markup = found.markup_percent if found and found.mode == Rule.Mode.CUSTOM else None
        mine = pricing_rules.markup_price(pays, markup) if markup is not None else company
        row = {
            "key": key,
            "label": label,
            "mode": found.mode if found else Rule.Mode.COMPANY,
            "markup_percent": _text(markup) if markup is not None else None,
            "example": {
                "cost_hint": _text(COST_HINT),
                "shop_pays": _text(pays),
                "company_price": _text(company),
                "your_price": _text(mine),
            },
        }
        if country:
            row["country"] = country
        rows.append(row)
    return rows


def _label(key: str) -> str:
    if key == pricing_rules.AIRTIME:
        return "الشحن المباشر"
    word = services_options.TYPE_WORDS.get(key.partition(":")[2], key)
    return f"دفع فواتير {word}"


def read(account=None) -> dict:
    account = account or _account()
    default = Rule.objects.filter(account=account, scope=Rule.Scope.DEFAULT).first()
    return {
        "default_mode": default.mode if default else Rule.Mode.COMPANY,
        "default_markup_percent": _text(default.markup_percent)
        if default and default.markup_percent is not None
        else None,
        "services": _service_rows(account),
        "company_rule": {
            key: value for key, value in company_rule(account).items() if key != "round_step"
        },
    }


@transaction.atomic
def write(data: dict) -> dict:
    account = _account()
    mode = _mode(data.get("default_mode", Rule.Mode.COMPANY))
    markup = _percent(data.get("default_markup_percent")) if mode == Rule.Mode.CUSTOM else None
    Rule.objects.update_or_create(
        account=account,
        scope=Rule.Scope.DEFAULT,
        service_key="",
        country="",
        variant=None,
        defaults={"mode": mode, "markup_percent": markup, "price": None},
    )
    known = {card["key"] for card in services_mirror.cards(account)}
    kept = []
    for entry in data.get("services") or ():
        key = str(entry.get("key") or "")
        country = str(entry.get("country") or "").upper()
        if not (key in known or key == pricing_rules.AIRTIME or key.startswith("bill:")):
            raise ValidationError({"services": "خدمة غير معروفة."})
        row_mode = _mode(entry.get("mode", Rule.Mode.COMPANY))
        row_markup = _percent(entry.get("markup_percent")) if row_mode == Rule.Mode.CUSTOM else None
        Rule.objects.update_or_create(
            account=account,
            scope=Rule.Scope.SERVICE,
            service_key=key,
            country=country,
            variant=None,
            defaults={"mode": row_mode, "markup_percent": row_markup, "price": None},
        )
        kept.append((key, country))
    stale = Rule.objects.filter(account=account, scope=Rule.Scope.SERVICE, variant__isnull=True)
    for rule in stale:
        if (rule.service_key, rule.country) not in kept:
            rule.delete()
    pricing_rules.forget(account)
    _reprice_cards(account)
    return read(account)


# --- cards -------------------------------------------------------------------------------
def _company_card_price(account, voucher) -> Decimal:
    prices = {voucher.code: voucher.suggested_price} if voucher.suggested_price is not None else {}
    return money(account.selling_price(voucher.cost, voucher.code, prices=prices))


def _cards_queryset(account):
    return IntegrationVoucher.objects.filter(account=account, variant__isnull=False).select_related(
        "brand", "variant"
    )


def cards(params) -> dict:
    account = _account()
    queryset = _cards_queryset(account)
    brand = (params.get("brand") or "").strip()
    if brand:
        queryset = queryset.filter(brand__code=brand)
    below = {row.variant_id for row in pricing_rules.below_cost_vouchers(account)}
    if str(params.get("below_cost") or "").lower() in ("1", "true"):
        queryset = queryset.filter(variant_id__in=below)
    search = (params.get("search") or "").strip()
    if search:
        from django.db.models import Q

        queryset = queryset.filter(
            Q(label__icontains=search)
            | Q(brand__name__icontains=search)
            | Q(brand__name_en__icontains=search)
        )
    try:
        page = max(int(params.get("page") or 1), 1)
    except ValueError:
        page = 1
    total = queryset.count()
    chunk = list(
        queryset.order_by("brand__rank", "brand__name", "cost")[
            (page - 1) * PAGE_SIZE : page * PAGE_SIZE
        ]
    )
    resolver = pricing_rules.Resolver(account)
    rows = []
    for voucher in chunk:
        rule = resolver.variants.get(voucher.variant_id)
        custom = rule is not None and rule.mode == Rule.Mode.CUSTOM
        rows.append(
            {
                "variant_id": voucher.variant_id,
                "name": voucher.label,
                "brand": voucher.brand.name,
                "shop_pays": _text(voucher.cost),
                "company_price": _text(_company_card_price(account, voucher)),
                "mode": Rule.Mode.CUSTOM if custom else Rule.Mode.COMPANY,
                "custom_price": _text(rule.price) if custom and rule.price is not None else None,
                # Sold at a loss if it were sold: so it is not (see ``below_cost``).
                "below_cost": voucher.variant_id in below,
            }
        )
    return {
        "count": total,
        # Every card of the shop that is blocked for this reason, whatever the page.
        "below_cost_count": len(below),
        "page": page,
        "page_size": PAGE_SIZE,
        "has_more": page * PAGE_SIZE < total,
        "results": rows,
    }


def _set_card(account, voucher, mode: str, price) -> None:
    if mode == Rule.Mode.CUSTOM:
        if price is None:
            raise ValidationError({"price": BAD_MARKUP})
        price = money(price)
        if price < money(voucher.cost):
            raise ValidationError({"price": BELOW_COST.format(pays=_text(voucher.cost))})
        Rule.objects.update_or_create(
            account=account,
            scope=Rule.Scope.VARIANT,
            variant_id=voucher.variant_id,
            defaults={"mode": mode, "price": price, "markup_percent": None},
        )
    else:
        Rule.objects.update_or_create(
            account=account,
            scope=Rule.Scope.VARIANT,
            variant_id=voucher.variant_id,
            defaults={"mode": Rule.Mode.COMPANY, "price": None, "markup_percent": None},
        )


def _apply(account, vouchers_) -> None:
    pricing_rules.forget(account)
    for voucher in vouchers_:
        price = money(vouchers.voucher_price(account, voucher))
        # A card whose own price is under cost is switched off, and back on once
        # the price is fixed (the sync does the same on its sweep).
        sellable = (
            voucher.brand.is_listed
            and voucher.is_available
            and not pricing_rules.below_cost(account, voucher)
        )
        ProductVariant.objects.filter(pk=voucher.variant_id).update(
            unit_price=price, is_active=sellable
        )


def _reprice_cards(account) -> None:
    _apply(account, _cards_queryset(account))


@transaction.atomic
def set_card(variant_id: int, data: dict) -> dict:
    account = _account()
    voucher = _cards_queryset(account).filter(variant_id=variant_id).first()
    if voucher is None:
        from rest_framework.exceptions import NotFound

        raise NotFound("البطاقة غير موجودة.")
    mode = _mode(data.get("mode"))
    price = None
    if mode == Rule.Mode.CUSTOM:
        try:
            price = Decimal(str(data.get("price")))
        except (InvalidOperation, TypeError):
            raise ValidationError({"price": BAD_MARKUP}) from None
    _set_card(account, voucher, mode, price)
    _apply(account, [voucher])
    row = next(
        r
        for r in cards({"search": voucher.label, "brand": voucher.brand.code})["results"]
        if r["variant_id"] == variant_id
    )
    return row


@transaction.atomic
def bulk_cards(data: dict) -> dict:
    account = _account()
    queryset = _cards_queryset(account)
    ids = data.get("variant_ids")
    if data.get("below_cost"):
        # «استخدام تسعير الشركة» on the alert: every card whose own price fell under cost.
        queryset = queryset.filter(
            variant_id__in=[row.variant_id for row in pricing_rules.below_cost_vouchers(account)]
        )
    elif ids:
        queryset = queryset.filter(variant_id__in=[int(i) for i in ids if str(i).isdigit()])
    elif data.get("brand"):
        queryset = queryset.filter(brand__code=str(data["brand"]))
    else:
        raise ValidationError({"detail": "حدد البطاقات أو العلامة التجارية."})
    mode = _mode(data.get("mode"))
    markup = _percent(data.get("markup_percent")) if mode == Rule.Mode.CUSTOM else None
    found = list(queryset)
    for voucher in found:
        price = pricing_rules.markup_price(voucher.cost, markup) if markup is not None else None
        _set_card(account, voucher, mode, price)
    _apply(account, found)
    return {"updated": len(found)}
