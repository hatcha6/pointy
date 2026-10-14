"""The assistant-written opening suggestions."""

import json
from unittest.mock import patch

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group
from django.core.cache import cache
from django.test import TestCase
from django.urls import reverse
from rest_framework.test import APIClient

from apps.core.models import RelayInstallation
from apps.core.roles import CASHIER_GROUP, MANAGER_GROUP, ensure_role_groups

from .memory import remember
from .suggestions import parse_suggestions
from .tests import FakeRelayResponse, fake_sse_lines

User = get_user_model()

REPLY = json.dumps(
    {
        "suggestions": [
            {"title": "لماذا تراجعت القهوة الثلاثاء؟", "prompt": "حلّل تراجع القهوة يوم الثلاثاء", "icon": "sales"},
            {"title": "اطلب من بُن اليمن قبل الثلاثاء", "prompt": "جهّز طلب شراء لبُن اليمن", "icon": "purchasing"},
            {"title": "عرض للعملاء المتأخرين", "icon": "weird"},
            {"title": ""},
        ]
    },
    ensure_ascii=False,
)


class ParseSuggestionsTests(TestCase):
    def test_sanitises_the_models_json(self):
        parsed = parse_suggestions("```json\n" + REPLY + "\n```")
        self.assertEqual(len(parsed), 3)
        self.assertEqual(parsed[2]["icon"], "idea")  # unknown icon falls back
        self.assertEqual(parsed[2]["prompt"], parsed[2]["title"])  # prompt defaults to title

    def test_too_little_is_no_answer(self):
        self.assertIsNone(parse_suggestions('{"suggestions": [{"title": "x"}]}'))
        self.assertIsNone(parse_suggestions("لا أستطيع"))


class SuggestionsViewTests(TestCase):
    def setUp(self):
        cache.clear()
        ensure_role_groups()
        self.manager = User.objects.create_user(username="sug-manager", password="pw")
        self.manager.groups.add(Group.objects.get(name=MANAGER_GROUP))
        self.cashier = User.objects.create_user(username="sug-cashier", password="pw")
        self.cashier.groups.add(Group.objects.get(name=CASHIER_GROUP))
        RelayInstallation.objects.create(
            installation_id="inst-sug",
            access_token="ptr1.inst-sug.secret",
            relay_enabled=False,
            subscription_active=True,
            ai_enabled=True,
        )
        remember(user=self.manager, content="مورّد بُن اليمن يورّد كل ثلاثاء")

    def _get(self, user, lines):
        client = APIClient()
        client.force_authenticate(user)
        with patch("apps.ai.views.scoped_relay_client") as mock_client:
            mock_client.return_value.open_ai_stream.return_value = FakeRelayResponse(lines)
            response = client.get(reverse("ai-suggestions"))
            return response, mock_client.return_value.open_ai_stream

    def test_generates_from_memory_unmetered_and_caches(self):
        response, stream = self._get(self.manager, fake_sse_lines([REPLY], reasoning=""))
        self.assertEqual(response.status_code, 200)
        self.assertEqual(len(response.json()["suggestions"]), 3)
        kwargs = stream.call_args.kwargs
        self.assertFalse(kwargs["count_usage"])
        self.assertIn("بُن اليمن", kwargs["messages"][1]["content"])
        # Cached: a second open makes no relay call.
        response, stream = self._get(self.manager, fake_sse_lines([REPLY], reasoning=""))
        self.assertEqual(len(response.json()["suggestions"]), 3)
        stream.assert_not_called()

    def test_a_cashier_is_told_to_stay_off_profit(self):
        _, stream = self._get(self.cashier, fake_sse_lines([REPLY], reasoning=""))
        self.assertIn("لا يرى التكاليف والأرباح", stream.call_args.kwargs["messages"][0]["content"])

    def test_bad_output_is_empty_and_not_cached(self):
        response, _ = self._get(self.manager, fake_sse_lines(["عذرًا"], reasoning=""))
        self.assertEqual(response.json(), {"suggestions": []})
        response, stream = self._get(self.manager, fake_sse_lines([REPLY], reasoning=""))
        stream.assert_called_once()
        self.assertEqual(len(response.json()["suggestions"]), 3)
