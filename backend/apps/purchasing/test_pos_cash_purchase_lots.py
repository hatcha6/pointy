"""The counter cash purchase names the lots its goods came in.

A ``batch`` or ``serial_batch`` article bought from the drawer is received the
moment it is bought, so the lot code and expiry the cashier reads off the box
ride in on the order line beside the IMEIs — the receive endpoint's own row
shape, quantities in base units. ``serial_batch`` cannot be bought without its
lot; a ``batch`` line with no lot named falls back, explicitly, to one generated
lot carrying the line's expiry, which is what kept the grocery's bread and milk
runs working before lots could be typed here at all.

Everything goes through the endpoint, never the service: the client half of
identified stock was once built and unreachable because every test called the
service directly.
"""

from datetime import date
from decimal import Decimal

from django.urls import reverse
from rest_framework import status
from rest_framework.test import APIClient

from apps.catalog.models import Product, ProductUnit, UnitOfMeasure
from apps.inventory.integrity import assert_tracking_invariants
from apps.inventory.models import (
    StockBatch,
    StockBatchBalance,
    StockUnit,
    StockValuationBin,
    Warehouse,
)
from apps.inventory.tracked_testing import tracked_product
from apps.sales.models import RegisterCashMovement, RegisterProfile
from apps.sales.services import checkout_order

from .models import PurchaseOrder
from .test_pos_cash_purchase import PosCashPurchaseTestCase


class CounterLotCaptureTestCase(PosCashPurchaseTestCase):
    def setUp(self):
        super().setUp()
        self.session = self.open_session(self.cashier)

    def buy(self, *lines, client=None):
        return self.post_purchase(client=client, lines=list(lines))

    def lot_product(self, mode, *, sku, expiry_required=False, unit_price="5.00"):
        # Priced above what the tests pay: the counter's cost guard blocks a
        # cost over the sale price outright.
        product = tracked_product(
            name=f"صنف {sku}", sku=sku, mode=mode, unit_price=unit_price
        )
        if expiry_required:
            product.expiry_required = True
            product.save(update_fields=["expiry_required", "updated_at"])
        return product.default_variant

    def assert_refused_without_trace(self, response, fragment):
        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertIn(fragment, str(response.data))
        # The whole purchase rolls back: no order, no stock, no drawer money.
        self.assertFalse(PurchaseOrder.objects.exists())
        self.assertFalse(StockUnit.objects.exists())
        self.assertFalse(
            RegisterCashMovement.objects.filter(
                register_session=self.session
            ).exists()
        )


