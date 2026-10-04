"""Recalled lots and unscanned handsets go back to the supplier.

Sending a recalled lot back to whoever sold it is the normal end of a recall
(§6.8.1), and it was the one thing the shop could not do: ``pick_balances``
served sellable balances only, named lots included, and a unit in a
quarantined lot — or a placeholder still owing its identifier — was refused
as if it were being sold. The supplier return now opts in
(``releasing_to_supplier``); everything else keeps its stop-sales, which the
last class here proves.

Through the endpoints, because that is the path the adjustment dialogs take,
and every return ends on ``assert_tracking_invariants()``.
"""

from datetime import timedelta
from decimal import Decimal

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group
from django.test import TestCase
from django.urls import reverse
from django.utils import timezone
from rest_framework import serializers as drf
from rest_framework import status
from rest_framework.test import APIClient

from apps.catalog.models import Product
from apps.core.models import ShopSettings
from apps.core.roles import MANAGER_GROUP, ensure_role_groups
from apps.inventory.integrity import assert_tracking_invariants
from apps.inventory.models import (
    StockAllocation,
    StockBatch,
    StockBatchBalance,
    StockItem,
    StockLedgerEntry,
    StockUnit,
    Warehouse,
)
from apps.inventory import tracking
from apps.inventory.services import allocate_adjustment
from apps.inventory.tracked_testing import receive, tracked_product
from apps.purchasing.models import SupplierCredit
from apps.sales.models import RegisterSession
from apps.sales.services import checkout_order


def _quarantine(code):
    lot = StockBatch.objects.get(code=code)
    lot.status = StockBatch.Status.QUARANTINED
    lot.is_locked = True
    lot.save()
    return lot


def _allow_capture_later():
    settings = ShopSettings.load()
    settings.serialized_capture_later_allowed = True
    settings.save(update_fields=["serialized_capture_later_allowed", "updated_at"])


class _ReturnApiTestCase(TestCase):
    def setUp(self):
        ensure_role_groups()
        self.client = APIClient()
        user = get_user_model().objects.create_user(
            username="recall-buyer", password="pass"
        )
        user.groups.add(Group.objects.get(name=MANAGER_GROUP))
        self.client.force_authenticate(user=user)
        self.today = timezone.localdate()

    def _post(self, action, order, payload):
        return self.client.post(
            reverse(f"purchaseorder-{action}", args=[order.pk]),
            payload,
            format="json",
        )

    def _on_hand(self, variant):
        return StockItem.objects.get(variant=variant).quantity_on_hand

    def _balances(self, variant):
        return dict(
            StockBatchBalance.objects.filter(variant=variant).values_list(
                "batch__code", "remaining_quantity"
            )
        )

    def _return_entry(self, order):
        return StockLedgerEntry.objects.get(
            voucher_type=StockLedgerEntry.VoucherType.PURCHASE_RETURN,
            voucher_id=order.pk,
        )


