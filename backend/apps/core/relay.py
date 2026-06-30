import base64
import hashlib
import hmac
import json
import ssl
from dataclasses import dataclass
from datetime import datetime, timezone as datetime_timezone
from urllib import error, request
from urllib.parse import urljoin, urlparse

from django.conf import settings
from django.core.exceptions import ImproperlyConfigured
from django.db import transaction
from django.utils import timezone
from django.utils.dateparse import parse_datetime

from .models import RelayConnectorSetupToken, RelayInstallation, ShopSettings


class RelayControlError(RuntimeError):
    def __init__(self, message, *, status_code=None, body=None):
        super().__init__(message)
        self.status_code = status_code
        self.body = body


@dataclass(frozen=True)
class RelayControlConfig:
    control_url: str
    public_api_url: str
    connector_address: str
    admin_token: str
    access_token: str
    installation_id: str
    connector_token: str
    enrollment_token: str
    timeout_seconds: int
    ai_timeout_seconds: int
    image_search_timeout_seconds: int
    allow_insecure_control: bool
    ca_file: str
    client_cert_file: str
    client_key_file: str


def relay_config():
    return RelayControlConfig(
        control_url=str(getattr(settings, "POINTY_RELAY_CONTROL_URL", "")).strip(),
        public_api_url=str(getattr(settings, "POINTY_RELAY_PUBLIC_API_URL", "")).strip(),
        connector_address=str(getattr(settings, "POINTY_RELAY_CONNECTOR_ADDR", "")).strip(),
        admin_token=str(getattr(settings, "POINTY_RELAY_ADMIN_TOKEN", "")).strip(),
        access_token=str(getattr(settings, "POINTY_RELAY_ACCESS_TOKEN", "")).strip(),
        installation_id=str(getattr(settings, "POINTY_RELAY_INSTALLATION_ID", "")).strip(),
        connector_token=str(getattr(settings, "POINTY_RELAY_CONNECTOR_TOKEN", "")).strip(),
        enrollment_token=str(getattr(settings, "POINTY_RELAY_ENROLLMENT_TOKEN", "")).strip(),
        timeout_seconds=max(
            int(getattr(settings, "POINTY_RELAY_REQUEST_TIMEOUT_SECONDS", 5)),
            1,
        ),
        ai_timeout_seconds=max(
            int(getattr(settings, "POINTY_RELAY_AI_REQUEST_TIMEOUT_SECONDS", 120)),
            1,
        ),
        image_search_timeout_seconds=max(
            int(getattr(settings, "POINTY_RELAY_IMAGE_SEARCH_TIMEOUT_SECONDS", 15)),
            1,
        ),
        allow_insecure_control=bool(
            getattr(settings, "POINTY_RELAY_ALLOW_INSECURE_CONTROL", False)
        ),
        ca_file=str(getattr(settings, "POINTY_RELAY_CONTROL_CA_FILE", "")).strip(),
        client_cert_file=str(
            getattr(settings, "POINTY_RELAY_CONTROL_CLIENT_CERT_FILE", "")
        ).strip(),
        client_key_file=str(getattr(settings, "POINTY_RELAY_CONTROL_CLIENT_KEY_FILE", "")).strip(),
    )


def validate_relay_config(config):
    if not config.control_url:
        raise ImproperlyConfigured("POINTY_RELAY_CONTROL_URL is required.")
    if not config.public_api_url:
        raise ImproperlyConfigured("POINTY_RELAY_PUBLIC_API_URL is required.")
    if not config.connector_address:
        raise ImproperlyConfigured("POINTY_RELAY_CONNECTOR_ADDR is required.")
    if (
        not config.admin_token
        and not (config.access_token and config.installation_id)
        and not config.enrollment_token
    ):
        raise ImproperlyConfigured(
            "Relay authentication is required: set POINTY_RELAY_ENROLLMENT_TOKEN (the "
            "shop's license key, redeemed on first boot), POINTY_RELAY_ACCESS_TOKEN + "
            "POINTY_RELAY_INSTALLATION_ID (already-provisioned scoped credentials), or "
            "POINTY_RELAY_ADMIN_TOKEN (operator/development only)."
        )
    parsed = urlparse(config.control_url)
    if parsed.scheme != "https" and not config.allow_insecure_control:
        raise ImproperlyConfigured(
            "POINTY_RELAY_CONTROL_URL must use https unless "
            "POINTY_RELAY_ALLOW_INSECURE_CONTROL is enabled for local development."
        )


