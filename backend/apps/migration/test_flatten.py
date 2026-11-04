"""Folding alias variants into one, on a shop that has traded on them."""

from decimal import Decimal

from django.contrib.contenttypes.models import ContentType
from django.core.management import call_command
from django.db import transaction
from django.test import TestCase
from django.utils import timezone
from rest_framework.test import APIClient

from apps.catalog.models import Product, ProductVariant, ProductVariantBarcode
from apps.catalog.testing import create_product_with_default_variant
from apps.inventory.models import (
    StockCount,
    StockCountLine,
    StockItem,
    StockLedgerEntry,
    StockMovement,
    StockValuationBin,
    Warehouse,
)
from apps.inventory.services import (
    create_stock_movement,
    lock_stock_item,
    save_stock_item_quantities,
    stock_snapshot,
)
from apps.inventory.reporting import shrinkage_value
from apps.reports.builders.balance_sheet import opening_stock_recorded
from apps.sales.models import RegisterSession
from apps.sales.serializers import CheckoutLineSerializer
from apps.sales.services import checkout_order, return_order_items

from . import flatten
from .models import MigrationIdentityMap, MigrationSource, VariantMerge

_TILL = 0


def _move(variant, kind, quantity, *, cost=None):
    """A stock movement the way the services write one, valued."""
    with transaction.atomic():
        item = lock_stock_item(variant=variant, warehouse=Warehouse.default_id())
        before = stock_snapshot(item)
        delta = Decimal(quantity)
        item.quantity_on_hand += (
            delta if kind == StockMovement.Type.INCREASE else -delta
        )
        save_stock_item_quantities(item)
        return create_stock_movement(
            stock_item=item,
            movement_type=kind,
            quantity=delta,
            note="",
            created_by=None,
            before=before,
            unit_cost=None if cost is None else Decimal(cost),
        )


def _receive(variant, quantity, cost):
    return _move(variant, StockMovement.Type.INCREASE, quantity, cost=cost)


def _sell(variant, quantity=1):
    global _TILL
    _TILL += 1
    session = RegisterSession.objects.create(
        owner_key=f"flatten-till-{_TILL}",
        status=RegisterSession.Status.OPEN,
        opening_cash=Decimal("0.00"),
    )
    return checkout_order(
        register_session=session,
        lines_data=[{"variant": variant, "quantity": Decimal(quantity)}],
        payments_data=[
            {"method": "cash", "amount": variant.unit_price * Decimal(quantity)}
        ],
    )


class Shop(TestCase):
    def setUp(self):
        self.product = create_product_with_default_variant(
            name="بسكويت", sku="P1", barcode="P1", unit_price=Decimal("5.00")
        )
        self.survivor = self.product.default_variant
        self.alias = self.make_alias("A1")

    def make_alias(self, code, *, price="5.00", product=None, imported=True, **fields):
        product = product or self.product
        alias = ProductVariant.objects.create(
            product=product,
            sku=code,
            barcode=code,
            unit_price=Decimal(price),
            is_default=False,
            **fields,
        )
        if imported:
            source, _ = MigrationSource.objects.get_or_create(
                name="fahd", defaults={"system_key": "fahd"}
            )
            MigrationIdentityMap.objects.create(
                source=source,
                entity_type="variant",
                source_key=code,
                target_content_type=ContentType.objects.get_for_model(ProductVariant),
                target_object_id=alias.pk,
            )
        return alias

    def on_hand(self, variant):
        return sum(
            (item.quantity_on_hand for item in StockItem.objects.filter(variant=variant)),
            Decimal("0"),
        )


