from __future__ import annotations

import ipaddress
import json
import logging
import mimetypes
import socket
from dataclasses import dataclass
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode, urlparse
from urllib.request import (
    HTTPRedirectHandler,
    Request,
    build_opener,
)

from django.conf import settings
from django.core import signing

from .models import Attachment
from .services import clean_original_filename, store_uploaded_attachment


IMAGE_IMPORT_SIGNING_SALT = "pointy.product-image-import"
DEFAULT_SERPAPI_ENDPOINT = "https://serpapi.com/search.json"
DEFAULT_SERPER_ENDPOINT = "https://google.serper.dev/images"
DEFAULT_IMAGE_IMPORT_MAX_AGE_SECONDS = 60 * 60
DEFAULT_IMAGE_SEARCH_PAGE_SIZE = 30
DEFAULT_IMAGE_SEARCH_MAX_PAGE_SIZE = 50
DEFAULT_IMAGE_FETCH_TIMEOUT_SECONDS = 8
DEFAULT_IMAGE_SEARCH_PROVIDERS = ("serper", "serpapi")
DISABLED_IMAGE_SEARCH_PROVIDERS = {"", "disabled", "none", "off"}

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
    provider: str = "serpapi"

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


def configured_image_search_provider() -> str:
    providers = configured_image_search_providers()
    return providers[0] if providers else "disabled"


def configured_image_search_providers() -> list[str]:
    raw_providers = getattr(settings, "POINTY_IMAGE_SEARCH_PROVIDERS", "")
    if raw_providers:
        provider_names = parse_provider_names(raw_providers)
    else:
        legacy_provider = str(getattr(settings, "POINTY_IMAGE_SEARCH_PROVIDER", "")).strip()
        if legacy_provider:
            provider_names = parse_provider_names(legacy_provider)
            if not provider_names or provider_names[0].lower() in DISABLED_IMAGE_SEARCH_PROVIDERS:
                return []
            provider_names.extend(
                name
                for name in DEFAULT_IMAGE_SEARCH_PROVIDERS
                if name not in {provider.lower() for provider in provider_names}
            )
        else:
            provider_names = list(DEFAULT_IMAGE_SEARCH_PROVIDERS)

    configured_names = []
    seen = set()
    for name in provider_names:
        normalized = name.lower()
        if normalized in DISABLED_IMAGE_SEARCH_PROVIDERS or normalized in seen:
            continue
        configured_names.append(normalized)
        seen.add(normalized)
    return configured_names


def parse_provider_names(value) -> list[str]:
    if isinstance(value, str):
        raw_names = value.split(",")
    else:
        raw_names = value or []
    return [str(name).strip() for name in raw_names if str(name).strip()]


def search_product_images(
    *,
    query: str,
    page: int = 1,
    page_size: int = DEFAULT_IMAGE_SEARCH_PAGE_SIZE,
) -> list[ProductImageSearchResult]:
    provider_names = configured_image_search_providers()
    if not provider_names:
        raise ProductImageSearchUnavailable("Product image search is not configured.")

    page = max(page, 1)
    page_size = min(max(page_size, 1), DEFAULT_IMAGE_SEARCH_MAX_PAGE_SIZE)
    results = []
    seen_urls = set()
    failures = []
    completed_provider = False

    for provider_name in provider_names:
        remaining = page_size - len(results)
        if remaining <= 0:
            break

        search_provider = image_search_provider_registry().get(provider_name)
        if search_provider is None:
            failures.append(f"{provider_name}: unsupported")
            logger.warning(
                "Unsupported product image search provider configured: %s",
                provider_name,
            )
            continue

        try:
            provider_results = search_provider(
                query=query,
                page=page,
                page_size=remaining,
            )
        except ProductImageSearchUnavailable as exc:
            failures.append(f"{provider_name}: {exc}")
            logger.info(
                "Product image search provider %s unavailable: %s",
                provider_name,
                exc,
            )
            continue
        except ProductImageSearchError as exc:
            failures.append(f"{provider_name}: {exc}")
            logger.warning(
                "Product image search provider %s failed: %s",
                provider_name,
                exc,
            )
            continue

        completed_provider = True
        for result in provider_results:
            url_key = normalized_result_url(result)
            if not url_key or url_key in seen_urls:
                continue
            results.append(result)
            seen_urls.add(url_key)
            if len(results) >= page_size:
                break

    if completed_provider:
        return results

    if failures:
        raise ProductImageSearchUnavailable(
            "Product image search providers are unavailable right now."
        )
    raise ProductImageSearchUnavailable("Product image search is not configured.")


