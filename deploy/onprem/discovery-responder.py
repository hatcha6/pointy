#!/usr/bin/env python3
"""Host-side LAN discovery responder for Dockerized Pointy backends.

POS clients find their backend by broadcasting ``POINTY_DISCOVERY_V1`` on UDP
port 47777. The backend has a built-in responder, but UDP *broadcasts* never
reach a container through Docker's published ports (docker-proxy forwards
unicast only) — so on Docker deployments this small responder runs on the HOST
instead, registered by register-autostart.sh. The reply only needs to point the
client at the API base URL: the client then calls ``GET /api/discovery/service/``
on it, which serves the full authoritative payload from the backend itself.

WINDOWS: this responder is registered but is never reached. The stack runs
inside a WSL2 distro, and broadcast frames do not cross the VM's NAT — a second
boundary this cannot forward across. That is not a fault to fix here: the
clients race three discovery paths (the stored IP, UDP, and an HTTP /24 subnet
sweep) and the sweep finds the backend at the Windows host's LAN address, which
wsl/bootstrap-wsl.ps1 forwards into the VM. Leaving the unit registered means it
starts working by itself if a host is ever switched to WSL mirrored networking.

Configuration (environment, all optional):
  POINTY_DISCOVERY_UDP_PORT      listen port           (default 47777)
  POINTY_DISCOVERY_API_PORT      advertised API port   (default 8000)
  POINTY_DISCOVERY_API_BASE_URL  full URL override, e.g. behind a proxy
"""

from __future__ import annotations

import ipaddress
import json
import os
import socket
import sys
import time

PROBE = b"POINTY_DISCOVERY_V1"


def log(message: str) -> None:
    print(f"[pointy-discovery] {message}", flush=True)


def peer_is_private(raw_address: str) -> bool:
    try:
        address = ipaddress.ip_address(raw_address)
    except ValueError:
        return False
    return address.is_private or address.is_loopback or address.is_link_local


def local_host_for_peer(peer: str) -> str:
    """The IP of the host interface that faces this peer (multi-NIC safe)."""
    try:
        probe = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        try:
            probe.connect((peer, 9))
            return probe.getsockname()[0]
        finally:
            probe.close()
    except OSError:
        return "127.0.0.1"


def payload_for_peer(peer: str) -> bytes:
    override = os.environ.get("POINTY_DISCOVERY_API_BASE_URL", "").strip()
    if override:
        backend_url = override.rstrip("/").removesuffix("/api").rstrip("/")
    else:
        port = int(os.environ.get("POINTY_DISCOVERY_API_PORT", "8000"))
        backend_url = f"http://{local_host_for_peer(peer)}:{port}"
    # Minimal shape of apps.core.discovery.backend_discovery_payload: the client
    # only reads service + api_base_url from UDP, then fetches the full payload
    # from the backend over HTTP.
    return json.dumps(
        {
            "service": "pointy-backend",
            "version": 1,
            "shop_name": "",
            "backend_url": backend_url,
            "api_base_url": f"{backend_url}/api",
            "api_path": "/api",
            "pairing_path": "/api/relay/pairing/",
            "installation_id": "",
            "remote_access_supported": False,
            "relay_public_api_url": "",
            "connector_last_seen_at": None,
        }
    ).encode("utf-8")


def serve() -> None:
    port = int(os.environ.get("POINTY_DISCOVERY_UDP_PORT", "47777"))
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.bind(("", port))
    log(f"listening on udp/{port}")
    while True:
        try:
            data, address = sock.recvfrom(512)
        except OSError as exc:
            log(f"receive failed ({exc}); retrying")
            time.sleep(1)
            continue
        if data.strip() != PROBE:
            continue
        if not peer_is_private(address[0]):
            continue
        try:
            sock.sendto(payload_for_peer(address[0]), address)
        except OSError as exc:
            log(f"reply to {address[0]} failed: {exc}")


def main() -> int:
    while True:
        try:
            serve()
        except OSError as exc:
            # Port busy (another responder?) or interface flap: keep trying, the
            # service supervisor treats this process as run-forever.
            log(f"socket error: {exc}; retrying in 10s")
            time.sleep(10)
        except KeyboardInterrupt:
            return 0


if __name__ == "__main__":
    sys.exit(main())
