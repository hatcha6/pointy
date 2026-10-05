"""The generative-UI unit card (§8.4): the tools hand the model a card's
properties ready to copy, and those properties pass the catalog's own gate."""

import json
from datetime import timedelta
from decimal import Decimal

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Permission
from django.test import TestCase
from django.utils import timezone

from apps.catalog.models import Product
from apps.inventory.models import StockBatch, StockUnit, UnitAttributeDefinition
from apps.inventory.tracked_testing import receive, tracked_product

from .tools import lookup_stock_unit, stock_unit_ageing
from .ui_catalog import load_catalog, validate_surface


def _assistant():
    user = get_user_model().objects.create_user(username="assistant", password="x")
    user.user_permissions.add(
        Permission.objects.get(
            content_type__app_label="inventory", codename="view_stockunit"
        )
    )
    return user


def _surface(*components):
    return {"surface_id": "unit", "components": list(components)}


class StockUnitCardCatalogTests(TestCase):
    def test_the_card_is_in_the_exported_catalog_with_meaning_only_props(self):
        spec = load_catalog()["components"]["StockUnitCard"]
        self.assertEqual(
            set(spec["required"]), {"unitId", "code", "product"}
        )
        self.assertEqual(spec["properties"]["variant"]["enum"], ["full", "compact"])
        self.assertNotIn("cost", json.dumps(spec).lower())


class LookupStockUnitCardTests(TestCase):
    def setUp(self):
        self.user = _assistant()
        product = tracked_product(
            name="آيفون",
            sku="AI-CARD",
            mode=Product.TrackingMode.SERIAL,
            unit_price="1800.00",
        )
        receive(
            variant=product.default_variant,
            quantity=1,
            unit_cost="1200.00",
            units=[
                {
                    "code": "358240051111110",
                    "list_price": Decimal("1750.00"),
                    "attributes": {"battery_health": "86"},
                }
            ],
        )

    def test_the_answer_carries_a_card_the_catalog_accepts(self):
        answer = lookup_stock_unit(user=self.user, code="358240051111110")
        card = answer["card"]
        unit = StockUnit.objects.get(code="358240051111110")

        self.assertEqual(card["unitId"], unit.pk)
        self.assertEqual(card["code"], "358240051111110")
        self.assertEqual(card["status"], "in_stock")
        self.assertEqual(card["price"], 1750.0)
        self.assertEqual(card["variant"], "full")
        # The seeded intake sheet's own label, never the raw key.
        label = UnitAttributeDefinition.objects.filter(key="battery_health").values_list("label", flat=True).first()
        self.assertEqual(card["attributes"], [{"label": label, "value": "86"}])
        # Same unit, same deep link the prose answer gives.
        self.assertEqual(answer["unit"]["link"], f"pointy://stock-unit/{unit.pk}")

        surface = validate_surface(
            _surface({"id": "root", "component": "StockUnitCard", **card})
        )
        self.assertEqual(surface["components"][0]["unitId"], unit.pk)

    def test_the_card_never_carries_what_the_shop_paid(self):
        card = lookup_stock_unit(user=self.user, code="358240051111110")["card"]
        flattened = json.dumps(card, ensure_ascii=False)
        for forbidden in ("cost", "incoming_rate", "1200", "payout"):
            self.assertNotIn(forbidden, flattened)

    def test_a_code_nobody_has_held_has_no_card(self):
        answer = lookup_stock_unit(user=self.user, code="NOT-A-THING")
        self.assertIsNone(answer["card"])

    def test_the_ageing_answer_carries_compact_cards_for_a_column(self):
        StockUnit.objects.update(in_stock_since=timezone.now() - timedelta(days=120))
        answer = stock_unit_ageing(user=self.user, days=90)

        self.assertEqual(len(answer["cards"]), 1)
        card = answer["cards"][0]
        self.assertEqual(card["variant"], "compact")
        self.assertGreaterEqual(card["daysOnShelf"], 120)
        validate_surface(
            _surface(
                {"id": "root", "component": "Column", "children": ["u0"]},
                {"id": "u0", "component": "StockUnitCard", **card},
            )
        )


class StoppedLotCardTests(TestCase):
    def test_a_pack_in_a_quarantined_lot_says_so_on_its_card(self):
        user = _assistant()
        product = tracked_product(
            name="لقاح",
            sku="AI-VAX",
            mode=Product.TrackingMode.SERIAL_BATCH,
            unit_price="90.00",
        )
        receive(
            variant=product.default_variant,
            quantity=1,
            unit_cost="40.00",
            units=[{"code": "PACK-AI-1"}],
            batches=[
                {
                    "code": "LOT-AI",
                    "expiry_date": timezone.localdate() + timedelta(days=200),
                }
            ],
        )
        lot = StockBatch.objects.get(code="LOT-AI")
        lot.status = StockBatch.Status.QUARANTINED
        lot.is_locked = True
        lot.save(update_fields=["status", "is_locked", "updated_at"])

        card = lookup_stock_unit(user=user, code="PACK-AI-1")["card"]

        self.assertEqual(card["availability"], "recalled")
        self.assertEqual(card["lot"], "LOT-AI")
        self.assertIn("expiryDate", card)
        validate_surface(_surface({"id": "root", "component": "StockUnitCard", **card}))
