from __future__ import annotations

from rest_framework import serializers

from .automation import auto_message_states, automatic_kinds
from .models import MessagingGateway, OutboundMessage


class MessagingGatewaySerializer(serializers.ModelSerializer):
    # A shop tunes its gateway, it does not configure one: the relay holds the
    # provider account, so the only writable fields are the shop's own brakes
    # (pace, daily cap, quiet hours) and the switch that stops all SMS.
    class Meta:
        model = MessagingGateway
        fields = [
            "id",
            "name",
            "provider",
            "channel",
            "is_default",
            "is_active",
            "max_messages_per_minute",
            "daily_cap",
            "quiet_hours_start",
            "quiet_hours_end",
            "send_timeout_seconds",
            "auto_messages",
            "last_seen_at",
            "last_error",
            "last_error_at",
            "created_at",
            "updated_at",
        ]
        read_only_fields = [
            "id",
            "name",
            "provider",
            "channel",
            "is_default",
            "send_timeout_seconds",
            "last_seen_at",
            "last_error",
            "last_error_at",
            "created_at",
            "updated_at",
        ]

    def validate(self, attrs):
        start = attrs.get("quiet_hours_start", getattr(self.instance, "quiet_hours_start", None))
        end = attrs.get("quiet_hours_end", getattr(self.instance, "quiet_hours_end", None))
        if (start is None) != (end is None):
            raise serializers.ValidationError(
                {"quiet_hours_end": "حدّد بداية ونهاية أوقات الهدوء معًا، أو اتركهما فارغين."}
            )
        return attrs

    def validate_auto_messages(self, value):
        """Switches for automatic texts, by kind. A partial update keeps the
        switches it does not name."""
        if not isinstance(value, dict):
            raise serializers.ValidationError("أرسل الرسائل التلقائية كقائمة تشغيل لكل نوع.")
        known = set(automatic_kinds())
        unknown = sorted(str(kind) for kind in value if kind not in known)
        if unknown:
            raise serializers.ValidationError(f"أنواع رسائل لا تُرسل تلقائيًا: {', '.join(unknown)}")
        if any(not isinstance(enabled, bool) for enabled in value.values()):
            raise serializers.ValidationError("كل مفتاح تشغيل إما true أو false.")
        current = getattr(self.instance, "auto_messages", None) or {}
        return {**current, **value}

    def to_representation(self, instance):
        data = super().to_representation(instance)
        # Every automatic kind, on or off — not only the ones the shop touched.
        data["auto_messages"] = auto_message_states(instance)
        return data


class OutboundMessageSerializer(serializers.ModelSerializer):
    class Meta:
        model = OutboundMessage
        fields = [
            "id",
            "gateway",
            "channel",
            "to_phone",
            "to_phone_raw",
            "body",
            "template_kind",
            "consent_class",
            "status",
            "segments",
            "provider_message_id",
            "attempts",
            "error_code",
            "error_detail",
            "source_type",
            "source_id",
            "sent_at",
            "delivered_at",
            "created_at",
        ]
        read_only_fields = fields
