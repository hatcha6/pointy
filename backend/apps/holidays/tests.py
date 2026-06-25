"""Tests for the holidays / special-events calendar.

The rule-engine tests are pure (no DB) and carry the edge-case weight; the
service/sync/tagging tests exercise the seed, the cache, the dashboard payload,
relay reconciliation, and the snapshot written onto real sales and purchases.
"""

from datetime import date, datetime
from datetime import timezone as dt_timezone
from decimal import Decimal
from unittest import mock

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group
from django.test import SimpleTestCase, TestCase, override_settings

from apps.catalog.testing import create_product_with_default_variant
from apps.core.models import RelayInstallation
from apps.core.roles import CASHIER_GROUP, ensure_role_groups
from apps.core.timeutils import business_local_date
from apps.holidays import rules, services
from apps.holidays.models import Holiday
from apps.inventory.models import StockItem
from apps.sales.models import RegisterSession
from apps.sales.services import checkout_order


def _fixed(key, month, day, *, span_days=1, category=rules.CATEGORY_NATIONAL,
           show_in_dashboard=True):
    return rules.Definition(
        key=key, name_en=key, name_ar=key, category=category,
        rule_type=rules.RULE_FIXED, month=month, day=day, span_days=span_days,
        show_in_dashboard=show_in_dashboard,
    )


def _keys(target, definitions):
    return [occ.key for occ in rules.special_days_for_date(target, definitions)]


