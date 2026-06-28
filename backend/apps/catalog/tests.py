from decimal import Decimal
from unittest.mock import patch

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group, Permission
from django.db import IntegrityError, transaction
from django.test import TestCase
from django.urls import reverse
from rest_framework import status
from rest_framework.test import APIClient

from apps.core.roles import CASHIER_GROUP, MANAGER_GROUP, ensure_role_groups
from apps.inventory.models import StockItem
from .models import (
    Product,
    ProductCategory,
    ProductVariant,
    VariantOption,
    VariantOptionValue,
)
from .testing import create_product_with_default_variant
from .views import ProductViewSet


class ProductVariantModelTests(TestCase):
    def test_create_product_with_default_variant_helper(self):
        product = create_product_with_default_variant(
            sku=" cof-100 ",
            barcode=" 123456789 ",
            name="قهوة عربية",
            unit_price=Decimal("5.50"),
            is_active=False,
        )

        variant = product.default_variant
        self.assertEqual(product.variants.count(), 1)
        self.assertTrue(variant.is_default)
        self.assertEqual(variant.sku, "COF-100")
        self.assertEqual(variant.barcode, "123456789")
        self.assertEqual(variant.unit_price, Decimal("5.50"))
        self.assertFalse(variant.is_active)

    def test_default_variant_read_does_not_create_variant(self):
        product = Product.objects.create(name="منتج عام")

        self.assertIsNone(product.default_variant)
        self.assertEqual(product.variants.count(), 0)

        variant = product.ensure_default_variant()
        self.assertEqual(product.variants.count(), 1)
        self.assertEqual(variant.sku, f"P{product.pk:06d}")
        self.assertEqual(variant.unit_price, Decimal("0.00"))

    def test_variant_display_names_fallback_to_product_name(self):
        product = create_product_with_default_variant(
            sku="COF-100",
            name="قهوة عربية",
            unit_price=Decimal("5.50"),
        )
        named_variant = ProductVariant.objects.create(
            product=product,
            name="كبير",
            sku="COF-100-L",
            unit_price=Decimal("7.00"),
        )

        self.assertEqual(product.default_variant.display_name, "قهوة عربية")
        self.assertEqual(product.default_variant.full_name, "قهوة عربية")
        self.assertEqual(named_variant.display_name, "كبير")
        self.assertEqual(named_variant.full_name, "قهوة عربية - كبير")

    def test_variant_display_names_include_option_values_when_name_is_blank(self):
        product = create_product_with_default_variant(
            sku="SHIRT",
            name="قميص",
            unit_price=Decimal("20.00"),
        )
        color = VariantOption.objects.create(code="display-color", name="اللون")
        size = VariantOption.objects.create(code="display-size", name="المقاس")
        red = VariantOptionValue.objects.create(
            option=color,
            code="red",
            name="أحمر",
        )
        large = VariantOptionValue.objects.create(
            option=size,
            code="large",
            name="كبير",
        )
        product.variant_options.add(color, size)
        variant = ProductVariant.objects.create(
            product=product,
            sku="SHIRT-RED-L",
            unit_price=Decimal("22.00"),
        )
        variant.option_values.set([red, large])

        self.assertEqual(variant.display_name, "اللون: أحمر / المقاس: كبير")
        self.assertEqual(
            variant.full_name,
            "قميص - اللون: أحمر / المقاس: كبير",
        )

    def test_variant_sku_and_non_blank_barcode_are_unique(self):
        product = create_product_with_default_variant(
            sku="COF-100",
            barcode="123456789",
            name="قهوة عربية",
            unit_price=Decimal("5.50"),
        )
        other = create_product_with_default_variant(
            sku="TEA-100",
            name="شاي",
            unit_price=Decimal("2.00"),
        )

        with self.assertRaises(IntegrityError), transaction.atomic():
            ProductVariant.objects.create(
                product=product,
                name="مكرر",
                sku="COF-100",
                unit_price=Decimal("6.00"),
            )
        with self.assertRaises(IntegrityError), transaction.atomic():
            ProductVariant.objects.create(
                product=other,
                name="باركود مكرر",
                sku="TEA-101",
                barcode="123456789",
                unit_price=Decimal("3.00"),
            )
        ProductVariant.objects.create(
            product=product,
            name="بدون باركود 1",
            sku="COF-101",
            barcode="",
            unit_price=Decimal("6.00"),
        )
        ProductVariant.objects.create(
            product=product,
            name="بدون باركود 2",
            sku="COF-102",
            barcode="",
            unit_price=Decimal("6.50"),
        )

    def test_active_variant_queryset_requires_active_product_and_variant(self):
        active_product = create_product_with_default_variant(
            sku="ACTIVE",
            name="نشط",
            unit_price=Decimal("1.00"),
            is_active=True,
        )
        inactive_variant_product = create_product_with_default_variant(
            sku="INACTIVE-VARIANT",
            name="متغير متوقف",
            unit_price=Decimal("1.00"),
            is_active=True,
        )
        inactive_variant = inactive_variant_product.default_variant
        inactive_variant.is_active = False
        inactive_variant.save(update_fields=["is_active", "updated_at"])
        create_product_with_default_variant(
            sku="INACTIVE-PRODUCT",
            name="منتج متوقف",
            unit_price=Decimal("1.00"),
            is_active=False,
        )

        self.assertEqual(
            list(ProductVariant.objects.active().values_list("sku", flat=True)),
            [active_product.default_variant.sku],
        )


