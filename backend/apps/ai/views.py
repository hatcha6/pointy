import hashlib
import json
import logging
import re
import urllib.parse
import urllib.request
from datetime import timedelta
from uuid import uuid4

from django.conf import settings
from django.core.cache import cache
from django.core.handlers.asgi import ASGIRequest
from django.http import HttpResponse, StreamingHttpResponse
from django.urls import reverse
from django.utils import timezone
from rest_framework import permissions, status, viewsets
from rest_framework.response import Response
from rest_framework.views import APIView

from apps.core.dashboard import build_dashboard_snapshot
from apps.core.models import RelayInstallation
from apps.core.relay import RelayControlClient, RelayControlError, relay_ai_available
from apps.core.streaming import aiter_in_thread

from .dashboard_digest import generate_dashboard_digest
from .models import AiConversation, AiMessage
from .relay_stream import build_system_prompt, favicon_url_for, iter_relay_sse, sse_event
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

logger = logging.getLogger(__name__)

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


# How much of a tool's JSON result to keep for the tappable "inspect" chip — large
# enough to debug a match/create result, bounded so it never bloats the SSE or row.
AI_TOOL_OUTPUT_PREVIEW_CHARS = 6000


def _tool_output_preview(result):
    """A bounded JSON string of a tool result, for the inspectable chip. Truncated
    with a marker so a big payload (e.g. many invoice candidates) stays small."""
    try:
        text = json.dumps(result, ensure_ascii=False, indent=2, default=str)
    except (TypeError, ValueError):
        text = str(result)
    if len(text) > AI_TOOL_OUTPUT_PREVIEW_CHARS:
        return text[:AI_TOOL_OUTPUT_PREVIEW_CHARS] + "\n… (مقتطع)"
    return text


def _fallback_title(user_text, attachments):
    """A conversation title used until/unless the relay returns an AI-generated one:
    the trimmed first message, or a hint from an attachment-only turn."""
    text = (user_text or "").strip()
    if text:
        return text[:60]
    if attachments:
        first = attachments[0]
        # A voice turn has only a technical filename (e.g. "voice-message.wav") —
        # never show that as a title; use a readable label instead.
        if (first.get("kind") or "") == "audio":
            return "رسالة صوتية"
        name = (first.get("name") or "").strip()
        return (name or "مرفق")[:60]
    return ""


