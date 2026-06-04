from __future__ import annotations

from decimal import Decimal
from statistics import median

from .metrics import build_cashier_metrics, money_string
from .models import FraudFinding
from .rules import FindingSpec, MIN_PEER_USERS, MONEY_ZERO, RULES


def detect_suspected_fraud(*, window_start, window_end, now=None) -> list[FindingSpec]:
    metrics_by_user = build_cashier_metrics(window_start, window_end)
    peer_context = _peer_context(metrics_by_user.values())
    specs: list[FindingSpec] = []
    for metrics in metrics_by_user.values():
        if not _has_reviewable_activity(metrics):
            continue
        specs.extend(_rule_findings(metrics, peer_context, window_start, window_end))
    return specs


def _peer_context(metrics_values):
    active_metrics = [
        metrics
        for metrics in metrics_values
        if metrics.paid_order_count
        or metrics.void_count
        or metrics.return_count
        or metrics.pay_out_count
        or metrics.closed_session_count
    ]
    context = {}
    for metric_name in (
        "void_rate",
        "return_rate",
        "cash_refund_rate",
        "discount_rate",
        "pay_out_rate",
        "cash_shortage_rate",
        "low_value_cash_rate",
        "near_zero_sale_rate",
        "receipt_reprint_rate",
    ):
        rates = {metrics.user_id: metrics.rate(metric_name) for metrics in active_metrics}
        context[metric_name] = {
            **_robust_stats(rates.values()),
            "rates": rates,
        }
    return context


def _rule_findings(metrics, peer_context, window_start, window_end):
    findings = []
    findings.extend(_absolute_rule_findings(metrics, peer_context, window_start, window_end))
    findings.extend(_peer_rule_findings(metrics, peer_context, window_start, window_end))
    composite = _composite_finding(metrics, peer_context, window_start, window_end)
    if composite is not None:
        findings.append(composite)
    return findings


def _absolute_rule_findings(metrics, peer_context, window_start, window_end):
    specs = []
    if metrics.late_adjustment_count:
        specs.append(
            _finding(
                "late_void_or_return",
                metrics,
                peer_context,
                window_start,
                window_end,
                score=75 if metrics.late_adjustment_amount < Decimal("100.00") else 85,
                headline="Void or return outside the cashier adjustment window",
                amount=metrics.late_adjustment_amount,
            )
        )
    if metrics.cash_shortage_count >= 2 or metrics.cash_shortage_amount >= Decimal("50.00"):
        specs.append(
            _finding(
                "cash_shortage",
                metrics,
                peer_context,
                window_start,
                window_end,
                score=70 if metrics.cash_shortage_amount < Decimal("100.00") else 88,
                headline="Cash shortage pattern in closed register sessions",
                amount=metrics.cash_shortage_amount,
            )
        )
    if metrics.near_zero_order_count >= 2:
        specs.append(
            _finding(
                "near_zero_sales",
                metrics,
                peer_context,
                window_start,
                window_end,
                score=68,
                headline="Near-zero sales require review",
                amount=MONEY_ZERO,
            )
        )
    return specs


def _peer_rule_findings(metrics, peer_context, window_start, window_end):
    candidates = (
        (
            "void_peer_outlier",
            "void_rate",
            metrics.void_count >= 3 or metrics.void_amount >= Decimal("75.00"),
            metrics.void_amount,
            "Void activity is high compared with peers",
        ),
        (
            "return_peer_outlier",
            "return_rate",
            metrics.return_count >= 3 or metrics.return_amount >= Decimal("75.00"),
            metrics.return_amount,
            "Return activity is high compared with peers",
        ),
        (
            "cash_refund_concentration",
            "cash_refund_rate",
            metrics.cash_refund_count >= 3 or metrics.cash_refund_amount >= Decimal("75.00"),
            metrics.cash_refund_amount,
            "Cash refunds are concentrated for this cashier",
        ),
        (
            "discount_peer_outlier",
            "discount_rate",
            metrics.discount_total >= Decimal("50.00") and metrics.paid_order_count >= 3,
            metrics.discount_total,
            "Discount activity is high compared with peers",
        ),
        (
            "low_value_cash_sales",
            "low_value_cash_rate",
            metrics.low_value_cash_order_count >= 5,
            metrics.cash_sales_total,
            "Low-value cash sales are clustered",
        ),
        (
            "cash_pay_out_activity",
            "pay_out_rate",
            metrics.pay_out_count >= 3 or metrics.pay_out_amount >= Decimal("50.00"),
            metrics.pay_out_amount,
            "Cash pay-outs need review",
        ),
        (
            "receipt_reprint_activity",
            "receipt_reprint_rate",
            metrics.receipt_reprint_count >= 3,
            Decimal(metrics.receipt_reprint_count),
            "Receipt reprints are clustered",
        ),
    )
    findings = []
    for rule_code, metric_name, has_volume, amount, headline in candidates:
        if not has_volume:
            continue
        rate = metrics.rate(metric_name)
        stats = _peer_stats_for_user(metric_name, metrics.user_id, peer_context)
        if not _is_peer_outlier(rate, stats):
            continue
        findings.append(
            _finding(
                rule_code,
                metrics,
                peer_context,
                window_start,
                window_end,
                score=_score_from_rate(rate, stats),
                headline=headline,
                amount=amount,
            )
        )
    return findings


