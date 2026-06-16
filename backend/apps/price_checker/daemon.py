"""Always-on socket server for TCP/UDP price-checker hardware.

HTTP/web-kiosk devices are served by the normal REST endpoint; this daemon is
only for the byte-oriented families (e.g. the Scantech Shuttle). It mirrors the
threading + guard pattern of :mod:`apps.core.discovery`: a daemon thread runs a
private asyncio loop. Production runs it once via ``manage.py
price_checker_serve``; ``autostart`` is opt-in so it never binds ports in every
web worker.

Django's ORM is synchronous, so all DB work happens in a worker thread via
``asyncio.to_thread`` and connections are reaped after each scan.
"""

from __future__ import annotations

import asyncio
import json
import logging
import sys
import threading
from contextlib import suppress

from django.conf import settings
from django.db import close_old_connections

from apps.core.discovery import address_is_private_network, private_network_host_for_peer

from . import discovery, service
from .models import PriceCheckerDevice

logger = logging.getLogger(__name__)

_started = False
TCP = PriceCheckerDevice.Transport.TCP
UDP = PriceCheckerDevice.Transport.UDP
_TCP_IDLE_TIMEOUT = 300  # close persistent connections after 5 min idle


def _tcp_port() -> int:
    return int(getattr(settings, "POINTY_PRICE_CHECKER_TCP_PORT", 9101))


def _udp_port() -> int:
    return int(getattr(settings, "POINTY_PRICE_CHECKER_UDP_PORT", 9100))


def _tcp_enabled() -> bool:
    return bool(getattr(settings, "POINTY_PRICE_CHECKER_TCP_ENABLED", True))


def _udp_enabled() -> bool:
    return bool(getattr(settings, "POINTY_PRICE_CHECKER_UDP_ENABLED", True))


def _process(raw: bytes, **kwargs) -> bytes:
    """Run the sync scan handler with clean DB connections (worker thread)."""
    close_old_connections()
    try:
        return service.process_socket_scan(raw, **kwargs)
    finally:
        close_old_connections()


# --------------------------------------------------------------------------
# TCP
# --------------------------------------------------------------------------
async def _handle_tcp(reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
    peer = writer.get_extra_info("peername") or ("", 0)
    sock = writer.get_extra_info("sockname") or ("", None)
    peer_ip, local_port = peer[0], (sock[1] if len(sock) > 1 else None)

    if not address_is_private_network(peer_ip):
        writer.close()
        return
    try:
        while True:
            try:
                data = await asyncio.wait_for(reader.read(512), timeout=_TCP_IDLE_TIMEOUT)
            except asyncio.TimeoutError:
                break
            if not data:
                break  # EOF
            reply = await asyncio.to_thread(
                _process,
                data,
                peer_ip=peer_ip,
                transport=TCP,
                local_port=local_port,
            )
            writer.write(reply)
            await writer.drain()
    except (ConnectionError, asyncio.IncompleteReadError):
        pass
    finally:
        with suppress(Exception):
            writer.close()


# --------------------------------------------------------------------------
# UDP
# --------------------------------------------------------------------------
class _UdpProtocol(asyncio.DatagramProtocol):
    def __init__(self, local_port: int) -> None:
        self.local_port = local_port
        self.transport: asyncio.DatagramTransport | None = None

    def connection_made(self, transport: asyncio.BaseTransport) -> None:
        self.transport = transport  # type: ignore[assignment]

    def datagram_received(self, data: bytes, addr) -> None:
        peer_ip = addr[0]
        if not address_is_private_network(peer_ip):
            return
        if data.strip() == discovery.PROBE:
            payload = discovery.announce_payload(
                host=private_network_host_for_peer(peer_ip)
            )
            self.transport.sendto(json.dumps(payload).encode("utf-8"), addr)
            return
        asyncio.ensure_future(self._respond(data, addr))

    async def _respond(self, data: bytes, addr) -> None:
        reply = await asyncio.to_thread(
            _process,
            data,
            peer_ip=addr[0],
            transport=UDP,
            local_port=self.local_port,
        )
        if self.transport is not None:
            self.transport.sendto(reply, addr)


# --------------------------------------------------------------------------
# Lifecycle
# --------------------------------------------------------------------------
async def _serve() -> None:
    loop = asyncio.get_running_loop()
    servers = []

    if _tcp_enabled():
        with suppress(OSError):
            tcp_server = await asyncio.start_server(_handle_tcp, host="", port=_tcp_port())
            servers.append(tcp_server)
            logger.info("price-checker TCP daemon listening on :%s", _tcp_port())

    udp_transport = None
    if _udp_enabled():
        with suppress(OSError):
            udp_transport, _ = await loop.create_datagram_endpoint(
                lambda: _UdpProtocol(_udp_port()),
                local_addr=("", _udp_port()),
            )
            logger.info("price-checker UDP daemon listening on :%s", _udp_port())

    if not servers and udp_transport is None:
        logger.warning("price-checker daemon: no transports bound; exiting")
        return

    try:
        await asyncio.Event().wait()  # run until cancelled
    finally:
        for server in servers:
            server.close()
        if udp_transport is not None:
            udp_transport.close()


def serve() -> None:
    """Run the daemon in the foreground (used by the management command)."""
    with suppress(KeyboardInterrupt):
        asyncio.run(_serve())


def _is_management_command_without_server() -> bool:
    blocking = {"check", "makemigrations", "migrate", "test", "collectstatic", "shell"}
    return any(command in sys.argv for command in blocking)


def start_price_checker_daemon() -> bool:
    """Start the daemon in a background thread (idempotent)."""
    global _started
    if _started:
        return False
    if not (_tcp_enabled() or _udp_enabled()):
        return False
    _started = True
    thread = threading.Thread(target=serve, name="pointy-price-checker", daemon=True)
    thread.start()
    return True


def autostart_price_checker_daemon() -> bool:
    """Called from AppConfig.ready(); opt-in via POINTY_PRICE_CHECKER_AUTOSTART."""
    if not bool(getattr(settings, "POINTY_PRICE_CHECKER_AUTOSTART", False)):
        return False
    if _is_management_command_without_server():
        return False
    return start_price_checker_daemon()
