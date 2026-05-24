from __future__ import annotations

import gzip
import hashlib
import mimetypes
import os
import re
import shutil
import tempfile
import uuid
from pathlib import Path

from django.conf import settings
from django.contrib.contenttypes.models import ContentType
from django.core.exceptions import ObjectDoesNotExist, ValidationError
from django.db import transaction
from django.utils import timezone
from django.utils.text import get_valid_filename

from .models import Attachment, AttachmentStorageState, StorageVolume


class AttachmentStorageError(Exception):
    pass


DEFAULT_VOLUME_NAME = "default"


def storage_root_path() -> Path:
    raw_path = getattr(settings, "POINTY_ATTACHMENT_STORAGE_ROOT", settings.MEDIA_ROOT)
    return Path(normalize_storage_path(raw_path))


def normalize_storage_path(path) -> str:
    raw_path = Path(str(path)).expanduser()
    if not raw_path.is_absolute():
        raw_path = Path(settings.BASE_DIR) / raw_path
    resolved = raw_path.resolve(strict=False)
    return str(resolved)


def discovered_storage_paths() -> list[str]:
    root = storage_root_path()
    root.mkdir(parents=True, exist_ok=True)
    paths = sorted(
        child.resolve(strict=False)
        for child in root.iterdir()
        if child.is_dir() and not child.name.startswith(".")
    )
    if not paths:
        default_path = root / DEFAULT_VOLUME_NAME
        default_path.mkdir(parents=True, exist_ok=True)
        paths = [default_path.resolve(strict=False)]
    return [str(path) for path in paths]


def sync_discovered_storage_volumes() -> list[str]:
    paths = discovered_storage_paths()
    for path in paths:
        name = Path(path).name or path
        StorageVolume.objects.get_or_create(
            path=path,
            defaults={"name": name, "is_active": True},
        )
    return paths


def ensure_volume_path(volume: StorageVolume) -> None:
    root = volume.root_path
    if not root.exists():
        raise AttachmentStorageError(f"{volume.path} does not exist.")
    if not root.is_dir():
        raise AttachmentStorageError(f"{volume.path} is not a directory.")

    try:
        with tempfile.NamedTemporaryFile(prefix=".pointy-write-", dir=root, delete=True):
            pass
    except OSError as exc:
        raise AttachmentStorageError(f"{volume.path} is not writable.") from exc


def active_writable_volumes(volumes: list[StorageVolume]) -> list[StorageVolume]:
    writable = []
    for volume in volumes:
        try:
            ensure_volume_path(volume)
        except AttachmentStorageError:
            continue
        writable.append(volume)
    return writable


def select_storage_volume() -> StorageVolume:
    discovered_paths = sync_discovered_storage_volumes()
    with transaction.atomic():
        volumes = list(
            StorageVolume.objects.select_for_update()
            .filter(is_active=True, path__in=discovered_paths)
            .order_by("path", "id")
        )
        writable_volumes = active_writable_volumes(volumes)
        if not writable_volumes:
            raise AttachmentStorageError("No writable attachment storage volumes are available.")

        state, _ = AttachmentStorageState.objects.select_for_update().get_or_create(pk=1)
        selected = writable_volumes[state.next_index % len(writable_volumes)]
        state.next_index += 1
        state.save(update_fields=["next_index", "updated_at"])
        return selected


def allowed_target_codes() -> set[str]:
    return {
        str(code).strip().lower()
        for code in getattr(settings, "POINTY_ATTACHMENT_ALLOWED_TARGETS", [])
        if str(code).strip()
    }


def resolve_attachment_owner(owner_type: str, owner_id):
    app_label, model = parse_owner_type(owner_type)
    try:
        content_type = ContentType.objects.get_by_natural_key(app_label, model)
    except ContentType.DoesNotExist as exc:
        raise ValidationError({"owner_type": "Attachment target type does not exist."}) from exc

    target_code = f"{content_type.app_label}.{content_type.model}"
    allowed_targets = allowed_target_codes()
    if "*" not in allowed_targets and target_code not in allowed_targets:
        raise ValidationError({"owner_type": "Attachment target type is not allowed."})

    model_class = content_type.model_class()
    if model_class is None:
        raise ValidationError({"owner_type": "Attachment target type is not available."})

    try:
        return model_class._default_manager.get(pk=owner_id)
    except (ObjectDoesNotExist, ValueError) as exc:
        raise ValidationError({"owner_id": "Attachment target object does not exist."}) from exc


def parse_owner_type(owner_type: str) -> tuple[str, str]:
    parts = str(owner_type or "").strip().lower().split(".")
    if len(parts) != 2 or not all(parts):
        raise ValidationError({"owner_type": "Use the form app_label.model."})
    return parts[0], parts[1]


def content_type_for_owner(owner) -> ContentType:
    return ContentType.objects.get_for_model(owner, for_concrete_model=False)


