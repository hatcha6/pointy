from decimal import Decimal

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group
from django.test import TestCase
from django.urls import reverse
from rest_framework import status
from rest_framework.test import APIClient

from apps.catalog.models import (
    Product,
    ProductCategory,
    ProductUnit,
    ProductVariant,
    UnitOfMeasure,
)
from apps.catalog.testing import create_product_with_default_variant
from apps.core.roles import CASHIER_GROUP, MANAGER_GROUP, ensure_role_groups
from .models import (
    StockCount,
    StockCountLine,
    StockItem,
    StockLedgerEntry,
    StockMovement,
)


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


class StockCountValuationTests(StockCountTestBase):
    """A count is a stock movement, so it is a valuation event.

    The engine became the source of truth for COGS after this feature shipped
    and nobody came back to check the count still posted through it. These pin
    that down: every movement a count writes carries a ledger entry, filed
    under the count, and the value it moves is the rate the shelf was already
    carrying — found stock is not free, and missing stock costs what it cost.
    """

    def _receive(self, variant, quantity, unit_cost):
        """Put valued stock on the shelf through the ledger's own door."""
        from .services import (
            create_stock_movement,
            lock_stock_item,
            save_stock_item_quantities,
            stock_snapshot,
        )

        stock_item = lock_stock_item(variant=variant)
        before = stock_snapshot(stock_item)
        stock_item.quantity_on_hand = stock_item.quantity_on_hand + Decimal(quantity)
        save_stock_item_quantities(stock_item)
        return create_stock_movement(
            stock_item=stock_item,
            movement_type=StockMovement.Type.INCREASE,
            quantity=Decimal(quantity),
            note="استلام تجريبي",
            created_by=self.manager,
            before=before,
            variant=variant,
            voucher_type=StockLedgerEntry.VoucherType.PURCHASE_RECEIPT,
            unit_cost=Decimal(unit_cost),
        )

    def test_shortage_issues_value_at_the_carrying_rate(self):
        variant = _make_variant(sku="VAL-SHORT")
        self._receive(variant, "10", "4.000")

        count_id = self.start(scope="full").data["id"]
        self.count(count_id, variant, "7")
        self.apply(count_id)

        entry = StockLedgerEntry.objects.get(
            variant=variant,
            voucher_type=StockLedgerEntry.VoucherType.STOCK_COUNT,
        )
        self.assertEqual(entry.voucher_id, count_id)
        self.assertEqual(entry.quantity_change, Decimal("-3"))
        self.assertEqual(entry.valuation_rate, Decimal("4.000000"))
        self.assertEqual(entry.value_change, Decimal("-12.000000"))
        self.assertEqual(entry.balance_quantity, Decimal("7"))
        self.assertEqual(entry.balance_value, Decimal("28.000000"))

    def test_surplus_receives_value_at_the_carrying_rate(self):
        variant = _make_variant(sku="VAL-OVER")
        self._receive(variant, "10", "4.000")

        count_id = self.start(scope="full").data["id"]
        self.count(count_id, variant, "12")
        self.apply(count_id)

        entry = StockLedgerEntry.objects.get(
            variant=variant,
            voucher_type=StockLedgerEntry.VoucherType.STOCK_COUNT,
        )
        self.assertEqual(entry.quantity_change, Decimal("2"))
        # Found goods are worth what the shelf already carried, not nothing:
        # a surplus valued at zero would silently write the average down.
        self.assertEqual(entry.valuation_rate, Decimal("4.000000"))
        self.assertEqual(entry.balance_value, Decimal("48.000000"))

    def test_matched_line_posts_nothing(self):
        variant = _make_variant(sku="VAL-MATCH")
        self._receive(variant, "10", "4.000")

        count_id = self.start(scope="full").data["id"]
        self.count(count_id, variant, "10")
        self.apply(count_id)

        self.assertFalse(
            StockLedgerEntry.objects.filter(
                voucher_type=StockLedgerEntry.VoucherType.STOCK_COUNT
            ).exists()
        )


class StockCountOversellPolicyTests(StockCountTestBase):
    """Whether a count may drive stock below zero is the shop's standing answer.

    ``apps.inventory.oversell`` exists so that question has exactly one answer,
    and its own docstring names a count as a caller. The count was written
    before it and refused on its own authority, which made it the strictest
    path in the app: a shop that deliberately allows negative stock could not
    finish a count.
    """

    def _sell_one(self, variant):
        return self.manager_client.post(
            reverse("stockmovement-list"),
            {
                "variant": variant.pk,
                "movement_type": StockMovement.Type.DECREASE,
                "quantity": 1,
            },
            format="json",
        )

    def test_refusal_names_every_short_line_not_just_the_first(self):
        first = _make_variant(sku="NEG-1", on_hand="3")
        second = _make_variant(sku="NEG-2", on_hand="3")
        count_id = self.start(scope="full").data["id"]
        self.count(count_id, first, "0")
        self.count(count_id, second, "0")
        self._sell_one(first)
        self._sell_one(second)

        response = self.apply(count_id)

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        # DRF renders every leaf of a ValidationError detail as a string, so
        # compare the ids as the wire carries them.
        shortfalls = response.data["stock"]
        self.assertEqual(
            {str(row["variant"]) for row in shortfalls},
            {str(first.pk), str(second.pk)},
        )
        self.assertEqual(
            StockCount.objects.get(pk=count_id).status,
            StockCount.Status.IN_PROGRESS,
        )

    def test_shop_that_allows_negative_stock_can_apply(self):
        from apps.core.models import ShopSettings

        settings = ShopSettings.load()
        settings.allow_overselling = True
        settings.save(update_fields=["allow_overselling", "updated_at"])

        variant = _make_variant(sku="NEG-OK", on_hand="3")
        count_id = self.start(scope="full").data["id"]
        self.count(count_id, variant, "0")
        self._sell_one(variant)

        response = self.apply(count_id)

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(variant.quantity_on_hand, Decimal("-1"))


