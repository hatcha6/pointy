"""Opening balances and adjustments on a customer's account.

Two directions, carried two ways (see ``apps.balances.models``):

* **They owe us** — an ``ACCOUNT_ENTRY`` order carries the debt, so collecting
  it is the collection the till already does: the same dialog, the same drawer,
  the same proof of payment. Nothing about it is a sale.
* **We owe them** — credit. It is spent against what the customer owes by
  :func:`apply_customer_credit`, which writes one non-money ``ACCOUNT_CREDIT``
  payment per debt it settles and links it back to the credit it drew on.

When credit is spent, and when it deliberately is not
------------------------------------------------------
Credit is applied when an entry is written (either way round), when the
customer's account is collected, and when someone asks for it on the
customer's screen. It is **not** applied at the till when an آجل sale is rung
up, and that is on purpose: the returns desk fixes a sale rung up to the wrong
customer by reassigning it, which is only allowed while nothing has been paid
against it. Spending the wrong customer's credit on it at checkout would lock
that mistake in. Until the next collection the customer therefore can hold both
a debt and credit at once, and every figure that matters states the two
together: what they owe is reported *net* of their credit, which is exactly
what the collection will ask them for.
"""

from __future__ import annotations

from dataclasses import dataclass
from decimal import Decimal

from django.db import transaction
from django.db.models import Count, DecimalField, OuterRef, Q, Subquery, Sum, Value
from django.db.models.functions import Coalesce
from django.utils import timezone

from rest_framework import serializers

from apps.analytics.models import AnalyticsEvent
from apps.analytics.services import record_domain_event
from apps.documents.statuses import DocumentStatus

from . import common
from .models import CustomerBalanceEntry, CustomerCreditApplication

ZERO = Decimal("0.00")
MONEY_FIELD = DecimalField(max_digits=12, decimal_places=2)
ENTITY = "customer_balance_entry"


# ---------------------------------------------------------------------------
# Writing an entry
# ---------------------------------------------------------------------------


@transaction.atomic
def create_customer_entry(
    *,
    customer,
    kind,
    direction,
    amount,
    effective_date=None,
    note="",
    actor=None,
):
    """Record an opening balance or an adjustment on ``customer``'s account."""
    from apps.customers.models import Customer

    common.refuse_written_refund(kind)
    cleaned = common.clean_entry_input(
        kind=kind,
        direction=direction,
        amount=amount,
        effective_date=effective_date,
        note=note,
    )
    # One writer per account at a time: the opening-balance check below and the
    # credit applied after it both read what the account already holds.
    customer = Customer.objects.select_for_update().get(pk=customer.pk)
    if cleaned.kind == common.Kind.OPENING:
        common.refuse_second_opening(
            customer.balance_entries.live().filter(kind=common.Kind.OPENING),
            party_label="customer",
        )
    common.assert_entry_period_open(
        cleaned.effective_date, user=actor, entity_type=ENTITY
    )

    entry = CustomerBalanceEntry(
        customer=customer,
        kind=cleaned.kind,
        direction=cleaned.direction,
        amount=cleaned.amount,
        effective_date=cleaned.effective_date,
        note=cleaned.note,
        created_by=actor,
    )
    if cleaned.direction == common.Direction.THEY_OWE_US:
        # Numbered before either row is written, so the carrier order is
        # issued under the entry's own number rather than taking a receipt
        # number — which would leave a hole in the sales series, the thing
        # that series exists never to have.
        common.allocate_number(entry)
        entry.order = _create_carrier(entry, actor=actor)
    entry.save()
    common.record_issued(entry, actor=actor)
    record_domain_event(
        name="balances.customer_entry.created",
        event_type=AnalyticsEvent.EventType.AUDIT,
        user=actor,
        entity_type=ENTITY,
        entity_id=entry.pk,
        attributes={
            "number": entry.number,
            "customer_id": customer.pk,
            "kind": entry.kind,
            "direction": entry.direction,
            "effective_date": entry.effective_date.isoformat(),
        },
        metrics={"amount": float(entry.amount)},
    )
    # A debt written onto an account that holds credit, or credit written onto
    # one that owes, settles against the other straight away — the customer
    # should never be shown owing and owed at once because of an entry.
    apply_customer_credit(customer, actor=actor)
    return entry


