"""Editing a received order whose goods are lots or serials, after some sold.

Every scenario ends with ``assert_tracking_invariants``: an edit that gets its
own numbers right and leaves a bin disagreeing with its articles is the bug
this whole path exists to avoid.
"""

from datetime import timedelta
from decimal import Decimal

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group
from django.test import TestCase
from django.urls import reverse
from django.utils import timezone
from rest_framework import serializers, status
from rest_framework.test import APIClient

from apps.catalog.models import Product
from apps.core.models import ShopSettings
from apps.core.roles import MANAGER_GROUP, ensure_role_groups
from apps.inventory.integrity import assert_tracking_invariants
from apps.inventory.models import (
    StockBatchBalance,
    StockItem,
    StockUnit,
    StockValuationBin,
)
from apps.inventory.tracked_testing import receive, tracked_product
from apps.sales.models import RegisterSession
from apps.sales.services import checkout_order

from .models import PurchaseOrder, PurchaseReceiptLine
from .services import save_purchase_order_with_lines

IMEI = [
    "351234567890116",
    "351234567890124",
    "351234567890132",
    "351234567890140",
]

_TILL = 0


def _sell(variant, quantity=1, *, price="100.00", **line_extra):
    global _TILL
    _TILL += 1
    session = RegisterSession.objects.create(
        owner_key=f"po-edit-till-{_TILL}",
        status=RegisterSession.Status.OPEN,
        opening_cash=Decimal("0.00"),
    )
    return checkout_order(
        register_session=session,
        lines_data=[{"variant": variant, "quantity": Decimal(quantity), **line_extra}],
        payments_data=[
            {"method": "cash", "amount": Decimal(price) * Decimal(quantity)}
        ],
    )


def _edit(order, variant, quantity, unit_cost, **extra):
    order.refresh_from_db()
    return save_purchase_order_with_lines(
        purchase_order=order,
        lines_data=[
            {
                "variant": variant,
                "quantity": Decimal(quantity),
                "unit": "",
                "unit_factor": Decimal("1"),
                "unit_cost": Decimal(unit_cost),
            }
        ],
        **extra,
    )


def _on_hand(variant):
    return StockItem.objects.get(variant=variant).quantity_on_hand


def _bin_value(variant):
    return StockValuationBin.objects.get(variant=variant).stock_value


