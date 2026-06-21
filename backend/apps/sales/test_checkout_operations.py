"""Checkout correctness + "long day" endurance for the sales service layer.

These tests exercise ``apps.sales.services.checkout_order`` directly (request=None)
so they cover the canonical sale path without the API's serializer plumbing. The
focus is on the invariants a shop owner cares about across a full trading day:
stock decrements by exactly what was sold, prices never drift on their own,
oversell/loss/archive guards behave, and totals aggregate correctly over dozens
of sequential sales in one open register session.

The API-level exact-payment rule is covered through the real checkout endpoint at
the bottom, since that validation lives in the serializer rather than the service.
"""

from decimal import Decimal

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group
from django.test import TestCase
from django.urls import reverse
from django.utils import timezone
from rest_framework import serializers, status
from rest_framework.test import APIClient

from apps.catalog.models import ProductUnit, UnitOfMeasure
from apps.catalog.testing import create_product_with_default_variant
from apps.core.models import ShopSettings
from apps.core.roles import CASHIER_GROUP, ensure_role_groups
from apps.inventory.models import StockItem, StockMovement
from apps.sales.models import Order, OrderLine, RegisterSession
from apps.sales.services import checkout_order


def _make_product(*, name, sku, unit_price, on_hand=None):
    product = create_product_with_default_variant(
        name=name, sku=sku, unit_price=unit_price, barcode=""
    )
    variant = product.default_variant
    if on_hand is not None:
        StockItem.objects.create(
            variant=variant, quantity_on_hand=Decimal(on_hand)
        )
    return product, variant


class CheckoutServiceTestBase(TestCase):
    def setUp(self):
        ensure_role_groups()
        self.user = get_user_model().objects.create_user(
            username="day-cashier", password="pass"
        )
        self.user.groups.add(Group.objects.get(name=CASHIER_GROUP))
        self.session = RegisterSession.objects.create(
            owner=self.user, owner_key=f"user:{self.user.pk}"
        )

    def checkout(self, lines_data, payments_data):
        return checkout_order(
            register_session=self.session,
            lines_data=lines_data,
            payments_data=payments_data,
            request=None,
        )


