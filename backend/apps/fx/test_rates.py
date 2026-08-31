"""The resolver: on-or-before lookup, the fallback ladder, staleness, provenance.

The behaviours pinned here are the ones a wrong answer would corrupt quietly —
reaching forward in time, substituting a settlement instrument without saying
so, or refusing to price because the network is down.
"""

from datetime import timedelta
from decimal import Decimal

from django.test import TestCase
from django.utils import timezone

from apps.core.models import ShopSettings
from apps.fx import currencies as ref
from apps.fx.models import Currency, ExchangeRate
from apps.fx.money import Money
from apps.fx.rates import (
    convert_amount,
    current_rate,
    decimals_for,
    invalidate_rate_cache,
    rate_on,
)
from apps.fx.services import ensure_builtin_currencies, record_manual_rate


class FxTestCase(TestCase):
    """Shared setup: a seeded registry and a clean resolver cache."""

    def setUp(self):
        super().setUp()
        ensure_builtin_currencies()
        invalidate_rate_cache()
        self.now = timezone.now()

    def add_rate(
        self,
        rate,
        *,
        at=None,
        frm="USD",
        to="LYD",
        instrument=ref.INSTRUMENT_CASH,
        bank_code="",
        source=ref.SOURCE_RELAY,
    ):
        return ExchangeRate.objects.create(
            from_currency_id=frm,
            to_currency_id=to,
            instrument=instrument,
            bank_code=bank_code,
            effective_at=at or self.now,
            rate=Decimal(rate),
            source=source,
        )


class IdentityTests(FxTestCase):
    def test_same_currency_resolves_to_one_without_a_row(self):
        resolved = rate_on("LYD", "LYD")
        self.assertEqual(resolved.rate, Decimal("1"))
        self.assertTrue(resolved.is_identity)

    def test_identity_is_never_stale_and_never_substituted(self):
        resolved = rate_on("LYD", "LYD")
        self.assertFalse(resolved.is_stale(1))
        self.assertFalse(resolved.is_substituted)

    def test_identity_is_case_insensitive(self):
        self.assertIsNotNone(rate_on(" lyd ", "LYD"))

    def test_blank_codes_resolve_to_nothing(self):
        self.assertIsNone(rate_on("", "LYD"))
        self.assertIsNone(rate_on("USD", None))


class OnOrBeforeTests(FxTestCase):
    def test_picks_the_newest_row_at_or_before_the_instant(self):
        self.add_rate("6.50", at=self.now - timedelta(hours=3))
        self.add_rate("6.85", at=self.now - timedelta(hours=1))
        self.assertEqual(rate_on("USD", "LYD", at=self.now).rate, Decimal("6.85"))

    def test_never_reaches_forward_in_time(self):
        self.add_rate("6.50", at=self.now - timedelta(hours=3))
        self.add_rate("7.02", at=self.now + timedelta(hours=1))
        # A sale rung up now must not be priced off a rate published later.
        self.assertEqual(rate_on("USD", "LYD", at=self.now).rate, Decimal("6.50"))

    def test_a_document_can_still_find_the_rate_it_froze(self):
        old = self.now - timedelta(days=21)
        self.add_rate("6.10", at=old)
        self.add_rate("7.11", at=self.now)
        # Three weeks on, the sale's own instant still resolves to its own rate.
        self.assertEqual(rate_on("USD", "LYD", at=old).rate, Decimal("6.10"))

    def test_a_row_exactly_on_the_instant_counts(self):
        self.add_rate("6.85", at=self.now)
        self.assertEqual(rate_on("USD", "LYD", at=self.now).rate, Decimal("6.85"))

    def test_nothing_before_the_instant_resolves_to_nothing(self):
        self.add_rate("6.85", at=self.now + timedelta(hours=1))
        self.assertIsNone(rate_on("USD", "LYD", at=self.now, allow_inverse=False))

    def test_unknown_pair_resolves_to_nothing_not_to_one(self):
        # The failure mode this guards: silently costing an import at 1:1.
        self.assertIsNone(rate_on("USD", "LYD"))