class SerialOrderEditTests(TestCase):
    def setUp(self):
        self.product = tracked_product(
            name="هاتف",
            sku="POE-SER",
            mode=Product.TrackingMode.SERIAL,
            unit_price="1500.00",
        )
        self.variant = self.product.default_variant
        self.order = receive(
            variant=self.variant,
            quantity=4,
            unit_cost="1000.00",
            units=[{"code": code} for code in IMEI],
        )
        self.units = {
            unit.code: unit for unit in StockUnit.objects.filter(variant=self.variant)
        }

    def _sell_first(self):
        return _sell(
            self.variant,
            1,
            price="1500.00",
            stock_units=[self.units[IMEI[0]].pk],
        )

    def test_a_cost_correction_after_a_sale_restates_the_shelf_and_the_sale(self):
        sale = self._sell_first()

        _edit(self.order, self.variant, 4, "1100.00")

        self.order.refresh_from_db()
        self.assertEqual(self.order.status, PurchaseOrder.Status.RECEIVED)
        self.assertEqual(StockUnit.objects.filter(variant=self.variant).count(), 4)
        for unit in StockUnit.objects.filter(variant=self.variant):
            self.assertEqual(unit.incoming_rate, Decimal("1100.000000"))
        self.assertEqual(_on_hand(self.variant), 3)
        self.assertEqual(_bin_value(self.variant), Decimal("3300.000000"))
        self.assertEqual(sale.lines.get().unit_cost, Decimal("1100.00"))
        assert_tracking_invariants()

    def test_a_sale_in_a_closed_period_keeps_its_cost(self):
        from apps.sales.models import Order

        sale = self._sell_first()
        # The sale fell in a month since closed; the order is corrected today.
        Order.objects.filter(pk=sale.pk).update(
            created_at=timezone.now() - timedelta(days=40)
        )
        settings = ShopSettings.load()
        settings.books_locked_through = timezone.localdate() - timedelta(days=30)
        settings.save()

        _edit(self.order, self.variant, 4, "1100.00")

        self.assertEqual(sale.lines.get().unit_cost, Decimal("1000.00"))
        self.assertEqual(_bin_value(self.variant), Decimal("3300.000000"))
        assert_tracking_invariants()

    def test_a_landed_cost_reaches_the_handsets_without_minting_new_ones(self):
        self._sell_first()

        self.order.refresh_from_db()
        save_purchase_order_with_lines(
            purchase_order=self.order,
            landed_cost_entries_data=[{"name": "شحن", "amount": Decimal("200.00")}],
        )

        self.assertEqual(
            StockUnit.objects.filter(variant=self.variant).count(), 4
        )
        self.assertEqual(
            StockUnit.objects.get(code=IMEI[1]).incoming_rate,
            Decimal("1050.000000"),
        )
        self.assertEqual(_bin_value(self.variant), Decimal("3150.000000"))
        assert_tracking_invariants()

    def test_lowering_the_line_asks_which_handsets_never_came(self):
        self._sell_first()

        with self.assertRaises(serializers.ValidationError) as caught:
            _edit(self.order, self.variant, 3, "1000.00")

        detail = caught.exception.detail
        self.assertEqual(str(detail["code"]), "purchase_edit_units_required")
        line = detail["lines"][0]
        self.assertEqual(int(line["remove_count"]), 1)
        self.assertEqual(
            sorted(str(row["code"]) for row in line["candidates"]), IMEI[1:]
        )
        self.assertEqual(_on_hand(self.variant), 3)

    def test_lowering_the_line_cancels_the_handsets_the_owner_named(self):
        self._sell_first()
        gone = self.units[IMEI[2]]

        _edit(self.order, self.variant, 3, "1000.00", removed_units=[gone.pk])

        gone.refresh_from_db()
        self.assertEqual(gone.status, StockUnit.Status.CANCELLED)
        self.assertEqual(_on_hand(self.variant), 2)
        self.assertEqual(_bin_value(self.variant), Decimal("2000.000000"))
        line = self.order.lines.get()
        self.assertEqual(line.quantity, 3)
        self.assertEqual(line.accepted_quantity, 3)
        self.assertEqual(line.outstanding_quantity, 0)
        self.order.refresh_from_db()
        self.assertEqual(self.order.status, PurchaseOrder.Status.RECEIVED)
        self.assertEqual(StockItem.objects.get(variant=self.variant).quantity_expected, 0)
        assert_tracking_invariants()

    def test_a_named_handset_that_sold_is_refused(self):
        self._sell_first()

        with self.assertRaises(serializers.ValidationError) as caught:
            _edit(
                self.order,
                self.variant,
                3,
                "1000.00",
                removed_units=[self.units[IMEI[0]].pk],
            )

        self.assertEqual(str(caught.exception.detail["code"]), "purchase_edit_units_required")

    def test_lowering_below_what_sold_is_refused(self):
        self._sell_first()
        _sell(
            self.variant,
            2,
            price="1500.00",
            stock_units=[self.units[IMEI[1]].pk, self.units[IMEI[2]].pk],
        )

        with self.assertRaises(serializers.ValidationError) as caught:
            _edit(self.order, self.variant, 2, "1000.00")

        detail = caught.exception.detail
        self.assertEqual(str(detail["code"]), "purchase_stock_already_sold")
        self.assertEqual(Decimal(str(detail["stock"][0]["available"])), 1)
        self.assertEqual(_on_hand(self.variant), 1)
        assert_tracking_invariants()

    def test_raising_the_line_leaves_the_extra_to_be_received(self):
        self._sell_first()

        _edit(self.order, self.variant, 6, "1000.00")

        self.order.refresh_from_db()
        self.assertEqual(self.order.status, PurchaseOrder.Status.PARTIALLY_RECEIVED)
        self.assertIsNone(self.order.received_at)
        line = self.order.lines.get()
        self.assertEqual(line.outstanding_quantity, 2)
        self.assertEqual(StockUnit.objects.filter(variant=self.variant).count(), 4)
        stock_item = StockItem.objects.get(variant=self.variant)
        self.assertEqual(stock_item.quantity_on_hand, 3)
        self.assertEqual(stock_item.quantity_expected, 2)
        assert_tracking_invariants()

    def test_dropping_the_line_cancels_its_handsets_when_none_sold(self):
        other = tracked_product(
            name="سماعة",
            sku="POE-PLAIN",
            mode=Product.TrackingMode.QUANTITY,
        ).default_variant

        _edit(self.order, other, 2, "10.00")

        self.assertEqual(
            StockUnit.objects.filter(
                variant=self.variant, status=StockUnit.Status.CANCELLED
            ).count(),
            4,
        )
        self.assertEqual(_on_hand(self.variant), 0)
        self.assertEqual(_on_hand(other), 2)
        self.assertEqual(self.order.lines.get().variant, other)
        assert_tracking_invariants()

    def test_dropping_a_line_that_sold_from_is_refused(self):
        self._sell_first()
        other = tracked_product(
            name="سماعة",
            sku="POE-PLAIN-2",
            mode=Product.TrackingMode.QUANTITY,
        ).default_variant

        with self.assertRaises(serializers.ValidationError) as caught:
            _edit(self.order, other, 2, "10.00")

        self.assertEqual(
            str(caught.exception.detail["code"]), "purchase_stock_already_sold"
        )

    def test_an_untouched_line_moves_nothing(self):
        self._sell_first()
        receipt_rows = list(
            PurchaseReceiptLine.objects.filter(
                purchase_line__purchase_order=self.order
            ).values_list("pk", "accepted_quantity")
        )

        _edit(self.order, self.variant, 4, "1000.00")

        self.assertEqual(
            list(
                PurchaseReceiptLine.objects.filter(
                    purchase_line__purchase_order=self.order
                ).values_list("pk", "accepted_quantity")
            ),
            receipt_rows,
        )
        self.assertEqual(_on_hand(self.variant), 3)
        assert_tracking_invariants()


