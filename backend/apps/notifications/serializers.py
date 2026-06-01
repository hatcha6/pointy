from datetime import timedelta

from rest_framework import serializers

from .models import BusinessNotification
from .services import notification_is_hidden_for_user, notification_state_for_user


class BusinessNotificationSerializer(serializers.ModelSerializer):
    acknowledged_at = serializers.SerializerMethodField()
    snoozed_until = serializers.SerializerMethodField()
    is_hidden = serializers.SerializerMethodField()
    hidden_reason = serializers.SerializerMethodField()

    class Meta:
        model = BusinessNotification
        fields = [
            "id",
            "code",
            "category",
            "severity",
            "status",
            "entity_type",
            "entity_id",
            "payload",
            "first_seen_at",
            "last_seen_at",
            "occurrence_count",
            "resolved_at",
            "acknowledged_at",
            "snoozed_until",
            "is_hidden",
            "hidden_reason",
            "created_at",
            "updated_at",
        ]
        read_only_fields = fields

    def get_acknowledged_at(self, obj):
        state = self._state(obj)
        return None if state is None else state.acknowledged_at

    def get_snoozed_until(self, obj):
        state = self._state(obj)
        return None if state is None else state.snoozed_until

    def get_is_hidden(self, obj):
        hidden, _ = notification_is_hidden_for_user(
            obj,
            self.context["request"].user,
        )
        return hidden

    def get_hidden_reason(self, obj):
        _, reason = notification_is_hidden_for_user(
            obj,
            self.context["request"].user,
        )
        return reason

    def _state(self, obj):
        return notification_state_for_user(obj, self.context["request"].user)


class SnoozeBusinessNotificationSerializer(serializers.Serializer):
    hours = serializers.IntegerField(min_value=1, max_value=168, default=4)

    @property
    def duration(self):
        return timedelta(hours=self.validated_data["hours"])
