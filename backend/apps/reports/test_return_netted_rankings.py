"""What a shop reorders must be ranked on what it actually sold.

The shop-wide totals net refunds out — a voided sale leaves ``net_sales`` and
``gross_profit`` at 0.00 (``test_gross_profit_conservation``). Every *ranking*
built from the very same order lines used to stop at what was rung up: "top
products", "top variants" and the report's ``top_products`` section credited a
wholly voided sale in full, so the product the shop never sold sat at the head
of the list directly beneath a net sales figure of zero. ``items_sold`` had the
same shape — "5 items sold" next to "0.00 net sales" on one summary block.

The netting is exact rather than approximate: ``OrderAdjustmentLine`` snapshots
the sale line's own ``unit_price`` and its share of ``discount_total``, and
takes cost from ``order_line__unit_cost``, so both sides state the same
arithmetic over the same columns and a line handed back in full cancels its own
sale term for term.
"""

from datetime import date, timedelta
from decimal import Decimal

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group
from django.core.cache import cache
from django.test import TestCase, override_settings
from django.urls import reverse
from rest_framework import status
from rest_framework.test import APIClient

from apps.catalog.testing import create_product_with_default_variant
from apps.core.roles import MANAGER_GROUP, ensure_role_groups
from apps.inventory.models import StockItem
from apps.reports.services import generate_report_payload
from apps.sales.models import Order, OrderLine


