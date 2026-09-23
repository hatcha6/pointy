#!/usr/bin/env bash
# Launch mitmproxy in WireGuard mode to capture the Qareeb iPhone app.
#
# WireGuard mode (not a system proxy) is the point: the Qareeb app is Flutter,
# and Flutter's Dart HttpClient ignores the iOS Wi-Fi proxy. WireGuard tunnels
# ALL device traffic through mitmproxy at the network layer, so proxy-blindness
# no longer matters. The iPhone needs the free WireGuard app and mitmproxy's CA
# trusted (see README).
#
# Usage:
#   ./run.sh session   # capture what a LOGGED-IN user can do
#   ./run.sh auth      # capture the login / request-OTP / verify-OTP flow
#   ./run.sh session qareeb   # 2nd arg = host substring to highlight in the log
#
# Each run writes a timestamped, gitignored .flows file under captures/.
set -euo pipefail

cd "$(dirname "$0")"

PHASE="${1:-session}"
export QAREEB_HOST="${2:-}"

case "$PHASE" in
  session|auth) ;;
  *) echo "phase must be 'session' or 'auth' (got '$PHASE')" >&2; exit 2 ;;
esac

if ! command -v mitmweb >/dev/null 2>&1; then
  echo "mitmproxy not found. Install it first:" >&2
  echo "    brew install mitmproxy      # or: make qareeb-capture-setup" >&2
  exit 1
fi

mkdir -p captures
STAMP="$(date +%Y%m%d-%H%M%S)"
OUT="captures/qareeb-${PHASE}-${STAMP}.flows"

# Best-effort: show the Mac's Wi-Fi IP so you can sanity-check the iPhone is on
# the same LAN (WireGuard mode still tunnels, but same-LAN keeps latency sane).
WIFI_DEV="$(networksetup -listallhardwareports 2>/dev/null | awk '/Wi-Fi|AirPort/{getline; print $2}')"
WIFI_IP="$(ipconfig getifaddr "${WIFI_DEV:-en1}" 2>/dev/null || true)"

cat <<EOF
──────────────────────────────────────────────────────────────────────────────
 Qareeb capture — phase: ${PHASE}
   writing → ${OUT}
   Mac Wi-Fi IP: ${WIFI_IP:-<unknown>}   (iPhone should share this LAN)
   mitmweb UI  → http://127.0.0.1:8081   (WireGuard QR + config are shown here)
   CA to trust → ~/.mitmproxy/mitmproxy-ca-cert.pem
                 (also at http://mitm.it from the phone once tunnelled)

 On the iPhone (once, per README):
   1. Install the WireGuard app.
   2. Add the tunnel from the QR in the mitmweb UI, toggle it ON.
   3. Install + FULLY TRUST the mitmproxy CA
      (Settings → General → VPN & Device Management, then
       Settings → General → About → Certificate Trust Settings).

 Then drive the app. Watch the lines below to spot Qareeb's API host.
 Stop with Ctrl-C — the host tally and any TLS-pinning warnings print at exit.
──────────────────────────────────────────────────────────────────────────────
EOF

exec mitmweb --mode wireguard -s capture.py -w "$OUT" --set web_host=127.0.0.1
