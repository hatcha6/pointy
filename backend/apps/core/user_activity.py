from decimal import Decimal

from django.db.models import Count, Q, Sum

from apps.analytics.export import estimate_export_rows
from apps.analytics.models import AnalyticsEvent
from apps.analytics.scope import technical_events_q
from apps.purchasing.models import (
    PurchaseOrder,
    PurchaseOrderAdjustment,
    PurchaseOrderAuditEvent,
    PurchaseReceipt,
    SupplierPayment,
)
from apps.sales.models import (
    Order,
    recognized_sale_q,
    OrderAdjustment,
    RegisterCashMovement,
    RegisterSession,
    prime_register_session_cash_totals,
)


RECENT_LIMIT = 5


def build_user_activity(user):
    owner_key = f"user:{user.pk}"
    register_sessions = RegisterSession.objects.filter(owner_key=owner_key)
    sales_orders = Order.objects.transactional().filter(
        register_session__owner_key=owner_key,
    )
    sales_adjustments = OrderAdjustment.objects.filter(created_by=user)
    cash_movements = RegisterCashMovement.objects.filter(created_by=user)

    purchase_order_ids = list(
        PurchaseOrderAuditEvent.objects.filter(
            created_by=user,
            action=PurchaseOrderAuditEvent.Action.CREATED,
            purchase_order__isnull=False,
        )
        .values_list("purchase_order_id", flat=True)
        .distinct()
    )
    purchase_orders = PurchaseOrder.objects.filter(pk__in=purchase_order_ids)
    purchase_receipts = PurchaseReceipt.objects.filter(created_by=user)
    purchase_adjustments = PurchaseOrderAdjustment.objects.filter(created_by=user)
    supplier_payments = SupplierPayment.objects.live().filter(created_by=user)
    # The person's own actions — sales, receipts, edits — not the telemetry
    # their till emits about the software (a busy till writes millions of
    # request-timing rows a month under its cashier's name; counting those
    # took the users screen 57 s in the field).
    activity_events = AnalyticsEvent.objects.filter(received_by=user).exclude(
        technical_events_q()
    )

    credit_orders = sales_orders.filter(sale_type=Order.SaleType.CREDIT)

    return {
        "summary": {
            "sales": _sales_summary(sales_orders, sales_adjustments, credit_orders),
            "register_sessions": _register_session_summary(register_sessions),
            "cash_movements": _cash_movement_summary(cash_movements),
            "purchasing": _purchasing_summary(
                purchase_orders,
                purchase_receipts,
                purchase_adjustments,
            ),
            "supplier_payments": _supplier_payment_summary(supplier_payments),
            "activity": _activity_summary(activity_events),
        },
        # Two lists, not one with the debt mixed in: a credit (آجل) invoice is
        # money still owed, and reading a cashier's history for outstanding
        # tabs meant picking them out of a run of settled cash sales by eye.
        # They are disjoint on purpose — an invoice appears under exactly one.
        "recent_sales": [
            _sale_order_data(order)
            for order in sales_orders.exclude(sale_type=Order.SaleType.CREDIT)
            .select_related("customer", "register_session")
            .prefetch_related("payments")
            .order_by("-created_at")[:RECENT_LIMIT]
        ],
        "recent_credit_sales": [
            _sale_order_data(order)
            for order in credit_orders.select_related(
                "customer",
                "register_session",
            )
            .prefetch_related("payments")
            .order_by("-created_at")[:RECENT_LIMIT]
        ],
        "recent_purchase_orders": [
            _purchase_order_data(order)
            for order in purchase_orders.select_related("supplier").order_by(
                "-created_at",
            )[:RECENT_LIMIT]
        ],
        "recent_register_sessions": [
            _register_session_data(session)
            for session in prime_register_session_cash_totals(
                register_sessions.order_by("-opened_at")[:RECENT_LIMIT]
            )
        ],
        "recent_activity": [
            _activity_event_data(event)
            for event in activity_events.order_by(
                "-occurred_at",
                "-id",
            )[:RECENT_LIMIT]
        ],
    }


