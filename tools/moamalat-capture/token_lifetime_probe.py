#!/usr/bin/env python3
"""Moamalat merchant API — login + transaction poll + token-lifetime probe.

What it does
------------
1. Logs in to https://merchant.moamalat.net/api (username + password, with an
   interactive OTP step if the server demands one).
2. Extracts the bearer JWT from the login response (auto-detected anywhere in
   the JSON — the field name is not known from the binary).
3. Polls the transactions endpoint on an interval, exactly like a live-counter
   reconciliation job would, sending `Authorization: Bearer <token>`.
4. Watches for the token to die. Moamalat signals a dead token with HTTP 401 and
   body `{"oprationstate": "6"}` (confirmed empirically 2026-10-12). When that
   first happens, it records how long the token lived and appends one JSON line
   to `token-lifetime.jsonl`, then stops (or re-logins with --loop).

The lifetime is measured from the JWT's own `date` claim (the server's issue
time) when present, else from the moment of login, to the first rejection.

Privacy: this NEVER writes the password, OTP, or token to disk or stdout. Only
redacted metadata (issue time, death time, elapsed, user_id/outlet from the
token) goes into the log.

This is view-only — it only reads. It does not create or move anything on
Moamalat's side. Use it against your OWN merchant account.

Usage
-----
    export MOAMALAT_USER='hatemu'
    export MOAMALAT_PASS='...'        # or you'll be prompted (no echo)
    python3 -I token_lifetime_probe.py --interval 300

    # keep re-logging in to measure lifetime repeatedly:
    python3 -I token_lifetime_probe.py --interval 300 --loop

Run with `python3 -I` so nothing from the cwd is importable.
"""
from __future__ import annotations

import argparse
import base64
import datetime as dt
import getpass
import json
import os
import ssl
import sys
import time
import urllib.error
import urllib.request

BASE = os.environ.get("MOAMALAT_BASE", "https://merchant.moamalat.net/api")
HERE = os.path.dirname(os.path.abspath(__file__))
LOG_PATH = os.path.join(HERE, "token-lifetime.jsonl")

# Endpoints (paths recovered from the APK; bodies/methods are best-effort and
# overridable via flags because the AOT binary does not reveal them).
LOGIN_PATH = os.environ.get("MOAMALAT_LOGIN_PATH", "/login-user")
VERIFY_PATH = os.environ.get("MOAMALAT_VERIFY_PATH", "/verify-code")
# Transactions list (confirmed by live web capture): POST /transformerch?page=N.
TX_PATH = os.environ.get("MOAMALAT_TX_PATH", "/transformerch?page=1")
PUBLIC_KEY = os.environ.get("MOAMALAT_PUBLICKEY", "BecomITPementKey")

UA = "moamalat-token-lifetime-probe/1.0 (pointy reconciliation research)"


def now_utc() -> dt.datetime:
    return dt.datetime.now(dt.timezone.utc)


def http(method: str, path: str, token: str | None = None,
         body: dict | None = None, timeout: int = 30) -> tuple[int, dict | str]:
    """Return (status_code, parsed_json_or_text). Never raises on HTTP errors."""
    url = BASE + path
    data = json.dumps(body).encode() if body is not None else None
    headers = {
        "Accept": "application/json",
        "Content-Type": "application/json",
        "User-Agent": UA,
    }
    if token:
        headers["Authorization"] = "Bearer " + token
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    ctx = ssl.create_default_context()
    try:
        with urllib.request.urlopen(req, timeout=timeout, context=ctx) as r:
            raw = r.read().decode("utf-8", "replace")
            return r.status, _maybe_json(raw)
    except urllib.error.HTTPError as e:
        raw = e.read().decode("utf-8", "replace")
        return e.code, _maybe_json(raw)
    except urllib.error.URLError as e:
        return 0, f"network error: {e.reason}"


def _maybe_json(raw: str):
    try:
        return json.loads(raw)
    except Exception:
        return raw


