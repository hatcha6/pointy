import asyncio
import json
import warnings
from decimal import Decimal
from unittest.mock import patch

from django.contrib.auth import get_user_model
from django.test import AsyncRequestFactory, TestCase, TransactionTestCase
from django.urls import reverse
from rest_framework.test import APIClient, force_authenticate

from apps.core.models import RelayInstallation
from apps.core.relay import RelayControlError, relay_ai_available

from .models import AiConversation, AiMessage
from .relay_stream import iter_relay_sse
from .tools import validate_ask_user_spec
from .views import MAX_TOOL_ITERS, AiChatView


class FakeRelayResponse:
    """Mimics the relay's streaming SSE response: line-iterable + close()."""

    def __init__(self, lines):
        self._lines = lines
        self.closed = False

    def __iter__(self):
        return iter(self._lines)

    def close(self):
        self.closed = True


def fake_sse_lines(
    text_chunks, *, model="test/model", tier="smart", reasoning="thinking", title=None,
    web_search=False, sources=None,
):
    lines = []
    if reasoning:
        lines.append(b"event: reasoning\n")
        lines.append(("data: " + json.dumps({"text": reasoning}) + "\n").encode("utf-8"))
        lines.append(b"\n")
    for chunk in text_chunks:
        lines.append(b"event: delta\n")
        lines.append(("data: " + json.dumps({"text": chunk}) + "\n").encode("utf-8"))
        lines.append(b"\n")
    done = {
        "model": model,
        "tier": tier,
        "usage": {"prompt_tokens": 3, "completion_tokens": 2, "total_tokens": 5},
    }
    if title is not None:
        done["title"] = title
    if web_search:
        done["web_search"] = True
    if sources is not None:
        done["sources"] = sources
    lines.append(b"event: done\n")
    lines.append(("data: " + json.dumps(done) + "\n").encode("utf-8"))
    lines.append(b"\n")
    return lines


def fake_tool_call_sse(
    name="query_resource", arguments='{"resource":"orders"}', route_tier="smart", web_search=False
):
    """A relay turn that asks for one tool call, then done(finish=tool_calls)."""
    tool_calls = [
        {
            "id": "call_1",
            "type": "function",
            "function": {"name": name, "arguments": arguments},
        }
    ]
    done = {"model": "m", "tier": route_tier, "route_tier": route_tier, "finish_reason": "tool_calls"}
    if web_search:
        done["web_search"] = True
    return [
        b"event: tool_calls\n",
        ("data: " + json.dumps({"tool_calls": tool_calls}) + "\n").encode("utf-8"),
        b"\n",
        b"event: done\n",
        ("data: " + json.dumps(done) + "\n").encode("utf-8"),
        b"\n",
    ]


class RelaySseParserTests(TestCase):
    def test_parses_delta_and_done_events(self):
        events = list(iter_relay_sse(fake_sse_lines(["hi"], reasoning="")))
        self.assertEqual(events[0], {"event": "delta", "data": {"text": "hi"}})
        self.assertEqual(events[-1]["event"], "done")
        self.assertEqual(events[-1]["data"]["usage"]["total_tokens"], 5)

    def test_ignores_keep_alive_comments(self):
        lines = [b": ping\n", b"event: delta\n", b'data: {"text": "x"}\n', b"\n"]
        events = list(iter_relay_sse(lines))
        self.assertEqual(events, [{"event": "delta", "data": {"text": "x"}}])


class RelayAiAvailableTests(TestCase):
    def test_requires_flag_and_active_subscription(self):
        installation = RelayInstallation.objects.create(
            installation_id="inst-ai",
            access_token="ptr1.inst-ai.secret",
            subscription_active=True,
            ai_enabled=True,
        )
        self.assertTrue(relay_ai_available(installation))

        installation.ai_enabled = False
        self.assertFalse(relay_ai_available(installation))

        installation.ai_enabled = True
        installation.subscription_active = False
        self.assertFalse(relay_ai_available(installation))


class _FakeHttpResponse:
    """Stand-in for urllib's response (context manager + read + headers)."""

    def __init__(self, content, content_type):
        self._content = content
        self.headers = {"Content-Type": content_type}

    def __enter__(self):
        return self

    def __exit__(self, *args):
        return False

    def read(self, _n=-1):
        return self._content


class AiFaviconViewTests(TestCase):
    """The same-origin favicon proxy for web-search source avatars."""

    def setUp(self):
        self.client = APIClient()  # unauthenticated on purpose (AllowAny)

    def test_rejects_a_non_hostname_domain(self):
        response = self.client.get(reverse("ai-favicon"), {"domain": "bad host/../x"})
        self.assertEqual(response.status_code, 400)

    def test_proxies_a_favicon_image(self):
        png = b"\x89PNG\r\n\x1a\nfake-bytes"
        with patch("apps.ai.views.urllib.request.urlopen") as mock_open:
            mock_open.return_value = _FakeHttpResponse(png, "image/png")
            response = self.client.get(reverse("ai-favicon"), {"domain": "reuters.com"})
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response["Content-Type"], "image/png")
        self.assertIn("max-age", response["Cache-Control"])
        self.assertEqual(response.content, png)
        # SSRF guard: we fetch Google's favicon endpoint, never the host directly.
        self.assertIn("gstatic.com/faviconV2", mock_open.call_args.args[0].full_url)

    def test_returns_404_when_the_fetch_fails(self):
        with patch("apps.ai.views.urllib.request.urlopen", side_effect=OSError("boom")):
            response = self.client.get(reverse("ai-favicon"), {"domain": "reuters.com"})
        self.assertEqual(response.status_code, 404)

    def test_persisted_sources_serialize_with_a_proxy_favicon_url(self):
        from rest_framework.test import APIRequestFactory

        from .serializers import AiMessageSerializer

        user = get_user_model().objects.create_user(username="src", password="pw-12345!")
        conversation = AiConversation.objects.create(user=user)
        message = AiMessage.objects.create(
            conversation=conversation,
            role=AiMessage.ROLE_ASSISTANT,
            content="السعر ارتفع",
            sources=[{"url": "https://reuters.com/a", "title": "Reuters"}],
            web_searched=True,
        )
        request = APIRequestFactory().get("/")
        data = AiMessageSerializer(message, context={"request": request}).data
        self.assertTrue(data["web_searched"])
        self.assertEqual(len(data["sources"]), 1)
        self.assertIn("ai/favicon/", data["sources"][0]["favicon"])
        self.assertIn("domain=reuters.com", data["sources"][0]["favicon"])


