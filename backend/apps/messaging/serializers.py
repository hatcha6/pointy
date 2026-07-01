from __future__ import annotations

from rest_framework import serializers

from .models import MessagingGateway, OutboundMessage

_SECRET_FIELDS = ("password", "webhook_signing_key")


class MessagingGatewaySerializer(serializers.ModelSerializer):
    # Secrets are write-only: accepted on create/update, never echoed back. GET
    # exposes only whether each secret is set.
    password = serializers.CharField(write_only=True, required=False, allow_blank=True)
    webhook_signing_key = serializers.CharField(
        write_only=True, required=False, allow_blank=True
    )
    has_password = serializers.SerializerMethodField()
    has_webhook_signing_key = serializers.SerializerMethodField()

    class Meta:
        model = MessagingGateway
        fields = [
            "id",
            "name",
            "provider",
            "channel",
            "config",
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
            "password",
            "webhook_signing_key",
            "has_password",
            "has_webhook_signing_key",
            "created_at",
            "updated_at",
        ]
        read_only_fields = [
            "last_seen_at",
            "last_error",
            "last_error_at",
            "created_at",
            "updated_at",
        ]

    def get_has_password(self, obj) -> bool:
        return obj.has_secret("password")

    def get_has_webhook_signing_key(self, obj) -> bool:
        return obj.has_secret("webhook_signing_key")

    def _pop_secrets(self, validated_data) -> dict:
        return {k: validated_data.pop(k) for k in _SECRET_FIELDS if k in validated_data}

    def create(self, validated_data):
        secrets_in = self._pop_secrets(validated_data)
        instance = MessagingGateway(**validated_data)
        for key, value in secrets_in.items():
            instance.set_secret(key, value)
        instance.save()
        return instance

    def update(self, instance, validated_data):
        secrets_in = self._pop_secrets(validated_data)
        for attr, value in validated_data.items():
            setattr(instance, attr, value)
        for key, value in secrets_in.items():
            instance.set_secret(key, value)
        instance.save()
        return instance


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
