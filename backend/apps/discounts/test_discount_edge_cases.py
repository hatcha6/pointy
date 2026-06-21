"""Edge-case / invariant tests for the discount engine.

These complement apps/discounts/tests.py (which already covers the happy
paths for each value type, priority/exclusivity, descendant categories at a
single level, the round-DOWN document/line modes, usage-limit locking, and the
API surface). The scenarios below deliberately push the engine to its
boundaries: discounts larger than what they apply to, stacking that would drive
a line negative, indivisible-cent allocation across many lines, the exact
ends_at boundary, the not-yet-tested 'nearest'/'up' rounding modes, the
min_order_subtotal threshold, disabled/expired explicit coupons, deeper
category nesting, and the through-checkout invariant that an order total can
never go negative.
"""

from decimal import Decimal

from django.contrib.auth import get_user_model
from django.test import TestCase
from django.utils import timezone

from apps.catalog.models import ProductCategory
from apps.catalog.testing import create_product_with_default_variant
from apps.inventory.models import StockItem
from apps.sales.models import RegisterSession
from apps.sales.services import checkout_order

from .models import DiscountRule
from .services import (
    DiscountContext,
    DiscountEngine,
    DiscountLineInput,
    allocate_discount_amount,
)


class DiscountEngineEdgeCaseTests(TestCase):
    def setUp(self):
        self.engine = DiscountEngine()
        self.product = create_product_with_default_variant(
            sku="EDGE-1",
            name="Edge product one",
            unit_price=Decimal("10.00"),
        )
        self.other_product = create_product_with_default_variant(
            sku="EDGE-2",
            name="Edge product two",
            unit_price=Decimal("20.00"),
        )

    def context(self, **overrides):
        data = {
            "channel": DiscountRule.Channel.SALES,
            "lines": (
                DiscountLineInput(
                    key="line-1",
                    product_id=self.product.pk,
                    quantity=2,
                    unit_amount=Decimal("10.00"),
                ),
                DiscountLineInput(
                    key="line-2",
                    product_id=self.other_product.pk,
                    quantity=1,
                    unit_amount=Decimal("20.00"),
                ),
            ),
        }
        data.update(overrides)
        return DiscountContext(**data)

    # --- 1. fixed_amount document discount larger than subtotal -------------

    def test_fixed_amount_document_discount_is_capped_at_subtotal(self):
        # A 1000.00-off coupon on a 40.00 cart must not over-discount: the
        # engine caps the document discount at the subtotal, so total == 0.00
        # and never goes negative.
        DiscountRule.objects.create(
            name="Mega fixed amount",
            channel=DiscountRule.Channel.SALES,
            scope=DiscountRule.Scope.DOCUMENT,
            value_type=DiscountRule.ValueType.FIXED_AMOUNT,
            value=Decimal("1000.00"),
        )

        result = self.engine.calculate(self.context())

        self.assertEqual(result.subtotal, Decimal("40.00"))
        self.assertEqual(result.discount_total, Decimal("40.00"))
        self.assertEqual(result.total, Decimal("0.00"))
        # The capped amount is split across both lines proportionally and the
        # allocations still sum exactly to the discount.
        allocated = sum(
            (allocation.amount for allocation in result.applications[0].allocations),
            Decimal("0.00"),
        )
        self.assertEqual(allocated, Decimal("40.00"))

    def test_fixed_amount_line_discount_larger_than_line_is_capped(self):
        # A line-scoped fixed amount larger than the line's own subtotal floors
        # at the line (min(value, remaining)), never producing a negative line.
        rule = DiscountRule.objects.create(
            name="Oversized line fixed",
            channel=DiscountRule.Channel.SALES,
            scope=DiscountRule.Scope.LINE,
            value_type=DiscountRule.ValueType.FIXED_AMOUNT,
            value=Decimal("500.00"),
        )
        rule.products.add(self.product)

        result = self.engine.calculate(self.context())

        # line-1 subtotal is 20.00; the discount is capped there.
        self.assertEqual(result.discount_total, Decimal("20.00"))
        self.assertEqual(result.applications[0].allocation_dicts(), [
            {"line_key": "line-1", "amount": "20.00"},
        ])
        self.assertEqual(result.total, Decimal("20.00"))

    # --- 2. Stacking two line rules to (and past) zero ----------------------

    def test_stacking_two_line_rules_floors_at_line_subtotal(self):
        # Two non-exclusive line-scoped fixed-amount rules each worth 15.00
        # target the same 20.00 line. The first takes 15.00; the second sees
        # only 5.00 remaining and is capped there. The line never goes negative
        # and the order discount is exactly the line subtotal.
        first = DiscountRule.objects.create(
            name="First fifteen",
            channel=DiscountRule.Channel.SALES,
            scope=DiscountRule.Scope.LINE,
            value_type=DiscountRule.ValueType.FIXED_AMOUNT,
            value=Decimal("15.00"),
            exclusive=False,
            priority=1,
        )
        second = DiscountRule.objects.create(
            name="Second fifteen",
            channel=DiscountRule.Channel.SALES,
            scope=DiscountRule.Scope.LINE,
            value_type=DiscountRule.ValueType.FIXED_AMOUNT,
            value=Decimal("15.00"),
            exclusive=False,
            priority=2,
        )
        first.products.add(self.product)
        second.products.add(self.product)

        # Single line: 2 x 10.00 = 20.00 subtotal.
        result = self.engine.calculate(
            self.context(
                lines=(
                    DiscountLineInput(
                        key="line-1",
                        product_id=self.product.pk,
                        quantity=2,
                        unit_amount=Decimal("10.00"),
                    ),
                )
            )
        )

        self.assertEqual(result.subtotal, Decimal("20.00"))
        self.assertEqual(result.discount_total, Decimal("20.00"))
        self.assertEqual(result.total, Decimal("0.00"))
        # Both rules applied, but the combined discount stops at the line value.
        amounts = [application.amount for application in result.applications]
        self.assertEqual(sorted(amounts), [Decimal("5.00"), Decimal("15.00")])

    def test_second_rule_sees_zero_remaining_and_is_dropped(self):
        # If the first non-exclusive rule already consumes the whole line, the
        # second rule has nothing to discount and is not applied at all.
        first = DiscountRule.objects.create(
            name="Whole line off",
            channel=DiscountRule.Channel.SALES,
            scope=DiscountRule.Scope.LINE,
            value_type=DiscountRule.ValueType.FIXED_AMOUNT,
            value=Decimal("20.00"),
            exclusive=False,
            priority=1,
        )
        second = DiscountRule.objects.create(
            name="Leftover percent",
            channel=DiscountRule.Channel.SALES,
            scope=DiscountRule.Scope.LINE,
            value_type=DiscountRule.ValueType.PERCENTAGE,
            value=Decimal("50.00"),
            exclusive=False,
            priority=2,
        )
        first.products.add(self.product)
        second.products.add(self.product)

        result = self.engine.calculate(
            self.context(
                lines=(
                    DiscountLineInput(
                        key="line-1",
                        product_id=self.product.pk,
                        quantity=2,
                        unit_amount=Decimal("10.00"),
                    ),
                )
            )
        )

        self.assertEqual(result.discount_total, Decimal("20.00"))
        self.assertEqual(
            [application.rule_name for application in result.applications],
            ["Whole line off"],
        )

    # --- 3. Indivisible-cent allocation across 3+ lines ---------------------

    def test_percentage_allocation_over_three_lines_sums_exactly(self):
        # 10% of 10.01 across three equal lines = 1.001 -> 1.00 order discount
        # split largest-remainder over three lines (1.00 / 3 indivisible). The
        # per-line allocations must sum EXACTLY to the order discount.
        third_product = create_product_with_default_variant(
            sku="EDGE-3",
            name="Edge product three",
            unit_price=Decimal("3.34"),
        )
        DiscountRule.objects.create(
            name="Ten percent everywhere",
            channel=DiscountRule.Channel.SALES,
            scope=DiscountRule.Scope.DOCUMENT,
            value_type=DiscountRule.ValueType.PERCENTAGE,
            value=Decimal("10.00"),
        )

        result = self.engine.calculate(
            self.context(
                lines=(
                    DiscountLineInput(
                        key="a",
                        product_id=self.product.pk,
                        quantity=1,
                        unit_amount=Decimal("3.34"),
                    ),
                    DiscountLineInput(
                        key="b",
                        product_id=self.other_product.pk,
                        quantity=1,
                        unit_amount=Decimal("3.34"),
                    ),
                    DiscountLineInput(
                        key="c",
                        product_id=third_product.pk,
                        quantity=1,
                        unit_amount=Decimal("3.34"),
                    ),
                )
            )
        )

        # 10% of 10.02 = 1.002 -> 1.00.
        self.assertEqual(result.subtotal, Decimal("10.02"))
        self.assertEqual(result.discount_total, Decimal("1.00"))
        allocations = result.applications[0].allocations
        allocated = sum((a.amount for a in allocations), Decimal("0.00"))
        self.assertEqual(allocated, result.discount_total)
        # Largest-remainder tie-break is deterministic by line key, so the
        # extra cent lands on the first key("a").
        by_key = {a.line_key: a.amount for a in allocations}
        self.assertEqual(by_key, {
            "a": Decimal("0.34"),
            "b": Decimal("0.33"),
            "c": Decimal("0.33"),
        })

    def test_allocate_discount_amount_indivisible_cent_is_deterministic(self):
        # Direct unit test of the largest-remainder helper: 0.01 over two equal
        # weights cannot split evenly; the single cent must go to exactly one
        # line, deterministically the lexicographically-first key.
        allocations = allocate_discount_amount(
            Decimal("0.01"),
            {"z": Decimal("5.00"), "a": Decimal("5.00")},
        )
        by_key = {a.line_key: a.amount for a in allocations}
        self.assertEqual(by_key, {"a": Decimal("0.01")})
        self.assertEqual(
            sum((a.amount for a in allocations), Decimal("0.00")),
            Decimal("0.01"),
        )

    # --- 4. ends_at boundary (exclusive end) --------------------------------

    def test_ends_at_exactly_now_is_treated_as_expired(self):
        # The engine filters ends_at__gt=now (strictly greater), so a rule whose
        # ends_at equals the evaluation instant is already expired. We freeze
        # `now` through the context to remove clock skew from the assertion.
        now = timezone.now()
        DiscountRule.objects.create(
            name="Ends exactly now",
            channel=DiscountRule.Channel.SALES,
            scope=DiscountRule.Scope.DOCUMENT,
            value_type=DiscountRule.ValueType.FIXED_AMOUNT,
            value=Decimal("5.00"),
            ends_at=now,
        )

        result = self.engine.calculate(self.context(now=now))

        self.assertEqual(result.discount_total, Decimal("0.00"))
        self.assertEqual(result.applications, ())

    def test_ends_at_just_in_the_future_still_applies(self):
        now = timezone.now()
        DiscountRule.objects.create(
            name="Ends one second from now",
            channel=DiscountRule.Channel.SALES,
            scope=DiscountRule.Scope.DOCUMENT,
            value_type=DiscountRule.ValueType.FIXED_AMOUNT,
            value=Decimal("5.00"),
            ends_at=now + timezone.timedelta(seconds=1),
        )

        result = self.engine.calculate(self.context(now=now))

        self.assertEqual(result.discount_total, Decimal("5.00"))
        self.assertEqual(result.total, Decimal("35.00"))

    def test_starts_at_exactly_now_is_inclusive(self):
        # Counterpart to ends_at: starts_at filters starts_at__lte=now, so a
        # rule starting at exactly `now` is already active (inclusive start).
        now = timezone.now()
        DiscountRule.objects.create(
            name="Starts exactly now",
            channel=DiscountRule.Channel.SALES,
            scope=DiscountRule.Scope.DOCUMENT,
            value_type=DiscountRule.ValueType.FIXED_AMOUNT,
            value=Decimal("5.00"),
            starts_at=now,
        )

        result = self.engine.calculate(self.context(now=now))

        self.assertEqual(result.discount_total, Decimal("5.00"))

    # --- 5. Rounding modes 'nearest' and 'up' -------------------------------

    def test_document_rounding_nearest_rounds_discounted_total(self):
        # Subtotal 40.00, 10% off -> 4.00 discount -> discounted total 36.00.
        # 'nearest' to a 5.00 increment rounds 36.00 -> 35.00 (nearer than
        # 40.00), so the discount grows to 5.00.
        DiscountRule.objects.create(
            name="Round nearest five",
            channel=DiscountRule.Channel.SALES,
            scope=DiscountRule.Scope.DOCUMENT,
            value_type=DiscountRule.ValueType.PERCENTAGE,
            value=Decimal("10.00"),
            rounding_mode=DiscountRule.RoundingMode.NEAREST,
            rounding_increment=Decimal("5.00"),
        )

        result = self.engine.calculate(self.context())

        self.assertEqual(result.discount_total, Decimal("5.00"))
        self.assertEqual(result.total, Decimal("35.00"))
        self.assertEqual(
            result.applications[0].metadata_dict(),
            {
                "rounding_mode": DiscountRule.RoundingMode.NEAREST,
                "rounding_increment": "5.00",
                "unrounded_discount_amount": "4.00",
                "rounding_adjustment": "1.00",
            },
        )

    def test_document_rounding_nearest_rounds_total_upward(self):
        # Subtotal 40.00, 5% off -> 2.00 discount -> discounted total 38.00.
        # 'nearest' 5.00: 38.00 is nearer 40.00 than 35.00, so it rounds UP to
        # 40.00 -> the discount shrinks to 0.00 and the application is dropped.
        DiscountRule.objects.create(
            name="Round nearest up",
            channel=DiscountRule.Channel.SALES,
            scope=DiscountRule.Scope.DOCUMENT,
            value_type=DiscountRule.ValueType.PERCENTAGE,
            value=Decimal("5.00"),
            rounding_mode=DiscountRule.RoundingMode.NEAREST,
            rounding_increment=Decimal("5.00"),
        )

        result = self.engine.calculate(self.context())

        self.assertEqual(result.discount_total, Decimal("0.00"))
        self.assertEqual(result.total, Decimal("40.00"))
        self.assertEqual(result.applications, ())

    def test_document_rounding_up_rounds_discounted_total_up(self):
        # 'up' rounds the discounted TOTAL up to the increment, which means the
        # smallest possible discount. Subtotal 40.00, 10% off -> 36.00; rounding
        # the total UP to the next 5.00 gives 40.00 -> discount 0.00.
        DiscountRule.objects.create(
            name="Round total up",
            channel=DiscountRule.Channel.SALES,
            scope=DiscountRule.Scope.DOCUMENT,
            value_type=DiscountRule.ValueType.PERCENTAGE,
            value=Decimal("10.00"),
            rounding_mode=DiscountRule.RoundingMode.UP,
            rounding_increment=Decimal("5.00"),
        )

        result = self.engine.calculate(self.context())

        self.assertEqual(result.discount_total, Decimal("0.00"))
        self.assertEqual(result.total, Decimal("40.00"))

    def test_document_rounding_up_to_one_dirham_increment(self):
        # With a 1.00 increment 'up' rounds the discounted total up to the next
        # whole unit. Subtotal 30.30, 10% off -> 27.27 -> rounded up to 28.00,
        # so the discount is 30.30 - 28.00 = 2.30.
        DiscountRule.objects.create(
            name="Round total up one",
            channel=DiscountRule.Channel.SALES,
            scope=DiscountRule.Scope.DOCUMENT,
            value_type=DiscountRule.ValueType.PERCENTAGE,
            value=Decimal("10.00"),
            rounding_mode=DiscountRule.RoundingMode.UP,
            rounding_increment=Decimal("1.00"),
        )

        result = self.engine.calculate(
            self.context(
                lines=(
                    DiscountLineInput(
                        key="line-1",
                        product_id=self.product.pk,
                        quantity=1,
                        unit_amount=Decimal("30.30"),
                    ),
                )
            )
        )

        self.assertEqual(result.subtotal, Decimal("30.30"))
        self.assertEqual(result.discount_total, Decimal("2.30"))
        self.assertEqual(result.total, Decimal("28.00"))

    # --- 6. min_order_subtotal threshold ------------------------------------

    def test_min_order_subtotal_threshold_is_inclusive(self):
        # min_order_subtotal=40.00. A 39.99 cart is below threshold and gets
        # nothing; a 40.00 cart is exactly at the threshold and qualifies. The
        # engine compares subtotal < min_order_subtotal, so equality passes.
        DiscountRule.objects.create(
            name="Spend forty",
            channel=DiscountRule.Channel.SALES,
            scope=DiscountRule.Scope.DOCUMENT,
            value_type=DiscountRule.ValueType.FIXED_AMOUNT,
            value=Decimal("5.00"),
            min_order_subtotal=Decimal("40.00"),
        )

        below = self.engine.calculate(
            self.context(
                lines=(
                    DiscountLineInput(
                        key="line-1",
                        product_id=self.product.pk,
                        quantity=1,
                        unit_amount=Decimal("39.99"),
                    ),
                )
            )
        )
        at = self.engine.calculate(
            self.context(
                lines=(
                    DiscountLineInput(
                        key="line-1",
                        product_id=self.product.pk,
                        quantity=1,
                        unit_amount=Decimal("40.00"),
                    ),
                )
            )
        )
        above = self.engine.calculate(self.context())  # 40.00 cart from helper

        self.assertEqual(below.discount_total, Decimal("0.00"))
        self.assertEqual(at.discount_total, Decimal("5.00"))
        self.assertEqual(above.discount_total, Decimal("5.00"))

    # --- 7. Explicit disabled / expired coupon codes ------------------------

    def test_disabled_coupon_supplied_explicitly_is_not_applied(self):
        # Even when the exact code is supplied, an inactive coupon rule must not
        # discount anything.
        DiscountRule.objects.create(
            name="Switched-off coupon",
            channel=DiscountRule.Channel.SALES,
            application_type=DiscountRule.ApplicationType.COUPON_CODE,
            coupon_code="DEAD",
            scope=DiscountRule.Scope.DOCUMENT,
            value_type=DiscountRule.ValueType.FIXED_AMOUNT,
            value=Decimal("5.00"),
            is_active=False,
        )

        result = self.engine.calculate(self.context(coupon_codes=("dead",)))

        self.assertEqual(result.discount_total, Decimal("0.00"))
        self.assertEqual(result.applications, ())

    def test_expired_coupon_supplied_explicitly_is_not_applied(self):
        now = timezone.now()
        DiscountRule.objects.create(
            name="Lapsed coupon",
            channel=DiscountRule.Channel.SALES,
            application_type=DiscountRule.ApplicationType.COUPON_CODE,
            coupon_code="LAPSED",
            scope=DiscountRule.Scope.DOCUMENT,
            value_type=DiscountRule.ValueType.FIXED_AMOUNT,
            value=Decimal("5.00"),
            ends_at=now - timezone.timedelta(seconds=1),
        )

        result = self.engine.calculate(
            self.context(coupon_codes=("LAPSED",), now=now)
        )

        self.assertEqual(result.discount_total, Decimal("0.00"))
        self.assertEqual(result.applications, ())

    def test_valid_coupon_is_applied_case_insensitively(self):
        # A live coupon supplied in mixed case is normalized and applied; the
        # snapshot reports the canonical upper-cased code.
        DiscountRule.objects.create(
            name="Live coupon",
            channel=DiscountRule.Channel.SALES,
            application_type=DiscountRule.ApplicationType.COUPON_CODE,
            coupon_code="FRESH5",
            scope=DiscountRule.Scope.DOCUMENT,
            value_type=DiscountRule.ValueType.FIXED_AMOUNT,
            value=Decimal("5.00"),
        )

        result = self.engine.calculate(self.context(coupon_codes=("  fReSh5 ",)))

        self.assertEqual(result.discount_total, Decimal("5.00"))
        self.assertEqual(result.applications[0].coupon_code, "FRESH5")
        self.assertEqual(
            result.applications[0].source,
            DiscountRule.ApplicationType.COUPON_CODE,
        )

    # --- 9. Category scoping with deeper descendants ------------------------

    def test_rule_targeting_parent_matches_grandchild_category_line(self):
        # The engine walks the category tree to all descendants, so a rule
        # scoped to a top-level category matches a line tagged with a
        # grandchild category two levels down.
        parent = ProductCategory.objects.create(name="Beverages")
        child = ProductCategory.objects.create(name="Hot drinks", parent=parent)
        grandchild = ProductCategory.objects.create(name="Espresso", parent=child)
        self.product.categories.add(grandchild)

        rule = DiscountRule.objects.create(
            name="All beverages 10 percent",
            channel=DiscountRule.Channel.SALES,
            scope=DiscountRule.Scope.LINE,
            value_type=DiscountRule.ValueType.PERCENTAGE,
            value=Decimal("10.00"),
        )
        rule.product_categories.add(parent)

        result = self.engine.calculate(
            self.context(
                lines=(
                    DiscountLineInput(
                        key="line-1",
                        product_id=self.product.pk,
                        quantity=2,
                        unit_amount=Decimal("10.00"),
                        category_ids=(grandchild.pk,),
                    ),
                    DiscountLineInput(
                        key="line-2",
                        product_id=self.other_product.pk,
                        quantity=1,
                        unit_amount=Decimal("20.00"),
                    ),
                )
            )
        )

        # Only line-1 (in the descendant category) is discounted: 10% of 20.00.
        self.assertEqual(result.discount_total, Decimal("2.00"))
        self.assertEqual(result.applications[0].allocation_dicts(), [
            {"line_key": "line-1", "amount": "2.00"},
        ])