class AiChatViewTests(TestCase):
    def setUp(self):
        user_model = get_user_model()
        self.user = user_model.objects.create_user(username="cashier", password="pw-12345!")
        self.client = APIClient()
        self.client.force_authenticate(self.user)
        self.installation = RelayInstallation.objects.create(
            installation_id="inst-1",
            access_token="ptr1.inst-1.secret",
            relay_enabled=False,
            subscription_active=True,
            ai_enabled=True,
        )

    def test_streams_reply_and_persists_messages(self):
        lines = fake_sse_lines(["Hel", "lo"])
        with patch("apps.ai.views.RelayControlClient") as mock_client:
            mock_client.return_value.open_ai_stream.return_value = FakeRelayResponse(lines)
            response = self.client.post(
                reverse("ai-chat"),
                {"message": "مرحبا"},
                format="json",
            )
            self.assertEqual(response.status_code, 200)
            self.assertEqual(response["Content-Type"], "text/event-stream")
            body = b"".join(response.streaming_content).decode("utf-8")

        self.assertIn("event: delta", body)
        self.assertIn('"text": "Hel"', body)
        self.assertIn("event: done", body)
        self.assertIn('"conversation_id"', body)
        # The relay's resolved tier and the model's reasoning are forwarded.
        self.assertIn('"tier": "smart"', body)
        self.assertIn("event: reasoning", body)
        self.assertIn('"text": "thinking"', body)

        # The backend never sends a tier; the relay always auto-routes.
        _, kwargs = mock_client.return_value.open_ai_stream.call_args
        self.assertNotIn("tier", kwargs)
        self.assertEqual(kwargs["access_token"], "ptr1.inst-1.secret")
        self.assertEqual(kwargs["messages"][0]["role"], "system")
        self.assertEqual(kwargs["messages"][-1], {"role": "user", "content": "مرحبا"})

        conversation = AiConversation.objects.get(user=self.user)
        stored = list(conversation.messages.values_list("role", "content"))
        self.assertEqual(stored[0], (AiMessage.ROLE_USER, "مرحبا"))
        self.assertEqual(stored[1][0], AiMessage.ROLE_ASSISTANT)
        self.assertEqual(stored[1][1], "Hello")
        assistant = conversation.messages.get(role=AiMessage.ROLE_ASSISTANT)
        self.assertEqual(assistant.model, "test/model")
        self.assertEqual(assistant.tier, "smart")
        self.assertEqual(assistant.reasoning, "thinking")
        self.assertEqual(assistant.completion_tokens, 2)

    def test_first_turn_requests_and_persists_an_ai_title(self):
        with patch("apps.ai.views.RelayControlClient") as mock_client:
            mock_client.return_value.open_ai_stream.return_value = FakeRelayResponse(
                fake_sse_lines(["مرحبا"], reasoning="", title="أكثر المنتجات مبيعًا")
            )
            response = self.client.post(
                reverse("ai-chat"),
                {"message": "ما هي أكثر المنتجات مبيعًا هذا الشهر؟"},
                format="json",
            )
            body = b"".join(response.streaming_content).decode("utf-8")

        # The first turn asks the relay to name the conversation.
        self.assertTrue(mock_client.return_value.open_ai_stream.call_args.kwargs["want_title"])
        # The AI title rides the done event and replaces the truncated fallback.
        self.assertIn('"title": "أكثر المنتجات مبيعًا"', body)
        conversation = AiConversation.objects.get(user=self.user)
        self.assertEqual(conversation.title, "أكثر المنتجات مبيعًا")

    def test_followup_turn_does_not_request_or_change_the_title(self):
        conversation = AiConversation.objects.create(user=self.user, title="عنوان موجود")
        with patch("apps.ai.views.RelayControlClient") as mock_client:
            mock_client.return_value.open_ai_stream.return_value = FakeRelayResponse(
                fake_sse_lines(["تمام"], reasoning="", title="عنوان جديد مختلف")
            )
            response = self.client.post(
                reverse("ai-chat"),
                {"message": "متابعة", "conversation_id": conversation.pk},
                format="json",
            )
            b"".join(response.streaming_content)
        # An already-named conversation never re-requests a title, so the existing
        # name is preserved.
        self.assertFalse(mock_client.return_value.open_ai_stream.call_args.kwargs["want_title"])
        conversation.refresh_from_db()
        self.assertEqual(conversation.title, "عنوان موجود")

    def test_attachment_only_first_turn_gets_a_fallback_title(self):
        with patch("apps.ai.views.RelayControlClient") as mock_client:
            mock_client.return_value.open_ai_stream.return_value = FakeRelayResponse(
                fake_sse_lines(["تم"], reasoning="")  # relay returns no title
            )
            response = self.client.post(
                reverse("ai-chat"),
                {
                    "message": "",
                    "attachments": [
                        {
                            "kind": "image",
                            "data_uri": "data:image/png;base64,AAAA",
                            "name": "فاتورة.png",
                        }
                    ],
                },
                format="json",
            )
            b"".join(response.streaming_content)
        # No AI title → the attachment name is the readable fallback.
        conversation = AiConversation.objects.get(user=self.user)
        self.assertEqual(conversation.title, "فاتورة.png")

    def test_audio_only_first_turn_titles_voice_message_not_filename(self):
        with patch("apps.ai.views.RelayControlClient") as mock_client:
            mock_client.return_value.open_ai_stream.return_value = FakeRelayResponse(
                fake_sse_lines(["تم"], reasoning="")  # relay returns no title
            )
            response = self.client.post(
                reverse("ai-chat"),
                {
                    "message": "",
                    "attachments": [
                        {
                            "kind": "audio",
                            "data_uri": "data:audio/wav;base64,AAAA",
                            "name": "voice-message.wav",
                            "mime": "audio/wav",
                        }
                    ],
                },
                format="json",
            )
            b"".join(response.streaming_content)
        # A voice turn must never title itself with the technical .wav filename.
        conversation = AiConversation.objects.get(user=self.user)
        self.assertEqual(conversation.title, "رسالة صوتية")

    def test_web_search_sources_are_persisted_and_streamed(self):
        with patch("apps.ai.views.RelayControlClient") as mock_client:
            mock_client.return_value.open_ai_stream.return_value = FakeRelayResponse(
                fake_sse_lines(
                    ["ارتفع سعر الذهب"],
                    reasoning="",
                    web_search=True,
                    sources=[{"url": "https://ex.com/a", "title": "Site A"}],
                )
            )
            response = self.client.post(
                reverse("ai-chat"), {"message": "كم سعر الذهب اليوم؟"}, format="json"
            )
            body = b"".join(response.streaming_content).decode("utf-8")

        self.assertIn('"web_search": true', body)
        self.assertIn("https://ex.com/a", body)
        message = AiConversation.objects.get(user=self.user).messages.get(
            role=AiMessage.ROLE_ASSISTANT
        )
        self.assertTrue(message.web_searched)
        self.assertEqual(message.sources, [{"url": "https://ex.com/a", "title": "Site A"}])

    def test_web_search_decision_is_carried_onto_continuations(self):
        with patch("apps.ai.views.RelayControlClient") as mock_client:
            mock_client.return_value.open_ai_stream.side_effect = [
                FakeRelayResponse(fake_tool_call_sse(web_search=True)),
                FakeRelayResponse(fake_sse_lines(["تم"], reasoning="")),
            ]
            with patch("apps.ai.views.execute_tool", return_value={"ok": True, "data": {}}):
                response = self.client.post(
                    reverse("ai-chat"), {"message": "قارن سعر الذهب بمنتجاتي"}, format="json"
                )
                b"".join(response.streaming_content)

        calls = mock_client.return_value.open_ai_stream.call_args_list
        # The user turn is classified by the relay (Django sends no hint); the
        # continuation rides the carried decision.
        self.assertFalse(calls[0].kwargs.get("web_search", False))
        self.assertTrue(calls[1].kwargs["web_search"])

    def test_blocks_when_ai_disabled(self):
        RelayInstallation.objects.update(ai_enabled=False)
        with patch("apps.ai.views.RelayControlClient") as mock_client:
            response = self.client.post(reverse("ai-chat"), {"message": "hi"}, format="json")
        self.assertEqual(response.status_code, 403)
        mock_client.assert_not_called()
        self.assertFalse(AiMessage.objects.exists())

    def test_continues_existing_conversation(self):
        conversation = AiConversation.objects.create(user=self.user, title="سابق")
        AiMessage.objects.create(
            conversation=conversation, role=AiMessage.ROLE_USER, content="قديم"
        )
        with patch("apps.ai.views.RelayControlClient") as mock_client:
            mock_client.return_value.open_ai_stream.return_value = FakeRelayResponse(
                fake_sse_lines(["ok"])
            )
            response = self.client.post(
                reverse("ai-chat"),
                {"message": "جديد", "conversation_id": conversation.pk},
                format="json",
            )
            self.assertEqual(response.status_code, 200)
            b"".join(response.streaming_content)

        self.assertEqual(AiConversation.objects.filter(user=self.user).count(), 1)
        self.assertEqual(conversation.messages.count(), 3)

    def test_requires_authentication(self):
        client = APIClient()
        response = client.post(reverse("ai-chat"), {"message": "hi"}, format="json")
        self.assertIn(response.status_code, (401, 403))

    def test_forwards_attachments_and_persists_metadata(self):
        with patch("apps.ai.views.RelayControlClient") as mock_client:
            mock_client.return_value.open_ai_stream.return_value = FakeRelayResponse(
                fake_sse_lines(["ok"])
            )
            response = self.client.post(
                reverse("ai-chat"),
                {
                    "message": "ما هذا؟",
                    "attachments": [
                        {
                            "kind": "image",
                            "data_uri": "data:image/png;base64,AAAA",
                            "name": "x.png",
                            "mime": "image/png",
                        }
                    ],
                },
                format="json",
            )
            self.assertEqual(response.status_code, 200)
            b"".join(response.streaming_content)

        _, kwargs = mock_client.return_value.open_ai_stream.call_args
        self.assertEqual(len(kwargs["attachments"]), 1)
        self.assertEqual(kwargs["attachments"][0]["data_uri"], "data:image/png;base64,AAAA")

        user_msg = AiMessage.objects.get(role=AiMessage.ROLE_USER)
        # Metadata persisted, never the bytes.
        self.assertEqual(
            user_msg.attachments,
            [{"kind": "image", "name": "x.png", "mime": "image/png"}],
        )

    def test_forwards_audio_attachment_and_persists_metadata(self):
        # A recorded voice message rides the same attachment path as images: the
        # data URI reaches the relay and only metadata is persisted.
        with patch("apps.ai.views.RelayControlClient") as mock_client:
            mock_client.return_value.open_ai_stream.return_value = FakeRelayResponse(
                fake_sse_lines(["ok"])
            )
            response = self.client.post(
                reverse("ai-chat"),
                {
                    "attachments": [
                        {
                            "kind": "audio",
                            "data_uri": "data:audio/wav;base64,QUJD",
                            "name": "voice-message.wav",
                            "mime": "audio/wav",
                        }
                    ],
                },
                format="json",
            )
            self.assertEqual(response.status_code, 200)
            b"".join(response.streaming_content)

        _, kwargs = mock_client.return_value.open_ai_stream.call_args
        self.assertEqual(len(kwargs["attachments"]), 1)
        self.assertEqual(kwargs["attachments"][0]["kind"], "audio")
        self.assertEqual(kwargs["attachments"][0]["data_uri"], "data:audio/wav;base64,QUJD")

        user_msg = AiMessage.objects.get(role=AiMessage.ROLE_USER)
        self.assertEqual(
            user_msg.attachments,
            [{"kind": "audio", "name": "voice-message.wav", "mime": "audio/wav"}],
        )

    def test_attachment_only_turn_is_allowed_and_reaches_the_model(self):
        with patch("apps.ai.views.RelayControlClient") as mock_client:
            mock_client.return_value.open_ai_stream.return_value = FakeRelayResponse(
                fake_sse_lines(["ok"])
            )
            response = self.client.post(
                reverse("ai-chat"),
                {"attachments": [{"kind": "image", "data_uri": "data:image/png;base64,AAAA"}]},
                format="json",
            )
            self.assertEqual(response.status_code, 200)
            b"".join(response.streaming_content)

        _, kwargs = mock_client.return_value.open_ai_stream.call_args
        # The empty-text user turn is still present so the relay can attach images.
        self.assertEqual(kwargs["messages"][-1], {"role": "user", "content": ""})

    def test_maps_relay_usage_limit_to_429(self):
        with patch("apps.ai.views.RelayControlClient") as mock_client:
            mock_client.return_value.open_ai_stream.side_effect = RelayControlError(
                "relay AI returned 429",
                status_code=429,
                body='{"error":"ai usage limit reached","scope":"five_hour","reset_at":"2026-06-19T12:00:00Z"}',
            )
            response = self.client.post(reverse("ai-chat"), {"message": "hi"}, format="json")
        self.assertEqual(response.status_code, 429)
        self.assertEqual(response.data["scope"], "five_hour")

    def test_usage_endpoint_returns_relay_snapshot(self):
        snapshot = {
            "five_hour": {"used": 2, "limit": 30, "remaining": 28},
            "weekly": {"used": 2, "limit": 200, "remaining": 198},
        }
        with patch("apps.ai.views.RelayControlClient") as mock_client:
            mock_client.return_value.get_ai_usage.return_value = snapshot
            response = self.client.get(reverse("ai-usage"))
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.data["five_hour"]["remaining"], 28)

    def test_usage_endpoint_serves_the_fleet_from_one_relay_call_per_window(self):
        from django.core.cache import cache as django_cache
        from django.test import override_settings

        snapshot = {
            "five_hour": {"used": 2, "limit": 30, "remaining": 28},
            "weekly": {"used": 2, "limit": 200, "remaining": 198},
        }
        with override_settings(
            CACHES={
                "default": {
                    "BACKEND": "django.core.cache.backends.locmem.LocMemCache",
                    "LOCATION": "ai-usage-cache-tests",
                },
            },
            POINTY_AI_USAGE_CACHE_TTL=60,
        ):
            django_cache.clear()
            with patch("apps.ai.views.RelayControlClient") as mock_client:
                mock_client.return_value.get_ai_usage.return_value = snapshot
                first = self.client.get(reverse("ai-usage"))
                second = self.client.get(reverse("ai-usage"))
            self.assertEqual(first.status_code, 200)
            self.assertEqual(second.status_code, 200)
            self.assertEqual(second.data["weekly"]["remaining"], 198)
            # Both polls, one relay round-trip.
            self.assertEqual(mock_client.return_value.get_ai_usage.call_count, 1)

    def test_done_event_reports_the_user_message_id(self):
        with patch("apps.ai.views.RelayControlClient") as mock_client:
            mock_client.return_value.open_ai_stream.return_value = FakeRelayResponse(
                fake_sse_lines(["ok"])
            )
            response = self.client.post(reverse("ai-chat"), {"message": "مرحبا"}, format="json")
            body = b"".join(response.streaming_content).decode("utf-8")

        # The client needs the user message's id to rewind (edit/retry) later.
        user_msg = AiMessage.objects.get(role=AiMessage.ROLE_USER)
        self.assertIn(f'"user_message_id": {user_msg.pk}', body)

    def test_truncate_deletes_the_message_and_everything_after(self):
        conversation = AiConversation.objects.create(user=self.user, title="t")
        keep_q = AiMessage.objects.create(
            conversation=conversation, role=AiMessage.ROLE_USER, content="q1"
        )
        keep_a = AiMessage.objects.create(
            conversation=conversation, role=AiMessage.ROLE_ASSISTANT, content="a1"
        )
        cut_q = AiMessage.objects.create(
            conversation=conversation, role=AiMessage.ROLE_USER, content="q2"
        )
        AiMessage.objects.create(
            conversation=conversation, role=AiMessage.ROLE_ASSISTANT, content="a2"
        )

        url = reverse("ai-conversation-truncate", args=[conversation.pk])
        response = self.client.post(url, {"message_id": cut_q.pk}, format="json")

        self.assertEqual(response.status_code, 204)
        remaining = list(conversation.messages.values_list("pk", flat=True))
        self.assertEqual(remaining, [keep_q.pk, keep_a.pk])

    def test_truncate_rejects_another_users_conversation(self):
        other = get_user_model().objects.create_user(username="intruder", password="pw-12345!")
        conversation = AiConversation.objects.create(user=other, title="x")
        message = AiMessage.objects.create(
            conversation=conversation, role=AiMessage.ROLE_USER, content="q"
        )

        url = reverse("ai-conversation-truncate", args=[conversation.pk])
        response = self.client.post(url, {"message_id": message.pk}, format="json")

        self.assertEqual(response.status_code, 404)
        self.assertTrue(AiMessage.objects.filter(pk=message.pk).exists())

    def test_agentic_loop_runs_a_tool_then_streams_the_answer(self):
        with patch("apps.ai.views.RelayControlClient") as mock_client:
            mock_client.return_value.open_ai_stream.side_effect = [
                FakeRelayResponse(fake_tool_call_sse()),
                FakeRelayResponse(fake_sse_lines(["لديك ", "٥ مبيعات"], reasoning="")),
            ]
            with patch(
                "apps.ai.views.execute_tool",
                return_value={"ok": True, "data": {"count": 5, "results": []}},
            ) as mock_exec:
                response = self.client.post(
                    reverse("ai-chat"),
                    {"message": "كم عدد مبيعات اليوم؟"},
                    format="json",
                )
                self.assertEqual(response.status_code, 200)
                body = b"".join(response.streaming_content).decode("utf-8")

        # Tool activity surfaced as status events; final answer streamed.
        self.assertIn("event: tool", body)
        self.assertIn('"name": "query_resource"', body)
        self.assertIn('"phase": "start"', body)
        self.assertIn('"phase": "done"', body)
        self.assertIn("لديك", body)
        # The done event carries the inputs + a result preview for the tap-to-inspect
        # chip (so the user can debug what the tool returned).
        self.assertIn('"output"', body)
        self.assertIn('"arguments"', body)
        self.assertIn('\\"count\\": 5', body)

        # The tool ran as the request's user — the permission boundary.
        self.assertTrue(mock_exec.called)
        self.assertEqual(mock_exec.call_args.kwargs["user"], self.user)

        # Two relay turns: the user turn charges usage, the continuation does not.
        calls = mock_client.return_value.open_ai_stream.call_args_list
        self.assertEqual(len(calls), 2)
        self.assertTrue(calls[0].kwargs.get("count_usage", True))
        self.assertFalse(calls[1].kwargs["count_usage"])
        self.assertIsNotNone(calls[0].kwargs.get("tools"))

        # The tool trace is persisted on the assistant message.
        conversation = AiConversation.objects.get(user=self.user)
        assistant = conversation.messages.get(role=AiMessage.ROLE_ASSISTANT)
        self.assertEqual(assistant.content, "لديك ٥ مبيعات")
        self.assertEqual(len(assistant.tool_events), 1)
        self.assertEqual(assistant.tool_events[0]["name"], "query_resource")
        self.assertTrue(assistant.tool_events[0]["ok"])
        # The result preview is persisted too, so a reloaded action chip stays
        # inspectable.
        self.assertIn("count", assistant.tool_events[0]["output"])

    def test_routed_tier_is_carried_onto_continuations(self):
        # The relay classifies difficulty once (here: frontier) and reports it as
        # route_tier; the agentic loop must carry that onto the continuation so the
        # whole flow rides one dynamic decision — not re-routed, not a fixed tier.
        with patch("apps.ai.views.RelayControlClient") as mock_client:
            mock_client.return_value.open_ai_stream.side_effect = [
                FakeRelayResponse(fake_tool_call_sse(route_tier="frontier")),
                FakeRelayResponse(fake_sse_lines(["تم"], reasoning="")),
            ]
            with patch("apps.ai.views.execute_tool", return_value={"ok": True, "data": {}}):
                response = self.client.post(
                    reverse("ai-chat"), {"message": "أنشئ أمر شراء معقّد"}, format="json"
                )
                b"".join(response.streaming_content)

        calls = mock_client.return_value.open_ai_stream.call_args_list
        # The user turn sends no tier (the relay classifies it); the continuation
        # carries the routed frontier tier back.
        self.assertEqual(calls[0].kwargs.get("route_tier", ""), "")
        self.assertEqual(calls[1].kwargs["route_tier"], "frontier")

    def test_agentic_loop_caps_tool_rounds(self):
        turns = [FakeRelayResponse(fake_tool_call_sse()) for _ in range(MAX_TOOL_ITERS)]
        turns.append(FakeRelayResponse(fake_sse_lines(["تم"], reasoning="")))
        with patch("apps.ai.views.RelayControlClient") as mock_client:
            mock_client.return_value.open_ai_stream.side_effect = turns
            with patch("apps.ai.views.execute_tool", return_value={"ok": True, "data": {}}):
                response = self.client.post(reverse("ai-chat"), {"message": "loop"}, format="json")
                self.assertEqual(response.status_code, 200)
                b"".join(response.streaming_content)

        calls = mock_client.return_value.open_ai_stream.call_args_list
        # post() + MAX_TOOL_ITERS continuations; the last drops tools to force an answer.
        self.assertEqual(len(calls), MAX_TOOL_ITERS + 1)
        self.assertIsNone(calls[-1].kwargs.get("tools"))

        conversation = AiConversation.objects.get(user=self.user)
        assistant = conversation.messages.get(role=AiMessage.ROLE_ASSISTANT)
        self.assertEqual(len(assistant.tool_events), MAX_TOOL_ITERS)


