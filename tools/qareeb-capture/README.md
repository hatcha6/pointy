# Qareeb capture

Groundwork for building the Qareeb driver (`backend/apps/integrations/providers/qareeb.py`,
currently a `PlannedProvider`). LNET and HD Box were reverse-engineered from a
captured agency session; Qareeb is the same job, but the agency console is a
**Flutter iPhone app**, not a web portal — so the capture mechanism is different.

## Why not just a proxy

The Qareeb app is Flutter. Flutter's networking is Dart's `HttpClient`, and on
iOS it **ignores the system Wi-Fi proxy**. Setting Settings → Wi-Fi → Proxy to
your Mac captures *nothing* from it — the app goes straight out around the proxy.
Charles / Proxyman hit the same wall.

The fix is to intercept **below** the app, at the network layer, so proxy-blindness
stops mattering. We use **mitmproxy's WireGuard mode**: mitmproxy runs a WireGuard
server, the iPhone joins it with the free WireGuard app, and every packet the
phone sends tunnels through mitmproxy. Two things still have to hold to read the
decrypted bodies:

1. mitmproxy's CA is installed **and fully trusted** on the iPhone (two iOS steps).
2. The app does **not** certificate-pin. A payments/top-up app might. You will
   know in seconds — pinned hosts show as `TLS handshake FAILED` in the live log
   and the app throws a network error. If Qareeb's own host is in that list, see
   [If it pins](#if-it-pins).

## One-time setup

On the Mac:

```bash
brew install mitmproxy      # or: make qareeb-capture-setup
```

On the iPhone:

1. Install **WireGuard** from the App Store.
2. Start a capture (below) so mitmproxy generates its WireGuard config, open the
   mitmweb UI at <http://127.0.0.1:8081>, and scan the WireGuard QR into the app.
   Toggle the tunnel **on**.
3. With the tunnel on, open Safari to <http://mitm.it>, download the Apple
   profile, then:
   - **Install** it: Settings → General → VPN & Device Management → the profile.
   - **Trust** it: Settings → General → About → Certificate Trust Settings →
     turn the mitmproxy cert **on**. This second step is the one everyone forgets;
     without it every HTTPS body stays encrypted.

## Capturing

Two phases, two runs, two files. Each `.flows` file is timestamped and gitignored.

**Logged-in surface** — what an authenticated agency user can do. Log into the app
first, then:

```bash
./run.sh session
```

Now walk the whole app: dashboard, balance/float, customer/line lookup, a top-up
you *don't* confirm, history, receipts, settings — every screen you want the
driver to reach. Ctrl-C to stop. The exit tally shows every host hit; that is how
you find Qareeb's API domain.

**Auth flow** — login, request OTP, enter OTP, logged in. Log out (or start from a
cold app), then:

```bash
./run.sh auth
```

Do exactly: open → enter phone/username → request OTP → type the OTP → land
logged in. Ctrl-C. This capture contains the OTP request, the verify call, and
the token/session the app gets back — the three things the driver's login needs.

> The second argument highlights a host once you know it, e.g. `./run.sh session api.qareeb`.

## Turning a capture into a contract

```bash
# first pass — see every host, find Qareeb's domain
python3 analyze_flows.py captures/qareeb-session-*.flows | less

# focused, redacted report you can keep and design against
python3 analyze_flows.py captures/qareeb-session-*.flows --host qareeb --out contract-session.md
python3 analyze_flows.py captures/qareeb-auth-*.flows    --host qareeb --out contract-auth.md
```

The report groups requests by `METHOD /path/:id` template and prints request and
response **shapes** — keys and types, not values. It is **redacted by default**:
OTP, tokens, cookies, the phone number are masked, so the `contract-*.md` is safe
to paste into a design note while the raw `.flows` stays local.

`--show-values` disables redaction. Only ever use it on a **logged-out** capture
you have already eyeballed — an auth capture with values shown is a plaintext OTP
and bearer token on disk.

## Secrets & hygiene

- Raw `.flows`, `.har`, `.pem`, `.key` and `*.conf` are gitignored here. Keep them
  local, read them locally, **delete them** once the contract is written. Same
  discipline as `tools/dump-analysis` and the LNET HAR.
- Never commit a capture, drop it in a share, or paste it into chat. Only the
  redacted `contract-*.md` — after you have read it — is safe to keep, and it is
  gitignored too so committing it is a deliberate choice, not an accident.
- This is your own agency account on your own phone. The capture is of a service
  you are authorised to use; the caution is about the OTP/token/phone it records,
  not about the act.

## If it pins

If Qareeb's own host shows `TLS handshake FAILED`, the app pins its certificate
and WireGuard + a trusted CA cannot decrypt it. That is a separate, heavier
decision — options are a jailbroken test device with an SSL-unpinning tweak, or
`reFlutter`/Frida against a repackaged build — none of which we do without
talking about it first. Capture what you can (you will still see hosts, timing
and TLS SNI), note it, and stop there.

## Files

| file | what |
|---|---|
| `run.sh` | launch mitmproxy (WireGuard mode) for a `session` or `auth` capture |
| `capture.py` | mitmproxy addon: live per-response log, host tally, pinning tell |
| `analyze_flows.py` | `.flows` → redacted Markdown contract |
| `captures/` | raw captures (gitignored) |
