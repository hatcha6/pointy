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

from .integrity import assert_tracking_invariants
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
        # And the shelf agrees with the article. Every other test in this phase
        # asserts the invariants; these four did not, which is how the bin and
        # the units were allowed to disagree the moment a screen was fitted.
        assert_tracking_invariants()

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


class TwoOfTheSameModelOnOneInvoiceTests(TestCase):
    """The used-goods shop's ordinary Tuesday, and the case nothing covered.

    Two handsets of the same model, bought at two prices, sold at two prices, on
    one invoice. §6.3 makes this the *normal* shape — quantity is locked to 1 and
    a second of the same model becomes a second line with its own unit — so every
    per-article number has to survive the same variant appearing twice.
    """

    def setUp(self):
        self.product = tracked_product(
            name="iPhone 13",
            sku="IP13-TWO",
            mode=Product.TrackingMode.SERIAL,
            unit_price="1500.00",
        )
        self.variant = self.product.default_variant
        receive(
            variant=self.variant,
            quantity=2,
            unit_cost="1000.00",
            units=[
                {"code": IMEI_A, "unit_cost": Decimal("1200.00"),
                 "list_price": Decimal("1400.00")},
                {"code": IMEI_B, "unit_cost": Decimal("800.00"),
                 "list_price": Decimal("1250.00")},
            ],
        )
        self.expensive = StockUnit.objects.get(code_normalized=IMEI_A)
        self.cheap = StockUnit.objects.get(code_normalized=IMEI_B)

    def _sell_both(self):
        return _sell(
            [
                {
                    "variant": self.variant,
                    "quantity": Decimal("1"),
                    "effective_unit_price": Decimal("1400.00"),
                    "stock_units": [self.expensive.pk],
                },
                {
                    "variant": self.variant,
                    "quantity": Decimal("1"),
                    "effective_unit_price": Decimal("1250.00"),
                    "stock_units": [self.cheap.pk],
                },
            ]
        )

    def test_each_article_records_the_price_it_actually_fetched(self):
        self._sell_both()

        self.expensive.refresh_from_db()
        self.cheap.refresh_from_db()
        self.assertEqual(self.expensive.sold_price, Decimal("1400.00"))
        self.assertEqual(self.cheap.sold_price, Decimal("1250.00"))

    def test_each_article_is_stamped_onto_the_line_that_sold_it(self):
        order = self._sell_both()

        self.expensive.refresh_from_db()
        self.cheap.refresh_from_db()
        self.assertNotEqual(
            self.expensive.sold_order_line_id, self.cheap.sold_order_line_id
        )
        lines = {line.pk: line for line in order.lines.all()}
        self.assertEqual(
            lines[self.expensive.sold_order_line_id].unit_price, Decimal("1400.00")
        )
        self.assertEqual(
            lines[self.cheap.sold_order_line_id].unit_price, Decimal("1250.00")
        )

    def test_each_line_carries_the_cost_of_the_article_it_sold(self):
        """Gross profit per line, which a blended rate quietly averages away."""
        order = self._sell_both()

        self.expensive.refresh_from_db()
        self.cheap.refresh_from_db()
        lines = {line.pk: line for line in order.lines.all()}
        self.assertEqual(
            lines[self.expensive.sold_order_line_id].unit_cost, Decimal("1200.00")
        )
        self.assertEqual(
            lines[self.cheap.sold_order_line_id].unit_cost, Decimal("800.00")
        )

    def test_returning_one_brings_back_the_article_that_was_returned(self):
        """The worst of it: the wrong handset comes back.

        A return reads the units off the line it is refunding, so two articles
        sharing one line means returning the cheap one puts the *expensive* one
        back on the shelf — and leaves a sold handset that is physically in the
        customer's hands marked as stock nobody can find.
        """
        from apps.sales.services import return_order_items

        order = self._sell_both()
        self.cheap.refresh_from_db()
        return_order_items(
            order=order,
            lines=[(self.cheap.sold_order_line, 1)],
            reason="عاد بعد يومين",
        )

        self.expensive.refresh_from_db()
        self.cheap.refresh_from_db()
        self.assertEqual(self.cheap.status, StockUnit.Status.IN_STOCK)
        self.assertEqual(self.expensive.status, StockUnit.Status.SOLD)


