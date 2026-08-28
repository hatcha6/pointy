"""What Pointy thinks the shop should have, and where.

The balance of an account is *derived*, never posted. Every money event already
exists somewhere — a ``Payment`` row, a drawer movement, an ``Expense``, a
``SupplierPayment``, a paid ``PayrollRun`` — and this module reads them once,
routes each to the account its payment method implies, and adds the two things
the events cannot know: the account's opening balance and the transfers the
shop makes between its own accounts.

Two traps this module exists to avoid, both of which have bitten this codebase
before:

**Double counting.** A refund is written as a *negative* ``Payment`` row per
original tender (``sales.services.record_adjustment``), so summing
``Payment.amount`` already nets refunds out — subtracting
``OrderAdjustment.cash_amount`` on top would deduct every refund twice. In the
same spirit, a drawer pay-out that paid an expense or a POS cash purchase is
also an ``Expense`` / ``SupplierPayment`` row, so only *standalone* pay-outs are
counted here — the rule ``expenses.services`` already follows.

**Silent assumptions.** Two flows have no payment method in the data at all:
payroll and payment-processor commissions. Rather than hide the guess, both are
returned as their own named components, so the owner sees the assumption in the
breakdown and can correct reality with a transfer instead of arguing with a
total they cannot see inside.
"""

from decimal import Decimal

from django.db.models import DecimalField, Q, Sum, Value
from django.utils import timezone
from django.db.models.functions import Coalesce

from apps.core.money_dates import day_range_end, day_range_start
from apps.expenses.models import Expense
from apps.payments.models import Payment
from apps.purchasing.models import SupplierPayment
from apps.sales.models import RegisterCashMovement

from .models import MoneyAccount, MoneyCount, MoneyTransfer

MONEY_FIELD = DecimalField(max_digits=14, decimal_places=2)
MONEY_PLACES = Decimal("0.01")
ZERO = Decimal("0.00")

# Distinguishes "caller passed no batched count" from "this account has none".
_UNSET = object()

# Stable component codes. The frontend maps these to Arabic labels, so they are
# part of the API contract — add, don't rename.
COMPONENT_OPENING = "opening"
COMPONENT_SALES = "sales"
COMPONENT_DRAWER_IN = "drawer_in"
COMPONENT_DRAWER_OUT = "drawer_out"
COMPONENT_EXPENSES = "expenses"
COMPONENT_SUPPLIERS = "suppliers"
COMPONENT_PAYROLL = "payroll"
COMPONENT_COMMISSION = "commission"
COMPONENT_TRANSFER_IN = "transfer_in"
COMPONENT_TRANSFER_OUT = "transfer_out"

# Which payment methods land in which kind of account. Every derived flow is
# routed by method, because no money row carries an account of its own yet.
CASH_METHODS = ("cash",)
BANK_METHODS = ("card", "transfer", "bank_transfer")

# Supplier payment methods that move no money through an account we can name.
# A credit note is a promise, not a payment. ``refund`` is money coming back
# from the supplier, but nothing in the codebase writes that method today and
# it carries no hint of which account received it — so it is left out rather
# than guessed into the wrong box. Both are excluded from every direction.
NON_CASH_SUPPLIER_METHODS = (
    SupplierPayment.Method.SUPPLIER_CREDIT,
    SupplierPayment.Method.REFUND,
)


def _sum(queryset, field="amount"):
    return queryset.aggregate(
        total=Coalesce(Sum(field), Value(ZERO), output_field=MONEY_FIELD),
    )["total"] or ZERO


def _component(code, amount, *, direction):
    """One named line of the arithmetic behind a balance.

    ``direction`` is what the line does to the balance (``in``/``out``);
    ``amount`` is always the signed contribution, so the components sum to the
    balance without the caller re-deciding any signs.
    """
    return {
        "code": code,
        "amount": Decimal(amount).quantize(MONEY_PLACES),
        "direction": direction,
    }


def _cash_components(*, start, end):
    """The money that moves through a cash box."""
    start_dt, end_dt = day_range_start(start), day_range_end(end)

    # Signed: refunds are negative Payment rows, so this is already net.
    sales = _sum(
        Payment.objects.filter(
            method=Payment.Method.CASH,
            paid_at__gte=start_dt,
            paid_at__lt=end_dt,
        )
    )
    drawer_in = _sum(
        RegisterCashMovement.objects.filter(
            movement_type=RegisterCashMovement.MovementType.PAY_IN,
            created_at__gte=start_dt,
            created_at__lt=end_dt,
        )
    )
    # Standalone pay-outs only — one that paid an expense or a POS cash
    # purchase is already counted as that expense / supplier payment.
    drawer_out = _sum(
        RegisterCashMovement.objects.filter(
            movement_type=RegisterCashMovement.MovementType.PAY_OUT,
            created_at__gte=start_dt,
            created_at__lt=end_dt,
            expense__isnull=True,
            supplier_payment__isnull=True,
        )
    )
    expenses = _sum(
        Expense.objects.filter(
            payment_method=Expense.PaymentMethod.CASH,
            spent_at__gte=start,
            spent_at__lte=end,
        )
    )
    suppliers = _supplier_outflow(CASH_METHODS, start_dt, end_dt)
    payroll = _payroll_outflow(start, end)

    return [
        _component(COMPONENT_SALES, sales, direction="in"),
        _component(COMPONENT_DRAWER_IN, drawer_in, direction="in"),
        _component(COMPONENT_DRAWER_OUT, -drawer_out, direction="out"),
        _component(COMPONENT_EXPENSES, -expenses, direction="out"),
        _component(COMPONENT_SUPPLIERS, -suppliers, direction="out"),
        _component(COMPONENT_PAYROLL, -payroll, direction="out"),
    ]


