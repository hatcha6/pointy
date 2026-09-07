"""Which place a till sells out of — and, more importantly, what happens to a
till that has never heard of the question.

Every shop running Pointy today has one warehouse and no register profiles. The
tests that matter most here are the ones asserting that such a shop keeps
selling exactly as it did, with nothing configured, through an update it did not
ask for.
"""

from decimal import Decimal

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group
from django.test import TestCase
from django.urls import reverse
from rest_framework.test import APIClient

from apps.catalog.testing import create_product_with_default_variant
from apps.core.roles import CASHIER_GROUP, MANAGER_GROUP, ensure_role_groups
from apps.inventory.models import StockItem, Warehouse
from apps.sales.models import RegisterProfile, RegisterSession
from apps.sales.registers import selling_warehouse_id
from apps.sales.services import checkout_order


class _Request:
    def __init__(self, device_id=None, user=None):
        self.META = {} if device_id is None else {"HTTP_X_POINTY_DEVICE_ID": device_id}
        self.user = user


class TillKeepsSellingTests(TestCase):
    """The upgrade property: nothing configured, nothing broken."""

    def setUp(self):
        ensure_role_groups()
        self.user = get_user_model().objects.create_user(username="c", password="p")
        self.user.groups.add(Group.objects.get(name=CASHIER_GROUP))
        product = create_product_with_default_variant(
            name="شاي", sku="RP-1", barcode="", unit_price=Decimal("5.00")
        )
        self.variant = product.default_variant
        StockItem.objects.create(
            variant=self.variant, quantity_on_hand=Decimal("100")
        )
        self.session = RegisterSession.objects.create(
            owner=self.user, owner_key=f"user:{self.user.pk}", opening_cash=Decimal("0")
        )

    def _sell(self, request=None):
        return checkout_order(
            register_session=self.session,
            lines_data=[{"variant": self.variant, "quantity": Decimal("1")}],
            payments_data=[{"method": "cash", "amount": Decimal("5.00")}],
            request=request,
        )

    def test_a_till_with_no_profile_sells_from_the_shops_one_warehouse(self):
        """The state every existing shop is in the moment this ships."""
        self.assertFalse(RegisterProfile.objects.exists())
        self.assertEqual(selling_warehouse_id(None), Warehouse.default_id())
        self._sell()
        self.assertEqual(
            self.variant.quantity_on_hand_at(Warehouse.default_id()), Decimal("99.000")
        )

    def test_a_till_that_does_not_say_who_it_is_still_sells(self):
        """An older client sends no device header. It must not be the reason a
        customer cannot be served."""
        self._sell(request=_Request(device_id=None, user=self.user))
        self.assertEqual(
            self.variant.quantity_on_hand_at(Warehouse.default_id()), Decimal("99.000")
        )

    def test_a_profile_pointing_at_a_closed_warehouse_falls_back(self):
        """A setting that has gone stale must degrade to selling, not to
        refusing to sell."""
        shut = Warehouse.objects.create(name="مغلق", code="shut", is_active=False)
        RegisterProfile.objects.create(device_id="till-1", warehouse=shut)
        self.assertEqual(
            selling_warehouse_id(_Request("till-1")), Warehouse.default_id()
        )

    def test_a_till_assigned_to_the_store_room_sells_the_store_rooms_stock(self):
        store = Warehouse.objects.create(name="المخزن", code="store")
        StockItem.objects.create(
            variant=self.variant, warehouse=store, quantity_on_hand=Decimal("40")
        )
        RegisterProfile.objects.create(device_id="till-2", warehouse=store)

        self._sell(request=_Request("till-2", user=self.user))
        self.assertEqual(
            self.variant.quantity_on_hand_at(store), Decimal("39.000")
        )
        self.assertEqual(
            self.variant.quantity_on_hand_at(Warehouse.default_id()),
            Decimal("100.000"),
            "the sale came off the wrong shelves",
        )

    def test_a_till_cannot_sell_what_its_own_place_has_not_got(self):
        """The showroom having none of something is not answered by the store
        room having plenty."""
        store = Warehouse.objects.create(name="المخزن", code="store")
        RegisterProfile.objects.create(device_id="till-3", warehouse=store)
        with self.assertRaises(Exception):
            self._sell(request=_Request("till-3", user=self.user))


class RegisterProfileApiTests(TestCase):
    def setUp(self):
        ensure_role_groups()
        self.manager = get_user_model().objects.create_user(username="m", password="p")
        self.manager.groups.add(Group.objects.get(name=MANAGER_GROUP))
        self.cashier = get_user_model().objects.create_user(username="c", password="p")
        self.cashier.groups.add(Group.objects.get(name=CASHIER_GROUP))
        self.store = Warehouse.objects.create(name="المخزن", code="store")

    def _client(self, user, device_id=None):
        client = APIClient()
        client.force_authenticate(user=user)
        if device_id:
            client.credentials(HTTP_X_POINTY_DEVICE_ID=device_id)
        return client

    def test_a_till_asking_about_itself_is_enrolled_on_the_spot(self):
        """A shop never has to register its own hardware."""
        response = self._client(self.cashier, "till-a").get(
            reverse("register-profile-me")
        )
        self.assertEqual(response.status_code, 200, response.data)
        self.assertTrue(response.data["assigned"])
        self.assertEqual(response.data["warehouse"], Warehouse.default_id())
        self.assertEqual(RegisterProfile.objects.count(), 1)

    def test_a_till_with_no_device_id_is_told_the_default_without_a_row(self):
        response = self._client(self.cashier).get(reverse("register-profile-me"))
        self.assertEqual(response.status_code, 200, response.data)
        self.assertFalse(response.data["assigned"])
        self.assertFalse(RegisterProfile.objects.exists())

    def test_a_cashier_may_see_where_the_till_sells_from_but_not_move_it(self):
        client = self._client(self.cashier, "till-b")
        self.assertEqual(client.get(reverse("register-profile-me")).status_code, 200)
        moved = client.patch(
            reverse("register-profile-me"),
            {"warehouse": self.store.pk},
            format="json",
        )
        self.assertEqual(moved.status_code, 403, moved.data)

    def test_a_manager_can_point_a_till_at_another_place(self):
        client = self._client(self.manager, "till-c")
        client.get(reverse("register-profile-me"))
        moved = client.patch(
            reverse("register-profile-me"),
            {"warehouse": self.store.pk, "name": "صندوق المخزن"},
            format="json",
        )
        self.assertEqual(moved.status_code, 200, moved.data)
        self.assertEqual(moved.data["warehouse"], self.store.pk)
        self.assertEqual(moved.data["warehouse_name"], "المخزن")

    def test_a_till_cannot_be_pointed_at_the_road(self):
        transit = Warehouse.objects.get(pk=Warehouse.transit_id())
        client = self._client(self.manager, "till-d")
        client.get(reverse("register-profile-me"))
        response = client.patch(
            reverse("register-profile-me"),
            {"warehouse": transit.pk},
            format="json",
        )
        self.assertEqual(response.status_code, 400, response.data)
