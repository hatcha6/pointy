"""Turning tracking on for a product that already has stock on the shelf.

A phone shop with thirty handsets on the shelf could never start tracking them:
the guard refused any mode change while stock was on hand, and opening
identification only listed products that were already tracked. §4.2 and §6.10
always meant the switch to be allowed *through* an opening-identification run,
and this is that run reached from the product form — asked as a question the
first time, answered with ``tracking_mode_identify_later`` the second.

Every test goes through the product endpoint, because the bug class in this
area is "built but never reachable": a service-level test would have passed
while no shop could get there.
"""

from decimal import Decimal

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group, Permission
from django.test import TestCase
from django.urls import reverse
from rest_framework import status
from rest_framework.test import APIClient

from apps.core.roles import MANAGER_GROUP, ensure_role_groups
from apps.inventory import tracking
from apps.inventory.integrity import assert_tracking_invariants, units_missing_lots
from apps.inventory.models import (
    StockBatch,
    StockBatchBalance,
    StockItem,
    StockUnit,
    StockValuationBin,
    Warehouse,
    forget_default_warehouse,
)
from apps.inventory.tracked_testing import receive, tracked_product
from apps.purchasing.models import PurchaseOrder, Supplier
from apps.purchasing.services import receive_purchase_order, submit_purchase_order

from .models import Product, ProductVariant
from .tracking_modes import IDENTIFY_LATER_CODE

SERIAL = Product.TrackingMode.SERIAL
BATCH = Product.TrackingMode.BATCH
SERIAL_BATCH = Product.TrackingMode.SERIAL_BATCH
QUANTITY = Product.TrackingMode.QUANTITY


def _stocked(*, sku, quantity, cost="500.00", mode=QUANTITY):
    """A product with ``quantity`` on the shelf, bought through a real receipt."""
    product = tracked_product(name="هاتف", sku=sku, mode=mode, unit_price="900.00")
    if quantity:
        receive(variant=product.default_variant, quantity=quantity, unit_cost=cost)
    return product


def _receive_at(variant, warehouse, quantity, cost):
    """``receive`` into a named place — the fixture only knows the default."""
    order = PurchaseOrder.objects.create(
        supplier=Supplier.objects.create(name="مورد"), warehouse=warehouse
    )
    line = order.lines.create(
        variant=variant, quantity=Decimal(quantity), unit_cost=Decimal(cost)
    )
    order.recalculate()
    order.save(update_fields=["subtotal", "total", "updated_at"])
    submit_purchase_order(order)
    receive_purchase_order(
        order,
        lines_data=[{"line": line, "accepted_quantity": Decimal(quantity)}],
    )


class _SwitchTestCase(TestCase):
    def setUp(self):
        # A cached default-warehouse id can name a row a previous test rolled
        # back; ``tracked_product`` clears it, but not every test here uses it.
        forget_default_warehouse()
        ensure_role_groups()
        self.user = get_user_model().objects.create_user(
            username="tracking-switch", password="pass"
        )
        self.user.groups.add(Group.objects.get(name=MANAGER_GROUP))
        self.client = APIClient()
        self.client.force_authenticate(self.user)

    def _switch(self, product, mode, *, identify_later=False, **extra):
        payload = {"tracking_mode": mode, **extra}
        if identify_later:
            payload["tracking_mode_identify_later"] = True
        return self.client.patch(
            reverse("product-detail", args=[product.pk]), payload, format="json"
        )

    def assertRefusedWithoutCode(self, response, product, mode):
        """Refused on the field, with nothing a confirmation could answer."""
        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertIn("tracking_mode", response.data)
        self.assertNotIn("code", response.data)
        product.refresh_from_db()
        self.assertEqual(product.tracking_mode, mode)


