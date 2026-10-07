"""The condition checklist editor — «قوائم فحص الأجهزة» — through its API.

The definitions used to be editable only in Django admin. Exposing them to the
app means the API has to defend what admin never had to: the key a value is
stored under, the type every recorded value was checked against, and the
choice codes units already carry. Each test below is one of those promises.
"""

from __future__ import annotations

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group
from django.test import TestCase
from django.urls import reverse
from rest_framework import status
from rest_framework.test import APIClient

from apps.catalog.models import Product
from apps.core.roles import MANAGER_GROUP, ensure_role_groups
from apps.customers.models import AssetType

from .consignment_serializers import MAX_CHOICES, MAX_DEFINITIONS_PER_TYPE
from .models import StockUnit, UnitAttributeDefinition
from .test_tracked_api import _user
from .tracked_testing import receive, tracked_product

LIST = "unit-attribute-definition-list"
DETAIL = "unit-attribute-definition-detail"
REORDER = "unit-attribute-definition-reorder"
SUMMARY = "unit-attribute-definition-summary"


def _rows(response):
    payload = response.data
    return payload["results"] if isinstance(payload, dict) else payload


class _ChecklistCase(TestCase):
    def setUp(self):
        ensure_role_groups()
        self.phone = AssetType.objects.get(slug="phone")
        self.laptop = AssetType.objects.get(slug="laptop")
        manager = get_user_model().objects.create_user(
            username="checklist-owner", password="pw"
        )
        manager.groups.add(Group.objects.get(name=MANAGER_GROUP))
        self.owner = APIClient()
        self.owner.force_authenticate(user=manager)

    def create(self, client=None, **payload):
        payload.setdefault("asset_type", self.phone.pk)
        return (client or self.owner).post(reverse(LIST), payload, format="json")

    def patch(self, definition_id, **payload):
        return self.owner.patch(
            reverse(DETAIL, kwargs={"pk": definition_id}), payload, format="json"
        )

    def phone_unit(self, attributes):
        product = tracked_product(
            name="iPhone 12", sku="CHK-IP12", mode=Product.TrackingMode.SERIAL
        )
        product.asset_type = self.phone
        product.save(update_fields=["asset_type"])
        receive(
            variant=product.default_variant,
            quantity=1,
            units=[{"code": "351234567890116", "identifier_kind": "imei"}],
        )
        unit = StockUnit.objects.get(code_normalized="351234567890116")
        unit.attributes = attributes
        unit.save(update_fields=["attributes"])
        return unit


