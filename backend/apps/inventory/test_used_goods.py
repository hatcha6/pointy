"""The rest of the used-goods trade: prices, refurbishment, trade-ins, attributes.

Everything here exists because an article of used stock is *itself* rather than
an instance of a model: two handsets of the same model were bought at two prices,
one of them had a screen fitted, and they sell at two prices. A quantity-only
system can hold none of that, and the failure mode is not an error message — it
is a margin report that quietly averages the two together.
"""

from decimal import Decimal

from django.test import TestCase
from django.utils import timezone

from apps.catalog.models import Product
from apps.customers.models import Asset, AssetType, Customer
from apps.discounts.models import DiscountRule
from apps.operations.models import Job, JobMaterial, WorkflowTemplate
from apps.operations.refurbishment import capitalise, refurb_cost_of, release
from apps.sales.models import RegisterSession
from apps.sales.services import checkout_order

from .models import StockUnit, UnitAttributeDefinition
from .tracked_testing import receive, tracked_product
from .unit_attributes import validate_attributes

IMEI_A = "351234567890116"
IMEI_B = "351234567890124"
IMEI_C = "351234567890132"

_TILL = 0


def _session():
    global _TILL
    _TILL += 1
    return RegisterSession.objects.create(
        owner_key=f"used-till-{_TILL}",
        status=RegisterSession.Status.OPEN,
        opening_cash=Decimal("0.00"),
    )


def _sell(lines, payments=None):
    total = sum(
        (
            Decimal(line.get("effective_unit_price", 0)) * Decimal(line["quantity"])
            for line in lines
        ),
        Decimal("0.00"),
    )
    return checkout_order(
        register_session=_session(),
        lines_data=lines,
        payments_data=payments
        if payments is not None
        else [{"method": "cash", "amount": total}],
    )


class PerUnitPriceTests(TestCase):
    """§5.7: the line takes the article's own asking price, or the variant's."""

    def setUp(self):
        self.product = tracked_product(
            name="iPhone 13",
            sku="IP13",
            mode=Product.TrackingMode.SERIAL,
            unit_price="1500.00",
        )
        self.variant = self.product.default_variant
        receive(
            variant=self.variant,
            quantity=3,
            unit_cost="1000.00",
            units=[
                {"code": IMEI_A, "unit_cost": Decimal("1200.00"),
                 "list_price": Decimal("1400.00")},
                {"code": IMEI_B, "unit_cost": Decimal("900.00"),
                 "list_price": Decimal("1300.00")},
                {"code": IMEI_C, "unit_cost": Decimal("900.00")},
            ],
        )

    def test_the_serializer_resolves_the_article_s_own_price(self):
        from apps.sales.serializers import CheckoutLineSerializer

        unit = StockUnit.objects.get(code_normalized=IMEI_A)
        serializer = CheckoutLineSerializer(
            data={
                "variant": self.variant.pk,
                "quantity": "1",
                "stock_units": [unit.pk],
            }
        )
        serializer.parent = _ParentWith({unit.pk: unit})
        serializer.is_valid(raise_exception=True)
        self.assertEqual(
            serializer.validated_data["effective_unit_price"], Decimal("1400.00")
        )

    def test_an_article_with_no_price_of_its_own_takes_the_variant_s(self):
        from apps.sales.serializers import CheckoutLineSerializer

        unit = StockUnit.objects.get(code_normalized=IMEI_C)
        serializer = CheckoutLineSerializer(
            data={
                "variant": self.variant.pk,
                "quantity": "1",
                "stock_units": [unit.pk],
            }
        )
        serializer.parent = _ParentWith({unit.pk: unit})
        serializer.is_valid(raise_exception=True)
        self.assertEqual(
            serializer.validated_data["effective_unit_price"], Decimal("1500.00")
        )

    def test_an_article_priced_at_zero_is_not_charged_the_variant_s_price(self):
        """A warranty replacement handed over at no charge is a real thing, and
        a truthiness check would quietly bill it at 1,500."""
        from apps.sales.serializers import CheckoutLineSerializer

        unit = StockUnit.objects.get(code_normalized=IMEI_C)
        unit.list_price = Decimal("0.00")
        unit.save(update_fields=["list_price"])
        serializer = CheckoutLineSerializer(
            data={
                "variant": self.variant.pk,
                "quantity": "1",
                "stock_units": [unit.pk],
            }
        )
        serializer.parent = _ParentWith({unit.pk: unit})
        serializer.is_valid(raise_exception=True)
        self.assertEqual(
            serializer.validated_data["effective_unit_price"], Decimal("0.00")
        )

    def test_the_loss_guard_reads_the_article_not_the_shelf(self):
        """A blended cost would let the expensive handset out at the cheap
        one's floor — which is precisely the bug the guard exists to stop."""
        from apps.sales.services import checkout_loss_lines

        expensive = StockUnit.objects.get(code_normalized=IMEI_A)
        losses = checkout_loss_lines(
            [
                {
                    "variant": self.variant,
                    "quantity": Decimal("1"),
                    "effective_unit_price": Decimal("1100.00"),
                    "stock_units": [expensive.pk],
                    "unit_factor": Decimal("1"),
                }
            ]
        )
        self.assertEqual(len(losses), 1)
        # Its own 1,200, not the bin's average of 1,000.
        self.assertEqual(losses[0]["unit_cost"], "1200.00")

    def test_a_cheaper_article_at_the_same_price_is_no_loss(self):
        from apps.sales.services import checkout_loss_lines

        cheap = StockUnit.objects.get(code_normalized=IMEI_B)
        losses = checkout_loss_lines(
            [
                {
                    "variant": self.variant,
                    "quantity": Decimal("1"),
                    "effective_unit_price": Decimal("1100.00"),
                    "stock_units": [cheap.pk],
                    "unit_factor": Decimal("1"),
                }
            ]
        )
        self.assertEqual(losses, [])