class RecalledLotSupplierReturnTests(_ReturnApiTestCase):
    """A lot product: the recalled cohort goes back by name."""

    def setUp(self):
        super().setUp()
        product = tracked_product(
            name="شراب سعال", sku="SYRUP-RECALL", mode=Product.TrackingMode.BATCH
        )
        self.variant = product.default_variant
        self.order = receive(
            variant=self.variant,
            quantity=10,
            unit_cost="5.00",
            batches=[
                {
                    "code": "GOOD",
                    "quantity": 6,
                    "expiry_date": self.today + timedelta(days=200),
                },
                {
                    "code": "RECALLED",
                    "quantity": 4,
                    "expiry_date": self.today + timedelta(days=400),
                },
            ],
        )
        self.line = self.order.lines.get()
        self.recalled = _quarantine("RECALLED")

    def test_a_return_naming_the_quarantined_lot_sends_it_back(self):
        response = self._post(
            "return-items",
            self.order,
            {
                "lines": [
                    {"line": self.line.pk, "quantity": 4, "batches": [self.recalled.pk]}
                ]
            },
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK, response.data)
        self.assertEqual(
            self._balances(self.variant),
            {"GOOD": Decimal("6"), "RECALLED": Decimal("0")},
        )
        self.assertEqual(self._on_hand(self.variant), Decimal("6"))
        entry = self._return_entry(self.order)
        self.assertEqual(entry.value_change, Decimal("-20.000000"))
        self.assertEqual(
            [(row.batch.code, row.quantity) for row in entry.allocations.all()],
            [("RECALLED", Decimal("4.000"))],
        )
        self.assertEqual(SupplierCredit.objects.get().amount, Decimal("20.00"))
        # Still quarantined: going back to the supplier is not a release.
        self.recalled.refresh_from_db()
        self.assertFalse(self.recalled.is_sellable)
        assert_tracking_invariants()

    def test_a_refund_of_the_recalled_lot_is_accepted_too(self):
        response = self._post(
            "refund-items",
            self.order,
            {
                "lines": [
                    {"line": self.line.pk, "quantity": 2, "batches": [self.recalled.pk]}
                ]
            },
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK, response.data)
        self.assertEqual(
            self._balances(self.variant),
            {"GOOD": Decimal("6"), "RECALLED": Decimal("2")},
        )
        assert_tracking_invariants()

    def test_naming_both_lots_drains_the_recalled_one_first(self):
        good = StockBatch.objects.get(code="GOOD")

        response = self._post(
            "return-items",
            self.order,
            {
                "lines": [
                    {
                        "line": self.line.pk,
                        "quantity": 5,
                        "batches": [good.pk, self.recalled.pk],
                    }
                ]
            },
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK, response.data)
        self.assertEqual(
            self._balances(self.variant),
            {"GOOD": Decimal("5"), "RECALLED": Decimal("0")},
        )
        assert_tracking_invariants()

    def test_an_unnamed_return_keeps_to_the_good_stock(self):
        response = self._post(
            "return-items",
            self.order,
            {"lines": [{"line": self.line.pk, "quantity": 3}]},
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK, response.data)
        self.assertEqual(
            self._balances(self.variant),
            {"GOOD": Decimal("3"), "RECALLED": Decimal("4")},
        )
        assert_tracking_invariants()

    def test_an_unnamed_return_past_the_good_stock_takes_the_recalled_rest(self):
        response = self._post(
            "exchange-items",
            self.order,
            {"lines": [{"line": self.line.pk, "quantity": 8}]},
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK, response.data)
        self.assertEqual(self._balances(self.variant)["GOOD"], Decimal("0"))
        self.assertEqual(self._balances(self.variant)["RECALLED"], Decimal("2"))
        assert_tracking_invariants()

    def test_an_expired_lot_goes_back_by_name(self):
        good = StockBatch.objects.get(code="GOOD")
        good.expiry_date = self.today - timedelta(days=3)
        good.status = StockBatch.Status.EXPIRED
        good.save()

        response = self._post(
            "return-items",
            self.order,
            {"lines": [{"line": self.line.pk, "quantity": 6, "batches": [good.pk]}]},
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK, response.data)
        self.assertEqual(self._balances(self.variant)["GOOD"], Decimal("0"))
        assert_tracking_invariants()

    def test_more_than_the_named_lot_holds_is_still_refused(self):
        response = self._post(
            "return-items",
            self.order,
            {
                "lines": [
                    {"line": self.line.pk, "quantity": 5, "batches": [self.recalled.pk]}
                ]
            },
        )

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertFalse(self.order.adjustments.exists())
        self.assertEqual(self._balances(self.variant)["RECALLED"], Decimal("4"))
        self.assertEqual(self._on_hand(self.variant), Decimal("10"))

    def test_the_named_lot_is_drawn_in_the_orders_own_warehouse_only(self):
        branch = Warehouse.objects.create(name="فرع", code="BR-RC")
        # The lot has a row in a second place too — empty, so the bins agree —
        # and the return must not be served from it.
        tracking.lock_balance(batch=self.recalled, warehouse=branch, variant=self.variant)

        response = self._post(
            "return-items",
            self.order,
            {
                "lines": [
                    {"line": self.line.pk, "quantity": 1, "batches": [self.recalled.pk]}
                ]
            },
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK, response.data)
        here = StockBatchBalance.objects.get(
            batch=self.recalled, warehouse_id=Warehouse.default_id()
        )
        self.assertEqual(here.remaining_quantity, Decimal("3"))
        self.assertEqual(
            StockBatchBalance.objects.get(
                batch=self.recalled, warehouse=branch
            ).remaining_quantity,
            Decimal("0"),
        )
        assert_tracking_invariants()


