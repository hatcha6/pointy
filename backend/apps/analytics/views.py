from django.http import HttpResponse
from rest_framework import mixins, status, viewsets
from rest_framework.decorators import action
from rest_framework.permissions import IsAuthenticated
from rest_framework.response import Response

from apps.core.permissions import HasPointyPermission, IsManager

from .models import AnalyticsEvent
from .serializers import (
    AnalyticsEventBatchSerializer,
    AnalyticsEventExportQuerySerializer,
    AnalyticsEventSerializer,
)
from .services import build_events_export_zip, filter_events_for_export, ingest_events


class AnalyticsEventViewSet(
    mixins.ListModelMixin,
    mixins.RetrieveModelMixin,
    viewsets.GenericViewSet,
):
    serializer_class = AnalyticsEventSerializer
    permission_classes = [IsAuthenticated, HasPointyPermission]
    permission_map = {
        "list": ("analytics.view_analyticsevent",),
        "retrieve": ("analytics.view_analyticsevent",),
        "ingest": ("analytics.add_analyticsevent",),
        "export": ("analytics.view_analyticsevent",),
    }
    queryset = AnalyticsEvent.objects.select_related("received_by")
    filterset_fields = (
        "event_type",
        "name",
        "severity",
        "source",
        "received_by",
        "session_id",
        "device_id",
        "installation_id",
        "platform",
        "entity_type",
        "entity_id",
    )
    search_fields = ("name", "trace_id", "entity_type", "entity_id")
    ordering_fields = ("occurred_at", "created_at", "severity", "risk_score")

    def get_permissions(self):
        if self.action == "export":
            return [IsAuthenticated(), IsManager(), HasPointyPermission()]
        return super().get_permissions()

    @action(detail=False, methods=["post"])
    def ingest(self, request):
        serializer = AnalyticsEventBatchSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)
        result = ingest_events(
            events=serializer.validated_data["events"],
            user=request.user,
            request=request,
        )
        return Response(
            {
                "accepted": result.accepted,
                "duplicates": result.duplicates,
                "event_ids": result.event_ids,
                "duplicate_event_ids": result.duplicate_event_ids,
            },
            status=status.HTTP_201_CREATED,
        )

    @action(detail=False, methods=["get"])
    def export(self, request):
        serializer = AnalyticsEventExportQuerySerializer(data=request.query_params)
        serializer.is_valid(raise_exception=True)
        queryset = filter_events_for_export(
            self.get_queryset(),
            serializer.normalized_filters,
        )
        export = build_events_export_zip(
            queryset=queryset,
            filters=serializer.normalized_filters,
            exported_by=request.user,
        )
        response = HttpResponse(export.content, content_type="application/zip")
        response["Content-Disposition"] = f'attachment; filename="{export.filename}"'
        response["X-Pointy-Analytics-Event-Count"] = str(export.event_count)
        return response
