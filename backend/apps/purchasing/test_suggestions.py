"""Tests for purchase suggestions — the products and quantities a shop
habitually buys from a supplier.

The support floors are the feature, so most of what is asserted here is the
feature keeping quiet: a pair seen twice, a quantity that wanders, a product
nobody has bought in months and a cancelled order all have to produce *nothing*.
A wrong quantity flows into stock and into cost basis, so silence is the
correct output far more often than an answer is.
"""

from datetime import timedelta
from decimal import Decimal
from unittest import mock

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group
from django.core.cache import cache
from django.db import connection
from django.test import TestCase, override_settings
from django.test.utils import CaptureQueriesContext
from django.urls import reverse
from django.utils import timezone
from rest_framework.test import APIClient

from apps.catalog.testing import create_product_with_default_variant
from apps.core.models import ShopSettings
from apps.core.roles import MANAGER_GROUP, ensure_role_groups

from . import services, suggestions, tasks
from .models import (
    PurchaseLine,
    PurchaseOrder,
    Supplier,
    SupplierPurchaseAffinity,
    SupplierPurchaseHabit,
)

LOCMEM = {"default": {"BACKEND": "django.core.cache.backends.locmem.LocMemCache"}}


class SuggestionTestMixin:
    def make_variant(self, sku, name):
        product = create_product_with_default_variant(
            sku=sku,
            barcode="",
            name=name,
            unit_price=Decimal("10.00"),
        )
        return product.default_variant

    def make_order(
        self,
        supplier,
        lines,
        *,
        days_ago=1,
        status=PurchaseOrder.Status.RECEIVED,
    ):
        """One committed order. ``lines`` is ``[(variant, quantity, unit, factor,
        unit_cost)]`` in the order the buyer typed them."""
        order = PurchaseOrder.objects.create(supplier=supplier, status=status)
        when = timezone.now() - timedelta(days=days_ago)
        PurchaseOrder.objects.filter(pk=order.pk).update(created_at=when)
        for index, spec in enumerate(lines):
            variant, quantity = spec[0], spec[1]
            unit = spec[2] if len(spec) > 2 else ""
            factor = spec[3] if len(spec) > 3 else Decimal("1")
            unit_cost = spec[4] if len(spec) > 4 else Decimal("5.00")
            line = PurchaseLine.objects.create(
                purchase_order=order,
                variant=variant,
                quantity=Decimal(quantity),
                unit=unit,
                unit_factor=Decimal(factor),
                unit_cost=Decimal(unit_cost),
            )
            # Entry order within the order, which is what the sequence signal
            # reads. Spaced by seconds so ordering is unambiguous.
            PurchaseLine.objects.filter(pk=line.pk).update(
                created_at=when + timedelta(seconds=index)
            )
        return order


