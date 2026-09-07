"""Where a purchase lands, and who is asked.

The rule the whole feature turns on: a cashier is never asked. A POS cash
purchase is goods being carried in through the door of the place that till
stands in, so that is where they go — and for the shop with one location, which
is every shop today, that is the only place there is.
"""

from decimal import Decimal

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group
from django.db import connection
from django.test import TestCase
from django.test.utils import CaptureQueriesContext
from django.urls import reverse
from rest_framework.test import APIClient

from apps.catalog.testing import create_product_with_default_variant
from apps.core.roles import MANAGER_GROUP, ensure_role_groups
from apps.inventory.models import StockItem, Warehouse
from apps.purchasing.models import PurchaseOrder, Supplier
from apps.purchasing.services import (
    receive_purchase_order,
    submit_purchase_order,
)
from apps.sales.models import RegisterProfile, RegisterSession


class _Request:
    def __init__(self, user, device_id=None):
        self.user = user
        self.META = {} if device_id is None else {"HTTP_X_POINTY_DEVICE_ID": device_id}
        self.query_params = {}
        self.data = {}


class PurchaseDestinationTests(TestCase):
    def setUp(self):
        ensure_role_groups()
        self.user = get_user_model().objects.create_user(username="m", password="p")
        self.user.groups.add(Group.objects.get(name=MANAGER_GROUP))
        self.request = _Request(self.user)
        self.showroom = Warehouse.objects.get(pk=Warehouse.default_id())
        self.store = Warehouse.objects.create(name="المخزن", code="store")
        self.supplier = Supplier.objects.create(name="مورد")
        product = create_product_with_default_variant(
            name="طحين", sku="PW-1", barcode="", unit_price=Decimal("9.00")
        )
        self.variant = product.default_variant

    def _order(self, warehouse=None, quantity=5):
        order = PurchaseOrder.objects.create(
            supplier=self.supplier, warehouse=warehouse
        )
        order.lines.create(
            variant=self.variant, quantity=quantity, unit_cost=Decimal("2.00")
        )
        order.recalculate()
        order.save(update_fields=["subtotal", "total", "updated_at"])
        return order

    def _on_hand(self, warehouse):
        row = StockItem.objects.filter(
            variant=self.variant, warehouse=warehouse
        ).first()
        return row.quantity_on_hand if row else Decimal("0.000")

    def test_an_order_with_no_place_named_goes_to_the_shops_one_place(self):
        """Every purchase order that existed before this shipped, and every
        client that has not learned to ask."""
        self.assertEqual(self._order().warehouse_id, self.showroom.pk)

    def test_a_delivery_lands_where_the_order_says(self):
        order = self._order(warehouse=self.store)
        submit_purchase_order(order, request=self.request)
        receive_purchase_order(order, request=self.request)

        self.assertEqual(self._on_hand(self.store), Decimal("5.000"))
        self.assertEqual(
            self._on_hand(self.showroom),
            Decimal("0.000"),
            "the delivery landed on the wrong shelves",
        )

    def test_expected_stock_is_registered_where_the_goods_are_going(self):
        order = self._order(warehouse=self.store)
        submit_purchase_order(order, request=self.request)
        row = StockItem.objects.get(variant=self.variant, warehouse=self.store)
        self.assertEqual(row.quantity_expected, Decimal("5.000"))

    def test_cancelling_gives_back_the_expectation_it_took(self):
        from apps.purchasing.services import cancel_purchase_order

        order = self._order(warehouse=self.store)
        submit_purchase_order(order, request=self.request)
        cancel_purchase_order(order, reason="x", request=self.request)
        row = StockItem.objects.get(variant=self.variant, warehouse=self.store)
        self.assertEqual(row.quantity_expected, Decimal("0.000"))


