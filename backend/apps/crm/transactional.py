"""Transactional customer SMS about sales and money.

Invoice and quotation delivery and the debt reminder (each with a twin that
carries the shareable public-invoice link, when the shop's subscription supports
it), the balance on an account, and the texts that go out by themselves when
money moves — a credit sale, a payment, a return, a new due date — each when
the shop has it switched on (apps.messaging.automation).

All are ``transactional`` consent-class, so they always send (none is
marketing). Idempotency keys keep a double-tap, a retried request or a daily
sweep from sending twice.
"""

from __future__ import annotations

import logging
from decimal import Decimal

from apps.core.models import ShopSettings
from apps.core.timeutils import business_local_date
from apps.messaging.models import OutboundMessage
from apps.messaging.automation import send_automatic
from apps.messaging.services import enqueue_message
from apps.messaging.shop_values import money, shop_name, sms_date
from apps.messaging.sms_templates import sms_template
from apps.sales.models import Order
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


def _validity(order) -> str:
    valid_until = getattr(order, "valid_until", None)
    if valid_until is None:
        return "دون تاريخ انتهاء"
    return f"ساري حتى {sms_date(valid_until)}"


def send_invoice_sms(order, *, actor=None) -> OutboundMessage:
    """Queue an invoice SMS to the order's customer (idempotent per order). A
    quotation goes out as one: an offer, with how long it holds — never as a
    "thank you for shopping"."""
    customer = getattr(order, "customer", None)
    phone = (getattr(customer, "phone", "") or "").strip() if customer else ""
    if not phone:
        raise NoRecipientPhone()

    shop_name, currency = _shop_context()
    # An account entry has no invoice page: the public page refuses it.
    link = None if order.sale_type == Order.SaleType.ACCOUNT_ENTRY else public_invoice_url_for_order(order)
    values = (shop_name, order.receipt_number, _amount(order.total, currency))
    if order.sale_type == Order.SaleType.QUOTATION:
        values += (_validity(order),)
        kind = "quotation"
    else:
        kind = "invoice"
    if link:
        template = sms_template(f"{kind}_link", *values, link)
    else:
        template = sms_template(kind, *values)
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


def _customer_phone(customer) -> str:
    return (getattr(customer, "phone", "") or "").strip() if customer is not None else ""


def _due_phrase(order) -> str:
    due_date = getattr(order, "due_date", None)
    if due_date is None:
        return "دون موعد استحقاق"
    return f"تستحق في {sms_date(due_date)}"


def notify_credit_invoice(order) -> None:
    """A credit (آجل) sale: what is left on it and when it falls due — the
    customer's own record of the debt, when the shop has it on."""
    customer = getattr(order, "customer", None)
    if order.sale_type != Order.SaleType.CREDIT or customer is None:
        return
    balance = order.balance_due
    if balance <= 0:
        return
    send_automatic(
        "credit_invoice",
        shop_name(),
        order.receipt_number,
        money(balance),
        _due_phrase(order),
        to=_customer_phone(customer),
        customer=customer,
        dedup_key=f"credit_invoice:{order.pk}",
        source_type="credit_invoice",
        source_id=order.pk,
    )


def notify_payment_received(customer, amount, *, reference) -> None:
    """A receipt for a payment on the customer's debt, with what the account
    still owes after it. ``reference`` keys it (the payment, or the first of an
    account collection's), so a retried request never texts twice."""
    if customer is None or not amount or amount <= 0 or not _customer_phone(customer):
        return
    from apps.customers.receivables import outstanding_balance
    from apps.messaging.automation import auto_sms_enabled

    # The account's balance is a query of its own: only for a text that goes.
    if not auto_sms_enabled("payment_received"):
        return
    send_automatic(
        "payment_received",
        shop_name(),
        money(amount),
        money(outstanding_balance(customer)),
        to=_customer_phone(customer),
        customer=customer,
        dedup_key=f"payment_received:{reference}",
        source_type="payment_received",
        source_id=reference,
    )


def notify_due_date_changed(order) -> None:
    """A credit invoice's due date moved: the new date and what is left."""
    customer = getattr(order, "customer", None)
    if customer is None or order.due_date is None or order.balance_due <= 0:
        return
    send_automatic(
        "due_date_changed",
        shop_name(),
        order.receipt_number,
        sms_date(order.due_date),
        money(order.balance_due),
        to=_customer_phone(customer),
        customer=customer,
        dedup_key=f"due_date_changed:{order.pk}:{order.due_date:%Y%m%d}",
        source_type="due_date_changed",
        source_id=order.pk,
    )


def notify_refund_issued(order, amount, *, reference) -> None:
    """A return recorded on the customer's invoice: everything given back in
    their name reaches their phone."""
    customer = getattr(order, "customer", None)
    if customer is None or not amount or amount <= 0:
        return
    send_automatic(
        "refund_issued",
        shop_name(),
        money(amount),
        order.receipt_number,
        to=_customer_phone(customer),
        customer=customer,
        dedup_key=f"refund_issued:{reference}",
        source_type="refund_issued",
        source_id=reference,
    )


class NothingOwed(Exception):
    """The customer owes nothing: there is no balance to text."""


def send_account_balance_sms(customer, *, now=None) -> OutboundMessage:
    """Text the customer what their account owes today (sent by hand from the
    customer's page). One per customer per day: a second tap returns the first."""
    from apps.customers.receivables import outstanding_balance

    phone = _customer_phone(customer)
    if not phone:
        raise NoRecipientPhone()
    owed = outstanding_balance(customer)
    if owed <= 0:
        raise NothingOwed()
    today = business_local_date(now)
    return enqueue_message(
        to=phone,
        template=sms_template("account_balance", shop_name(), sms_date(today), money(owed)),
        consent_class=_TRANSACTIONAL,
        dedup_key=f"account_balance:{customer.pk}:{today:%Y%m%d}",
        source_type="account_balance",
        source_id=customer.pk,
    )


def notify_warranties(order) -> None:
    """A sale of serial-numbered stock under warranty: the customer gets each
    article's number and the day its cover ends, when the shop has it on."""
    from apps.messaging.automation import auto_sms_enabled

    customer = getattr(order, "customer", None)
    if customer is None or not _customer_phone(customer) or not auto_sms_enabled("warranty_registered"):
        return
    from apps.inventory.models import StockUnit

    units = (
        StockUnit.objects.filter(sold_order_line__order=order, warranty_expires_on__isnull=False)
        .select_related("variant__product")
        .order_by("pk")
    )
    for unit in units:
        send_automatic(
            "warranty_registered",
            shop_name(),
            unit.variant.full_name,
            unit.code,
            sms_date(unit.warranty_expires_on),
            to=_customer_phone(customer),
            customer=customer,
            dedup_key=f"warranty_registered:{unit.pk}:{order.pk}",
            source_type="warranty_registered",
            source_id=unit.pk,
        )

