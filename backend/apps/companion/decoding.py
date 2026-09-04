"""Read a barcode out of a photograph, when the phone could not.

The page decodes in the browser first, because that is instant and costs the
shop's network nothing. But the in-browser decoder is jsQR, and jsQR is a
clean-image decoder: it reads a QR rendered on a screen and struggles with what
a phone camera actually produces — a glossy thermal receipt at an angle, under
shop lighting, slightly out of focus. And it does not read 1-D barcodes at all,
so on an iPhone (no ``BarcodeDetector``) an EAN-13 never resolved.

So a scan the browser cannot make sense of is sent here, where zxing-cpp — the
reference implementation, with real binarisation and perspective correction —
gets a turn. One extra round trip on the LAN, on the failure path only.
"""

import logging

logger = logging.getLogger(__name__)

# Symbologies a shop actually meets: retail 1-D, the 2-D codes on payment
# receipts and invoices. Narrowing the set makes the read faster and cuts false
# positives from stray edges in a photograph.
_FORMAT_NAMES = (
    "EAN13",
    "EAN8",
    "UPCA",
    "UPCE",
    "Code128",
    "Code39",
    "Code93",
    "ITF",
    "Codabar",
    "QRCode",
    "MicroQRCode",
    "DataMatrix",
    "PDF417",
    "Aztec",
)


def decoder_available() -> bool:
    return _zxing() is not None


def _zxing():
    try:
        import zxingcpp
    except ImportError:  # pragma: no cover - decoder not installed
        return None
    return zxingcpp


def _formats(zxingcpp):
    formats = zxingcpp.BarcodeFormat.NONE
    for name in _FORMAT_NAMES:
        candidate = getattr(zxingcpp.BarcodeFormat, name, None)
        if candidate is not None:
            formats = formats | candidate
    return formats or zxingcpp.BarcodeFormat.AllReadable


def decode_image(data: bytes):
    """Return ``(value, symbology)`` for the first code found, or ``None``.

    Never raises: a photo that cannot be opened is simply a scan that did not
    resolve, which the page already knows how to say.
    """
    zxingcpp = _zxing()
    if zxingcpp is None:
        return None

    try:
        from PIL import Image, ImageOps
        import io

        with Image.open(io.BytesIO(data)) as image:
            # A phone writes rotation as EXIF rather than rotating pixels, and
            # a 1-D barcode read sideways is a barcode not read at all.
            image = ImageOps.exif_transpose(image)
            image = image.convert("L")
            results = zxingcpp.read_barcodes(image, formats=_formats(zxingcpp))
    except Exception:
        logger.debug("companion decode failed", exc_info=True)
        return None

    for result in results or []:
        text = getattr(result, "text", "") or ""
        if text:
            symbology = str(getattr(result, "format", "") or "").split(".")[-1]
            return text, symbology.lower()
    return None
