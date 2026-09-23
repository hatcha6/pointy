"""Read-mode addon: dump a redacted, chronological report of one host's flows.

The cask build of mitmproxy discards stdout, and system Python can't import
mitmproxy, so neither console logs nor analyze_flows.py work here. This runs
INSIDE mitmproxy instead:

    QAREEB_REPORT=/path/out.txt QAREEB_HOST=qareb \
      mitmdump -nr capture.flows -s flow_report.py

`-nr` replays a saved file, firing request/response/error per flow; we collect
the ones whose host contains QAREEB_HOST and write them to QAREEB_REPORT on exit
(stdout is unreadable, a file is not). Secrets (otp/token/password/phone/auth)
are masked; status codes and error messages are kept — those are the diagnosis.
"""
from __future__ import annotations
import json, os
from collections import OrderedDict

TARGET = os.environ.get("QAREEB_HOST", "qareb").lower()
OUT = os.environ.get("QAREEB_REPORT", "/tmp/qareeb_report.txt")
TAIL = int(os.environ.get("QAREEB_TAIL", "0"))  # 0 = all
SECRET = ("otp", "password", "passwd", "token", "secret", "pin", "authorization",
          "auth", "phone", "mobile", "msisdn", "refresh", "access", "session", "jwt",
          "username")  # username IS the phone number on Qareeb


def _secret(k: str) -> bool:
    k = k.lower()
    return any(s in k for s in SECRET)


def redact(o, depth=0):
    if depth > 6:
        return "…"
    if isinstance(o, dict):
        return {k: ("«redacted»" if _secret(k) else redact(v, depth + 1)) for k, v in o.items()}
    if isinstance(o, list):
        return ([redact(o[0], depth + 1), f"…×{len(o)}"] if len(o) > 1
                else [redact(o[0], depth + 1)]) if o else []
    if isinstance(o, str) and len(o) > 60:
        return f"<str len={len(o)}>"
    return o


def body_summary(msg):
    if not msg or not msg.raw_content:
        return ""
    ct = msg.headers.get("content-type", "")
    if "json" in ct:
        try:
            return json.dumps(redact(json.loads(msg.get_text())), ensure_ascii=False)[:600]
        except Exception:
            return f"<unparsed json {len(msg.raw_content)}b>"
    if "form-urlencoded" in ct:
        try:
            from urllib.parse import parse_qsl
            return json.dumps({k: ("«redacted»" if _secret(k) else v)
                               for k, v in parse_qsl(msg.get_text())}, ensure_ascii=False)[:600]
        except Exception:
            return f"<form {len(msg.raw_content)}b>"
    return f"<{ct or 'body'} {len(msg.raw_content)}b>"


class Report:
    def __init__(self):
        self.flows = OrderedDict()  # id -> row

    def request(self, flow):
        if TARGET not in flow.request.pretty_host.lower():
            return
        r = flow.request
        self.flows[flow.id] = {
            "method": r.method, "host": r.pretty_host,
            "path": r.path.split("?", 1)[0], "query": r.path.split("?", 1)[1] if "?" in r.path else "",
            "req_ct": r.headers.get("content-type", ""),
            "req_body": body_summary(r) if r.method in ("POST", "PUT", "PATCH") else "",
            "status": "NO RESPONSE", "resp": "",
        }

    def response(self, flow):
        row = self.flows.get(flow.id)
        if row is None:
            return
        row["status"] = flow.response.status_code
        row["resp"] = body_summary(flow.response)

    def error(self, flow):
        row = self.flows.get(flow.id)
        if row is not None:
            row["status"] = f"ERROR: {flow.error}"

    def done(self):
        rows = list(self.flows.values())
        if TAIL:
            rows = rows[-TAIL:]
        lines = []
        # chronological transcript
        for r in rows:
            q = f"?{r['query']}" if r["query"] else ""
            lines.append(f"{r['status']:>12}  {r['method']:6} {r['path']}{q}")
            if r["req_body"]:
                lines.append(f"                → req:  {r['req_body']}")
            bad = str(r["status"]).startswith(("4", "5", "N", "E"))
            if r["resp"] and (bad or r["method"] != "GET"):
                lines.append(f"                ← resp: {r['resp']}")
        # summary by endpoint+status
        agg = OrderedDict()
        for r in rows:
            key = (r["method"], r["path"], str(r["status"]))
            agg[key] = agg.get(key, 0) + 1
        lines.append("\n=== summary (method path status ×count) ===")
        for (m, p, s), n in sorted(agg.items()):
            lines.append(f"  {n:4}×  {s:>12}  {m:6} {p}")
        with open(OUT, "w", encoding="utf-8") as f:
            f.write("\n".join(lines) + "\n")


addons = [Report()]
