from django.db.models import Count
from rest_framework import status, views, viewsets
from rest_framework.decorators import action
from rest_framework.permissions import IsAuthenticated
from rest_framework.response import Response

from apps.core.permissions import HasPointyPermission

from .models import MigrationRun, MigrationSource
from .serializers import (
    EntitySpecSerializer,
    MigrationIssueSerializer,
    MigrationRunCreateSerializer,
    MigrationRunSerializer,
    MigrationSourceSerializer,
    MigrationSystemSerializer,
)
from .services import queue_migration_run, run_compatibility, test_connection


class MigrationSystemsView(views.APIView):
    """The catalogue that drives the system picker + entity selection UI."""

    permission_classes = [IsAuthenticated, HasPointyPermission]

    def get_required_permissions(self, request):
        return ("migration.view_migrationsource",)

    def get(self, request):
        return Response(
            {
                "systems": MigrationSystemSerializer.catalogue(),
                "entities": EntitySpecSerializer.catalogue(),
            }
        )


class MigrationSourceViewSet(viewsets.ModelViewSet):
    serializer_class = MigrationSourceSerializer
    permission_classes = [IsAuthenticated, HasPointyPermission]
    permission_map = {
        "list": ("migration.view_migrationsource",),
        "retrieve": ("migration.view_migrationsource",),
        "create": ("migration.add_migrationsource",),
        "update": ("migration.change_migrationsource",),
        "partial_update": ("migration.change_migrationsource",),
        "destroy": ("migration.delete_migrationsource",),
        "test": ("migration.change_migrationsource",),
        "check": ("migration.change_migrationsource",),
    }
    queryset = MigrationSource.objects.all()
    filterset_fields = ("system_key", "transport_kind", "is_archived")

    @action(detail=True, methods=["post"])
    def test(self, request, pk=None):
        return Response(test_connection(self.get_object()))

    @action(detail=True, methods=["post"])
    def check(self, request, pk=None):
        return Response(run_compatibility(self.get_object(), user=request.user))


class MigrationRunViewSet(viewsets.ModelViewSet):
    permission_classes = [IsAuthenticated, HasPointyPermission]
    http_method_names = ["get", "post", "head", "options"]
    permission_map = {
        "list": ("migration.view_migrationrun",),
        "retrieve": ("migration.view_migrationrun",),
        "create": ("migration.add_migrationrun",),
        "issues": ("migration.view_migrationrun",),
    }
    queryset = MigrationRun.objects.select_related("source")
    filterset_fields = ("source", "mode", "status")

    def get_serializer_class(self):
        if self.action == "create":
            return MigrationRunCreateSerializer
        return MigrationRunSerializer

    def get_queryset(self):
        return super().get_queryset().annotate(issue_count=Count("issues"))

    def create(self, request, *args, **kwargs):
        serializer = MigrationRunCreateSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)
        run = queue_migration_run(
            serializer.validated_data["source"],
            mode=serializer.validated_data["mode"],
            entities=serializer.validated_data.get("selected_entities") or [],
            user=request.user,
        )
        return Response(
            MigrationRunSerializer(run).data,
            status=status.HTTP_202_ACCEPTED,
        )

    @action(detail=True, methods=["get"])
    def issues(self, request, pk=None):
        run = self.get_object()
        queryset = run.issues.all()
        severity = request.query_params.get("severity")
        if severity:
            queryset = queryset.filter(severity=severity)
        entity_type = request.query_params.get("entity_type")
        if entity_type:
            queryset = queryset.filter(entity_type=entity_type)
        page = self.paginate_queryset(queryset)
        if page is not None:
            serializer = MigrationIssueSerializer(page, many=True)
            return self.get_paginated_response(serializer.data)
        return Response(MigrationIssueSerializer(queryset, many=True).data)
