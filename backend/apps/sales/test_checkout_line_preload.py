"""Regression tests: a cart's catalog reads must not scale with its line count.

Each line's modifier groups, units and (through the discount engine) categories
used to cost a query per line on the two busiest till endpoints — checkout and
the discount preview the POS fires on every cart edit — because DRF hands the
line a bare variant. ``CheckoutLineListSerializer`` bulk-loads the cart first.
The scaling tests bound the marginal cost per extra line; the rest prove the
preloaded and the cold path resolve a line identically.
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

from apps.catalog.models import (
    ModifierGroup,
    ModifierOption,
    ProductModifierGroup,
    ProductUnit,
    UnitOfMeasure,
)
from apps.catalog.testing import create_product_with_default_variant
from apps.core.roles import CASHIER_GROUP, ensure_role_groups
from apps.inventory.models import StockItem
from apps.sales.models import Order

# The only read that may still scale with the cart is DRF resolving each line's
# variant (``PrimaryKeyRelatedField`` does its own ``.get(pk=...)``); the
# product's units, modifier groups and categories must not. Checkout also still
# inserts the line, locks and updates stock, and writes the stock movement.
MAX_PREVIEW_QUERIES_PER_EXTRA_LINE = 1
MAX_CHECKOUT_QUERIES_PER_EXTRA_LINE = 5

CACHE_SETTINGS = {
    "default": {"BACKEND": "django.core.cache.backends.locmem.LocMemCache"}
}


def _till_client(username):
    ensure_role_groups()
    client = APIClient()
    user = get_user_model().objects.create_user(username=username, password="p")
    user.groups.add(Group.objects.get(name=CASHIER_GROUP))
    client.force_authenticate(user=user)
    client.post(
        reverse("register-session-start"), {"opening_cash": "0.00"}, format="json"
    )
    return client


@override_settings(CACHES=CACHE_SETTINGS)
class CheckoutLinePreloadScalingTests(TestCase):
    _seq = 0

    def setUp(self):
        self.client = _till_client("till")

    def _variants(self, count):
        variants = []
        for _ in range(count):
            CheckoutLinePreloadScalingTests._seq += 1
            i = CheckoutLinePreloadScalingTests._seq
            product = create_product_with_default_variant(
                name=f"pre{i}", sku=f"PRE{i}", unit_price="3.00", barcode=""
            )
            StockItem.objects.create(
                variant=product.default_variant, quantity_on_hand=Decimal("100")
            )
            variants.append(product.default_variant)
        return variants

    def _preview_query_count(self, line_count):
        variants = self._variants(line_count)
        url = reverse("order-discount-preview")

        def payload(quantity):
            return {"lines": [{"variant": v.pk, "quantity": quantity} for v in variants]}

        # Warm the per-request caches so the measured request is steady-state;
        # the second cart differs, so the preview memo cannot answer it.
        self.client.post(url, payload(1), format="json")
        with CaptureQueriesContext(connection) as ctx:
            response = self.client.post(url, payload(2), format="json")
        self.assertEqual(response.status_code, status.HTTP_200_OK, response.data)
        return len(ctx.captured_queries)

    def _checkout_query_count(self, line_count):
        variants = self._variants(line_count)
        self.client.get(reverse("order-list"))
        payload = {
            "lines": [{"variant": v.pk, "quantity": 1} for v in variants],
            "payment_method": "cash",
            "amount_received": f"{3 * line_count}.00",
        }
        with CaptureQueriesContext(connection) as ctx:
            response = self.client.post(reverse("order-checkout"), payload, format="json")
        self.assertEqual(response.status_code, status.HTTP_201_CREATED, response.data)
        return len(ctx.captured_queries)

    def test_discount_preview_barely_grows_with_the_cart(self):
        small, large = self._preview_query_count(3), self._preview_query_count(8)
        per_line = (large - small) / 5
        self.assertLessEqual(
            per_line,
            MAX_PREVIEW_QUERIES_PER_EXTRA_LINE,
            f"the discount preview does {per_line:.1f} queries per extra cart line "
            f"({small} at 3 lines, {large} at 8); a per-line catalog read was "
            "likely reintroduced.",
        )

    def test_checkout_marginal_cost_carries_no_catalog_reads(self):
        small, large = self._checkout_query_count(2), self._checkout_query_count(8)
        per_line = (large - small) / 6
        self.assertLessEqual(
            per_line,
            MAX_CHECKOUT_QUERIES_PER_EXTRA_LINE,
            f"checkout does {per_line:.1f} queries per extra line "
            f"({small} at 2 lines, {large} at 8); a per-line catalog read was "
            "likely reintroduced.",
        )

    def test_a_one_line_cart_does_not_pay_for_a_bulk_load(self):
        # A bulk load costs a handful of queries however small the cart, so the
        # commonest sale of all — a single scanned item — keeps the cold path.
        # Without that threshold this change is a regression, not a win.
        one_line, two_lines = self._preview_query_count(1), self._preview_query_count(2)
        self.assertLessEqual(
            one_line,
            two_lines,
            f"a one-line cart costs {one_line} queries and a two-line cart "
            f"{two_lines}: the one-line cart is paying for a bulk load.",
        )


@override_settings(CACHES=CACHE_SETTINGS)
class PreloadedCartResolvesLikeAColdCartTests(TestCase):
    """Preloaded instances are filtered in Python where the cold path filtered
    in SQL (modifier groups), and read a prefetch where it queried (units, base
    unit). A one-line cart stays cold, a two-line cart is preloaded, and both
    must answer the same."""

    def setUp(self):
        self.client = _till_client("mod")
        self.product = create_product_with_default_variant(
            sku="COFFEE-P", name="Coffee", unit_price=Decimal("3.50")
        )
        self.variant = self.product.default_variant
        StockItem.objects.create(variant=self.variant, quantity_on_hand=400)
        # Sold by the box as well as the piece, so resolve_unit has to read the
        # product's units (prefetched on the preloaded path).
        ProductUnit.objects.create(
            product=self.product,
            unit=UnitOfMeasure.objects.get(code="box"),
            factor_to_base=Decimal("12"),
        )
        self.milk = ModifierGroup.objects.create(name="Milk", min_select=1, max_select=1)
        self.whole = ModifierOption.objects.create(group=self.milk, name="Whole")
        self.extras = ModifierGroup.objects.create(name="Extras", min_select=0)
        self.extra_shot = ModifierOption.objects.create(
            group=self.extras, name="Extra shot", price_delta=Decimal("0.50"),
            max_quantity=3,
        )
        # Retired group: the cold path excluded it in SQL, the preloaded path in
        # Python. Its option must be refused and its min_select not enforced.
        self.retired = ModifierGroup.objects.create(
            name="Retired", min_select=1, max_select=1, is_active=False
        )
        self.retired_option = ModifierOption.objects.create(
            group=self.retired, name="Gone", price_delta=Decimal("9.00")
        )
        for order, group in enumerate((self.milk, self.extras, self.retired)):
            ProductModifierGroup.objects.create(
                product=self.product, group=group, display_order=order
            )
        self.filler = create_product_with_default_variant(
            sku="FILL-P", name="Filler", unit_price=Decimal("1.00")
        )
        StockItem.objects.create(variant=self.filler.default_variant, quantity_on_hand=400)

    def _coffee_line(self, modifiers=(), unit=""):
        line = {"variant": self.variant.pk, "quantity": 2, "modifiers": list(modifiers)}
        if unit:
            line["unit"] = unit
        return line

    def _filler_line(self):
        return {"variant": self.filler.default_variant.pk, "quantity": 1}

    def _checkout(self, lines, amount):
        return self.client.post(
            reverse("order-checkout"),
            {"lines": lines, "payment_method": "cash", "amount_received": amount},
            format="json",
        )

    def _coffee_line_of(self, response):
        order = Order.objects.get(pk=response.data["id"])
        return order.lines.get(variant=self.variant)

    def _assert_same_line(self, cold, warm):
        self.assertEqual(cold.status_code, status.HTTP_201_CREATED, cold.data)
        self.assertEqual(warm.status_code, status.HTTP_201_CREATED, warm.data)
        cold_line, warm_line = self._coffee_line_of(cold), self._coffee_line_of(warm)
        self.assertEqual(warm_line.unit, cold_line.unit)
        self.assertEqual(warm_line.unit_factor, cold_line.unit_factor)
        self.assertEqual(warm_line.unit_price, cold_line.unit_price)
        return cold_line, warm_line

    def test_modifier_pricing_matches_between_a_cold_and_a_preloaded_cart(self):
        modifiers = [
            {"option": self.whole.pk},
            {"option": self.extra_shot.pk, "quantity": 2},
        ]
        cold = self._checkout([self._coffee_line(modifiers)], amount="9.00")
        warm = self._checkout(
            [self._coffee_line(modifiers), self._filler_line()], amount="10.00"
        )
        cold_line, warm_line = self._assert_same_line(cold, warm)
        self.assertEqual(cold_line.unit_price, Decimal("4.50"))
        self.assertEqual(
            warm_line.modifiers.get(option_name="Extra shot").quantity,
            cold_line.modifiers.get(option_name="Extra shot").quantity,
        )

    def test_a_non_base_unit_prices_the_same_on_both_paths(self):
        boxed = self._coffee_line([{"option": self.whole.pk}], unit="box")
        cold = self._checkout([boxed], amount="84.00")
        warm = self._checkout([boxed, self._filler_line()], amount="85.00")
        cold_line, _ = self._assert_same_line(cold, warm)
        self.assertEqual(cold_line.unit, "box")

    def test_group_rules_still_hold_on_the_preloaded_path(self):
        # A retired group's option is not on offer...
        refused = self._checkout(
            [
                self._coffee_line(
                    [{"option": self.whole.pk}, {"option": self.retired_option.pk}]
                ),
                self._filler_line(),
            ],
            amount="100.00",
        )
        self.assertEqual(refused.status_code, status.HTTP_400_BAD_REQUEST)
        # ...and its min_select must not be enforced on an otherwise valid cart.
        accepted = self._checkout(
            [self._coffee_line([{"option": self.whole.pk}]), self._filler_line()],
            amount="8.00",
        )
        self.assertEqual(accepted.status_code, status.HTTP_201_CREATED, accepted.data)
        # An active group's min_select still is.
        missing_milk = self._checkout(
            [self._coffee_line([]), self._filler_line()], amount="100.00"
        )
        self.assertEqual(missing_milk.status_code, status.HTTP_400_BAD_REQUEST)
