from django.core.exceptions import ValidationError as DjangoValidationError
from rest_framework import serializers
from rest_framework.reverse import reverse

from .models import Attachment, StorageVolume
from .image_search import DEFAULT_IMAGE_SEARCH_PAGE_SIZE, ProductImageSearchResult
from .services import (
    AttachmentStorageError,
    ensure_volume_path,
    normalize_storage_path,
    resolve_attachment_owner,
    sign_attachment_content_token,
    store_uploaded_attachment,
)


class ProductImageSearchQuerySerializer(serializers.Serializer):
    q = serializers.CharField(
        min_length=2,
        max_length=200,
        trim_whitespace=True,
    )
    page = serializers.IntegerField(required=False, min_value=1, default=1)
    page_size = serializers.IntegerField(
        required=False,
        min_value=1,
        max_value=50,
        default=DEFAULT_IMAGE_SEARCH_PAGE_SIZE,
    )


class ProductImageSearchResultSerializer(serializers.Serializer):
    title = serializers.CharField()
    thumbnail_url = serializers.URLField()
    source_url = serializers.CharField(allow_blank=True)
    source_name = serializers.CharField(allow_blank=True)
    width = serializers.IntegerField(allow_null=True)
    height = serializers.IntegerField(allow_null=True)
    provider = serializers.CharField()
    import_token = serializers.CharField()

    def to_representation(self, instance: ProductImageSearchResult):
        return {
            "title": instance.title,
            "thumbnail_url": instance.thumbnail_url,
            "source_url": instance.source_url,
            "source_name": instance.source_name,
            "width": instance.width,
            "height": instance.height,
            "provider": instance.provider,
            "import_token": instance.import_token,
        }


class ProductImageImportSerializer(serializers.Serializer):
    import_token = serializers.CharField(trim_whitespace=True)
    is_primary = serializers.BooleanField(required=False, default=True)


class StorageVolumeSerializer(serializers.ModelSerializer):
    class Meta:
        model = StorageVolume
        fields = [
            "id",
            "name",
            "path",
            "is_active",
            "notes",
            "created_at",
            "updated_at",
        ]
        read_only_fields = ("id", "created_at", "updated_at")

    def validate_path(self, value):
        return normalize_storage_path(value)

    def validate(self, attrs):
        attrs = super().validate(attrs)
        path = attrs.get("path", getattr(self.instance, "path", None))
        is_active = attrs.get("is_active", getattr(self.instance, "is_active", True))
        if path and is_active:
            self._ensure_path(StorageVolume(path=path))
        return attrs

    def _ensure_path(self, volume):
        try:
            ensure_volume_path(volume)
        except AttachmentStorageError as exc:
            raise serializers.ValidationError({"path": str(exc)}) from exc


class AttachmentSummarySerializer(serializers.ModelSerializer):
    owner_type = serializers.CharField(read_only=True)
    storage_volume = serializers.CharField(source="storage_volume.name", read_only=True)
    created_by_username = serializers.CharField(
        source="created_by.username",
        read_only=True,
    )
    download_url = serializers.SerializerMethodField()
    content_url = serializers.SerializerMethodField()
    compression_savings_bytes = serializers.IntegerField(read_only=True)

    class Meta:
        model = Attachment
        fields = [
            "id",
            "owner_type",
            "owner_object_id",
            "role",
            "original_filename",
            "content_type",
            "original_size",
            "stored_size",
            "compression_savings_bytes",
            "checksum_sha256",
            "storage_encoding",
            "is_primary",
            "status",
            "metadata",
            "storage_volume",
            "created_by",
            "created_by_username",
            "created_at",
            "updated_at",
            "download_url",
            "content_url",
        ]
        read_only_fields = fields

    def get_download_url(self, attachment):
        return self._attachment_url("attachment-download", attachment)

    def get_content_url(self, attachment):
        url = self._attachment_url("attachment-content", attachment)
        token = sign_attachment_content_token(attachment)
        separator = "&" if "?" in url else "?"
        return f"{url}{separator}token={token}"

    def _attachment_url(self, view_name, attachment):
        request = self.context.get("request")
        return reverse(view_name, kwargs={"pk": attachment.pk}, request=request)


class AttachmentSerializer(AttachmentSummarySerializer):
    file = serializers.FileField(write_only=True, required=False)
    owner_type = serializers.CharField(required=False)
    owner_id = serializers.IntegerField(write_only=True, required=False)
    role = serializers.ChoiceField(
        choices=Attachment.Role.choices,
        required=False,
        default=Attachment.Role.GENERAL,
    )
    is_primary = serializers.BooleanField(required=False, default=False)
    metadata = serializers.JSONField(required=False)

    class Meta(AttachmentSummarySerializer.Meta):
        fields = [
            *AttachmentSummarySerializer.Meta.fields,
            "file",
            "owner_id",
        ]
        read_only_fields = [
            field
            for field in AttachmentSummarySerializer.Meta.read_only_fields
            if field not in {"role", "is_primary", "metadata"}
        ]

    def validate(self, attrs):
        attrs = super().validate(attrs)
        if self.instance is not None:
            attrs.pop("file", None)
            attrs.pop("owner_type", None)
            attrs.pop("owner_id", None)
            return attrs

        if "file" not in attrs:
            raise serializers.ValidationError({"file": "Attachment file is required."})

        owner = self.context.get("owner")
        if owner is None:
            owner_type = attrs.pop("owner_type", None)
            owner_id = attrs.pop("owner_id", None)
            if not owner_type or owner_id is None:
                raise serializers.ValidationError(
                    {"owner_type": "owner_type and owner_id are required."}
                )
            try:
                owner = resolve_attachment_owner(owner_type, owner_id)
            except DjangoValidationError as exc:
                raise serializers.ValidationError(exc.message_dict) from exc
        attrs["owner"] = owner
        return attrs

    def create(self, validated_data):
        uploaded_file = validated_data.pop("file")
        owner = validated_data.pop("owner")
        request = self.context.get("request")
        try:
            return store_uploaded_attachment(
                uploaded_file=uploaded_file,
                owner=owner,
                role=validated_data.get("role", Attachment.Role.GENERAL),
                is_primary=validated_data.get("is_primary", False),
                metadata=validated_data.get("metadata") or {},
                created_by=(
                    request.user
                    if request is not None and request.user.is_authenticated
                    else None
                ),
            )
        except DjangoValidationError as exc:
            if hasattr(exc, "message_dict"):
                raise serializers.ValidationError(exc.message_dict) from exc
            raise serializers.ValidationError(exc.messages) from exc
        except AttachmentStorageError as exc:
            raise serializers.ValidationError({"file": str(exc)}) from exc

    def update(self, instance, validated_data):
        is_primary = validated_data.get("is_primary")
        if is_primary is True and not instance.is_primary:
            Attachment.objects.filter(
                owner_content_type=instance.owner_content_type,
                owner_object_id=instance.owner_object_id,
                role=validated_data.get("role", instance.role),
                status=Attachment.Status.ACTIVE,
                is_primary=True,
            ).exclude(pk=instance.pk).update(is_primary=False)
        return super().update(instance, validated_data)
