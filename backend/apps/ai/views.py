import hashlib
import json
from uuid import uuid4

from django.http import StreamingHttpResponse
from django.utils import timezone
from rest_framework import permissions, status, viewsets
from rest_framework.response import Response
from rest_framework.views import APIView

from apps.core.models import RelayInstallation
from apps.core.relay import RelayControlClient, RelayControlError, relay_ai_available

from .models import AiConversation, AiMessage
from .relay_stream import build_system_prompt, iter_relay_sse, sse_event
from .serializers import (
    AiChatRequestSerializer,
    AiChatResumeRequestSerializer,
    AiConversationDetailSerializer,
    AiConversationSerializer,
)
from .tools import (
    ASK_USER_TOOL_NAME,
    execute_tool,
    is_mutating_tool,
    tool_label,
    tools_definitions,
    validate_ask_user_spec,
)

# How many prior messages to include as context per turn.
HISTORY_WINDOW = 20

# Max tool rounds per user message before the model is forced to answer. Bounds
# runaway tool loops + cost; each round is one (uncharged) relay continuation.
# Generous enough for a multi-step composite action (e.g. create a product, then
# its variants/ingredients, then its recipe — each step needs the prior step's
# returned ids), which a tighter budget would cut off mid-creation.
MAX_TOOL_ITERS = 10

# Blast-radius backstop: the most *successful* create/edit/sale writes one user
# turn may commit. Well above any real composite (a dish + variant + recipe + a
# dozen ingredient products ≈ 30), but it bounds a runaway/prompt-injected loop
# from committing an unbounded number of irreversible writes (e.g. many sales).
MAX_MUTATING_WRITES_PER_TURN = 40


def _ai_idempotency_key(turn_id, name, args):
    """A turn-scoped idempotency key for a mutating tool call: identical calls
    *within the same turn* collapse to one committed write (guards an accidental
    double-emit), while a legitimately-repeated operation in a later turn gets a
    fresh ``turn_id`` and commits normally. Matches IDEMPOTENCY_KEY_PATTERN."""
    canonical = json.dumps({"n": name, "a": args}, sort_keys=True, ensure_ascii=False, default=str)
    digest = hashlib.sha256(canonical.encode("utf-8")).hexdigest()[:32]
    return f"ai-{turn_id}-{digest}"


class AiConversationViewSet(viewsets.ModelViewSet):
    """List, read (with messages), rename, and delete a user's chat threads."""

    permission_classes = [permissions.IsAuthenticated]
    http_method_names = ["get", "patch", "delete", "head", "options"]

    def get_queryset(self):
        return AiConversation.objects.filter(user=self.request.user)

    def get_serializer_class(self):
        if self.action == "retrieve":
            return AiConversationDetailSerializer
        return AiConversationSerializer


