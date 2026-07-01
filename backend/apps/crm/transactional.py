"""Transactional customer SMS: invoice delivery and debt reminders.

Both are ``transactional`` consent-class, so they always send (an invoice or a
debt reminder is not marketing). They reuse the shareable public-invoice link
when the shop's subscription supports it, and fall back to a plain-text summary
otherwise. Idempotency keys keep a double-tap (invoice) or a daily sweep (debt)
from sending twice.
"""

from __future__ import annotations

import logging
from decimal import Decimal

from apps.core.models import ShopSettings
from apps.core.timeutils import business_local_date
from apps.messaging.models import OutboundMessage
from apps.messaging.services import enqueue_message
from apps.sales.public_invoices import public_invoice_url_for_order

logger = logging.getLogger(__name__)

_TRANSACTIONAL = OutboundMessage.ConsentClass.TRANSACTIONAL


class NoRecipientPhone(Exception):
    """The order has no customer phone to send to."""


def _shop_context() -> tuple[str, str]:
    settings = ShopSettings.load()
    name = (getattr(settings, "shop_name", "") or "").strip() or "متجرنا"
    currency = (getattr(settings, "currency_symbol", "") or "").strip()
    return name, currency


def _money(amount) -> str:
    return f"{Decimal(amount):.2f}"


def send_invoice_sms(order, *, actor=None) -> OutboundMessage:
    """Queue an invoice SMS to the order's customer (idempotent per order)."""
    customer = getattr(order, "customer", None)
    phone = (getattr(customer, "phone", "") or "").strip() if customer else ""
    if not phone:
        raise NoRecipientPhone()

    shop_name, currency = _shop_context()
    link = public_invoice_url_for_order(order)
    total = _money(order.total)
    if link:
        body = f"فاتورتك من {shop_name}: الإجمالي {total} {currency}. عرض الفاتورة: {link}"
    else:
        body = (
            f"فاتورتك من {shop_name}: الإجمالي {total} {currency} "
            f"(فاتورة رقم {order.receipt_number})."
        )
    return enqueue_message(
        to=phone,
        body=body,
        consent_class=_TRANSACTIONAL,
        dedup_key=f"invoice:{order.id}",
        source_type="invoice",
        source_id=order.id,
    )


def send_debt_reminder(order, *, now=None) -> OutboundMessage | None:
    """Queue a debt reminder for an open-credit order. Idempotent per shop-local
    day, so the daily sweep reminds at most once. Returns None when there is no
    phone or nothing is owed."""
    customer = getattr(order, "customer", None)
    phone = (getattr(customer, "phone", "") or "").strip() if customer else ""
    if not phone:
        return None
    balance = order.balance_due
    if balance <= 0:
        return None

    shop_name, currency = _shop_context()
    link = public_invoice_url_for_order(order)
    body = (
        f"تذكير من {shop_name}: لديك مبلغ مستحق {_money(balance)} {currency} "
        f"على الفاتورة {order.receipt_number}."
    )
    if link:
        body += f" التفاصيل: {link}"
    day = business_local_date(now).strftime("%Y%m%d")
    return enqueue_message(
        to=phone,
        body=body,
        consent_class=_TRANSACTIONAL,
        dedup_key=f"debt:{order.id}:{day}",
        source_type="debt_reminder",
        source_id=order.id,
    )
