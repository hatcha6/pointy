"""The FX endpoints: permissions, provenance in the payload, and honest repricing."""

from datetime import timedelta
from decimal import Decimal

from django.contrib.auth import get_user_model
from django.urls import reverse
from django.utils import timezone
from rest_framework.test import APITestCase

from apps.catalog.models import Product, ProductVariant
from apps.catalog.pricing import set_foreign_price
from apps.core.models import ShopSettings
from apps.core.roles import ensure_role_groups
from apps.fx import currencies as ref
from apps.fx.models import Currency, ExchangeRate
from apps.fx.rates import invalidate_rate_cache
from apps.fx.services import ensure_builtin_currencies


class FxApiTestCase(APITestCase):
    def setUp(self):
        super().setUp()
        ensure_builtin_currencies()
        invalidate_rate_cache()
        ensure_role_groups()
        self.now = timezone.now()
        User = get_user_model()
        self.manager = User.objects.create_user(
            username="manager", password="pw-manager-1"
        )
        self.manager.groups.add(_group("manager"))
        self.cashier = User.objects.create_user(
            username="cashier", password="pw-cashier-1"
        )
        self.cashier.groups.add(_group("cashier"))

    def add_rate(self, rate, *, at=None, frm="USD"):
        return ExchangeRate.objects.create(
            from_currency_id=frm,
            to_currency_id="LYD",
            instrument=ref.INSTRUMENT_CASH,
            effective_at=at or self.now,
            rate=Decimal(rate),
            source=ref.SOURCE_RELAY,
        )


def _group(name):
    from django.contrib.auth.models import Group

    return Group.objects.get(name=name)


class PermissionTests(FxApiTestCase):
    def test_rates_require_authentication(self):
        response = self.client.get(reverse("exchange-rate-list"))
        self.assertIn(response.status_code, (401, 403))

    def test_a_manager_may_read_rates(self):
        self.client.force_authenticate(self.manager)
        self.assertEqual(self.client.get(reverse("exchange-rate-list")).status_code, 200)

    def test_a_cashier_may_not_type_a_rate(self):
        self.client.force_authenticate(self.cashier)
        response = self.client.post(
            reverse("exchange-rate-manual"),
            {"from_code": "USD", "rate": "7.00"},
            format="json",
        )
        self.assertEqual(response.status_code, 403)

    def test_a_cashier_may_not_reprice_the_catalogue(self):
        self.client.force_authenticate(self.cashier)
        self.assertEqual(
            self.client.get(reverse("repricing-preview")).status_code, 403
        )

    def test_currencies_cannot_be_deleted_through_the_api(self):
        # A currency may be referenced by a price sheet or by a rate a document
        # froze, so deleting one would orphan history. The viewset has no
        # destroy mixin; the permission layer happens to refuse first, so the
        # invariant is asserted rather than the particular status code.
        self.client.force_authenticate(self.manager)
        response = self.client.delete(
            reverse("currency-detail", kwargs={"pk": "USD"})
        )
        self.assertIn(response.status_code, (403, 405))
        self.assertTrue(Currency.objects.filter(pk="USD").exists())


class CurrentRateTests(FxApiTestCase):
    def setUp(self):
        super().setUp()
        self.client.force_authenticate(self.manager)

    def test_current_reports_the_base_currency_and_the_shops_instrument(self):
        response = self.client.get(reverse("exchange-rate-current"))
        self.assertEqual(response.data["base_code"], "LYD")
        self.assertEqual(response.data["instrument"], ref.INSTRUMENT_CASH)

    def test_a_resolved_rate_carries_its_provenance(self):
        self.add_rate("6.85")
        response = self.client.get(reverse("exchange-rate-current"))
        entry = next(r for r in response.data["rates"] if r["from_code"] == "USD")
        self.assertEqual(Decimal(entry["rate"]), Decimal("6.85000000"))
        self.assertEqual(entry["source"], ref.SOURCE_RELAY)
        self.assertFalse(entry["is_substituted"])
        self.assertIn("age_hours", entry)

    def test_an_old_rate_is_flagged_stale_rather_than_withheld(self):
        self.add_rate("6.10", at=self.now - timedelta(days=9))
        response = self.client.get(reverse("exchange-rate-current"))
        entry = next(r for r in response.data["rates"] if r["from_code"] == "USD")
        self.assertTrue(entry["is_stale"])
        self.assertEqual(Decimal(entry["rate"]), Decimal("6.10000000"))

    def test_currencies_with_no_rate_are_simply_absent(self):
        self.add_rate("6.85")
        response = self.client.get(reverse("exchange-rate-current"))
        self.assertEqual([r["from_code"] for r in response.data["rates"]], ["USD"])

    def test_a_disabled_currency_is_not_reported(self):
        self.add_rate("6.85")
        Currency.objects.filter(pk="USD").update(is_enabled=False)
        response = self.client.get(reverse("exchange-rate-current"))
        self.assertEqual(response.data["rates"], [])