class StockDecrementTests(CheckoutServiceTestBase):
    """Scenario 1, 2, 3, 7: stock math on the canonical sale path."""

    def test_single_line_decrements_stock_by_exact_quantity(self):
        _, variant = _make_product(
            name="Cola", sku="COLA", unit_price="2.00", on_hand="10"
        )

        order = self.checkout(
            [{"variant": variant, "quantity": Decimal("3")}],
            [{"method": "cash", "amount": Decimal("6.00")}],
        )

        stock = StockItem.objects.get(variant=variant)
        self.assertEqual(stock.quantity_on_hand, Decimal("7.000"))

        movement = StockMovement.objects.get(variant=variant)
        self.assertEqual(movement.movement_type, StockMovement.Type.DECREASE)
        self.assertEqual(movement.quantity, Decimal("3.000"))
        self.assertEqual(movement.on_hand_before, Decimal("10.000"))
        self.assertEqual(movement.on_hand_after, Decimal("7.000"))
        self.assertEqual(order.status, Order.Status.PAID)

    def test_multi_line_order_totals_and_per_variant_stock(self):
        _, milk = _make_product(
            name="Milk", sku="MILK", unit_price="4.00", on_hand="20"
        )
        _, bread = _make_product(
            name="Bread", sku="BREAD", unit_price="1.50", on_hand="8"
        )

        order = self.checkout(
            [
                {"variant": milk, "quantity": Decimal("2")},
                {"variant": bread, "quantity": Decimal("3")},
            ],
            [{"method": "cash", "amount": Decimal("12.50")}],
        )

        # 2*4.00 + 3*1.50 = 8.00 + 4.50 = 12.50
        self.assertEqual(order.subtotal, Decimal("12.50"))
        self.assertEqual(order.total, Decimal("12.50"))

        self.assertEqual(
            StockItem.objects.get(variant=milk).quantity_on_hand,
            Decimal("18.000"),
        )
        self.assertEqual(
            StockItem.objects.get(variant=bread).quantity_on_hand,
            Decimal("5.000"),
        )
        # Each variant gets its own decrease movement.
        self.assertEqual(
            StockMovement.objects.filter(variant=milk).count(), 1
        )
        self.assertEqual(
            StockMovement.objects.filter(variant=bread).count(), 1
        )

    def test_same_variant_lines_aggregate_into_one_decrement(self):
        _, variant = _make_product(
            name="Gum", sku="GUM", unit_price="0.50", on_hand="10"
        )

        order = self.checkout(
            [
                {"variant": variant, "quantity": Decimal("2")},
                {"variant": variant, "quantity": Decimal("3")},
            ],
            [{"method": "cash", "amount": Decimal("2.50")}],
        )

        # Two order lines are still recorded...
        self.assertEqual(order.lines.count(), 2)
        # ...but stock is adjusted once, by the combined quantity (5).
        self.assertEqual(
            StockItem.objects.get(variant=variant).quantity_on_hand,
            Decimal("5.000"),
        )
        movements = StockMovement.objects.filter(variant=variant)
        self.assertEqual(movements.count(), 1)
        movement = movements.get()
        self.assertEqual(movement.quantity, Decimal("5.000"))
        self.assertEqual(movement.on_hand_before, Decimal("10.000"))
        self.assertEqual(movement.on_hand_after, Decimal("5.000"))

    def test_oversell_drives_stock_negative_and_records_negative_after(self):
        ShopSettings.load()
        ShopSettings.objects.filter(pk=1).update(allow_overselling=True)
        _, variant = _make_product(
            name="Tea", sku="TEA", unit_price="1.00", on_hand="2"
        )

        self.checkout(
            [{"variant": variant, "quantity": Decimal("5")}],
            [{"method": "cash", "amount": Decimal("5.00")}],
        )

        stock = StockItem.objects.get(variant=variant)
        self.assertEqual(stock.quantity_on_hand, Decimal("-3.000"))
        movement = StockMovement.objects.get(variant=variant)
        self.assertEqual(movement.on_hand_before, Decimal("2.000"))
        self.assertEqual(movement.on_hand_after, Decimal("-3.000"))
        self.assertEqual(movement.quantity, Decimal("5.000"))


class UnitSaleStockTests(CheckoutServiceTestBase):
    """Scenario 4: selling in a packaging unit decrements in base units."""

    def test_box_sale_decrements_base_units_and_uses_per_unit_price(self):
        product, variant = _make_product(
            name="Soda", sku="SODA", unit_price="1.00", on_hand="100"
        )
        ProductUnit.objects.create(
            product=product,
            unit=UnitOfMeasure.objects.get(code="box"),
            factor_to_base=Decimal("12"),
        )

        # The API resolves the unit; the service expects the resolved factor +
        # effective per-unit price to be passed in line_data.
        order = self.checkout(
            [
                {
                    "variant": variant,
                    "quantity": Decimal("2"),
                    "unit": "box",
                    "unit_factor": Decimal("12"),
                    "effective_unit_price": Decimal("12.00"),
                }
            ],
            [{"method": "cash", "amount": Decimal("24.00")}],
        )

        line = order.lines.get()
        self.assertEqual(line.unit, "box")
        self.assertEqual(line.unit_factor, Decimal("12"))
        self.assertEqual(line.quantity, Decimal("2"))
        self.assertEqual(line.unit_price, Decimal("12.00"))
        # 2 boxes * 12 = 24 base units removed from a 100-unit shelf.
        self.assertEqual(line.base_quantity, Decimal("24.000"))
        self.assertEqual(
            StockItem.objects.get(variant=variant).quantity_on_hand,
            Decimal("76.000"),
        )
        movement = StockMovement.objects.get(variant=variant)
        self.assertEqual(movement.quantity, Decimal("24.000"))
        self.assertEqual(order.total, Decimal("24.00"))


