from django.conf import settings
from django.db.models import Count
from rest_framework import parsers, status, views, viewsets
from rest_framework.decorators import action
from rest_framework.permissions import IsAuthenticated
from rest_framework.response import Response

from apps.core.permissions import HasPointyPermission

from . import uploads
from .collapse_serializers import CollapsePlanSerializer
from .models import MigrationRun, MigrationSource
from .serializers import (
    EntitySpecSerializer,
    MigrationIssueSerializer,
    MigrationRunCreateSerializer,
    MigrationRunSerializer,
    MigrationSourceSerializer,
    MigrationSystemSerializer,
    UploadBeginSerializer,
    UploadCompleteSerializer,
)
from .services import (
    discard_source,
    queue_collapse_plan,
    queue_migration_run,
    queue_preparation,
)


class RawChunkParser(parsers.BaseParser):
    """Hand the request body back as a stream instead of buffering it.

    Every other parser materialises the body — as bytes, as a dict, as a temp
    file — before the view sees it. A 16 MB chunk survives that; it is still the
    wrong shape, because the view's job is to copy bytes to a file descriptor and
    nothing in between needs to hold them.
    """

    media_type = "application/octet-stream"

    def parse(self, stream, media_type=None, parser_context=None):
        return stream


class MigrationSystemsView(views.APIView):
    """What Pointy can read, and how a file should be handed over."""

    permission_classes = [IsAuthenticated, HasPointyPermission]

    def get_required_permissions(self, request):
        return ("migration.view_migrationsource",)

    def get(self, request):
        return Response(
            {
                "systems": MigrationSystemSerializer.catalogue(),
                "entities": EntitySpecSerializer.catalogue(),
                "upload": {
                    "chunk_size": uploads.chunk_size(),
                    "max_bytes": settings.POINTY_MIGRATION_MAX_UPLOAD_BYTES,
                    "accepted_extensions": [".mdb", ".accdb", ".sqlite", ".sqlite3", ".db", ".sql"],
                },
            }
        )


class MigrationSourceViewSet(viewsets.ReadOnlyModelViewSet):
    """Uploaded files. Created by ``begin``, never by a plain POST."""

    serializer_class = MigrationSourceSerializer
    permission_classes = [IsAuthenticated, HasPointyPermission]
    permission_map = {
        "list": ("migration.view_migrationsource",),
        "retrieve": ("migration.view_migrationsource",),
        "begin": ("migration.add_migrationsource",),
        "chunk": ("migration.add_migrationsource",),
        "complete": ("migration.add_migrationsource",),
        "discard": ("migration.delete_migrationsource",),
        "collapse": ("migration.add_migrationrun",),
    }
    queryset = MigrationSource.objects.all()
    filterset_fields = ("system_key", "upload_state")

    @action(detail=False, methods=["post"])
    def begin(self, request):
        """Reserve a row and an empty file; returns the chunk size to use."""
        serializer = UploadBeginSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)
        source = uploads.begin_upload(
            filename=serializer.validated_data["filename"],
            size_bytes=serializer.validated_data["size_bytes"],
            user=request.user,
        )
        return Response(
            {
                "source": MigrationSourceSerializer(source).data,
                "chunk_size": uploads.chunk_size(),
            },
            status=status.HTTP_201_CREATED,
        )

    @action(detail=True, methods=["put"], parser_classes=[RawChunkParser])
    def chunk(self, request, pk=None):
        """Append bytes at ``?offset=``.

        A mismatched offset is a **409** carrying the server's real one, so the
        client re-syncs rather than writing a chunk into the wrong place — which
        would produce a database that is subtly, silently wrong.
        """
        source = self.get_object()
        try:
            offset = int(request.query_params.get("offset", ""))
        except (TypeError, ValueError):
            return Response({"detail": "offset مطلوب."}, status=status.HTTP_400_BAD_REQUEST)
        try:
            updated = uploads.append_chunk(source, offset, request.data)
        except uploads.OffsetConflict as conflict:
            return Response(
                {
                    "detail": "الموضع غير متطابق — تابع من الموضع المُرسَل.",
                    "received_bytes": conflict.expected,
                },
                status=status.HTTP_409_CONFLICT,
            )
        return Response(
            {
                "received_bytes": updated.received_bytes,
                "upload_state": updated.upload_state,
                "upload_percent": updated.upload_percent,
            }
        )

    @action(detail=True, methods=["post"])
    def complete(self, request, pk=None):
        """Verify the received file, then queue conversion + identification."""
        serializer = UploadCompleteSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)
        source = uploads.complete_upload(
            self.get_object(),
            expected_checksum=serializer.validated_data.get("checksum_sha256") or "",
        )
        source = queue_preparation(source, user=request.user)
        return Response(MigrationSourceSerializer(source).data, status=status.HTTP_202_ACCEPTED)

    @action(detail=True, methods=["post"])
    def collapse(self, request, pk=None):
        """Propose what a one-product-per-handset catalogue would collapse into.

        Reads the file; writes nothing to the shop. The answer is a plan the
        owner reviews and approves, and an import run then names (§12).
        """
        plan = queue_collapse_plan(self.get_object(), user=request.user)
        return Response(
            CollapsePlanSerializer(plan).data,
            status=status.HTTP_202_ACCEPTED,
        )

    @action(detail=True, methods=["post"])
    def discard(self, request, pk=None):
        """Delete this file from the server now."""
        source = self.get_object()
        freed = discard_source(source, user=request.user)
        source.refresh_from_db()
        return Response({"source": MigrationSourceSerializer(source).data, "freed_bytes": freed})


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
            options=serializer.validated_data.get("options") or {},
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