class AiChatView(APIView):
    """Send a message (with optional attachments) and stream the reply as SSE.

    Builds a shop-aware prompt + recent history + the current turn, persists the
    user message (and attachment metadata, never the bytes), opens the relay AI
    stream, then re-emits normalized SSE while accumulating and persisting the
    reply.
    """

    permission_classes = [permissions.IsAuthenticated]

    def post(self, request):
        serializer = AiChatRequestSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)
        payload = serializer.validated_data

        installation = RelayInstallation.load()
        if not relay_ai_available(installation):
            return Response(
                {"detail": "AI is not enabled for this shop."},
                status=status.HTTP_403_FORBIDDEN,
            )

        user_text = payload.get("message", "").strip()
        attachments = payload.get("attachments") or []
        if not user_text and not attachments:
            return Response(
                {"detail": "Message or attachment is required."},
                status=status.HTTP_400_BAD_REQUEST,
            )

        conversation = self._resolve_conversation(request.user, payload.get("conversation_id"))
        if conversation is None:
            return Response(
                {"detail": "Conversation not found."},
                status=status.HTTP_404_NOT_FOUND,
            )

        # Build the prompt (prior history + this turn) BEFORE persisting so an
        # attachment-only (empty-text) turn still reaches the model.
        messages = self._build_messages(
            conversation, user_text, supports_actions=payload.get("supports_actions", False)
        )

        user_message = AiMessage.objects.create(
            conversation=conversation,
            role=AiMessage.ROLE_USER,
            content=user_text,
            attachments=[
                {
                    "kind": a["kind"],
                    "name": a.get("name", ""),
                    "mime": a.get("mime", ""),
                }
                for a in attachments
            ],
        )
        if not conversation.title and user_text:
            conversation.title = user_text[:60]
        conversation.save(update_fields=["title", "updated_at"])

        # Tools let the model query/write real shop data (as the current user).
        # They're advertised on attachment turns TOO, so a vision model can read
        # an uploaded supplier invoice AND act on it (match products, create a
        # purchase order) in one agentic flow — the relay forwards tools on the
        # vision path unchanged. A vision model that can't tool-call simply emits
        # text and the loop ends gracefully (no error). ask_user / action tools
        # are each still gated by the client's declared capability.
        tools = tools_definitions(
            supports_ask_user=payload.get("supports_ask_user", False),
            supports_actions=payload.get("supports_actions", False),
        )

        client = RelayControlClient()
        try:
            first_response = client.open_ai_stream(
                access_token=installation.access_token,
                messages=messages,
                attachments=attachments,
                tools=tools,
                count_usage=True,
            )
        except RelayControlError as exc:
            return _relay_error_response(exc)

        streaming = StreamingHttpResponse(
            self._agentic_stream(
                client=client,
                installation=installation,
                conversation=conversation,
                user_message=user_message,
                messages=messages,
                tools=tools,
                user=request.user,
                first_response=first_response,
            ),
            content_type="text/event-stream",
        )
        streaming["Cache-Control"] = "no-cache"
        streaming["X-Accel-Buffering"] = "no"
        return streaming

    def _resolve_conversation(self, user, conversation_id):
        if conversation_id:
            return AiConversation.objects.filter(user=user, pk=conversation_id).first()
        return AiConversation.objects.create(user=user)

    def _build_messages(self, conversation, user_text="", *, append_user=True, supports_actions=False):
        """Rebuild the model context from the DB.

        Plain user/assistant text turns flow through as before. An assistant turn
        that asked for tools (only ever persisted for a paused ask_user turn) is
        replayed *with* its ``tool_calls``, and each call is immediately followed
        by its tool result — the user's persisted answer when present, otherwise a
        synthesized "no answer" reply. That pairing invariant means a still-open or
        abandoned question never leaves a dangling tool_call, which OpenRouter would
        reject. ``append_user=False`` is used on resume, where the trailing turn is
        the answer (a tool result already in history), not a new user message.
        """
        history = list(
            conversation.messages.filter(
                role__in=[
                    AiMessage.ROLE_USER,
                    AiMessage.ROLE_ASSISTANT,
                    AiMessage.ROLE_TOOL,
                ]
            ).order_by("-created_at")[:HISTORY_WINDOW]
        )
        history.reverse()
        # Index tool replies by the call id they answer, to splice each in right
        # after its assistant tool_call (OpenRouter requires that adjacency).
        tool_replies = {
            message.tool_call_id: message
            for message in history
            if message.role == AiMessage.ROLE_TOOL and message.tool_call_id
        }
        messages = [{"role": "system", "content": build_system_prompt(supports_actions=supports_actions)}]
        for message in history:
            if message.role == AiMessage.ROLE_TOOL:
                continue  # emitted via its assistant turn below
            if message.role == AiMessage.ROLE_ASSISTANT and message.tool_calls:
                messages.append(
                    {
                        "role": "assistant",
                        "content": message.content or "",
                        "tool_calls": message.tool_calls,
                    }
                )
                for call in message.tool_calls:
                    messages.append(self._tool_reply_message(call, tool_replies))
                continue
            if message.content:
                messages.append({"role": message.role, "content": message.content})
        # Always include the current turn (even with empty text) so the relay can
        # attach images/files to it — unless this is a resume (answer already in
        # history as a tool result).
        if append_user:
            messages.append({"role": "user", "content": user_text})
        return messages

    def _tool_reply_message(self, call, tool_replies):
        """The ``role:tool`` reply for one assistant tool_call: the persisted
        answer if we have it, else a synthesized placeholder so the call is never
        left unanswered (which would invalidate the whole prompt)."""
        call_id = call.get("id", "")
        name = (call.get("function") or {}).get("name", "")
        reply = tool_replies.get(call_id)
        if reply is not None and reply.content:
            content = reply.content
        else:
            content = json.dumps({"status": "no_answer"}, ensure_ascii=False)
        return {
            "role": "tool",
            "tool_call_id": call_id,
            "name": name,
            "content": content,
        }

    def _agentic_stream(
        self,
        *,
        client,
        installation,
        conversation,
        user_message,
        messages,
        tools,
        user,
        first_response,
    ):
        """Drive the bounded tool loop: consume a relay turn; if the model asked
        for tools, run them as ``user``, feed the results back, and loop; on a
        normal text turn, stream it live and finish. Only the user-initiated turn
        charges usage — continuations pass count_usage=False."""
        answer = []
        reasoning = []
        tool_events = []
        usage_limits = None
        done_data = {}
        saved = False
        # Set once the model calls ask_user: the turn is persisted as a paused
        # assistant message and the stream ends without a `done` (the client renders
        # the question and resumes via /api/ai/chat/resume/). Guards the finally
        # block so the paused turn isn't re-saved as an ordinary one.
        paused = False
        # Per-turn idempotency salt + a running count of committed writes, both
        # spanning every tool round in this stream (see MAX_MUTATING_WRITES_PER_TURN
        # and _ai_idempotency_key).
        turn_id = uuid4().hex
        mutating_writes = 0
        response = first_response
        try:
            for iteration in range(MAX_TOOL_ITERS + 1):
                turn_text = []
                turn_reasoning = []
                turn_tool_calls = None
                for event in iter_relay_sse(response):
                    event_type = event.get("event")
                    data = event.get("data") or {}
                    if event_type == "delta":
                        text = data.get("text", "")
                        if text:
                            turn_text.append(text)
                            yield sse_event("delta", {"text": text})
                    elif event_type == "reasoning":
                        text = data.get("text", "")
                        if text:
                            turn_reasoning.append(text)
                            yield sse_event("reasoning", {"text": text})
                    elif event_type == "tool_calls":
                        turn_tool_calls = data.get("tool_calls") or []
                    elif event_type == "done":
                        done_data = data
                        if usage_limits is None and data.get("usage_limits"):
                            usage_limits = data.get("usage_limits")
                    elif event_type == "error":
                        yield sse_event("error", {"detail": data.get("detail", "AI error")})
                response.close()

                if not (turn_tool_calls and iteration < MAX_TOOL_ITERS):
                    # Final answer turn — its deltas were streamed live above.
                    answer = turn_text
                    reasoning = turn_reasoning
                    break

                # Tool turn: record the request, run each tool as the user, feed
                # the results back, and loop for the next model turn.
                messages.append(
                    {
                        "role": "assistant",
                        "content": "".join(turn_text),
                        "tool_calls": turn_tool_calls,
                    }
                )

                # ask_user is a client-side tool with no server handler: pause the
                # loop, persist the question, surface it to the client, and stop.
                # The user's answer arrives later via the resume endpoint, which
                # re-enters this same loop. Any sibling data-tool calls in the same
                # turn are intentionally deferred (the model re-issues them after
                # the answer if still needed) — _build_messages synthesizes their
                # replies so the paused turn stays a valid prompt.
                ask_user = self._find_ask_user_call(turn_tool_calls)
                if ask_user is not None:
                    call, spec = ask_user
                    paused = True
                    paused_message = self._save_paused_assistant(
                        conversation,
                        content="".join(turn_text),
                        reasoning="".join(turn_reasoning),
                        tool_calls=turn_tool_calls,
                        ask_call_id=call.get("id", ""),
                        question=spec,
                        data=done_data,
                        tool_events=tool_events,
                    )
                    yield sse_event(
                        "ask_user",
                        {
                            "conversation_id": conversation.pk,
                            "message_id": paused_message.pk,
                            "tool_call_id": call.get("id", ""),
                            "questions": spec["questions"],
                        },
                    )
                    return

                for call in turn_tool_calls:
                    function = call.get("function") or {}
                    name = function.get("name", "")
                    try:
                        args = json.loads(function.get("arguments") or "{}")
                    except (ValueError, TypeError):
                        args = {}
                    if not isinstance(args, dict):
                        args = {}
                    resource = args.get("resource")
                    label = tool_label(name, resource)
                    mutates = is_mutating_tool(name)
                    yield sse_event(
                        "tool",
                        {
                            "name": name,
                            "resource": resource,
                            "label": label,
                            "phase": "start",
                            "mutates": mutates,
                        },
                    )
                    if mutates and mutating_writes >= MAX_MUTATING_WRITES_PER_TURN:
                        # Backstop tripped: refuse to commit further writes this
                        # turn and let the model wrap up (it sees the error).
                        result = {
                            "ok": False,
                            "error": "write_limit_reached",
                            "message": (
                                "بلغت الحد الأقصى لعمليات الإنشاء/التعديل في هذا الدور. "
                                "توقّف وأخبر المستخدم بما أُنجز."
                            ),
                        }
                    else:
                        idem = _ai_idempotency_key(turn_id, name, args) if mutates else None
                        result = execute_tool(name, args, user=user, idempotency_key=idem)
                    ok = bool(result.get("ok"))
                    if mutates and ok:
                        mutating_writes += 1
                    tool_events.append(
                        {
                            "name": name,
                            "resource": resource,
                            "label": label,
                            "arguments": args,
                            "ok": ok,
                            "error": result.get("error"),
                            "mutates": mutates,
                        }
                    )
                    yield sse_event(
                        "tool",
                        {
                            "name": name,
                            "resource": resource,
                            "label": label,
                            "phase": "done",
                            "ok": ok,
                            "mutates": mutates,
                        },
                    )
                    messages.append(
                        {
                            "role": "tool",
                            "tool_call_id": call.get("id", ""),
                            "name": name,
                            "content": json.dumps(result, ensure_ascii=False),
                        }
                    )

                # The next turn after the last allowed round drops tools to force
                # a text answer.
                force_answer = (iteration + 1) >= MAX_TOOL_ITERS
                try:
                    response = client.open_ai_stream(
                        access_token=installation.access_token,
                        messages=messages,
                        tools=None if force_answer else tools,
                        count_usage=False,
                    )
                except RelayControlError:
                    yield sse_event("error", {"detail": "ai stream failed"})
                    break

            message = self._save_assistant(
                conversation,
                "".join(answer),
                "".join(reasoning),
                done_data,
                tool_events,
            )
            saved = True
            yield sse_event(
                "done",
                {
                    "conversation_id": conversation.pk,
                    "message_id": message.pk,
                    # None on resume turns, which continue an existing user turn.
                    "user_message_id": user_message.pk if user_message is not None else None,
                    "model": done_data.get("model", ""),
                    "tier": done_data.get("tier", ""),
                    "usage": done_data.get("usage"),
                    "usage_limits": usage_limits,
                },
            )
        finally:
            if not saved and not paused and ("".join(answer) or "".join(reasoning) or tool_events):
                self._save_assistant(
                    conversation,
                    "".join(answer),
                    "".join(reasoning),
                    done_data,
                    tool_events,
                )
            try:
                response.close()
            except Exception:
                pass

    def _save_assistant(self, conversation, content, reasoning, data, tool_events=None):
        usage = data.get("usage") or {}
        message = AiMessage.objects.create(
            conversation=conversation,
            role=AiMessage.ROLE_ASSISTANT,
            content=content,
            reasoning=reasoning,
            model=data.get("model", ""),
            tier=data.get("tier", ""),
            prompt_tokens=int(usage.get("prompt_tokens") or 0),
            completion_tokens=int(usage.get("completion_tokens") or 0),
            tool_events=tool_events or [],
        )
        AiConversation.objects.filter(pk=conversation.pk).update(updated_at=timezone.now())
        return message

    def _find_ask_user_call(self, tool_calls):
        """Return ``(call, validated_spec)`` for the first ask_user call in the
        batch, or None. The spec is defensively sanitised (the model's JSON can be
        malformed) so the persisted/streamed question is always well-formed."""
        for call in tool_calls or []:
            function = call.get("function") or {}
            if function.get("name") != ASK_USER_TOOL_NAME:
                continue
            # Guarantee a non-empty call id (the model/relay usually supplies one,
            # but defend against an id-less call). Mutating the dict keeps it
            # consistent everywhere the same object is used: the persisted
            # tool_calls, the streamed event, and the resume matcher.
            if not call.get("id"):
                call["id"] = f"ask_{uuid4().hex[:16]}"
            try:
                args = json.loads(function.get("arguments") or "{}")
            except (ValueError, TypeError):
                args = {}
            if not isinstance(args, dict):
                args = {}
            return call, validate_ask_user_spec(args)
        return None

    def _save_paused_assistant(
        self,
        conversation,
        *,
        content,
        reasoning,
        tool_calls,
        ask_call_id,
        question,
        data,
        tool_events=None,
    ):
        """Persist a paused ask_user turn: the assistant message carries its
        ``tool_calls`` (for replay) and ``pending_question`` (for the client to
        render), marked ``awaiting_answer`` until the resume endpoint answers it.
        Any data tools the model ran before pausing are kept in ``tool_events`` so
        the turn's trace survives the pause."""
        usage = data.get("usage") or {}
        message = AiMessage.objects.create(
            conversation=conversation,
            role=AiMessage.ROLE_ASSISTANT,
            content=content,
            reasoning=reasoning,
            tool_calls=tool_calls,
            tool_call_id=ask_call_id,
            pending_question=question,
            status=AiMessage.STATUS_AWAITING_ANSWER,
            tool_events=tool_events or [],
            model=data.get("model", ""),
            tier=data.get("tier", ""),
            prompt_tokens=int(usage.get("prompt_tokens") or 0),
            completion_tokens=int(usage.get("completion_tokens") or 0),
        )
        AiConversation.objects.filter(pk=conversation.pk).update(updated_at=timezone.now())
        return message