class PriceImmutabilityTests(CheckoutServiceTestBase):
    """Scenario 5: 'prices don't change on their own'."""

    def test_variant_price_is_unchanged_after_many_sales(self):
        _, variant = _make_product(
            name="Juice", sku="JUICE", unit_price="3.25", on_hand="100"
        )
        original_price = variant.unit_price
        self.assertEqual(original_price, Decimal("3.25"))

        for _ in range(8):
            order = self.checkout(
                [{"variant": variant, "quantity": Decimal("1")}],
                [{"method": "cash", "amount": Decimal("3.25")}],
            )
            line = order.lines.get()
            # Each line snapshots the variant's price at sale time.
            self.assertEqual(line.unit_price, Decimal("3.25"))

        variant.refresh_from_db()
        # The catalog price never drifted as a side effect of selling.
        self.assertEqual(variant.unit_price, Decimal("3.25"))
        self.assertEqual(variant.unit_price, original_price)

    def test_changing_catalog_price_does_not_rewrite_past_line_snapshots(self):
        _, variant = _make_product(
            name="Snack", sku="SNACK", unit_price="2.00", on_hand="50"
        )

        order = self.checkout(
            [{"variant": variant, "quantity": Decimal("1")}],
            [{"method": "cash", "amount": Decimal("2.00")}],
        )
        original_line = order.lines.get()
        self.assertEqual(original_line.unit_price, Decimal("2.00"))

        # Owner reprices the product upward later.
        variant.unit_price = Decimal("5.00")
        variant.save(update_fields=["unit_price", "updated_at"])

        # The already-sold line keeps the price it was sold at.
        original_line.refresh_from_db()
        self.assertEqual(original_line.unit_price, Decimal("2.00"))
        self.assertEqual(
            OrderLine.objects.get(pk=original_line.pk).unit_price,
            Decimal("2.00"),
        )


class InsufficientStockTests(CheckoutServiceTestBase):
    """Scenario 6: stock guard blocks the sale and leaves everything intact."""

    def test_checkout_over_on_hand_raises_and_changes_nothing(self):
        # allow_overselling defaults to False.
        _, variant = _make_product(
            name="Egg", sku="EGG", unit_price="0.30", on_hand="4"
        )

        with self.assertRaises(serializers.ValidationError) as ctx:
            self.checkout(
                [{"variant": variant, "quantity": Decimal("5")}],
                [{"method": "cash", "amount": Decimal("1.50")}],
            )
        # The error names the stock shortage.
        self.assertIn("stock", str(ctx.exception.detail))

        # Nothing was written: no order, no movement, stock untouched.
        self.assertEqual(Order.objects.count(), 0)
        self.assertEqual(StockMovement.objects.count(), 0)
        self.assertEqual(
            StockItem.objects.get(variant=variant).quantity_on_hand,
            Decimal("4.000"),
        )