class RelayControlClient:
    def __init__(self, config=None):
        self.config = config or relay_config()
        validate_relay_config(self.config)
        self._ssl_context = self._build_ssl_context()

    def provision_installation(self, *, shop_name):
        return self._request(
            "POST",
            "/v1/installations",
            body={
                "business_id": str(getattr(settings, "POINTY_RELAY_BUSINESS_ID", "")).strip(),
                "shop_name": shop_name,
                "relay_enabled": False,
                "subscription_active": False,
                "ai_enabled": False,
            },
            admin=True,
        )

    def enroll_installation(self, *, enrollment_token, shop_name):
        """Redeem a single-use enrollment (license) key for a brand-new
        installation and its scoped credentials. Authenticated solely by the
        license key, so an on-prem backend self-enrolls without the admin token.
        """
        return self._request(
            "POST",
            "/v1/enroll",
            body={"shop_name": shop_name},
            enrollment_token=enrollment_token,
        )

    def _installation_auth(self):
        """Auth kwargs for an installation-scoped relay call.

        On-prem backends hold only their own per-installation access token, never
        the company-wide admin token, so use the access token when configured and
        fall back to the admin token for operator/development setups.
        """
        if self.config.access_token:
            return {"relay_token": self.config.access_token}
        return {"admin": True}

    def get_installation(self, installation_id):
        return self._request(
            "GET",
            f"/v1/installations/{installation_id}",
            **self._installation_auth(),
        )

    def issue_ticket(self, *, access_token, device_id="", device_name=""):
        return self._request(
            "POST",
            "/v1/relay-tickets",
            body={"device_id": device_id, "device_name": device_name},
            relay_token=access_token,
        )

    def issue_connector_certificate(self, *, installation_id, csr_pem):
        return self._request(
            "POST",
            f"/v1/installations/{installation_id}/connector-certificate",
            body={"csr_pem": csr_pem},
            **self._installation_auth(),
        )

    def get_ai_usage(self, access_token):
        """Read the installation's current 5h + weekly AI usage (no consume)."""
        return self._request("GET", "/v1/ai/usage", relay_token=access_token)

    def get_holidays(self, *, access_token):
        """Read the installation's holiday calendar (global rows + this shop's
        local events). Authenticated with the installation access token, like
        ``get_ai_usage``. Returns the decoded ``{"holidays": [...]}`` payload."""
        return self._request("GET", "/v1/holidays", relay_token=access_token)

    def search_product_images(self, *, access_token, query, page=1, page_size=30):
        """Run a relay-hosted product image search (Serper.dev).

        The relay holds the Serper key — so shops never manage one — and gates on
        the installation's remote-access entitlement (subscription +
        relay_enabled), exactly like a relayed request. Returns the decoded
        ``{"results": [...]}`` payload; raises ``RelayControlError`` on transport
        or non-2xx status.
        """
        return self._request(
            "POST",
            "/v1/image-search",
            body={"query": query, "page": page, "page_size": page_size},
            relay_token=access_token,
            timeout=self.config.image_search_timeout_seconds,
        )

    def open_ai_stream(
        self,
        *,
        access_token,
        messages,
        attachments=None,
        tools=None,
        count_usage=True,
        max_tokens=0,
        temperature=None,
        route_tier="",
        want_title=False,
        web_search=False,
    ):
        """Open the relay AI chat endpoint and return the raw streaming response.

        The relay holds the OpenRouter key and gates on the installation's AI
        entitlement; the caller iterates the SSE body (see
        ``apps.ai.relay_stream.iter_relay_sse``). Authenticates exactly like
        ``issue_ticket`` so the production public/admin-listener split is
        inherited, not re-solved. Raises ``RelayControlError`` on transport or
        non-2xx status before any bytes are streamed to the client.
        """
        body = {"messages": list(messages)}
        if attachments:
            body["attachments"] = list(attachments)
        if tools:
            body["tools"] = list(tools)
        # Only the user-initiated turn charges usage; tool-continuation turns pass
        # count_usage=False so one question doesn't drain the quota.
        if not count_usage:
            body["count_usage"] = False
        # Carry the difficulty tier the relay picked for this turn's first request,
        # so a continuation reuses that one dynamic decision instead of re-routing
        # (or collapsing to a fixed tier). Honoured by the relay only on
        # continuations; ignored on user turns.
        if route_tier:
            body["route_tier"] = route_tier
        # First turn only: ask the relay to name the conversation (returned in done).
        if want_title:
            body["want_title"] = True
        # Carry the user turn's web-search decision onto its continuations so an
        # agentic web+tools flow keeps searching on the round that combines them.
        if web_search:
            body["web_search"] = True
        if max_tokens:
            body["max_tokens"] = max_tokens
        if temperature is not None:
            body["temperature"] = temperature
        return self._open_stream(
            "POST",
            "/v1/ai/chat",
            body=body,
            relay_token=access_token,
        )

    def _open_stream(self, method, path, *, body=None, admin=False, relay_token=""):
        data = None
        headers = {"Accept": "text/event-stream"}
        if body is not None:
            data = json.dumps(body).encode("utf-8")
            headers["Content-Type"] = "application/json"
        if admin:
            headers["Authorization"] = f"Bearer {self.config.admin_token}"
        if relay_token:
            headers["X-Pointy-Relay-Token"] = relay_token

        url = urljoin(self.config.control_url.rstrip("/") + "/", path.lstrip("/"))
        http_request = request.Request(url, data=data, headers=headers, method=method)
        try:
            return request.urlopen(
                http_request,
                timeout=self.config.ai_timeout_seconds,
                context=self._ssl_context,
            )
        except error.HTTPError as exc:
            detail = exc.read().decode("utf-8", errors="replace")
            raise RelayControlError(
                f"relay AI returned {exc.code}: {detail}",
                status_code=exc.code,
                body=detail,
            ) from exc
        except error.URLError as exc:
            raise RelayControlError(f"relay AI request failed: {exc.reason}") from exc

    def _request(
        self, method, path, *, body=None, admin=False, relay_token="", enrollment_token="", timeout=None
    ):
        data = None
        headers = {"Accept": "application/json"}
        if body is not None:
            data = json.dumps(body).encode("utf-8")
            headers["Content-Type"] = "application/json"
        if admin:
            headers["Authorization"] = f"Bearer {self.config.admin_token}"
        if relay_token:
            headers["X-Pointy-Relay-Token"] = relay_token
        if enrollment_token:
            headers["X-Pointy-Enrollment-Token"] = enrollment_token

        url = urljoin(self.config.control_url.rstrip("/") + "/", path.lstrip("/"))
        http_request = request.Request(url, data=data, headers=headers, method=method)
        try:
            with request.urlopen(
                http_request,
                timeout=timeout or self.config.timeout_seconds,
                context=self._ssl_context,
            ) as response:
                content = response.read()
        except error.HTTPError as exc:
            detail = exc.read().decode("utf-8", errors="replace")
            raise RelayControlError(f"relay control returned {exc.code}: {detail}") from exc
        except error.URLError as exc:
            raise RelayControlError(f"relay control request failed: {exc.reason}") from exc

        if not content:
            return {}
        try:
            return json.loads(content.decode("utf-8"))
        except json.JSONDecodeError as exc:
            raise RelayControlError("relay control returned invalid JSON") from exc

    def _build_ssl_context(self):
        parsed = urlparse(self.config.control_url)
        if parsed.scheme != "https":
            return None
        context = ssl.create_default_context(cafile=self.config.ca_file or None)
        if self.config.client_cert_file or self.config.client_key_file:
            if not self.config.client_cert_file or not self.config.client_key_file:
                raise ImproperlyConfigured(
                    "POINTY_RELAY_CONTROL_CLIENT_CERT_FILE and "
                    "POINTY_RELAY_CONTROL_CLIENT_KEY_FILE must be provided together."
                )
            context.load_cert_chain(
                self.config.client_cert_file,
                self.config.client_key_file,
            )
        return context


