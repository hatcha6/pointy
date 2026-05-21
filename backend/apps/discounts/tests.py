from decimal import Decimal

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Permission
from django.test import TestCase
from django.utils import timezone
from rest_framework.test import APIClient

from apps.catalog.models import Product, ProductCategory, ProductVariant
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
        self.product = Product.objects.create(
            sku="SKU-1",
            name="Product one",
            unit_price=Decimal("10.00"),
        )
        self.other_product = Product.objects.create(
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
        rule.product_variants.add(variant)

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
        self.assertEqual(snapshot.discount_amount, Decimal("4.00"))
        self.assertEqual(snapshot.document, order)
        self.assertEqual(snapshot.allocations[0]["amount"], "2.00")
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
        self.product = Product.objects.create(
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

    def test_create_update_disable_and_archive_discount_rule(self):
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
                "min_order_subtotal": "20.00",
                "priority": 10,
                "exclusive": False,
                "products": [self.product.pk],
                "product_variants": [self.variant.pk],
                "product_categories": [self.category.pk],
            },
            format="json",
        )

        self.assertEqual(response.status_code, 201, response.data)
        rule_id = response.data["id"]
        self.assertEqual(response.data["coupon_code"], "SAVE10")
        self.assertTrue(response.data["is_active"])
        self.assertEqual(response.data["products"], [self.product.pk])
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

        enable_response = self.client.post(f"/api/discount-rules/{rule_id}/enable/")
        self.assertEqual(enable_response.status_code, 200, enable_response.data)
        self.assertTrue(enable_response.data["is_active"])

        disable_response = self.client.post(f"/api/discount-rules/{rule_id}/disable/")
        self.assertEqual(disable_response.status_code, 200, disable_response.data)
        self.assertFalse(disable_response.data["is_active"])

        delete_response = self.client.delete(f"/api/discount-rules/{rule_id}/")
        self.assertEqual(delete_response.status_code, 200, delete_response.data)
        self.assertFalse(delete_response.data["is_active"])
        self.assertIn("archived_at", delete_response.data["metadata"])
        self.assertTrue(DiscountRule.objects.filter(pk=rule_id).exists())

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
                "lines": [{"product": self.product.pk, "quantity": 2}],
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

    def test_sales_discount_preview_reports_unapplied_coupon_codes(self):
        response = self.client.post(
            "/api/orders/discount-preview/",
            {
                "lines": [{"product": self.product.pk, "quantity": 1}],
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
                "lines": [{"product": self.product.pk, "quantity": 2}],
            },
            format="json",
        )

        self.assertEqual(response.status_code, 200, response.data)
        self.assertEqual(response.data["discount_total"], "2.40")
        self.assertEqual(
            [discount["rule_name"] for discount in response.data["applied_discounts"]],
            ["Category sales"],
        )