class CreateTests(_ChecklistCase):
    def test_an_english_label_becomes_the_key_and_lands_last(self):
        last = (
            UnitAttributeDefinition.objects.filter(asset_type=self.phone)
            .order_by("-display_order")
            .first()
        )

        response = self.create(label="  Face ID يعمل ", data_type="bool")

        self.assertEqual(response.status_code, status.HTTP_201_CREATED, response.data)
        self.assertEqual(response.data["key"], "face_id")
        self.assertEqual(response.data["label"], "Face ID يعمل")
        self.assertEqual(response.data["display_order"], last.display_order + 1)

    def test_an_arabic_label_gets_an_ascii_key_and_choice_values(self):
        response = self.create(
            label="لون الهيكل",
            data_type="choice",
            choices=[{"label": "أسود"}, {"label": "ذهبي", "value": ""}],
        )

        self.assertEqual(response.status_code, status.HTTP_201_CREATED, response.data)
        self.assertRegex(response.data["key"], r"^field_\d+$")
        self.assertEqual(
            response.data["choices"],
            [{"value": "opt_1", "label": "أسود"}, {"value": "opt_2", "label": "ذهبي"}],
        )

    def test_a_key_already_on_the_type_is_a_clean_400(self):
        response = self.create(key="battery_health", label="صحة البطارية 2")

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertIn("المفتاح", response.data["key"][0])

    def test_the_same_key_on_another_type_is_fine(self):
        response = self.create(
            asset_type=self.laptop.pk, key="battery_health", label="البطارية"
        )

        self.assertEqual(response.status_code, status.HTTP_201_CREATED, response.data)

    def test_a_key_that_is_not_an_identifier_is_refused(self):
        response = self.create(key="Battery Health", label="x")

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertIn("key", response.data)

    def test_a_blank_or_long_label_is_refused_in_arabic(self):
        blank = self.create(label="   ")
        long = self.create(label="ب" * 81)

        self.assertEqual(blank.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertEqual(blank.data["label"][0], "اسم الحقل مطلوب.")
        self.assertEqual(long.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertIn("80", long.data["label"][0])

    def test_an_unknown_type_is_refused_in_arabic(self):
        response = self.create(label="x", data_type="colour")

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertEqual(response.data["data_type"][0], "نوع الحقل غير معروف.")

    def test_a_suffix_is_kept_for_numbers_only(self):
        number = self.create(label="Storage", data_type="number", suffix=" GB ")
        text = self.create(label="Notes", data_type="text", suffix="GB")
        long = self.create(label="Weight", data_type="number", suffix="x" * 17)

        self.assertEqual(number.data["suffix"], "GB")
        self.assertEqual(text.data["suffix"], "")
        self.assertEqual(long.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertIn("suffix", long.data)

    def test_a_kind_has_a_ceiling(self):
        existing = UnitAttributeDefinition.objects.filter(asset_type=self.laptop)
        start = existing.count()
        UnitAttributeDefinition.objects.bulk_create(
            UnitAttributeDefinition(
                asset_type=self.laptop, key=f"extra_{n}", label=f"extra {n}"
            )
            for n in range(MAX_DEFINITIONS_PER_TYPE - start)
        )

        response = self.create(asset_type=self.laptop.pk, label="one too many")

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertIn("non_field_errors", response.data)

    def test_a_generated_key_never_reuses_one_a_unit_still_carries(self):
        """Delete «Face ID», add it again: the old answers must not reappear
        under the new field — a deleted definition's values stay on the unit."""
        first = self.create(label="Face ID", data_type="bool").data
        unit = self.phone_unit({"face_id": True})

        deleted = self.owner.delete(reverse(DETAIL, kwargs={"pk": first["id"]}))
        again = self.create(label="Face ID", data_type="text")

        self.assertEqual(deleted.status_code, status.HTTP_204_NO_CONTENT)
        unit.refresh_from_db()
        self.assertEqual(unit.attributes, {"face_id": True})
        self.assertEqual(again.status_code, status.HTTP_201_CREATED, again.data)
        self.assertEqual(again.data["key"], "face_id_2")


class ChoiceTests(_ChecklistCase):
    def assertRefused(self, response, fragment):
        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertIn(fragment, response.data["choices"][0])

    def test_a_choice_field_needs_choices(self):
        self.assertRefused(self.create(label="x", data_type="choice"), "خيارًا")
        self.assertRefused(
            self.create(label="x", data_type="choice", choices=[]), "خيارًا"
        )

    def test_each_choice_is_checked(self):
        cases = [
            ([{"label": ""}], "الاسم مطلوب"),
            ([{"label": "أ" * 61}], "60"),
            ([{"label": "أ"}, {"label": "أ"}], "مكرر"),
            ([{"label": "أ", "colour": "red"}], "مفاتيح غير معروفة"),
            ([{"label": 3}], "نص"),
            (["أسود"], "صيغة"),
            ([{"label": "أ", "value": "Not ok"}], "القيمة"),
            ([{"label": "أ", "value": "x"}, {"label": "ب", "value": "x"}], "مكررة"),
            ([{"label": f"c{n}"} for n in range(MAX_CHOICES + 1)], str(MAX_CHOICES)),
            ({"label": "أ"}, "قائمة"),
        ]
        for choices, fragment in cases:
            with self.subTest(choices=str(choices)[:40]):
                self.assertRefused(
                    self.create(label="x", data_type="choice", choices=choices),
                    fragment,
                )

    def test_another_type_drops_whatever_choices_it_was_sent(self):
        response = self.create(
            label="Notes", data_type="text", choices=[{"label": "أ"}]
        )

        self.assertEqual(response.status_code, status.HTTP_201_CREATED, response.data)
        self.assertEqual(response.data["choices"], [])

    def test_editing_keeps_existing_values_and_never_reuses_a_recorded_one(self):
        grade = UnitAttributeDefinition.objects.get(
            asset_type=self.phone, key="condition_grade"
        )
        # A unit recorded a code that is no longer on the list at all.
        self.phone_unit({"condition_grade": "opt_1"})

        response = self.patch(
            grade.pk,
            choices=[
                {"value": "a_plus", "label": "ممتاز جدًا"},
                {"value": "a", "label": "ممتاز"},
                {"label": "كسر في الشاشة"},
            ],
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK, response.data)
        self.assertEqual(
            response.data["choices"],
            [
                {"value": "a_plus", "label": "ممتاز جدًا"},
                {"value": "a", "label": "ممتاز"},
                # Not opt_1 (a unit carries it), not b/c/parts (removed now).
                {"value": "opt_2", "label": "كسر في الشاشة"},
            ],
        )


class ImmutabilityTests(_ChecklistCase):
    def setUp(self):
        super().setUp()
        self.battery = UnitAttributeDefinition.objects.get(
            asset_type=self.phone, key="battery_health"
        )

    def test_the_label_and_switches_change(self):
        response = self.patch(
            self.battery.pk, label="صحة البطارية %", is_required=True
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK, response.data)
        self.battery.refresh_from_db()
        self.assertEqual(self.battery.label, "صحة البطارية %")
        self.assertTrue(self.battery.is_required)
        self.assertEqual(self.battery.key, "battery_health")

    def test_sending_the_same_key_and_type_back_is_fine(self):
        response = self.patch(
            self.battery.pk,
            key="battery_health",
            data_type="percent",
            asset_type=self.phone.pk,
            label="البطارية",
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK, response.data)

    def test_the_key_type_and_kind_are_fixed(self):
        for field, value in (
            ("key", "battery"),
            ("data_type", "number"),
            ("asset_type", self.laptop.pk),
        ):
            with self.subTest(field=field):
                response = self.patch(self.battery.pk, **{field: value})
                self.assertEqual(
                    response.status_code, status.HTTP_400_BAD_REQUEST, response.data
                )
                self.assertIn(field, response.data)

        self.battery.refresh_from_db()
        self.assertEqual(
            (self.battery.key, self.battery.data_type, self.battery.asset_type_id),
            ("battery_health", "percent", self.phone.pk),
        )


class ReorderTests(_ChecklistCase):
    def phone_ids(self):
        return list(
            UnitAttributeDefinition.objects.filter(asset_type=self.phone)
            .order_by("display_order", "id")
            .values_list("pk", flat=True)
        )

    def test_the_new_order_is_written_in_one_go(self):
        ids = self.phone_ids()
        wanted = list(reversed(ids))

        response = self.owner.post(
            reverse(REORDER),
            {"asset_type": self.phone.pk, "ids": wanted},
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK, response.data)
        self.assertEqual([row["id"] for row in response.data], wanted)
        self.assertEqual(self.phone_ids(), wanted)
        self.assertEqual(
            [row["display_order"] for row in response.data],
            list(range(len(wanted))),
        )

    def test_an_unlisted_definition_keeps_its_place_after_the_listed(self):
        ids = self.phone_ids()

        response = self.owner.post(
            reverse(REORDER),
            {"asset_type": self.phone.pk, "ids": [ids[-1], ids[0]]},
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK, response.data)
        self.assertEqual(self.phone_ids(), [ids[-1], ids[0], *ids[1:-1]])

    def test_an_id_from_another_kind_is_refused(self):
        before = self.phone_ids()
        laptop_id = UnitAttributeDefinition.objects.filter(
            asset_type=self.laptop
        ).values_list("pk", flat=True)[0]

        response = self.owner.post(
            reverse(REORDER),
            {"asset_type": self.phone.pk, "ids": [laptop_id, *before]},
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertIn("ids", response.data)
        self.assertEqual(self.phone_ids(), before)

    def test_duplicates_and_unknown_ids_are_refused(self):
        ids = self.phone_ids()
        for bad in ([ids[0], ids[0]], [999_999]):
            with self.subTest(ids=bad):
                response = self.owner.post(
                    reverse(REORDER),
                    {"asset_type": self.phone.pk, "ids": bad},
                    format="json",
                )
                self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
                self.assertIn("ids", response.data)


class PermissionTests(_ChecklistCase):
    def test_a_reader_lists_but_cannot_write(self):
        reader = APIClient()
        reader.force_authenticate(
            user=_user("checklist-reader", permissions=("inventory.view_stockunit",))
        )
        battery = UnitAttributeDefinition.objects.get(
            asset_type=self.phone, key="battery_health"
        )

        listed = reader.get(reverse(LIST), {"asset_type": self.phone.pk})
        summary = reader.get(reverse(SUMMARY))
        writes = [
            self.create(reader, label="x"),
            reader.patch(
                reverse(DETAIL, kwargs={"pk": battery.pk}),
                {"label": "x"},
                format="json",
            ),
            reader.delete(reverse(DETAIL, kwargs={"pk": battery.pk})),
            reader.post(
                reverse(REORDER),
                {"asset_type": self.phone.pk, "ids": [battery.pk]},
                format="json",
            ),
        ]

        self.assertEqual(listed.status_code, status.HTTP_200_OK)
        self.assertEqual(summary.status_code, status.HTTP_200_OK)
        for response in writes:
            self.assertEqual(response.status_code, status.HTTP_403_FORBIDDEN)
        self.assertTrue(UnitAttributeDefinition.objects.filter(pk=battery.pk).exists())

    def test_nobody_without_view_stockunit_reads_the_checklists(self):
        stranger = APIClient()
        stranger.force_authenticate(user=_user("checklist-stranger"))

        self.assertEqual(
            stranger.get(reverse(LIST)).status_code, status.HTTP_403_FORBIDDEN
        )
        self.assertEqual(
            stranger.get(reverse(SUMMARY)).status_code, status.HTTP_403_FORBIDDEN
        )

    def test_the_holder_of_the_permission_alone_can_write(self):
        editor = APIClient()
        editor.force_authenticate(
            user=_user(
                "checklist-editor",
                permissions=(
                    "inventory.view_stockunit",
                    "inventory.manage_unitattributedefinition",
                ),
            )
        )

        response = self.create(editor, label="Face ID", data_type="bool")

        self.assertEqual(response.status_code, status.HTTP_201_CREATED, response.data)


class ReadTests(_ChecklistCase):
    def test_the_seeded_phone_checklist_reads_back_untouched(self):
        response = self.owner.get(reverse(LIST), {"asset_type": self.phone.pk})

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        rows = _rows(response)
        self.assertEqual(
            [row["key"] for row in rows],
            ["battery_health", "condition_grade", "carrier_lock", "box_and_accessories"],
        )
        grade = rows[1]
        self.assertEqual(grade["data_type"], "choice")
        self.assertEqual(grade["choices"][0], {"value": "a_plus", "label": "ممتاز +"})
        self.assertTrue(grade["show_on_label"])
        self.assertEqual(rows[0]["suffix"], "%")

    def test_the_summary_counts_each_active_kind(self):
        self.patch(
            UnitAttributeDefinition.objects.get(
                asset_type=self.phone, key="battery_health"
            ).pk,
            is_required=True,
        )
        inactive = AssetType.objects.create(
            name="مولد", slug="generator-test", is_active=False
        )

        response = self.owner.get(reverse(SUMMARY))

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        by_id = {row["asset_type"]: row for row in response.data}
        self.assertEqual(by_id[self.phone.pk]["field_count"], 4)
        self.assertEqual(by_id[self.phone.pk]["required_count"], 1)
        self.assertEqual(by_id[self.phone.pk]["name"], self.phone.name)
        self.assertNotIn(inactive.pk, by_id)