def store_uploaded_attachment(
    *,
    uploaded_file,
    owner,
    role: str = Attachment.Role.GENERAL,
    is_primary: bool = False,
    metadata: dict | None = None,
    created_by=None,
) -> Attachment:
    validate_upload(uploaded_file)

    source_path = None
    compressed_path = None
    final_path = None
    try:
        source_path, checksum, original_size = spool_upload(uploaded_file)
        compressed_path = gzip_file(source_path)
        compressed_size = os.path.getsize(compressed_path)

        if compressed_size < original_size:
            selected_path = compressed_path
            storage_encoding = Attachment.StorageEncoding.GZIP
            stored_size = compressed_size
        else:
            selected_path = source_path
            storage_encoding = Attachment.StorageEncoding.IDENTITY
            stored_size = original_size

        volume = select_storage_volume()
        relative_path = build_relative_path(
            role=role,
            original_filename=uploaded_file.name,
            storage_encoding=storage_encoding,
        )
        final_path = volume.root_path / relative_path
        final_path.parent.mkdir(parents=True, exist_ok=True)
        shutil.move(selected_path, final_path)
        selected_path = None

        owner_content_type = content_type_for_owner(owner)
        with transaction.atomic():
            if is_primary:
                Attachment.objects.filter(
                    owner_content_type=owner_content_type,
                    owner_object_id=owner.pk,
                    role=role,
                    status=Attachment.Status.ACTIVE,
                    is_primary=True,
                ).update(is_primary=False)
            return Attachment.objects.create(
                owner_content_type=owner_content_type,
                owner_object_id=owner.pk,
                role=role,
                storage_volume=volume,
                relative_path=relative_path,
                original_filename=clean_original_filename(uploaded_file.name),
                content_type=content_type_for_upload(uploaded_file),
                original_size=original_size,
                stored_size=stored_size,
                checksum_sha256=checksum,
                storage_encoding=storage_encoding,
                is_primary=is_primary,
                metadata=metadata or {},
                created_by=created_by,
            )
    except Exception:
        if final_path is not None and final_path.exists():
            final_path.unlink()
        raise
    finally:
        for path in (source_path, compressed_path):
            if path is not None and os.path.exists(path):
                os.unlink(path)


def validate_upload(uploaded_file) -> None:
    max_bytes = getattr(settings, "POINTY_ATTACHMENT_MAX_UPLOAD_BYTES", 0)
    if max_bytes and getattr(uploaded_file, "size", 0) > max_bytes:
        raise ValidationError({"file": "Attachment is larger than the allowed upload size."})

    allowed_content_types = {
        str(content_type).strip().lower()
        for content_type in getattr(settings, "POINTY_ATTACHMENT_ALLOWED_CONTENT_TYPES", [])
        if str(content_type).strip()
    }
    content_type = content_type_for_upload(uploaded_file).lower()
    if allowed_content_types and content_type not in allowed_content_types:
        raise ValidationError({"file": "Attachment content type is not allowed."})


def spool_upload(uploaded_file) -> tuple[str, str, int]:
    max_bytes = getattr(settings, "POINTY_ATTACHMENT_MAX_UPLOAD_BYTES", 0)
    checksum = hashlib.sha256()
    total_size = 0
    temp_file = tempfile.NamedTemporaryFile(prefix="pointy-attachment-", delete=False)
    try:
        with temp_file:
            for chunk in uploaded_file.chunks():
                total_size += len(chunk)
                if max_bytes and total_size > max_bytes:
                    raise ValidationError(
                        {"file": "Attachment is larger than the allowed upload size."}
                    )
                checksum.update(chunk)
                temp_file.write(chunk)
    except Exception:
        os.unlink(temp_file.name)
        raise
    return temp_file.name, checksum.hexdigest(), total_size


def gzip_file(source_path: str) -> str:
    compressed = tempfile.NamedTemporaryFile(prefix="pointy-attachment-", delete=False)
    compressed.close()
    with open(source_path, "rb") as source, open(compressed.name, "wb") as target_file:
        with gzip.GzipFile(
            filename="",
            mode="wb",
            fileobj=target_file,
            mtime=0,
        ) as target:
            shutil.copyfileobj(source, target, length=1024 * 1024)
    return compressed.name


def build_relative_path(
    *,
    role: str,
    original_filename: str,
    storage_encoding: str,
) -> str:
    today = timezone.localdate()
    role_dir = re.sub(r"[^a-z0-9_-]+", "-", str(role).lower()).strip("-") or "general"
    extension = safe_extension(original_filename)
    if storage_encoding == Attachment.StorageEncoding.GZIP:
        extension = f"{extension}.gz" if extension else ".gz"
    return f"{role_dir}/{today:%Y/%m/%d}/{uuid.uuid4().hex}{extension}"


def safe_extension(filename: str) -> str:
    suffix = Path(clean_original_filename(filename)).suffix.lower()
    if len(suffix) > 16:
        return ""
    if not re.fullmatch(r"\.[a-z0-9]+", suffix or ""):
        return ""
    return suffix


def clean_original_filename(filename: str) -> str:
    cleaned = get_valid_filename(Path(str(filename or "attachment")).name)
    return cleaned[:255] or "attachment"


def content_type_for_upload(uploaded_file) -> str:
    content_type = getattr(uploaded_file, "content_type", "") or ""
    if content_type:
        return content_type
    guessed, _ = mimetypes.guess_type(getattr(uploaded_file, "name", ""))
    return guessed or "application/octet-stream"


def open_attachment(attachment: Attachment):
    path = attachment.absolute_path
    if not path.exists():
        raise AttachmentStorageError("Attachment file is missing from storage.")
    if attachment.storage_encoding == Attachment.StorageEncoding.GZIP:
        return gzip.open(path, "rb")
    return open(path, "rb")


def active_attachments_for(owner, *, role: str | None = None):
    queryset = Attachment.objects.active().filter(
        owner_content_type=content_type_for_owner(owner),
        owner_object_id=owner.pk,
    )
    if role is not None:
        queryset = queryset.filter(role=role)
    return queryset.select_related("owner_content_type", "storage_volume", "created_by")