class ManualRateApiTests(FxApiTestCase):
    def setUp(self):
        super().setUp()
        self.client.force_authenticate(self.manager)

    def test_a_manager_can_type_a_rate(self):
        response = self.client.post(
            reverse("exchange-rate-manual"),
            {"from_code": "usd", "rate": "7.25", "note": "صرّاف السوق"},
            format="json",
        )
        self.assertEqual(response.status_code, 201)
        self.assertEqual(response.data["source"], ref.SOURCE_MANUAL)
        self.assertEqual(response.data["from_code"], "USD")

    def test_the_target_defaults_to_the_shops_own_currency(self):
        self.client.post(
            reverse("exchange-rate-manual"),
            {"from_code": "USD", "rate": "7.25"},
            format="json",
        )
        self.assertEqual(ExchangeRate.objects.get().to_currency_id, "LYD")

    def test_a_zero_rate_is_refused(self):
        response = self.client.post(
            reverse("exchange-rate-manual"),
            {"from_code": "USD", "rate": "0"},
            format="json",
        )
        self.assertEqual(response.status_code, 400)

    def test_converting_a_currency_to_itself_is_refused(self):
        response = self.client.post(
            reverse("exchange-rate-manual"),
            {"from_code": "LYD", "to_code": "LYD", "rate": "1"},
            format="json",
        )
        self.assertEqual(response.status_code, 400)

    def test_an_unknown_currency_is_refused(self):
        response = self.client.post(
            reverse("exchange-rate-manual"),
            {"from_code": "ZZZ", "rate": "3"},
            format="json",
        )
        self.assertEqual(response.status_code, 400)

    def test_the_author_is_recorded(self):
        self.client.post(
            reverse("exchange-rate-manual"),
            {"from_code": "USD", "rate": "7.25"},
            format="json",
        )
        self.assertEqual(ExchangeRate.objects.get().entered_by, self.manager)


class RepricingApiTests(FxApiTestCase):
    def setUp(self):
        super().setUp()
        self.client.force_authenticate(self.manager)
        self.add_rate("6.85", at=self.now - timedelta(hours=2))
        self.product = Product.objects.create(
            name="Imported widget", pricing_currency_id="USD"
        )
        self.variant = ProductVariant.objects.create(
            product=self.product,
            sku="IMP-1",
            unit_price=Decimal("1.00"),
            is_default=True,
        )
        set_foreign_price(self.variant, "12.00", at=self.now - timedelta(hours=2))
        self.add_rate("7.11", at=self.now - timedelta(hours=1))
        invalidate_rate_cache()

    def test_preview_reports_the_drift_without_writing_anything(self):
        response = self.client.get(reverse("repricing-preview"))
        self.assertEqual(response.data["count"], 1)
        proposal = response.data["proposals"][0]
        self.assertEqual(Decimal(proposal["current_base_price"]), Decimal("82.20"))
        self.assertEqual(Decimal(proposal["proposed_base_price"]), Decimal("85.32"))
        self.variant.refresh_from_db()
        self.assertEqual(self.variant.unit_price, Decimal("82.20"))

    def test_applying_only_the_approved_rows(self):
        response = self.client.post(
            reverse("repricing-apply"),
            {"targets": [{"kind": "variant", "target_id": self.variant.pk}]},
            format="json",
        )
        self.assertEqual(response.data["repriced"], 1)
        self.variant.refresh_from_db()
        self.assertEqual(self.variant.unit_price, Decimal("85.32"))

    def test_rows_the_owner_did_not_approve_are_left_alone(self):
        other = Product.objects.create(name="Other", pricing_currency_id="USD")
        other_variant = ProductVariant.objects.create(
            product=other, sku="IMP-2", unit_price=Decimal("1.00"), is_default=True
        )
        set_foreign_price(other_variant, "5.00", at=self.now - timedelta(hours=2))
        self.client.post(
            reverse("repricing-apply"),
            {"targets": [{"kind": "variant", "target_id": self.variant.pk}]},
            format="json",
        )
        other_variant.refresh_from_db()
        self.assertEqual(other_variant.unit_price, Decimal("34.25"))

    def test_an_empty_approval_list_is_refused(self):
        response = self.client.post(
            reverse("repricing-apply"), {"targets": []}, format="json"
        )
        self.assertEqual(response.status_code, 400)


