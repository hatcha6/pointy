from decimal import Decimal

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group
from django.test import TestCase
from django.urls import reverse
from rest_framework import status
from rest_framework.test import APIClient

from apps.core.roles import CASHIER_GROUP, MANAGER_GROUP, ensure_role_groups
from .models import Product


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
        response = self.client.post(
            reverse("product-list"),
            {
                "sku": " cof-100 ",
                "barcode": "123456789",
                "name": "قهوة عربية",
                "description": "حبوب مطحونة",
                "unit_price": "5.50",
                "is_active": True,
            },
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_201_CREATED)
        product = Product.objects.get()
        self.assertEqual(product.sku, "COF-100")
        self.assertEqual(product.name, "قهوة عربية")
        self.assertEqual(product.unit_price, Decimal("5.50"))

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
        create_response = client.post(
            reverse("product-list"),
            {"sku": "NEW", "name": "جديد", "unit_price": "1.00"},
            format="json",
        )

        self.assertEqual(list_response.status_code, status.HTTP_200_OK)
        self.assertEqual(create_response.status_code, status.HTTP_403_FORBIDDEN)
