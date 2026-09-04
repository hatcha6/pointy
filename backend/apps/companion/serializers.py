from django.utils import timezone
from rest_framework import serializers

from apps.attachments.serializers import AttachmentSummarySerializer
from apps.attachments.services import parse_owner_type, resolve_attachment_owner

from .models import (
    CompanionCaptureRequest,
    CompanionDevice,
    CompanionEvent,
)


class CompanionDeviceSerializer(serializers.ModelSerializer):
    is_live = serializers.BooleanField(read_only=True)
    paired_by_username = serializers.CharField(
        source="paired_by.username", read_only=True
    )

    class Meta:
        model = CompanionDevice
        fields = [
            "id",
            "till_key",
            "label",
            "paired_by",
            "paired_by_username",
            "user_agent",
            "address",
            "last_seen_at",
            "is_paused",
            "is_live",
            "revoked_at",
            "revoked_reason",
            "created_at",
        ]
        read_only_fields = [
            field for field in fields if field not in {"label", "is_paused"}
        ]


class CompanionEventSerializer(serializers.ModelSerializer):
    device_label = serializers.CharField(source="device.label", read_only=True)
    attachment_detail = serializers.SerializerMethodField()

    class Meta:
        model = CompanionEvent
        fields = [
            "id",
            "kind",
            "payload",
            "device",
            "device_label",
            "attachment",
            "attachment_detail",
            "capture_request",
            "created_at",
        ]
        read_only_fields = fields

    def get_attachment_detail(self, event):
        if event.attachment_id is None:
            return None
        return AttachmentSummarySerializer(
            event.attachment, context=self.context
        ).data


class CompanionCaptureRequestSerializer(serializers.ModelSerializer):
    # Write-only: ``owner`` is a GenericForeignKey, so there is no ``owner_id``
    # attribute to read back. The resolved target comes back as ``target``.
    owner_type = serializers.CharField(
        required=False, allow_blank=True, write_only=True
    )
    owner_id = serializers.IntegerField(
        required=False, allow_null=True, write_only=True
    )
    target = serializers.SerializerMethodField()

    class Meta:
        model = CompanionCaptureRequest
        fields = [
            "id",
            "till_key",
            "prompt",
            "owner_type",
            "owner_id",
            "target",
            "role",
            "is_primary",
            "allow_multiple",
            "status",
            "expires_at",
            "created_at",
        ]
        read_only_fields = ["id", "status", "expires_at", "created_at", "target"]

    def get_target(self, capture_request):
        if capture_request.owner_content_type_id is None:
            return None
        content_type = capture_request.owner_content_type
        return {
            "owner_type": f"{content_type.app_label}.{content_type.model}",
            "owner_id": capture_request.owner_object_id,
        }

    def validate(self, attrs):
        owner_type = (attrs.get("owner_type") or "").strip()
        owner_id = attrs.get("owner_id")
        if bool(owner_type) != bool(owner_id):
            raise serializers.ValidationError(
                {"owner_type": "Give both a target type and a target id, or neither."}
            )
        if owner_type:
            # Reuses the attachment allow-list, so a capture request can never
            # name a destination the attachment layer would have refused.
            parse_owner_type(owner_type)
            attrs["_owner"] = resolve_attachment_owner(owner_type, owner_id)
        return attrs


class CompanionContextSerializer(serializers.Serializer):
    """What the phone needs to know, and nothing else.

    Everything here is either about the phone itself or a prompt the till chose
    to show it. A companion never learns what is in the catalogue, the till, or
    the day's takings.
    """

    shop_name = serializers.CharField()
    till_label = serializers.CharField()
    device_id = serializers.IntegerField()
    device_label = serializers.CharField()
    is_paused = serializers.BooleanField()
    server_time = serializers.DateTimeField(default=timezone.now)
    capture_request = serializers.SerializerMethodField()

    def get_capture_request(self, data):
        request = data.get("capture_request")
        if request is None:
            return None
        return {
            "id": request.pk,
            "prompt": request.prompt,
            "allow_multiple": request.allow_multiple,
            "expires_at": request.expires_at,
        }