class PosCashPurchaseDestinationTests(TestCase):
    """The cashier's path. Nobody is asked and nobody is told."""

    def setUp(self):
        ensure_role_groups()
        self.user = get_user_model().objects.create_user(username="m", password="p")
        self.user.groups.add(Group.objects.get(name=MANAGER_GROUP))
        self.client = APIClient()
        self.client.force_authenticate(user=self.user)
        self.showroom = Warehouse.objects.get(pk=Warehouse.default_id())
        self.store = Warehouse.objects.create(name="المخزن", code="store")
        Supplier.objects.create(name="مورد")
        product = create_product_with_default_variant(
            name="خبز", sku="PW-2", barcode="", unit_price=Decimal("1.00")
        )
        self.variant = product.default_variant
        RegisterSession.objects.create(
            owner=self.user, owner_key=f"user:{self.user.pk}", opening_cash=Decimal("50")
        )

    def _buy(self, device_id=None):
        client = APIClient()
        client.force_authenticate(user=self.user)
        if device_id:
            client.credentials(HTTP_X_POINTY_DEVICE_ID=device_id)
        return client.post(
            reverse("purchaseorder-pos-cash-purchase"),
            {
                "supplier": Supplier.objects.first().pk,
                "lines": [
                    {
                        "variant": self.variant.pk,
                        "quantity": "3",
                        "unit_cost": "1.00",
                    }
                ],
            },
            format="json",
        )

    def _on_hand(self, warehouse):
        row = StockItem.objects.filter(
            variant=self.variant, warehouse=warehouse
        ).first()
        return row.quantity_on_hand if row else Decimal("0.000")

    def test_a_till_with_no_profile_buys_for_the_shops_one_place(self):
        response = self._buy()
        self.assertEqual(response.status_code, 201, response.data)
        self.assertEqual(self._on_hand(self.showroom), Decimal("3.000"))

    def test_a_till_in_the_store_room_buys_for_the_store_room(self):
        """Without the cashier choosing, seeing, or knowing."""
        RegisterProfile.objects.create(device_id="till-x", warehouse=self.store)
        response = self._buy(device_id="till-x")
        self.assertEqual(response.status_code, 201, response.data)
        self.assertEqual(self._on_hand(self.store), Decimal("3.000"))
        self.assertEqual(self._on_hand(self.showroom), Decimal("0.000"))

    def test_the_cashier_never_has_to_send_a_warehouse(self):
        """The request body carries no warehouse at all — that is the point."""
        RegisterProfile.objects.create(device_id="till-y", warehouse=self.store)
        response = self._buy(device_id="till-y")
        self.assertEqual(response.status_code, 201, response.data)
        self.assertEqual(response.data["warehouse"], self.store.pk)


class PurchaseWarehouseQueryScalingTests(TestCase):
    """A destination on every row must not cost a query per row."""

    def setUp(self):
        ensure_role_groups()
        self.user = get_user_model().objects.create_user(username="m", password="p")
        self.user.groups.add(Group.objects.get(name=MANAGER_GROUP))
        self.client = APIClient()
        self.client.force_authenticate(user=self.user)
        self.supplier = Supplier.objects.create(name="مورد")
        self.places = [
            Warehouse.objects.get(pk=Warehouse.default_id()),
            Warehouse.objects.create(name="المخزن", code="store"),
            Warehouse.objects.create(name="السيارة", code="van"),
        ]
        product = create_product_with_default_variant(
            name="زيت", sku="PW-3", barcode="", unit_price=Decimal("4.00")
        )
        self.variant = product.default_variant

    def _add(self, count):
        for index in range(count):
            order = PurchaseOrder.objects.create(
                supplier=self.supplier,
                # Spread across places so a per-row join would actually differ.
                warehouse=self.places[index % len(self.places)],
            )
            order.lines.create(
                variant=self.variant, quantity=1, unit_cost=Decimal("1.00")
            )

    def _measure(self):
        url = reverse("purchaseorder-list")
        self.client.get(url)  # warm
        with CaptureQueriesContext(connection) as ctx:
            response = self.client.get(url)
        self.assertEqual(response.status_code, 200)
        return len(ctx)

    def test_the_purchase_order_list_is_flat_in_the_number_of_places(self):
        self._add(3)
        few = self._measure()
        self._add(9)
        many = self._measure()
        print(f"\n[po-list] 3 orders: {few} queries; 12 orders: {many} queries")
        self.assertEqual(
            few,
            many,
            "the purchase-order list scales with the number of rows",
        )
