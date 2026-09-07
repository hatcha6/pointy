from decimal import Decimal

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group
from django.test import TestCase
from django.urls import reverse
from rest_framework import status
from rest_framework.test import APIClient

from apps.catalog.models import Product, ProductCategory, ProductVariant
from apps.catalog.testing import create_product_with_default_variant
from apps.core.roles import CASHIER_GROUP, MANAGER_GROUP, ensure_role_groups
from .models import StockCount, StockCountLine, StockItem, StockMovement


def _make_variant(*, sku, name="منتج", on_hand="0", is_service=False, is_prepared=False):
    product = Product.objects.create(
        name=name,
        is_active=True,
        is_service=is_service,
        is_prepared=is_prepared,
    )
    variant = ProductVariant.objects.create(
        product=product,
        sku=sku,
        unit_price=Decimal("1.00"),
        is_default=True,
    )
    if not (is_service or is_prepared):
        StockItem.objects.create(variant=variant, quantity_on_hand=Decimal(on_hand))
    return variant


class StockCountTestBase(TestCase):
    def setUp(self):
        ensure_role_groups()
        self.manager = get_user_model().objects.create_user(
            username="sc-manager", password="pass"
        )
        self.manager.groups.add(Group.objects.get(name=MANAGER_GROUP))
        self.cashier = get_user_model().objects.create_user(
            username="sc-cashier", password="pass"
        )
        self.cashier.groups.add(Group.objects.get(name=CASHIER_GROUP))
        self.manager_client = APIClient()
        self.manager_client.force_authenticate(user=self.manager)
        self.cashier_client = APIClient()
        self.cashier_client.force_authenticate(user=self.cashier)

    def start(self, client=None, **payload):
        client = client or self.manager_client
        response = client.post(reverse("stock-count-start"), payload, format="json")
        return response

    def count(self, count_id, variant, quantity, *, mode="replace", client=None):
        client = client or self.manager_client
        return client.post(
            reverse("stock-count-count", args=[count_id]),
            {"variant": variant.pk, "counted_quantity": quantity, "mode": mode},
            format="json",
        )

    def apply(self, count_id, *, client=None):
        client = client or self.manager_client
        return client.post(reverse("stock-count-apply", args=[count_id]), format="json")


class StockCountStartTests(StockCountTestBase):
    def test_start_freezes_denominator_over_countable_variants(self):
        _make_variant(sku="A")
        _make_variant(sku="B")
        response = self.start(scope="full")

        self.assertEqual(response.status_code, status.HTTP_201_CREATED)
        self.assertEqual(response.data["status"], StockCount.Status.IN_PROGRESS)
        self.assertEqual(response.data["expected_line_count"], 2)

    def test_start_excludes_service_and_prepared(self):
        _make_variant(sku="REAL")
        _make_variant(sku="SVC", is_service=True)
        _make_variant(sku="PREP", is_prepared=True)
        response = self.start(scope="full")

        self.assertEqual(response.data["expected_line_count"], 1)

    def test_start_reuses_existing_in_progress_session(self):
        _make_variant(sku="A")
        first = self.start(scope="full")
        second = self.start(scope="full")

        self.assertEqual(first.status_code, status.HTTP_201_CREATED)
        self.assertEqual(second.status_code, status.HTTP_200_OK)
        self.assertEqual(first.data["id"], second.data["id"])
        self.assertEqual(StockCount.objects.count(), 1)

    def test_category_scope_requires_category(self):
        response = self.start(scope="category")
        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)

    def test_category_scope_limits_denominator_to_category_tree(self):
        parent = ProductCategory.objects.create(name="مشروبات")
        child = ProductCategory.objects.create(name="عصائر", parent=parent)
        in_scope = _make_variant(sku="IN")
        in_scope.product.categories.add(child)
        nested = _make_variant(sku="NESTED")
        nested.product.categories.add(child)
        _make_variant(sku="OUT")  # no category

        response = self.start(scope="category", category=parent.pk)

        self.assertEqual(response.status_code, status.HTTP_201_CREATED)
        self.assertEqual(response.data["scope"], StockCount.Scope.CATEGORY)
        self.assertEqual(response.data["expected_line_count"], 2)


