"""Landed costs allocated "by retail value" over lines bought in packs.

``ProductVariant.unit_price`` is per BASE unit — per egg, never per tray — and
``PurchaseLine.quantity`` is in the line's purchase unit. The retail-value
weight multiplied the two directly, so a line of 5 cartons of 24 was weighed at
five eggs' retail instead of a hundred and twenty. On an order that mixes packs
with loose pieces the freight then lands almost entirely on the loose lines, and
the cost basis every margin is measured against goes with it.

The allocation is scale-invariant, so an order whose lines are all in the same
unit cannot tell a weight that converts from one that does not. Every test here
mixes units on purpose.

Each expectation is worked out from the payload's own inputs and stated as a
literal; the preview and the saved order are each checked against it, never
against each other — two backend surfaces agreeing proves nothing about either.
"""

from decimal import Decimal

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group
from django.test import TestCase
from django.urls import reverse
from rest_framework import status
from rest_framework.test import APIClient

from apps.catalog.models import ProductUnit, UnitOfMeasure
from apps.catalog.testing import create_product_with_default_variant
from apps.core.roles import MANAGER_GROUP, ensure_role_groups

from .models import PurchaseOrder, Supplier


class LandedCostPackUnitTests(TestCase):
    def setUp(self):
        ensure_role_groups()
        self.client = APIClient()
        user = get_user_model().objects.create_user(
            username="pack-buyer", password="pass"
        )
        user.groups.add(Group.objects.get(name=MANAGER_GROUP))
        self.client.force_authenticate(user=user)
        self.supplier = Supplier.objects.create(name="Pack supplier")

    # -- fixtures ---------------------------------------------------------

    def _variant(self, index, unit_price, *, base_unit="piece"):
        product = create_product_with_default_variant(
            sku=f"PACK-{index}",
            barcode="",
            name=f"Pack product {index}",
            unit_price=unit_price,
        )
        if base_unit != "piece":
            product.unit = base_unit
            product.save(update_fields=["unit"])
        return product.default_variant

    def _add_pack(self, variant, code, factor):
        """A purchase-only pack: bought by the carton, sold by the piece."""
        ProductUnit.objects.create(
            product=variant.product,
            unit=UnitOfMeasure.objects.get(code=code),
            factor_to_base=Decimal(factor),
            price=None,
            is_sellable=False,
            is_purchasable=True,
        )
        return variant

    # -- the two surfaces -------------------------------------------------

    def _preview(self, payload):
        response = self.client.post(
            reverse("purchaseorder-discount-preview"), payload, format="json"
        )
        self.assertEqual(response.status_code, status.HTTP_200_OK, response.data)
        return response.data

    def _save(self, payload):
        response = self.client.post(
            reverse("purchaseorder-list"), payload, format="json"
        )
        self.assertEqual(response.status_code, status.HTTP_201_CREATED, response.data)
        order = PurchaseOrder.objects.get(pk=response.data["id"])
        return list(order.lines.order_by("pk"))

    def assert_both(self, payload, field, expected):
        """``expected`` is one value per line, in payload order."""
        preview_lines = self._preview(payload)["lines"]
        self.assertEqual(
            [line[field] for line in preview_lines], expected, f"preview {field}"
        )
        saved_lines = self._save(payload)
        self.assertEqual(
            [f"{getattr(line, field):.2f}" for line in saved_lines],
            expected,
            f"saved {field}",
        )

    # -- tests ------------------------------------------------------------

    def test_carton_line_is_weighed_by_the_retail_value_of_what_is_inside(self):
        """5 cartons of 24 and 120 loose pieces are the same 120 pieces.

        Both variants retail at 0.50 a piece, so both lines are worth 60.00 at
        retail and 100.00 of freight splits down the middle. Weighing the
        carton line by its five *packs* values it at 2.50 against the loose
        line's 60.00 — 4% of the shipment — and hands it 4.00 of the freight
        while the loose pieces carry 96.00.
        """
        carton_variant = self._add_pack(self._variant(0, Decimal("0.50")), "carton", 24)
        piece_variant = self._variant(1, Decimal("0.50"))
        payload = {
            "supplier": self.supplier.pk,
            "landed_cost_allocation_method": "retail_value",
            "landed_cost_entries": [{"name": "شحن", "amount": "100.00"}],
            "lines": [
                {
                    "variant": carton_variant.pk,
                    "quantity": 5,
                    "unit_cost": "10.00",
                    "unit": "carton",
                },
                {"variant": piece_variant.pk, "quantity": 120, "unit_cost": "0.40"},
            ],
        }
        self.assert_both(payload, "allocated_landed_cost", ["50.00", "50.00"])
        # Per PURCHASE unit, which is what both surfaces publish: 50.00 over 5
        # cartons is 10.00 a carton; 50.00 over 120 pieces is 0.4166… → 0.42.
        self.assert_both(payload, "landed_unit_cost", ["10.00", "0.42"])
        self.assert_both(payload, "effective_unit_cost", ["20.00", "0.82"])

    def test_effective_cost_per_base_unit_stays_under_the_retail_price(self):
        """The figure the sell-at-a-loss guard and every margin actually read.

        A carton costing 10.00 landed at 20.00 is 0.83 a piece against a 0.50
        retail price — dear, but a real number. Under the pack-weighted
        allocation the same carton landed at 14.00, which flatters the pack
        line and overstates the loose line it stole the freight from.
        """
        carton_variant = self._add_pack(self._variant(0, Decimal("0.50")), "carton", 24)
        piece_variant = self._variant(1, Decimal("0.50"))
        payload = {
            "supplier": self.supplier.pk,
            "landed_cost_allocation_method": "retail_value",
            "landed_cost_entries": [{"name": "شحن", "amount": "100.00"}],
            "lines": [
                {
                    "variant": carton_variant.pk,
                    "quantity": 5,
                    "unit_cost": "10.00",
                    "unit": "carton",
                },
                {"variant": piece_variant.pk, "quantity": 120, "unit_cost": "0.40"},
            ],
        }
        carton_line, piece_line = self._save(payload)
        # 20.00 a carton / 24 = 0.8333… → 0.83 a piece.
        self.assertEqual(carton_line.effective_base_unit_cost, Decimal("0.83"))
        self.assertEqual(piece_line.effective_base_unit_cost, Decimal("0.82"))

    def test_fractional_base_unit_bought_in_whole_sacks(self):
        """25kg sacks of a product the shop weighs out.

        3 sacks are 75 kg at 4.00 a kg — 300.00 of retail — against 100 pieces
        at 1.00, which is 100.00. 40.00 of freight splits 300:100, so 30.00 and
        10.00. Weighed by sacks the same line is worth 12.00, and takes 4.29.
        """
        sack_variant = self._add_pack(
            self._variant(0, Decimal("4.00"), base_unit="kg"), "bag", 25
        )
        piece_variant = self._variant(1, Decimal("1.00"))
        payload = {
            "supplier": self.supplier.pk,
            "landed_cost_allocation_method": "retail_value",
            "landed_cost_entries": [{"name": "جمارك", "amount": "40.00"}],
            "lines": [
                {
                    "variant": sack_variant.pk,
                    "quantity": 3,
                    "unit_cost": "60.00",
                    "unit": "bag",
                },
                {"variant": piece_variant.pk, "quantity": 100, "unit_cost": "0.80"},
            ],
        }
        self.assert_both(payload, "allocated_landed_cost", ["30.00", "10.00"])

    def test_an_order_all_in_one_pack_allocates_exactly_as_it_did(self):
        """The guard against 'fixing' the common case into a different answer.

        Every line in cartons of 24 scales every weight by the same 24, and a
        largest-remainder allocation is scale-invariant — so this order must
        split its freight exactly as the equivalent all-pieces order does. 60.00
        over lines worth 2 and 4 cartons goes 20.00 / 40.00 either way.
        """
        first = self._add_pack(self._variant(0, Decimal("1.00")), "carton", 24)
        second = self._add_pack(self._variant(1, Decimal("1.00")), "carton", 24)
        payload = {
            "supplier": self.supplier.pk,
            "landed_cost_allocation_method": "retail_value",
            "landed_cost_entries": [{"name": "شحن", "amount": "60.00"}],
            "lines": [
                {
                    "variant": first.pk,
                    "quantity": 2,
                    "unit_cost": "5.00",
                    "unit": "carton",
                },
                {
                    "variant": second.pk,
                    "quantity": 4,
                    "unit_cost": "5.00",
                    "unit": "carton",
                },
            ],
        }
        self.assert_both(payload, "allocated_landed_cost", ["20.00", "40.00"])

    def test_unpriced_variants_still_fall_back_to_quantity_weights(self):
        """A zero retail value weighs nothing however it is converted.

        Both variants priced 0.00, so retail weights are zero for both and the
        allocation falls back to quantity — which is in PURCHASE units, the
        buyer's own column: 2 cartons against 8 pieces, so 90.00 splits 18.00 /
        72.00. Pinned because the fallback lives one level above the weights
        and a change to the weights must not disturb it.
        """
        carton_variant = self._add_pack(self._variant(0, Decimal("0.00")), "carton", 24)
        piece_variant = self._variant(1, Decimal("0.00"))
        payload = {
            "supplier": self.supplier.pk,
            "landed_cost_allocation_method": "retail_value",
            "landed_cost_entries": [{"name": "شحن", "amount": "90.00"}],
            "lines": [
                {
                    "variant": carton_variant.pk,
                    "quantity": 2,
                    "unit_cost": "1.00",
                    "unit": "carton",
                },
                {"variant": piece_variant.pk, "quantity": 8, "unit_cost": "1.00"},
            ],
        }
        self.assert_both(payload, "allocated_landed_cost", ["18.00", "72.00"])

    def test_quantity_weights_stay_in_the_buyers_own_unit(self):
        """Recorded, not endorsed — see the PR discussion.

        "حسب الكمية" weighs each line by the quantity the buyer typed, which is
        in packs. 2 cartons against 8 pieces therefore splits 90.00 as 18.00 /
        72.00 even though the cartons hold 48 pieces. Unlike retail value —
        which is a *money* figure and cannot mix a per-base price with a pack
        count — this one is a genuine question about what "by quantity" means
        to the person choosing it, and is left as it was. The test exists so
        that whoever changes it does so deliberately.
        """
        carton_variant = self._add_pack(self._variant(0, Decimal("3.00")), "carton", 24)
        piece_variant = self._variant(1, Decimal("3.00"))
        payload = {
            "supplier": self.supplier.pk,
            "landed_cost_allocation_method": "quantity",
            "landed_cost_entries": [{"name": "شحن", "amount": "90.00"}],
            "lines": [
                {
                    "variant": carton_variant.pk,
                    "quantity": 2,
                    "unit_cost": "1.00",
                    "unit": "carton",
                },
                {"variant": piece_variant.pk, "quantity": 8, "unit_cost": "1.00"},
            ],
        }
        self.assert_both(payload, "allocated_landed_cost", ["18.00", "72.00"])


