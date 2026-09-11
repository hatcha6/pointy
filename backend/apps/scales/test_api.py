"""The endpoints, and who is allowed to press the button."""

from decimal import Decimal
from unittest.mock import patch

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group
from django.test import TestCase
from django.urls import reverse
from rest_framework import status
from rest_framework.test import APIClient

from apps.catalog.models import Product, ScalePlu
from apps.catalog.testing import create_product_with_default_variant
from apps.core.roles import CASHIER_GROUP, MANAGER_GROUP, ensure_role_groups

from . import services
from .drivers import PushOutcome
from .models import Scale


class ScaleApiTests(TestCase):
    def setUp(self):
        ensure_role_groups()
        User = get_user_model()
        self.manager = User.objects.create_user(username="m", password="pw1234")
        self.manager.groups.add(Group.objects.get(name=MANAGER_GROUP))
        self.cashier = User.objects.create_user(username="c", password="pw1234")
        self.cashier.groups.add(Group.objects.get(name=CASHIER_GROUP))
        self.client = APIClient()
        self.client.force_authenticate(self.manager)

        product = create_product_with_default_variant(
            name="طماطم", sku="TOM", unit_price="40.00"
        )
        product.unit = Product.Unit.KILOGRAM
        product.save(update_fields=["unit"])
        self.variant = product.default_variant
        self.scale = Scale.objects.create(name="ميزان", driver="file_export")

    def test_drivers_are_listed_for_the_settings_form(self):
        response = self.client.get(reverse("scale-drivers"))
        self.assertEqual(response.status_code, status.HTTP_200_OK)
        keys = {row["key"] for row in response.data}
        self.assertEqual(keys, {"file_export", "cas_cl5000", "aclas_ftp"})
        by_key = {row["key"]: row for row in response.data}
        self.assertFalse(by_key["file_export"]["needs_address"])
        self.assertTrue(by_key["cas_cl5000"]["needs_address"])
        self.assertEqual(by_key["cas_cl5000"]["default_port"], 20304)

    def test_a_networked_scale_without_an_address_is_refused_at_the_form(self):
        response = self.client.post(
            reverse("scale-list"),
            {"name": "CAS", "driver": "cas_cl5000"},
            format="json",
        )
        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertIn("host", response.data)

    def test_a_file_scale_needs_no_address(self):
        response = self.client.post(
            reverse("scale-list"),
            {"name": "أي ميزان", "driver": "file_export"},
            format="json",
        )
        self.assertEqual(response.status_code, status.HTTP_201_CREATED)

    def test_a_plu_number_is_allocated_not_accepted_from_the_caller(self):
        response = self.client.post(
            reverse("scaleplu-list"),
            {"variant": self.variant.pk, "plu_number": 900, "label_name": "TAMATEM"},
            format="json",
        )
        self.assertEqual(response.status_code, status.HTTP_201_CREATED)
        self.assertEqual(response.data["plu_number"], 1)
        self.assertEqual(ScalePlu.objects.get().plu_number, 1)

    def test_pushing_reports_what_actually_happened(self):
        services.allocate_plu(self.variant)
        response = self.client.post(reverse("scale-push", args=[self.scale.pk]))
        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(response.data["status"], "exported")
        self.assertEqual(response.data["plu_count"], 1)

    def test_the_export_downloads_the_file_the_shop_carries_over(self):
        services.allocate_plu(self.variant)
        response = self.client.get(reverse("scale-export", args=[self.scale.pk]))
        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertIn("attachment", response["Content-Disposition"])
        self.assertIn("40.00", response.content.decode("utf-8-sig"))

    def test_exporting_nothing_explains_itself_instead_of_downloading_air(self):
        response = self.client.get(reverse("scale-export", args=[self.scale.pk]))
        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertIn("PLU", response.data["detail"])

    def test_the_export_header_follows_the_encoding_the_scale_wants(self):
        self.scale.options = {"encoding": "cp1256"}
        self.scale.save(update_fields=["options"])
        services.allocate_plu(self.variant)
        response = self.client.get(reverse("scale-export", args=[self.scale.pk]))
        self.assertIn("cp1256", response["Content-Type"])
        self.assertIn("طماطم", response.content.decode("cp1256"))

    def test_a_check_answers_instead_of_erroring_when_a_scale_is_absent(self):
        self.scale.driver = "cas_cl5000"
        self.scale.host = "192.0.2.1"
        self.scale.save(update_fields=["driver", "host"])
        response = self.client.post(reverse("scale-check", args=[self.scale.pk]))
        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertFalse(response.data["reachable"])
        self.assertTrue(response.data["detail"])

    def test_push_history_is_kept_for_the_argument_at_the_counter(self):
        services.allocate_plu(self.variant)
        with patch(
            "apps.scales.drivers.file_export.FileExportDriver.push",
            return_value=PushOutcome(sent=1),
        ):
            self.client.post(reverse("scale-push", args=[self.scale.pk]))
        response = self.client.get(reverse("scale-pushes", args=[self.scale.pk]))
        self.assertEqual(len(response.data), 1)
        self.assertEqual(response.data[0]["status"], "succeeded")

    def test_a_cashier_cannot_push_prices_to_a_scale(self):
        self.client.force_authenticate(self.cashier)
        response = self.client.post(reverse("scale-push", args=[self.scale.pk]))
        self.assertEqual(response.status_code, status.HTTP_403_FORBIDDEN)

    def test_a_cashier_cannot_see_the_scales_list(self):
        self.client.force_authenticate(self.cashier)
        response = self.client.get(reverse("scale-list"))
        self.assertEqual(response.status_code, status.HTTP_403_FORBIDDEN)


