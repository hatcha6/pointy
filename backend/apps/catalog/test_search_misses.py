"""Searches that found nothing, and the owner's worklist that fixes them."""

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group
from django.test import TestCase
from django.urls import reverse
from rest_framework import status
from rest_framework.test import APIClient

from apps.core.roles import CASHIER_GROUP, MANAGER_GROUP, ensure_role_groups

from .models import Product, ProductAlias, SearchMiss
from .search_misses import record_search_miss
from .testing import create_product_with_default_variant


class _Base(TestCase):
    def setUp(self):
        ensure_role_groups()
        self.client = APIClient()
        self.manager = get_user_model().objects.create_user(
            username="miss-manager", password="pass"
        )
        self.manager.groups.add(Group.objects.get(name=MANAGER_GROUP))
        self.client.force_authenticate(user=self.manager)
        self.rice = create_product_with_default_variant(
            name="أرز النجمة", sku="RICE-1", unit_price="1"
        )

    def _search(self, term, **params):
        params.setdefault("is_active", "true")
        params["search"] = term
        return self.client.get(reverse("product-list"), params)


class RecordingTests(_Base):
    def test_an_empty_search_is_counted_once_per_folded_word(self):
        self._search("زعتر بري")
        self._search("زَعتر  بري")

        miss = SearchMiss.objects.get()
        self.assertEqual(miss.count, 2)
        self.assertEqual(miss.normalized, "زعتر بري")

    def test_the_surface_follows_the_screen(self):
        self._search("زعتر بري", system="sellable")

        self.assertEqual(SearchMiss.objects.get().surface, SearchMiss.Surface.POS)

    def test_a_search_that_found_something_is_not_a_miss(self):
        self._search("ارز")

        self.assertFalse(SearchMiss.objects.exists())

    def test_codes_phone_numbers_and_keystrokes_are_never_recorded(self):
        for term in ("0912345678", "+218 91 234 5678", "123456", "زع", "A1"):
            with self.subTest(term=term):
                self._search(term)
        self.assertFalse(SearchMiss.objects.exists())

    def test_out_of_stock_is_not_a_miss(self):
        self._search("ارز", in_stock="true", system="sellable")

        self.assertFalse(SearchMiss.objects.exists())

    def test_a_resolved_word_that_misses_again_reopens(self):
        record_search_miss("زعتر بري")
        SearchMiss.objects.update(status=SearchMiss.Status.RESOLVED)

        record_search_miss("زعتر بري")

        self.assertEqual(SearchMiss.objects.get().status, SearchMiss.Status.OPEN)

    def test_a_dismissed_word_stays_dismissed(self):
        record_search_miss("زعتر بري")
        SearchMiss.objects.update(status=SearchMiss.Status.DISMISSED)

        record_search_miss("زعتر بري")

        miss = SearchMiss.objects.get()
        self.assertEqual(miss.status, SearchMiss.Status.DISMISSED)
        self.assertEqual(miss.count, 2)


class WorklistTests(_Base):
    def _misses(self, **params):
        response = self.client.get(reverse("search-miss-list"), params)
        self.assertEqual(response.status_code, status.HTTP_200_OK, response.data)
        return response.data["results"]

    def test_most_typed_first(self):
        record_search_miss("كسكسي")
        for _ in range(3):
            record_search_miss("زعتر بري")

        self.assertEqual([row["term"] for row in self._misses()], ["زعتر بري", "كسكسي"])

    def test_resolving_teaches_the_catalogue_the_word(self):
        self._search("بسمتي")
        miss = SearchMiss.objects.get()

        response = self.client.post(
            reverse("search-miss-resolve", args=[miss.pk]), {"product": self.rice.pk}
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK, response.data)
        self.assertEqual(response.data["status"], "resolved")
        self.assertEqual(response.data["product_name"], "أرز النجمة")
        self.assertTrue(ProductAlias.objects.filter(product=self.rice, alias="بسمتي").exists())
        found = self._search("بسمتي")
        self.assertEqual([row["id"] for row in found.data["results"]], [self.rice.pk])
        self.assertEqual(self._misses(), [])

    def test_dismissing_takes_it_off_the_list(self):
        record_search_miss("زعتر بري")
        miss = SearchMiss.objects.get()

        response = self.client.post(reverse("search-miss-dismiss", args=[miss.pk]))

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(self._misses(), [])
        self.assertEqual(len(self._misses(status="dismissed")), 1)

    def test_reopening_puts_it_back(self):
        record_search_miss("زعتر بري")
        miss = SearchMiss.objects.get()
        self.client.post(reverse("search-miss-dismiss", args=[miss.pk]))

        self.client.post(reverse("search-miss-reopen", args=[miss.pk]))

        self.assertEqual([row["term"] for row in self._misses()], ["زعتر بري"])

    def test_reopening_takes_back_the_alias_resolving_taught(self):
        self._search("بسمتي")
        miss = SearchMiss.objects.get()
        self.client.post(
            reverse("search-miss-resolve", args=[miss.pk]), {"product": self.rice.pk}
        )

        self.client.post(reverse("search-miss-reopen", args=[miss.pk]))

        self.assertFalse(ProductAlias.objects.filter(product=self.rice).exists())
        self.assertEqual(self._search("بسمتي").data["results"], [])

    def test_reopening_leaves_an_alias_that_was_already_there(self):
        ProductAlias.objects.create(product=self.rice, alias="بسمتي", normalized="بسمتي")
        record_search_miss("بسمتي")
        miss = SearchMiss.objects.get()
        self.client.post(
            reverse("search-miss-resolve", args=[miss.pk]), {"product": self.rice.pk}
        )

        self.client.post(reverse("search-miss-reopen", args=[miss.pk]))

        self.assertTrue(ProductAlias.objects.filter(product=self.rice).exists())

    def test_a_system_product_keeps_its_names(self):
        record_search_miss("زعتر بري")
        miss = SearchMiss.objects.get()
        Product.objects.filter(pk=self.rice.pk).update(is_system=True)

        response = self.client.post(
            reverse("search-miss-resolve", args=[miss.pk]), {"product": self.rice.pk}
        )

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertFalse(ProductAlias.objects.exists())

    def test_a_cashier_cannot_see_or_change_the_list(self):
        cashier = get_user_model().objects.create_user(username="miss-cashier", password="p")
        cashier.groups.add(Group.objects.get(name=CASHIER_GROUP))
        record_search_miss("زعتر بري")
        miss = SearchMiss.objects.get()
        self.client.force_authenticate(user=cashier)

        listed = self.client.get(reverse("search-miss-list"))
        resolved = self.client.post(
            reverse("search-miss-resolve", args=[miss.pk]), {"product": self.rice.pk}
        )

        self.assertEqual(listed.status_code, status.HTTP_403_FORBIDDEN)
        self.assertEqual(resolved.status_code, status.HTTP_403_FORBIDDEN)
