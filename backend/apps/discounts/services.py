from __future__ import annotations

from dataclasses import dataclass, field
from datetime import datetime
from decimal import Decimal, ROUND_DOWN, ROUND_HALF_UP
from typing import Iterable

from django.contrib.contenttypes.models import ContentType
from django.db import transaction
from django.db.models import Q
from django.utils import timezone

from .models import AppliedDiscount, DiscountRedemption, DiscountRule, normalize_coupon_code


MONEY_PLACES = Decimal("0.01")


def money(value: Decimal) -> Decimal:
    return Decimal(value).quantize(MONEY_PLACES, rounding=ROUND_HALF_UP)


@dataclass(frozen=True, slots=True)
class DiscountLineInput:
    key: str
    product_id: int | None
    quantity: int
    unit_amount: Decimal
    category_ids: tuple[int | str, ...] = ()
    metadata: dict = field(default_factory=dict)

    @property
    def subtotal(self) -> Decimal:
        return money(self.unit_amount * Decimal(self.quantity))


@dataclass(frozen=True, slots=True)
class DiscountContext:
    channel: str
    lines: tuple[DiscountLineInput, ...]
    customer_id: int | None = None
    supplier_id: int | None = None
    coupon_codes: tuple[str, ...] = ()
    location_id: int | str | None = None
    now: datetime | None = None

    @property
    def normalized_coupon_codes(self) -> tuple[str, ...]:
        codes = [normalize_coupon_code(code) for code in self.coupon_codes]
        return tuple(code for code in codes if code)

    @property
    def subtotal(self) -> Decimal:
        return money(sum((line.subtotal for line in self.lines), Decimal("0.00")))


@dataclass(frozen=True, slots=True)
class DiscountAllocation:
    line_key: str
    amount: Decimal

    def as_dict(self) -> dict:
        return {"line_key": self.line_key, "amount": str(money(self.amount))}


@dataclass(frozen=True, slots=True)
class DiscountApplication:
    rule_id: int
    rule_name: str
    coupon_code: str
    source: str
    scope: str
    value_type: str
    value: Decimal
    priority: int
    exclusive: bool
    source_subtotal: Decimal
    amount: Decimal
    allocations: tuple[DiscountAllocation, ...]

    def allocation_dicts(self) -> list[dict]:
        return [allocation.as_dict() for allocation in self.allocations]


@dataclass(frozen=True, slots=True)
class DiscountCalculationResult:
    channel: str
    customer_id: int | None
    supplier_id: int | None
    subtotal: Decimal
    discount_total: Decimal
    total: Decimal
    applications: tuple[DiscountApplication, ...]


class DiscountUsageLimitExceeded(Exception):
    def __init__(self, applications: Iterable[DiscountApplication]):
        self.applications = tuple(applications)
        self.coupon_codes = tuple(
            application.coupon_code
            for application in self.applications
            if application.coupon_code
        )
        super().__init__("Discount usage limit exceeded.")


def discount_rule_usage_available(
    rule: DiscountRule,
    *,
    customer_id: int | None = None,
    supplier_id: int | None = None,
) -> bool:
    if (
        rule.usage_limit is not None
        and rule.redemptions.count() >= rule.usage_limit
    ):
        return False
    if (
        rule.per_customer_usage_limit is not None
        and customer_id is not None
        and rule.redemptions.filter(customer_id=customer_id).count()
        >= rule.per_customer_usage_limit
    ):
        return False
    if (
        rule.per_supplier_usage_limit is not None
        and supplier_id is not None
        and rule.redemptions.filter(supplier_id=supplier_id).count()
        >= rule.per_supplier_usage_limit
    ):
        return False
    return True


