"""The reorder queue and the draft it creates, through the endpoints.

What matters most here is what stays off the list: an unwatched variant, a
healthy one, and one whose incoming order already covers the week. The queue is
only useful while it is short enough to act on.
"""

from datetime import timedelta
from decimal import Decimal

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group
from django.db import connection
from django.test import TestCase
from django.test.utils import CaptureQueriesContext
from django.urls import reverse
from django.utils import timezone
from rest_framework import status
from rest_framework.test import APIClient

from apps.catalog.models import ProductVariant
from apps.catalog.testing import create_product_with_default_variant
from apps.core.roles import MANAGER_GROUP, ensure_role_groups
from apps.inventory.models import StockItem, Warehouse
from apps.sales.models import Order, OrderLine

from .models import PurchaseLine, PurchaseOrder, Supplier
from .reorder import QUEUE_LIMIT, order_quantity, piece_margin


class ReorderTestCase(TestCase):
    def setUp(self):
        ensure_role_groups()
        self.user = get_user_model().objects.create_user(username="buyer", password="pw")
        self.user.groups.add(Group.objects.get(name=MANAGER_GROUP))
        self.client = APIClient()
        self.client.force_authenticate(user=self.user)
        self.store = Warehouse.objects.create(name="المحل", code="reorder-store")
        self.supplier = Supplier.objects.create(name="مورد أ")
        self.queue_url = reverse("purchaseorder-reorder-queue")
        self.create_url = reverse("purchaseorder-create-from-reorder")

    def variant(self, sku, *, on_hand, threshold, expected="0"):
        product = create_product_with_default_variant(
            name=f"صنف {sku}", sku=sku, unit_price="10", low_stock_threshold=threshold
        )
        variant = product.default_variant
        StockItem.objects.create(
            variant=variant,
            warehouse=self.store,
            quantity_on_hand=Decimal(str(on_hand)),
            quantity_expected=Decimal(str(expected)),
        )
        return variant

    def sold(self, variant, quantity, *, days_ago=3):
        order = Order.objects.create(
            sale_type=Order.SaleType.STANDARD, status=Order.Status.PAID
        )
        Order.objects.filter(pk=order.pk).update(
            created_at=timezone.now() - timedelta(days=days_ago)
        )
        OrderLine.objects.create(
            order=order,
            variant=variant,
            quantity=Decimal(str(quantity)),
            unit_price=Decimal("10"),
        )

    def bought(self, variant, supplier=None, *, unit_cost="4", unit_factor="1", state=None):
        order = PurchaseOrder.objects.create(
            supplier=supplier or self.supplier,
            status=state or PurchaseOrder.Status.SUBMITTED,
        )
        return PurchaseLine.objects.create(
            purchase_order=order,
            variant=variant,
            quantity=Decimal("1"),
            unit_factor=Decimal(unit_factor),
            unit_cost=Decimal(unit_cost),
        )

    def queue(self, **params):
        response = self.client.get(self.queue_url, params)
        self.assertEqual(response.status_code, status.HTTP_200_OK, response.data)
        return response.data["results"]

    def statuses(self, **params):
        return {row["sku"]: row["status"] for row in self.queue(**params)}