class RebuildTests(SuggestionTestMixin, TestCase):
    def setUp(self):
        self.supplier = Supplier.objects.create(name="مورد المياه")
        self.water = self.make_variant("SUG-WATER", "ماء معدني")
        self.juice = self.make_variant("SUG-JUICE", "عصير")
        self.crisps = self.make_variant("SUG-CRISPS", "شيبس")

    def habit(self, variant):
        return SupplierPurchaseHabit.objects.get(
            supplier=self.supplier, variant=variant
        )

    def test_counts_orders_and_records_last_cost_per_base_unit(self):
        for days_ago in (5, 12, 19):
            self.make_order(
                self.supplier,
                [(self.water, 2, "carton", Decimal("24"), Decimal("48.00"))],
                days_ago=days_ago,
            )
        suggestions.rebuild_supplier_suggestions(self.supplier.pk)

        habit = self.habit(self.water)
        self.assertEqual(habit.order_count, 3)
        # 48.00 for a carton of 24 is 2.00 a bottle — the same normalization the
        # last-cost endpoint applies, so a client seeded from here agrees with a
        # client that fetched.
        self.assertEqual(habit.last_base_unit_cost, Decimal("2.00"))
        self.assertEqual(habit.typical_unit, "carton")
        self.assertEqual(habit.typical_unit_factor, Decimal("24"))

    def test_repeated_quantity_becomes_the_typical_quantity(self):
        for days_ago in (3, 10, 17, 24):
            self.make_order(self.supplier, [(self.water, 12)], days_ago=days_ago)
        suggestions.rebuild_supplier_suggestions(self.supplier.pk)

        habit = self.habit(self.water)
        self.assertEqual(habit.typical_quantity, Decimal("12.000"))
        self.assertEqual(habit.quantity_confidence, 1.0)

    def test_wandering_quantity_suggests_nothing(self):
        # 3, 17, 8, 40 — a real buying pattern, and one with no answer in it.
        for quantity, days_ago in ((3, 4), (17, 11), (8, 18), (40, 25)):
            self.make_order(self.supplier, [(self.water, quantity)], days_ago=days_ago)
        suggestions.rebuild_supplier_suggestions(self.supplier.pk)

        self.assertIsNone(self.habit(self.water).typical_quantity)

    def test_quantity_needs_three_samples(self):
        for days_ago in (3, 10):
            self.make_order(self.supplier, [(self.water, 12)], days_ago=days_ago)
        suggestions.rebuild_supplier_suggestions(self.supplier.pk)

        self.assertIsNone(self.habit(self.water).typical_quantity)

    def test_quantity_uses_the_dominant_unit_only(self):
        # Moved from loose pieces to cartons: the piece quantities must not leak
        # into a carton suggestion.
        for days_ago in (40, 47):
            self.make_order(self.supplier, [(self.water, 100)], days_ago=days_ago)
        for days_ago in (3, 10, 17):
            self.make_order(
                self.supplier,
                [(self.water, 4, "carton", Decimal("24"))],
                days_ago=days_ago,
            )
        suggestions.rebuild_supplier_suggestions(self.supplier.pk)

        habit = self.habit(self.water)
        self.assertEqual(habit.typical_quantity, Decimal("4.000"))
        self.assertEqual(habit.typical_unit, "carton")

    def test_cancelled_and_draft_orders_are_not_evidence(self):
        for days_ago in (3, 10, 17):
            self.make_order(
                self.supplier,
                [(self.water, 12)],
                days_ago=days_ago,
                status=PurchaseOrder.Status.CANCELLED,
            )
        self.make_order(
            self.supplier,
            [(self.water, 12)],
            days_ago=1,
            status=PurchaseOrder.Status.DRAFT,
        )
        suggestions.rebuild_supplier_suggestions(self.supplier.pk)

        self.assertFalse(SupplierPurchaseHabit.objects.exists())

    def test_orders_outside_the_window_are_not_evidence(self):
        for days_ago in (300, 320, 340):
            self.make_order(self.supplier, [(self.water, 12)], days_ago=days_ago)
        suggestions.rebuild_supplier_suggestions(self.supplier.pk)

        self.assertFalse(SupplierPurchaseHabit.objects.exists())

    def test_affinity_needs_three_shared_orders(self):
        for days_ago in (3, 10):
            self.make_order(
                self.supplier, [(self.water, 12), (self.juice, 6)], days_ago=days_ago
            )
        suggestions.rebuild_supplier_suggestions(self.supplier.pk)
        self.assertFalse(SupplierPurchaseAffinity.objects.exists())

        self.make_order(
            self.supplier, [(self.water, 12), (self.juice, 6)], days_ago=17
        )
        suggestions.rebuild_supplier_suggestions(self.supplier.pk)
        pair = SupplierPurchaseAffinity.objects.get(
            anchor_variant=self.water, variant=self.juice
        )
        self.assertEqual(pair.together_count, 3)
        self.assertAlmostEqual(pair.confidence, 1.0, places=6)

    def test_affinity_below_confidence_floor_is_dropped(self):
        # Juice rides along on 3 of 10 water orders — real, but far too weak to
        # put in front of a buyer as "you usually add this next".
        for days_ago in range(3, 13):
            lines = [(self.water, 12)]
            if days_ago < 6:
                lines.append((self.juice, 6))
            self.make_order(self.supplier, lines, days_ago=days_ago)
        suggestions.rebuild_supplier_suggestions(self.supplier.pk)

        self.assertFalse(
            SupplierPurchaseAffinity.objects.filter(
                anchor_variant=self.water, variant=self.juice
            ).exists()
        )

    def test_recency_weighting_favours_the_newer_habit(self):
        for days_ago in (200, 210, 220, 230):
            self.make_order(self.supplier, [(self.crisps, 5)], days_ago=days_ago)
        for days_ago in (2, 9, 16):
            self.make_order(self.supplier, [(self.water, 5)], days_ago=days_ago)
        suggestions.rebuild_supplier_suggestions(self.supplier.pk)

        # Crisps were bought more often, water more recently — and recently wins.
        self.assertGreater(
            self.habit(self.water).weighted_count,
            self.habit(self.crisps).weighted_count,
        )
        self.assertGreater(
            self.habit(self.crisps).order_count,
            self.habit(self.water).order_count,
        )

    def test_rebuild_is_idempotent(self):
        for days_ago in (3, 10, 17):
            self.make_order(
                self.supplier, [(self.water, 12), (self.juice, 6)], days_ago=days_ago
            )
        first = suggestions.rebuild_supplier_suggestions(self.supplier.pk)
        second = suggestions.rebuild_supplier_suggestions(self.supplier.pk)

        self.assertEqual(first["habits"], second["habits"])
        self.assertEqual(first["affinities"], second["affinities"])
        self.assertEqual(
            SupplierPurchaseHabit.objects.filter(supplier=self.supplier).count(),
            first["habits"],
        )

    def test_duplicate_line_counts_once(self):
        for days_ago in (3, 10, 17):
            self.make_order(
                self.supplier,
                [(self.water, 12), (self.water, 3)],
                days_ago=days_ago,
            )
        suggestions.rebuild_supplier_suggestions(self.supplier.pk)

        self.assertEqual(self.habit(self.water).order_count, 3)

    def test_full_rebuild_prunes_suppliers_that_left_the_window(self):
        for days_ago in (3, 10, 17):
            self.make_order(self.supplier, [(self.water, 12)], days_ago=days_ago)
        suggestions.rebuild_purchase_suggestions()
        self.assertTrue(SupplierPurchaseHabit.objects.exists())

        PurchaseOrder.objects.update(
            created_at=timezone.now() - timedelta(days=400)
        )
        summary = suggestions.rebuild_purchase_suggestions()
        self.assertFalse(SupplierPurchaseHabit.objects.exists())
        self.assertGreater(summary["pruned"], 0)


