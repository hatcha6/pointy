from decimal import Decimal

from django.contrib.auth import get_user_model
from django.contrib.auth.models import AnonymousUser, Group
from django.core.cache import cache
from django.test import RequestFactory, TestCase, override_settings
from django.urls import reverse
from rest_framework import status
from rest_framework.exceptions import PermissionDenied
from rest_framework.test import APIClient

from apps.catalog.testing import create_product_with_default_variant
from apps.core.roles import CASHIER_GROUP, MANAGER_GROUP, ensure_role_groups
from apps.inventory.models import StockItem
from apps.sales.models import Order
from .models import SalesChannel
from .services import require_active_sales_channel, resolve_sales_channel


def create_user_with_role(username, role):
    user = get_user_model().objects.create_user(username=username, password="pass")
    user.groups.add(Group.objects.get(name=role))
    return user


def create_delivery_channel(name="Talabat"):
    channel = SalesChannel.objects.create(
        name=name,
        slug=SalesChannel.build_unique_slug(name),
        channel_type=SalesChannel.ChannelType.DELIVERY,
    )
    raw_key = channel.assign_new_api_key()
    return channel, raw_key


class SalesChannelModelTests(TestCase):
    def test_pos_channel_is_seeded_by_migration(self):
        channel = SalesChannel.objects.get(slug=SalesChannel.POS_SLUG)

        self.assertTrue(channel.is_system)
        self.assertTrue(channel.is_active)
        self.assertEqual(channel.channel_type, SalesChannel.ChannelType.POS)

    def test_api_key_round_trip_stores_only_the_hash(self):
        channel, raw_key = create_delivery_channel()

        self.assertNotIn(raw_key, channel.api_key_hash)
        self.assertEqual(SalesChannel.authenticate_api_key(raw_key), channel)

    def test_authenticate_rejects_unknown_and_malformed_keys(self):
        create_delivery_channel()

        self.assertIsNone(SalesChannel.authenticate_api_key(""))
        self.assertIsNone(SalesChannel.authenticate_api_key("not-a-key"))
        self.assertIsNone(SalesChannel.authenticate_api_key("pck_deadbeef_wrongsecret"))
        self.assertIsNone(SalesChannel.authenticate_api_key("x" * 1000))

    def test_rotating_the_key_invalidates_the_previous_one(self):
        channel, old_key = create_delivery_channel()

        new_key = channel.assign_new_api_key()

        self.assertNotEqual(old_key, new_key)
        self.assertIsNone(SalesChannel.authenticate_api_key(old_key))
        self.assertEqual(SalesChannel.authenticate_api_key(new_key), channel)


class SalesChannelResolutionTests(TestCase):
    def setUp(self):
        self.factory = RequestFactory()

    def test_session_authenticated_request_resolves_to_pos(self):
        request = self.factory.get("/api/orders/")
        request.user = get_user_model().objects.create_user(
            username="cashier",
            password="pass",
        )

        channel = resolve_sales_channel(request)

        self.assertEqual(channel.slug, SalesChannel.POS_SLUG)

    def test_anonymous_request_resolves_to_no_channel(self):
        request = self.factory.get("/api/orders/")
        request.user = AnonymousUser()

        self.assertIsNone(resolve_sales_channel(request))
        with self.assertRaises(PermissionDenied):
            require_active_sales_channel(request)

    def test_api_key_bound_channel_wins_over_session(self):
        channel, _raw_key = create_delivery_channel()
        request = self.factory.get("/api/orders/")
        request.user = get_user_model().objects.create_user(
            username="cashier2",
            password="pass",
        )
        request.sales_channel = channel

        self.assertEqual(resolve_sales_channel(request), channel)

    def test_require_active_rejects_deauthorized_channel(self):
        channel, _raw_key = create_delivery_channel()
        channel.is_active = False
        channel.save(update_fields=["is_active", "updated_at"])
        request = self.factory.get("/api/orders/")
        request.user = AnonymousUser()
        request.sales_channel = channel

        with self.assertRaises(PermissionDenied):
            require_active_sales_channel(request)