def image_search_provider_registry():
    return {
        "serper": search_serper_images,
        "serpapi": search_serpapi_images,
    }


def search_serper_images(
    *,
    query: str,
    page: int,
    page_size: int,
) -> list[ProductImageSearchResult]:
    api_key = getattr(settings, "POINTY_SERPER_API_KEY", "")
    if not api_key:
        raise ProductImageSearchUnavailable("Serper image search key is not configured.")

    page = max(page, 1)
    page_size = min(max(page_size, 1), DEFAULT_IMAGE_SEARCH_MAX_PAGE_SIZE)
    endpoint = getattr(settings, "POINTY_SERPER_ENDPOINT", DEFAULT_SERPER_ENDPOINT)
    payload = fetch_json(
        endpoint,
        method="POST",
        body={
            "q": query,
            "page": page,
            "num": page_size,
            "hl": getattr(settings, "POINTY_IMAGE_SEARCH_LANGUAGE", "ar"),
            "gl": getattr(settings, "POINTY_IMAGE_SEARCH_COUNTRY", "us"),
        },
        headers={"X-API-KEY": api_key},
    )
    error_message = payload.get("error") or payload.get("message")
    if error_message:
        raise ProductImageSearchUnavailable(str(error_message))

    results = []
    for item in payload.get("images", []):
        if not isinstance(item, dict):
            continue
        image_url = str(
            item.get("imageUrl") or item.get("image_url") or item.get("original") or ""
        ).strip()
        thumbnail_url = str(
            item.get("thumbnailUrl") or item.get("thumbnail_url") or item.get("thumbnail") or ""
        ).strip()
        thumbnail_url = thumbnail_url or image_url
        if not is_supported_remote_image_result_url(image_url) or not thumbnail_url:
            continue
        source_url = str(item.get("link") or item.get("sourceUrl") or "").strip()
        results.append(
            ProductImageSearchResult(
                title=str(item.get("title") or "").strip(),
                thumbnail_url=thumbnail_url,
                image_url=image_url,
                source_url=source_url,
                source_name=source_name_from_result(item, source_url),
                width=optional_int(
                    item.get("imageWidth")
                    or item.get("image_width")
                    or item.get("width")
                    or item.get("original_width")
                ),
                height=optional_int(
                    item.get("imageHeight")
                    or item.get("image_height")
                    or item.get("height")
                    or item.get("original_height")
                ),
                provider="serper",
            )
        )
        if len(results) >= page_size:
            break
    return results


def search_serpapi_images(
    *,
    query: str,
    page: int,
    page_size: int,
) -> list[ProductImageSearchResult]:
    api_key = getattr(settings, "POINTY_SERPAPI_API_KEY", "")
    if not api_key:
        raise ProductImageSearchUnavailable("SerpApi image search key is not configured.")

    page = max(page, 1)
    page_size = min(max(page_size, 1), DEFAULT_IMAGE_SEARCH_MAX_PAGE_SIZE)
    params = {
        "engine": "google_images",
        "api_key": api_key,
        "q": query,
        "ijn": page - 1,
        "safe": getattr(settings, "POINTY_IMAGE_SEARCH_SAFE", "active"),
        "hl": getattr(settings, "POINTY_IMAGE_SEARCH_LANGUAGE", "ar"),
        "gl": getattr(settings, "POINTY_IMAGE_SEARCH_COUNTRY", "us"),
    }
    endpoint = getattr(settings, "POINTY_SERPAPI_ENDPOINT", DEFAULT_SERPAPI_ENDPOINT)
    payload = fetch_json(f"{endpoint}?{urlencode(params)}")
    if payload.get("error"):
        raise ProductImageSearchUnavailable(str(payload["error"]))

    results = []
    for item in payload.get("images_results", []):
        if not isinstance(item, dict):
            continue
        image_url = str(item.get("original") or "").strip()
        thumbnail_url = str(item.get("thumbnail") or "").strip()
        if not is_supported_remote_image_result_url(image_url) or not thumbnail_url:
            continue
        results.append(
            ProductImageSearchResult(
                title=str(item.get("title") or "").strip(),
                thumbnail_url=thumbnail_url,
                image_url=image_url,
                source_url=str(item.get("link") or "").strip(),
                source_name=source_name_from_result(
                    item,
                    str(item.get("link") or "").strip(),
                ),
                width=optional_int(item.get("original_width") or item.get("width")),
                height=optional_int(item.get("original_height") or item.get("height")),
                provider="serpapi",
            )
        )
        if len(results) >= page_size:
            break
    return results


