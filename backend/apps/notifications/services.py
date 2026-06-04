from datetime import timedelta
from decimal import Decimal

from django.conf import settings
from django.db import transaction
from django.db.models import DecimalField, F, Q, Sum, Value
from django.db.models.functions import Coalesce
from django.utils import timezone

from apps.core.roles import user_is_manager
from apps.discounts.models import DiscountRule
from apps.inventory.models import StockBatch, StockItem
from apps.printing.models import PrintAgent, PrintJob
from apps.purchasing.models import PurchaseOrder, SupplierPayment
from apps.sales.models import Order, OrderLine, RegisterSession

from .models import BusinessNotification, BusinessNotificationUserState

MANAGED_CODES = (
    "inventory.out_of_stock",
    "inventory.low_stock",
    "inventory.expiring_batch",
    "purchasing.overdue_order",
    "printing.failed_job",
    "printing.stale_agent",
    "sales.register_variance",
    "sales.negative_margin",
    "fraud.suspected_cashier_activity",
    "discounts.expiring_rule",
    "operations.backend_error",
)
MONEY_FIELD = DecimalField(max_digits=12, decimal_places=2)
NOTIFICATION_AUDIENCE_RULES = {
    "inventory.out_of_stock": {
        "permissions": ("inventory.view_stockitem", "inventory.view_stockmovement"),
        "manager_only": True,
    },
    "inventory.low_stock": {
        "permissions": ("inventory.view_stockitem", "inventory.view_stockmovement"),
        "manager_only": True,
    },
    "inventory.expiring_batch": {
        "permissions": ("inventory.view_stockitem", "inventory.view_stockmovement"),
        "manager_only": True,
    },
    "purchasing.overdue_order": {
        "permissions": ("purchasing.view_purchaseorder", "purchasing.view_supplier"),
        "manager_only": True,
    },
    "printing.failed_job": {
        "permissions": ("printing.view_printjob",),
        "manager_only": False,
    },
    "printing.stale_agent": {
        "permissions": ("printing.view_printagent",),
        "manager_only": True,
    },
    "sales.register_variance": {
        "permissions": ("sales.view_registersession",),
        "manager_only": True,
    },
    "sales.negative_margin": {
        "permissions": ("sales.view_order",),
        "manager_only": True,
    },
    "fraud.suspected_cashier_activity": {
        "permissions": ("fraud.view_fraudfinding", "analytics.view_analyticsevent"),
        "manager_only": True,
    },
    "discounts.expiring_rule": {
        "permissions": ("discounts.view_discountrule",),
        "manager_only": True,
    },
}


def sync_business_notifications(now=None):
    now = now or timezone.now()
    desired = []
    desired.extend(_inventory_notifications(now))
    desired.extend(_expiry_notifications(now))
    desired.extend(_purchasing_notifications(now))
    desired.extend(_printing_notifications(now))
    desired.extend(_sales_notifications(now))
    desired.extend(_fraud_notifications(now))
    desired.extend(_discount_notifications(now))

    fingerprints = set()
    with transaction.atomic():
        for spec in desired:
            fingerprints.add(spec["fingerprint"])
            _upsert_notification(spec, now)

        BusinessNotification.objects.filter(
            code__in=MANAGED_CODES,
            status=BusinessNotification.Status.ACTIVE,
        ).exclude(fingerprint__in=fingerprints).update(
            status=BusinessNotification.Status.RESOLVED,
            resolved_at=now,
            last_seen_at=now,
        )

    return {
        "active": BusinessNotification.objects.filter(
            status=BusinessNotification.Status.ACTIVE,
        ).count(),
        "generated": len(desired),
    }


def visible_notifications_for_user(user):
    queryset = BusinessNotification.objects.filter(
        status=BusinessNotification.Status.ACTIVE,
    )
    codes = _codes_for_user(user)
    if not codes:
        return queryset.none()
    return queryset.filter(code__in=codes).prefetch_related("user_states")


def notification_is_hidden_for_user(notification, user, now=None):
    state = _state_for_user(notification, user)
    if state is None:
        return False, ""
    if state.acknowledged_at is not None:
        return True, "acknowledged"
    now = now or timezone.now()
    if state.snoozed_until is not None and state.snoozed_until > now:
        return True, "snoozed"
    return False, ""


def notification_state_for_user(notification, user):
    return _state_for_user(notification, user)


def acknowledge_notification(notification, user, now=None):
    now = now or timezone.now()
    state, _ = BusinessNotificationUserState.objects.get_or_create(
        notification=notification,
        user=user,
    )
    state.acknowledged_at = now
    state.snoozed_until = None
    state.save(update_fields=["acknowledged_at", "snoozed_until", "updated_at"])
    return state