class RuleEngineTests(SimpleTestCase):
    def test_fixed_single_day(self):
        defs = [_fixed("new_year", 1, 1)]
        self.assertEqual(_keys(date(2026, 1, 1), defs), ["new_year"])
        self.assertEqual(_keys(date(2026, 1, 2), defs), [])

    def test_fixed_recurs_every_year(self):
        defs = [_fixed("new_year", 1, 1)]
        for year in (2020, 2024, 2030):
            self.assertEqual(_keys(date(year, 1, 1), defs), ["new_year"])

    def test_multi_day_span_within_month(self):
        defs = [_fixed("festival", 3, 10, span_days=3)]  # 10,11,12
        self.assertEqual(_keys(date(2026, 3, 10), defs), ["festival"])
        self.assertEqual(_keys(date(2026, 3, 12), defs), ["festival"])
        self.assertEqual(_keys(date(2026, 3, 13), defs), [])

    def test_span_crossing_month_boundary(self):
        defs = [_fixed("bridge", 10, 30, span_days=4)]  # Oct30..Nov2
        self.assertEqual(_keys(date(2026, 11, 1), defs), ["bridge"])
        self.assertEqual(_keys(date(2026, 11, 2), defs), ["bridge"])
        self.assertEqual(_keys(date(2026, 11, 3), defs), [])

    def test_span_crossing_year_boundary(self):
        # A Dec-31 span-3 event must still match Jan 1-2 of the next year.
        defs = [_fixed("newyears_eve", 12, 31, span_days=3)]  # Dec31..Jan2
        self.assertEqual(_keys(date(2027, 1, 1), defs), ["newyears_eve"])
        self.assertEqual(_keys(date(2027, 1, 2), defs), ["newyears_eve"])
        self.assertEqual(_keys(date(2027, 1, 3), defs), [])
        self.assertEqual(_keys(date(2026, 12, 31), defs), ["newyears_eve"])

    def test_leap_day_only_in_leap_years(self):
        defs = [_fixed("leapling", 2, 29)]
        self.assertEqual(_keys(date(2024, 2, 29), defs), ["leapling"])  # leap year
        self.assertEqual(_keys(date(2025, 2, 28), defs), [])
        self.assertEqual(_keys(date(2025, 3, 1), defs), [])
        # 2023 is not a leap year — the anchor is invalid and simply skipped.
        self.assertEqual(_keys(date(2023, 2, 28), defs), [])

    def test_last_friday_of_november(self):
        defs = rules.builtin_definitions()
        self.assertEqual(_keys(date(2026, 11, 27), defs), ["white_friday"])  # last Fri 2026
        self.assertEqual(_keys(date(2025, 11, 28), defs), ["white_friday"])  # last Fri 2025
        self.assertEqual(_keys(date(2024, 11, 29), defs), ["white_friday"])  # last Fri 2024
        self.assertEqual(_keys(date(2026, 11, 20), defs), [])  # an earlier Friday

    def test_nth_weekday_ordinals(self):
        # 2nd Tuesday of June 2026 == June 9.
        d = rules.Definition(
            key="second_tue", name_en="x", name_ar="x",
            category=rules.CATEGORY_LOCAL, rule_type=rules.RULE_NTH_WEEKDAY,
            month=6, weekday=rules.TUESDAY, week_ordinal=2,
        )
        self.assertEqual(_keys(date(2026, 6, 9), [d]), ["second_tue"])
        self.assertEqual(_keys(date(2026, 6, 2), [d]), [])

    def test_nth_weekday_fifth_occurrence_absent_is_skipped(self):
        # June 2026 starts on a Monday: its Thursdays are 4, 11, 18, 25 — only
        # four — so a "5th Thursday of June" rule must never fire.
        d = rules.Definition(
            key="fifth_thu", name_en="x", name_ar="x",
            category=rules.CATEGORY_LOCAL, rule_type=rules.RULE_NTH_WEEKDAY,
            month=6, weekday=rules.THURSDAY, week_ordinal=5,
        )
        for day in range(1, 31):
            self.assertEqual(_keys(date(2026, 6, day), [d]), [])

    def test_nth_weekday_offset_days(self):
        # The day after the last Friday of November 2026 (Nov 27) is Nov 28.
        d = rules.Definition(
            key="wf_saturday", name_en="x", name_ar="x",
            category=rules.CATEGORY_COMMERCIAL, rule_type=rules.RULE_NTH_WEEKDAY,
            month=11, weekday=rules.FRIDAY, week_ordinal=rules.ORDINAL_LAST,
            offset_days=1,
        )
        self.assertEqual(_keys(date(2026, 11, 28), [d]), ["wf_saturday"])
        self.assertEqual(_keys(date(2026, 11, 27), [d]), [])

    def test_range_multi_day(self):
        d = rules.Definition(
            key="eid_fitr_2026", name_en="x", name_ar="x",
            category=rules.CATEGORY_RELIGIOUS, rule_type=rules.RULE_RANGE,
            start_date=date(2026, 3, 20), end_date=date(2026, 3, 22),
        )
        self.assertEqual(_keys(date(2026, 3, 20), [d]), ["eid_fitr_2026"])
        self.assertEqual(_keys(date(2026, 3, 22), [d]), ["eid_fitr_2026"])
        self.assertEqual(_keys(date(2026, 3, 23), [d]), [])
        self.assertEqual(_keys(date(2025, 3, 21), [d]), [])  # only that year

    def test_dec_24_carries_two_names_deterministically(self):
        defs = rules.builtin_definitions()
        # national (independence_day) sorts before religious (christmas_eve).
        self.assertEqual(
            _keys(date(2026, 12, 24), defs),
            ["independence_day", "christmas_eve"],
        )

    def test_duplicate_definitions_are_deduped_by_key(self):
        d = _fixed("new_year", 1, 1)
        self.assertEqual(_keys(date(2026, 1, 1), [d, d]), ["new_year"])

    def test_empty_definitions(self):
        self.assertEqual(_keys(date(2026, 1, 1), []), [])

    def test_inactive_window_returns_empty(self):
        self.assertEqual(_keys(date(2026, 4, 3), rules.builtin_definitions()), [])


class BusinessLocalDateTests(SimpleTestCase):
    @override_settings(POINTY_BUSINESS_TIMEZONE="Africa/Tripoli")
    def test_late_utc_sale_rolls_into_next_local_day(self):
        # 23:30 UTC on Dec 31 is 01:30 on Jan 1 in Tripoli (UTC+2) — a New-Year
        # sale, which is the whole point of business-local tagging.
        moment = datetime(2025, 12, 31, 23, 30, tzinfo=dt_timezone.utc)
        self.assertEqual(business_local_date(moment), date(2026, 1, 1))

    @override_settings(POINTY_BUSINESS_TIMEZONE="not/a-zone")
    def test_invalid_timezone_falls_back_to_tripoli(self):
        moment = datetime(2025, 12, 31, 23, 30, tzinfo=dt_timezone.utc)
        self.assertEqual(business_local_date(moment), date(2026, 1, 1))


