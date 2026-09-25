"""One answer to "when did this money move?".

Money lives in nine models and each one dates it differently: an ``Expense`` has
a backdatable ``spent_at`` date, a ``Payment`` has a ``paid_at`` timestamp, a
``PayrollRun`` has a ``payment_date``, an ``Order`` has only ``created_at``.
Before this module, each reporting surface picked a field by hand — and the
profit-and-costs report filtered sales on ``created_at``, payroll on
``payment_date`` and expenses on ``spent_at`` inside a single period, so a
report could include the wage and exclude the sale that paid it.

The registry below is the single statement of which column means *the day the
money moved*, and ``money_period`` is the only supported way to slice a money
queryset by a period. Adding a money model means adding a line here; a surface
that hand-rolls its own boundary is caught by
``apps.core.test_money_definitions``.

Period semantics are calendar days on the **app-wide** clock, inclusive on both
ends: "1 August to 31 August" means every money event stamped inside those days,
whichever column carries the stamp.

The clock is deliberately ``django.utils.timezone`` (``TIME_ZONE = "UTC"``), not
``timeutils.business_timezone``. ``timeutils`` says so in its own docstring: the
shop timezone is scoped to the holidays calendar, and reports, fraud lookback
and payroll all use the UTC calendar date. ``reports._period_from_params``
builds its ``start_date``/``end_date`` with ``timezone.localdate()``, so slicing
those same days in Tripoli time would move every window two hours and file a
22:30 sale under the next day. Promoting the whole app to shop-local days is a
separate, deliberate migration — when it happens, it happens here and in
``_period_from_params`` together.
"""

from datetime import date, datetime, time, timedelta

from django.utils import timezone

# model label -> the field that says when the money moved.
MONEY_DATE_FIELDS = {
    "payments.Payment": "paid_at",
    "sales.Order": "created_at",
    "sales.OrderAdjustment": "created_at",
    "sales.RegisterCashMovement": "created_at",
    # ``opened_at`` and ``created_at`` are the same instant on this model
    # (both are set at creation); ``created_at`` is the one that carries an
    # index, so the register-closure report keeps its index scan.
    "sales.RegisterSession": "created_at",
    "expenses.Expense": "spent_at",
    "purchasing.SupplierPayment": "paid_at",
    "purchasing.PurchaseOrder": "created_at",
    "employees.PayrollRun": "payment_date",
    "treasury.MoneyTransfer": "moved_at",
    "treasury.MoneyCount": "counted_at",
    # A top-up is drawn from the float when the PROVIDER performs it, not when
    # Pointy sold it — so the money date is the confirmation, and a row still
    # waiting for one is correctly outside every period.
    "integrations.IntegrationFulfillment": "confirmed_at",
    # An opening balance or an adjustment is dated the day it applies from,
    # which is often before it was typed — the day the shop started keeping
    # its books here. No money moves on that day; what moves is what a party
    # owes, and that is what a period of receivables or payables slices by.
    "balances.CustomerBalanceEntry": "effective_date",
    "balances.SupplierBalanceEntry": "effective_date",
    "balances.EmployeeBalanceEntry": "effective_date",
    # A loan's money leaves when it is handed over, which is when it is
    # approved; a loan approved before that was recorded has no date and is in
    # no period.
    "employees.EmployeeLoan": "disbursed_at",
}


class UnknownMoneyModel(LookupError):
    """Raised when a model is sliced by period without declaring its money date."""


def money_date_field(model) -> str:
    label = model._meta.label
    try:
        return MONEY_DATE_FIELDS[label]
    except KeyError as exc:  # pragma: no cover - guarded by a test
        raise UnknownMoneyModel(
            f"{label} has no money date. Add it to MONEY_DATE_FIELDS in "
            "apps/core/money_dates.py rather than filtering it by hand."
        ) from exc


def money_period(queryset, start, end):
    """Slice a money queryset to the business-local days ``start``..``end``.

    Works for both date and datetime columns: a date column is compared
    inclusively, a datetime column against the half-open interval that covers
    the same local days, so the two never disagree about a midnight.

    ``None`` leaves that side open: ``money_period(qs, None, end)`` is
    everything up to and including ``end``, which is what a balance needs. It
    must not reach ``day_range_start``, whose "today when omitted" turned that
    call into "today to ``end``" on a timestamp column (and an error on a date
    column), so the treasury subtracted only today's provider-float draws.
    """
    model = queryset.model
    field = money_date_field(model)
    date_column = _is_date_field(model, field)
    bounds = {}
    if start is not None:
        bounds[f"{field}__gte"] = start if date_column else day_range_start(start)
    if end is not None:
        if date_column:
            bounds[f"{field}__lte"] = end
        else:
            bounds[f"{field}__lt"] = day_range_end(end)
    return queryset.filter(**bounds)


def _is_date_field(model, field_name) -> bool:
    field = model._meta.get_field(field_name)
    return field.get_internal_type() == "DateField"


def day_range_start(value: date | None = None) -> datetime:
    """Midnight at the start of ``value`` (today when omitted)."""
    value = value or timezone.localdate()
    return _localize(datetime.combine(value, time.min))


def day_range_end(value: date) -> datetime:
    """The exclusive upper bound covering all of ``value``."""
    return _localize(datetime.combine(value, time.max)) + timedelta(microseconds=1)


def _localize(naive: datetime) -> datetime:
    return timezone.make_aware(naive, timezone.get_current_timezone())


__all__ = [
    "MONEY_DATE_FIELDS",
    "UnknownMoneyModel",
    "day_range_end",
    "day_range_start",
    "money_date_field",
    "money_period",
]
