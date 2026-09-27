from __future__ import annotations

from rest_framework import serializers

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
