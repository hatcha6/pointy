"""Inventory integrity tests.

Covers expiry FIFO draw-down, EXPECTED-family movement snapshots, multi-variant
isolation, unit-conversion round trips, oversell-negative movements, and a
stock-count delta that composes with a mid-count *increase* (the existing
``test_stock_count`` module only exercises a mid-count decrease/sale).

These add NEW scenarios on top of:
  * apps/inventory/tests.py            (INCREASE/DECREASE movements, services)
  * apps/inventory/test_stock_count.py (count lifecycle, mid-count *sale*)
  * apps/purchasing/tests.py           (batch creation on receive, basic FIFO)
"""

from datetime import timedelta
from decimal import Decimal

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group
from django.test import TestCase
from django.urls import reverse
from django.utils import timezone
from rest_framework import status
from rest_framework.test import APIClient

from apps.catalog.models import (
    Product,
    ProductUnit,
    ProductVariant,
    UnitOfMeasure,
)
from apps.catalog.testing import create_product_with_default_variant
from apps.catalog.units import resolve_unit, to_base_quantity, unit_sale_price
from apps.core.models import ShopSettings
from apps.core.roles import MANAGER_GROUP, ensure_role_groups
from apps.purchasing.models import (
    PurchaseLine,
    PurchaseOrder,
    PurchaseReceipt,
    PurchaseReceiptLine,
    Supplier,
)
from apps.sales.models import RegisterSession
from apps.sales.services import checkout_order

from .models import (
    StockBatch,
    StockBatchBalance,
    StockItem,
    StockMovement,
    Warehouse,
)
from .services import (
    consume_expiring_stock_batches,
    create_expiring_stock_batch,
    create_stock_movement,
    receipt_line_lot_code,
    stock_snapshot,
)


def _expiring_product(*, sku="EXP", name="حليب", tracks_expiry=True):
    product = create_product_with_default_variant(
        sku=sku, name=name, unit_price=Decimal("1.00")
    )
    if tracks_expiry:
        product.tracking_mode = Product.TrackingMode.BATCH
        product.expiry_required = True
        product.save(
            update_fields=["tracking_mode", "expiry_required", "updated_at"]
        )
    StockItem.objects.create(variant=product.default_variant, quantity_on_hand=0)
    return product


def _make_batch(*, variant, days, quantity, supplier, created_offset_seconds=0):
    """Build a lot and its balance through the receiving service.

    The cohort used to be one row with its quantity welded on; since the split
    it is an identity plus one balance per place, so a fixture has to make both.
    It still goes through the purchasing graph because that is where an expiry
    cohort comes from, and because ``receipt_line_lot_code`` keys the generated
    code on the receipt line.
    """
    qty = Decimal(quantity)
    order = PurchaseOrder.objects.create(supplier=supplier)
    purchase_line = PurchaseLine.objects.create(
        purchase_order=order,
        variant=variant,
        quantity=int(qty),
        unit_cost=Decimal("0.50"),
    )
    receipt = PurchaseReceipt.objects.create(purchase_order=order)
    receipt_line = PurchaseReceiptLine.objects.create(
        receipt=receipt,
        purchase_line=purchase_line,
        variant=variant,
        ordered_quantity=int(qty),
        outstanding_before=int(qty),
        accepted_quantity=int(qty),
        expiry_date=timezone.localdate() + timedelta(days=days),
    )
    batch = create_expiring_stock_batch(
        receipt_line=receipt_line,
        expiry_date=receipt_line.expiry_date,
        quantity=qty,
    )
    if batch is None:
        # The product does not track expiry — the stray-cohort case one test
        # needs. Write the identity and the balance directly.
        code = receipt_line_lot_code(receipt_line)
        batch = StockBatch.objects.create(
            variant=variant, code=code, code_is_generated=True,
            expiry_date=receipt_line.expiry_date,
        )
        StockBatchBalance.objects.create(
            batch=batch,
            warehouse_id=Warehouse.default_id(),
            variant=variant,
            received_quantity=qty,
            remaining_quantity=qty,
            expiry_date=batch.expiry_date,
            first_received_at=timezone.now(),
        )
    if created_offset_seconds:
        offset = timedelta(seconds=created_offset_seconds)
        StockBatch.objects.filter(pk=batch.pk).update(
            created_at=batch.created_at + offset
        )
        StockBatchBalance.objects.filter(batch=batch).update(
            first_received_at=timezone.now() + offset
        )
        batch.refresh_from_db()
    return batch