def _create_carrier(entry, *, actor):
    """The order that makes a debt collectable at the till.

    Issued already submitted and never through checkout: it sells nothing, so
    it has no lines, no register session, no stock movement and no discount
    run. It is dated at the entry's effective date so that "oldest first" —
    which is how a collection is allocated — treats an opening balance as the
    oldest thing the customer owes.
    """
    from apps.sales import documents as sales_documents
    from apps.sales.models import Order

    now = timezone.now()
    order = Order(
        customer=entry.customer,
        sale_type=Order.SaleType.ACCOUNT_ENTRY,
        status=Order.Status.OPEN,
        receipt_number=entry.number,
        subtotal=entry.amount,
        discount_total=ZERO,
        total=entry.amount,
        doc_status=DocumentStatus.SUBMITTED,
        submitted_at=now,
        submitted_by=actor,
    )
    order.save()
    stamped = common.effective_datetime(entry.effective_date)
    if stamped != order.created_at:
        # ``created_at`` is the order's money date and ``auto_now_add`` gives
        # no other way to set it; it is housekeeping to the freeze, precisely so
        # history can be given a date.
        Order.objects.filter(pk=order.pk).update(created_at=stamped)
        order.created_at = stamped
    sales_documents.recompute_progress(order)
    return order


@transaction.atomic
def refund_customer_credit(*, customer, amount, note="", actor=None):
    """Hand a customer, in cash, credit the shop owes them.

    Three things, in one transaction, each through the machinery that already
    owns it: a debt of ``amount`` written onto the account — the customer has
    been paid — settled at once from their credit, exactly as a collection
    would spend it; and the cash leaving the actor's own drawer as a pay-out,
    which the drawer count, the Z-report and the money position all read.

    Refused when the customer is owed less than ``amount`` once their debts
    have taken what the credit already owed them, and refused without an open
    register session — cash leaves a drawer, and the drawer is how the shop
    will know it did.
    """
    from apps.customers.models import Customer

    cleaned = common.clean_entry_input(
        kind=common.Kind.REFUND,
        direction=common.Direction.THEY_OWE_US,
        amount=amount,
        note=note,
    )
    session = common.open_drawer_for(actor)
    customer = Customer.objects.select_for_update().get(pk=customer.pk)
    # The credit settles what the customer owes first; only what is left of it
    # is theirs to take away in cash.
    apply_customer_credit(customer, actor=actor)
    available = account_position(customer).unapplied_credit
    if cleaned.amount > available:
        raise serializers.ValidationError(
            {
                "amount": (
                    f"The shop owes this customer {available:.2f}; it cannot "
                    f"refund {cleaned.amount:.2f}."
                ),
                "code": "refund_exceeds_credit",
                "available": f"{available:.2f}",
            }
        )

    entry = CustomerBalanceEntry(
        customer=customer,
        kind=common.Kind.REFUND,
        direction=common.Direction.THEY_OWE_US,
        amount=cleaned.amount,
        effective_date=cleaned.effective_date,
        note=cleaned.note,
        created_by=actor,
    )
    common.allocate_number(entry)
    entry.order = _create_carrier(entry, actor=actor)
    entry.cash_movement = common.drawer_movement(
        session,
        outgoing=True,
        amount=entry.amount,
        reason=f"رد رصيد للعميل {customer.full_name} ({entry.number})",
        actor=actor,
    )
    entry.save()
    common.record_issued(entry, actor=actor)
    apply_customer_credit(customer, actor=actor)
    # Every other debt was settled above, so the credit could only have gone
    # to this one — and it covers it, by the check above. Anything else is a
    # broken invariant, and the whole refund is rolled back rather than
    # handing money out against a debt left open.
    carrier = entry.order
    carrier.refresh_from_db()
    if carrier.balance_due > 0:
        raise RuntimeError(
            f"Refund {entry.number} was not settled from the customer's credit."
        )
    record_domain_event(
        name="balances.customer_credit.refunded",
        event_type=AnalyticsEvent.EventType.AUDIT,
        user=actor,
        entity_type=ENTITY,
        entity_id=entry.pk,
        attributes={
            "number": entry.number,
            "customer_id": customer.pk,
            "register_session_id": session.pk,
        },
        metrics={"amount": float(entry.amount)},
    )
    return entry


