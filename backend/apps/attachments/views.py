from django.core.handlers.asgi import ASGIRequest
from django.http import FileResponse, Http404, StreamingHttpResponse
from django.utils.cache import get_conditional_response
from django.utils.http import content_disposition_header, http_date, quote_etag
from rest_framework import parsers, viewsets
from rest_framework.decorators import action
from rest_framework.exceptions import PermissionDenied
from rest_framework.permissions import AllowAny, IsAuthenticated

from apps.core.permissions import HasPointyPermission
from apps.core.streaming import aiter_handle

from .models import Attachment, StorageVolume
from .serializers import AttachmentSerializer, StorageVolumeSerializer
from .services import (
    AttachmentStorageError,
    is_valid_attachment_content_token,
    open_attachment,
    sync_discovered_storage_volumes,
)


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

    def get_permissions(self):
        if self.action == "content" and self.request.query_params.get("token"):
            return [AllowAny()]
        return super().get_permissions()

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
        return self._file_response(
            as_attachment=False,
            token=request.query_params.get("token", ""),
        )

    def _file_response(self, *, as_attachment, token=""):
        attachment = self.get_object()
        if token and not is_valid_attachment_content_token(attachment, token):
            raise PermissionDenied("Attachment content token is invalid or expired.")

        # Attachment bytes are content-addressed by checksum, so the ETag lets
        # every product-image render after the first be a 304 (or, within
        # max-age, no request at all) instead of a full DB + file read.
        etag = quote_etag(
            attachment.checksum_sha256
            or f"{attachment.pk}:{attachment.updated_at.isoformat() if attachment.updated_at else ''}"
        )
        last_modified = (
            int(attachment.updated_at.timestamp()) if attachment.updated_at else None
        )
        response = get_conditional_response(
            self.request, etag=etag, last_modified=last_modified
        )
        if response is None:
            try:
                file_obj = open_attachment(attachment)
            except AttachmentStorageError as exc:
                raise Http404(str(exc)) from exc
            content_type = attachment.content_type or "application/octet-stream"
            django_request = getattr(self.request, "_request", self.request)
            if isinstance(django_request, ASGIRequest):
                # Served over ASGI (uvicorn in production), Django buffers
                # FileResponse's sync file iterator wholesale — the whole
                # attachment in memory before the first byte; product images
                # are small, but AI-chat file attachments run multi-MB. Hand
                # it an async iterator over the open_attachment() handle
                # (possibly a gzip-decompressing wrapper — there is no path
                # whose raw bytes are the response), setting by hand the
                # headers FileResponse would have derived. Either storage
                # encoding streams back the original upload byte-for-byte,
                # so original_size is the Content-Length. WSGI (runserver,
                # tests) keeps native sync streaming.
                response = StreamingHttpResponse(
                    aiter_handle(file_obj), content_type=content_type
                )
                response["Content-Length"] = attachment.original_size
                if disposition := content_disposition_header(
                    as_attachment=as_attachment,
                    filename=attachment.original_filename,
                ):
                    response["Content-Disposition"] = disposition
            else:
                response = FileResponse(
                    file_obj,
                    as_attachment=as_attachment,
                    filename=attachment.original_filename,
                    content_type=content_type,
                )
                if not as_attachment:
                    response["Content-Disposition"] = content_disposition_header(
                        as_attachment=False,
                        filename=attachment.original_filename,
                    )
        # On the 304 too, so clients extend their cache lifetime.
        response["ETag"] = etag
        if last_modified is not None:
            response["Last-Modified"] = http_date(last_modified)
        response["Cache-Control"] = "private, max-age=86400"
        return response
