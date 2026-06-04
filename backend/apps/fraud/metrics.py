from __future__ import annotations

from collections import defaultdict
from dataclasses import dataclass, field
from datetime import timedelta
from decimal import Decimal

from django.conf import settings
from django.contrib.auth import get_user_model

from apps.analytics.models import AnalyticsEvent
from apps.payments.models import Payment
from apps.sales.models import (
    Order,
    OrderAdjustment,
    RegisterCashMovement,
    RegisterSession,
)

from .rules import LOW_VALUE_CASH_SALE_THRESHOLD, MONEY_PLACES, MONEY_ZERO


@dataclass
class CashierMetrics:
    user_id: int
    user_label: str
    paid_order_count: int = 0
    paid_sales_total: Decimal = MONEY_ZERO
    paid_subtotal: Decimal = MONEY_ZERO
    discount_total: Decimal = MONEY_ZERO
    cash_order_count: int = 0
    cash_sales_total: Decimal = MONEY_ZERO
    low_value_cash_order_count: int = 0
    near_zero_order_count: int = 0
    void_count: int = 0
    void_amount: Decimal = MONEY_ZERO
    return_count: int = 0
    return_amount: Decimal = MONEY_ZERO
    cash_refund_count: int = 0
    cash_refund_amount: Decimal = MONEY_ZERO
    late_adjustment_count: int = 0
    late_adjustment_amount: Decimal = MONEY_ZERO
    pay_out_count: int = 0
    pay_out_amount: Decimal = MONEY_ZERO
    pay_in_count: int = 0
    pay_in_amount: Decimal = MONEY_ZERO
    closed_session_count: int = 0
    cash_shortage_count: int = 0
    cash_shortage_amount: Decimal = MONEY_ZERO
    cash_overage_amount: Decimal = MONEY_ZERO
    receipt_reprint_count: int = 0
    latest_event_at: object | None = None
    evidence: dict[str, list[dict]] = field(default_factory=lambda: defaultdict(list))

    @property
    def transaction_base(self) -> int:
        return max(self.paid_order_count, 1)

    @property
    def sales_base(self) -> Decimal:
        return max(self.paid_sales_total, Decimal("1.00"))

    def rate(self, metric: str) -> float:
        return {
            "void_rate": self.void_count / self.transaction_base,
            "return_rate": self.return_count / self.transaction_base,
            "cash_refund_rate": float(self.cash_refund_amount / self.sales_base),
            "discount_rate": float(
                self.discount_total / max(self.paid_subtotal, Decimal("1.00"))
            ),
            "pay_out_rate": float(self.pay_out_amount / self.sales_base),
            "cash_shortage_rate": float(self.cash_shortage_amount / self.sales_base),
            "low_value_cash_rate": self.low_value_cash_order_count
            / max(self.cash_order_count, 1),
            "near_zero_sale_rate": self.near_zero_order_count / self.transaction_base,
            "receipt_reprint_rate": self.receipt_reprint_count / self.transaction_base,
        }.get(metric, 0.0)


def build_cashier_metrics(window_start, window_end) -> dict[int, CashierMetrics]:
    User = get_user_model()
    users = {
        user.pk: user
        for user in User.objects.filter(is_active=True).only(
            "id",
            "username",
            "first_name",
            "last_name",
        )
    }
    metrics_by_user = {
        user_id: CashierMetrics(user_id=user_id, user_label=_user_label(user))
        for user_id, user in users.items()
    }

    _collect_orders(metrics_by_user, window_start, window_end)
    _collect_adjustments(metrics_by_user, window_start, window_end)
    _collect_cash_movements(metrics_by_user, window_start, window_end)
    _collect_register_sessions(metrics_by_user, window_start, window_end)
    _collect_receipt_reprints(metrics_by_user, window_start, window_end)
    return metrics_by_user


def money(value):
    return Decimal(value or MONEY_ZERO).quantize(MONEY_PLACES)


def money_string(value):
    return str(money(value))


