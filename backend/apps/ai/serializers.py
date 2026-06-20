from rest_framework import serializers

from .models import AiConversation, AiMessage


class AiMessageSerializer(serializers.ModelSerializer):
    class Meta:
        model = AiMessage
        fields = [
            "id",
            "role",
            "content",
            "reasoning",
            "attachments",
            "tool_events",
            # Interactive ask_user fields, so a pending question (or an answered
            # one) re-renders from conversation history after a reload/reconnect.
            "tool_calls",
            "tool_call_id",
            "pending_question",
            "status",
            "model",
            "tier",
            "prompt_tokens",
            "completion_tokens",
            "created_at",
        ]


class AiConversationSerializer(serializers.ModelSerializer):
    message_count = serializers.SerializerMethodField()

    class Meta:
        model = AiConversation
        fields = ["id", "title", "created_at", "updated_at", "message_count"]

    def get_message_count(self, obj):
        return obj.messages.count()


class AiConversationDetailSerializer(AiConversationSerializer):
    messages = AiMessageSerializer(many=True, read_only=True)

    class Meta(AiConversationSerializer.Meta):
        fields = AiConversationSerializer.Meta.fields + ["messages"]


class AiAttachmentSerializer(serializers.Serializer):
    kind = serializers.ChoiceField(choices=["image", "file"])
    data_uri = serializers.CharField()
    name = serializers.CharField(required=False, allow_blank=True, default="")
    mime = serializers.CharField(required=False, allow_blank=True, default="")


class AiChatRequestSerializer(serializers.Serializer):
    conversation_id = serializers.IntegerField(required=False)
    message = serializers.CharField(required=False, allow_blank=True, default="")
    attachments = AiAttachmentSerializer(many=True, required=False, default=list)
    # Whether this client can render the interactive ask_user question UI. The
    # tool is only advertised to capable clients, so an older app never receives a
    # question it can't display (it would just hang on an empty bubble).
    supports_ask_user = serializers.BooleanField(required=False, default=False)
    # Whether this client can surface create/edit actions (it shows what the AI
    # changed). The create/update/create_sale tools are advertised only to capable
    # clients, so an older app can never be steered into mutating shop data without
    # the user seeing it happen.
    supports_actions = serializers.BooleanField(required=False, default=False)
    # Whether this client renders the AI's in-app deep links (pointy://...). Only
    # then is the model told it can link the user to pages, so an older app never
    # shows an inert link it can't route.
    supports_navigation = serializers.BooleanField(required=False, default=False)


class AiAnswerSerializer(serializers.Serializer):
    """One answer to one question. Permissive on purpose: the backend does not
    interpret per-type config — it echoes the structured answer back to the model
    as the tool result. The frontend owns per-type validation."""

    question_id = serializers.CharField()
    type = serializers.CharField(required=False, allow_blank=True, default="")
    # Exactly one of these is set depending on the question type.
    value = serializers.JSONField(required=False)
    values = serializers.ListField(required=False)
    other_text = serializers.CharField(
        required=False, allow_blank=True, allow_null=True, default=""
    )
    is_other = serializers.BooleanField(required=False, default=False)


class AiChatResumeRequestSerializer(serializers.Serializer):
    """Resume a paused ask_user turn with the user's answers (or a skip)."""

    conversation_id = serializers.IntegerField()
    message_id = serializers.IntegerField()
    tool_call_id = serializers.CharField()
    answers = AiAnswerSerializer(many=True, required=False, default=list)
    # The user dismissed the question instead of answering — the AI is resumed
    # with a "declined" tool result so an agentic flow never deadlocks.
    declined = serializers.BooleanField(required=False, default=False)
    supports_ask_user = serializers.BooleanField(required=False, default=True)
    # A resume continues a turn the client already proved it can render; default
    # the action capability on so the resumed loop keeps its create/edit tools.
    supports_actions = serializers.BooleanField(required=False, default=True)
    supports_navigation = serializers.BooleanField(required=False, default=True)