def find_jwt(obj) -> str | None:
    """Recursively find the first value that looks like a JWT (a.b.c base64url)."""
    def looks_like_jwt(s: str) -> bool:
        if not isinstance(s, str) or s.count(".") != 2:
            return False
        head = s.split(".", 1)[0]
        try:
            dec = base64.urlsafe_b64decode(head + "=" * (-len(head) % 4))
            return b'"alg"' in dec and b'"typ"' in dec
        except Exception:
            return False

    stack = [obj]
    while stack:
        cur = stack.pop()
        if isinstance(cur, str) and looks_like_jwt(cur):
            return cur
        if isinstance(cur, dict):
            stack.extend(cur.values())
        elif isinstance(cur, list):
            stack.extend(cur)
    return None


def decode_payload(token: str) -> dict:
    try:
        p = token.split(".")[1]
        return json.loads(base64.urlsafe_b64decode(p + "=" * (-len(p) % 4)))
    except Exception:
        return {}


def issue_time(token: str, fallback: dt.datetime) -> dt.datetime:
    """Issue time from the JWT `date` claim (naive, treated as UTC) else fallback."""
    payload = decode_payload(token)
    # issue-time claim name differs by client: app token = "date", web = "idsissen".
    claim = payload.get("idsissen") or payload.get("date")
    if isinstance(claim, str):
        for fmt in ("%Y-%m-%d %H:%M:%S.%f", "%Y-%m-%d %H:%M:%S"):
            try:
                return dt.datetime.strptime(claim, fmt).replace(tzinfo=dt.timezone.utc)
            except ValueError:
                continue
    return fallback


def is_dead(status: int, body) -> bool:
    if status == 401:
        return True
    if isinstance(body, dict) and str(body.get("oprationstate")) == "6":
        return True
    return False


# Auth flow confirmed by live capture of the Nuxt web portal (2026-10-12):
#   step 1  POST /login-user  {username, password, publickey, version, os}
#           -> {msg, token: <otp-session-token>}   (data.oprationstate == "1")
#   step 2  POST /verify-code {code: <otp>, token: <otp-session-token>}
#           -> {msg, token: <BEARER JWT>, firstlog}
# OTP is required on EVERY login (no OTP-less path exists). Step 2's `token`
# field is the step-1 session token, NOT the username — this is the part the
# AOT binary could not reveal.
VERSION = os.environ.get("MOAMALAT_VERSION", "1.1.0")
OS_FIELD = os.environ.get("MOAMALAT_OS", "web")


def _unwrap(body) -> dict:
    """Portal wraps payloads as {success, data:{...}} or returns the dict directly."""
    if isinstance(body, dict) and isinstance(body.get("data"), dict):
        return body["data"]
    return body if isinstance(body, dict) else {}


def login(user: str, password: str) -> str:
    """Two-step OTP login (OTP required every time). Returns the bearer JWT."""
    # Step 1 — credentials; server texts an OTP and returns a session token.
    body1 = {"username": user, "password": password,
             "publickey": PUBLIC_KEY, "version": VERSION, "os": OS_FIELD}
    print(f"[login] step 1: POST {LOGIN_PATH} as {user!r} (expect OTP sent) ...",
          file=sys.stderr)
    status, body = http("POST", LOGIN_PATH, body=body1)
    data = _unwrap(body)
    session_token = data.get("token")
    if not session_token:
        print(f"[login] step 1 gave no session token (HTTP {status}); "
              f"shape: {shape(body)}", file=sys.stderr)
        sys.exit("aborted: login step 1 failed (check credentials / publickey).")
    print(f"[login] OTP sent: {data.get('msg', '')}", file=sys.stderr)

    # Step 2 — the OTP the merchant just received by SMS. This needs a human.
    code = input("[login] enter the OTP from SMS (blank to abort): ").strip()
    if not code:
        sys.exit("aborted: OTP is mandatory on every login and none was given.")

    body2 = {"code": code, "token": session_token}
    print(f"[login] step 2: POST {VERIFY_PATH} ...", file=sys.stderr)
    status, body = http("POST", VERIFY_PATH, body=body2)
    bearer = find_jwt(body) or _unwrap(body).get("token")
    if not bearer or bearer.count(".") != 2:
        print(f"[login] no bearer JWT after verify (HTTP {status}); "
              f"shape: {shape(body)}", file=sys.stderr)
        sys.exit("aborted: OTP verify did not return a bearer token.")
    print("[login] got bearer token after OTP verify.", file=sys.stderr)
    return bearer


