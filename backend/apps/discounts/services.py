from __future__ import annotations

from dataclasses import dataclass, field
from datetime import datetime
from decimal import Decimal, ROUND_CEILING, ROUND_DOWN, ROUND_FLOOR, ROUND_HALF_UP
from typing import Iterable

from django.contrib.contenttypes.models import ContentType
from django.db import transaction
from django.db.models import Count, Q
from django.utils import timezone

from apps.catalog.models import ProductCategory
from .models import AppliedDiscount, DiscountRedemption, DiscountRule, normalize_coupon_code


MONEY_PLACES = Decimal("0.01")


def money(value: Decimal) -> Decimal:
    return Decimal(value).quantize(MONEY_PLACES, rounding=ROUND_HALF_UP)


@dataclass(frozen=True, slots=True)
class DiscountLineInput:
    key: str
    product_id: int | None
    # Sales pass a ``Decimal`` (weighed/kg lines can be fractional); purchasing
    # passes an ``int``. Pooled quantity promotions floor this to whole units.
    quantity: Decimal | int
    unit_amount: Decimal
    variant_id: int | None = None
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
    # The customer's RFM rank (``Customer.rfm_segment``). Optional: callers that
    # already know it can pass it to skip a lookup; otherwise the engine resolves
    # it on demand, but only when a candidate rule actually targets ranks.
    customer_rank: str | None = None

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
    unrounded_amount: Decimal | None = None
    rounding_mode: str = DiscountRule.RoundingMode.NONE
    rounding_increment: Decimal | None = None
    rounding_adjustment: Decimal = Decimal("0.00")

    def allocation_dicts(self) -> list[dict]:
        return [allocation.as_dict() for allocation in self.allocations]

    def metadata_dict(self) -> dict:
        if self.rounding_mode == DiscountRule.RoundingMode.NONE:
            return {}
        return {
            "rounding_mode": self.rounding_mode,
            "rounding_increment": str(money(self.rounding_increment or Decimal("0.00"))),
            "unrounded_discount_amount": str(
                money(self.unrounded_amount or self.amount)
            ),
            "rounding_adjustment": str(money(self.rounding_adjustment)),
        }


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
    # Counts live redemption rows rather than a denormalised counter on the
    # rule. That keeps the check correct when redemptions are removed (e.g. the
    # purchasing revise flow clears and re-applies a PO's discounts), which a
    # cached counter would silently drift away from.
    #
    # The eligibility pass (eligible_rules) folds these counts into the single
    # rules query as annotations (``_usage_redemptions`` etc.), so a basket with
    # 50 rules costs one query, not 50. When called from the locked persist path
    # the rule is re-fetched WITHOUT annotations under ``SELECT ... FOR UPDATE``,
    # so ``_redemption_count`` falls back to a live COUNT — the authoritative,
    # serialised view that actually enforces the limit.
    if (
        rule.usage_limit is not None
        and _redemption_count(rule, "_usage_redemptions") >= rule.usage_limit
    ):
        return False
    if (
        rule.per_customer_usage_limit is not None
        and customer_id is not None
        and _redemption_count(rule, "_customer_redemptions", customer_id=customer_id)
        >= rule.per_customer_usage_limit
    ):
        return False
    if (
        rule.per_supplier_usage_limit is not None
        and supplier_id is not None
        and _redemption_count(rule, "_supplier_redemptions", supplier_id=supplier_id)
        >= rule.per_supplier_usage_limit
    ):
        return False
    return True


def _redemption_count(rule: DiscountRule, cached_attr: str, **filter_kwargs) -> int:
    """Redemption count for the usage check, preferring a query annotation.

    ``eligible_rules`` annotates the count (scoped to the same customer/supplier
    it will be checked against). Absent the annotation — the locked persist path
    — this issues a live COUNT so the FOR UPDATE re-check stays exact.
    """
    cached = getattr(rule, cached_attr, None)
    if cached is not None:
        return cached
    queryset = rule.redemptions.filter(**filter_kwargs) if filter_kwargs else rule.redemptions
    return queryset.count()


