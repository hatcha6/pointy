"""``serial → serial_batch`` grandfathers the units already on the shelf (§4.2).

A pharmacy that starts with serials must be able to adopt lots, so the switch is
allowed with stock on hand: the existing units keep ``batch = NULL`` and every
new receipt has to name a lot. Two places held the opposite rule and judged
every allocation by today's mode — the allocation guard refused to sell, return
or move a grandfathered unit (a ``ValueError``, so a 500 at the till), and
invariant 14 reported every allocation it ever had. Both now ask the question
§4.2 implies: was this unit born before its product required lots?
"""

from decimal import Decimal

from django.test import TestCase
from django.utils import timezone

from apps.catalog.models import Product
from apps.catalog.serializers import ProductCatalogSerializer
from apps.sales.models import RegisterSession
from apps.sales.services import checkout_order

from . import tracking
from .integrity import tracking_invariant_violations, units_missing_lots
from .models import StockAllocation, StockUnit, Warehouse
from .tracked_testing import receive, tracked_product

_TILL_SEQUENCE = 0


def _sell(variant, *, price, **line_extra):
    global _TILL_SEQUENCE
    _TILL_SEQUENCE += 1
    session = RegisterSession.objects.create(
        owner_key=f"grandfather-till-{_TILL_SEQUENCE}",
        status=RegisterSession.Status.OPEN,
        opening_cash=Decimal("0.00"),
    )
    return checkout_order(
        register_session=session,
        lines_data=[{"variant": variant, "quantity": Decimal("1"), **line_extra}],
        payments_data=[{"method": "cash", "amount": Decimal(price)}],
    )


def _switch(product, mode):
    serializer = ProductCatalogSerializer(
        product, data={"tracking_mode": mode}, partial=True
    )
    serializer.is_valid(raise_exception=True)
    serializer.save()
    product.refresh_from_db()
    return product


class GrandfatheredUnitTests(TestCase):
    def setUp(self):
        self.product = tracked_product(
            name="لقاح",
            sku="GF-VAX",
            mode=Product.TrackingMode.SERIAL,
            unit_price="300.00",
        )
        receive(
            variant=self.product.default_variant,
            quantity=2,
            unit_cost="100.00",
            units=[{"code": "GF-PACK-1"}, {"code": "GF-PACK-2"}],
        )
        _switch(self.product, Product.TrackingMode.SERIAL_BATCH)

    def test_the_switch_leaves_the_invariants_whole(self):
        self.assertEqual(units_missing_lots().count(), 2)
        self.assertEqual(tracking_invariant_violations(), [])

    def test_a_grandfathered_unit_is_still_sold(self):
        """It was a 500: the guard demanded a lot the article never had."""
        unit = StockUnit.objects.get(code="GF-PACK-1")

        _sell(self.product.default_variant, price="300.00", stock_units=[unit.pk])

        unit.refresh_from_db()
        self.assertEqual(unit.status, StockUnit.Status.SOLD)
        self.assertIsNone(
            StockAllocation.objects.filter(
                unit=unit, direction=StockAllocation.Direction.OUT
            )
            .get()
            .batch_id
        )
        self.assertEqual(tracking_invariant_violations(), [])

    def test_a_unit_born_after_the_switch_still_has_to_name_its_lot(self):
        """The excuse is for history, not for a path that forgot the lot."""
        unit = StockUnit.objects.create(
            variant=self.product.default_variant,
            warehouse_id=Warehouse.default_id(),
            code="GF-NEW-NOLOT",
            in_stock_since=timezone.now(),
        )
        plan = tracking.TrackedPlan(
            mode=Product.TrackingMode.SERIAL_BATCH,
            direction=StockAllocation.Direction.IN,
            warehouse_id=Warehouse.default_id(),
        )
        plan.allocations.append(
            tracking.Allocation(quantity=Decimal("1"), rate=Decimal("1"), unit=unit)
        )

        with self.assertRaises(ValueError):
            tracking.write_allocations(
                plan, voucher_type="adjustment", posting_at=timezone.now()
            )

        # And written past the guard, the invariant still names it.
        StockAllocation.objects.create(
            unit=unit,
            variant=self.product.default_variant,
            warehouse_id=Warehouse.default_id(),
            direction=StockAllocation.Direction.IN,
            quantity=Decimal("1"),
            rate=Decimal("1"),
            voucher_type="adjustment",
            posting_at=timezone.now(),
        )
        problems = tracking_invariant_violations()
        self.assertTrue(
            any(problem.startswith("[14]") for problem in problems), problems
        )


class LotHistoryBeforeSerialBatchTests(TestCase):
    def test_a_lot_product_that_sold_out_adopts_serials_cleanly(self):
        """Lot-only history from before the switch was right when it was
        written; it is judged by the mode it was written under."""
        product = tracked_product(
            name="شراب", sku="GF-SYR", mode=Product.TrackingMode.BATCH,
            unit_price="20.00",
        )
        variant = product.default_variant
        receive(
            variant=variant,
            quantity=1,
            unit_cost="5.00",
            batches=[{"code": "L-OLD", "quantity": 1}],
        )
        _sell(variant, price="20.00")

        _switch(product, Product.TrackingMode.SERIAL_BATCH)

        self.assertEqual(tracking_invariant_violations(), [])
