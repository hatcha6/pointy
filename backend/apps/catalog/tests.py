from decimal import Decimal
from unittest.mock import patch

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group
from django.test import TestCase
from django.urls import reverse
from rest_framework import status
from rest_framework.test import APIClient

from apps.core.roles import CASHIER_GROUP, MANAGER_GROUP, ensure_role_groups
from apps.inventory.models import StockItem
from .models import Product, ProductCategory
from .views import ProductViewSet


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
                "sku": " cof-100 ",
                "barcode": "123456789",
                "name": "قهوة عربية",
                "description": "حبوب مطحونة",
                "unit_price": "5.50",
                "is_active": True,
                "categories": [category.id],
            },
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_201_CREATED)
        product = Product.objects.get()
        self.assertEqual(product.sku, "COF-100")
        self.assertEqual(product.name, "قهوة عربية")
        self.assertEqual(product.unit_price, Decimal("5.50"))
        self.assertEqual(list(product.categories.values_list("id", flat=True)), [category.id])
        self.assertEqual(response.data["categories"], [category.id])

    def test_reject_negative_price(self):
        response = self.client.post(
            reverse("product-list"),
            {
                "sku": "BAD-001",
                "name": "منتج غير صالح",
                "unit_price": "-1.00",
                "is_active": True,
            },
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)

    def test_search_filter_and_order_products(self):
        Product.objects.create(
            sku="COF-100",
            barcode="111",
            name="قهوة عربية",
            unit_price=Decimal("5.50"),
            is_active=True,
        )
        Product.objects.create(
            sku="TEA-100",
            barcode="222",
            name="شاي نعناع",
            unit_price=Decimal("2.75"),
            is_active=True,
        )
        Product.objects.create(
            sku="OLD-100",
            barcode="333",
            name="منتج متوقف",
            unit_price=Decimal("1.50"),
            is_active=False,
        )

        response = self.client.get(
            reverse("product-list"),
            {"search": "100", "is_active": "true", "ordering": "unit_price"},
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        results = response.data["results"]
        self.assertEqual([product["sku"] for product in results], ["TEA-100", "COF-100"])

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

    def test_reject_category_parent_cycle(self):
        parent = ProductCategory.objects.create(name="الأصل")
        child = ProductCategory.objects.create(name="الفرع", parent=parent)

        response = self.client.patch(
            reverse("productcategory-detail", args=[parent.id]),
            {"parent": child.id},
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)

    def test_filter_products_by_category_includes_descendants(self):
        drinks = ProductCategory.objects.create(name="مشروبات")
        coffee = ProductCategory.objects.create(name="قهوة", parent=drinks)
        snack = ProductCategory.objects.create(name="وجبات خفيفة")
        latte = Product.objects.create(
            sku="LATTE",
            barcode="444",
            name="لاتيه",
            unit_price=Decimal("6.50"),
            is_active=True,
        )
        dates = Product.objects.create(
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
            [product["sku"] for product in response.data["results"]],
            ["LATTE"],
        )

    def test_active_category_filter_bypasses_active_id_cache(self):
        category = ProductCategory.objects.create(name="مشروبات")
        match = Product.objects.create(
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
        Product.objects.create(
            sku="MATCH",
            barcode="123456789",
            name="قهوة مطابقة",
            unit_price=Decimal("5.50"),
            is_active=True,
        )
        Product.objects.create(
            sku="PARTIAL",
            barcode="1234567890",
            name="قهوة قريبة",
            unit_price=Decimal("6.50"),
            is_active=True,
        )

        response = self.client.get(reverse("product-list"), {"barcode": "123456789"})

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(
            [product["sku"] for product in response.data["results"]],
            ["MATCH"],
        )

    def test_active_barcode_lookup_bypasses_active_id_cache(self):
        match = Product.objects.create(
            sku="MATCH",
            barcode="123456789",
            name="قهوة مطابقة",
            unit_price=Decimal("5.50"),
            is_active=True,
        )
        Product.objects.create(
            sku="INACTIVE",
            barcode="123456789",
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
        product = Product.objects.create(
            sku="STOCKED",
            barcode="987654321",
            name="منتج مخزن",
            unit_price=Decimal("3.00"),
            is_active=True,
        )
        StockItem.objects.create(product=product, quantity_on_hand=7)
        Product.objects.create(
            sku="NO-STOCK",
            name="بدون مخزون",
            unit_price=Decimal("2.00"),
            is_active=True,
        )

        response = self.client.get(reverse("product-list"), {"is_active": "true"})

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        quantities_by_sku = {
            product["sku"]: product["quantity_on_hand"]
            for product in response.data["results"]
        }
        self.assertEqual(quantities_by_sku["STOCKED"], 7)
        self.assertEqual(quantities_by_sku["NO-STOCK"], 0)

    def test_can_order_products_by_newest(self):
        first = Product.objects.create(
            sku="FIRST",
            name="الأول",
            unit_price=Decimal("1.00"),
        )
        newest = Product.objects.create(
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
        Product.objects.create(
            sku="VIEW",
            name="متاح",
            unit_price=Decimal("1.00"),
        )

        list_response = client.get(reverse("product-list"))
        category_response = client.get(reverse("productcategory-list"))
        create_response = client.post(
            reverse("product-list"),
            {"sku": "NEW", "name": "جديد", "unit_price": "1.00"},
            format="json",
        )

        self.assertEqual(list_response.status_code, status.HTTP_200_OK)
        self.assertEqual(category_response.status_code, status.HTTP_200_OK)
        self.assertEqual(create_response.status_code, status.HTTP_403_FORBIDDEN)