class ServiceAndPreparedProductTests(CheckoutServiceTestBase):
    """Scenario 8: labor/made-to-order lines never touch stock."""

    def test_service_product_checks_out_without_stock_item(self):
        product, variant = _make_product(
            name="Repair labor", sku="LABOR", unit_price="20.00"
        )
        product.is_service = True
        product.save(update_fields=["is_service", "updated_at"])
        # Deliberately NO StockItem for a service.
        self.assertFalse(StockItem.objects.filter(variant=variant).exists())

        order = self.checkout(
            [{"variant": variant, "quantity": Decimal("1")}],
            [{"method": "cash", "amount": Decimal("20.00")}],
        )

        self.assertEqual(order.status, Order.Status.PAID)
        self.assertEqual(order.total, Decimal("20.00"))
        # No stock side effects whatsoever.
        self.assertFalse(StockItem.objects.filter(variant=variant).exists())
        self.assertEqual(StockMovement.objects.filter(variant=variant).count(), 0)

    def test_prepared_product_checks_out_without_decrementing_stock(self):
        # A made-to-order dish may carry a StockItem but must not be decremented
        # at checkout (its ingredients are consumed via the kitchen job).
        product, variant = _make_product(
            name="Fresh burger", sku="BURGER", unit_price="9.00", on_hand="5"
        )
        product.is_prepared = True
        product.save(update_fields=["is_prepared", "updated_at"])

        order = self.checkout(
            [{"variant": variant, "quantity": Decimal("2")}],
            [{"method": "cash", "amount": Decimal("18.00")}],
        )

        self.assertEqual(order.status, Order.Status.PAID)
        # Stock for the prepared product is left exactly as it was.
        self.assertEqual(
            StockItem.objects.get(variant=variant).quantity_on_hand,
            Decimal("5.000"),
        )
        self.assertEqual(StockMovement.objects.filter(variant=variant).count(), 0)


class ArchivedAndInactiveGuardTests(CheckoutServiceTestBase):
    """Scenario 9 (regression): the sellable guard blocks discontinued stock."""

    def test_archived_product_cannot_be_sold(self):
        product, variant = _make_product(
            name="Discontinued", sku="OLD", unit_price="5.00", on_hand="10"
        )
        product.archived_at = timezone.now()
        product.save(update_fields=["archived_at", "updated_at"])

        with self.assertRaises(serializers.ValidationError) as ctx:
            self.checkout(
                [{"variant": variant, "quantity": Decimal("1")}],
                [{"method": "cash", "amount": Decimal("5.00")}],
            )
        self.assertIn(
            "Cannot sell an archived or inactive product",
            str(ctx.exception.detail),
        )
        # The archived guard runs before any order/stock write.
        self.assertEqual(Order.objects.count(), 0)
        self.assertEqual(StockMovement.objects.count(), 0)
        self.assertEqual(
            StockItem.objects.get(variant=variant).quantity_on_hand,
            Decimal("10.000"),
        )

    def test_inactive_variant_cannot_be_sold(self):
        _, variant = _make_product(
            name="Deactivated", sku="DEAD", unit_price="5.00", on_hand="10"
        )
        variant.is_active = False
        variant.save(update_fields=["is_active", "updated_at"])

        with self.assertRaises(serializers.ValidationError) as ctx:
            self.checkout(
                [{"variant": variant, "quantity": Decimal("1")}],
                [{"method": "cash", "amount": Decimal("5.00")}],
            )
        self.assertIn(
            "Cannot sell an archived or inactive product",
            str(ctx.exception.detail),
        )
        self.assertEqual(Order.objects.count(), 0)
        self.assertEqual(StockMovement.objects.count(), 0)


