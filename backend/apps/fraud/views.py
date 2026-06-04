from rest_framework import mixins, viewsets
from rest_framework.permissions import IsAuthenticated

from apps.core.permissions import HasPointyPermission

from .models import FraudFinding
from .serializers import FraudFindingSerializer


class FraudFindingViewSet(
    mixins.ListModelMixin,
    mixins.RetrieveModelMixin,
    viewsets.GenericViewSet,
):
    serializer_class = FraudFindingSerializer
    permission_classes = [IsAuthenticated, HasPointyPermission]
    permission_map = {
        "list": ("fraud.view_fraudfinding",),
        "retrieve": ("fraud.view_fraudfinding",),
    }
    queryset = FraudFinding.objects.select_related("target_user")
    filterset_fields = (
        "status",
        "severity",
        "rule_code",
        "target_user",
        "entity_type",
        "entity_id",
    )
    search_fields = (
        "rule_code",
        "fingerprint",
        "target_user__username",
        "target_user_label",
        "entity_type",
        "entity_id",
    )
    ordering_fields = (
        "risk_score",
        "last_detected_at",
        "created_at",
        "window_start",
        "window_end",
    )
