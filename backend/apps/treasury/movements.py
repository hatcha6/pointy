"""The individual money events behind an account's balance.

``position.py`` answers "how much should be here?" with six aggregates; this
answers the only question an owner asks next — "why?" — with the rows those
aggregates summed. Every row carries the same ``source`` codes the components
use, so a tapped component and this list can never describe different money.

Row-building deliberately mirrors ``apps.expenses.services.build_expense_ledger``
(the same shape, the same ceiling, the same exclusion rules); the two are
different questions over overlapping data — that ledger is "what did we spend",
this is "what moved through this account".
"""

from decimal import Decimal

from apps.core.money_dates import money_date_field, money_period
from apps.expenses.models import Expense
from apps.payments.models import Payment
from apps.purchasing.models import SupplierPayment
from apps.sales.models import RegisterCashMovement

from .models import MoneyAccount, MoneyTransfer
from .position import (
    BANK_METHODS,
    CASH_METHODS,
    COMPONENT_COMMISSION,
    COMPONENT_DRAWER_IN,
    COMPONENT_DRAWER_OUT,
    COMPONENT_EXPENSES,
    COMPONENT_INTEGRATION_DRAW,
    COMPONENT_PAYROLL,
    COMPONENT_SALES,
    COMPONENT_SUPPLIERS,
    COMPONENT_TRANSFER_IN,
    COMPONENT_TRANSFER_OUT,
    NON_CASH_SUPPLIER_METHODS,
    account_is_routed,
    bank_account_filter,
    claimed_by_live,
)

# Same ceiling as the expense ledger: enough for a month of a busy shop, and
# the response says when it truncated so the UI can ask for a shorter range.
MOVEMENT_ROW_LIMIT = 500
MONEY_PLACES = Decimal("0.01")


def _newest(queryset):
    """The newest rows of one source, capped in SQL rather than in Python.

    Without this, a month on a busy shop loaded *every* payment in the window,
    built a dict for each, sorted the lot and threw all but 500 away — work
    that grew with the shop's takings while the screen showed a fixed page.
    Measured at 5,000 payments: 154ms to return the same 500 rows, against 23ms
    at 500. The same shape as the 12K-PO purchases hang.

    One row beyond the limit is fetched deliberately: it is the sentinel that
    tells the merged list it was cut, so ``truncated`` stays honest even when a
    single source supplied every row.
    """
    field = money_date_field(queryset.model)
    return queryset.order_by(f"-{field}", "-id")[: MOVEMENT_ROW_LIMIT + 1]


def _row(*, source, date, amount, description, reference="", related_id=None):
    amount = Decimal(amount).quantize(MONEY_PLACES)
    return {
        "source": source,
        "date": date,
        "amount": amount,
        "direction": "in" if amount >= 0 else "out",
        "description": description,
        "reference": reference,
        "related_id": related_id,
    }


def account_movements(account, *, start, end):
    """Every money event that moved through ``account`` between two local days."""
    rows = list(_transfer_rows(account, start=start, end=end))
    is_routed = account_is_routed(account)
    if account.kind == MoneyAccount.Kind.BANK:
        # Every bank account has rows of its own — the payments that named it —
        # whether or not it is the one untagged money falls back to.
        rows.extend(
            _bank_rows(start=start, end=end, account=account, is_default=is_routed)
        )
    elif is_routed and account.kind == MoneyAccount.Kind.CASH:
        rows.extend(_cash_rows(start=start, end=end))
    elif account.kind == MoneyAccount.Kind.PROVIDER:
        rows.extend(_provider_rows(account, start=start, end=end))

    rows.sort(key=lambda row: (row["date"], row["source"]), reverse=True)
    truncated = len(rows) > MOVEMENT_ROW_LIMIT
    return {"rows": rows[:MOVEMENT_ROW_LIMIT], "truncated": truncated}


def _transfer_rows(account, *, start, end):
    transfers = _newest(
        money_period(
            MoneyTransfer.objects.select_related(
                "from_account", "to_account"
            ).filter(_transfer_touches(account)),
            start,
            end,
        )
    )
    for transfer in transfers:
        incoming = transfer.to_account_id == account.pk
        other = transfer.from_account if incoming else transfer.to_account
        yield _row(
            source=COMPONENT_TRANSFER_IN if incoming else COMPONENT_TRANSFER_OUT,
            date=transfer.moved_at,
            amount=transfer.amount if incoming else -transfer.amount,
            description=transfer.reason or (other.name if other else ""),
            reference=transfer.reference,
            related_id=transfer.pk,
        )


def _transfer_touches(account):
    from django.db.models import Q

    return Q(from_account=account) | Q(to_account=account)


