"""The server-enforced approval gate for money-moving / irreversible AI writes."""

import json
from unittest.mock import patch

from django.contrib.auth import get_user_model
from django.urls import reverse
from rest_framework.test import APIClient

from django.test import TestCase

from apps.core.models import RelayInstallation

from .approvals import APPROVAL_QUESTION_ID, approval_granted, approval_request
from .models import AiConversation, AiMessage
from .tests import FakeRelayResponse, fake_sse_lines

SUPPLIER_PAYMENT = {"supplier_id": 7, "method": "cash", "amount": "150.00", "confirm": True}


def _tool_calls_sse(calls):
    """A relay turn that asks for several tool calls: [(id, name, args_dict)]."""
    tool_calls = [
        {"id": call_id, "type": "function", "function": {"name": name, "arguments": json.dumps(args)}}
        for call_id, name, args in calls
    ]
    done = {"model": "m", "tier": "smart", "route_tier": "smart", "finish_reason": "tool_calls"}
    return [
        b"event: tool_calls\n",
        ("data: " + json.dumps({"tool_calls": tool_calls}) + "\n").encode("utf-8"),
        b"\n",
        b"event: done\n",
        ("data: " + json.dumps(done) + "\n").encode("utf-8"),
        b"\n",
    ]


class ApprovalRequestTests(TestCase):
    def setUp(self):
        self.user = get_user_model().objects.create_user(username="gate", password="pw-12345!")

    def test_preview_steps_are_not_gated(self):
        args = dict(SUPPLIER_PAYMENT, confirm=False)
        self.assertIsNone(approval_request("record_supplier_payment", args, user=self.user))

    def test_committing_payment_is_gated_with_its_figures(self):
        spec = approval_request("record_supplier_payment", SUPPLIER_PAYMENT, user=self.user)
        question = spec["questions"][0]
        self.assertEqual(question["id"], APPROVAL_QUESTION_ID)
        self.assertEqual(question["type"], "confirm")
        self.assertTrue(question["config"]["approval"])
        values = {row["label"]: row["value"] for row in question["config"]["details"]}
        money = next(r for r in question["config"]["details"] if r["label"] == "المبلغ")
        self.assertEqual((money["value"], money["kind"]), ("150.00", "money"))
        self.assertEqual(values["طريقة الدفع"], "نقدًا")
        # The frozen call the resume endpoint will run.
        self.assertEqual(spec["approval"], {"name": "record_supplier_payment", "arguments": SUPPLIER_PAYMENT})

    def test_expense_is_gated_only_when_it_pays_out(self):
        recorded = {"resource": "expenses", "data": {"amount": "30", "description": "كهرباء"}}
        self.assertIsNone(approval_request("create_resource", recorded, user=self.user))
        paid = {"resource": "expenses", "data": {"amount": "30", "pay_from_register": True}}
        spec = approval_request("create_resource", paid, user=self.user)
        self.assertIsNotNone(spec)
        labels = [row["label"] for row in spec["questions"][0]["config"]["details"]]
        self.assertIn("يُدفع من", labels)

    def test_discount_rules_are_gated_and_plain_records_are_not(self):
        self.assertIsNotNone(
            approval_request("create_resource", {"resource": "discount-rules", "data": {}}, user=self.user)
        )
        self.assertIsNone(
            approval_request("create_resource", {"resource": "products", "data": {"name": "x"}}, user=self.user)
        )

    def test_only_an_explicit_yes_approves(self):
        yes = [{"question_id": APPROVAL_QUESTION_ID, "value": True}]
        self.assertTrue(approval_granted(yes, declined=False))
        self.assertFalse(approval_granted(yes, declined=True))
        self.assertFalse(approval_granted([{"question_id": APPROVAL_QUESTION_ID, "value": False}], declined=False))
        self.assertFalse(approval_granted([{"question_id": APPROVAL_QUESTION_ID, "value": "true"}], declined=False))
        self.assertFalse(approval_granted([{"question_id": "q1", "value": True}], declined=False))
        self.assertFalse(approval_granted([], declined=False))


