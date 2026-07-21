from decimal import Decimal

from django.core.cache import cache
from django.db import connection
from django.test import TestCase, override_settings
from django.test.utils import CaptureQueriesContext

from apps.discounts.cache import preview_with_cache
from apps.discounts.models import DiscountRule
from apps.discounts.services import DiscountContext, DiscountEngine, DiscountLineInput

# Real (locmem) cache so hits actually hit — the configured django-redis backend
# has no Redis in tests, which would exercise only the fail-open path.
_LOCMEM = {
    "default": {
        "BACKEND": "django.core.cache.backends.locmem.LocMemCache",
        "LOCATION": "discount-preview-test",
    }
}


@override_settings(CACHES=_LOCMEM)
class PreviewCacheTest(TestCase):
    def setUp(self):
        cache.clear()
        self.context = DiscountContext(
            channel=DiscountRule.Channel.SALES,
            lines=(
                DiscountLineInput(
                    key="0",
                    product_id=1,
                    variant_id=1,
                    quantity=1,
                    unit_amount=Decimal("10.00"),
                ),
            ),
        )

    def _counting_compute(self, calls):
        def compute():
            calls.append(1)
            return DiscountEngine().calculate(self.context)

        return compute

    def test_no_active_rules_short_circuits_without_db_or_engine(self):
        calls = []
        compute = self._counting_compute(calls)
        preview_with_cache(self.context, compute)  # warms the gate
        with CaptureQueriesContext(connection) as captured:
            result = preview_with_cache(self.context, compute)
        self.assertEqual(calls, [], "engine ran despite no active rules")
        self.assertEqual(len(captured), 0, "hit the DB despite the cached gate")
        self.assertEqual(result.total, self.context.subtotal)
        self.assertEqual(result.applications, ())

    def test_result_cache_hit_then_signal_invalidates(self):
        rule = DiscountRule.objects.create(
            name="10pct",
            channel=DiscountRule.Channel.SALES,
            application_type=DiscountRule.ApplicationType.AUTOMATIC,
            scope=DiscountRule.Scope.DOCUMENT,
            value_type=DiscountRule.ValueType.PERCENTAGE,
            value=Decimal("10.00"),
            exclusive=False,
            is_active=True,
        )
        calls = []
        compute = self._counting_compute(calls)

        first = preview_with_cache(self.context, compute)  # miss -> compute
        second = preview_with_cache(self.context, compute)  # hit -> no compute
        self.assertEqual(len(calls), 1, "second identical preview recomputed")
        self.assertEqual(first.discount_total, second.discount_total)
        self.assertEqual(first.discount_total, Decimal("1.00"))  # 10% of 10.00

        # Editing the rule must invalidate via signal -> next preview recomputes.
        rule.value = Decimal("20.00")
        rule.save()
        third = preview_with_cache(self.context, compute)
        self.assertEqual(len(calls), 2, "rule edit did not invalidate the cache")
        self.assertEqual(third.discount_total, Decimal("2.00"))  # 20% now

    def test_engine_failure_degrades_to_an_undiscounted_preview(self):
        # An active rule so the no-rules gate doesn't short-circuit, then the
        # engine throws. The preview fires on every cart edit, so it must never
        # 500 — it degrades to the base totals with no discount shown.
        DiscountRule.objects.create(
            name="boom",
            channel=DiscountRule.Channel.SALES,
            application_type=DiscountRule.ApplicationType.AUTOMATIC,
            scope=DiscountRule.Scope.DOCUMENT,
            value_type=DiscountRule.ValueType.PERCENTAGE,
            value=Decimal("10.00"),
            exclusive=False,
            is_active=True,
        )

        def boom():
            raise RuntimeError("engine blew up")

        result = preview_with_cache(self.context, boom)  # must not raise

        self.assertEqual(result.total, self.context.subtotal)
        self.assertEqual(result.discount_total, Decimal("0.00"))
        self.assertEqual(result.applications, ())

    def test_matches_live_calculation(self):
        DiscountRule.objects.create(
            name="5pct",
            channel=DiscountRule.Channel.SALES,
            application_type=DiscountRule.ApplicationType.AUTOMATIC,
            scope=DiscountRule.Scope.DOCUMENT,
            value_type=DiscountRule.ValueType.PERCENTAGE,
            value=Decimal("5.00"),
            exclusive=False,
            is_active=True,
        )
        live = DiscountEngine().calculate(self.context)
        cached = preview_with_cache(
            self.context, lambda: DiscountEngine().calculate(self.context)
        )
        self.assertEqual(cached.discount_total, live.discount_total)
        self.assertEqual(cached.total, live.total)
