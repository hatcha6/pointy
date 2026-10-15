"""HTTPS transport for relay calls that survives a flaky DNS lookup.

A shop's backend resolves the relay's host name on every call, through
Docker's embedded resolver and whatever upstream the shop PC hands it. At
لمسة (Oct 2026) roughly nine lookups in ten failed in ~20 ms with
``EAI_AGAIN`` while the relay itself was up and reachable, so voucher and
recharge sales were refunded before they ever left the shop.

Every connection that completes a TLS handshake for the relay's host name
records the peer address. When a later lookup fails, the call connects to
those remembered addresses instead. The certificate is still verified against
the host name (SNI and hostname check use ``self.host``), so a remembered
address can only ever reach the real relay: a stale one fails the handshake
or the connect exactly as a dead host would. A remembered address is a hint,
never a substitute for a working lookup — DNS is always tried first.
"""

import http.client
import logging
import socket
import time
from urllib import request
from urllib.parse import urlparse

from django.conf import settings
from django.utils import timezone

from . import caching

logger = logging.getLogger(__name__)

# Long enough to ride out a shop whose DNS stays broken for weeks; every
# successful handshake refreshes it.
LAST_GOOD_ADDRESSES_TTL_SECONDS = 30 * 24 * 60 * 60
# The hosted relay sits behind a shared load balancer with a couple of
# addresses; keep a few in case one of them is the one that went away.
MAX_REMEMBERED_ADDRESSES = 4
_FALLBACK_STATS_KEY = "pointy:relay:dns-fallback"


def _addresses_key(host):
    return f"pointy:relay:last-good-addresses:{host.lower()}"


def last_good_addresses(host):
    """Addresses that completed a TLS handshake for ``host``, newest first."""
    addresses = caching._safe_get(_addresses_key(host), None)
    if not isinstance(addresses, list):
        return []
    return [address for address in addresses if isinstance(address, str) and address]


def remember_address(host, address):
    if not host or not address:
        return
    addresses = [address] + [
        known for known in last_good_addresses(host) if known != address
    ]
    caching._safe_set(
        _addresses_key(host),
        addresses[:MAX_REMEMBERED_ADDRESSES],
        LAST_GOOD_ADDRESSES_TTL_SECONDS,
    )


def _note_fallback(host, address):
    stats = caching._safe_get(_FALLBACK_STATS_KEY, None)
    count = stats.get("count", 0) if isinstance(stats, dict) else 0
    caching._safe_set(
        _FALLBACK_STATS_KEY,
        {
            "count": count + 1,
            "last_used_at": timezone.now().isoformat(),
            "host": host,
            "address": address,
        },
        LAST_GOOD_ADDRESSES_TTL_SECONDS,
    )


def fallback_stats():
    stats = caching._safe_get(_FALLBACK_STATS_KEY, None)
    return stats if isinstance(stats, dict) else {"count": 0, "last_used_at": None}


def create_connection_with_fallback(address, timeout=None, source_address=None):
    """``socket.create_connection`` that falls back to the last good addresses
    when the host name does not resolve."""
    host, port = address
    try:
        return socket.create_connection(address, timeout, source_address)
    except socket.gaierror as lookup_error:
        remembered = last_good_addresses(host)
        if not remembered:
            raise
        last_error = lookup_error
        for remembered_address in remembered:
            try:
                connection = socket.create_connection(
                    (remembered_address, port), timeout, source_address
                )
            except OSError as exc:
                last_error = exc
                continue
            logger.warning(
                "relay host %s did not resolve (%s); connected to last good address %s",
                host,
                lookup_error,
                remembered_address,
            )
            _note_fallback(host, remembered_address)
            return connection
        raise last_error from lookup_error


class RelayHTTPSConnection(http.client.HTTPSConnection):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self._create_connection = create_connection_with_fallback

    def connect(self):
        super().connect()
        # Through a proxy the peer is the proxy, not the relay.
        if self._tunnel_host:
            return
        try:
            peer = self.sock.getpeername()[0]
        except (OSError, IndexError, TypeError):
            return
        # Only reached once the handshake verified the certificate for
        # ``self.host``, so this address is known to serve the real relay.
        remember_address(self.host, peer)


class RelayHTTPSHandler(request.HTTPSHandler):
    def https_open(self, req):
        return self.do_open(RelayHTTPSConnection, req, context=self._context)


def relay_urlopen(http_request, timeout=None, context=None):
    """Drop-in for ``urllib.request.urlopen`` on relay calls."""
    opener = request.build_opener(RelayHTTPSHandler(context=context))
    if timeout is None:
        return opener.open(http_request)
    return opener.open(http_request, timeout=timeout)


def _resolv_conf(path="/etc/resolv.conf"):
    try:
        with open(path, encoding="utf-8", errors="replace") as handle:
            lines = handle.read().splitlines()
    except OSError as exc:
        return {"error": str(exc)}
    kept = [
        line.strip()
        for line in lines
        if line.strip().split(" ", 1)[0] in {"nameserver", "search", "domain", "options"}
    ]
    return {"lines": kept}


def _probe_lookup(host):
    started = time.monotonic()
    try:
        infos = socket.getaddrinfo(host, 443, type=socket.SOCK_STREAM)
    except OSError as exc:
        return {
            "ok": False,
            "error": f"{type(exc).__name__}: {exc}",
            "duration_ms": round((time.monotonic() - started) * 1000),
        }
    return {
        "ok": True,
        "addresses": sorted({info[4][0] for info in infos}),
        "duration_ms": round((time.monotonic() - started) * 1000),
    }


def resolver_snapshot(probes=3, resolv_conf_path="/etc/resolv.conf"):
    """How this container resolves the relay right now, for support exports."""
    control_url = str(getattr(settings, "POINTY_RELAY_CONTROL_URL", "") or "")
    host = urlparse(control_url).hostname or ""
    snapshot = {
        "generated_at": timezone.now().isoformat(),
        "relay_host": host,
        "resolv_conf": _resolv_conf(resolv_conf_path),
        "last_good_addresses": last_good_addresses(host) if host else [],
        "fallback": fallback_stats(),
        "lookups": [],
    }
    if host:
        snapshot["lookups"] = [_probe_lookup(host) for _ in range(max(probes, 0))]
    return snapshot
