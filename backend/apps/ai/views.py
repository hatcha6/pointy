import json

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
    AiConversationDetailSerializer,
    AiConversationSerializer,
)
from .tools import execute_tool, tool_label, tools_definitions

# How many prior messages to include as context per turn.
HISTORY_WINDOW = 20

# Max tool rounds per user message before the model is forced to answer. Bounds
# runaway tool loops + cost; each round is one (uncharged) relay continuation.
MAX_TOOL_ITERS = 6


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
        messages = self._build_messages(conversation, user_text)

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

        # Tools let the model query real shop data (as the current user). Skip
        # them for attachment turns, which route to a vision model that may not
        # support tool-calling.
        tools = None if attachments else tools_definitions()

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

    def _build_messages(self, conversation, user_text):
        history = list(
            conversation.messages.filter(
                role__in=[AiMessage.ROLE_USER, AiMessage.ROLE_ASSISTANT]
            ).order_by("-created_at")[:HISTORY_WINDOW]
        )
        history.reverse()
        messages = [{"role": "system", "content": build_system_prompt()}]
        for message in history:
            if message.content:
                messages.append({"role": message.role, "content": message.content})
        # Always include the current turn (even with empty text) so the relay can
        # attach images/files to it.
        messages.append({"role": "user", "content": user_text})
        return messages

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
                    yield sse_event(
                        "tool",
                        {
                            "name": name,
                            "resource": resource,
                            "label": label,
                            "phase": "start",
                        },
                    )
                    result = execute_tool(name, args, user=user)
                    ok = bool(result.get("ok"))
                    tool_events.append(
                        {
                            "name": name,
                            "resource": resource,
                            "arguments": args,
                            "ok": ok,
                            "error": result.get("error"),
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
                    "user_message_id": user_message.pk,
                    "model": done_data.get("model", ""),
                    "tier": done_data.get("tier", ""),
                    "usage": done_data.get("usage"),
                    "usage_limits": usage_limits,
                },
            )
        finally:
            if not saved and ("".join(answer) or "".join(reasoning) or tool_events):
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
