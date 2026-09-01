"""Which records a report may read, and how to slice them by day.

**Scope.** Reports used to narrow their sources to the register sessions the
running user personally owns unless that user was a *manager*. Every other
reading surface in the codebase — the dashboard, the orders list, the payments
list, printing — narrows on ``user_has_full_visibility``, which deliberately
includes accountants, auditors and supervisors; the reports layer was the only
one never moved across. The effect was not an empty screen but a confidently
wrong document: an accountant, who owns no register sessions, received a signed
PDF stating the shop had sold nothing, while the dashboard on the next tab
showed them the real revenue. One helper, used by every builder, is the fix.

**Days.** A daily breakdown is one GROUP BY, not one query per day, and it is
built from the same money-date column ``money_period`` slices by — so a figure
in a day row and the same figure in the total can never be dated differently.
"""

from decimal import Decimal

from django.db.models import Count, DecimalField, Prefetch, Sum, Value
from django.db.models.functions import Coalesce, TruncDate

from apps.catalog.models import VariantOptionValue
from apps.core.money_dates import (
    day_range_end,
    day_range_start,
    money_date_field,
    money_period,
)
from apps.core.roles import user_has_full_visibility
from apps.payments.models import Payment
from apps.sales.models import Order, OrderAdjustment, RegisterSession

MONEY_FIELD = DecimalField(max_digits=14, decimal_places=2)
ZERO_MONEY = Value(Decimal("0.00"), output_field=MONEY_FIELD)


def settled_orders(user):
    return _scoped(Order.objects.transactional(), user, "register_session__owner_key")


def order_adjustments(user):
    return _scoped(OrderAdjustment.objects.all(), user, "register_session__owner_key")


def payments(user):
    queryset = Payment.objects.select_related("order", "order__register_session")
    return _scoped(queryset, user, "order__register_session__owner_key")


def register_sessions(user):
    return _scoped(RegisterSession.objects.all(), user, "owner_key")


def _scoped(queryset, user, owner_path):
    # ``None`` is the scheduler (apps.reports.tasks): it owns no till, so
    # scoping it to one would snapshot an empty month. Unreachable from the
    # API — every view passes ``request.user``.
    if user is None or user_has_full_visibility(user):
        return queryset
    return queryset.filter(**{owner_path: owner_key(user)})


def owner_key(user):
    return f"user:{user.pk}"


def in_period(queryset, period):
    """The period's slice of a money queryset, dated by the one column that
    says when its money moved."""
    return money_period(queryset, period.start_date, period.end_date)


def in_window(queryset, period, field="created_at"):
    """The period's slice of a queryset whose subject is not money.

    A stock movement is an event, not a payment, so it has no entry in the
    money-date registry and must not acquire one — ``money_period`` refusing it
    is the registry working. This is the plain calendar-day window for those,
    on the same clock and the same inclusive-both-ends semantics.
    """
    return queryset.filter(
        **{
            f"{field}__gte": day_range_start(period.start_date),
            f"{field}__lt": day_range_end(period.end_date),
        }
    )


def daily_totals(queryset, period, *, date_field=None, **aggregates):
    """``{date: {name: value}}`` for every day that has activity.

    One grouped query whatever the length of the period. Days with no activity
    are absent rather than zero-filled — the caller decides whether a quiet day
    should print as a zero row or be skipped, and only the caller knows which
    reads better for its subject.
    """
    field = date_field or money_date_field(queryset.model)
    rows = (
        queryset.annotate(_day=TruncDate(field))
        .values("_day")
        .annotate(**aggregates)
        .order_by("_day")
    )
    return {
        row["_day"]: {name: row[name] for name in aggregates}
        for row in rows
        if row["_day"] is not None
    }


def money_sum(field):
    return Coalesce(Sum(field), ZERO_MONEY, output_field=MONEY_FIELD)


def row_count():
    return Count("id")


def with_variant_labels(queryset):
    """Carry the option values that ``ProductVariant.full_name`` reads.

    A product's default variant has an empty ``name``, so ``full_name`` falls
    through to ``option_values_label`` — which queries ``option_values`` unless
    they are already prefetched. That is one query per detail row, and it is
    invisible in the report code because it hides behind a plain attribute read.
    The inner ``select_related("option")`` matters too: the prefetched branch of
    ``option_values_label`` reads each value's ``option`` to build its label.
    """
    return queryset.prefetch_related(
        Prefetch(
            "variant__option_values",
            queryset=VariantOptionValue.objects.select_related("option"),
        )
    )


__all__ = [
    "daily_totals",
    "in_period",
    "in_window",
    "money_sum",
    "order_adjustments",
    "owner_key",
    "payments",
    "register_sessions",
    "row_count",
    "settled_orders",
    "with_variant_labels",
]