class QueueMembershipTests(ReorderTestCase):
    def test_at_or_below_the_threshold_is_listed_and_a_blank_threshold_never_is(self):
        self.variant("OUT", on_hand=0, threshold=5)
        self.variant("LOW", on_hand=5, threshold=5)
        self.variant("HEALTHY", on_hand=50, threshold=5)
        unwatched = create_product_with_default_variant(
            name="بلا حد", sku="BLANK", unit_price="10"
        ).default_variant
        StockItem.objects.create(
            variant=unwatched, warehouse=self.store, quantity_on_hand=Decimal("0")
        )

        self.assertEqual(self.statuses(), {"OUT": "out", "LOW": "low"})

    def test_a_piece_or_two_above_counts_as_approaching_without_any_sales(self):
        self.variant("NEAR", on_hand=6, threshold=5)
        self.variant("FAR", on_hand=8, threshold=5)

        self.assertEqual(self.statuses(), {"NEAR": "approaching"})

    def test_a_fast_seller_is_approaching_from_much_further_away(self):
        fast = self.variant("FAST", on_hand=30, threshold=5)
        slow = self.variant("SLOW", on_hand=30, threshold=5)
        self.sold(fast, 120)  # 30 a week: exactly the 25 it has to spare, and more.
        self.sold(slow, 4)

        rows = {row["sku"]: row for row in self.queue()}

        self.assertEqual(set(rows), {"FAST"})
        self.assertEqual(rows["FAST"]["status"], "approaching")
        self.assertEqual(rows["FAST"]["days_left"], 5)

    def test_sales_outside_the_window_are_not_demand(self):
        variant = self.variant("OLD", on_hand=30, threshold=5)
        self.sold(variant, 500, days_ago=60)

        self.assertEqual(self.statuses(), {})

    def test_incoming_stock_that_covers_the_margin_is_nothing_to_act_on(self):
        self.variant("COVERED", on_hand=6, threshold=5, expected=20)

        self.assertEqual(self.statuses(), {})

    def test_incoming_stock_never_hides_a_row_already_at_the_threshold(self):
        self.variant("COMING", on_hand=2, threshold=5, expected=20)

        self.assertEqual(self.statuses(), {"COMING": "low"})

    def test_switching_approaching_off_leaves_exactly_at_or_below(self):
        self.variant("LOW", on_hand=4, threshold=5)
        self.variant("NEAR", on_hand=6, threshold=5)

        self.assertEqual(self.statuses(approaching="false"), {"LOW": "low"})

    def test_each_variant_of_a_product_is_judged_on_its_own(self):
        healthy = self.variant("RED", on_hand=50, threshold=5)
        empty = ProductVariant.objects.create(
            product=healthy.product,
            name="أزرق",
            sku="BLUE",
            unit_price=Decimal("10"),
            low_stock_threshold=Decimal("5"),
        )
        StockItem.objects.create(
            variant=empty, warehouse=self.store, quantity_on_hand=Decimal("1")
        )

        rows = self.queue()

        self.assertEqual([row["sku"] for row in rows], ["BLUE"])
        self.assertEqual(rows[0]["variant_name"], "أزرق")

    def test_most_urgent_first_and_the_faster_seller_first_within_a_kind(self):
        self.variant("NEAR", on_hand=6, threshold=5)
        self.sold(self.variant("LOW-SLOW", on_hand=3, threshold=5), 4)
        self.sold(self.variant("LOW-FAST", on_hand=3, threshold=5), 40)
        self.variant("OUT", on_hand=0, threshold=5)

        self.assertEqual(
            [row["sku"] for row in self.queue()],
            ["OUT", "LOW-FAST", "LOW-SLOW", "NEAR"],
        )


class QueueSupplierTests(ReorderTestCase):
    def test_a_supplier_narrows_to_products_on_their_orders(self):
        mine = self.variant("MINE", on_hand=0, threshold=5)
        theirs = self.variant("THEIRS", on_hand=0, threshold=5)
        self.variant("NOBODY", on_hand=0, threshold=5)
        self.bought(mine)
        self.bought(theirs, Supplier.objects.create(name="مورد ب"))

        self.assertEqual(self.statuses(supplier=self.supplier.pk), {"MINE": "out"})

    def test_a_cancelled_order_does_not_make_a_supplier_of_anyone(self):
        variant = self.variant("X", on_hand=0, threshold=5)
        self.bought(variant, state=PurchaseOrder.Status.CANCELLED)

        self.assertEqual(self.statuses(supplier=self.supplier.pk), {})

    def test_the_row_names_who_it_was_last_bought_from(self):
        variant = self.variant("X", on_hand=0, threshold=5)
        self.bought(variant, Supplier.objects.create(name="قديم"))
        self.bought(variant)

        row = self.queue()[0]

        self.assertEqual(row["last_supplier"], self.supplier.pk)
        self.assertEqual(row["last_supplier_name"], "مورد أ")

    def test_quantity_on_a_draft_order_is_reported_and_does_not_count_as_coming(self):
        variant = self.variant("X", on_hand=2, threshold=5)
        self.bought(variant, state=PurchaseOrder.Status.DRAFT, unit_factor="6")

        row = self.queue()[0]

        self.assertEqual(row["in_draft"], Decimal("6"))
        self.assertEqual(row["order_quantity"], Decimal("8"))

    def test_a_malformed_supplier_is_refused(self):
        response = self.client.get(self.queue_url, {"supplier": "abc"})

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)