class SalesChannelMiddlewareTests(TestCase):
    def test_invalid_api_key_is_rejected_before_any_view(self):
        response = self.client.get(
            "/healthz/",
            headers={"X-Channel-Api-Key": "pck_deadbeef_bogus"},
        )

        self.assertEqual(response.status_code, 401)

    def test_deauthorized_channel_key_is_rejected_with_403(self):
        channel, raw_key = create_delivery_channel()
        channel.is_active = False
        channel.save(update_fields=["is_active", "updated_at"])

        response = self.client.get(
            "/healthz/",
            headers={"X-Channel-Api-Key": raw_key},
        )

        self.assertEqual(response.status_code, 403)

    def test_valid_key_passes_through_and_records_last_use(self):
        channel, raw_key = create_delivery_channel()

        response = self.client.get(
            "/healthz/",
            headers={"X-Channel-Api-Key": raw_key},
        )

        self.assertEqual(response.status_code, 200)
        channel.refresh_from_db()
        self.assertIsNotNone(channel.api_key_last_used_at)

    def test_requests_without_a_key_are_untouched(self):
        response = self.client.get("/healthz/")

        self.assertEqual(response.status_code, 200)

    @override_settings(
        CACHES={
            "default": {
                "BACKEND": "django.core.cache.backends.locmem.LocMemCache",
                "LOCATION": "channels-throttle-tests",
            },
        },
        POINTY_CHANNEL_LAST_USED_WRITE_SECONDS=60,
    )
    def test_last_used_write_is_throttled_to_one_per_window(self):
        cache.clear()
        channel, raw_key = create_delivery_channel()

        self.client.get("/healthz/", headers={"X-Channel-Api-Key": raw_key})
        channel.refresh_from_db()
        self.assertIsNotNone(channel.api_key_last_used_at)

        # Clear the stamp out-of-band: a second request inside the window must
        # NOT write it back.
        SalesChannel.objects.filter(pk=channel.pk).update(api_key_last_used_at=None)
        self.client.get("/healthz/", headers={"X-Channel-Api-Key": raw_key})
        channel.refresh_from_db()
        self.assertIsNone(channel.api_key_last_used_at)

        # Once the window lapses (simulated by clearing the guard key), the
        # next request writes again.
        cache.clear()
        self.client.get("/healthz/", headers={"X-Channel-Api-Key": raw_key})
        channel.refresh_from_db()
        self.assertIsNotNone(channel.api_key_last_used_at)