class MergeTests(Shop):
    def test_a_traded_alias_folds_with_every_number_intact(self):
        _receive(self.survivor, 10, "2.00")
        _receive(self.alias, 4, "3.00")
        _sell(self.survivor, 2)
        order = _sell(self.alias, 3)
        before = flatten.shop_totals()

        report = flatten.run(apply=True)

        self.assertEqual(report.merged_variants, 1)
        self.assertEqual(report.refused, [])
        self.assertEqual(flatten.shop_totals(), before)
        # On hand adds up, in one row, and the alias holds nothing.
        self.assertEqual(self.on_hand(self.survivor), Decimal("9"))
        self.assertFalse(StockItem.objects.filter(variant=self.alias).exists())
        # The old sale reads as a sale of the survivor, at what it was sold for.
        line = order.lines.get()
        self.assertEqual(line.variant_id, self.survivor.pk)
        self.assertEqual(line.quantity, Decimal("3"))
        # Value is carried: 8×2 + 1×3, the units each bin still held.
        row = StockValuationBin.objects.get(variant=self.survivor)
        self.assertEqual(row.quantity, Decimal("9"))
        self.assertEqual(
            sum(
                entry.value_change
                for entry in StockLedgerEntry.objects.filter(variant=self.survivor)
            ),
            row.stock_value,
        )
        self.alias.refresh_from_db()
        self.assertFalse(self.alias.is_active)
        self.assertEqual(self.alias.barcode, "")
        self.assertEqual(self.alias.merged_into_id, self.survivor.pk)
        self.assertTrue(
            ProductVariantBarcode.objects.filter(
                variant=self.survivor, barcode="A1"
            ).exists()
        )
        self.assertEqual(VariantMerge.objects.get().alias_sku, "A1")

    def test_a_negative_alias_comes_off_the_survivors_shelf(self):
        # What a real shop has: goods received under one code, rung under another.
        _receive(self.survivor, 5, "10.00")
        _move(self.alias, StockMovement.Type.DECREASE, 4)

        flatten.run(apply=True)

        self.assertEqual(self.on_hand(self.survivor), Decimal("1"))
        row = StockValuationBin.objects.get(variant=self.survivor)
        # One piece at the shelf's rate, not whatever (50 - 0) / 1 would invent.
        self.assertEqual(row.valuation_rate, Decimal("10"))
        self.assertEqual(row.stock_value, Decimal("10"))

    def test_a_negative_alias_beside_a_survivor_with_no_bin_keeps_its_rate(self):
        _receive(self.alias, 2, "6.00")
        _move(self.alias, StockMovement.Type.DECREASE, 5)
        flatten.run(apply=True)
        row = StockValuationBin.objects.get(variant=self.survivor)
        self.assertEqual(row.quantity, Decimal("-3"))
        self.assertEqual(row.valuation_rate, Decimal("6"))

    def test_a_product_with_nothing_on_its_aliases_writes_no_history(self):
        _receive(self.survivor, 5, "2.00")
        before = list(
            StockMovement.objects.filter(variant=self.survivor).values_list(
                "id", "on_hand_after"
            )
        )
        flatten.run(apply=True)
        self.assertEqual(
            list(
                StockMovement.objects.filter(variant=self.survivor).values_list(
                    "id", "on_hand_after"
                )
            ),
            before,
        )

    def test_an_old_sale_of_the_alias_can_still_be_returned(self):
        _receive(self.survivor, 5, "2.00")
        _receive(self.alias, 4, "3.00")
        order = _sell(self.alias, 3)
        line = order.lines.get()
        flatten.run(apply=True)
        on_hand = self.on_hand(self.survivor)

        line.refresh_from_db()
        return_order_items(order=order, lines=[(line, 1)], reason="رجع")

        # Back on the one shelf that exists, not on the tombstone.
        self.assertEqual(self.on_hand(self.survivor), on_hand + 1)
        self.assertFalse(StockItem.objects.filter(variant=self.alias).exists())

    def test_the_shop_can_sell_the_survivor_after_a_merge(self):
        _receive(self.alias, 4, "3.00")
        flatten.run(apply=True)
        self.survivor.refresh_from_db()
        _sell(self.survivor, 2)
        self.assertEqual(self.on_hand(self.survivor), Decimal("2"))
        self.assertEqual(
            StockValuationBin.objects.get(variant=self.survivor).quantity, Decimal("2")
        )

    def _shelf_sold_under_the_other_code(self):
        """Received under one code at 10, rung under the other at a cost of 1."""
        _receive(self.survivor, 5, "10.00")
        _receive(self.alias, 1, "1.00")
        _move(self.alias, StockMovement.Type.DECREASE, 5)
        today = timezone.localdate()
        return today, today

    def test_folding_a_negative_alias_is_no_loss_and_no_gain(self):
        start, end = self._shelf_sold_under_the_other_code()
        shrinkage = shrinkage_value(start, end)
        flatten.run(apply=True)
        # The restated value is on the ledger, and is nobody's profit or loss.
        self.assertEqual(shrinkage_value(start, end), shrinkage)
        entry = StockLedgerEntry.objects.get(
            voucher_type=StockLedgerEntry.VoucherType.CATALOG_MERGE
        )
        self.assertNotEqual(entry.value_change, 0)
        self.assertEqual(entry.quantity_change, 0)

    def test_the_dry_run_states_the_stock_value_change_exactly(self):
        self._shelf_sold_under_the_other_code()
        estimate = flatten.run(apply=False).value_restated
        self.assertEqual(StockLedgerEntry.objects.filter(
            voucher_type=StockLedgerEntry.VoucherType.CATALOG_MERGE
        ).count(), 0)
        actual = flatten.run(apply=True, run_key="r").value_restated
        self.assertNotEqual(actual, 0)
        self.assertEqual(estimate, actual)

    def test_the_dry_run_names_a_product_the_merge_would_put_below_cost(self):
        # Price 5. The shelf cost 2, but the alias's pieces cost 50.
        _receive(self.survivor, 1, "2.00")
        _receive(self.alias, 9, "50.00")
        report = flatten.run(apply=False)
        self.assertEqual([row[0] for row in report.newly_below_cost], [self.survivor.pk])

    def test_the_balance_sheet_does_not_read_a_merge_as_trading(self):
        start, end = self._shelf_sold_under_the_other_code()
        before = opening_stock_recorded(start=start, end=end)
        flatten.run(apply=True)
        entry = StockLedgerEntry.objects.get(
            voucher_type=StockLedgerEntry.VoucherType.CATALOG_MERGE
        )
        self.assertEqual(
            opening_stock_recorded(start=start, end=end),
            before + entry.value_change.quantize(Decimal("0.01")),
        )

    def test_a_sale_after_a_merge_is_costed_at_the_shelf_rate(self):
        self.survivor.unit_price = Decimal("20.00")
        self.survivor.save()
        self.alias.unit_price = Decimal("20.00")
        self.alias.save()
        self._shelf_sold_under_the_other_code()
        flatten.run(apply=True)
        self.survivor.refresh_from_db()
        order = _sell(self.survivor, 1)
        # Not the 50-odd a plain value / quantity would have invented.
        self.assertEqual(order.lines.get().unit_cost, Decimal("10.00"))

    def test_running_balances_read_as_one_history(self):
        _receive(self.survivor, 10, "2.00")
        _receive(self.alias, 4, "3.00")
        _sell(self.alias, 1)
        flatten.run(apply=True)
        movements = list(
            StockMovement.objects.filter(variant=self.survivor).order_by(
                "created_at", "id"
            )
        )
        self.assertEqual(movements[-1].on_hand_after, Decimal("13"))
        for earlier, later in zip(movements, movements[1:]):
            self.assertEqual(earlier.on_hand_after, later.on_hand_before)
        entries = list(
            StockLedgerEntry.objects.filter(
                variant=self.survivor, quantity_change__isnull=False
            ).order_by("posting_at", "id")
        )
        self.assertEqual(entries[-1].balance_quantity, Decimal("13"))

    def test_running_twice_changes_nothing(self):
        _receive(self.alias, 4, "3.00")
        flatten.run(apply=True)
        totals = flatten.shop_totals()
        report = flatten.run(apply=True)
        self.assertEqual(report.merged_variants, 0)
        self.assertEqual(flatten.shop_totals(), totals)
        self.assertEqual(VariantMerge.objects.count(), 1)

    def test_a_dry_run_writes_nothing(self):
        _receive(self.alias, 4, "3.00")
        report = flatten.run(apply=False)
        self.assertEqual(len(report.automatic), 1)
        self.alias.refresh_from_db()
        self.assertTrue(self.alias.is_active)
        self.assertEqual(self.on_hand(self.alias), Decimal("4"))

    def test_a_retired_pack_pseudo_variant_folds_too(self):
        pack = self.make_alias("PACK")
        pack.barcode = ""
        pack.is_active = False
        pack.save()
        flatten.run(apply=True)
        pack.refresh_from_db()
        self.assertEqual(pack.merged_into_id, self.survivor.pk)

    def test_the_survivor_takes_the_code_when_it_has_none(self):
        self.survivor.barcode = ""
        self.survivor.save()
        flatten.run(apply=True)
        self.survivor.refresh_from_db()
        self.assertEqual(self.survivor.barcode, "A1")

    def test_every_reference_has_somewhere_to_go(self):
        """A table added later is moved by default; this names what is special."""
        keys = {
            (model._meta.app_label, model._meta.model_name)
            for model, _ in flatten.variant_references()
        }
        self.assertIn(("sales", "orderline"), keys)
        self.assertIn(("inventory", "stockledgerentry"), keys)
        self.assertIn(("purchasing", "purchaseline"), keys)
        self.assertIn(("purchasing", "supplierpurchaseaffinity"), keys)
        # Through tables go through their manager, or a clash would raise.
        self.assertFalse(any(model._meta.auto_created for model, _ in flatten.variant_references()))


