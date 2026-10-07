"""What a receipt of identified stock may and may not say, through the API.

Three rules, each one a hole a real delivery walked through:

* **Dates belong to lots.** An order line is no longer asked for an expiry
  date — a delivery of two lots has two — and receiving asks every lot for one
  only where the product's ``expiry_required`` says so. A paint batch is
  lot-tracked for provenance and never expires; it used to be refused an order
  until somebody typed a date it does not have.
* **A price or a warranty date set while scanning answers to the permission
  the unit's own page asks for it.** Receiving is a clerk's job; repricing a
  handset and promising a customer a longer cover are not.
* **Per-article costs must add up whenever any is given.** The guard used to
  stand aside unless every row named a cost, so one row could carry any sum.
"""

from datetime import date
from decimal import Decimal

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group
from django.test import TestCase
from django.urls import reverse
from rest_framework import status
from rest_framework.test import APIClient

from apps.catalog.models import Product
from apps.core.roles import INVENTORY_CLERK_GROUP, MANAGER_GROUP, ensure_role_groups
from apps.customers.models import AssetType
from apps.inventory.integrity import assert_tracking_invariants
from apps.inventory.models import StockBatch, StockUnit
from apps.inventory.tracked_testing import tracked_product
from apps.purchasing.models import PurchaseReceiptLine, Supplier


class _ReceiptApiCase(TestCase):
    def setUp(self):
        ensure_role_groups()
        self.manager = self._client_for("owner", MANAGER_GROUP)
        self.supplier = Supplier.objects.create(name="مورد")

    def _client_for(self, username, group):
        user = get_user_model().objects.create_user(username=username, password="x")
        user.groups.add(Group.objects.get(name=group))
        client = APIClient()
        client.force_authenticate(user=user)
        return client

    def _submitted_order(self, variant, quantity, unit_cost, **line):
        created = self.manager.post(
            reverse("purchaseorder-list"),
            {
                "supplier": self.supplier.pk,
                "lines": [
                    {
                        "variant": variant.pk,
                        "quantity": quantity,
                        "unit_cost": unit_cost,
                        **line,
                    }
                ],
            },
            format="json",
        )
        self.assertEqual(created.status_code, status.HTTP_201_CREATED, created.data)
        order_id = created.data["id"]
        submitted = self.manager.post(
            reverse("purchaseorder-submit", args=[order_id]), format="json"
        )
        self.assertEqual(submitted.status_code, status.HTTP_200_OK, submitted.data)
        return order_id, created.data["lines"][0]["id"]

    def _receive(self, order_id, line, client=None):
        return (client or self.manager).post(
            reverse("purchaseorder-receive", args=[order_id]),
            {"lines": [line]},
            format="json",
        )


