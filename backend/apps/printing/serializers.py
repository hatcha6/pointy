from django.db import transaction
from rest_framework import serializers
from rest_framework.exceptions import PermissionDenied

from apps.core.roles import user_is_manager
from apps.purchasing.models import PurchaseOrder
from apps.sales.models import Order
from .models import (
    PrinterProfile,
    PrintAgent,
    PrintAuditEvent,
    PrintJob,
    PrintJobEvent,
    PrintTemplate,
    PrintTemplateVersion,
)
from .services import (
    create_print_audit_event,
    create_job_event,
    get_default_receipt_template_version,
    get_or_create_print_agent,
    next_template_version_number,
    report_print_audit_event,
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


class PrintAuditEventSerializer(serializers.ModelSerializer):
    agent_identifier = serializers.CharField(read_only=True)
    username = serializers.CharField(source="user.username", read_only=True)

    class Meta:
        model = PrintAuditEvent
        fields = [
            "id",
            "document_type",
            "action",
            "status",
            "sale_order",
            "purchase_order",
            "document_number",
            "print_job",
            "user",
            "username",
            "agent",
            "agent_identifier",
            "device_name",
            "printer_name",
            "printer_endpoint",
            "message",
            "metadata",
            "created_at",
            "updated_at",
        ]
        read_only_fields = fields


class PrintAuditEventRecordSerializer(serializers.Serializer):
    document_type = serializers.ChoiceField(choices=PrintAuditEvent.DocumentType.choices)
    document_id = serializers.IntegerField(min_value=1)
    action = serializers.ChoiceField(choices=PrintAuditEvent.Action.choices)
    status = serializers.ChoiceField(
        choices=PrintAuditEvent.Status.choices,
        default=PrintAuditEvent.Status.REQUESTED,
        required=False,
    )
    agent = serializers.PrimaryKeyRelatedField(
        queryset=PrintAgent.objects.filter(is_active=True),
        required=False,
    )
    agent_id = serializers.CharField(required=False, allow_blank=False)
    printer_endpoint = serializers.JSONField(required=False)
    device_name = serializers.CharField(required=False, allow_blank=True)
    printer_name = serializers.CharField(required=False, allow_blank=True)
    message = serializers.CharField(required=False, allow_blank=True)
    metadata = serializers.JSONField(required=False)
    print_job = serializers.PrimaryKeyRelatedField(
        queryset=PrintJob.objects.all(),
        required=False,
    )

    def validate(self, attrs):
        attrs = super().validate(attrs)
        document_type = attrs["document_type"]
        request = self.context.get("request")
        user = request.user if request is not None else None
        if document_type == PrintAuditEvent.DocumentType.SALE_ORDER:
            if user is None or not user.has_perm("sales.view_order"):
                raise PermissionDenied("Missing sale order permission.")
            attrs["sale_order"] = self._sale_order(attrs["document_id"], request)
        else:
            if user is None or not user.has_perm("purchasing.view_purchaseorder"):
                raise PermissionDenied("Missing purchase order permission.")
            attrs["purchase_order"] = self._purchase_order(attrs["document_id"])

        agent = attrs.get("agent")
        agent_id = attrs.get("agent_id")
        if agent is None and agent_id:
            agent = get_or_create_print_agent(agent_id)
            if not agent.is_active:
                raise serializers.ValidationError({"agent_id": "Print agent is inactive."})
            attrs["agent"] = agent
        return attrs

    def create(self, validated_data):
        request = self.context.get("request")
        return create_print_audit_event(
            document_type=validated_data["document_type"],
            action=validated_data["action"],
            status=validated_data.get("status", PrintAuditEvent.Status.REQUESTED),
            sale_order=validated_data.get("sale_order"),
            purchase_order=validated_data.get("purchase_order"),
            user=request.user if request is not None else None,
            agent=validated_data.get("agent"),
            agent_identifier=validated_data.get("agent_id", ""),
            printer_endpoint=validated_data.get("printer_endpoint", {}),
            device_name=validated_data.get("device_name", ""),
            printer_name=validated_data.get("printer_name", ""),
            print_job=validated_data.get("print_job"),
            message=validated_data.get("message", ""),
            metadata=validated_data.get("metadata", {}),
        )

    def _sale_order(self, order_id, request):
        queryset = Order.objects.all()
        if request is not None and not user_is_manager(request.user):
            queryset = queryset.filter(
                register_session__owner_key=self._register_session_owner_key(request),
            )
        try:
            return queryset.get(pk=order_id)
        except Order.DoesNotExist as exc:
            raise serializers.ValidationError(
                {"document_id": "Sale order was not found."}
            ) from exc

    def _purchase_order(self, order_id):
        try:
            return PurchaseOrder.objects.get(pk=order_id)
        except PurchaseOrder.DoesNotExist as exc:
            raise serializers.ValidationError(
                {"document_id": "Purchase order was not found."}
            ) from exc

    def _register_session_owner_key(self, request):
        if request.user.is_authenticated:
            return f"user:{request.user.pk}"
        return "anonymous"


class PrintAuditEventReportSerializer(serializers.Serializer):
    status = serializers.ChoiceField(
        choices=[
            PrintAuditEvent.Status.COMPLETED,
            PrintAuditEvent.Status.CANCELED,
            PrintAuditEvent.Status.FAILED,
        ]
    )
    message = serializers.CharField(required=False, allow_blank=True)
    metadata = serializers.JSONField(required=False)

    def update(self, instance, validated_data):
        return report_print_audit_event(
            instance,
            status=validated_data["status"],
            message=validated_data.get("message", ""),
            metadata=validated_data.get("metadata"),
        )
