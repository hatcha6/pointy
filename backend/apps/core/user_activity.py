from decimal import Decimal

from django.db.models import Count, Q, Sum

from apps.analytics.models import AnalyticsEvent
from apps.purchasing.models import (
    PurchaseOrder,
    PurchaseOrderAdjustment,
    PurchaseOrderAuditEvent,
    PurchaseReceipt,
    SupplierPayment,
)
from apps.sales.models import (
    Order,
    OrderAdjustment,
    RegisterCashMovement,
    RegisterSession,
)


RECENT_LIMIT = 5


def build_user_activity(user):
    owner_key = f"user:{user.pk}"
    register_sessions = RegisterSession.objects.filter(owner_key=owner_key)
    sales_orders = Order.objects.filter(
        register_session__owner_key=owner_key,
    ).exclude(status=Order.Status.OPEN)
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
    supplier_payments = SupplierPayment.objects.filter(created_by=user)
    activity_events = AnalyticsEvent.objects.filter(received_by=user)

    return {
        "summary": {
            "sales": _sales_summary(sales_orders, sales_adjustments),
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
        "recent_sales": [
            _sale_order_data(order)
            for order in sales_orders.select_related(
                "customer",
                "register_session",
            ).order_by("-created_at")[:RECENT_LIMIT]
        ],
        "recent_purchase_orders": [
            _purchase_order_data(order)
            for order in purchase_orders.select_related("supplier").order_by(
                "-created_at",
            )[:RECENT_LIMIT]
        ],
        "recent_register_sessions": [
            _register_session_data(session)
            for session in register_sessions.order_by("-opened_at")[:RECENT_LIMIT]
        ],
        "recent_activity": [
            _activity_event_data(event)
            for event in activity_events.order_by(
                "-occurred_at",
                "-id",
            )[:RECENT_LIMIT]
        ],
    }


def _sales_summary(orders, adjustments):
    order_totals = orders.aggregate(
        invoice_count=Count("id"),
        paid_invoice_count=Count("id", filter=Q(status=Order.Status.PAID)),
        void_invoice_count=Count("id", filter=Q(status=Order.Status.VOID)),
        customer_count=Count(
            "customer",
            filter=Q(customer__isnull=False),
            distinct=True,
        ),
        paid_total=Sum("total", filter=Q(status=Order.Status.PAID)),
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

    return {
        "invoice_count": order_totals["invoice_count"] or 0,
        "paid_invoice_count": order_totals["paid_invoice_count"] or 0,
        "void_invoice_count": order_totals["void_invoice_count"] or 0,
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
    variance_count = sum(1 for session in sessions if session.has_cash_variance)
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


def _activity_summary(events):
    latest_event = events.order_by("-occurred_at", "-id").first()
    return {
        "event_count": events.count(),
        "last_event_at": _iso(latest_event.occurred_at if latest_event else None),
    }


def _sale_order_data(order):
    return {
        "id": order.pk,
        "receipt_number": order.receipt_number,
        "status": order.status,
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
