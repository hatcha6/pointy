"""Read-only staff SMS commands.

A number on the [StaffCommandNumber] allow-list can text a keyword and get an
answer back — today's sales, outstanding debt, or a help list. Deliberately
read-only: an SMS can never *change* shop data, only query it.
"""

from __future__ import annotations

import re
import unicodedata
from decimal import Decimal

from django.db.models import Sum
from django.utils import timezone

from apps.core.models import ShopSettings
from apps.messaging.models import OutboundMessage
from apps.messaging.services import enqueue_message

from .models import StaffCommandNumber

_TATWEEL = "ـ"
_PUNCT = re.compile(r"[^\w]+", re.UNICODE)

_SALES_WORDS = {"sales", "مبيعات"}
_DEBT_WORDS = {"debt", "ديون", "الديون"}
_HELP_WORDS = {"help", "مساعدة"}


def _first_token(body: str) -> str:
    text = "".join(
        ch
        for ch in unicodedata.normalize("NFKD", (body or "").strip().lower())
        if unicodedata.combining(ch) == 0 and ch != _TATWEEL
    )
    text = _PUNCT.sub(" ", text).strip()
    tokens = text.split()
    return tokens[0] if tokens else ""


def is_staff_number(normalized_phone: str) -> bool:
    if not normalized_phone:
        return False
    return StaffCommandNumber.objects.filter(
        phone=normalized_phone, is_active=True
    ).exists()


def parse_staff_command(body: str):
    token = _first_token(body)
    if token in _SALES_WORDS:
        return "sales"
    if token in _DEBT_WORDS:
        return "debt"
    if token in _HELP_WORDS:
        return "help"
    return None


def _currency() -> str:
    return (getattr(ShopSettings.load(), "currency_symbol", "") or "").strip()


def _sales_today() -> Decimal:
    from apps.sales.models import Order

    today = timezone.now().date()
    total = (
        Order.objects.committed_sales()
        .filter(created_at__date=today)
        .aggregate(total=Sum("total"))["total"]
    )
    return total or Decimal("0")


def _outstanding_debt() -> Decimal:
    from apps.sales.models import Order

    total = Decimal("0")
    # Prefetch so balance_due (summed in Python) doesn't N+1 per order.
    # Every open debt, including the ones written onto customers' accounts
    # (an opening balance, an adjustment) rather than invoiced.
    for order in Order.objects.open_receivables().with_balance_relations():
        total += order.balance_due
    return total


def handle_staff_command(inbound, command) -> None:
    currency = _currency()
    if command == "sales":
        body = f"مبيعات اليوم: {_sales_today():.2f} {currency}"
    elif command == "debt":
        body = f"إجمالي الديون المستحقة: {_outstanding_debt():.2f} {currency}"
    else:
        body = "الأوامر المتاحة: SALES (مبيعات اليوم)، DEBT (الديون المستحقة)."
    enqueue_message(
        to=inbound.from_phone or inbound.from_phone_raw,
        body=body,
        consent_class=OutboundMessage.ConsentClass.TRANSACTIONAL,
        source_type="staff_command",
        source_id=inbound.id,
    )
