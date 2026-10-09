"""«أسعار كروت دفتر»: the shop's own prices against the company's."""

from __future__ import annotations

from decimal import Decimal

from django.test import TestCase

from apps.catalog.models import Product, ProductVariant

from . import pricing_rules, quotes, vouchers
from .models import IntegrationPriceRule as Rule
from .models import IntegrationVoucher, IntegrationVoucherBrand
from .pricing_rules import Resolver
from .test_services_api import BASE, ServicesApiMixin

PRICING = "/api/integrations/pointy/pricing/"


class PricingTests(ServicesApiMixin, TestCase):
    def put(self, path, body, user=None):
        self.client.force_authenticate(user or self.manager)
        return self.client.put(path, body, format="json")

    def make_card(self, cost="10.00", suggested="12.00"):
        brand = IntegrationVoucherBrand.objects.create(
            account=self.account, code="b1", name="ليبيانا"
        )
        product = Product.objects.create(name="ليبيانا")
        variant = ProductVariant.objects.create(
            product=product, name="10", sku="PX-1", unit_price=Decimal(suggested)
        )
        voucher = IntegrationVoucher.objects.create(
            account=self.account,
            brand=brand,
            code="c1",
            label="10 دينار",
            cost=Decimal(cost),
            suggested_price=Decimal(suggested),
            variant=variant,
        )
        return voucher

    def test_resolution_order(self):
        account = self.account
        Rule.objects.create(
            account=account, scope="default", mode="custom", markup_percent=Decimal("5")
        )
        Rule.objects.create(
            account=account,
            scope="service",
            service_key="airtime",
            mode="custom",
            markup_percent=Decimal("10"),
        )
        Rule.objects.create(
            account=account, scope="service", service_key="airtime", country="ML", mode="company"
        )
        resolver = Resolver(account)
        self.assertIsNone(resolver.markup("airtime", "ML"))
        self.assertEqual(resolver.markup("airtime", "NE"), Decimal("10"))
        self.assertEqual(resolver.markup("bill:water", "NE"), Decimal("5"))

    def test_quote_uses_the_custom_markup_and_seals_it(self):
        self.assertEqual(self.quote()["price"], "96.50")
        Rule.objects.create(
            account=self.account,
            scope="service",
            service_key="airtime",
            mode="custom",
            markup_percent=Decimal("10"),
        )
        data = self.quote()
        self.assertEqual(data["price"], "100.50")
        self.assertEqual(
            quotes.open_priced_quote(
                data["quote"],
                account=self.account,
                subscriber_ref="+22370123456",
                option_code="air:289:5000:XOF",
            ),
            (Decimal("91.30"), Decimal("100.50")),
        )

    def test_sync_keeps_a_custom_card_price_and_follows_the_company_otherwise(self):
        voucher = self.make_card()
        self.client.force_authenticate(self.manager)
        response = self.put(
            f"{PRICING}cards/{voucher.variant_id}/", {"mode": "custom", "price": "15.00"}
        )
        self.assertEqual(response.status_code, 200, response.content)
        self.assertEqual(response.json()["custom_price"], "15.00")
        voucher.suggested_price = Decimal("13.00")
        voucher.save()
        pricing_rules.forget(self.account)
        brand, product = voucher.brand, voucher.variant.product
        vouchers._materialize_variant(self.account, brand, product, voucher, voucher, name="10")
        voucher.variant.refresh_from_db()
        self.assertEqual(voucher.variant.unit_price, Decimal("15.00"))
        self.put(f"{PRICING}cards/{voucher.variant_id}/", {"mode": "company"})
        voucher.variant.refresh_from_db()
        self.assertEqual(voucher.variant.unit_price, Decimal("13.00"))

    def test_changing_the_default_reprices_cards_at_once(self):
        voucher = self.make_card(cost="10.00", suggested="12.00")
        body = self.put(PRICING, {"default_mode": "custom", "default_markup_percent": "50"})
        self.assertEqual(body.status_code, 200, body.content)
        voucher.variant.refresh_from_db()
        self.assertEqual(voucher.variant.unit_price, Decimal("15.00"))
        self.put(PRICING, {"default_mode": "company"})
        voucher.variant.refresh_from_db()
        self.assertEqual(voucher.variant.unit_price, Decimal("12.00"))
        # A card with its own custom price is not touched by the default.
        self.put(f"{PRICING}cards/{voucher.variant_id}/", {"mode": "custom", "price": "13.00"})
        self.put(PRICING, {"default_mode": "custom", "default_markup_percent": "50"})
        voucher.variant.refresh_from_db()
        self.assertEqual(voucher.variant.unit_price, Decimal("13.00"))

    def test_a_price_below_what_the_shop_pays_is_refused_in_arabic(self):
        voucher = self.make_card()
        response = self.put(
            f"{PRICING}cards/{voucher.variant_id}/", {"mode": "custom", "price": "9.00"}
        )
        self.assertEqual(response.status_code, 400)
        self.assertIn("أقل", response.json()["price"])

    def test_pricing_endpoints_and_permissions(self):
        self.client.force_authenticate(self.cashier)
        self.assertEqual(self.client.get(PRICING).status_code, 403)
        body = self.put(
            PRICING,
            {
                "default_mode": "company",
                "services": [{"key": "airtime", "mode": "custom", "markup_percent": "10"}],
            },
        )
        self.assertEqual(body.status_code, 200, body.content)
        row = next(r for r in body.json()["services"] if r["key"] == "airtime")
        self.assertEqual((row["mode"], row["markup_percent"]), ("custom", "10.00"))
        self.assertEqual(
            self.put(
                PRICING, {"default_mode": "custom", "default_markup_percent": "-1"}
            ).status_code,
            400,
        )
        voucher = self.make_card()
        bulk = self.client.post(
            f"{PRICING}cards/bulk/",
            {"brand": "b1", "mode": "custom", "markup_percent": "20"},
            format="json",
        )
        self.assertEqual(bulk.status_code, 200, bulk.content)
        voucher.variant.refresh_from_db()
        self.assertEqual(voucher.variant.unit_price, Decimal("12.00"))
        listing = self.client.get(f"{PRICING}cards/?brand=b1").json()
        self.assertEqual(listing["results"][0]["custom_price"], "12.00")

    def test_menu_flags_who_can_edit_pricing(self):
        self.client.force_authenticate(self.manager)
        self.assertTrue(
            self.client.get("/api/integrations/vouchers/menu/").json()["can_edit_pricing"]
        )
        self.client.force_authenticate(self.cashier)
        self.assertFalse(
            self.client.get("/api/integrations/vouchers/menu/").json()["can_edit_pricing"]
        )


