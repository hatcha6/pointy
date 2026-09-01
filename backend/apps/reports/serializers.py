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
            "figures_checksum",
            "requested_by",
            "requested_by_username",
            "completed_at",
            "error_message",
            "created_at",
            "updated_at",
        ]
        read_only_fields = fields


class ReportRunListSerializer(serializers.ModelSerializer):
    """A row in the run history: what was run, over what, by whom.

    Deliberately without ``payload``. The history exists so an accountant can
    find the run they issued last month and check it still holds; sending every
    listed run's rows to render that table would put megabytes on the wire for
    a list of dates.
    """

    requested_by_username = serializers.CharField(
        source="requested_by.username",
        read_only=True,
    )
    period_start = serializers.SerializerMethodField()
    period_end = serializers.SerializerMethodField()
    truncated = serializers.SerializerMethodField()

    class Meta:
        model = ReportRun
        fields = [
            "id",
            "report_type",
            "params",
            "output_format",
            "status",
            "row_count",
            "checksum",
            "figures_checksum",
            "requested_by",
            "requested_by_username",
            "period_start",
            "period_end",
            "truncated",
            "completed_at",
            "error_message",
            "created_at",
        ]
        read_only_fields = fields

    def get_period_start(self, run):
        return (run.payload.get("period") or {}).get("start_date", "")

    def get_period_end(self, run):
        return (run.payload.get("period") or {}).get("end_date", "")

    def get_truncated(self, run):
        return bool((run.payload.get("audit") or {}).get("truncated"))


class ReportRunCreateSerializer(serializers.Serializer):
    report_type = serializers.ChoiceField(choices=ReportRun.ReportType.choices)
    params = serializers.JSONField(required=False, default=dict)
    output_format = serializers.ChoiceField(
        choices=ReportRun.OutputFormat.choices,
        default=ReportRun.OutputFormat.PDF,
    )

    def validate_params(self, value):
        if value in (None, ""):
            return {}
        if not isinstance(value, dict):
            raise serializers.ValidationError("Parameters must be an object.")
        return value


class PeriodLockSerializer(serializers.Serializer):
    """The accounting calendar: which month the year opens on, and how far the
    books are closed.

    ``locked_through`` of ``null`` re-opens everything; a date closes the books
    through it. ``fiscal_year_start_month`` is optional — sending only the year
    start leaves the lock where it is, which is what the first-time setup does.
    """

    locked_through = serializers.DateField(allow_null=True, required=False)
    fiscal_year_start_month = serializers.IntegerField(
        required=False, min_value=1, max_value=12
    )
    note = serializers.CharField(required=False, allow_blank=True, max_length=240)
    acknowledged = serializers.BooleanField(required=False, default=False)

    def validate(self, attrs):
        if "locked_through" not in attrs and "fiscal_year_start_month" not in attrs:
            raise serializers.ValidationError(
                "Send a lock date, a fiscal year start month, or both."
            )
        return attrs
