"""The values customer texts carry, written the same way in every one: the
shop's name, money in the shop's currency, a date as the customer writes it."""

from __future__ import annotations

from decimal import Decimal


def _settings(settings):
    if settings is not None:
        return settings
    from apps.core.models import ShopSettings

    return ShopSettings.load()


def shop_name(settings=None) -> str:
    name = (getattr(_settings(settings), "shop_name", "") or "").strip()
    return name or "متجرنا"


def money(amount, settings=None) -> str:
    currency = (getattr(_settings(settings), "currency_symbol", "") or "").strip()
    return f"{Decimal(amount or 0):.2f} {currency}".strip()


def sms_date(value) -> str:
    return f"{value:%Y/%m/%d}"


def days_phrase(days: int) -> str:
    """How long something has waited, as Arabic counts days: يوم، يومين، 3 أيام،
    11 يومًا."""
    days = max(int(days or 0), 0)
    if days == 1:
        return "يوم"
    if days == 2:
        return "يومين"
    if 3 <= days <= 10:
        return f"{days} أيام"
    return f"{days} يومًا"