def _bank_components(*, start, end):
    """The money that moves through a bank account."""
    start_dt, end_dt = day_range_start(start), day_range_end(end)

    card_and_transfer = Payment.objects.filter(
        method__in=[Payment.Method.CARD, Payment.Method.TRANSFER],
        paid_at__gte=start_dt,
        paid_at__lt=end_dt,
    )
    sales = _sum(card_and_transfer)
    # The processor keeps its fee, so the shop banks the payment net of it.
    # Refund rows carry a negative commission, so this nets too.
    commission = _sum(card_and_transfer, "commission_amount")
    expenses = _sum(
        Expense.objects.filter(
            payment_method__in=[
                Expense.PaymentMethod.CARD,
                Expense.PaymentMethod.TRANSFER,
            ],
            spent_at__gte=start,
            spent_at__lte=end,
        )
    )
    suppliers = _supplier_outflow(BANK_METHODS, start_dt, end_dt)

    return [
        _component(COMPONENT_SALES, sales, direction="in"),
        _component(COMPONENT_COMMISSION, -commission, direction="out"),
        _component(COMPONENT_EXPENSES, -expenses, direction="out"),
        _component(COMPONENT_SUPPLIERS, -suppliers, direction="out"),
    ]


def _supplier_outflow(methods, start_dt, end_dt):
    """Money paid to suppliers by the given methods."""
    return _sum(
        SupplierPayment.objects.filter(
            method__in=methods,
            paid_at__gte=start_dt,
            paid_at__lt=end_dt,
        ).exclude(method__in=NON_CASH_SUPPLIER_METHODS)
    )


def _payroll_outflow(start, end):
    """Paid payroll.

    ``PayrollRun`` carries no payment method, and in this market salaries are
    paid in cash, so payroll is routed to the cash box. It is its own component
    precisely so that assumption is visible: a shop that pays by transfer sees
    the line, and corrects it with a transfer between its own accounts.
    """
    from apps.employees.models import PayrollRun

    return _sum(
        PayrollRun.objects.filter(
            status=PayrollRun.Status.PAID,
            payment_date__gte=start,
            payment_date__lte=end,
        ),
        "net_total",
    )


def _transfer_totals(*, end):
    """Transfers in and out for *every* account, in two grouped queries.

    Asking per account cost three queries a piece (two sides plus its last
    count), so a shop with a cash box, a safe and three banks paid fifteen
    queries for rows that fit in two GROUP BYs. Derived flows were already
    batched by kind; this is the other half.
    """
    incoming = {
        row["to_account"]: row["total"] or ZERO
        for row in MoneyTransfer.objects.filter(
            to_account__isnull=False, moved_at__lte=end
        )
        .values("to_account")
        .annotate(total=Sum("amount"))
    }
    outgoing = {
        row["from_account"]: row["total"] or ZERO
        for row in MoneyTransfer.objects.filter(
            from_account__isnull=False, moved_at__lte=end
        )
        .values("from_account")
        .annotate(total=Sum("amount"))
    }
    return incoming, outgoing


def _last_counts(accounts):
    """The most recent count per account, in one query.

    ``account.counts.first()`` is ordered ``-counted_at`` and is therefore a
    query per card. One ordered pass and a first-wins dict costs the same for
    one account as for ten.
    """
    latest = {}
    counts = MoneyCount.objects.filter(
        account__in=[account.pk for account in accounts]
    ).order_by("account_id", "-counted_at", "-created_at")
    for count in counts:
        latest.setdefault(count.account_id, count)
    return latest


def _transfer_components(account, *, incoming, outgoing):
    return [
        _component(
            COMPONENT_TRANSFER_IN, incoming.get(account.pk, ZERO), direction="in"
        ),
        _component(
            COMPONENT_TRANSFER_OUT, -outgoing.get(account.pk, ZERO), direction="out"
        ),
    ]


def _default_account_ids(accounts):
    """The account of each kind that untagged money events land in.

    Falls back to the first account of the kind when none is flagged, so a shop
    that never opened the settings screen still sees its money somewhere rather
    than seeing it nowhere.
    """
    defaults = {}
    for account in accounts:
        if account.kind in defaults:
            continue
        if account.is_default:
            defaults[account.kind] = account
    for account in accounts:
        defaults.setdefault(account.kind, account)
    return defaults


