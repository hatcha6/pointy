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

import os
from types import SimpleNamespace

from django.contrib.auth import get_user_model
from django.core.exceptions import ValidationError as DjangoValidationError
from django.urls import reverse
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
from apps.customers.models import Asset, Customer
from apps.operations.models import Job, WorkflowTemplate
from apps.operations.services import (
    _labor_variant,
    add_job_material,
    add_job_service,
    cancel_job,
    create_job,
    hold_job,
    invoice_job,
    resume_job,
    reverse_job_material,
    transition_job,
)
from apps.discounts.models import DiscountRule
from apps.expenses.models import Expense, ExpenseCategory
from apps.expenses.services import create_expense
from apps.inventory.models import StockItem, StockValuationBin, Warehouse, StockMovement
from apps.inventory.valuation import (
    ValuationMethod,
    consumed_unit_cost,
    valuation_engine,
)
from apps.purchasing.models import (
    PurchaseLine,
    PurchaseOrder,
    PurchaseOrderAdjustment,
    PurchaseOrderAdjustmentLine,
    Supplier,
    SupplierPayment,
    prime_supplier_balances,
)
from apps.purchasing.services import (
    create_supplier_payment,
    receive_purchase_order,
    save_purchase_order_with_lines,
    submit_purchase_order,
)
from apps.sales.models import (
    Order,
    OrderAdjustmentLine,
    OrderLine,
    RegisterSession,
    returned_cost_total,
)
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


def allocate_landed_cost(
    amount: Decimal,
    weights_by_line_id: dict,
    fallback_weights_by_line_id: dict | None = None,
) -> dict:
    """Independent port of ``PurchaseOrder._landed_cost_allocations``.

    Deliberately NOT a call into :func:`allocate_discount_amount`: the purchasing
    model runs its own allocator, and the two differ in two ways this port has to
    reproduce — zero-weight lines stay in the divisor set here, and ties on the
    fractional remainder are broken by ascending integer line id rather than by
    string key. Returns ``{line_id: amount}`` for every line.

    The model's zero-weight fallback belongs here too, and it is easy to put in
    the wrong place: when the chosen method weighs the whole order at zero the
    model re-weights by quantity rather than dropping the landed cost, and it
    does so for *every* allocation method, not only the cost one.
    """
    if amount == ZERO:
        return {line_id: ZERO for line_id in weights_by_line_id}

    weights = dict(weights_by_line_id)
    total_weight = sum(weights.values(), ZERO)
    if total_weight == ZERO:
        weights = dict(fallback_weights_by_line_id or {})
        total_weight = sum(weights.values(), ZERO)
    if total_weight == ZERO:
        return {line_id: ZERO for line_id in weights_by_line_id}

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
        """Return ``(per_line_discount, discount_total, applied_coupon_codes)``.

        ``per_line_discount`` is keyed by the line key (``str(index)``); the sum
        equals ``discount_total``. ``applied_coupon_codes`` names the coupons
        that actually produced an application — a coupon can be eligible and
        still contribute nothing (its rule caps out, or an exclusive rule ahead
        of it takes the whole cart), and the checkout API refuses a sale whose
        coupon changed nothing rather than silently pocketing it.
        """
        remaining = {line.key: line.subtotal for line in lines}
        per_line = defaultdict(lambda: ZERO)
        total = ZERO
        applications = 0
        applied_codes = set()
        for rule in self._eligible(lines, customer_id, coupon_codes):
            if rule.exclusive and applications:
                continue
            result = self._calc_rule(rule, lines, remaining)
            if result is None:
                continue
            amount, allocations = result
            applications += 1
            if rule.application_type == "coupon_code":
                applied_codes.update(_normalize_codes([rule.coupon_code]))
            total = up2(total + amount)
            for key, alloc in allocations.items():
                per_line[key] = up2(per_line[key] + alloc)
                remaining[key] = up2(remaining[key] - alloc)
            if rule.exclusive:
                break
        return dict(per_line), total, applied_codes


# ---------------------------------------------------------------------------
# Oracle state records
# ---------------------------------------------------------------------------


@dataclass
class RefundRec:
    """Everything the oracle predicts about one refund document, computed from
    the operation's own inputs before the backend is asked anything.

    ``lines`` is ``[(LineRec, quantity, refund_discount)]`` — one entry per
    sale line this refund takes back, so the document *and* each of its lines
    can be checked against a figure derived here rather than against each other.
    """

    total: Decimal
    cash_amount: Decimal
    primary_method: str
    lines: list
    order_id: int = 0

    @property
    def cost_total(self) -> Decimal:
        """Cost of the goods this refund puts back on the shelf.

        The backend answers this with a database-side
        ``Sum(quantity * order_line__unit_cost)`` (``sales.models``); the oracle
        answers it from the cost *it* predicted for each sale line when the sale
        was rung up, times the quantity *it* asked to send back. Rounded once at
        the end, like the backend's single trailing ``quantize``, not per line.
        """
        return even2(
            sum((line.unit_cost * Decimal(qty) for line, qty, _ in self.lines), ZERO)
        )


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
    # The method of the order's FIRST payment, mirroring production's
    # ``refund_method_for_order`` (``order.payments.order_by("created_at").first()``,
    # cash when the order was never paid). A refund whose tenders have all been
    # drained to zero by earlier refunds falls back to this one.
    first_payment_method: str | None = None
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
class JobMaterialRec:
    """A part on a job. Quantities are base units — job materials have no pack."""

    material_id: int
    variant_id: int
    quantity: Decimal
    unit_price: Decimal
    unit_cost: Decimal
    consumed: bool = False
    reversed: bool = False

    @property
    def billable(self) -> bool:
        return self.consumed and not self.reversed


@dataclass
class JobServiceRec:
    """Priced work on a job: no stock, no cost, billed at its snapshot price."""

    service_id: int
    variant_id: int
    quantity: Decimal
    unit_price: Decimal


@dataclass
class JobRec:
    job_id: int
    customer_id: int | None
    stage_index: int
    materials: list = field(default_factory=list)
    services: list = field(default_factory=list)
    order_id: int | None = None
    labor_total: Decimal = ZERO
    approved_price: Decimal | None = None
    handed_over: bool = False
    on_hold: bool = False
    cancelled: bool = False
    completed: bool = False

    @property
    def open(self) -> bool:
        return not self.cancelled and not self.completed

    @property
    def billable_materials(self) -> list:
        return [m for m in self.materials if m.billable]

    @property
    def materials_total(self) -> Decimal:
        return even2(
            sum((even2(m.unit_price * m.quantity) for m in self.billable_materials), ZERO)
        )

    @property
    def services_total(self) -> Decimal:
        return even2(
            sum((even2(s.unit_price * s.quantity) for s in self.services), ZERO)
        )

    @property
    def invoice_total(self) -> Decimal:
        return even2(self.materials_total + self.services_total + self.labor_total)

    @property
    def has_anything_to_bill(self) -> bool:
        """Mirrors ``apps.operations.services.job_has_anything_to_bill``."""
        if self.billable_materials:
            return True
        if self.services:
            return True
        return self.approved_price is not None and self.approved_price > ZERO


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
    unit_cost: Decimal  # per PACK (the cost of one carton, not one piece)
    unit_code: str = ""
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
    # What supplier returns have already taken off this line: packs sent back,
    # and the money credited for them. Both are the oracle's own running totals,
    # accumulated from the quantities it asked for and the amounts it computed.
    adjusted_packs: int = 0
    adjusted_value: Decimal = ZERO

    @property
    def line_total(self) -> Decimal:
        return up2(self.unit_cost * Decimal(self.quantity))

    @property
    def effective_line_total(self) -> Decimal:
        return even2(self.net_line_total + self.allocated_landed_cost)

    @property
    def base_quantity(self) -> Decimal:
        """The line in the only unit stock is ever counted in."""
        return q3(Decimal(self.quantity) * self.unit_factor)

    @property
    def base_unit_cost(self) -> Decimal:
        """What one BASE unit cost — the figure a sale's COGS snapshot and
        the sell-at-a-loss guard read. A per-pack cost meeting a per-base
        price without this division is the phantom-loss bug class."""
        return even2(self.unit_cost / self.unit_factor)

    @property
    def effective_base_unit_cost(self) -> Decimal:
        return even2(self.effective_unit_cost / self.unit_factor)

    @property
    def outstanding(self) -> int:
        return max(
            self.quantity - (self.recv_accepted + self.recv_damaged + self.recv_cancelled),
            0,
        )

    @property
    def adjustable(self) -> int:
        """Packs that can still go back to the supplier: what arrived, less
        what has already been returned. Damaged and cancelled units never
        arrived, so they are not in it."""
        return max(self.recv_accepted - self.adjusted_packs, 0)

    @property
    def unit_span(self) -> int:
        """The number of units the returnable value is spread across.

        The ordered count normally, because each ordered unit is worth the same
        share of the line whether it arrived or not — but an over-shipped line
        caps its returnable value at what was billed, so that capped value has
        to be divided by the units that actually arrived instead. Divide by the
        ordered count there and each arrived unit is priced above its share.
        """
        return max(self.quantity, self.recv_accepted)

    @property
    def returnable_value(self) -> Decimal:
        """The most this line can ever credit back, all returns added up: the
        arrived units' share of what the order billed, capped at the whole
        line (the surplus of an over-shipment was never billed for)."""
        if self.quantity <= 0:
            return ZERO
        arrived = min(self.recv_accepted, self.quantity)
        if arrived >= self.quantity:
            return even2(self.net_line_total)
        return even2(self.net_line_total * Decimal(arrived) / Decimal(self.quantity))

    def return_credit(self, packs: int) -> Decimal:
        """What the supplier owes for ``packs`` going back, computed from this
        line's own inputs — never read back from the backend.

        Two branches, mirroring the two questions being asked. The last units
        off the line settle up: they claim whatever of ``returnable_value``
        earlier returns left behind, so repeated partial returns always add to
        exactly that value. Anything earlier takes its proportional share.
        """
        if packs >= self.adjustable:
            return even2(self.returnable_value - self.adjusted_value)
        return even2(self.net_line_total * Decimal(packs) / Decimal(self.unit_span))


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

    @property
    def cancelled_value(self) -> Decimal:
        """The goods value of every unit a receipt closed as cancelled.

        Built from this record's own inputs only — the quantity the line was
        ordered at, the ``net_line_total`` the oracle computed for it, and the
        cancelled counts the simulation itself handed to the receipt. Nothing
        here is read back from the backend, so asserting the backend's
        ``cancelled_total`` against it is a real check rather than a restatement.

        Multiply before dividing so a wholly cancelled line comes out at
        exactly its net value and the order settles at zero.
        """
        exact = ZERO
        for line in self.lines:
            ordered = Decimal(line.quantity)
            if ordered <= 0 or line.recv_cancelled <= 0:
                continue
            cancelled = min(Decimal(line.recv_cancelled), ordered)
            exact += line.net_line_total * cancelled / ordered
        return even2(exact)

    @property
    def billable(self) -> Decimal:
        """What the supplier can still invoice: the ordered total less the
        goods that were cancelled at the door. Landed costs stay in — the
        freight was incurred on the shipment that did arrive."""
        return max(even2(self.total - self.cancelled_value), ZERO)

    @property
    def po_balance_due(self) -> Decimal:
        return max(even2(self.billable - self.paid), ZERO)