def _remaining(batch):
    """What is left of this lot, wherever it sits.

    ``batch.remaining_quantity`` used to answer this; the quantity now lives on
    the balances, one per place, and the lot's own total is their sum.
    """
    return sum(
        (balance.remaining_quantity for balance in batch.balances.all()),
        Decimal("0"),
    )


# ---------------------------------------------------------------------------
# 1. Expiry FIFO draw-down
# ---------------------------------------------------------------------------


class ExpiryFifoTests(TestCase):
    def setUp(self):
        self.supplier = Supplier.objects.create(name="مورد")
        self.product = _expiring_product(sku="MILK")
        self.variant = self.product.default_variant

    def test_earlier_expiry_batch_drawn_down_first(self):
        # Insert the LATER-expiry batch first so ordering can't be incidental.
        later = _make_batch(
            variant=self.variant, days=30, quantity="5", supplier=self.supplier
        )
        earlier = _make_batch(
            variant=self.variant, days=10, quantity="3", supplier=self.supplier
        )

        consumed = consume_expiring_stock_batches(
            variant=self.variant,
            quantity=2,
            warehouse=Warehouse.default_id(),
        )

        self.assertEqual(consumed.quantity, Decimal("2"))
        earlier.refresh_from_db()
        later.refresh_from_db()
        # Earlier-expiry batch is drained before the later one is touched.
        self.assertEqual(_remaining(earlier), Decimal("1"))
        self.assertEqual(_remaining(later), Decimal("5"))

    def test_consumption_spanning_two_batches_partially_consumes_second(self):
        earlier = _make_batch(
            variant=self.variant, days=10, quantity="3", supplier=self.supplier
        )
        later = _make_batch(
            variant=self.variant, days=30, quantity="5", supplier=self.supplier
        )

        # 4 > the first batch's 3, so it spills into the second.
        consumed = consume_expiring_stock_batches(
            variant=self.variant,
            quantity=4,
            warehouse=Warehouse.default_id(),
        )

        self.assertEqual(consumed.quantity, Decimal("4"))
        earlier.refresh_from_db()
        later.refresh_from_db()
        self.assertEqual(_remaining(earlier), Decimal("0"))
        self.assertEqual(_remaining(later), Decimal("4"))

    def test_consuming_more_than_available_drains_all_and_returns_actual(self):
        # Demand exceeds total stock: every batch empties and the return value is
        # the actually-consumed amount, not the requested amount.
        first = _make_batch(
            variant=self.variant, days=5, quantity="2", supplier=self.supplier
        )
        second = _make_batch(
            variant=self.variant, days=15, quantity="3", supplier=self.supplier
        )

        consumed = consume_expiring_stock_batches(
            variant=self.variant,
            quantity=10,
            warehouse=Warehouse.default_id(),
        )

        self.assertEqual(consumed.quantity, Decimal("5"))
        first.refresh_from_db()
        second.refresh_from_db()
        self.assertEqual(_remaining(first), Decimal("0"))
        self.assertEqual(_remaining(second), Decimal("0"))

    def test_same_expiry_breaks_tie_by_created_at(self):
        # Two batches expiring the same day: the one created first is consumed
        # first (the secondary FIFO sort key).
        older = _make_batch(
            variant=self.variant,
            days=20,
            quantity="4",
            supplier=self.supplier,
        )
        newer = _make_batch(
            variant=self.variant,
            days=20,
            quantity="4",
            supplier=self.supplier,
            created_offset_seconds=60,
        )

        consumed = consume_expiring_stock_batches(
            variant=self.variant,
            quantity=4,
            warehouse=Warehouse.default_id(),
        )

        self.assertEqual(consumed.quantity, Decimal("4"))
        older.refresh_from_db()
        newer.refresh_from_db()
        self.assertEqual(_remaining(older), Decimal("0"))
        self.assertEqual(_remaining(newer), Decimal("4"))

    def test_non_expiry_product_is_a_noop(self):
        plain = _expiring_product(sku="CAN", tracks_expiry=False)
        plain_variant = plain.default_variant
        # A stray batch row exists, but the product no longer tracks expiry.
        batch = _make_batch(
            variant=plain_variant, days=10, quantity="5", supplier=self.supplier
        )

        consumed = consume_expiring_stock_batches(
            variant=plain_variant,
            quantity=3,
            warehouse=Warehouse.default_id(),
        )

        self.assertIsNone(consumed)
        batch.refresh_from_db()
        self.assertEqual(_remaining(batch), Decimal("5"))

    def test_non_positive_quantity_is_a_noop(self):
        batch = _make_batch(
            variant=self.variant, days=10, quantity="5", supplier=self.supplier
        )

        self.assertIsNone(
            consume_expiring_stock_batches(
                variant=self.variant,
                quantity=0,
                warehouse=Warehouse.default_id(),
            )
        )
        self.assertIsNone(
            consume_expiring_stock_batches(
                variant=self.variant,
                quantity=Decimal("-2"),
                warehouse=Warehouse.default_id(),
            )
        )
        batch.refresh_from_db()
        self.assertEqual(_remaining(batch), Decimal("5"))


