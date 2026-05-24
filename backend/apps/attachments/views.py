from django.http import FileResponse, Http404
from django.utils.http import content_disposition_header
from rest_framework import parsers, viewsets
from rest_framework.decorators import action
from rest_framework.permissions import IsAuthenticated

from apps.core.permissions import HasPointyPermission

from .models import Attachment, StorageVolume
from .serializers import AttachmentSerializer, StorageVolumeSerializer
from .services import AttachmentStorageError, open_attachment, sync_discovered_storage_volumes


class StorageVolumeViewSet(viewsets.ModelViewSet):
    serializer_class = StorageVolumeSerializer
    permission_classes = [IsAuthenticated, HasPointyPermission]
    permission_map = {
        "list": ("attachments.view_storagevolume",),
        "retrieve": ("attachments.view_storagevolume",),
        "create": ("attachments.add_storagevolume",),
        "update": ("attachments.change_storagevolume",),
        "partial_update": ("attachments.change_storagevolume",),
        "destroy": ("attachments.delete_storagevolume",),
    }
    queryset = StorageVolume.objects.all()
    search_fields = ("name", "path", "notes")
    ordering_fields = ("name", "path", "created_at", "updated_at")

    def get_queryset(self):
        sync_discovered_storage_volumes()
        return super().get_queryset()


class AttachmentViewSet(viewsets.ModelViewSet):
    serializer_class = AttachmentSerializer
    permission_classes = [IsAuthenticated, HasPointyPermission]
    parser_classes = [parsers.MultiPartParser, parsers.FormParser, parsers.JSONParser]
    permission_map = {
        "list": ("attachments.view_attachment",),
        "retrieve": ("attachments.view_attachment",),
        "download": ("attachments.view_attachment",),
        "content": ("attachments.view_attachment",),
        "create": ("attachments.add_attachment",),
        "update": ("attachments.change_attachment",),
        "partial_update": ("attachments.change_attachment",),
        "destroy": ("attachments.delete_attachment",),
    }
    queryset = Attachment.objects.select_related(
        "owner_content_type",
        "storage_volume",
        "created_by",
        "deleted_by",
    )
    filterset_fields = ("role", "status", "is_primary", "content_type")
    search_fields = ("original_filename", "checksum_sha256", "metadata")
    ordering_fields = ("created_at", "updated_at", "original_size", "stored_size")

    def get_queryset(self):
        queryset = super().get_queryset()
        if self.request.query_params.get("include_deleted") != "true":
            queryset = queryset.active()

        owner_type = self.request.query_params.get("owner_type")
        if owner_type:
            queryset = queryset.filter(
                owner_content_type__app_label=owner_type.split(".", 1)[0].lower(),
                owner_content_type__model=owner_type.split(".", 1)[-1].lower(),
            )

        owner_id = self.request.query_params.get("owner_id")
        if owner_id:
            queryset = queryset.filter(owner_object_id=owner_id)
        return queryset

    def perform_destroy(self, instance):
        instance.soft_delete(deleted_by=self.request.user)

    @action(detail=True, methods=["get"], url_path="download")
    def download(self, request, pk=None):
        return self._file_response(as_attachment=True)

    @action(detail=True, methods=["get"], url_path="content")
    def content(self, request, pk=None):
        return self._file_response(as_attachment=False)

    def _file_response(self, *, as_attachment):
        attachment = self.get_object()
        try:
            file_obj = open_attachment(attachment)
        except AttachmentStorageError as exc:
            raise Http404(str(exc)) from exc
        response = FileResponse(
            file_obj,
            as_attachment=as_attachment,
            filename=attachment.original_filename,
            content_type=attachment.content_type or "application/octet-stream",
        )
        if not as_attachment:
            response["Content-Disposition"] = content_disposition_header(
                as_attachment=False,
                filename=attachment.original_filename,
            )
        return response
