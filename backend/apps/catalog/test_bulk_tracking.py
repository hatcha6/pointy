"""Moving a shelf of counted products onto expiry tracking, and reminders."""

from datetime import timedelta
from decimal import Decimal

from django.contrib.auth import get_user_model
from django.db import connection, transaction
from django.test import TestCase
from django.test.utils import CaptureQueriesContext
from django.utils import timezone
from rest_framework import serializers
from rest_framework.test import APIClient

from apps.inventory.expiry_reminders import due_reminders
from apps.inventory.integrity import tracking_invariant_violations
from apps.inventory.models import (
    StockBatch,
    StockBatchBalance,
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
from apps.notifications.models import BusinessNotification
from apps.notifications.services import sync_business_notifications
from apps.sales.models import RegisterSession
from apps.sales.services import checkout_order

from .models import Product
from .testing import create_product_with_default_variant

_TILL = 0
EVERYTHING = {"match": "all", "conditions": []}


def stock(variant, quantity, cost="2.00"):
    quantity = Decimal(quantity)
    with transaction.atomic():
        item = lock_stock_item(variant=variant, warehouse=Warehouse.default_id())
        before = stock_snapshot(item)
        item.quantity_on_hand += quantity
        save_stock_item_quantities(item)
        create_stock_movement(
            stock_item=item,
            movement_type=(
                StockMovement.Type.INCREASE if quantity > 0 else StockMovement.Type.DECREASE
            ),
            quantity=abs(quantity),
            note="",
            created_by=None,
            before=before,
            unit_cost=Decimal(cost) if quantity > 0 else None,
        )


def sell(variant, quantity=1):
    global _TILL
    _TILL += 1
    session = RegisterSession.objects.create(
        owner_key=f"bulk-tracking-till-{_TILL}",
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


class Base(TestCase):
    def setUp(self):
        self.user = get_user_model().objects.create_superuser("owner", password="x")
        self.client = APIClient()
        self.client.force_authenticate(self.user)

    def product(self, sku):
        return create_product_with_default_variant(
            name=f"صنف {sku}", sku=sku, unit_price=Decimal("5.00")
        )

    def preview(self, **body):
        body.setdefault("filter", EVERYTHING)
        response = self.client.post(
            "/api/bulk-tracking-changes/preview/", body, format="json"
        )
        self.assertEqual(response.status_code, 200, response.content)
        return response.json()

    def apply(self, ids, **body):
        body.setdefault("filter", EVERYTHING)
        response = self.client.post(
            "/api/bulk-tracking-changes/apply/", {**body, "product_ids": ids}, format="json"
        )
        self.assertEqual(response.status_code, 200, response.content)
        return response.json()


class BulkTrackingTests(Base):
    def test_a_stocked_product_moves_with_its_quantity_and_value(self):
        product = self.product("A")
        variant = product.default_variant
        stock(variant, 10, "2.00")
        value = StockValuationBin.objects.get(variant=variant).stock_value

        preview = self.preview(tracking="expiry")
        self.assertEqual(preview["summary"]["change"], 1)
        self.assertEqual(preview["results"][0]["warnings"], ["undated_stock"])

        result = self.apply([product.pk], tracking="expiry")
        self.assertEqual(result, {"done": 1, "blocked": 0, "failures": []})

        product.refresh_from_db()
        self.assertEqual(product.tracking_mode, Product.TrackingMode.BATCH)
        self.assertTrue(product.expiry_required)
        self.assertIsNotNone(product.tracking_mode_since)
        balance = StockBatchBalance.objects.get(variant=variant)
        self.assertEqual(balance.remaining_quantity, Decimal("10"))
        self.assertIsNone(balance.batch.expiry_date)
        self.assertTrue(balance.batch.code_is_generated)
        self.assertEqual(variant.quantity_on_hand, Decimal("10"))
        self.assertEqual(StockValuationBin.objects.get(variant=variant).stock_value, value)
        self.assertEqual(tracking_invariant_violations([variant.pk]), [])

    def test_the_stock_can_still_leave_afterwards(self):
        product = self.product("A")
        variant = product.default_variant
        stock(variant, 3)
        self.apply([product.pk], tracking="expiry")
        variant.refresh_from_db()
        sell(variant, 2)
        self.assertEqual(variant.quantity_on_hand, Decimal("1"))
        self.assertEqual(
            StockBatchBalance.objects.get(variant=variant).remaining_quantity,
            Decimal("1"),
        )
        self.assertEqual(tracking_invariant_violations([variant.pk]), [])

    def test_a_negative_shelf_is_refused_and_the_others_go_through(self):
        short = self.product("SHORT")
        stock(short.default_variant, -2)
        fine = self.product("FINE")
        stock(fine.default_variant, 4)

        preview = self.preview(tracking="expiry")
        self.assertEqual(preview["summary"]["blocked"], 1)
        self.assertEqual(preview["summary"]["change"], 1)
        refused = next(row for row in preview["results"] if row["product"] == short.pk)
        self.assertIn("بالسالب", refused["message"])

        result = self.apply([short.pk, fine.pk], tracking="expiry")
        self.assertEqual(result["done"], 1)
        self.assertEqual(result["blocked"], 1)
        short.refresh_from_db()
        fine.refresh_from_db()
        self.assertEqual(short.tracking_mode, Product.TrackingMode.QUANTITY)
        self.assertEqual(fine.tracking_mode, Product.TrackingMode.BATCH)

    def test_an_empty_shelf_is_warned_about_because_the_till_will_refuse_it(self):
        product = self.product("EMPTY")
        preview = self.preview(tracking="expiry")
        self.assertEqual(preview["results"][0]["warnings"], ["empty_shelf"])
        self.apply([product.pk], tracking="expiry")
        variant = product.default_variant
        variant.refresh_from_db()
        with self.assertRaises(serializers.ValidationError):
            sell(variant, 1)

    def test_applying_twice_is_harmless(self):
        product = self.product("A")
        stock(product.default_variant, 5)
        self.apply([product.pk], tracking="expiry")
        self.apply([product.pk], tracking="expiry")
        self.assertEqual(StockBatch.objects.filter(variant__product=product).count(), 1)
        self.assertEqual(self.preview(tracking="expiry")["summary"]["same"], 1)

    def test_a_service_is_not_tracked(self):
        product = self.product("SVC")
        product.is_service = True
        product.save()
        self.assertEqual(self.preview(tracking="expiry")["summary"]["blocked"], 1)

    def test_the_filter_narrows_it(self):
        chosen = self.product("A")
        other = self.product("B")
        preview = self.preview(
            tracking="expiry",
            filter={
                "match": "all",
                "conditions": [
                    {"field": "product", "op": "in", "value": [chosen.pk]},
                ],
            },
        )
        self.assertEqual([row["product"] for row in preview["results"]], [chosen.pk])
        self.assertNotEqual(chosen.pk, other.pk)

    def test_previewing_thirteen_thousand_is_not_a_query_per_product(self):
        for number in range(30):
            stock(self.product(f"Q{number}").default_variant, 1)
        with CaptureQueriesContext(connection) as few:
            self.preview(tracking="expiry")
        for number in range(30, 60):
            stock(self.product(f"Q{number}").default_variant, 1)
        with CaptureQueriesContext(connection) as many:
            self.preview(tracking="expiry")
        self.assertEqual(len(few), len(many))


class ReminderTests(Base):
    def setUp(self):
        super().setUp()
        self.product_row = self.product("R")
        self.variant = self.product_row.default_variant
        stock(self.variant, 6)
        self.soon = timezone.localdate() + timedelta(days=5)

    def alerts(self):
        sync_business_notifications()
        return BusinessNotification.objects.filter(code="inventory.expiry_reminder")

    def test_stating_a_date_raises_an_alert(self):
        response = self.client.patch(
            f"/api/product-variants/{self.variant.pk}/",
            {"expiry_reminder_date": self.soon.isoformat()},
            format="json",
        )
        self.assertEqual(response.status_code, 200, response.content)
        self.assertEqual(response.json()["expiry_reminder_date"], self.soon.isoformat())
        alert = self.alerts().get(status=BusinessNotification.Status.ACTIVE)
        self.assertEqual(alert.payload["quantity"], 6.0)
        self.assertEqual(alert.payload["expiry_date"], self.soon.isoformat())

    def test_it_never_stops_a_sale_even_after_the_date_has_passed(self):
        self.variant.expiry_reminder_date = timezone.localdate() - timedelta(days=30)
        self.variant.save()
        sell(self.variant, 1)
        self.assertEqual(self.variant.quantity_on_hand, Decimal("5"))
        self.assertFalse(StockBatch.objects.filter(variant=self.variant).exists())

    def test_a_far_date_stays_quiet(self):
        self.variant.expiry_reminder_date = timezone.localdate() + timedelta(days=300)
        self.variant.save()
        self.assertEqual(due_reminders(window_end=timezone.localdate() + timedelta(days=30)), [])

    def test_it_stops_when_the_shelf_is_empty(self):
        self.variant.expiry_reminder_date = self.soon
        self.variant.save()
        self.assertEqual(self.alerts().filter(status="active").count(), 1)
        sell(self.variant, 6)
        self.assertEqual(self.alerts().filter(status="active").count(), 0)

    def test_on_a_lot_product_it_speaks_only_for_undated_stock(self):
        self.apply([self.product_row.pk], tracking="expiry", reminder_mode="set",
                   reminder_date=self.soon.isoformat())
        window = timezone.localdate() + timedelta(days=30)
        due = due_reminders(window_end=window)
        self.assertEqual(due[0][1], Decimal("6"))
        batch = StockBatch.objects.get(variant=self.variant)
        batch.expiry_date = timezone.localdate() + timedelta(days=200)
        batch.save()
        self.assertEqual(due_reminders(window_end=window), [])

    def test_a_save_that_does_not_mention_it_keeps_it(self):
        # An old till build's client never sends the key.
        self.variant.expiry_reminder_date = self.soon
        self.variant.save()
        self.client.patch(
            f"/api/product-variants/{self.variant.pk}/",
            {"name": "جديد"},
            format="json",
        )
        self.variant.refresh_from_db()
        self.assertEqual(self.variant.expiry_reminder_date, self.soon)

    def test_bulk_set_and_clear(self):
        self.apply([self.product_row.pk], reminder_mode="set", reminder_date=self.soon.isoformat())
        self.variant.refresh_from_db()
        self.assertEqual(self.variant.expiry_reminder_date, self.soon)
        self.product_row.refresh_from_db()
        self.assertEqual(self.product_row.tracking_mode, Product.TrackingMode.QUANTITY)
        self.apply([self.product_row.pk], reminder_mode="clear")
        self.variant.refresh_from_db()
        self.assertIsNone(self.variant.expiry_reminder_date)
