"""Staff purchases: what employees buy from the shop, taken back through payroll.

Every employee has a customer account of their own (``Employee.customer``),
made with the employee. A member of staff who takes goods home is rung up on
that account as an آجل (credit) invoice — an ordinary sale: stock leaves,
revenue is recognised, and the employee owes the invoice like any customer.

The next payroll run deducts what is owed, one adjustment per invoice, oldest
invoice first and never more than the line's pay can carry; what does not fit
stays owed and the run after takes it. Paying the run settles those invoices
with a ``salary_deduction`` payment, which moves no money — the wage paid out
is smaller by exactly what it settled — and voiding a paid run gives the
settlements back, so the invoices are owed again.

Nothing here invents a second receivable. The invoice *is* the debt, the same
row every aging report, customer balance and balance sheet already reads.
"""

from collections import defaultdict
from datetime import datetime, time
from decimal import Decimal

from django.db import transaction
from django.db.models import Sum
from django.utils import timezone
from rest_framework import serializers

from apps.documents.statuses import DocumentStatus

from .models import Employee, PayrollAdjustment, PayrollRun

MONEY_PLACES = Decimal("0.01")
ZERO = Decimal("0.00")


def ensure_staff_customer(employee, *, created_by=None):
    """The employee's own customer account, created the first time it is needed.

    Locks the employee row so two tills asking at once cannot mint two
    accounts for the same person.
    """
    if employee.customer_id is not None:
        return employee.customer

    from apps.analytics.models import AnalyticsEvent
    from apps.analytics.services import record_domain_event
    from apps.customers.models import Customer

    with transaction.atomic():
        locked = Employee.objects.select_for_update().get(pk=employee.pk)
        if locked.customer_id is None:
            locked.customer = Customer.objects.create(
                full_name=locked.full_name or locked.employee_number,
                phone=locked.phone,
                email=locked.email,
            )
            locked.save(update_fields=["customer", "updated_at"])
            record_domain_event(
                name="customers.customer.created",
                event_type=AnalyticsEvent.EventType.AUDIT,
                user=created_by,
                entity_type="customer",
                entity_id=locked.customer_id,
                attributes={
                    "customer_number": locked.customer.customer_number,
                    "staff_employee_id": locked.pk,
                    "auto_created": True,
                },
            )
    employee.customer = locked.customer
    return employee.customer


def staff_customer_for_user(user, *, created_by=None):
    """The signed-in user's staff account — the "me" a cashier picks at the till.

    Makes the employee as well when the account predates automatic employee
    creation, so the button works for every user rather than only new ones.
    """
    from .services import ensure_employee_for_user

    employee = ensure_employee_for_user(user, created_by=created_by or user)
    return ensure_staff_customer(employee, created_by=created_by or user)


def _is_staff_purchase(adjustment_queryset):
    return adjustment_queryset.filter(
        adjustment_type=PayrollAdjustment.AdjustmentType.STAFF_PURCHASE,
        direction=PayrollAdjustment.Direction.DEDUCTION,
    )


def staff_purchases_withheld(runs):
    """What ``runs`` kept back from wages to settle staff purchases.

    Labour cost is the whole wage. The part an employee took home as the shop's
    own goods is revenue already, so a wage bill counted net of it would book
    the same money twice — once as a sale, once as a smaller wage.
    """
    total = _is_staff_purchase(
        PayrollAdjustment.objects.filter(payroll_line__payroll_run__in=runs)
    ).aggregate(total=Sum("amount"))["total"]
    return (total or ZERO).quantize(MONEY_PLACES)


def _open_invoices_by_customer(customer_ids):
    from apps.sales.models import Order

    invoices = (
        Order.objects.open_credit()
        .filter(customer_id__in=customer_ids, doc_status=DocumentStatus.SUBMITTED)
        # ``balance_due`` sums payments in Python; prefetched, it costs one query
        # for the whole run rather than one per invoice.
        .prefetch_related("payments")
        .order_by("created_at", "id")
    )
    by_customer = defaultdict(list)
    for invoice in invoices:
        by_customer[invoice.customer_id].append(invoice)
    return by_customer


def _scheduled_in_other_runs(order_ids, *, payroll_run):
    """What other unpaid runs have already promised to take from each invoice.

    Two open drafts must not both deduct the same debt. A paid run needs no
    counting here: its settlement is already a payment against the invoice, so
    it is already out of ``balance_due``.
    """
    rows = (
        _is_staff_purchase(PayrollAdjustment.objects)
        .filter(
            order_id__in=order_ids,
            payroll_line__payroll_run__status__in=(
                PayrollRun.Status.DRAFT,
                PayrollRun.Status.APPROVED,
            ),
        )
        .exclude(payroll_line__payroll_run_id=payroll_run.pk)
        .values("order_id")
        .order_by()
        .annotate(total=Sum("amount"))
    )
    return {row["order_id"]: row["total"] or ZERO for row in rows}