def _usage_count_annotations(context: "DiscountContext") -> dict:
    """Filtered redemption-count annotations for the eligibility rules query.

    Only annotates the per-customer / per-supplier variants when the context
    actually carries that id, so ``_redemption_count`` reads a value scoped to
    the same id it checks the limit against.
    """
    annotations = {"_usage_redemptions": Count("redemptions", distinct=True)}
    if context.customer_id is not None:
        annotations["_customer_redemptions"] = Count(
            "redemptions",
            filter=Q(redemptions__customer_id=context.customer_id),
            distinct=True,
        )
    if context.supplier_id is not None:
        annotations["_supplier_redemptions"] = Count(
            "redemptions",
            filter=Q(redemptions__supplier_id=context.supplier_id),
            distinct=True,
        )
    return annotations


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
            .prefetch_related(
                "products",
                "variants",
                "product_categories",
                "customers",
                "suppliers",
                "tiers",
            )
            .order_by("priority", "id")
            .annotate(**_usage_count_annotations(context))
        )
        rules = list(rules)
        customer_rank = self._resolve_customer_rank(context, rules)
        return [
            rule
            for rule in rules
            if self._context_matches_rule(rule, context, customer_rank)
        ]

    def _resolve_customer_rank(
        self,
        context: DiscountContext,
        rules: list[DiscountRule],
    ) -> str | None:
        """The customer's RFM rank, fetched lazily and only when it matters.

        Returns the caller-supplied rank as-is when present. Otherwise we look it
        up from the customer — but skip the query entirely unless at least one
        candidate rule targets ranks, so rank targeting costs nothing on the
        common path where no rule uses it.
        """
        if context.customer_rank is not None:
            return context.customer_rank
        if context.customer_id is None:
            return None
        if not any(rule.customer_ranks for rule in rules):
            return None
        # Local import avoids a discounts → customers import cycle.
        from apps.customers.models import Customer

        return (
            Customer.objects.filter(pk=context.customer_id)
            .values_list("rfm_segment", flat=True)
            .first()
        )

    def _context_matches_rule(
        self,
        rule: DiscountRule,
        context: DiscountContext,
        customer_rank: str | None = None,
    ) -> bool:
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

        # Rank targeting: when a rule names ranks, the order's customer must sit
        # in one of them. ANDs with the explicit customer whitelist above.
        target_ranks = rule.customer_ranks or []
        if target_ranks and (
            customer_rank is None or customer_rank not in target_ranks
        ):
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
        allowed_variant_ids = {variant.pk for variant in rule.variants.all()}
        allowed_category_ids = self._category_ids_with_descendants(
            category.pk for category in rule.product_categories.all()
        )
        has_line_constraints = bool(
            allowed_product_ids or allowed_variant_ids or allowed_category_ids
        )
        matching = []
        for line in lines:
            line_category_ids = self._normalized_category_ids(line.category_ids)
            matches_product = line.product_id in allowed_product_ids
            matches_variant = line.variant_id in allowed_variant_ids
            matches_category = bool(allowed_category_ids & line_category_ids)
            if has_line_constraints and not (
                matches_product or matches_variant or matches_category
            ):
                continue
            if rule.min_line_quantity is not None and line.quantity < rule.min_line_quantity:
                continue
            matching.append(line)
        return matching

    def _normalized_category_ids(self, category_ids: Iterable[int | str]) -> set[int]:
        normalized_ids = set()
        for category_id in category_ids:
            try:
                normalized_ids.add(int(category_id))
            except (TypeError, ValueError):
                continue
        return normalized_ids

    def _category_ids_with_descendants(self, category_ids: Iterable[int]) -> set[int]:
        # Memoised per engine instance (one instance per calculate() call): the
        # same rule's categories are resolved twice — once to test eligibility,
        # once to allocate — and many rules share the same category set, so
        # without this the descendant recursion runs O(rules x depth) queries.
        cache = self.__dict__.setdefault("_descendant_cache", {})
        key = frozenset(category_ids)
        cached = cache.get(key)
        if cached is not None:
            return cached
        all_category_ids = set(key)
        pending_ids = set(all_category_ids)
        while pending_ids:
            child_ids = set(
                ProductCategory.objects.filter(parent_id__in=pending_ids).values_list(
                    "id",
                    flat=True,
                )
            )
            pending_ids = child_ids - all_category_ids
            all_category_ids.update(child_ids)
        cache[key] = all_category_ids
        return all_category_ids

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

        base_allocations = self._rule_allocations(rule, matching_lines, remaining_by_line)
        base_amount = money(
            sum((allocation.amount for allocation in base_allocations), Decimal("0.00"))
        )
        allocations = self._apply_rounding(
            rule,
            matching_lines,
            remaining_by_line,
            base_allocations,
            source_subtotal,
        )
        amount = money(sum((allocation.amount for allocation in allocations), Decimal("0.00")))
        rounding_adjustment = money(amount - base_amount)
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
            unrounded_amount=base_amount,
            rounding_mode=rule.rounding_mode,
            rounding_increment=rule.rounding_increment,
            rounding_adjustment=rounding_adjustment,
        )

    def _apply_rounding(
        self,
        rule: DiscountRule,
        matching_lines: list[DiscountLineInput],
        remaining_by_line: dict[str, Decimal],
        base_allocations: tuple[DiscountAllocation, ...],
        source_subtotal: Decimal,
    ) -> tuple[DiscountAllocation, ...]:
        if (
            rule.rounding_mode == DiscountRule.RoundingMode.NONE
            or rule.rounding_increment is None
        ):
            return base_allocations

        base_by_line = {
            allocation.line_key: allocation.amount
            for allocation in base_allocations
        }
        if rule.scope == DiscountRule.Scope.LINE:
            rounded_allocations = []
            for line in matching_lines:
                source_amount = remaining_by_line[line.key]
                discounted_amount = money(
                    source_amount - base_by_line.get(line.key, Decimal("0.00"))
                )
                rounded_amount = rounded_price(
                    discounted_amount,
                    rule.rounding_increment,
                    rule.rounding_mode,
                )
                target_discount = clamp_discount_amount(
                    money(source_amount - rounded_amount),
                    source_amount,
                )
                if target_discount > Decimal("0.00"):
                    rounded_allocations.append(
                        DiscountAllocation(
                            line_key=line.key,
                            amount=target_discount,
                        )
                    )
            return tuple(rounded_allocations)

        base_amount = money(
            sum((allocation.amount for allocation in base_allocations), Decimal("0.00"))
        )
        discounted_amount = money(source_subtotal - base_amount)
        rounded_amount = rounded_price(
            discounted_amount,
            rule.rounding_increment,
            rule.rounding_mode,
        )
        target_discount = clamp_discount_amount(
            money(source_subtotal - rounded_amount),
            source_subtotal,
        )
        return tuple(
            allocate_discount_amount(
                target_discount,
                {line.key: remaining_by_line[line.key] for line in matching_lines},
            )
        )

    def _rule_allocations(
        self,
        rule: DiscountRule,
        matching_lines: list[DiscountLineInput],
        remaining_by_line: dict[str, Decimal],
    ) -> tuple[DiscountAllocation, ...]:
        if rule.value_type in DiscountRule.POOLED_VALUE_TYPES:
            return self._pooled_allocations(rule, matching_lines, remaining_by_line)

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

    # -- Quantity-based ("pooled") promotions --------------------------------
    #
    # multi-buy, tiered, and buy-X-get-Y price a *pool* of whole units gathered
    # across every line the rule matches (mix-and-match), instead of the flat
    # per-line ``value`` math the classic types use. Only whole units take part —
    # a fractional remainder on a weighed line (e.g. 1.5 kg) never joins a group
    # and keeps its full price. All three are line-scoped (enforced in
    # ``DiscountRule.clean``) and reuse the per-line allocation/cap/rounding/
    # snapshot machinery downstream.

    def _pooled_allocations(
        self,
        rule: DiscountRule,
        matching_lines: list[DiscountLineInput],
        remaining_by_line: dict[str, Decimal],
    ) -> tuple[DiscountAllocation, ...]:
        if rule.value_type == DiscountRule.ValueType.MULTI_BUY:
            return self._multi_buy_allocations(rule, matching_lines, remaining_by_line)
        if rule.value_type == DiscountRule.ValueType.TIERED:
            return self._tiered_allocations(rule, matching_lines, remaining_by_line)
        if rule.value_type == DiscountRule.ValueType.BUY_X_GET_Y:
            return self._buy_x_get_y_allocations(
                rule, matching_lines, remaining_by_line
            )
        return ()

    def _pooled_units(
        self,
        matching_lines: list[DiscountLineInput],
        remaining_by_line: dict[str, Decimal],
    ) -> list[tuple[Decimal, str]]:
        """Whole units available to a pooled promotion, most-expensive first.

        Each entry is ``(unit_price, line_key)``. Lines with no remaining balance
        are skipped so a stacked pooled promo can't discount value an earlier
        rule already removed.
        """
        units: list[tuple[Decimal, str]] = []
        for line in matching_lines:
            if remaining_by_line.get(line.key, Decimal("0.00")) <= Decimal("0.00"):
                continue
            whole = int(line.quantity)
            if whole <= 0:
                continue
            price = money(line.unit_amount)
            units.extend((price, line.key) for _ in range(whole))
        units.sort(key=lambda unit: (-unit[0], unit[1]))
        return units

    def _allocate_capped(
        self,
        amount: Decimal,
        weights_by_key: dict[str, Decimal],
        remaining_by_line: dict[str, Decimal],
    ) -> tuple[DiscountAllocation, ...]:
        """Allocate ``amount`` across lines weighted by ``weights_by_key`` while
        capping each line at its remaining balance, so a pooled promo stacked on
        an already-discounted line can never over-discount it."""
        capped_weights = {
            key: min(weight, remaining_by_line.get(key, Decimal("0.00")))
            for key, weight in weights_by_key.items()
            if weight > Decimal("0.00")
        }
        available = money(sum(capped_weights.values(), Decimal("0.00")))
        amount = min(money(amount), available)
        if amount <= Decimal("0.00"):
            return ()
        return allocate_discount_amount(amount, capped_weights)

    def _multi_buy_allocations(
        self,
        rule: DiscountRule,
        matching_lines: list[DiscountLineInput],
        remaining_by_line: dict[str, Decimal],
    ) -> tuple[DiscountAllocation, ...]:
        """N units for a fixed group price (``value``). The most-expensive units
        form the priced groups — the customer-friendly reading of "N for M" — and
        the cheaper remainder stays at full price. Self-stacks: 2×N units in the
        pool make two priced groups."""
        group_size = rule.group_size or 0
        if group_size < 2:
            return ()
        units = self._pooled_units(matching_lines, remaining_by_line)
        groups = len(units) // group_size
        if groups <= 0:
            return ()
        grouped = units[: groups * group_size]
        normal = money(sum((price for price, _ in grouped), Decimal("0.00")))
        charged = money(rule.value * groups)
        discount = normal - charged
        if discount <= Decimal("0.00"):
            return ()
        weights: dict[str, Decimal] = {}
        for price, key in grouped:
            weights[key] = money(weights.get(key, Decimal("0.00")) + price)
        return self._allocate_capped(discount, weights, remaining_by_line)

    def _tiered_allocations(
        self,
        rule: DiscountRule,
        matching_lines: list[DiscountLineInput],
        remaining_by_line: dict[str, Decimal],
    ) -> tuple[DiscountAllocation, ...]:
        """Wholesale-style price breaks: once the pooled count of whole units
        reaches a tier's ``min_quantity`` every whole unit reprices to that tier's
        ``unit_price``. The highest satisfied tier wins; units already cheaper
        than the tier price are left untouched."""
        tiers = sorted(rule.tiers.all(), key=lambda tier: tier.min_quantity)
        if not tiers:
            return ()
        total_units = sum(max(int(line.quantity), 0) for line in matching_lines)
        applicable = None
        for tier in tiers:
            if total_units >= tier.min_quantity:
                applicable = tier
            else:
                break
        if applicable is None:
            return ()
        tier_price = money(applicable.unit_price)
        weights: dict[str, Decimal] = {}
        for line in matching_lines:
            whole = int(line.quantity)
            if whole <= 0:
                continue
            per_unit = money(line.unit_amount) - tier_price
            if per_unit <= Decimal("0.00"):
                continue
            weights[line.key] = money(per_unit * whole)
        if not weights:
            return ()
        total = money(sum(weights.values(), Decimal("0.00")))
        return self._allocate_capped(total, weights, remaining_by_line)

    def _buy_x_get_y_allocations(
        self,
        rule: DiscountRule,
        matching_lines: list[DiscountLineInput],
        remaining_by_line: dict[str, Decimal],
    ) -> tuple[DiscountAllocation, ...]:
        """Buy ``buy_quantity`` units to reward ``get_quantity`` units per block.
        The cheapest units in the pool are the rewarded ones (standard BOGO: the
        cheaper item is the free/discounted one)."""
        buy = rule.buy_quantity or 0
        get = rule.get_quantity or 0
        if buy < 1 or get < 1:
            return ()
        block = buy + get
        units = self._pooled_units(matching_lines, remaining_by_line)
        blocks = len(units) // block
        rewarded_count = blocks * get
        if rewarded_count <= 0:
            return ()
        # ``units`` is most-expensive first, so the cheapest rewarded units are
        # the tail of the pool.
        rewarded = units[len(units) - rewarded_count :]
        weights: dict[str, Decimal] = {}
        for price, key in rewarded:
            per_unit = self._reward_unit_discount(rule, price)
            if per_unit <= Decimal("0.00"):
                continue
            weights[key] = money(weights.get(key, Decimal("0.00")) + per_unit)
        if not weights:
            return ()
        total = money(sum(weights.values(), Decimal("0.00")))
        return self._allocate_capped(total, weights, remaining_by_line)

    def _reward_unit_discount(self, rule: DiscountRule, unit_price: Decimal) -> Decimal:
        reward = rule.reward_type
        if reward == DiscountRule.BuyGetReward.FREE:
            return money(unit_price)
        if reward == DiscountRule.BuyGetReward.PERCENTAGE:
            return money(unit_price * rule.value / Decimal("100"))
        if reward == DiscountRule.BuyGetReward.FIXED_PRICE:
            return max(money(unit_price - rule.value), Decimal("0.00"))
        return Decimal("0.00")


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