class InstrumentLadderTests(FxTestCase):
    def test_bank_shop_prefers_its_own_bank_series(self):
        self.add_rate("6.85")
        self.add_rate("6.90", instrument=ref.INSTRUMENT_BANK)
        self.add_rate("6.95", instrument=ref.INSTRUMENT_BANK, bank_code="ncb")
        resolved = rate_on(
            "USD", "LYD", instrument=ref.INSTRUMENT_BANK, bank_code="ncb"
        )
        self.assertEqual(resolved.rate, Decimal("6.95"))
        self.assertFalse(resolved.is_substituted)

    def test_bank_shop_falls_back_to_the_generic_bank_series_and_says_so(self):
        self.add_rate("6.90", instrument=ref.INSTRUMENT_BANK)
        resolved = rate_on(
            "USD", "LYD", instrument=ref.INSTRUMENT_BANK, bank_code="ncb"
        )
        self.assertEqual(resolved.rate, Decimal("6.90"))
        self.assertTrue(resolved.is_substituted)
        self.assertEqual(resolved.requested_bank_code, "ncb")
        self.assertEqual(resolved.bank_code, "")

    def test_bank_shop_falls_back_to_cash_as_a_last_resort_and_says_so(self):
        self.add_rate("6.85")
        resolved = rate_on(
            "USD", "LYD", instrument=ref.INSTRUMENT_BANK, bank_code="ncb"
        )
        self.assertEqual(resolved.rate, Decimal("6.85"))
        self.assertTrue(resolved.is_substituted)
        self.assertEqual(resolved.instrument, ref.INSTRUMENT_CASH)

    def test_cash_shop_is_never_served_a_bank_rate(self):
        # A shop paying in notes costs its imports at the cash rate or not at
        # all; quietly using a transfer rate would misstate cost the other way.
        self.add_rate("6.90", instrument=ref.INSTRUMENT_BANK)
        self.assertIsNone(
            rate_on("USD", "LYD", instrument=ref.INSTRUMENT_CASH, allow_inverse=False)
        )

    def test_bank_code_on_a_cash_row_is_normalized_away(self):
        row = self.add_rate("6.85", bank_code="ncb")
        row.refresh_from_db()
        self.assertEqual(row.bank_code, "")


class ShopDefaultTests(FxTestCase):
    def test_resolver_uses_the_shops_configured_instrument(self):
        self.add_rate("6.85")
        self.add_rate("6.90", instrument=ref.INSTRUMENT_BANK, bank_code="aman")
        # ``load()`` creates the singleton lazily, so materialise it before
        # updating — a filtered update on a row that does not exist yet is a
        # silent no-op.
        row = ShopSettings.load()
        ShopSettings.objects.filter(pk=row.pk).update(
            fx_instrument=ref.INSTRUMENT_BANK, fx_bank_code="aman"
        )
        self.assertEqual(rate_on("USD", "LYD").rate, Decimal("6.90"))

    def test_default_shop_settles_in_cash(self):
        self.add_rate("6.85")
        self.add_rate("6.90", instrument=ref.INSTRUMENT_BANK)
        self.assertEqual(rate_on("USD", "LYD").rate, Decimal("6.85"))


class InverseTests(FxTestCase):
    def test_reverse_pair_resolves_by_inverting(self):
        self.add_rate("4")
        resolved = rate_on("LYD", "USD")
        self.assertEqual(resolved.rate, Decimal("0.25"))
        self.assertTrue(resolved.inverted)
        self.assertEqual(resolved.from_code, "LYD")
        self.assertEqual(resolved.to_code, "USD")

    def test_a_direct_row_beats_an_invertible_one(self):
        self.add_rate("4")
        self.add_rate("0.30", frm="LYD", to="USD")
        self.assertEqual(rate_on("LYD", "USD").rate, Decimal("0.30"))

    def test_inversion_can_be_refused(self):
        self.add_rate("4")
        self.assertIsNone(rate_on("LYD", "USD", allow_inverse=False))


class StalenessTests(FxTestCase):
    def test_an_old_rate_still_resolves(self):
        self.add_rate("6.10", at=self.now - timedelta(days=9))
        resolved = rate_on("USD", "LYD")
        self.assertIsNotNone(resolved)
        self.assertEqual(resolved.rate, Decimal("6.10"))

    def test_but_reports_itself_as_stale(self):
        self.add_rate("6.10", at=self.now - timedelta(days=9))
        self.assertTrue(rate_on("USD", "LYD").is_stale(24))

    def test_a_fresh_rate_is_not_stale(self):
        self.add_rate("6.85", at=self.now - timedelta(hours=2))
        self.assertFalse(rate_on("USD", "LYD").is_stale(24))

    def test_zero_threshold_disables_the_staleness_notion(self):
        self.add_rate("6.10", at=self.now - timedelta(days=400))
        self.assertFalse(rate_on("USD", "LYD").is_stale(0))

    def test_age_is_reported(self):
        self.add_rate("6.10", at=self.now - timedelta(hours=5))
        age = rate_on("USD", "LYD").age(now=self.now)
        self.assertAlmostEqual(age.total_seconds(), 5 * 3600, delta=5)


