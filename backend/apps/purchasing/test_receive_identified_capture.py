"""The receive endpoint keeps the identifiers the receiver scanned.

Every capture test in ``apps.inventory`` calls ``receive_purchase_order``
directly, so none of them noticed that ``PurchaseReceiptInputSerializer``
validated ``units`` and ``batches`` on each line and then rebuilt the lines it
hands the service without them. Through the API — which is the only way the
receiving dialog reaches the server — a delivery of handsets arrived with no
names at all (or was refused, without capture-later), and a delivery of
medicine landed in one generated lot with no expiry. These go through the
endpoint, which is the path a shop actually uses.
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
from apps.purchasing.models import Supplier


class ReceiveEndpointCaptureTests(TestCase):
    def setUp(self):
        ensure_role_groups()
        self.client = APIClient()
        user = get_user_model().objects.create_user(
            username="receiver", password="pass"
        )
        user.groups.add(Group.objects.get(name=MANAGER_GROUP))
        self.client.force_authenticate(user=user)
        self.supplier = Supplier.objects.create(name="مورد")

    def _submitted_order(self, variant, quantity, unit_cost):
        created = self.client.post(
            reverse("purchaseorder-list"),
            {
                "supplier": self.supplier.pk,
                "lines": [
                    {
                        "variant": variant.pk,
                        "quantity": quantity,
                        "unit_cost": unit_cost,
                    }
                ],
            },
            format="json",
        )
        self.assertEqual(created.status_code, status.HTTP_201_CREATED, created.data)
        order_id = created.data["id"]
        submitted = self.client.post(
            reverse("purchaseorder-submit", args=[order_id]), format="json"
        )
        self.assertEqual(submitted.status_code, status.HTTP_200_OK, submitted.data)
        return order_id, created.data["lines"][0]["id"]

    def test_a_serial_line_keeps_the_scanned_identifiers(self):
        product = tracked_product(
            name="هاتف",
            sku="PHONE-1",
            mode=Product.TrackingMode.SERIAL,
            unit_price="1500.00",
        )
        variant = product.default_variant
        order_id, line_id = self._submitted_order(variant, 2, "900.00")

        response = self.client.post(
            reverse("purchaseorder-receive", args=[order_id]),
            {
                "lines": [
                    {
                        "line": line_id,
                        "quantity": 2,
                        "units": [{"code": "SN-1001"}, {"code": "SN-1002"}],
                    }
                ]
            },
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK, response.data)
        units = StockUnit.objects.filter(variant=variant)
        self.assertEqual(
            sorted(units.values_list("code", flat=True)), ["SN-1001", "SN-1002"]
        )
        self.assertFalse(units.filter(is_identified=False).exists())
        assert_tracking_invariants()

    def test_a_lot_line_keeps_each_lot_and_its_expiry(self):
        product = tracked_product(
            name="مضاد حيوي", sku="MED-1", mode=Product.TrackingMode.BATCH
        )
        variant = product.default_variant
        order_id, line_id = self._submitted_order(variant, 10, "5.00")

        response = self.client.post(
            reverse("purchaseorder-receive", args=[order_id]),
            {
                "lines": [
                    {
                        "line": line_id,
                        "quantity": 10,
                        "batches": [
                            {
                                "code": "A-2026-01",
                                "quantity": 6,
                                "expiry_date": "2027-06-30",
                            },
                            {
                                "code": "B-2026-04",
                                "quantity": 4,
                                "expiry_date": "2027-09-30",
                            },
                        ],
                    }
                ]
            },
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK, response.data)
        lots = dict(
            StockBatch.objects.filter(variant=variant).values_list(
                "code", "expiry_date"
            )
        )
        self.assertEqual(
            lots,
            {"A-2026-01": date(2027, 6, 30), "B-2026-04": date(2027, 9, 30)},
        )
        assert_tracking_invariants()