# A two-question ask_user spec the (mocked) model "emits".
ASK_USER_SPEC = json.dumps(
    {
        "questions": [
            {
                "id": "q1",
                "type": "single_select",
                "prompt": "أي فرع؟",
                "config": {
                    "options": [{"value": "main", "label": "الرئيسي"}],
                    "allow_other": True,
                },
            },
            {"id": "q2", "type": "confirm", "prompt": "هل أتابع؟"},
        ]
    }
)


class AskUserSpecTests(TestCase):
    """The defensive sanitiser the loop runs on the model's raw ask_user JSON."""

    def test_sanitizes_types_ids_and_options(self):
        spec = validate_ask_user_spec(
            {
                "questions": [
                    {"type": "wat", "prompt": "س1"},  # unknown type → free_text
                    {
                        "type": "single_select",
                        "prompt": "س2",
                        "config": {"options": ["a", {"value": "b", "label": "B"}]},
                    },
                    {"prompt": ""},  # empty prompt dropped
                    "garbage",  # non-dict dropped
                ]
            }
        )
        questions = spec["questions"]
        self.assertEqual(len(questions), 2)
        self.assertEqual(questions[0]["type"], "free_text")
        self.assertEqual(questions[0]["id"], "q1")  # id backfilled from position
        self.assertEqual(questions[1]["type"], "single_select")
        self.assertEqual(
            questions[1]["config"]["options"],
            [{"value": "a", "label": "a"}, {"value": "b", "label": "B"}],
        )

    def test_falls_back_to_a_free_text_question_when_empty(self):
        spec = validate_ask_user_spec({})
        self.assertEqual(len(spec["questions"]), 1)
        self.assertEqual(spec["questions"][0]["type"], "free_text")

    def test_caps_at_five_questions(self):
        spec = validate_ask_user_spec(
            {"questions": [{"type": "free_text", "prompt": f"q{i}"} for i in range(9)]}
        )
        self.assertEqual(len(spec["questions"]), 5)

    def test_product_picker_candidate_options_are_normalised_and_config_kept(self):
        # The model can pre-suggest a candidate match (variant id) for one-tap
        # confirmation; a numeric value must reach the app as a string (the PO line
        # key), and the rest of the config (labels) must survive untouched.
        spec = validate_ask_user_spec(
            {
                "questions": [
                    {
                        "type": "product_picker",
                        "prompt": "هل المطابق هو كابل USB-C؟",
                        "config": {
                            "options": [{"value": 23, "label": "كابل USB-C"}],
                            "deny_label": "أنشئ منتجًا جديدًا",
                            "name": "كابل يو اس بي سي",
                        },
                    }
                ]
            }
        )
        question = spec["questions"][0]
        self.assertEqual(question["type"], "product_picker")
        self.assertEqual(
            question["config"]["options"], [{"value": "23", "label": "كابل USB-C"}]
        )
        self.assertEqual(question["config"]["deny_label"], "أنشئ منتجًا جديدًا")
        self.assertEqual(question["config"]["name"], "كابل يو اس بي سي")


