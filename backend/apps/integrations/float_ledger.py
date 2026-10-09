"""The one definition of what a provider float is worth.

A float is money the shop has already handed to a provider and not yet spent.
Four figures, and they are deliberately different things:

``topped_up``
    What the shop has put in — recorded as a :class:`~apps.treasury.models.
    MoneyTransfer` from the cash box or the bank into the float's own account.
    Moving your own money between your own places is not an expense, and the
    treasury model already says so.

``returned``
    What has been taken back out of the float, such as a provider refunding
    part of it into the cash box on the treasury screen. It is its own figure,
    not netted into ``topped_up``: what the shop put in stays what it put in.

``drawn``
    What the provider has actually taken, which is the cost of the top-ups it
    has **performed**. Pointy does not perform them yet, so this only moves
    when reconciliation finds a sale in the provider's own purchase log.

``committed``
    What the shop has sold but the provider has not yet performed. Shown
    beside the balance and never subtracted from it: the money is still in the
    float, and pretending otherwise would understate the float on the exact
    day somebody is deciding whether to top up.

The cost of a recharge reaches the profit report through
``OrderLine.unit_cost``, which the checkout already writes. Nothing here is a
second definition of that — this module answers "how much is left with the
provider", which nothing else answers.
"""

from __future__ import annotations

from decimal import Decimal

from django.db.models import DecimalField, Sum, Value
from django.db.models.functions import Coalesce
from django.utils import timezone

from apps.core.money_dates import money_period

ZERO = Decimal("0.00")
MONEY_PLACES = Decimal("0.01")
_SUM_FIELD = DecimalField(max_digits=14, decimal_places=2)


def _sum(queryset, field="cost"):
    total = queryset.aggregate(
        total=Coalesce(Sum(field), Value(ZERO), output_field=_SUM_FIELD)
    )["total"]
    return (total or ZERO).quantize(MONEY_PLACES)


def drawn(account, *, start=None, end=None) -> Decimal:
    """What the provider has taken from this float, confirmed only.

    With only ``end``, every draw up to that day: a balance is cumulative.
    ``start`` narrows it to a window, which is what a statement needs.
    """
    return _sum(draws(account, start=start, end=end))


def draws(account, *, start=None, end=None):
    """The fulfillments ``drawn`` sums, for a caller that lists them.

    The treasury's drill-down shows these as a float's draw rows. Taking them
    from here is what keeps those rows and the balance's draw line one set.
    """
    from .models import IntegrationFulfillment

    rows = IntegrationFulfillment.objects.filter(
        account=account, status=IntegrationFulfillment.Status.CONFIRMED
    )
    if start is not None or end is not None:
        rows = money_period(rows, start, end)
    return rows


def committed(account) -> Decimal:
    """Sold by the shop, not yet performed by the provider."""
    from .models import IntegrationFulfillment

    return _sum(
        IntegrationFulfillment.objects.filter(
            account=account, status=IntegrationFulfillment.Status.PENDING
        )
    )


def topped_up(account, *, end=None) -> Decimal:
    """What the shop has put into this float."""
    return _transfers(account, side="to_account", end=end)


def returned(account, *, end=None) -> Decimal:
    """What has been taken back out of this float.

    The treasury subtracts it from the float's own account, so this must too.
    Left out, a refund into the cash box made the float sheet overstate the
    float, and the drift alert blamed money that had come home.
    """
    return _transfers(account, side="from_account", end=end)


def _transfers(account, *, side, end):
    from apps.treasury.models import MoneyTransfer

    money_account = account.money_account
    if money_account is None:
        return ZERO
    rows = MoneyTransfer.objects.filter(**{side: money_account})
    if end is not None:
        rows = money_period(rows, None, end)
    return _sum(rows, field="amount")


def expected_balance(account, *, end=None) -> Decimal:
    """What Pointy believes is left with the provider, as of ``end``.

    Opening balance plus top-ups, less what was taken back out and what the
    provider has confirmed taking. That is the arithmetic the treasury does for
    the float's own account, so الخزينة and the float sheet show one number.
    ``end`` defaults to today, the day the treasury states balances for: a
    transfer dated tomorrow is in neither yet.
    Compared against the provider's own reported figure by reconciliation —
    the gap between the two is the whole point of keeping this.
    """
    end = end or timezone.localdate()
    money_account = account.money_account
    opening = money_account.opening_balance if money_account else ZERO
    return (
        Decimal(opening)
        + topped_up(account, end=end)
        - returned(account, end=end)
        - drawn(account, end=end)
    ).quantize(MONEY_PLACES)