def snooze_notification(notification, user, *, duration, now=None):
    now = now or timezone.now()
    state, _ = BusinessNotificationUserState.objects.get_or_create(
        notification=notification,
        user=user,
    )
    state.acknowledged_at = None
    state.snoozed_until = now + duration
    state.save(update_fields=["acknowledged_at", "snoozed_until", "updated_at"])
    return state


def restore_notification(notification, user):
    BusinessNotificationUserState.objects.filter(
        notification=notification,
        user=user,
    ).delete()


def restore_notifications_for_user(user, queryset):
    notification_ids = list(queryset.values_list("id", flat=True))
    if not notification_ids:
        return 0
    deleted, _ = BusinessNotificationUserState.objects.filter(
        user=user,
        notification_id__in=notification_ids,
    ).delete()
    return deleted


def acknowledge_notifications_for_user(user, queryset, now=None):
    now = now or timezone.now()
    notification_ids = list(queryset.values_list("id", flat=True))
    states = []
    for notification_id in notification_ids:
        state, _ = BusinessNotificationUserState.objects.get_or_create(
            notification_id=notification_id,
            user=user,
        )
        state.acknowledged_at = now
        state.snoozed_until = None
        state.updated_at = now
        states.append(state)
    if states:
        BusinessNotificationUserState.objects.bulk_update(
            states,
            ["acknowledged_at", "snoozed_until", "updated_at"],
        )
    return len(states)


def _inventory_notifications(now):
    specs = []
    stock = StockItem.objects.select_related("variant", "variant__product").filter(
        variant__is_active=True,
        variant__product__is_active=True,
    )
    for item in stock:
        if item.quantity_on_hand <= 0:
            specs.append(
                _spec(
                    code="inventory.out_of_stock",
                    category=BusinessNotification.Category.INVENTORY,
                    severity=BusinessNotification.Severity.CRITICAL,
                    fingerprint=f"inventory.out_of_stock:variant:{item.variant_id}",
                    entity_type="catalog.productvariant",
                    entity_id=str(item.variant_id),
                    payload=_stock_payload(item),
                )
            )
        elif item.quantity_on_hand <= item.reorder_level:
            specs.append(
                _spec(
                    code="inventory.low_stock",
                    category=BusinessNotification.Category.INVENTORY,
                    severity=BusinessNotification.Severity.WARNING,
                    fingerprint=f"inventory.low_stock:variant:{item.variant_id}",
                    entity_type="catalog.productvariant",
                    entity_id=str(item.variant_id),
                    payload=_stock_payload(item),
                )
            )
    return specs


def _expiry_notifications(now):
    specs = []
    today = timezone.localdate(now)
    alert_window_days = max(
        getattr(settings, "POINTY_EXPIRY_ALERT_WINDOW_DAYS", 30),
        0,
    )
    window_end = today + timedelta(days=alert_window_days)
    batches = (
        StockBatch.objects.select_related(
            "variant",
            "variant__product",
            "source_receipt_line",
            "source_receipt_line__receipt",
            "source_receipt_line__receipt__purchase_order",
            "source_receipt_line__receipt__purchase_order__supplier",
        )
        .filter(
            remaining_quantity__gt=0,
            expiry_date__lte=window_end,
            variant__is_active=True,
            variant__product__is_active=True,
            variant__product__tracks_expiry=True,
        )
        .order_by("expiry_date", "id")
    )
    for batch in batches:
        days = (batch.expiry_date - today).days
        severity = BusinessNotification.Severity.INFO
        if days <= 1:
            severity = BusinessNotification.Severity.CRITICAL
        elif days <= 7:
            severity = BusinessNotification.Severity.WARNING
        order = batch.source_receipt_line.receipt.purchase_order
        supplier_name = order.supplier.name if order.supplier_id else ""
        specs.append(
            _spec(
                code="inventory.expiring_batch",
                category=BusinessNotification.Category.INVENTORY,
                severity=severity,
                fingerprint=f"inventory.expiring_batch:stockbatch:{batch.pk}",
                entity_type="inventory.stockbatch",
                entity_id=str(batch.pk),
                payload={
                    "product_name": batch.variant.full_name,
                    "sku": batch.variant.sku,
                    "quantity": batch.remaining_quantity,
                    "expiry_date": batch.expiry_date.isoformat(),
                    "days": max(days, 0),
                    "order_number": order.order_number,
                    "supplier_name": supplier_name,
                    "count": 1,
                },
            )
        )
    return specs


