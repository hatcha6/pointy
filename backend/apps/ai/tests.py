import json
from unittest.mock import patch

from django.contrib.auth import get_user_model
from django.test import TestCase
from django.urls import reverse
from rest_framework.test import APIClient

from apps.core.models import RelayInstallation
from apps.core.relay import RelayControlError, relay_ai_available

from .models import AiConversation, AiMessage
from .relay_stream import iter_relay_sse
from .views import MAX_TOOL_ITERS


class FakeRelayResponse:
    """Mimics the relay's streaming SSE response: line-iterable + close()."""

    def __init__(self, lines):
        self._lines = lines
        self.closed = False

    def __iter__(self):
        return iter(self._lines)

    def close(self):
        self.closed = True


def fake_sse_lines(text_chunks, *, model="test/model", tier="smart", reasoning="thinking"):
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
    lines.append(b"event: done\n")
    lines.append(("data: " + json.dumps(done) + "\n").encode("utf-8"))
    lines.append(b"\n")
    return lines


def fake_tool_call_sse(name="query_resource", arguments='{"resource":"orders"}'):
    """A relay turn that asks for one tool call, then done(finish=tool_calls)."""
    tool_calls = [
        {
            "id": "call_1",
            "type": "function",
            "function": {"name": name, "arguments": arguments},
        }
    ]
    done = {"model": "m", "tier": "smart", "finish_reason": "tool_calls"}
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