def _learn_product_aliases(paused, answers):
    """Remember the invoice name a user just confirmed for an existing product, so
    the same wording auto-matches next time. For each ``product_picker`` answer that
    PICKED an existing variant (not "create new"), records the question's invoice
    name (``config.name``) as a learned alias of that variant's product. Idempotent
    and best-effort — a failure here must never break resuming the turn."""
    spec = paused.pending_question or {}
    # invoice name keyed by question id, for the product_picker questions only.
    invoice_names = {
        question.get("id"): (question.get("config") or {}).get("name")
        for question in (spec.get("questions") or [])
        if question.get("type") == "product_picker"
    }
    if not invoice_names:
        return
    try:
        from apps.catalog.models import ProductAlias, ProductVariant

        for answer in answers:
            if not isinstance(answer, dict) or answer.get("is_other"):
                continue
            name = (invoice_names.get(answer.get("question_id")) or "").strip()
            variant_id = answer.get("value")
            if not name or variant_id in (None, ""):
                continue
            variant = (
                ProductVariant.objects.filter(pk=variant_id)
                .select_related("product")
                .first()
            )
            if variant is not None:
                ProductAlias.remember(variant.product, name, source=ProductAlias.Source.INVOICE)
    except Exception:
        logger.exception("AI product-alias learning failed")


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
            conversation,
            user_text,
            supports_actions=payload.get("supports_actions", False),
            supports_navigation=payload.get("supports_navigation", False),
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
        # Name the conversation on its first turn: ask the relay for a good AI title
        # (returned in the done event), with a truncated fallback set now so there's
        # always *something* even if the title call fails or the turn pauses.
        wants_title = not conversation.title
        if wants_title:
            conversation.title = _fallback_title(user_text, attachments)
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
                want_title=wants_title,
            )
        except RelayControlError as exc:
            return _relay_error_response(exc)

        return self._sse_response(
            request,
            self._agentic_stream(
                client=client,
                installation=installation,
                conversation=conversation,
                user_message=user_message,
                messages=messages,
                tools=tools,
                user=request.user,
                first_response=first_response,
                apply_title=wants_title,
                favicon_base=request.build_absolute_uri(reverse("ai-favicon")),
            ),
        )

    def _sse_response(self, request, stream):
        """Wrap a turn generator in the SSE StreamingHttpResponse.

        Served over ASGI (uvicorn in production), Django would buffer a sync
        generator wholesale — after warning that it needs an asynchronous
        iterator — so the client would see nothing until the whole agentic turn
        finished. Bridge the generator to a chunk-by-chunk async iterator
        there; under WSGI (runserver, tests) sync generators stream natively.
        """
        django_request = getattr(request, "_request", request)
        if isinstance(django_request, ASGIRequest):
            stream = aiter_in_thread(stream)
        streaming = StreamingHttpResponse(stream, content_type="text/event-stream")
        streaming["Cache-Control"] = "no-cache"
        streaming["X-Accel-Buffering"] = "no"
        return streaming

    def _resolve_conversation(self, user, conversation_id):
        if conversation_id:
            return AiConversation.objects.filter(user=user, pk=conversation_id).first()
        return AiConversation.objects.create(user=user)

    def _build_messages(
        self,
        conversation,
        user_text="",
        *,
        append_user=True,
        supports_actions=False,
        supports_navigation=False,
    ):
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
        messages = [
            {
                "role": "system",
                "content": build_system_prompt(
                    supports_actions=supports_actions,
                    supports_navigation=supports_navigation,
                ),
            }
        ]
        for message in history:
            if message.role == AiMessage.ROLE_TOOL:
                continue  # emitted via its assistant turn below
            if message.role == AiMessage.ROLE_ASSISTANT and message.tool_calls:
                # Replay any tool rounds the model ran earlier in this turn before it
                # paused (already in wire format, each call paired with its result),
                # so what it extracted — e.g. a whole invoice — survives the pause.
                for prior in message.prior_tool_messages or []:
                    messages.append(prior)
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
        apply_title=False,
        favicon_base="",
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
        # The difficulty tier the relay classified for this turn's first request.
        # Carried onto every continuation so the whole agentic flow rides that one
        # dynamic decision (a hard PO-from-invoice escalates; a trivial flow stays
        # cheap) instead of the relay re-routing — or collapsing to a fixed tier —
        # each round.
        routed_tier = ""
        # The AI conversation title the relay generated on the first turn (set once),
        # persisted as soon as it arrives so even a paused turn gets a good name.
        generated_title = ""
        # Whether this turn used a live web search (carried onto continuations so an
        # agentic web+tools flow keeps it), and the de-duplicated source citations
        # accumulated across the turn's rounds.
        web_searched = False
        collected_sources = []
        seen_source_urls = set()
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
        # Where this turn's own messages begin (after system + history + user). Used
        # to snapshot the tool rounds run before a pause so they survive resume.
        base_len = len(messages)
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
                        if not routed_tier and data.get("route_tier"):
                            routed_tier = data.get("route_tier")
                        if data.get("web_search"):
                            web_searched = True
                        for src in data.get("sources") or []:
                            if not isinstance(src, dict):
                                continue
                            url = (src.get("url") or "").strip()
                            if url and url not in seen_source_urls:
                                seen_source_urls.add(url)
                                collected_sources.append(
                                    {"url": url, "title": (src.get("title") or "").strip()}
                                )
                        if apply_title and not generated_title and data.get("title"):
                            generated_title = data.get("title")
                            self._apply_conversation_title(conversation, generated_title)
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
                    # Everything appended this turn except the just-added ask_user
                    # assistant entry (persisted separately below): the earlier tool
                    # rounds + their results, in wire order. This is what keeps an
                    # extracted invoice alive across the pause.
                    prior_tool_messages = messages[base_len:-1]
                    paused_message = self._save_paused_assistant(
                        conversation,
                        content="".join(turn_text),
                        reasoning="".join(turn_reasoning),
                        tool_calls=turn_tool_calls,
                        ask_call_id=call.get("id", ""),
                        question=spec,
                        data=done_data,
                        tool_events=tool_events,
                        prior_tool_messages=prior_tool_messages,
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
                    # A truncated preview of the result so the user can tap the chip
                    # to inspect what the tool returned (debugging) — streamed live
                    # and persisted, bounded so a big result can't bloat the row.
                    output_preview = _tool_output_preview(result)
                    tool_events.append(
                        {
                            "name": name,
                            "resource": resource,
                            "label": label,
                            "arguments": args,
                            "ok": ok,
                            "error": result.get("error"),
                            "mutates": mutates,
                            "output": output_preview,
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
                            "arguments": args,
                            "output": output_preview,
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
                        route_tier=routed_tier,
                        web_search=web_searched,
                        # Keep asking for a title until one lands. A voice turn can't
                        # be titled until the model actually replies (no user text),
                        # which may be after a tool round — so the request must ride
                        # the continuation that produces the answer, not just turn 1.
                        want_title=apply_title and not generated_title,
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
                sources=collected_sources,
                web_searched=web_searched,
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
                    # The conversation's name (AI-generated on the first turn, else
                    # the fallback) so the client can show it without a refetch.
                    "title": conversation.title,
                    # Web-search sources (favicon avatars) + whether the web was used.
                    # Each source carries a same-origin favicon-proxy URL for the app.
                    "sources": [
                        {**src, "favicon": favicon_url_for(favicon_base, src["url"])}
                        for src in collected_sources
                    ],
                    "web_search": web_searched,
                },
            )
        except Exception:
            # A mid-stream failure — most often the relay tunnel dropping the
            # upstream SSE connection (IncompleteRead / ConnectionReset /
            # timeout while iterating iter_relay_sse, none of which are a
            # RelayControlError) — must never escape this generator. Under ASGI
            # aiter_in_thread would re-raise it and uvicorn would log "Exception
            # in ASGI application" while the client's stream just dies with no
            # signal. Emit a clean SSE error instead and end the turn; the
            # finally below still persists any partial answer. GeneratorExit
            # (client disconnect / early aclose) is a BaseException, not caught
            # here, so early-close cleanup keeps working.
            logger.exception("AI chat stream failed mid-turn")
            yield sse_event("error", {"detail": "ai stream failed"})
        finally:
            if not saved and not paused and ("".join(answer) or "".join(reasoning) or tool_events):
                self._save_assistant(
                    conversation,
                    "".join(answer),
                    "".join(reasoning),
                    done_data,
                    tool_events,
                    sources=collected_sources,
                    web_searched=web_searched,
                )
            try:
                response.close()
            except Exception:
                pass

    def _apply_conversation_title(self, conversation, title):
        """Persist the AI-generated conversation title (overriding the truncated
        fallback set on the first turn). No-op for a blank title."""
        title = (title or "").strip()[:200]
        if not title:
            return
        conversation.title = title
        AiConversation.objects.filter(pk=conversation.pk).update(title=title)

    def _save_assistant(
        self, conversation, content, reasoning, data, tool_events=None, sources=None, web_searched=False
    ):
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
            sources=sources or [],
            web_searched=bool(web_searched),
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
        prior_tool_messages=None,
    ):
        """Persist a paused ask_user turn: the assistant message carries its
        ``tool_calls`` (for replay) and ``pending_question`` (for the client to
        render), marked ``awaiting_answer`` until the resume endpoint answers it.
        Any data tools the model ran before pausing are kept in ``tool_events`` so
        the turn's trace survives the pause, and their full results in
        ``prior_tool_messages`` so the model can read them again on resume."""
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
            prior_tool_messages=prior_tool_messages or [],
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
            answers = payload.get("answers") or []
            result = {"answers": answers}
            # Learn from the confirmation: a product_picker pick teaches us which
            # product the invoice's name meant, so it auto-matches next time.
            _learn_product_aliases(paused, answers)
        AiMessage.objects.create(
            conversation=conversation,
            role=AiMessage.ROLE_TOOL,
            tool_call_id=tool_call_id,
            content=json.dumps(result, ensure_ascii=False),
        )
        # Keep the question spec (pending_question) on the answered turn so the card
        # re-renders read-only from history; ``status`` marks it no longer pending.
        paused.status = AiMessage.STATUS_ANSWERED
        paused.save(update_fields=["status"])

        supports_actions = payload.get("supports_actions", True)
        messages = self._build_messages(
            conversation,
            append_user=False,
            supports_actions=supports_actions,
            supports_navigation=payload.get("supports_navigation", True),
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
                # Resume is a continuation of the original turn — carry its tier
                # (persisted on the paused message) so a resumed PO/agentic flow
                # keeps the difficulty it was routed to, not a default.
                route_tier=paused.tier,
            )
        except RelayControlError as exc:
            return _relay_error_response(exc)

        return self._sse_response(
            request,
            self._agentic_stream(
                client=client,
                installation=installation,
                conversation=conversation,
                user_message=None,
                messages=messages,
                tools=tools,
                user=request.user,
                first_response=first_response,
                favicon_base=request.build_absolute_uri(reverse("ai-favicon")),
            ),
        )