class RecalledSerialBatchReturnTests(_ReturnApiTestCase):
    """Serial-and-lot: the pack is named, its lot is recalled."""

    def test_a_pack_in_a_quarantined_lot_goes_back_to_the_supplier(self):
        product = tracked_product(
            name="لقاح",
            sku="VAX-RECALL",
            mode=Product.TrackingMode.SERIAL_BATCH,
            unit_price="90.00",
        )
        variant = product.default_variant
        order = receive(
            variant=variant,
            quantity=2,
            unit_cost="40.00",
            batches=[
                {
                    "code": "LOT-R",
                    "quantity": 2,
                    "expiry_date": self.today + timedelta(days=300),
                }
            ],
            units=[
                {"code": "PACK-1", "batch_code": "LOT-R"},
                {"code": "PACK-2", "batch_code": "LOT-R"},
            ],
        )
        _quarantine("LOT-R")
        pack = StockUnit.objects.get(code="PACK-2")

        response = self._post(
            "return-items",
            order,
            {"lines": [{"line": order.lines.get().pk, "quantity": 1, "units": [pack.pk]}]},
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK, response.data)
        pack.refresh_from_db()
        self.assertEqual(pack.status, StockUnit.Status.RETURNED)
        self.assertEqual(
            StockUnit.objects.get(code="PACK-1").status, StockUnit.Status.IN_STOCK
        )
        self.assertEqual(self._balances(variant), {"LOT-R": Decimal("1")})
        self.assertEqual(self._on_hand(variant), Decimal("1"))
        self.assertEqual(
            self._return_entry(order).value_change, Decimal("-40.000000")
        )
        assert_tracking_invariants()


class ReturnablePickListTests(_ReturnApiTestCase):
    """What the return dialog's picker reads: ``stock-units`` without
    ``for_sale``, so a recalled pack and a placeholder are listed — and the
    pack says its lot is stopped."""

    def test_the_list_offers_recalled_packs_and_placeholders(self):
        _allow_capture_later()
        variant = tracked_product(
            name="لقاح",
            sku="VAX-LIST",
            mode=Product.TrackingMode.SERIAL_BATCH,
            unit_price="90.00",
        ).default_variant
        receive(
            variant=variant,
            quantity=2,
            unit_cost="40.00",
            batches=[{"code": "LOT-L", "quantity": 2}],
            units=[{"code": "PACK-L", "batch_code": "LOT-L"}],
        )
        _quarantine("LOT-L")

        response = self.client.get(
            reverse("stock-unit-list"),
            {
                "variant": variant.pk,
                "warehouse": Warehouse.default_id(),
                "status": StockUnit.Status.IN_STOCK,
            },
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK, response.data)
        rows = response.data.get("results", response.data)
        self.assertEqual(len(rows), 2)
        self.assertEqual(
            {(row["is_identified"], row["batch_status"]) for row in rows},
            {
                (True, StockBatch.Status.QUARANTINED),
                (False, StockBatch.Status.QUARANTINED),
            },
        )
        self.assertTrue(all(row["batch_is_sellable"] is False for row in rows))


