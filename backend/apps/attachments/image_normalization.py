"""Normalize product images into formats every Pointy client can decode.

The clients render product images through Flutter's image decoder, which only
handles JPEG, PNG, GIF, WebP and BMP. The web serves plenty of formats it does
not: a content-negotiating CDN happily returns AVIF, an image search hit can be
an SVG, a TIFF or a favicon-style ICO. Those all store fine and then silently
fail to decode on the client, which is why a shop could "save" a searched image
and never see it appear. Re-encoding at import time keeps that invariant on the
server, where it holds for every client at once.
"""

from __future__ import annotations

import io
from pathlib import Path

from django.core.files.uploadedfile import SimpleUploadedFile
from PIL import Image, ImageOps, UnidentifiedImageError
from PIL.Image import DecompressionBombError

try:
    # Teach Pillow to decode HEIC/HEIF (the default iPhone photo format), so
    # such uploads are re-encoded rather than rejected. Optional: on a build
    # without pillow-heif a HEIC simply stays undecodable and is refused.
    from pillow_heif import register_heif_opener

    register_heif_opener()
except ImportError:  # pragma: no cover - exercised only where the wheel is absent
    pass

# Formats Flutter's decoder handles natively. Anything else is re-encoded.
CLIENT_RENDERABLE_FORMATS = frozenset({"JPEG", "PNG", "GIF", "WEBP", "BMP"})

CONTENT_TYPES_BY_FORMAT = {
    "JPEG": "image/jpeg",
    "PNG": "image/png",
    "GIF": "image/gif",
    "WEBP": "image/webp",
    "BMP": "image/bmp",
}

EXTENSIONS_BY_FORMAT = {
    "JPEG": ".jpg",
    "PNG": ".png",
    "GIF": ".gif",
    "WEBP": ".webp",
    "BMP": ".bmp",
}

# Product images are shown at a few hundred pixels at most. Search hits can be
# 6000px press shots; downscaling keeps storage and client decode sane.
MAX_DIMENSION = 2048
JPEG_QUALITY = 88


class NormalizedImage:
    """Decoded, client-renderable image bytes plus the metadata to store them."""

    def __init__(self, *, data: bytes, content_type: str, extension: str):
        self.data = data
        self.content_type = content_type
        self.extension = extension


def normalize_image_bytes(data: bytes) -> NormalizedImage | None:
    """Return client-renderable bytes for ``data``, or ``None`` if it is not an image.

    Decoding is the real content check: a host that hotlink-blocks by serving an
    HTML page under an ``image/jpeg`` header fails here, where trusting the
    declared content type would have stored the error page as the product photo.
    """
    try:
        with Image.open(io.BytesIO(data)) as image:
            source_format = (image.format or "").upper()
            # Pillow is lazy; load() is what actually surfaces truncated or
            # malformed data that would otherwise fail later on the client.
            image.load()
            animated = getattr(image, "n_frames", 1) > 1
            if _is_passthrough(source_format, image, animated=animated):
                return NormalizedImage(
                    data=data,
                    content_type=CONTENT_TYPES_BY_FORMAT[source_format],
                    extension=EXTENSIONS_BY_FORMAT[source_format],
                )
            return _reencode(image)
    except (
        UnidentifiedImageError,
        DecompressionBombError,
        OSError,
        ValueError,
        MemoryError,
    ):
        # Pillow raises across this whole family for corrupt, truncated and
        # non-image payloads alike. DecompressionBombError derives straight from
        # Exception, so it needs naming here or a bomb becomes a 500 instead of
        # a rejected image.
        return None


def _is_passthrough(source_format: str, image: Image.Image, *, animated: bool) -> bool:
    """Whether the original bytes can be stored untouched.

    Re-encoding is lossy and pointless when the source already renders, so an
    in-budget JPEG/PNG/WebP keeps its exact bytes. Animated sources always pass
    through: re-encoding would flatten them to a single frame.
    """
    if source_format not in CLIENT_RENDERABLE_FORMATS:
        return False
    if animated:
        return True
    return max(image.size) <= MAX_DIMENSION


def _reencode(image: Image.Image) -> NormalizedImage:
    # Camera and phone sources carry rotation in EXIF rather than in the pixels.
    image = ImageOps.exif_transpose(image)

    # Transparency only survives in PNG; flattening it onto white beats the
    # black background a naive RGB convert would burn in.
    has_alpha = image.mode in ("RGBA", "LA", "PA") or (
        image.mode == "P" and "transparency" in image.info
    )
    if has_alpha:
        image = image.convert("RGBA")
        target_format = "PNG"
    else:
        image = image.convert("RGB")
        target_format = "JPEG"

    if max(image.size) > MAX_DIMENSION:
        image.thumbnail((MAX_DIMENSION, MAX_DIMENSION), Image.Resampling.LANCZOS)

    buffer = io.BytesIO()
    if target_format == "PNG":
        image.save(buffer, format="PNG", optimize=True)
    else:
        image.save(buffer, format="JPEG", quality=JPEG_QUALITY, optimize=True)

    return NormalizedImage(
        data=buffer.getvalue(),
        content_type=CONTENT_TYPES_BY_FORMAT[target_format],
        extension=EXTENSIONS_BY_FORMAT[target_format],
    )


def normalize_uploaded_image(uploaded_file) -> SimpleUploadedFile | None:
    """Re-encode a directly uploaded image into client-renderable bytes.

    Returns a fresh upload carrying the decoded bytes under a truthful content
    type and extension, or ``None`` when the payload is not a decodable image.
    Unlike the search-import path, a direct upload otherwise reaches storage
    with whatever content type the client declared -- and the picker labels
    every unrecognized extension ``image/jpeg`` -- so a HEIC or AVIF chosen from
    disk would be stored mislabeled and render as an invisible tile everywhere.
    Deciding the type from the bytes here keeps that from happening.
    """
    uploaded_file.seek(0)
    normalized = normalize_image_bytes(uploaded_file.read())
    if normalized is None:
        return None
    stem = Path(getattr(uploaded_file, "name", "") or "product-image").stem or "product-image"
    return SimpleUploadedFile(
        f"{stem}{normalized.extension}",
        normalized.data,
        content_type=normalized.content_type,
    )
