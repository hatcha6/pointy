"""Transactional customer SMS: invoice delivery and debt reminders.

Both are ``transactional`` consent-class, so they always send (an invoice or a
debt reminder is not marketing). Each has two approved templates: one carrying
the shareable public-invoice link, used when the shop's subscription supports
it, and one without. Idempotency keys keep a double-tap (invoice) or a daily
sweep (debt) from sending twice.
"""

from __future__ import annotations

import logging
from decimal import Decimal

from apps.core.models import ShopSettings
from apps.core.timeutils import business_local_date
from apps.messaging.models import OutboundMessage
from apps.messaging.services import enqueue_message
from apps.messaging.sms_templates import sms_template
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


def _amount(amount, currency: str) -> str:
    return f"{_money(amount)} {currency}".strip()


def send_invoice_sms(order, *, actor=None) -> OutboundMessage:
    """Queue an invoice SMS to the order's customer (idempotent per order)."""
    customer = getattr(order, "customer", None)
    phone = (getattr(customer, "phone", "") or "").strip() if customer else ""
    if not phone:
        raise NoRecipientPhone()

    shop_name, currency = _shop_context()
    link = public_invoice_url_for_order(order)
    values = (shop_name, order.receipt_number, _amount(order.total, currency))
    if link:
        template = sms_template("invoice_link", *values, link)
    else:
        template = sms_template("invoice", *values)
    return enqueue_message(
        to=phone,
        template=template,
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
    if getattr(order, "sale_type", None) == "account_entry":
        # A debt written onto the account — an opening balance, an adjustment —
        # is not an invoice, and has no invoice page to link to. Calling it one
        # would send the customer looking for a sale that never happened.
        link = None
        reference = f"رصيد مسجّل على حسابك (مرجع {order.receipt_number})"
    else:
        link = public_invoice_url_for_order(order)
        reference = f"الفاتورة رقم {order.receipt_number}"
    due_date = getattr(order, "due_date", None)
    if due_date is not None:
        reference += f" المستحقة بتاريخ {due_date:%Y-%m-%d}"
    values = (shop_name, _amount(balance, currency), reference)
    if link:
        template = sms_template("debt_reminder_link", *values, link)
    else:
        template = sms_template("debt_reminder", *values)
    day = business_local_date(now).strftime("%Y%m%d")
    return enqueue_message(
        to=phone,
        template=template,
        consent_class=_TRANSACTIONAL,
        dedup_key=f"debt:{order.id}:{day}",
        source_type="debt_reminder",
        source_id=order.id,
    )
