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
