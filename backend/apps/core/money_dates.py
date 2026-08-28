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

Period semantics are business-local days, inclusive on both ends: "1 August to
31 August" means every money event stamped inside those days in the shop's own
timezone, whichever column carries the stamp.
"""

from datetime import date, datetime, time, timedelta

from apps.core.timeutils import business_local_date, business_timezone

# model label -> the field that says when the money moved.
MONEY_DATE_FIELDS = {
    "payments.Payment": "paid_at",
    "sales.Order": "created_at",
    "sales.OrderAdjustment": "created_at",
    "sales.RegisterCashMovement": "created_at",
    "sales.RegisterSession": "opened_at",
    "expenses.Expense": "spent_at",
    "purchasing.SupplierPayment": "paid_at",
    "purchasing.PurchaseOrder": "created_at",
    "employees.PayrollRun": "payment_date",
    "treasury.MoneyTransfer": "moved_at",
    "treasury.MoneyCount": "counted_at",
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
    """
    model = queryset.model
    field = money_date_field(model)
    if _is_date_field(model, field):
        return queryset.filter(**{f"{field}__gte": start, f"{field}__lte": end})
    return queryset.filter(
        **{
            f"{field}__gte": day_range_start(start),
            f"{field}__lt": day_range_end(end),
        }
    )


def _is_date_field(model, field_name) -> bool:
    field = model._meta.get_field(field_name)
    return field.get_internal_type() == "DateField"


def day_range_start(value: date | None = None) -> datetime:
    """Business-local midnight at the start of ``value`` (today when omitted)."""
    value = value or business_local_date()
    return _localize(datetime.combine(value, time.min))


def day_range_end(value: date) -> datetime:
    """The exclusive upper bound covering all of ``value``."""
    return _localize(datetime.combine(value, time.max)) + timedelta(microseconds=1)


def _localize(naive: datetime) -> datetime:
    return naive.replace(tzinfo=business_timezone())


__all__ = [
    "MONEY_DATE_FIELDS",
    "UnknownMoneyModel",
    "day_range_end",
    "day_range_start",
    "money_date_field",
    "money_period",
]