class DiscountEngine:
    def calculate(self, context: DiscountContext) -> DiscountCalculationResult:
        subtotal = context.subtotal
        remaining_by_line = {line.key: line.subtotal for line in context.lines}
        applications: list[DiscountApplication] = []

        for rule in self.eligible_rules(context):
            if rule.exclusive and applications:
                continue
            application = self._calculate_rule_application(
                rule,
                context,
                remaining_by_line,
            )
            if application is None or application.amount <= Decimal("0.00"):
                continue

            applications.append(application)
            for allocation in application.allocations:
                remaining_by_line[allocation.line_key] = money(
                    remaining_by_line[allocation.line_key] - allocation.amount
                )
            if rule.exclusive:
                break

        discount_total = money(
            sum((application.amount for application in applications), Decimal("0.00"))
        )
        return DiscountCalculationResult(
            channel=context.channel,
            customer_id=context.customer_id,
            supplier_id=context.supplier_id,
            subtotal=subtotal,
            discount_total=discount_total,
            total=money(subtotal - discount_total),
            applications=tuple(applications),
        )

    def eligible_rules(self, context: DiscountContext) -> list[DiscountRule]:
        now = context.now or timezone.now()
        coupon_codes = context.normalized_coupon_codes
        application_filter = Q(application_type=DiscountRule.ApplicationType.AUTOMATIC)
        if coupon_codes:
            application_filter |= Q(
                application_type=DiscountRule.ApplicationType.COUPON_CODE,
                coupon_code__in=coupon_codes,
            )

        rules = (
            DiscountRule.objects.filter(is_active=True)
            .filter(Q(channel=context.channel) | Q(channel=DiscountRule.Channel.BOTH))
            .filter(Q(starts_at__isnull=True) | Q(starts_at__lte=now))
            .filter(Q(ends_at__isnull=True) | Q(ends_at__gt=now))
            .filter(application_filter)
            .prefetch_related("products", "customers", "suppliers")
            .order_by("priority", "id")
        )
        return [rule for rule in rules if self._context_matches_rule(rule, context)]

    def _context_matches_rule(self, rule: DiscountRule, context: DiscountContext) -> bool:
        if context.subtotal < rule.min_order_subtotal:
            return False
        if not discount_rule_usage_available(
            rule,
            customer_id=context.customer_id,
            supplier_id=context.supplier_id,
        ):
            return False

        allowed_customer_ids = {customer.pk for customer in rule.customers.all()}
        if allowed_customer_ids and context.customer_id not in allowed_customer_ids:
            return False

        allowed_supplier_ids = {supplier.pk for supplier in rule.suppliers.all()}
        if allowed_supplier_ids and context.supplier_id not in allowed_supplier_ids:
            return False

        return bool(self._matching_lines(rule, context.lines))

    def _matching_lines(
        self,
        rule: DiscountRule,
        lines: Iterable[DiscountLineInput],
    ) -> list[DiscountLineInput]:
        allowed_product_ids = {product.pk for product in rule.products.all()}
        matching = []
        for line in lines:
            if allowed_product_ids and line.product_id not in allowed_product_ids:
                continue
            if rule.min_line_quantity is not None and line.quantity < rule.min_line_quantity:
                continue
            matching.append(line)
        return matching

    def _calculate_rule_application(
        self,
        rule: DiscountRule,
        context: DiscountContext,
        remaining_by_line: dict[str, Decimal],
    ) -> DiscountApplication | None:
        matching_lines = [
            line
            for line in self._matching_lines(rule, context.lines)
            if remaining_by_line[line.key] > Decimal("0.00")
        ]
        if not matching_lines:
            return None

        source_subtotal = money(
            sum((remaining_by_line[line.key] for line in matching_lines), Decimal("0.00"))
        )
        if source_subtotal <= Decimal("0.00"):
            return None

        allocations = self._rule_allocations(rule, matching_lines, remaining_by_line)
        amount = money(sum((allocation.amount for allocation in allocations), Decimal("0.00")))
        if rule.max_discount_amount is not None and amount > rule.max_discount_amount:
            allocations = allocate_discount_amount(
                money(rule.max_discount_amount),
                {allocation.line_key: allocation.amount for allocation in allocations},
            )
            amount = money(rule.max_discount_amount)

        return DiscountApplication(
            rule_id=rule.pk,
            rule_name=rule.name,
            coupon_code=rule.coupon_code,
            source=rule.application_type,
            scope=rule.scope,
            value_type=rule.value_type,
            value=rule.value,
            priority=rule.priority,
            exclusive=rule.exclusive,
            source_subtotal=source_subtotal,
            amount=amount,
            allocations=tuple(allocations),
        )

    def _rule_allocations(
        self,
        rule: DiscountRule,
        matching_lines: list[DiscountLineInput],
        remaining_by_line: dict[str, Decimal],
    ) -> tuple[DiscountAllocation, ...]:
        if rule.value_type == DiscountRule.ValueType.FIXED_UNIT_AMOUNT:
            return tuple(
                DiscountAllocation(
                    line_key=line.key,
                    amount=min(
                        money(rule.value * Decimal(line.quantity)),
                        remaining_by_line[line.key],
                    ),
                )
                for line in matching_lines
            )

        if rule.scope == DiscountRule.Scope.LINE:
            line_amounts = {}
            for line in matching_lines:
                if rule.value_type == DiscountRule.ValueType.PERCENTAGE:
                    amount = money(remaining_by_line[line.key] * rule.value / Decimal("100"))
                elif rule.value_type == DiscountRule.ValueType.FIXED_PRICE:
                    fixed_total = money(rule.value * Decimal(line.quantity))
                    amount = max(
                        money(remaining_by_line[line.key] - fixed_total),
                        Decimal("0.00"),
                    )
                else:
                    amount = min(money(rule.value), remaining_by_line[line.key])
                line_amounts[line.key] = amount
            return tuple(
                DiscountAllocation(line_key=key, amount=amount)
                for key, amount in line_amounts.items()
                if amount > Decimal("0.00")
            )

        source_subtotal = money(
            sum((remaining_by_line[line.key] for line in matching_lines), Decimal("0.00"))
        )
        if rule.value_type == DiscountRule.ValueType.PERCENTAGE:
            amount = money(source_subtotal * rule.value / Decimal("100"))
        elif rule.value_type == DiscountRule.ValueType.FIXED_PRICE:
            amount = Decimal("0.00")
        else:
            amount = min(money(rule.value), source_subtotal)
        return tuple(
            allocate_discount_amount(
                amount,
                {line.key: remaining_by_line[line.key] for line in matching_lines},
            )
        )