# ---------------------------------------------------------------------------
# Retracting an entry
# ---------------------------------------------------------------------------


def reverse_entry(entry, *, at, actor, reason="", context=None):
    """What cancelling an entry gives back — the registry's ``reverse`` hook.

    Only an untouched entry can be cancelled. Once the debt has been collected
    from, or the credit spent, the entry is part of the customer's history: the
    correction is then a second entry the other way, which the statement shows
    as the correction it is.
    """
    common.refuse_refund_cancel(entry)
    if entry.direction == common.Direction.WE_OWE_THEM:
        # ``blocks_cancel`` on the registration refuses a spent credit before
        # this runs; there is nothing else a credit put anywhere.
        return None
    from apps.sales import documents as sales_documents
    from apps.sales.models import Order

    order = Order.objects.select_for_update().get(pk=entry.order_id)
    payments = list(order.payments.all()[:5])
    if payments:
        raise common.blocked(
            entry, label="دفعات محصّلة من هذا الرصيد", rows=payments
        )
    # The carrier goes with its entry. Not through ``documents.cancel``: that
    # would ask this user for the right to void a *sale*, and this is not one —
    # the entry's own cancel permission and period lock were checked already.
    order.doc_status = DocumentStatus.CANCELLED
    order.cancelled_at = at
    order.cancelled_by = actor
    order.cancel_reason = reason or ""
    order.save(
        update_fields=[
            "doc_status",
            "cancelled_at",
            "cancelled_by",
            "cancel_reason",
            "updated_at",
        ]
    )
    sales_documents.recompute_progress(order)
    return None


# ---------------------------------------------------------------------------
# Credit
# ---------------------------------------------------------------------------


def credit_remaining_by_entry(entries):
    """What is left of each credit entry: its amount less what it has spent."""
    ids = [entry.pk for entry in entries]
    if not ids:
        return {}
    spent = {
        row["entry"]: row["total"] or ZERO
        for row in CustomerCreditApplication.objects.filter(entry_id__in=ids)
        .values("entry")
        .annotate(total=Sum("amount"))
    }
    return {
        entry.pk: max(entry.amount - spent.get(entry.pk, ZERO), ZERO)
        for entry in entries
    }


def unapplied_credit_by_customer(customer_ids):
    """What the shop still owes each customer in account credit, in one query.

    Live credit entries less everything their applications have spent.
    """
    customer_ids = list(customer_ids)
    if not customer_ids:
        return {}
    rows = (
        CustomerBalanceEntry.objects.live()
        .filter(
            customer_id__in=customer_ids,
            direction=common.Direction.WE_OWE_THEM,
        )
        .order_by()
        .values("customer_id")
        .annotate(issued=Sum("amount"))
    )
    spent = {
        row["entry__customer_id"]: row["total"] or ZERO
        for row in CustomerCreditApplication.objects.filter(
            entry__customer_id__in=customer_ids,
            entry__doc_status=DocumentStatus.SUBMITTED,
        )
        .order_by()
        .values("entry__customer_id")
        .annotate(total=Sum("amount"))
    }
    return {
        row["customer_id"]: max(
            (row["issued"] or ZERO) - spent.get(row["customer_id"], ZERO), ZERO
        ).quantize(ZERO)
        for row in rows
    }