class SeedAndCacheTests(TestCase):
    def setUp(self):
        services.invalidate_definitions_cache()

    def test_builtins_are_seeded_by_migration(self):
        self.assertEqual(Holiday.objects.count(), len(rules.BUILTIN_HOLIDAYS))
        self.assertTrue(Holiday.objects.filter(key="white_friday").exists())
        valentine = Holiday.objects.get(key="valentines_day")
        self.assertFalse(valentine.show_in_dashboard)

    def test_ensure_builtin_holidays_is_idempotent(self):
        before = Holiday.objects.count()
        services.ensure_builtin_holidays()
        self.assertEqual(Holiday.objects.count(), before)

    def test_dashboard_hides_valentines_but_tagging_keeps_it(self):
        # Tagging includes Valentine's; the dashboard payload excludes it.
        self.assertIn("valentines_day", services.special_day_keys_for(date(2026, 2, 14)))
        self.assertEqual(services.today_dashboard_special_days(date(2026, 2, 14)), [])

    def test_dashboard_payload_shape_and_order(self):
        payload = services.today_dashboard_special_days(date(2026, 12, 24))
        self.assertEqual([row["key"] for row in payload],
                         ["independence_day", "christmas_eve"])
        self.assertEqual(set(payload[0]), {"key", "name_en", "name_ar", "category"})

    def test_special_day_keys_for_defensive_fallback(self):
        with mock.patch.object(services, "get_active_definitions",
                               side_effect=RuntimeError("boom")):
            self.assertEqual(services.special_day_keys_for(date(2026, 1, 1)), [])

    def test_cache_refreshes_after_invalidate(self):
        services.get_active_definitions(force_refresh=True)
        Holiday.objects.create(
            key="custom_event", name_en="Custom", name_ar="مخصص",
            category=rules.CATEGORY_LOCAL, rule_type=rules.RULE_FIXED,
            month=4, day=3, source=rules.SOURCE_LOCAL,
        )
        # Stale cache still doesn't know about it...
        self.assertEqual(services.special_day_keys_for(date(2026, 4, 3)), [])
        services.invalidate_definitions_cache()
        self.assertEqual(services.special_day_keys_for(date(2026, 4, 3)), ["custom_event"])


class _FakeRelayClient:
    def __init__(self, payload=None, error=None):
        self._payload = payload or {}
        self._error = error
        self.calls = 0

    def get_holidays(self, *, access_token):
        self.calls += 1
        if self._error is not None:
            raise self._error
        return self._payload


class SyncHolidaysTests(TestCase):
    def setUp(self):
        services.invalidate_definitions_cache()
        RelayInstallation.objects.create(
            installation_id="inst-1",
            relay_public_api_url="https://relay.example/api/",
            connector_token="c",
            access_token="tok-123",
        )

    def test_sync_skipped_without_installation(self):
        RelayInstallation.objects.all().delete()
        result = services.sync_holidays(client=_FakeRelayClient())
        self.assertTrue(result.get("skipped"))

    def test_sync_inserts_relay_range_holiday(self):
        client = _FakeRelayClient({"holidays": [{
            "id": "r1", "key": "eid_fitr_2026", "name_en": "Eid al-Fitr",
            "name_ar": "عيد الفطر", "category": "religious", "rule_type": "range",
            "start_date": "2026-03-20", "end_date": "2026-03-22",
        }]})
        result = services.sync_holidays(client=client)
        self.assertEqual(result["synced"], 1)
        eid = Holiday.objects.get(key="eid_fitr_2026")
        self.assertEqual(eid.source, rules.SOURCE_RELAY)
        self.assertEqual(eid.relay_id, "r1")
        # Mar 20 is inside the Eid range and not a built-in day (Mar 21 is also
        # Mother's Day, which would correctly add a second key).
        self.assertEqual(services.special_day_keys_for(date(2026, 3, 20)), ["eid_fitr_2026"])

    def test_relay_authoritative_for_builtin_but_stays_builtin(self):
        client = _FakeRelayClient({"holidays": [{
            "key": "new_year", "name_en": "NYE renamed", "name_ar": "س",
            "category": "national", "rule_type": "fixed", "month": 1, "day": 1,
        }]})
        services.sync_holidays(client=client)
        new_year = Holiday.objects.get(key="new_year")
        self.assertEqual(new_year.name_en, "NYE renamed")  # relay corrected fields
        self.assertEqual(new_year.source, rules.SOURCE_BUILTIN)  # but never demoted

    def test_vanished_relay_rows_deactivate_builtins_survive(self):
        # First sync brings a relay-only event...
        services.sync_holidays(client=_FakeRelayClient({"holidays": [{
            "key": "local_fair", "name_en": "Fair", "name_ar": "س",
            "category": "local", "rule_type": "fixed", "month": 4, "day": 3,
        }]}))
        self.assertTrue(Holiday.objects.get(key="local_fair").active)
        # ...a later sync no longer lists it (but does list a builtin).
        services.sync_holidays(client=_FakeRelayClient({"holidays": [{
            "key": "new_year", "name_en": "New Year's Day", "name_ar": "س",
            "category": "national", "rule_type": "fixed", "month": 1, "day": 1,
        }]}))
        self.assertFalse(Holiday.objects.get(key="local_fair").active)  # deactivated
        self.assertTrue(Holiday.objects.get(key="new_year").active)  # builtin survives

    def test_unreachable_relay_is_soft_noop(self):
        from apps.core.relay import RelayControlError
        before = Holiday.objects.count()
        result = services.sync_holidays(
            client=_FakeRelayClient(error=RelayControlError("down"))
        )
        self.assertIn("error", result)
        self.assertEqual(Holiday.objects.count(), before)  # built-ins untouched