class ApprovalGateFlowTests(TestCase):
    def setUp(self):
        self.user = get_user_model().objects.create_user(username="gate-owner", password="pw-12345!")
        self.client = APIClient()
        self.client.force_authenticate(self.user)
        RelayInstallation.objects.create(
            installation_id="inst-gate",
            access_token="ptr1.inst-gate.secret",
            relay_enabled=False,
            subscription_active=True,
            ai_enabled=True,
        )

    def _seed(self, calls):
        """Run one turn whose model round asks for ``calls``; returns the pause."""
        with patch("apps.ai.views.scoped_relay_client") as mock_client:
            mock_client.return_value.open_ai_stream.return_value = FakeRelayResponse(_tool_calls_sse(calls))
            with patch("apps.ai.views.execute_tool", return_value={"ok": True, "data": []}) as mock_exec:
                response = self.client.post(
                    reverse("ai-chat"),
                    {"message": "ادفع للمورّد ١٥٠", "supports_ask_user": True, "supports_actions": True},
                    format="json",
                )
                body = b"".join(response.streaming_content).decode("utf-8")
        conversation = AiConversation.objects.get(user=self.user)
        paused = conversation.messages.get(status=AiMessage.STATUS_AWAITING_ANSWER)
        return conversation, paused, body, mock_exec

    def _resume(self, conversation, paused, answers=None, declined=False):
        with patch("apps.ai.views.scoped_relay_client") as mock_client:
            mock_client.return_value.open_ai_stream.return_value = FakeRelayResponse(fake_sse_lines(["تم"]))
            with patch(
                "apps.ai.views.execute_tool", return_value={"ok": True, "data": {"id": 99}}
            ) as mock_exec:
                payload = {
                    "conversation_id": conversation.pk,
                    "message_id": paused.pk,
                    "tool_call_id": paused.tool_call_id,
                    "answers": answers or [],
                }
                if declined:
                    payload["declined"] = True
                response = self.client.post(reverse("ai-chat-resume"), payload, format="json")
                self.assertEqual(response.status_code, 200)
                body = b"".join(response.streaming_content).decode("utf-8")
        return body, mock_exec, mock_client.return_value.open_ai_stream.call_args.kwargs["messages"]

    def test_gated_call_pauses_without_running(self):
        conversation, paused, body, mock_exec = self._seed(
            [("call_pay", "record_supplier_payment", SUPPLIER_PAYMENT)]
        )
        mock_exec.assert_not_called()
        self.assertIn("event: ask_user", body)
        self.assertIn('"approval": true', body)
        self.assertNotIn("event: done", body)
        self.assertEqual(paused.tool_call_id, "call_pay")
        self.assertEqual(paused.pending_question["approval"]["name"], "record_supplier_payment")

    def test_approval_runs_the_frozen_call_once(self):
        conversation, paused, _, _ = self._seed([("call_pay", "record_supplier_payment", SUPPLIER_PAYMENT)])
        body, mock_exec, messages = self._resume(
            conversation, paused, answers=[{"question_id": APPROVAL_QUESTION_ID, "type": "confirm", "value": True}]
        )
        mock_exec.assert_called_once()
        name, args = mock_exec.call_args.args
        self.assertEqual(name, "record_supplier_payment")
        self.assertEqual(args, SUPPLIER_PAYMENT)
        self.assertEqual(mock_exec.call_args.kwargs["idempotency_key"], f"ai-approval-{paused.pk}")
        # The committed write shows as an action chip and the model reads the result.
        self.assertIn('"mutates": true', body)
        reply = next(m for m in messages if m.get("role") == "tool" and m["tool_call_id"] == "call_pay")
        content = json.loads(reply["content"])
        self.assertTrue(content["approved"])
        self.assertEqual(content["result"]["data"]["id"], 99)
        # A replayed resume is refused: the pause is no longer awaiting an answer.
        response = self.client.post(
            reverse("ai-chat-resume"),
            {"conversation_id": conversation.pk, "message_id": paused.pk, "tool_call_id": "call_pay", "answers": []},
            format="json",
        )
        self.assertEqual(response.status_code, 409)

    def test_refusal_never_runs_the_call(self):
        conversation, paused, _, _ = self._seed([("call_pay", "record_supplier_payment", SUPPLIER_PAYMENT)])
        _, mock_exec, messages = self._resume(
            conversation, paused, answers=[{"question_id": APPROVAL_QUESTION_ID, "type": "confirm", "value": False}]
        )
        mock_exec.assert_not_called()
        reply = next(m for m in messages if m.get("role") == "tool" and m["tool_call_id"] == "call_pay")
        self.assertEqual(json.loads(reply["content"])["result"]["error"], "user_declined")

    def test_skip_is_a_refusal(self):
        conversation, paused, _, _ = self._seed([("call_pay", "record_supplier_payment", SUPPLIER_PAYMENT)])
        _, mock_exec, _ = self._resume(conversation, paused, declined=True)
        mock_exec.assert_not_called()

    def test_siblings_in_the_round_keep_the_prompt_valid(self):
        conversation, paused, _, mock_exec = self._seed(
            [
                ("call_read", "query_resource", {"resource": "suppliers"}),
                ("call_pay", "record_supplier_payment", SUPPLIER_PAYMENT),
                ("call_after", "query_resource", {"resource": "orders"}),
            ]
        )
        # The read before the gate ran; the call queued after it did not.
        self.assertEqual(mock_exec.call_count, 1)
        self.assertEqual(mock_exec.call_args.args[0], "query_resource")
        _, _, messages = self._resume(
            conversation, paused, answers=[{"question_id": APPROVAL_QUESTION_ID, "type": "confirm", "value": True}]
        )
        idx = next(i for i, m in enumerate(messages) if m.get("tool_calls"))
        replies = {m["tool_call_id"]: m for m in messages[idx + 1 : idx + 4]}
        self.assertEqual(set(replies), {"call_read", "call_pay", "call_after"})
        self.assertEqual(json.loads(replies["call_after"]["content"])["error"], "not_run")

    def test_answered_approval_rehydrates_its_recap(self):
        conversation, paused, _, _ = self._seed([("call_pay", "record_supplier_payment", SUPPLIER_PAYMENT)])
        self._resume(
            conversation, paused, answers=[{"question_id": APPROVAL_QUESTION_ID, "type": "confirm", "value": True}]
        )
        detail = self.client.get(reverse("ai-conversation-detail", args=[conversation.pk])).json()
        answered = next(m for m in detail["messages"] if m["id"] == paused.pk)
        self.assertEqual(answered["answers"][0]["value"], True)


