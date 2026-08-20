import ipaddress
import json
import socket
import sys
import threading
from contextlib import suppress

from django.conf import settings
from django.db import OperationalError, ProgrammingError

from .models import RelayInstallation, ShopSettings


DISCOVERY_PROBE = b"POINTY_DISCOVERY_V1"
DISCOVERY_SERVICE = "pointy-backend"
RELAYED_REQUEST_META = "HTTP_X_POINTY_RELAYED_REQUEST"

_responder_started = False


def discovery_enabled():
    return bool(getattr(settings, "POINTY_DISCOVERY_ENABLED", True))


def request_is_private_network(request):
    remote_addr = _remote_addr(request)
    if not remote_addr:
        return False
    return address_is_private_network(remote_addr)


def request_is_relayed(request):
    return request.META.get(RELAYED_REQUEST_META) == "1"


def private_network_host_for_peer(raw_address):
    if not address_is_private_network(raw_address):
        return _local_host()
    with suppress(OSError):
        probe = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        try:
            probe.connect((raw_address, 9))
            return probe.getsockname()[0]
        finally:
            probe.close()
    return _local_host()


def address_is_private_network(raw_address):
    try:
        address = ipaddress.ip_address(raw_address)
    except ValueError:
        return False
    return address.is_private or address.is_loopback or address.is_link_local


def request_is_lan_local(request):
    """True only for a peer that reached us over this shop's own network.

    ``request_is_private_network`` alone is **not** that test. The relay
    connector dials the backend from the LAN, so a request tunnelled in from
    the internet also arrives with a private ``REMOTE_ADDR`` — every relayed
    request looks LAN-local to it. Anything that treats "on the LAN" as an
    authorisation decision must go through here, not through
    ``request_is_private_network``.
    """
    if request_is_relayed(request):
        return False
    return request_is_private_network(request)


def request_discovery_allowed(request):
    if not discovery_enabled():
        return False
    if request_is_relayed(request):
        return False
    if not bool(getattr(settings, "POINTY_DISCOVERY_PRIVATE_ONLY", True)):
        return True
    return request_is_lan_local(request)


def backend_discovery_payload(request=None, host=None):
    installation = _load_relay_installation()
    shop_name = _shop_name()
    api_base_url = _api_base_url(request=request, host=host)
    return {
        "service": DISCOVERY_SERVICE,
        "version": 1,
        "shop_name": shop_name,
        "backend_url": _backend_url(request=request, host=host),
        "api_base_url": api_base_url,
        "api_path": "/api",
        "pairing_path": "/api/relay/pairing/",
        "installation_id": installation.installation_id if installation else "",
        "remote_access_supported": (
            installation.remote_access_supported if installation else False
        ),
        "relay_public_api_url": installation.relay_public_api_url if installation else "",
        "connector_last_seen_at": (
            installation.connector_last_seen_at.isoformat()
            if installation and installation.connector_last_seen_at
            else None
        ),
    }


def start_discovery_responder():
    global _responder_started
    if _responder_started:
        return
    if not discovery_enabled():
        return
    if not bool(getattr(settings, "POINTY_DISCOVERY_UDP_ENABLED", True)):
        return
    if _running_management_command_without_server():
        return

    _responder_started = True
    thread = threading.Thread(
        target=_serve_discovery_udp,
        name="pointy-discovery",
        daemon=True,
    )
    thread.start()


def _serve_discovery_udp():
    port = int(getattr(settings, "POINTY_DISCOVERY_UDP_PORT", 47777))
    with suppress(OSError):
        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        try:
            sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            sock.bind(("", port))
            while True:
                data, address = sock.recvfrom(512)
                if data.strip() != DISCOVERY_PROBE:
                    continue
                payload = backend_discovery_payload(
                    host=private_network_host_for_peer(address[0])
                )
                sock.sendto(json.dumps(payload).encode("utf-8"), address)
        finally:
            sock.close()


def _running_management_command_without_server():
    commands = {"check", "makemigrations", "migrate", "test"}
    return any(command in sys.argv for command in commands)


def _api_base_url(request=None, host=None):
    return f"{_backend_url(request=request, host=host)}/api"


def _backend_url(request=None, host=None):
    if request is not None:
        return request.build_absolute_uri("/").rstrip("/")

    public_url = str(getattr(settings, "POINTY_DISCOVERY_API_BASE_URL", "")).strip()
    if public_url:
        return public_url.rstrip("/").removesuffix("/api").rstrip("/")

    port = int(getattr(settings, "POINTY_DISCOVERY_API_PORT", 8000))
    if host is None:
        host = _local_host()
    return f"http://{host}:{port}"


def _local_host():
    with suppress(OSError):
        probe = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        try:
            probe.connect(("8.8.8.8", 80))
            return probe.getsockname()[0]
        finally:
            probe.close()
    return "127.0.0.1"


def _remote_addr(request):
    forwarded_for = request.META.get("HTTP_X_FORWARDED_FOR", "")
    trust_proxy_headers = bool(
        getattr(settings, "POINTY_DISCOVERY_TRUST_PROXY_HEADERS", False)
    )
    if trust_proxy_headers and forwarded_for:
        return forwarded_for.split(",", 1)[0].strip()
    return request.META.get("REMOTE_ADDR", "")


def _load_relay_installation():
    try:
        return RelayInstallation.load()
    except (OperationalError, ProgrammingError):
        return None


def _shop_name():
    try:
        return ShopSettings.load().shop_name
    except (OperationalError, ProgrammingError):
        return ""