class AiChatResumeView(AiChatView):
    """Answer a paused ask_user question and resume the agentic turn.

    Subclasses AiChatView purely to reuse its streaming machinery (_build_messages,
    _agentic_stream, _save_assistant). The user's answer is persisted as the tool
    result that satisfies the pending ask_user call, then the same loop re-opens the
    relay (count_usage=False — one ask→answer is one logical turn) and continues
    from where the model paused. A skip ("declined") resumes too, so an agentic flow
    never deadlocks on an unanswered question.
    """

    def post(self, request):
        serializer = AiChatResumeRequestSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)
        payload = serializer.validated_data

        installation = RelayInstallation.load()
        if not relay_ai_available(installation):
            return Response(
                {"detail": "AI is not enabled for this shop."},
                status=status.HTTP_403_FORBIDDEN,
            )

        conversation = AiConversation.objects.filter(
            user=request.user, pk=payload["conversation_id"]
        ).first()
        if conversation is None:
            return Response(
                {"detail": "Conversation not found."},
                status=status.HTTP_404_NOT_FOUND,
            )

        paused = conversation.messages.filter(
            pk=payload["message_id"],
            role=AiMessage.ROLE_ASSISTANT,
            status=AiMessage.STATUS_AWAITING_ANSWER,
        ).first()
        if paused is None:
            return Response(
                {"detail": "No pending question for this message."},
                status=status.HTTP_409_CONFLICT,
            )

        tool_call_id = payload["tool_call_id"]
        matches = any(
            call.get("id") == tool_call_id
            and (call.get("function") or {}).get("name") == ASK_USER_TOOL_NAME
            for call in (paused.tool_calls or [])
        )
        if not matches:
            return Response(
                {"detail": "tool_call_id does not match the pending question."},
                status=status.HTTP_400_BAD_REQUEST,
            )

        # Persist the user's answer (or skip) as the tool result that satisfies the
        # ask_user call — this is exactly what gets replayed to the model on resume.
        if payload.get("declined"):
            result = {"declined": True}
        else:
            result = {"answers": payload.get("answers") or []}
        AiMessage.objects.create(
            conversation=conversation,
            role=AiMessage.ROLE_TOOL,
            tool_call_id=tool_call_id,
            content=json.dumps(result, ensure_ascii=False),
        )
        paused.status = AiMessage.STATUS_ANSWERED
        paused.pending_question = None
        paused.save(update_fields=["status", "pending_question"])

        supports_actions = payload.get("supports_actions", True)
        messages = self._build_messages(
            conversation, append_user=False, supports_actions=supports_actions
        )
        tools = tools_definitions(
            supports_ask_user=payload.get("supports_ask_user", True),
            supports_actions=supports_actions,
        )

        client = RelayControlClient()
        try:
            first_response = client.open_ai_stream(
                access_token=installation.access_token,
                messages=messages,
                tools=tools,
                count_usage=False,
            )
        except RelayControlError as exc:
            return _relay_error_response(exc)

        streaming = StreamingHttpResponse(
            self._agentic_stream(
                client=client,
                installation=installation,
                conversation=conversation,
                user_message=None,
                messages=messages,
                tools=tools,
                user=request.user,
                first_response=first_response,
            ),
            content_type="text/event-stream",
        )
        streaming["Cache-Control"] = "no-cache"
        streaming["X-Accel-Buffering"] = "no"
        return streaming


