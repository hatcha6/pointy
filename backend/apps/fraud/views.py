from rest_framework import mixins, viewsets
from rest_framework.decorators import action
from rest_framework.permissions import IsAuthenticated
from rest_framework.response import Response

from apps.core.permissions import HasPointyPermission

from .models import FraudFinding
from .serializers import FraudFindingReviewSerializer, FraudFindingSerializer
from .services import reopen_finding, review_finding


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
        "review": ("fraud.change_fraudfinding",),
        "dismiss": ("fraud.change_fraudfinding",),
        "reopen": ("fraud.change_fraudfinding",),
    }
    queryset = FraudFinding.objects.select_related("target_user", "reviewed_by")
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

    @action(detail=True, methods=["post"])
    def review(self, request, pk=None):
        return self._triage(request, dismiss=False)

    @action(detail=True, methods=["post"])
    def dismiss(self, request, pk=None):
        return self._triage(request, dismiss=True)

    @action(detail=True, methods=["post"])
    def reopen(self, request, pk=None):
        finding = reopen_finding(self.get_object(), user=request.user)
        return Response(FraudFindingSerializer(finding).data)

    def _triage(self, request, *, dismiss):
        serializer = FraudFindingReviewSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)
        finding = review_finding(
            self.get_object(),
            user=request.user,
            note=serializer.validated_data.get("note", ""),
            dismiss=dismiss,
        )
        return Response(FraudFindingSerializer(finding).data)
