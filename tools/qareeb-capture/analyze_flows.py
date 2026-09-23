#!/usr/bin/env python3
"""Turn one or more mitmproxy ``.flows`` files into a REDACTED API contract.

This is the twin of ``tools/dump-analysis/analyze.py``: a capture goes in, a
Markdown report describing the endpoints comes out — grouped by method and path
template, with request/response *shapes* rather than values. Secrets (OTP,
tokens, cookies, the phone number that logged in) are masked by default, so the
report is the artefact you can actually keep and paste into a driver design,
while the raw ``.flows`` stays local and gitignored.

Usage::

    python3 analyze_flows.py captures/qareeb-session-*.flows
    python3 analyze_flows.py captures/qareeb-auth-*.flows --host qareeb --out contract-auth.md

Flags:
    --host SUBSTR   keep only flows whose host contains SUBSTR (case-insensitive).
                    Omit on the first run to see every host, then filter.
    --out FILE      write the report here (default: stdout).
    --show-values   DO NOT redact. Off by default. Only ever use this on a
                    logged-OUT capture you have checked contains no secrets;
                    an auth capture with values shown is a plaintext OTP+token.

Reads mitmproxy's own on-disk format via ``mitmproxy.io.FlowReader``, so
mitmproxy must be importable (it is, once ``brew install mitmproxy`` has run —
its bundled interpreter is on PATH, or run this under that same environment).
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from collections import OrderedDict
from urllib.parse import parse_qsl

try:
    from mitmproxy import http
    from mitmproxy.io import FlowReader
except ImportError:  # pragma: no cover - environment guard
    sys.exit(
        "mitmproxy is not importable. Install it first (make qareeb-capture-setup "
        "or `brew install mitmproxy`), then run this with the same interpreter."
    )

# Header values that are pure secret — masked whole, never shown.
SECRET_HEADERS = {
    "authorization", "proxy-authorization", "cookie", "set-cookie",
    "x-api-key", "x-auth-token", "x-access-token", "x-session-token",
    "x-csrf-token", "x-xsrf-token",
}
# Body/query keys whose VALUE is sensitive. The key name is kept (it is part of
# the contract); the value is replaced with its type.
SECRET_KEY = re.compile(
    r"otp|pass(word)?|token|secret|\bpin\b|auth|session|jwt|bearer|"
    r"phone|mobile|msisdn|email|national|\bnid\b|card|cvv|serial|signature|device_?id",
    re.IGNORECASE,
)

_MASK = "«redacted»"


def norm_segment(seg: str) -> str:
    """Collapse an identifier-looking path segment to ``:id`` so ``/user/42``
    and ``/user/43`` are one endpoint."""
    if not seg:
        return seg
    if seg.isdigit():
        return ":id"
    if re.fullmatch(r"[0-9a-fA-F]{8,}", seg):  # hex id / hash
        return ":id"
    if re.fullmatch(r"[0-9a-fA-F-]{16,}", seg):  # uuid-ish
        return ":id"
    if re.search(r"\d", seg) and re.search(r"[A-Za-z]", seg) and len(seg) >= 12:
        return ":id"
    return seg


def norm_path(path: str) -> str:
    base = path.split("?", 1)[0]
    parts = base.split("/")
    return "/".join(norm_segment(p) for p in parts) or "/"


def shape(value, redact: bool, depth: int = 0, key: str | None = None):
    """Describe a parsed JSON value as its structure, masking secret leaves."""
    if depth > 6:
        return "…"
    if isinstance(value, dict):
        out = OrderedDict()
        for k, v in value.items():
            out[k] = shape(v, redact, depth + 1, key=k)
        return out
    if isinstance(value, list):
        if not value:
            return []
        return [shape(value[0], redact, depth + 1, key=key), f"…×{len(value)}"] if len(value) > 1 \
            else [shape(value[0], redact, depth + 1, key=key)]
    # scalar leaf
    if redact and key is not None and SECRET_KEY.search(key):
        return f"<{type(value).__name__}:{_MASK}>"
    if isinstance(value, str):
        if redact and len(value) > 40:
            return f"<str len={len(value)}>"
        return value if not redact else (value if value.isascii() and len(value) <= 40 else f"<str len={len(value)}>")
    return value


def parse_body(raw: bytes, content_type: str, redact: bool):
    ct = (content_type or "").lower()
    if not raw:
        return None
    text = raw.decode("utf-8", "replace")
    if "json" in ct or text[:1] in "{[":
        try:
            return shape(json.loads(text), redact)
        except ValueError:
            pass
    if "x-www-form-urlencoded" in ct:
        pairs = parse_qsl(text, keep_blank_values=True)
        d = OrderedDict()
        for k, v in pairs:
            d[k] = f"<{_MASK}>" if (redact and SECRET_KEY.search(k)) else (v if not redact else "<str>")
        return d
    if len(text) > 200:
        return f"<{ct or 'body'} len={len(raw)}>"
    return text if not redact else f"<{ct or 'text'} len={len(raw)}>"


def headers_summary(headers, redact: bool):
    out = OrderedDict()
    for k, v in headers.items():
        out[k] = _MASK if (redact and k.lower() in SECRET_HEADERS) else v
    return out


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("flows", nargs="+", help="one or more .flows files")
    ap.add_argument("--host", default="", help="keep only flows whose host contains this substring")
    ap.add_argument("--out", default="", help="write report here (default stdout)")
    ap.add_argument("--show-values", action="store_true",
                    help="DO NOT redact (only on a checked, logged-out capture)")
    args = ap.parse_args()
    redact = not args.show_values
    host_filter = args.host.lower()

    endpoints: "OrderedDict[tuple, dict]" = OrderedDict()
    hosts: set[str] = set()
    total = 0

    for path in args.flows:
        with open(path, "rb") as fh:
            for flow in FlowReader(fh).stream():
                if not isinstance(flow, http.HTTPFlow) or flow.request is None:
                    continue
                host = flow.request.pretty_host
                hosts.add(host)
                if host_filter and host_filter not in host.lower():
                    continue
                total += 1
                key = (flow.request.method, host, norm_path(flow.request.path))
                ep = endpoints.setdefault(key, {"count": 0, "req": None, "resp": None, "status": set(), "raw_paths": set()})
                ep["count"] += 1
                ep["raw_paths"].add(flow.request.path.split("?", 1)[0])
                if flow.response is not None:
                    ep["status"].add(flow.response.status_code)
                # Keep the first fully-formed sample of req/resp for the shape.
                if ep["req"] is None:
                    ep["req"] = {
                        "content_type": flow.request.headers.get("content-type", ""),
                        "query": [(k, (_MASK if redact and SECRET_KEY.search(k) else v))
                                  for k, v in flow.request.query.items()],
                        "headers": headers_summary(flow.request.headers, redact),
                        "body": parse_body(flow.request.raw_content or b"",
                                           flow.request.headers.get("content-type", ""), redact),
                    }
                if ep["resp"] is None and flow.response is not None and flow.response.raw_content:
                    ep["resp"] = {
                        "content_type": flow.response.headers.get("content-type", ""),
                        "body": parse_body(flow.response.raw_content,
                                           flow.response.headers.get("content-type", ""), redact),
                    }

    lines: list[str] = []
    w = lines.append
    w("# Qareeb API — captured contract")
    w("")
    w(f"- Flows analysed: **{total}**" + ("" if not host_filter else f" (host contains `{args.host}`)"))
    w(f"- Redaction: **{'ON' if redact else 'OFF — values shown'}**")
    w(f"- Endpoints: **{len(endpoints)}**")
    w("")
    w("## Hosts seen")
    for h in sorted(hosts):
        mark = " ←" if host_filter and host_filter in h.lower() else ""
        w(f"- `{h}`{mark}")
    w("")
    w("## Endpoints")
    for (method, host, tmpl), ep in sorted(endpoints.items(), key=lambda kv: (kv[0][1], kv[0][2], kv[0][0])):
        statuses = ",".join(str(s) for s in sorted(ep["status"])) or "—"
        w(f"### `{method} {tmpl}`")
        w(f"host `{host}` · seen {ep['count']}× · status {statuses}")
        if len(ep["raw_paths"]) > 1:
            w(f"<sub>concrete paths: {', '.join(sorted(ep['raw_paths'])[:5])}"
              + (" …" if len(ep["raw_paths"]) > 5 else "") + "</sub>")
        req = ep["req"] or {}
        if req.get("query"):
            w("**query**")
            w("```")
            for k, v in req["query"]:
                w(f"{k}={v}")
            w("```")
        if req.get("body") is not None:
            w(f"**request** ({req.get('content_type') or 'n/a'})")
            w("```json")
            w(json.dumps(req["body"], ensure_ascii=False, indent=2))
            w("```")
        if ep["resp"] is not None:
            w(f"**response** ({ep['resp'].get('content_type') or 'n/a'})")
            w("```json")
            w(json.dumps(ep["resp"]["body"], ensure_ascii=False, indent=2))
            w("```")
        w("")

    report = "\n".join(lines)
    if args.out:
        with open(args.out, "w", encoding="utf-8") as fh:
            fh.write(report)
        print(f"Wrote {args.out} ({len(endpoints)} endpoints, {total} flows).", file=sys.stderr)
    else:
        print(report)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