def _payment_rows(methods, *, start, end, with_commission, account_filter=None):
    queryset = Payment.objects.filter(method__in=methods)
    if account_filter is not None:
        queryset = queryset.filter(account_filter)
    payments = _newest(money_period(queryset.select_related("order"), start, end))
    for payment in payments:
        order_number = getattr(payment.order, "invoice_number", "") or ""
        yield _row(
            source=COMPONENT_SALES,
            date=payment.paid_at.date(),
            amount=payment.amount,
            description=order_number,
            reference=payment.external_reference,
            related_id=payment.order_id,
        )
        if with_commission and payment.commission_amount:
            yield _row(
                source=COMPONENT_COMMISSION,
                date=payment.paid_at.date(),
                amount=-payment.commission_amount,
                description=order_number,
                related_id=payment.order_id,
            )


def _expense_rows(methods, *, start, end, account_filter=None):
    queryset = Expense.objects.live()
    if account_filter is not None:
        queryset = queryset.filter(account_filter)
    expenses = _newest(
        money_period(
            queryset.filter(payment_method__in=methods).select_related("category"),
            start,
            end,
        )
    )
    for expense in expenses:
        yield _row(
            source=COMPONENT_EXPENSES,
            date=expense.spent_at,
            amount=-expense.amount,
            description=f"{expense.category.name} · {expense.description}",
            reference=expense.reference,
            related_id=expense.pk,
        )


def _supplier_rows(methods, *, start, end, account_filter=None):
    queryset = SupplierPayment.objects.live()
    if account_filter is not None:
        queryset = queryset.filter(account_filter)
    payments = _newest(
        money_period(
            queryset.filter(method__in=methods)
            .exclude(method__in=NON_CASH_SUPPLIER_METHODS)
            .select_related("supplier", "purchase_order"),
            start,
            end,
        )
    )
    for payment in payments:
        yield _row(
            source=COMPONENT_SUPPLIERS,
            date=payment.paid_at.date(),
            amount=-payment.amount,
            description=payment.supplier.name,
            reference=payment.reference,
            related_id=payment.pk,
        )


def _cash_rows(*, start, end):
    yield from _payment_rows(CASH_METHODS, start=start, end=end, with_commission=False)
    yield from _expense_rows(
        [Expense.PaymentMethod.CASH],
        start=start,
        end=end,
    )
    yield from _supplier_rows(CASH_METHODS, start=start, end=end)

    # Same rule as the balance: an expense's or a purchase's pay-out is shown
    # as that row while it stands, and as a pay-out of its own once cancelled —
    # beside the pay-in that brought the cash back.
    movements = _newest(
        money_period(
            RegisterCashMovement.objects.exclude(claimed_by_live(Expense)).exclude(
                claimed_by_live(SupplierPayment)
            ),
            start,
            end,
        )
    )
    for movement in movements:
        pay_in = movement.movement_type == RegisterCashMovement.MovementType.PAY_IN
        yield _row(
            source=COMPONENT_DRAWER_IN if pay_in else COMPONENT_DRAWER_OUT,
            date=movement.created_at.date(),
            amount=movement.amount if pay_in else -movement.amount,
            description=movement.reason,
            related_id=movement.pk,
        )

    yield from _payroll_rows(start=start, end=end)


def _payroll_rows(*, start, end):
    from apps.employees.models import PayrollRun

    runs = _newest(
        money_period(PayrollRun.objects.filter(status=PayrollRun.Status.PAID), start, end)
    )
    for run in runs:
        yield _row(
            source=COMPONENT_PAYROLL,
            date=run.payment_date,
            amount=-run.net_total,
            description=f"{run.period_start} → {run.period_end}",
            reference=run.run_number,
            related_id=run.pk,
        )


def _bank_rows(*, start, end, account, is_default):
    owned = bank_account_filter(account, is_default=is_default)
    yield from _payment_rows(
        BANK_METHODS,
        start=start,
        end=end,
        with_commission=True,
        account_filter=owned,
    )
    yield from _supplier_rows(
        BANK_METHODS, start=start, end=end, account_filter=owned
    )
    yield from _expense_rows(
        [Expense.PaymentMethod.CARD, Expense.PaymentMethod.TRANSFER],
        start=start,
        end=end,
        account_filter=owned,
    )


def _provider_rows(account, *, start, end):
    """What the provider drew from a float: one row per top-up it performed.

    Read from ``float_ledger.draws``, the rows its ``drawn`` sums, so these and
    the ``integration_draw`` component cannot describe different money. A float
    with no integration account behind it has no draws to list.
    """
    from apps.integrations import float_ledger

    integration = getattr(account, "integration_account", None)
    if integration is None:
        return
    fulfillments = _newest(float_ledger.draws(integration, start=start, end=end))
    for fulfillment in fulfillments:
        # A voucher off the shelf has no card number, only its label.
        what = fulfillment.option_label or fulfillment.option_code
        yield _row(
            source=COMPONENT_INTEGRATION_DRAW,
            date=fulfillment.confirmed_at.date(),
            amount=-fulfillment.cost,
            description=" · ".join(
                part for part in (fulfillment.subscriber_ref, what) if part
            ),
            reference=fulfillment.provider_reference,
            related_id=fulfillment.pk,
        )


__all__ = ["MOVEMENT_ROW_LIMIT", "account_movements"]