class SalesChannelApiTests(TestCase):
    def setUp(self):
        ensure_role_groups()
        self.manager = create_user_with_role("channel-manager", MANAGER_GROUP)
        self.client = APIClient()
        self.client.force_authenticate(user=self.manager)

    def test_cashier_cannot_access_channel_management(self):
        cashier_client = APIClient()
        cashier_client.force_authenticate(
            user=create_user_with_role("channel-cashier", CASHIER_GROUP)
        )

        list_response = cashier_client.get(reverse("sales-channel-list"))
        create_response = cashier_client.post(
            reverse("sales-channel-list"),
            {"name": "Talabat", "channel_type": "delivery"},
            format="json",
        )

        self.assertEqual(list_response.status_code, status.HTTP_403_FORBIDDEN)
        self.assertEqual(create_response.status_code, status.HTTP_403_FORBIDDEN)

    def test_list_always_includes_the_pos_channel(self):
        response = self.client.get(reverse("sales-channel-list"))

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        slugs = [channel["slug"] for channel in response.data["results"]]
        self.assertIn(SalesChannel.POS_SLUG, slugs)

    def test_create_returns_the_api_key_exactly_once(self):
        response = self.client.post(
            reverse("sales-channel-list"),
            {"name": "Talabat", "channel_type": "delivery"},
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_201_CREATED)
        raw_key = response.data["api_key"]
        self.assertTrue(raw_key.startswith("pck_"))
        self.assertFalse(response.data["is_system"])

        detail = self.client.get(reverse("sales-channel-detail", args=[response.data["id"]]))
        self.assertNotIn("api_key", detail.data)
        self.assertTrue(detail.data["has_api_key"])

    def test_client_supplied_system_flag_and_slug_are_ignored(self):
        response = self.client.post(
            reverse("sales-channel-list"),
            {
                "name": "Sneaky",
                "channel_type": "delivery",
                "is_system": True,
                "slug": SalesChannel.POS_SLUG,
            },
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_201_CREATED)
        channel = SalesChannel.objects.get(pk=response.data["id"])
        self.assertFalse(channel.is_system)
        self.assertNotEqual(channel.slug, SalesChannel.POS_SLUG)

    def test_pos_channel_type_is_reserved(self):
        response = self.client.post(
            reverse("sales-channel-list"),
            {"name": "Fake POS", "channel_type": "pos"},
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)

    def test_pos_channel_cannot_be_deauthorized_or_deleted(self):
        pos = SalesChannel.pos_channel()

        patch_response = self.client.patch(
            reverse("sales-channel-detail", args=[pos.pk]),
            {"is_active": False},
            format="json",
        )
        delete_response = self.client.delete(
            reverse("sales-channel-detail", args=[pos.pk])
        )
        rotate_response = self.client.post(
            reverse("sales-channel-rotate-key", args=[pos.pk])
        )

        self.assertEqual(patch_response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertEqual(delete_response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertEqual(rotate_response.status_code, status.HTTP_400_BAD_REQUEST)
        pos.refresh_from_db()
        self.assertTrue(pos.is_active)

    def test_deauthorizing_a_channel_blocks_its_key_immediately(self):
        channel, raw_key = create_delivery_channel()

        response = self.client.patch(
            reverse("sales-channel-detail", args=[channel.pk]),
            {"is_active": False},
            format="json",
        )
        self.assertEqual(response.status_code, status.HTTP_200_OK)

        rejected = APIClient().get(
            "/healthz/",
            headers={"X-Channel-Api-Key": raw_key},
        )
        self.assertEqual(rejected.status_code, 403)

    def test_rotate_key_returns_a_new_key_and_invalidates_the_old(self):
        channel, old_key = create_delivery_channel()

        response = self.client.post(reverse("sales-channel-rotate-key", args=[channel.pk]))

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        new_key = response.data["api_key"]
        self.assertNotEqual(new_key, old_key)

        old_attempt = APIClient().get("/healthz/", headers={"X-Channel-Api-Key": old_key})
        new_attempt = APIClient().get("/healthz/", headers={"X-Channel-Api-Key": new_key})
        self.assertEqual(old_attempt.status_code, 401)
        self.assertEqual(new_attempt.status_code, 200)

    def test_channel_with_orders_cannot_be_deleted(self):
        channel, _raw_key = create_delivery_channel()
        Order.objects.create(sales_channel=channel)

        response = self.client.delete(reverse("sales-channel-detail", args=[channel.pk]))

        self.assertEqual(response.status_code, status.HTTP_409_CONFLICT)
        self.assertTrue(SalesChannel.objects.filter(pk=channel.pk).exists())

    def test_channel_without_orders_can_be_deleted(self):
        channel, _raw_key = create_delivery_channel()

        response = self.client.delete(reverse("sales-channel-detail", args=[channel.pk]))

        self.assertEqual(response.status_code, status.HTTP_204_NO_CONTENT)
        self.assertFalse(SalesChannel.objects.filter(pk=channel.pk).exists())


class OrderChannelStampingTests(TestCase):
    def setUp(self):
        ensure_role_groups()
        self.client = APIClient()
        self.cashier = create_user_with_role("stamp-cashier", CASHIER_GROUP)
        self.client.force_authenticate(user=self.cashier)
        self.product = create_product_with_default_variant(
            sku="TEA",
            name="Tea",
            unit_price=Decimal("2.00"),
        )
        self.variant = self.product.default_variant
        StockItem.objects.create(variant=self.variant, quantity_on_hand=10)
        self.client.post(
            reverse("register-session-start"),
            {"opening_cash": "0.00"},
            format="json",
        )

    def test_checkout_stamps_the_pos_channel_from_the_session(self):
        response = self.client.post(
            reverse("order-checkout"),
            {
                "lines": [{"variant": self.variant.pk, "quantity": 1}],
                "payment_method": "cash",
                "amount_received": "2.00",
            },
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_201_CREATED)
        self.assertEqual(response.data["sales_channel_slug"], SalesChannel.POS_SLUG)
        order = Order.objects.get(pk=response.data["id"])
        self.assertEqual(order.sales_channel.slug, SalesChannel.POS_SLUG)

    def test_client_supplied_channel_is_ignored(self):
        delivery, _raw_key = create_delivery_channel()

        create_response = self.client.post(
            reverse("order-list"),
            {
                "lines": [{"variant": self.variant.pk, "quantity": 1}],
                "sales_channel": delivery.pk,
            },
            format="json",
        )
        checkout_response = self.client.post(
            reverse("order-checkout"),
            {
                "lines": [{"variant": self.variant.pk, "quantity": 1}],
                "payment_method": "cash",
                "amount_received": "2.00",
                "sales_channel": delivery.pk,
            },
            format="json",
        )

        self.assertEqual(create_response.status_code, status.HTTP_201_CREATED)
        self.assertEqual(checkout_response.status_code, status.HTTP_201_CREATED)
        for order_id in (create_response.data["id"], checkout_response.data["id"]):
            order = Order.objects.get(pk=order_id)
            self.assertEqual(order.sales_channel.slug, SalesChannel.POS_SLUG)