class StockCountCountTests(StockCountTestBase):
    def test_count_snapshots_expected_and_flags_large_variance(self):
        variant = _make_variant(sku="A", on_hand="50")
        count_id = self.start(scope="full").data["id"]

        response = self.count(count_id, variant, "3")

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(Decimal(str(response.data["counted_quantity"])), Decimal("3"))
        self.assertEqual(Decimal(str(response.data["expected_quantity"])), Decimal("50"))
        self.assertTrue(response.data["needs_review"])

    def test_small_variance_within_threshold_is_not_flagged(self):
        variant = _make_variant(sku="A", on_hand="50")
        count_id = self.start(scope="full").data["id"]

        response = self.count(count_id, variant, "48")  # 4% gap, below 10%

        self.assertFalse(response.data["needs_review"])

    def test_count_add_then_replace(self):
        variant = _make_variant(sku="A", on_hand="0")
        count_id = self.start(scope="full").data["id"]

        self.count(count_id, variant, "5")
        added = self.count(count_id, variant, "3", mode="add")
        self.assertEqual(Decimal(str(added.data["counted_quantity"])), Decimal("8"))

        replaced = self.count(count_id, variant, "2", mode="replace")
        self.assertEqual(Decimal(str(replaced.data["counted_quantity"])), Decimal("2"))
        self.assertEqual(StockCountLine.objects.filter(stock_count=count_id).count(), 1)

    def test_count_rejects_service_variant(self):
        variant = _make_variant(sku="SVC", is_service=True)
        count_id = self.start(scope="full").data["id"]

        response = self.count(count_id, variant, "5")
        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)

    def test_count_on_variant_without_stock_item_snapshots_zero(self):
        product = create_product_with_default_variant(
            sku="NOSTOCK", name="بدون مخزون", unit_price=Decimal("1.00")
        )
        variant = product.default_variant
        count_id = self.start(scope="full").data["id"]

        response = self.count(count_id, variant, "7")
        self.assertEqual(Decimal(str(response.data["expected_quantity"])), Decimal("0"))
        self.assertTrue(StockItem.objects.filter(variant=variant).exists())