class AskingFirstTests(_SwitchTestCase):
    """Without the flag the switch is a question, never a silent write."""

    def test_turning_serials_on_over_stock_asks_with_a_code(self):
        product = _stocked(sku="ASK-1", quantity=3)

        response = self._switch(product, SERIAL)

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        # DRF list-wraps every leaf of a ``validate()`` error, the code included.
        self.assertEqual(response.data["code"], [IDENTIFY_LATER_CODE])
        self.assertEqual(response.data["on_hand"], ["3"])
        self.assertEqual(response.data["requested_mode"], [SERIAL])
        self.assertIn("بانتظار المعرّف", str(response.data["tracking_mode"][0]))
        product.refresh_from_db()
        self.assertEqual(product.tracking_mode, QUANTITY)
        self.assertFalse(StockUnit.objects.exists())

    def test_turning_lots_on_over_stock_asks_with_a_code(self):
        product = _stocked(sku="ASK-2", quantity=12)

        response = self._switch(product, BATCH)

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertEqual(response.data["code"], [IDENTIFY_LATER_CODE])
        self.assertFalse(StockBatch.objects.exists())

    def test_an_unrelated_edit_that_resends_the_same_mode_is_not_asked(self):
        """The form sends the mode with every save; a rename must not trip it."""
        product = _stocked(sku="ASK-3", quantity=3)

        response = self._switch(product, QUANTITY, name="هاتف مستعمل")

        self.assertEqual(response.status_code, status.HTTP_200_OK, response.data)
        product.refresh_from_db()
        self.assertEqual(product.name, "هاتف مستعمل")