class AskUserFlowTests(TestCase):
    """The interactive ask_user pause/resume protocol end to end."""

    def setUp(self):
        user_model = get_user_model()
        self.user = user_model.objects.create_user(username="owner", password="pw-12345!")
        self.client = APIClient()
        self.client.force_authenticate(self.user)
        self.installation = RelayInstallation.objects.create(
            installation_id="inst-ask",
            access_token="ptr1.inst-ask.secret",
            relay_enabled=False,
            subscription_active=True,
            ai_enabled=True,
        )

    def _seed_paused(self, arguments=ASK_USER_SPEC):
        """Run one turn where the model calls ask_user; returns (conversation, paused)."""
        with patch("apps.ai.views.RelayControlClient") as mock_client:
            mock_client.return_value.open_ai_stream.return_value = FakeRelayResponse(
                fake_tool_call_sse(name="ask_user", arguments=arguments)
            )
            with patch("apps.ai.views.execute_tool") as mock_exec:
                response = self.client.post(
                    reverse("ai-chat"),
                    {"message": "أضف منتجًا", "supports_ask_user": True},
                    format="json",
                )
                body = b"".join(response.streaming_content).decode("utf-8")
        self.assertEqual(response.status_code, 200)
        self.assertIn("event: ask_user", body)
        # ask_user has no server handler — it must NOT be executed as a tool.
        mock_exec.assert_not_called()
        conversation = AiConversation.objects.get(user=self.user)
        paused = conversation.messages.get(status=AiMessage.STATUS_AWAITING_ANSWER)
        return conversation, paused, body

    def test_ask_user_pauses_and_persists_the_question(self):
        conversation, paused, body = self._seed_paused()

        # The question was surfaced and the turn paused — no terminal done event.
        self.assertIn('"id": "q1"', body)
        self.assertIn(f'"message_id": {paused.pk}', body)
        self.assertIn('"tool_call_id": "call_1"', body)
        self.assertNotIn("event: done", body)

        self.assertEqual(paused.role, AiMessage.ROLE_ASSISTANT)
        self.assertEqual(paused.tool_call_id, "call_1")
        self.assertTrue(paused.tool_calls)
        self.assertEqual(len(paused.pending_question["questions"]), 2)
        self.assertEqual(paused.pending_question["questions"][0]["type"], "single_select")

    def test_ask_user_advertised_only_with_capability(self):
        # Capable client → tool advertised.
        with patch("apps.ai.views.RelayControlClient") as mock_client:
            mock_client.return_value.open_ai_stream.return_value = FakeRelayResponse(
                fake_sse_lines(["ok"])
            )
            response = self.client.post(
                reverse("ai-chat"),
                {"message": "hi", "supports_ask_user": True},
                format="json",
            )
            b"".join(response.streaming_content)
        names = [t["function"]["name"] for t in mock_client.return_value.open_ai_stream.call_args.kwargs["tools"]]
        self.assertIn("ask_user", names)

        # Default (no capability) → tool withheld, so an old client can't be asked.
        with patch("apps.ai.views.RelayControlClient") as mock_client:
            mock_client.return_value.open_ai_stream.return_value = FakeRelayResponse(
                fake_sse_lines(["ok"])
            )
            response = self.client.post(reverse("ai-chat"), {"message": "hi"}, format="json")
            b"".join(response.streaming_content)
        names = [t["function"]["name"] for t in mock_client.return_value.open_ai_stream.call_args.kwargs["tools"]]
        self.assertNotIn("ask_user", names)

    def test_resume_replays_the_answer_and_continues(self):
        conversation, paused, _ = self._seed_paused()

        with patch("apps.ai.views.RelayControlClient") as mock_client:
            mock_client.return_value.open_ai_stream.return_value = FakeRelayResponse(
                fake_sse_lines(["تمام، ", "تم"], reasoning="")
            )
            response = self.client.post(
                reverse("ai-chat-resume"),
                {
                    "conversation_id": conversation.pk,
                    "message_id": paused.pk,
                    "tool_call_id": paused.tool_call_id,
                    "answers": [
                        {"question_id": "q1", "type": "single_select", "value": "main"},
                        {"question_id": "q2", "type": "confirm", "value": True},
                    ],
                },
                format="json",
            )
            self.assertEqual(response.status_code, 200)
            body = b"".join(response.streaming_content).decode("utf-8")

        self.assertIn("event: done", body)
        self.assertIn("تمام", body)

        # The resume reconstructs the prompt: the assistant tool_call turn is
        # immediately followed by the user's answer as the matching tool result.
        kwargs = mock_client.return_value.open_ai_stream.call_args.kwargs
        messages = kwargs["messages"]
        idx = next(i for i, m in enumerate(messages) if m.get("tool_calls"))
        self.assertEqual(messages[idx]["tool_calls"][0]["id"], "call_1")
        self.assertEqual(messages[idx + 1]["role"], "tool")
        self.assertEqual(messages[idx + 1]["tool_call_id"], "call_1")
        self.assertIn("main", messages[idx + 1]["content"])
        # One ask→answer is one logical turn: the resume must not re-charge usage.
        self.assertFalse(kwargs["count_usage"])

        paused.refresh_from_db()
        self.assertEqual(paused.status, AiMessage.STATUS_ANSWERED)
        # The question spec is kept (not cleared) so the answered card re-renders
        # read-only from history; ``status`` is what marks it no longer pending.
        self.assertEqual(len(paused.pending_question["questions"]), 2)
        final = conversation.messages.filter(role=AiMessage.ROLE_ASSISTANT, status="").last()
        self.assertEqual(final.content, "تمام، تم")
        self.assertTrue(
            conversation.messages.filter(role=AiMessage.ROLE_TOOL, tool_call_id="call_1").exists()
        )

    def test_answered_question_rehydrates_from_conversation_detail(self):
        # Reopening a past chat must re-render the answered question card: the
        # detail payload carries the (kept) question spec + the user's answers,
        # resolved from the sibling tool reply.
        conversation, paused, _ = self._seed_paused()
        with patch("apps.ai.views.RelayControlClient") as mock_client:
            mock_client.return_value.open_ai_stream.return_value = FakeRelayResponse(
                fake_sse_lines(["تمام"], reasoning="")
            )
            self.client.post(
                reverse("ai-chat-resume"),
                {
                    "conversation_id": conversation.pk,
                    "message_id": paused.pk,
                    "tool_call_id": paused.tool_call_id,
                    "answers": [
                        {"question_id": "q1", "type": "single_select", "value": "main"},
                        {"question_id": "q2", "type": "confirm", "value": True},
                    ],
                },
                format="json",
            )

        response = self.client.get(reverse("ai-conversation-detail", args=[conversation.pk]))
        self.assertEqual(response.status_code, 200)
        answered = next(
            m for m in response.data["messages"] if m["status"] == AiMessage.STATUS_ANSWERED
        )
        self.assertEqual(len(answered["pending_question"]["questions"]), 2)
        self.assertEqual(
            [a["question_id"] for a in answered["answers"]], ["q1", "q2"]
        )
        self.assertEqual(answered["answers"][0]["value"], "main")
        # An ordinary turn carries no answers payload (stays null).
        ordinary = next(m for m in response.data["messages"] if m["role"] == "user")
        self.assertIsNone(ordinary["answers"])

    def test_skipped_question_rehydrates_as_empty_answers(self):
        conversation, paused, _ = self._seed_paused()
        with patch("apps.ai.views.RelayControlClient") as mock_client:
            mock_client.return_value.open_ai_stream.return_value = FakeRelayResponse(
                fake_sse_lines(["حسنًا"], reasoning="")
            )
            self.client.post(
                reverse("ai-chat-resume"),
                {
                    "conversation_id": conversation.pk,
                    "message_id": paused.pk,
                    "tool_call_id": paused.tool_call_id,
                    "declined": True,
                },
                format="json",
            )
        response = self.client.get(reverse("ai-conversation-detail", args=[conversation.pk]))
        answered = next(
            m for m in response.data["messages"] if m["status"] == AiMessage.STATUS_ANSWERED
        )
        # Declined → empty list (not null) so the card recaps it as skipped.
        self.assertEqual(answered["answers"], [])

    def test_resume_skip_feeds_a_declined_result(self):
        conversation, paused, _ = self._seed_paused()
        with patch("apps.ai.views.RelayControlClient") as mock_client:
            mock_client.return_value.open_ai_stream.return_value = FakeRelayResponse(
                fake_sse_lines(["حسنًا"], reasoning="")
            )
            response = self.client.post(
                reverse("ai-chat-resume"),
                {
                    "conversation_id": conversation.pk,
                    "message_id": paused.pk,
                    "tool_call_id": paused.tool_call_id,
                    "declined": True,
                },
                format="json",
            )
            b"".join(response.streaming_content)

        tool_message = next(
            m
            for m in mock_client.return_value.open_ai_stream.call_args.kwargs["messages"]
            if m.get("role") == "tool"
        )
        self.assertIn("declined", tool_message["content"])
        answer = conversation.messages.get(role=AiMessage.ROLE_TOOL)
        self.assertIn("declined", answer.content)

    def test_resume_can_ask_another_question(self):
        conversation, paused, _ = self._seed_paused()
        followup = json.dumps(
            {"questions": [{"id": "q1", "type": "free_text", "prompt": "كم الكمية؟"}]}
        )
        with patch("apps.ai.views.RelayControlClient") as mock_client:
            mock_client.return_value.open_ai_stream.return_value = FakeRelayResponse(
                fake_tool_call_sse(name="ask_user", arguments=followup)
            )
            response = self.client.post(
                reverse("ai-chat-resume"),
                {
                    "conversation_id": conversation.pk,
                    "message_id": paused.pk,
                    "tool_call_id": paused.tool_call_id,
                    "answers": [{"question_id": "q1", "value": "main"}],
                },
                format="json",
            )
            body = b"".join(response.streaming_content).decode("utf-8")

        # The resumed turn paused again on a fresh question (re-entrancy).
        self.assertIn("event: ask_user", body)
        self.assertEqual(
            conversation.messages.filter(status=AiMessage.STATUS_AWAITING_ANSWER).count(), 1
        )

    def test_build_messages_synthesizes_reply_for_an_unanswered_call(self):
        conversation = AiConversation.objects.create(user=self.user)
        AiMessage.objects.create(
            conversation=conversation, role=AiMessage.ROLE_USER, content="q"
        )
        AiMessage.objects.create(
            conversation=conversation,
            role=AiMessage.ROLE_ASSISTANT,
            content="",
            tool_calls=[
                {"id": "call_9", "function": {"name": "ask_user", "arguments": "{}"}}
            ],
            tool_call_id="call_9",
            pending_question={"questions": [{"id": "q1", "type": "free_text", "prompt": "?"}]},
            status=AiMessage.STATUS_AWAITING_ANSWER,
        )
        messages = AiChatView()._build_messages(conversation, "متابعة")
        idx = next(i for i, m in enumerate(messages) if m.get("tool_calls"))
        self.assertEqual(messages[idx + 1]["role"], "tool")
        self.assertEqual(messages[idx + 1]["tool_call_id"], "call_9")
        self.assertIn("no_answer", messages[idx + 1]["content"])
        # The new user turn is still appended after the synthesized reply.
        self.assertEqual(messages[-1], {"role": "user", "content": "متابعة"})

    def test_truncate_removes_a_paused_turn_and_its_answer(self):
        conversation, paused, _ = self._seed_paused()
        answer = AiMessage.objects.create(
            conversation=conversation,
            role=AiMessage.ROLE_TOOL,
            tool_call_id=paused.tool_call_id,
            content='{"answers":[]}',
        )
        user_message = conversation.messages.filter(role=AiMessage.ROLE_USER).first()
        url = reverse("ai-conversation-truncate", args=[conversation.pk])
        response = self.client.post(url, {"message_id": user_message.pk}, format="json")
        self.assertEqual(response.status_code, 204)
        # No orphaned tool result left behind (which would 400 the next prompt).
        self.assertFalse(AiMessage.objects.filter(pk=paused.pk).exists())
        self.assertFalse(AiMessage.objects.filter(pk=answer.pk).exists())

    def test_resume_rejects_a_non_pending_message(self):
        conversation = AiConversation.objects.create(user=self.user)
        message = AiMessage.objects.create(
            conversation=conversation, role=AiMessage.ROLE_ASSISTANT, content="done"
        )
        response = self.client.post(
            reverse("ai-chat-resume"),
            {"conversation_id": conversation.pk, "message_id": message.pk, "tool_call_id": "x"},
            format="json",
        )
        self.assertEqual(response.status_code, 409)

    def test_resume_rejects_a_mismatched_tool_call_id(self):
        conversation, paused, _ = self._seed_paused()
        response = self.client.post(
            reverse("ai-chat-resume"),
            {
                "conversation_id": conversation.pk,
                "message_id": paused.pk,
                "tool_call_id": "wrong",
            },
            format="json",
        )
        self.assertEqual(response.status_code, 400)

    def test_resume_rejects_another_users_conversation(self):
        other = get_user_model().objects.create_user(username="intruder2", password="pw-12345!")
        conversation = AiConversation.objects.create(user=other)
        message = AiMessage.objects.create(
            conversation=conversation,
            role=AiMessage.ROLE_ASSISTANT,
            status=AiMessage.STATUS_AWAITING_ANSWER,
            tool_call_id="c1",
            tool_calls=[{"id": "c1", "function": {"name": "ask_user", "arguments": "{}"}}],
        )
        response = self.client.post(
            reverse("ai-chat-resume"),
            {"conversation_id": conversation.pk, "message_id": message.pk, "tool_call_id": "c1"},
            format="json",
        )
        self.assertEqual(response.status_code, 404)
        self.assertTrue(AiMessage.objects.filter(pk=message.pk).exists())

    def test_ask_user_call_without_id_gets_a_synthesized_resumable_id(self):
        # A model/relay that emits an ask_user call with no "id" must still yield
        # a resumable paused turn (a blank id would make resume unanswerable).
        no_id_sse = [
            b"event: tool_calls\n",
            (
                "data: "
                + json.dumps(
                    {
                        "tool_calls": [
                            {
                                "type": "function",
                                "function": {"name": "ask_user", "arguments": ASK_USER_SPEC},
                            }
                        ]
                    }
                )
                + "\n"
            ).encode("utf-8"),
            b"\n",
            b"event: done\n",
            ("data: " + json.dumps({"model": "m", "tier": "smart"}) + "\n").encode("utf-8"),
            b"\n",
        ]
        with patch("apps.ai.views.RelayControlClient") as mock_client:
            mock_client.return_value.open_ai_stream.return_value = FakeRelayResponse(no_id_sse)
            response = self.client.post(
                reverse("ai-chat"),
                {"message": "x", "supports_ask_user": True},
                format="json",
            )
            b"".join(response.streaming_content)

        paused = AiConversation.objects.get(user=self.user).messages.get(
            status=AiMessage.STATUS_AWAITING_ANSWER
        )
        # A non-empty id was synthesized and is consistent with the stored call.
        self.assertTrue(paused.tool_call_id)
        self.assertEqual(paused.tool_calls[0]["id"], paused.tool_call_id)

    def test_tool_events_before_a_pause_are_kept_on_the_paused_turn(self):
        # The model runs a data tool, then asks a question — the queried-resource
        # trace must survive the pause (not be discarded with the in-memory state).
        turns = [
            FakeRelayResponse(
                fake_tool_call_sse(name="query_resource", arguments='{"resource":"orders"}')
            ),
            FakeRelayResponse(fake_tool_call_sse(name="ask_user", arguments=ASK_USER_SPEC)),
        ]
        with patch("apps.ai.views.RelayControlClient") as mock_client:
            mock_client.return_value.open_ai_stream.side_effect = turns
            with patch("apps.ai.views.execute_tool", return_value={"ok": True, "data": {}}):
                response = self.client.post(
                    reverse("ai-chat"),
                    {"message": "حلّل ثم اسأل", "supports_ask_user": True},
                    format="json",
                )
                b"".join(response.streaming_content)

        paused = AiConversation.objects.get(user=self.user).messages.get(
            status=AiMessage.STATUS_AWAITING_ANSWER
        )
        self.assertEqual(len(paused.tool_events), 1)
        self.assertEqual(paused.tool_events[0]["name"], "query_resource")

    def test_prior_tool_results_survive_the_pause_and_resume(self):
        # Regression for the PO-from-invoice flow: the model extracts the whole
        # invoice via a data tool, THEN asks a question. The extraction (the tool's
        # result) must survive the pause and be replayed on resume — otherwise the
        # model loses the invoice the moment it asks anything and hallucinates the PO.
        turns = [
            FakeRelayResponse(
                fake_tool_call_sse(
                    name="match_invoice_products",
                    arguments='{"supplier_name":"الوفاق","lines":[{"name":"كابل","quantity":5}]}',
                )
            ),
            FakeRelayResponse(fake_tool_call_sse(name="ask_user", arguments=ASK_USER_SPEC)),
        ]
        extracted = {
            "ok": True,
            "supplier": {"name": "الوفاق", "matched": False},
            "lines": [{"name": "كابل", "quantity": 5, "unit_cost": "15.00"}],
        }
        with patch("apps.ai.views.RelayControlClient") as mock_client:
            mock_client.return_value.open_ai_stream.side_effect = turns
            with patch("apps.ai.views.execute_tool", return_value=extracted):
                response = self.client.post(
                    reverse("ai-chat"),
                    {
                        "message": "أنشئ أمر شراء من الفاتورة",
                        "supports_ask_user": True,
                        "supports_actions": True,
                    },
                    format="json",
                )
                b"".join(response.streaming_content)

        conversation = AiConversation.objects.get(user=self.user)
        paused = conversation.messages.get(status=AiMessage.STATUS_AWAITING_ANSWER)
        # The extraction is stored on the paused turn as a paired call + result.
        self.assertEqual([m["role"] for m in paused.prior_tool_messages], ["assistant", "tool"])
        self.assertEqual(
            paused.prior_tool_messages[0]["tool_calls"][0]["function"]["name"],
            "match_invoice_products",
        )
        self.assertIn("الوفاق", paused.prior_tool_messages[1]["content"])

        # On resume, the relay receives the replayed extraction (call + result)
        # before the ask_user turn — the invoice is back in the model's context.
        with patch("apps.ai.views.RelayControlClient") as mock_client:
            mock_client.return_value.open_ai_stream.return_value = FakeRelayResponse(
                fake_sse_lines(["تم"], reasoning="")
            )
            self.client.post(
                reverse("ai-chat-resume"),
                {
                    "conversation_id": conversation.pk,
                    "message_id": paused.pk,
                    "tool_call_id": paused.tool_call_id,
                    "answers": [
                        {"question_id": "q1", "type": "single_select", "value": "main"},
                        {"question_id": "q2", "type": "confirm", "value": True},
                    ],
                },
                format="json",
            )
            messages = mock_client.return_value.open_ai_stream.call_args.kwargs["messages"]

        replayed_names = [
            (m.get("tool_calls") or [{}])[0].get("function", {}).get("name")
            for m in messages
            if m.get("tool_calls")
        ]
        self.assertIn("match_invoice_products", replayed_names)
        self.assertTrue(
            any(m.get("role") == "tool" and "الوفاق" in (m.get("content") or "") for m in messages)
        )

    def _seed_product_picker(self, *, config_name="كابل يو اس بي سي"):
        """A paused conversation whose pending question is a product_picker for an
        unmatched invoice line — returns (conversation, paused)."""
        conversation = AiConversation.objects.create(user=self.user)
        AiMessage.objects.create(
            conversation=conversation, role=AiMessage.ROLE_USER, content="أنشئ أمر شراء"
        )
        paused = AiMessage.objects.create(
            conversation=conversation,
            role=AiMessage.ROLE_ASSISTANT,
            status=AiMessage.STATUS_AWAITING_ANSWER,
            tool_call_id="call_pick",
            tool_calls=[{"id": "call_pick", "function": {"name": "ask_user", "arguments": "{}"}}],
            pending_question={
                "questions": [
                    {
                        "id": "line1",
                        "type": "product_picker",
                        "prompt": "اختر المنتج",
                        "config": {"name": config_name},
                    }
                ]
            },
        )
        return conversation, paused

    def _resume_picker(self, conversation, paused, answer):
        with patch("apps.ai.views.RelayControlClient") as mock_client:
            mock_client.return_value.open_ai_stream.return_value = FakeRelayResponse(
                fake_sse_lines(["تم"], reasoning="")
            )
            response = self.client.post(
                reverse("ai-chat-resume"),
                {
                    "conversation_id": conversation.pk,
                    "message_id": paused.pk,
                    "tool_call_id": "call_pick",
                    "answers": [answer],
                },
                format="json",
            )
            b"".join(response.streaming_content)

    def test_resume_learns_a_product_alias_from_a_pick(self):
        # Confirming a product_picker teaches the matcher: the invoice's name becomes
        # a learned alias of the chosen product.
        from apps.catalog.models import Product, ProductAlias, ProductVariant

        product = Product.objects.create(name="كابل USB-C")
        variant = ProductVariant.objects.create(
            product=product, sku="U1", unit_price=Decimal("8.00"), is_default=True
        )
        conversation, paused = self._seed_product_picker()
        self._resume_picker(
            conversation,
            paused,
            {"question_id": "line1", "type": "product_picker", "value": variant.id, "is_other": False},
        )
        self.assertTrue(
            ProductAlias.objects.filter(product=product, alias="كابل يو اس بي سي").exists()
        )

    def test_resume_create_new_does_not_learn_an_alias(self):
        from apps.catalog.models import ProductAlias

        conversation, paused = self._seed_product_picker()
        self._resume_picker(
            conversation,
            paused,
            {"question_id": "line1", "type": "product_picker", "is_other": True},
        )
        self.assertFalse(ProductAlias.objects.exists())

    def test_resume_blocked_when_ai_disabled(self):
        conversation, paused, _ = self._seed_paused()
        RelayInstallation.objects.update(ai_enabled=False)
        response = self.client.post(
            reverse("ai-chat-resume"),
            {
                "conversation_id": conversation.pk,
                "message_id": paused.pk,
                "tool_call_id": paused.tool_call_id,
            },
            format="json",
        )
        self.assertEqual(response.status_code, 403)


