from __future__ import annotations

from dataclasses import dataclass
from decimal import Decimal


DETECTION_CODE = "fraud.suspected_cashier_activity"
DEFAULT_LOOKBACK_DAYS = 30
MIN_PEER_USERS = 3
LOW_VALUE_CASH_SALE_THRESHOLD = Decimal("5.00")
MONEY_ZERO = Decimal("0.00")
MONEY_PLACES = Decimal("0.01")


@dataclass(frozen=True)
class DetectionSyncResult:
    active: int
    generated: int
    resolved: int


@dataclass(frozen=True)
class RuleSpec:
    code: str
    title: str
    description: str
    metric: str
    evidence_actions: tuple[str, ...]


@dataclass(frozen=True)
class FindingSpec:
    rule_code: str
    severity: str
    risk_score: int
    user_id: int
    user_label: str
    window_start: object
    window_end: object
    summary: dict
    evidence: dict
    metrics: dict
    peer_metrics: dict
    pattern_count: int = 1

    @property
    def fingerprint(self) -> str:
        return f"{self.rule_code}:user:{self.user_id}"


RULES = {
    "late_void_or_return": RuleSpec(
        code="late_void_or_return",
        title="Late void or return",
        description=(
            "Void or return was created after the cashier adjustment window and "
            "needs review with the original sale."
        ),
        metric="late_adjustment_count",
        evidence_actions=("sales.order.voided", "sales.order.returned"),
    ),
    "cash_shortage": RuleSpec(
        code="cash_shortage",
        title="Cash shortage",
        description="Closed register sessions show repeated or material cash shortages.",
        metric="cash_shortage_rate",
        evidence_actions=("sales.register_session.closed",),
    ),
    "void_peer_outlier": RuleSpec(
        code="void_peer_outlier",
        title="High void activity",
        description="Void count or amount is high compared with peer cashier activity.",
        metric="void_rate",
        evidence_actions=("sales.order.voided",),
    ),
    "return_peer_outlier": RuleSpec(
        code="return_peer_outlier",
        title="High return activity",
        description="Return count or amount is high compared with peer cashier activity.",
        metric="return_rate",
        evidence_actions=("sales.order.returned",),
    ),
    "cash_refund_concentration": RuleSpec(
        code="cash_refund_concentration",
        title="Cash refund concentration",
        description="Cash refunds are concentrated for one cashier compared with sales.",
        metric="cash_refund_rate",
        evidence_actions=("sales.order.returned", "sales.order.voided"),
    ),
    "discount_peer_outlier": RuleSpec(
        code="discount_peer_outlier",
        title="High discount activity",
        description="Discount value is high compared with sales and peer cashiers.",
        metric="discount_rate",
        evidence_actions=("sales.checkout.completed", "sales.order.paid"),
    ),
    "low_value_cash_sales": RuleSpec(
        code="low_value_cash_sales",
        title="Low-value cash sale cluster",
        description="Low-value cash transactions are unusually concentrated.",
        metric="low_value_cash_rate",
        evidence_actions=("sales.checkout.completed", "sales.order.paid"),
    ),
    "cash_pay_out_activity": RuleSpec(
        code="cash_pay_out_activity",
        title="Cash pay-out activity",
        description="Cash pay-outs are repeated or high compared with sales activity.",
        metric="pay_out_rate",
        evidence_actions=("sales.register_cash_movement.created",),
    ),
    "near_zero_sales": RuleSpec(
        code="near_zero_sales",
        title="Near-zero sales",
        description="Completed transactions have no or near-no value after discounts.",
        metric="near_zero_sale_rate",
        evidence_actions=("sales.checkout.completed", "sales.order.paid"),
    ),
    "receipt_reprint_activity": RuleSpec(
        code="receipt_reprint_activity",
        title="Receipt reprint activity",
        description="Receipt reprints are clustered for one cashier.",
        metric="receipt_reprint_rate",
        evidence_actions=("sales.receipt.reprint.queued",),
    ),
    "shortage_with_adjustments": RuleSpec(
        code="shortage_with_adjustments",
        title="Cash shortage with adjustments",
        description=(
            "Cash shortages appear in the same window as voids, returns, or pay-outs."
        ),
        metric="cash_shortage_rate",
        evidence_actions=(
            "sales.register_session.closed",
            "sales.order.voided",
            "sales.order.returned",
            "sales.register_cash_movement.created",
        ),
    ),
}