class IdentifyLaterTests(_SwitchTestCase):
    """With the flag the shelf is identified as owed, in the same transaction."""

    def test_serial_stock_becomes_placeholders_and_the_bin_does_not_move(self):
        product = _stocked(sku="LATER-1", quantity=3, cost="500.00")
        variant = product.default_variant
        before = StockValuationBin.objects.get(variant=variant)

        response = self._switch(product, SERIAL, identify_later=True)

        self.assertEqual(response.status_code, status.HTTP_200_OK, response.data)
        self.assertNotIn("tracking_mode_identify_later", response.data)
        product.refresh_from_db()
        self.assertEqual(product.tracking_mode, SERIAL)
        units = StockUnit.objects.filter(variant=variant)
        self.assertEqual(units.count(), 3)
        self.assertFalse(units.filter(is_identified=True).exists())
        self.assertEqual(
            set(units.values_list("status", flat=True)), {StockUnit.Status.IN_STOCK}
        )
        self.assertEqual(
            set(units.values_list("incoming_rate", flat=True)),
            {Decimal("500.000000")},
        )
        after = StockValuationBin.objects.get(variant=variant)
        self.assertEqual(after.quantity, before.quantity)
        self.assertEqual(after.stock_value, before.stock_value)
        self.assertEqual(
            StockItem.objects.get(variant=variant).quantity_on_hand, Decimal("3")
        )
        assert_tracking_invariants()

    def test_placeholders_are_on_the_worklist_and_unsellable_until_named(self):
        product = _stocked(sku="LATER-2", quantity=2)
        variant = product.default_variant

        self._switch(product, SERIAL, identify_later=True)

        summary = self.client.get(
            "/api/stock-units/summary/", {"product": product.pk}
        ).data
        self.assertEqual(summary["missing_identifiers"], 2)
        warehouse = StockItem.objects.get(variant=variant).warehouse_id
        self.assertFalse(
            tracking.available_units(variant=variant, warehouse=warehouse).exists()
        )

        placeholder = StockUnit.objects.filter(variant=variant).first()
        named = self.client.post(
            f"/api/stock-units/{placeholder.pk}/identify/",
            {"code": "SN-LATER-0001"},
            format="json",
        )

        self.assertEqual(named.status_code, status.HTTP_200_OK, named.data)
        self.assertEqual(
            list(
                tracking.available_units(
                    variant=variant, warehouse=warehouse
                ).values_list("code", flat=True)
            ),
            ["SN-LATER-0001"],
        )
        assert_tracking_invariants()

    def test_lot_stock_lands_in_one_generated_lot_at_the_shelf_rate(self):
        product = _stocked(sku="LATER-3", quantity=12, cost="7.50")
        variant = product.default_variant
        before = StockValuationBin.objects.get(variant=variant)

        response = self._switch(product, BATCH, identify_later=True)

        self.assertEqual(response.status_code, status.HTTP_200_OK, response.data)
        lot = StockBatch.objects.get(variant=variant)
        self.assertTrue(lot.code_is_generated)
        self.assertIsNone(lot.expiry_date)
        balance = StockBatchBalance.objects.get(batch=lot)
        self.assertEqual(balance.remaining_quantity, Decimal("12.000"))
        self.assertEqual(balance.incoming_rate, Decimal("7.500000"))
        after = StockValuationBin.objects.get(variant=variant)
        self.assertEqual(after.stock_value, before.stock_value)
        assert_tracking_invariants()

    def test_lots_take_a_fractional_shelf(self):
        """Lots are measured, not counted — the unit-mode refusal is not theirs."""
        product = _stocked(sku="LATER-4", quantity="2.5", cost="4.00")

        response = self._switch(product, BATCH, identify_later=True)

        self.assertEqual(response.status_code, status.HTTP_200_OK, response.data)
        self.assertEqual(
            StockBatchBalance.objects.get(
                variant=product.default_variant
            ).remaining_quantity,
            Decimal("2.500"),
        )
        assert_tracking_invariants()

    def test_every_place_holding_stock_is_identified_where_it_stands(self):
        product = _stocked(sku="LATER-5", quantity=3, cost="500.00")
        variant = product.default_variant
        store = Warehouse.objects.create(
            name="المخزن", code="store-room", kind=Warehouse.Kind.STORE_ROOM
        )
        _receive_at(variant, store, 2, "500.00")

        response = self._switch(product, SERIAL, identify_later=True)

        self.assertEqual(response.status_code, status.HTTP_200_OK, response.data)
        by_place = {
            item.warehouse_id: StockUnit.objects.filter(
                variant=variant, warehouse_id=item.warehouse_id
            ).count()
            for item in StockItem.objects.filter(variant=variant)
        }
        self.assertEqual(by_place[store.pk], 2)
        self.assertEqual(sum(by_place.values()), 5)
        assert_tracking_invariants()

    def test_two_products_switched_on_never_share_a_placeholder_code(self):
        """Normalisation strips dashes, so ``#-OPEN-7001-11`` and
        ``#-OPEN-70011-1`` used to be one identifier to the live unique index,
        and the second product switched on failed with an IntegrityError."""
        first = Product.objects.create(name="هاتف أ")
        ProductVariant.objects.create(
            pk=7001, product=first, sku="COLL-1", unit_price=Decimal("900"),
            is_default=True,
        )
        second = Product.objects.create(name="هاتف ب")
        ProductVariant.objects.create(
            pk=70011, product=second, sku="COLL-2", unit_price=Decimal("900"),
            is_default=True,
        )
        receive(variant=ProductVariant.objects.get(pk=7001), quantity=11)
        receive(variant=ProductVariant.objects.get(pk=70011), quantity=1)

        self.assertEqual(
            self._switch(first, SERIAL, identify_later=True).status_code,
            status.HTTP_200_OK,
        )
        response = self._switch(second, SERIAL, identify_later=True)

        self.assertEqual(response.status_code, status.HTTP_200_OK, response.data)
        self.assertEqual(StockUnit.objects.filter(is_identified=False).count(), 12)
        assert_tracking_invariants()

    def test_serial_first_then_lots_is_the_road_to_serial_batch(self):
        """The refusal of ``quantity → serial_batch`` names this road, so it
        has to exist: serial with the shelf owed, then lots grandfathered."""
        product = _stocked(sku="LATER-6", quantity=2)

        self.assertEqual(
            self._switch(product, SERIAL, identify_later=True).status_code,
            status.HTTP_200_OK,
        )
        response = self._switch(product, SERIAL_BATCH)

        self.assertEqual(response.status_code, status.HTTP_200_OK, response.data)
        self.assertEqual(units_missing_lots().count(), 2)

    def test_the_flag_over_an_empty_shelf_just_switches(self):
        product = _stocked(sku="LATER-7", quantity=0)

        response = self._switch(product, SERIAL, identify_later=True)

        self.assertEqual(response.status_code, status.HTTP_200_OK, response.data)
        self.assertFalse(StockUnit.objects.exists())


