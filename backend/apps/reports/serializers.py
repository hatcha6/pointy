from rest_framework import serializers

from .models import ReportRun


class ReportRunSerializer(serializers.ModelSerializer):
    requested_by_username = serializers.CharField(
        source="requested_by.username",
        read_only=True,
    )

    class Meta:
        model = ReportRun
        fields = [
            "id",
            "report_type",
            "params",
            "output_format",
            "status",
            "payload",
            "row_count",
            "checksum",
            "requested_by",
            "requested_by_username",
            "completed_at",
            "error_message",
            "created_at",
            "updated_at",
        ]
        read_only_fields = fields


class ReportRunCreateSerializer(serializers.Serializer):
    report_type = serializers.ChoiceField(choices=ReportRun.ReportType.choices)
    params = serializers.JSONField(required=False, default=dict)
    output_format = serializers.ChoiceField(
        choices=ReportRun.OutputFormat.choices,
        default=ReportRun.OutputFormat.PDF,
    )
