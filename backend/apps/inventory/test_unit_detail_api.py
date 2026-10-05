"""The unit page's three edits — facts, photos, warranty — through the API.

Each of these is something a used-goods shop is asked about months later: what
condition the handset was in when it came in, who changed its price, and until
when it is covered. So each is tested where a shop actually uses it — the
endpoint, with a user holding exactly the permissions a role grants — and each
write is checked for the §6.9 history row it must leave behind.
"""

from __future__ import annotations

import io
import tempfile
from datetime import date, timedelta
from decimal import Decimal

from django.core.files.uploadedfile import SimpleUploadedFile
from django.db import connection
from django.test import TestCase, override_settings
from django.test.utils import CaptureQueriesContext
from django.urls import reverse
from django.utils import timezone
from PIL import Image
from rest_framework import status
from rest_framework.test import APIClient

from apps.attachments.models import Attachment
from apps.catalog.models import Product
from apps.core.roles import ensure_role_groups
from apps.crm.transactional import notify_warranties
from apps.customers.models import AssetType, Customer
from apps.messaging.models import MessagingGateway, OutboundMessage
from apps.core.models import ShopSettings
from apps.sales.services import checkout_order
from apps.sales.tracked_lines import order_line_identifiers

from .models import StockUnit, StockUnitEvent
from .test_tracked_api import _user
from .test_used_goods import _session
from .tracked_testing import receive, tracked_product

IMEI = "351234567890116"
IMEI_2 = "356938035643809"


def _png(size=(900, 600), colour=(30, 120, 90)) -> bytes:
    buffer = io.BytesIO()
    Image.new("RGB", size, colour).save(buffer, format="PNG")
    return buffer.getvalue()


def _rows(response):
    payload = response.data
    return payload["results"] if isinstance(payload, dict) else payload


class _UnitCase(TestCase):
    def setUp(self):
        ensure_role_groups()
        self.asset_type = AssetType.objects.get(slug="phone")
        self.product = tracked_product(
            name="iPhone 14",
            sku="UD-IP14",
            mode=Product.TrackingMode.SERIAL,
            unit_price="2000.00",
        )
        self.product.asset_type = self.asset_type
        self.product.warranty_days = 365
        self.product.save(update_fields=["asset_type", "warranty_days"])
        self.variant = self.product.default_variant
        receive(
            variant=self.variant,
            quantity=1,
            unit_cost="1500.00",
            units=[{"code": IMEI, "identifier_kind": "imei"}],
        )
        self.unit = StockUnit.objects.get(code_normalized=IMEI)

    def client_for(self, *permissions):
        client = APIClient()
        client.force_authenticate(user=_user("unitdetail", permissions=permissions))
        return client

    def url(self, name, **kwargs):
        return reverse(name, kwargs={"pk": self.unit.pk, **kwargs})