class BatchLineTests(CounterLotCaptureTestCase):
    def test_a_captured_lot_lands_in_the_tills_warehouse_at_the_base_rate(self):
        variant = self.lot_product(Product.TrackingMode.BATCH, sku="LOT-MILK")
        ProductUnit.objects.create(
            product=variant.product,
            unit=UnitOfMeasure.objects.get(code="carton"),
            factor_to_base=Decimal("12"),
        )
        store = Warehouse.objects.create(name="المخزن", code="lot-store")
        RegisterProfile.objects.create(device_id="till-lots", warehouse=store)
        client = APIClient()
        client.force_authenticate(user=self.cashier)
        client.credentials(HTTP_X_POINTY_DEVICE_ID="till-lots")

        # Two cartons of twelve; one lot read off the box, sent without a
        # quantity because it is the whole line.
        response = self.buy(
            {
                "variant": variant.pk,
                "quantity": "2",
                "unit": "carton",
                "unit_cost": "24.00",
                "batches": [{"code": "A-2026-01", "expiry_date": "2027-03-31"}],
            },
            client=client,
        )

        self.assertEqual(response.status_code, status.HTTP_201_CREATED, response.data)
        lot = StockBatch.objects.get(variant=variant)
        self.assertEqual(lot.code, "A-2026-01")
        self.assertEqual(lot.expiry_date, date(2027, 3, 31))
        self.assertFalse(lot.code_is_generated)
        balance = StockBatchBalance.objects.get(batch=lot)
        self.assertEqual(balance.warehouse_id, store.pk)
        # Base units: a carton of twelve is twelve, never one.
        self.assertEqual(balance.remaining_quantity, Decimal("24"))
        self.assertEqual(balance.incoming_rate, Decimal("2.000000"))
        valuation = StockValuationBin.objects.get(variant=variant, warehouse=store)
        self.assertEqual(valuation.quantity, Decimal("24"))
        self.assertEqual(valuation.stock_value, Decimal("48.000000"))
        self.session.refresh_from_db()
        self.assertEqual(self.session.pay_out_total, Decimal("48.00"))
        assert_tracking_invariants()

    def test_one_line_splits_across_two_lots(self):
        variant = self.lot_product(Product.TrackingMode.BATCH, sku="LOT-EGGS")
        response = self.buy(
            {
                "variant": variant.pk,
                "quantity": "10",
                "unit_cost": "1.00",
                "batches": [
                    {"code": "E-1", "quantity": "6", "expiry_date": "2026-12-01"},
                    {"code": "E-2", "quantity": "4", "expiry_date": "2026-12-15"},
                ],
            }
        )

        self.assertEqual(response.status_code, status.HTTP_201_CREATED, response.data)
        remaining = dict(
            StockBatchBalance.objects.filter(variant=variant).values_list(
                "batch__code", "remaining_quantity"
            )
        )
        self.assertEqual(remaining, {"E-1": Decimal("6"), "E-2": Decimal("4")})
        assert_tracking_invariants()

    def test_lots_that_do_not_add_up_are_refused_in_arabic(self):
        variant = self.lot_product(Product.TrackingMode.BATCH, sku="LOT-SHORT")
        response = self.buy(
            {
                "variant": variant.pk,
                "quantity": "10",
                "unit_cost": "1.00",
                "batches": [
                    {"code": "S-1", "quantity": "6"},
                    {"code": "S-2", "quantity": "3"},
                ],
            }
        )
        self.assert_refused_without_trace(response, "مجموع كميات الدفعات")

    def test_lots_sent_without_quantities_are_refused_not_generated(self):
        # Two rows and no quantities: skipped row by row, they would otherwise
        # have landed silently in a generated lot.
        variant = self.lot_product(Product.TrackingMode.BATCH, sku="LOT-BLANK")
        response = self.buy(
            {
                "variant": variant.pk,
                "quantity": "4",
                "unit_cost": "1.00",
                "batches": [{"code": "B-1"}, {"code": "B-2"}],
            }
        )
        self.assert_refused_without_trace(response, "مجموع كميات الدفعات")

    def test_a_lot_without_its_own_expiry_takes_the_lines(self):
        variant = self.lot_product(
            Product.TrackingMode.BATCH, sku="LOT-YOG", expiry_required=True
        )
        response = self.buy(
            {
                "variant": variant.pk,
                "quantity": "5",
                "unit_cost": "1.00",
                "expiry_date": "2026-11-30",
                "batches": [{"code": "Y-7"}],
            }
        )

        self.assertEqual(response.status_code, status.HTTP_201_CREATED, response.data)
        lot = StockBatch.objects.get(variant=variant)
        self.assertEqual(lot.expiry_date, date(2026, 11, 30))
        assert_tracking_invariants()

    def test_no_lot_named_falls_back_to_a_generated_lot_that_keeps_selling(self):
        """The explicit fallback: one generated lot, carrying the line's expiry.

        Requiring a lot code for every bread-and-milk run would take the counter
        purchase away from the shop it was built for, so a ``batch`` line may be
        bought without one. What it may not do is lose its expiry, or stop
        selling.
        """
        variant = self.lot_product(
            Product.TrackingMode.BATCH, sku="LOT-BREAD", expiry_required=True
        )
        response = self.buy(
            {
                "variant": variant.pk,
                "quantity": "20",
                "unit_cost": "0.35",
                "expiry_date": "2026-10-12",
            }
        )

        self.assertEqual(response.status_code, status.HTTP_201_CREATED, response.data)
        lot = StockBatch.objects.get(variant=variant)
        self.assertTrue(lot.code_is_generated)
        self.assertTrue(lot.code.startswith("LOT-PO"))
        self.assertEqual(lot.expiry_date, date(2026, 10, 12))
        balance = StockBatchBalance.objects.get(batch=lot)
        self.assertEqual(balance.remaining_quantity, Decimal("20"))
        self.assertEqual(balance.incoming_rate, Decimal("0.350000"))

        checkout_order(
            register_session=self.session,
            lines_data=[{"variant": variant, "quantity": Decimal("1")}],
            payments_data=[{"method": "cash", "amount": Decimal("5.00")}],
        )
        balance.refresh_from_db()
        self.assertEqual(balance.remaining_quantity, Decimal("19"))
        assert_tracking_invariants()


class SerialBatchLineTests(CounterLotCaptureTestCase):
    def setUp(self):
        super().setUp()
        self.variant = self.lot_product(
            Product.TrackingMode.SERIAL_BATCH, sku="LOT-VAX", unit_price="60.00"
        )

    def test_the_lot_header_and_every_imei_are_kept(self):
        response = self.buy(
            {
                "variant": self.variant.pk,
                "quantity": "2",
                "unit_cost": "40.00",
                "batches": [{"code": "VX-01", "expiry_date": "2027-01-31"}],
                "units": [{"code": "PACK-0001"}, {"code": "PACK-0002"}],
            }
        )

        self.assertEqual(response.status_code, status.HTTP_201_CREATED, response.data)
        lot = StockBatch.objects.get(variant=self.variant)
        self.assertEqual(lot.code, "VX-01")
        self.assertEqual(lot.expiry_date, date(2027, 1, 31))
        units = StockUnit.objects.filter(variant=self.variant).order_by("code")
        self.assertEqual(
            list(units.values_list("code", flat=True)), ["PACK-0001", "PACK-0002"]
        )
        self.assertTrue(all(unit.batch_id == lot.pk for unit in units))
        self.assertTrue(all(unit.is_identified for unit in units))
        self.assertEqual(
            StockBatchBalance.objects.get(batch=lot).remaining_quantity,
            Decimal("2"),
        )
        assert_tracking_invariants()

    def test_without_its_lot_it_is_refused_in_arabic(self):
        response = self.buy(
            {
                "variant": self.variant.pk,
                "quantity": "1",
                "unit_cost": "40.00",
                "units": [{"code": "PACK-0009"}],
            }
        )
        self.assert_refused_without_trace(response, "رقم الدفعة مطلوب")

    def test_a_second_lot_row_is_refused(self):
        response = self.buy(
            {
                "variant": self.variant.pk,
                "quantity": "2",
                "unit_cost": "40.00",
                "batches": [{"code": "VX-01"}, {"code": "VX-02"}],
                "units": [{"code": "PACK-0011"}, {"code": "PACK-0012"}],
            }
        )
        self.assert_refused_without_trace(response, "بدفعة واحدة")


