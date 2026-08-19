"""Model-based business simulation with an independent correctness oracle.

This module drives a randomized, *seeded* stream of real POS transactions through
the backend — sales of every kind, multi-tender payments, discounts, credit
(آجل) invoices and their settlement, quotations with stock reservations and their
conversion, returns and voids, purchase orders received in parts, supplier
payments, expenses, cash drawer movements, stock counts and register
open/close — and after every single operation it asserts that the backend's
stored quantities and monetary values *exactly* match an independent reference
computation (the "oracle").

The oracle never reads a number back from the backend to decide what to expect.
It recomputes, from the transaction inputs alone, what every quantity and money
value *must* be — using a faithful, independently-written port of the same
arithmetic the backend uses (the dual rounding regimes, the discount allocation
algorithm, the refund tender split, the units base-conversion, the register cash
formula). That is the whole point: it proves the backend's numbers are *correct
for the transactions*, not merely self-consistent.

The arithmetic port is itself guarded by :func:`self_test_arithmetic`, which
reproduces a set of documented worked examples; if the port ever drifts from the
backend it fails there first, with a message that distinguishes a *test* bug from
a *backend* bug.

Determinism: everything random comes from one seeded ``random.Random``. A failing
run prints its seed; re-running with that seed reproduces the exact sequence.

Run it as a test (CI scale)::

    DATABASE_URL='sqlite://:memory:' python manage.py test \
        apps.sales.test_business_simulation

…or at "big business" volume on demand::

    python manage.py simulate_business --operations 20000 --seed 7
"""

from __future__ import annotations

import random
from collections import defaultdict
from dataclasses import dataclass, field
from datetime import timedelta
from decimal import ROUND_DOWN, ROUND_HALF_EVEN, ROUND_HALF_UP, Decimal

from django.contrib.auth import get_user_model
from django.core.exceptions import ValidationError as DjangoValidationError
from django.utils import timezone
from rest_framework.exceptions import ValidationError as DRFValidationError
from rest_framework.test import APIClient

from apps.catalog.models import (
    ModifierGroup,
    ModifierOption,
    ProductModifierGroup,
    ProductUnit,
    UnitOfMeasure,
)
from apps.catalog.testing import create_product_with_default_variant
from apps.core.models import ShopSettings
from apps.customers.models import Customer
from apps.discounts.models import DiscountRule
from apps.expenses.models import Expense, ExpenseCategory
from apps.expenses.services import create_expense
from apps.inventory.models import StockItem, StockMovement
from apps.purchasing.models import PurchaseOrder, Supplier, SupplierPayment
from apps.purchasing.services import (
    create_supplier_payment,
    receive_purchase_order,
    save_purchase_order_with_lines,
    submit_purchase_order,
)
from apps.sales.models import Order, OrderLine, RegisterSession
from apps.sales.services import (
    convert_quotation_to_sale,
    exchange_order_items,
    record_customer_account_payment,
    record_customer_payment,
    release_quote_reservations,
    return_order_items,
    void_order,
)
from apps.sales.services import checkout_order

# ---------------------------------------------------------------------------
# Money / quantity rounding primitives — independent re-implementations of the
# backend's helpers. The backend uses three distinct regimes; the oracle must
# match each exactly:
#   * sales money  (apps/sales/services.py money())   -> 2dp, context default
#                                                        (ROUND_HALF_EVEN)
#   * discount/unit money (discounts/services.money,
#       catalog/units.quantize_money, unit_sale_price) -> 2dp, ROUND_HALF_UP
#   * quantity (catalog/units.quantize_quantity)       -> 3dp, ROUND_HALF_UP
# ---------------------------------------------------------------------------

CENT = Decimal("0.01")
QTY = Decimal("0.001")
ZERO = Decimal("0.00")
HUNDRED = Decimal("100")


def even2(value) -> Decimal:
    """Sales money: quantize to 2dp with banker's rounding (the backend's
    ``money()`` uses the process decimal context, which defaults to HALF_EVEN)."""
    return Decimal(value).quantize(CENT, rounding=ROUND_HALF_EVEN)


def up2(value) -> Decimal:
    """Discount/unit money: quantize to 2dp with HALF_UP."""
    return Decimal(value).quantize(CENT, rounding=ROUND_HALF_UP)


def q3(value) -> Decimal:
    """Quantity: quantize to 3dp with HALF_UP (base-unit conversion)."""
    return Decimal(value).quantize(QTY, rounding=ROUND_HALF_UP)


def allocate_discount_amount(amount: Decimal, weights_by_key: dict) -> dict:
    """Proportional floor + largest-remainder allocation.

    A verbatim, independent port of
    ``apps.discounts.services.allocate_discount_amount``: each key gets the floor
    (ROUND_DOWN) of its proportional share, then the leftover cents are handed
    one-at-a-time to the largest fractional remainders, ties broken by ascending
    string key. Returns ``{key: amount}`` for keys with a positive share, in the
    original ``weights_by_key`` order.
    """
    amount = up2(amount)
    if amount <= ZERO:
        return {}
    positive = {k: w for k, w in weights_by_key.items() if w > ZERO}
    total_weight = sum(positive.values(), ZERO)
    if total_weight <= ZERO:
        return {}

    allocations: dict = {}
    remainders = []
    allocated_total = ZERO
    for key, weight in positive.items():
        exact_share = amount * weight / total_weight
        rounded_share = exact_share.quantize(CENT, rounding=ROUND_DOWN)
        allocations[key] = rounded_share
        allocated_total += rounded_share
        remainders.append((exact_share - rounded_share, key))

    remaining_cents = int(((amount - allocated_total) * HUNDRED).to_integral_value())
    remainders.sort(key=lambda item: (-item[0], str(item[1])))
    for _, key in remainders[:remaining_cents]:
        allocations[key] += CENT

    return {
        key: allocations[key]
        for key in weights_by_key
        if allocations.get(key, ZERO) > ZERO
    }


def allocate_landed_cost(amount: Decimal, weights_by_line_id: dict) -> dict:
    """Independent port of ``PurchaseOrder._landed_cost_allocations``.

    Deliberately NOT a call into :func:`allocate_discount_amount`: the purchasing
    model runs its own allocator, and the two differ in two ways this port has to
    reproduce — zero-weight lines stay in the divisor set here, and ties on the
    fractional remainder are broken by ascending integer line id rather than by
    string key. Returns ``{line_id: amount}`` for every line.
    """
    if amount == ZERO:
        return {line_id: ZERO for line_id in weights_by_line_id}

    weights = dict(weights_by_line_id)
    total_weight = sum(weights.values(), ZERO)
    if total_weight == ZERO:
        return {line_id: ZERO for line_id in weights}

    allocations: dict = {}
    remainders = []
    allocated_total = ZERO
    for line_id, weight in weights.items():
        exact_share = amount * weight / total_weight
        rounded_share = exact_share.quantize(CENT, rounding=ROUND_DOWN)
        allocations[line_id] = rounded_share
        allocated_total += rounded_share
        remainders.append((exact_share - rounded_share, line_id))

    remaining_cents = int(((amount - allocated_total) * HUNDRED).to_integral_value())
    remainders.sort(key=lambda item: (-item[0], item[1]))
    for _, line_id in remainders[:remaining_cents]:
        allocations[line_id] += CENT
    return allocations


def refund_tender_allocations(net_by_method: dict, amount: Decimal) -> list:
    """Split ``amount`` across tenders proportional to net paid per method.

    Independent port of ``apps.sales.services.refund_tender_allocations`` given
    the already-computed net (positive) paid per method. Returns a list of
    ``(method, amount)`` summing exactly to ``amount``.
    """
    amount = up2(amount)
    net_by_method = {m: up2(v) for m, v in net_by_method.items() if up2(v) > ZERO}
    if not net_by_method:
        return []  # caller handles the no-positive-payment fallback

    methods = sorted(net_by_method)
    total_net = sum(net_by_method.values(), ZERO)
    floored = {}
    remainder = {}
    for method in methods:
        share = (amount * net_by_method[method]) / total_net
        floor_share = share.quantize(CENT, rounding=ROUND_DOWN)
        floored[method] = floor_share
        remainder[method] = share - floor_share

    allocated = sum(floored.values(), ZERO)
    leftover_cents = int(((amount - allocated) / CENT).to_integral_value())
    ranked = sorted(methods, key=lambda m: (remainder[m], m), reverse=True)
    for index in range(leftover_cents):
        floored[ranked[index % len(ranked)]] += CENT

    return [(method, floored[method]) for method in methods if floored[method] > ZERO]


def commission_amount(percent: Decimal, amount: Decimal) -> Decimal:
    """Payment commission: ``even2(amount * percent / 100)`` (HALF_EVEN, and
    negative for refunds — same as ``payment_commission_values``)."""
    return even2(Decimal(amount) * Decimal(percent) / HUNDRED)


# ---------------------------------------------------------------------------
# Discount engine — an independent port of the subset of
# ``apps.discounts.services.DiscountEngine`` exercised by this simulation:
# automatic + coupon rules, document/line scope, percentage / fixed_amount /
# fixed_unit_amount / fixed_price value types, optional max-amount cap,
# min-order-subtotal and min-line-quantity gates, product/variant targeting,
# exclusivity and priority/stacking. Rounding modes and usage limits are not
# used by the simulation, so they are intentionally omitted (rounding_mode is
# always NONE on the rules we create).
# ---------------------------------------------------------------------------


@dataclass
class OracleRule:
    rule_id: int
    application_type: str  # "automatic" | "coupon_code"
    coupon_code: str
    scope: str  # "document" | "line"
    value_type: str
    value: Decimal
    priority: int
    exclusive: bool
    max_discount_amount: Decimal | None = None
    min_order_subtotal: Decimal = ZERO
    min_line_quantity: int | None = None
    product_ids: frozenset = frozenset()
    variant_ids: frozenset = frozenset()
    customer_ids: frozenset = frozenset()


@dataclass
class DiscountLine:
    key: str
    product_id: int
    variant_id: int
    quantity: Decimal
    unit_amount: Decimal

    @property
    def subtotal(self) -> Decimal:
        return up2(self.unit_amount * Decimal(self.quantity))


def _normalize_codes(codes) -> set:
    return {c.strip().upper() for c in (codes or ()) if c and c.strip()}