# Favicons are tiny; cap the proxied bytes and validate the host to a plain name.
_FAVICON_MAX_BYTES = 256 * 1024
_FAVICON_HOST_RE = re.compile(r"^[a-z0-9.-]{1,253}$")
_FAVICON_ENDPOINT = "https://t2.gstatic.com/faviconV2"


class AiFaviconView(APIView):
    """Same-origin favicon proxy for AI web-search source avatars.

    Flutter web (CanvasKit) can't decode the public favicon services cross-origin,
    so the app loads each source's favicon from here — like it does product images
    — and we fetch it server-side from Google's favicon endpoint. Unauthenticated:
    it returns only a public site icon (no shop data), and image loads don't carry
    the app's auth. SSRF-safe: the requested host is only a query param to the fixed
    Google endpoint; we never fetch the host directly.
    """

    permission_classes = [permissions.AllowAny]

    def get(self, request):
        domain = (request.GET.get("domain") or "").strip().lower()
        if not domain or not _FAVICON_HOST_RE.match(domain):
            return Response(status=status.HTTP_400_BAD_REQUEST)
        params = urllib.parse.urlencode(
            {
                "client": "SOCIAL",
                "type": "FAVICON",
                "fallback_opts": "TYPE,SIZE,URL",
                "url": f"https://{domain}",
                "size": "64",
            }
        )
        try:
            req = urllib.request.Request(
                f"{_FAVICON_ENDPOINT}?{params}",
                headers={"User-Agent": "Pointy"},
            )
            with urllib.request.urlopen(req, timeout=6) as resp:
                content_type = resp.headers.get("Content-Type", "")
                content = resp.read(_FAVICON_MAX_BYTES + 1)
        except Exception:
            # Any failure → 404 so the client falls back to its globe glyph.
            return Response(status=status.HTTP_404_NOT_FOUND)
        if not content or len(content) > _FAVICON_MAX_BYTES or not content_type.startswith("image/"):
            return Response(status=status.HTTP_404_NOT_FOUND)
        response = HttpResponse(content, content_type=content_type)
        response["Cache-Control"] = "public, max-age=604800"
        return response