class Oracle:
    """The independent shadow model of the entire backend money/quantity state."""

    def __init__(self):
        self.on_hand: dict = defaultdict(lambda: ZERO)
        self.committed: dict = defaultdict(lambda: ZERO)
        self.expected: dict = defaultdict(lambda: ZERO)
        self.seed_on_hand: dict = defaultdict(lambda: ZERO)
        self.orders: dict = {}
        # Repair jobs by id. A job's invoice becomes a normal entry in
        # ``orders``, so job revenue rides every identity the sales side has.
        self.jobs: dict = {}
        self.sessions: dict = {}
        self.pos: dict = {}
        # Cost basis per BASE unit, keyed by variant: what the next sale of this
        # variant will snapshot onto its line. Set by the purchases this
        # simulation issues, from their own inputs.
        self.base_unit_cost: dict = {}
        # The valuation ledger this world implies: one engine per variant, fed
        # by the same stock events the oracle already tracks, in the same order.
        #
        # This deliberately reuses the production valuation engine rather than
        # reimplementing FIFO/LIFO/average arithmetic a second time. What the
        # oracle proves here is the *wiring* — that every stock event reaches
        # the ledger with the right quantity, the right cost and in the right
        # order — which is where this change can actually go wrong. The
        # arithmetic itself is pinned separately, and adversarially, by
        # ``apps.inventory.test_valuation``.
        self.valuation: dict = {}
        self.valuation_method = ValuationMethod.MOVING_AVERAGE
        self.last_bin_rate: dict = {}
        # Open supplier credit per supplier, accumulated from the returns this
        # simulation issued and the amounts the oracle computed for them.
        self.supplier_credit: dict = defaultdict(lambda: ZERO)
        # Independent logs that mirror exactly what we instructed the backend to
        # do; the register reconciliation + summary expectations are derived from
        # these, never from backend reads.
        self.payments_log = []  # (session_id, method, amount>0, commission)
        self.adjustments_log = []  # (session_id, refund_method, amount, cash_amount)
        self.cash_moves_log = []  # (session_id, movement_type, amount)
        # Every refund document the oracle predicted, kept whole. The per-refund
        # assertions consume a ``RefundRec`` and drop it; the shop-wide P&L
        # reconciliation needs the *cost* side of each one, and a cost summed
        # per document then re-summed is not the same number as one raw sum over
        # every returned line — which is exactly what the reports compute.
        self.refunds = []  # RefundRec

    # -- stock --
    def available(self, variant_id: int) -> Decimal:
        return self.on_hand[variant_id] - self.committed[variant_id]

    def seed_stock(self, variant_id: int, quantity: Decimal):
        self.on_hand[variant_id] = q3(quantity)
        self.seed_on_hand[variant_id] = q3(quantity)
        # Deliberately no valuation entry: this stock is created straight onto
        # ``StockItem`` with no movement, so the real ledger never sees it
        # either. The first sale of an unpurchased variant therefore falls back
        # to the last purchase cost on both sides, which is what makes that
        # fallback path exercised rather than theoretical.

    # -- valuation (mirrors apps.inventory.valuation_service) --
    def _valuation_engine(self, variant_id: int):
        engine = self.valuation.get(variant_id)
        if engine is None:
            engine = valuation_engine(self.valuation_method)
            self.valuation[variant_id] = engine
        return engine

    def _bin_rate(self, variant_id: int) -> Decimal:
        """The stored rate, quantised the way the bin column is."""
        engine = self.valuation.get(variant_id)
        if engine is None:
            return ZERO
        quantity, value = engine.get_total_stock_and_value()
        if quantity == ZERO:
            return self.last_bin_rate.get(variant_id, ZERO)
        return (value / quantity).quantize(Decimal("0.000001"))

    def _valuation_fallback(self, variant_id: int) -> Decimal:
        """What an issue costs when nothing has been valued yet.

        Mirrors the service: the bin's own rate when it has one, otherwise the
        last purchase cost — the pre-ledger rule, kept as the floor.
        """
        return self._bin_rate(variant_id) or self.base_unit_cost.get(variant_id, ZERO)

    def value_receipt(self, variant_id: int, base_quantity: Decimal, rate: Decimal):
        if base_quantity <= ZERO:
            return
        engine = self._valuation_engine(variant_id)
        previous = self._bin_rate(variant_id)
        engine.add_stock(base_quantity, rate)
        self._remember_bin_rate(variant_id, previous)

    def value_issue(self, variant_id: int, base_quantity: Decimal) -> Decimal:
        """Issue stock and return what it cost per base unit."""
        if base_quantity <= ZERO:
            return ZERO
        engine = self._valuation_engine(variant_id)
        previous = self._bin_rate(variant_id)
        fallback = self._valuation_fallback(variant_id)
        consumed = engine.remove_stock(
            base_quantity,
            rate_generator=lambda: fallback,
        )
        self._remember_bin_rate(variant_id, previous)
        return consumed_unit_cost(consumed)

    def _remember_bin_rate(self, variant_id: int, previous: Decimal):
        """Emptying a bin keeps its last rate, exactly as the column does."""
        engine = self.valuation[variant_id]
        quantity, value = engine.get_total_stock_and_value()
        if quantity == ZERO:
            self.last_bin_rate[variant_id] = previous
        else:
            self.last_bin_rate[variant_id] = (value / quantity).quantize(
                Decimal("0.000001")
            )

    def cost_basis(self, variant_id: int, base_quantity: Decimal) -> Decimal:
        """What issuing ``base_quantity`` of this variant would cost per base unit.

        Asked by *probing* a throwaway copy of the engine rather than reading
        the stored rate, because the backend takes the figure it stamps from
        the issue itself. The two diverge exactly where it matters: once a bin
        has been emptied or driven negative, the stored rate is the last rate
        the shelf *held*, while the issue is priced at the rate the engine is
        actually carrying.
        """
        engine = self.valuation.get(variant_id)
        if engine is None:
            return self.base_unit_cost.get(variant_id, ZERO)
        if base_quantity is None or base_quantity <= ZERO:
            return self._bin_rate(variant_id) or self.base_unit_cost.get(
                variant_id, ZERO
            )
        fallback = self._valuation_fallback(variant_id)
        probe = valuation_engine(self.valuation_method, engine.state)
        consumed = probe.remove_stock(base_quantity, rate_generator=lambda: fallback)
        return consumed_unit_cost(consumed)

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
    units: list  # list[UnitChoice] — units this item may be SOLD in
    # Units this item may be BOUGHT in. Deliberately a separate list: a shop
    # routinely buys by the carton and sells by the piece, so a purchasable
    # pack is not necessarily sellable, and feeding one to a sale line would
    # only ever produce a 400 the backend is right to return.
    purchase_units: list  # list[UnitChoice]
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


