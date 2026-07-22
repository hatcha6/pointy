"""Expense recording + the unified expense ledger.

``create_expense`` records an ad-hoc expense and, when paid in cash from an open
register, the linked drawer pay-out. ``build_expense_ledger`` unions every place
money leaves the shop (ad-hoc expenses, register pay-outs, supplier purchases,
paid payroll, payment commissions) into one normalized, permission-aware list.
"""

from datetime import datetime, time, timedelta
from decimal import Decimal

from django.db import transaction
from django.db.models import DecimalField, Sum, Value
from django.db.models.functions import Coalesce
from django.utils import timezone
from django.utils.dateparse import parse_date

from apps.analytics.services import record_domain_event
from apps.sales.models import RegisterCashMovement, RegisterSession

from .models import Expense

MONEY_FIELD = DecimalField(max_digits=12, decimal_places=2)
MONEY_PLACES = Decimal("0.01")
# Hard ceiling on rows returned for a single period; the response flags
# truncation so the UI can tell the user to narrow the range.
LEDGER_ROW_LIMIT = 500

# Stable source codes the frontend maps to Arabic labels + colored badges.
SOURCE_EXPENSE = "expense"
SOURCE_REGISTER_PAYOUT = "register_payout"
SOURCE_PURCHASE = "purchase"
SOURCE_PAYROLL = "payroll"
SOURCE_COMMISSION = "commission"
LEDGER_SOURCES = (
    SOURCE_EXPENSE,
    SOURCE_REGISTER_PAYOUT,
    SOURCE_PURCHASE,
    SOURCE_PAYROLL,
    SOURCE_COMMISSION,
)


def open_register_session(user):
    """The user's currently open register session, if any."""
    return RegisterSession.open_for(user)


@transaction.atomic
def create_expense(*, user, pay_from_register=False, **fields):
    """Create an ``Expense``. When ``pay_from_register`` is set and the expense
    is cash with an open register session, also record a linked ``PAY_OUT`` so
    the till reconciles automatically (``RegisterSession.expected_cash`` already
    nets out pay-outs).
    """
    creator = user if getattr(user, "is_authenticated", False) else None
    expense = Expense(created_by=creator, **fields)

    if pay_from_register and expense.payment_method == Expense.PaymentMethod.CASH:
        session = open_register_session(user)
        if session is not None:
            movement = RegisterCashMovement.objects.create(
                register_session=session,
                movement_type=RegisterCashMovement.MovementType.PAY_OUT,
                amount=expense.amount,
                reason=f"مصروف: {expense.category.name} — {expense.description}",
                created_by=creator,
            )
            expense.register_session = session
            expense.cash_movement = movement

    expense.save()
    record_domain_event(
        name="expenses.expense.created",
        user=creator,
        attributes={
            "expense_id": expense.pk,
            "category": expense.category.name,
            "payment_method": expense.payment_method,
            "paid_from_register": expense.cash_movement_id is not None,
        },
        metrics={"amount": float(expense.amount)},
    )
    return expense


def parse_ledger_period(params):
    """Resolve the ledger date window from query params, defaulting to the
    current calendar month (first of month → today).
    """
    today = timezone.localdate()
    end = _parse_date(params.get("end"), default=today)
    start = _parse_date(params.get("start"), default=today.replace(day=1))
    if start > end:
        start, end = end, start
    return start, end


def build_expense_ledger(*, user, start, end, sources=None):
    """Return ``{rows, totals, summary}`` across every expense source the user
    is allowed to see. ``rows`` are newest-first and capped at
    ``LEDGER_ROW_LIMIT`` with truncation metadata.
    """
    selected = _selected_sources(sources)
    start_dt = _start_of_day(start)
    end_dt = _start_of_day(end) + timedelta(days=1)

    rows = []
    totals = {}

    if SOURCE_EXPENSE in selected:
        rows.extend(_expense_rows(start, end))
    if SOURCE_REGISTER_PAYOUT in selected and _can(user, "sales.view_registercashmovement"):
        rows.extend(_register_payout_rows(start_dt, end_dt))
    if SOURCE_PURCHASE in selected and _can(user, "purchasing.view_purchaseorder"):
        rows.extend(_purchase_rows(start_dt, end_dt))
    if SOURCE_PAYROLL in selected and _can(user, "employees.view_payrollrun"):
        rows.extend(_payroll_rows(start, end))
    if SOURCE_COMMISSION in selected and _can(user, "payments.view_payment"):
        rows.extend(_commission_rows(start_dt, end_dt, end))

    rows.sort(key=lambda row: (row["date"], row["amount_value"]), reverse=True)

    for source in LEDGER_SOURCES:
        source_total = sum(
            (row["amount_value"] for row in rows if row["source"] == source),
            Decimal("0.00"),
        )
        totals[source] = _money(source_total)

    total_count = len(rows)
    truncated = total_count > LEDGER_ROW_LIMIT
    visible = rows[:LEDGER_ROW_LIMIT]
    grand_total = sum((row["amount_value"] for row in rows), Decimal("0.00"))

    return {
        "start": start.isoformat(),
        "end": end.isoformat(),
        "rows": [_public_row(row) for row in visible],
        "totals": totals,
        "summary": {
            "total": _money(grand_total),
            "returned_count": len(visible),
            "total_count": total_count,
            "truncated": truncated,
        },
    }