class LotOrderEditTests(TestCase):
    def setUp(self):
        self.product = tracked_product(
            name="مضاد حيوي",
            sku="POE-LOT",
            mode=Product.TrackingMode.BATCH,
            unit_price="20.00",
        )
        self.variant = self.product.default_variant
        self.order = receive(
            variant=self.variant,
            quantity=10,
            unit_cost="10.00",
            batches=[
                {
                    "code": "L-A",
                    "quantity": Decimal("10"),
                    "expiry_date": timezone.localdate() + timedelta(days=300),
                }
            ],
        )
        self.sale = _sell(self.variant, 4, price="20.00")

    def _balance(self):
        return StockBatchBalance.objects.get(batch__code="L-A")

    def test_a_cost_correction_re_rates_the_lot_and_restates_the_sale(self):
        _edit(self.order, self.variant, 10, "12.00")

        balance = self._balance()
        self.assertEqual(balance.incoming_rate, Decimal("12.000000"))
        self.assertEqual(balance.remaining_quantity, 6)
        self.assertEqual(_bin_value(self.variant), Decimal("72.000000"))
        self.assertEqual(self.sale.lines.get().unit_cost, Decimal("12.00"))
        assert_tracking_invariants()

    def test_lowering_within_what_is_left_gives_the_lot_back(self):
        _edit(self.order, self.variant, 7, "10.00")

        self.assertEqual(self._balance().remaining_quantity, 3)
        self.assertEqual(_on_hand(self.variant), 3)
        self.assertEqual(_bin_value(self.variant), Decimal("30.000000"))
        self.assertEqual(self.order.lines.get().accepted_quantity, 7)
        assert_tracking_invariants()

    def test_lowering_below_what_sold_is_refused(self):
        with self.assertRaises(serializers.ValidationError) as caught:
            _edit(self.order, self.variant, 3, "10.00")

        detail = caught.exception.detail
        self.assertEqual(str(detail["code"]), "purchase_stock_already_sold")
        self.assertEqual(Decimal(str(detail["stock"][0]["available"])), 6)
        self.assertEqual(self._balance().remaining_quantity, 6)

    def test_raising_leaves_the_extra_outstanding_in_no_lot(self):
        _edit(self.order, self.variant, 12, "10.00")

        self.assertEqual(self._balance().remaining_quantity, 6)
        self.assertEqual(self.order.lines.get().outstanding_quantity, 2)
        self.order.refresh_from_db()
        self.assertEqual(self.order.status, PurchaseOrder.Status.PARTIALLY_RECEIVED)
        assert_tracking_invariants()

    def test_an_edit_then_a_cost_correction_stay_in_step(self):
        _edit(self.order, self.variant, 8, "10.00")
        _edit(self.order, self.variant, 8, "11.00")

        balance = self._balance()
        self.assertEqual(balance.remaining_quantity, 4)
        self.assertEqual(
            _bin_value(self.variant),
            balance.remaining_quantity * balance.incoming_rate,
        )
        assert_tracking_invariants()