class ProductApiTests(TestCase):
    def setUp(self):
        ensure_role_groups()
        self.client = APIClient()
        self.user = get_user_model().objects.create_user(
            username="catalog-user",
            password="pass",
        )
        self.user.groups.add(Group.objects.get(name=MANAGER_GROUP))
        self.client.force_authenticate(user=self.user)

    def test_create_product(self):
        category = ProductCategory.objects.create(name="مشروبات")
        response = self.client.post(
            reverse("product-list"),
            {
                "name": "قهوة عربية",
                "description": "حبوب مطحونة",
                "is_active": True,
                "categories": [category.id],
                "default_variant": {
                    "sku": " cof-100 ",
                    "barcode": "123456789",
                    "unit_price": "5.50",
                },
            },
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_201_CREATED)
        product = Product.objects.get()
        variant = product.default_variant
        self.assertEqual(variant.sku, "COF-100")
        self.assertEqual(product.name, "قهوة عربية")
        self.assertEqual(variant.unit_price, Decimal("5.50"))
        self.assertEqual(list(product.categories.values_list("id", flat=True)), [category.id])
        self.assertEqual(response.data["categories"], [category.id])
        self.assertEqual(response.data["default_variant"]["sku"], "COF-100")
        self.assertNotIn("sku", response.data)
        self.assertNotIn("barcode", response.data)
        self.assertNotIn("unit_price", response.data)

    def test_create_product_with_generated_variant_combinations(self):
        color = VariantOption.objects.create(code="phone-color", name="اللون")
        storage = VariantOption.objects.create(code="phone-storage", name="السعة")
        white = VariantOptionValue.objects.create(
            option=color,
            code="white",
            name="أبيض",
        )
        black = VariantOptionValue.objects.create(
            option=color,
            code="black",
            name="أسود",
        )
        storage_128 = VariantOptionValue.objects.create(
            option=storage,
            code="128gb",
            name="128GB",
        )
        storage_256 = VariantOptionValue.objects.create(
            option=storage,
            code="256gb",
            name="256GB",
        )

        response = self.client.post(
            reverse("product-list"),
            {
                "name": "iPhone",
                "description": "",
                "is_active": True,
                "variant_options": [color.id, storage.id],
                "variants": [
                    {
                        "name": "أبيض 128GB",
                        "sku": "IPHONE-WHITE-128GB",
                        "unit_price": "1000.00",
                        "is_default": True,
                        "option_values": [white.id, storage_128.id],
                    },
                    {
                        "name": "أبيض 256GB",
                        "sku": "IPHONE-WHITE-256GB",
                        "unit_price": "1100.00",
                        "option_values": [white.id, storage_256.id],
                    },
                    {
                        "name": "أسود 128GB",
                        "sku": "IPHONE-BLACK-128GB",
                        "unit_price": "1000.00",
                        "option_values": [black.id, storage_128.id],
                    },
                    {
                        "name": "أسود 256GB",
                        "sku": "IPHONE-BLACK-256GB",
                        "unit_price": "1100.00",
                        "option_values": [black.id, storage_256.id],
                    },
                ],
            },
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_201_CREATED)
        product = Product.objects.get(name="iPhone")
        self.assertEqual(product.variants.count(), 4)
        self.assertEqual(
            set(product.variant_options.values_list("id", flat=True)),
            {color.id, storage.id},
        )
        self.assertEqual(product.default_variant.name, "أبيض 128GB")
        self.assertEqual(
            set(
                product.variants.values_list(
                    "option_values__name",
                    flat=True,
                )
            ),
            {"أبيض", "أسود", "128GB", "256GB"},
        )
        self.assertEqual(len(response.data["variants"]), 4)
        self.assertEqual(
            {option["id"] for option in response.data["variant_option_details"]},
            {color.id, storage.id},
        )

    def test_create_product_rejects_duplicate_generated_combinations(self):
        color = VariantOption.objects.create(code="dupe-color", name="اللون")
        white = VariantOptionValue.objects.create(
            option=color,
            code="white",
            name="أبيض",
        )

        response = self.client.post(
            reverse("product-list"),
            {
                "name": "منتج مكرر",
                "variant_options": [color.id],
                "variants": [
                    {
                        "name": "أبيض",
                        "sku": "DUP-1",
                        "unit_price": "1.00",
                        "option_values": [white.id],
                    },
                    {
                        "name": "أبيض آخر",
                        "sku": "DUP-2",
                        "unit_price": "1.00",
                        "option_values": [white.id],
                    },
                ],
            },
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertIn("variants", response.data)

    def test_update_product_can_upsert_generated_variants(self):
        product = create_product_with_default_variant(
            sku="IPHONE",
            name="iPhone",
            unit_price=Decimal("900.00"),
        )
        color = VariantOption.objects.create(code="upsert-color", name="اللون")
        storage = VariantOption.objects.create(code="upsert-storage", name="السعة")
        black = VariantOptionValue.objects.create(
            option=color,
            code="black",
            name="أسود",
        )
        white = VariantOptionValue.objects.create(
            option=color,
            code="white",
            name="أبيض",
        )
        storage_128 = VariantOptionValue.objects.create(
            option=storage,
            code="128gb",
            name="128GB",
        )

        response = self.client.patch(
            reverse("product-detail", args=[product.pk]),
            {
                "name": "iPhone",
                "description": "",
                "is_active": True,
                "categories": [],
                "variant_options": [color.id, storage.id],
                "variants": [
                    {
                        "id": product.default_variant.pk,
                        "name": "أسود 128GB",
                        "sku": "IPHONE-BLACK-128GB",
                        "unit_price": "950.00",
                        "is_default": True,
                        "option_values": [black.id, storage_128.id],
                    },
                    {
                        "name": "أبيض 128GB",
                        "sku": "IPHONE-WHITE-128GB",
                        "unit_price": "950.00",
                        "option_values": [white.id, storage_128.id],
                    },
                ],
            },
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        product.refresh_from_db()
        self.assertEqual(product.variants.count(), 2)
        self.assertEqual(product.default_variant.sku, "IPHONE-BLACK-128GB")
        self.assertEqual(
            set(product.variants.values_list("sku", flat=True)),
            {"IPHONE-BLACK-128GB", "IPHONE-WHITE-128GB"},
        )

    def test_update_product_generated_variants_preserves_existing_default(self):
        product = create_product_with_default_variant(
            sku="TEE",
            name="قميص",
            unit_price=Decimal("20.00"),
        )
        size = VariantOption.objects.create(code="tee-size", name="المقاس")
        small = VariantOptionValue.objects.create(
            option=size,
            code="small",
            name="صغير",
        )
        medium = VariantOptionValue.objects.create(
            option=size,
            code="medium",
            name="وسط",
        )
        product.variant_options.add(size)
        default_variant = product.default_variant
        default_variant.option_values.set([small])

        response = self.client.patch(
            reverse("product-detail", args=[product.pk]),
            {
                "variant_options": [size.id],
                "variants": [
                    {
                        "name": "وسط",
                        "sku": "TEE-MEDIUM",
                        "barcode": "TEE-MEDIUM-BARCODE",
                        "unit_price": "22.00",
                        "option_values": [medium.id],
                    },
                ],
            },
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        product.refresh_from_db()
        default_variant.refresh_from_db()
        self.assertTrue(default_variant.is_default)
        self.assertEqual(product.default_variant.pk, default_variant.pk)
        created_variant = product.variants.get(sku="TEE-MEDIUM")
        self.assertFalse(created_variant.is_default)
        self.assertEqual(created_variant.barcode, "TEE-MEDIUM-BARCODE")

    def test_reject_negative_price(self):
        response = self.client.post(
            reverse("product-list"),
            {
                "name": "منتج غير صالح",
                "is_active": True,
                "default_variant": {
                    "sku": "BAD-001",
                    "unit_price": "-1.00",
                },
            },
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)

    def test_search_filter_and_order_products(self):
        create_product_with_default_variant(
            sku="COF-100",
            barcode="111",
            name="قهوة عربية",
            unit_price=Decimal("5.50"),
            is_active=True,
        )
        create_product_with_default_variant(
            sku="TEA-100",
            barcode="222",
            name="شاي نعناع",
            unit_price=Decimal("2.75"),
            is_active=True,
        )
        create_product_with_default_variant(
            sku="OLD-100",
            barcode="333",
            name="منتج متوقف",
            unit_price=Decimal("1.50"),
            is_active=False,
        )

        response = self.client.get(
            reverse("product-list"),
            {"search": "100", "is_active": "true"},
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        results = response.data["results"]
        self.assertEqual(
            {product["default_variant"]["sku"] for product in results},
            {"TEA-100", "COF-100"},
        )

    def test_product_search_matches_variant_name(self):
        product = create_product_with_default_variant(
            sku="SHIRT",
            barcode="",
            name="قميص",
            unit_price=Decimal("20.00"),
            is_active=True,
        )
        ProductVariant.objects.create(
            product=product,
            name="أحمر / L",
            sku="SHIRT-RED-L",
            unit_price=Decimal("22.00"),
        )
        create_product_with_default_variant(
            sku="PANTS",
            barcode="",
            name="بنطال",
            unit_price=Decimal("18.00"),
            is_active=True,
        )

        response = self.client.get(
            reverse("product-list"),
            {"search": "أحمر", "is_active": "true"},
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(
            [product["id"] for product in response.data["results"]],
            [product.id],
        )

    def test_create_nested_product_category(self):
        parent = ProductCategory.objects.create(name="المشروبات")

        response = self.client.post(
            reverse("productcategory-list"),
            {
                "name": "القهوة",
                "description": "قهوة وشاي",
                "parent": parent.id,
                "is_active": True,
            },
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_201_CREATED)
        category = ProductCategory.objects.get(name="القهوة")
        self.assertEqual(category.parent, parent)
        self.assertEqual(response.data["parent_name"], "المشروبات")

    def test_filter_product_categories_by_root_and_parent(self):
        drinks = ProductCategory.objects.create(name="A Root")
        coffee = ProductCategory.objects.create(name="A Child", parent=drinks)
        snacks = ProductCategory.objects.create(name="B Root")

        root_response = self.client.get(reverse("productcategory-list"), {"root": "true"})
        child_response = self.client.get(reverse("productcategory-list"), {"parent": drinks.id})

        self.assertEqual(root_response.status_code, status.HTTP_200_OK)
        self.assertEqual(child_response.status_code, status.HTTP_200_OK)
        self.assertEqual(
            [category["id"] for category in root_response.data["results"]],
            [drinks.id, snacks.id],
        )
        self.assertEqual(
            [category["id"] for category in child_response.data["results"]],
            [coffee.id],
        )

    def test_filter_product_categories_by_quick_access_ordered(self):
        ProductCategory.objects.create(name="عادي")
        pinned_second = ProductCategory.objects.create(
            name="مثبت ثان", is_quick_access=True, display_order=2
        )
        pinned_first = ProductCategory.objects.create(
            name="مثبت أول", is_quick_access=True, display_order=1
        )

        response = self.client.get(
            reverse("productcategory-list"), {"is_quick_access": "true"}
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        # Quick-access only, ordered by display_order (not name/creation).
        self.assertEqual(
            [category["id"] for category in response.data["results"]],
            [pinned_first.id, pinned_second.id],
        )

    def test_product_category_exposes_counts_and_quick_access(self):
        parent = ProductCategory.objects.create(
            name="المشروبات", is_quick_access=True, display_order=3
        )
        ProductCategory.objects.create(name="قهوة", parent=parent)
        product = create_product_with_default_variant(
            sku="JUICE",
            barcode="909",
            name="عصير",
            unit_price=Decimal("4.00"),
            is_active=True,
        )
        product.categories.add(parent)

        response = self.client.get(
            reverse("productcategory-detail", args=[parent.id])
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertTrue(response.data["is_quick_access"])
        self.assertEqual(response.data["display_order"], 3)
        self.assertEqual(response.data["children_count"], 1)
        self.assertEqual(response.data["product_count"], 1)

    def test_update_product_category_quick_access_and_order(self):
        category = ProductCategory.objects.create(name="إكسسوارات")

        response = self.client.patch(
            reverse("productcategory-detail", args=[category.id]),
            {"is_quick_access": True, "display_order": 5},
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        category.refresh_from_db()
        self.assertTrue(category.is_quick_access)
        self.assertEqual(category.display_order, 5)

    def test_reject_category_parent_cycle(self):
        parent = ProductCategory.objects.create(name="الأصل")
        child = ProductCategory.objects.create(name="الفرع", parent=parent)

        response = self.client.patch(
            reverse("productcategory-detail", args=[parent.id]),
            {"parent": child.id},
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)

    def test_delete_category_with_children_returns_400(self):
        parent = ProductCategory.objects.create(name="الأصل")
        ProductCategory.objects.create(name="الفرع", parent=parent)

        response = self.client.delete(
            reverse("productcategory-detail", args=[parent.id])
        )

        # PROTECT surfaces as a clean validation error, not a 500.
        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertTrue(ProductCategory.objects.filter(id=parent.id).exists())

    def test_delete_leaf_category(self):
        category = ProductCategory.objects.create(name="قابل للحذف")

        response = self.client.delete(
            reverse("productcategory-detail", args=[category.id])
        )

        self.assertEqual(response.status_code, status.HTTP_204_NO_CONTENT)
        self.assertFalse(ProductCategory.objects.filter(id=category.id).exists())

    def test_filter_products_by_category_includes_descendants(self):
        drinks = ProductCategory.objects.create(name="مشروبات")
        coffee = ProductCategory.objects.create(name="قهوة", parent=drinks)
        snack = ProductCategory.objects.create(name="وجبات خفيفة")
        latte = create_product_with_default_variant(
            sku="LATTE",
            barcode="444",
            name="لاتيه",
            unit_price=Decimal("6.50"),
            is_active=True,
        )
        dates = create_product_with_default_variant(
            sku="DATES",
            barcode="555",
            name="تمر",
            unit_price=Decimal("3.00"),
            is_active=True,
        )
        latte.categories.add(coffee)
        dates.categories.add(snack)

        response = self.client.get(reverse("product-list"), {"category": drinks.id})

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(
            [product["default_variant"]["sku"] for product in response.data["results"]],
            ["LATTE"],
        )

    def test_active_category_filter_bypasses_active_id_cache(self):
        category = ProductCategory.objects.create(name="مشروبات")
        match = create_product_with_default_variant(
            sku="MATCH",
            barcode="123",
            name="قهوة مطابقة",
            unit_price=Decimal("5.50"),
            is_active=True,
        )
        match.categories.add(category)

        with patch.object(
            ProductViewSet,
            "_get_active_product_ids",
            side_effect=AssertionError("category lookup should not load all active ids"),
        ):
            response = self.client.get(
                reverse("product-list"),
                {"category": category.id, "is_active": "true"},
            )

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(
            [product["id"] for product in response.data["results"]],
            [match.id],
        )

    def test_filter_products_by_exact_barcode(self):
        create_product_with_default_variant(
            sku="MATCH",
            barcode="123456789",
            name="قهوة مطابقة",
            unit_price=Decimal("5.50"),
            is_active=True,
        )
        create_product_with_default_variant(
            sku="PARTIAL",
            barcode="1234567890",
            name="قهوة قريبة",
            unit_price=Decimal("6.50"),
            is_active=True,
        )

        response = self.client.get(reverse("product-list"), {"barcode": "123456789"})

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(
            [product["default_variant"]["sku"] for product in response.data["results"]],
            ["MATCH"],
        )

    def test_active_barcode_lookup_bypasses_active_id_cache(self):
        match = create_product_with_default_variant(
            sku="MATCH",
            barcode="123456789",
            name="قهوة مطابقة",
            unit_price=Decimal("5.50"),
            is_active=True,
        )
        create_product_with_default_variant(
            sku="INACTIVE",
            barcode="987654321",
            name="قهوة متوقفة",
            unit_price=Decimal("4.50"),
            is_active=False,
        )

        with patch.object(
            ProductViewSet,
            "_get_active_product_ids",
            side_effect=AssertionError("barcode lookup should not load all active ids"),
        ):
            response = self.client.get(
                reverse("product-list"),
                {"barcode": "123456789", "is_active": "true"},
            )

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(
            [product["id"] for product in response.data["results"]],
            [match.id],
        )

    def test_product_list_reads_stock_quantity_from_queryset_annotation(self):
        product = create_product_with_default_variant(
            sku="STOCKED",
            barcode="987654321",
            name="منتج مخزن",
            unit_price=Decimal("3.00"),
            is_active=True,
        )
        StockItem.objects.create(variant=product.default_variant, quantity_on_hand=7)
        variant = ProductVariant.objects.create(
            product=product,
            name="كبير",
            sku="STOCKED-L",
            unit_price=Decimal("4.00"),
        )
        StockItem.objects.create(variant=variant, quantity_on_hand=3)
        create_product_with_default_variant(
            sku="NO-STOCK",
            name="بدون مخزون",
            unit_price=Decimal("2.00"),
            is_active=True,
        )

        response = self.client.get(reverse("product-list"), {"is_active": "true"})

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        quantities_by_sku = {
            product["default_variant"]["sku"]: product["quantity_on_hand"]
            for product in response.data["results"]
        }
        self.assertEqual(quantities_by_sku["STOCKED"], 10)
        self.assertEqual(quantities_by_sku["NO-STOCK"], 0)

    def test_can_order_products_by_newest(self):
        first = create_product_with_default_variant(
            sku="FIRST",
            name="الأول",
            unit_price=Decimal("1.00"),
        )
        newest = create_product_with_default_variant(
            sku="NEWEST",
            name="الأحدث",
            unit_price=Decimal("2.00"),
        )

        response = self.client.get(reverse("product-list"), {"ordering": "-created_at"})

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(response.data["results"][0]["id"], newest.id)
        self.assertEqual(response.data["results"][-1]["id"], first.id)

    def test_cashier_can_view_but_cannot_create_products(self):
        cashier = get_user_model().objects.create_user(
            username="cashier",
            password="pass",
        )
        cashier.groups.add(Group.objects.get(name=CASHIER_GROUP))
        client = APIClient()
        client.force_authenticate(user=cashier)
        create_product_with_default_variant(
            sku="VIEW",
            name="متاح",
            unit_price=Decimal("1.00"),
        )

        list_response = client.get(reverse("product-list"))
        category_response = client.get(reverse("productcategory-list"))
        create_response = client.post(
            reverse("product-list"),
            {
                "name": "جديد",
                "default_variant": {"sku": "NEW", "unit_price": "1.00"},
            },
            format="json",
        )

        self.assertEqual(list_response.status_code, status.HTTP_200_OK)
        self.assertEqual(category_response.status_code, status.HTTP_200_OK)
        self.assertEqual(create_response.status_code, status.HTTP_403_FORBIDDEN)

    def test_top_level_product_variant_endpoint_creates_variant(self):
        product = create_product_with_default_variant(
            sku="COF-100",
            name="قهوة عربية",
            unit_price=Decimal("5.50"),
        )

        response = self.client.post(
            reverse("product-variant-list"),
            {
                "product": product.pk,
                "name": "كبير",
                "sku": " cof-100-l ",
                "barcode": "987654321",
                "unit_price": "7.00",
                "is_active": True,
            },
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_201_CREATED)
        variant = ProductVariant.objects.get(sku="COF-100-L")
        self.assertEqual(variant.product, product)
        self.assertEqual(response.data["product"], product.pk)
        self.assertEqual(response.data["product_detail"]["id"], product.pk)

    def test_product_variant_endpoint_filters_by_category_descendants(self):
        parent = ProductCategory.objects.create(name="مشروبات")
        child = ProductCategory.objects.create(name="قهوة", parent=parent)
        coffee = create_product_with_default_variant(
            sku="COF-100",
            name="قهوة عربية",
            unit_price=Decimal("5.50"),
        )
        tea = create_product_with_default_variant(
            sku="TEA-100",
            name="شاي",
            unit_price=Decimal("2.00"),
        )
        coffee.categories.add(child)
        tea.categories.add(ProductCategory.objects.create(name="شاي"))

        response = self.client.get(
            reverse("product-variant-list"),
            {"category": parent.pk},
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(
            [variant["id"] for variant in response.data["results"]],
            [coffee.default_variant.pk],
        )

    def test_nested_product_variants_returns_only_selected_product_variants(self):
        product = create_product_with_default_variant(
            sku="COF-100",
            name="قهوة عربية",
            unit_price=Decimal("5.50"),
        )
        other = create_product_with_default_variant(
            sku="TEA-100",
            name="شاي",
            unit_price=Decimal("2.00"),
        )
        ProductVariant.objects.create(
            product=product,
            name="كبير",
            sku="COF-100-L",
            unit_price=Decimal("7.00"),
        )

        response = self.client.get(reverse("product-variants", args=[product.pk]))

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(
            [variant["sku"] for variant in response.data["results"]],
            ["COF-100", "COF-100-L"],
        )
        self.assertNotIn(
            other.default_variant.pk,
            [variant["id"] for variant in response.data["results"]],
        )

    def test_nested_product_variants_force_url_product(self):
        product = create_product_with_default_variant(
            sku="COF-100",
            name="قهوة عربية",
            unit_price=Decimal("5.50"),
        )

        response = self.client.post(
            reverse("product-variants", args=[product.pk]),
            {
                "name": "كبير",
                "sku": "COF-100-L",
                "unit_price": "7.00",
                "is_active": True,
            },
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_201_CREATED)
        variant = ProductVariant.objects.get(sku="COF-100-L")
        self.assertEqual(variant.product, product)

    def test_nested_product_variants_reject_mismatched_product(self):
        product = create_product_with_default_variant(
            sku="COF-100",
            name="قهوة عربية",
            unit_price=Decimal("5.50"),
        )
        other = create_product_with_default_variant(
            sku="TEA-100",
            name="شاي",
            unit_price=Decimal("2.00"),
        )

        response = self.client.post(
            reverse("product-variants", args=[product.pk]),
            {
                "product": other.pk,
                "name": "كبير",
                "sku": "COF-100-L",
                "unit_price": "7.00",
            },
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)

    def test_product_variant_rejects_duplicate_values_for_same_option(self):
        product = create_product_with_default_variant(
            sku="COF-100",
            name="قهوة عربية",
            unit_price=Decimal("5.50"),
        )
        size = VariantOption.objects.create(code="size-test", name="الحجم")
        small = VariantOptionValue.objects.create(
            option=size,
            code="small",
            name="صغير",
        )
        large = VariantOptionValue.objects.create(
            option=size,
            code="large",
            name="كبير",
        )
        product.variant_options.add(size)

        response = self.client.post(
            reverse("product-variant-list"),
            {
                "product": product.pk,
                "name": "اختيار مكرر",
                "sku": "COF-100-BAD",
                "unit_price": "6.00",
                "option_values": [small.pk, large.pk],
            },
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertIn("option_values", response.data)

    def test_product_variant_rejects_duplicate_option_combination(self):
        product = create_product_with_default_variant(
            sku="COF-100",
            name="قهوة عربية",
            unit_price=Decimal("5.50"),
        )
        size = VariantOption.objects.create(code="size-combo", name="الحجم")
        color = VariantOption.objects.create(code="color-combo", name="اللون")
        small = VariantOptionValue.objects.create(
            option=size,
            code="small",
            name="صغير",
        )
        red = VariantOptionValue.objects.create(
            option=color,
            code="red",
            name="أحمر",
        )
        product.variant_options.add(size, color)
        existing_variant = ProductVariant.objects.create(
            product=product,
            name="صغير أحمر",
            sku="COF-100-S-RED",
            unit_price=Decimal("6.00"),
        )
        existing_variant.option_values.set([small, red])

        response = self.client.post(
            reverse("product-variant-list"),
            {
                "product": product.pk,
                "name": "مكرر",
                "sku": "COF-100-S-RED-2",
                "unit_price": "6.50",
                "option_values": [red.pk, small.pk],
            },
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertIn("option_values", response.data)

    def test_product_variant_rejects_values_outside_product_schema(self):
        product = create_product_with_default_variant(
            sku="COF-100",
            name="قهوة عربية",
            unit_price=Decimal("5.50"),
        )
        size = VariantOption.objects.create(code="size-schema", name="الحجم")
        flavor = VariantOption.objects.create(code="flavor-schema", name="النكهة")
        mint = VariantOptionValue.objects.create(
            option=flavor,
            code="mint",
            name="نعناع",
        )
        product.variant_options.add(size)

        response = self.client.post(
            reverse("product-variant-list"),
            {
                "product": product.pk,
                "name": "خارج المخطط",
                "sku": "COF-100-MINT",
                "unit_price": "6.00",
                "option_values": [mint.pk],
            },
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertIn("option_values", response.data)


class ProductArchiveApiTests(TestCase):
    def setUp(self):
        ensure_role_groups()
        self.client = APIClient()
        self.user = get_user_model().objects.create_user(
            username="archive-manager",
            password="pass",
        )
        self.user.groups.add(Group.objects.get(name=MANAGER_GROUP))
        self.client.force_authenticate(user=self.user)

    def _make_product(self, *, sku, name, is_active=True):
        return create_product_with_default_variant(
            sku=sku,
            name=name,
            unit_price=Decimal("5.00"),
            is_active=is_active,
        )

    def _result_ids(self, response):
        return {row["id"] for row in response.data["results"]}

    def test_archive_hides_product_from_default_list(self):
        live = self._make_product(sku="LIVE", name="حالي")
        archived = self._make_product(sku="OLD", name="قديم")

        archive_response = self.client.post(
            reverse("product-archive", args=[archived.pk])
        )

        self.assertEqual(archive_response.status_code, status.HTTP_200_OK)
        self.assertTrue(archive_response.data["is_archived"])
        self.assertIsNotNone(archive_response.data["archived_at"])

        archived.refresh_from_db()
        self.assertIsNotNone(archived.archived_at)
        self.assertEqual(archived.archived_by, self.user)

        list_response = self.client.get(reverse("product-list"))
        self.assertEqual(self._result_ids(list_response), {live.id})

    def test_archived_filter_returns_only_archived(self):
        live = self._make_product(sku="LIVE", name="حالي")
        archived = self._make_product(sku="OLD", name="قديم")
        self.client.post(reverse("product-archive", args=[archived.pk]))

        response = self.client.get(reverse("product-list"), {"archived": "true"})

        self.assertEqual(self._result_ids(response), {archived.id})

    def test_archived_product_excluded_from_pos_active_list(self):
        archived = self._make_product(sku="OLD", name="قديم", is_active=True)
        self.client.post(reverse("product-archive", args=[archived.pk]))

        response = self.client.get(reverse("product-list"), {"is_active": "true"})

        self.assertNotIn(archived.id, self._result_ids(response))

    def test_archived_product_variants_excluded_from_variant_endpoint(self):
        archived = self._make_product(sku="OLD", name="قديم")
        self.client.post(reverse("product-archive", args=[archived.pk]))

        response = self.client.get(reverse("product-variant-list"))

        skus = {row["sku"] for row in response.data["results"]}
        self.assertNotIn("OLD", skus)

    def test_restore_brings_product_back_without_changing_is_active(self):
        product = self._make_product(sku="OLD", name="قديم", is_active=True)
        self.client.post(reverse("product-archive", args=[product.pk]))

        restore_response = self.client.post(
            reverse("product-restore", args=[product.pk])
        )

        self.assertEqual(restore_response.status_code, status.HTTP_200_OK)
        self.assertFalse(restore_response.data["is_archived"])
        product.refresh_from_db()
        self.assertIsNone(product.archived_at)
        self.assertIsNone(product.archived_by)
        self.assertTrue(product.is_active)

        list_response = self.client.get(reverse("product-list"))
        self.assertIn(product.id, self._result_ids(list_response))

    def test_delete_soft_archives_instead_of_removing(self):
        product = self._make_product(sku="OLD", name="قديم")

        response = self.client.delete(reverse("product-detail", args=[product.pk]))

        self.assertEqual(response.status_code, status.HTTP_204_NO_CONTENT)
        self.assertTrue(Product.objects.filter(pk=product.pk).exists())
        product.refresh_from_db()
        self.assertIsNotNone(product.archived_at)

    def test_cashier_cannot_archive(self):
        product = self._make_product(sku="OLD", name="قديم")
        cashier = get_user_model().objects.create_user(
            username="archive-cashier",
            password="pass",
        )
        cashier.groups.add(Group.objects.get(name=CASHIER_GROUP))
        client = APIClient()
        client.force_authenticate(user=cashier)

        response = client.post(reverse("product-archive", args=[product.pk]))

        self.assertEqual(response.status_code, status.HTTP_403_FORBIDDEN)
        product.refresh_from_db()
        self.assertIsNone(product.archived_at)


class ProductInStockFilterApiTests(TestCase):
    def setUp(self):
        ensure_role_groups()
        self.client = APIClient()
        self.user = get_user_model().objects.create_user(
            username="instock-user",
            password="pass",
        )
        self.user.groups.add(Group.objects.get(name=MANAGER_GROUP))
        self.client.force_authenticate(user=self.user)

    def _stocked_product(self, *, sku, name, quantity):
        product = create_product_with_default_variant(
            sku=sku,
            name=name,
            unit_price=Decimal("5.00"),
        )
        StockItem.objects.create(
            variant=product.default_variant,
            quantity_on_hand=Decimal(quantity),
        )
        return product

    def _result_ids(self, response):
        return {row["id"] for row in response.data["results"]}

    def test_in_stock_hides_zero_quantity_products(self):
        in_stock = self._stocked_product(sku="HAS", name="متوفر", quantity="5")
        out_of_stock = self._stocked_product(sku="OUT", name="منتهٍ", quantity="0")

        response = self.client.get(reverse("product-list"), {"in_stock": "true"})

        ids = self._result_ids(response)
        self.assertIn(in_stock.id, ids)
        self.assertNotIn(out_of_stock.id, ids)

    def test_in_stock_keeps_service_and_prepared_products(self):
        service = create_product_with_default_variant(
            sku="SVC", name="خدمة", unit_price=Decimal("5.00")
        )
        service.is_service = True
        service.save(update_fields=["is_service"])
        prepared = create_product_with_default_variant(
            sku="DISH", name="طبق", unit_price=Decimal("5.00")
        )
        prepared.is_prepared = True
        prepared.save(update_fields=["is_prepared"])
        out_of_stock = self._stocked_product(sku="OUT", name="منتهٍ", quantity="0")

        response = self.client.get(reverse("product-list"), {"in_stock": "true"})

        ids = self._result_ids(response)
        self.assertIn(service.id, ids)
        self.assertIn(prepared.id, ids)
        self.assertNotIn(out_of_stock.id, ids)

    def test_without_in_stock_returns_zero_quantity_products(self):
        out_of_stock = self._stocked_product(sku="OUT", name="منتهٍ", quantity="0")

        response = self.client.get(reverse("product-list"))

        self.assertIn(out_of_stock.id, self._result_ids(response))

    def test_in_stock_combines_with_active_pos_filter(self):
        in_stock = self._stocked_product(sku="HAS", name="متوفر", quantity="5")
        out_of_stock = self._stocked_product(sku="OUT", name="منتهٍ", quantity="0")

        response = self.client.get(
            reverse("product-list"),
            {"is_active": "true", "in_stock": "true"},
        )

        ids = self._result_ids(response)
        self.assertIn(in_stock.id, ids)
        self.assertNotIn(out_of_stock.id, ids)


class ProductBulkActionTests(TestCase):
    def setUp(self):
        ensure_role_groups()
        self.client = APIClient()
        self.user = get_user_model().objects.create_user(
            username="bulk-user",
            password="pass",
        )
        self.user.groups.add(Group.objects.get(name=MANAGER_GROUP))
        self.client.force_authenticate(user=self.user)

    def _product(self, name, sku, price):
        return create_product_with_default_variant(
            name=name,
            sku=sku,
            unit_price=Decimal(price),
        )

    def test_bulk_archive_and_restore(self):
        a = self._product("a", "BA-1", "1.00")
        b = self._product("b", "BA-2", "2.00")

        response = self.client.post(
            reverse("product-bulk-archive"),
            {"ids": [a.id, b.id], "archived": True},
            format="json",
        )
        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(response.data["updated"], 2)
        a.refresh_from_db()
        b.refresh_from_db()
        self.assertTrue(a.is_archived)
        self.assertTrue(b.is_archived)

        response = self.client.post(
            reverse("product-bulk-archive"),
            {"ids": [a.id], "archived": False},
            format="json",
        )
        self.assertEqual(response.data["updated"], 1)
        a.refresh_from_db()
        self.assertFalse(a.is_archived)

    def test_bulk_reprice_modes(self):
        a = self._product("a", "BR-1", "10.00")
        b = self._product("b", "BR-2", "20.00")

        response = self.client.post(
            reverse("product-bulk-reprice"),
            {"ids": [a.id, b.id], "mode": "increase_percent", "value": "10"},
            format="json",
        )
        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(a.default_variant.unit_price, Decimal("11.00"))
        self.assertEqual(b.default_variant.unit_price, Decimal("22.00"))

        self.client.post(
            reverse("product-bulk-reprice"),
            {"ids": [a.id], "mode": "set", "value": "5.55"},
            format="json",
        )
        self.assertEqual(a.default_variant.unit_price, Decimal("5.55"))

        # A decrease that would go negative is clamped to zero.
        self.client.post(
            reverse("product-bulk-reprice"),
            {"ids": [a.id], "mode": "decrease_amount", "value": "9.99"},
            format="json",
        )
        self.assertEqual(a.default_variant.unit_price, Decimal("0.00"))

    def test_set_variant_prices_updates_all_variants_atomically(self):
        product = self._product("multi", "SVP-1", "10.00")
        default_variant = product.default_variant
        second = product.variants.create(
            name="large",
            sku="SVP-1-L",
            unit_price=Decimal("12.00"),
        )

        response = self.client.post(
            reverse("product-set-variant-prices", args=[product.id]),
            {
                "prices": [
                    {"variant": default_variant.id, "unit_price": "15.50"},
                    {"variant": second.id, "unit_price": "18.00"},
                ]
            },
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        default_variant.refresh_from_db()
        second.refresh_from_db()
        self.assertEqual(default_variant.unit_price, Decimal("15.50"))
        self.assertEqual(second.unit_price, Decimal("18.00"))

    def test_set_variant_prices_rejects_variant_from_other_product(self):
        product = self._product("a", "SVP-2", "10.00")
        other = self._product("b", "SVP-3", "10.00")
        other_variant = other.default_variant

        response = self.client.post(
            reverse("product-set-variant-prices", args=[product.id]),
            {"prices": [{"variant": other_variant.id, "unit_price": "1.00"}]},
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        other_variant.refresh_from_db()
        self.assertEqual(other_variant.unit_price, Decimal("10.00"))

    def test_set_variant_prices_requires_change_permission(self):
        product = self._product("a", "SVP-4", "10.00")
        viewer = get_user_model().objects.create_user(
            username="viewer",
            password="pass",
        )
        viewer.user_permissions.add(
            Permission.objects.get(
                content_type__app_label="catalog",
                codename="view_product",
            )
        )
        self.client.force_authenticate(user=viewer)

        response = self.client.post(
            reverse("product-set-variant-prices", args=[product.id]),
            {"prices": [{"variant": product.default_variant.id, "unit_price": "1.00"}]},
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_403_FORBIDDEN)

    def test_bulk_categorize_add_then_replace(self):
        a = self._product("a", "BC-1", "1.00")
        drinks = ProductCategory.objects.create(name="drinks")
        food = ProductCategory.objects.create(name="food")

        self.client.post(
            reverse("product-bulk-categorize"),
            {"ids": [a.id], "category_ids": [drinks.id], "mode": "add"},
            format="json",
        )
        self.assertEqual(
            set(a.categories.values_list("id", flat=True)), {drinks.id}
        )

        self.client.post(
            reverse("product-bulk-categorize"),
            {"ids": [a.id], "category_ids": [food.id], "mode": "replace"},
            format="json",
        )
        self.assertEqual(
            set(a.categories.values_list("id", flat=True)), {food.id}
        )

    def test_bulk_set_flags(self):
        a = self._product("a", "BF-1", "1.00")
        b = self._product("b", "BF-2", "2.00")

        response = self.client.post(
            reverse("product-bulk-set-flags"),
            {"ids": [a.id, b.id], "is_active": False, "is_service": True},
            format="json",
        )
        self.assertEqual(response.data["updated"], 2)
        a.refresh_from_db()
        self.assertFalse(a.is_active)
        self.assertTrue(a.is_service)

    def test_bulk_action_requires_ids(self):
        response = self.client.post(
            reverse("product-bulk-archive"),
            {"ids": [], "archived": True},
            format="json",
        )
        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)

    def test_bulk_action_forbidden_for_cashier(self):
        cashier = get_user_model().objects.create_user(
            username="bulk-cashier",
            password="pass",
        )
        cashier.groups.add(Group.objects.get(name=CASHIER_GROUP))
        client = APIClient()
        client.force_authenticate(user=cashier)
        a = self._product("a", "BX-1", "1.00")

        response = client.post(
            reverse("product-bulk-set-flags"),
            {"ids": [a.id], "is_active": False},
            format="json",
        )
        self.assertEqual(response.status_code, status.HTTP_403_FORBIDDEN)


class ProductBoughtTogetherApiTests(TestCase):
    """The product-detail "frequently bought together" endpoint."""

    def setUp(self):
        ensure_role_groups()
        self.client = APIClient()
        self.user = get_user_model().objects.create_user(
            username="bought-together-manager",
            password="pass",
        )
        self.user.groups.add(Group.objects.get(name=MANAGER_GROUP))
        self.client.force_authenticate(user=self.user)

    def _variant(self, name, sku):
        product = create_product_with_default_variant(
            name=name,
            sku=sku,
            unit_price=Decimal("5.00"),
        )
        variant = product.default_variant
        StockItem.objects.create(variant=variant, quantity_on_hand=Decimal("100"))
        return product, variant

    def _basket_orders(self):
        """Three paid orders — (A,B), (A,B), (A,C) — so against A, B co-occurs
        twice and C once. D never sells and shouldn't appear."""
        from apps.payments.models import Payment
        from apps.sales.models import RegisterSession
        from apps.sales.services import checkout_order

        self.product_a, a = self._variant("ألف", "BKT-A")
        self.product_b, b = self._variant("باء", "BKT-B")
        self.product_c, c = self._variant("جيم", "BKT-C")
        self.product_d, _ = self._variant("دال", "BKT-D")
        session = RegisterSession.objects.create(
            owner_key="seed:catalog-basket",
            status=RegisterSession.Status.OPEN,
        )

        def order(*variants):
            checkout_order(
                register_session=session,
                lines_data=[
                    {"variant": variant, "quantity": Decimal("1")}
                    for variant in variants
                ],
                payments_data=[
                    {"method": Payment.Method.CASH, "amount": Decimal(5 * len(variants))}
                ],
            )

        order(a, b)
        order(a, b)
        order(a, c)

    def test_ranks_neighbours_by_orders_together(self):
        self._basket_orders()

        response = self.client.get(
            reverse("product-bought-together", args=[self.product_a.pk])
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(response.data["product"], self.product_a.pk)
        results = response.data["results"]
        self.assertEqual(
            [(row["id"], row["orders_together"]) for row in results],
            [(self.product_b.pk, 2), (self.product_c.pk, 1)],
        )
        # The product being viewed and never-paired products are excluded.
        ids = {row["id"] for row in results}
        self.assertNotIn(self.product_a.pk, ids)
        self.assertNotIn(self.product_d.pk, ids)
        # Cards carry the price the panel renders.
        self.assertEqual(results[0]["unit_price"], "5.00")

    def test_excludes_archived_neighbours(self):
        self._basket_orders()
        self.product_b.archive(by=self.user)

        response = self.client.get(
            reverse("product-bought-together", args=[self.product_a.pk])
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        ids = [row["id"] for row in response.data["results"]]
        self.assertEqual(ids, [self.product_c.pk])

    def test_limit_is_capped(self):
        self._basket_orders()

        response = self.client.get(
            reverse("product-bought-together", args=[self.product_a.pk]),
            {"limit": "1"},
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(len(response.data["results"]), 1)
        self.assertEqual(response.data["results"][0]["id"], self.product_b.pk)

    def test_empty_when_product_never_sold(self):
        lonely = create_product_with_default_variant(
            name="وحيد",
            sku="LONELY",
            unit_price=Decimal("3.00"),
        )

        response = self.client.get(
            reverse("product-bought-together", args=[lonely.pk])
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(response.data["results"], [])

    def test_requires_authentication(self):
        product = create_product_with_default_variant(
            name="مغلق",
            sku="ANON",
            unit_price=Decimal("3.00"),
        )
        client = APIClient()

        response = client.get(
            reverse("product-bought-together", args=[product.pk])
        )

        self.assertIn(
            response.status_code,
            (status.HTTP_401_UNAUTHORIZED, status.HTTP_403_FORBIDDEN),
        )