class RulesTests(TestCase):
    def test_the_fixed_margin_stays_between_one_and_two(self):
        self.assertEqual(piece_margin(Decimal("0")), Decimal("1"))
        self.assertEqual(piece_margin(Decimal("8")), Decimal("1.6"))
        self.assertEqual(piece_margin(Decimal("500")), Decimal("2"))

    def quantity(self, on_hand, expected, threshold, weekly_demand):
        return order_quantity(
            on_hand=Decimal(on_hand),
            expected=Decimal(expected),
            threshold=Decimal(threshold),
            weekly_demand=Decimal(weekly_demand),
        )

    def test_the_quantity_returns_to_twice_the_threshold_for_a_slow_seller(self):
        self.assertEqual(self.quantity("3", "0", "5", "1"), Decimal("7"))

    def test_the_quantity_covers_a_week_of_sales_for_a_fast_one(self):
        self.assertEqual(self.quantity("3", "0", "5", "30"), Decimal("32"))

    def test_the_quantity_counts_what_is_on_the_way(self):
        self.assertEqual(self.quantity("3", "4", "5", "0"), Decimal("3"))

    def test_the_quantity_rounds_up_and_is_never_nothing(self):
        self.assertEqual(self.quantity("1.2", "0", "1.5", "0"), Decimal("2"))
        self.assertEqual(self.quantity("3", "50", "5", "0"), Decimal("1"))


