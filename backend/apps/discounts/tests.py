from datetime import timedelta
from decimal import Decimal

from django.contrib.contenttypes.models import ContentType
from django.contrib.auth import get_user_model
from django.contrib.auth.models import Permission
from django.db import connection
from django.test import TestCase
from django.test.utils import CaptureQueriesContext
from django.utils import timezone
from rest_framework.test import APIClient

from apps.analytics.models import AnalyticsEvent
from apps.catalog.models import ProductCategory, ProductVariant
from apps.catalog.testing import create_product_with_default_variant
from apps.customers.models import Customer
from apps.purchasing.models import Supplier
from apps.sales.models import Order

from .models import AppliedDiscount, DiscountRedemption, DiscountRule
from .services import (
    DiscountContext,
    DiscountEngine,
    DiscountLineInput,
    DiscountUsageLimitExceeded,
    persist_applied_discounts,
)


class DiscountEngineTests(TestCase):
    def setUp(self):
        self.engine = DiscountEngine()
        self.product = create_product_with_default_variant(
            sku="SKU-1",
            name="Product one",
            unit_price=Decimal("10.00"),
        )
        self.other_product = create_product_with_default_variant(
            sku="SKU-2",
            name="Product two",
            unit_price=Decimal("20.00"),
        )
        self.parent_category = ProductCategory.objects.create(name="Category parent")
        self.child_category = ProductCategory.objects.create(
            name="Category child",
            parent=self.parent_category,
        )
        self.product.categories.add(self.child_category)

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

    def test_automatic_document_percentage_discount(self):
        DiscountRule.objects.create(
            name="Ten percent",
            channel=DiscountRule.Channel.SALES,
            value_type=DiscountRule.ValueType.PERCENTAGE,
            value=Decimal("10.00"),
        )

        result = self.engine.calculate(self.context())

        self.assertEqual(result.subtotal, Decimal("40.00"))
        self.assertEqual(result.discount_total, Decimal("4.00"))
        self.assertEqual(result.total, Decimal("36.00"))
        self.assertEqual(
            [allocation.as_dict() for allocation in result.applications[0].allocations],
            [
                {"line_key": "line-1", "amount": "2.00"},
                {"line_key": "line-2", "amount": "2.00"},
            ],
        )

    def test_coupon_code_must_be_supplied_and_is_normalized(self):
        rule = DiscountRule.objects.create(
            name="Coupon",
            channel=DiscountRule.Channel.SALES,
            application_type=DiscountRule.ApplicationType.COUPON_CODE,
            coupon_code=" save5 ",
            value_type=DiscountRule.ValueType.FIXED_AMOUNT,
            value=Decimal("5.00"),
        )

        self.assertEqual(rule.coupon_code, "SAVE5")
        self.assertEqual(self.engine.calculate(self.context()).discount_total, Decimal("0.00"))

        result = self.engine.calculate(self.context(coupon_codes=("save5",)))
        self.assertEqual(result.discount_total, Decimal("5.00"))
        self.assertEqual(result.total, Decimal("35.00"))

    def test_minimum_subtotal_max_cap_and_cent_allocation_are_deterministic(self):
        DiscountRule.objects.create(
            name="Capped half off",
            channel=DiscountRule.Channel.SALES,
            value_type=DiscountRule.ValueType.PERCENTAGE,
            value=Decimal("50.00"),
            min_order_subtotal=Decimal("40.00"),
            max_discount_amount=Decimal("3.33"),
        )

        below_minimum = self.engine.calculate(
            self.context(
                lines=(
                    DiscountLineInput(
                        key="line-1",
                        product_id=self.product.pk,
                        quantity=1,
                        unit_amount=Decimal("10.00"),
                    ),
                    DiscountLineInput(
                        key="line-2",
                        product_id=self.other_product.pk,
                        quantity=1,
                        unit_amount=Decimal("29.99"),
                    ),
                )
            )
        )
        result = self.engine.calculate(self.context())

        self.assertEqual(below_minimum.discount_total, Decimal("0.00"))
        self.assertEqual(result.discount_total, Decimal("3.33"))
        self.assertEqual(result.total, Decimal("36.67"))
        self.assertEqual(result.applications[0].allocation_dicts(), [
            {"line_key": "line-1", "amount": "1.67"},
            {"line_key": "line-2", "amount": "1.66"},
        ])

    def test_line_discount_can_target_products_and_minimum_quantity(self):
        rule = DiscountRule.objects.create(
            name="Product unit discount",
            channel=DiscountRule.Channel.SALES,
            scope=DiscountRule.Scope.LINE,
            value_type=DiscountRule.ValueType.FIXED_UNIT_AMOUNT,
            value=Decimal("1.50"),
            min_line_quantity=2,
        )
        rule.products.add(self.product)

        result = self.engine.calculate(self.context())

        self.assertEqual(result.discount_total, Decimal("3.00"))
        self.assertEqual(result.applications[0].allocation_dicts(), [
            {"line_key": "line-1", "amount": "3.00"},
        ])

    def test_line_discount_can_target_a_specific_variant(self):
        variant = ProductVariant.objects.create(
            product=self.product,
            name="Large",
            sku="SKU-1-L",
            unit_price=Decimal("12.00"),
        )
        rule = DiscountRule.objects.create(
            name="Variant discount",
            channel=DiscountRule.Channel.SALES,
            scope=DiscountRule.Scope.LINE,
            value_type=DiscountRule.ValueType.FIXED_AMOUNT,
            value=Decimal("2.00"),
        )
        rule.variants.add(variant)

        result = self.engine.calculate(
            self.context(
                lines=(
                    DiscountLineInput(
                        key="default",
                        product_id=self.product.pk,
                        variant_id=self.product.default_variant.pk,
                        quantity=1,
                        unit_amount=Decimal("10.00"),
                    ),
                    DiscountLineInput(
                        key="large",
                        product_id=self.product.pk,
                        variant_id=variant.pk,
                        quantity=1,
                        unit_amount=Decimal("12.00"),
                    ),
                )
            )
        )

        self.assertEqual(result.discount_total, Decimal("2.00"))
        self.assertEqual(result.applications[0].allocation_dicts(), [
            {"line_key": "large", "amount": "2.00"},
        ])

    def test_line_discount_can_target_categories_with_descendants(self):
        rule = DiscountRule.objects.create(
            name="Category discount",
            channel=DiscountRule.Channel.SALES,
            scope=DiscountRule.Scope.LINE,
            value_type=DiscountRule.ValueType.PERCENTAGE,
            value=Decimal("10.00"),
        )
        rule.product_categories.add(self.parent_category)

        result = self.engine.calculate(
            self.context(
                lines=(
                    DiscountLineInput(
                        key="line-1",
                        product_id=self.product.pk,
                        quantity=2,
                        unit_amount=Decimal("10.00"),
                        category_ids=(self.child_category.pk,),
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

        self.assertEqual(result.discount_total, Decimal("2.00"))
        self.assertEqual(result.applications[0].allocation_dicts(), [
            {"line_key": "line-1", "amount": "2.00"},
        ])

    def test_priority_and_exclusivity_are_deterministic(self):
        DiscountRule.objects.create(
            name="Exclusive five",
            channel=DiscountRule.Channel.SALES,
            value_type=DiscountRule.ValueType.FIXED_AMOUNT,
            value=Decimal("5.00"),
            priority=1,
            exclusive=True,
        )
        DiscountRule.objects.create(
            name="Later ten",
            channel=DiscountRule.Channel.SALES,
            value_type=DiscountRule.ValueType.FIXED_AMOUNT,
            value=Decimal("10.00"),
            priority=2,
        )

        result = self.engine.calculate(self.context())

        self.assertEqual(result.discount_total, Decimal("5.00"))
        self.assertEqual([application.rule_name for application in result.applications], [
            "Exclusive five",
        ])

    def test_discounts_stack_only_when_marked_non_exclusive(self):
        DiscountRule.objects.create(
            name="Default exclusive five",
            channel=DiscountRule.Channel.SALES,
            value_type=DiscountRule.ValueType.FIXED_AMOUNT,
            value=Decimal("5.00"),
            priority=1,
        )
        DiscountRule.objects.create(
            name="Skipped later five",
            channel=DiscountRule.Channel.SALES,
            value_type=DiscountRule.ValueType.FIXED_AMOUNT,
            value=Decimal("5.00"),
            priority=2,
        )

        result = self.engine.calculate(self.context())

        self.assertEqual(result.discount_total, Decimal("5.00"))
        self.assertEqual(
            [application.rule_name for application in result.applications],
            ["Default exclusive five"],
        )

    def test_fixed_price_line_discount_reduces_unit_amount(self):
        rule = DiscountRule.objects.create(
            name="Fixed price",
            channel=DiscountRule.Channel.SALES,
            scope=DiscountRule.Scope.LINE,
            value_type=DiscountRule.ValueType.FIXED_PRICE,
            value=Decimal("7.50"),
        )
        rule.products.add(self.product)

        result = self.engine.calculate(self.context())

        self.assertEqual(result.discount_total, Decimal("5.00"))
        self.assertEqual(result.applications[0].allocation_dicts(), [
            {"line_key": "line-1", "amount": "5.00"},
        ])

    def test_document_discount_can_round_discounted_total_down_to_increment(self):
        DiscountRule.objects.create(
            name="Round document total",
            channel=DiscountRule.Channel.SALES,
            value_type=DiscountRule.ValueType.PERCENTAGE,
            value=Decimal("10.00"),
            rounding_mode=DiscountRule.RoundingMode.DOWN,
            rounding_increment=Decimal("5.00"),
        )

        result = self.engine.calculate(self.context())

        self.assertEqual(result.discount_total, Decimal("5.00"))
        self.assertEqual(result.total, Decimal("35.00"))
        self.assertEqual(result.applications[0].allocation_dicts(), [
            {"line_key": "line-1", "amount": "2.50"},
            {"line_key": "line-2", "amount": "2.50"},
        ])
        self.assertEqual(
            result.applications[0].metadata_dict(),
            {
                "rounding_mode": DiscountRule.RoundingMode.DOWN,
                "rounding_increment": "5.00",
                "unrounded_discount_amount": "4.00",
                "rounding_adjustment": "1.00",
            },
        )

    def test_line_discount_rounds_each_discounted_line_to_increment(self):
        rule = DiscountRule.objects.create(
            name="Round line total",
            channel=DiscountRule.Channel.SALES,
            scope=DiscountRule.Scope.LINE,
            value_type=DiscountRule.ValueType.PERCENTAGE,
            value=Decimal("10.00"),
            rounding_mode=DiscountRule.RoundingMode.DOWN,
            rounding_increment=Decimal("0.25"),
        )
        rule.products.add(self.product)

        result = self.engine.calculate(
            self.context(
                lines=(
                    DiscountLineInput(
                        key="line-1",
                        product_id=self.product.pk,
                        quantity=1,
                        unit_amount=Decimal("10.10"),
                    ),
                    DiscountLineInput(
                        key="line-2",
                        product_id=self.other_product.pk,
                        quantity=1,
                        unit_amount=Decimal("10.10"),
                    ),
                )
            )
        )

        self.assertEqual(result.discount_total, Decimal("1.10"))
        self.assertEqual(result.total, Decimal("19.10"))
        self.assertEqual(result.applications[0].allocation_dicts(), [
            {"line_key": "line-1", "amount": "1.10"},
        ])

    def test_rounding_respects_maximum_discount_cap(self):
        DiscountRule.objects.create(
            name="Rounded capped document",
            channel=DiscountRule.Channel.SALES,
            value_type=DiscountRule.ValueType.PERCENTAGE,
            value=Decimal("10.00"),
            max_discount_amount=Decimal("4.50"),
            rounding_mode=DiscountRule.RoundingMode.DOWN,
            rounding_increment=Decimal("5.00"),
        )

        result = self.engine.calculate(self.context())

        self.assertEqual(result.discount_total, Decimal("4.50"))
        self.assertEqual(result.total, Decimal("35.50"))
        self.assertEqual(result.applications[0].allocation_dicts(), [
            {"line_key": "line-1", "amount": "2.25"},
            {"line_key": "line-2", "amount": "2.25"},
        ])
        self.assertEqual(
            result.applications[0].metadata_dict(),
            {
                "rounding_mode": DiscountRule.RoundingMode.DOWN,
                "rounding_increment": "5.00",
                "unrounded_discount_amount": "4.00",
                "rounding_adjustment": "1.00",
            },
        )

    def test_disabled_future_and_expired_automatic_rules_are_ignored(self):
        DiscountRule.objects.create(
            name="Disabled",
            channel=DiscountRule.Channel.SALES,
            value_type=DiscountRule.ValueType.FIXED_AMOUNT,
            value=Decimal("5.00"),
            is_active=False,
            priority=1,
        )
        DiscountRule.objects.create(
            name="Future",
            channel=DiscountRule.Channel.SALES,
            value_type=DiscountRule.ValueType.FIXED_AMOUNT,
            value=Decimal("5.00"),
            starts_at=timezone.now() + timezone.timedelta(days=1),
            priority=2,
        )
        DiscountRule.objects.create(
            name="Expired",
            channel=DiscountRule.Channel.SALES,
            value_type=DiscountRule.ValueType.FIXED_AMOUNT,
            value=Decimal("5.00"),
            ends_at=timezone.now() - timezone.timedelta(seconds=1),
            priority=3,
        )

        result = self.engine.calculate(self.context())

        self.assertEqual(result.discount_total, Decimal("0.00"))
        self.assertEqual(result.applications, ())

    def test_dates_usage_limits_and_customer_constraints(self):
        customer = Customer.objects.create(full_name="Customer one")
        constrained_rule = DiscountRule.objects.create(
            name="Customer coupon",
            channel=DiscountRule.Channel.SALES,
            application_type=DiscountRule.ApplicationType.COUPON_CODE,
            coupon_code="ONEUSE",
            value_type=DiscountRule.ValueType.FIXED_AMOUNT,
            value=Decimal("3.00"),
            starts_at=timezone.now() - timezone.timedelta(days=1),
            ends_at=timezone.now() + timezone.timedelta(days=1),
            usage_limit=1,
            per_customer_usage_limit=1,
        )
        constrained_rule.customers.add(customer)

        missing_customer = self.engine.calculate(self.context(coupon_codes=("ONEUSE",)))
        self.assertEqual(missing_customer.discount_total, Decimal("0.00"))

        first_result = self.engine.calculate(
            self.context(customer_id=customer.pk, coupon_codes=("ONEUSE",))
        )
        self.assertEqual(first_result.discount_total, Decimal("3.00"))

        DiscountRedemption.objects.create(
            rule=constrained_rule,
            coupon_code="ONEUSE",
            channel=DiscountRule.Channel.SALES,
            customer=customer,
            discount_amount=Decimal("3.00"),
        )
        used_result = self.engine.calculate(
            self.context(customer_id=customer.pk, coupon_codes=("ONEUSE",))
        )
        self.assertEqual(used_result.discount_total, Decimal("0.00"))

    def test_purchase_supplier_constraint_uses_same_engine(self):
        supplier = Supplier.objects.create(name="Supplier one")
        rule = DiscountRule.objects.create(
            name="Supplier discount",
            channel=DiscountRule.Channel.PURCHASING,
            value_type=DiscountRule.ValueType.PERCENTAGE,
            value=Decimal("5.00"),
        )
        rule.suppliers.add(supplier)

        result = self.engine.calculate(
            self.context(channel=DiscountRule.Channel.PURCHASING, supplier_id=supplier.pk)
        )

        self.assertEqual(result.discount_total, Decimal("2.00"))

    def test_persist_applied_discount_snapshots_and_redemptions(self):
        rule = DiscountRule.objects.create(
            name="Snapshot coupon",
            channel=DiscountRule.Channel.SALES,
            application_type=DiscountRule.ApplicationType.COUPON_CODE,
            coupon_code="SNAP",
            value_type=DiscountRule.ValueType.FIXED_AMOUNT,
            value=Decimal("4.00"),
            rounding_mode=DiscountRule.RoundingMode.DOWN,
            rounding_increment=Decimal("5.00"),
        )
        order = Order.objects.create()
        result = self.engine.calculate(self.context(coupon_codes=("SNAP",)))

        snapshots = persist_applied_discounts(document=order, result=result)

        self.assertEqual(len(snapshots), 1)
        snapshot = AppliedDiscount.objects.get()
        redemption = DiscountRedemption.objects.get()
        self.assertEqual(snapshot.rule, rule)
        self.assertEqual(snapshot.rule_name, "Snapshot coupon")
        self.assertEqual(snapshot.source, DiscountRule.ApplicationType.COUPON_CODE)
        self.assertEqual(snapshot.discount_amount, Decimal("5.00"))
        self.assertEqual(snapshot.document, order)
        self.assertEqual(snapshot.allocations[0]["amount"], "2.50")
        self.assertEqual(
            snapshot.metadata,
            {
                "rounding_mode": DiscountRule.RoundingMode.DOWN,
                "rounding_increment": "5.00",
                "unrounded_discount_amount": "4.00",
                "rounding_adjustment": "1.00",
            },
        )
        self.assertEqual(redemption.applied_discount, snapshot)
        self.assertEqual(redemption.document, order)

    def test_persist_rechecks_usage_limits_under_rule_lock(self):
        rule = DiscountRule.objects.create(
            name="Single redemption coupon",
            channel=DiscountRule.Channel.SALES,
            application_type=DiscountRule.ApplicationType.COUPON_CODE,
            coupon_code="LOCKME",
            value_type=DiscountRule.ValueType.FIXED_AMOUNT,
            value=Decimal("4.00"),
            usage_limit=1,
        )
        stale_result = self.engine.calculate(self.context(coupon_codes=("LOCKME",)))
        order = Order.objects.create()
        DiscountRedemption.objects.create(
            rule=rule,
            coupon_code="LOCKME",
            channel=DiscountRule.Channel.SALES,
            discount_amount=Decimal("4.00"),
        )

        with self.assertRaises(DiscountUsageLimitExceeded) as error:
            persist_applied_discounts(document=order, result=stale_result)

        self.assertEqual(error.exception.coupon_codes, ("LOCKME",))
        self.assertEqual(AppliedDiscount.objects.count(), 0)
        self.assertEqual(DiscountRedemption.objects.count(), 1)

    def test_concurrent_stale_results_cannot_both_redeem_single_use_coupon(self):
        # The race: two checkouts both price the coupon while it is still
        # available (zero redemptions), so each independently believes it may
        # apply. Persisting the first redeems it; the second must be rejected by
        # the locked recheck — the usage limit can never be overshot.
        DiscountRule.objects.create(
            name="One-shot coupon",
            channel=DiscountRule.Channel.SALES,
            application_type=DiscountRule.ApplicationType.COUPON_CODE,
            coupon_code="ONESHOT",
            value_type=DiscountRule.ValueType.FIXED_AMOUNT,
            value=Decimal("4.00"),
            usage_limit=1,
        )
        # Both results are calculated up front, before either is persisted, so
        # each sees an available coupon — exactly what two racing requests see.
        result_a = self.engine.calculate(self.context(coupon_codes=("ONESHOT",)))
        result_b = self.engine.calculate(self.context(coupon_codes=("ONESHOT",)))
        self.assertEqual(result_a.discount_total, Decimal("4.00"))
        self.assertEqual(result_b.discount_total, Decimal("4.00"))

        persist_applied_discounts(document=Order.objects.create(), result=result_a)

        with self.assertRaises(DiscountUsageLimitExceeded) as error:
            persist_applied_discounts(document=Order.objects.create(), result=result_b)

        self.assertEqual(error.exception.coupon_codes, ("ONESHOT",))
        self.assertEqual(DiscountRedemption.objects.count(), 1)
        self.assertEqual(AppliedDiscount.objects.count(), 1)

    def test_concurrent_stale_results_respect_per_customer_limit(self):
        # Same race, but the cap is per-customer: a customer who races two
        # checkouts of a once-per-customer coupon may only redeem it once.
        customer = Customer.objects.create(full_name="Repeat buyer")
        DiscountRule.objects.create(
            name="Once per customer",
            channel=DiscountRule.Channel.SALES,
            application_type=DiscountRule.ApplicationType.COUPON_CODE,
            coupon_code="ONCEEACH",
            value_type=DiscountRule.ValueType.FIXED_AMOUNT,
            value=Decimal("4.00"),
            per_customer_usage_limit=1,
        )
        stale_context = self.context(
            customer_id=customer.pk,
            coupon_codes=("ONCEEACH",),
        )
        result_a = self.engine.calculate(stale_context)
        result_b = self.engine.calculate(stale_context)
        self.assertEqual(result_a.discount_total, Decimal("4.00"))
        self.assertEqual(result_b.discount_total, Decimal("4.00"))

        persist_applied_discounts(document=Order.objects.create(), result=result_a)

        with self.assertRaises(DiscountUsageLimitExceeded):
            persist_applied_discounts(document=Order.objects.create(), result=result_b)

        self.assertEqual(
            DiscountRedemption.objects.filter(customer=customer).count(), 1
        )

    def test_persist_locks_discount_rules_for_update(self):
        # Guards the lock itself (the recheck tests above would still pass if the
        # FOR UPDATE were dropped): persistence must take a row lock on every
        # rule it redeems so the recheck is serialized against concurrent
        # redemptions. Skipped on backends without row locking (e.g. SQLite).
        if not connection.features.has_select_for_update:
            self.skipTest("backend does not support select_for_update")
        DiscountRule.objects.create(
            name="Locked coupon",
            channel=DiscountRule.Channel.SALES,
            application_type=DiscountRule.ApplicationType.COUPON_CODE,
            coupon_code="LOCKSQL",
            value_type=DiscountRule.ValueType.FIXED_AMOUNT,
            value=Decimal("4.00"),
            usage_limit=5,
        )
        result = self.engine.calculate(self.context(coupon_codes=("LOCKSQL",)))
        order = Order.objects.create()

        with CaptureQueriesContext(connection) as captured:
            persist_applied_discounts(document=order, result=result)

        self.assertTrue(
            any(
                "discounts_discountrule" in query["sql"].lower()
                and "for update" in query["sql"].lower()
                for query in captured.captured_queries
            ),
            "expected a SELECT ... FOR UPDATE on the discount rule during persist",
        )

    def test_applied_discount_snapshot_survives_rule_edits(self):
        rule = DiscountRule.objects.create(
            name="Original coupon",
            channel=DiscountRule.Channel.SALES,
            application_type=DiscountRule.ApplicationType.COUPON_CODE,
            coupon_code="ORIGINAL",
            value_type=DiscountRule.ValueType.FIXED_AMOUNT,
            value=Decimal("4.00"),
        )
        order = Order.objects.create()
        result = self.engine.calculate(self.context(coupon_codes=("ORIGINAL",)))
        persist_applied_discounts(document=order, result=result)

        rule.name = "Renamed coupon"
        rule.coupon_code = "RENAMED"
        rule.value = Decimal("9.00")
        rule.save()

        snapshot = AppliedDiscount.objects.get()
        self.assertEqual(snapshot.rule, rule)
        self.assertEqual(snapshot.rule_name, "Original coupon")
        self.assertEqual(snapshot.coupon_code, "ORIGINAL")
        self.assertEqual(snapshot.value, Decimal("4.0000"))
        self.assertEqual(snapshot.discount_amount, Decimal("4.00"))


class DiscountRuleApiTests(TestCase):
    def setUp(self):
        self.client = APIClient()
        self.user = get_user_model().objects.create_user(
            username="discount-manager",
            password="pass",
        )
        self.user.user_permissions.add(
            *Permission.objects.filter(
                content_type__app_label__in=("discounts", "sales"),
            )
        )
        self.client.force_authenticate(self.user)
        self.product = create_product_with_default_variant(
            sku="API-1",
            name="API product",
            unit_price=Decimal("12.00"),
        )
        self.customer = Customer.objects.create(full_name="API customer")
        self.supplier = Supplier.objects.create(name="API supplier")
        self.category = ProductCategory.objects.create(name="API category")
        self.product.categories.add(self.category)
        self.variant = ProductVariant.objects.create(
            product=self.product,
            name="API variant",
            sku="API-1-V",
            unit_price=Decimal("14.00"),
        )

    def create_discounted_order(
        self,
        rule,
        *,
        customer=None,
        subtotal=Decimal("40.00"),
        discount_amount=Decimal("5.00"),
        redeemed_at=None,
    ):
        order = Order.objects.create(
            customer=customer,
            status=Order.Status.PAID,
            subtotal=subtotal,
            discount_total=discount_amount,
            total=subtotal - discount_amount,
        )
        document_content_type = ContentType.objects.get_for_model(
            Order,
            for_concrete_model=False,
        )
        applied_discount = AppliedDiscount.objects.create(
            rule=rule,
            rule_name=rule.name,
            coupon_code=rule.coupon_code,
            source=rule.application_type,
            channel=DiscountRule.Channel.SALES,
            scope=rule.scope,
            value_type=rule.value_type,
            value=rule.value,
            priority=rule.priority,
            exclusive=rule.exclusive,
            source_subtotal=subtotal,
            discount_amount=discount_amount,
            document_content_type=document_content_type,
            document_object_id=order.pk,
        )
        redemption = DiscountRedemption.objects.create(
            rule=rule,
            applied_discount=applied_discount,
            coupon_code=rule.coupon_code,
            channel=DiscountRule.Channel.SALES,
            customer=customer,
            discount_amount=discount_amount,
            document_content_type=document_content_type,
            document_object_id=order.pk,
        )
        if redeemed_at is not None:
            DiscountRedemption.objects.filter(pk=redemption.pk).update(
                created_at=redeemed_at,
            )
            AppliedDiscount.objects.filter(pk=applied_discount.pk).update(
                created_at=redeemed_at,
            )
            redemption.refresh_from_db()
        return order, applied_discount, redemption

    def test_create_update_disable_and_archive_discount_rule(self):
        with self.captureOnCommitCallbacks(execute=True):
            response = self.client.post(
                "/api/discount-rules/",
                {
                    "name": "Manager coupon",
                    "channel": DiscountRule.Channel.BOTH,
                    "application_type": DiscountRule.ApplicationType.COUPON_CODE,
                    "coupon_code": " save10 ",
                    "scope": DiscountRule.Scope.DOCUMENT,
                    "value_type": DiscountRule.ValueType.PERCENTAGE,
                    "value": "10.0000",
                    "max_discount_amount": "5.00",
                    "rounding_mode": DiscountRule.RoundingMode.DOWN,
                    "rounding_increment": "0.25",
                    "min_order_subtotal": "20.00",
                    "priority": 10,
                    "exclusive": False,
                    "products": [self.product.pk],
                    "variants": [self.variant.pk],
                    "product_categories": [self.category.pk],
                },
                format="json",
            )

            self.assertEqual(response.status_code, 201, response.data)
            rule_id = response.data["id"]
            self.assertEqual(response.data["coupon_code"], "SAVE10")
            self.assertTrue(response.data["is_active"])
            self.assertEqual(response.data["rounding_mode"], "down")
            self.assertEqual(response.data["rounding_increment"], "0.25")
            self.assertEqual(response.data["products"], [self.product.pk])
            self.assertEqual(response.data["variants"], [self.variant.pk])
            self.assertEqual(response.data["product_variants"], [self.variant.pk])
            self.assertEqual(response.data["product_categories"], [self.category.pk])

            patch_response = self.client.patch(
                f"/api/discount-rules/{rule_id}/",
                {"is_active": False, "priority": 5},
                format="json",
            )

            self.assertEqual(patch_response.status_code, 200, patch_response.data)
            self.assertFalse(patch_response.data["is_active"])
            self.assertEqual(patch_response.data["priority"], 5)

            enable_response = self.client.post(
                f"/api/discount-rules/{rule_id}/enable/"
            )
            self.assertEqual(enable_response.status_code, 200, enable_response.data)
            self.assertTrue(enable_response.data["is_active"])

            disable_response = self.client.post(
                f"/api/discount-rules/{rule_id}/disable/"
            )
            self.assertEqual(disable_response.status_code, 200, disable_response.data)
            self.assertFalse(disable_response.data["is_active"])

            delete_response = self.client.delete(f"/api/discount-rules/{rule_id}/")
            self.assertEqual(delete_response.status_code, 200, delete_response.data)
            self.assertFalse(delete_response.data["is_active"])
            self.assertIn("archived_at", delete_response.data["metadata"])
            self.assertTrue(DiscountRule.objects.filter(pk=rule_id).exists())

        event_names = list(
            AnalyticsEvent.objects.filter(entity_type="discount_rule")
            .order_by("id")
            .values_list("name", flat=True)
        )
        self.assertEqual(
            event_names,
            [
                "discounts.rule.created",
                "discounts.rule.updated",
                "discounts.rule.enabled",
                "discounts.rule.disabled",
                "discounts.rule.archived",
            ],
        )
        updated_event = AnalyticsEvent.objects.get(name="discounts.rule.updated")
        self.assertEqual(
            updated_event.attributes["changed_fields"],
            ["is_active", "priority"],
        )
        self.assertEqual(updated_event.metrics["changed_field_count"], 2)

    def test_discount_rule_accepts_legacy_product_variants_alias(self):
        response = self.client.post(
            "/api/discount-rules/",
            {
                "name": "Legacy variant alias",
                "channel": DiscountRule.Channel.SALES,
                "application_type": DiscountRule.ApplicationType.AUTOMATIC,
                "scope": DiscountRule.Scope.LINE,
                "value_type": DiscountRule.ValueType.FIXED_AMOUNT,
                "value": "1.0000",
                "product_variants": [self.variant.pk],
            },
            format="json",
        )

        self.assertEqual(response.status_code, 201, response.data)
        self.assertEqual(response.data["variants"], [self.variant.pk])
        self.assertEqual(response.data["product_variants"], [self.variant.pk])

    def test_api_rejects_ambiguous_or_unsafe_discount_configurations(self):
        invalid_cases = [
            (
                {
                    "name": "Automatic with code",
                    "application_type": DiscountRule.ApplicationType.AUTOMATIC,
                    "coupon_code": "AUTO",
                    "scope": DiscountRule.Scope.DOCUMENT,
                    "value_type": DiscountRule.ValueType.FIXED_AMOUNT,
                    "value": "1.0000",
                },
                "coupon_code",
            ),
            (
                {
                    "name": "Missing coupon code",
                    "application_type": DiscountRule.ApplicationType.COUPON_CODE,
                    "scope": DiscountRule.Scope.DOCUMENT,
                    "value_type": DiscountRule.ValueType.FIXED_AMOUNT,
                    "value": "1.0000",
                },
                "coupon_code",
            ),
            (
                {
                    "name": "Too much percentage",
                    "scope": DiscountRule.Scope.DOCUMENT,
                    "value_type": DiscountRule.ValueType.PERCENTAGE,
                    "value": "101.0000",
                },
                "value",
            ),
            (
                {
                    "name": "Fixed price document",
                    "scope": DiscountRule.Scope.DOCUMENT,
                    "value_type": DiscountRule.ValueType.FIXED_PRICE,
                    "value": "9.0000",
                },
                "scope",
            ),
            (
                {
                    "name": "Unit document",
                    "scope": DiscountRule.Scope.DOCUMENT,
                    "value_type": DiscountRule.ValueType.FIXED_UNIT_AMOUNT,
                    "value": "1.0000",
                },
                "scope",
            ),
            (
                {
                    "name": "Purchasing customer constraint",
                    "channel": DiscountRule.Channel.PURCHASING,
                    "scope": DiscountRule.Scope.DOCUMENT,
                    "value_type": DiscountRule.ValueType.FIXED_AMOUNT,
                    "value": "1.0000",
                    "customers": [self.customer.pk],
                },
                "customers",
            ),
            (
                {
                    "name": "Sales supplier constraint",
                    "channel": DiscountRule.Channel.SALES,
                    "scope": DiscountRule.Scope.DOCUMENT,
                    "value_type": DiscountRule.ValueType.FIXED_AMOUNT,
                    "value": "1.0000",
                    "suppliers": [self.supplier.pk],
                },
                "suppliers",
            ),
            (
                {
                    "name": "Missing rounding increment",
                    "scope": DiscountRule.Scope.DOCUMENT,
                    "value_type": DiscountRule.ValueType.FIXED_AMOUNT,
                    "value": "1.0000",
                    "rounding_mode": DiscountRule.RoundingMode.DOWN,
                },
                "rounding_increment",
            ),
        ]

        for payload, field in invalid_cases:
            with self.subTest(payload["name"]):
                response = self.client.post(
                    "/api/discount-rules/",
                    payload,
                    format="json",
                )
                self.assertEqual(response.status_code, 400, response.data)
                self.assertIn(field, response.data)

    def test_api_rejects_duplicate_coupon_codes_cleanly(self):
        DiscountRule.objects.create(
            name="Existing coupon",
            application_type=DiscountRule.ApplicationType.COUPON_CODE,
            coupon_code="SAVE",
            scope=DiscountRule.Scope.DOCUMENT,
            value_type=DiscountRule.ValueType.FIXED_AMOUNT,
            value=Decimal("1.00"),
        )

        response = self.client.post(
            "/api/discount-rules/",
            {
                "name": "Duplicate coupon",
                "application_type": DiscountRule.ApplicationType.COUPON_CODE,
                "coupon_code": " save ",
                "scope": DiscountRule.Scope.DOCUMENT,
                "value_type": DiscountRule.ValueType.FIXED_AMOUNT,
                "value": "1.0000",
            },
            format="json",
        )

        self.assertEqual(response.status_code, 400, response.data)
        self.assertIn("coupon_code", response.data)

    def test_discount_rule_performance_reports_usage_and_baseline(self):
        rule = DiscountRule.objects.create(
            name="Weekend coupon",
            application_type=DiscountRule.ApplicationType.COUPON_CODE,
            coupon_code="WEEKEND",
            channel=DiscountRule.Channel.SALES,
            scope=DiscountRule.Scope.DOCUMENT,
            value_type=DiscountRule.ValueType.FIXED_AMOUNT,
            value=Decimal("5.00"),
            usage_limit=10,
        )
        now = timezone.now()
        baseline_order = Order.objects.create(
            customer=self.customer,
            status=Order.Status.PAID,
            subtotal=Decimal("30.00"),
            discount_total=Decimal("0.00"),
            total=Decimal("30.00"),
        )
        Order.objects.filter(pk=baseline_order.pk).update(
            created_at=now - timedelta(days=20),
        )
        self.create_discounted_order(
            rule,
            customer=self.customer,
            subtotal=Decimal("40.00"),
            discount_amount=Decimal("5.00"),
            redeemed_at=now,
        )

        response = self.client.get(f"/api/discount-rules/{rule.pk}/performance/")

        self.assertEqual(response.status_code, 200, response.data)
        summary = response.data["summary"]
        self.assertEqual(summary["redemption_count"], 1)
        self.assertEqual(summary["document_count"], 1)
        self.assertEqual(summary["unique_customer_count"], 1)
        self.assertEqual(summary["beneficiary_count"], 1)
        self.assertEqual(summary["influenced_gross"], "40.00")
        self.assertEqual(summary["discount_amount"], "5.00")
        self.assertEqual(summary["influenced_net"], "35.00")
        self.assertEqual(summary["remaining_usage"], 9)
        self.assertEqual(response.data["channel_breakdown"][0]["channel"], "sales")
        self.assertEqual(response.data["monthly_trend"][0]["redemption_count"], 1)
        incrementality = response.data["incrementality"]
        self.assertEqual(incrementality["baseline_document_count"], 1)
        self.assertEqual(incrementality["baseline_gross"], "30.00")
        self.assertEqual(incrementality["confidence"], "low")

    def test_discount_rule_beneficiaries_are_grouped_and_paginated(self):
        rule = DiscountRule.objects.create(
            name="Customer coupon",
            application_type=DiscountRule.ApplicationType.COUPON_CODE,
            coupon_code="CUSTOMER",
            channel=DiscountRule.Channel.SALES,
            scope=DiscountRule.Scope.DOCUMENT,
            value_type=DiscountRule.ValueType.FIXED_AMOUNT,
            value=Decimal("2.00"),
        )
        self.create_discounted_order(
            rule,
            customer=self.customer,
            subtotal=Decimal("20.00"),
            discount_amount=Decimal("2.00"),
        )
        self.create_discounted_order(
            rule,
            customer=self.customer,
            subtotal=Decimal("30.00"),
            discount_amount=Decimal("2.00"),
        )

        response = self.client.get(f"/api/discount-rules/{rule.pk}/beneficiaries/")

        self.assertEqual(response.status_code, 200, response.data)
        self.assertEqual(response.data["count"], 1)
        beneficiary = response.data["results"][0]
        self.assertEqual(beneficiary["party_type"], "customer")
        self.assertEqual(beneficiary["party_id"], self.customer.pk)
        self.assertEqual(beneficiary["name"], self.customer.full_name)
        self.assertEqual(beneficiary["redemption_count"], 2)
        self.assertEqual(beneficiary["document_count"], 2)
        self.assertEqual(beneficiary["discount_amount"], "4.00")
        self.assertEqual(beneficiary["influenced_gross"], "50.00")
        self.assertEqual(beneficiary["influenced_net"], "46.00")

    def test_sales_discount_preview_reports_automatic_and_coupon_applications(self):
        DiscountRule.objects.create(
            name="Automatic sales",
            channel=DiscountRule.Channel.SALES,
            scope=DiscountRule.Scope.DOCUMENT,
            value_type=DiscountRule.ValueType.PERCENTAGE,
            value=Decimal("10.00"),
            exclusive=False,
            priority=1,
        )
        DiscountRule.objects.create(
            name="Coupon sales",
            channel=DiscountRule.Channel.SALES,
            application_type=DiscountRule.ApplicationType.COUPON_CODE,
            coupon_code="SAVE2",
            scope=DiscountRule.Scope.DOCUMENT,
            value_type=DiscountRule.ValueType.FIXED_AMOUNT,
            value=Decimal("2.00"),
            exclusive=False,
            priority=2,
        )

        response = self.client.post(
            "/api/orders/discount-preview/",
            {
                "lines": [{"variant": self.product.default_variant.pk, "quantity": 2}],
                "coupon_code": "save2",
            },
            format="json",
        )

        self.assertEqual(response.status_code, 200, response.data)
        self.assertEqual(response.data["subtotal"], "24.00")
        self.assertEqual(response.data["discount_total"], "4.40")
        self.assertEqual(response.data["total"], "19.60")
        self.assertEqual(response.data["unapplied_coupon_codes"], [])
        self.assertEqual(
            [discount["rule_name"] for discount in response.data["applied_discounts"]],
            ["Automatic sales", "Coupon sales"],
        )

    def test_sales_discount_preview_reports_rounding_metadata(self):
        DiscountRule.objects.create(
            name="Rounded sales",
            channel=DiscountRule.Channel.SALES,
            scope=DiscountRule.Scope.DOCUMENT,
            value_type=DiscountRule.ValueType.PERCENTAGE,
            value=Decimal("10.00"),
            rounding_mode=DiscountRule.RoundingMode.DOWN,
            rounding_increment=Decimal("5.00"),
        )

        response = self.client.post(
            "/api/orders/discount-preview/",
            {
                "lines": [{"variant": self.product.default_variant.pk, "quantity": 2}],
            },
            format="json",
        )

        self.assertEqual(response.status_code, 200, response.data)
        self.assertEqual(response.data["subtotal"], "24.00")
        self.assertEqual(response.data["discount_total"], "4.00")
        self.assertEqual(response.data["total"], "20.00")
        discount = response.data["applied_discounts"][0]
        self.assertEqual(discount["rounding_mode"], "down")
        self.assertEqual(discount["rounding_increment"], "5.00")
        self.assertEqual(discount["unrounded_discount_amount"], "2.40")
        self.assertEqual(discount["rounding_adjustment"], "1.60")

    def test_sales_discount_preview_reports_unapplied_coupon_codes(self):
        response = self.client.post(
            "/api/orders/discount-preview/",
            {
                "lines": [{"variant": self.product.default_variant.pk, "quantity": 1}],
                "coupon_code": "missing",
            },
            format="json",
        )

        self.assertEqual(response.status_code, 200, response.data)
        self.assertEqual(response.data["discount_total"], "0.00")
        self.assertEqual(response.data["unapplied_coupon_codes"], ["MISSING"])

    def test_sales_discount_preview_applies_category_constraints(self):
        rule = DiscountRule.objects.create(
            name="Category sales",
            channel=DiscountRule.Channel.SALES,
            scope=DiscountRule.Scope.LINE,
            value_type=DiscountRule.ValueType.PERCENTAGE,
            value=Decimal("10.00"),
        )
        rule.product_categories.add(self.category)

        response = self.client.post(
            "/api/orders/discount-preview/",
            {
                "lines": [{"variant": self.product.default_variant.pk, "quantity": 2}],
            },
            format="json",
        )

        self.assertEqual(response.status_code, 200, response.data)
        self.assertEqual(response.data["discount_total"], "2.40")
        self.assertEqual(
            [discount["rule_name"] for discount in response.data["applied_discounts"]],
            ["Category sales"],
        )
