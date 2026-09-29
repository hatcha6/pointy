"""The list search boxes find a record however it is typed.

Customers, suppliers and the jobs board searched with DRF's stock filter:
``icontains`` on the raw column, so «احمد» never found «أحمد» and a phone typed
«+218 91-234 5678» never found «0912345678». These pin the folding filter's
promises through the real endpoints, and that it is still DRF's filter
underneath: every term required, in any order, and the ``^ = @ $`` prefixes
unchanged.
"""

from django.contrib.auth import get_user_model
from django.test import SimpleTestCase, TestCase
from django.urls import reverse
from rest_framework import status
from rest_framework.filters import SearchFilter
from rest_framework.request import Request
from rest_framework.settings import api_settings
from rest_framework.test import APIClient, APIRequestFactory

from apps.core.roles import MANAGER_GROUP, ensure_role_groups
from apps.core.search_filters import (
    FOLDING_FILTER_BACKENDS,
    FoldingSearchFilter,
    is_one_phone_number,
    is_phone_field,
)
from apps.customers.models import Customer
from apps.customers.views import CustomerViewSet
from apps.operations.tests import OperationsTestCase, authenticated_client
from apps.operations.views import JobViewSet
from apps.purchasing.models import Supplier
from apps.purchasing.views import SupplierViewSet

# Every way a cashier writes the one number saved as «0912345678».
PHONE_SPELLINGS = (
    "0912345678",
    "912345678",
    "+218912345678",
    "218912345678",
    "00218912345678",
    "+218 91-234 5678",
    "+218 91 234 5678",
    "091 234 5678",
    "091-234-5678",
    "(091) 234 5678",
    "٠٩١٢٣٤٥٦٧٨",
    "٠٩١ ٢٣٤ ٥٦٧٨",
    "۰۹۱۲۳۴۵۶۷۸",
)


def _search_terms(search):
    request = Request(APIRequestFactory().get("/", {"search": search}))
    return FoldingSearchFilter().get_search_terms(request)


class FoldingSearchFilterUnitTests(SimpleTestCase):
    def test_the_backends_are_the_project_default_with_the_search_swapped(self):
        expected = tuple(
            FoldingSearchFilter if backend is SearchFilter else backend
            for backend in api_settings.DEFAULT_FILTER_BACKENDS
        )
        self.assertEqual(FOLDING_FILTER_BACKENDS, expected)
        for viewset in (CustomerViewSet, SupplierViewSet, JobViewSet):
            with self.subTest(viewset=viewset.__name__):
                self.assertEqual(tuple(viewset.filter_backends), expected)

    def test_a_search_that_is_one_phone_number_stays_one_term(self):
        # As its digits: the phone fields read their key from them, and a code
        # typed in groups still finds the unbroken code a text field stores.
        self.assertEqual(_search_terms("+218 91-234 5678"), ["218912345678"])
        self.assertEqual(_search_terms(" 091 234 5678 "), ["0912345678"])
        self.assertEqual(_search_terms("٠٩١ ٢٣٤ ٥٦٧٨"), ["0912345678"])

    def test_anything_else_splits_the_way_drf_splits_it(self):
        self.assertEqual(_search_terms("محمد علي"), ["محمد", "علي"])
        self.assertEqual(_search_terms("احمد 0912345678"), ["احمد", "0912345678"])
        self.assertEqual(_search_terms("091 23"), ["091", "23"])  # too few digits
        # Two numbers typed together are two terms, not one impossible number.
        self.assertEqual(_search_terms("0912345678 0923456789"), ["0912345678", "0923456789"])
        self.assertEqual(_search_terms('"محمد علي" حسن'), ["محمد علي", "حسن"])

    def test_one_phone_number(self):
        for text in ("0912345678", "+218 91-234 5678", "00218 91 234 5678"):
            with self.subTest(text=text):
                self.assertTrue(is_one_phone_number(text))
        for text in ("12345", "0912345678 0923456789", "احمد 0912345678", ""):
            with self.subTest(text=text):
                self.assertFalse(is_one_phone_number(text))

    def test_phone_fields_are_named_for_it(self):
        for name in ("phone", "customer__phone", "mobile_phone", "customer__work_phone"):
            with self.subTest(name=name):
                self.assertTrue(is_phone_field(name))
        for name in ("full_name", "phones", "phone_model", "customer__telephone_note"):
            with self.subTest(name=name):
                self.assertFalse(is_phone_field(name))

    def test_each_search_field_gets_its_lookup(self):
        search = FoldingSearchFilter()
        customers = Customer.objects.all()
        expected = {
            "full_name": "full_name__pfold_contains",
            "email": "email__pfold_contains",
            "phone": "phone__pphone_contains",
            # DRF's prefixes and spelled-out lookups keep their stock meaning.
            "^full_name": "full_name__istartswith",
            "=customer_number": "customer_number__iexact",
            "$full_name": "full_name__iregex",
            "full_name__iexact": "full_name__iexact",
            # Not a text column: nothing to fold, the stock lookup stands.
            "id": "id__icontains",
            "staff_employee": "staff_employee__icontains",
        }
        for field, lookup in expected.items():
            with self.subTest(field=field):
                self.assertEqual(search.construct_search(field, customers), lookup)

    def test_a_related_phone_field_is_a_phone_field(self):
        search = FoldingSearchFilter()
        self.assertEqual(
            search.construct_search("customer__phone", JobViewSet.queryset),
            "customer__phone__pphone_contains",
        )
        self.assertEqual(
            search.construct_search("job_assets__asset__imei", JobViewSet.queryset),
            "job_assets__asset__imei__pfold_contains",
        )