def shape(obj, depth: int = 0) -> str:
    """Render JSON structure with values redacted, for debugging unknown responses."""
    if isinstance(obj, dict):
        return "{" + ", ".join(f"{k}: {shape(v, depth+1)}" for k, v in obj.items()) + "}"
    if isinstance(obj, list):
        return "[" + (shape(obj[0], depth+1) if obj else "") + (", ...]" if len(obj) > 1 else "]")
    if isinstance(obj, str):
        return "<str>"
    return f"<{type(obj).__name__}>"


def append_log(record: dict) -> None:
    with open(LOG_PATH, "a") as f:
        f.write(json.dumps(record) + "\n")
    print(f"[log] wrote lifetime record to {LOG_PATH}", file=sys.stderr)


def fmt_dur(seconds: float) -> str:
    s = int(seconds)
    h, s = divmod(s, 3600)
    m, s = divmod(s, 60)
    return f"{h}h{m:02d}m{s:02d}s"


def resolve_mid(token: str) -> str | None:
    """Fetch the account's primary MID so the tx probe returns a clean 200."""
    status, body = http("GET", "/get-merchant/dest", token=token)
    data = _unwrap(body)
    lst = data.get("listOfMerchant") or (data if isinstance(data, list) else [])
    if isinstance(lst, list) and lst and isinstance(lst[0], dict):
        return lst[0].get("outlet_number")
    return None


def probe(token: str, tx_body: dict) -> tuple[bool, int, object]:
    """One real transactions query. Returns (dead?, status, body)."""
    status, body = http("POST", TX_PATH, token=token, body=tx_body)
    return is_dead(status, body), status, body


def _tx_body(token: str) -> tuple[dict, dict]:
    """Resolve MID → transactions body; return (tx_body, jwt_payload)."""
    payload = decode_payload(token)
    mid = resolve_mid(token) or payload.get("outlet")
    return ({"out_let": mid} if mid else {}), payload


def watch(token: str, interval: int) -> dict:
    """Keep the token warm (poll every `interval`s) until it dies.

    Measures the lifetime under CONTINUOUS activity — it does NOT reveal an idle
    timeout (polling resets any sliding window). Use --idle-probe for that.
    """
    login_at = now_utc()
    issued = issue_time(token, login_at)
    tx_body, payload = _tx_body(token)
    print(f"[watch] token issued {issued.isoformat()} "
          f"(user_id={payload.get('user_id')}, out_let={tx_body.get('out_let')}); "
          f"polling {TX_PATH} every {interval}s", file=sys.stderr)
    probes = 0
    while True:
        dead, status, body = probe(token, tx_body)
        probes += 1
        t = now_utc()
        if dead:
            elapsed = (t - issued).total_seconds()
            print(f"[watch] token DEAD after {fmt_dur(elapsed)} "
                  f"(HTTP {status}) — {probes} probes", file=sys.stderr)
            return {
                "kind": "token_lifetime_active",
                "base": BASE, "tx_path": TX_PATH,
                "user_id": payload.get("user_id"), "outlet": payload.get("outlet"),
                "issued_at": issued.isoformat(), "login_at": login_at.isoformat(),
                "died_at": t.isoformat(),
                "lifetime_seconds": round(elapsed, 1), "lifetime_human": fmt_dur(elapsed),
                "seconds_since_login": round((t - login_at).total_seconds(), 1),
                "probe_interval_s": interval, "probes": probes,
                "death_status": status,
                "death_signal": body if isinstance(body, dict) else str(body)[:120],
            }
        note = "alive" if status == 200 else f"ambiguous HTTP {status}"
        print(f"[watch] probe #{probes} {note}; alive "
              f"{fmt_dur((t - issued).total_seconds())}; sleeping {interval}s",
              file=sys.stderr)
        time.sleep(interval)


