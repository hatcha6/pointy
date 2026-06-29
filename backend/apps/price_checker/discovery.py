"""Network discovery for price-checker devices.

Plug-and-play, three ways:

1. **Active scan** — probe the local subnet for known device ports and
   fingerprint the make (``scan_for_devices`` / ``run_discovery_scan``).
2. **Passive self-registration** — when an unknown device first talks to us
   (socket daemon), auto-register it (``resolve_device_for_peer``).
3. **Advertise** — answer a UDP probe so a device/config tool can find Pointy
   (``announce_payload``; served by the daemon).

No software can fully auto-configure *every* make — some need their host IP set
once via their own tool. The ``discovery_method`` on each device records how it
arrived so that boundary stays visible instead of pretended away.
"""

from __future__ import annotations

import concurrent.futures
import ipaddress
import re
import socket
import subprocess
from contextlib import suppress

from django.conf import settings
from django.db import transaction

from . import drivers
from .models import PriceCheckerDevice, normalize_device_identifier

PROBE = b"POINTY_PRICE_CHECKER_V1"
SERVICE = "pointy-price-checker"

# Well-known port -> driver key. Used to fingerprint a make during a scan and
# to pick a driver for a device that connects to a given listener port.
PORT_FINGERPRINTS = {
    9101: "scantech_shuttle",
    9100: "generic_tcp",
}


def discovery_enabled() -> bool:
    return bool(getattr(settings, "POINTY_PRICE_CHECKER_DISCOVERY_ENABLED", True))


def driver_for_port(port: int | None) -> str:
    if port is None:
        return "generic_tcp"
    return PORT_FINGERPRINTS.get(int(port), "generic_tcp")


def scan_ports() -> list[int]:
    raw = str(getattr(settings, "POINTY_PRICE_CHECKER_SCAN_PORTS", "9101,9100"))
    ports = [int(p) for p in (part.strip() for part in raw.split(",")) if p.isdigit()]
    return ports or [9101, 9100]


def scan_timeout() -> float:
    return float(getattr(settings, "POINTY_PRICE_CHECKER_SCAN_TIMEOUT", 0.4))


def _local_ip() -> str:
    with suppress(OSError):
        probe = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        try:
            probe.connect(("8.8.8.8", 80))
            return probe.getsockname()[0]
        finally:
            probe.close()
    return "127.0.0.1"


def local_ipv4_network(prefix: int = 24) -> ipaddress.IPv4Network | None:
    with suppress(ValueError):
        return ipaddress.ip_network(f"{_local_ip()}/{prefix}", strict=False)
    return None


def announce_payload(host: str | None = None) -> dict:
    return {
        "service": SERVICE,
        "version": 1,
        "host": host or _local_ip(),
        "tcp_port": int(getattr(settings, "POINTY_PRICE_CHECKER_TCP_PORT", 9101)),
        "udp_port": int(getattr(settings, "POINTY_PRICE_CHECKER_UDP_PORT", 9100)),
    }


# --------------------------------------------------------------------------
# Active scan
# --------------------------------------------------------------------------
def probe_port(ip: str, port: int, timeout: float) -> bool:
    with suppress(OSError):
        with socket.create_connection((ip, port), timeout=timeout):
            return True
    return False


def probe_targets(
    targets: list[tuple[str, int]],
    *,
    timeout: float | None = None,
    max_workers: int = 64,
) -> list[tuple[str, int]]:
    if not targets:
        return []
    timeout = timeout or scan_timeout()
    open_targets: list[tuple[str, int]] = []
    workers = min(max_workers, len(targets))
    with concurrent.futures.ThreadPoolExecutor(max_workers=workers) as pool:
        futures = {
            pool.submit(probe_port, ip, port, timeout): (ip, port)
            for ip, port in targets
        }
        for future in concurrent.futures.as_completed(futures):
            with suppress(Exception):
                if future.result():
                    open_targets.append(futures[future])
    return sorted(open_targets)


_MAC_RE = re.compile(r"(?:[0-9a-f]{2}[:-]){5}[0-9a-f]{2}", re.IGNORECASE)


def arp_lookup(ip: str) -> str:
    """Best-effort MAC for a LAN IP via the system ARP table (may be empty)."""
    with suppress(Exception):
        result = subprocess.run(
            ["arp", "-n", ip],
            capture_output=True,
            text=True,
            timeout=2,
        )
        match = _MAC_RE.search(result.stdout or "")
        if match:
            return match.group(0).replace("-", ":").lower()
    return ""


def scan_for_devices(
    *,
    network: ipaddress.IPv4Network | None = None,
    ports: list[int] | None = None,
    timeout: float | None = None,
) -> list[dict]:
    if not discovery_enabled():
        return []
    network = network or local_ipv4_network()
    if network is None:
        return []
    ports = ports or scan_ports()
    own_ip = _local_ip()
    hosts = [str(host) for host in network.hosts() if str(host) != own_ip]
    targets = [(host, port) for host in hosts for port in ports]
    candidates = []
    for ip, port in probe_targets(targets, timeout=timeout):
        candidates.append(
            {
                "address": ip,
                "port": port,
                "driver": driver_for_port(port),
                "mac": arp_lookup(ip),
            }
        )
    return candidates