def relay_status_payload(installation):
    if installation is None:
        return {
            "configured": False,
            "remote_access_supported": False,
            "installation_id": "",
            "shop_name": ShopSettings.load().shop_name,
            "relay_public_api_url": "",
            "relay_connector_address": "",
            "relay_enabled": False,
            "subscription_active": False,
            "ai_enabled": False,
            "subscription_ends_at": None,
            "last_synced_at": None,
            "connector_last_seen_at": None,
            "connector_version": "",
        }
    return {
        "configured": True,
        "remote_access_supported": installation.remote_access_supported,
        "installation_id": installation.installation_id,
        "shop_name": installation.shop_name,
        "relay_public_api_url": installation.relay_public_api_url,
        "relay_connector_address": installation.relay_connector_address,
        "relay_enabled": installation.relay_enabled,
        "subscription_active": installation.subscription_active,
        "ai_enabled": installation.ai_enabled,
        "subscription_ends_at": installation.subscription_ends_at,
        "last_synced_at": installation.last_synced_at,
        "connector_last_seen_at": installation.connector_last_seen_at,
        "connector_version": installation.connector_version,
    }


def relay_ai_available(installation=None):
    """Whether relay-hosted AI is currently usable for this shop.

    Mirrors the relay's own gate: an active, unexpired subscription plus the AI
    flag, independent of remote-access (relay_enabled). The frontend reads this
    (via the ``me`` payload) to show or hide the AI assistant.
    """
    if installation is None:
        installation = RelayInstallation.load()
    if installation is None or not installation.ai_enabled:
        return False
    if not installation.subscription_active:
        return False
    if (
        installation.subscription_ends_at is not None
        and installation.subscription_ends_at <= timezone.now()
    ):
        return False
    return True