class AiUsageView(APIView):
    """Current 5h + weekly AI usage for the shop (powers the usage ring)."""

    permission_classes = [permissions.IsAuthenticated]

    def get(self, request):
        installation = RelayInstallation.load()
        if not relay_ai_available(installation):
            return Response(
                {"detail": "AI is not enabled for this shop."},
                status=status.HTTP_403_FORBIDDEN,
            )
        try:
            usage = RelayControlClient().get_ai_usage(installation.access_token)
        except RelayControlError as exc:
            return _relay_error_response(exc)
        return Response(usage)


class AiConversationTruncateView(APIView):
    """Delete a message and everything after it — powers edit/retry rewind.

    The model context is rebuilt from the DB each turn, so the client cannot just
    drop messages locally; rewinding the conversation must truncate server-side
    too, or the dropped turns would leak back into the next prompt.
    """

    permission_classes = [permissions.IsAuthenticated]

    def post(self, request, pk):
        conversation = AiConversation.objects.filter(user=request.user, pk=pk).first()
        if conversation is None:
            return Response(
                {"detail": "Conversation not found."},
                status=status.HTTP_404_NOT_FOUND,
            )
        target = conversation.messages.filter(pk=request.data.get("message_id")).first()
        if target is None:
            return Response(
                {"detail": "Message not found."},
                status=status.HTTP_404_NOT_FOUND,
            )
        conversation.messages.filter(pk__gte=target.pk).delete()
        AiConversation.objects.filter(pk=conversation.pk).update(updated_at=timezone.now())
        return Response(status=status.HTTP_204_NO_CONTENT)


def _relay_error_response(exc):
    """Map a relay AI HTTP error to an app-facing DRF Response."""
    status_code = getattr(exc, "status_code", None)
    detail = {}
    body = getattr(exc, "body", None)
    if body:
        try:
            detail = json.loads(body)
        except (ValueError, TypeError):
            detail = {}

    if status_code == 429:
        return Response(
            {
                "detail": detail.get("error", "AI usage limit reached."),
                "scope": detail.get("scope"),
                "reset_at": detail.get("reset_at"),
            },
            status=status.HTTP_429_TOO_MANY_REQUESTS,
        )
    if status_code == 422:
        return Response(
            {
                "detail": detail.get("error", "Too many images."),
                "limit": detail.get("limit"),
            },
            status=status.HTTP_422_UNPROCESSABLE_ENTITY,
        )
    if status_code in (401, 402):
        return Response(
            {"detail": "AI is not enabled for this shop."},
            status=status.HTTP_403_FORBIDDEN,
        )
    return Response({"detail": str(exc)}, status=status.HTTP_502_BAD_GATEWAY)
