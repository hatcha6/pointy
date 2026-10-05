"""Small JPEG renditions of image attachments, made once and kept on disk.

A list of handsets shows a 40-pixel cover beside each row and the unit page a
strip of them. Serving the 1600-pixel original for that is a megabyte per row
over a shop's LAN — or over the relay — to draw something the size of a
thumbnail, and every till would decode it again on each scroll. So the server
keeps one small rendition per attachment beside the volume's files, keyed by
the attachment's checksum: replacing the bytes changes the checksum, which
names a new thumbnail, and nothing ever has to be invalidated.
"""

from __future__ import annotations

import io
import os
import tempfile
from pathlib import Path

from PIL import Image, ImageOps, UnidentifiedImageError
from PIL.Image import DecompressionBombError

from .models import Attachment
from .services import AttachmentStorageError, open_attachment

#: The longer edge, in pixels. Enough for a crisp 96-point tile on a 3x phone
#: screen, and a few tens of kilobytes as a JPEG.
THUMBNAIL_EDGE = 320
THUMBNAIL_QUALITY = 80
THUMBNAIL_CONTENT_TYPE = "image/jpeg"


def thumbnail_path(attachment: Attachment, *, edge: int = THUMBNAIL_EDGE) -> Path:
    checksum = attachment.checksum_sha256 or f"id{attachment.pk}"
    return (
        attachment.storage_volume.root_path
        / ".thumbnails"
        / checksum[:2]
        / f"{checksum}-{edge}.jpg"
    )


def thumbnail_bytes(attachment: Attachment, *, edge: int = THUMBNAIL_EDGE) -> bytes | None:
    """The attachment's thumbnail, rendered on first request.

    ``None`` when the attachment is not an image Pillow can read, or its file
    has gone — the caller answers 404 and the client falls back to its
    placeholder, exactly as for a missing original.
    """
    path = thumbnail_path(attachment, edge=edge)
    try:
        return path.read_bytes()
    except OSError:
        pass
    data = _render(attachment, edge=edge)
    if data is None:
        return None
    _store(path, data)
    return data


def _render(attachment: Attachment, *, edge: int) -> bytes | None:
    try:
        with open_attachment(attachment) as handle:
            source = handle.read()
    except (AttachmentStorageError, OSError):
        return None
    try:
        with Image.open(io.BytesIO(source)) as image:
            image.load()
            # Phone cameras record rotation in EXIF rather than in the pixels.
            image = ImageOps.exif_transpose(image)
            if image.mode in ("RGBA", "LA", "PA") or (
                image.mode == "P" and "transparency" in image.info
            ):
                # Flatten transparency onto white: a JPEG has no alpha, and a
                # naive convert burns it in black.
                image = image.convert("RGBA")
                backdrop = Image.new("RGB", image.size, (255, 255, 255))
                backdrop.paste(image, mask=image.getchannel("A"))
                image = backdrop
            else:
                image = image.convert("RGB")
            image.thumbnail((edge, edge), Image.Resampling.LANCZOS)
            buffer = io.BytesIO()
            image.save(buffer, format="JPEG", quality=THUMBNAIL_QUALITY, optimize=True)
            return buffer.getvalue()
    except (
        UnidentifiedImageError,
        DecompressionBombError,
        OSError,
        ValueError,
        MemoryError,
    ):
        return None


def _store(path: Path, data: bytes) -> None:
    """Write atomically, so two tills asking at once never read half a file.

    A failure to cache is not a failure to answer: the bytes are already in
    hand, and the next request simply renders them again.
    """
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        handle, temporary = tempfile.mkstemp(dir=path.parent, suffix=".tmp")
        with os.fdopen(handle, "wb") as stream:
            stream.write(data)
        os.replace(temporary, path)
    except OSError:
        return


__all__ = [
    "THUMBNAIL_CONTENT_TYPE",
    "THUMBNAIL_EDGE",
    "thumbnail_bytes",
    "thumbnail_path",
]