class TaggingTests(TestCase):
    def setUp(self):
        services.invalidate_definitions_cache()
        ensure_role_groups()
        self.user = get_user_model().objects.create_user(
            username="tagging-cashier", password="pass"
        )
        self.user.groups.add(Group.objects.get(name=CASHIER_GROUP))
        self.session = RegisterSession.objects.create(
            owner=self.user, owner_key=f"user:{self.user.pk}"
        )
        # Make "today" (shop-local) a special day so a fresh sale gets tagged.
        self.today = business_local_date()
        Holiday.objects.create(
            key="today_event", name_en="Today", name_ar="اليوم",
            category=rules.CATEGORY_LOCAL, rule_type=rules.RULE_RANGE,
            start_date=self.today, end_date=self.today, source=rules.SOURCE_LOCAL,
        )
        services.invalidate_definitions_cache()

    def _product(self, sku):
        product = create_product_with_default_variant(
            name=sku, sku=sku, unit_price="2.00", barcode=""
        )
        StockItem.objects.create(variant=product.default_variant, quantity_on_hand=Decimal("10"))
        return product.default_variant

    def test_sale_is_tagged_with_todays_special_day(self):
        variant = self._product("COLA")
        order = checkout_order(
            register_session=self.session,
            lines_data=[{"variant": variant, "quantity": Decimal("1")}],
            payments_data=[{"method": "cash", "amount": Decimal("2.00")}],
            request=None,
        )
        self.assertIn("today_event", order.special_day_keys)

    def test_sale_completes_even_if_definitions_load_fails(self):
        # A holidays failure must never roll back a paid sale: the defensive
        # helper swallows the error and the sale is simply tagged with [].
        variant = self._product("MILK")
        with mock.patch.object(
            services, "get_active_definitions", side_effect=RuntimeError("boom")
        ):
            order = checkout_order(
                register_session=self.session,
                lines_data=[{"variant": variant, "quantity": Decimal("1")}],
                payments_data=[{"method": "cash", "amount": Decimal("2.00")}],
                request=None,
            )
        self.assertEqual(order.special_day_keys, [])
        self.assertEqual(order.status, order.Status.PAID)

    def test_purchase_order_is_tagged_on_creation(self):
        from apps.purchasing.models import PurchaseOrder, Supplier
        from apps.purchasing.services import save_purchase_order_with_lines

        supplier = Supplier.objects.create(name="ACME")
        po = save_purchase_order_with_lines(supplier=supplier)
        self.assertIn("today_event", po.special_day_keys)
        self.assertEqual(PurchaseOrder.objects.get(pk=po.pk).special_day_keys,
                         po.special_day_keys)

    def test_backfill_retags_existing_rows_from_creation_date(self):
        from django.core.management import call_command

        from apps.sales.models import Order

        variant = self._product("BF")
        order = checkout_order(
            register_session=self.session,
            lines_data=[{"variant": variant, "quantity": Decimal("1")}],
            payments_data=[{"method": "cash", "amount": Decimal("2.00")}],
            request=None,
        )
        # Simulate a historical, untagged sale rung up on New Year's Day.
        Order.objects.filter(pk=order.pk).update(
            created_at=datetime(2026, 1, 1, 9, 0, tzinfo=dt_timezone.utc),
            special_day_keys=[],
        )
        call_command("backfill_special_days", verbosity=0)
        order.refresh_from_db()
        self.assertEqual(order.special_day_keys, ["new_year"])

        # Idempotent: a second run leaves the now-tagged row unchanged.
        call_command("backfill_special_days", verbosity=0)
        order.refresh_from_db()
        self.assertEqual(order.special_day_keys, ["new_year"])
