import json
from types import SimpleNamespace
from unittest.mock import patch

from django.contrib.auth import get_user_model
from django.core.cache import cache
from django.test import TestCase
from django.urls import reverse
from rest_framework.test import APIClient

from apps.core.models import RelayInstallation

from .dashboard_digest import (
    DIGEST_EXPLAINER_KEYS,
    _parse_digest,
    compact_figures,
    generate_dashboard_digest,
)
from .tests import FakeRelayResponse, fake_sse_lines


def _sections():
    return {
        "sales": {
            "summary": {
                "net_sales": "1000.00",
                "net_sales_change_percent": "-12.00",
                "order_count": 40,
                "average_order_value": "25.00",
                "gross_profit": "300.00",
                "profit_margin_percent": "30.00",
                "refund_total": "0",
            },
            "registers": {"variance_count": 2, "variance_total": "15.00"},
            "top_products": [{"product_name": "قهوة", "quantity": 30, "profit": "120.00"}],
            "top_categories": [{"category_name": "مشروبات", "revenue": "500.00"}],
        },
        "inventory": {
            "summary": {"low_stock_count": 7, "out_of_stock_count": 1, "retail_stock_value": "2000"},
            "low_stock_items": [{"product_name": "سكر"}, {"product_name": "حليب"}],
            "dusty_items": [{"product_name": "علبة قديمة"}],
        },
    }


class CompactFiguresTests(TestCase):
    def test_extracts_only_meaningful_numbers(self):
        figures = compact_figures(_sections(), 30)
        self.assertEqual(figures["period_days"], 30)
        self.assertEqual(figures["sales"]["net_sales"], 1000.0)
        self.assertEqual(figures["sales"]["net_sales_change_percent"], -12.0)
        self.assertEqual(figures["registers"]["variance_count"], 2)
        self.assertEqual(figures["inventory"]["low_stock_count"], 7)
        self.assertEqual(figures["inventory"]["dead_stock_count"], 1)

    def test_empty_sections_yield_no_figures(self):
        self.assertEqual(compact_figures({}, 30), {})
        # A sales section with zero variance omits the registers key entirely.
        figures = compact_figures(
            {"sales": {"summary": {"net_sales": "0"}, "registers": {"variance_count": 0}}},
            30,
        )
        self.assertNotIn("registers", figures)


class ParseDigestTests(TestCase):
    def test_parses_fenced_json_and_filters_unknown_keys(self):
        text = (
            "```json\n"
            '{"brief": "  أداء جيد  ", '
            '"explainers": {"low_stock": "أعد الطلب", "bogus_key": "تُتجاهل"}}\n'
            "```"
        )
        digest = _parse_digest(text)
        self.assertEqual(digest["brief"], "أداء جيد")
        self.assertEqual(digest["explainers"], {"low_stock": "أعد الطلب"})
        self.assertTrue(set(digest["explainers"]).issubset(set(DIGEST_EXPLAINER_KEYS)))

    def test_returns_none_for_unusable_text(self):
        self.assertIsNone(_parse_digest("no json here"))
        self.assertIsNone(_parse_digest('{"brief": "", "explainers": {}}'))


class GenerateDigestTests(TestCase):
    def test_one_non_metered_call_returns_parsed_digest(self):
        lines = fake_sse_lines(
            ['{"brief": "مبيعاتك تراجعت ١٢٪", ', '"explainers": {"low_stock": "٧ أصناف أوشكت"}}']
        )
        client = SimpleNamespace(calls=[])

        def open_ai_stream(**kwargs):
            client.calls.append(kwargs)
            return FakeRelayResponse(lines)

        client.open_ai_stream = open_ai_stream
        installation = SimpleNamespace(access_token="ptr1.inst.secret")

        digest = generate_dashboard_digest(installation, _sections(), 30, client=client)

        self.assertEqual(digest["brief"], "مبيعاتك تراجعت ١٢٪")
        self.assertEqual(digest["explainers"], {"low_stock": "٧ أصناف أوشكت"})
        self.assertIn("generated_at", digest)
        # Exactly one call, and it must NOT charge the shop's chat quota.
        self.assertEqual(len(client.calls), 1)
        self.assertFalse(client.calls[0]["count_usage"])
        self.assertEqual(client.calls[0]["access_token"], "ptr1.inst.secret")

    def test_no_figures_skips_the_relay_entirely(self):
        client = SimpleNamespace(open_ai_stream=lambda **k: 1 / 0)  # would explode if called
        installation = SimpleNamespace(access_token="x")
        self.assertIsNone(generate_dashboard_digest(installation, {}, 30, client=client))


