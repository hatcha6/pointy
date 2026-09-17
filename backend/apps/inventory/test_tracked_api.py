"""The API for identified stock, and the one thing about it that is unusual.

``inventory.view_stockunit_cost`` is the first field-level cost mask in this
codebase. It is here because a used-goods shop does not show its counter staff
what it paid the walk-in seller, and it is tested here because a mask that
silently stops working is a mask nobody notices has stopped working.
"""

from decimal import Decimal

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group, Permission
from django.test import TestCase
from django.urls import reverse
from rest_framework import status
from rest_framework.test import APIClient

from apps.catalog.models import Product
from apps.core.roles import MANAGER_GROUP, ensure_role_groups

from .models import StockBatch, StockUnit
from .tracked_testing import receive, tracked_product

IMEI = "351234567890116"


def _rows(response):
    """List payloads are paginated for a manager and not for everyone else."""
    payload = response.data
    return payload["results"] if isinstance(payload, dict) else payload


_USER_SEQUENCE = 0


def _user(username, *, permissions=()):
    """A user with exactly these permissions, and a name nobody else has taken."""
    global _USER_SEQUENCE
    _USER_SEQUENCE += 1
    user = get_user_model().objects.create_user(
        username=f"{username}-{_USER_SEQUENCE}", password="pw"
    )
    for codename in permissions:
        app_label, code = codename.split(".")
        user.user_permissions.add(
            Permission.objects.get(
                content_type__app_label=app_label, codename=code
            )
        )
    return user


