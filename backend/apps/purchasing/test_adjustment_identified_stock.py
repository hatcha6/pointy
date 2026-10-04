"""Supplier returns, refunds and exchanges of identified stock.

``return-items``, ``refund-items`` and ``exchange-items`` moved the bin and
named nothing, so ``post_movement_valuations`` refused every one of them on a
serial or lot product (ERPNext #42997) — a 500 on the one correction the
received-order edit guard tells the owner to use instead. These go through the
endpoints, which is the path the adjustment dialogs actually take.
"""

from datetime import date
from decimal import Decimal

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group
from django.test import TestCase
from django.urls import reverse
from rest_framework import status
from rest_framework.test import APIClient

from apps.catalog.models import Product, ProductUnit, UnitOfMeasure
from apps.core.roles import MANAGER_GROUP, ensure_role_groups
from apps.inventory.integrity import assert_tracking_invariants
from apps.inventory.models import (
    StockBatch,
    StockBatchBalance,
    StockItem,
    StockUnit,
)
from apps.inventory.tracked_testing import receive, tracked_product
from apps.purchasing.models import PurchaseOrder, Supplier, SupplierCredit
from apps.purchasing.services import receive_purchase_order, submit_purchase_order


class _AdjustmentApiTestCase(TestCase):
    def setUp(self):
        ensure_role_groups()
        self.client = APIClient()
        user = get_user_model().objects.create_user(
            username="buyer", password="pass"
        )
        user.groups.add(Group.objects.get(name=MANAGER_GROUP))
        self.client.force_authenticate(user=user)

    def _post(self, action, order, payload):
        return self.client.post(
            reverse(f"purchaseorder-{action}", args=[order.pk]),
            payload,
            format="json",
        )

    def _unit(self, code):
        return StockUnit.objects.get(code=code)

    def _on_hand(self, variant):
        return StockItem.objects.get(variant=variant).quantity_on_hand

    def _balances(self, variant):
        return dict(
            StockBatchBalance.objects.filter(variant=variant).values_list(
                "batch__code", "remaining_quantity"
            )
        )