@dataclass(frozen=True)
class AccountPosition:
    """What the entries on one customer's account say."""

    unapplied_credit: Decimal
    has_opening: bool


def account_position(customer) -> AccountPosition:
    """The credit the shop still owes a customer, and whether an opening
    balance is on record — in one read, and a second only when there is credit
    to net (the customer screen asks for both on every open)."""
    row = (
        CustomerBalanceEntry.objects.live()
        .filter(customer_id=customer.pk)
        .aggregate(
            credit_issued=Sum(
                "amount", filter=Q(direction=common.Direction.WE_OWE_THEM)
            ),
            openings=Count("pk", filter=Q(kind=common.Kind.OPENING)),
        )
    )
    issued = row["credit_issued"] or ZERO
    spent = ZERO
    if issued > 0:
        spent = (
            CustomerCreditApplication.objects.filter(entry__customer_id=customer.pk)
            .exclude(entry__doc_status=DocumentStatus.CANCELLED)
            .aggregate(total=Sum("amount"))["total"]
            or ZERO
        )
    return AccountPosition(
        unapplied_credit=max(issued - spent, ZERO).quantize(ZERO),
        has_opening=bool(row["openings"]),
    )


def unapplied_credit(customer) -> Decimal:
    return account_position(customer).unapplied_credit


def customers_holding_credit() -> set:
    """Every customer the shop still owes account credit to.

    Bounded by the customers who have ever been given credit, which is a
    handful in any shop — never a walk over the whole customer table.
    """
    ids = (
        CustomerBalanceEntry.objects.live()
        .filter(direction=common.Direction.WE_OWE_THEM)
        .order_by()
        .values_list("customer_id", flat=True)
        .distinct()
    )
    return {
        customer_id
        for customer_id, credit in unapplied_credit_by_customer(ids).items()
        if credit > 0
    }


@transaction.atomic
def apply_customer_credit(customer, *, actor=None):
    """Spend the customer's credit against what they owe, oldest first on both
    sides. Returns the applications written — empty when there was nothing to
    do, which is the common case and costs one indexed query.

    Each settlement is an ``ACCOUNT_CREDIT`` payment on the debt (an invoice or
    an account entry), dated now, attributed to no drawer, linked back to the
    credit it drew on. A debt that is settled in full is flipped to paid by the
    same progress rule every payment goes through.
    """
    from apps.customers.models import Customer
    from apps.payments.models import Payment
    from apps.sales import documents as sales_documents
    from apps.sales.models import Order

    has_credit = (
        CustomerBalanceEntry.objects.live()
        .filter(customer_id=customer.pk, direction=common.Direction.WE_OWE_THEM)
        .exists()
    )
    if not has_credit:
        return []

    # Lock order: the account first, then its documents — the same order an
    # account collection takes, so the two can never wait on each other.
    Customer.objects.select_for_update().filter(pk=customer.pk).first()
    credits = list(
        CustomerBalanceEntry.objects.live()
        .filter(customer_id=customer.pk, direction=common.Direction.WE_OWE_THEM)
        .select_for_update()
        .order_by("effective_date", "id")
    )
    remaining = credit_remaining_by_entry(credits)
    credits = [entry for entry in credits if remaining[entry.pk] > 0]
    if not credits:
        return []

    debts = list(
        Order.objects.open_receivables()
        .filter(customer_id=customer.pk)
        .select_for_update()
        .order_by("created_at", "id")
    )
    if not debts:
        return []

    now = timezone.now()
    applications = []
    for debt in debts:
        # Fresh from the database, not a prefetch: an earlier pass of this
        # loop may be the thing that just paid it.
        due = debt.balance_due
        touched = False
        while due > 0 and credits:
            entry = credits[0]
            take = min(remaining[entry.pk], due)
            payment = Payment.objects.create(
                order=debt,
                method=Payment.Method.ACCOUNT_CREDIT,
                amount=take,
                commission_percent=ZERO,
                commission_amount=ZERO,
                external_reference=entry.number[:128],
                register_session=None,
                created_by=actor,
                paid_at=now,
            )
            applications.append(
                CustomerCreditApplication.objects.create(
                    entry=entry, payment=payment, amount=take
                )
            )
            touched = True
            due -= take
            remaining[entry.pk] -= take
            if remaining[entry.pk] <= 0:
                credits.pop(0)
        if touched:
            # ``balance_due`` reads the payments relation; drop any cache so
            # the progress rule sees the rows just written.
            debt = Order.objects.get(pk=debt.pk)
            sales_documents.recompute_progress(debt)
        if not credits:
            break

    if applications:
        record_domain_event(
            name="balances.customer_credit.applied",
            event_type=AnalyticsEvent.EventType.AUDIT,
            user=actor,
            entity_type="customer",
            entity_id=customer.pk,
            attributes={
                "application_count": len(applications),
                "orders": sorted({app.payment.order_id for app in applications}),
            },
            metrics={
                "amount": float(sum((app.amount for app in applications), ZERO))
            },
        )
    return applications