def _collect_orders(metrics_by_user, window_start, window_end):
    orders = (
        Order.objects.select_related("register_session", "register_session__owner")
        .prefetch_related("payments")
        .filter(
            status=Order.Status.PAID,
            created_at__gte=window_start,
            created_at__lt=window_end,
            register_session__owner__isnull=False,
        )
        .order_by("created_at", "pk")
    )
    for order in orders:
        user_id = order.register_session.owner_id
        metrics = metrics_by_user.get(user_id)
        if metrics is None:
            continue
        metrics.paid_order_count += 1
        metrics.paid_sales_total += money(order.total)
        metrics.paid_subtotal += money(order.subtotal)
        metrics.discount_total += money(order.discount_total)
        metrics.latest_event_at = _latest(metrics.latest_event_at, order.created_at)

        cash_paid = any(
            payment.method == Payment.Method.CASH and payment.amount > MONEY_ZERO
            for payment in order.payments.all()
        )
        if cash_paid:
            metrics.cash_order_count += 1
            metrics.cash_sales_total += money(order.total)
            if order.total <= LOW_VALUE_CASH_SALE_THRESHOLD:
                metrics.low_value_cash_order_count += 1
                _append_evidence(
                    metrics,
                    "low_value_cash_sales",
                    {
                        "order_id": order.pk,
                        "receipt_number": order.receipt_number,
                        "amount": money_string(order.total),
                        "occurred_at": order.created_at.isoformat(),
                    },
                )
        if order.total <= MONEY_ZERO:
            metrics.near_zero_order_count += 1
            _append_evidence(
                metrics,
                "near_zero_sales",
                {
                    "order_id": order.pk,
                    "receipt_number": order.receipt_number,
                    "amount": money_string(order.total),
                    "discount_total": money_string(order.discount_total),
                    "occurred_at": order.created_at.isoformat(),
                },
            )
        if order.discount_total > MONEY_ZERO:
            _append_evidence(
                metrics,
                "discount_peer_outlier",
                {
                    "order_id": order.pk,
                    "receipt_number": order.receipt_number,
                    "discount_total": money_string(order.discount_total),
                    "subtotal": money_string(order.subtotal),
                    "occurred_at": order.created_at.isoformat(),
                },
            )


def _collect_adjustments(metrics_by_user, window_start, window_end):
    adjustments = (
        OrderAdjustment.objects.select_related("order", "created_by")
        .filter(
            created_at__gte=window_start,
            created_at__lt=window_end,
            created_by__isnull=False,
        )
        .order_by("created_at", "pk")
    )
    adjustment_window_hours = getattr(
        settings,
        "POINTY_CASHIER_RETURN_WINDOW_HOURS",
        None,
    )
    if adjustment_window_hours is None:
        try:
            from apps.core.models import ShopSettings

            adjustment_window_hours = ShopSettings.load().cashier_return_window_hours
        except Exception:
            adjustment_window_hours = 24

    for adjustment in adjustments:
        metrics = metrics_by_user.get(adjustment.created_by_id)
        if metrics is None:
            continue

        amount = money(adjustment.amount)
        is_void = adjustment.adjustment_type == OrderAdjustment.AdjustmentType.VOID
        if is_void:
            metrics.void_count += 1
            metrics.void_amount += amount
            evidence_key = "void_peer_outlier"
        else:
            metrics.return_count += 1
            metrics.return_amount += amount
            evidence_key = "return_peer_outlier"

        if adjustment.refund_method == Payment.Method.CASH:
            metrics.cash_refund_count += 1
            metrics.cash_refund_amount += amount
            _append_evidence(
                metrics,
                "cash_refund_concentration",
                _adjustment_evidence(adjustment),
            )

        if _is_late_adjustment(adjustment, adjustment_window_hours):
            metrics.late_adjustment_count += 1
            metrics.late_adjustment_amount += amount
            _append_evidence(
                metrics,
                "late_void_or_return",
                _adjustment_evidence(adjustment),
            )

        _append_evidence(metrics, evidence_key, _adjustment_evidence(adjustment))
        metrics.latest_event_at = _latest(metrics.latest_event_at, adjustment.created_at)