class BelowCostTests(ServicesApiMixin, TestCase):
    """A card price the company's cost has overtaken: told once, blocked, fixable in one tap."""

    put = PricingTests.put
    make_card = PricingTests.make_card

    def card_below_cost(self):
        voucher = self.make_card(cost="10.00", suggested="12.00")
        self.put(f"{PRICING}cards/{voucher.variant_id}/", {"mode": "custom", "price": "15.00"})
        # The company's price rose at the next sync: 15.00 is now under what the shop pays.
        voucher.cost = Decimal("16.00")
        voucher.save()
        pricing_rules.forget(self.account)
        vouchers._materialize_variant(
            self.account, voucher.brand, voucher.variant.product, voucher, voucher, name="10"
        )
        voucher.variant.refresh_from_db()
        return voucher

    def alerts(self):
        from apps.notifications.models import BusinessNotification
        from apps.notifications.services import sync_business_notifications

        sync_business_notifications()
        return BusinessNotification.objects.filter(
            code="integrations.below_cost_cards", status="active"
        )

    def test_the_card_is_blocked_listed_and_flagged(self):
        voucher = self.card_below_cost()
        self.assertFalse(voucher.variant.is_active)
        self.assertEqual(voucher.variant.unit_price, Decimal("15.00"))
        self.client.force_authenticate(self.manager)
        rows = self.client.get(f"{PRICING}cards/?below_cost=1").json()
        self.assertEqual([row["variant_id"] for row in rows["results"]], [voucher.variant_id])
        self.assertTrue(rows["results"][0]["below_cost"])
        self.assertEqual(rows["below_cost_count"], 1)
        self.assertEqual(
            self.client.get(f"{PRICING}cards/").json()["results"][0]["below_cost"], True
        )
        from rest_framework import serializers

        from .fulfillment import _resolve_voucher_line

        with self.assertRaises(serializers.ValidationError):
            _resolve_voucher_line("pointy", voucher.variant)

    def test_the_owner_is_told_once_per_set_and_it_clears_when_fixed(self):
        voucher = self.card_below_cost()
        first = list(self.alerts())
        self.assertEqual(len(first), 1)
        self.assertEqual(first[0].payload["count"], 1)
        self.assertEqual(len(self.alerts()), 1)
        self.assertEqual(self.alerts()[0].pk, first[0].pk)
        from apps.notifications.services import visible_notifications_for_user

        self.assertIn(first[0].pk, [n.pk for n in visible_notifications_for_user(self.manager)])

        # «استخدام تسعير الشركة»: one call for every card under cost.
        self.client.force_authenticate(self.manager)
        response = self.client.post(
            f"{PRICING}cards/bulk/", {"below_cost": True, "mode": "company"}, format="json"
        )
        self.assertEqual(response.json(), {"updated": 1})
        voucher.variant.refresh_from_db()
        self.assertTrue(voucher.variant.is_active)
        self.assertEqual(len(self.alerts()), 0)