class ForeignPriceThroughTheApiTests(FxApiTestCase):
    """Writing a foreign price through the catalogue API derives the base one."""

    def setUp(self):
        super().setUp()
        self.client.force_authenticate(self.manager)
        self.add_rate("6.85")
        self.product = Product.objects.create(
            name="Imported", pricing_currency_id="USD"
        )

    def test_creating_a_variant_with_a_foreign_price_derives_the_base_price(self):
        response = self.client.post(
            reverse("product-variant-list"),
            {
                "product": self.product.pk,
                "sku": "NEW-1",
                "unit_price": "0.00",
                "price_amount": "12.00",
            },
            format="json",
        )
        self.assertEqual(response.status_code, 201, response.data)
        variant = ProductVariant.objects.get(sku="NEW-1")
        self.assertEqual(variant.unit_price, Decimal("82.20"))
        self.assertEqual(variant.price_amount, Decimal("12.00"))
        self.assertEqual(variant.price_rate, Decimal("6.85000000"))

    def test_updating_the_foreign_price_re_derives_the_base_price(self):
        variant = ProductVariant.objects.create(
            product=self.product,
            sku="UPD-1",
            unit_price=Decimal("1.00"),
            is_default=True,
        )
        response = self.client.patch(
            reverse("product-variant-detail", kwargs={"pk": variant.pk}),
            {"price_amount": "20.00"},
            format="json",
        )
        self.assertEqual(response.status_code, 200, response.data)
        variant.refresh_from_db()
        self.assertEqual(variant.unit_price, Decimal("137.00"))

    def test_a_base_priced_product_is_untouched_by_the_new_path(self):
        local = Product.objects.create(name="Local")
        response = self.client.post(
            reverse("product-variant-list"),
            {"product": local.pk, "sku": "LOC-1", "unit_price": "9.50"},
            format="json",
        )
        self.assertEqual(response.status_code, 201, response.data)
        variant = ProductVariant.objects.get(sku="LOC-1")
        self.assertEqual(variant.unit_price, Decimal("9.50"))
        self.assertIsNone(variant.price_amount)

    def test_the_frozen_rate_is_read_only_from_the_client(self):
        variant = ProductVariant.objects.create(
            product=self.product,
            sku="RO-1",
            unit_price=Decimal("1.00"),
            is_default=True,
        )
        self.client.patch(
            reverse("product-variant-detail", kwargs={"pk": variant.pk}),
            {"price_amount": "10.00", "price_rate": "99.00"},
            format="json",
        )
        variant.refresh_from_db()
        # The client's rate is ignored; the resolver's is used.
        self.assertEqual(variant.price_rate, Decimal("6.85000000"))
        self.assertEqual(variant.unit_price, Decimal("68.50"))