def _sales_summary(orders, adjustments, credit_orders):
    order_totals = orders.aggregate(
        invoice_count=Count("id"),
        paid_invoice_count=Count("id", filter=Q(status=Order.Status.PAID)),
        void_invoice_count=Count("id", filter=Q(status=Order.Status.VOID)),
        customer_count=Count(
            "customer",
            filter=Q(customer__isnull=False),
            distinct=True,
        ),
        paid_total=Sum("total", filter=recognized_sale_q()),
        void_total=Sum("total", filter=Q(status=Order.Status.VOID)),
    )
    adjustment_totals = adjustments.aggregate(
        return_count=Count(
            "id",
            filter=Q(adjustment_type=OrderAdjustment.AdjustmentType.RETURN),
        ),
        return_total=Sum(
            "amount",
            filter=Q(adjustment_type=OrderAdjustment.AdjustmentType.RETURN),
        ),
    )
    latest_order = orders.order_by("-created_at").first()
    net_sales = _decimal(order_totals["paid_total"]) - _decimal(
        adjustment_totals["return_total"]
    )

    # The debt this person issued, and how much of it is still owed. The
    # outstanding figure sums ``Order.balance_due`` — the one definition of what
    # an invoice still carries — over the OPEN credit only, which is a small set
    # by nature: a settled tab is not a receivable.
    credit_count = credit_orders.count()
    outstanding = sum(
        (
            order.balance_due
            for order in credit_orders.open_credit().prefetch_related("payments")
        ),
        Decimal("0.00"),
    )

    return {
        "invoice_count": order_totals["invoice_count"] or 0,
        "paid_invoice_count": order_totals["paid_invoice_count"] or 0,
        "void_invoice_count": order_totals["void_invoice_count"] or 0,
        "credit_invoice_count": credit_count,
        "credit_outstanding_total": _money(outstanding),
        "customer_count": order_totals["customer_count"] or 0,
        "net_sales": _money(net_sales),
        "void_total": _money(order_totals["void_total"]),
        "return_count": adjustment_totals["return_count"] or 0,
        "return_total": _money(adjustment_totals["return_total"]),
        "last_invoice_at": _iso(
            latest_order.created_at if latest_order else None
        ),
    }


def _register_session_summary(sessions):
    totals = sessions.aggregate(
        session_count=Count("id"),
        open_count=Count("id", filter=Q(status=RegisterSession.Status.OPEN)),
        closed_count=Count("id", filter=Q(status=RegisterSession.Status.CLOSED)),
        opening_cash_total=Sum("opening_cash"),
        closing_cash_total=Sum("closing_cash"),
    )
    # ``has_cash_variance`` walks four aggregates through ``expected_cash``, so
    # a cashier with a year of shifts used to cost 8 queries per session here.
    # Prime the whole (already-materialised) set once instead.
    variance_count = sum(
        1
        for session in prime_register_session_cash_totals(sessions)
        if session.has_cash_variance
    )
    latest_session = sessions.order_by("-opened_at").first()

    return {
        "session_count": totals["session_count"] or 0,
        "open_count": totals["open_count"] or 0,
        "closed_count": totals["closed_count"] or 0,
        "variance_count": variance_count,
        "opening_cash_total": _money(totals["opening_cash_total"]),
        "closing_cash_total": _money(totals["closing_cash_total"]),
        "last_session_at": _iso(
            latest_session.opened_at if latest_session else None
        ),
    }


def _cash_movement_summary(movements):
    totals = movements.aggregate(
        movement_count=Count("id"),
        pay_in_count=Count(
            "id",
            filter=Q(movement_type=RegisterCashMovement.MovementType.PAY_IN),
        ),
        pay_out_count=Count(
            "id",
            filter=Q(movement_type=RegisterCashMovement.MovementType.PAY_OUT),
        ),
        pay_in_total=Sum(
            "amount",
            filter=Q(movement_type=RegisterCashMovement.MovementType.PAY_IN),
        ),
        pay_out_total=Sum(
            "amount",
            filter=Q(movement_type=RegisterCashMovement.MovementType.PAY_OUT),
        ),
    )

    return {
        "movement_count": totals["movement_count"] or 0,
        "pay_in_count": totals["pay_in_count"] or 0,
        "pay_out_count": totals["pay_out_count"] or 0,
        "pay_in_total": _money(totals["pay_in_total"]),
        "pay_out_total": _money(totals["pay_out_total"]),
    }