class DashboardAiDigestViewTests(TestCase):
    def setUp(self):
        # The digest is cached per user+period+day; clear it so one test's cached
        # result can't leak into the next (the cache outlives a TestCase).
        cache.clear()
        self.addCleanup(cache.clear)
        self.user = get_user_model().objects.create_user(
            username="manager", password="pw-12345!"
        )
        self.client = APIClient()
        self.client.force_authenticate(self.user)
        self.installation = RelayInstallation.objects.create(
            installation_id="inst-1",
            access_token="ptr1.inst-1.secret",
            relay_enabled=False,
            subscription_active=True,
            ai_enabled=True,
        )

    def test_403_when_ai_unavailable(self):
        RelayInstallation.objects.update(ai_enabled=False)
        response = self.client.get(reverse("ai-dashboard-digest"))
        self.assertEqual(response.status_code, 403)

    def test_returns_generated_digest(self):
        lines = fake_sse_lines(['{"brief": "ملخص اليوم", "explainers": {"low_stock": "أعد الطلب"}}'])
        with patch("apps.ai.views.build_dashboard_snapshot") as snapshot, patch(
            "apps.ai.dashboard_digest.RelayControlClient"
        ) as relay:
            snapshot.return_value = {"period": {"days": 30}, "sections": _sections()}
            relay.return_value.open_ai_stream.return_value = FakeRelayResponse(lines)
            response = self.client.get(reverse("ai-dashboard-digest"))

        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.data["brief"], "ملخص اليوم")
        self.assertEqual(response.data["explainers"], {"low_stock": "أعد الطلب"})

    def test_caches_per_day_so_the_relay_runs_once(self):
        lines = fake_sse_lines(['{"brief": "ملخص", "explainers": {"low_stock": "أعد الطلب"}}'])
        with patch("apps.ai.views.build_dashboard_snapshot") as snapshot, patch(
            "apps.ai.dashboard_digest.RelayControlClient"
        ) as relay:
            snapshot.return_value = {"period": {"days": 30}, "sections": _sections()}
            relay.return_value.open_ai_stream.return_value = FakeRelayResponse(lines)
            first = self.client.get(reverse("ai-dashboard-digest"))
            # Second call (same user + period + day) must serve from cache.
            relay.return_value.open_ai_stream.return_value = FakeRelayResponse(lines)
            second = self.client.get(reverse("ai-dashboard-digest"))

        self.assertEqual(first.data["brief"], second.data["brief"])
        relay.return_value.open_ai_stream.assert_called_once()

    def test_empty_when_no_sections(self):
        with patch("apps.ai.views.build_dashboard_snapshot") as snapshot:
            snapshot.return_value = {"period": {"days": 30}, "sections": {}}
            response = self.client.get(reverse("ai-dashboard-digest"))
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.data["brief"], "")
        self.assertEqual(response.data["explainers"], {})

    def test_snapshot_failure_degrades_to_the_empty_digest(self):
        # The digest is an optional dashboard widget. A failing section aggregate
        # (the snapshot build) must never 500 the whole dashboard load — it
        # degrades to an empty digest so the client simply shows nothing.
        with patch("apps.ai.views.build_dashboard_snapshot") as snapshot:
            snapshot.side_effect = RuntimeError("a section aggregate blew up")
            response = self.client.get(reverse("ai-dashboard-digest"))
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.data["brief"], "")
        self.assertEqual(response.data["explainers"], {})

    def test_generation_failure_degrades_to_the_empty_digest(self):
        with patch("apps.ai.views.build_dashboard_snapshot") as snapshot, patch(
            "apps.ai.views.generate_dashboard_digest"
        ) as generate:
            snapshot.return_value = {"period": {"days": 30}, "sections": _sections()}
            generate.side_effect = RuntimeError("relay generation blew up")
            response = self.client.get(reverse("ai-dashboard-digest"))
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.data["brief"], "")
        self.assertEqual(response.data["explainers"], {})