class StillRefusedTests(_SwitchTestCase):
    """What a confirmation cannot fix is refused with no code to answer."""

    def test_negative_stock(self):
        product = _stocked(sku="NO-1", quantity=0)
        StockItem.objects.filter(variant=product.default_variant).update(
            quantity_on_hand=Decimal("-2")
        )

        response = self._switch(product, SERIAL, identify_later=True)

        self.assertRefusedWithoutCode(response, product, QUANTITY)
        self.assertIn("بالسالب", str(response.data["tracking_mode"][0]))

    def test_a_fractional_shelf_for_serials(self):
        product = _stocked(sku="NO-2", quantity="2.5")

        response = self._switch(product, SERIAL, identify_later=True)

        self.assertRefusedWithoutCode(response, product, QUANTITY)
        self.assertFalse(StockUnit.objects.exists())

    def test_stock_held_for_quotations_for_serials(self):
        """Invariant 2: a hold on anonymous stock names no unit to reserve."""
        product = _stocked(sku="NO-3", quantity=3)
        StockItem.objects.filter(variant=product.default_variant).update(
            quantity_committed=Decimal("1")
        )

        response = self._switch(product, SERIAL, identify_later=True)

        self.assertRefusedWithoutCode(response, product, QUANTITY)
        self.assertIn("عروض أسعار", str(response.data["tracking_mode"][0]))

    def test_stock_on_the_road(self):
        product = _stocked(sku="NO-4", quantity=3)
        StockItem.objects.create(
            variant=product.default_variant,
            warehouse_id=Warehouse.transit_id(),
            quantity_on_hand=Decimal("2"),
        )

        response = self._switch(product, SERIAL, identify_later=True)

        self.assertRefusedWithoutCode(response, product, QUANTITY)
        self.assertFalse(StockUnit.objects.exists())

    def test_straight_to_serial_batch_points_at_serial_first(self):
        product = _stocked(sku="NO-5", quantity=3)

        response = self._switch(product, SERIAL_BATCH, identify_later=True)

        self.assertRefusedWithoutCode(response, product, QUANTITY)
        self.assertIn("«رقم تسلسلي» أولًا", str(response.data["tracking_mode"][0]))

    def test_lots_on_the_shelf_cannot_become_serials_in_a_lot(self):
        product = _stocked(sku="NO-6", quantity=0, mode=BATCH)
        receive(variant=product.default_variant, quantity=4, unit_cost="3.00")

        response = self._switch(product, SERIAL_BATCH, identify_later=True)

        self.assertRefusedWithoutCode(response, product, BATCH)

    def test_without_the_stock_unit_permission(self):
        """Identifying a shelf is stock work; editing a product is not."""
        product = _stocked(sku="NO-7", quantity=3)
        clerk = get_user_model().objects.create_user(username="catalog-only")
        clerk.user_permissions.add(
            *Permission.objects.filter(
                content_type__app_label="catalog",
                codename__in=("view_product", "change_product"),
            )
        )
        self.client.force_authenticate(clerk)

        asked = self._switch(product, SERIAL)
        forced = self._switch(product, SERIAL, identify_later=True)

        # No code even when asked plainly: a confirmation it would then refuse
        # is worse than saying so up front.
        self.assertRefusedWithoutCode(asked, product, QUANTITY)
        self.assertRefusedWithoutCode(forced, product, QUANTITY)
        self.assertFalse(StockUnit.objects.exists())


class OpeningIdentificationGuardTests(_SwitchTestCase):
    def test_a_fractional_shelf_is_refused_rather_than_half_named(self):
        """``int(2.5)`` used to name two handsets and leave half of one that
        nothing could ever account for."""
        product = _stocked(sku="OPEN-FRAC", quantity="2.5")
        # Set the way the migration path does, past the guard.
        product.tracking_mode = SERIAL
        product.save(update_fields=["tracking_mode", "updated_at"])

        response = self.client.post(
            "/api/stock-units/identify-opening/",
            {"variant": product.default_variant.pk, "capture_later": True},
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertFalse(StockUnit.objects.exists())
