from django.conf import settings
from django.db import models


class AiConversation(models.Model):
    """A chat thread between a Pointy user and the relay-hosted assistant.

    Conversation content lives on-prem in the shop's own database; the relay is
    stateless about chat content and only proxies turns to OpenRouter.
    """

    user = models.ForeignKey(
        settings.AUTH_USER_MODEL,
        on_delete=models.CASCADE,
        related_name="ai_conversations",
    )
    title = models.CharField(max_length=200, blank=True)
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        ordering = ["-updated_at", "-id"]

    def __str__(self):
        return self.title or f"Conversation {self.pk}"


class AiMessage(models.Model):
    ROLE_USER = "user"
    ROLE_ASSISTANT = "assistant"
    ROLE_SYSTEM = "system"
    # A tool-result turn: the reply that satisfies an assistant tool_call. For the
    # interactive ask_user tool this carries the *user's answer* (the human is the
    # tool), so a paused agentic turn can be resumed by replaying it to the model.
    ROLE_TOOL = "tool"
    ROLE_CHOICES = [
        (ROLE_USER, "user"),
        (ROLE_ASSISTANT, "assistant"),
        (ROLE_SYSTEM, "system"),
        (ROLE_TOOL, "tool"),
    ]

    # Lifecycle of an interactive (ask_user) assistant turn. "" = an ordinary turn.
    STATUS_AWAITING_ANSWER = "awaiting_answer"
    STATUS_ANSWERED = "answered"

    conversation = models.ForeignKey(
        AiConversation,
        on_delete=models.CASCADE,
        related_name="messages",
    )
    role = models.CharField(max_length=16, choices=ROLE_CHOICES)
    content = models.TextField(blank=True)
    # The model's reasoning/thinking, when it exposes it (shown collapsed in the UI).
    reasoning = models.TextField(blank=True)
    # Lightweight metadata (name/kind/mime) of attachments sent with the turn —
    # never the bytes, which are forwarded to the model and not stored.
    attachments = models.JSONField(default=list, blank=True)
    # Compact trace of any tools the assistant ran to answer (name/resource/args/
    # ok) — for re-rendering "queried X" chips; never the full result rows.
    tool_events = models.JSONField(default=list, blank=True)
    # The OpenAI tool_calls payload of an assistant turn that asked for tools —
    # persisted only for a paused ask_user turn so the call can be replayed to the
    # model on resume (ordinary tool turns resolve in one request and don't need it).
    tool_calls = models.JSONField(default=list, blank=True)
    # On a ROLE_TOOL row: the id of the assistant tool_call this reply answers
    # (OpenRouter requires the id to match). On a paused assistant row: the id of
    # its pending ask_user call, so the resume request can be matched to it.
    tool_call_id = models.CharField(max_length=64, blank=True, default="")
    # The pending ask_user question spec ({"questions": [...]}) on a paused
    # assistant turn, so the client can (re-)render the question card — including
    # after a reload/reconnect. Cleared once answered.
    pending_question = models.JSONField(null=True, blank=True)
    # "" (normal) / awaiting_answer / answered — marks an interactive turn.
    status = models.CharField(max_length=20, blank=True, default="")
    # The concrete OpenRouter model id and the abstract tier the relay used.
    model = models.CharField(max_length=120, blank=True)
    tier = models.CharField(max_length=20, blank=True)
    prompt_tokens = models.PositiveIntegerField(default=0)
    completion_tokens = models.PositiveIntegerField(default=0)
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        ordering = ["created_at", "id"]

    def __str__(self):
        return f"{self.role}: {self.content[:40]}"
