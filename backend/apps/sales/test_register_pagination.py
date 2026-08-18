"""Paging the register feeds while the drawer is still selling.

These three lists — the session history, a session's sales, its cash movements —
are read newest-first *while they are being written to*. Under page-number
pagination each page is an OFFSET into that live list, so a sale rung up between
two pages pushes every row down: the boundary rows come back a second time and
the rows written since the first page, already behind the offset the client
consumed, are never served at all. Cashiers saw sales vanish from the shift and
drawers missing from the history. These tests pin the cursor behaviour that
replaced it.
"""

from decimal import Decimal
from urllib.parse import parse_qs, urlparse

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group
from django.test import TestCase
from django.urls import reverse
from rest_framework import status
from rest_framework.test import APIClient

from apps.catalog.testing import create_product_with_default_variant
from apps.core.roles import MANAGER_GROUP, ensure_role_groups
from apps.inventory.models import StockItem

from .models import RegisterCashMovement, RegisterSession
from .services import checkout_order

PAGE_SIZE = 50


def _session(owner, *, session_status=RegisterSession.Status.CLOSED):
    return RegisterSession.objects.create(
        owner=owner,
        owner_key=f"user:{owner.pk}",
        opening_cash=Decimal("0.00"),
        status=session_status,
    )


def _next_cursor(payload):
    next_url = payload.get("next")
    if not next_url:
        return None
    return parse_qs(urlparse(next_url).query).get("cursor", [None])[0]


class RegisterFeedPaginationTests(TestCase):
    def setUp(self):
        ensure_role_groups()
        self.user = get_user_model().objects.create_user(
            username="pagination-manager",
            password="pass",
        )
        self.user.groups.add(Group.objects.get(name=MANAGER_GROUP))
        self.client = APIClient()
        self.client.force_authenticate(user=self.user)
        product = create_product_with_default_variant(
            name="Paged item",
            sku="PAGE-1",
            barcode="",
            unit_price=Decimal("1.00"),
        )
        StockItem.objects.create(
            variant=product.default_variant,
            quantity_on_hand=Decimal("10000"),
        )
        self.variant = product.default_variant

    def _sell(self, session):
        return checkout_order(
            register_session=session,
            lines_data=[{"variant": self.variant, "quantity": Decimal("1")}],
            payments_data=[{"method": "cash", "amount": Decimal("1.00")}],
        ).pk

    def _page(self, url, cursor=None):
        response = self.client.get(url, {"cursor": cursor} if cursor else {})
        self.assertEqual(response.status_code, status.HTTP_200_OK, response.data)
        return response.data

    def _two_pages_across_a_write(self, url, write):
        """First page, a concurrent write, then the page it pointed at."""
        first = self._page(url)
        write()
        second = self._page(url, _next_cursor(first))
        return [row["id"] for row in first["results"]] + [
            row["id"] for row in second["results"]
        ]

    # 1. A sale rung up mid-review still reaches the shift's list; nothing repeats.
    def test_a_sale_during_paging_never_drops_an_earlier_sale(self):
        session = _session(self.user, session_status=RegisterSession.Status.OPEN)
        issued = [self._sell(session) for _ in range(PAGE_SIZE + 10)]

        url = reverse("register-session-orders", args=[session.pk])
        seen = self._two_pages_across_a_write(
            url,
            lambda: [self._sell(session) for _ in range(3)],
        )

        self.assertEqual(set(issued) - set(seen), set())
        self.assertEqual(len(seen), len(set(seen)))

    # 2. A drawer opened mid-scroll never displaces one already in the history.
    def test_a_drawer_opening_during_paging_never_drops_a_session(self):
        opened = [_session(self.user).pk for _ in range(PAGE_SIZE + 10)]

        url = reverse("register-session-list")
        seen = self._two_pages_across_a_write(
            url,
            lambda: [_session(self.user) for _ in range(2)],
        )

        self.assertEqual(set(opened) - set(seen), set())
        self.assertEqual(len(seen), len(set(seen)))

    # 3. Same guarantee for the drawer's pay-ins / pay-outs.
    def test_a_cash_movement_during_paging_never_drops_a_movement(self):
        session = _session(self.user, session_status=RegisterSession.Status.OPEN)

        def pay_in():
            return RegisterCashMovement.objects.create(
                register_session=session,
                movement_type=RegisterCashMovement.MovementType.PAY_IN,
                amount=Decimal("1.00"),
            ).pk

        recorded = [pay_in() for _ in range(PAGE_SIZE + 5)]

        url = reverse("register-session-cash-movements", args=[session.pk])
        seen = self._two_pages_across_a_write(url, pay_in)

        self.assertEqual(set(recorded) - set(seen), set())
        self.assertEqual(len(seen), len(set(seen)))

    # 4. Walking the cursor to the end yields every row exactly once.
    def test_walking_the_cursor_covers_a_quiet_feed_exactly_once(self):
        opened = [_session(self.user).pk for _ in range(PAGE_SIZE + 10)]

        url = reverse("register-session-list")
        seen = []
        cursor = None
        while True:
            payload = self._page(url, cursor)
            seen.extend(row["id"] for row in payload["results"])
            cursor = _next_cursor(payload)
            if cursor is None:
                break

        self.assertEqual(seen, sorted(opened, reverse=True))
