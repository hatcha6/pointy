"""The purchase discount preview must run through the Redis guard, not the engine.

The PO editor re-previews on every edit — 13 call sites in ``PurchaseViewModel``,
all undebounced — so the engine pass was being paid per keystroke. The sales
preview has been guarded by ``apps.discounts.cache`` for a while; purchasing
called ``DiscountEngine().calculate()`` straight, which meant a shop running no
purchasing promotions still paid a full engine pass (and its rule scan) on every
line edit, and a shop that *does* run them re-ran the engine's 7 queries even for
edits that cannot change a discount.

Measured on the 11-line payload below (sqlite, per-request query count):

    no purchasing rules   7 -> 6 queries (1 line), 17 -> 16 (11 lines)
    active rule, repeat  24 -> 16 queries (the engine's rule scan, its 5 M2M
                         prefetches and the tier read are all skipped)

These tests lock the behaviour rather than the absolute numbers.
"""

from decimal import Decimal
from unittest import mock

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group
from django.core.cache import cache
from django.test import TestCase, override_settings
from django.urls import reverse
from rest_framework.test import APIClient

from apps.catalog.models import ProductCategory
from apps.catalog.testing import create_product_with_default_variant
from apps.core.roles import MANAGER_GROUP, ensure_role_groups
from apps.discounts.services import DiscountEngine

from .models import Supplier

# Real (locmem) cache so hits actually hit — the configured django-redis backend
# has no Redis in tests, which would exercise only the fail-open path.
_LOCMEM = {
    "default": {
        "BACKEND": "django.core.cache.backends.locmem.LocMemCache",
        "LOCATION": "purchase-preview-test",
    }
}


@override_settings(CACHES=_LOCMEM)
class PurchaseDiscountPreviewCacheTests(TestCase):
    def setUp(self):
        cache.clear()
        ensure_role_groups()
        self.client = APIClient()
        user = get_user_model().objects.create_user(
            username="purchase-manager",
            password="pass",
        )
        user.groups.add(Group.objects.get(name=MANAGER_GROUP))
        self.client.force_authenticate(user=user)
        self.supplier = Supplier.objects.create(name="Cache supplier")
        category = ProductCategory.objects.create(name="Cache category")
        self.variants = []
        for index in range(3):
            product = create_product_with_default_variant(
                sku=f"PUR-CACHE-{index}",
                barcode="",
                name=f"Cache product {index}",
                unit_price=Decimal("1.00"),
            )
            product.categories.add(category)
            self.variants.append(product.default_variant)

    def _payload(self, **extra):
        return {
            "supplier": self.supplier.pk,
            "lines": [
                {"variant": variant.pk, "quantity": 2, "unit_cost": "5.00"}
                for variant in self.variants
            ],
            **extra,
        }

    def _preview(self, **extra):
        response = self.client.post(
            reverse("purchaseorder-discount-preview"),
            self._payload(**extra),
            format="json",
        )
        self.assertEqual(response.status_code, 200, response.data)
        return response.data

    def _active_rule(self):
        from apps.discounts.models import DiscountRule

        rule = DiscountRule.objects.create(
            name="Supplier automatic",
            channel=DiscountRule.Channel.PURCHASING,
            value_type=DiscountRule.ValueType.PERCENTAGE,
            value=Decimal("10.00"),
            priority=1,
            exclusive=False,
        )
        cache.clear()  # drop the gate the earlier no-rule state may have cached
        return rule

    def test_no_purchasing_rules_never_reaches_the_engine(self):
        self._preview()  # warms the active-rules gate
        with mock.patch.object(
            DiscountEngine, "calculate", side_effect=AssertionError("engine ran")
        ):
            data = self._preview()
        self.assertEqual(data["discount_total"], "0.00")
        self.assertEqual(data["total"], "30.00")

    def test_repeat_preview_of_the_same_cart_is_served_from_cache(self):
        self._active_rule()
        with mock.patch.object(
            DiscountEngine, "calculate", wraps=DiscountEngine().calculate
        ) as calculate:
            first = self._preview()
            second = self._preview()
        self.assertEqual(calculate.call_count, 1, "the identical cart re-ran the engine")
        self.assertEqual(first["discount_total"], "3.00")
        self.assertEqual(second, first)

    def test_landed_cost_edit_reuses_the_cached_discount_but_not_the_totals(self):
        """The fields outside the discount digest must still be recomputed.

        Landed costs, the allocation method and the manual extra discount all
        trigger a preview refresh but cannot change the discount result — that is
        exactly where the memo pays off, so guard that only the *discount* half is
        reused and the rest of the payload still tracks the request.
        """
        self._active_rule()
        with mock.patch.object(
            DiscountEngine, "calculate", wraps=DiscountEngine().calculate
        ) as calculate:
            plain = self._preview()
            landed = self._preview(
                landed_cost_entries=[{"name": "Freight", "amount": "12.00"}]
            )
            extra = self._preview(extra_discount_amount="2.00")
        self.assertEqual(calculate.call_count, 1, "a non-discount edit re-ran the engine")

        self.assertEqual(plain["landed_cost_total"], "0.00")
        self.assertEqual(plain["total"], "27.00")

        # Same discount, but the landed cost is added on top of it.
        self.assertEqual(landed["discount_total"], "3.00")
        self.assertEqual(landed["landed_cost_total"], "12.00")
        self.assertEqual(landed["total"], "39.00")
        self.assertEqual(len(landed["applied_discounts"]), 1)

        # Same rule discount, plus the one-off manual discount on top.
        self.assertEqual(extra["extra_discount_amount"], "2.00")
        self.assertEqual(extra["discount_total"], "5.00")
        self.assertEqual(extra["total"], "25.00")