class DiscountCheckoutInvariantTests(TestCase):
    """Drive a couple of edge cases end-to-end through the sales checkout."""

    def setUp(self):
        self.user = get_user_model().objects.create_user(
            username="edge-cashier",
            password="pass",
        )
        # A register session is required for checkout_order; managers / None
        # owner bypass the per-channel owner checks (request=None).
        self.session = RegisterSession.objects.create(
            owner=self.user,
            owner_key=f"user:{self.user.pk}",
        )
        # No purchase / production history => unit_cost 0 => the prevent-loss
        # guard is a no-op, so a near-100% discount is allowed through.
        self.product = create_product_with_default_variant(
            sku="CHECKOUT-1",
            name="Checkout product",
            unit_price=Decimal("10.00"),
        )
        self.variant = self.product.default_variant
        StockItem.objects.create(
            variant=self.variant,
            quantity_on_hand=Decimal("100"),
        )

    def test_near_total_discount_cannot_drive_order_total_negative(self):
        # A 99% document discount on a 30.00 cart leaves a positive total; the
        # invariant we assert is the floor: total >= 0 and discount <= subtotal.
        DiscountRule.objects.create(
            name="Ninety-nine percent",
            channel=DiscountRule.Channel.SALES,
            scope=DiscountRule.Scope.DOCUMENT,
            value_type=DiscountRule.ValueType.PERCENTAGE,
            value=Decimal("99.00"),
        )
        lines_data = [{"variant": self.variant, "quantity": Decimal("3")}]
        discount_result = DiscountEngine().calculate(
            DiscountContext(
                channel=DiscountRule.Channel.SALES,
                lines=(
                    DiscountLineInput(
                        key="0",
                        product_id=self.product.pk,
                        variant_id=self.variant.pk,
                        quantity=3,
                        unit_amount=Decimal("10.00"),
                    ),
                ),
            )
        )
        # 99% of 30.00 = 29.70, so the buyer owes 0.30.
        self.assertEqual(discount_result.discount_total, Decimal("29.70"))

        order = checkout_order(
            register_session=self.session,
            lines_data=lines_data,
            payments_data=[{"method": "cash", "amount": Decimal("0.30")}],
            discount_result=discount_result,
        )

        self.assertEqual(order.subtotal, Decimal("30.00"))
        self.assertEqual(order.discount_total, Decimal("29.70"))
        self.assertEqual(order.total, Decimal("0.30"))
        self.assertGreaterEqual(order.total, Decimal("0.00"))
        self.assertLessEqual(order.discount_total, order.subtotal)

    def test_full_value_fixed_amount_checkout_clamps_total_to_zero(self):
        # A fixed-amount coupon worth more than the cart is capped at subtotal
        # by the engine AND clamped again by Order.recalculate, so the order
        # total is exactly 0.00 with a fully-zero cash payment.
        DiscountRule.objects.create(
            name="Whole cart off",
            channel=DiscountRule.Channel.SALES,
            scope=DiscountRule.Scope.DOCUMENT,
            value_type=DiscountRule.ValueType.FIXED_AMOUNT,
            value=Decimal("500.00"),
        )
        lines_data = [{"variant": self.variant, "quantity": Decimal("2")}]
        discount_result = DiscountEngine().calculate(
            DiscountContext(
                channel=DiscountRule.Channel.SALES,
                lines=(
                    DiscountLineInput(
                        key="0",
                        product_id=self.product.pk,
                        variant_id=self.variant.pk,
                        quantity=2,
                        unit_amount=Decimal("10.00"),
                    ),
                ),
            )
        )
        self.assertEqual(discount_result.discount_total, Decimal("20.00"))

        order = checkout_order(
            register_session=self.session,
            lines_data=lines_data,
            payments_data=[{"method": "cash", "amount": Decimal("0.00")}],
            discount_result=discount_result,
        )

        self.assertEqual(order.subtotal, Decimal("20.00"))
        self.assertEqual(order.discount_total, Decimal("20.00"))
        self.assertEqual(order.total, Decimal("0.00"))
        self.assertGreaterEqual(order.total, Decimal("0.00"))