def _collect_cash_movements(metrics_by_user, window_start, window_end):
    movements = (
        RegisterCashMovement.objects.select_related("register_session", "created_by")
        .filter(
            created_at__gte=window_start,
            created_at__lt=window_end,
            created_by__isnull=False,
        )
        .order_by("created_at", "pk")
    )
    for movement in movements:
        metrics = metrics_by_user.get(movement.created_by_id)
        if metrics is None:
            continue
        amount = money(movement.amount)
        if movement.movement_type == RegisterCashMovement.MovementType.PAY_OUT:
            metrics.pay_out_count += 1
            metrics.pay_out_amount += amount
            _append_evidence(
                metrics,
                "cash_pay_out_activity",
                {
                    "cash_movement_id": movement.pk,
                    "register_session_id": movement.register_session_id,
                    "session_number": movement.register_session.session_number,
                    "amount": money_string(amount),
                    "reason_present": bool(movement.reason),
                    "occurred_at": movement.created_at.isoformat(),
                },
            )
        else:
            metrics.pay_in_count += 1
            metrics.pay_in_amount += amount
        metrics.latest_event_at = _latest(metrics.latest_event_at, movement.created_at)


def _collect_register_sessions(metrics_by_user, window_start, window_end):
    sessions = (
        RegisterSession.objects.select_related("owner")
        .filter(
            status=RegisterSession.Status.CLOSED,
            closed_at__gte=window_start,
            closed_at__lt=window_end,
            owner__isnull=False,
            closing_cash__isnull=False,
        )
        .order_by("closed_at", "pk")
    )
    for session in sessions:
        metrics = metrics_by_user.get(session.owner_id)
        if metrics is None:
            continue
        metrics.closed_session_count += 1
        variance = session.cash_variance
        if variance is None:
            continue
        if variance < MONEY_ZERO:
            shortage = abs(money(variance))
            metrics.cash_shortage_count += 1
            metrics.cash_shortage_amount += shortage
            _append_evidence(
                metrics,
                "cash_shortage",
                {
                    "register_session_id": session.pk,
                    "session_number": session.session_number,
                    "expected_cash": money_string(session.expected_cash),
                    "closing_cash": money_string(session.closing_cash),
                    "shortage": money_string(shortage),
                    "closed_at": session.closed_at.isoformat()
                    if session.closed_at
                    else "",
                },
            )
            _append_evidence(
                metrics,
                "shortage_with_adjustments",
                metrics.evidence["cash_shortage"][-1],
            )
        elif variance > MONEY_ZERO:
            metrics.cash_overage_amount += money(variance)
        metrics.latest_event_at = _latest(metrics.latest_event_at, session.closed_at)


def _collect_receipt_reprints(metrics_by_user, window_start, window_end):
    events = AnalyticsEvent.objects.filter(
        name="sales.receipt.reprint.queued",
        occurred_at__gte=window_start,
        occurred_at__lt=window_end,
        received_by__isnull=False,
    ).order_by("occurred_at", "pk")
    for event in events:
        metrics = metrics_by_user.get(event.received_by_id)
        if metrics is None:
            continue
        metrics.receipt_reprint_count += 1
        _append_evidence(
            metrics,
            "receipt_reprint_activity",
            {
                "analytics_event_id": event.pk,
                "entity_type": event.entity_type,
                "entity_id": event.entity_id,
                "occurred_at": event.occurred_at.isoformat(),
            },
        )
        metrics.latest_event_at = _latest(metrics.latest_event_at, event.occurred_at)


def _append_evidence(metrics, key, value):
    if len(metrics.evidence[key]) < 12:
        metrics.evidence[key].append(value)


def _adjustment_evidence(adjustment):
    return {
        "adjustment_id": adjustment.pk,
        "order_id": adjustment.order_id,
        "receipt_number": adjustment.order.receipt_number,
        "adjustment_type": adjustment.adjustment_type,
        "refund_method": adjustment.refund_method,
        "amount": money_string(adjustment.amount),
        "reason_present": bool(adjustment.reason),
        "occurred_at": adjustment.created_at.isoformat(),
    }


def _is_late_adjustment(adjustment, adjustment_window_hours):
    if adjustment.order.created_at is None:
        return False
    deadline = adjustment.order.created_at + timedelta(hours=adjustment_window_hours)
    return adjustment.created_at > deadline


def _user_label(user):
    full_name = user.get_full_name().strip()
    return full_name or user.username


def _latest(left, right):
    if right is None:
        return left
    if left is None or right > left:
        return right
    return left