class OracleDiscountEngine:
    """Predicts the per-line discount the backend will store for each line."""

    def __init__(self, rules: list):
        self.rules = sorted(rules, key=lambda r: (r.priority, r.rule_id))

    def _matching_lines(self, rule: OracleRule, lines: list) -> list:
        has_constraints = bool(rule.product_ids or rule.variant_ids)
        matched = []
        for line in lines:
            if has_constraints and not (
                line.product_id in rule.product_ids
                or line.variant_id in rule.variant_ids
            ):
                continue
            if (
                rule.min_line_quantity is not None
                and Decimal(line.quantity) < Decimal(rule.min_line_quantity)
            ):
                continue
            matched.append(line)
        return matched

    def _eligible(self, lines: list, customer_id, coupon_codes) -> list:
        subtotal = up2(sum((line.subtotal for line in lines), ZERO))
        normalized = _normalize_codes(coupon_codes)
        eligible = []
        for rule in self.rules:
            if rule.application_type == DiscountRule.ApplicationType.COUPON_CODE:
                if rule.coupon_code not in normalized:
                    continue
            if subtotal < rule.min_order_subtotal:
                continue
            if rule.customer_ids and customer_id not in rule.customer_ids:
                continue
            if not self._matching_lines(rule, lines):
                continue
            eligible.append(rule)
        return eligible

    def _rule_allocations(self, rule: OracleRule, matching: list, remaining: dict) -> dict:
        if rule.value_type == DiscountRule.ValueType.FIXED_UNIT_AMOUNT:
            return {
                line.key: min(
                    up2(rule.value * Decimal(line.quantity)), remaining[line.key]
                )
                for line in matching
            }

        if rule.scope == DiscountRule.Scope.LINE:
            amounts = {}
            for line in matching:
                if rule.value_type == DiscountRule.ValueType.PERCENTAGE:
                    amount = up2(remaining[line.key] * rule.value / HUNDRED)
                elif rule.value_type == DiscountRule.ValueType.FIXED_PRICE:
                    fixed_total = up2(rule.value * Decimal(line.quantity))
                    amount = max(up2(remaining[line.key] - fixed_total), ZERO)
                else:  # FIXED_AMOUNT
                    amount = min(up2(rule.value), remaining[line.key])
                amounts[line.key] = amount
            return {k: v for k, v in amounts.items() if v > ZERO}

        # document scope
        source_subtotal = up2(sum((remaining[line.key] for line in matching), ZERO))
        if rule.value_type == DiscountRule.ValueType.PERCENTAGE:
            amount = up2(source_subtotal * rule.value / HUNDRED)
        elif rule.value_type == DiscountRule.ValueType.FIXED_PRICE:
            amount = ZERO
        else:  # FIXED_AMOUNT
            amount = min(up2(rule.value), source_subtotal)
        return allocate_discount_amount(
            amount, {line.key: remaining[line.key] for line in matching}
        )

    def _calc_rule(self, rule: OracleRule, lines: list, remaining: dict):
        matching = [
            line
            for line in self._matching_lines(rule, lines)
            if remaining[line.key] > ZERO
        ]
        if not matching:
            return None
        source_subtotal = up2(sum((remaining[line.key] for line in matching), ZERO))
        if source_subtotal <= ZERO:
            return None
        allocations = self._rule_allocations(rule, matching, remaining)
        amount = up2(sum(allocations.values(), ZERO))
        if rule.max_discount_amount is not None and amount > rule.max_discount_amount:
            allocations = allocate_discount_amount(
                up2(rule.max_discount_amount), dict(allocations)
            )
            amount = up2(rule.max_discount_amount)
        if amount <= ZERO:
            return None
        return amount, allocations

    def calculate(self, lines: list, customer_id=None, coupon_codes=()):
        """Return ``(per_line_discount: dict, discount_total: Decimal)``.

        ``per_line_discount`` is keyed by the line key (``str(index)``); the sum
        equals ``discount_total``.
        """
        remaining = {line.key: line.subtotal for line in lines}
        per_line = defaultdict(lambda: ZERO)
        total = ZERO
        applications = 0
        for rule in self._eligible(lines, customer_id, coupon_codes):
            if rule.exclusive and applications:
                continue
            result = self._calc_rule(rule, lines, remaining)
            if result is None:
                continue
            amount, allocations = result
            applications += 1
            total = up2(total + amount)
            for key, alloc in allocations.items():
                per_line[key] = up2(per_line[key] + alloc)
                remaining[key] = up2(remaining[key] - alloc)
            if rule.exclusive:
                break
        return dict(per_line), total


# ---------------------------------------------------------------------------
# Oracle state records
# ---------------------------------------------------------------------------


@dataclass
class LineRec:
    order_line_id: int
    variant_id: int
    unit_price: Decimal
    quantity: Decimal
    unit_factor: Decimal
    discount_total: Decimal
    tracks_stock: bool
    whole_only: bool = True
    returned_qty: Decimal = ZERO  # in the transacted unit
    returned_discount: Decimal = ZERO
    # Cost of one unit *in the transacted unit*, snapshotted when the sale was
    # rung up. Predicted from the purchase that set the variant's cost at that
    # moment, never read back from the order line.
    unit_cost: Decimal = ZERO

    @property
    def line_subtotal(self) -> Decimal:
        return even2(self.unit_price * self.quantity)

    @property
    def line_total(self) -> Decimal:
        return even2(self.line_subtotal - self.discount_total)

    @property
    def line_cost(self) -> Decimal:
        return even2(self.unit_cost * self.quantity)

    @property
    def line_profit(self) -> Decimal:
        return even2(self.line_total - self.line_cost)

    @property
    def returnable_qty(self) -> Decimal:
        return max(self.quantity - self.returned_qty, ZERO)


@dataclass
class OrderRec:
    order_id: int
    sale_type: str
    register_session_id: int
    customer_id: int | None
    lines: list
    subtotal: Decimal
    discount_total: Decimal
    total: Decimal
    sum_positive: Decimal = ZERO  # cumulative positive payments
    amount_paid: Decimal = ZERO  # all payments incl. negative refunds
    paid_by_method: dict = field(default_factory=lambda: defaultdict(lambda: ZERO))
    has_service: bool = False
    voided: bool = False
    converted: bool = False
    reservations: list = field(default_factory=list)  # (variant_id, base_qty)
    reservation_active: bool = False
    created_index: int = 0

    @property
    def balance_due(self) -> Decimal:
        return max(self.total - self.amount_paid, ZERO)

    @property
    def total_cost(self) -> Decimal:
        return even2(sum((line.line_cost for line in self.lines), ZERO))

    @property
    def total_profit(self) -> Decimal:
        return even2(sum((line.line_profit for line in self.lines), ZERO))

    @property
    def status(self) -> str:
        if self.voided:
            return Order.Status.VOID
        if self.sale_type == Order.SaleType.QUOTATION:
            return Order.Status.OPEN
        if self.sum_positive >= self.total and self.total >= ZERO:
            # a fully-paid order stays PAID even after a partial refund
            if self.total == ZERO and self.sum_positive == ZERO:
                return Order.Status.OPEN  # zero-total, never paid
            return Order.Status.PAID
        return Order.Status.OPEN

    @property
    def is_open_credit(self) -> bool:
        return (
            self.sale_type == Order.SaleType.CREDIT
            and self.status == Order.Status.OPEN
            and not self.voided
        )


@dataclass
class SessionRec:
    session_id: int
    opening_cash: Decimal
    closed: bool = False
    closing_cash: Decimal | None = None


@dataclass
class PoLineRec:
    line_id: int
    variant_id: int
    quantity: int  # packs
    unit_factor: Decimal
    unit_cost: Decimal
    recv_accepted: int = 0
    recv_damaged: int = 0
    recv_cancelled: int = 0
    # Cost basis, computed by the oracle from the line's own inputs. These are
    # the numbers a margin is measured against and a supplier return is credited
    # from, so they are money as much as ``total`` is.
    discount_amount: Decimal = ZERO
    net_line_total: Decimal = ZERO
    net_unit_cost: Decimal = ZERO
    allocated_landed_cost: Decimal = ZERO
    landed_unit_cost: Decimal = ZERO
    effective_unit_cost: Decimal = ZERO

    @property
    def line_total(self) -> Decimal:
        return up2(self.unit_cost * Decimal(self.quantity))

    @property
    def effective_line_total(self) -> Decimal:
        return even2(self.net_line_total + self.allocated_landed_cost)

    @property
    def outstanding(self) -> int:
        return max(
            self.quantity - (self.recv_accepted + self.recv_damaged + self.recv_cancelled),
            0,
        )


@dataclass
class PoRec:
    po_id: int
    supplier_id: int
    total: Decimal
    lines: list
    paid: Decimal = ZERO  # excludes supplier_credit
    subtotal: Decimal = ZERO
    extra_discount: Decimal = ZERO
    landed_cost_total: Decimal = ZERO


class Oracle:
    """The independent shadow model of the entire backend money/quantity state."""

    def __init__(self):
        self.on_hand: dict = defaultdict(lambda: ZERO)
        self.committed: dict = defaultdict(lambda: ZERO)
        self.expected: dict = defaultdict(lambda: ZERO)
        self.seed_on_hand: dict = defaultdict(lambda: ZERO)
        self.orders: dict = {}
        self.sessions: dict = {}
        self.pos: dict = {}
        # Cost basis per BASE unit, keyed by variant: what the next sale of this
        # variant will snapshot onto its line. Set by the purchases this
        # simulation issues, from their own inputs.
        self.base_unit_cost: dict = {}
        # Independent logs that mirror exactly what we instructed the backend to
        # do; the register reconciliation + summary expectations are derived from
        # these, never from backend reads.
        self.payments_log = []  # (session_id, method, amount>0, commission)
        self.adjustments_log = []  # (session_id, refund_method, amount, cash_amount)
        self.cash_moves_log = []  # (session_id, movement_type, amount)

    # -- stock --
    def available(self, variant_id: int) -> Decimal:
        return self.on_hand[variant_id] - self.committed[variant_id]

    def seed_stock(self, variant_id: int, quantity: Decimal):
        self.on_hand[variant_id] = q3(quantity)
        self.seed_on_hand[variant_id] = q3(quantity)

    # -- register cash (derived from logs) --
    def session_cash_sales(self, session_id: int) -> Decimal:
        return even2(
            sum(
                (
                    amount
                    for sid, method, amount, _ in self.payments_log
                    if sid == session_id and method == "cash"
                ),
                ZERO,
            )
        )

    def session_pay_in(self, session_id: int) -> Decimal:
        return even2(
            sum(
                (
                    amount
                    for sid, mtype, amount in self.cash_moves_log
                    if sid == session_id and mtype == "pay_in"
                ),
                ZERO,
            )
        )

    def session_pay_out(self, session_id: int) -> Decimal:
        return even2(
            sum(
                (
                    amount
                    for sid, mtype, amount in self.cash_moves_log
                    if sid == session_id and mtype == "pay_out"
                ),
                ZERO,
            )
        )

    def session_cash_refund(self, session_id: int) -> Decimal:
        return even2(
            sum(
                (
                    cash_amount
                    for sid, _, _, cash_amount in self.adjustments_log
                    if sid == session_id
                ),
                ZERO,
            )
        )

    def session_expected_cash(self, session_id: int) -> Decimal:
        rec = self.sessions[session_id]
        return even2(
            rec.opening_cash
            + self.session_cash_sales(session_id)
            + self.session_pay_in(session_id)
            - self.session_pay_out(session_id)
            - self.session_cash_refund(session_id)
        )

    # -- summary per method, per session --
    def session_method_summary(self, session_id: int) -> dict:
        summary = {
            method: {"gross": ZERO, "commission": ZERO, "count": 0, "refund": ZERO}
            for method in ("cash", "card", "transfer")
        }
        for sid, method, amount, commission in self.payments_log:
            if sid == session_id:
                summary[method]["gross"] = even2(summary[method]["gross"] + amount)
                summary[method]["commission"] = even2(
                    summary[method]["commission"] + commission
                )
                summary[method]["count"] += 1
        for sid, refund_method, amount, _ in self.adjustments_log:
            if sid == session_id:
                summary[refund_method]["refund"] = even2(
                    summary[refund_method]["refund"] + amount
                )
        for method in summary:
            row = summary[method]
            row["net"] = even2(row["gross"] - row["refund"])
        return summary

    def customer_ar(self, customer_id: int) -> Decimal:
        return even2(
            sum(
                (
                    order.balance_due
                    for order in self.orders.values()
                    if order.customer_id == customer_id and order.is_open_credit
                ),
                ZERO,
            )
        )


# ---------------------------------------------------------------------------
# Catalog model used by the simulation to build sale lines
# ---------------------------------------------------------------------------


@dataclass
class UnitChoice:
    code: str  # "" for the base unit
    factor: Decimal
    custom_price: Decimal | None
    whole_only: bool


@dataclass
class SaleItem:
    variant: object
    product_id: int
    variant_id: int
    tracks_stock: bool
    units: list  # list[UnitChoice]
    modifier_options: list  # list[(option_id, price_delta)]

    def effective_unit_price(self, unit: UnitChoice, modifiers) -> Decimal:
        if unit.custom_price is not None:
            base = up2(unit.custom_price)
        else:
            base = up2(Decimal(self.variant.unit_price) * unit.factor)
        delta = sum(
            (price_delta * Decimal(qty) for _, price_delta, qty in modifiers), ZERO
        )
        return base + delta


class SimulationError(AssertionError):
    """Raised when the backend's stored state diverges from the oracle."""


# ---------------------------------------------------------------------------
# The simulation driver
# ---------------------------------------------------------------------------


