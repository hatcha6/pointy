import base64
import hashlib
import json
import logging
import ssl
import time
from dataclasses import dataclass, replace
from datetime import datetime, timezone as datetime_timezone
from decimal import Decimal, InvalidOperation
from urllib import error, request
from urllib.parse import quote, urljoin, urlparse

from django.conf import settings
from django.core.exceptions import ImproperlyConfigured
from django.db import transaction
from django.utils import timezone
from django.utils.dateparse import parse_datetime

from . import caching
from .credentials import constant_time_secret_equal
from .models import RelayConnectorSetupToken, RelayInstallation, ShopSettings

logger = logging.getLogger(__name__)


class RelayControlError(RuntimeError):
    def __init__(self, message, *, status_code=None, body=None):
        super().__init__(message)
        self.status_code = status_code
        self.body = body


# --- relay transport cooldown -------------------------------------------------
# A shop on a slow or flapping uplink can spend the full request timeout on
# EVERY relay call, and the opportunistic callers (device pairing at each
# sign-in) chain several. Once a call fails at the transport level (timeout,
# unreachable host) the failure is remembered for a cooldown window so those
# opportunistic paths answer "relay unavailable" at once instead of holding a
# worker for the whole budget again. Deliberate user actions (AI chat, image
# search) do NOT consult it — a merchant who presses the button gets a real
# attempt. Any successful relay call clears it.
_TRANSPORT_COOLDOWN_KEY = "pointy:relay:transport-unavailable"


def _transport_cooldown_seconds():
    return max(int(getattr(settings, "POINTY_RELAY_UNAVAILABLE_COOLDOWN_SECONDS", 300)), 0)


def relay_transport_cooldown_active():
    """Whether a recent relay transport failure is still being remembered."""
    return bool(caching._safe_get(_TRANSPORT_COOLDOWN_KEY, False))


def note_relay_transport_failure():
    ttl = _transport_cooldown_seconds()
    if ttl <= 0:
        return
    caching._safe_set(_TRANSPORT_COOLDOWN_KEY, True, ttl)


def clear_relay_transport_cooldown():
    caching._safe_delete(_TRANSPORT_COOLDOWN_KEY)


