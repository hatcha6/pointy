"""What the shop is told when identified stock will not sell.

Both of these were refusals that named the wrong thing. A recall made a
drug unsellable outright rather than moving to the next lot, and a carton
split into honest money was refused over a hundredth the backend had
rounded into existence. Each is a sentence a cashier or a receiver reads,
which is why they are tested as behaviour rather than as arithmetic.
"""

from decimal import Decimal

from django.test import TestCase
from django.utils import timezone
from rest_framework import serializers as drf

from apps.catalog.models import Product
from apps.inventory.models import StockBatch, StockUnit
from apps.inventory.tracked_testing import receive, tracked_product
from apps.sales.models import RegisterSession
from apps.sales.services import checkout_order


def _sess(k):
    return RegisterSession.objects.create(
        owner_key=k, status=RegisterSession.Status.OPEN, opening_cash=Decimal("0.00"))


class RecallUX(TestCase):
    def setUp(self):
        self.p = tracked_product(name="Amoxil", sku="UX",
                                 mode=Product.TrackingMode.SERIAL_BATCH, unit_price="10.00")
        self.v = self.p.default_variant
        receive(variant=self.v, quantity=1, unit_cost="5.00",
                batches=[{"code": "LOTA", "quantity": Decimal("1")}],
                units=[{"code": "PACK-A", "batch_code": "LOTA"}])
        receive(variant=self.v, quantity=1, unit_cost="5.00",
                batches=[{"code": "LOTB", "quantity": Decimal("1")}],
                units=[{"code": "PACK-B", "batch_code": "LOTB"}])

    def test_a_recall_skips_to_the_good_pack(self):
        lota = StockBatch.objects.get(code="LOTA")
        lota.is_locked = True
        lota.status = StockBatch.Status.QUARANTINED
        lota.save()
        checkout_order(register_session=_sess("ux1"),
            lines_data=[{"variant": self.v, "quantity": Decimal("1")}],
            payments_data=[{"method": "cash", "amount": Decimal("10.00")}])
        sold = StockUnit.objects.get(status=StockUnit.Status.SOLD)
        self.assertEqual(sold.code, "PACK-B")

    def test_when_everything_is_recalled_the_error_says_so(self):
        for lot in StockBatch.objects.all():
            lot.is_locked = True
            lot.status = StockBatch.Status.QUARANTINED
            lot.save()
        with self.assertRaises(drf.ValidationError) as c:
            checkout_order(register_session=_sess("ux2"),
                lines_data=[{"variant": self.v, "quantity": Decimal("1")}],
                payments_data=[{"method": "cash", "amount": Decimal("10.00")}])
        self.assertIn("محجورة", str(c.exception.detail))


class CartonCostUX(TestCase):
    def test_a_receiver_can_split_a_carton_into_honest_money(self):
        """A carton of 12 at 100.00 is 8.333333 a piece.

        The old comparison was made at six places — 8.333333 x 12 = 99.999996 —
        so a receiver typing a correct 100.00 split was refused for a hundredth
        the backend had introduced itself.
        """
        from apps.purchasing.models import PurchaseOrder, Supplier
        from apps.purchasing.services import receive_purchase_order, submit_purchase_order

        p = tracked_product(name="iPhone", sku="UXC",
                            mode=Product.TrackingMode.SERIAL, unit_price="200.00")
        v = p.default_variant
        order = PurchaseOrder.objects.create(supplier=Supplier.objects.create(name="م"))
        line = order.lines.create(
            variant=v,
            quantity=Decimal("1"),          # one carton...
            unit_factor=Decimal("12"),      # ...of twelve handsets
            unit_cost=Decimal("100.00"),
        )
        order.recalculate()
        order.save(update_fields=["subtotal", "total", "updated_at"])
        submit_purchase_order(order)


        receive_purchase_order(order, lines_data=[{
            "line": line,
            "accepted_quantity": Decimal("1"),
            "damaged_quantity": Decimal("0"),
            "units": [
                # 4 x 8.34 + 8 x 8.33 = 100.00 exactly, which is what the
                # receiver would actually write down.
                {"code": f"C{n}", "unit_cost": Decimal("8.34" if n < 4 else "8.33")}
                for n in range(12)
            ]}])
        costs = sorted(StockUnit.objects.values_list("incoming_rate", flat=True))
        total = sum(costs)
        self.assertEqual(len(costs), 12)
        self.assertEqual(total, Decimal("100.000000"))