class StockUnitApiTests(TestCase):
    def setUp(self):
        ensure_role_groups()
        self.product = tracked_product(
            name="iPhone 13 Pro",
            sku="API-IP13",
            mode=Product.TrackingMode.SERIAL,
            unit_price="1500.00",
        )
        self.variant = self.product.default_variant
        receive(
            variant=self.variant,
            quantity=1,
            unit_cost="1200.00",
            units=[{"code": IMEI}],
        )
        self.unit = StockUnit.objects.get()

    def _client(self, user):
        client = APIClient()
        client.force_authenticate(user=user)
        return client

    def test_a_cashier_sees_the_unit_but_not_what_it_cost(self):
        cashier = _user("cashier", permissions=["inventory.view_stockunit"])
        response = self._client(cashier).get(reverse("stock-unit-list"))

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        row = _rows(response)[0]
        self.assertEqual(row["code"], IMEI)
        self.assertNotIn("incoming_rate", row)
        self.assertNotIn("refurb_cost", row)
        self.assertNotIn("total_cost", row)

    def test_a_manager_sees_the_cost(self):
        manager = _user("manager")
        manager.groups.add(Group.objects.get(name=MANAGER_GROUP))
        response = self._client(manager).get(reverse("stock-unit-list"))

        row = _rows(response)[0]
        self.assertEqual(Decimal(str(row["incoming_rate"])), Decimal("1200.000000"))
        self.assertEqual(Decimal(str(row["total_cost"])), Decimal("1200.000000"))

    def test_lookup_answers_with_the_live_unit(self):
        clerk = _user("clerk", permissions=["inventory.view_stockunit"])
        response = self._client(clerk).post(
            reverse("stock-unit-lookup"), {"code": " 351234-567890116 "}, format="json"
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(response.data["unit"]["id"], self.unit.pk)
        self.assertEqual(response.data["history"], [])

    def test_history_is_the_articles_whole_life(self):
        clerk = _user("clerk2", permissions=["inventory.view_stockunit"])
        response = self._client(clerk).get(
            reverse("stock-unit-history", args=[self.unit.pk])
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(len(response.data), 1)
        self.assertEqual(response.data[0]["direction"], "in")
        self.assertEqual(response.data[0]["unit_code"], IMEI)

    def test_viewing_units_needs_the_permission(self):
        nobody = _user("nobody")
        response = self._client(nobody).get(reverse("stock-unit-list"))
        self.assertEqual(response.status_code, status.HTTP_403_FORBIDDEN)


class CaptureLaterApiTests(TestCase):
    def setUp(self):
        from apps.core.models import ShopSettings

        ensure_role_groups()
        settings = ShopSettings.load()
        settings.serialized_capture_later_allowed = True
        settings.save(
            update_fields=["serialized_capture_later_allowed", "updated_at"]
        )
        self.product = tracked_product(
            name="iPhone 13 Pro",
            sku="API-LATE",
            mode=Product.TrackingMode.SERIAL,
            unit_price="1500.00",
        )
        self.variant = self.product.default_variant
        receive(variant=self.variant, quantity=2, unit_cost="1200.00", units=[])
        self.pending = StockUnit.objects.filter(is_identified=False)

    def _client(self):
        user = _user(
            "receiver",
            permissions=["inventory.view_stockunit", "inventory.add_stockunit"],
        )
        client = APIClient()
        client.force_authenticate(user=user)
        return client

    def test_the_worklist_counts_what_is_still_owed(self):
        response = self._client().get(reverse("stock-unit-summary"))
        self.assertEqual(response.data["missing_identifiers"], 2)

    def test_identifying_a_placeholder_gives_it_its_number(self):
        unit = self.pending.first()
        response = self._client().post(
            reverse("stock-unit-identify", args=[unit.pk]),
            {"code": IMEI, "identifier_kind": "imei"},
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        unit.refresh_from_db()
        self.assertTrue(unit.is_identified)
        self.assertEqual(unit.code_normalized, IMEI)
        self.assertEqual(response.data["identifier_warnings"], [])

    def test_a_bad_check_digit_is_reported_and_still_saved(self):
        """The guard warns; it does not wall. A receiver holding a handset whose
        label disagrees with GSMA still has that handset."""
        unit = self.pending.first()
        response = self._client().post(
            reverse("stock-unit-identify", args=[unit.pk]),
            {"code": "351234567890117", "identifier_kind": "imei"},
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(
            [warning["code"] for warning in response.data["identifier_warnings"]],
            ["imei_checksum"],
        )

    def test_an_identifier_already_live_elsewhere_is_a_structured_conflict(self):
        first, second = list(self.pending)
        client = self._client()
        client.post(
            reverse("stock-unit-identify", args=[first.pk]),
            {"code": IMEI},
            format="json",
        )
        response = client.post(
            reverse("stock-unit-identify", args=[second.pk]),
            {"code": IMEI},
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertEqual(int(response.data["conflicts"][0]["object_id"]), first.pk)


class StockBatchApiTests(TestCase):
    def setUp(self):
        from datetime import timedelta

        from django.utils import timezone

        ensure_role_groups()
        self.product = tracked_product(
            name="أموكسيسيلين",
            sku="API-AMOX",
            mode=Product.TrackingMode.BATCH,
            unit_price="20.00",
        )
        self.variant = self.product.default_variant
        self.expiry = timezone.localdate() + timedelta(days=20)
        receive(
            variant=self.variant,
            quantity=10,
            unit_cost="14.00",
            batches=[
                {
                    "code": "A-2026-01",
                    "quantity": Decimal("10"),
                    "expiry_date": self.expiry,
                }
            ],
        )
        self.batch = StockBatch.objects.get()

    def _client(self, *permissions):
        user = _user("lots", permissions=permissions)
        client = APIClient()
        client.force_authenticate(user=user)
        return client

    def test_the_lot_carries_its_balances_and_its_total(self):
        response = self._client("inventory.view_stockbatch").get(
            reverse("stock-batch-detail", args=[self.batch.pk])
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(response.data["code"], "A-2026-01")
        self.assertEqual(Decimal(str(response.data["on_hand"])), Decimal("10.000"))
        self.assertEqual(len(response.data["balances"]), 1)

    def test_quarantine_flips_every_balance_in_one_write(self):
        response = self._client(
            "inventory.view_stockbatch", "inventory.quarantine_batch"
        ).post(reverse("stock-batch-quarantine", args=[self.batch.pk]))

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.batch.refresh_from_db()
        self.assertEqual(self.batch.status, StockBatch.Status.QUARANTINED)
        self.assertFalse(self.batch.balances.get().is_sellable)

    def test_quarantine_needs_its_own_permission(self):
        response = self._client("inventory.view_stockbatch").post(
            reverse("stock-batch-quarantine", args=[self.batch.pk])
        )
        self.assertEqual(response.status_code, status.HTTP_403_FORBIDDEN)

    def test_the_expiry_watchlist_only_lists_lots_with_goods_left(self):
        response = self._client("inventory.view_stockbatch").get(
            reverse("stock-batch-expiry-watchlist"), {"days": 30}
        )
        self.assertEqual(response.status_code, status.HTTP_200_OK)
        results = response.data.get("results", response.data)
        self.assertEqual(len(results), 1)

        self.batch.balances.update(remaining_quantity=0)
        response = self._client("inventory.view_stockbatch").get(
            reverse("stock-batch-expiry-watchlist"), {"days": 30}
        )
        results = response.data.get("results", response.data)
        self.assertEqual(len(results), 0)