# ---------------------------------------------------------------------------
# 2. EXPECTED-family movement snapshot accuracy (via the movement API)
# ---------------------------------------------------------------------------


class ExpectedMovementSnapshotTests(TestCase):
    def setUp(self):
        ensure_role_groups()
        self.manager = get_user_model().objects.create_user(
            username="exp-manager", password="pass"
        )
        self.manager.groups.add(Group.objects.get(name=MANAGER_GROUP))
        self.client = APIClient()
        self.client.force_authenticate(user=self.manager)
        self.product = create_product_with_default_variant(
            sku="EXP-SNAP", name="بضاعة", unit_price=Decimal("2.00")
        )
        self.variant = self.product.default_variant
        self.stock_item = StockItem.objects.create(
            variant=self.variant,
            quantity_on_hand=Decimal("4"),
            quantity_expected=Decimal("0"),
        )

    def _move(self, movement_type, quantity):
        return self.client.post(
            reverse("stockmovement-list"),
            {
                "variant": self.variant.pk,
                "movement_type": movement_type,
                "quantity": quantity,
            },
            format="json",
        )

    def test_expected_movement_records_expected_before_after(self):
        # EXPECTED bumps quantity_expected, leaves on_hand untouched.
        response = self._move(StockMovement.Type.EXPECTED, 6)

        self.assertEqual(response.status_code, status.HTTP_201_CREATED)
        movement = StockMovement.objects.get(pk=response.data["id"])
        self.assertEqual(movement.movement_type, StockMovement.Type.EXPECTED)
        self.assertEqual(movement.expected_before, Decimal("0"))
        self.assertEqual(movement.expected_after, Decimal("6"))
        self.assertEqual(movement.on_hand_before, Decimal("4"))
        self.assertEqual(movement.on_hand_after, Decimal("4"))
        self.stock_item.refresh_from_db()
        self.assertEqual(self.stock_item.quantity_expected, Decimal("6"))
        self.assertEqual(self.stock_item.quantity_on_hand, Decimal("4"))

    def test_receive_expected_moves_expected_into_on_hand(self):
        # Seed an expected balance, then receive part of it: on_hand rises and
        # expected falls by the same amount in a single audited movement.
        StockItem.objects.filter(pk=self.stock_item.pk).update(
            quantity_expected=Decimal("10")
        )

        response = self._move(StockMovement.Type.RECEIVE_EXPECTED, 4)

        self.assertEqual(response.status_code, status.HTTP_201_CREATED)
        movement = StockMovement.objects.get(pk=response.data["id"])
        self.assertEqual(movement.expected_before, Decimal("10"))
        self.assertEqual(movement.expected_after, Decimal("6"))
        self.assertEqual(movement.on_hand_before, Decimal("4"))
        self.assertEqual(movement.on_hand_after, Decimal("8"))
        self.stock_item.refresh_from_db()
        self.assertEqual(self.stock_item.quantity_on_hand, Decimal("8"))
        self.assertEqual(self.stock_item.quantity_expected, Decimal("6"))

    def test_cancel_expected_drops_expected_only(self):
        StockItem.objects.filter(pk=self.stock_item.pk).update(
            quantity_expected=Decimal("7")
        )

        response = self._move(StockMovement.Type.CANCEL_EXPECTED, 5)

        self.assertEqual(response.status_code, status.HTTP_201_CREATED)
        movement = StockMovement.objects.get(pk=response.data["id"])
        self.assertEqual(movement.expected_before, Decimal("7"))
        self.assertEqual(movement.expected_after, Decimal("2"))
        # on_hand never moves on a cancellation.
        self.assertEqual(movement.on_hand_before, Decimal("4"))
        self.assertEqual(movement.on_hand_after, Decimal("4"))
        self.stock_item.refresh_from_db()
        self.assertEqual(self.stock_item.quantity_expected, Decimal("2"))
        self.assertEqual(self.stock_item.quantity_on_hand, Decimal("4"))

    def test_cancel_expected_cannot_drive_expected_negative(self):
        StockItem.objects.filter(pk=self.stock_item.pk).update(
            quantity_expected=Decimal("3")
        )

        response = self._move(StockMovement.Type.CANCEL_EXPECTED, 5)

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        # Nothing committed: expected stays at 3 and no movement row is written.
        self.stock_item.refresh_from_db()
        self.assertEqual(self.stock_item.quantity_expected, Decimal("3"))
        self.assertFalse(
            StockMovement.objects.filter(variant=self.variant).exists()
        )