class LotsOwnTheirExpiryTests(_ReceiptApiCase):
    def _formula(self):
        product = tracked_product(
            name="حليب أطفال", sku="NAN-1", mode=Product.TrackingMode.BATCH
        )
        Product.objects.filter(pk=product.pk).update(expiry_required=True)
        return product.default_variant

    def test_an_order_for_expiring_goods_needs_no_date_until_they_arrive(self):
        variant = self._formula()
        # Created and submitted with no expiry anywhere on the line.
        self._submitted_order(variant, 10, "30.00")

    def test_each_lot_must_carry_a_date_when_the_product_expires(self):
        variant = self._formula()
        order_id, line_id = self._submitted_order(variant, 10, "30.00")

        response = self._receive(
            order_id,
            {
                "line": line_id,
                "quantity": 10,
                "batches": [
                    {"code": "L-A", "quantity": 6, "expiry_date": "2027-04-30"},
                    {"code": "L-B", "quantity": 4},
                ],
            },
        )

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertIn("batches", response.data)
        self.assertFalse(StockBatch.objects.filter(variant=variant).exists())

    def test_the_line_records_the_first_lot_to_expire(self):
        variant = self._formula()
        order_id, line_id = self._submitted_order(variant, 10, "30.00")

        response = self._receive(
            order_id,
            {
                "line": line_id,
                "quantity": 10,
                "batches": [
                    {"code": "L-A", "quantity": 6, "expiry_date": "2027-10-31"},
                    {"code": "L-B", "quantity": 4, "expiry_date": "2027-04-30"},
                ],
            },
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK, response.data)
        receipt_line = PurchaseReceiptLine.objects.get(purchase_line_id=line_id)
        self.assertEqual(receipt_line.expiry_date, date(2027, 4, 30))
        assert_tracking_invariants()

    def test_a_receipt_with_no_lots_still_needs_a_date_for_expiring_goods(self):
        variant = self._formula()
        order_id, line_id = self._submitted_order(variant, 10, "30.00")

        refused = self._receive(order_id, {"line": line_id, "quantity": 10})
        self.assertEqual(refused.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertIn("expiry_date", refused.data)

        accepted = self._receive(
            order_id, {"line": line_id, "quantity": 10, "expiry_date": "2027-01-31"}
        )
        self.assertEqual(accepted.status_code, status.HTTP_200_OK, accepted.data)
        self.assertEqual(
            StockBatch.objects.get(variant=variant).expiry_date, date(2027, 1, 31)
        )

    def test_lots_of_goods_that_never_expire_need_no_date(self):
        paint = tracked_product(
            name="دهان", sku="PAINT-1", mode=Product.TrackingMode.BATCH
        ).default_variant
        order_id, line_id = self._submitted_order(paint, 10, "70.00")

        response = self._receive(
            order_id,
            {
                "line": line_id,
                "quantity": 10,
                "batches": [{"code": "BATCH-07", "quantity": 10}],
            },
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK, response.data)
        self.assertIsNone(StockBatch.objects.get(code="BATCH-07").expiry_date)

    def test_a_serialised_pack_needs_a_date_on_its_lot_header(self):
        product = tracked_product(
            name="قلم إنسولين", sku="PEN-1", mode=Product.TrackingMode.SERIAL_BATCH
        )
        Product.objects.filter(pk=product.pk).update(expiry_required=True)
        variant = product.default_variant
        order_id, line_id = self._submitted_order(variant, 2, "45.00")
        line = {
            "line": line_id,
            "quantity": 2,
            "units": [{"code": "PEN-0001"}, {"code": "PEN-0002"}],
            "batches": [{"code": "NV-1"}],
        }

        refused = self._receive(order_id, line)
        self.assertEqual(refused.status_code, status.HTTP_400_BAD_REQUEST)

        line["batches"] = [{"code": "NV-1", "expiry_date": "2027-09-30"}]
        accepted = self._receive(order_id, line)
        self.assertEqual(accepted.status_code, status.HTTP_200_OK, accepted.data)
        self.assertEqual(
            set(StockUnit.objects.values_list("batch__expiry_date", flat=True)),
            {date(2027, 9, 30)},
        )


class ScanningAnswersToTheUnitPagesPermissionsTests(_ReceiptApiCase):
    def setUp(self):
        super().setUp()
        self.clerk = self._client_for("clerk", INVENTORY_CLERK_GROUP)
        self.variant = tracked_product(
            name="آيفون مستعمل", sku="U-IP13", mode=Product.TrackingMode.SERIAL,
            unit_price="2600.00",
        ).default_variant
        self.order_id, self.line_id = self._submitted_order(
            self.variant, 1, "1950.00"
        )

    def _line(self, **unit):
        return {
            "line": self.line_id,
            "quantity": 1,
            "units": [{"code": "353012118845120", **unit}],
        }

    def test_a_clerk_may_not_price_a_handset_while_scanning_it(self):
        response = self._receive(
            self.order_id, self._line(list_price="2600.00"), client=self.clerk
        )
        self.assertEqual(response.status_code, status.HTTP_403_FORBIDDEN)
        self.assertFalse(StockUnit.objects.exists())

    def test_a_clerk_may_not_give_a_handset_its_own_warranty(self):
        response = self._receive(
            self.order_id,
            self._line(warranty_override_expires_on="2027-10-06"),
            client=self.clerk,
        )
        self.assertEqual(response.status_code, status.HTTP_403_FORBIDDEN)

    def test_a_clerk_may_scan_and_describe_without_either(self):
        response = self._receive(
            self.order_id,
            self._line(list_price=None, attributes={"note": "x"}),
            client=self.clerk,
        )
        self.assertEqual(response.status_code, status.HTTP_200_OK, response.data)

    def test_someone_who_may_reprice_sets_the_handsets_own_price(self):
        response = self._receive(self.order_id, self._line(list_price="2600.00"))
        self.assertEqual(response.status_code, status.HTTP_200_OK, response.data)
        self.assertEqual(StockUnit.objects.get().list_price, Decimal("2600.00"))

    def test_a_negative_price_is_refused(self):
        response = self._receive(self.order_id, self._line(list_price="-1"))
        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)