def _manager_client():
    groups = ensure_role_groups()
    user = get_user_model().objects.create_user(username="search-manager", password="p")
    user.groups.add(groups[MANAGER_GROUP])
    client = APIClient()
    client.force_authenticate(user)
    return client


def _names(response, key):
    assert response.status_code == status.HTTP_200_OK, response.data
    return sorted(row[key] for row in response.data["results"])


class CustomerSearchTests(TestCase):
    def setUp(self):
        self.client = _manager_client()
        # Numbered by hand: the automatic «C{today}{id}» could hold the very
        # digits a test searches for on some days of the year.
        Customer.objects.create(
            full_name="أحمد الطاهر", phone="0912345678", customer_number="C20260101000001"
        )
        Customer.objects.create(
            full_name="علي محمد", phone="+218 92 555 1234", customer_number="C20260101000002"
        )
        Customer.objects.create(
            full_name="فاطمة", phone="0915678234", customer_number="C20260101004455"
        )

    def _search(self, text):
        return _names(self.client.get(reverse("customer-list"), {"search": text}), "full_name")

    def test_a_name_is_found_without_its_hamza(self):
        self.assertEqual(self._search("احمد"), ["أحمد الطاهر"])
        self.assertEqual(self._search("الطاهر احمد"), ["أحمد الطاهر"])

    def test_the_words_of_a_name_are_found_in_any_order(self):
        self.assertEqual(self._search("محمد علي"), ["علي محمد"])
        self.assertEqual(self._search("علي محمد"), ["علي محمد"])
        # Every word still has to be there.
        self.assertEqual(self._search("محمد حسن"), [])

    def test_every_spelling_of_a_phone_finds_its_customer(self):
        for spelling in PHONE_SPELLINGS:
            with self.subTest(spelling=spelling):
                self.assertEqual(self._search(spelling), ["أحمد الطاهر"])

    def test_a_number_saved_in_international_form_is_found_locally(self):
        self.assertEqual(self._search("0925551234"), ["علي محمد"])
        self.assertEqual(self._search("092 555 1234"), ["علي محمد"])

    def test_a_spaced_phone_is_not_matched_piece_by_piece(self):
        # Split on its spaces, «091 234 5678» is in «0915678234» too.
        self.assertEqual(self._search("091 234 5678"), ["أحمد الطاهر"])

    def test_a_few_remembered_digits_are_an_ordinary_contains(self):
        # Too short to be a phone number: found wherever the digits appear,
        # with no «0» or «218» taken off them first.
        self.assertEqual(self._search("5678"), ["أحمد الطاهر", "فاطمة"])
        self.assertEqual(self._search("0915"), ["فاطمة"])

    def test_a_phone_shaped_number_still_finds_other_fields_by_contains(self):
        # Digits enough to be a phone, but they are the customer number.
        self.assertEqual(self._search("20260101004455"), ["فاطمة"])
        self.assertEqual(self._search("004455"), ["فاطمة"])

    def test_the_stock_prefixes_are_untouched(self):
        # CustomerViewSet's own fields carry no prefix; exercise the filter the
        # way a viewset that uses ``=`` would.
        request = Request(APIRequestFactory().get("/", {"search": "فاطمة"}))

        class ExactNames:
            search_fields = ("=full_name",)

        exact = FoldingSearchFilter().filter_queryset(request, Customer.objects.all(), ExactNames)
        self.assertEqual([c.full_name for c in exact], ["فاطمة"])
        folded = Request(APIRequestFactory().get("/", {"search": "فاطمه"}))
        self.assertFalse(
            FoldingSearchFilter().filter_queryset(folded, Customer.objects.all(), ExactNames)
        )