class ReadTests(SuggestionTestMixin, TestCase):
    def setUp(self):
        self.supplier = Supplier.objects.create(name="مورد البقالة")
        self.water = self.make_variant("SUG-R-WATER", "ماء معدني")
        self.juice = self.make_variant("SUG-R-JUICE", "عصير")
        self.crisps = self.make_variant("SUG-R-CRISPS", "شيبس")

    def build_repeating_history(self, count=6, step=7):
        for index in range(count):
            self.make_order(
                self.supplier,
                [(self.water, 12), (self.juice, 6), (self.crisps, 4)],
                days_ago=2 + index * step,
            )
        suggestions.rebuild_supplier_suggestions(self.supplier.pk)

    def test_anchor_predicts_its_companions(self):
        self.build_repeating_history()
        items, _basket = suggestions.suggestions_for_draft(
            supplier_id=self.supplier.pk, anchor_variant_ids=[self.water.pk]
        )
        variants = [item["variant"] for item in items]
        self.assertIn(self.juice.pk, variants)
        self.assertIn(self.crisps.pk, variants)
        # Never suggest what is already on the draft.
        self.assertNotIn(self.water.pk, variants)
        juice = next(item for item in items if item["variant"] == self.juice.pk)
        self.assertEqual(juice["reason"], "often_with")
        self.assertEqual(juice["reason_variant"], self.water.pk)
        self.assertEqual(juice["suggested_quantity"], Decimal("6.000"))

    def test_suggested_cost_is_expressed_in_the_suggested_unit(self):
        for index in range(4):
            self.make_order(
                self.supplier,
                [(self.water, 2, "carton", Decimal("24"), Decimal("48.00"))],
                days_ago=2 + index * 7,
            )
        suggestions.rebuild_supplier_suggestions(self.supplier.pk)

        items, _basket = suggestions.suggestions_for_draft(
            supplier_id=self.supplier.pk, anchor_variant_ids=[]
        )
        water = next(item for item in items if item["variant"] == self.water.pk)
        # 2.00 a bottle → 48.00 the carton, and the base figure travels too so
        # the client's cost cache is seeded in the unit it stores.
        self.assertEqual(water["unit_cost"], Decimal("48.00"))
        self.assertEqual(water["base_unit_cost"], Decimal("2.00"))
        self.assertEqual(water["unit"], "carton")

    def test_empty_draft_falls_back_to_the_supplier_baseline(self):
        self.build_repeating_history()
        items, _basket = suggestions.suggestions_for_draft(
            supplier_id=self.supplier.pk, anchor_variant_ids=[]
        )
        self.assertTrue(items)
        self.assertTrue(
            all(
                item["reason"] in ("usual_for_supplier", "due_again")
                for item in items
            )
        )

    def test_regular_cadence_becomes_due_again(self):
        # Bought like clockwork every 7 days, and the last one was 8 days ago —
        # so standing in front of this supplier, it is due.
        for index in range(6):
            self.make_order(
                self.supplier,
                [(self.water, 12), (self.juice, 6)],
                days_ago=8 + index * 7,
            )
        suggestions.rebuild_supplier_suggestions(self.supplier.pk)

        items, _basket = suggestions.suggestions_for_draft(
            supplier_id=self.supplier.pk, anchor_variant_ids=[]
        )
        self.assertTrue(any(item["reason"] == "due_again" for item in items))

    def test_a_product_bought_yesterday_is_not_due_again(self):
        # Same clockwork rhythm, but the delivery already came this week.
        self.build_repeating_history(count=6, step=7)
        items, _basket = suggestions.suggestions_for_draft(
            supplier_id=self.supplier.pk, anchor_variant_ids=[]
        )
        self.assertFalse(any(item["reason"] == "due_again" for item in items))

    def test_irregular_buying_is_never_due_again(self):
        for days_ago in (4, 9, 40, 44, 120):
            self.make_order(self.supplier, [(self.water, 12)], days_ago=days_ago)
        suggestions.rebuild_supplier_suggestions(self.supplier.pk)

        habit = SupplierPurchaseHabit.objects.get(variant=self.water)
        self.assertIsNone(habit.next_due_at)

    def test_a_supplier_with_no_history_suggests_nothing(self):
        items, basket = suggestions.suggestions_for_draft(
            supplier_id=self.supplier.pk, anchor_variant_ids=[self.water.pk]
        )
        self.assertEqual(items, [])
        self.assertFalse(basket["available"])

    def test_archived_products_are_never_suggested(self):
        self.build_repeating_history()
        product = self.juice.product
        product.archived_at = timezone.now()
        product.save(update_fields=["archived_at"])

        items, _basket = suggestions.suggestions_for_draft(
            supplier_id=self.supplier.pk, anchor_variant_ids=[self.water.pk]
        )
        self.assertNotIn(self.juice.pk, [item["variant"] for item in items])

    def test_stale_products_are_never_suggested(self):
        self.build_repeating_history()
        SupplierPurchaseHabit.objects.filter(variant=self.juice).update(
            last_ordered_at=timezone.now() - timedelta(days=200)
        )
        items, _basket = suggestions.suggestions_for_draft(
            supplier_id=self.supplier.pk, anchor_variant_ids=[self.water.pk]
        )
        self.assertNotIn(self.juice.pk, [item["variant"] for item in items])

    def test_usual_basket_lists_the_repeating_order(self):
        self.build_repeating_history()
        _items, basket = suggestions.suggestions_for_draft(
            supplier_id=self.supplier.pk, anchor_variant_ids=[]
        )
        self.assertTrue(basket["available"])
        self.assertEqual(basket["line_count"], 3)
        self.assertEqual(
            {item["variant"] for item in basket["items"]},
            {self.water.pk, self.juice.pk, self.crisps.pk},
        )

    def test_usual_basket_needs_a_real_pattern(self):
        # Two orders is not a habit.
        for index in range(2):
            self.make_order(
                self.supplier, [(self.water, 12)], days_ago=2 + index * 7
            )
        suggestions.rebuild_supplier_suggestions(self.supplier.pk)
        _items, basket = suggestions.suggestions_for_draft(
            supplier_id=self.supplier.pk, anchor_variant_ids=[]
        )
        self.assertFalse(basket["available"])

    def test_read_query_count_does_not_grow_with_the_draft(self):
        """The strip re-reads on every line the buyer adds, so the read has to be
        flat in the size of the draft — the property the precomputed tables exist
        to buy."""
        extra = [self.make_variant(f"SUG-Q-{i}", f"صنف {i}") for i in range(10)]
        for index in range(5):
            self.make_order(
                self.supplier,
                [(self.water, 12), (self.juice, 6)]
                + [(variant, 3) for variant in extra],
                days_ago=2 + index * 7,
            )
        suggestions.rebuild_supplier_suggestions(self.supplier.pk)

        def measure(anchors):
            with CaptureQueriesContext(connection) as ctx:
                suggestions.suggestions_for_draft(
                    supplier_id=self.supplier.pk, anchor_variant_ids=anchors
                )
            return len(ctx.captured_queries)

        one = measure([self.water.pk])
        many = measure([self.water.pk, self.juice.pk] + [v.pk for v in extra])
        # Flat in the size of the draft. The one query of slack is the baseline
        # fallback, which only runs when affinity and cadence together have not
        # already filled the strip — it does not depend on how many lines there
        # are, so it cannot become a per-line read.
        self.assertLessEqual(abs(one - many), 1)
        self.assertLessEqual(max(one, many), 6)