def position(account) -> dict:
    """Every float figure at once, for the settings screen and the API.

    All as of today, so the figures add up to the balance beside them.
    """
    today = timezone.localdate()
    return {
        "expected_balance": expected_balance(account, end=today),
        "topped_up": topped_up(account, end=today),
        # Added beside the others. A client that predates it still gets the
        # right expected_balance, and simply does not list the refund.
        "returned": returned(account, end=today),
        "drawn": drawn(account, end=today),
        "committed": committed(account),
        # What the provider itself last said, from the most recent probe.
        "reported_balance": account.balance,
        "reported_at": account.balance_at,
    }


# --- recording a top-up ------------------------------------------------------
# Deliberately NOT a purchase order. A PO buys stock from a supplier and moves
# inventory; topping up a float buys nothing and moves no stock, and forcing it
# through purchasing would invent a phantom product and phantom quantities that
# every stock report would then have to be taught to ignore. What the owner
# actually wants from a PO — "this money went to HD Box, show me cost and
# profit" — is served instead by the transfer below (the money's new location)
# and by OrderLine.unit_cost (its cost when it is spent).

TOP_UP_REASON = "شحن رصيد وكالة"


def ensure_money_account(account):
    """The float's own account in the money position, created on demand."""
    from apps.treasury.models import MoneyAccount

    if account.money_account_id is not None:
        return account.money_account

    money_account = MoneyAccount.objects.create(
        name=_float_account_name(account),
        kind=MoneyAccount.Kind.PROVIDER,
        # Never a default: untagged money must never land in a float.
        is_default=False,
    )
    account.money_account = money_account
    account.save(update_fields=["money_account", "updated_at"])
    return money_account


def source_accounts():
    """Where a top-up can be paid from: the shop's active cash boxes and banks.

    Never a float. One float cannot fund another, and the view refuses it.
    """
    from apps.treasury.models import MoneyAccount

    return MoneyAccount.objects.filter(
        is_active=True,
        kind__in=[MoneyAccount.Kind.CASH, MoneyAccount.Kind.BANK],
    )


def default_source_account():
    """The account a top-up comes out of when the client does not say.

    This is the cash box that untagged cash lands in. Before the float sheet
    asked, no client sent a source, so every top-up was written as money from
    outside the shop. The cash box was never debited, and the shop's money grew
    by every amount it paid a provider.
    """
    from apps.treasury.models import MoneyAccount
    from apps.treasury.position import routed_account

    return routed_account(MoneyAccount.Kind.CASH)


#: The company's own cards' float is the shop's voucher balance in its Daftar
#: wallet: named as the owner knows it, with no login to tell it apart by.
RELAY_FLOAT_NAME = "رصيد كروت دفتر"


def _float_account_name(account) -> str:
    from . import catalog

    spec = catalog.spec_for(account.provider)
    if spec is not None and spec.relay_hosted:
        return RELAY_FLOAT_NAME
    label = account.account_label or account.username or account.provider
    provider = spec.key.upper() if spec else account.provider
    return f"رصيد {provider} — {label}"[:120]


def record_top_up(
    account,
    *,
    amount,
    from_account=None,
    moved_at=None,
    reference: str = "",
    note: str = "",
    user=None,
):
    """Record money the shop paid the provider, as a move between its places.

    ``from_account`` is the cash box or bank the money left. ``None`` records
    the float going up with money from outside the shop. That is accepted,
    because a shop that paid from a pocket should still be able to write it
    down, and a transfer with only one side is a shape the treasury model
    already understands. The treasury counts it as money added to the shop, so
    the API asks for it explicitly (``from_outside``). A source the client left
    out means ``default_source_account()``.
    """
    from apps.treasury.models import MoneyTransfer

    money_account = ensure_money_account(account)
    return MoneyTransfer.objects.create(
        from_account=from_account,
        to_account=money_account,
        amount=amount,
        moved_at=moved_at or MoneyTransfer._meta.get_field("moved_at").get_default(),
        reason=note.strip() or TOP_UP_REASON,
        reference=reference.strip()[:128],
        created_by=user if (user and user.is_authenticated) else None,
    )