class AiUsageView(APIView):
    """Current 5h + weekly AI usage for the shop (powers the usage ring)."""

    permission_classes = [permissions.IsAuthenticated]

    _CACHE_KEY = "pointy:ai:usage:{installation_id}"

    def get(self, request):
        installation = RelayInstallation.load()
        if not relay_ai_available(installation):
            return Response(
                {"detail": "AI is not enabled for this shop."},
                status=status.HTTP_403_FORBIDDEN,
            )
        # The ring is polled by every device but the counters only move when
        # someone actually chats; a short shop-global cache turns the fleet's
        # polls into one relay round-trip per window. Fail-open on Redis.
        ttl = int(getattr(settings, "POINTY_AI_USAGE_CACHE_TTL", 0))
        cache_key = self._CACHE_KEY.format(installation_id=installation.installation_id)
        if ttl > 0:
            try:
                cached = cache.get(cache_key)
            except Exception:  # noqa: BLE001
                cached = None
            if cached is not None:
                return Response(cached)
        try:
            usage = RelayControlClient().get_ai_usage(installation.access_token)
        except RelayControlError as exc:
            return _relay_error_response(exc)
        if ttl > 0:
            try:
                cache.set(cache_key, usage, ttl)
            except Exception:  # noqa: BLE001
                pass
        return Response(usage)


class DashboardAiDigestView(APIView):
    """The dashboard's inline AI text: a short daily brief + per-card explainers.

    Reuses the exact capability-gated dashboard snapshot, generates the text with
    ONE non-persisted, non-metered relay call, and caches it for the rest of the
    day (per user + period) so the dashboard renders cached text instantly and
    the model runs at most once a day. Always 200 with possibly-empty content so
    the client simply shows nothing when there's no digest."""

    permission_classes = [permissions.IsAuthenticated]

    _EMPTY = {"brief": "", "explainers": {}, "generated_at": None}

    def get(self, request):
        installation = RelayInstallation.load()
        if not relay_ai_available(installation):
            return Response(
                {"detail": "AI is not enabled for this shop."},
                status=status.HTTP_403_FORBIDDEN,
            )

        snapshot = build_dashboard_snapshot(request)
        sections = snapshot.get("sections") or {}
        period_days = (snapshot.get("period") or {}).get("days", 30)

        # Bump the version to invalidate every shop's cached digest at once when
        # the figures shape or generation prompt changes.
        cache_key = (
            f"ai_dashboard_digest:v2:{request.user.pk}:"
            f"{period_days}:{timezone.localdate().isoformat()}"
        )
        try:
            cached = cache.get(cache_key)
        except Exception:
            cached = None
        if cached is not None:
            return Response(cached)

        digest = generate_dashboard_digest(installation, sections, period_days)
        if digest is None:
            # Don't cache a miss — a transient relay hiccup shouldn't blank the
            # digest for the rest of the day.
            return Response(self._EMPTY)

        try:
            cache.set(cache_key, digest, timeout=_seconds_until_local_midnight())
        except Exception:
            pass
        return Response(digest)


def _seconds_until_local_midnight():
    """Seconds from now until the next local midnight, so a cached digest expires
    at the day boundary (and regenerates fresh the next day). Floored so a call
    moments before midnight still caches briefly rather than for ~0 seconds."""
    now = timezone.localtime()
    tomorrow = (now + timedelta(days=1)).replace(
        hour=0, minute=0, second=0, microsecond=0
    )
    return max(int((tomorrow - now).total_seconds()), 300)


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