def _purchasing_summary(orders, receipts, adjustments):
    order_totals = orders.aggregate(
        purchase_order_count=Count("id"),
        supplier_invoice_count=Count(
            "id",
            filter=~Q(supplier_invoice_number=""),
        ),
        received_order_count=Count(
            "id",
            filter=Q(status=PurchaseOrder.Status.RECEIVED),
        ),
        purchase_total=Sum("total"),
    )
    adjustment_totals = adjustments.aggregate(
        adjustment_count=Count("id"),
        adjustment_total=Sum("amount"),
    )
    latest_order = orders.order_by("-created_at").first()

    return {
        "purchase_order_count": order_totals["purchase_order_count"] or 0,
        "supplier_invoice_count": order_totals["supplier_invoice_count"] or 0,
        "received_order_count": order_totals["received_order_count"] or 0,
        "receipt_count": receipts.count(),
        "adjustment_count": adjustment_totals["adjustment_count"] or 0,
        "purchase_total": _money(order_totals["purchase_total"]),
        "adjustment_total": _money(adjustment_totals["adjustment_total"]),
        "last_purchase_at": _iso(
            latest_order.created_at if latest_order else None
        ),
    }


def _supplier_payment_summary(payments):
    totals = payments.aggregate(
        payment_count=Count("id"),
        payment_total=Sum("amount"),
        refund_count=Count(
            "id",
            filter=Q(method=SupplierPayment.Method.REFUND),
        ),
        refund_total=Sum(
            "amount",
            filter=Q(method=SupplierPayment.Method.REFUND),
        ),
    )
    latest_payment = payments.order_by("-paid_at", "-created_at").first()

    return {
        "payment_count": totals["payment_count"] or 0,
        "payment_total": _money(totals["payment_total"]),
        "refund_count": totals["refund_count"] or 0,
        "refund_total": _money(totals["refund_total"]),
        "last_payment_at": _iso(
            latest_payment.paid_at if latest_payment else None
        ),
    }


# Below this many rows (by the planner's estimate) the count is exact; above
# it the estimate is served as the count. An exact COUNT over a person's whole
# history is a scan that grows with every day they work; the number is a
# summary tile, not a ledger.
ACTIVITY_COUNT_EXACT_LIMIT = 5000


def _activity_summary(events):
    latest_event = events.order_by("-occurred_at", "-id").first()
    estimate = estimate_export_rows(events)
    if estimate is not None and estimate > ACTIVITY_COUNT_EXACT_LIMIT:
        event_count, is_estimate = int(estimate), True
    else:
        event_count, is_estimate = events.count(), False
    return {
        "event_count": event_count,
        "event_count_is_estimate": is_estimate,
        "last_event_at": _iso(latest_event.occurred_at if latest_event else None),
    }


def _sale_order_data(order):
    return {
        "id": order.pk,
        "receipt_number": order.receipt_number,
        "status": order.status,
        "sale_type": order.sale_type,
        # Only meaningful on a credit row, but cheap on every row (``payments``
        # is prefetched) and it keeps one shape for both lists.
        "amount_paid": _money(order.amount_paid),
        "balance_due": _money(order.balance_due),
        "payment_status": order.payment_status,
        "due_date": order.due_date.isoformat() if order.due_date else None,
        "is_overdue": order.is_overdue,
        "customer_name": order.customer.full_name if order.customer_id else "",
        "register_session": order.register_session_id,
        "register_session_number": (
            order.register_session.session_number
            if order.register_session_id
            else ""
        ),
        "subtotal": _money(order.subtotal),
        "discount_total": _money(order.discount_total),
        "total": _money(order.total),
        "created_at": _iso(order.created_at),
    }


def _purchase_order_data(order):
    return {
        "id": order.pk,
        "order_number": order.order_number,
        "status": order.status,
        "supplier": order.supplier_id,
        "supplier_name": order.supplier.name,
        "supplier_invoice_number": order.supplier_invoice_number,
        "supplier_invoice_date": _iso(order.supplier_invoice_date),
        "total": _money(order.total),
        "created_at": _iso(order.created_at),
    }


def _register_session_data(session):
    return {
        "id": session.pk,
        "session_number": session.session_number,
        "status": session.status,
        "opening_cash": _money(session.opening_cash),
        "closing_cash": _nullable_money(session.closing_cash),
        "cash_variance": _nullable_money(session.cash_variance),
        "has_cash_variance": session.has_cash_variance,
        "opened_at": _iso(session.opened_at),
        "closed_at": _iso(session.closed_at),
    }


def _activity_event_data(event):
    return {
        "id": event.pk,
        "name": event.name,
        "event_type": event.event_type,
        "severity": event.severity,
        "entity_type": event.entity_type,
        "entity_id": event.entity_id,
        "occurred_at": _iso(event.occurred_at),
    }


def _money(value):
    return f"{_decimal(value).quantize(Decimal('0.01')):.2f}"


def _nullable_money(value):
    return None if value is None else _money(value)


def _decimal(value):
    return value if value is not None else Decimal("0.00")


def _iso(value):
    return value.isoformat() if value is not None else None
