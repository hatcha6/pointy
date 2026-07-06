from decimal import Decimal

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group
from django.test import TestCase
from django.urls import reverse
from rest_framework import status
from rest_framework.test import APIClient

from apps.catalog.models import ProductUnit, UnitOfMeasure
from apps.catalog.serializers import ProductCatalogSerializer
from apps.catalog.testing import create_product_with_default_variant
from apps.core.roles import MANAGER_GROUP, ensure_role_groups
from apps.catalog.units import (
    UnitConversionError,
    base_unit_cost_from_purchase,
    resolve_unit,
    to_base_quantity,
    unit_sale_price,
    validate_quantity,
)


class UnitEngineTests(TestCase):
    def setUp(self):
        self.product = create_product_with_default_variant(
            name="Bottled water",
            sku="WATER",
            unit_price="1.00",
        )
        self.variant = self.product.default_variant
        self.box = UnitOfMeasure.objects.get(code="box")
        self.product_unit = ProductUnit.objects.create(
            product=self.product,
            unit=self.box,
            factor_to_base=Decimal("12"),
        )

    def test_blank_code_resolves_to_base_unit(self):
        resolved = resolve_unit(self.product, "")
        self.assertTrue(resolved.is_base)
        self.assertEqual(resolved.factor, Decimal("1"))
        self.assertEqual(resolved.code, "piece")

    def test_resolves_product_unit(self):
        resolved = resolve_unit(self.product, "box")
        self.assertFalse(resolved.is_base)
        self.assertEqual(resolved.factor, Decimal("12"))

    def test_unknown_unit_raises(self):
        with self.assertRaises(UnitConversionError):
            resolve_unit(self.product, "carton")

    def test_non_sellable_unit_rejected_for_sale(self):
        self.product_unit.is_sellable = False
        self.product_unit.save()
        with self.assertRaises(UnitConversionError):
            resolve_unit(self.product, "box")

    def test_non_purchasable_unit_rejected_for_purchase(self):
        self.product_unit.is_purchasable = False
        self.product_unit.save()
        with self.assertRaises(UnitConversionError):
            resolve_unit(self.product, "box", for_purchase=True)

    def test_derived_price_scales_with_factor(self):
        resolved = resolve_unit(self.product, "box")
        self.assertEqual(unit_sale_price(self.variant, resolved), Decimal("12.00"))

    def test_custom_price_overrides_derivation(self):
        self.product_unit.price = Decimal("10.00")
        self.product_unit.save()
        resolved = resolve_unit(self.product, "box")
        self.assertEqual(unit_sale_price(self.variant, resolved), Decimal("10.00"))

    def test_to_base_quantity(self):
        resolved = resolve_unit(self.product, "box")
        self.assertEqual(to_base_quantity(2, resolved), Decimal("24.000"))

    def test_count_unit_rejects_fractional_quantity(self):
        resolved = resolve_unit(self.product, "box")
        with self.assertRaises(UnitConversionError):
            validate_quantity(Decimal("1.5"), resolved)

    def test_weight_base_unit_allows_fractional_quantity(self):
        rice = create_product_with_default_variant(
            name="Rice", sku="RICE", unit_price="2.00"
        )
        rice.unit = "kg"
        rice.save()
        resolved = resolve_unit(rice, "")
        self.assertTrue(resolved.allows_fractional)
        validate_quantity(Decimal("1.5"), resolved)  # must not raise

    def test_base_unit_cost_from_purchase_normalises(self):
        self.assertEqual(
            base_unit_cost_from_purchase(Decimal("120.00"), Decimal("12")),
            Decimal("10.00"),
        )


