from __future__ import annotations

import ipaddress
import logging
import socket
from dataclasses import dataclass
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.parse import urlparse
from urllib.request import (
    HTTPRedirectHandler,
    Request,
    build_opener,
)

from django.conf import settings
from django.core import signing
from django.core.exceptions import ImproperlyConfigured

from apps.core.models import RelayInstallation
from apps.core.relay import RelayControlClient, RelayControlError

from .image_normalization import normalize_image_bytes
from .models import Attachment
from .services import clean_original_filename, store_uploaded_attachment


IMAGE_IMPORT_SIGNING_SALT = "pointy.product-image-import"
DEFAULT_IMAGE_IMPORT_MAX_AGE_SECONDS = 60 * 60
DEFAULT_IMAGE_SEARCH_PAGE_SIZE = 30
DEFAULT_IMAGE_SEARCH_MAX_PAGE_SIZE = 50
DEFAULT_IMAGE_FETCH_TIMEOUT_SECONDS = 8

logger = logging.getLogger(__name__)


class ProductImageSearchError(Exception):
    pass


class ProductImageSearchUnavailable(ProductImageSearchError):
    pass


class ProductImageImportError(ProductImageSearchError):
    pass


class ProductImageDownloadError(ProductImageImportError):
    pass


@dataclass(frozen=True)
class ProductImageSearchResult:
    title: str
    thumbnail_url: str
    image_url: str
    source_url: str
    source_name: str
    width: int | None = None
    height: int | None = None
    provider: str = "serper"

    @property
    def import_token(self) -> str:
        return sign_image_import_payload(
            {
                "image_url": self.image_url,
                "thumbnail_url": self.thumbnail_url,
                "source_url": self.source_url,
                "source_name": self.source_name,
                "title": self.title,
                "provider": self.provider,
            }
        )


class RemoteImageUpload:
    def __init__(self, *, name: str, content_type: str, data: bytes):
        self.name = clean_original_filename(name)
        self.content_type = content_type
        self.size = len(data)
        self._data = data

    def chunks(self, chunk_size=None):
        chunk_size = chunk_size or 64 * 1024
        for start in range(0, len(self._data), chunk_size):
            yield self._data[start : start + chunk_size]


