"""mitmproxy addon: a live, readable log of what the Qareeb app talks to.

Loaded with ``-s capture.py``. It does three jobs while a capture runs:

* prints one compact line per response so you can watch the app work and see,
  in real time, which host and path each screen hits;
* counts every host seen and prints the tally at exit — the first capture's
  real purpose is to DISCOVER Qareeb's API domain, since we do not know it yet;
* shouts when a TLS handshake fails, because for a Flutter app that is the tell
  for certificate pinning — the connection appears but never decrypts, and the
  app shows a network error. If you see those, the plain WireGuard + trusted-CA
  route cannot read the bodies and we are into the pinning fallback.

Set ``QAREEB_HOST`` in the environment to a substring (e.g. ``qareeb``) to mark
matching hosts with ``*`` in the live log. It only changes the display; every
flow is still recorded to the ``-w`` file for analyze_flows.py to read later.

The addon never writes anything itself and never blocks a request — it only
observes. The recording is done by mitmproxy's own ``-w`` stream.
"""

from __future__ import annotations

import collections
import logging
import os

log = logging.getLogger("qareeb")

_HIGHLIGHT = os.environ.get("QAREEB_HOST", "").strip().lower()


class QareebCapture:
    def __init__(self) -> None:
        self.hosts: collections.Counter[str] = collections.Counter()
        self.tls_failures: collections.Counter[str] = collections.Counter()

    def running(self) -> None:
        log.info("qareeb-capture live. Drive the app; every response prints below.")
        if _HIGHLIGHT:
            log.info("Highlighting hosts containing %r with '*'.", _HIGHLIGHT)
        else:
            log.info("No QAREEB_HOST set — logging every host, so watch for the API domain.")

    def response(self, flow) -> None:  # mitmproxy.http.HTTPFlow
        req = flow.request
        host = req.pretty_host
        self.hosts[host] += 1
        code = flow.response.status_code if flow.response else "---"
        mark = "*" if _HIGHLIGHT and _HIGHLIGHT in host.lower() else " "
        # Path only (no query): query strings routinely carry tokens/OTPs and
        # this line is for orientation, not evidence.
        path = req.path.split("?", 1)[0]
        log.info("%s %3s %-6s %s%s", mark, code, req.method, host, path)

    def error(self, flow) -> None:
        # Connect/transport errors never produce a response; surface them so a
        # blocked or pinned endpoint is not silently absent from the picture.
        req = getattr(flow, "request", None)
        if req is not None:
            log.warning("  ERR      %-6s %s%s  (%s)", req.method, req.pretty_host,
                        req.path.split("?", 1)[0], flow.error)

    def tls_failed_client(self, data) -> None:
        # Pinning tell. Hook signature is stable in mitmproxy 9–12; guard the
        # attribute walk so a version bump degrades to "unknown" not a crash.
        sni = "unknown"
        try:
            sni = data.context.client.sni or getattr(data.conn, "sni", None) or "unknown"
        except Exception:  # noqa: BLE001 - best-effort diagnostics only
            pass
        self.tls_failures[sni] += 1
        log.warning("TLS handshake FAILED for %s — likely certificate pinning.", sni)

    def done(self) -> None:
        if self.hosts:
            log.info("=== hosts seen (by request count) ===")
            for host, n in self.hosts.most_common():
                log.info("  %5d  %s", n, host)
        if self.tls_failures:
            log.warning("=== TLS handshakes that FAILED (pinning suspects) ===")
            for sni, n in self.tls_failures.most_common():
                log.warning("  %5d  %s", n, sni)
            log.warning("If Qareeb's own host is in that list, the app pins. "
                        "Plain WireGuard + trusted CA will not decrypt it.")


addons = [QareebCapture()]
