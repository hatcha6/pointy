"""A category a feature keeps is the shop's in every way but one.

A provider's shelf of cards keeps one category it files its cards under
(``apps.integrations.shelf_category``), found by ``system_key`` and never by
name. So the shop may rename it, move it, switch it off, unpin it or reorder
it, and no sync changes that back. Deleting it is refused: the next sync would
only make it again, pinned.
"""

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group
from django.test import TestCase
from django.urls import reverse
from rest_framework import status
from rest_framework.test import APIClient

from apps.core.roles import MANAGER_GROUP, ensure_role_groups

from .models import ProductCategory


class SystemCategoryTests(TestCase):
    def setUp(self):
        ensure_role_groups()
        manager = get_user_model().objects.create_user(username="mgr", password="x")
        manager.groups.add(Group.objects.get(name=MANAGER_GROUP))
        self.client = APIClient()
        self.client.force_authenticate(manager)
        self.shelf = ProductCategory.objects.create(
            name="كروت قريب",
            system_key="vouchers:qareeb",
            is_quick_access=True,
            display_order=2,
        )
        self.drinks = ProductCategory.objects.create(name="مشروبات")

    def _url(self, category):
        return reverse("productcategory-detail", args=[category.pk])

    def test_the_api_says_which_one_the_system_keeps(self):
        response = self.client.get(reverse("productcategory-list"))
        self.assertEqual(response.status_code, status.HTTP_200_OK)
        flags = {row["id"]: row["is_system"] for row in response.data["results"]}
        self.assertEqual(flags, {self.shelf.pk: True, self.drinks.pk: False})

    def test_nobody_deletes_it(self):
        response = self.client.delete(self._url(self.shelf))
        self.assertEqual(response.status_code, status.HTTP_403_FORBIDDEN)
        self.assertEqual(response.data["code"], "system_category")
        self.assertTrue(ProductCategory.objects.filter(pk=self.shelf.pk).exists())
        # The shop's own categories delete exactly as before.
        response = self.client.delete(self._url(self.drinks))
        self.assertEqual(response.status_code, status.HTTP_204_NO_CONTENT)

    def test_the_shop_still_names_places_and_pins_it(self):
        response = self.client.patch(
            self._url(self.shelf),
            {
                "name": "الكروت",
                "parent": self.drinks.pk,
                "is_active": False,
                "is_quick_access": False,
                "display_order": 0,
            },
            format="json",
        )
        self.assertEqual(response.status_code, status.HTTP_200_OK, response.data)
        self.shelf.refresh_from_db()
        self.assertEqual(self.shelf.name, "الكروت")
        self.assertEqual(self.shelf.parent, self.drinks)
        self.assertFalse(self.shelf.is_active)
        self.assertFalse(self.shelf.is_quick_access)
        self.assertEqual(self.shelf.display_order, 0)
        # Still the feature's: an edit never loosens the key it is found by.
        self.assertEqual(self.shelf.system_key, "vouchers:qareeb")
        self.assertTrue(response.data["is_system"])

    def test_a_client_cannot_make_or_unmake_one(self):
        response = self.client.post(
            reverse("productcategory-list"),
            {"name": "مزيف", "is_system": True, "system_key": "vouchers:qareeb"},
            format="json",
        )
        self.assertEqual(response.status_code, status.HTTP_201_CREATED, response.data)
        self.assertEqual(ProductCategory.objects.get(name="مزيف").system_key, "")
        self.assertFalse(response.data["is_system"])

        response = self.client.patch(
            self._url(self.shelf), {"is_system": False, "system_key": ""}, format="json"
        )
        self.assertEqual(response.status_code, status.HTTP_200_OK, response.data)
        self.shelf.refresh_from_db()
        self.assertEqual(self.shelf.system_key, "vouchers:qareeb")