class StockCountCategoryScopeTests(StockCountTestBase):
    """A category-scoped count must answer the same questions a full one does."""

    def test_scan_reconciliation_survives_a_category_scope(self):
        category = ProductCategory.objects.create(name="هواتف")
        variant = _make_variant(sku="CAT-1", on_hand="2")
        variant.product.categories.add(category)

        count_id = self.start(
            scope=StockCount.Scope.CATEGORY, category=category.pk
        ).data["id"]

        response = self.manager_client.get(
            reverse("stock-count-scan-reconciliation", args=[count_id])
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(response.data["expected"], 0)
        self.assertEqual(response.data["missing"], [])


class StockCountUnitTests(StockCountTestBase):
    """Counting a shelf of cartons.

    Multi-unit products landed after this feature did, and the count never
    learned about them: a shop whose goods arrive in cartons of 24 had to type
    the answer in pieces. The arithmetic is done on a ladder, so the mistakes
    went straight into the shelf.
    """

    def setUp(self):
        super().setUp()
        self.variant = _make_variant(sku="CTN", on_hand="0")
        # "carton" is one of the seeded units, so take the existing row.
        self.carton, _ = UnitOfMeasure.objects.get_or_create(
            code="carton", defaults={"name": "كرتونة"}
        )

    def _pack(self, *, factor, is_sellable=True, is_purchasable=True):
        return ProductUnit.objects.create(
            product=self.variant.product,
            unit=self.carton,
            factor_to_base=Decimal(factor),
            is_sellable=is_sellable,
            is_purchasable=is_purchasable,
        )

    def count_in(self, count_id, quantity, unit):
        return self.manager_client.post(
            reverse("stock-count-count", args=[count_id]),
            {
                "variant": self.variant.pk,
                "counted_quantity": quantity,
                "unit": unit,
                "mode": "replace",
            },
            format="json",
        )

    def test_counted_in_cartons_is_stored_in_base_units(self):
        self._pack(factor="24")
        count_id = self.start(scope="full").data["id"]

        response = self.count_in(count_id, "3", "carton")

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        line = StockCountLine.objects.get(stock_count=count_id)
        self.assertEqual(line.counted_quantity, Decimal("72"))

    def test_add_mode_composes_cartons_and_loose_pieces(self):
        # The way a shelf is actually counted: four full cartons and five
        # singles left over.
        self._pack(factor="24")
        count_id = self.start(scope="full").data["id"]

        self.count_in(count_id, "4", "carton")
        self.manager_client.post(
            reverse("stock-count-count", args=[count_id]),
            {
                "variant": self.variant.pk,
                "counted_quantity": "5",
                "mode": "add",
            },
            format="json",
        )

        line = StockCountLine.objects.get(stock_count=count_id)
        self.assertEqual(line.counted_quantity, Decimal("101"))

    def test_a_purchase_only_carton_can_still_be_counted(self):
        # Counting is not selling. A carton the shop only ever buys in is
        # still a carton standing on the shelf.
        self._pack(factor="12", is_sellable=False)
        count_id = self.start(scope="full").data["id"]

        response = self.count_in(count_id, "2", "carton")

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(
            StockCountLine.objects.get(stock_count=count_id).counted_quantity,
            Decimal("24"),
        )

    def test_a_unit_this_product_does_not_have_is_refused(self):
        count_id = self.start(scope="full").data["id"]

        response = self.count_in(count_id, "2", "carton")

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertIn("unit", response.data)
        self.assertFalse(StockCountLine.objects.filter(stock_count=count_id).exists())

    def test_no_unit_means_base_units_exactly_as_before(self):
        self._pack(factor="24")
        count_id = self.start(scope="full").data["id"]

        self.count(count_id, self.variant, "7")

        self.assertEqual(
            StockCountLine.objects.get(stock_count=count_id).counted_quantity,
            Decimal("7"),
        )

    def test_applying_a_carton_count_moves_base_units(self):
        self._pack(factor="24")
        StockItem.objects.filter(variant=self.variant).update(
            quantity_on_hand=Decimal("50")
        )
        count_id = self.start(scope="full").data["id"]
        self.count_in(count_id, "3", "carton")  # 72 pieces, +22

        self.apply(count_id)

        self.assertEqual(self.variant.quantity_on_hand, Decimal("72"))
        movement = StockMovement.objects.get(variant=self.variant)
        self.assertEqual(movement.movement_type, StockMovement.Type.INCREASE)
        self.assertEqual(movement.quantity, Decimal("22"))
