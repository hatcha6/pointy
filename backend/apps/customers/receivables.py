"""What a customer owes, and how much more they may owe.

The receivable itself was already stated in three places — the customer sales
summary, the collect-debt service and the AI receivables tool — each summing
``balance_due`` over ``open_credit()`` orders. Adding a fourth caller (the
credit gate at checkout) is what made it worth stating once: a ceiling that
disagreed with the balance printed on the customer's own screen would be a
refusal nobody could explain to a shopkeeper standing at the till.

The limit is deliberately a *policy* rather than only a number. A shop-wide
default with no per-customer escape hatch cannot express the wholesale buyer
everyone trusts; a per-customer number with no inheritance means editing every
contact the day the shop's appetite for risk changes. So a customer either
follows the shop, is exempt from it, or carries its own ceiling.

``None`` means "no limit" everywhere in this module. ``Decimal("0")`` means the
opposite — no credit at all — and the two must never be conflated, because one
of them is what every shop had before this feature existed.
"""

from dataclasses import dataclass
from decimal import Decimal

MONEY = Decimal("0.01")


def _money(value: Decimal) -> Decimal:
    return Decimal(value).quantize(MONEY)


def outstanding_balance(customer, exclude_order_id=None) -> Decimal:
    """The customer's FULL open debt, across every session and cashier.

    Scoped to the customer, never to the register session that happens to be
    asking: a cashier deciding whether one more آجل invoice is safe must see
    what the shop is owed, not what they personally issued.

    ``exclude_order_id`` leaves one invoice out. The credit gate runs after the
    order rows exist (that is where the total is known), and an آجل invoice is
    OPEN from creation — so without this the sale being judged counts itself as
    debt the customer already had, and every credit sale is measured at twice
    its size.
    """
    from apps.sales.models import Order

    orders = Order.objects.open_credit().filter(customer=customer)
    if exclude_order_id is not None:
        orders = orders.exclude(pk=exclude_order_id)
    return _money(
        sum(
            (order.balance_due for order in orders.with_balance_relations()),
            Decimal("0.00"),
        )
    )


def effective_credit_limit(customer, settings=None) -> Decimal | None:
    """The ceiling that actually applies to this customer.

    Returns ``None`` for "no limit". Resolution order is the customer's own
    policy first, the shop default second.
    """
    from apps.customers.models import Customer

    policy = getattr(customer, "credit_limit_policy", Customer.CreditLimitPolicy.SHOP_DEFAULT)
    if policy == Customer.CreditLimitPolicy.UNLIMITED:
        return None
    if policy == Customer.CreditLimitPolicy.CUSTOM:
        # ``clean()`` refuses a custom policy with no number, so a null here is
        # a row that predates the validation rather than a supported state.
        if customer.credit_limit is None:
            return None
        return _money(customer.credit_limit)

    if settings is None:
        from apps.core.models import ShopSettings

        settings = ShopSettings.load()
    shop_default = settings.default_customer_credit_limit
    return None if shop_default is None else _money(shop_default)


@dataclass(frozen=True)
class CreditAssessment:
    """Whether this customer may take on ``new_debt`` more."""

    allowed: bool
    limit: Decimal | None
    outstanding: Decimal
    new_debt: Decimal

    @property
    def available(self) -> Decimal | None:
        """Head-room left under the limit; ``None`` when there is no limit.

        Never negative: a customer already over their ceiling (the limit was
        lowered under them, or a refund reversed a payment) has zero available,
        not a negative allowance to be added to the next sale.
        """
        if self.limit is None:
            return None
        return max(self.limit - self.outstanding, Decimal("0.00")).quantize(MONEY)

    @property
    def projected(self) -> Decimal:
        return _money(self.outstanding + self.new_debt)


def assess_credit(
    customer, new_debt: Decimal, settings=None, exclude_order_id=None
) -> CreditAssessment:
    """Can ``customer`` owe ``new_debt`` more than they already do?

    ``new_debt`` is what the sale actually puts on account — the total less any
    down-payment taken at the till — not the invoice total. A 500 sale with 500
    handed over adds nothing to the receivable and must never be refused.
    """
    limit = effective_credit_limit(customer, settings=settings)
    outstanding = outstanding_balance(customer, exclude_order_id=exclude_order_id)
    new_debt = _money(max(Decimal(new_debt), Decimal("0.00")))
    if limit is None:
        return CreditAssessment(True, None, outstanding, new_debt)
    return CreditAssessment(
        allowed=outstanding + new_debt <= limit,
        limit=limit,
        outstanding=outstanding,
        new_debt=new_debt,
    )