class MixedOrderEditTests(TestCase):
    """A plain line and a serial line on one order: the plain one replays, the
    serial one is corrected where it stands, and neither disturbs the other."""

    def setUp(self):
        self.handset = tracked_product(
            name="هاتف",
            sku="POE-MIX-S",
            mode=Product.TrackingMode.SERIAL,
            unit_price="900.00",
        ).default_variant
        self.cable = tracked_product(
            name="كابل",
            sku="POE-MIX-Q",
            mode=Product.TrackingMode.QUANTITY,
        ).default_variant
        self.order = receive(
            variant=self.handset,
            quantity=2,
            unit_cost="500.00",
            units=[{"code": IMEI[0]}, {"code": IMEI[1]}],
        )
        cable_line = self.order.lines.create(
            variant=self.cable, quantity=Decimal("5"), unit_cost=Decimal("3.00")
        )
        from apps.inventory.services import lock_stock_item

        # Put the cables on the shelf the way a second delivery would.
        stock_item = lock_stock_item(variant=self.cable, warehouse=None)
        stock_item.quantity_on_hand = Decimal("5")
        stock_item.save(update_fields=["quantity_on_hand"])
        PurchaseReceiptLine.objects.create(
            receipt=self.order.receipts.get(),
            purchase_line=cable_line,
            variant=self.cable,
            ordered_quantity=Decimal("5"),
            outstanding_before=Decimal("5"),
            accepted_quantity=Decimal("5"),
            expected_reduction_quantity=Decimal("5"),
        )

    def test_both_lines_edit_together(self):
        _sell(self.handset, 1, price="900.00", stock_unit_codes=[IMEI[0]])
        self.order.refresh_from_db()

        save_purchase_order_with_lines(
            purchase_order=self.order,
            lines_data=[
                {
                    "variant": self.handset,
                    "quantity": Decimal("2"),
                    "unit": "",
                    "unit_factor": Decimal("1"),
                    "unit_cost": Decimal("550.00"),
                },
                {
                    "variant": self.cable,
                    "quantity": Decimal("6"),
                    "unit": "",
                    "unit_factor": Decimal("1"),
                    "unit_cost": Decimal("3.00"),
                },
            ],
        )

        self.assertEqual(StockUnit.objects.filter(variant=self.handset).count(), 2)
        self.assertEqual(_on_hand(self.handset), 1)
        self.assertEqual(_on_hand(self.cable), 6)
        self.order.refresh_from_db()
        self.assertEqual(self.order.status, PurchaseOrder.Status.RECEIVED)
        self.assertEqual(
            [line.variant_id for line in self.order.lines.order_by("created_at")],
            [self.handset.pk, self.cable.pk],
        )
        assert_tracking_invariants()


class IdentifiedOrderEditApiTests(TestCase):
    def setUp(self):
        ensure_role_groups()
        self.client = APIClient()
        user = get_user_model().objects.create_user(username="po-edit", password="x")
        user.groups.add(Group.objects.get(name=MANAGER_GROUP))
        self.client.force_authenticate(user=user)
        self.variant = tracked_product(
            name="هاتف",
            sku="POE-API",
            mode=Product.TrackingMode.SERIAL,
            unit_price="900.00",
        ).default_variant
        self.order = receive(
            variant=self.variant,
            quantity=3,
            unit_cost="700.00",
            units=[{"code": code} for code in IMEI[:3]],
        )

    def _patch(self, **extra):
        return self.client.patch(
            reverse("purchaseorder-detail", args=[self.order.pk]),
            {
                "lines": [
                    {"variant": self.variant.pk, "quantity": 2, "unit_cost": "700.00"}
                ],
                **extra,
            },
            format="json",
        )

    def test_the_handset_choice_round_trips_through_the_api(self):
        refused = self._patch()
        self.assertEqual(refused.status_code, status.HTTP_400_BAD_REQUEST, refused.data)
        self.assertEqual(refused.data["code"], "purchase_edit_units_required")
        candidate = refused.data["lines"][0]["candidates"][1]["id"]

        response = self._patch(removed_units=[candidate])

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(
            StockUnit.objects.get(pk=candidate).status, StockUnit.Status.CANCELLED
        )
        self.assertEqual(_on_hand(self.variant), 2)
        assert_tracking_invariants()

    def test_a_stranger_unit_is_refused(self):
        other = tracked_product(
            name="هاتف آخر", sku="POE-API-2", mode=Product.TrackingMode.SERIAL
        ).default_variant
        receive(variant=other, quantity=1, unit_cost="1.00", units=[{"code": IMEI[3]}])
        stranger = StockUnit.objects.get(code=IMEI[3])
        mine = StockUnit.objects.get(code=IMEI[0])

        response = self._patch(removed_units=[mine.pk, stranger.pk])

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertEqual(response.data["code"], "purchase_edit_unknown_units")