class StockCountApplyTests(StockCountTestBase):
    def test_apply_writes_delta_movements_and_updates_stock(self):
        short = _make_variant(sku="SHORT", on_hand="50")
        over = _make_variant(sku="OVER", on_hand="10")
        count_id = self.start(scope="full").data["id"]
        self.count(count_id, short, "44")  # -6
        self.count(count_id, over, "13")  # +3

        response = self.apply(count_id)

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(response.data["status"], StockCount.Status.APPLIED)
        self.assertEqual(short.quantity_on_hand, Decimal("44"))
        self.assertEqual(over.quantity_on_hand, Decimal("13"))

        decrease = StockMovement.objects.get(variant=short)
        increase = StockMovement.objects.get(variant=over)
        self.assertEqual(decrease.movement_type, StockMovement.Type.DECREASE)
        self.assertEqual(decrease.quantity, Decimal("6"))
        self.assertEqual(decrease.on_hand_before, Decimal("50"))
        self.assertEqual(decrease.on_hand_after, Decimal("44"))
        self.assertEqual(increase.movement_type, StockMovement.Type.INCREASE)
        self.assertEqual(increase.quantity, Decimal("3"))

        line = StockCountLine.objects.get(stock_count=count_id, variant=short)
        self.assertTrue(line.applied)
        self.assertEqual(line.movement_id, decrease.pk)

    def test_apply_skips_zero_variance_lines(self):
        variant = _make_variant(sku="A", on_hand="20")
        count_id = self.start(scope="full").data["id"]
        self.count(count_id, variant, "20")

        self.apply(count_id)

        self.assertFalse(StockMovement.objects.filter(variant=variant).exists())
        line = StockCountLine.objects.get(stock_count=count_id, variant=variant)
        self.assertTrue(line.applied)
        self.assertIsNone(line.movement_id)

    def test_mid_count_sale_uses_delta_and_flags_stale(self):
        # Count finds 48 against an expected 50 (-2). Then 5 sell mid-count.
        variant = _make_variant(sku="A", on_hand="50")
        count_id = self.start(scope="full").data["id"]
        self.count(count_id, variant, "48")

        # Simulate a sale landing after the count via the proven movement path.
        self.manager_client.post(
            reverse("stockmovement-list"),
            {
                "variant": variant.pk,
                "movement_type": StockMovement.Type.DECREASE,
                "quantity": 5,
            },
            format="json",
        )
        self.assertEqual(variant.quantity_on_hand, Decimal("45"))

        self.apply(count_id)

        # Delta (-2) applied to the now-45 on hand => 43, NOT set-to-48.
        self.assertEqual(variant.quantity_on_hand, Decimal("43"))
        line = StockCountLine.objects.get(stock_count=count_id, variant=variant)
        self.assertTrue(line.stale_at_apply)
        self.assertEqual(line.on_hand_at_apply, Decimal("45"))

    def test_apply_negative_guard_rolls_back(self):
        variant = _make_variant(sku="A", on_hand="3")
        count_id = self.start(scope="full").data["id"]
        # Count 0 against expected 3 (-3). Then sell 1 -> on hand 2; delta -3 => -1.
        self.count(count_id, variant, "0")
        self.manager_client.post(
            reverse("stockmovement-list"),
            {
                "variant": variant.pk,
                "movement_type": StockMovement.Type.DECREASE,
                "quantity": 1,
            },
            format="json",
        )

        response = self.apply(count_id)

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertEqual(variant.quantity_on_hand, Decimal("2"))
        self.assertEqual(
            StockCount.objects.get(pk=count_id).status, StockCount.Status.IN_PROGRESS
        )

    def test_double_apply_without_key_is_noop(self):
        variant = _make_variant(sku="A", on_hand="10")
        count_id = self.start(scope="full").data["id"]
        self.count(count_id, variant, "7")

        self.apply(count_id)
        second = self.apply(count_id)

        self.assertEqual(second.status_code, status.HTTP_200_OK)
        self.assertEqual(StockMovement.objects.filter(variant=variant).count(), 1)

    def test_apply_replayed_with_idempotency_key(self):
        variant = _make_variant(sku="A", on_hand="10")
        count_id = self.start(scope="full").data["id"]
        self.count(count_id, variant, "7")

        url = reverse("stock-count-apply", args=[count_id])
        first = self.manager_client.post(url, format="json", HTTP_IDEMPOTENCY_KEY="k-1")
        second = self.manager_client.post(url, format="json", HTTP_IDEMPOTENCY_KEY="k-1")

        self.assertEqual(first.status_code, status.HTTP_200_OK)
        self.assertEqual(second.headers.get("Idempotency-Replayed"), "true")
        self.assertEqual(StockMovement.objects.filter(variant=variant).count(), 1)


class StockCountPermissionTests(StockCountTestBase):
    def test_cashier_can_count_but_not_apply(self):
        variant = _make_variant(sku="A", on_hand="10")
        started = self.start(client=self.cashier_client, scope="full")
        self.assertEqual(started.status_code, status.HTTP_201_CREATED)
        count_id = started.data["id"]

        counted = self.count(count_id, variant, "8", client=self.cashier_client)
        self.assertEqual(counted.status_code, status.HTTP_200_OK)

        forbidden = self.apply(count_id, client=self.cashier_client)
        self.assertEqual(forbidden.status_code, status.HTTP_403_FORBIDDEN)

        # A manager can apply the cashier's session.
        allowed = self.apply(count_id, client=self.manager_client)
        self.assertEqual(allowed.status_code, status.HTTP_200_OK)
        self.assertEqual(variant.quantity_on_hand, Decimal("8"))


class StockCountReconciliationTests(StockCountTestBase):
    def test_reconciliation_returns_only_differing_lines(self):
        matching = _make_variant(sku="MATCH", on_hand="5")
        differing = _make_variant(sku="DIFF", on_hand="5")
        count_id = self.start(scope="full").data["id"]
        self.count(count_id, matching, "5")
        self.count(count_id, differing, "2")

        response = self.manager_client.get(
            reverse("stock-count-reconciliation", args=[count_id])
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        results = response.data["results"] if "results" in response.data else response.data
        skus = {row["variant_detail"]["sku"] for row in results}
        self.assertEqual(skus, {"DIFF"})

    def test_cancel_marks_session_cancelled(self):
        _make_variant(sku="A", on_hand="5")
        count_id = self.start(scope="full").data["id"]

        response = self.manager_client.post(
            reverse("stock-count-cancel", args=[count_id]), format="json"
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(response.data["status"], StockCount.Status.CANCELLED)