class SameShapeTwiceTests(CounterLotCaptureTestCase):
    """Two counter purchases of one shape — the collision class.

    Generated codes once repeated across arrivals and crashed the second one on
    a unique index; any key built from the order and line has to survive being
    used twice in the same second.
    """

    def test_two_unnamed_batch_purchases_get_two_generated_lots(self):
        variant = self.lot_product(
            Product.TrackingMode.BATCH, sku="LOT-TWICE", expiry_required=True
        )
        line = {
            "variant": variant.pk,
            "quantity": "3",
            "unit_cost": "1.00",
            "expiry_date": "2026-12-31",
        }
        first = self.buy(line)
        second = self.buy(line)

        self.assertEqual(first.status_code, status.HTTP_201_CREATED, first.data)
        self.assertEqual(second.status_code, status.HTTP_201_CREATED, second.data)
        lots = StockBatch.objects.filter(variant=variant)
        self.assertEqual(lots.count(), 2)
        self.assertTrue(all(lot.code_is_generated for lot in lots))
        assert_tracking_invariants()

    def test_the_same_lot_bought_twice_is_one_lot(self):
        variant = self.lot_product(Product.TrackingMode.BATCH, sku="LOT-SAME")
        line = {
            "variant": variant.pk,
            "quantity": "3",
            "unit_cost": "1.00",
            "batches": [{"code": "SAME-1", "expiry_date": "2027-02-28"}],
        }
        self.assertEqual(self.buy(line).status_code, status.HTTP_201_CREATED)
        self.assertEqual(self.buy(line).status_code, status.HTTP_201_CREATED)

        lot = StockBatch.objects.get(variant=variant)
        self.assertEqual(
            StockBatchBalance.objects.get(batch=lot).remaining_quantity,
            Decimal("6"),
        )
        assert_tracking_invariants()

    def test_the_same_serial_batch_lot_bought_twice_holds_both_packs(self):
        variant = self.lot_product(
            Product.TrackingMode.SERIAL_BATCH, sku="LOT-SB-TWICE", unit_price="60.00"
        )
        for code in ("SB-PACK-1", "SB-PACK-2"):
            response = self.buy(
                {
                    "variant": variant.pk,
                    "quantity": "1",
                    "unit_cost": "40.00",
                    "batches": [{"code": "SB-LOT", "expiry_date": "2027-05-31"}],
                    "units": [{"code": code}],
                }
            )
            self.assertEqual(
                response.status_code, status.HTTP_201_CREATED, response.data
            )

        lot = StockBatch.objects.get(variant=variant)
        self.assertEqual(
            StockUnit.objects.filter(variant=variant, batch=lot).count(), 2
        )
        self.assertEqual(
            StockBatchBalance.objects.get(batch=lot).remaining_quantity,
            Decimal("2"),
        )
        assert_tracking_invariants()


class OrdinaryOrderTests(CounterLotCaptureTestCase):
    def test_an_ordinary_order_refuses_lot_rows_rather_than_dropping_them(self):
        """Only a flow that receives in the same call may carry captures."""
        variant = self.lot_product(Product.TrackingMode.BATCH, sku="LOT-PO")
        response = self.manager_client.post(
            reverse("purchaseorder-list"),
            {
                "supplier": self.supplier.pk,
                "lines": [
                    {
                        "variant": variant.pk,
                        "quantity": "3",
                        "unit_cost": "1.00",
                        "batches": [{"code": "PO-LOT", "quantity": "3"}],
                    }
                ],
            },
            format="json",
        )
        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertIn("عند استلام", str(response.data))
        self.assertFalse(PurchaseOrder.objects.exists())

    def test_an_ordinary_order_without_captures_is_unchanged(self):
        variant = self.lot_product(Product.TrackingMode.BATCH, sku="LOT-PO-OK")
        response = self.manager_client.post(
            reverse("purchaseorder-list"),
            {
                "supplier": self.supplier.pk,
                "lines": [
                    {"variant": variant.pk, "quantity": "3", "unit_cost": "1.00"}
                ],
            },
            format="json",
        )
        self.assertEqual(response.status_code, status.HTTP_201_CREATED, response.data)
        self.assertFalse(StockBatch.objects.exists())