class Simulation:
    PAYMENT_METHODS = ("cash", "card", "transfer")
    SUPPLIER_METHODS = (
        SupplierPayment.Method.CASH,
        SupplierPayment.Method.CARD,
        SupplierPayment.Method.TRANSFER,
        SupplierPayment.Method.BANK_TRANSFER,
    )

    def __init__(self, *, seed: int, checkpoint_every: int = 25, verbose: bool = False):
        self.seed = seed
        self.rng = random.Random(seed)
        self.checkpoint_every = checkpoint_every
        self.verbose = verbose
        self.oracle = Oracle()
        self.client = APIClient()
        self.op_index = 0
        self.current_session_id = None
        self.commission_percent = {"cash": ZERO, "card": ZERO, "transfer": ZERO}
        self.items: list = []  # SaleItem
        self.stock_items: list = []  # SaleItem with tracks_stock
        self.customers: list = []
        self.suppliers: list = []
        self.expense_category = None
        self.discount_engine: OracleDiscountEngine | None = None
        self.coupon_codes = ["SAVE3", "HALF"]
        self.op_counts: dict = defaultdict(int)
        # How much the cost-basis assertions actually got to say. A sale of a
        # never-purchased variant costs 0.00, which every wrong implementation
        # also produces, so a run that only ever saw those has proved nothing
        # about COGS; the entry-point test refuses such a run.
        self.costed_line_assertions = 0
        self.multi_unit_costed_line_assertions = 0

    # -- helpers ----------------------------------------------------------

    def fail(self, message: str):
        raise SimulationError(
            f"[seed={self.seed} op#{self.op_index}] {message}"
        )

    def assert_money(self, actual, expected, what: str):
        if even2(actual) != even2(expected):
            self.fail(f"{what}: backend={even2(actual)} oracle={even2(expected)}")

    def assert_qty(self, actual, expected, what: str):
        if q3(actual) != q3(expected):
            self.fail(f"{what}: backend={q3(actual)} oracle={q3(expected)}")

    def assert_equal(self, actual, expected, what: str):
        if actual != expected:
            self.fail(f"{what}: backend={actual!r} oracle={expected!r}")

    def split_amount(self, total: Decimal, methods: list) -> list:
        """Split ``total`` into per-tender amounts, each >= 0.01, summing exactly
        to ``total``, across a random subset of ``methods``."""
        total = even2(total)
        cents = int((total / CENT).to_integral_value())
        if cents <= 0:
            return []
        max_tenders = min(len(methods), 3, cents)
        n = self.rng.randint(1, max_tenders)
        chosen = self.rng.sample(methods, n)
        if n == 1:
            parts = [cents]
        else:
            cuts = sorted(self.rng.sample(range(1, cents), n - 1))
            bounds = [0, *cuts, cents]
            parts = [bounds[i + 1] - bounds[i] for i in range(n)]
        return [
            (method, (Decimal(part) * CENT).quantize(CENT))
            for method, part in zip(chosen, parts)
        ]

    def log_payment(self, session_id: int, method: str, amount: Decimal):
        commission = commission_amount(self.commission_percent[method], amount)
        self.oracle.payments_log.append((session_id, method, even2(amount), commission))

    def record_order_payment(self, order: OrderRec, method: str, amount: Decimal):
        amount = even2(amount)
        order.sum_positive = even2(order.sum_positive + amount)
        order.amount_paid = even2(order.amount_paid + amount)
        order.paid_by_method[method] = even2(order.paid_by_method[method] + amount)
        # Cash is attributed to the COLLECTING (current) session, which is the
        # accrual-vs-cash split: an آجل invoice issued in an earlier session but
        # settled now puts the revenue in the issuing session and the cash in the
        # current drawer. In every flow here the payment is collected by the
        # session that is open right now.
        self.log_payment(self.current_session_id, method, amount)

    # -- world ------------------------------------------------------------

    def build_world(self):
        settings = ShopSettings.load()
        settings.allow_overselling = False
        settings.prevent_selling_at_loss = False
        settings.require_opening_cash = True
        settings.enable_cash_payments = True
        settings.enable_card_payments = True
        settings.enable_transfer_payments = True
        settings.require_card_payment_receipt = False
        settings.require_customer_for_credit = True
        settings.card_commission_percent = Decimal("1.5")
        settings.transfer_commission_percent = Decimal("0.5")
        settings.save()
        self.commission_percent = {
            "cash": ZERO,
            "card": Decimal("1.5"),
            "transfer": Decimal("0.5"),
        }

        user_model = get_user_model()
        self.user = user_model.objects.create_superuser(
            username="sim-operator", email="sim@example.com", password="sim-pass"
        )
        self.client.force_authenticate(user=self.user)

        box = UnitOfMeasure.objects.get(code="box")
        carton = UnitOfMeasure.objects.get(code="carton")

        # Piece products (whole quantities, base unit).
        for i in range(6):
            self._add_product(
                name=f"Piece {i}",
                sku=f"PCE{i}",
                unit_price=Decimal(["2.00", "3.50", "1.25", "4.00", "0.75", "9.99"][i]),
                base_whole=True,
            )
        # Weight products (fractional kg base unit).
        for i in range(2):
            self._add_product(
                name=f"Weight {i}",
                sku=f"WGT{i}",
                unit_price=Decimal(["3.33", "5.50"][i]),
                base_unit="kg",
                base_whole=False,
            )
        # Multi-unit products: base piece + a box/carton unit, some with a custom
        # per-unit price so unit_sale_price exercises both branches.
        m0 = self._add_product(
            name="Multi 0", sku="MUL0", unit_price=Decimal("1.00"), base_whole=True
        )
        ProductUnit.objects.create(
            product=m0.variant.product, unit=box, factor_to_base=Decimal("12"),
            price=Decimal("11.00"), is_sellable=True, is_purchasable=True,
        )
        m0.units.append(UnitChoice("box", Decimal("12"), Decimal("11.00"), True))

        m1 = self._add_product(
            name="Multi 1", sku="MUL1", unit_price=Decimal("0.50"), base_whole=True
        )
        ProductUnit.objects.create(
            product=m1.variant.product, unit=carton, factor_to_base=Decimal("24"),
            price=None, is_sellable=True, is_purchasable=True,
        )
        m1.units.append(UnitChoice("carton", Decimal("24"), None, True))

        # Service products (no stock).
        for i in range(2):
            self._add_product(
                name=f"Service {i}",
                sku=f"SRV{i}",
                unit_price=Decimal(["10.00", "25.00"][i]),
                is_service=True,
            )

        # Priced modifiers on Piece 0 and Multi 0.
        group = ModifierGroup.objects.create(
            name="Extras", min_select=0, max_select=None
        )
        opt_a = ModifierOption.objects.create(
            group=group, name="Extra A", price_delta=Decimal("0.50"), max_quantity=3
        )
        opt_b = ModifierOption.objects.create(
            group=group, name="Extra B", price_delta=Decimal("1.25"), max_quantity=2
        )
        for item in (self.items[0], m0):
            ProductModifierGroup.objects.create(
                product=item.variant.product, group=group, display_order=0
            )
            item.modifier_options = [
                (opt_a, Decimal("0.50")),
                (opt_b, Decimal("1.25")),
            ]

        # Seed initial stock for every stock-tracked variant.
        for item in self.stock_items:
            quantity = Decimal(self.rng.randint(400, 1200))
            StockItem.objects.create(variant=item.variant, quantity_on_hand=quantity)
            self.oracle.seed_stock(item.variant_id, quantity)

        # Customers, suppliers, expense category.
        self.customers = [
            Customer.objects.create(full_name=f"Customer {i}") for i in range(4)
        ]
        self.suppliers = [
            Supplier.objects.create(name=f"Supplier {i}") for i in range(3)
        ]
        self.expense_category = ExpenseCategory.objects.create(name="Misc")

        self._build_discounts()
        self._open_register()

    def _add_product(
        self,
        *,
        name,
        sku,
        unit_price,
        base_unit="piece",
        base_whole=True,
        is_service=False,
    ) -> SaleItem:
        product = create_product_with_default_variant(
            name=name, sku=sku, unit_price=str(unit_price)
        )
        if base_unit != "piece" or is_service:
            product.unit = base_unit
            product.is_service = is_service
            product.save(update_fields=["unit", "is_service"])
        variant = product.default_variant
        item = SaleItem(
            variant=variant,
            product_id=product.id,
            variant_id=variant.id,
            tracks_stock=not is_service,
            units=[UnitChoice("", Decimal("1"), None, base_whole)],
            modifier_options=[],
        )
        self.items.append(item)
        if item.tracks_stock:
            self.stock_items.append(item)
        return item

    def _build_discounts(self):
        rules = []
        specs = [
            dict(
                name="Auto 10%",
                application_type=DiscountRule.ApplicationType.AUTOMATIC,
                coupon_code="",
                scope=DiscountRule.Scope.DOCUMENT,
                value_type=DiscountRule.ValueType.PERCENTAGE,
                value=Decimal("10"),
                priority=20,
                exclusive=False,
            ),
            dict(
                name="Auto 5 off over 40",
                application_type=DiscountRule.ApplicationType.AUTOMATIC,
                coupon_code="",
                scope=DiscountRule.Scope.DOCUMENT,
                value_type=DiscountRule.ValueType.FIXED_AMOUNT,
                value=Decimal("5"),
                priority=30,
                exclusive=False,
                min_order_subtotal=Decimal("40.00"),
            ),
            dict(
                name="Piece1 line 15%",
                application_type=DiscountRule.ApplicationType.AUTOMATIC,
                coupon_code="",
                scope=DiscountRule.Scope.LINE,
                value_type=DiscountRule.ValueType.PERCENTAGE,
                value=Decimal("15"),
                priority=10,
                exclusive=False,
                min_line_quantity=2,
                products=[self.items[1].variant.product],
            ),
            dict(
                name="Piece2 0.50/unit",
                application_type=DiscountRule.ApplicationType.AUTOMATIC,
                coupon_code="",
                scope=DiscountRule.Scope.LINE,
                value_type=DiscountRule.ValueType.FIXED_UNIT_AMOUNT,
                value=Decimal("0.50"),
                priority=15,
                exclusive=False,
                products=[self.items[2].variant.product],
            ),
            dict(
                name="Coupon SAVE3",
                application_type=DiscountRule.ApplicationType.COUPON_CODE,
                coupon_code="SAVE3",
                scope=DiscountRule.Scope.DOCUMENT,
                value_type=DiscountRule.ValueType.FIXED_AMOUNT,
                value=Decimal("3"),
                priority=40,
                exclusive=False,
            ),
            dict(
                name="Coupon HALF",
                application_type=DiscountRule.ApplicationType.COUPON_CODE,
                coupon_code="HALF",
                scope=DiscountRule.Scope.DOCUMENT,
                value_type=DiscountRule.ValueType.PERCENTAGE,
                value=Decimal("50"),
                priority=5,
                exclusive=True,
                max_discount_amount=Decimal("8.00"),
            ),
        ]
        for spec in specs:
            products = spec.pop("products", None)
            min_line_quantity = spec.pop("min_line_quantity", None)
            min_order_subtotal = spec.pop("min_order_subtotal", ZERO)
            max_discount_amount = spec.pop("max_discount_amount", None)
            rule = DiscountRule.objects.create(
                channel=DiscountRule.Channel.SALES,
                is_active=True,
                min_order_subtotal=min_order_subtotal,
                min_line_quantity=min_line_quantity,
                max_discount_amount=max_discount_amount,
                **spec,
            )
            if products:
                rule.products.set(products)
            rules.append(
                OracleRule(
                    rule_id=rule.id,
                    application_type=rule.application_type,
                    coupon_code=rule.coupon_code,
                    scope=rule.scope,
                    value_type=rule.value_type,
                    value=rule.value,
                    priority=rule.priority,
                    exclusive=rule.exclusive,
                    max_discount_amount=max_discount_amount,
                    min_order_subtotal=min_order_subtotal,
                    min_line_quantity=min_line_quantity,
                    product_ids=frozenset(p.id for p in (products or [])),
                )
            )
        self.discount_engine = OracleDiscountEngine(rules)

    # -- register lifecycle ----------------------------------------------

    def _open_register(self):
        opening = (Decimal(self.rng.randint(0, 200)) * CENT * Decimal("10")).quantize(
            CENT
        )
        response = self.client.post(
            "/api/register-sessions/start/",
            {"opening_cash": str(opening)},
            format="json",
        )
        if response.status_code != 200:
            self.fail(f"register start failed: {response.status_code} {response.data}")
        session_id = response.data["id"]
        self.current_session_id = session_id
        self.oracle.sessions[session_id] = SessionRec(
            session_id=session_id, opening_cash=even2(opening)
        )

    def _register_session_obj(self) -> RegisterSession:
        return RegisterSession.objects.get(pk=self.current_session_id)

    # -- sale-line construction ------------------------------------------

    def _pick_line(self, item: SaleItem, max_units: int = 6):
        """Build one sale line for ``item`` (respecting oracle availability for
        stock items). Returns a spec dict, or None if it cannot be satisfied."""
        unit = self.rng.choice(item.units)
        if item.tracks_stock:
            available = self.oracle.available(item.variant_id)
            if available <= ZERO:
                return None
            if unit.whole_only:
                cap = int(available / unit.factor)
                if cap < 1:
                    return None
                quantity = Decimal(self.rng.randint(1, min(cap, max_units)))
            else:
                cap = available / unit.factor
                if cap < Decimal("0.25"):
                    return None
                steps = int(min(cap, Decimal(max_units)) / Decimal("0.25"))
                quantity = Decimal(self.rng.randint(1, max(steps, 1))) * Decimal("0.25")
        else:
            if unit.whole_only:
                quantity = Decimal(self.rng.randint(1, max_units))
            else:
                quantity = Decimal(self.rng.randint(1, max_units * 4)) * Decimal("0.25")

        modifiers = []
        if item.modifier_options and self.rng.random() < 0.5:
            for option, price_delta in item.modifier_options:
                if self.rng.random() < 0.5:
                    qty = self.rng.randint(1, min(option.max_quantity or 1, 2))
                    modifiers.append((option, price_delta, qty))
        eff_price = item.effective_unit_price(unit, modifiers)
        base_qty = q3(quantity * unit.factor)
        return {
            "item": item,
            "unit": unit,
            "quantity": quantity,
            "modifiers": modifiers,
            "eff_price": eff_price,
            "base_qty": base_qty,
        }

    def _choose_lines(self, *, include_service: bool, stock_only: bool = False):
        pool = list(self.stock_items if stock_only else self.items)
        if not include_service and not stock_only:
            pool = [i for i in pool if i.tracks_stock]
        self.rng.shuffle(pool)
        count = self.rng.randint(1, min(4, len(pool)))
        specs = []
        for item in pool[:count]:
            spec = self._pick_line(item)
            if spec is not None:
                specs.append(spec)
        return specs

    def _build_lines_payload(self, specs):
        lines_data = []
        for spec in specs:
            line = {
                "variant": spec["item"].variant,
                "quantity": spec["quantity"],
                "unit": spec["unit"].code,
                "unit_factor": spec["unit"].factor,
                "effective_unit_price": spec["eff_price"],
                "notes": "",
            }
            if spec["modifiers"]:
                line["modifiers"] = [
                    {"option": option, "quantity": qty}
                    for option, _, qty in spec["modifiers"]
                ]
            lines_data.append(line)
        return lines_data

    def _compute_discounts(self, specs, customer_id, coupon_codes):
        discount_lines = [
            DiscountLine(
                key=str(index),
                product_id=spec["item"].product_id,
                variant_id=spec["item"].variant_id,
                quantity=spec["quantity"],
                unit_amount=spec["eff_price"],
            )
            for index, spec in enumerate(specs)
        ]
        return self.discount_engine.calculate(discount_lines, customer_id, coupon_codes)

    def _order_totals(self, specs, per_line_discount):
        subtotal = even2(
            sum((even2(s["eff_price"] * s["quantity"]) for s in specs), ZERO)
        )
        discount_total = sum(
            (per_line_discount.get(str(i), ZERO) for i in range(len(specs))), ZERO
        )
        discount_total = min(even2(discount_total), subtotal)
        total = even2(subtotal - discount_total)
        return subtotal, discount_total, total

    def _expected_unit_cost(self, variant_id: int, unit_factor: Decimal) -> Decimal:
        """The cost a sale line for ``variant_id`` must snapshot right now.

        Ported from the documented backend chain, not read back from it: the
        most recent non-cancelled purchase line for the variant supplies a cost
        per BASE unit (``PurchaseLine.base_unit_cost``), which the sale scales
        by the factor of the unit it is transacting in, so
        ``unit_cost * quantity`` stays the cost of the goods that actually left.
        A variant nobody has purchased yet costs nothing — this world has no
        production, so there is no second source to fall back to.

        Note the cost is *not* the effective (landed, discounted) cost: the
        backend deliberately reads the raw purchase price here, so the oracle
        must too, and a change to either side has to show up as a divergence.
        """
        base_cost = self.oracle.base_unit_cost.get(variant_id, ZERO)
        return even2(base_cost * unit_factor)

    def _build_order_rec(self, order, specs, per_line_discount, sale_type, customer_id):
        subtotal, discount_total, total = self._order_totals(specs, per_line_discount)
        order_lines = list(order.lines.order_by("pk"))
        if len(order_lines) != len(specs):
            self.fail(
                f"line count mismatch: backend={len(order_lines)} oracle={len(specs)}"
            )
        line_recs = []
        for index, (spec, order_line) in enumerate(zip(specs, order_lines)):
            line_recs.append(
                LineRec(
                    order_line_id=order_line.pk,
                    variant_id=spec["item"].variant_id,
                    unit_price=spec["eff_price"],
                    quantity=spec["quantity"],
                    unit_factor=spec["unit"].factor,
                    discount_total=per_line_discount.get(str(index), ZERO),
                    tracks_stock=spec["item"].tracks_stock,
                    whole_only=spec["unit"].whole_only,
                    unit_cost=self._expected_unit_cost(
                        spec["item"].variant_id, spec["unit"].factor
                    ),
                )
            )
        rec = OrderRec(
            order_id=order.pk,
            sale_type=sale_type,
            register_session_id=self.current_session_id,
            customer_id=customer_id,
            lines=line_recs,
            subtotal=subtotal,
            discount_total=discount_total,
            total=total,
            has_service=any(not s["item"].tracks_stock for s in specs),
            created_index=self.op_index,
        )
        self.oracle.orders[order.pk] = rec
        return rec

    def _apply_sale_stock(self, specs):
        for spec in specs:
            if spec["item"].tracks_stock:
                vid = spec["item"].variant_id
                self.oracle.on_hand[vid] = q3(self.oracle.on_hand[vid] - spec["base_qty"])

    # -- operations -------------------------------------------------------

    def op_standard_sale(self) -> bool:
        specs = self._choose_lines(include_service=self.rng.random() < 0.25)
        if not specs:
            return False
        customer = self.rng.choice(self.customers) if self.rng.random() < 0.5 else None
        customer_id = customer.id if customer else None
        coupon_codes = self._random_coupons()
        per_line_discount, _ = self._compute_discounts(specs, customer_id, coupon_codes)
        _, _, total = self._order_totals(specs, per_line_discount)
        if total <= ZERO:
            return False
        payments = self.split_amount(total, list(self.PAYMENT_METHODS))
        lines_data = self._build_lines_payload(specs)
        order = checkout_order(
            register_session=self._register_session_obj(),
            lines_data=lines_data,
            payments_data=[{"method": m, "amount": a} for m, a in payments],
            customer=customer,
            coupon_codes=coupon_codes,
            sale_type=Order.SaleType.STANDARD,
            request=None,
        )
        rec = self._build_order_rec(
            order, specs, per_line_discount, Order.SaleType.STANDARD, customer_id
        )
        self._apply_sale_stock(specs)
        for method, amount in payments:
            self.record_order_payment(rec, method, amount)
        self._assert_order(rec)
        self._assert_touched(specs)
        self._assert_session(self.current_session_id)
        return True

    def op_credit_sale(self) -> bool:
        specs = self._choose_lines(include_service=self.rng.random() < 0.25)
        if not specs:
            return False
        customer = self.rng.choice(self.customers)
        per_line_discount, _ = self._compute_discounts(specs, customer.id, ())
        _, _, total = self._order_totals(specs, per_line_discount)
        if total <= ZERO:
            return False
        # Random down-payment between nothing and the full total.
        down = (Decimal(self.rng.randint(0, int(total / CENT))) * CENT).quantize(CENT)
        payments = self.split_amount(down, list(self.PAYMENT_METHODS)) if down > ZERO else []
        lines_data = self._build_lines_payload(specs)
        order = checkout_order(
            register_session=self._register_session_obj(),
            lines_data=lines_data,
            payments_data=[{"method": m, "amount": a} for m, a in payments],
            customer=customer,
            sale_type=Order.SaleType.CREDIT,
            request=None,
        )
        rec = self._build_order_rec(
            order, specs, per_line_discount, Order.SaleType.CREDIT, customer.id
        )
        self._apply_sale_stock(specs)
        for method, amount in payments:
            self.record_order_payment(rec, method, amount)
        self._assert_order(rec)
        self._assert_touched(specs)
        self._assert_session(self.current_session_id)
        self._assert_customer(customer.id)
        return True

    def op_customer_payment(self) -> bool:
        candidates = [
            o for o in self.oracle.orders.values() if o.is_open_credit and o.balance_due > ZERO
        ]
        if not candidates:
            return False
        rec = self.rng.choice(candidates)
        amount = (
            Decimal(self.rng.randint(1, int(rec.balance_due / CENT))) * CENT
        ).quantize(CENT)
        method = self.rng.choice(self.PAYMENT_METHODS)
        record_customer_payment(
            Order.objects.get(pk=rec.order_id),
            method=method,
            amount=amount,
            register_session=self._register_session_obj(),
            request=None,
            allow_cross_owner=True,
        )
        self.record_order_payment(rec, method, amount)
        self._assert_order(rec)
        self._assert_session(self.current_session_id)
        if rec.customer_id is not None:
            self._assert_customer(rec.customer_id)
        return True

    def op_customer_account_payment(self) -> bool:
        by_customer = defaultdict(list)
        for o in self.oracle.orders.values():
            if o.is_open_credit and o.balance_due > ZERO and o.customer_id is not None:
                by_customer[o.customer_id].append(o)
        candidates = [cid for cid, orders in by_customer.items() if orders]
        if not candidates:
            return False
        customer_id = self.rng.choice(candidates)
        orders = sorted(by_customer[customer_id], key=lambda o: (o.created_index, o.order_id))
        outstanding = sum((o.balance_due for o in orders), ZERO)
        amount = (
            Decimal(self.rng.randint(1, int(outstanding / CENT))) * CENT
        ).quantize(CENT)
        method = self.rng.choice(self.PAYMENT_METHODS)
        record_customer_account_payment(
            Customer.objects.get(pk=customer_id),
            method=method,
            amount=amount,
            register_session=self._register_session_obj(),
            request=None,
        )
        # Mirror the oldest-first allocation exactly.
        remaining = amount
        for rec in orders:
            if remaining <= ZERO:
                break
            portion = min(remaining, rec.balance_due)
            if portion <= ZERO:
                continue
            self.record_order_payment(rec, method, portion)
            remaining = even2(remaining - portion)
            self._assert_order(rec)
        self._assert_session(self.current_session_id)
        self._assert_customer(customer_id)
        return True

    def op_quotation(self) -> bool:
        specs = self._choose_lines(include_service=False, stock_only=True)
        if not specs:
            return False
        customer = self.rng.choice(self.customers)
        per_line_discount, _ = self._compute_discounts(specs, customer.id, ())
        lines_data = self._build_lines_payload(specs)
        valid_until = timezone.now().date() + timedelta(days=7)
        order = checkout_order(
            register_session=self._register_session_obj(),
            lines_data=lines_data,
            payments_data=[],
            customer=customer,
            sale_type=Order.SaleType.QUOTATION,
            valid_until=valid_until,
            reserve_stock=True,
            request=None,
        )
        rec = self._build_order_rec(
            order, specs, per_line_discount, Order.SaleType.QUOTATION, customer.id
        )
        rec.reservation_active = True
        for spec in specs:
            vid = spec["item"].variant_id
            rec.reservations.append((vid, spec["base_qty"]))
            self.oracle.committed[vid] = q3(self.oracle.committed[vid] + spec["base_qty"])
        self._assert_order(rec)
        self._assert_touched(specs)
        return True

    def op_convert_quotation(self) -> bool:
        candidates = [
            o
            for o in self.oracle.orders.values()
            if o.sale_type == Order.SaleType.QUOTATION
            and o.reservation_active
            and not o.voided
        ]
        if not candidates:
            return False
        quote = self.rng.choice(candidates)
        sale_type = self.rng.choice([Order.SaleType.STANDARD, Order.SaleType.CREDIT])
        total = quote.total
        if total <= ZERO:
            return False
        if sale_type == Order.SaleType.STANDARD:
            down = total
        else:
            down = (Decimal(self.rng.randint(0, int(total / CENT))) * CENT).quantize(CENT)
        payments = self.split_amount(down, list(self.PAYMENT_METHODS)) if down > ZERO else []
        new_order = convert_quotation_to_sale(
            Order.objects.get(pk=quote.order_id),
            sale_type=sale_type,
            register_session=self._register_session_obj(),
            payments_data=[{"method": m, "amount": a} for m, a in payments],
            request=None,
        )
        # Release the holds and move on-hand for the converted sale.
        for vid, base_qty in quote.reservations:
            self.oracle.committed[vid] = q3(self.oracle.committed[vid] - base_qty)
            self.oracle.on_hand[vid] = q3(self.oracle.on_hand[vid] - base_qty)
        quote.reservation_active = False
        quote.voided = True
        quote.converted = True

        new_lines = list(new_order.lines.order_by("pk"))
        line_recs = []
        for src, order_line in zip(quote.lines, new_lines):
            line_recs.append(
                LineRec(
                    order_line_id=order_line.pk,
                    variant_id=src.variant_id,
                    unit_price=src.unit_price,
                    quantity=src.quantity,
                    unit_factor=src.unit_factor,
                    discount_total=src.discount_total,
                    tracks_stock=src.tracks_stock,
                    whole_only=src.whole_only,
                    # A conversion rings up a NEW sale through the ordinary
                    # checkout path, so it takes a fresh cost snapshot: if a
                    # purchase moved the cost between quoting and converting,
                    # the sale carries the newer one, not the quote's.
                    unit_cost=self._expected_unit_cost(
                        src.variant_id, src.unit_factor
                    ),
                )
            )
        rec = OrderRec(
            order_id=new_order.pk,
            sale_type=sale_type,
            register_session_id=self.current_session_id,
            customer_id=quote.customer_id,
            lines=line_recs,
            subtotal=quote.subtotal,
            discount_total=quote.discount_total,
            total=quote.total,
            created_index=self.op_index,
        )
        self.oracle.orders[new_order.pk] = rec
        for method, amount in payments:
            self.record_order_payment(rec, method, amount)
        self._assert_order(quote)
        self._assert_order(rec)
        for vid, _ in quote.reservations:
            self._assert_variant(vid)
        self._assert_session(self.current_session_id)
        if quote.customer_id is not None:
            self._assert_customer(quote.customer_id)
        return True

    def op_release_quotation(self) -> bool:
        candidates = [
            o
            for o in self.oracle.orders.values()
            if o.sale_type == Order.SaleType.QUOTATION
            and o.reservation_active
            and not o.voided
        ]
        if not candidates:
            return False
        quote = self.rng.choice(candidates)
        release_quote_reservations(Order.objects.get(pk=quote.order_id))
        for vid, base_qty in quote.reservations:
            self.oracle.committed[vid] = q3(self.oracle.committed[vid] - base_qty)
        quote.reservation_active = False
        for vid, _ in quote.reservations:
            self._assert_variant(vid)
        return True

    def _refundable_orders(self):
        return [
            o
            for o in self.oracle.orders.values()
            if o.sale_type in (Order.SaleType.STANDARD, Order.SaleType.CREDIT)
            and o.status == Order.Status.PAID
            and not o.voided
            and not o.has_service
            and any(line.returnable_qty > ZERO for line in o.lines)
        ]

    def _apply_refund(self, rec: OrderRec, refund_lines) -> Decimal:
        """refund_lines: list of (LineRec, qty). Applies the documented refund
        arithmetic to the oracle and returns the refund total (asserts handled
        by the caller)."""
        total = ZERO
        per_line_refund = []
        for line, qty in refund_lines:
            refund_discount = self._line_refund_discount(line, qty)
            gross = even2(line.unit_price * Decimal(qty))
            amount = even2(gross - refund_discount)
            per_line_refund.append((line, qty, refund_discount))
            total = even2(total + amount)
        net_by_method = {m: v for m, v in rec.paid_by_method.items() if v > ZERO}
        allocations = refund_tender_allocations(net_by_method, total)
        cash_amount = sum((a for m, a in allocations if m == "cash"), ZERO)
        primary_method = max(allocations, key=lambda item: item[1])[0]
        for method, alloc in allocations:
            rec.paid_by_method[method] = even2(rec.paid_by_method[method] - alloc)
            rec.amount_paid = even2(rec.amount_paid - alloc)
        self.oracle.adjustments_log.append(
            (self.current_session_id, primary_method, even2(total), even2(cash_amount))
        )
        for line, qty, refund_discount in per_line_refund:
            line.returned_qty = line.returned_qty + Decimal(qty)
            line.returned_discount = even2(line.returned_discount + refund_discount)
            if line.tracks_stock:
                base = q3(Decimal(qty) * line.unit_factor)
                self.oracle.on_hand[line.variant_id] = q3(
                    self.oracle.on_hand[line.variant_id] + base
                )
        if all(line.returnable_qty <= ZERO for line in rec.lines):
            rec.voided = True
        return even2(total)

    def _line_refund_discount(self, line: LineRec, qty) -> Decimal:
        if line.discount_total <= ZERO:
            return ZERO
        remaining_discount = even2(line.discount_total - line.returned_discount)
        if Decimal(qty) >= line.returnable_qty:
            return max(remaining_discount, ZERO)
        proportional = even2(line.discount_total * Decimal(qty) / Decimal(line.quantity))
        return min(proportional, max(remaining_discount, ZERO))

    def op_return_items(self) -> bool:
        candidates = self._refundable_orders()
        if not candidates:
            return False
        rec = self.rng.choice(candidates)
        returnable = [line for line in rec.lines if line.returnable_qty > ZERO]
        chosen = self.rng.sample(returnable, self.rng.randint(1, len(returnable)))
        refund_lines = []
        api_lines = []
        for line in chosen:
            qty = self._pick_return_qty(line)
            if qty <= ZERO:
                continue
            refund_lines.append((line, qty))
            api_lines.append((OrderLine.objects.get(pk=line.order_line_id), qty))
        if not refund_lines:
            return False
        return_order_items(
            order=Order.objects.get(pk=rec.order_id),
            lines=api_lines,
            reason="sim return",
            register_session=self._register_session_obj(),
            request=None,
        )
        self._apply_refund(rec, refund_lines)
        self._assert_order(rec)
        for line, _ in refund_lines:
            self._assert_variant(line.variant_id)
        self._assert_session(self.current_session_id)
        return True

    def op_exchange(self) -> bool:
        """Swap goods from a past order for different goods, in one operation.

        An exchange is not a refund and it is not a sale — it is both, glued by
        an arithmetic of its own, and that glue is what this models. The
        customer hands back part of an old order and walks out with something
        else, settling only the *difference*; the drawer, however, must see both
        legs at full gross (a refund out, a payment in), because that is what
        actually moved. A shop is defrauded quietly if the net the customer pays
        and the gross the drawer records ever stop agreeing.

        Everything expected here is computed from this operation's own inputs:
        the outbound total from the documented refund arithmetic already ported
        for returns, the replacement total from the ported discount engine
        priced (as the backend prices it) against the *original* order's
        customer with no coupon, and the net as their difference. Nothing is
        read back from the backend to decide what to expect.
        """
        candidates = self._refundable_orders()
        if not candidates:
            return False
        rec = self.rng.choice(candidates)
        returnable = [line for line in rec.lines if line.returnable_qty > ZERO]
        outbound = []
        outbound_api_lines = []
        for line in self.rng.sample(returnable, self.rng.randint(1, len(returnable))):
            qty = self._pick_return_qty(line)
            if qty <= ZERO:
                continue
            outbound.append((line, qty))
            outbound_api_lines.append((OrderLine.objects.get(pk=line.order_line_id), qty))
        if not outbound:
            return False
        # Replacement goods are chosen against availability as it stands *before*
        # the outbound leg restocks — deliberately conservative, so the choice can
        # never trip the backend's stock guard on quantities the return is about
        # to hand back.
        specs = self._choose_lines(include_service=False)
        if not specs:
            return False
        # The backend prices the replacement leg with the ORIGINAL order's
        # customer and no coupon codes; mirror exactly that.
        customer_id = rec.customer_id
        per_line_discount, _ = self._compute_discounts(specs, customer_id, ())
        _, _, replacement_total = self._order_totals(specs, per_line_discount)
        if replacement_total <= ZERO:
            return False
        settlement = self.rng.choice(list(self.PAYMENT_METHODS))
        exchange = exchange_order_items(
            order=Order.objects.get(pk=rec.order_id),
            outbound_lines=outbound_api_lines,
            replacement_lines=self._build_lines_payload(specs),
            settlement_method=settlement,
            reason="sim exchange",
            register_session=self._register_session_obj(),
            request=None,
        )
        # Apply the two legs to the oracle in the order the backend applies
        # them: refund first (restocks, reverses tenders), then the new sale.
        outbound_total = self._apply_refund(rec, outbound)
        replacement_rec = self._build_order_rec(
            exchange.replacement_order,
            specs,
            per_line_discount,
            Order.SaleType.STANDARD,
            customer_id,
        )
        self._apply_sale_stock(specs)
        self.record_order_payment(replacement_rec, settlement, replacement_total)

        self.assert_money(
            exchange.outbound_amount, outbound_total, "exchange outbound_amount"
        )
        self.assert_money(
            exchange.replacement_amount, replacement_total, "exchange replacement_amount"
        )
        self.assert_money(
            exchange.net_amount,
            even2(replacement_total - outbound_total),
            "exchange net_amount",
        )
        self.assert_equal(
            exchange.settlement_method, settlement, "exchange settlement_method"
        )
        self.assert_equal(
            exchange.original_order_id, rec.order_id, "exchange original_order"
        )
        self._assert_order(rec)
        self._assert_order(replacement_rec)
        for line, _ in outbound:
            self._assert_variant(line.variant_id)
        self._assert_touched(specs)
        self._assert_session(self.current_session_id)
        if customer_id is not None:
            self._assert_customer(customer_id)
        return True

    def op_void_order(self) -> bool:
        candidates = self._refundable_orders()
        if not candidates:
            return False
        rec = self.rng.choice(candidates)
        refund_lines = [
            (line, line.returnable_qty) for line in rec.lines if line.returnable_qty > ZERO
        ]
        void_order(
            order=Order.objects.get(pk=rec.order_id),
            reason="sim void",
            register_session=self._register_session_obj(),
            request=None,
        )
        self._apply_refund(rec, refund_lines)
        rec.voided = True
        self._assert_order(rec)
        for line, _ in refund_lines:
            self._assert_variant(line.variant_id)
        self._assert_session(self.current_session_id)
        return True

    def _pick_return_qty(self, line: LineRec) -> Decimal:
        returnable = line.returnable_qty
        if line.whole_only:
            whole = int(returnable)
            if whole < 1:
                return ZERO
            return Decimal(self.rng.randint(1, whole))
        # fractional/weight line: return a 0.25 multiple up to returnable
        steps = int(returnable / Decimal("0.25"))
        if steps < 1:
            return returnable
        return Decimal(self.rng.randint(1, steps)) * Decimal("0.25")

    def op_purchase_submit(self) -> bool:
        supplier = self.rng.choice(self.suppliers)
        pool = list(self.stock_items)
        self.rng.shuffle(pool)
        chosen = pool[: self.rng.randint(1, 3)]
        lines_data = []
        line_specs = []
        for item in chosen:
            quantity = self.rng.randint(5, 40)
            unit_cost = (Decimal(self.rng.randint(25, 500)) * CENT).quantize(CENT)
            lines_data.append(
                {"variant": item.variant, "quantity": quantity, "unit_cost": unit_cost}
            )
            line_specs.append((item, quantity, unit_cost))
        # Freight/customs typed onto the order, and the one-off manual discount
        # the buyer knocks off the whole thing. Both land on the ORDER but have
        # to be spread over the LINES, which is where a cost basis lives.
        landed_entries = [
            {
                "name": f"landed {index}",
                "amount": (Decimal(self.rng.randint(1, 4000)) * CENT).quantize(CENT),
            }
            for index in range(self.rng.choice((0, 0, 1, 1, 2)))
        ]
        allocation_method = self.rng.choice(
            [choice[0] for choice in PurchaseOrder.LandedCostAllocationMethod.choices]
        )
        subtotal = ZERO
        for _, quantity, unit_cost in line_specs:
            subtotal = even2(subtotal + up2(unit_cost * quantity))
        extra_requested = ZERO
        if self.rng.random() < 0.3:
            # Spans the ordinary "shave the fraction off" case and the extreme
            # one where the manual discount swallows the whole order.
            ceiling = int(subtotal / CENT)
            extra_requested = (
                Decimal(self.rng.randint(1, ceiling + ceiling // 4)) * CENT
            ).quantize(CENT)
        po = save_purchase_order_with_lines(
            supplier=supplier,
            lines_data=lines_data,
            landed_cost_entries_data=landed_entries or None,
            extra_discount_amount=extra_requested,
            landed_cost_allocation_method=allocation_method,
            request=None,
        )
        submit_purchase_order(po, request=None)
        po_lines = list(po.lines.order_by("pk"))
        line_recs = []
        for (item, quantity, unit_cost), po_line in zip(line_specs, po_lines):
            po_line_rec = PoLineRec(
                line_id=po_line.pk,
                variant_id=item.variant_id,
                quantity=quantity,
                unit_factor=Decimal("1"),
                unit_cost=unit_cost,
            )
            line_recs.append(po_line_rec)
            # The newest purchase line for a variant is the one a sale reads,
            # whether or not the order has been received yet — only a CANCELLED
            # order drops out, and this simulation cancels none. Re-expressed
            # per base unit, exactly as PurchaseLine.base_unit_cost does.
            self.oracle.base_unit_cost[item.variant_id] = even2(
                po_line_rec.unit_cost / po_line_rec.unit_factor
            )
            base = q3(Decimal(quantity))
            self.oracle.expected[item.variant_id] = q3(
                self.oracle.expected[item.variant_id] + base
            )
        landed_total = even2(
            sum((entry["amount"] for entry in landed_entries), ZERO)
        )
        # No PURCHASING discount rule exists in this world, so the engine's
        # discount is nil and the manual discount is clamped to the subtotal.
        extra = min(extra_requested, max(subtotal, ZERO))
        rec = PoRec(
            po_id=po.pk,
            supplier_id=supplier.id,
            total=even2(subtotal - extra + landed_total),
            lines=line_recs,
            subtotal=subtotal,
            extra_discount=extra,
            landed_cost_total=landed_total,
        )
        self._expect_po_line_costs(
            rec,
            allocation_method,
            {line.line_id: item.variant.unit_price for line, (item, _, _) in
             zip(line_recs, line_specs)},
        )
        self.oracle.pos[po.pk] = rec
        self._assert_po(po.pk, expected_status=PurchaseOrder.Status.SUBMITTED)
        for item, _, _ in line_specs:
            self._assert_variant(item.variant_id)
        return True

    def _expect_po_line_costs(self, rec: PoRec, allocation_method, retail_prices):
        """Compute every line's cost basis from the order's OWN inputs.

        Nothing here reads a figure back off the purchase order: the manual
        discount is spread with the ported largest-remainder allocator, the
        landed costs with the ported purchasing allocator, and the per-unit
        figures are derived from those. The two conservation laws this makes
        checkable are that the lines' discounts add up to the order's discount
        and their effective totals add up to the order's total — the identity
        that fails the moment an order-level number stops reaching the lines.
        """
        # 1. The manual discount, weighted by what each line costs.
        keys = {line.line_id: f"{index:06d}" for index, line in enumerate(rec.lines)}
        extra_shares = allocate_discount_amount(
            rec.extra_discount,
            {keys[line.line_id]: line.line_total for line in rec.lines},
        )
        for line in rec.lines:
            share = extra_shares.get(keys[line.line_id], ZERO)
            line.discount_amount = min(share, line.line_total)
            line.net_line_total = even2(line.line_total - line.discount_amount)
            line.net_unit_cost = up2(line.net_line_total / Decimal(line.quantity))

        # 2. The landed costs, weighted by the method the order was created with
        # — read off the post-discount line values, exactly as recalculate()
        # orders the two steps.
        Method = PurchaseOrder.LandedCostAllocationMethod
        if allocation_method == Method.QUANTITY:
            weights = {ln.line_id: Decimal(ln.quantity) for ln in rec.lines}
        elif allocation_method == Method.RETAIL_VALUE:
            weights = {
                ln.line_id: even2(retail_prices[ln.line_id] * Decimal(ln.quantity))
                for ln in rec.lines
            }
        elif allocation_method == Method.EQUAL:
            weights = {ln.line_id: Decimal("1.00") for ln in rec.lines}
        else:
            weights = {ln.line_id: ln.net_line_total for ln in rec.lines}
            if sum(weights.values(), ZERO) == ZERO:
                weights = {ln.line_id: Decimal(ln.quantity) for ln in rec.lines}
        allocations = allocate_landed_cost(rec.landed_cost_total, weights)
        for line in rec.lines:
            line.allocated_landed_cost = allocations.get(line.line_id, ZERO)
            line.landed_unit_cost = even2(
                line.allocated_landed_cost / Decimal(line.quantity)
            )
            line.effective_unit_cost = even2(
                line.net_unit_cost + line.landed_unit_cost
            )

    def op_purchase_receive(self) -> bool:
        candidates = [
            rec
            for rec in self.oracle.pos.values()
            if any(line.outstanding > 0 for line in rec.lines)
        ]
        if not candidates:
            return False
        rec = self.rng.choice(candidates)
        po = PurchaseOrder.objects.get(pk=rec.po_id)
        lines_data = []
        plan = []
        for line in rec.lines:
            outstanding = line.outstanding
            if outstanding <= 0:
                continue
            mode = self.rng.random()
            if mode < 0.6:
                accepted, damaged, cancelled = outstanding, 0, 0
            elif mode < 0.8:
                accepted = self.rng.randint(1, outstanding)
                damaged = cancelled = 0
            else:
                accepted = self.rng.randint(0, outstanding)
                rest = outstanding - accepted
                damaged = self.rng.randint(0, rest)
                cancelled = rest - damaged
            if accepted + damaged + cancelled <= 0:
                continue
            lines_data.append(
                {
                    "line": next(
                        pl for pl in po.lines.all() if pl.pk == line.line_id
                    ),
                    "accepted_quantity": accepted,
                    "damaged_quantity": damaged,
                    "cancelled_quantity": cancelled,
                }
            )
            plan.append((line, accepted, damaged, cancelled))
        if not lines_data:
            return False
        receive_purchase_order(po, lines_data=lines_data, request=None)
        for line, accepted, damaged, cancelled in plan:
            self._apply_receipt(line, accepted, damaged, cancelled)
        # status
        expected_status = (
            PurchaseOrder.Status.RECEIVED
            if all(line.outstanding == 0 for line in rec.lines)
            else PurchaseOrder.Status.PARTIALLY_RECEIVED
        )
        self._assert_po(rec.po_id, expected_status=expected_status)
        for line, *_ in plan:
            self._assert_variant(line.variant_id)
        return True

    def _apply_receipt(self, line: PoLineRec, accepted, damaged, cancelled):
        outstanding_before = line.outstanding
        accepted_expected = min(accepted, outstanding_before)
        remaining = max(outstanding_before - accepted_expected, 0)
        damaged_expected = min(damaged, remaining)
        remaining = max(remaining - damaged_expected, 0)
        cancelled_expected = min(cancelled, remaining)
        accepted_overage = accepted - accepted_expected
        vid = line.variant_id

        accepted_expected_base = q3(Decimal(accepted_expected) * line.unit_factor)
        accepted_overage_base = q3(Decimal(accepted_overage) * line.unit_factor)
        self.oracle.on_hand[vid] = q3(
            self.oracle.on_hand[vid] + accepted_expected_base + accepted_overage_base
        )
        # expected decremented (clamped at 0) for accepted_expected, damaged, cancelled
        for packs in (accepted_expected, damaged_expected, cancelled_expected):
            base = q3(Decimal(packs) * line.unit_factor)
            self.oracle.expected[vid] = q3(max(self.oracle.expected[vid] - base, ZERO))
        line.recv_accepted += accepted
        line.recv_damaged += damaged
        line.recv_cancelled += cancelled

    def op_supplier_payment(self) -> bool:
        candidates = [
            rec
            for rec in self.oracle.pos.values()
            if even2(rec.total - rec.paid) > ZERO
        ]
        if not candidates:
            return False
        rec = self.rng.choice(candidates)
        balance = even2(rec.total - rec.paid)
        amount = (Decimal(self.rng.randint(1, int(balance / CENT))) * CENT).quantize(CENT)
        method = self.rng.choice(self.SUPPLIER_METHODS)
        create_supplier_payment(
            created_by=self.user,
            supplier=Supplier.objects.get(pk=rec.supplier_id),
            amount=amount,
            method=method,
            purchase_order=PurchaseOrder.objects.get(pk=rec.po_id),
        )
        rec.paid = even2(rec.paid + amount)
        self._assert_po(rec.po_id)
        return True

    def op_expense_payout(self) -> bool:
        amount = (Decimal(self.rng.randint(100, 5000)) * CENT).quantize(CENT)
        create_expense(
            user=self.user,
            category=self.expense_category,
            amount=amount,
            description="sim expense",
            payment_method=Expense.PaymentMethod.CASH,
            pay_from_register=True,
        )
        self.oracle.cash_moves_log.append((self.current_session_id, "pay_out", even2(amount)))
        self._assert_session(self.current_session_id)
        return True

    def op_cash_movement(self) -> bool:
        movement = self.rng.choice(["pay-in", "pay-out"])
        amount = (Decimal(self.rng.randint(100, 5000)) * CENT).quantize(CENT)
        response = self.client.post(
            f"/api/register-sessions/{self.current_session_id}/{movement}/",
            {"amount": str(amount), "reason": "sim cash movement"},
            format="json",
        )
        if response.status_code != 201:
            self.fail(f"{movement} failed: {response.status_code} {response.data}")
        self.oracle.cash_moves_log.append(
            (self.current_session_id, movement.replace("-", "_"), even2(amount))
        )
        self._assert_session(self.current_session_id)
        return True

    def op_stock_count(self) -> bool:
        response = self.client.post(
            "/api/stock-counts/start/", {"scope": "full"}, format="json"
        )
        if response.status_code not in (200, 201):
            self.fail(f"stock-count start failed: {response.status_code} {response.data}")
        count_id = response.data["id"]
        pool = list(self.stock_items)
        self.rng.shuffle(pool)
        chosen = pool[: self.rng.randint(2, 4)]
        planned = []
        for item in chosen:
            on_hand = self.oracle.on_hand[item.variant_id]
            base_unit = item.variant.product.unit
            if base_unit == "kg":
                delta = Decimal(self.rng.randint(-8, 8)) * Decimal("0.25")
            else:
                delta = Decimal(self.rng.randint(-5, 5))
            counted = on_hand + delta
            # Never count below what is reserved: a stock count that drops
            # on-hand under quantity_committed would leave a quotation's
            # reservation un-honorable (a legitimate but separately-tested edge),
            # which we keep out of this invariant-focused run.
            floor = self.oracle.committed[item.variant_id]
            if counted < floor:
                counted = floor
            resp = self.client.post(
                f"/api/stock-counts/{count_id}/count/",
                {"variant": item.variant_id, "counted_quantity": str(counted), "mode": "replace"},
                format="json",
            )
            if resp.status_code not in (200, 201):
                self.fail(f"stock-count count failed: {resp.status_code} {resp.data}")
            planned.append((item.variant_id, q3(counted)))
        resp = self.client.post(
            f"/api/stock-counts/{count_id}/apply/", {}, format="json"
        )
        if resp.status_code not in (200, 201):
            self.fail(f"stock-count apply failed: {resp.status_code} {resp.data}")
        for vid, counted in planned:
            self.oracle.on_hand[vid] = counted
            self._assert_variant(vid)
        return True

    def op_cycle_register(self) -> bool:
        session_id = self.current_session_id
        rec = self.oracle.sessions[session_id]
        expected_cash = self.oracle.session_expected_cash(session_id)
        counts = {
            "count_025": self.rng.randint(0, 4),
            "count_050": self.rng.randint(0, 4),
            "count_075": self.rng.randint(0, 2),
            "count_100": self.rng.randint(0, 6),
        }
        denom_total = even2(
            Decimal("0.25") * counts["count_025"]
            + Decimal("0.50") * counts["count_050"]
            + Decimal("0.75") * counts["count_075"]
            + Decimal("1.00") * counts["count_100"]
        )
        # sometimes aim for zero variance, sometimes introduce one
        if self.rng.random() < 0.5:
            entered = max(even2(expected_cash - denom_total), ZERO)
        else:
            entered = max(
                even2(expected_cash - denom_total)
                + Decimal(self.rng.randint(-300, 300)) * CENT,
                ZERO,
            )
        payload = {"closing_cash": str(entered), **counts}
        response = self.client.post(
            f"/api/register-sessions/{session_id}/close/", payload, format="json"
        )
        if response.status_code != 200:
            self.fail(f"register close failed: {response.status_code} {response.data}")
        rec.closed = True
        rec.closing_cash = even2(entered + denom_total)
        # verify close reconciliation immediately
        session = RegisterSession.objects.get(pk=session_id)
        self.assert_money(session.closing_cash, rec.closing_cash, f"session#{session_id} closing_cash")
        self.assert_money(
            session.cash_variance,
            even2(rec.closing_cash - expected_cash),
            f"session#{session_id} cash_variance",
        )
        self._open_register()
        return True

    def op_attempt_oversell(self) -> bool:
        items = [i for i in self.stock_items if self.oracle.available(i.variant_id) >= ZERO]
        if not items:
            return False
        item = self.rng.choice(items)
        available = self.oracle.available(item.variant_id)
        base_unit = item.variant.product.unit
        # Request strictly more than is available so the guard must reject it.
        quantity = available + (Decimal("1") if base_unit == "kg" else Decimal("1"))
        on_hand_before = self.oracle.on_hand[item.variant_id]
        order_count_before = Order.objects.count()
        eff_price = item.effective_unit_price(item.units[0], [])
        raised = False
        try:
            checkout_order(
                register_session=self._register_session_obj(),
                lines_data=[
                    {
                        "variant": item.variant,
                        "quantity": quantity,
                        "unit": "",
                        "unit_factor": Decimal("1"),
                        "effective_unit_price": eff_price,
                    }
                ],
                payments_data=[{"method": "cash", "amount": even2(eff_price * quantity)}],
                sale_type=Order.SaleType.STANDARD,
                request=None,
            )
        except (DRFValidationError, DjangoValidationError):
            raised = True
        if not raised:
            self.fail(
                f"oversell of variant {item.variant_id} (req {quantity} > avail "
                f"{available}) was NOT rejected"
            )
        # nothing must have changed
        stock_item = StockItem.objects.get(variant_id=item.variant_id)
        self.assert_qty(
            stock_item.quantity_on_hand, on_hand_before, "oversell left stock unchanged"
        )
        if Order.objects.count() != order_count_before:
            self.fail("oversell created an order despite the shortage")
        return True

    def _random_coupons(self):
        choice = self.rng.random()
        if choice < 0.55:
            return ()
        if choice < 0.75:
            return ("SAVE3",)
        if choice < 0.9:
            return ("HALF",)
        return ("SAVE3", "HALF")

    # -- run loop ---------------------------------------------------------

    def operations(self):
        return [
            (self.op_standard_sale, 28),
            (self.op_credit_sale, 10),
            (self.op_customer_payment, 8),
            (self.op_customer_account_payment, 4),
            (self.op_quotation, 6),
            (self.op_convert_quotation, 4),
            (self.op_release_quotation, 2),
            (self.op_return_items, 7),
            (self.op_exchange, 4),
            (self.op_void_order, 3),
            (self.op_purchase_submit, 7),
            (self.op_purchase_receive, 7),
            (self.op_supplier_payment, 5),
            (self.op_expense_payout, 3),
            (self.op_cash_movement, 4),
            (self.op_stock_count, 3),
            (self.op_cycle_register, 2),
            (self.op_attempt_oversell, 2),
        ]

    def run(self, operations_target: int):
        ops = self.operations()
        choices = [op for op, _ in ops]
        weights = [w for _, w in ops]
        executed = 0
        attempts = 0
        max_attempts = operations_target * 20 + 200
        while executed < operations_target and attempts < max_attempts:
            attempts += 1
            op = self.rng.choices(choices, weights=weights, k=1)[0]
            if op():
                executed += 1
                self.op_index += 1
                self.op_counts[op.__name__] += 1
                if self.op_index % self.checkpoint_every == 0:
                    self.full_reconcile()
        if executed < operations_target:
            self.fail(
                f"only executed {executed}/{operations_target} ops in {attempts} attempts"
            )
        self.full_reconcile()
        # The movement-ledger reconciliation (seed + signed movements == snapshot)
        # is a global consistency check, run once at the end over every variant.
        for item in self.stock_items:
            self._assert_ledger(item.variant_id)
        self.reconcile_summaries()
        self.reconcile_identities()
        return executed

    # -- assertions / reconciliation -------------------------------------

    def _assert_touched(self, specs):
        for spec in specs:
            if spec["item"].tracks_stock:
                self._assert_variant(spec["item"].variant_id)

    def _assert_variant(self, variant_id: int):
        stock = StockItem.objects.get(variant_id=variant_id)
        self.assert_qty(
            stock.quantity_on_hand, self.oracle.on_hand[variant_id],
            f"variant {variant_id} on_hand",
        )
        self.assert_qty(
            stock.quantity_committed, self.oracle.committed[variant_id],
            f"variant {variant_id} committed",
        )
        self.assert_qty(
            stock.quantity_expected, self.oracle.expected[variant_id],
            f"variant {variant_id} expected",
        )

    def _assert_order(self, rec: OrderRec):
        # Prefetch the lines: the line assertions and the total_cost/total_profit
        # properties all walk them, and without this each walk is its own query
        # against every order the run has ever created, at every checkpoint.
        order = Order.objects.prefetch_related("lines").get(pk=rec.order_id)
        self.assert_money(order.subtotal, rec.subtotal, f"order#{rec.order_id} subtotal")
        self.assert_money(
            order.discount_total, rec.discount_total, f"order#{rec.order_id} discount_total"
        )
        self.assert_money(order.total, rec.total, f"order#{rec.order_id} total")
        self.assert_money(
            order.amount_paid, rec.amount_paid, f"order#{rec.order_id} amount_paid"
        )
        self.assert_money(
            order.balance_due, rec.balance_due, f"order#{rec.order_id} balance_due"
        )
        self.assert_equal(order.status, rec.status, f"order#{rec.order_id} status")
        self._assert_order_lines(order, rec)

    def _assert_order_lines(self, order, rec: OrderRec):
        """Every line's price, discount and COST basis, plus the identities that
        tie the lines back to the order they belong to.

        The cost basis is what makes this more than a restatement of the totals:
        an order's money can be entirely right while ``unit_cost`` is wrong, and
        nothing about revenue would notice — but every margin, every profit
        report and the credit a return gives back for restocked goods are all
        computed from this one snapshot.
        """
        lines = {line.pk: line for line in order.lines.all()}
        for expected in rec.lines:
            line = lines[expected.order_line_id]
            tag = f"order#{order.pk} line#{line.pk}"
            self.assert_money(line.unit_price, expected.unit_price, f"{tag} unit_price")
            self.assert_money(
                line.discount_total, expected.discount_total, f"{tag} discount_total"
            )
            self.assert_money(line.unit_cost, expected.unit_cost, f"{tag} unit_cost")
            self.assert_money(line.line_total, expected.line_total, f"{tag} line_total")
            self.assert_money(line.line_cost, expected.line_cost, f"{tag} line_cost")
            self.assert_money(
                line.line_profit, expected.line_profit, f"{tag} line_profit"
            )
            if expected.unit_cost > ZERO:
                self.costed_line_assertions += 1
                if expected.unit_factor != Decimal("1"):
                    # A box costs twelve pieces: the scaling from the purchase's
                    # base unit into the sale's transacted unit is exactly the
                    # step the phantom-loss bug class lives in.
                    self.multi_unit_costed_line_assertions += 1
        # Identity 1: the lines' revenue is the order's revenue.
        self.assert_money(
            even2(sum((line.line_subtotal for line in lines.values()), ZERO)),
            order.subtotal,
            f"identity: order#{order.pk} line subtotals sum to subtotal",
        )
        # Identity 2: the lines' discounts are the order's discount. This is the
        # one an order-level figure that never reached the lines would fail.
        self.assert_money(
            even2(sum((line.discount_total for line in lines.values()), ZERO)),
            order.discount_total,
            f"identity: order#{order.pk} line discounts sum to discount_total",
        )
        # Identity 3: what the lines are worth is what the order charges.
        self.assert_money(
            even2(sum((line.line_total for line in lines.values()), ZERO)),
            order.total,
            f"identity: order#{order.pk} line totals sum to total",
        )
        # Identity 4: the cost basis the reports read is the lines' own.
        self.assert_money(order.total_cost, rec.total_cost, f"order#{order.pk} total_cost")
        self.assert_money(
            order.total_profit, rec.total_profit, f"order#{order.pk} total_profit"
        )
        self.assert_money(
            even2(order.total - order.total_cost),
            order.total_profit,
            f"identity: order#{order.pk} profit is revenue minus cost",
        )

    def _assert_session(self, session_id: int):
        session = RegisterSession.objects.get(pk=session_id)
        self.assert_money(
            session.cash_sales_total,
            self.oracle.session_cash_sales(session_id),
            f"session#{session_id} cash_sales_total",
        )
        self.assert_money(
            session.pay_in_total,
            self.oracle.session_pay_in(session_id),
            f"session#{session_id} pay_in_total",
        )
        self.assert_money(
            session.pay_out_total,
            self.oracle.session_pay_out(session_id),
            f"session#{session_id} pay_out_total",
        )
        self.assert_money(
            session.cash_refund_total,
            self.oracle.session_cash_refund(session_id),
            f"session#{session_id} cash_refund_total",
        )
        self.assert_money(
            session.expected_cash,
            self.oracle.session_expected_cash(session_id),
            f"session#{session_id} expected_cash",
        )

    def _assert_customer(self, customer_id: int):
        backend = even2(
            sum(
                (
                    o.balance_due
                    for o in Order.objects.filter(
                        customer_id=customer_id,
                        sale_type=Order.SaleType.CREDIT,
                        status=Order.Status.OPEN,
                    )
                ),
                ZERO,
            )
        )
        self.assert_money(
            backend, self.oracle.customer_ar(customer_id), f"customer#{customer_id} AR"
        )

    def _assert_po(self, po_id: int, expected_status=None):
        rec = self.oracle.pos[po_id]
        po = PurchaseOrder.objects.get(pk=po_id)
        self.assert_money(po.total, rec.total, f"po#{po_id} total")
        self.assert_money(po.paid_total, rec.paid, f"po#{po_id} paid_total")
        self.assert_money(
            po.balance_due, max(even2(rec.total - rec.paid), ZERO), f"po#{po_id} balance_due"
        )
        if expected_status is not None:
            self.assert_equal(po.status, expected_status, f"po#{po_id} status")
        self._assert_po_line_costs(po, rec)

    def _assert_po_line_costs(self, po, rec: PoRec):
        """The cost basis every line carries, plus the two identities that tie
        the lines back to the order they belong to."""
        self.assert_money(po.subtotal, rec.subtotal, f"po#{po.pk} subtotal")
        self.assert_money(
            po.discount_total, rec.extra_discount, f"po#{po.pk} discount_total"
        )
        self.assert_money(
            po.landed_cost_total, rec.landed_cost_total, f"po#{po.pk} landed_cost_total"
        )
        lines = {line.pk: line for line in po.lines.all()}
        for expected in rec.lines:
            line = lines[expected.line_id]
            tag = f"po#{po.pk} line#{line.pk}"
            for name in (
                "discount_amount",
                "net_line_total",
                "net_unit_cost",
                "allocated_landed_cost",
                "landed_unit_cost",
                "effective_unit_cost",
            ):
                self.assert_money(
                    getattr(line, name), getattr(expected, name), f"{tag} {name}"
                )
            self.assert_money(
                line.effective_line_total,
                expected.effective_line_total,
                f"{tag} effective_line_total",
            )
        # Identity 1: the lines' discounts are the order's discount.
        self.assert_money(
            even2(sum((line.discount_amount for line in lines.values()), ZERO)),
            po.discount_total,
            f"identity: po#{po.pk} line discounts sum to discount_total",
        )
        # Identity 2: the lines' cost bases are the order's total. This is the
        # one that catches an order-level figure that never reached the lines.
        self.assert_money(
            even2(sum((line.effective_line_total for line in lines.values()), ZERO)),
            po.total,
            f"identity: po#{po.pk} line costs sum to total",
        )

    def full_reconcile(self):
        for item in self.stock_items:
            self._assert_variant(item.variant_id)
        for rec in self.oracle.orders.values():
            self._assert_order(rec)
        for session_id in self.oracle.sessions:
            self._assert_session(session_id)
        for customer in self.customers:
            self._assert_customer(customer.id)
        for po_id in self.oracle.pos:
            self._assert_po(po_id)

    def _assert_ledger(self, variant_id: int):
        """Independent second check: the backend's own movement ledger must
        explain its on-hand snapshot from the seeded baseline."""
        positive = (
            StockMovement.Type.INCREASE,
            StockMovement.Type.RECEIVE_EXPECTED,
        )
        negative = (
            StockMovement.Type.DECREASE,
            StockMovement.Type.DAMAGED,
        )
        delta = ZERO
        for movement in StockMovement.objects.filter(variant_id=variant_id):
            if movement.movement_type in positive:
                delta += movement.quantity
            elif movement.movement_type in negative:
                delta -= movement.quantity
        expected = q3(self.oracle.seed_on_hand[variant_id] + delta)
        stock = StockItem.objects.get(variant_id=variant_id)
        self.assert_qty(
            stock.quantity_on_hand, expected, f"variant {variant_id} ledger-vs-snapshot"
        )

    def reconcile_summaries(self):
        """Cross-check the production Z-Report aggregation (the summary endpoint)
        against the oracle for every session, per payment method."""
        for session_id in self.oracle.sessions:
            response = self.client.get(
                f"/api/register-sessions/{session_id}/summary/"
            )
            if response.status_code != 200:
                self.fail(
                    f"summary#{session_id} failed: {response.status_code} {response.data}"
                )
            payload = response.data
            expected = self.oracle.session_method_summary(session_id)
            rows = {row["method"]: row for row in payload["payment_methods"]}
            for method, exp in expected.items():
                row = rows[method]
                self.assert_money(
                    row["gross"], exp["gross"], f"summary#{session_id} {method} gross"
                )
                self.assert_money(
                    row["refund"], exp["refund"], f"summary#{session_id} {method} refund"
                )
                self.assert_money(
                    row["net"], exp["net"], f"summary#{session_id} {method} net"
                )
                self.assert_money(
                    row["commission"],
                    exp["commission"],
                    f"summary#{session_id} {method} commission",
                )
            cash = payload["cash"]
            self.assert_money(
                cash["expected_cash"],
                self.oracle.session_expected_cash(session_id),
                f"summary#{session_id} cash.expected_cash",
            )

    def reconcile_identities(self):
        """Global conservation identities that must hold across the whole run."""
        # 1. Every session's drawer change is fully explained by its cash flows.
        for session_id, rec in self.oracle.sessions.items():
            session = RegisterSession.objects.get(pk=session_id)
            explained = even2(
                rec.opening_cash
                + self.oracle.session_cash_sales(session_id)
                + self.oracle.session_pay_in(session_id)
                - self.oracle.session_pay_out(session_id)
                - self.oracle.session_cash_refund(session_id)
            )
            self.assert_money(
                session.expected_cash, explained, f"identity: session#{session_id} drawer"
            )
        # 2. Per method across every order this run created, backend net
        # payments == oracle net. Scoped to the run's own orders on purpose:
        # unscoped, the sum also picks up whatever payments the database already
        # held, so a run against a non-empty database (a dev Postgres, say)
        # reports an oracle mismatch that is really pre-existing data.
        from apps.payments.models import Payment

        for method in self.PAYMENT_METHODS:
            backend_net = even2(
                sum(
                    (
                        p.amount
                        for p in Payment.objects.filter(
                            method=method, order_id__in=list(self.oracle.orders)
                        )
                    ),
                    ZERO,
                )
            )
            oracle_net = ZERO
            for rec in self.oracle.orders.values():
                oracle_net = even2(oracle_net + rec.paid_by_method.get(method, ZERO))
            self.assert_money(backend_net, oracle_net, f"identity: net {method} payments")


# ---------------------------------------------------------------------------
# Arithmetic self-test — reproduces documented worked examples so a port bug in
# the oracle fails HERE (clearly a test bug) rather than masquerading as a
# backend bug deep in a simulation run.
# ---------------------------------------------------------------------------


def _line(key, product_id, quantity, unit_amount, variant_id=None):
    return DiscountLine(
        key=str(key),
        product_id=product_id,
        variant_id=variant_id if variant_id is not None else product_id,
        quantity=Decimal(quantity),
        unit_amount=Decimal(unit_amount),
    )


def _doc_rule(rule_id, value_type, value, **kw):
    return OracleRule(
        rule_id=rule_id,
        application_type=kw.pop("application_type", DiscountRule.ApplicationType.AUTOMATIC),
        coupon_code=kw.pop("coupon_code", ""),
        scope=kw.pop("scope", DiscountRule.Scope.DOCUMENT),
        value_type=value_type,
        value=Decimal(value),
        priority=kw.pop("priority", 100),
        exclusive=kw.pop("exclusive", False),
        **kw,
    )


def self_test_arithmetic():
    """Raises AssertionError if any oracle arithmetic diverges from the
    documented backend behavior."""

    def check(label, actual, expected):
        if actual != expected:
            raise AssertionError(
                f"oracle self-test '{label}': got {actual!r}, expected {expected!r}"
            )

    VT = DiscountRule.ValueType
    SC = DiscountRule.Scope
    AT = DiscountRule.ApplicationType

    # (A) document percentage 10 over two lines.
    engine = OracleDiscountEngine([_doc_rule(1, VT.PERCENTAGE, "10")])
    per_line, total = engine.calculate([_line(0, 1, 2, "10.00"), _line(1, 2, 1, "20.00")])
    check("A.total", total, Decimal("4.00"))
    check("A.lines", per_line, {"0": Decimal("2.00"), "1": Decimal("2.00")})

    # (C) document percentage 10, three lines, indivisible cent -> largest key.
    engine = OracleDiscountEngine([_doc_rule(1, VT.PERCENTAGE, "10")])
    per_line, total = engine.calculate(
        [_line(0, 1, 1, "3.34"), _line(1, 2, 1, "3.34"), _line(2, 3, 1, "3.34")]
    )
    check("C.total", total, Decimal("1.00"))
    check("C.lines", per_line, {"0": Decimal("0.34"), "1": Decimal("0.33"), "2": Decimal("0.33")})

    # (D) line fixed_unit_amount 1.50, min_line_quantity 2, product-targeted.
    engine = OracleDiscountEngine(
        [_doc_rule(1, VT.FIXED_UNIT_AMOUNT, "1.50", scope=SC.LINE,
                   min_line_quantity=2, product_ids=frozenset({1}))]
    )
    per_line, total = engine.calculate([_line(0, 1, 2, "10.00"), _line(1, 2, 1, "10.00")])
    check("D.total", total, Decimal("3.00"))
    check("D.lines", per_line, {"0": Decimal("3.00")})

    # (E) line fixed_price 7.50, product-targeted.
    engine = OracleDiscountEngine(
        [_doc_rule(1, VT.FIXED_PRICE, "7.50", scope=SC.LINE, product_ids=frozenset({1}))]
    )
    per_line, total = engine.calculate([_line(0, 1, 2, "10.00")])
    check("E.total", total, Decimal("5.00"))

    # (G) coupon fixed_amount only applies with the code.
    engine = OracleDiscountEngine(
        [_doc_rule(1, VT.FIXED_AMOUNT, "5", application_type=AT.COUPON_CODE, coupon_code="SAVE5")]
    )
    _, total_without = engine.calculate([_line(0, 1, 4, "10.00")])
    check("G.without", total_without, Decimal("0.00"))
    _, total_with = engine.calculate([_line(0, 1, 4, "10.00")], coupon_codes=("save5",))
    check("G.with", total_with, Decimal("5.00"))

    # (H) two non-exclusive line fixed_amount rules stack down to the line floor.
    engine = OracleDiscountEngine(
        [
            _doc_rule(1, VT.FIXED_AMOUNT, "15", scope=SC.LINE, priority=1,
                      product_ids=frozenset({1})),
            _doc_rule(2, VT.FIXED_AMOUNT, "15", scope=SC.LINE, priority=2,
                      product_ids=frozenset({1})),
        ]
    )
    per_line, total = engine.calculate([_line(0, 1, 2, "10.00")])
    check("H.total", total, Decimal("20.00"))
    check("H.lines", per_line, {"0": Decimal("20.00")})

    # (B) document percentage 50 with min subtotal + max cap, indivisible cent.
    engine = OracleDiscountEngine(
        [_doc_rule(1, VT.PERCENTAGE, "50", min_order_subtotal=Decimal("40.00"),
                   max_discount_amount=Decimal("3.33"))]
    )
    per_line, total = engine.calculate([_line(0, 1, 1, "20.00"), _line(1, 2, 1, "20.00")])
    check("B.total", total, Decimal("3.33"))
    check("B.lines", per_line, {"0": Decimal("1.67"), "1": Decimal("1.66")})
    # below threshold -> nothing
    _, total_low = engine.calculate([_line(0, 1, 1, "19.99"), _line(1, 2, 1, "19.99")])
    check("B.below", total_low, Decimal("0.00"))

    # (J) automatic percentage then non-exclusive coupon, stacked on remaining.
    engine = OracleDiscountEngine(
        [
            _doc_rule(1, VT.PERCENTAGE, "10", priority=1),
            _doc_rule(2, VT.FIXED_AMOUNT, "2", application_type=AT.COUPON_CODE,
                      coupon_code="SAVE2", priority=2),
        ]
    )
    _, total = engine.calculate([_line(0, 1, 2, "12.00")], coupon_codes=("SAVE2",))
    check("J.total", total, Decimal("4.40"))

    # exclusivity short-circuits a lower-priority rule.
    engine = OracleDiscountEngine(
        [
            _doc_rule(1, VT.PERCENTAGE, "50", priority=1, exclusive=True),
            _doc_rule(2, VT.PERCENTAGE, "10", priority=2, exclusive=False),
        ]
    )
    _, total = engine.calculate([_line(0, 1, 1, "20.00")])
    check("excl.total", total, Decimal("10.00"))  # only the 50% rule, not 50%+10%

    # allocate_discount_amount tie-break (ascending string key).
    check(
        "allocate.tie",
        allocate_discount_amount(Decimal("0.01"), {"z": Decimal("5"), "a": Decimal("5")}),
        {"a": Decimal("0.01")},
    )

    # refund tender split: 4 cash + 3 card, full refund of 7.
    check(
        "refund.split",
        refund_tender_allocations({"cash": Decimal("4"), "card": Decimal("3")}, Decimal("7")),
        [("card", Decimal("3.00")), ("cash", Decimal("4.00"))],
    )
    # refund single indivisible cent across equal tenders -> deterministic.
    check(
        "refund.cent",
        refund_tender_allocations({"cash": Decimal("1"), "card": Decimal("1")}, Decimal("0.01")),
        [("cash", Decimal("0.01"))],
    )

    # commission (HALF_EVEN).
    check("commission.card", commission_amount(Decimal("1.5"), Decimal("100")), Decimal("1.50"))
    check("commission.cash", commission_amount(Decimal("0"), Decimal("50")), Decimal("0.00"))


# ---------------------------------------------------------------------------
# Module entry point
# ---------------------------------------------------------------------------


def run_simulation(*, seed, operations, checkpoint_every=25, verbose=False) -> Simulation:
    """Build the world and run ``operations`` randomized operations, asserting the
    oracle continuously. Returns the finished :class:`Simulation` (for its
    ``op_counts`` report). Raises :class:`SimulationError` on any divergence."""
    self_test_arithmetic()
    sim = Simulation(seed=seed, checkpoint_every=checkpoint_every, verbose=verbose)
    sim.build_world()
    sim.run(operations)
    return sim


