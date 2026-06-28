"""Find SQL Server instances reachable on the local network.

This uses the standard **SQL Server Resolution Protocol** (SSRP) — the same
UDP/1434 broadcast that ``SSMS`` "Browse for servers" and ``sqlcmd -L`` use. The
SQL Server Browser service answers with the instance name, version, and TCP
port. It is a *discovery* probe only:

- It never sends credentials and never opens a data connection — it just answers
  "which SQL Server instances are reachable here?".
- The migration operator picks the one that is the client's POS box; only then
  does the transport connect (and only then may the vendor-default credential
  fallback in ``transports/mssql.py`` run, against that chosen target).

That ordering — discover, then a human confirms the target, then authenticate —
is what keeps this a migration aid and not a network credential sweep. We never
auto-authenticate against every host we happen to find.
"""

from __future__ import annotations

import socket
from dataclasses import asdict, dataclass

# SSRP request byte that asks every listening SQL Server Browser to dump all of
# its instances (CLNT_BCAST_EX). Responses come back on the same UDP socket.
_SSRP_CLNT_BCAST_EX = b"\x02"
_BROWSER_PORT = 1434
_DISCOVERY_TIMEOUT_SECONDS = 3.0
_MAX_RESPONSE_BYTES = 65535


@dataclass(frozen=True)
class DiscoveredInstance:
    address: str  # IP the response came from
    server_name: str
    instance_name: str
    version: str
    tcp_port: int | None

    @property
    def host(self) -> str:
        """The value to put in a source's ``host`` field."""
        return self.address


def _parse_ssrp_payload(address: str, raw: bytes) -> list[DiscoveredInstance]:
    """Parse one Browser response into its (possibly several) instances.

    Wire format: ``0x05``, 2-byte little-endian length, then a ``;``-delimited
    ``key;value`` string. Instances are separated by ``;;``. We read the fields
    we care about and ignore the rest defensively — old/odd Browsers vary.
    """
    if not raw or raw[0] != 0x05:
        return []
    body = raw[3:].decode("latin-1", errors="replace")
    instances: list[DiscoveredInstance] = []
    for block in body.split(";;"):
        tokens = block.split(";")
        fields: dict[str, str] = {}
        # Walk key;value pairs.
        for i in range(0, len(tokens) - 1, 2):
            key = tokens[i].strip().lower()
            value = tokens[i + 1].strip()
            if key and key not in fields:
                fields[key] = value
        if "servername" not in fields and "instancename" not in fields:
            continue
        port_raw = fields.get("tcp")
        try:
            tcp_port = int(port_raw) if port_raw else None
        except ValueError:
            tcp_port = None
        instances.append(
            DiscoveredInstance(
                address=address,
                server_name=fields.get("servername", ""),
                instance_name=fields.get("instancename", ""),
                version=fields.get("version", ""),
                tcp_port=tcp_port,
            )
        )
    return instances


def discover_sql_servers(
    *, timeout: float = _DISCOVERY_TIMEOUT_SECONDS
) -> list[DiscoveredInstance]:
    """Broadcast an SSRP request and collect every Browser that answers.

    Returns a de-duplicated list of reachable instances. Never raises on network
    trouble — a closed/blocked UDP path just yields an empty list (the operator
    can still type the host manually).
    """
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
    sock.settimeout(timeout)
    seen: dict[tuple[str, str, str], DiscoveredInstance] = {}
    try:
        # Limited broadcast — reaches every Browser on the local segment.
        sock.sendto(_SSRP_CLNT_BCAST_EX, ("255.255.255.255", _BROWSER_PORT))
        while True:
            try:
                raw, (addr, _port) = sock.recvfrom(_MAX_RESPONSE_BYTES)
            except socket.timeout:
                break
            except OSError:
                break
            for inst in _parse_ssrp_payload(addr, raw):
                key = (inst.address, inst.server_name, inst.instance_name)
                seen.setdefault(key, inst)
    finally:
        sock.close()
    return sorted(seen.values(), key=lambda i: (i.address, i.instance_name))


def discover_sql_servers_as_dicts(*, timeout: float | None = None) -> list[dict]:
    """JSON-serialisable view of :func:`discover_sql_servers` for the API."""
    kwargs = {} if timeout is None else {"timeout": timeout}
    return [asdict(inst) for inst in discover_sql_servers(**kwargs)]