# ---------------------------------------------------------------------------
# 3. Multi-variant independence
# ---------------------------------------------------------------------------


class MultiVariantIsolationTests(TestCase):
    def setUp(self):
        ensure_role_groups()
        self.product = create_product_with_default_variant(
            sku="ISO-A", name="قميص", unit_price=Decimal("5.00")
        )
        self.variant_a = self.product.default_variant
        self.variant_b = ProductVariant.objects.create(
            product=self.product,
            name="Large",
            sku="ISO-B",
            unit_price=Decimal("7.50"),
        )
        self.stock_a = StockItem.objects.create(
            variant=self.variant_a, quantity_on_hand=Decimal("10")
        )
        self.stock_b = StockItem.objects.create(
            variant=self.variant_b, quantity_on_hand=Decimal("4")
        )

    def test_adjusting_variant_a_leaves_b_stock_and_prices_untouched(self):
        manager = get_user_model().objects.create_user(
            username="iso-manager", password="pass"
        )
        manager.groups.add(Group.objects.get(name=MANAGER_GROUP))
        client = APIClient()
        client.force_authenticate(user=manager)

        response = client.post(
            reverse("stockmovement-list"),
            {
                "variant": self.variant_a.pk,
                "movement_type": StockMovement.Type.DECREASE,
                "quantity": 3,
            },
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_201_CREATED)
        self.stock_a.refresh_from_db()
        self.stock_b.refresh_from_db()
        self.variant_a.refresh_from_db()
        self.variant_b.refresh_from_db()
        self.assertEqual(self.stock_a.quantity_on_hand, Decimal("7"))
        # Sibling variant's stock and BOTH prices are wholly unaffected.
        self.assertEqual(self.stock_b.quantity_on_hand, Decimal("4"))
        self.assertEqual(self.variant_a.unit_price, Decimal("5.00"))
        self.assertEqual(self.variant_b.unit_price, Decimal("7.50"))
        # The movement and its stock_item point at variant A only.
        movement = StockMovement.objects.get(pk=response.data["id"])
        self.assertEqual(movement.variant_id, self.variant_a.pk)
        self.assertEqual(movement.stock_item_id, self.stock_a.pk)
        self.assertFalse(
            StockMovement.objects.filter(variant=self.variant_b).exists()
        )

    def test_selling_one_variant_does_not_consume_the_other(self):
        # Sell 6 of variant A through the real checkout path; B is never queried.
        user = get_user_model().objects.create_user(
            username="iso-cashier", password="pass"
        )
        session = RegisterSession.objects.create(
            owner=user, owner_key=f"user:{user.pk}"
        )

        order = checkout_order(
            register_session=session,
            lines_data=[{"variant": self.variant_a, "quantity": Decimal("6")}],
            payments_data=[{"method": "cash", "amount": Decimal("30.00")}],
        )

        self.assertEqual(order.total, Decimal("30.00"))
        self.stock_a.refresh_from_db()
        self.stock_b.refresh_from_db()
        self.assertEqual(self.stock_a.quantity_on_hand, Decimal("4"))
        self.assertEqual(self.stock_b.quantity_on_hand, Decimal("4"))