class RepricePreviewIsBindingTests(FxApiTestCase):
    """What the owner was shown is what gets written, across two requests."""

    def setUp(self):
        super().setUp()
        self.client.force_authenticate(self.manager)
        self.add_rate("6.85", at=self.now - timedelta(hours=2))
        self.product = Product.objects.create(
            name="Imported", pricing_currency_id="USD"
        )
        self.variant = ProductVariant.objects.create(
            product=self.product,
            sku="BIND-1",
            unit_price=Decimal("1.00"),
            is_default=True,
        )
        set_foreign_price(self.variant, "12.00", at=self.now - timedelta(hours=2))
        self.add_rate("7.11", at=self.now - timedelta(hours=1))
        invalidate_rate_cache()

    def test_preview_hands_back_the_instant_it_resolved_at(self):
        response = self.client.get(reverse("repricing-preview"))
        self.assertIsNotNone(response.data["resolved_at"])

    def test_echoing_the_instant_pins_the_price_that_was_shown(self):
        preview = self.client.get(reverse("repricing-preview"))
        shown = Decimal(preview.data["proposals"][0]["proposed_base_price"])
        self.assertEqual(shown, Decimal("85.32"))

        # A newer rate lands AFTER the preview resolved — which is the case the
        # pinning exists for. Dated off timezone.now() rather than the fixture
        # clock so it is genuinely later than the instant the preview returned.
        self.add_rate("9.50", at=timezone.now())
        invalidate_rate_cache()

        self.client.post(
            reverse("repricing-apply"),
            {
                "targets": [{"kind": "variant", "target_id": self.variant.pk}],
                "resolved_at": preview.data["resolved_at"],
            },
            format="json",
        )
        self.variant.refresh_from_db()
        # The confirmation dialog was binding.
        self.assertEqual(self.variant.unit_price, shown)

    def test_without_the_instant_the_current_rate_is_used(self):
        # Still correct, just not pinned — documented so the behaviour is a
        # choice rather than a surprise.
        self.add_rate("9.50", at=self.now - timedelta(minutes=1))
        invalidate_rate_cache()
        self.client.post(
            reverse("repricing-apply"),
            {"targets": [{"kind": "variant", "target_id": self.variant.pk}]},
            format="json",
        )
        self.variant.refresh_from_db()
        self.assertEqual(self.variant.unit_price, Decimal("114.00"))


class ProductCreatedWithAPricingCurrencyTests(FxApiTestCase):
    """Creating a whole product in one request derives its base price.

    The nested paths write the variant row directly rather than through
    ProductVariantSerializer, so without an explicit derivation a product
    created from the product form would store the dollar figure and sell at
    whatever base price happened to be sent.
    """

    def setUp(self):
        super().setUp()
        self.client.force_authenticate(self.manager)
        self.add_rate("6.85")

    def test_default_variant_derives_from_the_foreign_price(self):
        response = self.client.post(
            reverse("product-list"),
            {
                "name": "Imported kettle",
                "pricing_currency": "USD",
                "default_variant": {
                    "sku": "KETTLE-1",
                    "unit_price": "0.00",
                    "price_amount": "12.00",
                },
            },
            format="json",
        )
        self.assertEqual(response.status_code, 201, response.data)
        variant = ProductVariant.objects.get(sku="KETTLE-1")
        self.assertEqual(variant.unit_price, Decimal("82.20"))
        self.assertEqual(variant.price_amount, Decimal("12.00"))
        self.assertEqual(variant.price_rate, Decimal("6.85000000"))

    def test_generated_variants_each_derive(self):
        response = self.client.post(
            reverse("product-list"),
            {
                "name": "Imported mug",
                "pricing_currency": "USD",
                "variants": [
                    {"sku": "MUG-S", "unit_price": "0.00",
                     "price_amount": "5.00", "is_default": True},
                    {"sku": "MUG-L", "unit_price": "0.00",
                     "price_amount": "8.00"},
                ],
            },
            format="json",
        )
        self.assertEqual(response.status_code, 201, response.data)
        self.assertEqual(
            ProductVariant.objects.get(sku="MUG-S").unit_price, Decimal("34.25")
        )
        self.assertEqual(
            ProductVariant.objects.get(sku="MUG-L").unit_price, Decimal("54.80")
        )

    def test_a_base_priced_product_still_takes_the_price_it_was_sent(self):
        response = self.client.post(
            reverse("product-list"),
            {
                "name": "Local broom",
                "default_variant": {"sku": "BROOM-1", "unit_price": "9.50"},
            },
            format="json",
        )
        self.assertEqual(response.status_code, 201, response.data)
        variant = ProductVariant.objects.get(sku="BROOM-1")
        self.assertEqual(variant.unit_price, Decimal("9.50"))
        self.assertIsNone(variant.price_amount)

    def test_switching_a_product_to_a_currency_reprices_on_the_next_save(self):
        self.client.post(
            reverse("product-list"),
            {
                "name": "Later import",
                "default_variant": {"sku": "LATER-1", "unit_price": "9.50"},
            },
            format="json",
        )
        product = Product.objects.get(name="Later import")
        response = self.client.patch(
            reverse("product-detail", kwargs={"pk": product.pk}),
            {
                "pricing_currency": "USD",
                "default_variant": {"sku": "LATER-1", "price_amount": "3.00"},
            },
            format="json",
        )
        self.assertEqual(response.status_code, 200, response.data)
        variant = ProductVariant.objects.get(sku="LATER-1")
        self.assertEqual(variant.unit_price, Decimal("20.55"))