class ProductUnitSerializerTests(TestCase):
    def test_create_product_with_units_and_default(self):
        data = {
            "name": "Soda",
            "unit": "piece",
            "default_sale_unit": "box",
            "units": [
                {
                    "unit": "box",
                    "factor_to_base": "6",
                    "price": "5.00",
                    "is_sellable": True,
                    "is_purchasable": True,
                }
            ],
            "default_variant": {"sku": "SODA", "unit_price": "1.00"},
        }
        serializer = ProductCatalogSerializer(data=data)
        self.assertTrue(serializer.is_valid(), serializer.errors)
        product = serializer.save()
        self.assertEqual(product.units.count(), 1)
        product_unit = product.units.get()
        self.assertEqual(product_unit.unit.code, "box")
        self.assertEqual(product_unit.factor_to_base, Decimal("6"))
        self.assertEqual(product.default_sale_unit, "box")

    def test_duplicate_unit_rejected(self):
        data = {
            "name": "Soda",
            "unit": "piece",
            "units": [
                {"unit": "box", "factor_to_base": "6"},
                {"unit": "box", "factor_to_base": "12"},
            ],
            "default_variant": {"sku": "SODA-DUP", "unit_price": "1.00"},
        }
        serializer = ProductCatalogSerializer(data=data)
        self.assertFalse(serializer.is_valid())
        self.assertIn("units", serializer.errors)

    def test_default_unit_must_be_known(self):
        data = {
            "name": "Soda",
            "unit": "piece",
            "default_sale_unit": "carton",
            "default_variant": {"sku": "SODA-BAD", "unit_price": "1.00"},
        }
        serializer = ProductCatalogSerializer(data=data)
        self.assertFalse(serializer.is_valid())
        self.assertIn("default_sale_unit", serializer.errors)

    def test_unknown_base_unit_rejected(self):
        data = {
            "name": "Mystery",
            "unit": "furlong",
            "default_variant": {"sku": "MYST", "unit_price": "1.00"},
        }
        serializer = ProductCatalogSerializer(data=data)
        self.assertFalse(serializer.is_valid())
        self.assertIn("unit", serializer.errors)