class ScaleRuleApiTests(TestCase):
    def setUp(self):
        ensure_role_groups()
        User = get_user_model()
        self.manager = User.objects.create_user(username="m", password="pw1234")
        self.manager.groups.add(Group.objects.get(name=MANAGER_GROUP))
        self.cashier = User.objects.create_user(username="c", password="pw1234")
        self.cashier.groups.add(Group.objects.get(name=CASHIER_GROUP))
        self.client = APIClient()

    def test_the_till_may_read_the_rules(self):
        # A cashier's till has to know how a sticker is laid out before it can
        # read one, so reading is granted to every role that sees the catalog.
        self.client.force_authenticate(self.cashier)
        response = self.client.get(reverse("scalebarcoderule-list"))
        self.assertEqual(response.status_code, status.HTTP_200_OK)

    def test_a_cashier_may_not_change_how_a_sticker_is_read(self):
        self.client.force_authenticate(self.cashier)
        response = self.client.post(
            reverse("scalebarcoderule-list"),
            {"name": "x", "pattern": "22IIIIIVVVVVC"},
            format="json",
        )
        self.assertEqual(response.status_code, status.HTTP_403_FORBIDDEN)

    def test_a_manager_gets_a_worked_example_back(self):
        self.client.force_authenticate(self.manager)
        response = self.client.post(
            reverse("scalebarcoderule-list"),
            {
                "name": "الديلي",
                "pattern": "23IIIIIVVVVVC",
                "value_kind": "price",
                "value_decimals": 2,
            },
            format="json",
        )
        self.assertEqual(response.status_code, status.HTTP_201_CREATED)
        self.assertEqual(response.data["example"]["barcode"], "2312345001504")
        self.assertEqual(response.data["example"]["value_kind"], "price")

    def test_a_clashing_rule_is_refused_with_the_field_error(self):
        self.client.force_authenticate(self.manager)
        payload = {"name": "A", "pattern": "24IIIIIVVVVVC"}
        self.assertEqual(
            self.client.post(
                reverse("scalebarcoderule-list"), payload, format="json"
            ).status_code,
            status.HTTP_201_CREATED,
        )
        response = self.client.post(
            reverse("scalebarcoderule-list"),
            {"name": "B", "pattern": "24IIIIIVVVVVC"},
            format="json",
        )
        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertIn("pattern", response.data)

    def test_an_impossible_pattern_is_refused(self):
        self.client.force_authenticate(self.manager)
        response = self.client.post(
            reverse("scalebarcoderule-list"),
            {"name": "bad", "pattern": "IIIIIVVVVVVVC"},
            format="json",
        )
        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertIn("pattern", response.data)