# ---------------------------------------------------------------------------
# 4. Unit conversion round-trip
# ---------------------------------------------------------------------------


class UnitConversionRoundTripTests(TestCase):
    def setUp(self):
        # Base unit is kg (fractional) so the sack/box factor can be non-integer.
        self.product = Product.objects.create(name="سكر", unit=Product.Unit.KILOGRAM)
        self.variant = ProductVariant.objects.create(
            product=self.product,
            sku="SUGAR",
            unit_price=Decimal("2.00"),
            is_default=True,
        )

    def _add_unit(self, code, factor, price=None):
        uom = UnitOfMeasure.objects.get(code=code)
        return ProductUnit.objects.create(
            product=self.product,
            unit=uom,
            factor_to_base=Decimal(factor),
            price=None if price is None else Decimal(price),
        )

    def test_to_base_quantity_scales_by_integer_factor(self):
        self._add_unit("box", "25")
        self.product.refresh_from_db()
        resolved = resolve_unit(self.product, "box")

        # 2 sacks of 25 kg = 50 kg in the base unit.
        self.assertEqual(to_base_quantity(Decimal("2"), resolved), Decimal("50.000"))
        # Derived price = base price * factor when no custom price is set.
        self.assertEqual(unit_sale_price(self.variant, resolved), Decimal("50.00"))

    def test_non_integer_factor_round_trips(self):
        # 1 "box" here is half a kg (a fractional packaging factor).
        self._add_unit("box", "0.5")
        self.product.refresh_from_db()
        resolved = resolve_unit(self.product, "box")

        base = to_base_quantity(Decimal("3"), resolved)
        self.assertEqual(base, Decimal("1.500"))
        # Round trip: dividing the base back out by the factor recovers the count.
        self.assertEqual(base / resolved.factor, Decimal("3"))
        self.assertEqual(unit_sale_price(self.variant, resolved), Decimal("1.00"))

    def test_custom_product_unit_price_overrides_derived(self):
        # Wholesale sack priced BELOW 25x the per-kg price (volume discount).
        self._add_unit("box", "25", price="40.00")
        self.product.refresh_from_db()
        resolved = resolve_unit(self.product, "box")

        # Quantity conversion is unchanged by the custom price.
        self.assertEqual(to_base_quantity(Decimal("1"), resolved), Decimal("25.000"))
        # Price uses the override (40.00), not the derived 50.00.
        self.assertEqual(unit_sale_price(self.variant, resolved), Decimal("40.00"))

    def test_base_unit_resolves_to_factor_one(self):
        # No unit / the base code resolves to the implicit base (factor 1, var price).
        resolved = resolve_unit(self.product, None)

        self.assertTrue(resolved.is_base)
        self.assertEqual(resolved.factor, Decimal("1"))
        self.assertEqual(to_base_quantity(Decimal("3.5"), resolved), Decimal("3.500"))
        self.assertEqual(unit_sale_price(self.variant, resolved), Decimal("2.00"))