class _ParentWith:
    """A stand-in for the list serializer's bulk preload."""

    parent = None

    def __init__(self, units):
        self.preloaded_units = units
        self.preloaded_variants = {}


class PooledPromotionTests(TestCase):
    """§5.7's second half, verified rather than assumed.

    Buy-two-get-one over three handsets at three prices must give away the
    *cheapest*. It already did — the pool has been most-expensive-first since
    the promotions landed — and this test is what stops that quietly changing
    once each line carries its own price.
    """

    def setUp(self):
        self.product = tracked_product(
            name="سماعة",
            sku="HP-1",
            mode=Product.TrackingMode.SERIAL,
            unit_price="100.00",
        )
        self.variant = self.product.default_variant
        receive(
            variant=self.variant,
            quantity=3,
            unit_cost="10.00",
            units=[{"code": f"HP-{index}"} for index in range(3)],
        )

    def test_the_free_unit_is_the_cheapest_one(self):
        from apps.discounts.services import DiscountEngine
        from apps.sales.services import prepare_discount_lines

        rule = DiscountRule.objects.create(
            name="اشترِ اثنتين واحصل على واحدة",
            scope=DiscountRule.Scope.LINE,
            value_type=DiscountRule.ValueType.BUY_X_GET_Y,
            buy_quantity=2,
            get_quantity=1,
            reward_type=DiscountRule.BuyGetReward.FREE,
            channel=DiscountRule.Channel.SALES,
            # Ignored for a FREE reward (treated as 100% off), but the column
            # carries a positive-value validator.
            value=Decimal("100.00"),
            is_active=True,
        )
        rule.products.add(self.product)

        lines = prepare_discount_lines(
            [
                {"variant": self.variant, "quantity": Decimal("1"),
                 "effective_unit_price": Decimal(price)}
                for price in ("140.00", "130.00", "120.00")
            ]
        )
        result = DiscountEngine().calculate(
            _context(lines, self.variant)
        )
        allocations = {
            allocation.line_key: allocation.amount
            for application in result.applications
            for allocation in application.allocations
        }
        # The 120 line is the one given away, not the 140.
        self.assertEqual(allocations.get("2"), Decimal("120.00"))
        self.assertNotIn("0", allocations)


