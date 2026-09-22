"""Opening balances are a cost source, not only a stock event.

The cost screens — "lowest / highest / last / average" and the cost history
beside them — read purchase lines. A shop that typed its shelves in rather than
buying them through Pointy therefore saw "no cost data" on the product page
while the till, which reads the valuation ledger, happily showed a cost. These
tests pin the second source into both endpoints, including the boundary that is
easy to get wrong: paging a list assembled from two tables.
"""

from decimal import Decimal
from unittest.mock import patch

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group
from django.db import connection
from django.test import TestCase
from django.test.utils import CaptureQueriesContext
from django.urls import reverse
from django.utils import timezone
from rest_framework.pagination import PageNumberPagination
from rest_framework.test import APIClient

from apps.catalog.models import Product, ProductVariant
from apps.core.roles import MANAGER_GROUP, ensure_role_groups
from apps.inventory.models import Warehouse
from apps.inventory.opening_balance import open_stock_balance

from .models import PurchaseLine, PurchaseOrder, Supplier


class OpeningCostSourceTests(TestCase):
    def setUp(self):
        ensure_role_groups()
        self.client = APIClient()
        self.user = get_user_model().objects.create_user(
            username="cost-manager", password="pass"
        )
        self.user.groups.add(Group.objects.get(name=MANAGER_GROUP))
        self.client.force_authenticate(user=self.user)
        self.warehouse = Warehouse.objects.first() or Warehouse.objects.create(
            name="main"
        )
        self.supplier = Supplier.objects.create(name="مورد", phone="0910000000")
        self.product = Product.objects.create(name="منتج", is_active=True)
        self.variant = ProductVariant.objects.create(
            product=self.product,
            sku="OC-1",
            unit_price=Decimal("10"),
            is_active=True,
            is_default=True,
        )
        self._order_seq = 0

    def _buy(self, cost, *, quantity="1"):
        self._order_seq += 1
        order = PurchaseOrder.objects.create(
            warehouse=self.warehouse,
            supplier=self.supplier,
            order_number=f"OC-PO-{self._order_seq:04d}",
            status=PurchaseOrder.Status.RECEIVED,
        )
        return PurchaseLine.objects.create(
            purchase_order=order,
            variant=self.variant,
            quantity=Decimal(quantity),
            unit_cost=Decimal(cost),
        )

    def _open(self, quantity, cost, *, at=None):
        return open_stock_balance(
            variant=self.variant,
            quantity=Decimal(quantity),
            unit_cost=Decimal(cost),
            warehouse=self.warehouse,
            user=self.user,
            at=at,
        )

    def _summary(self):
        response = self.client.get(
            reverse("purchaseorder-product-cost-summary"),
            {"product": self.product.pk},
        )
        self.assertEqual(response.status_code, 200, response.content[:300])
        return {row["variant"]: row for row in response.data}[self.variant.pk]

    def _history(self, **params):
        response = self.client.get(
            reverse("purchaseorder-product-cost-history"),
            {"product": self.product.pk, **params},
        )
        self.assertEqual(response.status_code, 200, response.content[:300])
        return response.data

    # ------------------------------------------------------------------
    # Summary
    # ------------------------------------------------------------------

    def test_an_opening_alone_is_cost_data(self):
        """The whole complaint in one test: a shop that never raised a PO used
        to be told it had no cost for a product it had just priced."""
        self._open("40", "7.50")

        row = self._summary()

        self.assertEqual(row["purchases_count"], 0)
        self.assertEqual(row["openings_count"], 1)
        self.assertEqual(Decimal(row["lowest_cost"]), Decimal("7.50"))
        self.assertEqual(Decimal(row["highest_cost"]), Decimal("7.50"))
        self.assertEqual(Decimal(row["average_cost"]), Decimal("7.50"))
        self.assertEqual(Decimal(row["last_cost"]), Decimal("7.50"))

    def test_a_variant_with_neither_still_reports_nothing(self):
        row = self._summary()

        self.assertEqual(row["purchases_count"], 0)
        self.assertEqual(row["openings_count"], 0)
        self.assertIsNone(row["lowest_cost"])
        self.assertIsNone(row["average_cost"])
        self.assertIsNone(row["last_cost"])

    def test_an_opening_widens_the_lowest_and_highest(self):
        self._buy("4.00")
        self._buy("6.00")
        self._open("5", "1.00")

        row = self._summary()

        self.assertEqual(Decimal(row["lowest_cost"]), Decimal("1.00"))
        self.assertEqual(Decimal(row["highest_cost"]), Decimal("6.00"))

    def test_the_average_is_taken_over_events_not_over_sources(self):
        """Three purchases at 6 and one opening at 2 average 5 — not 4, which
        is what averaging the purchase mean against the opening would give."""
        self._buy("6.00")
        self._buy("6.00")
        self._buy("6.00")
        self._open("5", "2.00")

        row = self._summary()

        self.assertEqual(Decimal(row["average_cost"]), Decimal("5.00"))
        self.assertEqual(row["purchases_count"], 3)
        self.assertEqual(row["openings_count"], 1)

    def test_last_cost_is_whichever_event_happened_most_recently(self):
        self._buy("6.00")
        self._open("5", "2.00")

        self.assertEqual(Decimal(self._summary()["last_cost"]), Decimal("2.00"))

    def test_an_older_opening_does_not_outrank_a_newer_purchase(self):
        self._open(
            "5", "2.00", at=timezone.now() - timezone.timedelta(days=30)
        )
        self._buy("6.00")

        self.assertEqual(Decimal(self._summary()["last_cost"]), Decimal("6.00"))

    def test_summary_query_count_does_not_grow_with_variants(self):
        """The openings lookup is one query for the whole product, like the
        batched last-line lookup beside it — the 2026-09-16 regression."""
        for index in range(3):
            variant = ProductVariant.objects.create(
                product=self.product,
                name=f"v{index}",
                sku=f"OC-S-{index}",
                unit_price=Decimal("10"),
            )
            open_stock_balance(
                variant=variant,
                quantity=Decimal("2"),
                unit_cost=Decimal("3"),
                warehouse=self.warehouse,
                user=self.user,
            )
        url = reverse("purchaseorder-product-cost-summary")
        params = {"product": self.product.pk}
        self.client.get(url, params)  # warm the per-request caches
        with CaptureQueriesContext(connection) as ctx:
            self.client.get(url, params)
        few = len(ctx.captured_queries)

        for index in range(3, 12):
            variant = ProductVariant.objects.create(
                product=self.product,
                name=f"v{index}",
                sku=f"OC-S-{index}",
                unit_price=Decimal("10"),
            )
            open_stock_balance(
                variant=variant,
                quantity=Decimal("2"),
                unit_cost=Decimal("3"),
                warehouse=self.warehouse,
                user=self.user,
            )
        self.client.get(url, params)
        with CaptureQueriesContext(connection) as ctx:
            self.client.get(url, params)
        many = len(ctx.captured_queries)

        self.assertEqual(
            few,
            many,
            "product-cost-summary scaled with opened variants: "
            f"{few} -> {many} queries",
        )

    # ------------------------------------------------------------------
    # History
    # ------------------------------------------------------------------

    def test_history_carries_the_opening_row(self):
        self._open("40", "7.50")

        data = self._history()

        self.assertEqual(data["count"], 1)
        row = data["results"][0]
        self.assertEqual(row["source"], "opening")
        self.assertEqual(row["effective_base_unit_cost"], "7.50")
        self.assertEqual(Decimal(row["quantity"]), Decimal("40"))
        # No supplier and no order, said explicitly rather than by omission —
        # the client labels the row on this rather than on a missing name.
        self.assertIsNone(row["supplier"])
        self.assertIsNone(row["supplier_name"])
        self.assertIsNone(row["purchase_order"])
        self.assertEqual(Decimal(row["unit_factor"]), Decimal("1"))

    def test_history_marks_purchases_as_purchases(self):
        self._buy("4.00")

        row = self._history()["results"][0]

        self.assertEqual(row["source"], "purchase")

    def test_history_interleaves_the_two_sources_newest_first(self):
        self._buy("1.00")
        self._open("5", "2.00")
        self._buy("3.00")

        rows = self._history()["results"]

        self.assertEqual(data_costs(rows), ["3.00", "2.00", "1.00"])
        self.assertEqual(
            [row["source"] for row in rows],
            ["purchase", "opening", "purchase"],
        )

    def test_history_paging_neither_repeats_nor_drops_a_row(self):
        """The boundary that a two-table list gets wrong: an offset page has to
        be a window onto the merged list, not onto one source with the other
        stapled to the front.

        The page size is forced down rather than six pages' worth of rows being
        written, because what is under test is the window arithmetic and not
        the volume."""
        for cost in range(1, 6):
            self._buy(f"{cost}.00")
        self._open("5", "10.00")

        with patch.object(PageNumberPagination, "page_size", 2):
            first = self._history()["results"]
            second = self._history(page=2)["results"]
            third = self._history(page=3)["results"]
            total = self._history()["count"]

        self.assertEqual(total, 6)
        self.assertEqual([len(first), len(second), len(third)], [2, 2, 2])
        seen = data_costs(first + second + third)
        self.assertEqual(len(set(seen)), 6, f"a row was served twice: {seen}")
        # The opening was posted last, so it heads the merged list — and it
        # must head it on page ONE, not appear again on a later page.
        self.assertEqual(seen, ["10.00", "5.00", "4.00", "3.00", "2.00", "1.00"])

    def test_variant_history_is_scoped_to_its_own_variant(self):
        other = ProductVariant.objects.create(
            product=self.product,
            name="آخر",
            sku="OC-2",
            unit_price=Decimal("10"),
        )
        self._open("5", "2.00")
        open_stock_balance(
            variant=other,
            quantity=Decimal("3"),
            unit_cost=Decimal("9.00"),
            warehouse=self.warehouse,
            user=self.user,
        )

        response = self.client.get(
            reverse("purchaseorder-variant-cost-history"),
            {"variant": self.variant.pk},
        )

        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.data["count"], 1)
        self.assertEqual(
            response.data["results"][0]["effective_base_unit_cost"], "2.00"
        )

    # ------------------------------------------------------------------
    # Margin impact
    # ------------------------------------------------------------------

    def _margin(self):
        response = self.client.get(
            reverse("purchaseorder-variant-margin-impact"),
            {"variant": self.variant.pk},
        )
        self.assertEqual(response.status_code, 200, response.content[:300])
        return response.data

    def test_margin_is_computed_from_an_opening_when_that_is_all_there_is(self):
        """This block sits directly under the cost overview. While it read
        purchase lines alone, the same screen showed "12.50" above "not
        specified" for the same variant."""
        self._open("15", "7.50")

        row = self._margin()

        self.assertEqual(row["latest_effective_unit_cost"], "7.50")
        # unit_price is 10 in this fixture.
        self.assertEqual(row["latest_margin_amount"], "2.50")
        self.assertEqual(row["latest_margin_percent"], "25.00")
        # An opening balance is not a purchase order line, and must not be
        # served as one — a client following the id would land on a stranger.
        self.assertIsNone(row["latest_purchase_line"])

    def test_a_newer_purchase_still_wins_the_margin(self):
        self._open("15", "7.50")
        line = self._buy("6.00")

        row = self._margin()

        self.assertEqual(row["latest_effective_unit_cost"], "6.00")
        self.assertEqual(row["latest_purchase_line"], line.pk)
        # The opening is the one it moved from.
        self.assertEqual(row["previous_effective_unit_cost"], "7.50")
        self.assertEqual(row["effective_unit_cost_delta"], "-1.50")

    def test_a_newer_opening_displaces_the_newest_purchase(self):
        self._buy("6.00")
        self._open("15", "7.50")

        row = self._margin()

        self.assertEqual(row["latest_effective_unit_cost"], "7.50")
        self.assertEqual(row["previous_effective_unit_cost"], "6.00")

    def test_margin_with_no_cost_event_at_all_is_still_empty(self):
        row = self._margin()

        self.assertIsNone(row["latest_effective_unit_cost"])
        self.assertIsNone(row["latest_margin_amount"])

    def test_history_without_any_opening_is_unchanged(self):
        self._buy("4.00")

        data = self._history()

        self.assertEqual(data["count"], 1)
        self.assertEqual(data["results"][0]["source"], "purchase")


def data_costs(rows):
    return [row["effective_base_unit_cost"] for row in rows]