# --------------------------------------------------------------------------
# Registration
# --------------------------------------------------------------------------
def _identifier_for(*, mac: str = "", address: str = "", port: int | None = None) -> str:
    base = f"pc-{mac.replace(':', '')}" if mac else f"pc-{address}-{port or ''}"
    return normalize_device_identifier(base) or "pc-device"


def _unique_identifier(base: str) -> str:
    identifier = base
    suffix = 2
    while PriceCheckerDevice.objects.filter(identifier=identifier).exists():
        identifier = f"{base}-{suffix}"
        suffix += 1
    return identifier


def _seed_fields(driver: drivers.Driver) -> dict:
    return dict(driver.default_device_fields())


@transaction.atomic
def register_scanned(candidates: list[dict]) -> list[PriceCheckerDevice]:
    """Create/update DISCOVERED devices from scan candidates (idempotent)."""
    devices = []
    for candidate in candidates:
        address = candidate.get("address")
        port = candidate.get("port")
        mac = candidate.get("mac", "")
        driver = drivers.get_driver(candidate.get("driver") or "") or drivers.get_driver(
            "generic_tcp"
        )

        existing = None
        if mac:
            existing = PriceCheckerDevice.objects.filter(mac_address=mac).first()
        if existing is None and address:
            existing = PriceCheckerDevice.objects.filter(
                address=address, port=port
            ).first()
        if existing is not None:
            existing.mark_seen(address=address)
            devices.append(existing)
            continue

        fields = _seed_fields(driver)
        fields.update(
            {
                "identifier": _unique_identifier(
                    _identifier_for(mac=mac, address=address, port=port)
                ),
                "name": f"{driver.label} {address}".strip(),
                "address": address,
                "port": port or fields.get("port"),
                "mac_address": mac,
                "status": PriceCheckerDevice.Status.DISCOVERED,
                "discovery_method": PriceCheckerDevice.DiscoveryMethod.SCAN,
            }
        )
        devices.append(PriceCheckerDevice.objects.create(**fields))
    return devices


def self_register_device(
    *,
    address: str,
    transport: str,
    driver_key: str | None = None,
) -> PriceCheckerDevice | None:
    """Auto-register a device that contacts us, so it works immediately."""
    if not discovery_enabled():
        return None
    if transport == PriceCheckerDevice.Transport.UDP:
        driver_key = driver_key or "generic_udp"
    driver = drivers.get_driver(driver_key or "") or drivers.get_driver("generic_tcp")

    identifier = normalize_device_identifier(f"pc-{address}-{transport}") or "pc-device"
    fields = _seed_fields(driver)
    fields.update(
        {
            "name": f"{driver.label} {address}".strip(),
            "address": address,
            "transport": transport,
            "status": PriceCheckerDevice.Status.ACTIVE,
            "discovery_method": PriceCheckerDevice.DiscoveryMethod.SELF,
        }
    )
    device, _ = PriceCheckerDevice.objects.get_or_create(
        identifier=identifier,
        defaults=fields,
    )
    return device


def register_http_kiosk(
    *,
    identifier: str,
    name: str = "",
    location: str = "",
    address: str = "",
) -> PriceCheckerDevice:
    """Upsert a self-registering HTTP/web kiosk (our app in price-checker mode).

    Idempotent on ``identifier`` so a kiosk re-announcing on each launch updates
    its descriptive fields and refreshes ``last_seen`` instead of duplicating. An
    admin's explicit *disable* is respected — re-registration never reactivates a
    device, it only touches name/location/address and the last-seen timestamp.
    """
    driver = drivers.get_driver(drivers.DEFAULT_DRIVER_KEY)  # generic_http
    normalized = normalize_device_identifier(identifier) or _unique_identifier(
        _identifier_for(address=address)
    )
    fields = _seed_fields(driver)
    fields.update(
        {
            "name": name or f"{driver.label} {address}".strip(),
            "location": location,
            "address": address or None,
            "transport": PriceCheckerDevice.Transport.HTTP,
            "status": PriceCheckerDevice.Status.ACTIVE,
            "discovery_method": PriceCheckerDevice.DiscoveryMethod.SELF,
        }
    )
    device, created = PriceCheckerDevice.objects.get_or_create(
        identifier=normalized,
        defaults=fields,
    )
    if not created:
        changed = []
        if name and device.name != name:
            device.name = name
            changed.append("name")
        if location and device.location != location:
            device.location = location
            changed.append("location")
        if address and device.address != address:
            device.address = address
            changed.append("address")
        if changed:
            device.save(update_fields=changed)
    device.mark_seen(address=address or None)
    return device


def resolve_device_for_peer(
    peer_ip: str,
    transport: str,
    *,
    default_driver_key: str | None = None,
) -> PriceCheckerDevice | None:
    device = (
        PriceCheckerDevice.objects.filter(address=peer_ip, transport=transport)
        .exclude(status=PriceCheckerDevice.Status.DISABLED)
        .order_by("-last_seen_at")
        .first()
    )
    if device is not None:
        return device
    return self_register_device(
        address=peer_ip,
        transport=transport,
        driver_key=default_driver_key,
    )


def run_discovery_scan(**kwargs) -> dict:
    """Scan + register; returns a summary suitable for an API/CLI response."""
    candidates = scan_for_devices(**kwargs)
    devices = register_scanned(candidates)
    return {
        "found": len(candidates),
        "registered": [device.identifier for device in devices],
        "candidates": candidates,
    }
