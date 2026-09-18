"""A quotation holds the handset it was written against.

Before this, a quote on a serialized product bumped ``quantity_committed`` and
reserved nothing: §5.4 invariant 2 (committed == count of reserved units) failed
for every such quote, the held article stayed in every other till's picker, and
converting sold whichever one happened to be oldest rather than the one the
customer had been shown.
"""

from decimal import Decimal

from django.test import TestCase

from apps.catalog.models import Product
from apps.inventory.integrity import tracking_invariant_violations
from apps.inventory.models import StockItem, StockUnit
from apps.inventory.tracked_testing import receive, tracked_product
from apps.sales.models import Order, RegisterSession, StockReservation
from apps.sales.services import (
    checkout_order,
    convert_quotation_to_sale,
    release_quote_reservations,
)

IMEI_A = "351234567890123"
IMEI_B = "351234567890124"


def _session(key):
    return RegisterSession.objects.create(
        owner_key=key,
        status=RegisterSession.Status.OPEN,
        opening_cash=Decimal("0.00"),
    )


class QuotationsHoldTheArticle(TestCase):
    def setUp(self):
        self.product = tracked_product(
            name="آيفون", sku="QT", mode=Product.TrackingMode.SERIAL,
            unit_price="1500.00",
        )
        self.variant = self.product.default_variant
        receive(
            variant=self.variant, quantity=2, unit_cost="1200.00",
            units=[
                {"code": IMEI_A, "unit_cost": Decimal("1300.00")},
                {"code": IMEI_B, "unit_cost": Decimal("1100.00")},
            ],
        )

    def _quote(self, key="quote", units=None):
        return checkout_order(
            register_session=_session(key),
            lines_data=[
                {
                    "variant": self.variant,
                    "quantity": Decimal("1"),
                    **({"stock_units": units} if units else {}),
                }
            ],
            payments_data=[],
            sale_type=Order.SaleType.QUOTATION,
            reserve_stock=True,
        )

    def test_a_quote_reserves_the_unit_and_the_invariants_hold(self):
        unit = StockUnit.objects.get(code_normalized=IMEI_B)
        self._quote(units=[unit.pk])

        unit.refresh_from_db()
        self.assertEqual(unit.status, StockUnit.Status.RESERVED)
        item = StockItem.objects.get(variant=self.variant)
        self.assertEqual(item.quantity_committed, Decimal("1.000"))
        reservation = StockReservation.objects.get()
        self.assertEqual(reservation.stock_unit_id, unit.pk)
        self.assertEqual(tracking_invariant_violations(), [])

    def test_a_held_article_is_not_offered_to_another_till(self):
        from apps.inventory.tracking import available_units
        from apps.inventory.models import Warehouse

        unit = StockUnit.objects.get(code_normalized=IMEI_B)
        self._quote(units=[unit.pk])

        offered = list(
            available_units(
                variant=self.variant, warehouse=Warehouse.default_id()
            ).values_list("code_normalized", flat=True)
        )
        self.assertEqual(offered, [IMEI_A])

    def test_letting_the_quote_lapse_puts_it_back(self):
        unit = StockUnit.objects.get(code_normalized=IMEI_B)
        order = self._quote(units=[unit.pk])

        release_quote_reservations(order)

        unit.refresh_from_db()
        self.assertEqual(unit.status, StockUnit.Status.IN_STOCK)
        self.assertEqual(
            StockItem.objects.get(variant=self.variant).quantity_committed,
            Decimal("0.000"),
        )
        self.assertEqual(tracking_invariant_violations(), [])

    def test_converting_sells_the_article_that_was_quoted(self):
        """Not the oldest one — the one the customer was shown."""
        quoted = StockUnit.objects.get(code_normalized=IMEI_B)
        order = self._quote(units=[quoted.pk])

        sale = convert_quotation_to_sale(
            quotation=order,
            register_session=_session("convert"),
            payments_data=[{"method": "cash", "amount": Decimal("1500.00")}],
            sale_type=Order.SaleType.STANDARD,
        )

        quoted.refresh_from_db()
        self.assertEqual(quoted.status, StockUnit.Status.SOLD)
        self.assertEqual(quoted.sold_order_line.order_id, sale.pk)
        # The other handset never moved.
        other = StockUnit.objects.get(code_normalized=IMEI_A)
        self.assertEqual(other.status, StockUnit.Status.IN_STOCK)
        self.assertEqual(tracking_invariant_violations(), [])
