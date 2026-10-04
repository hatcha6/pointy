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
counted here — and a pay-out stands alone again once the document it paid is
cancelled, since the cancellation's pay-in is counted too (``claimed_by_live``).

**Silent assumptions.** Two flows have no payment method in the data at all:
payroll and payment-processor commissions. Rather than hide the guess, both are
returned as their own named components, so the owner sees the assumption in the
breakdown and can correct reality with a transfer instead of arguing with a
total they cannot see inside.
"""

from datetime import timedelta
from decimal import Decimal

from django.db.models import DecimalField, Exists, OuterRef, Q, Sum, Value
from django.utils import timezone
from django.db.models.functions import Coalesce

from apps.core.money_dates import day_range_end, day_range_start
from apps.expenses.models import Expense
from apps.payments.models import Payment
from apps.purchasing.models import SupplierPayment
from apps.sales.models import RegisterCashMovement

from . import clearing
from .models import CardSettlement, MoneyAccount, MoneyCount, MoneyTransfer

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
# Money handed to the owner of goods the shop sold on their behalf. Its own
# code, deliberately: filing it under expenses or supplier payments would put
# other people's money in a category the shop reads as its own spending.
COMPONENT_CONSIGNOR_PAYOUT = "consignor_payout"
# What a resale provider has taken out of its float. Only confirmed draws: a
# top-up Pointy has sold but the provider has not performed is still money
# sitting with the provider, and subtracting it would understate the float on
# the very day somebody is deciding whether to top up (apps.integrations.
# float_ledger holds the definition; this module only places it).
COMPONENT_INTEGRATION_DRAW = "integration_draw"
# Money lent to employees, paid out when the loan was approved. Its own code:
# it is not spending — the shop is owed it back — and filing it under drawer
# pay-outs or expenses would put money the shop still has a claim to among
# money it has spent.
COMPONENT_STAFF_LOANS = "staff_loans"
# A card processor paying held takings into the bank (``CardSettlement``):
# arriving in the bank, and leaving the clearing account that held them. The
# same deposit seen from its two ends, like a transfer's two codes.
COMPONENT_SETTLEMENT_IN = "settlement_in"
COMPONENT_SETTLEMENT_OUT = "settlement_out"
# What the processor kept beyond the fee estimated at each sale (negative), or
# kept short of it (positive). Its own line on the clearing account so a fee
# the shop was not told about is seen, never folded into the takings.
COMPONENT_SETTLEMENT_DIFFERENCE = "settlement_difference"

# Which payment methods land in which kind of account. Method decides the
# *kind* of account; ``money_account`` — when a row carries one — decides WHICH
# account of that kind. See ``bank_account_filter``.
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


def claimed_by_live(document_model):
    """Whether a live ``document_model`` counts this drawer movement as its own.

    A pay-out that paid an expense, a POS cash purchase or a consignor *is*
    that document, and is counted as it — for as long as the document stands.
    Cancelling one stops it counting (``.live()``) and brings the cash back into
    a drawer as a pay-in of its own; from then on its pay-out is a plain pay-out
    again, so the two net to nothing, each on the day the cash really moved.
    Left claimed by the cancelled document, that pay-in would be money arriving
    from nowhere, and the box would read richer by every amount ever cancelled.

    The expense ledger keeps the plain "linked or not" rule on purpose: it asks
    what the shop spent, and a cancelled expense's pay-out never was spending.
    """
    return Exists(document_model.objects.live().filter(cash_movement=OuterRef("pk")))


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
    from apps.inventory.models import ConsignorPayout

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
    # Standalone pay-outs only — one that paid an expense, a POS cash purchase,
    # a consignor or an employee's loan is already counted as that expense /
    # supplier payment / consignor payout / loan: the first three while they
    # stand (``claimed_by_live``), a loan's always (``staff_loans``).
    drawer_out = _sum(
        RegisterCashMovement.objects.filter(
            movement_type=RegisterCashMovement.MovementType.PAY_OUT,
            created_at__gte=start_dt,
            created_at__lt=end_dt,
            employee_loan__isnull=True,
        )
        .exclude(claimed_by_live(Expense))
        .exclude(claimed_by_live(SupplierPayment))
        .exclude(claimed_by_live(ConsignorPayout))
    )
    expenses = _sum(
        Expense.objects.live().filter(
            payment_method=Expense.PaymentMethod.CASH,
            spent_at__gte=start,
            spent_at__lte=end,
        )
    )
    suppliers = _supplier_outflow(CASH_METHODS, start_dt, end_dt)
    payroll = _payroll_outflow(start, end)
    consignors = _consignor_outflow("cash", start_dt, end_dt)
    loans = _loan_outflow("cash", start_dt, end_dt)

    return [
        _component(COMPONENT_SALES, sales, direction="in"),
        _component(COMPONENT_DRAWER_IN, drawer_in, direction="in"),
        _component(COMPONENT_DRAWER_OUT, -drawer_out, direction="out"),
        _component(COMPONENT_EXPENSES, -expenses, direction="out"),
        _component(COMPONENT_SUPPLIERS, -suppliers, direction="out"),
        _component(COMPONENT_PAYROLL, -payroll, direction="out"),
        _component(COMPONENT_CONSIGNOR_PAYOUT, -consignors, direction="out"),
        _component(COMPONENT_STAFF_LOANS, -loans, direction="out"),
    ]


def bank_account_filter(account, *, is_default, field="money_account"):
    """Which of a table's rows belong to one bank account.

    Two clauses, and the second is the whole compatibility story:

    * a row **tagged** with this account is this account's, always;
    * an **untagged** row is the default account's — because that is precisely
      where it went before rows could be tagged at all. A shop with one bank
      account tags nothing, its one account is the default, and every figure on
      the screen is the number it was yesterday.

    Shared by the balance (``position``) and the drill-down (``movements``) so
    a total and the rows behind it can never disagree about ownership.
    """
    owned = Q(**{field: account.pk})
    if is_default:
        owned |= Q(**{f"{field}__isnull": True})
    return owned


def _bank_components(
    *, start, end, account, is_default, held=None, receives_settlements=False
):
    """The money that moves through one bank account.

    Sales, supplier payments and expenses are attributed per account. Consignor
    payouts and the processor's commission are not: those rows carry no account
    of their own, so they stay with the default — visibly, as their own named
    components, which is the same way payroll's cash assumption is shown rather
    than hidden.

    ``held`` is the card takings a clearing account is holding
    (``clearing.held_by_any_q``). They are left out here: they reach this bank
    only when the processor pays them in, as a settlement, and counting them at
    the sale as well would count them twice. ``receives_settlements`` adds those
    deposits; it is false for a bank no clearing account settles into, so such
    a bank costs exactly the queries it always did.
    """
    start_dt, end_dt = day_range_start(start), day_range_end(end)
    owned = bank_account_filter(account, is_default=is_default)

    card_and_transfer = Payment.objects.filter(
        owned,
        method__in=[Payment.Method.CARD, Payment.Method.TRANSFER],
        paid_at__gte=start_dt,
        paid_at__lt=end_dt,
    )
    if held is not None:
        card_and_transfer = card_and_transfer.exclude(held)
    # One pass for both figures: the processor keeps its fee, so the shop banks
    # the payment net of it. Refund rows carry a negative commission, so this
    # nets too.
    totals = card_and_transfer.aggregate(
        sales=Coalesce(Sum("amount"), Value(ZERO), output_field=MONEY_FIELD),
        commission=Coalesce(
            Sum("commission_amount"), Value(ZERO), output_field=MONEY_FIELD
        ),
    )
    sales = totals["sales"] or ZERO
    commission = totals["commission"] or ZERO
    suppliers = _supplier_outflow(
        BANK_METHODS, start_dt, end_dt, account_filter=owned
    )
    expenses = _sum(
        Expense.objects.live().filter(
            owned,
            payment_method__in=[
                Expense.PaymentMethod.CARD,
                Expense.PaymentMethod.TRANSFER,
            ],
            spent_at__gte=start,
            spent_at__lte=end,
        )
    )

    loans = _loan_outflow("transfer", start_dt, end_dt, account_filter=owned)

    components = [
        _component(COMPONENT_SALES, sales, direction="in"),
        _component(COMPONENT_COMMISSION, -commission, direction="out"),
        _component(COMPONENT_SUPPLIERS, -suppliers, direction="out"),
        _component(COMPONENT_EXPENSES, -expenses, direction="out"),
        _component(COMPONENT_STAFF_LOANS, -loans, direction="out"),
    ]
    if receives_settlements:
        settled = _sum(
            clearing.live_settlements().filter(
                bank_account=account,
                settled_on__gte=start,
                settled_on__lte=end,
            ),
            "amount_received",
        )
        components.append(
            _component(COMPONENT_SETTLEMENT_IN, settled, direction=_sign(settled))
        )
    if is_default:
        # Still untagged by nature: a consignor payout names the owner of the
        # goods, not a bank, so it stays with the account untagged money falls
        # back to.
        consignors = _consignor_outflow("bank", start_dt, end_dt)
        components.append(
            _component(COMPONENT_CONSIGNOR_PAYOUT, -consignors, direction="out")
        )
    return components


def _sign(amount):
    return "in" if amount >= 0 else "out"


def _clearing_components(account, *, end, start=None):
    """What a clearing account holds: card takings in, deposits out.

    The takings are the card payments its rule holds (``clearing.claim_q``),
    net of the fee estimated at each sale — the same two figures a bank showed
    for them before, moved here. A settlement takes out what reached the bank,
    and its difference from the estimate is a line of its own, so after a
    settlement the payments it covered contribute exactly nothing.

    No ``opening_at`` window of its own: the rule already starts at the first
    held processor day, on the shop's clock. Narrowing it again by the UTC day
    would drop the takings rung up in the first hours of that day — held, so no
    bank counts them either, and they would be counted nowhere.
    """
    payments = Payment.objects.filter(
        clearing.claim_q(account), paid_at__lt=day_range_end(end)
    )
    settlements = clearing.live_settlements().filter(
        clearing_account=account, settled_on__lte=end
    )
    if start is not None:
        payments = payments.filter(paid_at__gte=day_range_start(start))
        settlements = settlements.filter(settled_on__gte=start)

    takings = payments.aggregate(
        sales=Coalesce(Sum("amount"), Value(ZERO), output_field=MONEY_FIELD),
        commission=Coalesce(
            Sum("commission_amount"), Value(ZERO), output_field=MONEY_FIELD
        ),
    )
    paid = settlements.aggregate(
        received=Coalesce(
            Sum("amount_received"), Value(ZERO), output_field=MONEY_FIELD
        ),
        difference=Coalesce(Sum("difference"), Value(ZERO), output_field=MONEY_FIELD),
    )
    difference = paid["difference"] or ZERO
    return [
        _component(COMPONENT_SALES, takings["sales"] or ZERO, direction="in"),
        _component(
            COMPONENT_COMMISSION, -(takings["commission"] or ZERO), direction="out"
        ),
        _component(
            COMPONENT_SETTLEMENT_OUT, -(paid["received"] or ZERO), direction="out"
        ),
        _component(
            COMPONENT_SETTLEMENT_DIFFERENCE, difference, direction=_sign(difference)
        ),
    ]


def loan_disbursements(method, start_dt, end_dt, *, account_filter=None):
    """Loans paid out to employees by ``method``, inside the window.

    Dated when the money was handed over. A loan approved before disbursements
    were recorded has none, and is not counted: its cash was never taken off
    the books here, and inventing the day it left would move a balance the
    owner has already counted.
    """
    from apps.employees.models import EmployeeLoan
    from apps.employees.reporting import LENT_STATUSES

    queryset = EmployeeLoan.objects.filter(
        status__in=LENT_STATUSES,
        disbursement_method=method,
        disbursed_at__gte=start_dt,
        disbursed_at__lt=end_dt,
    )
    if account_filter is not None:
        queryset = queryset.filter(account_filter)
    return queryset


def _loan_outflow(method, start_dt, end_dt, *, account_filter=None):
    return _sum(
        loan_disbursements(method, start_dt, end_dt, account_filter=account_filter)
    )


def _consignor_outflow(method, start_dt, end_dt):
    """Money paid out to the owners of consigned goods, by this route."""
    from apps.inventory.models import ConsignorPayout

    return _sum(
        ConsignorPayout.objects.live().filter(
            method=method,
            paid_at__gte=start_dt,
            paid_at__lt=end_dt,
        )
    )


def _supplier_outflow(methods, start_dt, end_dt, *, account_filter=None):
    """Money paid to suppliers by the given methods.

    ``account_filter`` narrows to one bank account's share; cash callers pass
    nothing, because a cash pay-out's account is the drawer.
    """
    queryset = SupplierPayment.objects.live()
    if account_filter is not None:
        queryset = queryset.filter(account_filter)
    return _sum(
        queryset.filter(
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


def _transfer_totals(*, end, start=None):
    """Transfers in and out for *every* account, in two grouped queries.

    Asking per account cost three queries a piece (two sides plus its last
    count), so a shop with a cash box, a safe and three banks paid fifteen
    queries for rows that fit in two GROUP BYs. Derived flows were already
    batched by kind; this is the other half.

    ``start`` narrows to a window rather than everything up to ``end``, which is
    what a statement needs: a balance is cumulative, a movement is not.
    """
    window = {"moved_at__lte": end}
    if start is not None:
        window["moved_at__gte"] = start
    incoming = {
        row["to_account"]: row["total"] or ZERO
        for row in MoneyTransfer.objects.filter(to_account__isnull=False, **window)
        .values("to_account")
        .annotate(total=Sum("amount"))
    }
    outgoing = {
        row["from_account"]: row["total"] or ZERO
        for row in MoneyTransfer.objects.filter(from_account__isnull=False, **window)
        .values("from_account")
        .annotate(total=Sum("amount"))
    }
    return incoming, outgoing


def _last_counts(accounts, *, end=None):
    """The most recent count per account, in one query — at the close of
    ``end`` when one is given, so a statement for September is not answered
    with a count taken in October.

    ``account.counts.first()`` is ordered ``-counted_at`` and is therefore a
    query per card. One ordered pass and a first-wins dict costs the same for
    one account as for ten.
    """
    latest = {}
    counts = MoneyCount.objects.filter(
        account__in=[account.pk for account in accounts]
    )
    if end is not None:
        counts = counts.filter(counted_at__lt=day_range_end(end))
    counts = counts.order_by("account_id", "-counted_at", "-created_at")
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


def _provider_components(money_account, *, end, start=None):
    """What a provider has drawn out of its float, for one float account.

    Every draw up to ``end``, not only those since ``opening_at`` as for a
    bank. A float's account is created on the day its first top-up is written
    down, and that top-up may be dated earlier and followed by draws (a payment
    on LNET's website is dated when LNET took it); ``float_ledger`` counts
    those, so this row must too. ``start`` narrows to a window, for a statement.
    """
    from apps.integrations import float_ledger

    integration = getattr(money_account, "integration_account", None)
    if integration is None:
        return []
    drawn = float_ledger.drawn(integration, start=start, end=end)
    return [_component(COMPONENT_INTEGRATION_DRAW, -drawn, direction="out")]


def _default_account_ids(accounts):
    """The account of each kind that untagged money events land in.

    Falls back to the first account of the kind when none is flagged, so a shop
    that never opened the settings screen still sees its money somewhere rather
    than seeing it nowhere.

    A clearing account is never one: what it holds is decided by its own rule
    (``clearing.claim_q``), not by being the account untagged money falls to.
    """
    accounts = [account for account in accounts if not account.is_clearing]
    defaults = {}
    for account in accounts:
        if account.kind in defaults:
            continue
        if account.is_default:
            defaults[account.kind] = account
    for account in accounts:
        defaults.setdefault(account.kind, account)
    return defaults


def _reported_accounts(all_accounts):
    """The accounts a position or statement is stated for.

    Every active account, plus any closed clearing account — one that stopped
    holding still owns the takings of its window, and is shown for as long as
    it holds any of them (see ``_drop_settled_closed``).
    """
    return [
        account
        for account in all_accounts
        if account.is_active or account.is_clearing
    ]


def _drop_settled_closed(rows, *keys):
    """Leave out a closed clearing account with nothing left in it."""
    return [
        row
        for row in rows
        if row["account"].is_active
        or any(row[key] != ZERO for key in keys)
    ]


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

    Cash and the shop-wide lookups are flat: the cash flows are computed once
    for the one cash box that receives them, and transfers and last counts are
    batched across every account in two grouped queries and one ordered pass.

    Bank accounts cost two aggregates each, because each one asks its own
    question over its own window — a second bank account opened last month must
    not be credited with the first one's takings since its own opening date.
    That is a handful of indexed range scans for the two or three accounts a
    shop actually has, and the alternative (one GROUP BY for all of them) can
    only be written by pretending they share an opening date.
    """
    as_of = as_of or timezone.localdate()
    all_accounts = list(MoneyAccount.objects.all())
    accounts = _reported_accounts(all_accounts)
    if not accounts:
        return {"accounts": [], "totals": _totals([]), "as_of": as_of}

    defaults = _default_account_ids(
        [account for account in accounts if account.is_active]
    )
    clearings = clearing.clearing_accounts(all_accounts)
    held = clearing.held_by_any_q(clearings)
    settled_banks = {account.settles_into_id for account in clearings}
    derived = {}
    cash_default = defaults.get(MoneyAccount.Kind.CASH)
    if cash_default is not None:
        # One cash box takes every untagged cash event: a drawer is attributed
        # by register session, not by naming an account at the till.
        derived[cash_default.pk] = _cash_components(
            start=cash_default.opening_at, end=as_of
        )
    bank_default = defaults.get(MoneyAccount.Kind.BANK)
    for account in accounts:
        if account.kind == MoneyAccount.Kind.PROVIDER:
            # A float has no untagged flows to attribute — every movement names
            # its provider.
            derived[account.pk] = _provider_components(account, end=as_of)
        elif account.kind == MoneyAccount.Kind.BANK:
            derived[account.pk] = _bank_components(
                start=account.opening_at,
                end=as_of,
                account=account,
                is_default=bank_default is not None
                and bank_default.pk == account.pk,
                held=held,
                receives_settlements=account.pk in settled_banks,
            )
        elif account.is_clearing:
            derived[account.pk] = _clearing_components(account, end=as_of)

    # Two grouped queries and one ordered pass, whatever the account count.
    transfers = _transfer_totals(end=as_of)
    last_counts = _last_counts(accounts)

    positions = _drop_settled_closed(
        [
            account_position(
                account,
                as_of=as_of,
                components=derived.get(account.pk),
                transfers=transfers,
                last_count=last_counts.get(account.pk),
            )
            for account in accounts
        ],
        "expected_balance",
    )
    return {
        "accounts": positions,
        "totals": _totals(positions),
        "as_of": as_of,
        # An **overlay**, never a component. The cash in the drawer really is
        # there; what is untrue is that all of it is the shop's. Subtracting a
        # consignor payable from the money position would double-count it the
        # moment the payout is actually made, so this sits beneath the total and
        # says how much of it is spoken for (§5.8).
        "obligations": obligations(as_of=as_of),
    }


def obligations(*, as_of=None):
    """What the shop is holding that belongs to somebody else.

    Derived on read from the units' own sales and their own payout rows, never
    stored — which is the whole reason it cannot drift from them.
    """
    from apps.inventory import consignment

    # ``as_of`` is a date; the rows it bounds are timestamps, so the day is
    # taken whole rather than cut off at midnight-minus-one-microsecond.
    bound = day_range_end(as_of) if as_of is not None else None
    return {
        "consignor_payable": consignment.consignor_payable(as_of=bound),
        # Shown beside the payable and never netted against it: a shop that owes
        # one consignor 10,000 and is owed 3,000 by another owes 10,000, and a
        # single figure hiding two people is how a drawer comes up short.
        "consignor_receivable": consignment.consignor_receivable(as_of=bound),
        "consignor_claims_open": consignment.consignor_claims_open(bound),
        # A count, not a number. An incident nobody has assessed yet is a
        # liability the shop has not accepted, and folding a placeholder zero
        # into a money figure would state that it had (§6.2.2).
        "consignor_claims_unassessed": consignment.consignor_claims_unassessed(
            bound
        ),
        "custody": consignment.custody_exposure(bound),
    }


def treasury_statement(*, start, end):
    """Opening balance, what moved, and closing balance — per account.

    A balance answers "what should be in the box"; a close needs the third
    question too: "and how did it get from last month's figure to this one".
    Stated as opening + movements = closing, so the statement foots and the
    closing figure is the same number ``treasury_position`` would give for the
    same day rather than a second derivation of it.

    Costs one position pass for the opening balances plus the same per-account
    passes ``treasury_position`` makes: one for the cash box, two aggregates
    per bank account, one per provider float.
    """
    all_accounts = list(MoneyAccount.objects.all())
    accounts = _reported_accounts(all_accounts)
    if not accounts:
        return {"accounts": [], "totals": _statement_totals([]), "start": start, "end": end}

    opening_positions = {
        position["account"].pk: position
        for position in treasury_position(as_of=start - timedelta(days=1))["accounts"]
    }
    defaults = _default_account_ids(
        [account for account in accounts if account.is_active]
    )
    clearings = clearing.clearing_accounts(all_accounts)
    held = clearing.held_by_any_q(clearings)
    settled_banks = {account.settles_into_id for account in clearings}
    movements = {}
    cash_default = defaults.get(MoneyAccount.Kind.CASH)
    if cash_default is not None:
        # From the account's own opening date when that falls inside the
        # window, exactly as its balance is derived. The money taken before
        # the shop opened the box in Pointy is already inside its opening
        # balance; replayed here as well, a shop that upgraded mid-month
        # closed the month with that half-month counted twice.
        movements[cash_default.pk] = _cash_components(
            start=max(start, cash_default.opening_at), end=end
        )
    bank_default = defaults.get(MoneyAccount.Kind.BANK)
    for account in accounts:
        if account.kind == MoneyAccount.Kind.PROVIDER:
            # Only the window's draws: the earlier ones are in the opening
            # balance already, and without these the closing one left them out.
            movements[account.pk] = _provider_components(account, start=start, end=end)
        elif account.kind == MoneyAccount.Kind.BANK:
            movements[account.pk] = _bank_components(
                start=max(start, account.opening_at),
                end=end,
                account=account,
                is_default=bank_default is not None and bank_default.pk == account.pk,
                held=held,
                receives_settlements=account.pk in settled_banks,
            )
        elif account.is_clearing:
            # The window's own takings and deposits: the earlier ones are in
            # the opening balance, which is the position the day before.
            movements[account.pk] = _clearing_components(
                account, start=start, end=end
            )

    incoming, outgoing = _transfer_totals(start=start, end=end)
    last_counts = _last_counts(accounts, end=end)

    rows = []
    for account in accounts:
        opening = opening_positions.get(account.pk)
        opening_balance = opening["expected_balance"] if opening else ZERO
        components = list(movements.get(account.pk) or [])
        components.extend(
            _transfer_components(account, incoming=incoming, outgoing=outgoing)
        )
        moved = sum((part["amount"] for part in components), ZERO)
        last_count = last_counts.get(account.pk)
        rows.append(
            {
                "account": account,
                "opening_balance": opening_balance.quantize(MONEY_PLACES),
                "components": [part for part in components if part["amount"] != ZERO],
                "movement_total": moved.quantize(MONEY_PLACES),
                "closing_balance": (opening_balance + moved).quantize(MONEY_PLACES),
                "last_count": last_count,
                "counted_variance": (
                    last_count.variance if last_count is not None else None
                ),
            }
        )
    rows = _drop_settled_closed(
        rows, "opening_balance", "movement_total", "closing_balance"
    )
    return {
        "accounts": rows,
        "totals": _statement_totals(rows),
        "start": start,
        "end": end,
    }


def outside_money_totals(*, start, end):
    """Money that came into the shop from outside, and left it, over a window.

    The two transfer shapes that are not the shop moving its own money between
    its own accounts: a deposit (capital from the owner, a loan) and a
    withdrawal (the owner's draw). Neither is trading, so a comparison of two
    balance sheets has to take both out before the difference can be read as
    what the shop's business did. Only active accounts count, the same set a
    balance is stated for — otherwise money moved into a closed account would
    be explained here and missing there.
    """
    window = MoneyTransfer.objects.filter(moved_at__gte=start, moved_at__lte=end)
    added = _sum(window.filter(from_account__isnull=True, to_account__is_active=True))
    withdrawn = _sum(
        window.filter(to_account__isnull=True, from_account__is_active=True)
    )
    return {
        "added": Decimal(added).quantize(MONEY_PLACES),
        "withdrawn": Decimal(withdrawn).quantize(MONEY_PLACES),
    }


def _statement_totals(rows):
    """The statement's totals: cash and bank, with the provider floats beside
    them and never inside — the same split ``_totals`` makes for the money
    position, so the closing total here is the screen's total and the balance
    sheet's cash line for the same day."""
    money_rows = [
        row for row in rows if row["account"].kind != MoneyAccount.Kind.PROVIDER
    ]

    def total(key, among=money_rows):
        return sum((row[key] for row in among), ZERO).quantize(MONEY_PLACES)

    # A clearing account is proved by the settlements recorded against it,
    # never by a count, so it is not one of the accounts waiting to be counted.
    countable = [row for row in money_rows if not row["account"].is_clearing]
    counted = [row for row in countable if row["last_count"] is not None]
    floats = [row for row in rows if row["account"].kind == MoneyAccount.Kind.PROVIDER]
    held = [row for row in rows if row["account"].is_clearing]
    return {
        "opening_total": total("opening_balance"),
        "movement_total": total("movement_total"),
        "closing_total": total("closing_balance"),
        "provider_float": total("closing_balance", among=floats),
        # Inside the closing total, unlike the floats: see ``_totals``.
        "in_transit": total("closing_balance", among=held),
        "counted_variance_total": sum(
            (row["last_count"].variance for row in counted), ZERO
        ).quantize(MONEY_PLACES),
        "accounts_counted": len(counted),
        "accounts_total": len(countable),
    }


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
    # Reported beside `total`, never inside it. A provider float is the shop's
    # money, but it cannot pay a wage or settle a supplier — folding it into
    # the figure an owner reads as "what I can spend" would change what that
    # figure means, which is the same reason consignor obligations sit outside
    # it rather than being netted off.
    provider_float = total_for(MoneyAccount.Kind.PROVIDER)
    # Card takings the processor is holding ARE inside `total`, unlike a float.
    # They are cash already earned and owed back to the shop within days — a
    # receivable from the processor that accountants class with cash — and
    # until a shop starts holding them they were counted in the bank, inside
    # this same total. Leaving them out would make the total drop the moment a
    # shop switched the hold on, with no money having moved.
    in_transit = total_for(MoneyAccount.Kind.CLEARING)
    # Proved by its settlements, not by a count: a clearing account never
    # waits in "not counted yet".
    countable = [
        position for position in positions if not position["account"].is_clearing
    ]
    counted = [
        position for position in countable if position["last_count"] is not None
    ]
    return {
        "cash": cash,
        "bank": bank,
        "in_transit": in_transit,
        "total": (cash + bank + in_transit).quantize(MONEY_PLACES),
        "provider_float": provider_float,
        "accounts_counted": len(counted),
        "accounts_total": len(countable),
        "accounts_with_variance": sum(
            1 for position in counted if position["last_count"].has_variance
        ),
    }


def expected_balance_for(account, *, as_of=None):
    """The single expected balance for one account — used when recording a
    count, so the snapshot a count stores is the same number the screen showed."""
    as_of = as_of or timezone.localdate()
    all_accounts = list(MoneyAccount.objects.all())
    defaults = _default_account_ids(
        [candidate for candidate in all_accounts if candidate.is_active]
    )
    default = defaults.get(account.kind)
    is_default = bool(default and default.pk == account.pk)
    clearings = clearing.clearing_accounts(all_accounts)
    components = None
    if account.kind == MoneyAccount.Kind.PROVIDER:
        components = _provider_components(account, end=as_of)
    elif account.kind == MoneyAccount.Kind.BANK:
        # Every bank account has derived flows now, not just the default one:
        # the payments tagged to it are its own.
        components = _bank_components(
            start=account.opening_at,
            end=as_of,
            account=account,
            is_default=is_default,
            held=clearing.held_by_any_q(clearings),
            receives_settlements=any(
                held_by.settles_into_id == account.pk for held_by in clearings
            ),
        )
    elif account.is_clearing:
        components = _clearing_components(account, end=as_of)
    elif is_default:
        components = _cash_components(start=account.opening_at, end=as_of)
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


def routed_account(kind):
    """The active account of ``kind`` that untagged money events land in.

    ``None`` when the shop has no active account of that kind.
    """
    accounts = list(MoneyAccount.objects.filter(is_active=True, kind=kind))
    return _default_account_ids(accounts).get(kind)


def account_is_routed(account):
    """True when this account receives the money events nothing has tagged.

    A second bank account is not "routed" and still shows its own balance: it
    holds the payments that named it. What this answers is narrower — where an
    untagged card payment, a bank expense, or a consignor payout lands.
    """
    default = routed_account(account.kind)
    return bool(default and default.pk == account.pk)


__all__ = [
    "account_is_routed",
    "bank_account_filter",
    "account_position",
    "expected_balance_for",
    "outside_money_totals",
    "record_count",
    "routed_account",
    "treasury_position",
    "treasury_statement",
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
    "COMPONENT_SETTLEMENT_IN",
    "COMPONENT_SETTLEMENT_OUT",
    "COMPONENT_SETTLEMENT_DIFFERENCE",
]