class CreateFromReorderTests(ReorderTestCase):
    def create(self, lines, supplier=None):
        return self.client.post(
            self.create_url,
            {"supplier": (supplier or self.supplier).pk, "lines": lines},
            format="json",
        )

    def test_it_creates_a_draft_for_that_supplier_with_the_quantities_sent(self):
        first = self.variant("A", on_hand=1, threshold=5)
        second = self.variant("B", on_hand=2, threshold=5)

        response = self.create(
            [
                {"variant": first.pk, "quantity": "12"},
                {"variant": second.pk, "quantity": "3"},
            ]
        )

        self.assertEqual(response.status_code, status.HTTP_201_CREATED, response.data)
        order = PurchaseOrder.objects.get(pk=response.data["id"])
        self.assertEqual(order.supplier, self.supplier)
        self.assertEqual(order.status, PurchaseOrder.Status.DRAFT)
        self.assertEqual(
            {line.variant_id: line.quantity for line in order.lines.all()},
            {first.pk: Decimal("12"), second.pk: Decimal("3")},
        )

    def test_a_draft_moves_no_stock(self):
        variant = self.variant("A", on_hand=1, threshold=5)

        self.create([{"variant": variant.pk, "quantity": "12"}])

        item = StockItem.objects.get(variant=variant)
        self.assertEqual(item.quantity_on_hand, Decimal("1"))
        self.assertEqual(item.quantity_expected, Decimal("0"))

    def test_the_cost_is_this_suppliers_last_per_base_unit(self):
        variant = self.variant("A", on_hand=1, threshold=5)
        self.bought(variant, unit_cost="120", unit_factor="24")
        self.bought(variant, Supplier.objects.create(name="أحدث"), unit_cost="9")

        response = self.create([{"variant": variant.pk, "quantity": "2"}])

        line = PurchaseOrder.objects.get(pk=response.data["id"]).lines.get()
        self.assertEqual(line.unit_cost, Decimal("5"))
        self.assertEqual(line.unit_factor, Decimal("1"))

    def test_with_no_history_from_this_supplier_it_falls_back_to_anybodys(self):
        variant = self.variant("A", on_hand=1, threshold=5)
        self.bought(variant, Supplier.objects.create(name="آخر"), unit_cost="9")

        response = self.create([{"variant": variant.pk, "quantity": "2"}])

        line = PurchaseOrder.objects.get(pk=response.data["id"]).lines.get()
        self.assertEqual(line.unit_cost, Decimal("9"))

    def test_a_variant_never_bought_starts_at_zero_for_the_buyer_to_fill_in(self):
        variant = self.variant("A", on_hand=1, threshold=5)

        response = self.create([{"variant": variant.pk, "quantity": "2"}])

        self.assertEqual(response.status_code, status.HTTP_201_CREATED, response.data)
        line = PurchaseOrder.objects.get(pk=response.data["id"]).lines.get()
        self.assertEqual(line.unit_cost, Decimal("0"))

    def test_a_cost_far_above_the_sale_price_does_not_stop_the_draft(self):
        variant = self.variant("A", on_hand=1, threshold=5)
        self.bought(variant, unit_cost="900")

        response = self.create([{"variant": variant.pk, "quantity": "1"}])

        self.assertEqual(response.status_code, status.HTTP_201_CREATED, response.data)

    def test_it_refuses_nothing_to_order_a_repeat_and_a_zero_quantity(self):
        variant = self.variant("A", on_hand=1, threshold=5)
        line = {"variant": variant.pk, "quantity": "1"}

        for lines in ([], [line, line], [{"variant": variant.pk, "quantity": "0"}]):
            response = self.create(lines)
            self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertFalse(PurchaseOrder.objects.exists())

    def test_an_unknown_supplier_or_variant_is_refused(self):
        variant = self.variant("A", on_hand=1, threshold=5)

        for payload in (
            {"supplier": 999999, "lines": [{"variant": variant.pk, "quantity": "1"}]},
            {"supplier": self.supplier.pk, "lines": [{"variant": 999999, "quantity": "1"}]},
        ):
            response = self.client.post(self.create_url, payload, format="json")
            self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertFalse(PurchaseOrder.objects.exists())

    def test_a_retry_with_the_same_key_makes_one_order(self):
        variant = self.variant("A", on_hand=1, threshold=5)
        body = {
            "supplier": self.supplier.pk,
            "lines": [{"variant": variant.pk, "quantity": "2"}],
        }

        first, second = (
            self.client.post(
                self.create_url, body, format="json", HTTP_IDEMPOTENCY_KEY="reorder-1"
            )
            for _ in range(2)
        )

        self.assertEqual(first.data["id"], second.data["id"])
        self.assertEqual(PurchaseOrder.objects.count(), 1)


class PermissionTests(ReorderTestCase):
    def test_both_endpoints_need_the_right_to_draft_an_order(self):
        client = APIClient()
        client.force_authenticate(
            user=get_user_model().objects.create_user(username="nobody", password="pw")
        )

        self.assertEqual(client.get(self.queue_url).status_code, status.HTTP_403_FORBIDDEN)
        self.assertEqual(
            client.post(self.create_url, {}, format="json").status_code,
            status.HTTP_403_FORBIDDEN,
        )


class QueueScalingTests(ReorderTestCase):
    def queries(self):
        with CaptureQueriesContext(connection) as captured:
            self.queue()
        return len(captured)

    def test_more_rows_cost_no_more_queries(self):
        self.variant("A", on_hand=0, threshold=5)
        self.queries()  # The first request also reads the user's permissions.
        baseline = self.queries()

        for index in range(10):
            self.bought(self.variant(f"V{index}", on_hand=0, threshold=5))

        self.assertEqual(self.queries(), baseline)


class QueueLimitTests(ReorderTestCase):
    def test_the_count_says_how_many_there_were_before_the_cap(self):
        self.variant("A", on_hand=0, threshold=5)

        response = self.client.get(self.queue_url)

        self.assertEqual(response.data["count"], 1)
        self.assertGreater(QUEUE_LIMIT, 1)