class ManualRateTests(FxTestCase):
    def test_a_typed_rate_resolves(self):
        record_manual_rate(from_code="USD", to_code="LYD", rate="7.00")
        resolved = rate_on("USD", "LYD")
        self.assertEqual(resolved.rate, Decimal("7.00000000"))
        self.assertEqual(resolved.source, ref.SOURCE_MANUAL)

    def test_a_newer_typed_rate_beats_an_older_feed_rate(self):
        self.add_rate("6.85", at=self.now - timedelta(hours=2))
        record_manual_rate(
            from_code="USD", to_code="LYD", rate="7.20", effective_at=self.now
        )
        self.assertEqual(rate_on("USD", "LYD").rate, Decimal("7.20000000"))

    def test_a_typed_rate_wins_a_tie_on_the_same_instant(self):
        self.add_rate("6.85", at=self.now)
        record_manual_rate(
            from_code="USD", to_code="LYD", rate="7.20", effective_at=self.now
        )
        resolved = rate_on("USD", "LYD", at=self.now)
        self.assertEqual(resolved.rate, Decimal("7.20000000"))
        self.assertEqual(resolved.source, ref.SOURCE_MANUAL)
        self.assertEqual(ExchangeRate.objects.count(), 1)

    def test_an_older_typed_rate_does_not_beat_a_newer_feed_rate(self):
        # Manual wins ties and outranks nothing else: recency still decides, so
        # a rate typed last month does not freeze the shop's pricing forever.
        record_manual_rate(
            from_code="USD",
            to_code="LYD",
            rate="7.20",
            effective_at=self.now - timedelta(days=30),
        )
        self.add_rate("6.85", at=self.now)
        self.assertEqual(rate_on("USD", "LYD").rate, Decimal("6.85"))

    def test_note_and_author_are_recorded(self):
        row = record_manual_rate(
            from_code="USD", to_code="LYD", rate="7.00", note="  agreed with changer  "
        )
        self.assertEqual(row.note, "agreed with changer")

    def test_manual_bank_rate_keeps_its_bank_code(self):
        row = record_manual_rate(
            from_code="USD",
            to_code="LYD",
            rate="7.05",
            instrument=ref.INSTRUMENT_BANK,
            bank_code="NCB",
        )
        self.assertEqual(row.bank_code, "ncb")


class ConversionEntryPointTests(FxTestCase):
    def test_convert_amount_returns_money_and_the_rate_that_did_it(self):
        self.add_rate("6.85")
        money, resolved = convert_amount("12.00", from_code="USD", to_code="LYD")
        self.assertEqual(money, Money("82.20", "LYD"))
        self.assertEqual(resolved.rate, Decimal("6.85000000"))

    def test_convert_amount_degrades_to_none_when_no_rate_exists(self):
        money, resolved = convert_amount("12.00", from_code="USD", to_code="LYD")
        self.assertIsNone(money)
        self.assertIsNone(resolved)

    def test_apply_uses_the_targets_precision(self):
        self.add_rate("6.85")
        resolved = rate_on("USD", "LYD")
        self.assertEqual(resolved.apply(Money("12.00", "USD")), Money("82.20", "LYD"))

    def test_decimals_for_known_and_unknown_codes(self):
        self.assertEqual(decimals_for("LYD"), 2)
        self.assertEqual(decimals_for("ZZZ"), 2)


class CacheTests(FxTestCase):
    def test_current_rate_reflects_a_write_after_invalidation(self):
        self.add_rate("6.85", at=self.now - timedelta(hours=1))
        self.assertEqual(current_rate("USD", "LYD").rate, Decimal("6.85"))
        record_manual_rate(from_code="USD", to_code="LYD", rate="7.20")
        self.assertEqual(current_rate("USD", "LYD").rate, Decimal("7.20000000"))

    def test_pinning_an_instant_bypasses_the_cache(self):
        old = self.now - timedelta(days=2)
        self.add_rate("6.10", at=old)
        self.add_rate("6.85", at=self.now)
        self.assertEqual(current_rate("USD", "LYD").rate, Decimal("6.85"))
        self.assertEqual(current_rate("USD", "LYD", at=old).rate, Decimal("6.10"))


class RegistryTests(FxTestCase):
    def test_seeding_is_idempotent(self):
        before = Currency.objects.count()
        ensure_builtin_currencies()
        self.assertEqual(Currency.objects.count(), before)

    def test_every_fulus_pair_is_seeded(self):
        for code in ("LYD", "USD", "EUR", "GBP", "TRY", "EGP", "TND", "SAR", "AED"):
            self.assertTrue(Currency.objects.filter(pk=code).exists(), code)

    def test_seeding_does_not_re_enable_a_currency_the_shop_hid(self):
        Currency.objects.filter(pk="SAR").update(is_enabled=False)
        ensure_builtin_currencies()
        self.assertFalse(Currency.objects.get(pk="SAR").is_enabled)

    def test_seeding_refreshes_display_fields(self):
        Currency.objects.filter(pk="USD").update(symbol_ar="XX")
        ensure_builtin_currencies()
        self.assertEqual(Currency.objects.get(pk="USD").symbol_ar, "$")

    def test_the_dinar_carries_two_places_not_iso_three(self):
        self.assertEqual(Currency.objects.get(pk="LYD").decimals, 2)
        self.assertEqual(Currency.objects.get(pk="TND").decimals, 2)

    def test_codes_are_normalized_on_save(self):
        Currency.objects.create(code=" chf ", name_en="Franc", name_ar="فرنك")
        self.assertTrue(Currency.objects.filter(pk="CHF").exists())