class AiChatActionToolTests(TestCase):
    """The create/edit (action) tools end to end through the agentic loop and the
    capability gate — complementing the in-isolation tests in test_action_tools."""

    def setUp(self):
        from django.contrib.auth.models import Group

        from apps.core.roles import MANAGER_GROUP, ensure_role_groups

        ensure_role_groups()
        user_model = get_user_model()
        self.manager = user_model.objects.create_user(username="loop-manager", password="pw-12345!")
        self.manager.groups.add(Group.objects.get(name=MANAGER_GROUP))
        self.client = APIClient()
        self.client.force_authenticate(self.manager)
        self.installation = RelayInstallation.objects.create(
            installation_id="inst-act",
            access_token="ptr1.inst-act.secret",
            relay_enabled=False,
            subscription_active=True,
            ai_enabled=True,
        )

    def _advertised_tools(self, payload):
        with patch("apps.ai.views.RelayControlClient") as mock_client:
            mock_client.return_value.open_ai_stream.return_value = FakeRelayResponse(
                fake_sse_lines(["ok"])
            )
            self.client.post(reverse("ai-chat"), payload, format="json")
            _, kwargs = mock_client.return_value.open_ai_stream.call_args
            return {t["function"]["name"] for t in kwargs["tools"]}

    def test_action_tools_advertised_only_with_capability(self):
        with_actions = self._advertised_tools({"message": "x", "supports_actions": True})
        self.assertIn("create_resource", with_actions)
        self.assertIn("create_sale", with_actions)
        without = self._advertised_tools({"message": "x"})
        self.assertNotIn("create_resource", without)
        self.assertNotIn("create_sale", without)

    def _system_prompt_for(self, payload):
        with patch("apps.ai.views.RelayControlClient") as mock_client:
            mock_client.return_value.open_ai_stream.return_value = FakeRelayResponse(
                fake_sse_lines(["ok"])
            )
            self.client.post(reverse("ai-chat"), payload, format="json")
            _, kwargs = mock_client.return_value.open_ai_stream.call_args
            return kwargs["messages"][0]["content"]

    def test_navigation_link_guidance_gated_by_capability(self):
        # A capable client is told it can emit pointy:// deep links; an older one
        # never is (so it can't render an inert link).
        with_nav = self._system_prompt_for({"message": "x", "supports_navigation": True})
        self.assertIn("pointy://", with_nav)
        self.assertIn("pointy://screen/", with_nav)
        without = self._system_prompt_for({"message": "x"})
        self.assertNotIn("pointy://", without)

    def test_attachment_turn_still_advertises_tools(self):
        # A supplier-invoice upload must carry tools so the vision model can read
        # it AND act (match products, draft the PO) — previously tools were nulled
        # on any attachment turn.
        names = self._advertised_tools(
            {
                "message": "أنشئ أمر شراء من هذه الفاتورة",
                "supports_actions": True,
                "attachments": [
                    {
                        "kind": "image",
                        "data_uri": "data:image/jpeg;base64,/9j/4AAQSkZJRg==",
                        "name": "invoice.jpg",
                        "mime": "image/jpeg",
                    }
                ],
            }
        )
        self.assertIn("match_invoice_products", names)
        self.assertIn("create_resource", names)

    def test_create_tool_executes_in_loop_and_marks_mutation(self):
        from apps.expenses.models import Expense, ExpenseCategory

        category = ExpenseCategory.objects.create(name="فئة-حلقة")
        args = json.dumps(
            {
                "resource": "expenses",
                "data": {"category": category.id, "description": "كهرباء", "amount": "30.00"},
            }
        )
        with patch("apps.ai.views.RelayControlClient") as mock_client:
            mock_client.return_value.open_ai_stream.side_effect = [
                FakeRelayResponse(fake_tool_call_sse(name="create_resource", arguments=args)),
                FakeRelayResponse(fake_sse_lines(["تم تسجيل المصروف"])),
            ]
            response = self.client.post(
                reverse("ai-chat"),
                {"message": "سجّل مصروف كهرباء ٣٠", "supports_actions": True},
                format="json",
            )
            body = b"".join(response.streaming_content).decode("utf-8")

        # The write genuinely happened through the real viewset → service (the
        # acting user was stamped) — not a simulated/fake action.
        self.assertEqual(Expense.objects.count(), 1)
        self.assertEqual(Expense.objects.get().created_by, self.manager)
        # The tool chip is flagged as a mutation so the UI surfaces it as an action.
        self.assertIn("event: tool", body)
        self.assertIn('"mutates": true', body)
        # And the mutation is persisted in the assistant turn's trace.
        assistant = (
            AiConversation.objects.get(user=self.manager)
            .messages.filter(role=AiMessage.ROLE_ASSISTANT)
            .last()
        )
        self.assertTrue(any(event.get("mutates") for event in assistant.tool_events))

    def _two_call_turn(self, calls):
        """A relay turn that emits several tool calls at once, then done."""
        done = {"model": "m", "tier": "smart", "finish_reason": "tool_calls"}
        return [
            b"event: tool_calls\n",
            ("data: " + json.dumps({"tool_calls": calls}) + "\n").encode("utf-8"),
            b"\n",
            b"event: done\n",
            ("data: " + json.dumps(done) + "\n").encode("utf-8"),
            b"\n",
        ]

    def test_duplicate_write_in_one_turn_is_deduped(self):
        from apps.expenses.models import Expense, ExpenseCategory

        category = ExpenseCategory.objects.create(name="فئة-تكرار")
        args = json.dumps(
            {
                "resource": "expenses",
                "data": {"category": category.id, "description": "نفس المصروف", "amount": "12.00"},
            }
        )
        # The model emits the SAME create twice in one round (an accidental
        # double-emit). The turn-scoped Idempotency-Key collapses them to one
        # committed write instead of two identical expenses.
        calls = [
            {"id": "c1", "type": "function", "function": {"name": "create_resource", "arguments": args}},
            {"id": "c2", "type": "function", "function": {"name": "create_resource", "arguments": args}},
        ]
        with patch("apps.ai.views.RelayControlClient") as mock_client:
            mock_client.return_value.open_ai_stream.side_effect = [
                FakeRelayResponse(self._two_call_turn(calls)),
                FakeRelayResponse(fake_sse_lines(["تم"])),
            ]
            response = self.client.post(
                reverse("ai-chat"),
                {"message": "سجّل المصروف", "supports_actions": True},
                format="json",
            )
            b"".join(response.streaming_content)

        self.assertEqual(Expense.objects.filter(description="نفس المصروف").count(), 1)

    def test_mutating_write_cap_blocks_excess_writes_in_a_turn(self):
        from apps.expenses.models import Expense, ExpenseCategory

        category = ExpenseCategory.objects.create(name="فئة-سقف")

        def create_call(call_id, description):
            args = json.dumps(
                {
                    "resource": "expenses",
                    "data": {"category": category.id, "description": description, "amount": "5.00"},
                }
            )
            return {"id": call_id, "type": "function", "function": {"name": "create_resource", "arguments": args}}

        # Two DISTINCT creates in one turn, but the per-turn cap is patched to 1 —
        # so the first commits and the second is refused (write_limit_reached).
        calls = [create_call("c1", "أول"), create_call("c2", "ثانٍ")]
        with patch("apps.ai.views.MAX_MUTATING_WRITES_PER_TURN", 1):
            with patch("apps.ai.views.RelayControlClient") as mock_client:
                mock_client.return_value.open_ai_stream.side_effect = [
                    FakeRelayResponse(self._two_call_turn(calls)),
                    FakeRelayResponse(fake_sse_lines(["تم"])),
                ]
                response = self.client.post(
                    reverse("ai-chat"),
                    {"message": "سجّل مصروفين", "supports_actions": True},
                    format="json",
                )
                b"".join(response.streaming_content)

        self.assertTrue(Expense.objects.filter(description="أول").exists())
        self.assertFalse(Expense.objects.filter(description="ثانٍ").exists())


