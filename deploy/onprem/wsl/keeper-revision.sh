#!/usr/bin/env bash
#
# The keeper's revision, kept honest.
#
# keep-pointy-running.ps1 declares "# pointy-keeper-revision: N", and every
# copy of it - the release's in the distro, the one the till carries, -Install -
# only ever replaces a LOWER revision. So a change without a new revision would
# never reach a shop that already has the old one. keeper-revision.lock records
# the revision and a hash of everything else in the file; CI fails when they
# disagree.
#
#   bash deploy/onprem/wsl/keeper-revision.sh check
#   bash deploy/onprem/wsl/keeper-revision.sh bump    # make onprem-keeper-revision
set -euo pipefail
cd "$(dirname "$0")"

KEEPER=keep-pointy-running.ps1
LOCK=keeper-revision.lock
TAG='# pointy-keeper-revision:'

sha256() { if command -v sha256sum >/dev/null; then sha256sum | cut -d' ' -f1; else shasum -a 256 | cut -d' ' -f1; fi; }
body_hash() { grep -v "^${TAG}" "$KEEPER" | tr -d '\r' | sha256; }
declared() { grep -m1 "^${TAG}" "$KEEPER" | sed "s/^${TAG}[[:space:]]*//" | tr -d '\r[:space:]'; }

have_rev="$(declared)"
have_hash="$(body_hash)"
lock_rev="$(cut -d' ' -f1 "$LOCK" 2>/dev/null || true)"
lock_hash="$(cut -d' ' -f2 "$LOCK" 2>/dev/null || true)"

case "${1:-check}" in
  check)
    if [ -z "$have_rev" ]; then
      echo "FAIL: ${KEEPER} has no '${TAG} N' line." >&2; exit 1
    fi
    if [ "$have_rev" != "$lock_rev" ] || [ "$have_hash" != "$lock_hash" ]; then
      echo "FAIL: ${KEEPER} changed without a new revision (file: ${have_rev}, lock: ${lock_rev})." >&2
      echo "      A shop with the old keeper would never take it. Run: make onprem-keeper-revision" >&2
      exit 1
    fi
    echo "keeper revision ${have_rev} matches its contents"
    ;;
  bump)
    if [ "$have_hash" = "$lock_hash" ] && [ "$have_rev" = "$lock_rev" ]; then
      echo "keeper unchanged; revision stays ${have_rev}"; exit 0
    fi
    next=$(( ${lock_rev:-0} + 1 ))
    if [ "${have_rev:-0}" -ge "$next" ] 2>/dev/null; then next="$have_rev"; fi
    tmp="$(mktemp)"
    sed "s/^${TAG}.*/${TAG} ${next}/" "$KEEPER" > "$tmp" && cat "$tmp" > "$KEEPER" && rm -f "$tmp"
    echo "${next} $(body_hash)" > "$LOCK"
    echo "keeper revision is now ${next}"
    ;;
  *) echo "usage: $0 check|bump" >&2; exit 2 ;;
esac
