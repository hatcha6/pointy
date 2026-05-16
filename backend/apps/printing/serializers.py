from django.db import transaction
from rest_framework import serializers

from .models import (
    PrinterProfile,
    PrintAgent,
    PrintJob,
    PrintJobEvent,
    PrintTemplate,
    PrintTemplateVersion,
)
from .services import (
    create_job_event,
    get_default_receipt_template_version,
    get_or_create_print_agent,
    next_template_version_number,
)


class PrintTemplateSerializer(serializers.ModelSerializer):
    current_version_number = serializers.IntegerField(
        source="current_version.version_number",
        read_only=True,
    )

    class Meta:
        model = PrintTemplate
        fields = [
            "id",
            "slug",
            "name",
            "template_type",
            "description",
            "is_active",
            "current_version",
            "current_version_number",
            "created_at",
            "updated_at",
        ]
        read_only_fields = ("current_version", "current_version_number", "created_at", "updated_at")


class PrintTemplateVersionSerializer(serializers.ModelSerializer):
    template_slug = serializers.CharField(source="template.slug", read_only=True)
    created_by_username = serializers.CharField(source="created_by.username", read_only=True)

    class Meta:
        model = PrintTemplateVersion
        fields = [
            "id",
            "template",
            "template_slug",
            "version_number",
            "status",
            "content",
            "schema",
            "created_by",
            "created_by_username",
            "published_at",
            "created_at",
            "updated_at",
        ]
        read_only_fields = (
            "version_number",
            "status",
            "created_by",
            "created_by_username",
            "published_at",
            "created_at",
            "updated_at",
        )

    @transaction.atomic
    def create(self, validated_data):
        template = validated_data["template"]
        validated_data["version_number"] = next_template_version_number(template)
        request = self.context.get("request")
        if request is not None and request.user.is_authenticated:
            validated_data["created_by"] = request.user
        return super().create(validated_data)


class PrinterProfileSerializer(serializers.ModelSerializer):
    class Meta:
        model = PrinterProfile
        fields = [
            "id",
            "name",
            "printer_type",
            "settings",
            "is_default",
            "is_active",
            "created_at",
            "updated_at",
        ]
        read_only_fields = ("created_at", "updated_at")


class PrintAgentSerializer(serializers.ModelSerializer):
    class Meta:
        model = PrintAgent
        fields = [
            "id",
            "name",
            "identifier",
            "printer_profile",
            "is_active",
            "last_seen_at",
            "created_at",
            "updated_at",
        ]
        read_only_fields = ("last_seen_at", "created_at", "updated_at")


class PrintJobEventSerializer(serializers.ModelSerializer):
    agent_identifier = serializers.CharField(source="agent.identifier", read_only=True)
    username = serializers.CharField(source="user.username", read_only=True)

    class Meta:
        model = PrintJobEvent
        fields = [
            "id",
            "job",
            "event_type",
            "user",
            "username",
            "agent",
            "agent_identifier",
            "message",
            "metadata",
            "created_at",
        ]
        read_only_fields = fields


class PrintJobSerializer(serializers.ModelSerializer):
    events = PrintJobEventSerializer(many=True, read_only=True)

    class Meta:
        model = PrintJob
        fields = [
            "id",
            "job_type",
            "status",
            "order",
            "template_version",
            "printer_profile",
            "payload",
            "idempotency_key",
            "priority",
            "attempts",
            "claimed_by",
            "claimed_at",
            "printed_at",
            "failed_at",
            "error_message",
            "events",
            "created_at",
            "updated_at",
        ]
        read_only_fields = (
            "status",
            "attempts",
            "claimed_by",
            "claimed_at",
            "printed_at",
            "failed_at",
            "error_message",
            "events",
            "created_at",
            "updated_at",
        )

    def validate(self, attrs):
        attrs = super().validate(attrs)
        if "template_version" not in attrs:
            attrs["template_version"] = get_default_receipt_template_version()
        return attrs

    def create(self, validated_data):
        job = super().create(validated_data)
        request = self.context.get("request")
        create_job_event(
            job,
            PrintJobEvent.Type.CREATED,
            user=request.user if request is not None else None,
            message="Print job created.",
        )
        return job


class PrintJobAgentActionSerializer(serializers.Serializer):
    agent = serializers.PrimaryKeyRelatedField(
        queryset=PrintAgent.objects.filter(is_active=True),
        required=False,
    )
    agent_id = serializers.CharField(required=False, allow_blank=False)
    printer_endpoint = serializers.JSONField(required=False)

    def validate(self, attrs):
        attrs = super().validate(attrs)
        agent = attrs.get("agent")
        agent_id = attrs.get("agent_id")
        if agent is None and not agent_id:
            raise serializers.ValidationError({"agent_id": "Agent id is required."})
        if agent is None:
            agent = get_or_create_print_agent(agent_id)
            if not agent.is_active:
                raise serializers.ValidationError({"agent_id": "Print agent is inactive."})
            attrs["agent"] = agent
        return attrs


class PrintJobFailureSerializer(PrintJobAgentActionSerializer):
    error_message = serializers.CharField(allow_blank=True, required=False)


class PrintJobReportSerializer(PrintJobAgentActionSerializer):
    status = serializers.ChoiceField(
        choices=[
            PrintJob.Status.PRINTED,
            PrintJob.Status.FAILED,
            "completed",
        ],
    )
    message = serializers.CharField(allow_blank=True, required=False)
    error_message = serializers.CharField(allow_blank=True, required=False)
