"""Who rang a sale up, on the invoice and on the slip.

Until now that answer lived only in the Z-Report: an owner holding a receipt
had to reconcile shifts against timestamps to put a name to it. The order now
carries its cashier — derived from the drawer session's owner, never stored a
second time — and the printed receipt carries the first name (all a 58 mm roll
has room for) alongside the session number.

The attribution is read through ``register_session__owner``, which is one query
per row unless it is joined; the scaling test here is the guard, because a page
of sales rung up by one person hides the N+1 that a real day's list exposes.
"""

from decimal import Decimal

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group
from django.db import connection
from django.test import TestCase, override_settings
from django.test.utils import CaptureQueriesContext
from django.urls import reverse
from rest_framework import status
from rest_framework.test import APIClient

from apps.catalog.testing import create_product_with_default_variant
from apps.core.roles import CASHIER_GROUP, MANAGER_GROUP, ensure_role_groups
from apps.inventory.models import StockItem
from apps.printing.services import build_receipt_payload

from .models import Order


@override_settings(
    CACHES={"default": {"BACKEND": "django.core.cache.backends.locmem.LocMemCache"}}
)
class InvoiceCashierAttributionTests(TestCase):
    def setUp(self):
        ensure_role_groups()
        User = get_user_model()
        self.manager = User.objects.create_user(username="attr-manager", password="p")
        self.manager.groups.add(Group.objects.get(name=MANAGER_GROUP))
        self.manager_client = APIClient()
        self.manager_client.force_authenticate(user=self.manager)

        product = create_product_with_default_variant(
            sku="ATTR1",
            barcode="",
            name="Attribution coffee",
            unit_price=Decimal("4.00"),
        )
        self.variant = product.default_variant
        StockItem.objects.create(variant=self.variant, quantity_on_hand=10000)
        self._seq = 0

    def _cashier(self, *, first_name, last_name=""):
        self._seq += 1
        user = get_user_model().objects.create_user(
            username=f"attr-cashier-{self._seq}",
            password="p",
            first_name=first_name,
            last_name=last_name,
        )
        user.groups.add(Group.objects.get(name=CASHIER_GROUP))
        client = APIClient()
        client.force_authenticate(user=user)
        response = client.post(
            reverse("register-session-start"), {"opening_cash": "0.00"}, format="json"
        )
        self.assertIn(
            response.status_code,
            (status.HTTP_200_OK, status.HTTP_201_CREATED),
            response.data,
        )
        return user, client, response.data["id"]

    def _checkout(self, client):
        response = client.post(
            reverse("order-checkout"),
            {"lines": [{"variant": self.variant.pk, "quantity": 1}]},
            format="json",
        )
        self.assertEqual(response.status_code, status.HTTP_201_CREATED, response.data)
        return response.data

    def test_the_invoice_names_the_cashier_and_the_drawer_session(self):
        cashier, client, session_id = self._cashier(
            first_name="سالم", last_name="الفيتوري"
        )
        order = self._checkout(client)

        detail = self.manager_client.get(
            reverse("order-detail", args=[order["id"]])
        ).data

        self.assertEqual(detail["cashier"], cashier.pk)
        self.assertEqual(detail["cashier_name"], "سالم الفيتوري")
        self.assertEqual(detail["register_session"], session_id)
        self.assertEqual(detail["register_session_number"], f"RS-{session_id}")

    def test_a_list_row_carries_the_same_attribution_as_the_detail(self):
        # The invoices list is where an owner scans for an odd sale, so the
        # answer has to be on the row, not only behind a second request.
        cashier, client, session_id = self._cashier(first_name="سالم")
        self._checkout(client)

        row = self.manager_client.get(reverse("order-list")).data["results"][0]

        self.assertEqual(row["cashier"], cashier.pk)
        self.assertEqual(row["cashier_name"], "سالم")
        self.assertEqual(row["register_session_number"], f"RS-{session_id}")

    def test_a_cashier_with_no_full_name_falls_back_to_the_username(self):
        cashier, client, _ = self._cashier(first_name="")
        order = self._checkout(client)

        detail = self.manager_client.get(
            reverse("order-detail", args=[order["id"]])
        ).data

        self.assertEqual(detail["cashier_name"], cashier.username)

    def test_an_order_with_no_drawer_session_names_nobody(self):
        order = Order.objects.create(total=Decimal("0.00"))

        detail = self.manager_client.get(reverse("order-detail", args=[order.pk])).data

        # Absent rather than a made-up name: an imported or channel order was
        # not rung up by anyone at a till.
        self.assertIsNone(detail.get("cashier"))
        self.assertIsNone(build_receipt_payload(order)["order"]["cashier"])

    def test_a_deleted_cashier_leaves_the_slip_unsigned_not_keyed(self):
        cashier, client, session_id = self._cashier(first_name="سالم")
        order = Order.objects.get(pk=self._checkout(client)["id"])
        cashier_pk = cashier.pk
        cashier.delete()
        order.refresh_from_db()

        payload = build_receipt_payload(order)["order"]
        detail = self.manager_client.get(
            reverse("order-detail", args=[order.pk])
        ).data

        # Nothing on the customer's slip, because "user:5" is a worse answer
        # there than no line at all; the shift still identifies itself.
        self.assertEqual(payload["cashier"]["name"], "")
        self.assertEqual(payload["register_session"]["session_number"], f"RS-{session_id}")
        # The internal record keeps the immutable key, so the sale is still
        # traceable to the drawer it was rung up on.
        self.assertEqual(detail["cashier_name"], f"user:{cashier_pk}")

    def test_the_printed_receipt_carries_the_first_name_and_the_session(self):
        _, client, session_id = self._cashier(first_name="سالم", last_name="الفيتوري")
        order = Order.objects.get(pk=self._checkout(client)["id"])

        payload = build_receipt_payload(order)["order"]

        # First name only: the full one does not fit a 58 mm roll, and the
        # cashier is identified to the customer by the name they go by.
        self.assertEqual(payload["cashier"]["name"], "سالم")
        self.assertEqual(payload["cashier"]["full_name"], "سالم الفيتوري")
        self.assertEqual(payload["register_session"]["session_number"], f"RS-{session_id}")

    def test_the_list_can_be_filtered_to_one_cashier(self):
        # "Show me Bahr's invoices" — the point of the whole attribution.
        bahr, bahr_client, _ = self._cashier(first_name="بحر")
        _, other_client, _ = self._cashier(first_name="محمد")
        bahr_order = self._checkout(bahr_client)["id"]
        other_order = self._checkout(other_client)["id"]

        response = self.manager_client.get(
            reverse("order-list"), {"cashier": bahr.pk}
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK, response.data)
        ids = [row["id"] for row in response.data["results"]]
        self.assertEqual(ids, [bahr_order])
        self.assertNotIn(other_order, ids)

    def test_a_cashier_filter_that_is_not_a_number_is_refused(self):
        # Ignoring it would answer an unfiltered list that the client still
        # labels "filtered by Bahr" — a wrong answer dressed as a right one.
        response = self.manager_client.get(
            reverse("order-list"), {"cashier": "bahr"}
        )

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)

    def test_the_filter_cannot_widen_what_a_cashier_may_see(self):
        # The list is scoped to the caller's own register sessions unless they
        # have full visibility; the filter narrows that scope, never escapes it.
        _, bahr_client, _ = self._cashier(first_name="بحر")
        bahr_order = self._checkout(bahr_client)["id"]
        mohammed, mohammed_client, _ = self._cashier(first_name="محمد")
        self._checkout(mohammed_client)

        response = bahr_client.get(
            reverse("order-list"), {"cashier": mohammed.pk}
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK, response.data)
        self.assertEqual(response.data["results"], [])
        # And Bahr's own list is untouched.
        own = bahr_client.get(reverse("order-list")).data["results"]
        self.assertEqual([row["id"] for row in own], [bahr_order])

    def test_filtering_by_cashier_costs_no_query_per_row(self):
        for _ in range(2):
            _, client, _ = self._cashier(first_name="أ")
            self._checkout(client)
        cashier, client, _ = self._cashier(first_name="ب")
        for _ in range(2):
            self._checkout(client)
        params = {"cashier": cashier.pk}
        self.manager_client.get(reverse("order-list"), params)
        with CaptureQueriesContext(connection) as few:
            self.manager_client.get(reverse("order-list"), params)

        for _ in range(3):
            self._checkout(client)
        with CaptureQueriesContext(connection) as more:
            more_response = self.manager_client.get(reverse("order-list"), params)

        self.assertEqual(len(more_response.data["results"]), 5)
        self.assertEqual(
            len(few),
            len(more),
            "a filtered page must cost the same however many rows it returns",
        )

    def test_naming_the_cashier_costs_no_query_per_row(self):
        """Each row's cashier is a different user, so an unjoined
        ``register_session.owner`` shows up as one extra query per order."""
        for _ in range(2):
            _, client, _ = self._cashier(first_name="أ")
            self._checkout(client)
        # Untimed first: permission and content-type lookups would otherwise
        # land on whichever measurement runs first.
        self.manager_client.get(reverse("order-list"))
        with CaptureQueriesContext(connection) as few:
            few_response = self.manager_client.get(reverse("order-list"))

        for _ in range(3):
            _, client, _ = self._cashier(first_name="ب")
            self._checkout(client)
        with CaptureQueriesContext(connection) as more:
            more_response = self.manager_client.get(reverse("order-list"))

        self.assertEqual(len(few_response.data["results"]), 2)
        self.assertEqual(len(more_response.data["results"]), 5)
        self.assertTrue(
            all(row["cashier_name"] for row in more_response.data["results"])
        )
        self.assertEqual(
            len(few),
            len(more),
            "naming the cashier must not cost a query per order row",
        )
