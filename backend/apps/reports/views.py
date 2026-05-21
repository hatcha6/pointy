from rest_framework import mixins, status, viewsets
from rest_framework.decorators import action
from rest_framework.exceptions import PermissionDenied, ValidationError
from rest_framework.permissions import IsAuthenticated
from rest_framework.response import Response

from .models import ReportRun
from .serializers import ReportRunCreateSerializer, ReportRunSerializer
from .services import (
    ReportAccessDenied,
    ReportValidationError,
    create_report_run,
    report_catalog_for_user,
)


class ReportRunViewSet(
    mixins.ListModelMixin,
    mixins.RetrieveModelMixin,
    viewsets.GenericViewSet,
):
    serializer_class = ReportRunSerializer
    permission_classes = [IsAuthenticated]
    queryset = ReportRun.objects.select_related("requested_by")
    filterset_fields = ("report_type", "output_format", "status")
    ordering_fields = ("created_at", "completed_at", "report_type", "row_count")

    def get_queryset(self):
        queryset = super().get_queryset()
        if self.request.user.is_superuser:
            return queryset
        if self.request.user.has_perm("reports.view_reportrun"):
            return queryset
        return queryset.filter(requested_by=self.request.user)

    @action(detail=False, methods=["get"])
    def catalog(self, request):
        return Response({"reports": report_catalog_for_user(request.user)})

    def create(self, request, *args, **kwargs):
        serializer = ReportRunCreateSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)
        try:
            run = create_report_run(user=request.user, **serializer.validated_data)
        except ReportAccessDenied as exc:
            raise PermissionDenied(str(exc)) from exc
        except ReportValidationError as exc:
            raise ValidationError({"detail": str(exc)}) from exc

        output_serializer = self.get_serializer(run)
        return Response(output_serializer.data, status=status.HTTP_201_CREATED)