def response_body(response):
    """The body of *any* response, DRF or not.

    ``.data`` exists only on DRF ``Response``. Middleware answers with a plain
    ``JsonResponse`` — the license gate (503 until enrolled) and the anonymous
    burst ceiling (429) both do — so reading ``.data`` in a failure message
    raises ``AttributeError`` and destroys the diagnostic at exactly the moment
    it is needed: the run dies reporting a missing attribute instead of the
    status and body that say what actually refused.
    """
    data = getattr(response, "data", None)
    if data is not None:
        return data
    content = getattr(response, "content", b"")
    try:
        return content.decode("utf-8", "replace")[:500]
    except Exception:  # pragma: no cover - defensive
        return repr(content)[:500]


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
        # Vacuity guards for the supplier-return assertions: a run that never
        # sent goods back, or never sent back part of an over-shipped line,
        # proves nothing about either and must not pass for coverage.
        self.returned_line_assertions = 0
        self.over_received_return_assertions = 0
        # Vacuity guards for the purchasing side's pack↔base crossing. At
        # factor 1 every conversion is the identity, so a dropped multiply is
        # invisible — which is exactly the state this harness was in.
        # ``mixed_unit_retail_landed_orders`` is the narrower one: freight
        # spread BY RETAIL VALUE (the only weight that reads a per-base
        # catalog price) over lines bought in DIFFERENT units is the one
        # shape in which a weight that forgot to convert differs from one
        # that did — scaling every weight alike changes no allocation.
        self.pack_purchase_line_assertions = 0
        self.mixed_unit_retail_landed_orders = 0
        # Vacuity guards for the sales refund document. A refund of goods that
        # were never purchased reverses a cost of 0.00, which every broken
        # implementation of the COGS reversal also produces; and at unit factor
        # 1 the pack↔base crossing in that reversal is the identity. A run that
        # only ever saw those has proved nothing about ``returned_cost_total``.
        self.costed_refund_assertions = 0
        self.multi_unit_costed_refund_assertions = 0
        # Vacuity guard for the destination-regime cap on a line's discount.
        # The engine's cap and the order line's own subtotal can only disagree
        # on a line the discounts consumed ENTIRELY (anything less is far from
        # both caps) whose gross lands exactly on a half-cent (anything else
        # rounds the same way in both regimes). A run that never rang up that
        # combination proves nothing about ``_order_line_discounts`` — with or
        # without the cap, every line agrees.
        self.fully_discounted_line_assertions = 0
        self.half_cent_fully_discounted_lines = 0
        # Vacuity guard for the shop-wide P&L reconciliation. Reported profit
        # only diverges from the documents on a line whose gross carries more
        # precision than the cent the line stores — a whole-unit sale at a 2dp
        # price is identical under every implementation. Counted over orders
        # that were fully handed back, because that is where the divergence
        # stops being a rounding preference and becomes a conservation failure:
        # a sale that was entirely undone must leave profit exactly where it
        # found it.
        self.undone_orders_reconciled = 0
        self.rounding_sensitive_undone_orders = 0
        self.ranking_rows_reconciled = 0
        self.returned_ranking_rows = 0

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
        if order.first_payment_method is None:
            order.first_payment_method = method
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
        piece_prices = [
            "2.00", "3.50", "1.25", "4.00", "0.75", "9.99",
            "6.40", "0.30", "12.75",
        ]
        for i, price in enumerate(piece_prices):
            self._add_product(
                name=f"Piece {i}",
                sku=f"PCE{i}",
                unit_price=Decimal(price),
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
        m0.purchase_units.append(UnitChoice("box", Decimal("12"), None, True))

        m1 = self._add_product(
            name="Multi 1", sku="MUL1", unit_price=Decimal("0.50"), base_whole=True
        )
        ProductUnit.objects.create(
            product=m1.variant.product, unit=carton, factor_to_base=Decimal("24"),
            price=None, is_sellable=True, is_purchasable=True,
        )
        m1.units.append(UnitChoice("carton", Decimal("24"), None, True))
        m1.purchase_units.append(UnitChoice("carton", Decimal("24"), None, True))

        # Purchase-only packs: goods bought by the carton and sold by the
        # piece, which is how a shop actually buys most of what it stocks.
        # Without these the purchasing side never crosses a pack↔base boundary
        # at all — every factor is 1, where a dropped conversion is the
        # identity and therefore invisible. Spread over several products on
        # purpose: a landed-cost allocation is scale-invariant, so a defect in
        # a per-line weight only shows on an order that MIXES units.
        purchase_packs = [
            (self.items[1], "carton", Decimal("30")),   # Piece 1
            (self.items[3], "pack", Decimal("6")),      # Piece 3
            (self.items[5], "box", Decimal("10")),      # Piece 5
            (self.items[8], "dozen", Decimal("12")),    # Piece 8
        ]
        for item, code, factor in purchase_packs:
            ProductUnit.objects.create(
                product=item.variant.product,
                unit=UnitOfMeasure.objects.get(code=code),
                factor_to_base=factor,
                price=None,
                is_sellable=False,
                is_purchasable=True,
            )
            item.purchase_units.append(UnitChoice(code, factor, None, True))
        # A fractional base unit bought in a whole pack: 25kg sacks of a
        # product the shop weighs out. The base quantity is then a multiple of
        # 25 rather than a small integer, which is where a 3dp quantize and a
        # per-base cost division have room to disagree.
        sack_item = self.items[9]  # Weight 0 (kg base)
        ProductUnit.objects.create(
            product=sack_item.variant.product,
            unit=UnitOfMeasure.objects.get(code="bag"),
            factor_to_base=Decimal("25"),
            price=None,
            is_sellable=False,
            is_purchasable=True,
        )
        sack_item.purchase_units.append(
            UnitChoice("bag", Decimal("25"), None, True)
        )

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

        self._build_operations_world()
        self._build_discounts()
        self._open_register()

    def _build_operations_world(self):
        """The repair counter: a workflow, some customer property, a labour SKU.

        Jobs end in a normal ``sales.Order``, so once a job is invoiced its
        order joins ``oracle.orders`` like any other sale and every conservation
        identity already in this file — drawer cash, per-method net payments,
        session summaries, revenue, profit — covers repair revenue too, without
        a parallel set of assertions.
        """
        settings = ShopSettings.load()
        settings.enable_repair_operations = True
        settings.save(update_fields=["enable_repair_operations"])

        self.repair_template = (
            WorkflowTemplate.objects.filter(job_type="repair", is_system=True)
            .prefetch_related("stages")
            .first()
        )
        self.repair_stages = list(
            self.repair_template.stages.order_by("display_order", "id")
        )
        # Materialise the labour SKU now so its variant id is known before any
        # invoice needs it; production creates it lazily on first use.
        self.labor_variant = _labor_variant()
        self.assets = [
            Asset.objects.create(
                customer=customer,
                asset_type=Asset.AssetType.PHONE,
                brand="Brand",
                model_name=f"Model {index}",
                imei=f"35678901234{index:04d}",
            )
            for index, customer in enumerate(self.customers)
        ]
        # Service products the repair counter charges for, reusing the catalog's
        # own non-stock items rather than inventing a second kind of service.
        self.service_items = [item for item in self.items if not item.tracks_stock]

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
            purchase_units=[UnitChoice("", Decimal("1"), None, base_whole)],
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
                # A line-scope 100% coupon on the two weighed products. This is
                # the ONLY generator that can hand an order line a discount
                # equal to its whole value, and a weighed line priced 3.33 or
                # 5.50 against quantities in 0.25 steps lands on a half-cent
                # often (5.50 x 0.75 = 4.125). That pair is the entire reachable
                # surface of the two rounding regimes' disagreement about what a
                # line can carry, and nothing in this world produced it before.
                name="Coupon FREEKG",
                application_type=DiscountRule.ApplicationType.COUPON_CODE,
                coupon_code="FREEKG",
                scope=DiscountRule.Scope.LINE,
                value_type=DiscountRule.ValueType.PERCENTAGE,
                value=Decimal("100"),
                priority=1,
                exclusive=False,
                products=[self.items[9].variant.product, self.items[10].variant.product],
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
            self.fail(f"register start failed: {response.status_code} {response_body(response)}")
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

    def _force_half_cent_free_line(self, specs):
        """Put a weighed line whose gross lands exactly on a half-cent into
        ``specs``, replacing any line already there for the same variant.

        FREEKG zeroes such a line outright, and a fully consumed line whose
        gross is a half-cent is the *only* shape in which the discount engine's
        cap (``up2`` — 5.50 x 0.75 = 4.125 -> 4.13) and the subtotal the order
        line actually stores (``even2`` -> 4.12) disagree about what that line
        can carry. Left to chance it is a few percent of carts, and a 300-op CI
        run sees none — so it is forced, the same deliberate widening the
        11-line purchase order and the mixed-unit landed-cost order already get.
        """
        for item in (self.items[9], self.items[10]):  # Weight 0 / Weight 1
            unit = item.units[0]
            price = item.effective_unit_price(unit, [])
            for quantity in (
                Decimal("0.75"),
                Decimal("0.25"),
                Decimal("1.50"),
                Decimal("0.50"),
            ):
                gross = price * quantity
                if even2(gross) == up2(gross):
                    continue  # not a half-cent: both regimes agree, no test
                if self.oracle.available(item.variant_id) < quantity:
                    continue
                specs = [
                    spec
                    for spec in specs
                    if spec["item"].variant_id != item.variant_id
                ]
                specs.append(
                    {
                        "item": item,
                        "unit": unit,
                        "quantity": quantity,
                        "modifiers": [],
                        "eff_price": price,
                        "base_qty": q3(quantity * unit.factor),
                    }
                )
                return specs
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
        per_line, total, _ = self._compute_discounts_detail(
            specs, customer_id, coupon_codes
        )
        return per_line, total

    def _compute_discounts_detail(self, specs, customer_id, coupon_codes):
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

    def _order_line_discounts(self, specs, per_line_discount):
        """The discount each ORDER LINE stores — the oracle's own port of
        ``apps.sales.services.order_line_discounts``.

        The engine (ported above as ``OracleDiscountEngine``) allocates in the
        discount regime, ``up2``, and caps a line at *its* subtotal. An order
        line stores ``even2``. On a gross landing exactly on a half-cent the two
        differ by a cent, so an allocation that consumed the whole engine line
        is one cent more than the order line can carry. Cap at the line's own
        ``even2`` subtotal — computed here from the oracle's own ``eff_price``
        and ``quantity``, never read back from the order.
        """
        return {
            str(index): min(
                per_line_discount.get(str(index), ZERO),
                even2(spec["eff_price"] * spec["quantity"]),
            )
            for index, spec in enumerate(specs)
        }

    def _order_totals(self, specs, per_line_discount):
        subtotal = even2(
            sum((even2(s["eff_price"] * s["quantity"]) for s in specs), ZERO)
        )
        # The discounts the LINES can carry, not the engine's raw allocations:
        # an allocation a cent above its own line used to take that cent off the
        # order as well. Ported from the documented backend rule.
        discount_total = sum(
            self._order_line_discounts(specs, per_line_discount).values(), ZERO
        )
        discount_total = min(even2(discount_total), subtotal)
        total = even2(subtotal - discount_total)
        return subtotal, discount_total, total

    def _expected_unit_cost(
        self, variant_id: int, unit_factor: Decimal, base_quantity: Decimal = None
    ) -> Decimal:
        """The cost a sale line for ``variant_id`` must snapshot right now.

        Since the valuation ledger landed this is no longer "whatever the item
        last cost to buy". It is what the goods on the shelf are actually
        worth: the rate the ledger holds for this variant, scaled by the factor
        of the unit being transacted in so ``unit_cost * quantity`` stays the
        cost of the goods that actually left.

        A variant with nothing valued yet — this world seeds free opening stock
        with no movement behind it, exactly as a pre-ledger shop has — falls
        back to the last purchase cost, which is the old rule kept as the floor.

        Read *before* the issue rather than after, which is sound because this
        world values at moving average and issuing stock does not move a moving
        average. A simulation running FIFO or LIFO would have to take the rate
        from the issue itself, since there the two differ.
        """
        base_cost = self.oracle.cost_basis(variant_id, base_quantity)
        return even2(base_cost * unit_factor)

    def _build_order_rec(self, order, specs, per_line_discount, sale_type, customer_id):
        issues_stock = sale_type != Order.SaleType.QUOTATION
        subtotal, discount_total, total = self._order_totals(specs, per_line_discount)
        line_discounts = self._order_line_discounts(specs, per_line_discount)
        for index, spec in enumerate(specs):
            gross = spec["eff_price"] * spec["quantity"]
            if gross <= ZERO:
                continue
            if line_discounts.get(str(index), ZERO) < even2(gross):
                continue
            # A line the discounts consumed entirely: the only shape in which
            # the engine's cap and the line's own subtotal can disagree, and
            # therefore the only one that proves the destination-regime port
            # above does anything.
            self.fully_discounted_line_assertions += 1
            if even2(gross) != up2(gross):
                self.half_cent_fully_discounted_lines += 1
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
                    discount_total=line_discounts.get(str(index), ZERO),
                    tracks_stock=spec["item"].tracks_stock,
                    whole_only=spec["unit"].whole_only,
                    unit_cost=self._expected_unit_cost(
                        spec["item"].variant_id,
                        spec["unit"].factor,
                        # A quotation reserves stock, it does not issue any, so
                        # its lines keep the provisional cost the cart was
                        # priced at and are never restamped. Only a sale that
                        # actually moves stock is costed from the issue.
                        spec["base_qty"]
                        if spec["item"].tracks_stock and issues_stock
                        else None,
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
                self.oracle.value_issue(vid, spec["base_qty"])

    # -- jobs (apps.operations) -------------------------------------------
    #
    # Everything here recomputes from transaction inputs, never from what the
    # backend stored. Stock moved by a job is the same oracle state a sale
    # moves, so a part fitted on a repair and the same part sold over the
    # counter are proven against one set of quantities and one valuation.

    def _stage(self, code: str):
        return next(stage for stage in self.repair_stages if stage.code == code)

    def _stage_index(self, code: str) -> int:
        return next(
            index for index, stage in enumerate(self.repair_stages)
            if stage.code == code
        )

    def _open_jobs(self) -> list:
        return [rec for rec in self.oracle.jobs.values() if rec.open]

    def _job_object(self, rec: JobRec):
        return Job.objects.select_related("workflow_template", "current_stage").get(
            pk=rec.job_id
        )

    def _expected_material_cost(self, variant_id: int) -> Decimal:
        """What ``_job_material_unit_cost`` will snapshot, per base unit.

        The valuation ledger's rate — the same basis a sale line uses. This is
        read *before* the issue, which is sound at moving average because
        issuing stock does not move the average.
        """
        return self._expected_unit_cost(variant_id, Decimal("1"))

    def op_open_repair_job(self) -> bool:
        if len(self._open_jobs()) >= 6:
            return False
        customer = self.rng.choice(self.customers)
        job = create_job(
            workflow_template=self.repair_template,
            request=None,
            customer=customer,
            symptoms="sim intake",
        )
        rec = JobRec(
            job_id=job.pk,
            customer_id=customer.id,
            stage_index=0,
        )
        self.oracle.jobs[job.pk] = rec
        self._assert_job(rec)
        return True

    def op_job_add_material(self) -> bool:
        candidates = [
            rec for rec in self._open_jobs()
            if rec.order_id is None and len(rec.materials) < 3
        ]
        if not candidates:
            return False
        rec = self.rng.choice(candidates)
        item = self.rng.choice(self.stock_items)
        quantity = Decimal(self.rng.randint(1, 3))
        if self.oracle.on_hand[item.variant_id] < quantity:
            return False
        # Consume now or leave pending: a pending material must not move stock
        # until a consuming stage or the invoice finalises it, and that is the
        # single most important thing about the two modes.
        consume_now = self.rng.random() < 0.5
        unit_price = up2(Decimal(item.variant.unit_price))
        unit_cost = self._expected_material_cost(item.variant_id)

        material = add_job_material(
            job=self._job_object(rec),
            variant=item.variant,
            quantity=quantity,
            request=None,
            consume_now=consume_now,
        )
        material_rec = JobMaterialRec(
            material_id=material.pk,
            variant_id=item.variant_id,
            quantity=quantity,
            unit_price=unit_price,
            unit_cost=unit_cost,
            consumed=consume_now,
        )
        rec.materials.append(material_rec)
        if consume_now:
            self._issue_job_material(material_rec)
        self._assert_job(rec)
        self._assert_variant(item.variant_id)
        return True

    def _issue_job_material(self, material: JobMaterialRec):
        self.oracle.on_hand[material.variant_id] = q3(
            self.oracle.on_hand[material.variant_id] - material.quantity
        )
        self.oracle.value_issue(material.variant_id, material.quantity)

    def _return_job_material(self, material: JobMaterialRec):
        """Unconsumed stock back on the shelf, at the shelf's own rate.

        ``reverse_job_material`` writes an INCREASE movement with no declared
        cost, and an undeclared incoming movement is valued at the bin's rate
        before it (``post_movement_valuations``), falling back to the last
        purchase cost and then to zero.
        """
        rate = (
            self.oracle._bin_rate(material.variant_id)
            or self.oracle._valuation_fallback(material.variant_id)
            or ZERO
        )
        self.oracle.on_hand[material.variant_id] = q3(
            self.oracle.on_hand[material.variant_id] + material.quantity
        )
        self.oracle.value_receipt(material.variant_id, material.quantity, rate)

    def op_job_reverse_material(self) -> bool:
        candidates = [
            (rec, m)
            for rec in self._open_jobs()
            if rec.order_id is None
            for m in rec.materials
            if not m.reversed
        ]
        if not candidates:
            return False
        rec, material = self.rng.choice(candidates)
        reverse_job_material(
            job=self._job_object(rec),
            material=self._job_object(rec).materials.get(pk=material.material_id),
            request=None,
        )
        if material.consumed:
            self._return_job_material(material)
        material.reversed = True
        self._assert_job(rec)
        self._assert_variant(material.variant_id)
        return True

    def op_job_add_service(self) -> bool:
        candidates = [
            rec for rec in self._open_jobs()
            if rec.order_id is None and len(rec.services) < 2
        ]
        if not candidates or not self.service_items:
            return False
        rec = self.rng.choice(candidates)
        item = self.rng.choice(self.service_items)
        quantity = Decimal(self.rng.randint(1, 2))
        unit_price = up2(Decimal(item.variant.unit_price))

        service = add_job_service(
            job=self._job_object(rec),
            variant=item.variant,
            quantity=quantity,
            request=None,
        )
        rec.services.append(
            JobServiceRec(
                service_id=service.pk,
                variant_id=item.variant_id,
                quantity=quantity,
                unit_price=unit_price,
            )
        )
        # A service moves no stock. Asserting the variant proves it: a service
        # that quietly decremented something would show up here.
        self._assert_job(rec)
        return True

    def op_job_advance(self) -> bool:
        """Move a job one stage, and prove the two gates on the way.

        The approval gate refuses to be left without an approved price; the
        settlement gate refuses to be *entered* while the job still owes money.
        Both are asserted by attempting the move and requiring the refusal.
        """
        candidates = [
            rec for rec in self._open_jobs()
            if rec.stage_index < len(self.repair_stages) - 1
        ]
        if not candidates:
            return False
        rec = self.rng.choice(candidates)
        current = self.repair_stages[rec.stage_index]
        target = self.repair_stages[rec.stage_index + 1]

        if current.requires_customer_approval and rec.approved_price is None:
            # Leaving the approval gate without a price must be refused, then
            # allowed once the price is recorded.
            self._assert_transition_refused(rec, target, "approval")
            price = up2(Decimal(self.rng.randint(50, 400)))
            job = self._job_object(rec)
            job.approved_price = price
            job.save(update_fields=["approved_price"])
            rec.approved_price = price

        if target.requires_settlement and not self._job_is_settled(rec):
            self._assert_transition_refused(rec, target, "settlement")
            return True

        transition_job(job=self._job_object(rec), to_stage=target, request=None)
        rec.stage_index += 1
        if rec.on_hold:
            # A forward move ends a hold: the part arrived.
            rec.on_hold = False
        if target.consumes_materials:
            for material in rec.materials:
                if not material.consumed and not material.reversed:
                    material.consumed = True
                    self._issue_job_material(material)
        if target.releases_custody:
            rec.handed_over = True
        if target.is_terminal:
            rec.completed = True
        self._assert_job(rec)
        for material in rec.materials:
            self._assert_variant(material.variant_id)
        return True

    def _job_is_settled(self, rec: JobRec) -> bool:
        """Mirrors ``apps.operations.services._job_is_settled``."""
        if rec.order_id is None:
            return not rec.has_anything_to_bill
        order = self.oracle.orders[rec.order_id]
        if order.balance_due <= ZERO:
            return True
        return order.sale_type == Order.SaleType.CREDIT and order.customer_id is not None

    def _assert_transition_refused(self, rec: JobRec, target, gate: str):
        try:
            transition_job(job=self._job_object(rec), to_stage=target, request=None)
        except DRFValidationError:
            return
        self.fail(
            f"job#{rec.job_id} passed the {gate} gate into '{target.code}' "
            f"when it should have been refused"
        )

    def op_job_invoice(self) -> bool:
        candidates = [
            rec for rec in self._open_jobs()
            if rec.order_id is None and (rec.materials or rec.services)
        ]
        if not candidates:
            return False
        rec = self.rng.choice(candidates)
        # Invoicing finalises every still-pending material, moving its stock
        # exactly once — the same rule a consuming stage applies.
        pending = [m for m in rec.materials if not m.consumed and not m.reversed]
        for material in pending:
            if self.oracle.on_hand[material.variant_id] < material.quantity:
                return False

        labor = (
            up2(Decimal(self.rng.randint(1, 60)))
            if self.rng.random() < 0.5
            else ZERO
        )
        rec.labor_total = labor
        for material in pending:
            material.consumed = True
        total = rec.invoice_total
        if total <= ZERO:
            for material in pending:
                material.consumed = False
            rec.labor_total = ZERO
            return False

        on_credit = self.rng.random() < 0.3
        if on_credit:
            paid_now = up2(total * Decimal(self.rng.choice(["0", "0.4", "1"])))
        else:
            paid_now = total
        payments = (
            self.split_amount(paid_now, list(self.PAYMENT_METHODS))
            if paid_now > ZERO
            else []
        )
        # Billing above the approved price is a deliberate act; the oracle takes
        # it deliberately too rather than letting the guard fire at random.
        acknowledge = rec.approved_price is not None and total > rec.approved_price

        invoice_job(
            job=self._job_object(rec),
            register_session=self._register_session_obj(),
            payments_data=[{"method": m, "amount": a} for m, a in payments],
            labor_total=labor,
            request=None,
            sale_type=(
                Order.SaleType.CREDIT if on_credit else Order.SaleType.STANDARD
            ),
            acknowledge_over_quote=acknowledge,
        )
        for material in pending:
            self._issue_job_material(material)

        job = self._job_object(rec)
        rec.order_id = job.order_id
        order_rec = self._build_job_order_rec(rec, job.order)
        for method, amount in payments:
            self.record_order_payment(order_rec, method, amount)
        self._assert_order(order_rec)
        self._assert_job(rec)
        for material in rec.materials:
            self._assert_variant(material.variant_id)
        self._assert_session(self.current_session_id)
        return True

    def _build_job_order_rec(self, rec: JobRec, order) -> OrderRec:
        """The job's invoice as a normal ``OrderRec``.

        No discount engine runs on a job invoice — ``invoice_job`` writes the
        lines and calls ``order.recalculate()``, which only sums them — so the
        subtotal is the lines and the discount is zero. Materials keep the price
        and cost they snapshotted when the technician fitted them; services and
        labour carry no cost, because the shop's cost there is payroll's, and
        charging it twice is what a cost on those lines would do.
        """
        # ``tracks_stock`` states what the VARIANT is, not what happened at
        # invoice time. Invoicing moves no stock — the parts left when the
        # technician fitted them, which is why the order is marked
        # ``stock_already_recorded`` — but a job invoice is a normal order, so
        # the returns desk can hand its parts back, and that DOES restock them.
        # Saying "false" here because nothing moved on the way out silently lost
        # every unit that came back on the way in.
        stock_tracked = {item.variant_id for item in self.stock_items}
        whole_only_of = {
            item.variant_id: item.units[0].whole_only for item in self.items
        }
        expected = [
            (m.variant_id, m.quantity, m.unit_price, m.unit_cost)
            for m in rec.billable_materials
        ]
        expected += [
            (s.variant_id, s.quantity, s.unit_price, ZERO) for s in rec.services
        ]
        if rec.labor_total > ZERO:
            expected.append(
                (self.labor_variant.pk, Decimal("1"), rec.labor_total, ZERO)
            )

        order_lines = list(order.lines.order_by("pk"))
        if len(order_lines) != len(expected):
            self.fail(
                f"job#{rec.job_id} invoice line count: backend={len(order_lines)} "
                f"oracle={len(expected)}"
            )
        line_recs = []
        for order_line, (variant_id, quantity, unit_price, unit_cost) in zip(
            order_lines, expected
        ):
            line_recs.append(
                LineRec(
                    order_line_id=order_line.pk,
                    variant_id=variant_id,
                    unit_price=unit_price,
                    quantity=quantity,
                    unit_factor=Decimal("1"),
                    discount_total=ZERO,
                    tracks_stock=variant_id in stock_tracked,
                    whole_only=whole_only_of.get(variant_id, True),
                    unit_cost=unit_cost,
                )
            )
        subtotal = even2(
            sum((even2(lr.unit_price * lr.quantity) for lr in line_recs), ZERO)
        )
        order_rec = OrderRec(
            order_id=order.pk,
            sale_type=order.sale_type,
            register_session_id=self.current_session_id,
            customer_id=rec.customer_id,
            lines=line_recs,
            subtotal=subtotal,
            discount_total=ZERO,
            total=subtotal,
            has_service=bool(rec.services) or rec.labor_total > ZERO,
            created_index=self.op_index,
        )
        self.oracle.orders[order.pk] = order_rec
        return order_rec

    def op_job_hold_resume(self) -> bool:
        candidates = [rec for rec in self._open_jobs() if not rec.handed_over]
        if not candidates:
            return False
        rec = self.rng.choice(candidates)
        if rec.on_hold:
            resume_job(job=self._job_object(rec), request=None)
            rec.on_hold = False
        else:
            hold_job(job=self._job_object(rec), reason="waiting on a part", request=None)
            rec.on_hold = True
        self._assert_job(rec)
        return True

    def _manager_request(self):
        """A request carrying the (superuser, therefore manager) sim operator.

        Handed only to the services that gate on *authority*. Everything else
        keeps ``request=None``: ``create_job`` and ``invoice_job`` stamp a sales
        channel from the request's credentials, and giving them one would change
        what those paths exercise.
        """
        return SimpleNamespace(user=self.user)

    def op_job_cancel(self) -> bool:
        """Cancelling puts every consumed part back on the shelf.

        Proves the authority gate in both directions: a job that has already
        eaten stock cannot be cancelled by someone with no manager standing,
        and can be by someone with it — at which point every consumed part is
        credited back at the shelf's own rate.
        """
        candidates = [
            rec for rec in self._open_jobs()
            if rec.order_id is None and rec.materials
        ]
        if not candidates:
            return False
        rec = self.rng.choice(candidates)

        if any(material.billable for material in rec.materials):
            try:
                cancel_job(job=self._job_object(rec), request=None, reason="no rights")
            except DRFValidationError:
                pass
            else:
                self.fail(
                    f"job#{rec.job_id} was cancelled with consumed materials by a "
                    "caller with no manager standing"
                )
            self._assert_job(rec)

        cancel_job(
            job=self._job_object(rec),
            request=self._manager_request(),
            reason="sim cancel",
        )
        for material in rec.materials:
            if material.billable:
                self._return_job_material(material)
                material.reversed = True
        rec.cancelled = True
        self._assert_job(rec)
        for material in rec.materials:
            self._assert_variant(material.variant_id)
        return True

    def _assert_job(self, rec: JobRec):
        job = Job.objects.prefetch_related("materials", "services").get(pk=rec.job_id)
        tag = f"job#{rec.job_id}"
        expected_status = (
            Job.Status.CANCELLED
            if rec.cancelled
            else Job.Status.COMPLETED
            if rec.completed
            else Job.Status.OPEN
        )
        self.assert_equal(job.status, expected_status, f"{tag} status")
        self.assert_equal(
            job.current_stage.code,
            self.repair_stages[rec.stage_index].code,
            f"{tag} stage",
        )
        self.assert_equal(job.is_on_hold, rec.on_hold, f"{tag} on_hold")
        self.assert_equal(
            job.handed_over_at is not None, rec.handed_over, f"{tag} handed_over"
        )
        self.assert_equal(job.order_id, rec.order_id, f"{tag} order")
        self.assert_equal(
            job.materials.count(), len(rec.materials), f"{tag} material count"
        )
        self.assert_equal(
            job.services.count(), len(rec.services), f"{tag} service count"
        )
        for material in rec.materials:
            stored = job.materials.get(pk=material.material_id)
            mtag = f"{tag} material#{material.material_id}"
            self.assert_qty(stored.quantity, material.quantity, f"{mtag} quantity")
            self.assert_money(stored.unit_price, material.unit_price, f"{mtag} price")
            # The cost basis: a part fitted on a repair must cost what the same
            # part costs when it is sold over the counter.
            self.assert_money(stored.unit_cost, material.unit_cost, f"{mtag} cost")
            self.assert_equal(
                stored.is_consumed, material.billable, f"{mtag} consumed"
            )
        for service in rec.services:
            stored = job.services.get(pk=service.service_id)
            stag = f"{tag} service#{service.service_id}"
            self.assert_qty(stored.quantity, service.quantity, f"{stag} quantity")
            self.assert_money(stored.unit_price, service.unit_price, f"{stag} price")

    # -- operations -------------------------------------------------------

    def op_standard_sale(self) -> bool:
        specs = self._choose_lines(include_service=self.rng.random() < 0.25)
        if not specs:
            return False
        customer = self.rng.choice(self.customers) if self.rng.random() < 0.5 else None
        customer_id = customer.id if customer else None
        coupon_codes = self._random_coupons()
        if "FREEKG" in coupon_codes:
            specs = self._force_half_cent_free_line(specs)
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

    def op_api_sale(self) -> bool:
        """A standard sale rung up through the DRF checkout endpoint.

        ``op_standard_sale`` calls the ``checkout_order`` service directly *and
        tells it the unit price to charge*, so two things stay unproven: whatever
        the API layer decides on the way in, and the server's own per-unit
        pricing. This op posts what a POS actually sends — a variant id, a
        quantity, a unit code and modifier option ids — and lets the backend
        price the cart itself.

        Every expected figure is still the oracle's own, computed from the inputs
        it put in the request: its port of ``unit_sale_price`` (the unit's custom
        price if set, else the base price scaled by the factor) plus the modifier
        deltas it chose, run through its own discount engine and its own
        rounding. Nothing is read back from the response to decide what to
        expect; the response is only ever asserted against.
        """
        specs = self._choose_lines(include_service=self.rng.random() < 0.25)
        if not specs:
            return False
        customer = self.rng.choice(self.customers) if self.rng.random() < 0.5 else None
        customer_id = customer.id if customer else None
        coupon_codes = self._random_coupons()
        if "FREEKG" in coupon_codes:
            specs = self._force_half_cent_free_line(specs)
        per_line_discount, _, applied_codes = self._compute_discounts_detail(
            specs, customer_id, coupon_codes
        )
        # The API refuses a sale carrying a coupon that changed nothing (the
        # service path silently ignores it). The oracle predicts which coupons
        # its own engine applied, so it knows which answer to demand.
        unapplied = sorted(_normalize_codes(coupon_codes) - applied_codes)
        subtotal, discount_total, total = self._order_totals(specs, per_line_discount)
        if total <= ZERO:
            return False
        payments = self.split_amount(total, list(self.PAYMENT_METHODS))
        payload = {
            "lines": [
                {
                    "variant": spec["item"].variant_id,
                    "quantity": str(spec["quantity"]),
                    "unit": spec["unit"].code,
                    "modifiers": [
                        {"option": option.pk, "quantity": qty}
                        for option, _, qty in spec["modifiers"]
                    ],
                }
                for spec in specs
            ],
            "payments": [{"method": m, "amount": str(a)} for m, a in payments],
            "sale_type": str(Order.SaleType.STANDARD),
        }
        if customer_id is not None:
            payload["customer"] = customer_id
        if coupon_codes:
            payload["coupon_codes"] = list(coupon_codes)
        order_count_before = Order.objects.count()
        response = self.client.post("/api/orders/checkout/", payload, format="json")
        if unapplied:
            # A coupon the engine could not apply must be refused outright, and
            # nothing may be written — a sale that quietly drops the coupon
            # charges the customer a price the cashier did not agree to.
            if response.status_code != 400:
                self.fail(
                    f"api checkout accepted unapplied coupons {unapplied}: "
                    f"{response.status_code}"
                )
            if "coupon_codes" not in response.data:
                self.fail(
                    f"api checkout rejected {unapplied} without naming the coupon: "
                    f"{response_body(response)}"
                )
            if Order.objects.count() != order_count_before:
                self.fail("rejected api checkout still created an order")
            return True
        if response.status_code != 201:
            # The tender offered is exactly the total the oracle says is owed. A
            # rejection here means the API is demanding a different number from
            # the one the order would go on to store.
            self.fail(
                f"api checkout rejected a correct tender of {total}: "
                f"{response.status_code} {response_body(response)}"
            )
        order = Order.objects.get(pk=response.data["id"])
        # The response body is the receipt, the drawer screen and the customer's
        # copy — assert it, not only the row it wrote.
        self.assert_money(
            Decimal(str(response.data["subtotal"])), subtotal, "api sale response subtotal"
        )
        self.assert_money(
            Decimal(str(response.data["discount_total"])),
            discount_total,
            "api sale response discount_total",
        )
        self.assert_money(
            Decimal(str(response.data["total"])), total, "api sale response total"
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
            self.oracle.value_issue(vid, base_qty)
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
                        src.variant_id,
                        src.unit_factor,
                        q3(Decimal(src.quantity) * src.unit_factor)
                        if src.tracks_stock
                        else None,
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

    def _apply_refund(self, rec: OrderRec, refund_lines) -> RefundRec:
        """refund_lines: list of (LineRec, qty). Applies the documented refund
        arithmetic to the oracle and returns the :class:`RefundRec` describing
        the document the backend should now have written (asserts handled by
        the caller)."""
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
        if not allocations:
            # No tender left to attribute the refund to: earlier refunds have
            # already drained every method's net to zero (or the order was never
            # paid at all — an آجل invoice returned before it was settled).
            # Production does not crash here, it falls back to the order's first
            # tender (``refund_method_for_order``) and writes the whole refund
            # against it, driving that method's net negative. The port returns []
            # and documents that the caller owns this branch; this is that branch.
            allocations = [(rec.first_payment_method or "cash", total)]
        cash_amount = sum((a for m, a in allocations if m == "cash"), ZERO)
        primary_method = max(allocations, key=lambda item: item[1])[0]
        for method, alloc in allocations:
            rec.paid_by_method[method] = even2(rec.paid_by_method[method] - alloc)
            rec.amount_paid = even2(rec.amount_paid - alloc)
        self.oracle.adjustments_log.append(
            (self.current_session_id, primary_method, even2(total), even2(cash_amount))
        )
        refund = RefundRec(
            total=even2(total),
            cash_amount=even2(cash_amount),
            primary_method=primary_method,
            lines=per_line_refund,
            order_id=rec.order_id,
        )
        self.oracle.refunds.append(refund)
        for line, qty, refund_discount in per_line_refund:
            line.returned_qty = line.returned_qty + Decimal(qty)
            line.returned_discount = even2(line.returned_discount + refund_discount)
            if line.tracks_stock:
                base = q3(Decimal(qty) * line.unit_factor)
                self.oracle.on_hand[line.variant_id] = q3(
                    self.oracle.on_hand[line.variant_id] + base
                )
                # Returned goods re-enter at what they left at: the cost the
                # original line snapshotted, per base unit.
                factor = line.unit_factor or Decimal("1")
                self.oracle.value_receipt(
                    line.variant_id, base, Decimal(line.unit_cost) / factor
                )
        if all(line.returnable_qty <= ZERO for line in rec.lines):
            rec.voided = True
        return refund

    def _line_refund_discount(self, line: LineRec, qty) -> Decimal:
        if line.discount_total <= ZERO:
            return ZERO
        remaining_discount = even2(line.discount_total - line.returned_discount)
        if Decimal(qty) >= line.returnable_qty:
            discount = max(remaining_discount, ZERO)
        else:
            proportional = even2(
                line.discount_total * Decimal(qty) / Decimal(line.quantity)
            )
            discount = min(proportional, max(remaining_discount, ZERO))
        # A refund line never credits less than nothing: each part of a split
        # return rounds its own gross, so a proportional share of a fully
        # discounted line can land a cent above the gross it is subtracted
        # from. Ported from the documented backend rule, not read back.
        return min(discount, even2(line.unit_price * Decimal(qty)))

    def _refund_gross(self, refund_lines) -> Decimal:
        """What ``adjustment_amount`` will make of ``refund_lines``.

        Production refuses a non-positive refund outright
        (``apps.sales.services.adjustment_amount``), so a set of lines that were
        discounted to nothing is not a valid input and the simulation must not
        offer one — the 400 that comes back is the backend being right. Note
        this is a *product* limitation worth knowing rather than an arithmetic
        one: goods given away free cannot be handed back at all, so their stock
        never returns to the shelf. Computed from the oracle's own ported refund
        arithmetic, like everything else here.
        """
        return even2(
            sum(
                (
                    even2(
                        even2(line.unit_price * Decimal(qty))
                        - self._line_refund_discount(line, qty)
                    )
                    for line, qty in refund_lines
                ),
                ZERO,
            )
        )

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
        if not refund_lines or self._refund_gross(refund_lines) <= ZERO:
            return False
        adjustment = return_order_items(
            order=Order.objects.get(pk=rec.order_id),
            lines=api_lines,
            reason="sim return",
            register_session=self._register_session_obj(),
            request=None,
        )
        refund = self._apply_refund(rec, refund_lines)
        self._assert_adjustment(adjustment, refund)
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
        if not outbound or self._refund_gross(outbound) <= ZERO:
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
        refund = self._apply_refund(rec, outbound)
        outbound_total = refund.total
        self._assert_adjustment(exchange.return_adjustment, refund)
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

    def _rounding_sensitive(self, rec: OrderRec) -> bool:
        """Does any line on ``rec`` carry more precision than the cent it stores?

        This is the only shape in which reported profit can diverge from the
        documents, so it is what the P&L reconciliation needs a void of. A whole
        unit at a 2dp price is exact under every implementation.
        """
        return any(
            even2(line.unit_price * line.quantity) != line.unit_price * line.quantity
            or even2(line.unit_cost * line.quantity) != line.unit_cost * line.quantity
            for line in rec.lines
        )

    def op_void_order(self) -> bool:
        candidates = self._refundable_orders()
        if not candidates:
            return False
        # Once the run has one such void the choice goes back to being random;
        # until then, prefer an order the identity can actually bite on. Left to
        # chance it is a coin flip — roughly one seed in twelve reached 300
        # operations without ever voiding a weighed sale, and that run passes the
        # conservation identity with or without the defect it exists to catch.
        # The same trick ``op_purchase_submit`` uses to force its 11-line order.
        if self.rounding_sensitive_undone_orders == 0:
            preferred = [rec for rec in candidates if self._rounding_sensitive(rec)]
            if preferred:
                candidates = preferred
        rec = self.rng.choice(candidates)
        refund_lines = [
            (line, line.returnable_qty) for line in rec.lines if line.returnable_qty > ZERO
        ]
        if self._refund_gross(refund_lines) <= ZERO:
            # Everything still on the order was given away free, so the void is
            # worth 0.00 and production refuses it — the third entry point into
            # ``adjustment_amount``'s positive-refund rule, and the sharpest:
            # a sale that cost the customer nothing cannot be voided at all.
            return False
        adjustment = void_order(
            order=Order.objects.get(pk=rec.order_id),
            reason="sim void",
            register_session=self._register_session_obj(),
            request=None,
        )
        refund = self._apply_refund(rec, refund_lines)
        self._assert_adjustment(adjustment, refund)
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
        # Usually a handful of lines. Sometimes a wide order, because the
        # leftover cents of a largest-remainder allocation only reach past the
        # first few lines when there are enough of them — and that is exactly
        # where two allocators that break their ties differently diverge.
        if self.rng.random() < 0.12 and len(pool) >= 11:
            line_count = self.rng.randint(11, len(pool))
        else:
            line_count = self.rng.randint(1, 3)
        chosen = pool[:line_count]
        # A deliberate slice of orders in the one shape that separates a
        # landed-cost weight which converts to base units from one that does
        # not: freight, spread by RETAIL VALUE (the only weight that reads a
        # per-base catalog price), over lines bought in DIFFERENT units. An
        # allocation is scale-invariant, so a single-unit order cannot tell the
        # two apart however much freight it carries. Left purely to chance the
        # combination is a couple of percent of orders and a 300-operation run
        # sees none often enough to make the vacuity guard decorative.
        packed_item = next((i for i in pool if len(i.purchase_units) > 1), None)
        plain_item = next((i for i in pool if len(i.purchase_units) == 1), None)
        force_retail_mix = (
            self.rng.random() < 0.18
            and packed_item is not None
            and plain_item is not None
        )
        if force_retail_mix:
            chosen = [packed_item, plain_item] + [
                i for i in chosen if i is not packed_item and i is not plain_item
            ]
        lines_data = []
        line_specs = []
        for item in chosen:
            quantity = self.rng.randint(5, 40)
            unit_cost = (Decimal(self.rng.randint(25, 500)) * CENT).quantize(CENT)
            # Buy in a pack roughly half the time when the product has one, so
            # ordinary orders mix units on their own too.
            unit = item.purchase_units[0]
            if len(item.purchase_units) > 1 and (
                (force_retail_mix and item is packed_item)
                or self.rng.random() < 0.5
            ):
                unit = self.rng.choice(item.purchase_units[1:])
            lines_data.append(
                {
                    "variant": item.variant,
                    "quantity": quantity,
                    "unit_cost": unit_cost,
                    "unit": unit.code,
                    "unit_factor": unit.factor,
                }
            )
            line_specs.append((item, quantity, unit_cost, unit))
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
        if force_retail_mix:
            allocation_method = PurchaseOrder.LandedCostAllocationMethod.RETAIL_VALUE
            if not landed_entries:
                landed_entries = [
                    {
                        "name": "landed mix",
                        "amount": (
                            Decimal(self.rng.randint(1, 4000)) * CENT
                        ).quantize(CENT),
                    }
                ]
        subtotal = ZERO
        for _, quantity, unit_cost, _unit in line_specs:
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
        for (item, quantity, unit_cost, unit), po_line in zip(line_specs, po_lines):
            po_line_rec = PoLineRec(
                line_id=po_line.pk,
                variant_id=item.variant_id,
                quantity=quantity,
                unit_factor=unit.factor,
                unit_cost=unit_cost,
                unit_code=unit.code,
            )
            line_recs.append(po_line_rec)
            # The newest purchase line for a variant is the one a sale reads,
            # whether or not the order has been received yet — only a CANCELLED
            # order drops out, and this simulation cancels none. Re-expressed
            # per base unit, exactly as PurchaseLine.base_unit_cost does.
            self.oracle.base_unit_cost[item.variant_id] = even2(
                po_line_rec.unit_cost / po_line_rec.unit_factor
            )
            # Submitting reserves the goods as EXPECTED stock, and stock is
            # only ever counted in base units — an order for 5 cartons of 24
            # promises 120 pieces, not 5.
            base = q3(Decimal(quantity) * unit.factor)
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
            {line.line_id: item.variant.unit_price for line, (item, _, _, _) in
             zip(line_recs, line_specs)},
        )
        if (
            landed_total > ZERO
            and allocation_method == PurchaseOrder.LandedCostAllocationMethod.RETAIL_VALUE
            and len({ln.unit_factor for ln in line_recs}) > 1
        ):
            self.mixed_unit_retail_landed_orders += 1
        self.oracle.pos[po.pk] = rec
        self._assert_po(po.pk, expected_status=PurchaseOrder.Status.SUBMITTED)
        self._assert_purchase_preview(
            supplier, lines_data, landed_entries, extra_requested,
            allocation_method, rec,
        )
        for item, _, _, _ in line_specs:
            self._assert_variant(item.variant_id)
        return True

    def _assert_purchase_preview(
        self, supplier, lines_data, landed_entries, extra_requested,
        allocation_method, rec: PoRec,
    ):
        """The buyer decides from the preview, so the preview owes the same
        numbers as the order it is about to save.

        Checked against the ORACLE's line costs, never against the purchase
        order that was just written — comparing the two backend surfaces to
        each other would only prove they agree, including on being wrong
        together. ``rec`` was computed in :meth:`_expect_po_line_costs` from the
        order's inputs alone.
        """
        response = self.client.post(
            reverse("purchaseorder-discount-preview"),
            {
                "supplier": supplier.id,
                "landed_cost_allocation_method": allocation_method,
                "extra_discount_amount": f"{extra_requested:.2f}",
                "landed_cost_entries": [
                    {"name": entry["name"], "amount": f"{entry['amount']:.2f}"}
                    for entry in landed_entries
                ],
                "lines": [
                    {
                        "variant": line["variant"].pk,
                        "quantity": line["quantity"],
                        "unit_cost": f"{line['unit_cost']:.2f}",
                        # The unit CODE only — the factor is the server's to
                        # look up, exactly as the PO editor sends it. Handing
                        # over the factor would be dictating the answer.
                        "unit": line["unit"],
                    }
                    for line in lines_data
                ],
            },
            format="json",
        )
        if response.status_code != 200:
            self.fail(f"purchase preview HTTP {response.status_code}: {response_body(response)}")
        data = response.data
        self.assert_money(data["subtotal"], rec.subtotal, "preview subtotal")
        self.assert_money(
            data["discount_total"], rec.extra_discount, "preview discount_total"
        )
        self.assert_money(
            data["landed_cost_total"], rec.landed_cost_total,
            "preview landed_cost_total",
        )
        self.assert_money(data["total"], rec.total, "preview total")
        # Preview lines come back in payload order, which is the order the
        # oracle recorded them in.
        for index, (payload, expected) in enumerate(zip(data["lines"], rec.lines)):
            tag = f"preview line#{index}"
            for name in (
                "discount_amount",
                "net_line_total",
                "net_unit_cost",
                "allocated_landed_cost",
                "landed_unit_cost",
                "effective_unit_cost",
                "effective_line_total",
            ):
                self.assert_money(
                    Decimal(payload[name]), getattr(expected, name), f"{tag} {name}"
                )

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
            # What the line is worth at retail. ``unit_price`` is per BASE unit,
            # so the quantity meeting it must be in base units — 5 cartons of 24
            # at 0.50 a piece is 60.00 of goods, not 2.50. Derived here from the
            # catalog price and the pack factor the oracle chose, not copied
            # from the backend's weight function: the whole point of a second
            # port is that it can disagree.
            weights = {
                ln.line_id: even2(retail_prices[ln.line_id] * ln.base_quantity)
                for ln in rec.lines
            }
        elif allocation_method == Method.EQUAL:
            weights = {ln.line_id: Decimal("1.00") for ln in rec.lines}
        else:
            weights = {ln.line_id: ln.net_line_total for ln in rec.lines}
        allocations = allocate_landed_cost(
            rec.landed_cost_total,
            weights,
            {ln.line_id: Decimal(ln.quantity) for ln in rec.lines},
        )
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
            if mode < 0.55:
                accepted, damaged, cancelled = outstanding, 0, 0
            elif mode < 0.68:
                # The supplier shipped more than was ordered. The order never
                # billed for the surplus, so every figure derived from the line
                # has to decide whether it follows the ordered count or the
                # arrived one — which is exactly where they can disagree.
                accepted = outstanding + self.rng.randint(1, 3)
                damaged = cancelled = 0
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
                    "allowed_over_receipt_quantity": max(
                        accepted + damaged - outstanding, 0
                    ),
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
        self._assert_supplier_ap(rec.supplier_id)
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
        # Received stock is valued at what it cost to put on the shelf: net of
        # discounts and landed costs, per base unit.
        #
        # The expected portion and the overage are valued SEPARATELY, in the
        # order the backend writes them, because the backend writes them as two
        # movements (``receive_expected`` then ``increase``) and
        # ``post_movement_valuations`` values one movement at a time, calling
        # ``_write_bin`` after each.
        #
        # Collapsing them into one receipt of the combined quantity gets the
        # same quantity and the same value, which is why this went unnoticed —
        # but not the same *rate*. An emptied bin keeps the rate it held before
        # the movement that emptied it, so when the two receipts straddle zero
        # (the ledger runs negative here: this world seeds opening stock with no
        # movement behind it, so every sale issues against nothing) the backend
        # keeps the rate as of the intermediate state and a single combined
        # receipt keeps the rate from before the whole batch. That kept rate is
        # what the next sale of the variant snapshots as its cost, so the two
        # disagree about what the goods cost from then on.
        self.oracle.value_receipt(
            vid, accepted_expected_base, line.effective_base_unit_cost
        )
        self.oracle.value_receipt(
            vid, accepted_overage_base, line.effective_base_unit_cost
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
            if rec.po_balance_due > ZERO
        ]
        if not candidates:
            return False
        rec = self.rng.choice(candidates)
        balance = rec.po_balance_due
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
        self._assert_supplier_ap(rec.supplier_id)
        return True

    def op_purchase_return(self) -> bool:
        """Send goods back to the supplier.

        Entered through the DRF endpoint on purpose: the client sends a line id
        and a quantity and nothing else, so every figure asserted below — the
        credit, the unit cost, the settlement — is the backend's own answer,
        not a number this simulation handed it. What the oracle supplies is only
        *which* units go back.
        """
        candidates = []
        for rec in self.oracle.pos.values():
            if not any(
                line.recv_accepted + line.recv_damaged + line.recv_cancelled > 0
                for line in rec.lines
            ):
                continue  # nothing received yet: the backend refuses to adjust
            for line in rec.lines:
                if line.adjustable > 0:
                    candidates.append((rec, line))
        if not candidates:
            return False
        self.rng.shuffle(candidates)
        if self.rng.random() < 0.5:
            # Half the time, go for an over-shipped line first. Left to chance
            # these are rare enough that a few hundred operations often see
            # none, and they are the whole reason the per-unit share and the
            # returnable ceiling can disagree.
            candidates.sort(key=lambda pair: pair[1].recv_accepted <= pair[1].quantity)

        for rec, line in candidates:
            adjustable = line.adjustable
            if adjustable >= 2 and self.rng.random() < 0.5:
                packs = self.rng.randint(1, adjustable - 1)
            else:
                packs = adjustable
            base_quantity = q3(Decimal(packs) * line.unit_factor)
            # The goods have to still be on the shelf, and not promised to an
            # open quotation — a return that ate reserved stock would strand a
            # conversion later and confuse the failure it caused.
            if self.oracle.available(line.variant_id) < base_quantity:
                continue
            amount = line.return_credit(packs)
            if amount <= ZERO:
                # The backend refuses a non-positive adjustment, so there is no
                # request to make. Legitimately reachable two ways: the line's
                # value was swallowed whole by the order's manual discount, or
                # earlier returns already claimed all of it. Note the blind
                # spot this leaves — a backend that credited something here
                # would go unseen — but it is bounded to sub-cent line values,
                # and the ceiling assertion below catches any over-credit the
                # moment a return does go through.
                continue
            break
        else:
            return False

        refund = self.rng.random() < 0.4
        url = reverse(
            "purchaseorder-refund-items" if refund else "purchaseorder-return-items",
            args=[rec.po_id],
        )
        response = self.client.post(
            url,
            {
                "lines": [{"line": line.line_id, "quantity": str(packs)}],
                "reason": "مرتجع مورد",
            },
            format="json",
        )
        if response.status_code not in (200, 201):
            self.fail(
                f"po#{rec.po_id} line#{line.line_id} return of {packs} rejected: "
                f"{response.status_code} {response_body(response)}"
            )

        # -- oracle state, from the quantities we asked for ------------------
        line.adjusted_packs += packs
        line.adjusted_value = even2(line.adjusted_value + amount)
        self.oracle.on_hand[line.variant_id] = q3(
            self.oracle.on_hand[line.variant_id] - base_quantity
        )
        self.oracle.value_issue(line.variant_id, base_quantity)
        if refund:
            # Settled as a refund: a supplier payment, so it counts against
            # what the shop still owes on the order.
            rec.paid = even2(rec.paid + amount)
        else:
            self.oracle.supplier_credit[rec.supplier_id] = even2(
                self.oracle.supplier_credit[rec.supplier_id] + amount
            )

        self._assert_purchase_return(rec, line, packs, amount, refund=refund)
        self._assert_variant(line.variant_id)
        self._assert_po(rec.po_id)
        self._assert_supplier_credit(rec.supplier_id)
        return True

    def _assert_purchase_return(self, rec: PoRec, line: PoLineRec, packs, amount, *, refund):
        po_line = PurchaseLine.objects.get(pk=line.line_id)
        tag = f"po#{rec.po_id} line#{line.line_id} return"
        self.assert_qty(
            po_line.adjusted_quantity, Decimal(line.adjusted_packs), f"{tag} adjusted_quantity"
        )
        self.assert_qty(
            po_line.adjustable_quantity, Decimal(line.adjustable), f"{tag} adjustable_quantity"
        )

        adjustment = (
            PurchaseOrderAdjustment.objects.filter(purchase_order_id=rec.po_id)
            .order_by("-created_at", "-pk")
            .first()
        )
        self.assert_money(adjustment.outbound_amount, amount, f"{tag} outbound_amount")
        self.assert_money(adjustment.amount, amount, f"{tag} amount")
        adj_line = adjustment.lines.get()
        self.assert_qty(adj_line.quantity, Decimal(packs), f"{tag} line quantity")
        self.assert_money(adj_line.line_amount, amount, f"{tag} line_amount")
        self.assert_money(
            adj_line.unit_cost, even2(amount / Decimal(packs)), f"{tag} line unit_cost"
        )

        # The invariant the per-return amounts exist to satisfy: every credit
        # this line will ever produce adds up to the value of the units that
        # arrived — no more, and once they have all gone back, no less.
        credited = even2(
            sum(
                (
                    adjline.line_amount
                    for adjline in PurchaseOrderAdjustmentLine.objects.filter(
                        purchase_line_id=line.line_id
                    )
                ),
                ZERO,
            )
        )
        self.assert_money(credited, line.adjusted_value, f"{tag} credited to date")
        if credited > line.returnable_value:
            self.fail(
                f"{tag} credited {credited} for a line worth {line.returnable_value} "
                f"(ordered {line.quantity}, arrived {line.recv_accepted})"
            )
        if line.adjustable == 0:
            self.assert_money(
                credited, line.returnable_value, f"{tag} fully returned line credit"
            )
        self.returned_line_assertions += 1
        if line.recv_accepted > line.quantity:
            self.over_received_return_assertions += 1

    def _assert_supplier_credit(self, supplier_id: int):
        supplier = Supplier.objects.get(pk=supplier_id)
        self.assert_money(
            supplier.credit_balance,
            self.oracle.supplier_credit[supplier_id],
            f"supplier#{supplier_id} credit_balance",
        )

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
            self.fail(f"{movement} failed: {response.status_code} {response_body(response)}")
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
            self.fail(f"stock-count start failed: {response.status_code} {response_body(response)}")
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
            delta = q3(counted - self.oracle.on_hand[vid])
            self.oracle.on_hand[vid] = counted
            # A count variance is stock appearing or disappearing at the value
            # the shelf already carried — no new cost information exists.
            if delta > ZERO:
                self.oracle.value_receipt(
                    vid, delta, self.oracle._valuation_fallback(vid)
                )
            elif delta < ZERO:
                self.oracle.value_issue(vid, -delta)
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
            self.fail(f"register close failed: {response.status_code} {response_body(response)}")
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
        if choice < 0.45:
            return ()
        if choice < 0.65:
            return ("SAVE3",)
        if choice < 0.80:
            return ("HALF",)
        if choice < 0.90:
            return ("SAVE3", "HALF")
        # FREEKG zeroes a weighed line outright. Handed out deliberately rather
        # than left to chance: the shape it creates (a fully consumed line whose
        # gross is a half-cent) is the only one the destination-regime cap on a
        # line's discount can be observed by, and the vacuity guard in the
        # entry-point test refuses a run that never saw it.
        return ("FREEKG",)

    # -- run loop ---------------------------------------------------------

    def operations(self):
        return [
            (self.op_standard_sale, 22),
            (self.op_api_sale, 8),
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
            (self.op_purchase_return, 5),
            (self.op_expense_payout, 3),
            (self.op_cash_movement, 4),
            (self.op_stock_count, 3),
            (self.op_cycle_register, 2),
            (self.op_attempt_oversell, 2),
            # The repair counter. Weighted so a run builds real jobs — parts
            # fitted, services added, stages walked, money taken — rather than
            # opening jobs it never finishes.
            (self.op_open_repair_job, 5),
            (self.op_job_add_material, 7),
            (self.op_job_add_service, 4),
            (self.op_job_advance, 8),
            (self.op_job_invoice, 5),
            (self.op_job_reverse_material, 2),
            (self.op_job_hold_resume, 2),
            (self.op_job_cancel, 2),
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
        self.reconcile_reports()
        self.reconcile_product_rankings()
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
        self._assert_valuation(variant_id)

    def _assert_valuation(self, variant_id: int):
        """The valuation ledger, asserted where the stock event happens.

        Quantities alone are not enough. A stock event the oracle models but the
        backend does not (or the reverse) leaves the two *valuations* apart while
        both quantity columns still agree — and nothing notices until, dozens of
        operations later, some unrelated sale snapshots a cost from the drifted
        rate and fails somewhere that has nothing to do with the cause. Two real
        divergences hid exactly that way before this existed.

        Compared against the oracle's own engine rather than ``on_hand``: this
        world seeds opening stock straight into ``StockItem`` with no movement
        behind it, so the ledger legitimately knows less than the shelf does.
        Both sides here count only what actually moved.
        """
        engine = self.oracle.valuation.get(variant_id)
        if engine is None:
            return
        bin_row = StockValuationBin.objects.filter(
            variant_id=variant_id,
            warehouse_id=Warehouse.default_id(),
        ).first()
        quantity, value = engine.get_total_stock_and_value()
        if bin_row is None:
            if quantity != ZERO or value != ZERO:
                self.fail(
                    f"variant {variant_id} valuation: backend has no bin, "
                    f"oracle holds {quantity} @ {value}"
                )
            return
        self.assert_qty(
            bin_row.quantity, quantity, f"variant {variant_id} valued quantity"
        )
        # Compared at the precision the COLUMN holds, not at cents.
        # ``stock_value`` is a 6dp field, so the backend has already rounded
        # once; rounding that to cents and the oracle's raw value to cents
        # rounds twice on one side and once on the other, and a value ending
        # .894999 reads as 59.90 against 59.89 — a cent of pure arithmetic
        # theatre. Quantising both sides the same way compares like with like.
        self.assert_equal(
            Decimal(bin_row.stock_value),
            Decimal(value).quantize(Decimal("0.000001")),
            f"variant {variant_id} stock value",
        )
        # The kept rate of an emptied bin, which nothing above can see.
        #
        # An emptied bin keeps the rate it last held, and that kept rate is what
        # the next sale of this variant snapshots as its cost. Quantity and
        # value are both zero either way, so a bin whose kept rate has drifted
        # looks identical to one that has not until, dozens of operations later,
        # some unrelated sale is costed from it. That is exactly how a receipt
        # valued as one event instead of two hid here.
        self.assert_equal(
            even2(bin_row.valuation_rate),
            even2(self.oracle._bin_rate(variant_id) or ZERO),
            f"variant {variant_id} valuation rate",
        )

    def _assert_adjustment(self, adjustment, refund: RefundRec):
        """The refund *document* — the row a return receipt is printed from and
        the row every profit report reverses margin through.

        Nothing here was reachable before. ``_apply_refund`` fed its figures
        into the session/drawer aggregates only, so the ``OrderAdjustment`` and
        its lines were the one document class in the simulation that the oracle
        created and then never looked at. Three things ride on them:

        * ``cash_amount`` decides how much of a split-tender refund leaves the
          drawer, and ``refund_method`` is what the shop sees the money went
          back on;
        * the per-line ``quantity``/``unit_price``/``discount_total`` snapshot is
          what the customer's return receipt shows, and ``discount_total`` is
          also what the *next* partial return of the same line subtracts from
          its remaining discount (``line_refund_discount``), so an error here
          compounds instead of staying put;
        * ``returned_cost_total`` is the cost of the restocked goods, which the
          dashboard and both profit reports add back so a refund reverses margin
          rather than margin *plus* the cost of goods that never left the shop.
          It only ever feeds reports, so revenue assertions cannot reach it.

        Every expectation is ``refund``'s — the oracle's own refund arithmetic
        and its own predicted cost basis. Nothing is read back off the order,
        the order line or the adjustment to decide what to expect.
        """
        tag = f"adjustment#{adjustment.pk}"
        self.assert_money(adjustment.amount, refund.total, f"{tag} amount")
        self.assert_money(
            adjustment.cash_amount, refund.cash_amount, f"{tag} cash_amount"
        )
        self.assert_equal(
            adjustment.refund_method, refund.primary_method, f"{tag} refund_method"
        )
        rows = list(
            OrderAdjustmentLine.objects.filter(adjustment=adjustment).order_by("pk")
        )
        # Matched by the sale line each row refunds, not by position: a void
        # walks the order's lines in pk order while a return walks whichever
        # ones this operation happened to pick, and neither ordering is the
        # thing under test.
        expected_by_line = {
            line.order_line_id: (line, qty, refund_discount)
            for line, qty, refund_discount in refund.lines
        }
        if len(rows) != len(expected_by_line):
            self.fail(
                f"{tag} line count: backend={len(rows)} "
                f"oracle={len(expected_by_line)}"
            )
        for row in rows:
            if row.order_line_id not in expected_by_line:
                self.fail(
                    f"{tag} refunds order line {row.order_line_id}, "
                    "which this operation never asked to return"
                )
            line, qty, refund_discount = expected_by_line.pop(row.order_line_id)
            row_tag = f"{tag} line#{row.pk}"
            self.assert_equal(row.variant_id, line.variant_id, f"{row_tag} variant")
            # The returned quantity is stored in the sale line's *transacted*
            # unit (cartons, not bottles) — that is the unit ``unit_price`` and
            # ``unit_cost`` are both denominated in, so the three multiply
            # directly and a base-unit quantity here would silently inflate both.
            self.assert_qty(row.quantity, Decimal(qty), f"{row_tag} quantity")
            self.assert_money(row.unit_price, line.unit_price, f"{row_tag} unit_price")
            self.assert_money(
                row.discount_total, refund_discount, f"{row_tag} discount_total"
            )
            if Decimal(qty) == line.quantity and line.returned_qty == Decimal(qty):
                # A line taken back whole, in one go, credits exactly what the
                # sale charged for it — the oracle's own ``line_total``, not
                # another backend figure. Deliberately *not* asserted for a line
                # returned in pieces: each part's gross rounds on its own, so
                # 0.5 + 0.5 of a line at 3.33 credits 3.32, and demanding
                # otherwise would report a defect the backend does not have.
                self.assert_money(
                    row.line_total, line.line_total, f"{row_tag} credits the sale line"
                )
        # Identity: the lines of the refund document are worth what the document
        # refunds. The document-level ``amount`` above is satisfiable while no
        # line agrees with it (see the purchasing-side entries in .ai/oracle.md),
        # and this is the only assertion that would notice.
        self.assert_money(
            even2(sum((row.line_total for row in rows), ZERO)),
            adjustment.amount,
            f"identity: {tag} line totals sum to amount",
        )
        expected_cost = refund.cost_total
        self.assert_money(
            returned_cost_total([adjustment]), expected_cost, f"{tag} returned_cost"
        )
        if expected_cost > ZERO:
            self.costed_refund_assertions += 1
            if any(line.unit_factor != Decimal("1") for line, _, _ in refund.lines):
                # A carton going back has to credit twenty-four pieces of cost,
                # not one — the same pack/base crossing the phantom-loss class
                # lives in, on the one figure no revenue assertion can see.
                self.multi_unit_costed_refund_assertions += 1

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
        """Every stored line is the line the oracle priced and costed, plus the
        identities that tie the lines back to the document they belong to.

        Two things are proven here that the order's own totals cannot reach.
        The **cost basis** is invisible to revenue: an order's money can be
        entirely right while ``unit_cost`` is wrong, and every margin, every
        profit report and the credit a return gives back for restocked goods are
        computed from that one snapshot. The **line identities** close the other
        gap — asking an order for its three totals is satisfiable without any
        line agreeing with them, which is exactly how an order-level figure that
        never reached the lines stayed invisible on the purchasing side.

        Every per-line expectation is the oracle's own (the unit price it
        derived from the catalog, the quantity it asked for, the allocation its
        own discount engine made, the cost it predicted from the purchase
        ledger); nothing is read back from the order to decide what to expect.
        """
        lines = {line.pk: line for line in order.lines.all()}
        if len(lines) != len(rec.lines):
            # A backend line the oracle never asked for is as wrong as a missing
            # one, and looking each row up by id below would not notice it.
            self.fail(
                f"order#{rec.order_id} line count: backend={len(lines)} "
                f"oracle={len(rec.lines)}"
            )
        for expected in rec.lines:
            line = lines[expected.order_line_id]
            tag = f"order#{order.pk} line#{line.pk}"
            self.assert_money(line.unit_price, expected.unit_price, f"{tag} unit_price")
            self.assert_qty(line.quantity, expected.quantity, f"{tag} quantity")
            self.assert_equal(
                Decimal(line.unit_factor),
                Decimal(expected.unit_factor),
                f"{tag} unit_factor",
            )
            self.assert_money(
                line.discount_total, expected.discount_total, f"{tag} discount_total"
            )
            # base_quantity is what stock was actually moved in; a line that
            # prices in cartons and decrements in pieces has to agree here.
            self.assert_qty(
                line.base_quantity,
                q3(expected.quantity * expected.unit_factor),
                f"{tag} base_quantity",
            )
            self.assert_money(
                line.line_subtotal, expected.line_subtotal, f"{tag} line_subtotal"
            )
            self.assert_money(line.unit_cost, expected.unit_cost, f"{tag} unit_cost")
            self.assert_money(line.line_total, expected.line_total, f"{tag} line_total")
            if line.discount_total > line.line_subtotal:
                # A line worth less than nothing. The refund path credits
                # ``line_total`` for a whole-line return, and
                # ``adjustment_amount`` refuses a non-positive refund outright —
                # so an over-discounted line does not merely misreport, it makes
                # the goods unreturnable.
                self.fail(
                    f"{tag} discount {line.discount_total} exceeds its own "
                    f"subtotal {line.line_subtotal} (line_total "
                    f"{line.line_total})"
                )
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
        subtotal_sum = even2(sum((line.line_subtotal for line in lines.values()), ZERO))
        discount_sum = even2(sum((line.discount_total for line in lines.values()), ZERO))
        # ``Order.recalculate`` clamps the discount to the subtotal
        # (apps/sales/models.py). That clamp is defensive only: a line can never
        # be handed more discount than it is worth, because
        # ``apps.sales.services.order_line_discounts`` caps each line at the
        # subtotal it stores before the line is written. So the clamp must never
        # fire, and an order that needs it is itself the defect — it used to be
        # the one way a line landed at ``line_total = -0.01`` and became
        # unreturnable. Asserting the clamp away rather than mirroring it is the
        # point: mirroring it is what hid this for as long as it did.
        if discount_sum > subtotal_sum:
            self.fail(
                f"order#{order.pk} is over-discounted: lines discount "
                f"{discount_sum} against subtotal {subtotal_sum} — "
                "Order.recalculate's clamp would forgive the excess while the "
                "lines keep it"
            )
        clamped_discount = discount_sum
        # Identity 1: the lines' revenue is the order's revenue.
        self.assert_money(
            subtotal_sum,
            order.subtotal,
            f"identity: order#{order.pk} line subtotals sum to subtotal",
        )
        # Identity 2: the lines' discounts are the order's discount. This is the
        # one an order-level figure that never reached the lines would fail.
        self.assert_money(
            clamped_discount,
            order.discount_total,
            f"identity: order#{order.pk} line discounts sum to discount_total",
        )
        # Identity 3: what the lines are worth is what the order charges.
        self.assert_money(
            even2(subtotal_sum - clamped_discount),
            order.total,
            f"identity: order#{order.pk} subtotal less discount is total",
        )
        # The lines' own net value must land on the total. This used to be
        # conditional on the order not being over-discounted; with the cap in
        # place that state is unreachable, so the condition is gone and the
        # identity holds for every order.
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

    def _assert_supplier_ap(self, supplier_id: int):
        """Accounts payable to one supplier, checked against both of the
        backend's implementations.

        ``Supplier.payable_balance`` computes it per supplier, while
        ``prime_supplier_balances`` recomputes the same figure in bulk SQL for
        list pages and reports — two ports of one number that can drift apart.
        The expectation is the oracle's own: the sum of what each of this
        supplier's orders can still be invoiced for, less what has been paid
        against it.
        """
        expected = even2(
            sum(
                (
                    rec.po_balance_due
                    for rec in self.oracle.pos.values()
                    if rec.supplier_id == supplier_id
                ),
                ZERO,
            )
        )
        cold = Supplier.objects.get(pk=supplier_id)
        self.assert_money(
            cold.payable_balance, expected, f"supplier#{supplier_id} payable"
        )
        primed = prime_supplier_balances([Supplier.objects.get(pk=supplier_id)])[0]
        self.assert_money(
            primed.payable_balance,
            expected,
            f"supplier#{supplier_id} payable (primed)",
        )

    def _assert_po(self, po_id: int, expected_status=None):
        rec = self.oracle.pos[po_id]
        po = PurchaseOrder.objects.get(pk=po_id)
        self.assert_money(po.total, rec.total, f"po#{po_id} total")
        self.assert_money(po.paid_total, rec.paid, f"po#{po_id} paid_total")
        # A short shipment must stop billing for what never came: the units a
        # receipt cancelled can never arrive and can never be returned either
        # (only accepted units are adjustable), so an order that keeps them on
        # its balance leaves a payable nothing can ever clear.
        self.assert_money(
            po.cancelled_total, rec.cancelled_value, f"po#{po_id} cancelled_total"
        )
        self.assert_money(po.billable_total, rec.billable, f"po#{po_id} billable_total")
        self.assert_money(
            po.balance_due, rec.po_balance_due, f"po#{po_id} balance_due"
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
            # The pack the line was bought in, and the two figures that cross
            # out of it. ``base_quantity`` is what the order reserves and the
            # receipt moves; ``base_unit_cost`` is what a sale of this variant
            # snapshots as its COGS. Both are identities at factor 1, which is
            # every purchase this simulation used to make.
            self.assert_equal(line.unit, expected.unit_code, f"{tag} unit")
            self.assert_equal(
                Decimal(line.unit_factor),
                Decimal(expected.unit_factor),
                f"{tag} unit_factor",
            )
            self.assert_qty(
                line.to_base_quantity(line.quantity),
                expected.base_quantity,
                f"{tag} base_quantity",
            )
            self.assert_money(
                line.base_unit_cost, expected.base_unit_cost, f"{tag} base_unit_cost"
            )
            self.assert_money(
                line.effective_base_unit_cost,
                expected.effective_base_unit_cost,
                f"{tag} effective_base_unit_cost",
            )
            if expected.unit_factor != Decimal("1"):
                self.pack_purchase_line_assertions += 1
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
                    f"summary#{session_id} failed: {response.status_code} {response_body(response)}"
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

    def reconcile_reports(self):
        """The shop-wide P&L the owner reads must be the shop's own documents.

        Every per-order figure is already proved line by line, but nothing
        reached the *aggregations* — and an aggregate is its own implementation.
        The reports layer answers "what did the shop sell, and what did it make"
        with SQL over the whole period, and the dashboard answers it again; a
        figure can be right on all 200 invoices and wrong the moment they are
        added up, which is precisely how the purchasing side's payable stayed
        broken across five read paths (see .ai/oracle.md).

        Every expectation below is built from the oracle's own records — the
        totals it derived when each sale was rung up, the refunds it computed,
        the per-line costs it predicted from the purchase ledger. Nothing is
        read back from an order, an adjustment or another endpoint to decide
        what to expect, and in particular the report is never compared against
        the dashboard: two backend surfaces agreeing says nothing about either
        being right.

        The one thing borrowed from production is the *scope* — which orders
        count as transactional. That is a definition, not an answer.
        """
        txn = [
            rec
            for rec in self.oracle.orders.values()
            if rec.sale_type != Order.SaleType.QUOTATION
            and (
                rec.status in (Order.Status.PAID, Order.Status.VOID)
                or (
                    rec.sale_type == Order.SaleType.CREDIT
                    and rec.status == Order.Status.OPEN
                )
            )
        ]
        gross_sales = even2(sum((rec.subtotal for rec in txn), ZERO))
        discount_total = even2(sum((rec.discount_total for rec in txn), ZERO))
        # Revenue is the documents': what the customers were actually charged.
        revenue = even2(sum((rec.total for rec in txn), ZERO))
        refund_total = even2(sum((r.total for r in self.oracle.refunds), ZERO))
        net_sales = even2(revenue - refund_total)
        # Cost of goods sold and cost of goods handed back are summed raw and
        # rounded once — the same convention on both sides, so the cost a sale
        # takes out of profit is exactly the cost its return puts back. Both
        # are the oracle's own per-line costs times the quantities it asked for.
        sold_cost = even2(
            sum(
                (line.unit_cost * line.quantity for rec in txn for line in rec.lines),
                ZERO,
            )
        )
        returned_cost = even2(
            sum(
                (
                    line.unit_cost * Decimal(qty)
                    for refund in self.oracle.refunds
                    for line, qty, _ in refund.lines
                ),
                ZERO,
            )
        )
        gross_profit = even2(revenue - sold_cost - refund_total + returned_cost)

        summary = self._report_summary("sales_summary")
        self.assert_money(summary["gross_sales"], gross_sales, "report gross_sales")
        self.assert_money(
            summary["discount_total"], discount_total, "report discount_total"
        )
        self.assert_money(summary["refund_total"], refund_total, "report refund_total")
        self.assert_money(summary["net_sales"], net_sales, "report net_sales")
        self.assert_money(summary["gross_profit"], gross_profit, "report gross_profit")
        self.assert_equal(
            summary["paid_order_count"],
            sum(1 for rec in txn if rec.status == Order.Status.PAID),
            "report paid_order_count",
        )
        self.assert_equal(
            summary["voided_order_count"],
            sum(1 for rec in txn if rec.status == Order.Status.VOID),
            "report voided_order_count",
        )
        # Units the shop actually sold. Stated gross this sat next to a
        # ``net_sales`` of 0.00 on the very same summary after a sale was
        # voided: nothing sold, five items sold.
        self.assert_qty(
            summary["items_sold"],
            sum((line.quantity for rec in txn for line in rec.lines), ZERO)
            - sum(
                (Decimal(qty) for refund in self.oracle.refunds for _, qty, _ in refund.lines),
                ZERO,
            ),
            "report items_sold",
        )
        # The second implementation of the same question, on its own endpoint.
        profit_costs = self._report_summary("profit_costs")
        self.assert_money(
            profit_costs["gross_profit"], gross_profit, "profit_costs gross_profit"
        )
        self.assert_money(
            profit_costs["purchase_spend_total"],
            even2(sum((po.total for po in self.oracle.pos.values()), ZERO)),
            "profit_costs purchase_spend_total",
        )

        # Conservation, stated without reference to any rounding convention:
        # an order that was handed back in full took exactly as much revenue and
        # exactly as much cost back out as it ever put in, so its contribution
        # to reported profit is exactly nothing. This is the property the
        # aggregate figures above are only *evidence* for, and it is the one a
        # shop would notice — profit left behind on goods it no longer sold.
        refunds_by_order = defaultdict(list)
        for refund in self.oracle.refunds:
            refunds_by_order[refund.order_id].append(refund)
        for rec in txn:
            if not rec.voided:
                continue
            docs = refunds_by_order.get(rec.order_id, [])
            # Restricted to an order taken back whole in ONE document — every
            # void, and a return that happens to close the order in one go.
            # Split back over several documents the identity does NOT hold, and
            # that is deliberate, not an oversight: each part rounds its own
            # gross, so 0.5 + 0.5 of a line at 3.33 credits 3.32 (recorded in
            # .ai/oracle.md). Asserting it there would report a defect the
            # backend does not have.
            if len(docs) != 1:
                continue
            refund = docs[0]
            if len(refund.lines) != len(rec.lines):
                continue
            if any(Decimal(qty) != line.quantity for line, qty, _ in refund.lines):
                continue
            cost_back = even2(
                sum(
                    (line.unit_cost * Decimal(qty) for line, qty, _ in refund.lines),
                    ZERO,
                )
            )
            own_cost = even2(
                sum((line.unit_cost * line.quantity for line in rec.lines), ZERO)
            )
            self.assert_money(
                even2(rec.total - own_cost - refund.total + cost_back),
                ZERO,
                f"identity: order#{rec.order_id} was undone in full but still "
                "contributes profit",
            )
            self.undone_orders_reconciled += 1
            if self._rounding_sensitive(rec):
                # Without a line whose gross or cost carries more precision than
                # the cent it stores, the identity holds under every
                # implementation and proves nothing.
                self.rounding_sensitive_undone_orders += 1

    def reconcile_product_rankings(self):
        """What the shop reorders, ranked — and it must be what the shop kept.

        ``reconcile_reports`` proved the shop-wide P&L, but the same order lines
        are also rolled up per product and per variant into six rankings on the
        dashboard and one section of the sales report, and those rollups looked
        only at what was rung up. A sale that was voided, and goods that were
        handed back, still counted in full: a wholly voided sale ranked as the
        shop's best seller directly beneath a ``net_sales`` of 0.00.

        Every expectation here is built from the oracle's own records — the
        per-line price, quantity, discount and cost it derived when each sale
        was rung up, and the quantities and refund discounts it computed for
        each return. Nothing is read back from an order line, an adjustment
        line or the other endpoint to decide what to expect, and the report and
        the dashboard are never compared to each other: they are two
        implementations of one answer, and two implementations agreeing says
        nothing about either being right.

        Borrowed from production, deliberately: the *scope* (which orders count
        as transactional, and that the netting is against the same period's own
        refund documents) and the *ordering rule* (value descending, ties by
        name). Both are definitions, not answers.
        """
        txn = [
            rec
            for rec in self.oracle.orders.values()
            if rec.sale_type != Order.SaleType.QUOTATION
            and (
                rec.status in (Order.Status.PAID, Order.Status.VOID)
                or (
                    rec.sale_type == Order.SaleType.CREDIT
                    and rec.status == Order.Status.OPEN
                )
            )
        ]
        product_of = {item.variant_id: item.product_id for item in self.items}
        # The labour SKU is a real product on real orders but is not one of the
        # catalog items this world builds — production creates it on demand — so
        # the ranking has to know it or every job invoice trips this map.
        product_of[self.labor_variant.pk] = self.labor_variant.product_id
        name_of = {
            item.product_id: item.variant.product.name for item in self.items
        }
        name_of[self.labor_variant.product_id] = self.labor_variant.product.name
        variant_name_of = {item.variant_id: item.variant.name for item in self.items}
        variant_name_of[self.labor_variant.pk] = self.labor_variant.name

        def blank():
            return {"quantity": ZERO, "revenue": ZERO, "profit": ZERO, "returned": False}

        by_product = defaultdict(blank)
        by_variant = defaultdict(blank)
        # The sold side: raw per-line products, summed. Rounded once at the very
        # end, which is the convention the cost figures already share — so a
        # line handed back in full cancels its own sale term for term instead of
        # leaving a rounding residue behind on the ranking.
        for rec in txn:
            for line in rec.lines:
                revenue = line.unit_price * line.quantity - line.discount_total
                profit = (
                    line.quantity * (line.unit_price - line.unit_cost)
                    - line.discount_total
                )
                for bucket in (
                    by_product[product_of[line.variant_id]],
                    by_variant[line.variant_id],
                ):
                    bucket["quantity"] += line.quantity
                    bucket["revenue"] += revenue
                    bucket["profit"] += profit
        # ...and the returned side, stated the same way over the quantities and
        # refund discounts the oracle itself asked each return document for.
        for refund in self.oracle.refunds:
            for line, qty, refund_discount in refund.lines:
                qty = Decimal(qty)
                revenue = line.unit_price * qty - refund_discount
                profit = qty * (line.unit_price - line.unit_cost) - refund_discount
                for bucket in (
                    by_product[product_of[line.variant_id]],
                    by_variant[line.variant_id],
                ):
                    bucket["quantity"] -= qty
                    bucket["revenue"] -= revenue
                    bucket["profit"] -= profit
                    bucket["returned"] = True

        product_rows = [
            {
                "name": name_of[product_id],
                "sort_name": name_of[product_id],
                **bucket,
            }
            for product_id, bucket in by_product.items()
        ]
        variant_rows = [
            {
                "name": (
                    f"{name_of[product_of[variant_id]]} - {variant_name_of[variant_id]}"
                    if (variant_name_of[variant_id] or "").strip()
                    else name_of[product_of[variant_id]]
                ),
                "sort_name": (
                    name_of[product_of[variant_id]],
                    variant_name_of[variant_id] or "",
                ),
                **bucket,
            }
            for variant_id, bucket in by_variant.items()
        ]

        report_rows = self._report_section("sales_summary", "top_products")
        self._assert_ranking(
            report_rows, product_rows, order_by="revenue", limit=24,
            what="report top_products",
        )
        # The dashboard is a second, independently written implementation of the
        # same six rankings, so it is checked against the oracle too — never
        # against the report.
        reports = self._dashboard_sales_reports()
        for grain, rows in (("products", product_rows), ("variants", variant_rows)):
            for key, order_by in (
                ("top_sold", "quantity"),
                ("revenue", "revenue"),
                ("profit", "profit"),
            ):
                self._assert_ranking(
                    reports[grain][key], rows, order_by=order_by, limit=24,
                    what=f"dashboard {grain}.{key}",
                )

    def _assert_ranking(self, actual, expected_rows, *, order_by, limit, what):
        """Compare one ranking, row for row, against the oracle's own rows.

        Both the *selection* and the *order* are checked, not just the figures:
        the defect this exists to catch is a product that should have dropped
        down the ranking (or off it) once what came back was taken off, and a
        figures-only check on whatever rows the backend chose to return would
        never see it.
        """
        # Ranked on the figure the row displays, like the backend: ordering on
        # the raw sums would let a difference far below a cent decide which of
        # two rows showing the same money comes first.
        quantize = q3 if order_by == "quantity" else even2
        ranked = sorted(
            expected_rows,
            key=lambda row: (-quantize(row[order_by]), row["sort_name"]),
        )[:limit]
        self.assert_equal(
            [row["product_name"] for row in actual],
            [row["name"] for row in ranked],
            f"{what}: ranking",
        )
        for actual_row, expected in zip(actual, ranked):
            name = expected["name"]
            self.assert_qty(
                actual_row["quantity"], expected["quantity"], f"{what}: {name} units"
            )
            self.assert_money(
                actual_row["revenue"], expected["revenue"], f"{what}: {name} revenue"
            )
            self.assert_money(
                actual_row["profit"], expected["profit"], f"{what}: {name} profit"
            )
            self.ranking_rows_reconciled += 1
            if expected["returned"]:
                # Without a row something actually came back from, gross and net
                # are the same number and the assertion holds under the
                # implementation this exists to catch.
                self.returned_ranking_rows += 1

    def _report_section(self, report_type: str, key: str) -> list:
        payload = self._report_payload(report_type)
        for section in payload["sections"]:
            if section.get("key") == key:
                return section["rows"]
        self.fail(f"report {report_type} has no {key} section")

    def _dashboard_sales_reports(self) -> dict:
        """The dashboard's own six rankings, through its own endpoint.

        Sections are cached for 30s under a key that names neither the database
        nor the test, so a sibling simulation run in the same process would
        otherwise be served this one's payload.
        """
        from django.core.cache import cache

        cache.clear()
        response = self.client.get("/api/dashboard/", {"sections": "sales"})
        if response.status_code != 200:
            self.fail(f"dashboard failed: {response.status_code} {response_body(response)}")
        return response.data["sections"]["sales"]["reports"]

    def _report_summary(self, report_type: str) -> dict:
        return self._report_payload(report_type)["summary"]

    def _report_payload(self, report_type: str) -> dict:
        """Run a production report through its own endpoint and hand back its
        payload. Deliberately the API and not the service function: the report a
        shop reads is the one that came through here."""
        today = timezone.localdate()
        response = self.client.post(
            "/api/reports/",
            {
                "report_type": report_type,
                "params": {
                    "start_date": (today - timedelta(days=1)).isoformat(),
                    "end_date": (today + timedelta(days=1)).isoformat(),
                },
                "output_format": "json",
            },
            format="json",
        )
        if response.status_code != 201:
            self.fail(
                f"report {report_type} failed: {response.status_code} {response_body(response)}"
            )
        return response.data["payload"]

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
    per_line, total, _ = engine.calculate([_line(0, 1, 2, "10.00"), _line(1, 2, 1, "20.00")])
    check("A.total", total, Decimal("4.00"))
    check("A.lines", per_line, {"0": Decimal("2.00"), "1": Decimal("2.00")})

    # (C) document percentage 10, three lines, indivisible cent -> largest key.
    engine = OracleDiscountEngine([_doc_rule(1, VT.PERCENTAGE, "10")])
    per_line, total, _ = engine.calculate(
        [_line(0, 1, 1, "3.34"), _line(1, 2, 1, "3.34"), _line(2, 3, 1, "3.34")]
    )
    check("C.total", total, Decimal("1.00"))
    check("C.lines", per_line, {"0": Decimal("0.34"), "1": Decimal("0.33"), "2": Decimal("0.33")})

    # (D) line fixed_unit_amount 1.50, min_line_quantity 2, product-targeted.
    engine = OracleDiscountEngine(
        [_doc_rule(1, VT.FIXED_UNIT_AMOUNT, "1.50", scope=SC.LINE,
                   min_line_quantity=2, product_ids=frozenset({1}))]
    )
    per_line, total, _ = engine.calculate([_line(0, 1, 2, "10.00"), _line(1, 2, 1, "10.00")])
    check("D.total", total, Decimal("3.00"))
    check("D.lines", per_line, {"0": Decimal("3.00")})

    # (E) line fixed_price 7.50, product-targeted.
    engine = OracleDiscountEngine(
        [_doc_rule(1, VT.FIXED_PRICE, "7.50", scope=SC.LINE, product_ids=frozenset({1}))]
    )
    per_line, total, _ = engine.calculate([_line(0, 1, 2, "10.00")])
    check("E.total", total, Decimal("5.00"))

    # (G) coupon fixed_amount only applies with the code.
    engine = OracleDiscountEngine(
        [_doc_rule(1, VT.FIXED_AMOUNT, "5", application_type=AT.COUPON_CODE, coupon_code="SAVE5")]
    )
    _, total_without, _ = engine.calculate([_line(0, 1, 4, "10.00")])
    check("G.without", total_without, Decimal("0.00"))
    _, total_with, _ = engine.calculate([_line(0, 1, 4, "10.00")], coupon_codes=("save5",))
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
    per_line, total, _ = engine.calculate([_line(0, 1, 2, "10.00")])
    check("H.total", total, Decimal("20.00"))
    check("H.lines", per_line, {"0": Decimal("20.00")})

    # (B) document percentage 50 with min subtotal + max cap, indivisible cent.
    engine = OracleDiscountEngine(
        [_doc_rule(1, VT.PERCENTAGE, "50", min_order_subtotal=Decimal("40.00"),
                   max_discount_amount=Decimal("3.33"))]
    )
    per_line, total, _ = engine.calculate([_line(0, 1, 1, "20.00"), _line(1, 2, 1, "20.00")])
    check("B.total", total, Decimal("3.33"))
    check("B.lines", per_line, {"0": Decimal("1.67"), "1": Decimal("1.66")})
    # below threshold -> nothing
    _, total_low, _ = engine.calculate([_line(0, 1, 1, "19.99"), _line(1, 2, 1, "19.99")])
    check("B.below", total_low, Decimal("0.00"))

    # (J) automatic percentage then non-exclusive coupon, stacked on remaining.
    engine = OracleDiscountEngine(
        [
            _doc_rule(1, VT.PERCENTAGE, "10", priority=1),
            _doc_rule(2, VT.FIXED_AMOUNT, "2", application_type=AT.COUPON_CODE,
                      coupon_code="SAVE2", priority=2),
        ]
    )
    _, total, _ = engine.calculate([_line(0, 1, 2, "12.00")], coupon_codes=("SAVE2",))
    check("J.total", total, Decimal("4.40"))

    # (K) which coupons actually applied. The checkout API refuses a sale whose
    # coupon contributed nothing (``unapplied_coupon_codes``), so the port has to
    # predict that too: an exclusive automatic rule ahead of the coupon leaves
    # the coupon eligible but unapplied, and the code must NOT be reported.
    engine = OracleDiscountEngine(
        [
            _doc_rule(1, VT.PERCENTAGE, "50", priority=1, exclusive=True),
            _doc_rule(2, VT.FIXED_AMOUNT, "2", application_type=AT.COUPON_CODE,
                      coupon_code="SAVE2", priority=2),
        ]
    )
    _, total, applied = engine.calculate(
        [_line(0, 1, 1, "20.00")], coupon_codes=("save2",)
    )
    check("K.total", total, Decimal("10.00"))
    check("K.applied", applied, set())
    # …and when nothing pre-empts it, the (case-normalized) code is reported.
    engine = OracleDiscountEngine(
        [_doc_rule(1, VT.FIXED_AMOUNT, "2", application_type=AT.COUPON_CODE,
                   coupon_code="SAVE2")]
    )
    _, total, applied = engine.calculate(
        [_line(0, 1, 1, "20.00")], coupon_codes=("save2",)
    )
    check("K.applied.total", total, Decimal("2.00"))
    check("K.applied.codes", applied, {"SAVE2"})

    # exclusivity short-circuits a lower-priority rule.
    engine = OracleDiscountEngine(
        [
            _doc_rule(1, VT.PERCENTAGE, "50", priority=1, exclusive=True),
            _doc_rule(2, VT.PERCENTAGE, "10", priority=2, exclusive=False),
        ]
    )
    _, total, _ = engine.calculate([_line(0, 1, 1, "20.00")])
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