class ReviewTests(Shop):
    def reasons(self, alias):
        for candidate in flatten.scan_candidates():
            if candidate.alias_id == alias.pk:
                return candidate.reasons
        return None

    def test_a_different_price_waits_for_a_person(self):
        alias = self.make_alias("A2", price="7.00")
        self.assertEqual(self.reasons(alias), [flatten.PRICE_DIFFERS])
        flatten.run(apply=True)
        alias.refresh_from_db()
        self.assertTrue(alias.is_active)
        self.assertEqual(alias.unit_price, Decimal("7.00"))

    def test_the_owner_can_overrule_a_price_difference(self):
        alias = self.make_alias("A2", price="7.00")
        flatten.run(apply=True, include_reasons=[flatten.PRICE_DIFFERS])
        alias.refresh_from_db()
        self.assertEqual(alias.merged_into_id, self.survivor.pk)

    def test_a_variant_somebody_built_is_left_alone(self):
        alias = self.make_alias("HANDMADE", imported=False)
        alias.barcode = "OTHER"
        alias.save()
        self.assertIn(flatten.NOT_IMPORTED, self.reasons(alias))

    def test_an_open_count_waits(self):
        count = StockCount.objects.create(
            warehouse_id=Warehouse.default_id(), status=StockCount.Status.IN_PROGRESS
        )
        StockCountLine.objects.create(
            stock_count=count,
            variant=self.alias,
            counted_quantity=1,
            expected_quantity=1,
            counted_at=timezone.now(),
        )
        self.assertIn(flatten.OPEN_COUNT, self.reasons(self.alias))

    def test_identified_stock_is_never_taken(self):
        self.product.tracking_mode = Product.TrackingMode.SERIAL
        self.product.save()
        self.assertIn(flatten.IDENTIFIED_STOCK, self.reasons(self.alias))

    def test_a_finished_count_that_counted_both_keeps_its_two_figures(self):
        count = StockCount.objects.create(
            warehouse_id=Warehouse.default_id(), status=StockCount.Status.APPLIED
        )
        for variant in (self.survivor, self.alias):
            StockCountLine.objects.create(
                stock_count=count,
                variant=variant,
                counted_quantity=2,
                expected_quantity=2,
                counted_at=timezone.now(),
            )
        report = flatten.run(apply=True)
        self.assertEqual(report.refused, [])
        self.assertEqual(count.lines.count(), 2)