class UnitAttributeEditTests(_UnitCase):
    def test_the_facts_are_coerced_shown_with_labels_and_audited(self):
        client = self.client_for(
            "inventory.view_stockunit", "inventory.change_stockunit"
        )
        response = client.post(
            self.url("stock-unit-edit-attributes"),
            {"attributes": {"battery_health": "92", "condition_grade": "a_plus"}},
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK, response.data)
        self.unit.refresh_from_db()
        # A number, so «battery above 85%» compares numerically.
        self.assertEqual(self.unit.attributes["battery_health"], 92.0)
        display = {row["key"]: row["display"] for row in response.data["attribute_display"]}
        self.assertEqual(display["battery_health"], "92%")
        # The choice's label, never its code.
        self.assertEqual(display["condition_grade"], "ممتاز +")

        event = self.unit.events.get(kind=StockUnitEvent.Kind.ATTRIBUTES_EDITED)
        self.assertIn("صحة البطارية", event.note)
        self.assertIn("92%", event.to_value)
        self.assertIsNotNone(event.actor_id)

    def test_a_bad_value_is_refused_per_field_in_arabic(self):
        client = self.client_for(
            "inventory.view_stockunit", "inventory.change_stockunit"
        )
        response = client.post(
            self.url("stock-unit-edit-attributes"),
            {"attributes": {"battery_health": "140"}},
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertIn("battery_health", response.data["attributes"])
        self.assertIn("نسبة", str(response.data["attributes"]["battery_health"]))
        self.assertFalse(self.unit.events.exists())

    def test_a_required_field_left_empty_is_refused(self):
        definition = self.asset_type.unit_attributes.get(key="condition_grade")
        definition.is_required = True
        definition.save(update_fields=["is_required"])
        client = self.client_for(
            "inventory.view_stockunit", "inventory.change_stockunit"
        )

        response = client.post(
            self.url("stock-unit-edit-attributes"),
            {"attributes": {"battery_health": 90}},
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertIn("مطلوب", str(response.data["attributes"]["condition_grade"]))

    def test_a_cashier_cannot_rewrite_the_condition_record(self):
        client = self.client_for("inventory.view_stockunit")
        response = client.post(
            self.url("stock-unit-edit-attributes"),
            {"attributes": {"battery_health": 99}},
            format="json",
        )
        self.assertEqual(response.status_code, status.HTTP_403_FORBIDDEN)

    def test_intake_coerces_the_checklist_and_keeps_the_warranty_date(self):
        expires = date.today() + timedelta(days=700)
        receive(
            variant=self.variant,
            quantity=1,
            unit_cost="1400.00",
            units=[
                {
                    "code": IMEI_2,
                    "identifier_kind": "imei",
                    "attributes": {"battery_health": "85", "carrier_lock": "unlocked"},
                    "warranty_override_expires_on": expires,
                }
            ],
        )
        unit = StockUnit.objects.get(code_normalized=IMEI_2)
        self.assertEqual(unit.attributes, {"battery_health": 85.0, "carrier_lock": "unlocked"})
        self.assertEqual(unit.warranty_override_expires_on, expires)


class UnitRepriceAuditTests(_UnitCase):
    def test_a_reprice_names_who_and_from_what(self):
        client = self.client_for(
            "inventory.view_stockunit", "inventory.reprice_stockunit"
        )
        client.patch(self.url("stock-unit-detail"), {"list_price": "1600.00"}, format="json")
        response = client.patch(
            self.url("stock-unit-detail"), {"list_price": "1450.00"}, format="json"
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK, response.data)
        latest = self.unit.events.filter(kind=StockUnitEvent.Kind.REPRICED).order_by("-id").first()
        self.assertEqual((latest.from_value, latest.to_value), ("1600.00", "1450.00"))
        timeline = client.get(self.url("stock-unit-timeline")).data
        self.assertEqual(
            [row["to_value"] for row in timeline if row["kind"] == "repriced"],
            ["1600.00", "1450.00"],
        )

    def test_repricing_follows_its_own_grant(self):
        describer = self.client_for(
            "inventory.view_stockunit", "inventory.change_stockunit"
        )
        response = describer.patch(
            self.url("stock-unit-detail"), {"list_price": "10.00"}, format="json"
        )
        self.assertEqual(response.status_code, status.HTTP_403_FORBIDDEN)
        # ...while the notes stay theirs to write, and are on the record too.
        response = describer.patch(
            self.url("stock-unit-detail"), {"notes": "خدش في الزاوية"}, format="json"
        )
        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertTrue(self.unit.events.filter(kind=StockUnitEvent.Kind.NOTE).exists())

    def test_a_shelf_markdown_leaves_a_row_per_article(self):
        client = self.client_for(
            "inventory.view_stockunit", "inventory.reprice_stockunit"
        )
        response = client.post(
            reverse("stock-unit-bulk-reprice"),
            {"ids": [self.unit.pk], "percent": "-10"},
            format="json",
        )

        self.assertEqual(response.data["updated"], 1)
        event = self.unit.events.get(kind=StockUnitEvent.Kind.REPRICED)
        self.assertEqual((event.from_value, event.to_value), ("", "1800.00"))


class UnitWarrantyOverrideTests(_UnitCase):
    def setUp(self):
        super().setUp()
        settings = ShopSettings.load()
        settings.shop_name = "محل النور"
        settings.save()
        MessagingGateway.objects.create(
            name="phone",
            provider=MessagingGateway.Provider.FAKE,
            is_default=True,
            auto_messages={"warranty_registered": True},
        )
        self.customer = Customer.objects.create(full_name="زبون", phone="0912345678")
        self.override = timezone.localdate() + timedelta(days=1000)

    def sell(self):
        return checkout_order(
            register_session=_session(),
            lines_data=[
                {
                    "variant": self.variant,
                    "quantity": Decimal("1"),
                    "effective_unit_price": Decimal("2000.00"),
                    "stock_units": [self.unit.pk],
                }
            ],
            payments_data=[{"method": "cash", "amount": Decimal("2000.00")}],
            customer=self.customer,
        )

    def set_override(self, value, *permissions):
        client = self.client_for(
            "inventory.view_stockunit",
            *(permissions or ("inventory.change_stockunit_warranty",)),
        )
        return client.post(
            self.url("stock-unit-set-warranty"),
            {"warranty_override_expires_on": value.isoformat() if value else None},
            format="json",
        )

    def test_the_override_wins_on_the_receipt_the_text_and_the_asset(self):
        response = self.set_override(self.override)
        self.assertEqual(response.status_code, status.HTTP_200_OK, response.data)

        order = self.sell()
        self.unit.refresh_from_db()
        self.assertEqual(self.unit.warranty_expires_on, self.override)

        # The receipt names the date beside the IMEI.
        line = order.lines.get()
        [row] = order_line_identifiers(line)
        self.assertEqual(row["warranty_expires_on"], self.override.isoformat())

        # The warranty SMS quotes it.
        with self.captureOnCommitCallbacks(execute=True):
            notify_warranties(order)
        [text] = OutboundMessage.objects.filter(template_kind="warranty_registered")
        self.assertIn(f"{self.override:%Y/%m/%d}", text.body)

        # And the buyer's asset answers the counter with it.
        admin = self.client_for("customers.view_asset")
        asset = admin.get(reverse("asset-detail", kwargs={"pk": self.unit.asset_id}))
        self.assertEqual(asset.status_code, status.HTTP_200_OK)
        self.assertEqual(asset.data["warranty_expires_on"], self.override.isoformat())

    def test_changing_it_after_the_sale_moves_the_stamped_date(self):
        self.sell()
        self.unit.refresh_from_db()
        sold_on = timezone.localtime(self.unit.sold_at).date()
        self.assertEqual(self.unit.warranty_expires_on, sold_on + timedelta(days=365))

        self.set_override(self.override)
        self.unit.refresh_from_db()
        self.assertEqual(self.unit.warranty_expires_on, self.override)

        # Clearing it returns the article to the product's days from the sale.
        self.set_override(None)
        self.unit.refresh_from_db()
        self.assertIsNone(self.unit.warranty_override_expires_on)
        self.assertEqual(self.unit.warranty_expires_on, sold_on + timedelta(days=365))

        events = list(
            self.unit.events.filter(kind=StockUnitEvent.Kind.WARRANTY_CHANGED)
            .order_by("id")
            .values_list("from_value", "to_value")
        )
        self.assertEqual(
            events,
            [("", self.override.isoformat()), (self.override.isoformat(), "")],
        )

    def test_a_warranty_is_a_managers_promise(self):
        response = self.set_override(self.override, "inventory.change_stockunit")
        self.assertEqual(response.status_code, status.HTTP_403_FORBIDDEN)

    def test_a_product_without_days_and_a_unit_without_a_date_sell_uncovered(self):
        self.product.warranty_days = 0
        self.product.save(update_fields=["warranty_days"])
        self.sell()
        self.unit.refresh_from_db()
        self.assertIsNone(self.unit.warranty_expires_on)


class _StorageMixin:
    def setUp(self):
        super().setUp()
        storage = tempfile.TemporaryDirectory()
        self.addCleanup(storage.cleanup)
        override = override_settings(
            POINTY_ATTACHMENT_STORAGE_ROOT=storage.name,
            POINTY_ATTACHMENT_ALLOWED_CONTENT_TYPES=[],
            POINTY_ATTACHMENT_MAX_UPLOAD_BYTES=5 * 1024 * 1024,
        )
        override.enable()
        self.addCleanup(override.disable)

    def upload(self, client, *, name="front.png", data=None, is_cover=None):
        payload = {"file": SimpleUploadedFile(name, data or _png(), content_type="image/png")}
        if is_cover is not None:
            payload["is_cover"] = "true" if is_cover else "false"
        return client.post(self.url("stock-unit-photos"), payload, format="multipart")


class UnitPhotoTests(_StorageMixin, _UnitCase):
    def photographer(self):
        return self.client_for(
            "inventory.view_stockunit", "inventory.manage_stockunit_photos"
        )

    def test_the_first_photo_is_the_cover_and_the_unit_shows_it(self):
        client = self.photographer()
        first = self.upload(client, name="front.png")
        second = self.upload(client, name="back.png")

        self.assertEqual(first.status_code, status.HTTP_201_CREATED, first.data)
        self.assertTrue(first.data["is_cover"])
        self.assertFalse(second.data["is_cover"])
        self.assertIn("/thumbnail/?token=", first.data["thumbnail_url"])

        listed = client.get(self.url("stock-unit-photos")).data
        self.assertEqual([row["id"] for row in listed], [first.data["id"], second.data["id"]])
        unit = client.get(self.url("stock-unit-detail")).data
        self.assertEqual(unit["cover_photo"]["id"], first.data["id"])
        self.assertEqual(
            self.unit.events.filter(kind=StockUnitEvent.Kind.PHOTO_ADDED).count(), 2
        )

    def test_a_new_cover_and_removing_the_cover_promotes_another(self):
        client = self.photographer()
        first = self.upload(client).data
        second = self.upload(client).data

        response = client.post(
            self.url("stock-unit-photo-cover", photo_id=second["id"])
        )
        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertTrue(Attachment.objects.get(pk=second["id"]).is_primary)
        self.assertFalse(Attachment.objects.get(pk=first["id"]).is_primary)

        response = client.delete(self.url("stock-unit-photo", photo_id=second["id"]))
        self.assertEqual(response.status_code, status.HTTP_204_NO_CONTENT)
        # Soft: the record of what the article looked like is never unlinked.
        self.assertEqual(
            Attachment.objects.get(pk=second["id"]).status, Attachment.Status.DELETED
        )
        self.assertTrue(Attachment.objects.get(pk=first["id"]).is_primary)
        self.assertTrue(
            self.unit.events.filter(kind=StockUnitEvent.Kind.PHOTO_REMOVED).exists()
        )

    def test_a_large_photo_is_scaled_down_and_its_thumbnail_is_small(self):
        client = self.photographer()
        created = self.upload(client, data=_png(size=(4000, 3000))).data

        attachment = Attachment.objects.get(pk=created["id"])
        self.assertEqual(attachment.role, Attachment.Role.UNIT_PHOTO)
        self.assertEqual(attachment.content_type, "image/jpeg")
        # The thumbnail is served by token alone, as the till's image loader
        # asks for it — no session.
        response = APIClient().get(created["thumbnail_url"])
        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(response["Content-Type"], "image/jpeg")
        with Image.open(io.BytesIO(response.content)) as image:
            self.assertLessEqual(max(image.size), 320)
        # A second request is answered from the conditional cache.
        again = APIClient().get(created["thumbnail_url"], HTTP_IF_NONE_MATCH=response["ETag"])
        self.assertEqual(again.status_code, status.HTTP_304_NOT_MODIFIED)

    def test_something_that_is_not_a_picture_is_refused(self):
        response = self.upload(self.photographer(), name="notes.png", data=b"not an image")
        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertFalse(Attachment.objects.filter(role=Attachment.Role.UNIT_PHOTO).exists())

    def test_reading_photos_needs_the_unit_and_adding_needs_the_grant(self):
        reader = self.client_for("inventory.view_stockunit")
        self.assertEqual(reader.get(self.url("stock-unit-photos")).status_code, 200)
        self.assertEqual(self.upload(reader).status_code, status.HTTP_403_FORBIDDEN)


class UnitListQueryScalingTests(_StorageMixin, _UnitCase):
    """The units list and the till's picker draw a cover and the facts beside
    every row: both must cost the same few queries for six rows as for two."""

    def _add_units(self, count, *, start):
        rows = [{"code": f"SN-UD-{start + index:04d}"} for index in range(count)]
        receive(variant=self.variant, quantity=count, unit_cost="900.00", units=rows)
        client = self.client_for(
            "inventory.view_stockunit", "inventory.manage_stockunit_photos"
        )
        for unit in StockUnit.objects.filter(code__in=[row["code"] for row in rows]):
            unit.attributes = {"battery_health": 88.0, "condition_grade": "a"}
            unit.save(update_fields=["attributes"])
            self.unit = unit
            self.upload(client)

    def _queries_for_list(self):
        client = self.client_for("inventory.view_stockunit")
        with CaptureQueriesContext(connection) as captured:
            response = client.get(reverse("stock-unit-list"), {"in_stock": "true"})
        self.assertEqual(response.status_code, status.HTTP_200_OK)
        rows = _rows(response)
        self.assertTrue(all(row["cover_photo"] for row in rows if row["code"].startswith("SN-UD")))
        self.assertTrue(
            all(row["attribute_display"] for row in rows if row["code"].startswith("SN-UD"))
        )
        return len(captured.captured_queries), len(rows)

    def test_covers_and_facts_cost_no_query_per_row(self):
        self._add_units(2, start=0)
        small, small_rows = self._queries_for_list()
        self._add_units(4, start=10)
        large, large_rows = self._queries_for_list()

        self.assertGreater(large_rows, small_rows)
        self.assertEqual(small, large)