class TradeInTests(TestCase):
    """A handset in part-payment for a handset — the used-phone shop's other
    daily transaction, and the one Phase C shipped with no test at all.

    The claim under test is §6.2's: a trade-in needs **no new tender**. A counter
    purchase pays out of the drawer, a sale pays into it, and
    ``RegisterSession.expected_cash`` nets the two — so a 1,400 sale against a
    500 trade-in must leave the till expecting exactly 900 more than it started
    with, arrived at from two documents that are each true on their own.
    """

    def setUp(self):
        from django.contrib.auth import get_user_model
        from rest_framework.test import APIClient

        from apps.core.roles import MANAGER_GROUP, ensure_role_groups
        from apps.customers.models import Customer
        from apps.purchasing.models import Supplier
        from apps.sales.models import RegisterSession

        ensure_role_groups()
        from django.contrib.auth.models import Group

        self.user = get_user_model().objects.create_user(
            username="trader", password="pw"
        )
        self.user.groups.add(Group.objects.get(name=MANAGER_GROUP))
        self.client = APIClient()
        self.client.force_authenticate(user=self.user)
        self.session = RegisterSession.objects.create(
            owner=self.user,
            owner_key=f"user:{self.user.pk}",
            status=RegisterSession.Status.OPEN,
            opening_cash=Decimal("0.00"),
        )
        self.product = tracked_product(
            name="iPhone 14",
            sku="IP14-TRADE",
            mode=Product.TrackingMode.SERIAL,
            unit_price="1400.00",
        )
        self.variant = self.product.default_variant
        receive(
            variant=self.variant,
            quantity=1,
            unit_cost="1000.00",
            units=[{"code": IMEI_A}],
        )
        self.outgoing = StockUnit.objects.get(code_normalized=IMEI_A)
        self.seller = Supplier.objects.create(name="زبون")
        self.customer = Customer.objects.create(full_name="مشتري")

    def _checkout(self, *, trade_in_price="500.00", sale_price="1400.00",
                  cash=None):
        from django.urls import reverse

        cash = sale_price if cash is None else cash
        return self.client.post(
            reverse("order-checkout"),
            {
                "lines": [
                    {
                        "variant": self.variant.pk,
                        "quantity": "1",
                        "stock_units": [self.outgoing.pk],
                        "effective_unit_price": sale_price,
                    }
                ],
                "payments": [{"method": "cash", "amount": cash}],
                "trade_in": {
                    "supplier": self.seller.pk,
                    "lines": [
                        {
                            "variant": self.variant.pk,
                            "quantity": "1",
                            "unit_cost": trade_in_price,
                            "units": [{"code": IMEI_B}],
                        }
                    ],
                },
            },
            format="json",
        )

    def test_one_act_writes_a_purchase_a_sale_and_the_row_that_links_them(self):
        from apps.sales.models import TradeIn

        response = self._checkout()

        self.assertEqual(response.status_code, 201, response.data)
        link = TradeIn.objects.get()
        self.assertEqual(link.trade_in_amount, Decimal("500.00"))
        self.assertEqual(link.sale_amount, Decimal("1400.00"))
        self.assertEqual(link.net_amount, Decimal("900.00"))
        self.assertEqual(link.order_id, response.data["id"])

    def test_the_incoming_handset_arrives_as_an_identified_article(self):
        self._checkout()

        incoming = StockUnit.objects.get(code_normalized=IMEI_B)
        self.assertEqual(incoming.status, StockUnit.Status.IN_STOCK)
        self.assertEqual(incoming.incoming_rate, Decimal("500.000000"))
        self.assertFalse(incoming.is_consignment)
        # And the one that left is gone.
        self.outgoing.refresh_from_db()
        self.assertEqual(self.outgoing.status, StockUnit.Status.SOLD)

    def test_the_drawer_expects_the_difference_and_nothing_else(self):
        """§6.2's whole argument, as a number."""
        self._checkout()

        self.session.refresh_from_db()
        self.assertEqual(self.session.expected_cash, Decimal("900.00"))

    def test_a_trade_in_worth_more_than_the_sale_is_refused(self):
        from apps.sales.models import TradeIn

        response = self._checkout(trade_in_price="1500.00")

        self.assertEqual(response.status_code, 400, response.data)
        self.assertIn("trade_in", response.data)
        # And neither leg survives: a refused sale takes its purchase down too.
        self.assertEqual(TradeIn.objects.count(), 0)
        self.assertFalse(
            StockUnit.objects.filter(code_normalized=IMEI_B).exists()
        )

    def test_a_refused_sale_takes_the_purchase_with_it(self):
        """The two documents stand or fall together — a purchase left behind by
        a sale that never happened is stock the shop paid for and cannot
        explain."""
        from apps.sales.models import TradeIn

        # Sell an article that is not on the shelf: the sale is refused inside
        # the trade-in's transaction, after the purchase has been written.
        response = self.client.post(
            "/api/orders/checkout/",
            {
                "lines": [
                    {
                        "variant": self.variant.pk,
                        "quantity": "1",
                        "stock_units": [self.outgoing.pk + 9999],
                        "effective_unit_price": "1400.00",
                    }
                ],
                "payments": [{"method": "cash", "amount": "1400.00"}],
                "trade_in": {
                    "supplier": self.seller.pk,
                    "lines": [
                        {
                            "variant": self.variant.pk,
                            "quantity": "1",
                            "unit_cost": "500.00",
                            "units": [{"code": IMEI_C}],
                        }
                    ],
                },
            },
            format="json",
        )

        self.assertGreaterEqual(response.status_code, 400)
        self.assertEqual(TradeIn.objects.count(), 0)
        self.assertFalse(
            StockUnit.objects.filter(code_normalized=IMEI_C).exists()
        )