class SupplierSearchTests(TestCase):
    def setUp(self):
        self.client = _manager_client()
        Supplier.objects.create(
            name="مؤسسة الأمل للمكرونة", contact_name="سالم", phone="+218 91 777 8899"
        )
        Supplier.objects.create(name="شركة النور", phone="0923334444")

    def _search(self, text):
        return _names(self.client.get(reverse("supplier-list"), {"search": text}), "name")

    def test_a_supplier_is_found_by_its_folded_name(self):
        self.assertEqual(self._search("مكرونه"), ["مؤسسة الأمل للمكرونة"])
        self.assertEqual(self._search("موسسه الامل"), ["مؤسسة الأمل للمكرونة"])
        self.assertEqual(self._search("شركه"), ["شركة النور"])

    def test_a_supplier_is_found_by_its_phone_in_any_spelling(self):
        self.assertEqual(self._search("0917778899"), ["مؤسسة الأمل للمكرونة"])
        self.assertEqual(self._search("٠٩٢ ٣٣٣ ٤٤٤٤"), ["شركة النور"])


class JobSearchTests(OperationsTestCase):
    def setUp(self):
        super().setUp()
        self.caller = Customer.objects.create(full_name="إبراهيم سالم", phone="0912345678")
        self.caller_job = self.create_repair_job(customer=self.caller.pk, asset_ids=[])
        self.walk_in_job = self.create_repair_job()  # «أحمد علي», imei 356789
        self.client = authenticated_client(self.manager)

    def _search(self, text):
        return _names(self.client.get(reverse("job-list"), {"search": text}), "job_number")

    def test_a_job_is_found_by_its_customers_phone(self):
        for spelling in ("+218 91 234 5678", "0912345678", "٠٩١٢٣٤٥٦٧٨"):
            with self.subTest(spelling=spelling):
                self.assertEqual(self._search(spelling), [self.caller_job["job_number"]])

    def test_a_job_is_found_by_its_customers_folded_name(self):
        self.assertEqual(self._search("ابراهيم"), [self.caller_job["job_number"]])
        self.assertEqual(self._search("احمد"), [self.walk_in_job["job_number"]])

    def test_an_imei_is_still_found_on_the_jobs_board(self):
        self.assertEqual(self._search("356789"), [self.walk_in_job["job_number"]])

    def test_an_imei_typed_in_groups_is_found_too(self):
        self.assertEqual(self._search("356 789"), [self.walk_in_job["job_number"]])