@override_settings(CACHES=LOCMEM)
class SuggestionEndpointTests(SuggestionTestMixin, TestCase):
    def setUp(self):
        ensure_role_groups()
        self.client = APIClient()
        self.user = get_user_model().objects.create_user(
            username="suggestion-manager", password="pass"
        )
        self.user.groups.add(Group.objects.get(name=MANAGER_GROUP))
        self.client.force_authenticate(user=self.user)

        self.supplier = Supplier.objects.create(name="مورد")
        self.water = self.make_variant("SUG-E-WATER", "ماء معدني")
        self.juice = self.make_variant("SUG-E-JUICE", "عصير")
        for index in range(5):
            self.make_order(
                self.supplier,
                [(self.water, 12), (self.juice, 6)],
                days_ago=2 + index * 7,
            )
        suggestions.rebuild_supplier_suggestions(self.supplier.pk)
        self.url = reverse("purchaseorder-suggestions")

    def test_returns_ranked_suggestions_for_the_draft(self):
        response = self.client.get(
            self.url, {"supplier": self.supplier.pk, "variants": str(self.water.pk)}
        )
        self.assertEqual(response.status_code, 200, response.data)
        self.assertTrue(response.data["enabled"])
        variants = [item["variant"] for item in response.data["items"]]
        self.assertEqual(variants, [self.juice.pk])
        item = response.data["items"][0]
        self.assertEqual(item["suggested_quantity"], "6.000")
        self.assertEqual(item["product_name"], "عصير")
        self.assertEqual(item["evidence"]["orders"], 5)

    def test_supplier_is_required(self):
        response = self.client.get(self.url)
        self.assertEqual(response.status_code, 400)

    def test_bad_variant_list_is_rejected_not_ignored(self):
        response = self.client.get(
            self.url, {"supplier": self.supplier.pk, "variants": "abc"}
        )
        self.assertEqual(response.status_code, 400)

    def test_disabled_setting_returns_an_empty_disabled_payload(self):
        ShopSettings.objects.get_or_create(pk=1)
        ShopSettings.objects.filter(pk=1).update(enable_purchase_suggestions=False)
        response = self.client.get(
            self.url, {"supplier": self.supplier.pk, "variants": str(self.water.pk)}
        )
        self.assertEqual(response.status_code, 200)
        self.assertFalse(response.data["enabled"])
        self.assertEqual(response.data["items"], [])

    def test_requires_the_drafting_permission(self):
        cashier = get_user_model().objects.create_user(
            username="suggestion-cashier", password="pass"
        )
        self.client.force_authenticate(user=cashier)
        response = self.client.get(self.url, {"supplier": self.supplier.pk})
        self.assertEqual(response.status_code, 403)