class ValidatingRedirectHandler(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        validate_remote_image_url(newurl)
        return super().redirect_request(req, fp, code, msg, headers, newurl)


def search_product_images(
    *,
    query: str,
    page: int = 1,
    page_size: int = DEFAULT_IMAGE_SEARCH_PAGE_SIZE,
) -> list[ProductImageSearchResult]:
    """Search the web for candidate product images via the relay.

    The relay holds the Serper.dev key centrally and gates on the shop's
    remote-access entitlement, so a shop never configures or pays for an image
    search key itself. Unconfigured installations (or an unentitled/failing
    relay) surface as ``ProductImageSearchUnavailable``.
    """
    installation = RelayInstallation.load()
    if installation is None or not installation.access_token:
        raise ProductImageSearchUnavailable("Product image search is not configured.")

    page = max(page, 1)
    page_size = min(max(page_size, 1), DEFAULT_IMAGE_SEARCH_MAX_PAGE_SIZE)

    try:
        client = RelayControlClient()
    except ImproperlyConfigured as exc:
        raise ProductImageSearchUnavailable(
            "Product image search is not configured."
        ) from exc

    try:
        payload = client.search_product_images(
            access_token=installation.access_token,
            query=query,
            page=page,
            page_size=page_size,
        )
    except RelayControlError as exc:
        logger.info("Relay product image search failed: %s", exc)
        raise ProductImageSearchUnavailable(
            "Product image search is unavailable right now."
        ) from exc

    results = []
    seen_urls = set()
    for item in payload.get("results", []):
        if not isinstance(item, dict):
            continue
        image_url = str(item.get("image_url") or "").strip()
        if not is_supported_remote_image_result_url(image_url):
            continue
        url_key = image_url.lower()
        if url_key in seen_urls:
            continue
        thumbnail_url = str(item.get("thumbnail_url") or "").strip() or image_url
        results.append(
            ProductImageSearchResult(
                title=str(item.get("title") or "").strip(),
                thumbnail_url=thumbnail_url,
                image_url=image_url,
                source_url=str(item.get("source_url") or "").strip(),
                source_name=str(item.get("source_name") or "").strip(),
                width=optional_int(item.get("width")),
                height=optional_int(item.get("height")),
                provider="serper",
            )
        )
        seen_urls.add(url_key)
        if len(results) >= page_size:
            break
    return results


def import_product_image_from_token(
    *,
    owner,
    import_token: str,
    is_primary: bool = True,
    created_by=None,
) -> Attachment:
    payload = load_image_import_payload(import_token)
    image_url = str(payload.get("image_url") or "").strip()
    thumbnail_url = str(payload.get("thumbnail_url") or "").strip()
    if not image_url and not thumbnail_url:
        raise ProductImageImportError("Image import token is missing its image URL.")

    upload, imported_url = fetch_first_available_image(
        candidates=[image_url, thumbnail_url],
        referer=str(payload.get("source_url") or "").strip(),
    )
    metadata = {
        "imported_from": "internet_search",
        "source_url": payload.get("source_url") or "",
        "thumbnail_url": payload.get("thumbnail_url") or "",
        "source_name": payload.get("source_name") or "",
        "title": payload.get("title") or "",
        "provider": payload.get("provider") or "",
        # Which candidate actually served the bytes: the full-size original, or
        # the thumbnail we fell back to when its host refused us. Shops that
        # want a sharper photo can tell the two apart.
        "imported_url": imported_url,
        "imported_fallback_thumbnail": bool(
            imported_url and image_url and imported_url != image_url
        ),
    }
    return store_uploaded_attachment(
        uploaded_file=upload,
        owner=owner,
        role=Attachment.Role.PRODUCT_IMAGE,
        is_primary=is_primary,
        metadata=metadata,
        created_by=created_by,
    )


def fetch_first_available_image(
    *,
    candidates: list[str],
    referer: str = "",
) -> tuple[RemoteImageUpload, str]:
    """Download the first candidate URL that yields a usable image.

    Search results carry two URLs for the same picture: the full-size original on
    the publisher's own host, and the provider-hosted thumbnail. Only the
    thumbnail is ever shown in the picker, while the original is what a shop is
    really asking for -- so we try the original first and fall back to the
    thumbnail. Publisher hosts block hotlinking, rate-limit, or simply 404 out of
    a stale search index often enough that without the fallback a shop hits
    "I can see it but I can't save it" on results that looked perfectly fine.
    """
    attempted = []
    last_error: ProductImageImportError | None = None
    for url in candidates:
        if not url or url in attempted:
            continue
        attempted.append(url)
        try:
            return fetch_remote_image_upload(url, referer=referer), url
        except ProductImageImportError as exc:
            logger.info("Product image candidate %s failed: %s", url, exc)
            last_error = exc

    if last_error is not None:
        raise last_error
    raise ProductImageImportError("Image import token is missing its image URL.")


def fetch_remote_image_upload(url: str, *, referer: str = "") -> RemoteImageUpload:
    validate_remote_image_url(url)
    timeout = getattr(
        settings,
        "POINTY_IMAGE_FETCH_TIMEOUT_SECONDS",
        DEFAULT_IMAGE_FETCH_TIMEOUT_SECONDS,
    )
    max_bytes = remote_image_max_bytes()
    request = Request(url, headers=remote_image_request_headers(url, referer=referer))

    try:
        with build_opener(ValidatingRedirectHandler()).open(
            request,
            timeout=timeout,
        ) as response:
            content_length = response.headers.get("Content-Length")
            if content_length and int(content_length) > max_bytes:
                raise ProductImageDownloadError("Selected image is larger than allowed.")

            data = bytearray()
            while True:
                chunk = response.read(64 * 1024)
                if not chunk:
                    break
                data.extend(chunk)
                if len(data) > max_bytes:
                    raise ProductImageDownloadError("Selected image is larger than allowed.")
            final_url = response.geturl()
    except ProductImageImportError:
        raise
    except (HTTPError, URLError, TimeoutError, OSError, ValueError) as exc:
        raise ProductImageDownloadError("Selected image could not be downloaded.") from exc

    if not data:
        raise ProductImageDownloadError("Selected image was empty.")

    # Decode rather than trust the Content-Type header. Hosts mislabel images
    # constantly, and a hotlink-blocking host will serve its "no hotlinking"
    # HTML page under an image/* header -- stored unchecked, that page becomes
    # the product photo and renders as a broken tile forever after.
    normalized = normalize_image_bytes(bytes(data))
    if normalized is None:
        raise ProductImageDownloadError("Selected URL did not return an image.")

    return RemoteImageUpload(
        name=remote_image_filename(final_url, normalized.extension),
        content_type=normalized.content_type,
        data=normalized.data,
    )


def remote_image_request_headers(url: str, *, referer: str = "") -> dict[str, str]:
    """Headers that read as a browser loading the image on its own page.

    Publisher hosts fend off hotlinking and bot traffic by checking exactly these
    two things, so an honest "PointyPOS/1.0" with no Referer is precisely the
    request they are built to refuse. Note the Accept list omits AVIF and SVG on
    purpose: a content-negotiating CDN offered those would hand back a format the
    clients cannot decode, which is the other half of this bug.
    """
    headers = {
        "Accept": "image/webp,image/apng,image/jpeg,image/png,image/gif,image/*;q=0.8",
        "Accept-Language": "en-US,en;q=0.9,ar;q=0.8",
        "User-Agent": (
            "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
            "(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"
        ),
    }
    # A browser sends the page the image is embedded in; that is the value
    # referer-based hotlink rules are checking for. Only send it when it is a
    # safe absolute http(s) URL, never a private host we probed.
    referer = str(referer or "").strip()
    if referer:
        parsed = urlparse(referer)
        if parsed.scheme in {"http", "https"} and parsed.hostname:
            headers["Referer"] = referer
    else:
        parsed = urlparse(url)
        if parsed.scheme in {"http", "https"} and parsed.hostname:
            headers["Referer"] = f"{parsed.scheme}://{parsed.hostname}/"
    return headers


def sign_image_import_payload(payload: dict) -> str:
    return signing.dumps(payload, salt=IMAGE_IMPORT_SIGNING_SALT, compress=True)


def load_image_import_payload(token: str) -> dict:
    max_age = getattr(
        settings,
        "POINTY_IMAGE_IMPORT_TOKEN_MAX_AGE_SECONDS",
        DEFAULT_IMAGE_IMPORT_MAX_AGE_SECONDS,
    )
    try:
        payload = signing.loads(
            token,
            salt=IMAGE_IMPORT_SIGNING_SALT,
            max_age=max_age,
        )
    except signing.BadSignature as exc:
        raise ProductImageImportError("Image import token is invalid or expired.") from exc
    if not isinstance(payload, dict):
        raise ProductImageImportError("Image import token payload is invalid.")
    return payload


def validate_remote_image_url(url: str) -> None:
    parsed = urlparse(str(url or "").strip())
    if parsed.scheme not in {"http", "https"}:
        raise ProductImageImportError("Only HTTP and HTTPS image URLs are allowed.")
    if not parsed.hostname:
        raise ProductImageImportError("Image URL must include a hostname.")
    if parsed.username or parsed.password:
        raise ProductImageImportError("Image URL credentials are not allowed.")

    hostname = parsed.hostname.lower()
    if hostname in {"localhost", "localhost.localdomain"} or hostname.endswith(".local"):
        raise ProductImageImportError("Local image URLs are not allowed.")

    try:
        addresses = socket.getaddrinfo(hostname, parsed.port, type=socket.SOCK_STREAM)
    except socket.gaierror as exc:
        raise ProductImageImportError("Image URL host could not be resolved.") from exc

    for address in addresses:
        ip_address = ipaddress.ip_address(address[4][0])
        if (
            ip_address.is_private
            or ip_address.is_loopback
            or ip_address.is_link_local
            or ip_address.is_multicast
            or ip_address.is_reserved
            or ip_address.is_unspecified
        ):
            raise ProductImageImportError("Private or local image hosts are not allowed.")


def remote_image_max_bytes() -> int:
    return int(
        getattr(
            settings,
            "POINTY_PRODUCT_IMAGE_IMPORT_MAX_BYTES",
            getattr(settings, "POINTY_ATTACHMENT_MAX_UPLOAD_BYTES", 10 * 1024 * 1024),
        )
    )


def remote_image_filename(url: str, extension: str) -> str:
    """Name the stored file after the URL, but always with the real extension.

    The extension comes from what the bytes actually decoded to, not from the
    URL: a ``.jpg`` that was really an AVIF has just been re-encoded, and
    carrying the original suffix would mislabel it all over again.
    """
    path_name = clean_original_filename(Path(urlparse(url).path).name)
    stem = Path(path_name).stem or "product-image"
    return f"{stem}{extension or '.img'}"


def is_supported_remote_image_result_url(url: str) -> bool:
    parsed = urlparse(str(url or "").strip())
    return bool(parsed.scheme in {"http", "https"} and parsed.hostname)


def optional_int(value) -> int | None:
    try:
        return int(value)
    except (TypeError, ValueError):
        return None
