from django.contrib import admin

from .models import Attachment, AttachmentStorageState, StorageVolume


@admin.register(StorageVolume)
class StorageVolumeAdmin(admin.ModelAdmin):
    list_display = ("name", "path", "is_active", "created_at", "updated_at")
    list_filter = ("is_active",)
    search_fields = ("name", "path", "notes")


@admin.register(Attachment)
class AttachmentAdmin(admin.ModelAdmin):
    list_display = (
        "original_filename",
        "owner_type",
        "owner_object_id",
        "role",
        "status",
        "storage_volume",
        "original_size",
        "stored_size",
        "created_at",
    )
    list_filter = ("role", "status", "storage_encoding", "is_primary")
    search_fields = ("original_filename", "checksum_sha256", "metadata")
    readonly_fields = ("checksum_sha256", "relative_path", "created_at", "updated_at")


@admin.register(AttachmentStorageState)
class AttachmentStorageStateAdmin(admin.ModelAdmin):
    list_display = ("id", "next_index", "updated_at")
