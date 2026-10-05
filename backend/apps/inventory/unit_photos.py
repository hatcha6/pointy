"""Photographs of one article: its condition record, and the face it shows.

Built on the shop's existing attachments (``apps.attachments``) rather than a
table of its own: the bytes, the storage volumes, the signed content URLs and
the soft delete are all already there and already backed up. What is new is a
role — ``unit_photo`` — and one rule: exactly one of an article's photos is its
**cover**, the picture the till's picker and the unit page show first. The
attachments' own ``is_primary`` flag is that cover, and its partial unique
index already guarantees there is never more than one.

Used goods are bought and sold on their condition, so a photo here is evidence
as much as decoration: adding and removing one is written to the unit's §6.9
history, and a removal is a soft delete, never an unlink.
"""

from __future__ import annotations

from django.conf import settings
from django.contrib.contenttypes.models import ContentType
from django.core.exceptions import ValidationError as DjangoValidationError
from django.db import transaction
from django.db.models import Prefetch
from rest_framework import serializers
from rest_framework.reverse import reverse

from apps.attachments.image_normalization import normalize_image_bytes
from apps.attachments.models import Attachment
from apps.attachments.services import (
    AttachmentStorageError,
    sign_attachment_content_token,
    store_uploaded_attachment,
)

from .models import StockUnit, StockUnitEvent

ROLE = Attachment.Role.UNIT_PHOTO
#: A condition record, not an album. Twelve covers every face of a laptop and
#: its charger twice over; past that a shop is filling a disk with one article.
MAX_PHOTOS_PER_UNIT = 12
#: Long edge the stored photo is scaled to. A phone camera's 4000-pixel frame
#: is ten times what any Pointy screen draws, and the original costs a backup.
MAX_PHOTO_DIMENSION = 1600

#: Where :func:`with_cover_photos` leaves each unit's cover (a 0- or 1-list).
COVER_ATTR = "cover_photos"


def _content_type():
    return ContentType.objects.get_for_model(StockUnit)


def photos_of(unit):
    """The unit's live photos, cover first, then newest first."""
    return (
        Attachment.objects.active()
        .filter(
            owner_content_type=_content_type(),
            owner_object_id=unit.pk,
            role=ROLE,
        )
        .select_related("created_by")
        .order_by("-is_primary", "-created_at", "-id")
    )


def with_cover_photos(queryset):
    """Prefetch each unit's cover in one query for the whole page.

    The units list and the till's picker draw a thumbnail beside every row; a
    lookup per row would be the N+1 this exists to prevent.
    """
    return queryset.prefetch_related(
        Prefetch(
            "attachments",
            queryset=Attachment.objects.active()
            .filter(role=ROLE, is_primary=True)
            .select_related("created_by"),
            to_attr=COVER_ATTR,
        )
    )


def cover_of(unit):
    """The unit's cover, from the prefetch when there is one."""
    prefetched = getattr(unit, COVER_ATTR, None)
    if prefetched is not None:
        return prefetched[0] if prefetched else None
    return photos_of(unit).filter(is_primary=True).first()


# ---------------------------------------------------------------------------
# Wire shape
# ---------------------------------------------------------------------------


def photo_payload(attachment, *, request=None) -> dict:
    """``{id, content_url, thumbnail_url, is_cover, ...}`` for one photo.

    One signature serves both URLs: the token names the attachment and its
    checksum, which is exactly what the thumbnail is made from.
    """
    token = sign_attachment_content_token(attachment)
    content = reverse("attachment-content", kwargs={"pk": attachment.pk}, request=request)
    thumbnail = reverse(
        "attachment-thumbnail", kwargs={"pk": attachment.pk}, request=request
    )
    return {
        "id": attachment.pk,
        "content_url": f"{content}?token={token}",
        "thumbnail_url": f"{thumbnail}?token={token}",
        "is_cover": attachment.is_primary,
        "original_filename": attachment.original_filename,
        "created_at": attachment.created_at,
        "created_by_username": getattr(attachment.created_by, "username", "")
        if attachment.created_by_id
        else "",
    }


class UnitPhotoUploadSerializer(serializers.Serializer):
    file = serializers.FileField()
    #: Make this one the cover. The first photo of an article always is.
    is_cover = serializers.BooleanField(required=False, default=False)