class SerialSupplierReturnTests(_AdjustmentApiTestCase):
    def _phones(self, *codes, mode=Product.TrackingMode.SERIAL, batches=None):
        product = tracked_product(
            name="هاتف", sku="PHONE-RET", mode=mode, unit_price="1500.00"
        )
        variant = product.default_variant
        order = receive(
            variant=variant,
            quantity=len(codes),
            unit_cost="900.00",
            units=[{"code": code} for code in codes],
            batches=batches,
        )
        return variant, order, order.lines.get()

    def test_a_return_sends_back_the_handset_it_names(self):
        variant, order, line = self._phones("SN-1", "SN-2", "SN-3")

        response = self._post(
            "return-items",
            order,
            {
                "lines": [
                    {"line": line.pk, "quantity": 1, "units": [self._unit("SN-2").pk]}
                ]
            },
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK, response.data)
        self.assertEqual(self._unit("SN-2").status, StockUnit.Status.RETURNED)
        self.assertEqual(self._unit("SN-1").status, StockUnit.Status.IN_STOCK)
        self.assertEqual(self._unit("SN-3").status, StockUnit.Status.IN_STOCK)
        self.assertEqual(self._on_hand(variant), Decimal("2"))
        self.assertEqual(SupplierCredit.objects.get().amount, Decimal("900.00"))
        assert_tracking_invariants()

    def test_a_refund_accepts_the_scanned_code(self):
        variant, order, line = self._phones("SN-4", "SN-5")

        response = self._post(
            "refund-items",
            order,
            {"lines": [{"line": line.pk, "quantity": 1, "units": ["SN-5"]}]},
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK, response.data)
        self.assertEqual(self._unit("SN-5").status, StockUnit.Status.RETURNED)
        self.assertEqual(self._unit("SN-4").status, StockUnit.Status.IN_STOCK)
        assert_tracking_invariants()

    def test_a_return_that_names_no_handset_is_refused_in_arabic(self):
        variant, order, line = self._phones("SN-7", "SN-8")

        response = self._post(
            "return-items", order, {"lines": [{"line": line.pk, "quantity": 1}]}
        )

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertIn("حدّد الوحدات المُرجَعة للمورد", str(response.data["detail"]))
        self.assertFalse(order.adjustments.exists())
        self.assertEqual(self._on_hand(variant), Decimal("2"))
        self.assertEqual(
            set(StockUnit.objects.values_list("status", flat=True)),
            {StockUnit.Status.IN_STOCK},
        )

    def test_naming_fewer_handsets_than_the_quantity_is_refused(self):
        variant, order, line = self._phones("SN-9", "SN-10")

        response = self._post(
            "return-items",
            order,
            {"lines": [{"line": line.pk, "quantity": 2, "units": ["SN-9"]}]},
        )

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertIn("تم تحديد 1 وحدة لكمية قدرها 2", str(response.data["detail"]))
        self.assertFalse(order.adjustments.exists())

    def test_a_code_that_is_not_in_stock_is_refused_in_arabic(self):
        variant, order, line = self._phones("SN-11")

        response = self._post(
            "return-items",
            order,
            {"lines": [{"line": line.pk, "quantity": 1, "units": ["NOPE-1"]}]},
        )

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertIn("NOPE-1", str(response.data["detail"]))
        self.assertEqual(self._unit("SN-11").status, StockUnit.Status.IN_STOCK)

    def test_a_handset_cannot_go_back_twice(self):
        variant, order, line = self._phones("SN-12", "SN-13")
        unit_id = self._unit("SN-12").pk
        first = self._post(
            "return-items",
            order,
            {"lines": [{"line": line.pk, "quantity": 1, "units": [unit_id]}]},
        )
        self.assertEqual(first.status_code, status.HTTP_200_OK, first.data)

        # By id, so the refusal is the one taken under the unit's lock.
        second = self._post(
            "return-items",
            order,
            {"lines": [{"line": line.pk, "quantity": 1, "units": [unit_id]}]},
        )

        self.assertEqual(second.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertEqual(order.adjustments.count(), 1)
        self.assertEqual(self._unit("SN-13").status, StockUnit.Status.IN_STOCK)
        self.assertEqual(self._on_hand(variant), Decimal("1"))
        assert_tracking_invariants()

    def test_one_handset_cannot_go_back_on_two_lines(self):
        product = tracked_product(
            name="هاتف", sku="PHONE-2L", mode=Product.TrackingMode.SERIAL
        )
        variant = product.default_variant
        order = PurchaseOrder.objects.create(supplier=Supplier.objects.create(name="م"))
        first = order.lines.create(
            variant=variant, quantity=1, unit_cost=Decimal("900.00")
        )
        second = order.lines.create(
            variant=variant, quantity=1, unit_cost=Decimal("950.00")
        )
        order.recalculate()
        order.save(update_fields=["subtotal", "total", "updated_at"])
        submit_purchase_order(order)
        receive_purchase_order(
            order,
            lines_data=[
                {"line": first, "accepted_quantity": 1, "units": [{"code": "A-1"}]},
                {"line": second, "accepted_quantity": 1, "units": [{"code": "B-1"}]},
            ],
        )

        response = self._post(
            "return-items",
            order,
            {
                "lines": [
                    {"line": first.pk, "quantity": 1, "units": ["A-1"]},
                    {"line": second.pk, "quantity": 1, "units": ["A-1"]},
                ]
            },
        )

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertIn("أكثر من سطر", str(response.data["detail"]))
        self.assertEqual(self._unit("A-1").status, StockUnit.Status.IN_STOCK)

    def test_a_box_of_handsets_names_every_handset_in_it(self):
        product = tracked_product(
            name="هاتف",
            sku="PHONE-BOX",
            mode=Product.TrackingMode.SERIAL,
            unit_price="1500.00",
        )
        variant = product.default_variant
        ProductUnit.objects.create(
            product=product,
            unit=UnitOfMeasure.objects.get(code="box"),
            factor_to_base=Decimal("2"),
        )
        supplier = Supplier.objects.create(name="مورد علب")
        created = self.client.post(
            reverse("purchaseorder-list"),
            {
                "supplier": supplier.pk,
                "lines": [
                    {
                        "variant": variant.pk,
                        "quantity": 2,
                        "unit": "box",
                        "unit_cost": "1800.00",
                    }
                ],
            },
            format="json",
        )
        self.assertEqual(created.status_code, status.HTTP_201_CREATED, created.data)
        order = PurchaseOrder.objects.get(pk=created.data["id"])
        line_id = created.data["lines"][0]["id"]
        self.client.post(reverse("purchaseorder-submit", args=[order.pk]))
        received = self.client.post(
            reverse("purchaseorder-receive", args=[order.pk]),
            {
                "lines": [
                    {
                        "line": line_id,
                        "quantity": 2,
                        "units": [{"code": f"BX-{n}"} for n in range(1, 5)],
                    }
                ]
            },
            format="json",
        )
        self.assertEqual(received.status_code, status.HTTP_200_OK, received.data)

        # One box is two handsets, and both must be named.
        short = self._post(
            "return-items",
            order,
            {"lines": [{"line": line_id, "quantity": 1, "units": ["BX-1"]}]},
        )
        self.assertEqual(short.status_code, status.HTTP_400_BAD_REQUEST)
        response = self._post(
            "return-items",
            order,
            {"lines": [{"line": line_id, "quantity": 1, "units": ["BX-1", "BX-3"]}]},
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK, response.data)
        returned = set(
            StockUnit.objects.filter(status=StockUnit.Status.RETURNED).values_list(
                "code", flat=True
            )
        )
        self.assertEqual(returned, {"BX-1", "BX-3"})
        self.assertEqual(self._on_hand(variant), Decimal("2"))
        assert_tracking_invariants()

    def test_a_serial_and_lot_return_gives_its_lot_back_the_quantity(self):
        variant, order, line = self._phones(
            "SL-1",
            "SL-2",
            mode=Product.TrackingMode.SERIAL_BATCH,
            batches=[{"code": "LOT-H", "expiry_date": date(2028, 1, 31)}],
        )

        response = self._post(
            "return-items",
            order,
            {"lines": [{"line": line.pk, "quantity": 1, "units": ["SL-2"]}]},
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK, response.data)
        self.assertEqual(self._unit("SL-2").status, StockUnit.Status.RETURNED)
        self.assertEqual(self._balances(variant), {"LOT-H": Decimal("1")})
        assert_tracking_invariants()

    def test_an_exchange_returns_the_named_handset_and_holds_the_replacement(self):
        variant, order, line = self._phones("SN-6")

        response = self._post(
            "exchange-items",
            order,
            {"lines": [{"line": line.pk, "quantity": 1, "units": ["SN-6"]}]},
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK, response.data)
        self.assertEqual(self._unit("SN-6").status, StockUnit.Status.RETURNED)
        # Nobody scanned the replacement, so it waits on the
        # missing-identifier list — counted, unsellable, and the supplier's.
        replacement = StockUnit.objects.get(status=StockUnit.Status.IN_STOCK)
        self.assertFalse(replacement.is_identified)
        self.assertEqual(replacement.supplier_id, order.supplier_id)
        self.assertEqual(self._on_hand(variant), Decimal("1"))
        assert_tracking_invariants()

    def test_an_exchange_keeps_the_scanned_replacement(self):
        variant, order, line = self._phones("SN-14", "SN-15")

        response = self._post(
            "exchange-items",
            order,
            {
                "lines": [{"line": line.pk, "quantity": 1, "units": ["SN-14"]}],
                "replacement_lines": [
                    {
                        "variant": variant.pk,
                        "quantity": 1,
                        "unit_cost": "900.00",
                        "units": [{"code": "SN-NEW"}],
                    }
                ],
            },
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK, response.data)
        replacement = self._unit("SN-NEW")
        self.assertTrue(replacement.is_identified)
        self.assertEqual(replacement.status, StockUnit.Status.IN_STOCK)
        self.assertEqual(replacement.supplier_id, order.supplier_id)
        self.assertEqual(self._unit("SN-14").status, StockUnit.Status.RETURNED)
        assert_tracking_invariants()


class LotSupplierReturnTests(_AdjustmentApiTestCase):
    def setUp(self):
        super().setUp()
        product = tracked_product(
            name="مضاد حيوي", sku="MED-RET", mode=Product.TrackingMode.BATCH
        )
        self.variant = product.default_variant
        self.order = receive(
            variant=self.variant,
            quantity=10,
            unit_cost="5.00",
            batches=[
                {"code": "B-LATE", "quantity": 4, "expiry_date": date(2027, 9, 30)},
                {"code": "A-SOON", "quantity": 6, "expiry_date": date(2027, 6, 30)},
            ],
        )
        self.line = self.order.lines.get()

    def test_a_return_draws_the_earliest_expiring_lot_first(self):
        response = self._post(
            "return-items",
            self.order,
            {"lines": [{"line": self.line.pk, "quantity": 3}]},
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK, response.data)
        self.assertEqual(
            self._balances(self.variant),
            {"A-SOON": Decimal("3"), "B-LATE": Decimal("4")},
        )
        assert_tracking_invariants()

    def test_a_return_takes_the_lot_it_names(self):
        late = StockBatch.objects.get(code="B-LATE")

        response = self._post(
            "return-items",
            self.order,
            {"lines": [{"line": self.line.pk, "quantity": 3, "batches": [late.pk]}]},
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK, response.data)
        self.assertEqual(
            self._balances(self.variant),
            {"A-SOON": Decimal("6"), "B-LATE": Decimal("1")},
        )
        assert_tracking_invariants()

    def test_an_exchange_files_the_replacement_under_the_lot_it_names(self):
        response = self._post(
            "exchange-items",
            self.order,
            {
                "lines": [{"line": self.line.pk, "quantity": 2}],
                "replacement_lines": [
                    {
                        "variant": self.variant.pk,
                        "quantity": 2,
                        "unit_cost": "5.00",
                        "batches": [{"code": "C-NEW", "expiry_date": "2028-01-31"}],
                    }
                ],
            },
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK, response.data)
        self.assertEqual(
            self._balances(self.variant),
            {"A-SOON": Decimal("4"), "B-LATE": Decimal("4"), "C-NEW": Decimal("2")},
        )
        self.assertEqual(
            StockBatch.objects.get(code="C-NEW").expiry_date, date(2028, 1, 31)
        )
        assert_tracking_invariants()