# ---------------------------------------------------------------------------
# 5. Oversell negative movement (no floor under oversell)
# ---------------------------------------------------------------------------


class OversellNegativeMovementTests(TestCase):
    def setUp(self):
        self.user = get_user_model().objects.create_user(
            username="oversell-cashier", password="pass"
        )
        self.product = create_product_with_default_variant(
            sku="OVS", name="منتج", unit_price=Decimal("3.00")
        )
        self.variant = self.product.default_variant
        self.stock_item = StockItem.objects.create(
            variant=self.variant, quantity_on_hand=Decimal("2")
        )

    def test_oversell_checkout_records_negative_on_hand_after(self):
        # Overselling on: selling 5 against an on-hand of 2 succeeds and drives
        # stock to -3. The movement faithfully records the negative result; there
        # is intentionally NO floor under oversell.
        ShopSettings.load()  # materialize the pk=1 singleton before updating it
        ShopSettings.objects.filter(pk=1).update(allow_overselling=True)
        session = RegisterSession.objects.create(
            owner=self.user, owner_key=f"user:{self.user.pk}"
        )

        order = checkout_order(
            register_session=session,
            lines_data=[{"variant": self.variant, "quantity": Decimal("5")}],
            payments_data=[{"method": "cash", "amount": Decimal("15.00")}],
        )

        self.assertEqual(order.total, Decimal("15.00"))
        self.stock_item.refresh_from_db()
        self.assertEqual(self.stock_item.quantity_on_hand, Decimal("-3"))

        movement = StockMovement.objects.get(variant=self.variant)
        self.assertEqual(movement.movement_type, StockMovement.Type.DECREASE)
        self.assertEqual(movement.quantity, Decimal("5"))
        self.assertEqual(movement.on_hand_before, Decimal("2"))
        self.assertEqual(movement.on_hand_after, Decimal("-3"))

    def test_overselling_off_blocks_the_sale_and_leaves_stock(self):
        # Control: with the default (overselling off) the same sale is rejected
        # and stock is untouched, so the negative case above is genuinely gated.
        self.assertFalse(ShopSettings.load().allow_overselling)
        session = RegisterSession.objects.create(
            owner=self.user, owner_key=f"user:{self.user.pk}"
        )

        from rest_framework.exceptions import ValidationError

        with self.assertRaises(ValidationError):
            checkout_order(
                register_session=session,
                lines_data=[{"variant": self.variant, "quantity": Decimal("5")}],
                payments_data=[{"method": "cash", "amount": Decimal("15.00")}],
            )

        self.stock_item.refresh_from_db()
        self.assertEqual(self.stock_item.quantity_on_hand, Decimal("2"))
        self.assertFalse(
            StockMovement.objects.filter(variant=self.variant).exists()
        )

    def test_service_layer_decrease_below_zero_is_recorded(self):
        # The low-level service has no floor either: a snapshot/decrement that
        # crosses zero still writes a faithful negative on_hand_after movement.
        before = stock_snapshot(self.stock_item)
        self.stock_item.quantity_on_hand -= Decimal("5")
        self.stock_item.save(update_fields=["quantity_on_hand", "updated_at"])

        movement = create_stock_movement(
            stock_item=self.stock_item,
            movement_type=StockMovement.Type.DECREASE,
            quantity=Decimal("5"),
            note="manual oversell",
            created_by=None,
            before=before,
        )

        self.assertIsNotNone(movement)
        self.assertEqual(movement.on_hand_before, Decimal("2"))
        self.assertEqual(movement.on_hand_after, Decimal("-3"))


