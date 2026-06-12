"""Server-side image normalization for shop branding uploads."""

import io

from django.core.files.uploadedfile import SimpleUploadedFile
from PIL import Image, ImageOps, UnidentifiedImageError

# Receipts and the public invoice page embed the logo inline (base64), so
# every stored logo must stay comfortably under the embedding budget defined
# by apps.printing.services.RECEIPT_LOGO_MAX_BYTES.
LOGO_MAX_DIMENSION = 512
LOGO_MAX_BYTES = 200 * 1024
LOGO_MIN_DIMENSION = 32


def normalized_logo_upload(uploaded_file, content_type):
    """Downscale and re-encode an uploaded logo so it always fits the inline
    embedding budget. Returns a replacement upload, or ``None`` when the file
    is not a decodable image."""
    try:
        image = Image.open(uploaded_file)
        image.load()
    except (UnidentifiedImageError, OSError):
        return None

    # Honor camera EXIF rotation before any resizing.
    image = ImageOps.exif_transpose(image)

    keep_png = content_type == "image/png"
    if keep_png:
        if image.mode not in ("RGBA", "LA", "P"):
            image = image.convert("RGBA")
    elif image.mode not in ("RGB", "L"):
        image = image.convert("RGB")

    image.thumbnail(
        (LOGO_MAX_DIMENSION, LOGO_MAX_DIMENSION),
        Image.Resampling.LANCZOS,
    )

    encoded = _encode(image, keep_png=keep_png)
    # Photographic PNGs can stay heavy even at 512px — halve dimensions until
    # the encoded logo fits the budget.
    while len(encoded) > LOGO_MAX_BYTES and min(image.size) > LOGO_MIN_DIMENSION:
        image = image.resize(
            (
                max(image.width // 2, LOGO_MIN_DIMENSION),
                max(image.height // 2, LOGO_MIN_DIMENSION),
            ),
            Image.Resampling.LANCZOS,
        )
        encoded = _encode(image, keep_png=keep_png)

    name = getattr(uploaded_file, "name", "") or "logo"
    extension = ".png" if keep_png else ".jpg"
    base_name = name.rsplit(".", 1)[0] or "logo"
    return SimpleUploadedFile(
        f"{base_name}{extension}",
        encoded,
        content_type="image/png" if keep_png else "image/jpeg",
    )


def _encode(image, *, keep_png):
    buffer = io.BytesIO()
    if keep_png:
        image.save(buffer, format="PNG", optimize=True)
    else:
        image.save(buffer, format="JPEG", quality=85, optimize=True)
    return buffer.getvalue()
