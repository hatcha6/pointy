"""Lots, expiry dates and serials typed on the purchase order itself.

A buyer entering an order off the supplier's invoice has the dates and numbers
in front of them; these prove the order keeps them, the receipt takes them, and
that a lot number is never demanded — the case of a shop that tracks expiry and
has never been told what a batch number is.
"""

from datetime import date

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group
from django.test import TestCase
from django.urls import reverse
from rest_framework import status
from rest_framework.test import APIClient

from apps.catalog.models import Product
from apps.core.roles import MANAGER_GROUP, ensure_role_groups
from apps.inventory.integrity import assert_tracking_invariants
from apps.inventory.models import StockBatch, StockUnit
from apps.inventory.tracked_testing import tracked_product
from apps.purchasing.models import PurchaseLine, Supplier


class PlannedCaptureTests(TestCase):
    def setUp(self):
        ensure_role_groups()
        self.client = APIClient()
        user = get_user_model().objects.create_user(username="buyer", password="pass")
        user.groups.add(Group.objects.get(name=MANAGER_GROUP))
        self.client.force_authenticate(user=user)
        self.supplier = Supplier.objects.create(name="مورد")

    def _create(self, variant, quantity, **capture):
        response = self.client.post(
            reverse("purchaseorder-list"),
            {
                "supplier": self.supplier.pk,
                "lines": [
                    {
                        "variant": variant.pk,
                        "quantity": quantity,
                        "unit_cost": "5.00",
                        **capture,
                    }
                ],
            },
            format="json",
        )
        return response

    def _submitted(self, variant, quantity, **capture):
        created = self._create(variant, quantity, **capture)
        self.assertEqual(created.status_code, status.HTTP_201_CREATED, created.data)
        order_id = created.data["id"]
        submitted = self.client.post(
            reverse("purchaseorder-submit", args=[order_id]), format="json"
        )
        self.assertEqual(submitted.status_code, status.HTTP_200_OK, submitted.data)
        return order_id, created.data["lines"][0]

    def _receive(self, order_id, lines=None):
        payload = {} if lines is None else {"lines": lines}
        return self.client.post(
            reverse("purchaseorder-receive", args=[order_id]), payload, format="json"
        )

    def _lot_product(self, sku, mode=Product.TrackingMode.BATCH):
        return tracked_product(name="دواء", sku=sku, mode=mode).default_variant

    def test_the_order_keeps_the_lots_typed_on_it(self):
        variant = self._lot_product("MED-PLAN")
        _order_id, line = self._submitted(
            variant,
            10,
            batches=[
                {"code": "A1", "quantity": 6, "expiry_date": "2027-06-30"},
                {"quantity": 4, "expiry_date": "2027-09-30"},
            ],
        )
        self.assertEqual(
            line["planned_batches"],
            [
                {"code": "A1", "quantity": "6", "expiry_date": "2027-06-30"},
                {"quantity": "4", "expiry_date": "2027-09-30"},
            ],
        )
        self.assertEqual(line["planned_units"], [])

    def test_receiving_everything_takes_the_planned_lots(self):
        variant = self._lot_product("MED-RECV")
        order_id, _line = self._submitted(
            variant,
            10,
            batches=[
                {"code": "A1", "quantity": 6, "expiry_date": "2027-06-30"},
                {"quantity": 4, "expiry_date": "2027-09-30"},
            ],
        )

        response = self._receive(order_id)

        self.assertEqual(response.status_code, status.HTTP_200_OK, response.data)
        lots = {
            lot.expiry_date: lot
            for lot in StockBatch.objects.filter(variant=variant)
        }
        self.assertEqual(set(lots), {date(2027, 6, 30), date(2027, 9, 30)})
        self.assertEqual(lots[date(2027, 6, 30)].code, "A1")
        self.assertFalse(lots[date(2027, 6, 30)].code_is_generated)
        # The unnamed lot got a number of our own, honestly marked as ours.
        self.assertTrue(lots[date(2027, 9, 30)].code_is_generated)
        assert_tracking_invariants()

    def test_one_planned_lot_covers_a_short_delivery_and_the_rest(self):
        variant = self._lot_product("MED-SHORT")
        order_id, line = self._submitted(
            variant, 10, batches=[{"expiry_date": "2027-03-31"}]
        )

        first = self._receive(order_id, [{"line": line["id"], "quantity": 4}])
        self.assertEqual(first.status_code, status.HTTP_200_OK, first.data)
        second = self._receive(order_id, [{"line": line["id"], "quantity": 6}])
        self.assertEqual(second.status_code, status.HTTP_200_OK, second.data)

        lots = StockBatch.objects.filter(variant=variant)
        self.assertEqual(lots.count(), 1)
        self.assertEqual(lots.get().expiry_date, date(2027, 3, 31))
        assert_tracking_invariants()

    def test_an_explicit_capture_wins_over_the_plan(self):
        variant = self._lot_product("MED-OVER")
        order_id, line = self._submitted(
            variant, 5, batches=[{"code": "PLANNED", "expiry_date": "2027-01-31"}]
        )

        response = self._receive(
            order_id,
            [
                {
                    "line": line["id"],
                    "quantity": 5,
                    "batches": [
                        {"code": "ON-BOX", "quantity": 5, "expiry_date": "2028-01-31"}
                    ],
                }
            ],
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK, response.data)
        self.assertEqual(
            list(StockBatch.objects.filter(variant=variant).values_list("code", flat=True)),
            ["ON-BOX"],
        )

    def test_a_split_plan_is_not_guessed_on_a_partial_delivery(self):
        variant = self._lot_product("MED-SPLIT")
        order_id, line = self._submitted(
            variant,
            10,
            batches=[
                {"code": "A", "quantity": 5, "expiry_date": "2027-06-30"},
                {"code": "B", "quantity": 5, "expiry_date": "2027-09-30"},
            ],
        )

        response = self._receive(order_id, [{"line": line["id"], "quantity": 3}])

        self.assertEqual(response.status_code, status.HTTP_200_OK, response.data)
        lot = StockBatch.objects.get(variant=variant)
        self.assertTrue(lot.code_is_generated)

    def test_planned_serials_are_received_and_not_twice(self):
        variant = tracked_product(
            name="هاتف", sku="PHONE-PLAN", mode=Product.TrackingMode.SERIAL
        ).default_variant
        order_id, line = self._submitted(
            variant,
            3,
            units=[{"code": "IMEI-1"}, {"code": "IMEI-2"}, {"code": "IMEI-3"}],
        )

        first = self._receive(
            order_id,
            [
                {
                    "line": line["id"],
                    "quantity": 1,
                    "units": [{"code": "IMEI-2"}],
                }
            ],
        )
        self.assertEqual(first.status_code, status.HTTP_200_OK, first.data)
        rest = self._receive(order_id, [{"line": line["id"], "quantity": 2}])
        self.assertEqual(rest.status_code, status.HTTP_200_OK, rest.data)

        self.assertEqual(
            sorted(StockUnit.objects.filter(variant=variant).values_list("code", flat=True)),
            ["IMEI-1", "IMEI-2", "IMEI-3"],
        )
        assert_tracking_invariants()

    def test_a_serial_batch_line_needs_no_lot_number(self):
        variant = self._lot_product("PEN-1", mode=Product.TrackingMode.SERIAL_BATCH)
        order_id, line = self._submitted(variant, 2)

        response = self._receive(
            order_id,
            [
                {
                    "line": line["id"],
                    "quantity": 2,
                    "units": [{"code": "P-1"}, {"code": "P-2"}],
                    "batches": [{"expiry_date": "2027-12-31"}],
                }
            ],
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK, response.data)
        lot = StockBatch.objects.get(variant=variant)
        self.assertTrue(lot.code_is_generated)
        self.assertEqual(lot.expiry_date, date(2027, 12, 31))
        self.assertEqual(
            StockUnit.objects.filter(variant=variant, batch=lot).count(), 2
        )
        assert_tracking_invariants()

    def test_two_unnamed_deliveries_with_different_dates_are_two_lots(self):
        variant = self._lot_product("MILK-1")
        order_id, line = self._submitted(variant, 10)

        for quantity, expiry in ((4, "2026-12-01"), (6, "2026-12-09")):
            response = self._receive(
                order_id,
                [
                    {
                        "line": line["id"],
                        "quantity": quantity,
                        "batches": [{"quantity": quantity, "expiry_date": expiry}],
                    }
                ],
            )
            self.assertEqual(response.status_code, status.HTTP_200_OK, response.data)

        self.assertEqual(
            sorted(
                StockBatch.objects.filter(variant=variant).values_list(
                    "expiry_date", flat=True
                )
            ),
            [date(2026, 12, 1), date(2026, 12, 9)],
        )
        assert_tracking_invariants()

    def test_impossible_plans_are_refused_while_typing_the_order(self):
        lots = self._lot_product("MED-BAD")
        too_much = self._create(lots, 2, batches=[{"quantity": 3}])
        self.assertEqual(too_much.status_code, status.HTTP_400_BAD_REQUEST)

        phone = tracked_product(
            name="هاتف", sku="PHONE-BAD", mode=Product.TrackingMode.SERIAL
        ).default_variant
        twice = self._create(phone, 2, units=[{"code": "X1"}, {"code": "x1"}])
        self.assertEqual(twice.status_code, status.HTTP_400_BAD_REQUEST)
        extra = self._create(phone, 1, units=[{"code": "X1"}, {"code": "X2"}])
        self.assertEqual(extra.status_code, status.HTTP_400_BAD_REQUEST)

        counted = tracked_product(
            name="ورق", sku="PAPER", mode=Product.TrackingMode.QUANTITY
        ).default_variant
        refused = self._create(counted, 1, batches=[{"expiry_date": "2027-01-01"}])
        self.assertEqual(refused.status_code, status.HTTP_400_BAD_REQUEST)

    def test_editing_a_draft_replaces_the_plan(self):
        variant = self._lot_product("MED-EDIT")
        created = self._create(variant, 4, batches=[{"expiry_date": "2027-01-31"}])
        self.assertEqual(created.status_code, status.HTTP_201_CREATED, created.data)
        order_id = created.data["id"]

        updated = self.client.patch(
            reverse("purchaseorder-detail", args=[order_id]),
            {
                "lines": [
                    {
                        "variant": variant.pk,
                        "quantity": 4,
                        "unit_cost": "5.00",
                        "batches": [{"code": "Z9", "expiry_date": "2027-05-31"}],
                    }
                ]
            },
            format="json",
        )

        self.assertEqual(updated.status_code, status.HTTP_200_OK, updated.data)
        line = PurchaseLine.objects.get(purchase_order_id=order_id)
        self.assertEqual(
            line.planned_batches, [{"code": "Z9", "expiry_date": "2027-05-31"}]
        )

    def test_a_required_expiry_typed_on_the_order_satisfies_the_receipt(self):
        variant = self._lot_product("MED-REQ")
        Product.objects.filter(pk=variant.product_id).update(expiry_required=True)
        order_id, _line = self._submitted(
            variant, 3, batches=[{"expiry_date": "2027-04-30"}]
        )

        response = self._receive(order_id)

        self.assertEqual(response.status_code, status.HTTP_200_OK, response.data)
        receipt_line = PurchaseLine.objects.get(
            purchase_order_id=order_id
        ).receipt_lines.get()
        self.assertEqual(receipt_line.expiry_date, date(2027, 4, 30))

    def test_a_required_expiry_still_missing_is_refused(self):
        variant = self._lot_product("MED-REQ2")
        Product.objects.filter(pk=variant.product_id).update(expiry_required=True)
        order_id, _line = self._submitted(variant, 3, batches=[{"code": "L-9"}])

        response = self._receive(order_id)

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertIn("تاريخ الصلاحية مطلوب", str(response.data))