def parse_relay_datetime(value):
    if value in ("", None):
        return None
    if isinstance(value, datetime):
        parsed = value
    elif isinstance(value, str):
        parsed = parse_datetime(value)
    else:
        raise RelayControlError("relay control returned an invalid datetime value")

    if parsed is None:
        raise RelayControlError("relay control returned an invalid datetime value")
    if timezone.is_naive(parsed):
        parsed = timezone.make_aware(parsed, datetime_timezone.utc)
    return parsed


def _persist_provisioned(provisioned, *, public_api_url, connector_address, shop_settings):
    relay_installation = provisioned["installation"]
    return RelayInstallation.objects.create(
        installation_id=relay_installation["id"],
        shop_name=relay_installation.get("shop_name") or shop_settings.shop_name,
        relay_public_api_url=public_api_url,
        relay_connector_address=connector_address,
        connector_token=provisioned["connector_token"],
        access_token=provisioned["access_token"],
        relay_enabled=bool(relay_installation.get("relay_enabled", False)),
        subscription_active=bool(relay_installation.get("subscription_active", False)),
        ai_enabled=bool(relay_installation.get("ai_enabled", False)),
        subscription_ends_at=parse_relay_datetime(relay_installation.get("subscription_ends_at")),
        last_synced_at=timezone.now(),
    )