class ProductUnitBarcodeTests(TestCase):
    """Packaging (unit) barcodes: the carton EAN attached to a ProductUnit."""

    def _create_soda(self, *, barcodes):
        data = {
            "name": "Soda",
            "unit": "piece",
            "units": [
                {"unit": "box", "factor_to_base": "6", "barcodes": barcodes}
            ],
            "default_variant": {
                "sku": "SODA-BC",
                "barcode": "100200300",
                "unit_price": "1.00",
            },
        }
        serializer = ProductCatalogSerializer(data=data)
        self.assertTrue(serializer.is_valid(), serializer.errors)
        return serializer.save()

    def test_create_and_read_unit_barcodes(self):
        product = self._create_soda(barcodes=["600100200", "600100201"])
        unit = product.units.get()
        self.assertEqual(
            sorted(entry.barcode for entry in unit.barcodes.all()),
            ["600100200", "600100201"],
        )
        payload = ProductCatalogSerializer(product).data
        self.assertEqual(
            sorted(payload["units"][0]["barcodes"]), ["600100200", "600100201"]
        )

    def test_omitting_barcodes_on_update_preserves_them(self):
        # Clients that predate unit barcodes resend the units list without the
        # key — the stored codes must survive the rebuild.
        product = self._create_soda(barcodes=["600100200"])
        serializer = ProductCatalogSerializer(
            product,
            data={"units": [{"unit": "box", "factor_to_base": "12"}]},
            partial=True,
        )
        self.assertTrue(serializer.is_valid(), serializer.errors)
        serializer.save()
        unit = product.units.get()
        self.assertEqual(unit.factor_to_base, Decimal("12"))
        self.assertEqual(
            [entry.barcode for entry in unit.barcodes.all()], ["600100200"]
        )

    def test_sending_barcodes_replaces_them(self):
        product = self._create_soda(barcodes=["600100200"])
        serializer = ProductCatalogSerializer(
            product,
            data={
                "units": [
                    {"unit": "box", "factor_to_base": "6", "barcodes": ["700100200"]}
                ]
            },
            partial=True,
        )
        self.assertTrue(serializer.is_valid(), serializer.errors)
        serializer.save()
        self.assertEqual(
            [entry.barcode for entry in product.units.get().barcodes.all()],
            ["700100200"],
        )

    def test_unit_barcode_may_not_shadow_a_variant_barcode(self):
        self._create_soda(barcodes=["600100200"])
        data = {
            "name": "Cola",
            "unit": "piece",
            # Collides with the soda default variant's barcode.
            "units": [
                {"unit": "box", "factor_to_base": "6", "barcodes": ["100200300"]}
            ],
            "default_variant": {"sku": "COLA-BC", "unit_price": "1.00"},
        }
        serializer = ProductCatalogSerializer(data=data)
        self.assertTrue(serializer.is_valid(), serializer.errors)
        with self.assertRaises(Exception):
            serializer.save()

    def test_unit_barcode_unique_across_products(self):
        self._create_soda(barcodes=["600100200"])
        data = {
            "name": "Cola",
            "unit": "piece",
            "units": [
                {"unit": "box", "factor_to_base": "6", "barcodes": ["600100200"]}
            ],
            "default_variant": {"sku": "COLA-BC2", "unit_price": "1.00"},
        }
        serializer = ProductCatalogSerializer(data=data)
        self.assertTrue(serializer.is_valid(), serializer.errors)
        with self.assertRaises(Exception):
            serializer.save()

    def test_product_and_variant_lookup_resolve_unit_barcodes(self):
        from django.db.models import Q

        from apps.catalog.models import Product, ProductVariant
        from apps.catalog.views import ProductVariantFilter

        product = self._create_soda(barcodes=["600100200"])
        found = Product.objects.filter(
            Q(variants__barcode="600100200")
            | Q(units__barcodes__barcode="600100200")
        ).distinct()
        self.assertEqual(list(found), [product])

        filtered = ProductVariantFilter(
            data={"barcode": "600100200"},
            queryset=ProductVariant.objects.all(),
        ).qs
        self.assertEqual(
            list(filtered), [product.default_variant]
        )

    def test_price_checker_resolves_unit_barcode_at_unit_price(self):
        from apps.price_checker.pricing import lookup_price

        product = self._create_soda(barcodes=["600100200"])
        result = lookup_price("600100200")
        self.assertTrue(result.found)
        self.assertEqual(result.product_name, product.name)
        # No custom unit price -> derived: 1.00 piece × 6.
        self.assertEqual(result.final_price, Decimal("6.00"))
        self.assertEqual(result.unit, "box")


