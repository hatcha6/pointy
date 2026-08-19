"""The discounts list must not cross-join a rule's two usage relations.

``DiscountRuleViewSet`` reports ``redemption_count`` and ``applied_count``.
Annotating both as joined aggregates in one query makes the database
materialise every (redemption x applied_discount) pair per rule, so the work
grows quadratically with how much a rule has been used — and ``AppliedDiscount``
gains a row for every discounted line ever sold. The query *count* is identical
either way, so only the plan can catch a regression here.
"""

import re
from decimal import Decimal

from django.db import connection
from django.test import TestCase

from .models import AppliedDiscount, DiscountRedemption, DiscountRule
from .views import DiscountRuleViewSet

RULES = 8


def _seed(rules, usage_per_rule):
    DiscountRedemption.objects.all().delete()
    AppliedDiscount.objects.all().delete()
    DiscountRule.objects.all().delete()
    for index in range(rules):
        rule = DiscountRule.objects.create(
            name=f"Rule {index}",
            channel=DiscountRule.Channel.SALES,
            scope=DiscountRule.Scope.DOCUMENT,
            value_type=DiscountRule.ValueType.PERCENTAGE,
            value=Decimal("10.0000"),
        )
        AppliedDiscount.objects.bulk_create(
            [
                AppliedDiscount(
                    rule=rule,
                    rule_name=rule.name,
                    channel=rule.channel,
                    scope=rule.scope,
                    value_type=rule.value_type,
                    value=rule.value,
                    discount_amount=Decimal("1.00"),
                )
                for _ in range(usage_per_rule)
            ]
        )
        DiscountRedemption.objects.bulk_create(
            [
                DiscountRedemption(
                    rule=rule,
                    channel=rule.channel,
                    discount_amount=Decimal("1.00"),
                )
                for _ in range(usage_per_rule)
            ]
        )


def _list_queryset():
    view = DiscountRuleViewSet()
    view.request = None
    view.format_kwarg = None
    return view.get_queryset()


def _peak_rows_scanned(queryset):
    """Largest ``rows=`` any node in the plan actually produced."""
    sql, params = queryset.query.sql_with_params()
    with connection.cursor() as cursor:
        cursor.execute("EXPLAIN (ANALYZE) " + sql, params)
        plan = "\n".join(row[0] for row in cursor.fetchall())
    produced = [int(value) for value in re.findall(r"\(actual time=[\d.]+\.\.[\d.]+ rows=(\d+)", plan)]
    assert produced, plan
    return max(produced)


class DiscountRuleUsageCountValueTests(TestCase):
    def test_counts_match_a_direct_per_rule_count(self):
        _seed(rules=3, usage_per_rule=4)
        # A rule nobody has ever used must still report 0, not be dropped: the
        # old LEFT JOIN produced 0, and Coalesce keeps the subquery agreeing.
        DiscountRule.objects.create(
            name="Never used",
            channel=DiscountRule.Channel.SALES,
            scope=DiscountRule.Scope.DOCUMENT,
            value_type=DiscountRule.ValueType.PERCENTAGE,
            value=Decimal("5.0000"),
        )
        # Give one rule an uneven split so a swapped pair of annotations shows.
        lopsided = DiscountRule.objects.order_by("id").first()
        AppliedDiscount.objects.create(
            rule=lopsided,
            rule_name=lopsided.name,
            channel=lopsided.channel,
            scope=lopsided.scope,
            value_type=lopsided.value_type,
            value=lopsided.value,
            discount_amount=Decimal("1.00"),
        )

        rows = list(_list_queryset())
        self.assertEqual(len(rows), 4)
        for rule in rows:
            self.assertEqual(
                rule.redemption_count,
                DiscountRedemption.objects.filter(rule=rule).count(),
                rule.name,
            )
            self.assertEqual(
                rule.applied_count,
                AppliedDiscount.objects.filter(rule=rule).count(),
                rule.name,
            )
        self.assertEqual(lopsided.pk, rows[0].pk)
        self.assertEqual((rows[0].redemption_count, rows[0].applied_count), (4, 5))


class DiscountRuleUsageCountScalingTests(TestCase):
    def test_rows_scanned_stay_linear_in_rule_usage(self):
        if connection.vendor != "postgresql":
            self.skipTest("Plan row counts are measured on the real database.")

        _seed(rules=RULES, usage_per_rule=15)
        single = _peak_rows_scanned(_list_queryset())

        _seed(rules=RULES, usage_per_rule=30)
        double = _peak_rows_scanned(_list_queryset())

        # Doubling each rule's usage doubles the work when the two counts are
        # independent subqueries. Joining them in one query instead squares it:
        # 8x15x15 = 1800 rows -> 8x30x30 = 7200, a 4x jump. Anything at or above
        # a 3x growth factor means the cross product is back.
        self.assertLess(
            double,
            single * 3,
            f"usage counts scale super-linearly: {single} -> {double} rows scanned",
        )
