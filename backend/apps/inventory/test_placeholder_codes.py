"""An article owed its identifier never collides with another one.

A unit received without a scan carries a generated stand-in code, and the
partial unique index over live units compares *normalised* codes. Normalising
strips dashes, and the keys callers build those codes from are not unique per
call — every manual arrival of one variant was ``MV-<variant>``, both partial
deliveries of one order line started at ``PO<order>L<line>-1``, and
``SC-1-23`` and ``SC-12-3`` are one string once the dashes go. So the second
capture-later arrival died with an ``IntegrityError``: a 500, where a shop was
only putting goods on the shelf to scan later.
"""

from decimal import Decimal

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group
from django.test import TestCase
from django.urls import reverse
from django.utils import timezone
from rest_framework import status
from rest_framework.test import APIClient

from apps.catalog.models import Product
from apps.core.models import ShopSettings
from apps.core.roles import MANAGER_GROUP, ensure_role_groups

from . import tracking
from .identity import normalize_identifier
from .integrity import assert_tracking_invariants
from .models import StockItem, StockUnit
from .tracked_testing import tracked_product


class _ManagerTestCase(TestCase):
    def setUp(self):
        ensure_role_groups()
        user = get_user_model().objects.create_user(
            username="placeholders", password="pass"
        )
        user.groups.add(Group.objects.get(name=MANAGER_GROUP))
        self.client = APIClient()
        self.client.force_authenticate(user)

    def _serial(self, sku):
        return tracked_product(
            name="هاتف",
            sku=sku,
            mode=Product.TrackingMode.SERIAL,
            unit_price="1500.00",
        ).default_variant


class ManualArrivalTests(_ManagerTestCase):
    def test_a_second_unnamed_arrival_of_one_variant_is_not_a_500(self):
        variant = self._serial("PH-MV")

        for _ in range(2):
            response = self.client.post(
                "/api/stock-movements/",
                {
                    "variant": variant.pk,
                    "movement_type": "increase",
                    "quantity": "1",
                },
                format="json",
            )
            self.assertEqual(
                response.status_code, status.HTTP_201_CREATED, response.data
            )

        placeholders = StockUnit.objects.filter(variant=variant, is_identified=False)
        self.assertEqual(placeholders.count(), 2)
        self.assertEqual(
            StockItem.objects.get(variant=variant).quantity_on_hand, Decimal("2")
        )
        assert_tracking_invariants()


class PartialDeliveryTests(_ManagerTestCase):
    def setUp(self):
        super().setUp()
        settings = ShopSettings.load()
        settings.serialized_capture_later_allowed = True
        settings.save(
            update_fields=["serialized_capture_later_allowed", "updated_at"]
        )

    def test_two_deliveries_of_one_line_both_left_to_scan_later(self):
        """A truck at six in the evening, and another the next morning."""
        from apps.purchasing.models import Supplier

        variant = self._serial("PH-PO")
        created = self.client.post(
            reverse("purchaseorder-list"),
            {
                "supplier": Supplier.objects.create(name="مورد").pk,
                "lines": [
                    {"variant": variant.pk, "quantity": 5, "unit_cost": "900.00"}
                ],
            },
            format="json",
        )
        self.assertEqual(created.status_code, status.HTTP_201_CREATED, created.data)
        order_id, line_id = created.data["id"], created.data["lines"][0]["id"]
        self.client.post(reverse("purchaseorder-submit", args=[order_id]))

        for quantity in (2, 3):
            response = self.client.post(
                reverse("purchaseorder-receive", args=[order_id]),
                {"lines": [{"line": line_id, "quantity": quantity}]},
                format="json",
            )
            self.assertEqual(response.status_code, status.HTTP_200_OK, response.data)

        self.assertEqual(
            StockUnit.objects.filter(variant=variant, is_identified=False).count(), 5
        )
        assert_tracking_invariants()


class KeysThatNormaliseAlikeTests(_ManagerTestCase):
    def test_two_keys_whose_digits_run_together_make_distinct_codes(self):
        """``SC-1-23`` and ``SC-12-3`` are both ``SC123`` to the index."""
        at = timezone.now()
        first = tracking.plan_receipt(
            variant=self._serial("PH-K1"),
            warehouse=None,
            quantity=4,
            rate=Decimal("10"),
            at=at,
            capture_later=True,
            placeholder_key="SC-1-23",
        )
        second = tracking.plan_receipt(
            variant=self._serial("PH-K2"),
            warehouse=None,
            quantity=4,
            rate=Decimal("10"),
            at=at,
            capture_later=True,
            placeholder_key="SC-12-3",
        )

        codes = [
            normalize_identifier(unit.code)
            for plan in (first, second)
            for unit in plan.new_units
        ]
        self.assertEqual(len(codes), 8)
        self.assertEqual(len(set(codes)), 8, codes)

    def test_the_same_key_twice_makes_distinct_codes(self):
        """The shape of every caller whose key is not unique per call."""
        variant = self._serial("PH-K3")
        plans = [
            tracking.plan_receipt(
                variant=variant,
                warehouse=None,
                quantity=3,
                rate=Decimal("10"),
                at=timezone.now(),
                capture_later=True,
                placeholder_key=f"MV-{variant.pk}",
            )
            for _ in range(2)
        ]

        codes = {
            normalize_identifier(unit.code)
            for plan in plans
            for unit in plan.new_units
        }
        self.assertEqual(len(codes), 6, codes)
        # The caller's key stays readable in front of the article.
        self.assertTrue(
            all(
                unit.code.startswith(f"#-MV-{variant.pk}-")
                for plan in plans
                for unit in plan.new_units
            )
        )