def _purchasing_notifications(now):
    specs = []
    today = timezone.localdate()
    orders = (
        PurchaseOrder.objects.exclude(status=PurchaseOrder.Status.CANCELLED)
        .annotate(
            notification_paid_total=Coalesce(
                Sum(
                    "supplier_payments__amount",
                    filter=~Q(
                        supplier_payments__method=SupplierPayment.Method.SUPPLIER_CREDIT,
                    ),
                ),
                Value(Decimal("0.00")),
                output_field=MONEY_FIELD,
            ),
            notification_credit_total=Coalesce(
                Sum(
                    "supplier_payments__amount",
                    filter=Q(
                        supplier_payments__method=SupplierPayment.Method.SUPPLIER_CREDIT,
                    ),
                ),
                Value(Decimal("0.00")),
                output_field=MONEY_FIELD,
            ),
        )
        .select_related("supplier")
    )
    for order in orders:
        if order.due_date is None or order.due_date >= today:
            continue
        balance = max(
            order.total - order.notification_paid_total - order.notification_credit_total,
            Decimal("0.00"),
        )
        if balance <= 0:
            continue
        specs.append(
            _spec(
                code="purchasing.overdue_order",
                category=BusinessNotification.Category.PURCHASING,
                severity=BusinessNotification.Severity.CRITICAL,
                fingerprint=f"purchasing.overdue_order:{order.pk}",
                entity_type="purchasing.purchaseorder",
                entity_id=str(order.pk),
                payload={
                    "order_number": order.order_number,
                    "supplier_name": order.supplier.name,
                    "due_date": order.due_date.isoformat(),
                    "amount": _money(balance),
                    "count": 1,
                },
            )
        )
    return specs


def _printing_notifications(now):
    specs = []
    failed_jobs = PrintJob.objects.select_related("order").filter(
        status=PrintJob.Status.FAILED,
    )
    for job in failed_jobs:
        specs.append(
            _spec(
                code="printing.failed_job",
                category=BusinessNotification.Category.PRINTING,
                severity=BusinessNotification.Severity.CRITICAL,
                fingerprint=f"printing.failed_job:{job.pk}",
                entity_type="printing.printjob",
                entity_id=str(job.pk),
                payload={
                    "receipt_number": job.order.receipt_number if job.order_id else "",
                    "message": job.error_message,
                    "failed_at": job.failed_at.isoformat() if job.failed_at else None,
                    "count": 1,
                },
            )
        )

    stale_before = now - timedelta(minutes=15)
    queued_count = PrintJob.objects.filter(status=PrintJob.Status.QUEUED).count()
    stale_agents = PrintAgent.objects.filter(is_active=True).filter(
        Q(last_seen_at__lt=stale_before) | Q(last_seen_at__isnull=True)
    )
    for agent in stale_agents:
        specs.append(
            _spec(
                code="printing.stale_agent",
                category=BusinessNotification.Category.PRINTING,
                severity=(
                    BusinessNotification.Severity.CRITICAL
                    if queued_count
                    else BusinessNotification.Severity.WARNING
                ),
                fingerprint=f"printing.stale_agent:{agent.pk}",
                entity_type="printing.printagent",
                entity_id=str(agent.pk),
                payload={
                    "agent_name": agent.name,
                    "queued_count": queued_count,
                    "count": 1,
                },
            )
        )
    return specs


def _sales_notifications(now):
    specs = []
    sessions = RegisterSession.objects.filter(
        status=RegisterSession.Status.CLOSED,
        closing_cash__isnull=False,
    )
    for session in sessions:
        variance = session.cash_variance
        if variance in (None, Decimal("0.00")):
            continue
        absolute_variance = abs(variance)
        specs.append(
            _spec(
                code="sales.register_variance",
                category=BusinessNotification.Category.SALES,
                severity=(
                    BusinessNotification.Severity.CRITICAL
                    if absolute_variance >= Decimal("100.00")
                    else BusinessNotification.Severity.WARNING
                ),
                fingerprint=f"sales.register_variance:{session.pk}",
                entity_type="sales.registersession",
                entity_id=str(session.pk),
                payload={
                    "session_number": session.session_number,
                    "amount": _money(absolute_variance),
                    "count": 1,
                },
            )
        )

    period_start = now - timedelta(days=30)
    orders = Order.objects.filter(
        status__in=(Order.Status.PAID, Order.Status.VOID),
        created_at__gte=period_start,
        created_at__lt=now,
    )
    revenue_expr = F("quantity") * F("unit_price") - F("discount_total")
    cost_expr = F("quantity") * F("unit_cost")
    line_values = OrderLine.objects.filter(order__in=orders).aggregate(
        revenue=Coalesce(
            Sum(revenue_expr, output_field=MONEY_FIELD),
            Value(Decimal("0.00")),
            output_field=MONEY_FIELD,
        ),
        cost=Coalesce(
            Sum(cost_expr, output_field=MONEY_FIELD),
            Value(Decimal("0.00")),
            output_field=MONEY_FIELD,
        ),
    )
    revenue = line_values["revenue"]
    cost = line_values["cost"]
    if revenue > 0 and cost > revenue:
        loss = cost - revenue
        specs.append(
            _spec(
                code="sales.negative_margin",
                category=BusinessNotification.Category.SALES,
                severity=BusinessNotification.Severity.CRITICAL,
                fingerprint="sales.negative_margin:30d",
                entity_type="sales.order",
                entity_id="",
                payload={
                    "amount": _money(loss),
                    "percent": str(((loss / revenue) * Decimal("100")).quantize(Decimal("1"))),
                    "days": 30,
                    "count": orders.count(),
                },
            )
        )
    return specs


