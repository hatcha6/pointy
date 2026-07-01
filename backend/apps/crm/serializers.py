from __future__ import annotations

from rest_framework import serializers

from .models import (
    Campaign,
    CampaignRecipient,
    Conversation,
    ConversationMessage,
)


class ConversationMessageSerializer(serializers.ModelSerializer):
    outbound_status = serializers.SerializerMethodField()

    class Meta:
        model = ConversationMessage
        fields = [
            "id",
            "direction",
            "body",
            "author",
            "outbound",
            "inbound",
            "outbound_status",
            "created_at",
        ]
        read_only_fields = fields

    def get_outbound_status(self, obj) -> str:
        return obj.outbound.status if obj.outbound_id else ""


class ConversationSerializer(serializers.ModelSerializer):
    customer_name = serializers.SerializerMethodField()

    class Meta:
        model = Conversation
        fields = [
            "id",
            "customer",
            "customer_name",
            "phone",
            "phone_raw",
            "status",
            "last_message_at",
            "last_inbound_at",
            "unread_count",
            "assigned_to",
            "created_at",
        ]
        read_only_fields = fields

    def get_customer_name(self, obj) -> str:
        return obj.customer.full_name if obj.customer_id else ""


class ConversationDetailSerializer(ConversationSerializer):
    messages = ConversationMessageSerializer(many=True, read_only=True)

    class Meta(ConversationSerializer.Meta):
        fields = ConversationSerializer.Meta.fields + ["messages"]
        read_only_fields = fields


class CampaignRecipientSerializer(serializers.ModelSerializer):
    customer_name = serializers.CharField(
        source="customer.full_name", read_only=True
    )
    outbound_status = serializers.SerializerMethodField()

    class Meta:
        model = CampaignRecipient
        fields = [
            "id",
            "customer",
            "customer_name",
            "phone",
            "rendered_body",
            "segments",
            "status",
            "outbound_status",
            "created_at",
        ]
        read_only_fields = fields

    def get_outbound_status(self, obj) -> str:
        return obj.outbound.status if obj.outbound_id else ""


class CampaignSerializer(serializers.ModelSerializer):
    class Meta:
        model = Campaign
        fields = [
            "id",
            "name",
            "body_template",
            "channel",
            "status",
            "rfm_segments",
            "customers",
            "discount_rule",
            "gateway",
            "scheduled_at",
            "created_by",
            "created_via",
            "approved_by",
            "approved_at",
            "total_recipients",
            "sent_count",
            "failed_count",
            "skipped_optout_count",
            "created_at",
            "updated_at",
        ]
        # status + governance + counters are server-controlled: a create/update
        # can never set status (so the AI can draft but never send).
        read_only_fields = [
            "id",
            "status",
            "created_by",
            "created_via",
            "approved_by",
            "approved_at",
            "total_recipients",
            "sent_count",
            "failed_count",
            "skipped_optout_count",
            "created_at",
            "updated_at",
        ]


class CampaignDetailSerializer(CampaignSerializer):
    recipients = CampaignRecipientSerializer(many=True, read_only=True)

    class Meta(CampaignSerializer.Meta):
        fields = CampaignSerializer.Meta.fields + ["recipients"]
