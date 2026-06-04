from rest_framework import serializers

from .models import FraudFinding


class FraudFindingSerializer(serializers.ModelSerializer):
    target_username = serializers.CharField(
        source="target_user.username",
        read_only=True,
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
            "created_at",
            "updated_at",
        ]
        read_only_fields = fields