def rounded_price(amount: Decimal, increment: Decimal, mode: str) -> Decimal:
    amount = money(amount)
    increment = money(increment)
    if amount <= Decimal("0.00") or increment <= Decimal("0.00"):
        return money(amount)

    units = amount / increment
    if mode == DiscountRule.RoundingMode.DOWN:
        rounded_units = units.to_integral_value(rounding=ROUND_FLOOR)
    elif mode == DiscountRule.RoundingMode.UP:
        rounded_units = units.to_integral_value(rounding=ROUND_CEILING)
    else:
        rounded_units = units.to_integral_value(rounding=ROUND_HALF_UP)
    return money(rounded_units * increment)


def clamp_discount_amount(amount: Decimal, source_amount: Decimal) -> Decimal:
    return min(max(money(amount), Decimal("0.00")), money(source_amount))


def rounding_metadata_payload(metadata: dict | None) -> dict:
    metadata = metadata or {}
    mode = metadata.get("rounding_mode")
    if not mode or mode == DiscountRule.RoundingMode.NONE:
        return {}
    return {
        "rounding_mode": mode,
        "rounding_increment": metadata.get("rounding_increment"),
        "unrounded_discount_amount": metadata.get("unrounded_discount_amount"),
        "rounding_adjustment": metadata.get("rounding_adjustment"),
    }


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
            metadata=application.metadata_dict(),
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
    """Re-check usage limits under a row lock, closing the redemption race.

    Discounts are priced (and usage pre-checked) without a lock, so two
    requests can both price the same single-use coupon while it still looks
    available. This runs inside the caller's order/PO transaction (every caller
    is ``@transaction.atomic``) and takes ``SELECT ... FOR UPDATE`` on each rule
    about to be redeemed. Concurrent redemptions of the same rule therefore
    serialise here: the loser blocks until the winner commits, then re-counts
    and sees the winner's redemption, so the limit can never be overshot. Rule
    ids are locked in sorted order so a checkout redeeming several rules can't
    deadlock against another doing the same.
    """
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
            variant = getattr(line, "variant", None)
            product_id = getattr(line, "product_id", None)
            if product_id is None and variant is not None:
                product_id = variant.product_id
            if product_id is not None:
                data["product_id"] = product_id
            variant_id = getattr(line, "variant_id", None)
            if variant_id is None and variant is not None:
                variant_id = variant.pk
            if variant_id is not None:
                data["variant_id"] = variant_id
        allocations.append(data)
    return allocations