class RefurbishmentLedgerTests(TestCase):
    """§5.6 capitalises a repair into the article. The ledger has to hear it.

    The failure this guards is the one §5.8 names for consignment, pointed at
    owned stock: ``StockValuationBin`` is **derived** from the units and heals
    itself the instant ``refurb_cost`` changes; ``StockLedgerEntry`` is
    append-only and does not. Capitalise 150 into a handset with no entry behind
    it and the sale then issues 1,350 of value out of a ledger that only ever
    took 1,200 in — a variant whose cumulative stock value walks downward over a
    year of refurbishments, with every invariant green.
    """

    def setUp(self):
        self.product = tracked_product(
            name="iPhone 12",
            sku="IP12-REF",
            mode=Product.TrackingMode.SERIAL,
            unit_price="1400.00",
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
            sku="SCR-REF",
            mode=Product.TrackingMode.QUANTITY,
            unit_price="200.00",
        )

    def _ledger_value(self):
        from .models import StockLedgerEntry

        return sum(
            (
                entry.value_change
                for entry in StockLedgerEntry.objects.filter(variant=self.variant)
            ),
            Decimal("0"),
        )

    def _capitalise(self, amount):
        template = WorkflowTemplate.objects.create(
            name="إصلاح", job_type=WorkflowTemplate.JobType.REPAIR
        )
        start = template.stages.create(
            code="open", name="مفتوح", is_initial=True, display_order=0
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
            unit_cost=Decimal(amount),
            unit_price=Decimal("200.00"),
            consumed_at=timezone.now(),
        )
        capitalise(job)
        self.unit.refresh_from_db()
        return job

    def test_the_bin_and_the_ledger_agree_after_a_refurbishment(self):
        self._capitalise("150.00")

        from .models import StockValuationBin

        bin_row = StockValuationBin.objects.get(variant=self.variant)
        self.assertEqual(bin_row.stock_value, Decimal("1350.000000"))
        self.assertEqual(self._ledger_value(), Decimal("1350.000000"))

    def test_the_invariants_hold_after_a_refurbishment(self):
        self._capitalise("150.00")

        assert_tracking_invariants()

    def test_selling_a_refurbished_article_leaves_the_ledger_at_zero(self):
        self._capitalise("150.00")

        _sell(
            [
                {
                    "variant": self.variant,
                    "quantity": Decimal("1"),
                    "effective_unit_price": Decimal("1400.00"),
                    "stock_units": [self.unit.pk],
                }
            ]
        )

        # Everything that entered has left; nothing more and nothing less.
        self.assertEqual(self._ledger_value(), Decimal("0.000000"))

    def test_reopening_the_job_takes_the_value_back_out_of_the_ledger(self):
        job = self._capitalise("150.00")

        release(job)

        self.unit.refresh_from_db()
        self.assertEqual(self.unit.refurb_cost, Decimal("0.000000"))
        self.assertEqual(self._ledger_value(), Decimal("1200.000000"))
        assert_tracking_invariants()

    def test_reopening_a_job_on_an_article_that_has_left_moves_no_shelf(self):
        """The sale already booked what it cost. Taking value off the bin now
        would move a shelf the handset is no longer on."""
        from .models import StockValuationBin

        job = self._capitalise("150.00")
        _sell(
            [
                {
                    "variant": self.variant,
                    "quantity": Decimal("1"),
                    "effective_unit_price": Decimal("1400.00"),
                    "stock_units": [self.unit.pk],
                }
            ]
        )

        release(job)

        self.assertEqual(self._ledger_value(), Decimal("0.000000"))
        bin_row = StockValuationBin.objects.get(variant=self.variant)
        self.assertEqual(bin_row.stock_value, Decimal("0.000000"))
        assert_tracking_invariants()

    def test_a_repost_keeps_what_the_repair_added(self):
        """A replay must not lose a value-only entry, whatever posted it.

        `repost_variant` asks each entry whether it added stock or removed it,
        and a capitalisation does neither — so it used to fall into the removal
        branch, remove nothing, and have its stored value overwritten with zero.
        """
        from .valuation_service import repost_variant

        self._capitalise("150.00")

        repost_variant(self.variant.pk)

        self.assertEqual(self._ledger_value(), Decimal("1350.000000"))
        from .models import StockValuationBin

        bin_row = StockValuationBin.objects.get(variant=self.variant)
        self.assertEqual(bin_row.stock_value, Decimal("1350.000000"))
        assert_tracking_invariants()
