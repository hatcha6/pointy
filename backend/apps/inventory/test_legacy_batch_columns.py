from decimal import Decimal

from django.test import TestCase

from apps.catalog.models import Product
from apps.inventory.models import StockBatch, StockBatchBalance
from apps.inventory.tracked_testing import receive, tracked_product
from apps.sales.models import RegisterSession
from apps.sales.services import checkout_order


class R1LegacyColumnsSurvive(TestCase):
    """Exactly what the release currently in shops does, against this schema.

    §15.1 R1. During an update the edge nginx serves the previous backend
    against the new schema for about a minute, and that backend decrements
    ``remaining_quantity`` on the checkout path and joins
    ``source_receipt_line`` in its expiry-alert query. If this file ever goes
    red, the batch split has been contracted too early and an update will 500
    every sale of an expiry-tracked product in every shop that uses expiry.
    Delete it in the contract release, with the columns and the dual-write.
    """

    def test_the_previous_releases_queries_still_run(self):
        p = tracked_product(name="Panadol", sku="R1",
                            mode=Product.TrackingMode.BATCH, unit_price="10.00")
        v = p.default_variant
        receive(variant=v, quantity=100, unit_cost="5.00",
                batches=[{"code": "A7719", "quantity": Decimal("100")}])

        # 1. the checkout-path query: FEFO over the legacy column
        rows = list(
            StockBatch.objects.select_for_update()
            .filter(variant=v, remaining_quantity__gt=0)
            .order_by("expiry_date")
        )
        self.assertEqual(rows[0].remaining_quantity, Decimal("100.000"))
        self.assertEqual(rows[0].received_quantity, Decimal("100.000"))

        # 2. the expiry-alert join the old release does
        alerted = list(
            StockBatch.objects.select_related(
                "source_receipt_line",
                "source_receipt_line__receipt",
                "source_receipt_line__receipt__purchase_order",
                "source_receipt_line__receipt__purchase_order__supplier",
            ).filter(remaining_quantity__gt=0)
        )
        self.assertEqual(len(alerted), 1)

        # 3. a sale on the NEW code keeps the mirror current
        checkout_order(
            register_session=RegisterSession.objects.create(
                owner_key="r1", status=RegisterSession.Status.OPEN,
                opening_cash=Decimal("0.00")),
            lines_data=[{"variant": v, "quantity": Decimal("30")}],
            payments_data=[{"method": "cash", "amount": Decimal("300.00")}],
        )
        lot = StockBatch.objects.get(code="A7719")
        balance = StockBatchBalance.objects.get()
        self.assertEqual(lot.remaining_quantity, balance.remaining_quantity)
        self.assertEqual(lot.remaining_quantity, Decimal("70.000"))
        self.assertEqual(lot.received_quantity, Decimal("100.000"))
