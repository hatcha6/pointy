"""Madfoatech (مدفوعاتك) receipt links, served off LPCO's receipt system.

``https://rms.lpco.ly/RCP/Dwl/<token>`` where the token is 40 bytes of opaque
high-entropy binary, base64url'd. Nothing about the payment is in the link, so
unlike Moamalat there is nothing to decode: the only way to learn the amount is
to ask the issuer, and the only way to prove the slip is genuine is that the
issuer answers at all.

That asymmetry is the point. A Moamalat payload is unsigned and forgeable but
instant; a Madfoatech token cannot be forged without the issuer's database but
costs a slow round trip. So this provider is split: recognising a link is
offline and immediate (the till reacts to the scan straight away), while proving
it is a separate, network-bound step that must never sit in the checkout path.

Four things about the endpoint are load-bearing and none of them are documented,
so they are asserted here rather than assumed:

1. **It gates on User-Agent.** A request without a browser-shaped UA gets a
   200 with an empty body *even for a valid token*. Treating that as "receipt
   not found" would reject every genuine receipt.
2. **It always returns 200.** Validity is signalled by body length. A forged
   token gets 200 + ``content-length: 0``, fast; a real one gets 200 + a
   bitmap, slowly.
3. **The content type is wrong.** It declares ``images/png`` (sic) and names the
   file ``rcp.png``, but the bytes are an uncompressed Windows BMP. The image is
   sniffed, never trusted from the header.
4. **It is slow.** Time-to-first-byte was 16-44s in testing, because the server
   renders the bitmap on demand. The timeout is generous for that reason, and
   the caller is expected to be a background task.
"""

import logging
import re
from urllib.parse import urlparse

from .base import (
    CardReceipt,
    CardReceiptError,
    receipt_is_successful,
)
from .ocr import parse_ocr_amount, read_receipt_fields

logger = logging.getLogger(__name__)

KEY = "madfoatech"
RECEIPT_HOST = "rms.lpco.ly"
RECEIPT_PATH_PREFIX = "/RCP/Dwl/"
needs_verification = True

# The endpoint serves an empty body to anything that does not look like a
# browser. This is the shape that was observed to work; it is not an attempt to
# hide what we are, only to be served at all.
_USER_AGENT = (
    "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) "
    "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
)
# Connect fast, then wait: the delay is the issuer rendering the image, not the
# network, so a short read timeout would abandon receipts that were about to
# arrive. Still bounded -- an unbounded wait is how a worker pool dies.
_TIMEOUT = (10, 75)
# The real slip is ~800KB of uncompressed bitmap. The ceiling is a guard against
# a redirected or replaced endpoint streaming something unbounded at a worker.
_MAX_BYTES = 8 * 1024 * 1024
_TOKEN_PATTERN = re.compile(r"^[A-Za-z0-9_\-]+={0,2}$")


def handles(url: str) -> bool:
    try:
        parsed = urlparse(url.strip())
    except ValueError:
        return False
    return (
        parsed.scheme == "https"
        and parsed.hostname == RECEIPT_HOST
        and parsed.path.startswith(RECEIPT_PATH_PREFIX)
    )


def receipt_token(url: str) -> str:
    parsed = urlparse(url.strip())
    token = parsed.path[len(RECEIPT_PATH_PREFIX) :].strip("/")
    if not token or not _TOKEN_PATTERN.match(token):
        raise CardReceiptError("Receipt URL does not carry a valid receipt token.")
    return token


def parse(url: str) -> CardReceipt:
    """Recognise the link offline. No fields, because the link carries none.

    The returned receipt is deliberately ``amount=None``: it records *that a
    slip was scanned*, not what it proves. Matching it to a payment requires
    ``verify``.
    """
    if not handles(url):
        raise CardReceiptError("Receipt must be a Madfoatech HTTPS receipt URL.")
    token = receipt_token(url)
    return CardReceipt(
        provider=KEY,
        source_url=url.strip(),
        receipt_id=token,
        validation_method="pending_issuer_fetch",
        server_validated=False,
        amount=None,
    )


def verify(url: str, *, fetch=None) -> tuple[CardReceipt, bytes]:
    """Prove the receipt against the issuer and read what it says.

    Returns the receipt and the raw image, so the caller can file the bitmap as
    the shop's own evidence — the issuer is not obliged to keep serving it.

    Raises ``CardReceiptError`` when the issuer does not recognise the token.
    That is the strong signal this provider exists for: an empty body means no
    such receipt was ever issued.
    """
    if not handles(url):
        raise CardReceiptError("Receipt must be a Madfoatech HTTPS receipt URL.")
    token = receipt_token(url)
    image_bytes = (fetch or _fetch_receipt_image)(url)
    if not image_bytes:
        raise CardReceiptError("The card issuer does not recognise this receipt.")
    if not _looks_like_image(image_bytes):
        raise CardReceiptError("The card issuer returned an unreadable receipt.")

    fields = read_receipt_fields(image_bytes)
    amount = parse_ocr_amount(fields.get("Amount"))
    # A slip whose status line reads at all must read as approved. When OCR is
    # unavailable the status is simply absent, and absence is not a decline --
    # the issuer serving the receipt is itself evidence the payment happened.
    if fields.get("TransactionStatus") and not receipt_is_successful(fields):
        raise CardReceiptError("Receipt transaction is not marked successful.")

    receipt = CardReceipt(
        provider=KEY,
        source_url=url.strip(),
        receipt_id=token,
        validation_method="issuer_fetch_ocr" if amount is not None else "issuer_fetch",
        server_validated=True,
        amount=amount,
        transaction_type=fields.get("TransactionType", ""),
        fields=fields,
    )
    return receipt, image_bytes


def _fetch_receipt_image(url: str) -> bytes:
    import requests

    try:
        response = requests.get(
            url,
            timeout=_TIMEOUT,
            headers={
                "User-Agent": _USER_AGENT,
                "Accept": "image/avif,image/webp,image/png,*/*;q=0.8",
                "Accept-Language": "ar,en;q=0.9",
            },
            stream=True,
        )
    except requests.RequestException as exc:
        # Could not ask, which is not the same as asked and refused. The caller
        # retries this; it must not be turned into "the receipt is fake".
        raise IssuerUnavailable(str(exc)) from exc

    if response.status_code >= 500:
        raise IssuerUnavailable(f"Issuer returned HTTP {response.status_code}.")
    if response.status_code != 200:
        raise CardReceiptError("The card issuer does not recognise this receipt.")

    try:
        content = response.raw.read(_MAX_BYTES + 1, decode_content=True)
    except Exception as exc:  # pragma: no cover - transport failure mid-body
        raise IssuerUnavailable(str(exc)) from exc
    finally:
        response.close()

    if len(content) > _MAX_BYTES:
        raise CardReceiptError("The card issuer returned an oversized receipt.")
    return content


def _looks_like_image(data: bytes) -> bool:
    """Sniff the bytes. The declared content type is ``images/png`` and wrong."""
    try:
        import io

        from PIL import Image

        with Image.open(io.BytesIO(data)) as image:
            image.verify()
        return True
    except Exception:
        return False


class IssuerUnavailable(Exception):
    """The issuer could not be reached or failed — retry, do not reject.

    Separated from ``CardReceiptError`` on purpose. A shop on a Libyan link
    loses its connection routinely, and a receipt must never be branded a
    forgery because the shop was offline when we asked.
    """
