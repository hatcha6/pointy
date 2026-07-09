"""Query-count regression guard for the discount engine.

The engine must stay O(1) in queries: it must not issue work proportional to the
number of discount rules (usage-limit counts are folded into the rules query as
annotations; category-descendant recursion is memoised) nor to the number of
cart lines (line matching is done in Python over prefetched data). A basket with
50 active rules and 50 lines pricing at checkout must cost the same handful of
queries as one rule and one line — see the benchmark table in the commit that
added this. Without the guard an innocent `rule.<relation>.count()` in the hot
loop would quietly reintroduce an N+1 that only bites shops with many rules.
"""

from decimal import Decimal

from django.db import connection
from django.test import TestCase
from django.test.utils import CaptureQueriesContext

from apps.catalog.models import Product, ProductCategory, ProductVariant
from apps.discounts.models import DiscountRule
from apps.discounts.services import DiscountContext, DiscountEngine, DiscountLineInput


class EngineQueryScalingTest(TestCase):
    @classmethod
    def setUpTestData(cls):
        cls.root = ProductCategory.objects.create(name="root")
        # a little depth so the descendant recursion actually runs
        cls.child = ProductCategory.objects.create(name="child", parent=cls.root)
        cls.product = Product.objects.create(name="p")
        cls.product.categories.add(cls.child)
        cls.variant = ProductVariant.objects.create(
            product=cls.product, sku="sku-1", unit_price=Decimal("10.00")
        )

    def _make_rules(self, m):
        for i in range(m):
            rule = DiscountRule.objects.create(
                name=f"rule-{i}",
                channel=DiscountRule.Channel.SALES,
                application_type=DiscountRule.ApplicationType.AUTOMATIC,
                scope=DiscountRule.Scope.DOCUMENT,
                value_type=DiscountRule.ValueType.PERCENTAGE,
                value=Decimal("1.00"),
                exclusive=False,
                is_active=True,
                usage_limit=100000,  # exercises the redemption-count path
            )
            rule.product_categories.add(self.root)  # exercises category recursion

    def _context(self, n):
        lines = tuple(
            DiscountLineInput(
                key=str(k),
                product_id=self.product.pk,
                variant_id=self.variant.pk,
                quantity=1,
                unit_amount=Decimal("10.00"),
                category_ids=(self.child.pk,),
            )
            for k in range(n)
        )
        return DiscountContext(channel=DiscountRule.Channel.SALES, lines=lines)

    def _count_queries(self, context):
        with CaptureQueriesContext(connection) as captured:
            DiscountEngine().calculate(context)
        return len(captured)

    def test_query_count_is_flat_in_rule_count(self):
        self._make_rules(1)
        one_rule = self._count_queries(self._context(5))
        DiscountRule.objects.all().delete()
        self._make_rules(50)
        fifty_rules = self._count_queries(self._context(5))
        # allow a tiny slack for one extra distinct-category resolution, but it
        # must NOT grow ~linearly (pre-optimisation this was 12 vs 257).
        self.assertLessEqual(
            fifty_rules,
            one_rule + 2,
            f"engine query count grew with rule count: 1 rule={one_rule}, "
            f"50 rules={fifty_rules} (expected ~flat)",
        )

    def test_query_count_is_flat_in_cart_lines(self):
        self._make_rules(5)
        one_line = self._count_queries(self._context(1))
        fifty_lines = self._count_queries(self._context(50))
        self.assertEqual(
            one_line,
            fifty_lines,
            f"engine query count grew with cart lines: 1 line={one_line}, "
            f"50 lines={fifty_lines} (expected identical)",
        )