@transaction.atomic
def refresh_staff_purchase_deductions(payroll_run):
    """Re-derive every staff-purchase deduction on a draft run from what is owed now.

    Run when the draft is made and again when it is approved, so the approved
    run takes exactly what the staff owe at that moment: an invoice paid off in
    cash in the meantime drops out, one bought since comes in. Returns the run,
    re-read with its new totals.
    """
    if payroll_run.status != PayrollRun.Status.DRAFT:
        raise serializers.ValidationError(
            {"detail": "Only draft payroll runs can be changed."}
        )
    _is_staff_purchase(
        PayrollAdjustment.objects.filter(payroll_line__payroll_run=payroll_run)
    ).delete()

    lines = list(
        payroll_run.lines.select_related("employee", "compensation_plan", "payroll_run")
        .prefetch_related("adjustments")
        .order_by("id")
    )
    customer_ids = {line.employee.customer_id for line in lines} - {None}
    invoices_by_customer = _open_invoices_by_customer(customer_ids) if customer_ids else {}
    scheduled = _scheduled_in_other_runs(
        [
            invoice.pk
            for invoices in invoices_by_customer.values()
            for invoice in invoices
        ],
        payroll_run=payroll_run,
    )

    deductions = []
    for line in lines:
        invoices = invoices_by_customer.get(line.employee.customer_id)
        if not invoices:
            continue
        # The pay this line has left once everything else is taken off it.
        line.recalculate()
        available = line.net_amount
        for invoice in invoices:
            if available <= ZERO:
                break
            owed = (invoice.balance_due - scheduled.get(invoice.pk, ZERO)).quantize(
                MONEY_PLACES
            )
            if owed <= ZERO:
                continue
            amount = min(owed, available)
            deductions.append(
                PayrollAdjustment(
                    payroll_line=line,
                    direction=PayrollAdjustment.Direction.DEDUCTION,
                    adjustment_type=PayrollAdjustment.AdjustmentType.STAFF_PURCHASE,
                    amount=amount,
                    order=invoice,
                )
            )
            available -= amount
    # Created oldest invoice first, so the newest one is the first to give way
    # if the line's pay later shrinks (``PayrollLine.recalculate``).
    PayrollAdjustment.objects.bulk_create(deductions)

    payroll_run = PayrollRun.objects.get(pk=payroll_run.pk)
    payroll_run.recalculate(save_lines=True)
    payroll_run.save(
        update_fields=[
            "gross_total",
            "additions_total",
            "deductions_total",
            "net_total",
            "updated_at",
        ]
    )
    return payroll_run


def _money_moment(payment_date):
    """``paid_at`` for a settlement, on the run's own money date.

    The run is filed under ``payment_date``; its settlements must land on the
    same day, or a period report could take the smaller wage and miss the
    settlement that made it smaller.
    """
    today = timezone.localdate()
    if payment_date is None or payment_date == today:
        return timezone.now()
    return timezone.make_aware(datetime.combine(payment_date, time(12, 0)))


def _still_owed_by(invoice, employee):
    from apps.sales.models import Order

    return (
        invoice.sale_type == Order.SaleType.CREDIT
        and invoice.status == Order.Status.OPEN
        and invoice.doc_status == DocumentStatus.SUBMITTED
        and invoice.customer_id is not None
        and invoice.customer_id == employee.customer_id
    )


