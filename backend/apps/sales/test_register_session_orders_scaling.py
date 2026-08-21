"""Query-count scaling for the register-session orders strip.

``OrderSessionSerializer`` is ``OrderListSerializer`` plus one flag, so the
strip reads exactly what the invoices list reads: the ``sales_channel`` FK
behind ``sales_channel_name``/``_slug``, the ``applied_discounts`` generic
relation and the ``exchanges`` tree. The endpoint used to hand-roll a shorter
prefetch list than the invoices list does, which cost a query per order in the
page for each of those — invisibly, because an *empty* relation still queries
per row when it is not prefetched. Both callers now share
``OrderQuerySet.with_list_serializer_relations()``; these tests keep the page
flat as the shift grows.
"""

from decimal import Decimal

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group
from django.db import connection
from django.test import TestCase, override_settings
from django.test.utils import CaptureQueriesContext
from django.urls import reverse
from rest_framework.test import APIClient

from apps.catalog.testing import create_product_with_default_variant
from apps.channels.models import SalesChannel
from apps.core.roles import MANAGER_GROUP, ensure_role_groups
from apps.inventory.models import StockItem

from .models import Order, RegisterSession
from .serializers import OrderSessionSerializer
from .services import checkout_order


@override_settings(
    CACHES={"default": {"BACKEND": "django.core.cache.backends.locmem.LocMemCache"}}
)
class RegisterSessionOrdersQueryScalingTests(TestCase):
    def setUp(self):
        ensure_role_groups()
        self.client = APIClient()
        self.user = get_user_model().objects.create_user(username="m", password="p")
        self.user.groups.add(Group.objects.get(name=MANAGER_GROUP))
        self.client.force_authenticate(user=self.user)
        product = create_product_with_default_variant(
            name="Widget",
            sku="W1",
            barcode="",
            unit_price=Decimal("5.00"),
        )
        self.variant = product.default_variant
        StockItem.objects.create(
            variant=self.variant, quantity_on_hand=Decimal("100000")
        )
        self.channel, _ = SalesChannel.objects.get_or_create(
            slug=SalesChannel.POS_SLUG,
            defaults={
                "name": SalesChannel.POS_NAME,
                "channel_type": SalesChannel.ChannelType.POS,
            },
        )
        self.session = RegisterSession.objects.create(
            owner=self.user,
            owner_key=f"user:{self.user.pk}",
            opening_cash=Decimal("10.00"),
        )

    def _add_orders(self, count, lines=2):
        for _ in range(count):
            checkout_order(
                register_session=self.session,
                lines_data=[
                    {"variant": self.variant, "quantity": Decimal("1")}
                    for _ in range(lines)
                ],
                payments_data=[{"method": "cash", "amount": Decimal("5.00") * lines}],
            )
        # The channel is derived from the authenticating credential, which the
        # service-level checkout above has no request for; set it here so the
        # rows really do traverse the FK the serializer names.
        Order.objects.filter(register_session=self.session).update(
            sales_channel=self.channel
        )

    def _measure(self):
        url = reverse("register-session-orders", args=[self.session.pk])
        # Warm permissions / content types / settings singletons first, or the
        # first request's fixed overhead lands on the smaller measurement.
        self.client.get(url)
        with CaptureQueriesContext(connection) as ctx:
            response = self.client.get(url)
        self.assertEqual(response.status_code, 200)
        return len(ctx), response

    def test_query_count_is_flat_as_the_shift_grows(self):
        self._add_orders(5)
        five, response_five = self._measure()
        self.assertEqual(len(response_five.data["results"]), 5)

        self._add_orders(15)
        twenty, response_twenty = self._measure()
        self.assertEqual(len(response_twenty.data["results"]), 20)

        print(
            f"\n[session-orders] 5 orders: {five} queries; "
            f"20 orders: {twenty} queries"
        )
        self.assertEqual(
            five,
            twenty,
            "register-session orders strip scales with the order count",
        )

    def test_rows_match_an_unprefetched_serialization(self):
        """The shared prefetch shape changes only *where* each field is read
        from, never what it says."""
        self._add_orders(3)
        _count, response = self._measure()
        rows = {row["id"]: row for row in response.data["results"]}
        self.assertEqual(len(rows), 3)
        for order_id in rows:
            cold = Order.objects.get(pk=order_id)
            expected = OrderSessionSerializer(cold, context={"request": None}).data
            self.assertEqual(dict(rows[order_id]), dict(expected))