def account_position(
    account,
    *,
    as_of=None,
    components=None,
    transfers=None,
    last_count=_UNSET,
):
    """One account's expected balance, with the arithmetic that produced it.

    ``transfers`` and ``last_count`` are the batched lookups ``treasury_position``
    already made. Passing them is what keeps a page of accounts flat; omitting
    them (a single-account caller) falls back to fetching just this account's.
    """
    as_of = as_of or timezone.localdate()
    incoming, outgoing = transfers or _transfer_totals(end=as_of)
    if last_count is _UNSET:
        last_count = account.counts.first()

    parts = [_component(COMPONENT_OPENING, account.opening_balance, direction="in")]
    parts.extend(components or [])
    parts.extend(_transfer_components(account, incoming=incoming, outgoing=outgoing))
    expected = sum((part["amount"] for part in parts), ZERO).quantize(MONEY_PLACES)

    return {
        "account": account,
        "expected_balance": expected,
        "components": [part for part in parts if part["amount"] != ZERO],
        "last_count": last_count,
        # The drift since the last count is what the owner actually acts on: a
        # variance recorded last Tuesday says nothing about today's box.
        "uncounted_since": last_count.counted_at if last_count else None,
    }


def treasury_position(*, as_of=None):
    """Every active account's expected balance, plus the shop-wide totals.

    Flat in the number of accounts: derived flows are computed once per *kind*
    and attributed to that kind's default account (which also stops the same
    payment being counted into two accounts), and transfers and last counts are
    batched across every account. Adding a bank account costs nothing.
    """
    as_of = as_of or timezone.localdate()
    accounts = list(MoneyAccount.objects.filter(is_active=True))
    if not accounts:
        return {"accounts": [], "totals": _totals([]), "as_of": as_of}

    defaults = _default_account_ids(accounts)
    derived = {}
    for kind, account in defaults.items():
        builder = (
            _cash_components if kind == MoneyAccount.Kind.CASH else _bank_components
        )
        derived[account.pk] = builder(start=account.opening_at, end=as_of)

    # Two grouped queries and one ordered pass, whatever the account count.
    transfers = _transfer_totals(end=as_of)
    last_counts = _last_counts(accounts)

    positions = [
        account_position(
            account,
            as_of=as_of,
            components=derived.get(account.pk),
            transfers=transfers,
            last_count=last_counts.get(account.pk),
        )
        for account in accounts
    ]
    return {"accounts": positions, "totals": _totals(positions), "as_of": as_of}


def _totals(positions):
    def total_for(kind):
        return sum(
            (
                position["expected_balance"]
                for position in positions
                if position["account"].kind == kind
            ),
            ZERO,
        ).quantize(MONEY_PLACES)

    cash = total_for(MoneyAccount.Kind.CASH)
    bank = total_for(MoneyAccount.Kind.BANK)
    counted = [
        position for position in positions if position["last_count"] is not None
    ]
    return {
        "cash": cash,
        "bank": bank,
        "total": (cash + bank).quantize(MONEY_PLACES),
        "accounts_counted": len(counted),
        "accounts_total": len(positions),
        "accounts_with_variance": sum(
            1 for position in counted if position["last_count"].has_variance
        ),
    }


def expected_balance_for(account, *, as_of=None):
    """The single expected balance for one account — used when recording a
    count, so the snapshot a count stores is the same number the screen showed."""
    as_of = as_of or timezone.localdate()
    accounts = list(MoneyAccount.objects.filter(is_active=True))
    defaults = _default_account_ids(accounts)
    components = None
    if defaults.get(account.kind) and defaults[account.kind].pk == account.pk:
        builder = (
            _cash_components
            if account.kind == MoneyAccount.Kind.CASH
            else _bank_components
        )
        components = builder(start=account.opening_at, end=as_of)
    return account_position(account, as_of=as_of, components=components)[
        "expected_balance"
    ]


def record_count(*, account, counted_amount, note="", created_by=None):
    """Store what was found, against what was expected at that moment."""
    expected = expected_balance_for(account)
    return MoneyCount.objects.create(
        account=account,
        counted_amount=counted_amount,
        expected_amount=expected,
        variance=(Decimal(counted_amount) - expected).quantize(MONEY_PLACES),
        note=note,
        created_by=created_by,
    )


def account_is_routed(account):
    """True when this account receives the derived flows for its kind."""
    accounts = list(MoneyAccount.objects.filter(is_active=True))
    default = _default_account_ids(accounts).get(account.kind)
    return bool(default and default.pk == account.pk)


__all__ = [
    "account_is_routed",
    "account_position",
    "expected_balance_for",
    "record_count",
    "treasury_position",
    "COMPONENT_OPENING",
    "COMPONENT_SALES",
    "COMPONENT_DRAWER_IN",
    "COMPONENT_DRAWER_OUT",
    "COMPONENT_EXPENSES",
    "COMPONENT_SUPPLIERS",
    "COMPONENT_PAYROLL",
    "COMPONENT_COMMISSION",
    "COMPONENT_TRANSFER_IN",
    "COMPONENT_TRANSFER_OUT",
]