class PreviewReadsThePurchaseUnitTests(TestCase):
    """The preview endpoint used to drop ``unit`` on the floor.

    The PO editor has always sent it — ``PurchaseOrderLineDraft.toJson`` puts it
    on every preview line — but ``PurchaseDiscountPreviewLineSerializer`` did not
    declare the field, so DRF discarded it and the preview could not tell a
    carton from a piece. These tests are about the field being *read*, separately
    from what any one weight does with it.
    """

    def setUp(self):
        ensure_role_groups()
        self.client = APIClient()
        user = get_user_model().objects.create_user(
            username="preview-pack-buyer", password="pass"
        )
        user.groups.add(Group.objects.get(name=MANAGER_GROUP))
        self.client.force_authenticate(user=user)
        self.supplier = Supplier.objects.create(name="Preview pack supplier")
        self.carton_variant = create_product_with_default_variant(
            sku="PREV-PACK-0",
            barcode="",
            name="Preview pack product",
            unit_price=Decimal("0.50"),
        ).default_variant
        ProductUnit.objects.create(
            product=self.carton_variant.product,
            unit=UnitOfMeasure.objects.get(code="carton"),
            factor_to_base=Decimal("24"),
            price=None,
            is_sellable=False,
            is_purchasable=True,
        )
        self.piece_variant = create_product_with_default_variant(
            sku="PREV-PACK-1",
            barcode="",
            name="Preview loose product",
            unit_price=Decimal("0.50"),
        ).default_variant

    def _payload(self, unit):
        line = {
            "variant": self.carton_variant.pk,
            "quantity": 5,
            "unit_cost": "10.00",
        }
        if unit:
            line["unit"] = unit
        return {
            "supplier": self.supplier.pk,
            "landed_cost_allocation_method": "retail_value",
            "landed_cost_entries": [{"name": "شحن", "amount": "100.00"}],
            "lines": [
                line,
                {"variant": self.piece_variant.pk, "quantity": 120, "unit_cost": "0.40"},
            ],
        }

    def _preview(self, payload, expect=status.HTTP_200_OK):
        response = self.client.post(
            reverse("purchaseorder-discount-preview"), payload, format="json"
        )
        self.assertEqual(response.status_code, expect, response.data)
        return response.data

    def test_the_same_line_previews_differently_with_and_without_its_unit(self):
        """Proof the field reaches the arithmetic rather than being accepted
        and ignored — the failure mode a serializer field silently added to a
        payload nobody reads would otherwise have."""
        with_unit = self._preview(self._payload("carton"))["lines"]
        without_unit = self._preview(self._payload(""))["lines"]
        self.assertEqual(
            [line["allocated_landed_cost"] for line in with_unit],
            ["50.00", "50.00"],
        )
        self.assertEqual(
            [line["allocated_landed_cost"] for line in without_unit],
            ["4.00", "96.00"],
        )

    def test_a_unit_the_product_cannot_be_bought_in_is_refused(self):
        """The preview holds the same bar the save does, rather than quietly
        treating an unknown pack as the base unit and quoting costs for it.

        Reported per line and aligned by index, so the editor can put the
        message on the offending row.
        """
        data = self._preview(
            self._payload("dozen"), expect=status.HTTP_400_BAD_REQUEST
        )
        self.assertIn("unit", data["lines"][0])
        self.assertEqual(data["lines"][1], {})
