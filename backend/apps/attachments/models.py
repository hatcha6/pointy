from pathlib import Path

from django.conf import settings
from django.contrib.contenttypes.fields import GenericForeignKey
from django.contrib.contenttypes.models import ContentType
from django.db import models
from django.db.models import Q
from django.utils import timezone

from apps.core.models import TimeStampedModel


class StorageVolume(TimeStampedModel):
    name = models.CharField(max_length=120)
    path = models.CharField(max_length=500, unique=True)
    is_active = models.BooleanField(default=True)
    notes = models.TextField(blank=True)

    class Meta:
        ordering = ["id"]

    @property
    def root_path(self) -> Path:
        return Path(self.path)

    def __str__(self) -> str:
        return self.name or self.path


class AttachmentStorageState(TimeStampedModel):
    next_index = models.PositiveBigIntegerField(default=0)

    class Meta:
        verbose_name = "attachment storage state"
        verbose_name_plural = "attachment storage state"


class AttachmentQuerySet(models.QuerySet):
    def active(self):
        return self.filter(status=Attachment.Status.ACTIVE)


class Attachment(TimeStampedModel):
    class Role(models.TextChoices):
        GENERAL = "general", "General"
        DOCUMENT = "document", "Document"
        PRODUCT_IMAGE = "product_image", "Product image"
        SUPPLIER_INVOICE_SCAN = "supplier_invoice_scan", "Supplier invoice scan"

    class Status(models.TextChoices):
        ACTIVE = "active", "Active"
        DELETED = "deleted", "Deleted"

    class StorageEncoding(models.TextChoices):
        IDENTITY = "identity", "Identity"
        GZIP = "gzip", "Gzip"

    owner_content_type = models.ForeignKey(
        ContentType,
        on_delete=models.PROTECT,
        related_name="owned_attachments",
    )
    owner_object_id = models.PositiveBigIntegerField()
    owner = GenericForeignKey("owner_content_type", "owner_object_id")
    role = models.CharField(
        max_length=64,
        choices=Role.choices,
        default=Role.GENERAL,
        db_index=True,
    )
    storage_volume = models.ForeignKey(
        StorageVolume,
        on_delete=models.PROTECT,
        related_name="attachments",
    )
    relative_path = models.CharField(max_length=600)
    original_filename = models.CharField(max_length=255)
    content_type = models.CharField(max_length=160, blank=True)
    original_size = models.PositiveBigIntegerField()
    stored_size = models.PositiveBigIntegerField()
    checksum_sha256 = models.CharField(max_length=64, db_index=True)
    storage_encoding = models.CharField(
        max_length=16,
        choices=StorageEncoding.choices,
        default=StorageEncoding.IDENTITY,
    )
    is_primary = models.BooleanField(default=False)
    status = models.CharField(
        max_length=16,
        choices=Status.choices,
        default=Status.ACTIVE,
        db_index=True,
    )
    metadata = models.JSONField(default=dict, blank=True)
    created_by = models.ForeignKey(
        settings.AUTH_USER_MODEL,
        on_delete=models.SET_NULL,
        related_name="created_attachments",
        blank=True,
        null=True,
    )
    deleted_at = models.DateTimeField(blank=True, null=True)
    deleted_by = models.ForeignKey(
        settings.AUTH_USER_MODEL,
        on_delete=models.SET_NULL,
        related_name="deleted_attachments",
        blank=True,
        null=True,
    )

    objects = AttachmentQuerySet.as_manager()

    class Meta:
        ordering = ["-created_at", "-id"]
        constraints = [
            models.UniqueConstraint(
                fields=["storage_volume", "relative_path"],
                name="unique_attachment_file_path",
            ),
            models.UniqueConstraint(
                fields=["owner_content_type", "owner_object_id", "role"],
                condition=Q(is_primary=True, status="active"),
                name="unique_primary_attachment_per_owner_role",
            ),
        ]
        indexes = [
            models.Index(
                fields=["owner_content_type", "owner_object_id", "role", "status"],
                name="att_owner_role_status_idx",
            ),
            models.Index(
                fields=["storage_volume", "status"],
                name="att_volume_status_idx",
            ),
        ]

    @property
    def owner_type(self) -> str:
        return f"{self.owner_content_type.app_label}.{self.owner_content_type.model}"

    @property
    def absolute_path(self) -> Path:
        return self.storage_volume.root_path / self.relative_path

    @property
    def compression_savings_bytes(self) -> int:
        return max(int(self.original_size) - int(self.stored_size), 0)

    def soft_delete(self, *, deleted_by=None):
        self.status = self.Status.DELETED
        self.is_primary = False
        self.deleted_at = timezone.now()
        self.deleted_by = deleted_by
        self.save(
            update_fields=[
                "status",
                "is_primary",
                "deleted_at",
                "deleted_by",
                "updated_at",
            ]
        )

    def __str__(self) -> str:
        return f"{self.original_filename} ({self.owner_type}:{self.owner_object_id})"