def _context(lines, variant):
    from apps.discounts.models import DiscountRule
    from apps.discounts.services import DiscountContext

    return DiscountContext(
        channel=DiscountRule.Channel.SALES,
        lines=lines,
        customer_id=None,
        supplier_id=None,
    )


class RefurbishmentTests(TestCase):
    """§5.6: the screen the shop fitted is part of what the handset cost."""

    def setUp(self):
        self.product = tracked_product(
            name="iPhone 12",
            sku="IP12",
            mode=Product.TrackingMode.SERIAL,
            unit_price="1300.00",
        )
        self.variant = self.product.default_variant
        receive(
            variant=self.variant,
            quantity=1,
            unit_cost="1200.00",
            units=[{"code": IMEI_A}],
        )
        self.unit = StockUnit.objects.get(code_normalized=IMEI_A)
        self.part = tracked_product(
            name="شاشة",
            sku="SCR-1",
            mode=Product.TrackingMode.QUANTITY,
            unit_price="200.00",
        )

    def _job(self):
        template = WorkflowTemplate.objects.create(
            name="إصلاح", job_type=WorkflowTemplate.JobType.REPAIR
        )
        start = template.stages.create(
            code="open", name="مفتوح", is_initial=True, display_order=0
        )
        done = template.stages.create(
            code="done", name="منتهٍ", is_terminal=True, display_order=1
        )
        job = Job.objects.create(
            job_type=WorkflowTemplate.JobType.REPAIR,
            workflow_template=template,
            current_stage=start,
            stock_unit=self.unit,
        )
        JobMaterial.objects.create(
            job=job,
            variant=self.part.default_variant,
            quantity=Decimal("1"),
            unit_cost=Decimal("150.00"),
            unit_price=Decimal("200.00"),
            consumed_at=timezone.now(),
        )
        return job, done

    def test_completing_a_job_capitalises_its_cost_into_the_article(self):
        job, _ = self._job()
        self.assertEqual(refurb_cost_of(job), Decimal("150.00"))

        capitalise(job)

        self.unit.refresh_from_db()
        self.assertEqual(self.unit.refurb_cost, Decimal("150.00"))
        # 1,200 + 150: the number the loss guard now compares against, which is
        # the whole point.
        self.assertEqual(self.unit.stock_value, Decimal("1350.000000"))

    def test_capitalising_twice_does_not_charge_twice(self):
        job, _ = self._job()
        capitalise(job)
        capitalise(job)

        self.unit.refresh_from_db()
        self.assertEqual(self.unit.refurb_cost, Decimal("150.00"))

    def test_reopening_the_job_takes_the_cost_back_off(self):
        job, _ = self._job()
        capitalise(job)

        release(job)

        self.unit.refresh_from_db()
        self.assertEqual(self.unit.refurb_cost, Decimal("0.00"))

    def test_a_refurbished_handset_cannot_be_sold_at_its_purchase_price(self):
        from apps.sales.services import checkout_loss_lines

        job, _ = self._job()
        capitalise(job)

        losses = checkout_loss_lines(
            [
                {
                    "variant": self.variant,
                    "quantity": Decimal("1"),
                    "effective_unit_price": Decimal("1300.00"),
                    "stock_units": [self.unit.pk],
                    "unit_factor": Decimal("1"),
                }
            ]
        )
        self.assertEqual(len(losses), 1)
        self.assertEqual(losses[0]["unit_cost"], "1350.00")