class PerArticleCostsAddUpTests(_ReceiptApiCase):
    def setUp(self):
        super().setUp()
        self.variant = tracked_product(
            name="آيفون مستعمل", sku="U-IP13", mode=Product.TrackingMode.SERIAL,
            unit_price="2600.00",
        ).default_variant
        # Three handsets at 1950.00: the line is 5850.00.
        self.order_id, self.line_id = self._submitted_order(
            self.variant, 3, "1950.00"
        )

    def _receive_costs(self, *costs):
        units = [
            {"code": f"35301211884{index:04d}", **({"unit_cost": c} if c else {})}
            for index, c in enumerate(costs)
        ]
        return self._receive(
            self.order_id, {"line": self.line_id, "quantity": 3, "units": units}
        )

    def test_one_inflated_handset_beside_two_blank_ones_is_refused(self):
        response = self._receive_costs("9000.00", None, None)
        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertFalse(StockUnit.objects.exists())

    def test_a_negative_cost_cannot_pay_for_an_inflated_one(self):
        response = self._receive_costs("4000.00", "-100.00", "1950.00")
        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)

    def test_a_split_that_adds_up_is_booked_handset_by_handset(self):
        response = self._receive_costs("2150.00", "1950.00", "1750.00")
        self.assertEqual(response.status_code, status.HTTP_200_OK, response.data)
        self.assertEqual(
            sorted(StockUnit.objects.values_list("incoming_rate", flat=True)),
            [Decimal("1750"), Decimal("1950"), Decimal("2150")],
        )
        assert_tracking_invariants()

    def test_a_partial_split_that_still_adds_up_is_accepted(self):
        # The blank one is booked at the line's 1950.00, so these balance.
        response = self._receive_costs("2150.00", None, "1750.00")
        self.assertEqual(response.status_code, status.HTTP_200_OK, response.data)


class LotCostsAddUpTests(_ReceiptApiCase):
    def test_one_costed_lot_beside_a_blank_one_must_still_add_up(self):
        variant = tracked_product(
            name="دهان", sku="PAINT-2", mode=Product.TrackingMode.BATCH
        ).default_variant
        order_id, line_id = self._submitted_order(variant, 10, "70.00")

        response = self._receive(
            order_id,
            {
                "line": line_id,
                "quantity": 10,
                "batches": [
                    {"code": "B-1", "quantity": 5, "unit_cost": "500.00"},
                    {"code": "B-2", "quantity": 5},
                ],
            },
        )

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)