class UnitsManagementApiTests(TestCase):
    def setUp(self):
        ensure_role_groups()
        self.client = APIClient()
        self.manager = get_user_model().objects.create_user(
            username="units-manager", password="pass"
        )
        self.manager.groups.add(Group.objects.get(name=MANAGER_GROUP))
        self.client.force_authenticate(user=self.manager)
        self.list_url = reverse("unitofmeasure-list")

    def _detail(self, unit):
        return reverse("unitofmeasure-detail", args=[unit.pk])

    def test_manager_can_create_custom_unit(self):
        response = self.client.post(
            self.list_url,
            {
                "code": "Crate",
                "name": "صندوق كبير",
                "abbreviation": "صندوق",
                "dimension": "count",
                "allows_fractional": False,
            },
            format="json",
        )
        self.assertEqual(response.status_code, status.HTTP_201_CREATED, response.data)
        # code is normalised to lowercase, is_system defaults False.
        self.assertEqual(response.data["code"], "crate")
        self.assertFalse(response.data["is_system"])
        self.assertEqual(response.data["product_count"], 0)

    def test_manager_can_update_and_deactivate_custom_unit(self):
        unit = UnitOfMeasure.objects.create(code="crate", name="صندوق", dimension="count")
        response = self.client.patch(
            self._detail(unit),
            {"name": "صندوق معدّل", "is_active": False},
            format="json",
        )
        self.assertEqual(response.status_code, status.HTTP_200_OK, response.data)
        unit.refresh_from_db()
        self.assertEqual(unit.name, "صندوق معدّل")
        self.assertFalse(unit.is_active)

    def test_cannot_change_system_unit_code(self):
        piece = UnitOfMeasure.objects.get(code="piece")
        response = self.client.patch(
            self._detail(piece), {"code": "renamed"}, format="json"
        )
        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        piece.refresh_from_db()
        self.assertEqual(piece.code, "piece")

    def test_cannot_delete_system_unit(self):
        piece = UnitOfMeasure.objects.get(code="piece")
        response = self.client.delete(self._detail(piece))
        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertTrue(UnitOfMeasure.objects.filter(code="piece").exists())

    def test_cannot_delete_unit_in_use_and_count_is_reported(self):
        product = create_product_with_default_variant(
            name="Soda", sku="SODA", unit_price="1.00"
        )
        unit = UnitOfMeasure.objects.create(code="crate", name="صندوق", dimension="count")
        ProductUnit.objects.create(
            product=product, unit=unit, factor_to_base=Decimal("12")
        )

        detail = self.client.get(self._detail(unit))
        self.assertEqual(detail.data["product_count"], 1)

        response = self.client.delete(self._detail(unit))
        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertTrue(UnitOfMeasure.objects.filter(code="crate").exists())

    def test_manager_can_delete_unused_custom_unit(self):
        unit = UnitOfMeasure.objects.create(code="crate", name="صندوق", dimension="count")
        response = self.client.delete(self._detail(unit))
        self.assertEqual(response.status_code, status.HTTP_204_NO_CONTENT)
        self.assertFalse(UnitOfMeasure.objects.filter(code="crate").exists())


class SetProductUnitCommandTests(TestCase):
    """The post-migration fixup command — especially the ``--take-over`` path
    (rename a mislabeled pack in place without stranding history)."""

    def setUp(self):
        self.product = create_product_with_default_variant(
            name="Table eggs", sku="EGGS", unit_price="0.75"
        )
        self.variant = self.product.default_variant
        carton, _ = UnitOfMeasure.objects.get_or_create(
            code="carton", defaults={"name": "كرتون", "dimension": "count"}
        )
        self.old_unit = ProductUnit.objects.create(
            product=self.product, unit=carton, factor_to_base=Decimal("30")
        )

    def _run_take_over(self):
        from django.core.management import call_command

        call_command(
            "set_product_unit",
            "--product=EGGS",
            "--unit=tray",
            "--unit-name=طبق",
            "--factor=30",
            "--price=15",
            "--fractional",
            "--take-over=carton",
        )

    def test_take_over_retags_historical_purchase_lines(self):
        from apps.purchasing.models import PurchaseLine, PurchaseOrder, Supplier

        order = PurchaseOrder.objects.create(
            supplier=Supplier.objects.create(name="Egg farm")
        )
        line = PurchaseLine.objects.create(
            purchase_order=order,
            variant=self.variant,
            quantity=Decimal("2"),
            unit="carton",
            unit_factor=Decimal("30"),
            unit_cost=Decimal("13.50"),
        )

        self._run_take_over()

        line.refresh_from_db()
        self.assertEqual(line.unit, "tray")
        # The snapshot is a rename, not a repack: factor and cost untouched.
        self.assertEqual(line.unit_factor, Decimal("30"))
        self.assertEqual(line.unit_cost, Decimal("13.50"))
        self.assertEqual(line.base_unit_cost, Decimal("0.45"))
        self.assertFalse(
            ProductUnit.objects.filter(product=self.product, unit__code="carton").exists()
        )

    def test_take_over_moves_packaging_barcodes(self):
        from apps.catalog.models import ProductUnitBarcode

        ProductUnitBarcode.objects.create(
            product_unit=self.old_unit, barcode="6210000000017"
        )

        self._run_take_over()

        tray = ProductUnit.objects.get(product=self.product, unit__code="tray")
        self.assertEqual(
            [entry.barcode for entry in tray.barcodes.all()], ["6210000000017"]
        )