# ---------------------------------------------------------------------------
# Writes
# ---------------------------------------------------------------------------


def _normalized_upload(upload):
    """Decode, re-encode anything a client cannot draw, and cap the size.

    The bytes decide the type, never the picker's label: a HEIC chosen from a
    desktop is labelled image/jpeg by the file dialog and would otherwise be
    stored as an invisible tile.
    """
    from django.core.files.uploadedfile import SimpleUploadedFile
    from pathlib import Path

    max_bytes = getattr(settings, "POINTY_ATTACHMENT_MAX_UPLOAD_BYTES", 0)
    if max_bytes and getattr(upload, "size", 0) > max_bytes:
        # Too big to read into memory to re-encode; the storage layer refuses
        # it with its own size message.
        return upload
    upload.seek(0)
    normalized = normalize_image_bytes(upload.read(), max_dimension=MAX_PHOTO_DIMENSION)
    if normalized is None:
        raise serializers.ValidationError({"file": "الملف ليس صورة يمكن عرضها."})
    stem = Path(getattr(upload, "name", "") or "unit-photo").stem or "unit-photo"
    return SimpleUploadedFile(
        f"{stem}{normalized.extension}",
        normalized.data,
        content_type=normalized.content_type,
    )


def _record(unit, kind, *, actor, attachment, note=""):
    from .stock_count_tracking import record_unit_event

    record_unit_event(
        unit,
        kind=kind,
        actor=actor,
        note=note or attachment.original_filename,
        reference_type="attachment",
        reference_id=attachment.pk,
    )


@transaction.atomic
def add_photo(unit, upload, *, actor=None, make_cover=False):
    """Store one photo of ``unit``; the first one becomes its cover."""
    existing = photos_of(unit)
    if existing.count() >= MAX_PHOTOS_PER_UNIT:
        raise serializers.ValidationError(
            {"file": f"لا يمكن إضافة أكثر من {MAX_PHOTOS_PER_UNIT} صورة للوحدة."}
        )
    is_cover = make_cover or not existing.filter(is_primary=True).exists()
    try:
        attachment = store_uploaded_attachment(
            uploaded_file=_normalized_upload(upload),
            owner=unit,
            role=ROLE,
            is_primary=is_cover,
            created_by=actor if getattr(actor, "is_authenticated", False) else None,
        )
    except DjangoValidationError as exc:
        messages = exc.message_dict if hasattr(exc, "message_dict") else exc.messages
        raise serializers.ValidationError(messages) from exc
    except AttachmentStorageError as exc:
        raise serializers.ValidationError({"file": str(exc)}) from exc
    _record(unit, StockUnitEvent.Kind.PHOTO_ADDED, actor=_actor(actor), attachment=attachment)
    return attachment


@transaction.atomic
def remove_photo(unit, attachment, *, actor=None):
    """Soft-delete one photo. Removing the cover promotes the newest other."""
    was_cover = attachment.is_primary
    attachment.soft_delete(deleted_by=_actor(actor))
    if was_cover:
        successor = photos_of(unit).first()
        if successor is not None:
            successor.is_primary = True
            successor.save(update_fields=["is_primary", "updated_at"])
    _record(unit, StockUnitEvent.Kind.PHOTO_REMOVED, actor=_actor(actor), attachment=attachment)


@transaction.atomic
def set_cover(unit, attachment):
    """Make ``attachment`` the face of ``unit``. Not audited: it changes what
    is shown first, not what is on record."""
    if attachment.is_primary:
        return attachment
    photos_of(unit).filter(is_primary=True).update(is_primary=False)
    attachment.is_primary = True
    attachment.save(update_fields=["is_primary", "updated_at"])
    return attachment


def photo_of(unit, photo_id):
    try:
        return photos_of(unit).get(pk=photo_id)
    except (Attachment.DoesNotExist, ValueError, TypeError):
        from django.http import Http404

        raise Http404("الصورة غير موجودة.") from None


def _actor(user):
    return user if getattr(user, "is_authenticated", False) else None


__all__ = [
    "COVER_ATTR",
    "MAX_PHOTOS_PER_UNIT",
    "UnitPhotoUploadSerializer",
    "add_photo",
    "cover_of",
    "photo_of",
    "photo_payload",
    "photos_of",
    "remove_photo",
    "set_cover",
    "with_cover_photos",
]