class LineTellsTheScanLoopWhatItReadsTests(_ReceiptApiCase):
    def test_a_phone_line_reads_imei_and_a_counted_line_reads_nothing(self):
        phone_type, _ = AssetType.objects.get_or_create(
            slug="test-phone", defaults={"name": "هاتف", "tracks_imei": True}
        )
        phone = tracked_product(
            name="آيفون",
            sku="IP-16",
            mode=Product.TrackingMode.SERIAL,
            unit_price="4800.00",
        )
        Product.objects.filter(pk=phone.pk).update(asset_type=phone_type)
        counted = tracked_product(
            name="شاحن", sku="CHG-1", mode=Product.TrackingMode.QUANTITY
        )
        created = self.manager.post(
            reverse("purchaseorder-list"),
            {
                "supplier": self.supplier.pk,
                "lines": [
                    {
                        "variant": phone.default_variant.pk,
                        "quantity": 1,
                        "unit_cost": "4000.00",
                    },
                    {
                        "variant": counted.default_variant.pk,
                        "quantity": 1,
                        "unit_cost": "50.00",
                    },
                ],
            },
            format="json",
        )
        self.assertEqual(created.status_code, status.HTTP_201_CREATED, created.data)

        detail = self.manager.get(
            reverse("purchaseorder-detail", args=[created.data["id"]])
        )

        kinds = {
            line["variant_sku"]: line["identifier_kind"]
            for line in detail.data["lines"]
        }
        self.assertEqual(kinds, {"IP-16": "imei", "CHG-1": ""})

    def test_the_catalog_variant_says_whether_its_lots_must_be_dated(self):
        product = tracked_product(
            name="حليب", sku="MILK-1", mode=Product.TrackingMode.BATCH
        )
        Product.objects.filter(pk=product.pk).update(expiry_required=True)

        response = self.manager.get(
            reverse("product-variant-detail", args=[product.default_variant.pk])
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK, response.data)
        self.assertTrue(response.data["tracks_expiry"])
        self.assertTrue(response.data["expiry_required"])

class StickersHaveWhatTheyPrintTests(_ReceiptApiCase):
    """A sticker printed on receipt, or for a lot, needs the product's own
    barcode and selling price — and a lot sticker needs its own date."""

    def test_an_order_line_carries_the_barcode_and_the_selling_price(self):
        product = tracked_product(
            name="حليب", sku="MILK-9", mode=Product.TrackingMode.BATCH,
            unit_price="48.00",
        )
        variant = product.default_variant
        variant.barcode = "6221000000017"
        variant.save(update_fields=["barcode"])
        order_id, _ = self._submitted_order(variant, 2, "36.00")

        line = self.manager.get(
            reverse("purchaseorder-detail", args=[order_id])
        ).data["lines"][0]

        self.assertEqual(line["variant_barcode"], "6221000000017")
        self.assertEqual(line["selling_price"], "48.00")

    def test_a_lot_carries_its_products_barcode_price_and_mode(self):
        product = tracked_product(
            name="قلم إنسولين",
            sku="PEN-9",
            mode=Product.TrackingMode.SERIAL_BATCH,
            unit_price="62.00",
        )
        Product.objects.filter(pk=product.pk).update(expiry_required=True)
        variant = product.default_variant
        variant.barcode = "6221000000024"
        variant.save(update_fields=["barcode"])
        order_id, line_id = self._submitted_order(variant, 1, "45.00")
        received = self._receive(
            order_id,
            {
                "line": line_id,
                "quantity": 1,
                "units": [{"code": "PEN-9-0001"}],
                "batches": [{"code": "NV-9", "expiry_date": "2027-09-30"}],
            },
        )
        self.assertEqual(received.status_code, status.HTTP_200_OK, received.data)

        lots = self.manager.get(
            reverse("stock-batch-list"), {"variant": variant.pk}
        ).data
        lot = (lots["results"] if isinstance(lots, dict) else lots)[0]

        self.assertEqual(lot["variant_barcode"], "6221000000024")
        self.assertEqual(lot["variant_sku"], "PEN-9")
        self.assertEqual(lot["variant_price"], "62.00")
        self.assertEqual(lot["tracking_mode"], "serial_batch")
        self.assertEqual(lot["expiry_date"], "2027-09-30")