def watch_idle(token: str, backoff: list[int]) -> dict:
    """Measure the IDLE timeout: probe at widening gaps, staying quiet between.

    After each successful probe we go silent for the next `backoff` gap, then
    probe again. The gap since the last *successful* probe is the idle the
    server saw. When a probe comes back dead, the idle timeout lies between the
    longest gap it survived and the gap that killed it.
    """
    login_at = now_utc()
    issued = issue_time(token, login_at)
    tx_body, payload = _tx_body(token)
    # confirm alive at t0 before starting the idle clock
    dead, status, _ = probe(token, tx_body)
    if dead:
        sys.exit(f"aborted: token already dead at start (HTTP {status}).")
    last_alive = now_utc()
    print(f"[idle] token issued {issued.isoformat()} — alive at t0. "
          f"backoff gaps: {[fmt_dur(g) for g in backoff]}", file=sys.stderr)

    survived_max = 0.0  # longest idle gap the token survived
    step = 0
    while True:
        gap = backoff[min(step, len(backoff) - 1)]
        print(f"[idle] going quiet for {fmt_dur(gap)} ...", file=sys.stderr)
        time.sleep(gap)
        dead, status, body = probe(token, tx_body)
        t = now_utc()
        idle = (t - last_alive).total_seconds()
        if dead:
            print(f"[idle] token DEAD after {fmt_dur(idle)} idle "
                  f"(survived up to {fmt_dur(survived_max)}) — HTTP {status}",
                  file=sys.stderr)
            return {
                "kind": "token_lifetime_idle",
                "base": BASE, "tx_path": TX_PATH,
                "user_id": payload.get("user_id"), "outlet": payload.get("outlet"),
                "issued_at": issued.isoformat(), "login_at": login_at.isoformat(),
                "died_at": t.isoformat(),
                "total_lifetime_human": fmt_dur((t - issued).total_seconds()),
                "idle_timeout_lower_s": round(survived_max, 1),
                "idle_timeout_lower_human": fmt_dur(survived_max),
                "idle_timeout_upper_s": round(idle, 1),
                "idle_timeout_upper_human": fmt_dur(idle),
                "death_status": status,
                "death_signal": body if isinstance(body, dict) else str(body)[:120],
            }
        survived_max = max(survived_max, idle)
        last_alive = t
        step += 1
        print(f"[idle] still alive after {fmt_dur(idle)} idle "
              f"(total {fmt_dur((t - issued).total_seconds())}); widening gap",
              file=sys.stderr)


def main() -> None:
    ap = argparse.ArgumentParser(description="Moamalat token-lifetime probe (view-only).")
    ap.add_argument("--interval", type=int, default=300,
                    help="seconds between transaction polls (default 300 = 5 min; "
                         "smaller = finer resolution on the death time)")
    ap.add_argument("--loop", action="store_true",
                    help="after a token dies, log in again and keep measuring")
    ap.add_argument("--idle-probe", action="store_true",
                    help="measure the IDLE timeout: stay quiet between probes at "
                         "widening gaps instead of polling continuously")
    ap.add_argument("--backoff", default="900,1800,3600,7200,14400,28800",
                    help="idle-probe gap schedule in seconds (last value repeats); "
                         "default 15m,30m,1h,2h,4h,8h")
    args = ap.parse_args()

    user = os.environ.get("MOAMALAT_USER") or input("Moamalat username: ").strip()
    password = os.environ.get("MOAMALAT_PASS") or getpass.getpass("Moamalat password: ")
    backoff = [int(x) for x in args.backoff.split(",") if x.strip()]

    while True:
        token = login(user, password)
        record = watch_idle(token, backoff) if args.idle_probe \
            else watch(token, args.interval)
        append_log(record)
        if record["kind"] == "token_lifetime_idle":
            print(f"\n>>> IDLE timeout is between "
                  f"{record['idle_timeout_lower_human']} and "
                  f"{record['idle_timeout_upper_human']}. "
                  f"Logged to {os.path.basename(LOG_PATH)}.\n", file=sys.stderr)
        else:
            print(f"\n>>> token lived {record['lifetime_human']} under active "
                  f"polling. Logged to {os.path.basename(LOG_PATH)}.\n",
                  file=sys.stderr)
        if not args.loop:
            break
        print("[loop] re-logging in for another measurement "
              "(needs a fresh OTP) ...", file=sys.stderr)


if __name__ == "__main__":
    main()
