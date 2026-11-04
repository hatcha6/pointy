"""The per-variant low-stock threshold, end to end.

``ProductVariant.low_stock_threshold`` replaced both ``StockItem.reorder_level``
(a 5 nobody could edit, judged row by row) and the shop-wide setting nothing
read. These tests pin the rules every surface now shares:

* blank means not watched — no low-stock and no out-of-stock alert;
* the threshold is compared with the shop-wide total, not location by
  location;
* clearing a threshold resolves its open alert;
* the API keeps a threshold an older client did not send, and clears it only
  on an explicit null;
* the migration carries over only levels somebody chose.
"""

from decimal import Decimal
from importlib import import_module

from django.apps import apps as django_apps
from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group
from django.test import TestCase
from django.urls import reverse
from rest_framework import status
from rest_framework.test import APIClient

from apps.catalog.models import ProductVariant
from apps.catalog.testing import create_product_with_default_variant
from apps.core.roles import MANAGER_GROUP, ensure_role_groups
from apps.inventory.low_stock import low_stock_variants, suggested_reorder_quantity
from apps.inventory.models import StockItem, Warehouse
from apps.notifications.models import BusinessNotification
from apps.notifications.services import sync_business_notifications


def _variant(sku, *, threshold=None, on_hand="0", warehouse=None):
    variant = create_product_with_default_variant(
        name=f"صنف {sku}",
        sku=sku,
        unit_price=Decimal("3.00"),
        low_stock_threshold=threshold,
    ).default_variant
    StockItem.objects.create(
        variant=variant, quantity_on_hand=Decimal(on_hand), warehouse=warehouse
    )
    return variant


def _active_codes(variant):
    return set(
        BusinessNotification.objects.filter(
            code__startswith="inventory.",
            entity_id=str(variant.pk),
            status=BusinessNotification.Status.ACTIVE,
        ).values_list("code", flat=True)
    )


class LowStockRulesTests(TestCase):
    def test_an_unwatched_variant_never_alerts_even_when_empty(self):
        empty = _variant("UNW-0", on_hand="0")
        low = _variant("UNW-1", on_hand="1")

        sync_business_notifications()

        self.assertEqual(_active_codes(empty), set())
        self.assertEqual(_active_codes(low), set())
        self.assertFalse(low_stock_variants().exists())

    def test_a_watched_variant_is_low_at_its_threshold_and_out_at_zero(self):
        at = _variant("W-AT", threshold="4", on_hand="4")
        above = _variant("W-ABOVE", threshold="4", on_hand="4.001")
        empty = _variant("W-ZERO", threshold="4", on_hand="0")

        sync_business_notifications()

        self.assertEqual(_active_codes(at), {"inventory.low_stock"})
        self.assertEqual(_active_codes(above), set())
        self.assertEqual(_active_codes(empty), {"inventory.out_of_stock"})

    def test_a_zero_threshold_only_warns_when_the_shelf_empties(self):
        one = _variant("Z-1", threshold="0", on_hand="1")
        none = _variant("Z-0", threshold="0", on_hand="0")

        sync_business_notifications()

        self.assertEqual(_active_codes(one), set())
        self.assertEqual(_active_codes(none), {"inventory.out_of_stock"})

    def test_a_weighed_threshold_keeps_its_fraction(self):
        cheese = _variant("KG-1", threshold="1.250", on_hand="1.2")

        sync_business_notifications()

        alert = BusinessNotification.objects.get(
            code__startswith="inventory.", entity_id=str(cheese.pk)
        )
        self.assertEqual(alert.code, "inventory.low_stock")
        self.assertEqual(alert.payload["threshold"], 1.25)
        self.assertEqual(alert.payload["quantity"], 1.2)

    def test_the_threshold_is_judged_on_the_shop_wide_total(self):
        store = Warehouse.objects.create(
            name="المخزن", code="store-ls", kind=Warehouse.Kind.STORE_ROOM
        )
        variant = _variant("MULTI", threshold="5", on_hand="3")
        StockItem.objects.create(variant=variant, warehouse=store, quantity_on_hand=Decimal("4"))

        sync_business_notifications()
        # 3 on the shop floor is below 5, but the shop holds 7.
        self.assertEqual(_active_codes(variant), set())

        variant.low_stock_threshold = Decimal("7")
        variant.save(update_fields=["low_stock_threshold"])
        sync_business_notifications()

        alerts = BusinessNotification.objects.filter(
            code__startswith="inventory.", entity_id=str(variant.pk)
        )
        # One alert for the variant, not one per location.
        self.assertEqual(alerts.count(), 1)
        self.assertEqual(alerts.get().payload["quantity"], 7.0)

    def test_a_transit_row_does_not_count_toward_the_shelf(self):
        transit = Warehouse.objects.get(pk=Warehouse.transit_id())
        variant = _variant("TRANSIT", threshold="5", on_hand="2")
        StockItem.objects.create(variant=variant, warehouse=transit, quantity_on_hand=Decimal("50"))

        sync_business_notifications()

        self.assertEqual(_active_codes(variant), {"inventory.low_stock"})

    def test_a_service_with_a_threshold_is_never_low(self):
        service = _variant("SVC", threshold="5", on_hand="0")
        service.product.is_service = True
        service.product.save(update_fields=["is_service"])

        sync_business_notifications()

        self.assertEqual(_active_codes(service), set())

    def test_clearing_the_threshold_resolves_the_open_alert(self):
        variant = _variant("CLEAR", threshold="5", on_hand="2")
        sync_business_notifications()
        self.assertEqual(_active_codes(variant), {"inventory.low_stock"})

        variant.low_stock_threshold = None
        variant.save(update_fields=["low_stock_threshold"])
        sync_business_notifications()

        self.assertEqual(_active_codes(variant), set())
        self.assertEqual(
            BusinessNotification.objects.get(
                code__startswith="inventory.", entity_id=str(variant.pk)
            ).status,
            BusinessNotification.Status.RESOLVED,
        )

    def test_the_suggested_reorder_counts_what_is_on_the_way(self):
        variant = _variant("SUGG", threshold="10", on_hand="3")
        StockItem.objects.filter(variant=variant).update(quantity_expected=Decimal("4"))

        annotated = low_stock_variants().get(pk=variant.pk)

        # Back to twice the threshold: 20 - 3 on hand - 4 expected.
        self.assertEqual(suggested_reorder_quantity(annotated), Decimal("13"))

    def test_the_database_refuses_a_negative_threshold(self):
        from django.db import IntegrityError, transaction

        variant = _variant("NEG")
        with self.assertRaises(IntegrityError), transaction.atomic():
            ProductVariant.objects.filter(pk=variant.pk).update(low_stock_threshold=Decimal("-1"))