class PlaceholderSupplierReturnTests(_ReturnApiTestCase):
    """A handset that arrived unscanned can go back unscanned."""

    def setUp(self):
        super().setUp()
        _allow_capture_later()
        product = tracked_product(
            name="هاتف", sku="PH-PLACE", mode=Product.TrackingMode.SERIAL
        )
        self.variant = product.default_variant
        self.order = receive(
            variant=self.variant,
            quantity=2,
            unit_cost="900.00",
            units=[{"code": "SN-REAL"}],
        )
        self.line = self.order.lines.get()
        self.placeholder = StockUnit.objects.get(
            variant=self.variant, is_identified=False
        )

    def test_a_placeholder_goes_back_by_id(self):
        response = self._post(
            "return-items",
            self.order,
            {
                "lines": [
                    {"line": self.line.pk, "quantity": 1, "units": [self.placeholder.pk]}
                ]
            },
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK, response.data)
        self.placeholder.refresh_from_db()
        self.assertEqual(self.placeholder.status, StockUnit.Status.RETURNED)
        self.assertEqual(
            StockUnit.objects.get(code="SN-REAL").status, StockUnit.Status.IN_STOCK
        )
        self.assertEqual(self._on_hand(self.variant), Decimal("1"))
        self.assertTrue(
            StockAllocation.objects.filter(
                unit=self.placeholder, direction=StockAllocation.Direction.OUT
            ).exists()
        )
        self.assertEqual(
            self._return_entry(self.order).value_change, Decimal("-900.000000")
        )
        assert_tracking_invariants()

    def test_an_exchange_sends_the_placeholder_back(self):
        response = self._post(
            "exchange-items",
            self.order,
            {
                "lines": [
                    {"line": self.line.pk, "quantity": 1, "units": [self.placeholder.pk]}
                ],
                "replacement_lines": [
                    {
                        "variant": self.variant.pk,
                        "quantity": 1,
                        "unit_cost": "900.00",
                        "units": [{"code": "SN-SWAP"}],
                    }
                ],
            },
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK, response.data)
        self.placeholder.refresh_from_db()
        self.assertEqual(self.placeholder.status, StockUnit.Status.RETURNED)
        self.assertTrue(StockUnit.objects.get(code="SN-SWAP").is_identified)
        self.assertEqual(self._on_hand(self.variant), Decimal("2"))
        assert_tracking_invariants()

    def test_a_placeholder_of_another_product_is_still_refused(self):
        other = tracked_product(
            name="هاتف آخر", sku="PH-OTHER", mode=Product.TrackingMode.SERIAL
        ).default_variant
        receive(variant=other, quantity=1, unit_cost="100.00")
        foreign = StockUnit.objects.get(variant=other, is_identified=False)

        response = self._post(
            "return-items",
            self.order,
            {"lines": [{"line": self.line.pk, "quantity": 1, "units": [foreign.pk]}]},
        )

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        foreign.refresh_from_db()
        self.assertEqual(foreign.status, StockUnit.Status.IN_STOCK)
        self.assertFalse(self.order.adjustments.exists())

    def test_a_returned_placeholder_cannot_go_back_twice(self):
        payload = {
            "lines": [
                {"line": self.line.pk, "quantity": 1, "units": [self.placeholder.pk]}
            ]
        }
        first = self._post("return-items", self.order, payload)
        self.assertEqual(first.status_code, status.HTTP_200_OK, first.data)

        second = self._post("return-items", self.order, payload)

        self.assertEqual(second.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertEqual(self.order.adjustments.count(), 1)
        self.assertEqual(self._on_hand(self.variant), Decimal("1"))
        assert_tracking_invariants()


_TILL = 0


def _till():
    global _TILL
    _TILL += 1
    return RegisterSession.objects.create(
        owner_key=f"recall-till-{_TILL}",
        status=RegisterSession.Status.OPEN,
        opening_cash=Decimal("0.00"),
    )


def _sell(variant, *, price="10.00", **line_extra):
    return checkout_order(
        register_session=_till(),
        lines_data=[{"variant": variant, "quantity": Decimal("1"), **line_extra}],
        payments_data=[{"method": "cash", "amount": Decimal(price)}],
    )


class StopSalesStillHoldEverywhereElseTests(TestCase):
    """The opt-in is the supplier return's alone.

    A sale, a manual write-off and the shared allocation door's default — the
    one transfers, counts and job materials go through — refuse a recalled lot
    and a placeholder exactly as they did before.
    """

    def setUp(self):
        ensure_role_groups()
        user = get_user_model().objects.create_user(
            username="recall-clerk", password="pass"
        )
        user.groups.add(Group.objects.get(name=MANAGER_GROUP))
        self.client = APIClient()
        self.client.force_authenticate(user=user)
        self.today = timezone.localdate()

    def _lot_product(self):
        variant = tracked_product(
            name="شراب", sku="SY-STOP", mode=Product.TrackingMode.BATCH
        ).default_variant
        receive(
            variant=variant,
            quantity=4,
            unit_cost="5.00",
            batches=[
                {
                    "code": "STOP",
                    "quantity": 4,
                    "expiry_date": self.today + timedelta(days=300),
                }
            ],
        )
        return variant, _quarantine("STOP")

    def _placeholder(self):
        _allow_capture_later()
        variant = tracked_product(
            name="هاتف",
            sku="PH-STOP",
            mode=Product.TrackingMode.SERIAL,
            unit_price="1500.00",
        ).default_variant
        receive(variant=variant, quantity=1, unit_cost="900.00")
        return variant, StockUnit.objects.get(variant=variant, is_identified=False)

    def _decrease(self, variant, **extra):
        return self.client.post(
            "/api/stock-movements/",
            {
                "variant": variant.pk,
                "movement_type": "decrease",
                "quantity": "1",
                **extra,
            },
            format="json",
        )

    def test_a_sale_still_refuses_a_quarantined_lot(self):
        variant, lot = self._lot_product()

        with self.assertRaises(drf.ValidationError):
            _sell(variant, stock_batches=[lot.pk])

        self.assertEqual(
            StockBatchBalance.objects.get(batch=lot).remaining_quantity,
            Decimal("4"),
        )

    def test_a_sale_still_refuses_a_pack_in_a_quarantined_lot(self):
        variant = tracked_product(
            name="لقاح",
            sku="VAX-STOP",
            mode=Product.TrackingMode.SERIAL_BATCH,
            unit_price="90.00",
        ).default_variant
        receive(
            variant=variant,
            quantity=1,
            unit_cost="40.00",
            batches=[{"code": "LOT-S", "quantity": 1}],
            units=[{"code": "PACK-S", "batch_code": "LOT-S"}],
        )
        _quarantine("LOT-S")
        pack = StockUnit.objects.get(code="PACK-S")

        with self.assertRaises(drf.ValidationError) as caught:
            _sell(variant, price="90.00", stock_units=[pack.pk])

        self.assertIn("محجورة", str(caught.exception.detail))
        pack.refresh_from_db()
        self.assertEqual(pack.status, StockUnit.Status.IN_STOCK)

    def test_a_sale_still_refuses_a_placeholder(self):
        variant, placeholder = self._placeholder()

        with self.assertRaises(drf.ValidationError) as caught:
            _sell(variant, price="1500.00", stock_units=[placeholder.pk])

        self.assertIn("لم يُسجَّل معرّفها", str(caught.exception.detail))
        placeholder.refresh_from_db()
        self.assertEqual(placeholder.status, StockUnit.Status.IN_STOCK)

    def test_a_manual_write_off_still_refuses_a_quarantined_lot(self):
        variant, lot = self._lot_product()

        response = self._decrease(variant, batches=[lot.pk])

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertEqual(
            StockBatchBalance.objects.get(batch=lot).remaining_quantity,
            Decimal("4"),
        )
        self.assertEqual(
            StockItem.objects.get(variant=variant).quantity_on_hand, Decimal("4")
        )

    def test_a_manual_write_off_still_refuses_a_placeholder(self):
        variant, placeholder = self._placeholder()

        response = self._decrease(variant, units=[placeholder.pk])

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertIn("لم يُسجَّل معرّفها", str(response.data))
        placeholder.refresh_from_db()
        self.assertEqual(placeholder.status, StockUnit.Status.IN_STOCK)

    def test_the_shared_door_refuses_both_by_default(self):
        """Transfers, counts and job materials all go through this default."""
        lot_variant, lot = self._lot_product()
        unit_variant, placeholder = self._placeholder()

        with self.assertRaises(drf.ValidationError):
            allocate_adjustment(
                variant=lot_variant,
                warehouse=Warehouse.default_id(),
                delta=Decimal("-1"),
                batches=[lot.pk],
            )
        with self.assertRaises(drf.ValidationError):
            allocate_adjustment(
                variant=unit_variant,
                warehouse=Warehouse.default_id(),
                delta=Decimal("-1"),
                units=[placeholder.pk],
            )