def ensure_relay_installation(*, client=None, config=None):
    installation = RelayInstallation.load()
    if installation is not None:
        return installation, False

    cfg = config or relay_config()
    shop_settings = ShopSettings.load()

    # On-prem: build the installation from the per-installation credentials handed
    # out at central provisioning. This path never calls the admin API, so a
    # customer backend never needs the company-wide fleet admin token. Entitlement
    # fields stay at their defaults until the first scoped sync populates them.
    if cfg.access_token and cfg.installation_id:
        installation = RelayInstallation.objects.create(
            installation_id=cfg.installation_id,
            shop_name=shop_settings.shop_name,
            relay_public_api_url=cfg.public_api_url,
            relay_connector_address=cfg.connector_address,
            connector_token=cfg.connector_token,
            access_token=cfg.access_token,
        )
        return installation, True

    # On-prem first boot: redeem the shop's single-use license key for scoped
    # credentials. No admin token, no operator machine — the backend self-enrolls.
    if cfg.enrollment_token:
        relay_client = client or RelayControlClient()
        provisioned = relay_client.enroll_installation(
            enrollment_token=cfg.enrollment_token,
            shop_name=shop_settings.shop_name,
        )
        installation = _persist_provisioned(
            provisioned,
            public_api_url=relay_client.config.public_api_url,
            connector_address=relay_client.config.connector_address,
            shop_settings=shop_settings,
        )
        return installation, True

    # Operator/development: self-provision through the admin API.
    relay_client = client or RelayControlClient()
    provisioned = relay_client.provision_installation(shop_name=shop_settings.shop_name)
    installation = _persist_provisioned(
        provisioned,
        public_api_url=relay_client.config.public_api_url,
        connector_address=relay_client.config.connector_address,
        shop_settings=shop_settings,
    )
    return installation, True


def sync_relay_installation(installation, *, client=None):
    if installation is None:
        return None
    relay_client = client or RelayControlClient()
    relay_installation = relay_client.get_installation(installation.installation_id)
    installation.shop_name = relay_installation.get("shop_name") or installation.shop_name
    installation.relay_enabled = bool(relay_installation.get("relay_enabled", False))
    installation.subscription_active = bool(relay_installation.get("subscription_active", False))
    installation.ai_enabled = bool(relay_installation.get("ai_enabled", False))
    installation.subscription_ends_at = parse_relay_datetime(
        relay_installation.get("subscription_ends_at")
    )
    installation.last_synced_at = timezone.now()
    installation.save(
        update_fields=[
            "shop_name",
            "relay_enabled",
            "subscription_active",
            "ai_enabled",
            "subscription_ends_at",
            "last_synced_at",
            "updated_at",
        ]
    )
    return installation


def issue_pairing_ticket(installation, *, device_id="", device_name="", client=None):
    relay_client = client or RelayControlClient()
    issued = relay_client.issue_ticket(
        access_token=installation.access_token,
        device_id=device_id,
        device_name=device_name,
    )
    installation.last_pairing_issued_at = timezone.now()
    installation.save(update_fields=["last_pairing_issued_at", "updated_at"])
    return issued


def consume_connector_setup_token(raw_token):
    token = str(raw_token or "").strip()
    if not token:
        return False
    token_hash = connector_setup_token_hash(token)
    now = timezone.now()
    with transaction.atomic():
        record = _locked_setup_token(token_hash, token)
        if record is None:
            return False
        if record.consumed_at is not None:
            return False
        if record.expires_at is not None and now >= record.expires_at:
            return False
        record.consumed_at = now
        record.save(update_fields=["consumed_at", "updated_at"])
    return True


def connector_setup_token_hash(raw_token):
    digest = hashlib.sha256(str(raw_token).encode("utf-8")).digest()
    return base64.urlsafe_b64encode(digest).decode("ascii").rstrip("=")


def _locked_setup_token(token_hash, raw_token):
    record = (
        RelayConnectorSetupToken.objects.select_for_update().filter(token_hash=token_hash).first()
    )
    if record is not None:
        return record

    seed_token = str(getattr(settings, "POINTY_RELAY_CONNECTOR_SETUP_TOKEN", "")).strip()
    if not seed_token or not hmac.compare_digest(raw_token, seed_token):
        return None
    record, _ = RelayConnectorSetupToken.objects.select_for_update().get_or_create(
        token_hash=token_hash
    )
    return record
