"""History is judged by the mode it was written under, not by today's.

A product's tracking mode can change after it has traded: switched off and on
again, or moved sideways between lots and serials once its shelf is empty. The
allocations and ledger entries it wrote before were right for the mode it had
then — a lot sold under ``batch`` names no unit, a sale made while the product
was counted by quantity names nothing at all — and invariants 5 and 14 used to
read them against the mode it has now, reporting a permanent violation for a
shop that did everything right.
"""

from decimal import Decimal

from django.test import TestCase
from django.utils import timezone

from apps.catalog.models import Product
from apps.catalog.serializers import ProductCatalogSerializer
from apps.sales.models import RegisterSession
from apps.sales.services import checkout_order

from .integrity import tracking_invariant_violations
from .models import StockAllocation, StockBatch, StockUnit, Warehouse
from .tracked_testing import receive, tracked_product

QUANTITY = Product.TrackingMode.QUANTITY
BATCH = Product.TrackingMode.BATCH
SERIAL = Product.TrackingMode.SERIAL
SERIAL_BATCH = Product.TrackingMode.SERIAL_BATCH

_TILL_SEQUENCE = 0


def _sell(variant, quantity=1, *, price, **line_extra):
    global _TILL_SEQUENCE
    _TILL_SEQUENCE += 1
    session = RegisterSession.objects.create(
        owner_key=f"history-till-{_TILL_SEQUENCE}",
        status=RegisterSession.Status.OPEN,
        opening_cash=Decimal("0.00"),
    )
    return checkout_order(
        register_session=session,
        lines_data=[
            {"variant": variant, "quantity": Decimal(quantity), **line_extra}
        ],
        payments_data=[
            {"method": "cash", "amount": Decimal(price) * Decimal(quantity)}
        ],
    )


def _switch(product, mode):
    serializer = ProductCatalogSerializer(
        product, data={"tracking_mode": mode}, partial=True
    )
    serializer.is_valid(raise_exception=True)
    serializer.save()
    product.refresh_from_db()
    return product


def _product(sku, mode):
    return tracked_product(name="صنف", sku=sku, mode=mode, unit_price="50.00")


def _sell_the_unit(product, code):
    receive(
        variant=product.default_variant,
        quantity=1,
        unit_cost="10.00",
        units=[{"code": code}],
        batches=(
            [{"code": f"LOT-{code}", "quantity": 1}]
            if product.tracking_mode == SERIAL_BATCH
            else None
        ),
    )
    unit = StockUnit.objects.get(code=code)
    _sell(product.default_variant, price="50.00", stock_units=[unit.pk])


def _sell_a_lot(product, code):
    receive(
        variant=product.default_variant,
        quantity=1,
        unit_cost="10.00",
        batches=[{"code": code, "quantity": 1}],
    )
    _sell(product.default_variant, price="50.00")


class SwitchedOffAndOnAgainTests(TestCase):
    """Invariant 5: what a product sold while counted by quantity names nothing."""

    def test_trading_by_quantity_in_between_is_not_a_violation(self):
        product = _product("HIST-OFF", SERIAL)
        _sell_the_unit(product, "HIST-OFF-1")
        first_tracked = product.tracking_since

        _switch(product, QUANTITY)
        self.assertIsNone(product.tracking_since)
        receive(variant=product.default_variant, quantity=2, unit_cost="10.00")
        _sell(product.default_variant, 2, price="50.00")
        _switch(product, SERIAL)

        self.assertGreater(product.tracking_since, first_tracked)
        self.assertEqual(tracking_invariant_violations(), [])


class SidewaysAtAnEmptyShelfTests(TestCase):
    """Invariant 14: a lot sold under ``batch`` was right to name no unit."""

    def test_lots_then_serials(self):
        product = _product("HIST-B2S", BATCH)
        _sell_a_lot(product, "HIST-LOT-1")

        _switch(product, SERIAL)

        self.assertEqual(tracking_invariant_violations(), [])

    def test_serials_then_lots(self):
        product = _product("HIST-S2B", SERIAL)
        _sell_the_unit(product, "HIST-S2B-1")

        _switch(product, BATCH)

        self.assertEqual(tracking_invariant_violations(), [])

    def test_serials_in_a_lot_then_lots_alone(self):
        product = _product("HIST-SB2B", SERIAL_BATCH)
        _sell_the_unit(product, "HIST-SB2B-1")

        _switch(product, BATCH)

        self.assertEqual(tracking_invariant_violations(), [])

    def test_what_is_written_after_the_switch_is_still_held_to_it(self):
        product = _product("HIST-AFTER", BATCH)
        _sell_a_lot(product, "HIST-LOT-2")
        _switch(product, SERIAL)

        StockAllocation.objects.create(
            batch=StockBatch.objects.get(code="HIST-LOT-2"),
            variant=product.default_variant,
            warehouse_id=Warehouse.default_id(),
            direction=StockAllocation.Direction.IN,
            quantity=Decimal("1"),
            rate=Decimal("10"),
            voucher_type="adjustment",
            posting_at=timezone.now(),
        )

        problems = tracking_invariant_violations()
        self.assertTrue(
            any(problem.startswith("[14]") for problem in problems), problems
        )


class AModeChangeIsStampedOnceTests(TestCase):
    def test_saving_without_changing_the_mode_keeps_the_stamp(self):
        product = _product("HIST-STAMP", SERIAL)
        stamped = product.tracking_mode_since
        self.assertIsNotNone(stamped)

        product.name = "صنف آخر"
        product.save()
        product.refresh_from_db()
        self.assertEqual(product.tracking_mode_since, stamped)

        _switch(product, BATCH)
        self.assertGreater(product.tracking_mode_since, stamped)

    def test_a_mode_written_by_name_only_is_still_noticed(self):
        """``save(update_fields=[...])`` on a reloaded row, the way the
        migration path and the opening-identification tests switch modes."""
        product = _product("HIST-UF", QUANTITY)
        stamped = product.tracking_mode_since
        reloaded = Product.objects.get(pk=product.pk)

        reloaded.tracking_mode = SERIAL
        reloaded.save(update_fields=["tracking_mode", "updated_at"])

        reloaded.refresh_from_db()
        self.assertGreater(reloaded.tracking_mode_since, stamped)
        self.assertIsNotNone(reloaded.tracking_since)