def _composite_finding(metrics, peer_context, window_start, window_end):
    adjustment_count = metrics.void_count + metrics.return_count + metrics.pay_out_count
    if metrics.cash_shortage_amount < Decimal("25.00") or adjustment_count < 2:
        return None
    evidence = {
        "cash_shortage": metrics.evidence.get("cash_shortage", [])[:5],
        "void_peer_outlier": metrics.evidence.get("void_peer_outlier", [])[:5],
        "return_peer_outlier": metrics.evidence.get("return_peer_outlier", [])[:5],
        "cash_pay_out_activity": metrics.evidence.get("cash_pay_out_activity", [])[:5],
    }
    return _finding(
        "shortage_with_adjustments",
        metrics,
        peer_context,
        window_start,
        window_end,
        score=90 if metrics.cash_shortage_amount >= Decimal("100.00") else 82,
        headline="Cash shortage appears with void, return, or pay-out activity",
        amount=metrics.cash_shortage_amount,
        evidence=evidence,
        pattern_count=sum(1 for items in evidence.values() if items),
    )


def _finding(
    rule_code,
    metrics,
    peer_context,
    window_start,
    window_end,
    *,
    score,
    headline,
    amount,
    evidence=None,
    pattern_count=1,
):
    rule = RULES[rule_code]
    severity = (
        FraudFinding.Severity.CRITICAL
        if score >= 85
        else FraudFinding.Severity.WARNING
    )
    evidence = evidence or {rule_code: metrics.evidence.get(rule_code, [])[:8]}
    return FindingSpec(
        rule_code=rule_code,
        severity=severity,
        risk_score=min(max(int(score), 0), 100),
        user_id=metrics.user_id,
        user_label=metrics.user_label,
        window_start=window_start,
        window_end=window_end,
        summary={
            "headline": headline,
            "review_wording": "suspected_activity",
            "rule_title": rule.title,
            "rule_description": rule.description,
            "amount": money_string(amount),
        },
        evidence=evidence,
        metrics=_metrics_payload(metrics),
        peer_metrics=_peer_payload(rule.metric, metrics, peer_context),
        pattern_count=pattern_count,
    )


def _metrics_payload(metrics):
    return {
        "paid_order_count": metrics.paid_order_count,
        "paid_sales_total": money_string(metrics.paid_sales_total),
        "paid_subtotal": money_string(metrics.paid_subtotal),
        "discount_total": money_string(metrics.discount_total),
        "cash_order_count": metrics.cash_order_count,
        "cash_sales_total": money_string(metrics.cash_sales_total),
        "low_value_cash_order_count": metrics.low_value_cash_order_count,
        "near_zero_order_count": metrics.near_zero_order_count,
        "void_count": metrics.void_count,
        "void_amount": money_string(metrics.void_amount),
        "return_count": metrics.return_count,
        "return_amount": money_string(metrics.return_amount),
        "cash_refund_count": metrics.cash_refund_count,
        "cash_refund_amount": money_string(metrics.cash_refund_amount),
        "late_adjustment_count": metrics.late_adjustment_count,
        "late_adjustment_amount": money_string(metrics.late_adjustment_amount),
        "pay_out_count": metrics.pay_out_count,
        "pay_out_amount": money_string(metrics.pay_out_amount),
        "closed_session_count": metrics.closed_session_count,
        "cash_shortage_count": metrics.cash_shortage_count,
        "cash_shortage_amount": money_string(metrics.cash_shortage_amount),
        "receipt_reprint_count": metrics.receipt_reprint_count,
    }


def _peer_payload(metric_name, metrics, peer_context):
    stats = _peer_stats_for_user(metric_name, metrics.user_id, peer_context)
    rate = metrics.rate(metric_name)
    return {
        "metric": metric_name,
        "user_rate": round(rate, 4),
        "peer_median": stats.get("median", 0),
        "peer_mad": stats.get("mad", 0),
        "peer_count": stats.get("count", 0),
        "threshold": stats.get("threshold", 0),
        "peer_outlier": _is_peer_outlier(rate, stats),
    }


def _peer_stats_for_user(metric_name, user_id, peer_context):
    context = peer_context.get(metric_name, {})
    rates = context.get("rates", {})
    peer_values = [
        rate
        for peer_user_id, rate in rates.items()
        if peer_user_id != user_id
    ]
    return _robust_stats(peer_values)


def _is_peer_outlier(value, stats):
    if stats.get("count", 0) < MIN_PEER_USERS:
        return value >= max(stats.get("threshold", 0), 0.2)
    return value > stats.get("threshold", 0)


def _score_from_rate(value, stats):
    threshold = max(float(stats.get("threshold", 0)), 0.01)
    ratio = value / threshold
    if ratio >= 2:
        return 88
    if ratio >= 1.5:
        return 80
    return 68


def _robust_stats(values):
    if not values:
        return {"count": 0, "median": 0, "mad": 0, "threshold": 0}
    med = median(values)
    deviations = [abs(value - med) for value in values]
    mad = median(deviations) if deviations else 0
    threshold = med + max(mad * 3, 0.10)
    return {
        "count": len(values),
        "median": round(med, 4),
        "mad": round(mad, 4),
        "threshold": round(threshold, 4),
    }


def _has_reviewable_activity(metrics):
    return any(
        (
            metrics.paid_order_count,
            metrics.void_count,
            metrics.return_count,
            metrics.cash_refund_count,
            metrics.pay_out_count,
            metrics.closed_session_count,
            metrics.receipt_reprint_count,
        )
    )