class RelayDeadline:
    """A wall-clock budget shared by a chain of relay calls.

    Each call in the chain gets ``min(per_call_timeout, time left)`` so the
    chain as a whole can never exceed the budget, however slow the link is.
    """

    def __init__(self, budget_seconds, *, clock=None):
        # Resolved at call time (not as a default argument) so tests can patch
        # ``time.monotonic``.
        self._clock = clock or time.monotonic
        self._ends_at = self._clock() + max(float(budget_seconds), 0.0)

    def remaining(self):
        return max(self._ends_at - self._clock(), 0.0)

    @property
    def expired(self):
        return self.remaining() <= 0

    def timeout(self, per_call_timeout):
        """Timeout for the next call, or ``None`` when the budget is spent."""
        remaining = self.remaining()
        if remaining <= 0:
            return None
        return min(float(per_call_timeout), remaining)


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

    def get_fleet_status(self, *, timeout=None):
        """Every installation, its version, and the floor they collectively set.

        Admin-scoped: an on-prem backend holds only its own token and has no
        business reading the fleet. This is for the operator deciding whether a
        **contract** migration may ship — one that removes something the
        previous release still writes — which is a fleet-wide question and
        never a per-shop one (§15.1 R3, ``zero-downtime-updates``).
        """
        return self._request(
            "GET", "/v1/fleet/status", admin=True, timeout=timeout
        )

    def get_installation(self, installation_id, *, timeout=None):
        return self._request(
            "GET",
            f"/v1/installations/{installation_id}",
            timeout=timeout,
            **self._installation_auth(),
        )

    def update_installation_metadata(self, installation_id, *, shop_name):
        """Update this installation's shop-owned metadata (the display name) on
        the relay so the operator's fleet console stays current after a rename.
        Authenticated with the installation's own access token, like the status
        read — so an on-prem backend keeps its name fresh without the admin token,
        and an inert/unsubscribed shop can still update it.
        """
        return self._request(
            "PATCH",
            f"/v1/installations/{installation_id}/metadata",
            body={"shop_name": shop_name},
            **self._installation_auth(),
        )

    def issue_ticket(self, *, access_token, device_id="", device_name="", timeout=None):
        return self._request(
            "POST",
            "/v1/relay-tickets",
            body={"device_id": device_id, "device_name": device_name},
            relay_token=access_token,
            timeout=timeout,
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

    def get_exchange_rates(self, *, access_token, since=None):
        """Read the installation's exchange rates from the relay control plane.

        The relay holds one ``fulus.ly`` subscription for the whole fleet and
        fans the published rates out, so a shop never needs a key of its own and
        never spends the provider's daily quota. Gated on the installation's FX
        entitlement (subscription + ``fx_enabled``), the same shape as AI usage
        and image search.

        ``since`` is an ISO-8601 instant; passing the newest rate we already hold
        turns a full calendar into a delta, which matters because rates are
        published several times a day and a shop may have been offline for a
        week. Returns the decoded ``{"rates": [...]}`` payload.
        """
        path = "/v1/exchange-rates"
        if since:
            path = f"{path}?since={quote(str(since))}"
        return self._request("GET", path, relay_token=access_token)

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

    def send_sms(
        self,
        *,
        access_token,
        kind,
        to,
        variables,
        idempotency_key,
        consent_class,
        test=False,
        timeout=None,
    ):
        """Send one templated SMS through the relay (Resala behind it).

        The relay holds the provider account and the approved template ids, and
        gates on the installation's SMS entitlement and monthly allowance. The
        idempotency key makes a retry safe: a key the relay has already seen
        answers with that send's outcome instead of texting the customer twice.
        Returns the decoded ``{id, status, content, ...}``; raises
        ``RelayControlError`` on transport or non-2xx status.
        """
        body = {
            "kind": kind,
            "to": to,
            "variables": list(variables),
            "idempotency_key": idempotency_key,
            "consent_class": consent_class,
        }
        if test:
            body["test"] = True
        return self._request(
            "POST",
            "/v1/sms/send",
            body=body,
            relay_token=access_token,
            timeout=timeout,
        )

    def get_sms_usage(self, *, access_token, timeout=None):
        """This installation's SMS balance, the price of a message and this
        month's sends (no charge)."""
        return self._request(
            "GET", "/v1/sms/usage/self", relay_token=access_token, timeout=timeout
        )

    def get_sms_statuses(self, *, access_token, ids, timeout=None):
        """Delivery status of messages this installation sent, by relay id."""
        joined = ",".join(str(value) for value in ids)
        return self._request(
            "GET",
            f"/v1/sms/status?ids={quote(joined, safe=',')}",
            relay_token=access_token,
            timeout=timeout,
        )

    def get_wallet(self, *, access_token, timeout=None):
        """This installation's wallet: balance, top-up options, latest movements.

        The wallet lives on the relay — it is the shop's prepaid balance with the
        company — and answers on the installation's identity alone, so a shop
        whose subscription lapsed can still see it and pay in.
        """
        return self._request("GET", "/v1/wallet", relay_token=access_token, timeout=timeout)

    def list_wallet_entries(
        self, *, access_token, limit=50, before="", kind="", account="", timeout=None
    ):
        """One account's statement (``main``, the default, or ``sms``), newest
        first; ``before`` is the last entry id seen."""
        return self._request(
            "GET",
            _wallet_path(
                "/v1/wallet/entries", limit=limit, before=before, kind=kind, account=account
            ),
            relay_token=access_token,
            timeout=timeout,
        )

    def list_wallet_topups(self, *, access_token, limit=50, before="", status="", timeout=None):
        """This installation's top-ups, newest first."""
        return self._request(
            "GET",
            _wallet_path("/v1/wallet/topups", limit=limit, before=before, status=status),
            relay_token=access_token,
            timeout=timeout,
        )

    def create_wallet_topup(
        self,
        *,
        access_token,
        amount,
        method,
        idempotency_key,
        requested_by="",
        user_identifier="",
        birth_year="",
        timeout=None,
    ):
        """Start a top-up: the relay records it and asks the gateway to start the
        payment. The answer says what the payer does next — type the code their
        provider texted them, or pay on the gateway's page. The idempotency key
        makes a retry return the SAME payment instead of a second one. Nothing
        is credited until the gateway proves it paid."""
        body = {
            "amount": str(amount),
            "method": method,
            "idempotency_key": idempotency_key,
            "requested_by": requested_by,
        }
        if user_identifier:
            body["user_identifier"] = user_identifier
        if birth_year:
            body["birth_year"] = birth_year
        return self._request(
            "POST", "/v1/wallet/topups", body=body, relay_token=access_token, timeout=timeout
        )

    def get_wallet_topup(self, *, access_token, topup_id, timeout=None):
        """One top-up — what the app polls while the payer pays. For a bank card
        the relay reads the payment back from the gateway on the way."""
        return self._request(
            "GET",
            f"/v1/wallet/topups/{quote(str(topup_id), safe='')}",
            relay_token=access_token,
            timeout=timeout,
        )

    def confirm_wallet_topup(self, *, access_token, topup_id, otp, timeout=None):
        """Send the code the payer's provider texted them. The gateway's answer
        to the relay is the proof of payment."""
        return self._request(
            "POST",
            f"/v1/wallet/topups/{quote(str(topup_id), safe='')}/confirm",
            body={"otp": otp},
            relay_token=access_token,
            timeout=timeout,
        )

    def cancel_wallet_topup(self, *, access_token, topup_id, timeout=None):
        """Call off a top-up waiting for its code (the owner backed out)."""
        return self._request(
            "POST",
            f"/v1/wallet/topups/{quote(str(topup_id), safe='')}/cancel",
            body={},
            relay_token=access_token,
            timeout=timeout,
        )

    def allocate_wallet_sms(
        self, *, access_token, amount, idempotency_key, requested_by="", timeout=None
    ):
        """Move money from the main wallet into the SMS balance, which every
        message is paid from. Both sides move in one step on the relay, and a
        retried key returns the first transfer."""
        return self._request(
            "POST",
            "/v1/wallet/sms/allocations",
            body={
                "amount": str(amount),
                "idempotency_key": idempotency_key,
                "requested_by": requested_by,
            },
            relay_token=access_token,
            timeout=timeout,
        )

    def purchase_wallet_plan(
        self, *, access_token, plan, periods, idempotency_key, requested_by="", timeout=None
    ):
        """Pay for ``periods`` periods of a plan (``remote_access`` or ``ai``)
        from the main wallet. The relay charges it and moves the plan's
        paid-through date in one step; a retried key returns the first purchase."""
        return self._request(
            "POST",
            "/v1/wallet/subscriptions",
            body={
                "plan": plan,
                "periods": int(periods),
                "idempotency_key": idempotency_key,
                "requested_by": requested_by,
            },
            relay_token=access_token,
            timeout=timeout,
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
        response_format=None,
        purpose="",
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
        # Structured extraction: constrain the reply to a JSON schema and tell
        # the relay this is a document read, not a conversation (it then picks
        # the extraction model and skips the difficulty router).
        if response_format:
            body["response_format"] = response_format
        if purpose:
            body["purpose"] = purpose
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
            # The relay answered — the transport is fine, only the request was
            # refused. A 5xx from the relay still counts as reachable.
            detail = exc.read().decode("utf-8", errors="replace")
            raise RelayControlError(
                f"relay control returned {exc.code}: {detail}",
                status_code=exc.code,
                body=detail,
            ) from exc
        except error.URLError as exc:
            note_relay_transport_failure()
            raise RelayControlError(f"relay control request failed: {exc.reason}") from exc
        except (TimeoutError, OSError) as exc:
            # ``urlopen`` only wraps failures it sees while opening; a socket
            # timeout during ``response.read()`` (or a TLS/socket OSError)
            # surfaces raw and used to escape the view as a 500. Slow uplinks
            # hit exactly that path.
            note_relay_transport_failure()
            raise RelayControlError(f"relay control request failed: {exc}") from exc
        clear_relay_transport_cooldown()

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


def _wallet_path(path, **params):
    """``path`` with the non-empty ``params`` as its query string."""
    query = "&".join(
        f"{key}={quote(str(value), safe='')}"
        for key, value in params.items()
        if value not in (None, "")
    )
    return f"{path}?{query}" if query else path


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
            "sms_enabled": False,
            "subscription_ends_at": None,
            "remote_access_paid_until": None,
            "ai_paid_until": None,
            "remote_access_until": None,
            "ai_available": False,
            "ai_until": None,
            "sms_available": False,
            "sms_balance": "0.000",
            "sms_price": "0.000",
            "last_synced_at": None,
            "connector_last_seen_at": None,
            "connector_version": "",
        }
    remote_access = plan_coverage(installation, "remote_access")
    ai = plan_coverage(installation, "ai")
    return {
        "configured": True,
        "remote_access_supported": remote_access.active,
        "installation_id": installation.installation_id,
        "shop_name": installation.shop_name,
        "relay_public_api_url": installation.relay_public_api_url,
        "relay_connector_address": installation.relay_connector_address,
        "relay_enabled": installation.relay_enabled,
        "subscription_active": installation.subscription_active,
        "ai_enabled": installation.ai_enabled,
        "sms_enabled": installation.sms_enabled,
        "subscription_ends_at": installation.subscription_ends_at,
        "remote_access_paid_until": installation.remote_access_paid_until,
        "ai_paid_until": installation.ai_paid_until,
        # When each plan stops: null while it is not running, or runs with no
        # end (the operator's subscription includes it).
        "remote_access_until": remote_access.until,
        "ai_available": ai.active,
        "ai_until": ai.until,
        "sms_available": relay_sms_available(installation),
        "sms_balance": f"{installation.sms_balance:.3f}",
        "sms_price": f"{installation.sms_price:.3f}",
        "last_synced_at": installation.last_synced_at,
        "connector_last_seen_at": installation.connector_last_seen_at,
        "connector_version": installation.connector_version,
    }


@dataclass(frozen=True)
class PlanCoverage:
    """How long one plan's service runs for this shop."""

    active: bool = False
    # When it stops; None when it is not running, or runs with no end.
    until: datetime | None = None
    # The operator's subscription includes the plan with no end date.
    indefinite: bool = False


#: Each plan's feature flag on the operator's subscription, and the date the
#: shop has paid it through from its wallet.
_PLAN_FIELDS = {
    "remote_access": ("relay_enabled", "remote_access_paid_until"),
    "ai": ("ai_enabled", "ai_paid_until"),
}


def plan_coverage(installation, plan, *, now=None):
    """Mirror of the relay's ``Installation.PlanCoverage``: a plan runs while the
    operator's subscription includes it (its flag, active, unexpired) or while
    the shop has paid for it from its wallet, whichever runs longer."""
    if installation is None or plan not in _PLAN_FIELDS:
        return PlanCoverage()
    now = now or timezone.now()
    flag_field, paid_field = _PLAN_FIELDS[plan]
    coverage = PlanCoverage()
    if getattr(installation, flag_field) and installation.subscription_active:
        ends_at = installation.subscription_ends_at
        if ends_at is None:
            return PlanCoverage(active=True, indefinite=True)
        if now < ends_at:
            coverage = PlanCoverage(active=True, until=ends_at)
    paid_until = getattr(installation, paid_field)
    if paid_until is not None and now < paid_until and (
        coverage.until is None or paid_until > coverage.until
    ):
        coverage = PlanCoverage(active=True, until=paid_until)
    return coverage


def relay_ai_available(installation=None):
    """Whether relay-hosted AI is currently usable for this shop.

    Mirrors the relay's own gate: the operator's subscription with the AI flag,
    or the period the shop paid for from its wallet — independent of remote
    access. The frontend reads this (via the ``me`` payload) to show or hide the
    AI assistant.
    """
    if installation is None:
        installation = RelayInstallation.load()
    return plan_coverage(installation, "ai").active


def sms_prepaid(installation):
    """Whether the relay sells SMS from the SMS balance (it reported a price —
    of one SMS part). A relay from before the SMS balance reports none and
    still gates on the flag."""
    return installation is not None and installation.sms_price > 0


def sms_affordable(installation, segments):
    """Whether the mirrored SMS balance pays for a message of ``segments`` SMS
    parts. The relay charges per part — an Arabic text past 70 letters goes out
    as several — and holds them all before sending, so a balance that covers a
    short message may not cover a long one. Always true against a relay that
    does not sell by the part."""
    if not sms_prepaid(installation):
        return True
    return installation.sms_balance >= installation.sms_price * max(int(segments or 1), 1)


def relay_sms_available(installation=None):
    """Whether this shop can send SMS right now.

    SMS is prepaid: its SMS balance must pay for at least one more SMS part,
    the relay's check at claim time for the shortest message (a longer one is
    checked against its own parts when it is queued). Against a relay from
    before the SMS balance it is the old entitlement — an active, unexpired
    subscription plus the SMS flag. The relay remains the authority; this
    mirror only keeps a shop that cannot send from queueing messages that would
    all be refused.
    """
    if installation is None:
        installation = RelayInstallation.load()
    if installation is None:
        return False
    if sms_prepaid(installation):
        return installation.sms_balance >= installation.sms_price
    if not installation.sms_enabled or not installation.subscription_active:
        return False
    if (
        installation.subscription_ends_at is not None
        and installation.subscription_ends_at <= timezone.now()
    ):
        return False
    return True


def _relay_decimal(value):
    try:
        return Decimal(str(value))
    except (InvalidOperation, TypeError, ValueError):
        return None


def mirror_sms_wallet(sms, *, installation=None):
    """Copy an SMS balance the relay reported (``{balance, price, ...}``) onto
    the shop's mirror, and make devices re-read ``sms_available`` when it
    flipped. Anything unreadable is ignored: the next sync tries again."""
    if not isinstance(sms, dict):
        return None
    balance = _relay_decimal(sms.get("balance"))
    if balance is None:
        return None
    installation = installation or RelayInstallation.load()
    if installation is None:
        return None
    price = _relay_decimal(sms.get("price"))
    available_before = relay_sms_available(installation)
    fields = []
    if installation.sms_balance != balance:
        installation.sms_balance = balance
        fields.append("sms_balance")
    if price is not None and installation.sms_price != price:
        installation.sms_price = price
        fields.append("sms_price")
    if fields:
        installation.save(update_fields=[*fields, "updated_at"])
        if relay_sms_available(installation) != available_before:
            caching.bump_perm_version()
    return installation


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
        sms_enabled=bool(relay_installation.get("sms_enabled", False)),
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


def scoped_relay_client(installation, *, config=None):
    """Build a relay client authenticated as a specific installation.

    Enrolled on-prem backends keep their scoped access token on the
    RelayInstallation row — the .env only carries the single-use enrollment
    (license) key, which is consumed on first boot. Installation-scoped calls
    (status sync, connector-certificate issuance) must therefore read the
    access token from the row; the process config's access token is empty in
    the enroll model, which would force an admin-token fallback the on-prem
    backend cannot satisfy.
    """
    base = config or relay_config()
    scoped = replace(
        base,
        access_token=installation.access_token or base.access_token,
        installation_id=installation.installation_id or base.installation_id,
    )
    return RelayControlClient(config=scoped)


def push_shop_name_to_relay(installation=None, *, client=None):
    """Best-effort: push the local shop name to the relay when our mirror of it is
    stale (e.g. the merchant renamed the shop).

    The merchant edits the name locally in Shop Settings; the relay only mirrors
    it for the operator's fleet console. ``RelayInstallation.shop_name`` tracks the
    name we last confirmed the relay holds, so a difference from
    ``ShopSettings.shop_name`` means a push is due. Safe to call when offline or
    when no relay is configured — transport/config errors are swallowed and it
    returns ``False`` so the caller can carry on; the periodic sync retries on the
    next reconnect. Returns ``True`` when the relay now has the current name (or
    already did).
    """
    if installation is None:
        installation = RelayInstallation.load()
    if installation is None:
        return False
    desired = ShopSettings.load().shop_name
    if desired == installation.shop_name:
        return True
    try:
        relay_client = client or scoped_relay_client(installation)
        updated = relay_client.update_installation_metadata(
            installation.installation_id,
            shop_name=desired,
        )
    except (ImproperlyConfigured, RelayControlError) as exc:
        logger.warning("relay shop-name push failed (%s); retrying on next sync", exc)
        return False
    installation.shop_name = updated.get("shop_name") or desired
    installation.save(update_fields=["shop_name", "updated_at"])
    return True


def sync_relay_installation(installation, *, client=None, timeout=None, push_shop_name=True):
    """Mirror the relay's entitlement state for ``installation`` down.

    ``timeout`` bounds the status read (defaults to the configured relay
    timeout). ``push_shop_name=False`` skips the best-effort shop-name push —
    opportunistic callers on a budget (device pairing) leave it to the periodic
    sync rather than spend a second round trip on a slow link.
    """
    if installation is None:
        return None
    relay_client = client or scoped_relay_client(installation)
    relay_installation = relay_client.get_installation(
        installation.installation_id, timeout=timeout
    )
    entitlements_before = _entitlement_snapshot(installation)
    switches_before = list(installation.integrations_disabled or [])
    # Entitlements are relay-owned, so mirror them down.
    installation.shop_name = relay_installation.get("shop_name") or installation.shop_name
    installation.relay_enabled = bool(relay_installation.get("relay_enabled", False))
    installation.subscription_active = bool(relay_installation.get("subscription_active", False))
    installation.ai_enabled = bool(relay_installation.get("ai_enabled", False))
    installation.sms_enabled = bool(relay_installation.get("sms_enabled", False))
    installation.subscription_ends_at = parse_relay_datetime(
        relay_installation.get("subscription_ends_at")
    )
    installation.remote_access_paid_until = parse_relay_datetime(
        relay_installation.get("remote_access_paid_until")
    )
    installation.ai_paid_until = parse_relay_datetime(relay_installation.get("ai_paid_until"))
    sms_wallet = relay_installation.get("sms")
    if isinstance(sms_wallet, dict):
        balance = _relay_decimal(sms_wallet.get("balance"))
        price = _relay_decimal(sms_wallet.get("price"))
        if balance is not None and price is not None:
            installation.sms_balance = balance
            installation.sms_price = price
    switched_off = _switched_off_integrations(relay_installation)
    if switched_off is not None:
        installation.integrations_disabled = switched_off
    # The relay's addresses are deployment config, mirrored onto the row when
    # it was enrolled — and then never again. A relay that moved (a new
    # platform environment, a custom domain) left every shop handing phones
    # the old public URL at pairing, so remote access failed everywhere at
    # once while the shop itself, configured with the new address, was fine.
    _mirror_relay_addresses(installation, relay_client.config)
    installation.last_synced_at = timezone.now()
    installation.save(
        update_fields=[
            "shop_name",
            "relay_enabled",
            "subscription_active",
            "ai_enabled",
            "sms_enabled",
            "integrations_disabled",
            "subscription_ends_at",
            "remote_access_paid_until",
            "ai_paid_until",
            "sms_balance",
            "sms_price",
            "relay_public_api_url",
            "relay_connector_address",
            "last_synced_at",
            "updated_at",
        ]
    )
    if _entitlement_snapshot(installation) != entitlements_before:
        # Devices read ai_available / sms_available with the session. Moving the
        # permissions version makes every one of them re-read it now, instead of
        # showing a feature the plan no longer has until someone signs in again.
        caching.bump_perm_version()
    if installation.integrations_disabled != switches_before:
        _apply_integration_switches(switches_before, installation.integrations_disabled)
    # The shop name is backend-owned; the line above mirrored the relay's current
    # copy. If the merchant renamed the shop while offline, our local name now
    # differs from that copy — push it up while we have the connection. Best-effort
    # and reusing the same authenticated client.
    if push_shop_name:
        push_shop_name_to_relay(installation, client=relay_client)
    return installation


def _switched_off_integrations(relay_installation):
    """The provider keys the relay has switched off, or ``None`` for no news.

    The relay leaves the field out when it could not read its switches (and an
    older relay never sends it). That must not read as "every provider is
    back on", so only a list replaces what this shop last heard.
    """
    keys = relay_installation.get("integrations_disabled")
    if not isinstance(keys, list):
        return None
    return sorted({key.strip().lower() for key in keys if isinstance(key, str) and key.strip()})


def _apply_integration_switches(before, after):
    """Act on a switch change now; enforcement never waits on this.

    The mirrored list is already saved, and every path to a provider reads it,
    so a failure here costs only promptness — the next voucher sweep takes
    the cards off anyway.
    """
    from apps.integrations import switches

    try:
        switches.apply_change(before, after)
    except Exception:  # noqa: BLE001 - see the docstring
        logger.exception("could not apply integration switches %s -> %s", before, after)


def _entitlement_snapshot(installation):
    # Whether SMS can be sent, not the balance itself: the balance moves with
    # every message, and only a flip is worth making every device re-read.
    return (
        installation.relay_enabled,
        installation.subscription_active,
        installation.ai_enabled,
        installation.sms_enabled,
        installation.subscription_ends_at,
        installation.remote_access_paid_until,
        installation.ai_paid_until,
        relay_sms_available(installation),
    )


def _mirror_relay_addresses(installation, config):
    """Copy the configured relay addresses onto ``installation`` when set.

    Empty config values are left alone: a backend that sets neither (tests, a
    developer machine) keeps whatever the row was enrolled with.
    """
    public_api_url = str(getattr(config, "public_api_url", "") or "").strip()
    if public_api_url:
        installation.relay_public_api_url = public_api_url
    connector_address = str(getattr(config, "connector_address", "") or "").strip()
    if connector_address:
        installation.relay_connector_address = connector_address


def issue_pairing_ticket(
    installation, *, device_id="", device_name="", client=None, timeout=None
):
    relay_client = client or RelayControlClient()
    issued = relay_client.issue_ticket(
        access_token=installation.access_token,
        device_id=device_id,
        device_name=device_name,
        timeout=timeout,
    )
    installation.last_pairing_issued_at = timezone.now()
    installation.save(update_fields=["last_pairing_issued_at", "updated_at"])
    return issued


def connector_setup_token_accepted(raw_token):
    """Whether ``raw_token`` may bootstrap a connector — WITHOUT spending it.

    Validation is deliberately separated from consumption so a one-time token is
    only burned once the *whole* bootstrap has succeeded (see
    ``consume_connector_setup_token``). Previously the token was consumed up
    front, so a transient failure downstream — the relay being unreachable while
    issuing the connector certificate, say — permanently stranded the connector
    with a token it had already spent, and every retry came back
    ``403 connector setup token rejected`` (issue #4).

    The env seed (``POINTY_RELAY_CONNECTOR_SETUP_TOKEN``) is a durable deployment
    secret that the backend and its own connector share through the same
    ``.env``, so it stays valid for re-bootstrap and recovery — a wiped
    connector-state volume, a reissued installation — even after an earlier
    bootstrap consumed it. Rotating the seed still revokes: a token that no
    longer matches the current seed is accepted only while a live, unconsumed,
    unexpired record exists.
    """
    token = str(raw_token or "").strip()
    if not token:
        return False
    seed_token = _connector_setup_seed_token()
    if constant_time_secret_equal(token, seed_token):
        return True
    token_hash = connector_setup_token_hash(token)
    record = RelayConnectorSetupToken.objects.filter(token_hash=token_hash).first()
    if record is None:
        return False
    if record.consumed_at is not None:
        return False
    if record.expires_at is not None and timezone.now() >= record.expires_at:
        return False
    return True


def consume_connector_setup_token(raw_token):
    """Record a setup token as spent — call only after a *successful* bootstrap.

    Idempotent and best-effort: it marks (creating it if needed) the token's
    record so a non-seed ad-hoc/rotated token can be redeemed only once.
    Consuming the env seed is harmless — ``connector_setup_token_accepted``
    honours the live seed regardless of ``consumed_at`` — but leaves an audit
    trail of when it was used.
    """
    token = str(raw_token or "").strip()
    if not token:
        return
    token_hash = connector_setup_token_hash(token)
    with transaction.atomic():
        record, _ = RelayConnectorSetupToken.objects.select_for_update().get_or_create(
            token_hash=token_hash
        )
        if record.consumed_at is None:
            record.consumed_at = timezone.now()
            record.save(update_fields=["consumed_at", "updated_at"])


def connector_setup_token_hash(raw_token):
    digest = hashlib.sha256(str(raw_token).encode("utf-8")).digest()
    return base64.urlsafe_b64encode(digest).decode("ascii").rstrip("=")


def _connector_setup_seed_token():
    return str(getattr(settings, "POINTY_RELAY_CONNECTOR_SETUP_TOKEN", "")).strip()


def fleet_status(*, client=None, timeout=None):
    """The operator's view of every installation's version.

    Its one caller is the contract-release gate
    (``manage.py check_batch_split_contract``), and it raises rather than
    returning a default on any failure: a gate that answers "probably fine"
    when it could not reach the relay is not a gate.
    """
    client = client or RelayControlClient()
    return client.get_fleet_status(timeout=timeout)