class TillTests(Shop):
    def test_a_cart_holding_the_old_id_still_sells(self):
        _receive(self.survivor, 5, "2.00")
        stale_id = self.alias.pk
        flatten.run(apply=True)
        field = CheckoutLineSerializer().fields["variant"]
        self.assertEqual(field.to_internal_value(stale_id).pk, self.survivor.pk)

    def test_scanning_the_old_code_finds_the_survivor(self):
        from django.contrib.auth import get_user_model

        flatten.run(apply=True)
        user = get_user_model().objects.create_superuser("owner", password="x")
        client = APIClient()
        client.force_authenticate(user)
        response = client.get("/api/product-variants/", {"barcode": "A1"})
        rows = response.json()["results"]
        self.assertEqual([row["id"] for row in rows], [self.survivor.pk])
        self.assertIn("A1", rows[0]["extra_barcodes"])

    def test_a_frozen_win8_till_can_ring_the_old_code(self):
        """It keeps only a row whose ``barcode`` is the scan (v0.6.1-compat)."""
        from django.contrib.auth import get_user_model

        flatten.run(apply=True)
        user = get_user_model().objects.create_superuser("owner", password="x")
        client = APIClient()
        client.force_authenticate(user)
        frozen = client.get(
            "/api/product-variants/",
            {"barcode": "A1"},
            headers={"X-Pointy-App-Version": "0.6.1-compat"},
        ).json()["results"]
        self.assertEqual(
            [row["id"] for row in frozen if row["barcode"].strip() == "A1"],
            [self.survivor.pk],
        )
        current = client.get(
            "/api/product-variants/",
            {"barcode": "A1"},
            headers={"X-Pointy-App-Version": "0.9.9"},
        ).json()["results"]
        self.assertEqual(current[0]["barcode"], "P1")

    def test_the_product_reads_as_one_variant(self):
        from django.contrib.auth import get_user_model

        flatten.run(apply=True)
        user = get_user_model().objects.create_superuser("owner", password="x")
        client = APIClient()
        client.force_authenticate(user)
        payload = client.get(f"/api/products/{self.product.pk}/").json()
        self.assertEqual([row["id"] for row in payload["variants"]], [self.survivor.pk])

    def test_a_sale_racing_the_merge_is_swept(self):
        _receive(self.survivor, 5, "2.00")
        flatten.run(apply=True)
        # What a checkout past validation does the instant the merge commits.
        _move(self.alias, StockMovement.Type.DECREASE, 1)
        report = flatten.run(apply=True)
        self.assertEqual(report.swept, 1)
        self.assertEqual(self.on_hand(self.survivor), Decimal("4"))
        self.assertFalse(StockItem.objects.filter(variant=self.alias).exists())


class CommandTests(Shop):
    def test_dry_run_is_the_default(self):
        call_command("flatten_imported_variants", verbosity=0)
        self.alias.refresh_from_db()
        self.assertIsNone(self.alias.merged_into_id)

    def test_apply(self):
        call_command("flatten_imported_variants", "--apply", verbosity=0)
        self.alias.refresh_from_db()
        self.assertEqual(self.alias.merged_into_id, self.survivor.pk)
