from rest_framework import serializers

from .models import FraudFinding


class FraudFindingSerializer(serializers.ModelSerializer):
    target_username = serializers.CharField(
        source="target_user.username",
        read_only=True,
    )
    reviewed_by_username = serializers.CharField(
        source="reviewed_by.username",
        read_only=True,
        default="",
    )

    class Meta:
        model = FraudFinding
        fields = [
            "id",
            "fingerprint",
            "rule_code",
            "status",
            "severity",
            "target_user",
            "target_username",
            "target_user_label",
            "entity_type",
            "entity_id",
            "risk_score",
            "window_start",
            "window_end",
            "summary",
            "evidence",
            "metrics",
            "peer_metrics",
            "pattern_count",
            "first_detected_at",
            "last_detected_at",
            "occurrence_count",
            "resolved_at",
            "reviewed_by",
            "reviewed_by_username",
            "reviewed_at",
            "resolution_note",
            "created_at",
            "updated_at",
        ]
        read_only_fields = fields


class FraudFindingReviewSerializer(serializers.Serializer):
    note = serializers.CharField(
        required=False,
        allow_blank=True,
        max_length=1000,
    )