# --- per-source row builders -------------------------------------------------


def _expense_rows(start, end):
    queryset = (
        Expense.objects.filter(spent_at__gte=start, spent_at__lte=end)
        .select_related("category")
    )
    return [
        _row(
            source=SOURCE_EXPENSE,
            date=expense.spent_at,
            amount=expense.amount,
            description=expense.description,
            category=expense.category.name,
            payment_method=expense.payment_method,
            reference=expense.reference,
            related_id=expense.pk,
        )
        for expense in queryset
    ]


def _register_payout_rows(start_dt, end_dt):
    # Standalone pay-outs only: a pay-out linked to an Expense is already
    # represented by its expense row, and one linked to a SupplierPayment (POS
    # cash purchase) by its purchase-order row — excluding both here avoids
    # double counting.
    queryset = RegisterCashMovement.objects.filter(
        movement_type=RegisterCashMovement.MovementType.PAY_OUT,
        created_at__gte=start_dt,
        created_at__lt=end_dt,
        expense__isnull=True,
        supplier_payment__isnull=True,
    )
    return [
        _row(
            source=SOURCE_REGISTER_PAYOUT,
            date=movement.created_at.date(),
            amount=movement.amount,
            description=movement.reason,
            payment_method=Expense.PaymentMethod.CASH,
            related_id=movement.pk,
        )
        for movement in queryset
    ]


def _purchase_rows(start_dt, end_dt):
    from apps.purchasing.models import PurchaseOrder

    queryset = (
        PurchaseOrder.objects.exclude(status=PurchaseOrder.Status.CANCELLED)
        .filter(created_at__gte=start_dt, created_at__lt=end_dt)
        .select_related("supplier")
    )
    return [
        _row(
            source=SOURCE_PURCHASE,
            date=order.created_at.date(),
            amount=order.total,
            description=f"{order.supplier.name} · {order.order_number}",
            reference=order.supplier_invoice_number,
            related_id=order.pk,
        )
        for order in queryset
    ]


def _payroll_rows(start, end):
    from apps.employees.models import PayrollRun

    queryset = PayrollRun.objects.filter(
        status=PayrollRun.Status.PAID,
        payment_date__gte=start,
        payment_date__lte=end,
    )
    return [
        _row(
            source=SOURCE_PAYROLL,
            date=run.payment_date,
            amount=run.net_total,
            description=f"{run.period_start} → {run.period_end}",
            related_id=run.pk,
        )
        for run in queryset
    ]


def _commission_rows(start_dt, end_dt, period_end):
    from apps.payments.models import Payment

    total = Payment.objects.filter(
        created_at__gte=start_dt,
        created_at__lt=end_dt,
    ).aggregate(
        total=Coalesce(Sum("commission_amount"), Value(Decimal("0.00")), output_field=MONEY_FIELD),
    )["total"]
    if total <= Decimal("0.00"):
        return []
    return [
        _row(
            source=SOURCE_COMMISSION,
            date=period_end,
            amount=total,
            description="عمولات الدفع",
        )
    ]


# --- helpers -----------------------------------------------------------------


def _row(*, source, date, amount, description, category=None, payment_method="", reference="", related_id=None):
    amount_value = _decimal_from(amount)
    return {
        "source": source,
        "date": date,
        "amount_value": amount_value,
        "description": description,
        "category": category,
        "payment_method": payment_method,
        "reference": reference,
        "related_id": related_id,
    }


def _public_row(row):
    return {
        "source": row["source"],
        "date": row["date"].isoformat(),
        "amount": _money(row["amount_value"]),
        "description": row["description"],
        "category": row["category"],
        "payment_method": row["payment_method"],
        "reference": row["reference"],
        "related_id": row["related_id"],
    }


def _selected_sources(sources):
    if not sources:
        return set(LEDGER_SOURCES)
    return {source for source in sources if source in LEDGER_SOURCES} or set(LEDGER_SOURCES)


def _start_of_day(value):
    return timezone.make_aware(datetime.combine(value, time.min))


def _parse_date(value, *, default):
    if not value:
        return default
    parsed = parse_date(value)
    return parsed or default


def _can(user, permission):
    return bool(user) and user.has_perm(permission)


def _money(value):
    return str(_decimal_from(value).quantize(MONEY_PLACES))


def _decimal_from(value):
    if value is None:
        return Decimal("0.00")
    if isinstance(value, Decimal):
        return value
    return Decimal(str(value))