class WarrantyAndAssetTests(TestCase):
    """§4.8 and §6.4: the handset we sold arrives for repair knowing its history."""

    def setUp(self):
        self.asset_type = AssetType.objects.get(slug="phone")
        self.product = tracked_product(
            name="iPhone 14",
            sku="IP14",
            mode=Product.TrackingMode.SERIAL,
            unit_price="2000.00",
        )
        self.product.asset_type = self.asset_type
        self.product.warranty_days = 365
        self.product.save(update_fields=["asset_type", "warranty_days"])
        self.variant = self.product.default_variant
        receive(
            variant=self.variant,
            quantity=1,
            unit_cost="1500.00",
            units=[{"code": IMEI_A, "identifier_kind": "imei"}],
        )
        self.unit = StockUnit.objects.get(code_normalized=IMEI_A)
        self.customer = Customer.objects.create(full_name="زبون")

    def test_selling_to_a_named_customer_registers_their_asset(self):
        checkout_order(
            register_session=_session(),
            lines_data=[
                {
                    "variant": self.variant,
                    "quantity": Decimal("1"),
                    "effective_unit_price": Decimal("2000.00"),
                    "stock_units": [self.unit.pk],
                }
            ],
            payments_data=[{"method": "cash", "amount": Decimal("2000.00")}],
            customer=self.customer,
        )

        self.unit.refresh_from_db()
        self.assertIsNotNone(self.unit.asset_id)
        asset = Asset.objects.get(pk=self.unit.asset_id)
        self.assertEqual(asset.customer_id, self.customer.pk)
        self.assertEqual(asset.imei, IMEI_A)
        # Warranty runs from the sale, stamped rather than derived: a corrected
        # ``warranty_days`` next month must not silently re-cover a handset that
        # went out of cover last week.
        self.assertIsNotNone(self.unit.warranty_expires_on)

    def test_a_walk_in_sale_creates_no_asset_and_still_records_the_sale(self):
        checkout_order(
            register_session=_session(),
            lines_data=[
                {
                    "variant": self.variant,
                    "quantity": Decimal("1"),
                    "effective_unit_price": Decimal("2000.00"),
                    "stock_units": [self.unit.pk],
                }
            ],
            payments_data=[{"method": "cash", "amount": Decimal("2000.00")}],
        )

        self.unit.refresh_from_db()
        self.assertEqual(self.unit.status, StockUnit.Status.SOLD)
        self.assertIsNone(self.unit.asset_id)
        self.assertEqual(Asset.objects.count(), 0)


class UnitAttributeTests(TestCase):
    def setUp(self):
        self.asset_type = AssetType.objects.get(slug="phone")

    def test_the_seeded_intake_sheet_is_there(self):
        keys = set(
            UnitAttributeDefinition.objects.filter(
                asset_type=self.asset_type
            ).values_list("key", flat=True)
        )
        self.assertIn("battery_health", keys)
        self.assertIn("condition_grade", keys)

    def test_a_percent_is_stored_as_a_number_so_it_sorts(self):
        cleaned = validate_attributes(
            {"battery_health": "85"}, asset_type_id=self.asset_type.pk, partial=True
        )
        # A number, not the string "85" — otherwise "9" sorts above "85".
        self.assertEqual(cleaned["battery_health"], 85.0)

    def test_a_percent_outside_its_range_is_refused(self):
        from rest_framework import serializers as drf_serializers

        with self.assertRaises(drf_serializers.ValidationError):
            validate_attributes(
                {"battery_health": "180"},
                asset_type_id=self.asset_type.pk,
                partial=True,
            )

    def test_a_choice_outside_its_list_is_refused(self):
        from rest_framework import serializers as drf_serializers

        with self.assertRaises(drf_serializers.ValidationError):
            validate_attributes(
                {"condition_grade": "sparkling"},
                asset_type_id=self.asset_type.pk,
                partial=True,
            )

    def test_a_key_nobody_defines_is_dropped_not_refused(self):
        """A shop that deleted a definition has not invalidated the articles
        that carried it, and a 400 on every later save of those articles would
        be a worse answer than quietly ceasing to show the field."""
        cleaned = validate_attributes(
            {"battery_health": 90, "was_a_field_once": "x"},
            asset_type_id=self.asset_type.pk,
            partial=True,
        )
        self.assertEqual(cleaned, {"battery_health": 90.0})