def fetch_json(
    url: str,
    *,
    method: str = "GET",
    body: dict | None = None,
    headers: dict | None = None,
) -> dict:
    timeout = getattr(
        settings,
        "POINTY_IMAGE_FETCH_TIMEOUT_SECONDS",
        DEFAULT_IMAGE_FETCH_TIMEOUT_SECONDS,
    )
    request_headers = {
        "Accept": "application/json",
        "User-Agent": "PointyPOS/1.0",
    }
    if headers:
        request_headers.update(headers)
    data = None
    if body is not None:
        data = json.dumps(body).encode("utf-8")
        request_headers.setdefault("Content-Type", "application/json")
    request = Request(
        url,
        data=data,
        headers=request_headers,
        method=method,
    )
    try:
        with build_opener().open(request, timeout=timeout) as response:
            body = response.read()
    except (HTTPError, URLError, TimeoutError, OSError) as exc:
        raise ProductImageSearchUnavailable("Product image search request failed.") from exc

    try:
        decoded = json.loads(body.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise ProductImageSearchUnavailable("Product image search returned invalid JSON.") from exc
    return decoded if isinstance(decoded, dict) else {}


def import_product_image_from_token(
    *,
    owner,
    import_token: str,
    is_primary: bool = True,
    created_by=None,
) -> Attachment:
    payload = load_image_import_payload(import_token)
    image_url = str(payload.get("image_url") or "").strip()
    if not image_url:
        raise ProductImageImportError("Image import token is missing its image URL.")

    upload = fetch_remote_image_upload(image_url)
    metadata = {
        "imported_from": "internet_search",
        "source_url": payload.get("source_url") or "",
        "thumbnail_url": payload.get("thumbnail_url") or "",
        "source_name": payload.get("source_name") or "",
        "title": payload.get("title") or "",
        "provider": payload.get("provider") or "",
    }
    return store_uploaded_attachment(
        uploaded_file=upload,
        owner=owner,
        role=Attachment.Role.PRODUCT_IMAGE,
        is_primary=is_primary,
        metadata=metadata,
        created_by=created_by,
    )


def fetch_remote_image_upload(url: str) -> RemoteImageUpload:
    validate_remote_image_url(url)
    timeout = getattr(
        settings,
        "POINTY_IMAGE_FETCH_TIMEOUT_SECONDS",
        DEFAULT_IMAGE_FETCH_TIMEOUT_SECONDS,
    )
    max_bytes = remote_image_max_bytes()
    request = Request(
        url,
        headers={
            "Accept": "image/avif,image/webp,image/apng,image/svg+xml,image/*,*/*;q=0.8",
            "User-Agent": "PointyPOS/1.0",
        },
    )

    try:
        with build_opener(ValidatingRedirectHandler()).open(
            request,
            timeout=timeout,
        ) as response:
            content_type = response.headers.get_content_type()
            if not content_type.startswith("image/"):
                raise ProductImageDownloadError("Selected URL did not return an image.")

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

    return RemoteImageUpload(
        name=remote_image_filename(final_url, content_type),
        content_type=content_type,
        data=bytes(data),
    )


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


def remote_image_filename(url: str, content_type: str) -> str:
    path_name = clean_original_filename(Path(urlparse(url).path).name)
    suffix = Path(path_name).suffix
    if suffix:
        return path_name
    extension = mimetypes.guess_extension(content_type) or ".img"
    return f"{path_name or 'product-image'}{extension}"


def normalized_result_url(result: ProductImageSearchResult) -> str:
    return str(result.image_url or "").strip().lower()


def is_supported_remote_image_result_url(url: str) -> bool:
    parsed = urlparse(str(url or "").strip())
    return bool(parsed.scheme in {"http", "https"} and parsed.hostname)


def source_name_from_result(item: dict, source_url: str) -> str:
    source_name = str(item.get("source") or item.get("domain") or "").strip()
    if source_name:
        return source_name
    hostname = urlparse(source_url).hostname
    return hostname or ""


def optional_int(value) -> int | None:
    try:
        return int(value)
    except (TypeError, ValueError):
        return None
