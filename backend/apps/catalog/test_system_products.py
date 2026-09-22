"""A product a feature owns is not a product the shop sells.

``apps.integrations`` creates one service product per recharge provider,
because every order line has to point at a real variant. It is priced per line
from the provider's own quote, so its standing price is zero and always will
be — and on Annaseem's till it appeared in the POS catalog grid as
«شحن اشتراك LNET — 0.00 د.ل», near the front, because the default sort is
most-bought and an agency sells hundreds of top-ups a week. Tapping it added a
free line that topped nobody up.

These pin both halves of the answer: it is hidden from every listing that
sells or quotes, and the one surface that manages products has to ask for it.
"""

from decimal import Decimal

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group
from django.test import TestCase
from django.urls import reverse
from rest_framework import status
from rest_framework.test import APIClient

from apps.core.roles import MANAGER_GROUP, ensure_role_groups

from .models import Product
from .testing import create_product_with_default_variant


class SystemProductVisibilityTests(TestCase):
    def setUp(self):
        ensure_role_groups()
        self.client = APIClient()
        self.user = get_user_model().objects.create_user(
            username="catalog-manager",
            password="pass",
        )
        self.user.groups.add(Group.objects.get(name=MANAGER_GROUP))
        self.client.force_authenticate(user=self.user)

        self.ordinary = create_product_with_default_variant(
            name="أرز",
            sku="RICE-1",
            unit_price=Decimal("5.00"),
        )
        self.system = create_product_with_default_variant(
            name="شحن اشتراك LNET",
            sku="INTEG-LNET",
            unit_price=Decimal("0.00"),
        )
        Product.objects.filter(pk=self.system.pk).update(
            is_service=True, is_system=True
        )
        self.system.refresh_from_db()

    def _ids(self, response):
        return {row["id"] for row in response.data["results"]}

    def test_the_default_listing_leaves_it_out(self):
        response = self.client.get(reverse("product-list"))

        self.assertEqual(self._ids(response), {self.ordinary.id})

    def test_the_till_listing_leaves_it_out(self):
        # ?is_active=true takes a different branch (a cached id list), so the
        # exclusion has to hold on that path too — and it is the branch the
        # POS grid actually uses.
        response = self.client.get(reverse("product-list"), {"is_active": "true"})

        self.assertEqual(self._ids(response), {self.ordinary.id})

    def test_a_search_cannot_reach_it_either(self):
        # Hiding it from the grid but leaving it findable by name would move
        # the same free line one keystroke away.
        response = self.client.get(reverse("product-list"), {"search": "شحن"})

        self.assertEqual(self._ids(response), set())

    def test_an_in_stock_listing_leaves_it_out(self):
        # A service product is exempt from the stock filter — deliberately,
        # since it holds no stock — so this is the one listing it would
        # otherwise survive. (The ordinary product has no stock either and is
        # correctly absent, which is why only the system one is asserted on.)
        response = self.client.get(reverse("product-list"), {"in_stock": "true"})

        self.assertNotIn(self.system.id, self._ids(response))

    def test_the_back_office_asks_for_it_and_gets_it(self):
        response = self.client.get(reverse("product-list"), {"system": "all"})

        self.assertEqual(self._ids(response), {self.ordinary.id, self.system.id})

    def test_it_is_still_reachable_by_id(self):
        # Renaming it, archiving it and reading its sales all go through the
        # detail route; only the LIST is scoped.
        response = self.client.get(reverse("product-detail", args=[self.system.pk]))

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertTrue(response.data["is_system"])

    def test_a_client_cannot_declare_its_own_product_a_system_one(self):
        response = self.client.patch(
            reverse("product-detail", args=[self.ordinary.pk]),
            {"is_system": True},
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.ordinary.refresh_from_db()
        self.assertFalse(self.ordinary.is_system)