# ---------------------------------------------------------------------------
# Reading an account
# ---------------------------------------------------------------------------


def entry_settled_amount(entry) -> Decimal:
    """How much of an entry has been settled: collected from a debt, or spent
    from a credit."""
    if entry.direction == common.Direction.THEY_OWE_US:
        if entry.order_id is None:
            return ZERO
        order = entry.order
        return min(order.amount_paid, entry.amount).quantize(ZERO) if order else ZERO
    spent = entry.applications.aggregate(total=Sum("amount"))["total"] or ZERO
    return min(spent, entry.amount).quantize(ZERO)


def live_entries(customer):
    return customer.balance_entries.live()


def has_live_opening(customer) -> bool:
    return (
        CustomerBalanceEntry.objects.live()
        .filter(customer_id=customer.pk, kind=common.Kind.OPENING)
        .exists()
    )


def entries_with_settlement(queryset):
    """Annotate what each entry has settled, in the listing's own query.

    A debt entry is settled by the payments on its carrier order (a refund, a
    negative row, counts against them the way it does on an invoice); a credit
    entry by its applications. Two correlated subqueries rather than two joined
    sums, which would multiply each other's rows.
    """
    from apps.payments.models import Payment

    collected = (
        Payment.objects.filter(order_id=OuterRef("order_id"))
        .order_by()
        .values("order_id")
        .annotate(total=Sum("amount"))
        .values("total")[:1]
    )
    spent = (
        CustomerCreditApplication.objects.filter(entry_id=OuterRef("pk"))
        .order_by()
        .values("entry_id")
        .annotate(total=Sum("amount"))
        .values("total")[:1]
    )
    return queryset.select_related("created_by", "cancelled_by").annotate(
        settled_collected=Coalesce(
            Subquery(collected, output_field=MONEY_FIELD), Value(ZERO)
        ),
        settled_spent=Coalesce(Subquery(spent, output_field=MONEY_FIELD), Value(ZERO)),
    )


def settled_amount(entry) -> Decimal:
    """What :func:`entries_with_settlement` annotated, read the same way for
    both directions, and never more than the entry itself."""
    if entry.direction == common.Direction.THEY_OWE_US:
        settled = getattr(entry, "settled_collected", None)
    else:
        settled = getattr(entry, "settled_spent", None)
    if settled is None:
        return entry_settled_amount(entry)
    return min(max(Decimal(settled), ZERO), entry.amount).quantize(ZERO)


__all__ = [
    "AccountPosition",
    "account_position",
    "apply_customer_credit",
    "refund_customer_credit",
    "create_customer_entry",
    "credit_remaining_by_entry",
    "entries_with_settlement",
    "entry_settled_amount",
    "has_live_opening",
    "reverse_entry",
    "settled_amount",
    "unapplied_credit",
    "unapplied_credit_by_customer",
]