@override_settings(CACHES=LOCMEM)
class SuggestionRefreshSchedulingTests(SuggestionTestMixin, TestCase):
    """Committing an order must feed the suggestion tables — today's delivery is
    evidence for tomorrow's order — and must never fail because it couldn't."""

    def setUp(self):
        cache.clear()
        self.supplier = Supplier.objects.create(name="مورد")
        self.water = self.make_variant("SUG-T-WATER", "ماء معدني")

    def test_first_refresh_wins_and_the_burst_behind_it_is_dropped(self):
        queued = []
        with mock.patch.object(
            tasks.refresh_supplier_suggestions_task, "delay", queued.append
        ):
            # The refresh is queued on_commit, which a TestCase's wrapping
            # transaction never reaches on its own.
            with self.captureOnCommitCallbacks(execute=True):
                for _ in range(5):
                    tasks.schedule_supplier_refresh(self.supplier.pk)

        self.assertEqual(
            queued,
            [self.supplier.pk],
            msg="a burst of receipts against one supplier must queue one rebuild",
        )

    def test_each_supplier_is_debounced_separately(self):
        other = Supplier.objects.create(name="مورد آخر")
        queued = []
        with mock.patch.object(
            tasks.refresh_supplier_suggestions_task, "delay", queued.append
        ):
            with self.captureOnCommitCallbacks(execute=True):
                tasks.schedule_supplier_refresh(self.supplier.pk)
                tasks.schedule_supplier_refresh(other.pk)

        self.assertEqual(sorted(queued), sorted([self.supplier.pk, other.pk]))

    def test_a_broker_that_is_down_does_not_break_the_caller(self):
        def explode(_supplier_id):
            raise RuntimeError("broker unreachable")

        with mock.patch.object(
            tasks.refresh_supplier_suggestions_task, "delay", explode
        ):
            # Must not raise: suggestions are decoration, and a shop running
            # without a worker still has to be able to receive a delivery.
            with self.captureOnCommitCallbacks(execute=True):
                tasks.schedule_supplier_refresh(self.supplier.pk)

    def test_submitting_an_order_schedules_its_supplier(self):
        order = self.make_order(
            self.supplier,
            [(self.water, 12)],
            status=PurchaseOrder.Status.DRAFT,
        )
        queued = []
        with mock.patch.object(
            tasks.refresh_supplier_suggestions_task, "delay", queued.append
        ):
            with self.captureOnCommitCallbacks(execute=True):
                services.submit_purchase_order(order)

        self.assertEqual(queued, [self.supplier.pk])