class PlanToolTests(TestCase):
    def setUp(self):
        self.user = get_user_model().objects.create_user(username="planner", password="pw-12345!")
        self.client = APIClient()
        self.client.force_authenticate(self.user)
        RelayInstallation.objects.create(
            installation_id="inst-plan",
            access_token="ptr1.inst-plan.secret",
            relay_enabled=False,
            subscription_active=True,
            ai_enabled=True,
        )

    def test_validate_plan_keeps_one_current_step(self):
        from .plan_tool import validate_plan

        steps = validate_plan(
            {
                "steps": [
                    {"step": "أنشئ المنتج", "status": "completed"},
                    {"step": "أنشئ الوصفة", "status": "in_progress"},
                    {"step": "اربط المكوّنات", "status": "in_progress"},
                    {"step": "", "status": "pending"},
                    {"step": "راجع", "status": "weird"},
                ]
            }
        )
        self.assertEqual([s["status"] for s in steps], ["completed", "in_progress", "pending", "pending"])
        self.assertIsNone(validate_plan({"steps": "nope"}))

    def test_plan_streams_and_persists_without_a_chip(self):
        plan = {"steps": [{"step": "اجمع البيانات", "status": "in_progress"}, {"step": "أنشئ الطلب", "status": "pending"}]}
        with patch("apps.ai.views.scoped_relay_client") as mock_client:
            mock_client.return_value.open_ai_stream.side_effect = [
                FakeRelayResponse(_tool_calls_sse([("call_plan", "update_plan", plan)])),
                FakeRelayResponse(fake_sse_lines(["تم"])),
            ]
            response = self.client.post(
                reverse("ai-chat"), {"message": "رتّب الطلبات", "supports_plan": True}, format="json"
            )
            body = b"".join(response.streaming_content).decode("utf-8")
            first_tools = {
                t["function"]["name"]
                for t in mock_client.return_value.open_ai_stream.call_args_list[0].kwargs["tools"]
            }
        self.assertIn("update_plan", first_tools)
        self.assertIn("event: plan", body)
        self.assertNotIn('"name": "update_plan"', body)  # no tool chip
        final = AiMessage.objects.filter(role=AiMessage.ROLE_ASSISTANT).last()
        self.assertEqual(final.plan[0]["step"], "اجمع البيانات")

    def test_plan_tool_needs_the_capability(self):
        with patch("apps.ai.views.scoped_relay_client") as mock_client:
            mock_client.return_value.open_ai_stream.return_value = FakeRelayResponse(fake_sse_lines(["ok"]))
            b"".join(self.client.post(reverse("ai-chat"), {"message": "x"}, format="json").streaming_content)
            names = {t["function"]["name"] for t in mock_client.return_value.open_ai_stream.call_args.kwargs["tools"]}
        self.assertNotIn("update_plan", names)

    def test_tool_events_carry_the_call_id(self):
        with patch("apps.ai.views.scoped_relay_client") as mock_client:
            mock_client.return_value.open_ai_stream.side_effect = [
                FakeRelayResponse(_tool_calls_sse([("call_q", "query_resource", {"resource": "orders"})])),
                FakeRelayResponse(fake_sse_lines(["تم"])),
            ]
            with patch("apps.ai.views.execute_tool", return_value={"ok": True, "data": []}):
                body = b"".join(
                    self.client.post(reverse("ai-chat"), {"message": "x"}, format="json").streaming_content
                ).decode("utf-8")
        self.assertEqual(body.count('"id": "call_q"'), 2)  # start and done