def allocate_discount_amount(
    amount: Decimal,
    weights_by_key: dict[str, Decimal],
) -> tuple[DiscountAllocation, ...]:
    amount = money(amount)
    if amount <= Decimal("0.00"):
        return ()

    positive_weights = {
        key: weight
        for key, weight in weights_by_key.items()
        if weight > Decimal("0.00")
    }
    total_weight = sum(positive_weights.values(), Decimal("0.00"))
    if total_weight <= Decimal("0.00"):
        return ()

    allocations: dict[str, Decimal] = {}
    remainders = []
    allocated_total = Decimal("0.00")
    for key, weight in positive_weights.items():
        exact_share = amount * weight / total_weight
        rounded_share = exact_share.quantize(MONEY_PLACES, rounding=ROUND_DOWN)
        allocations[key] = rounded_share
        allocated_total += rounded_share
        remainders.append((exact_share - rounded_share, key))

    remaining_cents = int(
        ((amount - allocated_total) * Decimal("100")).to_integral_value()
    )
    remainders.sort(key=lambda item: (-item[0], str(item[1])))
    for _, key in remainders[:remaining_cents]:
        allocations[key] += MONEY_PLACES

    return tuple(
        DiscountAllocation(line_key=key, amount=allocations[key])
        for key in weights_by_key
        if allocations.get(key, Decimal("0.00")) > Decimal("0.00")
    )


@transaction.atomic
def persist_applied_discounts(
    *,
    document,
    result: DiscountCalculationResult,
    line_objects_by_key: dict[str, object] | None = None,
) -> list[AppliedDiscount]:
    document_content_type = ContentType.objects.get_for_model(
        document,
        for_concrete_model=False,
    )
    line_objects_by_key = line_objects_by_key or {}
    applied_discounts = []
    lock_and_validate_usage_limits(result)

    for application in result.applications:
        line = None
        if len(application.allocations) == 1:
            line = line_objects_by_key.get(application.allocations[0].line_key)

        line_content_type = None
        line_object_id = None
        if line is not None:
            line_content_type = ContentType.objects.get_for_model(
                line,
                for_concrete_model=False,
            )
            line_object_id = line.pk

        applied_discount = AppliedDiscount.objects.create(
            rule_id=application.rule_id,
            rule_name=application.rule_name,
            coupon_code=application.coupon_code,
            source=application.source,
            channel=result.channel,
            scope=application.scope,
            value_type=application.value_type,
            value=application.value,
            priority=application.priority,
            exclusive=application.exclusive,
            source_subtotal=application.source_subtotal,
            discount_amount=application.amount,
            document_content_type=document_content_type,
            document_object_id=document.pk,
            line_content_type=line_content_type,
            line_object_id=line_object_id,
            allocations=allocation_dicts(application, line_objects_by_key),
        )
        DiscountRedemption.objects.create(
            rule_id=application.rule_id,
            applied_discount=applied_discount,
            coupon_code=application.coupon_code,
            channel=result.channel,
            customer_id=result.customer_id,
            supplier_id=result.supplier_id,
            discount_amount=application.amount,
            document_content_type=document_content_type,
            document_object_id=document.pk,
        )
        applied_discounts.append(applied_discount)

    return applied_discounts


def lock_and_validate_usage_limits(result: DiscountCalculationResult) -> None:
    rule_ids = sorted({application.rule_id for application in result.applications})
    if not rule_ids:
        return

    rules_by_id = {
        rule.pk: rule
        for rule in DiscountRule.objects.select_for_update().filter(pk__in=rule_ids)
    }
    exhausted = []
    for application in result.applications:
        rule = rules_by_id.get(application.rule_id)
        if rule is None:
            continue
        if not discount_rule_usage_available(
            rule,
            customer_id=result.customer_id,
            supplier_id=result.supplier_id,
        ):
            exhausted.append(application)
    if exhausted:
        raise DiscountUsageLimitExceeded(exhausted)


def allocation_dicts(
    application: DiscountApplication,
    line_objects_by_key: dict[str, object],
) -> list[dict]:
    allocations = []
    for allocation in application.allocations:
        data = allocation.as_dict()
        line = line_objects_by_key.get(allocation.line_key)
        if line is not None:
            data["line_object_id"] = line.pk
            product_id = getattr(line, "product_id", None)
            if product_id is not None:
                data["product_id"] = product_id
        allocations.append(data)
    return allocations