def settle_staff_purchases(payroll_run, *, actor=None):
    """Settle the run's staff-purchase invoices. Called while paying it.

    Runs before the run is submitted, because it may have to shrink a
    deduction: an invoice the employee paid off at the till after the run was
    approved must not be charged to their wages as well. Each deduction is cut
    to what its invoice still owes, the run's totals follow, and only then does
    each invoice get its ``salary_deduction`` payment.
    """
    from apps.payments.models import Payment
    from apps.sales import documents as sales_documents
    from apps.sales.models import Order

    adjustments = list(
        _is_staff_purchase(
            PayrollAdjustment.objects.filter(
                payroll_line__payroll_run=payroll_run,
                settlement_payment__isnull=True,
            )
        )
        .select_related("payroll_line__employee")
        .order_by("payroll_line_id", "id")
    )
    if not adjustments:
        return payroll_run

    invoices = {
        invoice.pk: invoice
        for invoice in Order.objects.select_for_update()
        .filter(pk__in={adjustment.order_id for adjustment in adjustments} - {None})
        .order_by("pk")
    }
    shrunk = False
    to_settle = []
    for adjustment in adjustments:
        invoice = invoices.get(adjustment.order_id)
        owed = ZERO
        if invoice is not None and _still_owed_by(
            invoice, adjustment.payroll_line.employee
        ):
            owed = invoice.balance_due
        amount = min(adjustment.amount, owed)
        if amount < adjustment.amount:
            shrunk = True
            if amount <= ZERO:
                adjustment.delete()
                continue
            adjustment.amount = amount
            adjustment.save(update_fields=["amount", "updated_at"])
        to_settle.append((adjustment, invoice))

    if shrunk:
        payroll_run = PayrollRun.objects.get(pk=payroll_run.pk)
        payroll_run.recalculate(save_lines=True)
        payroll_run.save(
            update_fields=[
                "gross_total",
                "additions_total",
                "deductions_total",
                "net_total",
                "updated_at",
            ]
        )

    paid_at = _money_moment(payroll_run.payment_date)
    for adjustment, invoice in to_settle:
        payment = Payment.objects.create(
            order=invoice,
            method=Payment.Method.SALARY_DEDUCTION,
            amount=adjustment.amount,
            # No drawer took this: the wage was paid out smaller instead.
            register_session=None,
            created_by=actor,
            paid_at=paid_at,
            external_reference=f"payroll:{payroll_run.run_number}",
        )
        adjustment.settlement_payment = payment
        adjustment.save(update_fields=["settlement_payment", "updated_at"])
        sales_documents.recompute_progress(invoice)
    return payroll_run


def reverse_staff_purchase_settlements(payroll_run, *, at=None, actor=None, reason=""):
    """Give back what paying ``payroll_run`` settled. Part of voiding a paid run.

    Each settlement is undone the way every payment is — a counter payment,
    which reopens its invoice so the next run takes it again — and marked
    cancelled with the run's actor and reason. It is the run's cancellation
    that was authorised and checked against the period lock, for the same money
    date these settlements carry, so they are not put through the payment's own
    gate a second time: that would refuse a payroll accountant who holds no
    payments permission, and a manager whose override let the void through.

    Refused when an invoice has been returned since it was settled: the goods
    came back and the refund already went to the employee, so reopening the
    debt as well would charge them for the same goods twice or pay them twice.
    """
    from apps.documents import trail
    from apps.documents.models import DocumentEvent
    from apps.payments import documents as payment_documents
    from apps.sales.models import OrderAdjustment

    settlements = [
        adjustment.settlement_payment
        for adjustment in PayrollAdjustment.objects.select_related(
            "settlement_payment__order"
        ).filter(
            payroll_line__payroll_run=payroll_run,
            settlement_payment__isnull=False,
        )
        if adjustment.settlement_payment.doc_status != DocumentStatus.CANCELLED
    ]
    returned = [
        payment.order.receipt_number
        for payment in settlements
        if OrderAdjustment.objects.filter(
            order_id=payment.order_id, created_at__gte=payment.created_at
        ).exists()
    ]
    if returned:
        raise serializers.ValidationError(
            {
                "code": "staff_purchase_returned",
                "detail": (
                    "This payroll run settled invoices that have been returned "
                    "since, so it can no longer be voided."
                ),
                "invoices": returned,
            }
        )

    at = at or timezone.now()
    reason = reason or f"Payroll run {payroll_run.run_number} voided"
    for payment in settlements:
        payment_documents.reverse(payment, at=at, actor=actor, reason=reason)
        payment.doc_status = DocumentStatus.CANCELLED
        payment.cancelled_at = at
        payment.cancelled_by = actor
        payment.cancel_reason = reason
        payment.save(
            update_fields=[
                "doc_status",
                "cancelled_at",
                "cancelled_by",
                "cancel_reason",
                "updated_at",
            ]
        )
        trail.record(
            payment,
            DocumentEvent.Action.CANCELLED,
            actor=actor,
            reason=reason,
            details={"reversed": True, "cascaded": True},
        )


__all__ = [
    "ensure_staff_customer",
    "refresh_staff_purchase_deductions",
    "reverse_staff_purchase_settlements",
    "settle_staff_purchases",
    "staff_customer_for_user",
    "staff_purchases_withheld",
]