@override_settings(
    CACHES={
        "default": {
            "BACKEND": "django.core.cache.backends.locmem.LocMemCache",
            "LOCATION": "return-netted-ranking-tests",
        }
    }
)
class ReturnNettedRankingTests(TestCase):
    def setUp(self):
        # Dashboard sections are cached under a key that names neither the
        # database nor the test, so a sibling's payload is served to this one
        # unless the cache is isolated and emptied.
        cache.clear()
        ensure_role_groups()
        User = get_user_model()
        self.manager = User.objects.create_user(
            username="ranking-manager", password="pass"
        )
        self.manager.groups.add(Group.objects.get(name=MANAGER_GROUP))
        self.big = self._product("BIG-1", "Big seller", Decimal("10.00"))
        self.small = self._product("SMALL-1", "Small seller", Decimal("9.00"))
        self.client = APIClient()
        self.client.force_authenticate(user=self.manager)
        self.client.post(
            reverse("register-session-start"),
            {"opening_cash": "0.00"},
            format="json",
        )

    def _product(self, sku, name, unit_price):
        product = create_product_with_default_variant(
            sku=sku, barcode="", name=name, unit_price=unit_price
        )
        variant = product.default_variant
        StockItem.objects.create(variant=variant, quantity_on_hand=Decimal("500"))
        return variant

    def _sell(self, variant, quantity, unit_cost):
        response = self.client.post(
            reverse("order-checkout"),
            {"lines": [{"variant": variant.pk, "quantity": str(quantity)}]},
            format="json",
        )
        self.assertEqual(response.status_code, status.HTTP_201_CREATED)
        order_id = response.data["id"]
        # The cost basis a purchase would have snapshotted. Set directly so the
        # test is about the rollup's arithmetic, not about how cost got there.
        OrderLine.objects.filter(order_id=order_id).update(unit_cost=unit_cost)
        return order_id, response.data["lines"][0]["id"]

    def _void(self, order_id):
        response = self.client.post(
            reverse("order-void", args=[order_id]),
            {"reason": "ranking"},
            format="json",
        )
        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(Order.objects.get(pk=order_id).status, Order.Status.VOID)

    def _return(self, order_id, line_id, quantity):
        response = self.client.post(
            reverse("order-return-items", args=[order_id]),
            {"reason": "ranking", "lines": [{"line": line_id, "quantity": quantity}]},
            format="json",
        )
        self.assertEqual(response.status_code, status.HTTP_200_OK)

    # -- the two surfaces ---------------------------------------------------

    def _report(self):
        params = {
            "start_date": (date.today() - timedelta(days=1)).isoformat(),
            "end_date": (date.today() + timedelta(days=1)).isoformat(),
        }
        return generate_report_payload(
            report_type="sales_summary", params=params, user=self.manager
        )

    def _report_top_products(self):
        for section in self._report()["sections"]:
            if section["key"] == "top_products":
                return section["rows"]
        self.fail("sales_summary has no top_products section")

    def _dashboard(self):
        cache.clear()
        response = self.client.get(reverse("dashboard"), {"sections": "sales"})
        self.assertEqual(response.status_code, status.HTTP_200_OK)
        return response.data["sections"]["sales"]

    def _row(self, rows, name):
        for row in rows:
            if row["product_name"] == name:
                return row
        self.fail(f"no row for {name} in {rows}")

    # -- non-vacuity --------------------------------------------------------

    def test_a_standing_sale_is_stated_in_full(self):
        """Everything below has to reach the *sale* first, not merely reach
        zero once it is gone: a ranking that always answered 0.00 would pass
        every netting assertion here."""
        self._sell(self.big, 5, Decimal("4.00"))
        row = self._row(self._report_top_products(), "Big seller")
        self.assertEqual(row["quantity"], "5")
        self.assertEqual(row["revenue"], "50.00")
        self.assertEqual(row["profit"], "30.00")
        self.assertEqual(self._report()["summary"]["items_sold"], "5")

    # -- a voided sale ------------------------------------------------------

    def test_report_top_products_drops_a_voided_sale(self):
        order_id, _ = self._sell(self.big, 5, Decimal("4.00"))
        self._void(order_id)
        row = self._row(self._report_top_products(), "Big seller")
        self.assertEqual(row["quantity"], "0")
        self.assertEqual(row["revenue"], "0.00")
        self.assertEqual(row["profit"], "0.00")

    def test_report_items_sold_drops_a_voided_sale(self):
        order_id, _ = self._sell(self.big, 5, Decimal("4.00"))
        self._void(order_id)
        summary = self._report()["summary"]
        # The figure this sat next to all along.
        self.assertEqual(summary["net_sales"], "0.00")
        self.assertEqual(summary["items_sold"], "0")

    def test_dashboard_product_ranking_drops_a_voided_sale(self):
        order_id, _ = self._sell(self.big, 5, Decimal("4.00"))
        self._void(order_id)
        sales = self._dashboard()
        for rows in (
            sales["top_products"],
            sales["reports"]["products"]["revenue"],
            sales["reports"]["products"]["profit"],
            sales["reports"]["products"]["top_sold"],
        ):
            row = self._row(rows, "Big seller")
            self.assertEqual(row["quantity"], Decimal("0"))
            self.assertEqual(row["revenue"], "0.00")
            self.assertEqual(row["profit"], "0.00")
        self.assertEqual(sales["summary"]["items_sold"], Decimal("0"))

    def test_dashboard_variant_ranking_drops_a_voided_sale(self):
        order_id, _ = self._sell(self.big, 5, Decimal("4.00"))
        self._void(order_id)
        row = self._row(
            self._dashboard()["reports"]["variants"]["revenue"], "Big seller"
        )
        self.assertEqual(row["quantity"], Decimal("0"))
        self.assertEqual(row["revenue"], "0.00")
        self.assertEqual(row["profit"], "0.00")

    # -- a partial return ---------------------------------------------------

    def test_a_partial_return_takes_off_exactly_its_share(self):
        order_id, line_id = self._sell(self.big, 5, Decimal("4.00"))
        self._return(order_id, line_id, 2)
        row = self._row(self._report_top_products(), "Big seller")
        self.assertEqual(row["quantity"], "3")
        self.assertEqual(row["revenue"], "30.00")
        self.assertEqual(row["profit"], "18.00")
        self.assertEqual(self._report()["summary"]["items_sold"], "3")

    # -- the ranking itself -------------------------------------------------

    def test_the_ranking_reorders_once_returns_are_taken_off(self):
        """The sharpest form of the defect, and the one a shop acts on.

        100.00 sold and handed back in full is not a better seller than 90.00
        sold and kept — but ranked on the gross it came first, so the buyer
        reordered goods the shop had returned every one of.
        """
        order_id, _ = self._sell(self.big, 10, Decimal("4.00"))
        self._sell(self.small, 10, Decimal("4.00"))
        self.assertEqual(
            [row["product_name"] for row in self._report_top_products()],
            ["Big seller", "Small seller"],
        )
        self._void(order_id)
        self.assertEqual(
            [row["product_name"] for row in self._report_top_products()],
            ["Small seller", "Big seller"],
        )
        self.assertEqual(
            [
                row["product_name"]
                for row in self._dashboard()["reports"]["products"]["revenue"]
            ],
            ["Small seller", "Big seller"],
        )

    def test_a_product_returned_in_full_cancels_to_the_cent(self):
        """Conservation, stated without reference to any rounding convention.

        0.750 at 5.50 is a gross of 4.1250 and a cost of 3.33 × 0.750 = 2.4975 —
        neither lands on a cent, which is the only shape in which a rollup can
        leave a residue behind. Sold and handed back whole, the row must be
        exactly nothing, not a cent of either.
        """
        weighed = self._product("WGT-1", "Weighed goods", Decimal("5.50"))
        order_id, _ = self._sell(weighed, Decimal("0.750"), Decimal("3.33"))
        self._void(order_id)
        row = self._row(self._report_top_products(), "Weighed goods")
        self.assertEqual(row["revenue"], "0.00")
        self.assertEqual(row["profit"], "0.00")
        self.assertEqual(row["quantity"], "0")