# ---------------------------------------------------------------------------
# 6. Stock-count delta composes with a mid-count INCREASE
# ---------------------------------------------------------------------------


class StockCountMidCountIncreaseTests(TestCase):
    def setUp(self):
        ensure_role_groups()
        self.manager = get_user_model().objects.create_user(
            username="mci-manager", password="pass"
        )
        self.manager.groups.add(Group.objects.get(name=MANAGER_GROUP))
        self.client = APIClient()
        self.client.force_authenticate(user=self.manager)
        self.product = create_product_with_default_variant(
            sku="MCI", name="صنف", unit_price=Decimal("1.00")
        )
        self.variant = self.product.default_variant
        self.stock_item = StockItem.objects.create(
            variant=self.variant, quantity_on_hand=Decimal("50")
        )

    def test_mid_count_increase_uses_delta_and_flags_stale(self):
        # Count finds 48 against expected 50 (delta -2). Then a restock of 10
        # lands mid-count, taking on-hand to 60. Apply must use the -2 delta
        # against the CURRENT 60 -> 58 (not set-to-48), and flag the line stale.
        start = self.client.post(
            reverse("stock-count-start"), {"scope": "full"}, format="json"
        )
        self.assertEqual(start.status_code, status.HTTP_201_CREATED)
        count_id = start.data["id"]

        counted = self.client.post(
            reverse("stock-count-count", args=[count_id]),
            {"variant": self.variant.pk, "counted_quantity": "48", "mode": "replace"},
            format="json",
        )
        self.assertEqual(counted.status_code, status.HTTP_200_OK)
        self.assertEqual(
            Decimal(str(counted.data["expected_quantity"])), Decimal("50")
        )

        # Mid-count restock via the proven movement path.
        restock = self.client.post(
            reverse("stockmovement-list"),
            {
                "variant": self.variant.pk,
                "movement_type": StockMovement.Type.INCREASE,
                "quantity": 10,
            },
            format="json",
        )
        self.assertEqual(restock.status_code, status.HTTP_201_CREATED)
        self.stock_item.refresh_from_db()
        self.assertEqual(self.stock_item.quantity_on_hand, Decimal("60"))

        applied = self.client.post(
            reverse("stock-count-apply", args=[count_id]), format="json"
        )
        self.assertEqual(applied.status_code, status.HTTP_200_OK)

        self.stock_item.refresh_from_db()
        # Delta (-2) composed onto the now-60 on-hand => 58, NOT set-to-counted-48.
        self.assertEqual(self.stock_item.quantity_on_hand, Decimal("58"))

        from .models import StockCountLine

        line = StockCountLine.objects.get(
            stock_count=count_id, variant=self.variant
        )
        self.assertTrue(line.applied)
        self.assertTrue(line.stale_at_apply)
        self.assertEqual(line.on_hand_at_apply, Decimal("60"))

        # The apply wrote a DECREASE of 2 spanning the post-restock on-hand.
        applied_movement = line.movement
        self.assertIsNotNone(applied_movement)
        self.assertEqual(
            applied_movement.movement_type, StockMovement.Type.DECREASE
        )
        self.assertEqual(applied_movement.quantity, Decimal("2"))
        self.assertEqual(applied_movement.on_hand_before, Decimal("60"))
        self.assertEqual(applied_movement.on_hand_after, Decimal("58"))
