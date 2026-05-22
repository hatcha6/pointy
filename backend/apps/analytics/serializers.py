import json

from django.utils import timezone
from rest_framework import serializers

from .models import AnalyticsEvent

MAX_EVENTS_PER_BATCH = 100
MAX_JSON_FIELD_BYTES = 16_384


class AnalyticsEventSerializer(serializers.ModelSerializer):
    received_by_username = serializers.CharField(
        source="received_by.username",
        read_only=True,
    )

    class Meta:
        model = AnalyticsEvent
        fields = [
            "id",
            "client_event_id",
            "event_type",
            "name",
            "severity",
            "source",
            "occurred_at",
            "received_by",
            "received_by_username",
            "session_id",
            "device_id",
            "installation_id",
            "app_version",
            "platform",
            "request_path",
            "ip_address",
            "user_agent",
            "trace_id",
            "entity_type",
            "entity_id",
            "risk_score",
            "attributes",
            "metrics",
            "created_at",
            "updated_at",
        ]
        read_only_fields = [
            "id",
            "received_by",
            "received_by_username",
            "request_path",
            "ip_address",
            "user_agent",
            "created_at",
            "updated_at",
        ]


class AnalyticsEventCreateSerializer(serializers.Serializer):
    client_event_id = serializers.UUIDField(required=False)
    event_type = serializers.ChoiceField(choices=AnalyticsEvent.EventType.choices)
    name = serializers.RegexField(
        regex=r"^[a-z][a-z0-9_.:-]{1,119}$",
        max_length=120,
    )
    severity = serializers.ChoiceField(
        choices=AnalyticsEvent.Severity.choices,
        default=AnalyticsEvent.Severity.INFO,
    )
    source = serializers.ChoiceField(
        choices=AnalyticsEvent.Source.choices,
        default=AnalyticsEvent.Source.FRONTEND,
    )
    occurred_at = serializers.DateTimeField(default=timezone.now)
    session_id = serializers.CharField(max_length=96, required=False, allow_blank=True)
    device_id = serializers.CharField(max_length=96, required=False, allow_blank=True)
    installation_id = serializers.CharField(
        max_length=96, required=False, allow_blank=True
    )
    app_version = serializers.CharField(max_length=40, required=False, allow_blank=True)
    platform = serializers.CharField(max_length=48, required=False, allow_blank=True)
    trace_id = serializers.CharField(max_length=96, required=False, allow_blank=True)
    entity_type = serializers.CharField(max_length=64, required=False, allow_blank=True)
    entity_id = serializers.CharField(max_length=96, required=False, allow_blank=True)
    risk_score = serializers.IntegerField(
        min_value=0,
        max_value=100,
        required=False,
        allow_null=True,
    )
    attributes = serializers.JSONField(default=dict)
    metrics = serializers.JSONField(default=dict)

    def validate_attributes(self, value):
        return _validate_json_object(value, "attributes")

    def validate_metrics(self, value):
        value = _validate_json_object(value, "metrics")
        invalid_keys = [
            key
            for key, metric in value.items()
            if not isinstance(metric, int | float) or isinstance(metric, bool)
        ]
        if invalid_keys:
            raise serializers.ValidationError(
                "Metrics must be an object of numeric values."
            )
        return value


class AnalyticsEventBatchSerializer(serializers.Serializer):
    events = AnalyticsEventCreateSerializer(
        many=True,
        allow_empty=False,
        max_length=MAX_EVENTS_PER_BATCH,
    )

    def validate_events(self, events):
        event_ids = [
            str(event["client_event_id"])
            for event in events
            if event.get("client_event_id") is not None
        ]
        if len(event_ids) != len(set(event_ids)):
            raise serializers.ValidationError(
                "Each event in a batch must have a unique client_event_id."
            )
        return events


class AnalyticsEventExportQuerySerializer(serializers.Serializer):
    format = serializers.ChoiceField(
        choices=("csv", "json"),
        required=False,
        default="csv",
    )
    event_type = serializers.ChoiceField(
        choices=AnalyticsEvent.EventType.choices,
        required=False,
    )
    source = serializers.ChoiceField(
        choices=AnalyticsEvent.Source.choices,
        required=False,
    )
    severity = serializers.ChoiceField(
        choices=AnalyticsEvent.Severity.choices,
        required=False,
    )
    name = serializers.CharField(max_length=120, required=False)
    user = serializers.IntegerField(min_value=1, required=False)
    received_by = serializers.IntegerField(min_value=1, required=False)
    date_from = serializers.DateTimeField(required=False)
    date_to = serializers.DateTimeField(required=False)
    occurred_at_after = serializers.DateTimeField(required=False)
    occurred_at_before = serializers.DateTimeField(required=False)
    platform = serializers.CharField(max_length=48, required=False)
    session_id = serializers.CharField(max_length=96, required=False)
    device_id = serializers.CharField(max_length=96, required=False)
    entity_type = serializers.CharField(max_length=64, required=False)
    entity_id = serializers.CharField(max_length=96, required=False)
    search = serializers.CharField(max_length=120, required=False)
    risk_score_min = serializers.IntegerField(
        min_value=0, max_value=100, required=False
    )
    risk_score_max = serializers.IntegerField(
        min_value=0, max_value=100, required=False
    )

    def validate(self, attrs):
        date_from = attrs.get("occurred_at_after") or attrs.get("date_from")
        date_to = attrs.get("occurred_at_before") or attrs.get("date_to")
        if date_from and date_to and date_from > date_to:
            raise serializers.ValidationError(
                "date_from/occurred_at_after must be before date_to/occurred_at_before."
            )

        risk_score_min = attrs.get("risk_score_min")
        risk_score_max = attrs.get("risk_score_max")
        if (
            risk_score_min is not None
            and risk_score_max is not None
            and risk_score_min > risk_score_max
        ):
            raise serializers.ValidationError(
                "risk_score_min must be less than or equal to risk_score_max."
            )
        return attrs

    @property
    def normalized_filters(self):
        filters = dict(self.validated_data)
        if "user" in filters and "received_by" not in filters:
            filters["received_by"] = filters["user"]
        if "date_from" in filters and "occurred_at_after" not in filters:
            filters["occurred_at_after"] = filters["date_from"]
        if "date_to" in filters and "occurred_at_before" not in filters:
            filters["occurred_at_before"] = filters["date_to"]
        return filters


def _validate_json_object(value, field_name):
    if not isinstance(value, dict):
        raise serializers.ValidationError(f"{field_name} must be a JSON object.")
    encoded = json.dumps(value, separators=(",", ":"), ensure_ascii=False)
    if len(encoded.encode("utf-8")) > MAX_JSON_FIELD_BYTES:
        raise serializers.ValidationError(
            f"{field_name} must be smaller than {MAX_JSON_FIELD_BYTES} bytes."
        )
    return value
