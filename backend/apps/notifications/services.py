import logging
from datetime import timedelta
from decimal import Decimal

from django.conf import settings
from django.core.cache import cache
from django.db import transaction
from django.db.models import (
    Count,
    DecimalField,
    F,
    OuterRef,
    Prefetch,
    Q,
    Subquery,
    Sum,
    Value,
)
from django.db.models.functions import Coalesce
from django.utils import timezone

from apps.core.dispatch import enqueue_best_effort
from apps.core.roles import user_is_manager
from apps.discounts.models import DiscountRule
from apps.inventory.models import StockBatch, StockItem
from apps.payments.models import Payment
from apps.printing.models import PrintAgent, PrintJob
from apps.purchasing.models import PurchaseOrder, SupplierPayment
from apps.sales.models import (
    Order,
    OrderAdjustment,
    OrderLine,
    RegisterCashMovement,
    RegisterSession,
)

from .cache import bump_notifications_version, bump_user_notifications_version
from .models import BusinessNotification, BusinessNotificationUserState

logger = logging.getLogger(__name__)

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
    "employees.payroll_ready",
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
    "employees.payroll_ready": {
        "permissions": ("employees.view_payrollrun", "employees.approve_payrollrun"),
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
    desired.extend(_payroll_notifications(now))

    fingerprints = set()
    changed = 0
    with transaction.atomic():
        for spec in desired:
            fingerprints.add(spec["fingerprint"])
            if _upsert_notification(spec, now):
                changed += 1

        changed += (
            BusinessNotification.objects.filter(
                code__in=MANAGED_CODES,
                status=BusinessNotification.Status.ACTIVE,
            )
            .exclude(fingerprint__in=fingerprints)
            .update(
                status=BusinessNotification.Status.RESOLVED,
                resolved_at=now,
                last_seen_at=now,
            )
        )
    if changed:
        # Only a material change orphans feed ETags — the last_seen_at-only
        # refresh above must keep every device 304ing.
        bump_notifications_version()

    return {
        "active": BusinessNotification.objects.filter(
            status=BusinessNotification.Status.ACTIVE,
        ).count(),
        "generated": len(desired),
    }


# The feed is recomputed on a Celery beat (notifications.sync_business_notifications).
# Reads *also* top it up inline, but no more than once per this window (seconds),
# so a fleet of devices polling the bell/badge can't each trigger a fresh
# whole-catalog + all-time recompute. Tunable via settings; <= 0 disables the
# throttle (recompute on every read, the old behaviour).
INLINE_SYNC_THROTTLE_SECONDS = 300
INLINE_SYNC_THROTTLE_CACHE_KEY = "notifications:inline-sync:lock"


def maybe_sync_business_notifications(now=None):
    """Advance the feed out of band, at most once per throttle window, WITHOUT
    ever running the recompute on the request path.

    The Celery beat is the primary refresher. This top-up hands a recompute to
    the worker so (a) a fresh deploy primes the table before the beat's first
    tick and (b) the feed keeps advancing between ticks — but the bell/badge
    poll from every signed-in device never itself pays (or waits on) the full
    whole-catalog scan, which was ~1300 queries and several seconds inline.
    ``cache.add`` is atomic on the Redis backend, so concurrent polls collapse
    into a single enqueue per window.

    Falls back to an inline recompute only when the broker can't be reached
    (Celery not configured / worker+broker down), so the feed still advances in
    that degraded state. Returns the sync result dict only when it recomputed
    inline (throttle disabled or broker unreachable), else None. When the cache
    itself is unreachable the top-up is skipped entirely — see below.
    """
    throttle_seconds = getattr(
        settings,
        "POINTY_NOTIFICATION_INLINE_SYNC_THROTTLE_SECONDS",
        INLINE_SYNC_THROTTLE_SECONDS,
    )
    if throttle_seconds <= 0:
        # Escape hatch: recompute inline on every read (e.g. a deployment with no
        # running beat/worker that accepts the per-read cost).
        return sync_business_notifications(now=now)
    # Only the first caller in the window sets the key and proceeds; the rest see
    # the key already present and short-circuit, serving the last-computed table.
    # No usable Redis means no usable Celery either (same server is the broker),
    # so the fallback below cannot help — and running the whole-catalog recompute
    # inline on every poll from every device would turn a cache outage into a
    # database one. Skip the top-up instead: the bell keeps serving the
    # last-computed feed, stale but present, until Redis comes back.
    try:
        claimed = cache.add(
            INLINE_SYNC_THROTTLE_CACHE_KEY, "1", timeout=throttle_seconds
        )
    except Exception:  # noqa: BLE001 — redis down/unreachable
        logger.warning(
            "notification sync throttle unavailable; skipping the top-up",
            exc_info=True,
        )
        return None
    if not claimed:
        return None
    from .tasks import sync_business_notifications_task

    # Bounded and best-effort: enqueuing a recompute must never add latency to
    # (or hang) the bell poll every device runs. A broker that accepts the
    # connection and then stops answering is the case a bare try/except cannot
    # see, so the deadline lives in the connection.
    if enqueue_best_effort(sync_business_notifications_task):
        return None
    return sync_business_notifications(now=now)


def visible_notifications_for_user(user):
    queryset = BusinessNotification.objects.filter(
        status=BusinessNotification.Status.ACTIVE,
    )
    codes = _codes_for_user(user)
    if not codes:
        return queryset.none()
    # Scope the prefetch to the viewer. ``_state_for_user`` is the only reader
    # of these rows and it wants exactly one of them — this user's — yet an
    # unfiltered prefetch loads every member of staff's state for every alert
    # on the feed. That is rows the bell poll pays for and throws away, and it
    # grows with headcount, a dimension the request does not depend on: at a
    # full 50-alert page it is 50 x staff rows to answer 50 questions. The
    # statement count is identical either way, which is why a query-count test
    # cannot see it (see ``test_feed_state_rows_do_not_grow_with_staff_count``).
    return queryset.filter(code__in=codes).prefetch_related(
        Prefetch(
            "user_states",
            queryset=BusinessNotificationUserState.objects.filter(user=user),
        )
    )


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
    bump_user_notifications_version(user.pk)
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
    bump_user_notifications_version(user.pk)
    return state


def restore_notification(notification, user):
    BusinessNotificationUserState.objects.filter(
        notification=notification,
        user=user,
    ).delete()
    bump_user_notifications_version(user.pk)


def restore_notifications_for_user(user, queryset):
    notification_ids = list(queryset.values_list("id", flat=True))
    if not notification_ids:
        return 0
    deleted, _ = BusinessNotificationUserState.objects.filter(
        user=user,
        notification_id__in=notification_ids,
    ).delete()
    bump_user_notifications_version(user.pk)
    return deleted


def acknowledge_notifications_for_user(user, queryset, now=None):
    now = now or timezone.now()
    notification_ids = list(queryset.values_list("id", flat=True))
    if not notification_ids:
        return 0
    # A constant three statements — SELECT existing, UPDATE them, INSERT the
    # rest — inside one transaction, rather than a get_or_create per
    # notification plus a trailing bulk_update. The old loop issued O(N)
    # round-trips and left the writes non-atomic: a "hide all" that lost its
    # connection midway (e.g. the server restarting under it) could commit a
    # partial dismissal. This keeps the whole batch all-or-nothing.
    with transaction.atomic():
        existing_ids = set(
            BusinessNotificationUserState.objects.filter(
                user=user,
                notification_id__in=notification_ids,
            ).values_list("notification_id", flat=True)
        )
        if existing_ids:
            BusinessNotificationUserState.objects.filter(
                user=user,
                notification_id__in=existing_ids,
            ).update(acknowledged_at=now, snoozed_until=None, updated_at=now)
        missing_states = [
            BusinessNotificationUserState(
                notification_id=notification_id,
                user=user,
                acknowledged_at=now,
                snoozed_until=None,
            )
            for notification_id in notification_ids
            if notification_id not in existing_ids
        ]
        if missing_states:
            # ignore_conflicts covers the race where a concurrent read or the
            # sync beat created the state between the SELECT above and here.
            BusinessNotificationUserState.objects.bulk_create(
                missing_states,
                ignore_conflicts=True,
            )
    bump_user_notifications_version(user.pk)
    return len(notification_ids)


def _inventory_notifications(now):
    specs = []
    # Only rows that can alert leave the DB: on a 30k-item catalog a handful
    # are at/below reorder, but this used to materialize every StockItem.
    stock = (
        StockItem.objects.select_related("variant", "variant__product")
        .filter(
            variant__is_active=True,
            variant__product__is_active=True,
        )
        .filter(
            Q(quantity_on_hand__lte=0)
            | Q(quantity_on_hand__lte=F("reorder_level"))
        )
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
                    "quantity": float(batch.remaining_quantity),
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
        # Overdue + unpaid decided in SQL: only actual alerts leave the DB,
        # not every non-cancelled PO ever recorded.
        .filter(
            due_date__isnull=False,
            due_date__lt=today,
            total__gt=F("notification_paid_total") + F("notification_credit_total"),
        )
        .select_related("supplier")
    )
    for order in orders:
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
    # cash_variance is a 4-aggregate Python property (payments, refunds,
    # pay-ins, pay-outs) — computing it per closed session used to cost
    # 1 + 4N queries over all-time history. The same filtered sums as
    # correlated subqueries decide "has variance" in one query; each relation
    # gets its own subquery because joining them would fan out the sums.
    def _session_sum(queryset, field="amount"):
        return Coalesce(
            Subquery(
                queryset.values("register_session")
                .annotate(total=Sum(field))
                .values("total")[:1]
            ),
            Value(Decimal("0.00")),
            output_field=MONEY_FIELD,
        )

    sessions = (
        RegisterSession.objects.filter(
            status=RegisterSession.Status.CLOSED,
            closing_cash__isnull=False,
        )
        .annotate(
            variance_cash_sales=_session_sum(
                Payment.objects.filter(
                    register_session=OuterRef("pk"),
                    method=Payment.Method.CASH,
                    amount__gt=0,
                )
            ),
            variance_refunds=_session_sum(
                OrderAdjustment.objects.filter(register_session=OuterRef("pk")),
                "cash_amount",
            ),
            variance_pay_in=_session_sum(
                RegisterCashMovement.objects.filter(
                    register_session=OuterRef("pk"),
                    movement_type=RegisterCashMovement.MovementType.PAY_IN,
                )
            ),
            variance_pay_out=_session_sum(
                RegisterCashMovement.objects.filter(
                    register_session=OuterRef("pk"),
                    movement_type=RegisterCashMovement.MovementType.PAY_OUT,
                )
            ),
        )
        .annotate(
            cash_variance_amount=F("closing_cash")
            - (
                F("opening_cash")
                + F("variance_cash_sales")
                + F("variance_pay_in")
                - F("variance_pay_out")
                - F("variance_refunds")
            )
        )
        .exclude(cash_variance_amount=Decimal("0.00"))
    )
    for session in sessions:
        variance = session.cash_variance_amount
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
    orders = Order.objects.transactional().filter(
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
        # Round the remaining time UP to whole days so an alert never reports
        # "0 days" for a rule that is still active, and the severity band lines
        # up with how a human reads it ("~36h left" is 2 days, not 1). Plain
        # ``timedelta.days`` truncates toward zero and produced an off-by-one.
        if rule.ends_at:
            remaining_seconds = int((rule.ends_at - now).total_seconds())
            days = max(0, -(-remaining_seconds // 86400))
        else:
            days = 0
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


def _payroll_notifications(now):
    from apps.employees.models import PayrollRun

    runs = (
        PayrollRun.objects.filter(status=PayrollRun.Status.DRAFT)
        .annotate(notification_line_count=Count("lines"))
        .filter(notification_line_count__gt=0)
        .order_by("-period_end", "-created_at")
    )
    specs = []
    for run in runs:
        specs.append(
            _spec(
                code="employees.payroll_ready",
                category=BusinessNotification.Category.OPERATIONS,
                severity=BusinessNotification.Severity.INFO,
                fingerprint=f"employees.payroll_ready:{run.pk}",
                entity_type="employees.payrollrun",
                entity_id=str(run.pk),
                payload={
                    "run_number": run.run_number,
                    "period_start": run.period_start.isoformat(),
                    "period_end": run.period_end.isoformat(),
                    "amount": _money(run.net_total),
                    "count": run.notification_line_count,
                },
            )
        )
    return specs


def _json_safe_payload(value):
    from decimal import Decimal

    if isinstance(value, Decimal):
        return float(value)
    if isinstance(value, dict):
        return {key: _json_safe_payload(item) for key, item in value.items()}
    if isinstance(value, (list, tuple)):
        return [_json_safe_payload(item) for item in value]
    return value


def _upsert_notification(spec, now):
    """Create or refresh one notification; returns True when the upsert
    changed anything a client can see (new row, reactivation, or a field
    diff) — the ``last_seen_at``-only refresh of a persisting notification
    returns False so it never orphans feed ETags."""
    # Stock quantities are Decimals since weighted-product support; the
    # payload column is JSON, so coerce them at the boundary.
    if "payload" in spec:
        spec = {**spec, "payload": _json_safe_payload(spec["payload"])}
    # get_or_create keys on the unique fingerprint and absorbs the IntegrityError
    # from a concurrent insert (sync runs on a Celery beat AND, throttled, inline
    # on reads, so two syncs racing on the same fingerprint is possible). A plain
    # filter-then-create would raise under that race.
    defaults = {key: value for key, value in spec.items() if key != "fingerprint"}
    notification, created = BusinessNotification.objects.get_or_create(
        fingerprint=spec["fingerprint"],
        defaults={**defaults, "first_seen_at": now, "last_seen_at": now},
    )
    if created:
        return True

    was_resolved = notification.status == BusinessNotification.Status.RESOLVED
    materially_changed = was_resolved or any(
        getattr(notification, field) != spec[field]
        for field in ("code", "category", "severity", "entity_type", "entity_id", "payload")
    )
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
    return materially_changed


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
        "quantity": float(item.quantity_on_hand),
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
    # When user_states is prefetched (the feed list always prefetches it), the
    # loop above is authoritative: the user simply has no state, so skip the
    # fallback query. Serializing each notification hits this four times (one
    # per state-derived field), so the fallback was a per-notification N+1 (x4)
    # across the whole feed on every read.
    if "user_states" in getattr(notification, "_prefetched_objects_cache", {}):
        return None
    return BusinessNotificationUserState.objects.filter(
        notification=notification,
        user=user,
    ).first()
