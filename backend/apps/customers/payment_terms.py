"""When a credit invoice falls due, and who decides that.

A ceiling without a clock is half a credit policy. The shop could already say
how much a customer may owe (``apps.customers.receivables``) and could not say
by when — so nothing was ever late, the aging report had to age from the
invoice date and say so, and the debt reminder had nothing to wait for.

This module is the missing half, and it is deliberately shaped like the other
one: a shop-wide default, a per-customer policy that can follow it, opt out of
it, or replace it, and one function every caller goes through. A shop that
changes its mind about terms edits one number, not every contact.

**What was refused.** ERPNext models this as a Payment Terms Template holding
many Payment Terms, each with an ``invoice_portion``, so one invoice can fall
due in instalments — 30% now, 70% at month end — and it carries a Payment
Schedule child table on every document to track them. That is real, and it is
not this market: an آجل customer runs an open tab and pays it down when they
have cash, which the payment rows against the invoice already express. One due
date per invoice, no schedule table.

**What was kept.** ERPNext's two useful bases (``erpnext/accounts/party.py``,
``get_due_date_from_template``): plain days after the invoice, and days after
the *end of the invoice month* — نهاية الشهر, which wholesale buyers here ask
for by name and which no count of days can express. Also its floor: a computed
due date is never before the invoice date.

``days == 0`` means due on the day it is issued. It is a real answer, not a
missing one, and it is what a shop that has never configured terms gets — which
is exactly how an invoice with no due date behaves today.
"""

from calendar import monthrange
from dataclasses import dataclass
from datetime import date, timedelta

from django.db import models


class PaymentTermsBasis(models.TextChoices):
    """What the credit days are counted from."""

    #: ``invoice_date + days``. The common case: "بعد 30 يوم".
    NET_DAYS = "net_days", "Days after the invoice"
    #: ``last day of the invoice's month + days``. Everything bought in a month
    #: falls due together, which is how a shop billing a regular buyer monthly
    #: actually thinks — "نهاية الشهر".
    END_OF_MONTH = "end_of_month", "Days after the end of the invoice month"


#: Ceiling on credit days. Not a business rule so much as a typo guard: a shop
#: meaning 30 and typing 300 should be told, and no real term is longer than
#: two years. Mirrors the spirit of the purchase cost guard.
MAX_CREDIT_DAYS = 730


def _end_of_month(day: date) -> date:
    return day.replace(day=monthrange(day.year, day.month)[1])


@dataclass(frozen=True)
class PaymentTerms:
    """The terms that actually apply to one customer, and where they came from.

    ``source`` is carried so the UI can say *why* a date was proposed. A
    cashier who sees a due date they did not type will trust it exactly as far
    as they can tell where it came from.
    """

    basis: str
    days: int
    source: str  # "customer" | "shop"

    @property
    def is_immediate(self) -> bool:
        """True when an invoice on these terms is due the day it is issued."""
        return self.basis == PaymentTermsBasis.NET_DAYS and self.days == 0

    def due_date_for(self, invoice_date: date) -> date:
        """The day an invoice issued on ``invoice_date`` falls due.

        Never earlier than the invoice itself. ERPNext applies the same floor
        (``get_due_date``), and it matters here for one reason: END_OF_MONTH
        with 0 days on the last day of a month lands back on the invoice date,
        and any negative drift would make an invoice born overdue.
        """
        if self.basis == PaymentTermsBasis.END_OF_MONTH:
            due = _end_of_month(invoice_date) + timedelta(days=self.days)
        else:
            due = invoice_date + timedelta(days=self.days)
        return max(due, invoice_date)


def shop_payment_terms(settings=None) -> PaymentTerms:
    """The shop-wide default terms."""
    if settings is None:
        from apps.core.models import ShopSettings

        settings = ShopSettings.load()
    return PaymentTerms(
        basis=settings.default_payment_terms_basis or PaymentTermsBasis.NET_DAYS,
        days=int(settings.default_payment_terms_days or 0),
        source="shop",
    )


def resolve_payment_terms(customer, settings=None) -> PaymentTerms:
    """The terms that apply to ``customer`` — their own, or the shop's.

    A missing customer resolves to the shop's terms rather than to nothing: a
    walk-in آجل sale (allowed when ``require_customer_for_credit`` is off) is
    still credit, and still falls due when the shop says credit falls due.
    """
    from apps.customers.models import Customer

    if customer is None:
        return shop_payment_terms(settings)

    policy = getattr(
        customer, "payment_terms_policy", Customer.PaymentTermsPolicy.SHOP_DEFAULT
    )
    if policy == Customer.PaymentTermsPolicy.IMMEDIATE:
        return PaymentTerms(basis=PaymentTermsBasis.NET_DAYS, days=0, source="customer")
    if policy == Customer.PaymentTermsPolicy.CUSTOM:
        # ``clean()`` refuses a custom policy with no day count, so a null here
        # is a row that predates the validation rather than a supported state —
        # the same reading ``effective_credit_limit`` gives its own null.
        if customer.payment_terms_days is None:
            return shop_payment_terms(settings)
        return PaymentTerms(
            basis=customer.payment_terms_basis or PaymentTermsBasis.NET_DAYS,
            days=int(customer.payment_terms_days),
            source="customer",
        )
    return shop_payment_terms(settings)


def resolve_due_date(customer, invoice_date: date, settings=None) -> date:
    """When a credit invoice raised today for ``customer`` falls due.

    Always a date, never ``None``. A null ``Order.due_date`` means "no terms
    were recorded", which the reminder sweep and the aging report both read as
    *due now* — so returning null for a shop on zero-day terms would say the
    same thing in a second, weaker way. One meaning, one representation.
    """
    return resolve_payment_terms(customer, settings=settings).due_date_for(invoice_date)