def _discount_notifications(now):
    specs = []
    rules = DiscountRule.objects.filter(
        is_active=True,
        ends_at__gte=now,
        ends_at__lte=now + timedelta(days=7),
    )
    for rule in rules:
        days = max(0, (rule.ends_at - now).days) if rule.ends_at else 0
        specs.append(
            _spec(
                code="discounts.expiring_rule",
                category=BusinessNotification.Category.DISCOUNTS,
                severity=(
                    BusinessNotification.Severity.WARNING
                    if days <= 2
                    else BusinessNotification.Severity.INFO
                ),
                fingerprint=f"discounts.expiring_rule:{rule.pk}",
                entity_type="discounts.discountrule",
                entity_id=str(rule.pk),
                payload={
                    "rule_name": rule.name,
                    "channel": rule.channel,
                    "ends_at": rule.ends_at.isoformat() if rule.ends_at else None,
                    "days": days,
                    "count": 1,
                },
            )
        )
    return specs


def _fraud_notifications(now):
    from apps.fraud.services import suspected_fraud_notification_specs

    return suspected_fraud_notification_specs(now=now)


def _upsert_notification(spec, now):
    notification = BusinessNotification.objects.filter(
        fingerprint=spec["fingerprint"]
    ).first()
    if notification is None:
        BusinessNotification.objects.create(**spec, first_seen_at=now, last_seen_at=now)
        return

    was_resolved = notification.status == BusinessNotification.Status.RESOLVED
    notification.code = spec["code"]
    notification.category = spec["category"]
    notification.severity = spec["severity"]
    notification.status = BusinessNotification.Status.ACTIVE
    notification.entity_type = spec["entity_type"]
    notification.entity_id = spec["entity_id"]
    notification.payload = spec["payload"]
    notification.last_seen_at = now
    notification.resolved_at = None
    if was_resolved:
        notification.occurrence_count += 1
    notification.save(
        update_fields=[
            "code",
            "category",
            "severity",
            "status",
            "entity_type",
            "entity_id",
            "payload",
            "last_seen_at",
            "resolved_at",
            "occurrence_count",
            "updated_at",
        ]
    )
    if was_resolved:
        BusinessNotificationUserState.objects.filter(notification=notification).delete()


def _spec(
    *,
    code,
    category,
    severity,
    fingerprint,
    entity_type,
    entity_id,
    payload,
):
    return {
        "code": code,
        "category": category,
        "severity": severity,
        "fingerprint": fingerprint,
        "entity_type": entity_type,
        "entity_id": entity_id,
        "payload": payload,
    }


def _stock_payload(item):
    variant_name = item.variant.name.strip()
    product_name = item.variant.product.name
    display_name = f"{product_name} - {variant_name}" if variant_name else product_name
    return {
        "product_name": display_name,
        "sku": item.variant.sku,
        "quantity": item.quantity_on_hand,
        "threshold": item.reorder_level,
        "expected": item.quantity_expected,
        "count": 1,
    }


def _money(value):
    return str(Decimal(value).quantize(Decimal("0.01")))


def _codes_for_user(user):
    if not user or not user.is_authenticated:
        return ()
    manager = user_is_manager(user)
    return [
        code
        for code, rule in NOTIFICATION_AUDIENCE_RULES.items()
        if (manager or not rule["manager_only"])
        and any(user.has_perm(permission_code) for permission_code in rule["permissions"])
    ]


def _state_for_user(notification, user):
    for state in notification.user_states.all():
        if state.user_id == user.id:
            return state
    return BusinessNotificationUserState.objects.filter(
        notification=notification,
        user=user,
    ).first()