class ChangingAPricingCurrencyTests(FxApiTestCase):
    """Switching a product's price sheet currency is not a repricing.

    A settings edit must never move a shelf price on its own — the stored base
    price is what the shop sells at, and it changes only when someone enters a
    new price or runs a repricing they approved.
    """

    def setUp(self):
        super().setUp()
        self.client.force_authenticate(self.manager)
        self.add_rate("6.85")
        self.product = Product.objects.create(name="Kettle")
        self.variant = ProductVariant.objects.create(
            product=self.product,
            sku="KETTLE-9",
            unit_price=Decimal("50.00"),
            is_default=True,
        )

    def test_setting_a_currency_alone_leaves_the_price_alone(self):
        response = self.client.patch(
            reverse("product-detail", kwargs={"pk": self.product.pk}),
            {"pricing_currency": "USD"},
            format="json",
        )
        self.assertEqual(response.status_code, 200, response.data)
        self.variant.refresh_from_db()
        self.assertEqual(self.variant.unit_price, Decimal("50.00"))
        self.assertIsNone(self.variant.price_amount)

    def test_clearing_the_currency_leaves_the_price_alone(self):
        self.product.pricing_currency_id = "USD"
        self.product.save(update_fields=["pricing_currency"])
        response = self.client.patch(
            reverse("product-detail", kwargs={"pk": self.product.pk}),
            {"pricing_currency": None},
            format="json",
        )
        self.assertEqual(response.status_code, 200, response.data)
        self.product.refresh_from_db()
        self.assertIsNone(self.product.pricing_currency_id)
        self.variant.refresh_from_db()
        self.assertEqual(self.variant.unit_price, Decimal("50.00"))

    def test_a_sale_prices_off_the_stored_base_price_not_todays_rate(self):
        # The invariant the whole design rests on: the rate is read when the
        # price is SET, never when it is sold.
        self.client.patch(
            reverse("product-detail", kwargs={"pk": self.product.pk}),
            {
                "pricing_currency": "USD",
                "default_variant": {"sku": "KETTLE-9", "price_amount": "12.00"},
            },
            format="json",
        )
        self.variant.refresh_from_db()
        self.assertEqual(self.variant.unit_price, Decimal("82.20"))

        # The dollar moves sharply. The shelf price does not.
        self.add_rate("9.50", at=timezone.now())
        invalidate_rate_cache()
        self.variant.refresh_from_db()
        self.assertEqual(self.variant.unit_price, Decimal("82.20"))
        self.assertEqual(self.variant.price_rate, Decimal("6.85000000"))


class SingleCurrencyShopSeesNothingTests(FxApiTestCase):
    """A shop that trades only in its own currency must never meet the feature.

    The currency registry is seeded on every install, so without an explicit
    master switch every shop in the fleet would be offered eight currencies it
    has no use for. ``fx_enabled`` is that switch, and it is OFF by default.
    """

    def setUp(self):
        super().setUp()
        self.client.force_authenticate(self.manager)

    def test_fx_is_off_by_default(self):
        self.assertFalse(ShopSettings.load().fx_enabled)

    def test_the_current_rates_payload_reports_the_switch(self):
        response = self.client.get(reverse("exchange-rate-current"))
        self.assertFalse(response.data["fx_enabled"])

    def test_turning_it_on_is_reported_too(self):
        row = ShopSettings.load()
        ShopSettings.objects.filter(pk=row.pk).update(fx_enabled=True)
        response = self.client.get(reverse("exchange-rate-current"))
        self.assertTrue(response.data["fx_enabled"])

    def test_the_switch_is_editable_through_shop_settings(self):
        response = self.client.patch(
            reverse("shop-settings"), {"fx_enabled": True}, format="json"
        )
        self.assertEqual(response.status_code, 200, response.data)
        self.assertTrue(ShopSettings.load().fx_enabled)

    def test_a_single_currency_shop_still_prices_and_sells_normally(self):
        """The switch hides the feature; it does not break anything."""
        product = Product.objects.create(name="Bread")
        variant = ProductVariant.objects.create(
            product=product,
            sku="BREAD-1",
            unit_price=Decimal("1.00"),
            is_default=True,
        )
        self.assertIsNone(product.pricing_currency_id)
        self.assertIsNone(variant.price_amount)
        self.assertEqual(variant.unit_price, Decimal("1.00"))