class LowStockThresholdApiTests(TestCase):
    def setUp(self):
        ensure_role_groups()
        self.client = APIClient()
        user = get_user_model().objects.create_user(username="ls-mgr", password="pw")
        user.groups.add(Group.objects.get(name=MANAGER_GROUP))
        self.client.force_authenticate(user=user)

    def _patch_variant(self, variant, payload):
        return self.client.patch(
            reverse("product-variant-detail", args=[variant.pk]),
            payload,
            format="json",
        )

    def test_the_variant_endpoint_sets_reads_and_clears_it(self):
        variant = _variant("API-1")

        response = self._patch_variant(variant, {"low_stock_threshold": "2.500"})
        self.assertEqual(response.status_code, status.HTTP_200_OK, response.data)
        self.assertEqual(response.data["low_stock_threshold"], "2.500")

        response = self._patch_variant(variant, {"low_stock_threshold": None})
        self.assertEqual(response.status_code, status.HTTP_200_OK, response.data)
        variant.refresh_from_db()
        self.assertIsNone(variant.low_stock_threshold)

    def test_a_negative_threshold_is_refused(self):
        variant = _variant("API-NEG")

        response = self._patch_variant(variant, {"low_stock_threshold": "-1"})

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertIn("low_stock_threshold", response.data)

    def test_a_product_save_without_the_field_keeps_the_threshold(self):
        """The compat till build predates the field: saving a product from it
        must not wipe a threshold the owner set elsewhere."""
        variant = _variant("API-KEEP", threshold="6")

        response = self.client.patch(
            reverse("product-detail", args=[variant.product_id]),
            {
                "name": "اسم جديد",
                "default_variant": {"sku": variant.sku, "unit_price": "3.00"},
            },
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK, response.data)
        variant.refresh_from_db()
        self.assertEqual(variant.low_stock_threshold, Decimal("6"))

    def test_creating_a_product_writes_each_variants_threshold(self):
        response = self.client.post(
            reverse("product-list"),
            {
                "name": "عصير",
                "default_variant": {
                    "sku": "API-NEW",
                    "unit_price": "2.00",
                    "low_stock_threshold": "12",
                },
            },
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_201_CREATED, response.data)
        variant = ProductVariant.objects.get(sku="API-NEW")
        self.assertEqual(variant.low_stock_threshold, Decimal("12"))

    def test_the_shop_setting_is_no_longer_part_of_the_api(self):
        response = self.client.get(reverse("shop-settings"))

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertNotIn("low_stock_threshold", response.data)


class CarryOverImportedLevelsTests(TestCase):
    """Calls catalog 0043's forward function against the live models, as
    ``test_backlog_migration`` does: the fields it reads are unchanged."""

    def _forward(self):
        module = import_module("apps.catalog.migrations.0043_variant_low_stock_threshold")
        module.carry_over_imported_levels(django_apps, None)

    def test_only_levels_somebody_chose_are_carried_over(self):
        defaulted = _variant("MIG-5")
        StockItem.objects.filter(variant=defaulted).update(reorder_level=5)
        imported = _variant("MIG-12")
        StockItem.objects.filter(variant=imported).update(reorder_level=12)
        zero = _variant("MIG-0")
        StockItem.objects.filter(variant=zero).update(reorder_level=0)

        self._forward()

        for variant in (defaulted, imported, zero):
            variant.refresh_from_db()
        self.assertIsNone(defaulted.low_stock_threshold)
        self.assertEqual(imported.low_stock_threshold, Decimal("12"))
        self.assertIsNone(zero.low_stock_threshold)

    def test_several_locations_keep_the_highest_level(self):
        store = Warehouse.objects.create(
            name="المخزن", code="store-mig", kind=Warehouse.Kind.STORE_ROOM
        )
        variant = _variant("MIG-MULTI")
        StockItem.objects.filter(variant=variant).update(reorder_level=8)
        StockItem.objects.create(variant=variant, warehouse=store, reorder_level=20)

        self._forward()

        variant.refresh_from_db()
        self.assertEqual(variant.low_stock_threshold, Decimal("20"))