class LongDayEnduranceTests(CheckoutServiceTestBase):
    """Scenario 10: dozens of sales in one open session stay consistent."""

    def test_fifty_sequential_sales_aggregate_exactly(self):
        starting_stock = Decimal("500")
        _, variant = _make_product(
            name="Espresso", sku="ESP", unit_price="2.50", on_hand=starting_stock
        )

        sale_count = 50
        qty_each = Decimal("2")
        amount_each = Decimal("5.00")  # 2 * 2.50

        for _ in range(sale_count):
            self.checkout(
                [{"variant": variant, "quantity": qty_each}],
                [{"method": "cash", "amount": amount_each}],
            )

        # Order count for the day.
        day_orders = Order.objects.filter(register_session=self.session)
        self.assertEqual(day_orders.count(), sale_count)
        self.assertTrue(
            all(o.status == Order.Status.PAID for o in day_orders)
        )

        # Cumulative stock decrement is exact: 500 - (50 * 2) = 400.
        expected_remaining = starting_stock - (sale_count * qty_each)
        self.assertEqual(
            StockItem.objects.get(variant=variant).quantity_on_hand,
            expected_remaining.quantize(Decimal("0.001")),
        )

        # One DECREASE movement per sale, and they chain without gaps: the
        # last movement's after-quantity is the final on-hand.
        movements = list(
            StockMovement.objects.filter(variant=variant).order_by("pk")
        )
        self.assertEqual(len(movements), sale_count)
        self.assertTrue(
            all(m.movement_type == StockMovement.Type.DECREASE for m in movements)
        )
        self.assertEqual(
            movements[-1].on_hand_after,
            expected_remaining.quantize(Decimal("0.001")),
        )
        # Movements form a continuous ledger: each before == previous after.
        for prev, current in zip(movements, movements[1:]):
            self.assertEqual(current.on_hand_before, prev.on_hand_after)

        # Day's takings aggregate correctly across every order.
        day_total = sum(
            (o.total for o in day_orders), Decimal("0.00")
        )
        self.assertEqual(day_total, amount_each * sale_count)

    def test_mixed_basket_long_day_keeps_two_variants_consistent(self):
        _, water = _make_product(
            name="Water", sku="H2O", unit_price="1.00", on_hand="300"
        )
        _, chips = _make_product(
            name="Chips", sku="CHIP", unit_price="2.00", on_hand="300"
        )

        rounds = 40
        for _ in range(rounds):
            self.checkout(
                [
                    {"variant": water, "quantity": Decimal("1")},
                    {"variant": chips, "quantity": Decimal("2")},
                ],
                [{"method": "cash", "amount": Decimal("5.00")}],  # 1*1 + 2*2
            )

        self.assertEqual(
            Order.objects.filter(register_session=self.session).count(), rounds
        )
        self.assertEqual(
            StockItem.objects.get(variant=water).quantity_on_hand,
            Decimal("260.000"),  # 300 - 40*1
        )
        self.assertEqual(
            StockItem.objects.get(variant=chips).quantity_on_hand,
            Decimal("220.000"),  # 300 - 40*2
        )
        self.assertEqual(
            StockMovement.objects.filter(variant=water).count(), rounds
        )
        self.assertEqual(
            StockMovement.objects.filter(variant=chips).count(), rounds
        )


class ExactPaymentApiTests(TestCase):
    """Scenario 11: the API enforces paying exactly the order total."""

    def setUp(self):
        ensure_role_groups()
        self.client = APIClient()
        self.user = get_user_model().objects.create_user(
            username="pay-cashier", password="pass"
        )
        self.user.groups.add(Group.objects.get(name=CASHIER_GROUP))
        self.client.force_authenticate(user=self.user)
        _, self.variant = _make_product(
            name="Bagel", sku="BAGEL", unit_price="3.00", on_hand="50"
        )
        self.client.post(
            reverse("register-session-start"),
            {"opening_cash": "0.00"},
            format="json",
        )

    def _checkout(self, amount_received):
        # 2 * 3.00 = 6.00 is the exact total.
        return self.client.post(
            reverse("order-checkout"),
            {
                "lines": [{"variant": self.variant.pk, "quantity": 2}],
                "payment_method": "cash",
                "amount_received": amount_received,
            },
            format="json",
        )

    def test_exact_payment_succeeds(self):
        response = self._checkout("6.00")
        self.assertEqual(
            response.status_code, status.HTTP_201_CREATED, response.data
        )
        self.assertEqual(response.data["total"], "6.00")

    def test_underpayment_is_rejected(self):
        response = self._checkout("5.00")
        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertEqual(Order.objects.count(), 0)
        self.assertEqual(StockMovement.objects.count(), 0)

    def test_overpayment_is_rejected(self):
        response = self._checkout("7.00")
        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertEqual(Order.objects.count(), 0)
        self.assertEqual(StockMovement.objects.count(), 0)