class IdentifiedEdgeCaseTests(TestCase):
    def test_serial_batch_cost_and_quantity_correct_together(self):
        variant = tracked_product(
            name="لقاح",
            sku="POE-SB",
            mode=Product.TrackingMode.SERIAL_BATCH,
            unit_price="300.00",
        ).default_variant
        order = receive(
            variant=variant,
            quantity=3,
            unit_cost="100.00",
            units=[{"code": code} for code in IMEI[:3]],
            batches=[{"code": "SB-LOT"}],
        )
        _sell(variant, 1, price="300.00", stock_unit_codes=[IMEI[0]])
        gone = StockUnit.objects.get(code=IMEI[2])

        _edit(order, variant, 2, "120.00", removed_units=[gone.pk])

        gone.refresh_from_db()
        self.assertEqual(gone.status, StockUnit.Status.CANCELLED)
        self.assertEqual(
            StockUnit.objects.get(code=IMEI[1]).incoming_rate, Decimal("120.000000")
        )
        self.assertEqual(_on_hand(variant), 1)
        self.assertEqual(_bin_value(variant), Decimal("120.000000"))
        assert_tracking_invariants()

    def test_dropping_a_line_cancels_its_damaged_handsets_too(self):
        variant = tracked_product(
            name="هاتف",
            sku="POE-DMG",
            mode=Product.TrackingMode.SERIAL,
            unit_price="900.00",
        ).default_variant
        order = receive(
            variant=variant,
            quantity=2,
            damaged_quantity=1,
            unit_cost="500.00",
            units=[{"code": code} for code in IMEI[:3]],
        )
        other = tracked_product(
            name="كابل", sku="POE-DMG-Q", mode=Product.TrackingMode.QUANTITY
        ).default_variant

        _edit(order, other, 1, "5.00")

        self.assertEqual(
            StockUnit.objects.filter(
                variant=variant, status=StockUnit.Status.CANCELLED
            ).count(),
            3,
        )
        self.assertFalse(
            PurchaseReceiptLine.objects.filter(purchase_line__variant=variant).exists()
        )
        self.assertEqual(_on_hand(variant), 0)
        assert_tracking_invariants()

    def test_a_customer_return_after_a_cost_correction_comes_back_at_the_new_cost(
        self,
    ):
        from apps.sales.services import create_order_adjustment

        variant = tracked_product(
            name="هاتف",
            sku="POE-RET",
            mode=Product.TrackingMode.SERIAL,
            unit_price="900.00",
        ).default_variant
        order = receive(
            variant=variant,
            quantity=2,
            unit_cost="500.00",
            units=[{"code": code} for code in IMEI[:2]],
        )
        sale = _sell(variant, 1, price="900.00", stock_unit_codes=[IMEI[0]])

        _edit(order, variant, 2, "600.00")
        self.assertEqual(sale.lines.get().unit_cost, Decimal("600.00"))

        create_order_adjustment(
            order=sale,
            adjustment_type="refund",
            lines=[(sale.lines.get(), Decimal("1"))],
            reason="test",
        )

        self.assertEqual(_on_hand(variant), 2)
        self.assertEqual(_bin_value(variant), Decimal("1200.000000"))
        assert_tracking_invariants()

    def test_a_lot_two_orders_filled_is_re_rated_by_this_orders_share(self):
        variant = tracked_product(
            name="شراب",
            sku="POE-SHARE",
            mode=Product.TrackingMode.BATCH,
            unit_price="30.00",
        ).default_variant
        expiry = timezone.localdate() + timedelta(days=200)
        first = receive(
            variant=variant,
            quantity=10,
            unit_cost="10.00",
            batches=[{"code": "SH", "quantity": Decimal("10"), "expiry_date": expiry}],
        )
        receive(
            variant=variant,
            quantity=10,
            unit_cost="10.00",
            batches=[{"code": "SH", "quantity": Decimal("10"), "expiry_date": expiry}],
        )

        _edit(first, variant, 10, "14.00")

        balance = StockBatchBalance.objects.get(batch__code="SH")
        # Half the lot came on this order, so half the correction lands on it.
        self.assertEqual(balance.incoming_rate, Decimal("12.000000"))
        self.assertEqual(_bin_value(variant), Decimal("240.000000"))
        assert_tracking_invariants()