class AiChatAsgiStreamingTests(TransactionTestCase):
    """The chat SSE body must be an async iterator when served over ASGI.

    Django only *buffers* a sync iterator under ASGI — it warns
    ("StreamingHttpResponse must consume synchronous iterators … Use an
    asynchronous iterator instead.") and collects the whole body via
    ``sync_to_async(list)`` before sending byte one, so in production (uvicorn)
    the client saw nothing until the entire agentic turn finished and every
    chat request appeared to hang/fail. TransactionTestCase because the bridge
    runs the turn on a worker thread whose DB connection can't see an open
    test transaction.
    """

    def setUp(self):
        user_model = get_user_model()
        self.user = user_model.objects.create_user(username="asgi-cashier", password="pw-12345!")
        RelayInstallation.objects.create(
            installation_id="inst-asgi",
            access_token="ptr1.inst-asgi.secret",
            relay_enabled=False,
            subscription_active=True,
            ai_enabled=True,
        )

    def _post_chat_over_asgi(self):
        request = AsyncRequestFactory().post(
            "/api/ai/chat/",
            data=json.dumps({"message": "مرحبا"}),
            content_type="application/json",
        )
        force_authenticate(request, user=self.user)
        return AiChatView.as_view()(request)

    def test_streams_an_async_body_and_persists_the_turn(self):
        with patch("apps.ai.views.RelayControlClient") as mock_client:
            mock_client.return_value.open_ai_stream.return_value = FakeRelayResponse(
                fake_sse_lines(["Hel", "lo"])
            )
            response = self._post_chat_over_asgi()
            self.assertEqual(response.status_code, 200)
            # The load-bearing assertion: an async body streams event-by-event;
            # a sync one would be silently buffered wholesale (after a warning).
            self.assertTrue(response.is_async)

            async def consume():
                # Iterate the response exactly like Django's ASGI handler does.
                collected = []
                with warnings.catch_warnings(record=True) as caught:
                    warnings.simplefilter("always")
                    async for part in response:
                        collected.append(part)
                return collected, caught

            parts, caught = asyncio.run(consume())

        body = b"".join(parts).decode("utf-8")
        self.assertIn("event: delta", body)
        self.assertIn('"text": "Hel"', body)
        self.assertIn("event: done", body)
        self.assertEqual([w for w in caught if "StreamingHttpResponse" in str(w.message)], [])

        # The worker thread persisted the turn like the WSGI path does.
        conversation = AiConversation.objects.get(user=self.user)
        roles = list(conversation.messages.values_list("role", flat=True))
        self.assertEqual(roles, [AiMessage.ROLE_USER, AiMessage.ROLE_ASSISTANT])
        self.assertEqual(
            conversation.messages.get(role=AiMessage.ROLE_ASSISTANT).content, "Hello"
        )

    def test_wsgi_requests_keep_a_sync_body(self):
        # runserver/tests serve WSGI, where a sync generator streams natively —
        # the async bridge must stay out of that path.
        client = APIClient()
        client.force_authenticate(self.user)
        with patch("apps.ai.views.RelayControlClient") as mock_client:
            mock_client.return_value.open_ai_stream.return_value = FakeRelayResponse(
                fake_sse_lines(["hi"])
            )
            response = client.post(reverse("ai-chat"), {"message": "مرحبا"}, format="json")
            self.assertFalse(response.is_async)
            body = b"".join(response.streaming_content).decode("utf-8")
        self.assertIn("event: done", body)
